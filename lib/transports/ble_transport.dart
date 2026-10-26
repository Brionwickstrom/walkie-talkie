import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart' as per;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../core/fragmenter.dart';
import '../core/frame.dart';
import '../core/transport.dart';
import 'ble_scan_lock.dart';

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
/// Latency: on Android each central link asks for MTU 247 (one frame per
/// packet) and high connection priority (7.5-15 ms interval instead of the
/// default ~45 ms). Writes are write-without-response, and audio is dropped
/// rather than queued when a link has more than [maxInflightAudio] frames
/// pending, so a slow link loses a few packets instead of falling seconds
/// behind. While at least one link is up the background scan drops to
/// low-power mode, because scanning steals radio time from connections.
///
/// Failover: a link that disconnects is removed immediately (so the manager
/// stops routing over it via [canReach]); a link silent for [silentLinkDrop]
/// is torn down so the phone can rediscover and reconnect when back in range.
///
/// Peer identity is not in the advertisement (a 128-bit UUID already uses
/// most of the 31 B legacy advertising payload); it is learned from the
/// sender id of the first frame (hello) received on each link.
class BleTransport extends Transport {
  BleTransport({
    this.maxCentralLinks = 4,
    this.fbpLicense = fbp.License.nonprofit,
    this.maxInflightAudio = 2,
    this.silentLinkDrop = const Duration(seconds: 8),
  });

  static const int requestedMtu = 247;
  final int maxInflightAudio;
  final Duration silentLinkDrop;

  static const String serviceUuid = 'a7e1c0de-5741-4c4b-9e1e-77616c6b6965';
  static const String txUuid = 'a7e1c0de-5741-4c4b-9e1e-000000000001';
  static const String rxUuid = 'a7e1c0de-5741-4c4b-9e1e-000000000002';

  final int maxCentralLinks;

  /// Bluetooth ids that are not phones (the paired LoRa radio).
  final Set<String> ignoreDevices = {};
  static final _meshtasticGuid = fbp.Guid(
    '6ba1b218-15a8-461f-9fa8-5dcae273eafd',
  );

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
  // Node ids that reach us through our peripheral (they are our centrals),
  // with the last time we heard from each.
  final Map<int, DateTime> _peripheralPeers = {};
  final Map<String, DateTime> _retryAfter = {};
  int _peripheralInflight = 0;
  int _dropped = 0;
  int _peripheralMtu = 23;
  Timer? _watchdog;
  DateTime? _lastScanStart;
  fbp.AndroidScanMode? _scanMode;

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
    _subs.add(
      fbp.FlutterBluePlus.adapterState.listen((state) async {
        if (state == fbp.BluetoothAdapterState.on) {
          await _bringUp();
        } else if (state == fbp.BluetoothAdapterState.off ||
            state == fbp.BluetoothAdapterState.unauthorized) {
          await _tearDown();
          _setStatus(
            TransportStatus.unavailable,
            state == fbp.BluetoothAdapterState.off
                ? 'Bluetooth is off'
                : 'Bluetooth permission denied',
          );
        }
      }),
    );
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
    _watchdog?.cancel();
    _watchdog = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkLinks(),
    );
    _setStatus(TransportStatus.running, _detail);
  }

  /// Drop silent links, forget stale peripheral peers, keep scanning in the
  /// right mode so peers that come back in range reconnect on their own.
  Future<void> _checkLinks() async {
    final now = DateTime.now();
    // A LoRa radio pairing scan is running: leave the scanner alone (it
    // also looks for our service, so phones are still found).
    final scanLocked = BleScanLock.held;
    for (final e in _links.entries.toList()) {
      if (now.difference(e.value.lastRx) > silentLinkDrop) {
        final device = e.value.device;
        _dropLink(e.key);
        _retryAfter[e.key] = now.add(const Duration(seconds: 2));
        try {
          await device.disconnect();
        } catch (_) {}
      }
    }
    _peripheralPeers.removeWhere((_, t) => now.difference(t) > silentLinkDrop);
    if (scanLocked) return;
    if (_saver) {
      // Battery saver: scan in short bursts (duty cycle) instead of
      // continuously. Existing links stay up; new phones take longer to
      // be found over Bluetooth.
      final cycle = _offline
          ? (_links.isEmpty ? offlineScanCycleIdle : offlineScanCycleLinked)
          : (_links.isEmpty ? saverScanCycleIdle : saverScanCycleLinked);
      final burst = _offline ? offlineScanOn : saverScanOn;
      final since = _lastScanStart == null
          ? null
          : now.difference(_lastScanStart!);
      try {
        if (fbp.FlutterBluePlus.isScanningNow) {
          if (since == null || since >= burst) {
            await fbp.FlutterBluePlus.stopScan();
          }
        } else if (since == null || since >= cycle) {
          await _startCentral();
        }
      } catch (_) {}
      return;
    }
    final wantMode = _links.isEmpty
        ? fbp.AndroidScanMode.lowLatency
        : fbp.AndroidScanMode.lowPower;
    final recently =
        _lastScanStart != null &&
        now.difference(_lastScanStart!) < const Duration(seconds: 10);
    if (!recently &&
        (!fbp.FlutterBluePlus.isScanningNow ||
            (Platform.isAndroid && wantMode != _scanMode))) {
      try {
        await _startCentral();
      } catch (_) {}
    }
  }

  void _listenOnce() {
    _subs.add(
      _peripheral.onGattWrite.listen((w) {
        if (w.characteristicUuid.toLowerCase() != rxUuid) return;
        final msg = _peripheralReassembler.add(w.data);
        if (msg == null) return;
        final frame = Frame.tryDecode(msg);
        if (frame == null) return;
        _peripheralPeers[frame.senderId] = DateTime.now();
        _framesCtl.add(InboundFrame(frame, TransportKind.ble));
      }),
    );
    _subs.add(
      _peripheral.onMtuChanged.listen((mtu) {
        _peripheralMtu = mtu;
        if (mtu > 23) _peripheralFragmenter.maxChunkSize = mtu - 3;
      }),
    );
    _subs.add(
      fbp.FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          // Meshtastic radios (seen while pairing one) are not phones.
          if (r.advertisementData.serviceUuids.contains(_meshtasticGuid)) {
            continue;
          }
          if (ignoreDevices.contains(r.device.remoteId.str)) continue;
          _maybeConnect(r.device);
        }
      }),
    );
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

  bool _saver = false;
  static const saverScanOn = Duration(seconds: 8);
  static const saverScanCycleIdle = Duration(seconds: 30);
  static const saverScanCycleLinked = Duration(seconds: 90);

  @override
  void setPowerSaver(bool on) => _saver = on;

  /// Offline power save: even shorter bursts, longer gaps, low-power scan
  /// mode. (Advertising already uses Android's low-power default.)
  bool _offline = false;
  bool get offlineSaver => _offline;
  static const offlineScanOn = Duration(seconds: 5);
  static const offlineScanCycleIdle = Duration(seconds: 45);
  static const offlineScanCycleLinked = Duration(seconds: 120);

  @override
  void setOfflineSaver(bool on) {
    _offline = on;
    if (on) _saver = true;
  }

  /// Pull-to-refresh (v1.8.5): one fast scan burst now. The normal
  /// schedule (continuous, or duty-cycled in the savers) takes over again
  /// on the next link check, so the burst stays short.
  @override
  void kickDiscovery() {
    if (_status != TransportStatus.running || BleScanLock.held) return;
    final last = _lastScanStart;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 2)) {
      return;
    }
    unawaited(() async {
      try {
        await _startCentral(burst: true);
      } catch (_) {}
    }());
  }

  Future<void> _startCentral({bool burst = false}) async {
    final mode = burst
        ? fbp.AndroidScanMode.lowLatency
        : _offline
        ? fbp.AndroidScanMode.lowPower
        : _saver
        ? (_links.isEmpty
              ? fbp.AndroidScanMode.balanced
              : fbp.AndroidScanMode.lowPower)
        : _links.isEmpty
        ? fbp.AndroidScanMode.lowLatency
        : fbp.AndroidScanMode.lowPower;
    _lastScanStart = DateTime.now();
    if (fbp.FlutterBluePlus.isScanningNow) {
      await fbp.FlutterBluePlus.stopScan();
    }
    await fbp.FlutterBluePlus.startScan(
      withServices: [fbp.Guid(serviceUuid)],
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 10),
      androidScanMode: mode,
    );
    _scanMode = mode;
  }

  Future<void> _maybeConnect(fbp.BluetoothDevice device) async {
    final id = device.remoteId.str;
    if (_links.containsKey(id) || _connecting.contains(id)) return;
    if (_links.length + _connecting.length >= maxCentralLinks) return;
    final retry = _retryAfter[id];
    if (retry != null && DateTime.now().isBefore(retry)) return;
    _connecting.add(id);
    try {
      await device.connect(
        license: fbpLicense,
        timeout: const Duration(seconds: 10),
        mtu: Platform.isAndroid ? requestedMtu : null,
      );
      if (Platform.isAndroid) {
        try {
          await device.requestConnectionPriority(
            connectionPriorityRequest: _saver
                ? fbp.ConnectionPriority.balanced
                : fbp.ConnectionPriority.high,
          );
        } catch (_) {}
      }
      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == fbp.Guid(serviceUuid),
        orElse: () => throw StateError('service missing'),
      );
      final tx = service.characteristics.firstWhere(
        (c) => c.uuid == fbp.Guid(txUuid),
      );
      final rx = service.characteristics.firstWhere(
        (c) => c.uuid == fbp.Guid(rxUuid),
      );
      final link = _CentralLink(
        device,
        rx,
        Fragmenter(maxChunkSize: (device.mtuNow - 3).clamp(20, 512)),
      );
      link.subs.add(
        tx.onValueReceived.listen((value) {
          link.lastRx = DateTime.now();
          final msg = link.reassembler.add(value);
          if (msg == null) return;
          final frame = Frame.tryDecode(msg);
          if (frame == null) return;
          _peerToLink[frame.senderId] = id;
          link.peerIds.add(frame.senderId);
          _framesCtl.add(InboundFrame(frame, TransportKind.ble));
        }),
      );
      link.subs.add(
        device.mtu.listen((mtu) {
          link.fragmenter.maxChunkSize = (mtu - 3).clamp(20, 512);
        }),
      );
      link.subs.add(
        device.connectionState.listen((s) {
          if (s == fbp.BluetoothConnectionState.disconnected) _dropLink(id);
        }),
      );
      await tx.setNotifyValue(true);
      link.lastRx = DateTime.now();
      _links[id] = link;
      _retryAfter.remove(id);
    } catch (_) {
      _retryAfter[id] = DateTime.now().add(const Duration(seconds: 3));
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
  bool canReach(int peerId) {
    if (_links.containsKey(_peerToLink[peerId])) return true;
    final t = _peripheralPeers[peerId];
    return t != null && DateTime.now().difference(t) <= silentLinkDrop;
  }

  @override
  String? get debugInfo {
    final mtus = _links.values.map((l) => l.device.mtuNow).join(',');
    return '${_links.length} link(s)${mtus.isEmpty ? '' : ' mtu $mtus'}'
        ' · ${_peripheralPeers.length} in · periph mtu $_peripheralMtu'
        '${_dropped > 0 ? ' · dropped $_dropped' : ''}';
  }

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    if (_status != TransportStatus.running) return;
    final isAudio = frame.length > 3 && frame[3] == FrameType.audio.code;
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
        } else if (_peripheralPeers.containsKey(id)) {
          notify = true;
        }
      }
    }
    final futures = <Future<void>>[];
    for (final link in targets) {
      if (isAudio && link.inflight >= maxInflightAudio) {
        _dropped++; // link is behind: drop rather than add latency
        continue;
      }
      futures.add(_writeLink(link, frame));
    }
    if (notify && _peripheralUp) {
      if (isAudio && _peripheralInflight >= maxInflightAudio) {
        _dropped++;
      } else {
        futures.add(_notifyAll(frame));
      }
    }
    await Future.wait(futures);
  }

  Future<void> _writeLink(_CentralLink link, Uint8List frame) async {
    link.inflight++;
    try {
      for (final chunk in link.fragmenter.split(frame)) {
        await link.rx.write(chunk, withoutResponse: true);
      }
    } catch (_) {
    } finally {
      link.inflight--;
    }
  }

  Future<void> _notifyAll(Uint8List frame) async {
    _peripheralInflight++;
    try {
      for (final chunk in _peripheralFragmenter.split(frame)) {
        // Throws when nobody is subscribed; that is fine.
        await _peripheral.sendData(chunk, characteristicUuid: txUuid);
      }
    } catch (_) {
    } finally {
      _peripheralInflight--;
    }
  }

  Future<void> _tearDown() async {
    _watchdog?.cancel();
    _watchdog = null;
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
  final Set<int> peerIds = {};
  DateTime lastRx = DateTime.now();
  int inflight = 0;
}
