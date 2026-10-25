import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

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

/// Glue between UI, [TransportManager] and [AudioEngine].
class WalkieController extends ChangeNotifier {
  WalkieController()
      : nodeId = Random.secure().nextInt(0xFFFFFFFF),
        _relay = RelayTransport(
            serverUri: AppConfig.relayUrl.isEmpty
                ? null
                : Uri.tryParse(AppConfig.relayUrl)) {
    name = 'Phone ${nodeId.toRadixString(16).substring(0, 4).toUpperCase()}';
    manager = TransportManager(
      transports: [
        LanTransport(discoveries: [MdnsLanDiscovery()]),
        BleTransport(),
        _relay,
      ],
      localNodeId: nodeId,
      localName: name,
      channel: AppConfig.defaultChannel,
    );
  }

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
    _subs.add(manager.peerChanges.listen((list) {
      for (final p in list) {
        if (!p.talking) _audio.peerStopped(p.id);
      }
      peers = list;
      notifyListeners();
    }));
    _subs.add(manager.transportChanges.listen((_) => notifyListeners()));
    _subs.add(manager.audio.listen((a) {
      if (!transmitting) _audio.play(a.peerId, a.seq, a.opus);
    }));
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
    notifyListeners();
  }

  void setName(String n) {
    name = n.trim().isEmpty ? name : n.trim();
    manager.localName = name;
    manager.sendHello();
    notifyListeners();
  }

  Future<void> setRelayUrl(String url) async {
    final uri = url.trim().isEmpty ? null : Uri.tryParse(url.trim());
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
