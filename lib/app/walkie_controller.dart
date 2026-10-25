import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio/audio_engine.dart';
import '../core/peer.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
import '../transports/ble_transport.dart';
import '../transports/lan_transport.dart';
import '../transports/mdns_discovery.dart';
import '../transports/relay_transport.dart';
import 'config.dart';
import 'settings.dart';

/// Glue between UI, [TransportManager] and [AudioEngine].
class WalkieController extends ChangeNotifier {
  WalkieController({
    required this.settings,
    this.settingsStore = const SharedPrefsSettingsStore(),
  }) : nodeId = settings.nodeId,
       _relay = RelayTransport(serverUri: _relayUri(settings)) {
    name = settings.name;
    manager = TransportManager(
      transports: [
        LanTransport(
          discoveries: [MdnsLanDiscovery()],
          platform: Platform.isAndroid
              ? const AndroidLanPlatform()
              : const LanPlatform(),
          store: const SharedPrefsLanPeerStore(),
        ),
        BleTransport(),
        _relay,
      ],
      localNodeId: nodeId,
      localName: name,
      channel: settings.channel,
    );
  }

  /// Loads the saved id/name/channel/relay (creating a stable id on first
  /// launch) and builds the controller.
  static Future<WalkieController> load({
    SettingsStore store = const SharedPrefsSettingsStore(),
  }) async {
    final s = await store.load(defaultChannel: AppConfig.defaultChannel);
    return WalkieController(settings: s, settingsStore: store);
  }

  static Uri? _relayUri(AppSettings s) {
    final url = (s.relayUrl ?? AppConfig.relayUrl).trim();
    return url.isEmpty ? null : Uri.tryParse(url);
  }

  final AppSettings settings;
  final SettingsStore settingsStore;
  final int nodeId;
  late String name;
  late final TransportManager manager;
  final RelayTransport _relay;
  final AudioEngine _audio = AudioEngine();
  final List<StreamSubscription<dynamic>> _subs = [];

  List<Peer> peers = const [];
  bool transmitting = false;
  String? error;
  bool started = false;

  int get channel => manager.channel;
  Uri? get relayUri => _relay.serverUri;
  List<Transport> get transports => manager.transports;
  int get playbackDropped => _audio.playbackDropped;
  int? get talkingPeer {
    for (final p in peers) {
      if (p.talking && p.channel == channel) return p.id;
    }
    return null;
  }

  Future<void> start() async {
    if (started) return;
    started = true;
    await _requestPermissions();
    try {
      await _audio.init();
    } catch (e) {
      error = 'Audio init failed: $e';
    }
    _subs.add(
      manager.peerChanges.listen((list) {
        for (final p in list) {
          if (!p.talking) _audio.peerStopped(p.id);
        }
        peers = list;
        notifyListeners();
      }),
    );
    _subs.add(manager.transportChanges.listen((_) => notifyListeners()));
    _subs.add(
      manager.audio.listen((a) {
        if (!transmitting) _audio.play(a.peerId, a.seq, a.opus);
      }),
    );
    await manager.start();
    notifyListeners();
  }

  Future<void> _requestPermissions() async {
    final perms = <Permission>[Permission.microphone];
    if (Platform.isAndroid) {
      perms.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse, // needed for BLE scan on Android <= 11
        Permission.nearbyWifiDevices,
      ]);
    } else if (Platform.isIOS) {
      perms.add(Permission.bluetooth);
    }
    try {
      await perms.request();
    } catch (_) {}
  }

  Future<void> pushToTalk(bool down) async {
    if (down == transmitting) return;
    transmitting = down;
    notifyListeners();
    try {
      if (down) {
        await manager.setTalking(true);
        await _audio.startTransmit(manager.sendAudio);
      } else {
        await _audio.stopTransmit(manager.sendAudio);
        await manager.setTalking(false);
      }
    } catch (e) {
      error = 'Mic error: $e';
      transmitting = false;
      notifyListeners();
    }
  }

  Future<void> setChannel(int ch) async {
    await manager.setChannel(ch);
    settings.channel = ch;
    unawaited(settingsStore.save(settings));
    notifyListeners();
  }

  /// Empty resets to the default name derived from the stable id.
  void setName(String n) {
    final t = n.trim();
    settings.customName = t.isEmpty ? null : t;
    name = settings.name;
    manager.localName = name;
    manager.sendHello();
    unawaited(settingsStore.save(settings));
    notifyListeners();
  }

  Future<void> setRelayUrl(String url) async {
    final uri = url.trim().isEmpty ? null : Uri.tryParse(url.trim());
    settings.relayUrl = url.trim();
    unawaited(settingsStore.save(settings));
    await _relay.setServerUri(uri);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    manager.dispose();
    _audio.dispose();
    super.dispose();
  }
}
