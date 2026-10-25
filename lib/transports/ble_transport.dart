import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart' as per;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../core/fragmenter.dart';
import '../core/frame.dart';
import '../core/transport.dart';

/// Bluetooth Low Energy transport: the only phone-to-phone radio link that
/// works between Android and iPhone with no network at all.
///
/// Every phone plays BOTH roles at once:
/// * Peripheral (flutter_ble_peripheral): advertises [serviceUuid] and serves
///   a GATT service with a notify characteristic ([txUuid], phone -> its
///   centrals) and a write-without-response characteristic ([rxUuid],
///   centrals -> phone).
/// * Central (flutter_blue_plus): scans for [serviceUuid], connects to up to
///   [maxCentralLinks] phones, subscribes to their TX and writes to their RX.
///
/// Budget: Opus at 12 kbps / 20 ms = ~30 B per packet + 12 B frame header
/// + 2 B fragment prefix = ~44 B, 50 packets/s, ~17 kbps on air. That fits a
/// single BLE packet once MTU >= 47 (Android requests 512, iOS negotiates
/// ~185 automatically). On the 23 B default MTU frames are fragmented into
/// 3 chunks, which still works but is near the practical limit.
///
/// Peer identity is not in the advertisement (a 128-bit UUID already uses
/// most of the 31 B legacy advertising payload); it is learned from the
/// sender id of the first frame (hello) received on each link.
class BleTransport extends Transport {
  BleTransport({
    this.maxCentralLinks = 4,
    this.fbpLicense = fbp.License.nonprofit,
  });

  static const String serviceUuid = 'a7e1c0de-5741-4c4b-9e1e-77616c6b6965';
  static const String txUuid = 'a7e1c0de-5741-4c4b-9e1e-000000000001';
  static const String rxUuid = 'a7e1c0de-5741-4c4b-9e1e-000000000002';

  final int maxCentralLinks;

  /// flutter_blue_plus 2.x requires declaring a license on connect. It is
  /// free for personal/non-profit use; for-profit use needs a commercial
  /// license from the author. See README.
  final fbp.License fbpLicense;

  final _peripheral = per.FlutterBlePeripheral();
  TransportStatus _status = TransportStatus.stopped;
  String? _detail;
  final _statusCtl = StreamController<TransportStatus>.broadcast();
  final _framesCtl = StreamController<InboundFrame>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];

  // Central-role links, keyed by remote device id.
  final Map<String, _CentralLink> _links = {};
  final Set<String> _connecting = {};
  // Which link reaches which node id (learned from frames).
  final Map<int, String> _peerToLink = {};
  // Node ids that reach us through our peripheral (they are our centrals).
  final Set<int> _peripheralPeers = {};

  final _peripheralReassembler = Reassembler();
  final _peripheralFragmenter = Fragmenter(maxChunkSize: 20);
  bool _peripheralUp = false;

  @override
  TransportKind get kind => TransportKind.ble;
  @override
  TransportStatus get status => _status;
  @override
  String? get statusDetail => _detail;
  @override
  Stream<TransportStatus> get statusChanges => _statusCtl.stream;
  @override
  Stream<InboundFrame> get frames => _framesCtl.stream;

  void _setStatus(TransportStatus s, [String? detail]) {
    _status = s;
    _detail = detail;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    if (_status == TransportStatus.running ||
        _status == TransportStatus.starting) {
      return;
    }
    _setStatus(TransportStatus.starting);
    if (!await fbp.FlutterBluePlus.isSupported) {
      _setStatus(TransportStatus.unavailable, 'Bluetooth LE not supported');
      return;
    }
    _listenOnce();
    // React to the adapter being turned on/off at any time.
    _subs.add(fbp.FlutterBluePlus.adapterState.listen((state) async {
      if (state == fbp.BluetoothAdapterState.on) {
        await _bringUp();
      } else if (state == fbp.BluetoothAdapterState.off ||
          state == fbp.BluetoothAdapterState.unauthorized) {
        await _tearDown();
        _setStatus(TransportStatus.unavailable,
            state == fbp.BluetoothAdapterState.off
                ? 'Bluetooth is off'
                : 'Bluetooth permission denied');
      }
    }));
    if (Platform.isAndroid &&
        fbp.FlutterBluePlus.adapterStateNow != fbp.BluetoothAdapterState.on) {
      try {
        await fbp.FlutterBluePlus.turnOn();
      } catch (_) {}
    }
  }

  Future<void> _bringUp() async {
    try {
      await _startPeripheral();
    } catch (e) {
      _detail = 'Advertising failed: $e';
    }
    try {
      await _startCentral();
    } catch (e) {
      _detail = '${_detail ?? ''} Scan failed: $e'.trim();
    }
    _setStatus(TransportStatus.running, _detail);
  }

  void _listenOnce() {
    _subs.add(_peripheral.onGattWrite.listen((w) {
      if (w.characteristicUuid.toLowerCase() != rxUuid) return;
      final msg = _peripheralReassembler.add(w.data);
      if (msg == null) return;
      final frame = Frame.tryDecode(msg);
      if (frame == null) return;
      _peripheralPeers.add(frame.senderId);
      _framesCtl.add(InboundFrame(frame, TransportKind.ble));
    }));
    _subs.add(_peripheral.onMtuChanged.listen((mtu) {
      if (mtu > 23) _peripheralFragmenter.maxChunkSize = mtu - 3;
    }));
    _subs.add(fbp.FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        _maybeConnect(r.device);
      }
    }));
  }

  Future<void> _startPeripheral() async {
    if (_peripheralUp) return;
    await _peripheral.start(
      advertiseData: per.AdvertiseDataCore(serviceUuid: serviceUuid),
      gattServer: const per.GattServerSettings(
        serviceUuid: serviceUuid,
        txCharacteristicUuid: txUuid,
        rxCharacteristicUuid: rxUuid,
      ),
    );
    _peripheralUp = true;
  }

  Future<void> _startCentral() async {
    await fbp.FlutterBluePlus.startScan(
      withServices: [fbp.Guid(serviceUuid)],
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 10),
    );
  }

  Future<void> _maybeConnect(fbp.BluetoothDevice device) async {
    final id = device.remoteId.str;
    if (_links.containsKey(id) || _connecting.contains(id)) return;
    if (_links.length + _connecting.length >= maxCentralLinks) return;
    _connecting.add(id);
    try {
      await device.connect(
          license: fbpLicense, timeout: const Duration(seconds: 10));
      final services = await device.discoverServices();
      final service = services.firstWhere(
          (s) => s.uuid == fbp.Guid(serviceUuid),
          orElse: () => throw StateError('service missing'));
      final tx = service.characteristics
          .firstWhere((c) => c.uuid == fbp.Guid(txUuid));
      final rx = service.characteristics
          .firstWhere((c) => c.uuid == fbp.Guid(rxUuid));
      final link = _CentralLink(device, rx,
          Fragmenter(maxChunkSize: (device.mtuNow - 3).clamp(20, 512)));
      link.subs.add(tx.onValueReceived.listen((value) {
        final msg = link.reassembler.add(value);
        if (msg == null) return;
        final frame = Frame.tryDecode(msg);
        if (frame == null) return;
        _peerToLink[frame.senderId] = id;
        _framesCtl.add(InboundFrame(frame, TransportKind.ble));
      }));
      link.subs.add(device.mtu.listen((mtu) {
        link.fragmenter.maxChunkSize = (mtu - 3).clamp(20, 512);
      }));
      link.subs.add(device.connectionState.listen((s) {
        if (s == fbp.BluetoothConnectionState.disconnected) _dropLink(id);
      }));
      await tx.setNotifyValue(true);
      _links[id] = link;
    } catch (_) {
      try {
        await device.disconnect();
      } catch (_) {}
    } finally {
      _connecting.remove(id);
    }
  }

  void _dropLink(String id) {
    final link = _links.remove(id);
    if (link == null) return;
    for (final s in link.subs) {
      s.cancel();
    }
    _peerToLink.removeWhere((_, linkId) => linkId == id);
  }

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    if (_status != TransportStatus.running) return;
    final targets = <_CentralLink>{};
    var notify = false;
    if (peerIds == null) {
      targets.addAll(_links.values);
      notify = true;
    } else {
      for (final id in peerIds) {
        final link = _links[_peerToLink[id]];
        if (link != null) {
          targets.add(link);
        } else if (_peripheralPeers.contains(id)) {
          notify = true;
        }
      }
    }
    final futures = <Future<void>>[];
    for (final link in targets) {
      for (final chunk in link.fragmenter.split(frame)) {
        futures.add(link.rx.write(chunk, withoutResponse: true).catchError((_) {}));
      }
    }
    if (notify && _peripheralUp) {
      for (final chunk in _peripheralFragmenter.split(frame)) {
        // Throws when nobody is subscribed; that is fine.
        futures.add(_peripheral
            .sendData(chunk, characteristicUuid: txUuid)
            .catchError((_) {}));
      }
    }
    await Future.wait(futures);
  }

  Future<void> _tearDown() async {
    try {
      await fbp.FlutterBluePlus.stopScan();
    } catch (_) {}
    for (final id in _links.keys.toList()) {
      final device = _links[id]!.device;
      _dropLink(id);
      try {
        await device.disconnect();
      } catch (_) {}
    }
    if (_peripheralUp) {
      try {
        await _peripheral.stop();
      } catch (_) {}
      _peripheralUp = false;
    }
    _peripheralPeers.clear();
  }

  @override
  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _tearDown();
    _setStatus(TransportStatus.stopped);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _statusCtl.close();
    await _framesCtl.close();
  }
}

class _CentralLink {
  _CentralLink(this.device, this.rx, this.fragmenter);
  final fbp.BluetoothDevice device;
  final fbp.BluetoothCharacteristic rx;
  final Fragmenter fragmenter;
  final Reassembler reassembler = Reassembler();
  final List<StreamSubscription<dynamic>> subs = [];
}
