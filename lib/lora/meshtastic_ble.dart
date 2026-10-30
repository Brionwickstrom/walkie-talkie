import 'dart:async';
import 'dart:io' show Platform, SocketException;
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../platform/platform_caps.dart';
import '../transports/ble_scan_lock.dart';
import 'lora_transport.dart';
import 'meshtastic_proto.dart';
import 'meshtastic_session.dart';
import 'stream_radio.dart';

/// Connection state of the paired LoRa radio.
enum RadioState {
  /// No radio paired.
  none,

  /// Bluetooth is off / not allowed.
  bluetoothOff,
  connecting,

  /// Waiting for the Bluetooth pairing (PIN) prompt.
  pairing,

  /// Downloading the radio's node list and settings.
  configuring,
  ready,

  /// Lost; trying again every few seconds.
  reconnecting,
}

/// A Meshtastic radio found by [MeshtasticRadio.scan].
class FoundRadio {
  FoundRadio(this.id, this.name, this.rssi);
  final String id;
  final String name;
  final int rssi;

  /// USB serial or Wi-Fi (TCP) radio (desktop app), not Bluetooth.
  bool get isStream => StreamRadioId.isStream(id);
}

class _BleWire implements MeshtasticWire {
  _BleWire(this.toRadio, this.fromRadio, this.fromNum);
  final fbp.BluetoothCharacteristic toRadio;
  final fbp.BluetoothCharacteristic fromRadio;
  final fbp.BluetoothCharacteristic fromNum;

  @override
  Future<void> write(Uint8List b) =>
      toRadio.write(b, withoutResponse: false, allowLongWrite: true);

  @override
  Future<Uint8List> read() async => Uint8List.fromList(await fromRadio.read());

  @override
  Stream<void> get notifications => fromNum.onValueReceived.map((_) {});
}

/// The phone's link to one Meshtastic radio over Bluetooth LE (official
/// client API, see [MeshtasticSession]), with pairing and auto-reconnect.
///
/// Runs next to the app's own BLE phone transport: both use
/// flutter_blue_plus, the radio is a separate GATT connection, the pairing
/// scan holds [BleScanLock] and asks for both service UUIDs so phones are
/// still found, and the phone transport ignores Meshtastic devices.
class MeshtasticRadio implements RadioLink {
  MeshtasticRadio({this.license = fbp.License.nonprofit});

  final fbp.License license;

  String? deviceId;
  String? deviceName;
  RadioState state = RadioState.none;
  String? detail;
  MeshtasticSession? session;

  final _changes = StreamController<void>.broadcast();
  final _packets = StreamController<MeshPacketPb>.broadcast();
  final _ready = StreamController<bool>.broadcast();
  final List<StreamSubscription<dynamic>> _linkSubs = [];
  fbp.BluetoothDevice? _device;

  /// USB / Wi-Fi link (desktop app, v1.9.6) while connected.
  StreamRadioConnection? _stream;

  /// The saved radio is on USB serial or Wi-Fi (TCP), not Bluetooth.
  bool get isStream => StreamRadioId.isStream(deviceId);

  /// Tests: open a USB / Wi-Fi radio link.
  Future<StreamRadioConnection> Function(String id) openStream =
      openStreamRadio;

  /// Tests: list USB radios.
  List<String> Function() usbRadios = usbRadioIds;
  bool _wanted = false;
  bool _looping = false;
  Completer<void>? _lost;
  int _failures = 0;

  /// Called with the radio's Bluetooth id when it changes (null = none),
  /// so the phone transport can ignore it.
  void Function(String? id)? onDevice;

  Stream<void> get changes => _changes.stream;

  @override
  bool get ready => state == RadioState.ready;
  @override
  Stream<bool> get readyChanges => _ready.stream;
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;
  @override
  int? get queueFree => session?.queueFree;

  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
    int hopLimit = 0,
  }) async {
    final s = session;
    if (s == null || !ready) throw StateError('radio not ready');
    await s.send(
      payload,
      to: to,
      wantAck: wantAck,
      priority: priority,
      channel: channel,
      hopLimitOverride: hopLimit,
    );
  }

  void _set(RadioState s, [String? d]) {
    final wasReady = ready;
    state = s;
    detail = d;
    if (!_changes.isClosed) _changes.add(null);
    if (wasReady != ready && !_ready.isClosed) _ready.add(ready);
  }

  /// Look for Meshtastic radios nearby for [timeout].
  Future<List<FoundRadio>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (PlatformCaps.streamRadios) {
      // Desktop: radios plugged in over USB (Wi-Fi radios are typed in).
      return [
        for (final id in usbRadios())
          FoundRadio(id, StreamRadioId.label(id), 0),
      ];
    }
    if (fbp.FlutterBluePlus.adapterStateNow != fbp.BluetoothAdapterState.on) {
      throw StateError('Turn Bluetooth on first.');
    }
    final found = <String, FoundRadio>{};
    final mesh = fbp.Guid(MeshtasticUuids.service);
    final sub = fbp.FlutterBluePlus.onScanResults.listen((rs) {
      for (final r in rs) {
        if (!r.advertisementData.serviceUuids.contains(mesh)) continue;
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        found[r.device.remoteId.str] = FoundRadio(
          r.device.remoteId.str,
          name.isEmpty ? r.device.remoteId.str : name,
          r.rssi,
        );
      }
    });
    BleScanLock.hold(timeout + const Duration(seconds: 2));
    try {
      if (fbp.FlutterBluePlus.isScanningNow) {
        await fbp.FlutterBluePlus.stopScan();
      }
      await fbp.FlutterBluePlus.startScan(
        // Our phone service too, so the phone transport keeps finding
        // phones during the scan.
        withServices: [mesh, fbp.Guid('a7e1c0de-5741-4c4b-9e1e-77616c6b6965')],
        timeout: timeout,
      );
      await fbp.FlutterBluePlus.isScanning
          .where((s) => !s)
          .first
          .timeout(
            timeout + const Duration(seconds: 3),
            onTimeout: () => false,
          );
    } finally {
      await sub.cancel();
      BleScanLock.release();
    }
    final list = found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  /// Use [id] from now on (pairs on first connect) and keep it connected.
  Future<void> use(String id, String name) async {
    if (deviceId != id) await _disconnect();
    deviceId = id;
    deviceName = name;
    onDevice?.call(id);
    start();
  }

  /// Keep the saved radio connected (no-op without one).
  void start() {
    if (deviceId == null) {
      _set(RadioState.none);
      return;
    }
    _wanted = true;
    if (!_looping) unawaited(_loop());
  }

  /// Disconnect and forget the radio (also drops the Android bond).
  Future<void> forget() async {
    final d = _device;
    _wanted = false;
    await _disconnect();
    if (d != null && Platform.isAndroid) {
      try {
        await d.removeBond();
      } catch (_) {}
    }
    deviceId = null;
    deviceName = null;
    onDevice?.call(null);
    _set(RadioState.none);
  }

  Future<void> stop() async {
    _wanted = false;
    await _disconnect();
    _set(deviceId == null ? RadioState.none : RadioState.reconnecting, null);
  }

  Future<void> _loop() async {
    _looping = true;
    try {
      while (_wanted && deviceId != null) {
        if (!isStream &&
            fbp.FlutterBluePlus.adapterStateNow !=
                fbp.BluetoothAdapterState.on) {
          _set(RadioState.bluetoothOff, 'Bluetooth is off');
          await fbp.FlutterBluePlus.adapterState
              .where((s) => s == fbp.BluetoothAdapterState.on)
              .first
              .timeout(
                const Duration(seconds: 30),
                onTimeout: () => fbp.BluetoothAdapterState.off,
              );
          continue;
        }
        try {
          await _connectOnce(deviceId!);
          _failures = 0;
          // Stay here until the link drops.
          _lost = Completer<void>();
          await _lost!.future;
        } catch (e) {
          _failures++;
          await _disconnect();
          if (!_wanted) break;
          _set(RadioState.reconnecting, _explain(e));
        }
        if (!_wanted) break;
        final wait = Duration(
          seconds: switch (_failures) {
            0 => 2,
            1 => 5,
            2 => 10,
            3 => 20,
            _ => 30,
          },
        );
        await Future<void>.delayed(wait);
      }
    } finally {
      _looping = false;
    }
  }

  String _explain(Object e) {
    final s = e.toString();
    if (isStream) {
      if (e is StateError && e.message.isNotEmpty) return e.message;
      if (e is SocketException) {
        return 'No answer from the radio on Wi-Fi: check the address and that '
            'its Wi-Fi is on (Meshtastic: Network > WiFi enabled)';
      }
      if (e is TimeoutException) return 'No answer from the radio';
      return 'Not connected: $s';
    }
    if (s.contains('bond') || s.contains('Bond') || s.contains('auth')) {
      return 'Pairing failed: check the PIN and try again';
    }
    if (s.contains('service missing')) {
      return 'That device is not a Meshtastic radio';
    }
    return 'Not in range or turned off';
  }

  Future<void> _connectOnce(String id) async {
    if (StreamRadioId.isStream(id)) return _connectStream(id);
    _set(RadioState.connecting);
    final dev = fbp.BluetoothDevice.fromId(id);
    _device = dev;
    await dev.connect(
      license: license,
      timeout: const Duration(seconds: 15),
      mtu: Platform.isAndroid ? 512 : null,
    );
    _linkSubs.add(
      dev.connectionState.listen((s) {
        if (s == fbp.BluetoothConnectionState.disconnected) {
          unawaited(_onLost());
        }
      }),
    );
    if (Platform.isAndroid) {
      try {
        final bond = await dev.bondState.first.timeout(
          const Duration(seconds: 2),
        );
        if (bond != fbp.BluetoothBondState.bonded) {
          // The system asks for the radio's PIN (123456 on screenless
          // radios such as the T1000-E, shown on the screen otherwise).
          _set(RadioState.pairing);
          await dev.createBond(timeout: 90);
        }
      } catch (_) {
        // "No PIN" radios bond silently or not at all; reading below
        // triggers the system prompt if the radio insists.
      }
    }
    final services = await dev.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid == fbp.Guid(MeshtasticUuids.service),
      orElse: () => throw StateError('service missing'),
    );
    fbp.BluetoothCharacteristic? find(String u) {
      for (final c in svc.characteristics) {
        if (c.uuid == fbp.Guid(u)) return c;
      }
      return null;
    }

    final toRadio = find(MeshtasticUuids.toRadio);
    final fromRadio =
        find(MeshtasticUuids.fromRadio) ??
        find(MeshtasticUuids.fromRadioLegacy);
    final fromNum = find(MeshtasticUuids.fromNum);
    if (toRadio == null || fromRadio == null || fromNum == null) {
      throw StateError('service missing');
    }
    await fromNum.setNotifyValue(true);
    _set(RadioState.configuring);
    final s = MeshtasticSession(_BleWire(toRadio, fromRadio, fromNum));
    session = s;
    _linkSubs.add(
      s.packets.listen((p) {
        if (!_packets.isClosed) _packets.add(p);
      }),
    );
    _linkSubs.add(
      s.changes.listen((_) {
        if (!_changes.isClosed) _changes.add(null);
      }),
    );
    await s.start();
    final me = s.nodes[s.myNodeNum];
    final n = me?.longName ?? '';
    if (n.isNotEmpty) deviceName = n;
    _set(RadioState.ready);
  }

  /// USB serial / Wi-Fi radio: same session as Bluetooth over the stream
  /// framing ([StreamWire]); the link ends when the wire does.
  Future<void> _connectStream(String id) async {
    _set(RadioState.connecting, StreamRadioId.label(id));
    final conn = await openStream(id);
    _stream = conn;
    _set(RadioState.configuring);
    final s = MeshtasticSession(conn.wire);
    session = s;
    _linkSubs.add(
      s.packets.listen((p) {
        if (!_packets.isClosed) _packets.add(p);
      }),
    );
    _linkSubs.add(
      s.changes.listen((_) {
        if (!_changes.isClosed) _changes.add(null);
      }),
    );
    unawaited(
      conn.wire.done.then((_) {
        if (identical(_stream, conn)) unawaited(_onLost());
      }),
    );
    await s.start(timeout: const Duration(seconds: 30));
    if (s.myNodeNum == null) throw StateError('No answer from the radio');
    final me = s.nodes[s.myNodeNum];
    final n = me?.longName ?? '';
    if (n.isNotEmpty) deviceName = n;
    _set(RadioState.ready);
  }

  Future<void> _onLost() async {
    final wasUp = session != null;
    await _teardown();
    if (wasUp && _wanted) _set(RadioState.reconnecting, 'Connection lost');
    final l = _lost;
    if (l != null && !l.isCompleted) l.complete();
  }

  Future<void> _teardown() async {
    for (final s in _linkSubs) {
      await s.cancel();
    }
    _linkSubs.clear();
    final s = session;
    session = null;
    await s?.close();
    final st = _stream;
    _stream = null;
    if (st != null) {
      try {
        await st.close();
      } catch (_) {}
    }
    if (ready) _set(RadioState.reconnecting);
  }

  Future<void> _disconnect() async {
    final d = _device;
    await _teardown();
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    final l = _lost;
    if (l != null && !l.isCompleted) l.complete();
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
    await _packets.close();
    await _ready.close();
  }
}
