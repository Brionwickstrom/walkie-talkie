import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, exit;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:permission_handler/permission_handler.dart';

import '../audio/audio_engine.dart';
import 'link_settings.dart';
import 'link_settings.dart' as link_settings;

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import 'conn_probes.dart';
import 'connection_test.dart';
import 'debug_log.dart';
import 'invite.dart';
import 'mesh_links.dart';
import 'setup.dart';
import 'people_refresh.dart';
import 'power_plan.dart';
import '../audio/codec.dart';
import '../audio/codec2_ffi.dart';
import '../audio/opus_voice_codec.dart';
import '../audio/live_gate.dart';
import '../chat/chat_body.dart';
import '../chat/chat_store.dart';
import '../chat/photo.dart';
import '../core/link_policy.dart';
import '../core/channel_crypto.dart';
import '../core/frame.dart';
import '../core/gateway_protocol.dart' show GatewayInfo;
import '../core/listeners.dart';
import '../core/lobby.dart';
import '../core/pair_key.dart';
import '../core/peer.dart';
import '../core/peer_box.dart';
import '../core/rekey.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
import '../friends/friend_links.dart';
import '../friends/friend_messenger_link.dart';
import '../friends/friend_ring_link.dart';
import '../history/talk_history.dart';
import '../lora/lora_transport.dart';
import '../lora/meshtastic_ble.dart';
import '../lora/meshtastic_admin.dart';
import '../lora/meshtastic_channels.dart';
import '../lora/radio_clip.dart';
import '../messaging/inbox.dart';
import '../messaging/messenger.dart';
import '../messaging/outbox.dart';
import '../messaging/ringer.dart';
import '../messaging/storage.dart';
import '../messaging/voice_clip.dart';
import '../platform/background_bridge.dart';
import '../platform/platform_caps.dart';
import '../transports/ble_transport.dart';
import '../transports/lan_transport.dart';
import '../transports/mdns_discovery.dart';
import '../transports/direct_links.dart';
import '../transports/relay_socket.dart';
import '../transports/relay_transport.dart';
import '../transports/wifi_direct_transport.dart';
import '../trip/geo.dart';
import '../trip/sos.dart';
import '../trip/trip_controller.dart';
import '../trip/trip_route.dart';
import 'call_signs.dart';
import 'config.dart';
import 'passcodes.dart';
import 'playback_log.dart';
import 'private_reply.dart';
import 'quiet.dart';
import 'settings.dart';
import 'whos_where.dart';

/// A friend request waiting for an answer.
class FriendRequest {
  FriendRequest({
    required this.from,
    required this.name,
    required this.id,
    required this.publicKey,
    required this.at,
  });
  final int from;
  final String name;
  final int id;
  final String publicKey;
  final DateTime at;
}

class _LiveShare {
  _LiveShare(this.liveId, this.until);
  final int liveId;
  final DateTime until;
  Timer? timer;
  int? lastMsgId;
  ({double lat, double lng, double? acc})? last;
}

/// Voice message being recorded.
class Recording {
  Recording(this.toPeer, this.startedAt, {this.toFriend = false});
  final int? toPeer;

  /// [toPeer] is a friend: send privately (any channel, end-to-end).
  final bool toFriend;
  final DateTime startedAt;
  final List<Uint8List> packets = [];
}

/// Glue between UI, [TransportManager], [AudioEngine], voice messages,
/// rings and the Android background service.
class WalkieController extends ChangeNotifier {
  WalkieController({
    required this.settings,
    this.settingsStore = const SharedPrefsSettingsStore(),
    ChannelKey? channelKey,
  }) : nodeId = settings.nodeId,
       _relay = MultiRelayTransport(
         serverUris: relayUrisFor(settings),
         connector: RelayConnector.platform(),
         // v1.8.9: direct phone-to-phone links, signaled via the relays.
         direct: DirectLinks(),
         // v1.9.4: room rosters for the "Unknown listener" warning.
         roster: true,
       ) {
    name = settings.name;
    final wd = Platform.isAndroid
        ? (WifiDirectTransport()..enabled = settings.wifiDirect)
        : null;
    _wifiDirect = wd;
    // v1.9.6: no Bluetooth phone links in the desktop app.
    final ble = PlatformCaps.bluetooth ? BleTransport() : null;
    radioDevice.deviceId = settings.radioId;
    radioDevice.deviceName = settings.radioName;
    if (settings.radioId != null) ble?.ignoreDevices.add(settings.radioId!);
    radioDevice.onDevice = (id) {
      ble?.ignoreDevices.clear();
      if (id != null) ble?.ignoreDevices.add(id);
    };
    manager = TransportManager(
      transports: [
        LanTransport(
          discoveries: [MdnsLanDiscovery()],
          platform: Platform.isAndroid
              ? const AndroidLanPlatform()
              : const LanPlatform(),
          store: const SharedPrefsLanPeerStore(),
        ),
        ?wd,
        ?ble,
        _relay,
        loraTransport,
      ],
      localNodeId: nodeId,
      localName: name,
      channel: settings.channel,
      channelKey: channelKey,
    );
    manager.relayForOthers = settings.relayForOthers;
    manager.shareRadio = settings.shareRadio;
    // v1.9.7: open Walkie channels linked to a Meshtastic channel go out
    // on that channel's slot of the paired radio (looked up by name +
    // hash on whichever radio is paired).
    loraTransport.meshLinkFor = meshLinkForFrame;
    loraTransport.meshIndexOf = (ref) => radioDevice.session?.indexOf(ref);
    manager.meshLinkFor = meshLinkForFrame;
    // Only form a Wi-Fi Direct group with phones we cannot already reach
    // over a shared Wi-Fi / hotspot.
    wd?.sharedNetworkWith = (id) {
      final p = manager.peer(id);
      if (p == null) return false;
      return manager.usableLinks(p, DateTime.now()).contains(TransportKind.lan);
    };
    if (channelKey != null) {
      _keys['${channelKey.channel}\u0000${settings.passcodeFor(channelKey.channel)}'] =
          channelKey;
    }
    ringer = Ringer(
      link: FriendAwareRingLink(
        ManagerRingLink(manager),
        () => friendLinks,
        friendScope,
      ),
    );
    manager.helloExtras = _helloExtras;
    manager.blocked.addAll(settings.blocked.keys);
    final relays = relayUrisFor(settings);
    friendLinks = FriendLinks(
      localId: nodeId,
      radio: ManagerFriendRadio(manager),
      far: ManagerFriendFarPaths(manager),
      localName: () => name,
      // v1.8.8: friend rooms on every relay too (home + backup), so two
      // friends meet even when only one of them can reach the home relay.
      relayFactory: relays.isEmpty
          ? null
          : (room) => MultiRelayTransport(
              serverUris: relays,
              factory: (u) => RelayTransport(
                serverUri: u,
                connector: RelayConnector.platform(),
                room: room,
              ),
            ),
    );
    friendLinks.setFriends(settings.friends);
    manager.sealedHandler = friendLinks.handle;
    whosWhere = WhosWhere(
      localId: nodeId,
      sendLocal: manager.sendLobbyLocal,
      sendRadio: manager.sendLobbyRadio,
      beacon: _lobbyBeacon,
      relayFactory: _lobbyRelayFactory(relays),
      plan: powerPlan,
    );
    whosWhere.replyPresence = _replyPresence;
    whosWhere.addListener(notifyListeners);
    debugLog.secrets = () => settings.privateChannels.values;
    _relay.onRoleChange = _logRelayRole;
    _relay.direct!
      ..attach(manager)
      ..onEvent = (l) => debugLog.add('direct', l);
    _wrapDirectSignals();
    unawaited(
      PeerBox.create().then((b) {
        peerBox ??= b;
      }),
    );
    peopleRefresh = PeopleRefresh(
      probe: _probeEveryone,
      probeRadio: _probeRadio,
      changes: whosWhere,
    );
  }

  // ------------------------------------------------ pull-to-refresh (v1.8.5)

  /// Pull-to-refresh on the people list and Who's where.
  late final PeopleRefresh peopleRefresh;
  int _probeNonce = Random().nextInt(0x10000);
  int _probeSeq = 0;

  Uint8List _probeBytes({bool radio = false}) {
    _probeNonce = (_probeNonce + 1) & 0xFFFF;
    _probeSeq = (_probeSeq + 1) & 0xFFFF;
    return LobbyProbe(
      nonce: _probeNonce,
      radio: radio,
    ).encode(senderId: nodeId, seq: _probeSeq);
  }

  /// "Who's here?" on every fast path: local links (+ sweep, Wi-Fi Direct
  /// discovery, Bluetooth scan burst), the mesh, the relay channel room
  /// and the relay lobby room (reconnecting it when down). Offline power
  /// save: no relay.
  Future<void> _probeEveryone() async {
    final bytes = _probeBytes();
    await manager.probePeople(bytes);
    await whosWhere.probeRelay(bytes);
  }

  bool _probeRadio() => manager.sendProbeRadio(_probeBytes(radio: true));

  /// Someone else refreshed: say we are here right now.
  Future<void> _replyPresence({required bool radio}) =>
      radio ? manager.sendRadioHello() : manager.sendHello();

  // ------------------------------------- setup, connection test, invites,
  // ------------------------------------- debug log (v1.8.7)

  /// Rolling connection log ("Send debug log").
  final DebugLog debugLog = DebugLog();

  /// What to show at start for setup (wizard / one-time prompt / none).
  SetupEntry get setupEntry => setupEntryFor(
    newInstall: settings.newInstall,
    setupDone: settings.setupDone,
    promptShown: settings.setupPromptShown,
  );

  /// The wizard asks for permissions itself: [start] must not.
  bool permissionsBySetup = false;

  Future<void> markSetupDone() async {
    if (settings.setupDone) return;
    settings.setupDone = true;
    settings.setupPromptShown = true;
    // The wizard covered the battery question.
    settings.batteryPromptShown = true;
    await settingsStore.save(settings);
    debugLog.add('setup', 'setup finished / skipped');
  }

  Future<void> markSetupPromptShown() async {
    settings.setupPromptShown = true;
    await settingsStore.save(settings);
  }

  static PermState _permState(PermissionStatus s) {
    if (s.isGranted || s.isLimited || s.isProvisional) return PermState.granted;
    if (s.isPermanentlyDenied) return PermState.permanentlyDenied;
    return PermState.denied;
  }

  int? _sdk;

  /// Android SDK level (0 elsewhere / unknown -> treated as newest).
  Future<int> androidSdk() async {
    if (_sdk != null) return _sdk!;
    if (!Platform.isAndroid) return _sdk = 0;
    final d = await bridge.deviceInfo();
    final v = d?['sdk'];
    return _sdk = v is int ? v : 0;
  }

  /// Runtime permissions behind [p] on this phone. Android 11 and older
  /// have no "Nearby devices" (Bluetooth scanning uses location there);
  /// Wi-Fi Direct's NEARBY_WIFI_DEVICES exists from Android 13.
  static List<Permission> _permsFor(AppPermission p, int sdk) {
    final android = Platform.isAndroid;
    final newest = sdk == 0;
    return switch (p) {
      AppPermission.microphone => [Permission.microphone],
      AppPermission.nearby =>
        android
            ? [
                if (newest || sdk >= 31) ...[
                  Permission.bluetoothScan,
                  Permission.bluetoothConnect,
                  Permission.bluetoothAdvertise,
                ],
                if (newest || sdk >= 33) Permission.nearbyWifiDevices,
              ]
            : [Permission.bluetooth],
      AppPermission.location =>
        android ? [Permission.locationWhenInUse] : const [],
      AppPermission.notifications => [Permission.notification],
    };
  }

  /// Each permission group: the worst of its parts.
  Future<Map<AppPermission, PermState>> permissionStates() async {
    final out = <AppPermission, PermState>{};
    if (!Platform.isAndroid && !Platform.isIOS) return out;
    final sdk = await androidSdk();
    for (final p in AppPermission.values) {
      final perms = _permsFor(p, sdk);
      if (perms.isEmpty) {
        out[p] = PermState.notNeeded;
        continue;
      }
      var worst = PermState.granted;
      for (final x in perms) {
        try {
          final st = _permState(await x.status);
          if (st == PermState.permanentlyDenied) {
            worst = st;
          } else if (st == PermState.denied && worst == PermState.granted) {
            worst = st;
          }
        } catch (_) {}
      }
      out[p] = worst;
    }
    return out;
  }

  /// Ask for [p]; "don't ask again" opens App info. Links that were down
  /// for lack of it start again. True when granted.
  Future<bool> requestAppPermission(AppPermission p) async {
    final perms = _permsFor(p, await androidSdk());
    if (perms.isEmpty) return true;
    var ok = false;
    try {
      final r = await perms.request();
      ok = r.values.every((s) => _permState(s) == PermState.granted);
      if (!ok && r.values.any((s) => s.isPermanentlyDenied)) {
        await openPhoneSettings(PhoneSetting.appInfo);
      }
    } catch (_) {}
    debugLog.add('perm', '${p.name}: ${ok ? 'granted' : 'not granted'}');
    if (ok && p == AppPermission.nearby) await restartDownLinks();
    return ok;
  }

  /// Ask for every missing permission at once (setup wizard).
  Future<void> requestAllPermissions() async {
    await _requestPermissions(force: true);
    debugLog.add('perm', 'asked for all permissions');
    await restartDownLinks();
  }

  /// Bluetooth / Wi-Fi Direct that are down (e.g. permission was missing)
  /// start again.
  Future<void> restartDownLinks() async {
    if (!started) return;
    for (final t in manager.transports) {
      if (t.kind != TransportKind.ble && t.kind != TransportKind.wifiDirect) {
        continue;
      }
      if (t.status == TransportStatus.running ||
          t.status == TransportStatus.starting) {
        continue;
      }
      try {
        await t.stop();
        await t.start(localNodeId: nodeId, channel: scope);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Bluetooth adapter on (null: unknown / unsupported).
  Future<bool?> bluetoothOn() async {
    if (!PlatformCaps.bluetooth) return null;
    try {
      if (!await fbp.FlutterBluePlus.isSupported) return null;
      final s = fbp.FlutterBluePlus.adapterStateNow;
      if (s == fbp.BluetoothAdapterState.on) return true;
      if (s == fbp.BluetoothAdapterState.off) return false;
    } catch (_) {}
    return null;
  }

  Transport? _transport(TransportKind k) {
    for (final t in manager.transports) {
      if (t.kind == k) return t;
    }
    return null;
  }

  /// The connection test: active probes + current link states.
  bool connectionTestRunning = false;

  Future<List<CheckRow>> runConnectionTest({
    Future<NetProbe> Function()? internetProbe,
    Future<RelayProbe> Function(Uri server)? relayProbe,
  }) async {
    connectionTestRunning = true;
    notifyListeners();
    try {
      if (bridge.supported) await refreshPhoneNet();
      final offline = settings.offlineSaver;
      final relays = relayUrisFor(settings);
      NetProbe? net;
      RelayProbe? relay;
      var relayProbes = const <RelayProbe>[];
      final natCheck = offline
          ? Future<NatInfo?>.value()
          : (_relay.direct?.probeNat() ?? Future<NatInfo?>.value());
      if (!offline) {
        // v1.8.8: every relay (home + backup), in parallel.
        final results = await Future.wait<Object?>([
          (internetProbe ?? probeInternet)(),
          for (var i = 0; i < relays.length; i++)
            (relayProbe ??
                    (u) => probeRelay(
                      server: u,
                      channelScope: scope,
                      connector: RelayConnector.platform(),
                      connectTimeout: i == 0 && relays.length > 1
                          ? const Duration(seconds: 10)
                          : const Duration(seconds: 45),
                    ))(relays[i])
                .then(
                  (p) => p.withLabel(
                    MultiRelayTransport.labelAt(i, relays.length),
                  ),
                ),
        ]);
        net = results[0] as NetProbe;
        relayProbes = [for (final r in results.skip(1)) r as RelayProbe];
        if (relayProbes.isNotEmpty) relay = relayProbes.first;
      }
      final lan = _transport(TransportKind.lan);
      final wd = _transport(TransportKind.wifiDirect);
      final ble = _transport(TransportKind.ble);
      final snap = ConnSnapshot(
        offlineSaver: offline,
        ios: Platform.isIOS,
        phoneNet: phoneNet,
        lan: lan?.status,
        lanDetail: lan?.statusDetail,
        wifiDirect: wd?.status,
        wifiDirectDetail: wd?.statusDetail,
        wifiDirectEnabled: settings.wifiDirect,
        ble: ble?.status,
        bleDetail: ble?.statusDetail,
        bluetoothOn: await bluetoothOn(),
        bluetoothPermissionMissing: await bluetoothPermissionMissing(),
        cell: cellStatus,
        cellInfo: cellInfo,
        internet: net,
        relayConfigured: relays.isNotEmpty,
        relayLink: _relay.status,
        relayLinkDetail: internetStatus.text,
        relay: relay,
        relayProbes: relayProbes,
        relayInUse: relayInUse,
        direct: _relay.direct == null
            ? null
            : DirectCheck(
                nat: await natCheck,
                up: directPeers.length,
                paths: [
                  for (final id in directPeers) ?_relay.direct!.pathOf(id),
                ],
              ),
        radioPaired: radioPaired,
        radioReady: radioDevice.ready,
        radioDetail: radioDevice.deviceName ?? radioDevice.detail,
        permissions: await permissionStates(),
        batteryExempt: bridge.supported
            ? await bridge.ignoringBatteryOptimizations()
            : null,
        stayReachable: settings.stayReachable,
        serviceRunning: bridge.supported ? await bridge.serviceRunning() : null,
        manufacturer: bridge.supported ? await bridge.manufacturer() : '',
      );
      final rows = evaluateConnection(snap);
      lastConnectionTest = rows;
      for (final r in rows) {
        debugLog.add('test', '$r');
      }
      return rows;
    } finally {
      connectionTestRunning = false;
      notifyListeners();
    }
  }

  List<CheckRow>? lastConnectionTest;

  /// Battery optimization exemption (the system "Allow" dialog).
  Future<void> requestBatteryExemption() async {
    debugLog.add('battery', 'asked to ignore battery optimizations');
    await bridge.requestIgnoreBatteryOptimizations();
  }

  /// The phone maker's own screen, else App info.
  Future<void> openVendorBattery() async {
    if (!await bridge.openVendorBattery()) {
      await openPhoneSettings(PhoneSetting.appInfo);
    }
  }

  // invites

  /// Invite for the current channel (public or private) and / or a friend
  /// add (valid for [friendValid]).
  Invite makeInvite({
    bool channel = true,
    bool friend = false,
    Duration friendValid = const Duration(hours: 1),
  }) => Invite(
    channel: channel ? this.channel : null,
    passcode: channel ? settings.passcodeFor(this.channel) : null,
    name: name,
    friendCode: friend ? friendQrText(validFor: friendValid) : null,
  );

  /// Apply a confirmed invite. Returns a short summary for a snackbar.
  Future<String> applyInvite(
    Invite inv, {
    bool joinChannel = true,
    bool addFriend = true,
  }) async {
    final done = <String>[];
    if (joinChannel && inv.channel != null) {
      final ch = inv.channel!;
      if (inv.isPrivate) {
        settings.privateChannels[ch] = ChannelKey.normalize(inv.passcode!);
        await settingsStore.save(settings);
      } else if (settings.isPrivate(ch)) {
        // The invite is for the public channel with that number.
        settings.privateChannels.remove(ch);
        await settingsStore.save(settings);
      }
      await setChannel(ch);
      done.add('joined CH $ch${inv.isPrivate ? ' (private group)' : ''}');
    }
    if (addFriend && inv.friendCode != null) {
      final err = await addFriendFromQr(inv.friendCode!);
      done.add(err ?? 'friend added');
    }
    debugLog.add('invite', done.join(', '));
    return done.isEmpty ? 'Nothing to do' : done.join(', ');
  }

  // debug log

  /// v1.8.8: which relay is in use, into the debug log when it changes.
  String? _lastRelayLabel;

  void _logRelayRole(RelayRole? from, RelayRole? to) {
    final n = _relay.relays.length;
    String label(RelayRole r) => MultiRelayTransport.labelFor(r, count: n);
    final host = _relay.active?.serverUri?.host;
    final now = _relay.activeLabel;
    final prev = _lastRelayLabel;
    _lastRelayLabel = now;
    debugLog.add(
      'relay',
      to == null
          ? 'no relay connected${prev != null
                ? ' (was $prev)'
                : from != null
                ? ' (was ${label(from)})'
                : ''}'
          : 'using ${now ?? label(to)}${host != null ? ' ($host)' : ''}'
                '${prev != null
                    ? ', was $prev'
                    : from != null
                    ? ', was ${label(from)}'
                    : ''}',
    );
  }

  Future<void> _attachDebugLog() async {
    debugLog.secrets = () => settings.privateChannels.values;
    try {
      final base = await bridge.filesDir();
      final root = base != null
          ? Directory(base)
          : await getApplicationSupportDirectory();
      await debugLog.attach(Directory('${root.path}/logs'));
    } catch (_) {}
    debugLog.add('app', 'started, $channelLabel');
  }

  final Map<TransportKind, String> _lastLinkLog = {};

  void _logLinks() {
    for (final t in manager.transports) {
      final line =
          '${t.status.name}${t.statusDetail != null ? ' (${t.statusDetail})' : ''}';
      if (_lastLinkLog[t.kind] == line) continue;
      _lastLinkLog[t.kind] = line;
      debugLog.add(t.kind.name, line);
    }
  }

  /// Header lines of the debug report.
  Future<List<String>> debugHeader() async {
    String version = '?';
    try {
      final i = await PackageInfo.fromPlatform();
      version = '${i.version}+${i.buildNumber}';
    } catch (_) {}
    final d = await bridge.deviceInfo();
    final device = d == null
        ? Platform.operatingSystem
        : '${d['manufacturer']} ${d['model']}, Android ${d['release']} '
              '(SDK ${d['sdk']})';
    return [
      'Walkie Talkie debug log',
      'Created: ${DateTime.now().toIso8601String()}',
      'App version: $version',
      'Device: $device',
      'Phone id: ${nodeId.toRadixString(16)}',
      'Channel: $channelLabel',
      'Offline power save: ${settings.offlineSaver}, battery saver: '
          '${settings.powerSaver}, stay reachable: ${settings.stayReachable}',
      'Phone network: ${phoneNet ?? '?'}, cell: ${cellStatus.name}'
          '${cellInfo != null ? ' (${cellLabel(cellInfo!)})' : ''}',
      internetStatus.text,
      'Relay: ${[for (final r in _relay.relays) '${_relay.labelOf(r)} ${r.serverUri?.host} ${r.status.name}${r.lastError != null && r.status != TransportStatus.running ? ' (${r.lastError})' : ''}'].join(', ')}',
      'Relay in use: ${relayInUse ?? 'none'}',
      'Fastest path: ${connectionSummary.text} · ${settings.connectionSpeed.name}, '
          '${manager.activity.name}, check every ${manager.probeInterval.inSeconds} s · '
          'switches ${manager.degradedEvents}, resent ${manager.resent}, '
          'urgent ${manager.urgentSends}, network changes ${manager.networkChanges}',
      'Direct links: ${_relay.direct?.debugInfo ?? 'off'}'
          '${directPeers.isNotEmpty ? ' (${directPeers.map((id) => id.toRadixString(16)).join(', ')})' : ''}',
      for (final t in manager.transports)
        'Link ${t.kind.name}: ${t.status.name}'
            '${t.statusDetail != null ? ' (${t.statusDetail})' : ''}',
      'People here: ${peers.length}, Who\'s where: '
          '$whosWhereElsewhereCount elsewhere',
      'Radio: ${radioPaired ? (radioDevice.ready ? 'connected' : 'paired, not connected') : 'none'}',
      if (lastConnectionTest != null) ...[
        'Last connection test:',
        for (final r in lastConnectionTest!) '  $r',
      ],
    ];
  }

  Future<String> debugReport() async => debugLog.report(await debugHeader());

  /// Write the report to a file and open the share sheet.
  Future<bool> shareDebugLog() async {
    final text = await debugReport();
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}/exports');
      await dir.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(':', '-');
      final f = File('${dir.path}/walkie-debug-$stamp.txt');
      await f.writeAsString(text);
      return await bridge.shareFile(
        f.path,
        mime: 'text/plain',
        title: 'Walkie Talkie debug log',
      );
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------- connection settings (v1.8.5)

  /// The phone's network: "wifi", "cell", "other", "none" (null = unknown).
  String? phoneNet;

  Future<void> refreshPhoneNet() async {
    final n = await bridge.netKind();
    final cell = CellInfo.fromMap(await bridge.cellInfo());
    if (n == phoneNet && cell == cellInfo) return;
    if (n != phoneNet) debugLog.add('net', 'phone network: ${n ?? '?'}');
    phoneNet = n;
    cellInfo = cell;
    final cs = cellStatus.name;
    if (cs != _lastCellLog) {
      _lastCellLog = cs;
      debugLog.add(
        'cell',
        '$cs${cell != null ? ' (${cellLabel(cell)}, data ${cell.dataUp ? 'up' : 'down'}'
                  '${cell.airplane ? ', airplane' : ''}${cell.dataSaver ? ', data saver' : ''})' : ''}',
      );
    }
    notifyListeners();
  }

  String? _lastCellLog;

  /// The phone's cellular side (v1.8.6), null when unknown (iOS).
  CellInfo? cellInfo;

  /// Why nobody shows up over the internet (v1.8.7).
  AloneReason get aloneReason {
    final net = internetStatus;
    String? detail;
    for (final r in _relay.relays) {
      detail ??= r.statusDetail;
    }
    return link_settings.aloneReason(
      offlineSaver: settings.offlineSaver,
      hasRelay: _relay.relays.isNotEmpty,
      internet: net.status,
      internetDetail: net.status == TransportStatus.running ? null : detail,
      cell: cellStatus,
      channelLabel: labelFor(scope),
      isPrivate: isPrivate,
    );
  }

  /// The Cell icon (v1.8.6).
  CellState get cellStatus {
    final up = _relay.relays
        .where((r) => r.status == TransportStatus.running)
        .toList();
    return cellState(
      info: cellInfo,
      relayUp: up.isNotEmpty,
      relayNet: up.isEmpty ? null : up.first.network,
      phoneNet: phoneNet,
      hasRelay: _relay.relays.isNotEmpty,
      offlineSaver: settings.offlineSaver,
    );
  }

  /// "Allow mobile data" next to the internet status.
  bool get mobileDataHint => showMobileDataHint(
    internet: internetStatus.status,
    netKind: phoneNet,
    hasRelay: _relay.relays.isNotEmpty,
    offlineSaver: settings.offlineSaver,
  );

  /// Bluetooth permission ("Nearby devices") not granted.
  Future<bool> bluetoothPermissionMissing() async {
    try {
      if (Platform.isAndroid) {
        final sdk = await androidSdk();
        // Android 11 and older: no "Nearby devices" permission.
        if (sdk != 0 && sdk < 31) return false;
        return !await Permission.bluetoothScan.isGranted ||
            !await Permission.bluetoothConnect.isGranted;
      }
      if (Platform.isIOS) return !await Permission.bluetooth.isGranted;
    } catch (_) {}
    return false;
  }

  /// Ask for the Bluetooth permission; true when granted. Permanently
  /// denied: opens App info instead.
  Future<bool> requestBluetoothPermission() async {
    try {
      final perms = Platform.isAndroid
          ? [Permission.bluetoothScan, Permission.bluetoothConnect]
          : [Permission.bluetooth];
      final r = await perms.request();
      if (r.values.every((s) => s.isGranted)) return true;
      if (r.values.any((s) => s.isPermanentlyDenied)) {
        await openPhoneSettings(PhoneSetting.appInfo);
      }
    } catch (_) {}
    return false;
  }

  /// Open a phone settings screen (Android); elsewhere this app's settings.
  Future<void> openPhoneSettings(PhoneSetting s) async {
    if (s == PhoneSetting.radioPairing) return; // in-app screen (UI)
    if (bridge.supported) {
      await bridge.openSystemSettings(s.wire);
      return;
    }
    try {
      await openAppSettings();
    } catch (_) {}
  }

  /// A LoRa radio is connected (the "Also ask over radio" option).
  bool get radioConnected => manager.radio?.status == TransportStatus.running;

  /// Pull-to-refresh: the people on our channel ([whosWhere] false) or
  /// everyone in Who's where.
  Future<RefreshResult> refreshPeople({
    bool radio = false,
    bool whosWhere = false,
  }) => peopleRefresh.refresh(
    radio: radio,
    count: whosWhere
        ? () => whosWhereTotal(whosWhereGroups)
        : () => peers.length,
  );

  /// Who's where (v1.8.2): lobby beacons in / out.
  late final WhosWhere whosWhere;

  /// The relay lobby room on every configured relay (null = none).
  static Transport Function()? _lobbyRelayFactory(List<Uri> relays) =>
      relays.isEmpty
      ? null
      : () => MultiRelayTransport(
          serverUris: relays,
          factory: (u) => RelayTransport(
            serverUri: u,
            connector: RelayConnector.platform(),
            room: LobbyBeacon.relayRoom,
          ),
        );

  /// Our lobby beacon, or null with "Show me in Who's where" off. On a
  /// private channel only the call sign (never a custom name or anything
  /// about the channel).
  LobbyBeacon? _lobbyBeacon(Duration every) {
    if (!settings.showInWhosWhere) return null;
    if (isPrivate) {
      return LobbyBeacon.private(
        callSign: settings.defaultName,
        every: every,
        battery: batteryPct,
      );
    }
    final n = channelName;
    return LobbyBeacon.public(
      name: name,
      channel: channel,
      every: every,
      channelName: n?.name,
      channelEmoji: n?.emoji,
      battery: batteryPct,
    );
  }

  /// This phone's battery 0..100 (null = unknown), shared in hellos, the
  /// radio presence hello, check-ins and lobby beacons (v1.8.3).
  int? batteryPct;

  Future<void> _refreshBattery() async {
    final b = await bridge.batteryLevel();
    if (b == null || b.pct == batteryPct) return;
    batteryPct = b.pct;
    notifyListeners();
  }

  /// Someone's last known battery: their hellos, else their latest
  /// check-in, else their lobby beacon.
  int? batteryOf(int id) {
    final p = manager.peer(id)?.battery;
    if (p != null) return p;
    final t = trip?.batteries[id]?.pct;
    if (t != null) return t;
    for (final e in whosWhere.entries) {
      if (e.id == id) return e.beacon.battery;
    }
    return null;
  }

  /// Everyone this phone can see, grouped by channel (Who's where).
  List<WhoGroup> get whosWhereGroups {
    final now = DateTime.now();
    final n = channelName;
    return buildWhosWhere(
      myId: nodeId,
      myName: name,
      myChannel: channel,
      myScope: scope,
      iAmPrivate: isPrivate,
      myChannelName: n?.name,
      myChannelEmoji: n?.emoji,
      seen: [
        for (final p in peers)
          WhoSeen(
            id: p.id,
            name: p.displayName,
            scope: p.channel,
            links: manager.liveLinksOf(p, now).toSet(),
            hops: p.meshHops,
            lastHeard: _lastHeard(p, now),
            talking: p.talking,
            info: p.info,
            feature: p.feature,
            battery: batteryOf(p.id),
          ),
      ],
      lobby: whosWhere.entries,
      friends: {for (final f in friends) f.id: f.name},
      onlineFriends: {
        for (final f in friends)
          if (friendOnline(f.id)) f.id,
      },
      knownNames: {
        for (final e in settings.channelNames.entries)
          if (!TransportManager.isPrivateScope(e.key) && !e.value.isEmpty)
            e.key: (name: e.value.name, emoji: e.value.emoji),
      },
      now: now,
    );
  }

  static Duration? _lastHeard(Peer p, DateTime now) {
    DateTime? last;
    for (final t in [...p.lastSeen.values, ?p.meshSeen]) {
      if (last == null || t.isAfter(last)) last = t;
    }
    return last == null ? null : now.difference(last);
  }

  /// People on other channels (badge on the Talk screen).
  int get whosWhereElsewhereCount => whosWhereElsewhere(whosWhereGroups);

  /// Settings > "Show me in Who's where".
  Future<void> setReadReceipts(bool on) async {
    settings.readReceipts = on;
    notifyListeners();
    await settingsStore.save(settings);
  }

  Future<void> setShowInWhosWhere(bool on) async {
    settings.showInWhosWhere = on;
    notifyListeners();
    await settingsStore.save(settings);
    await manager.sendHello();
    if (on) whosWhere.announceSoon();
  }

  /// Loads the saved id/name/channel/relay (creating a stable id on first
  /// launch) and builds the controller.
  static Future<WalkieController> load({
    SettingsStore store = const SharedPrefsSettingsStore(),
  }) async {
    final s = await store.load(defaultChannel: AppConfig.defaultChannel);
    final pass = s.passcodeFor(s.channel);
    ChannelKey? key;
    if (pass != null) {
      try {
        key = await ChannelKey.derive(s.channel, pass);
      } catch (_) {}
    }
    return WalkieController(settings: s, settingsStore: store, channelKey: key);
  }

  /// Ordered relay list: the saved override (comma separated, "off" =
  /// none), or the app default when nothing / an empty string is saved.
  ///
  /// v1.8.8: a saved value that is just an old built-in default (the
  /// Render relay alone) counts as "default", so those phones get the home
  /// relay too. Any other custom list is used exactly as typed.
  static List<Uri> relayUrisFor(AppSettings s) {
    final saved = s.relayUrl?.trim() ?? '';
    final isLegacy =
        saved.isNotEmpty &&
        AppConfig.legacyDefaults.any(
          (d) => _sameUris(
            MultiRelayTransport.parseList(saved),
            MultiRelayTransport.parseList(d),
          ),
        );
    return MultiRelayTransport.parseList(
      saved.isEmpty || isLegacy ? AppConfig.relayUrl : saved,
    );
  }

  static bool _sameUris(List<Uri> a, List<Uri> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  /// How long an incoming ring rings before it counts as missed.
  static const ringDuration = Duration(seconds: 15);

  /// Urgent rings repeat until answered, up to this long.
  static const urgentRingDuration = Duration(seconds: 60);

  final AppSettings settings;
  final SettingsStore settingsStore;
  final int nodeId;
  late String name;
  late final TransportManager manager;
  late final Ringer ringer;
  Messenger? messenger;

  /// Trip tab (map, SOS, check-ins, pins, trails, base camp, weather);
  /// null until [start] has set it up.
  TripController? trip;
  final MultiRelayTransport _relay;
  WifiDirectTransport? _wifiDirect;

  /// Paired Meshtastic LoRa radio (v1.7.0) and the transport using it.
  final MeshtasticRadio radioDevice = MeshtasticRadio();
  late final LoraTransport loraTransport = LoraTransport(radio: radioDevice);

  /// Codec 2 (native), null when the library is missing: then voice
  /// messages do not go over the radio (texts, locations and rings do).
  final Codec2Lib? _codec2 = Codec2Lib.load();
  bool get radioVoiceSupported => _codec2 != null;
  RadioClipCodec? get _radioCodec {
    final lib = _codec2;
    return lib == null ? null : RadioClipCodec(() => Codec2FrameCodec(lib));
  }

  /// Android only; null on iPhone.
  bool get wifiDirectSupported => _wifiDirect != null;
  final AudioEngine _audio = AudioEngine();
  final BackgroundBridge bridge = BackgroundBridge();
  final List<StreamSubscription<dynamic>> _subs = [];
  final List<Timer> _timers = [];
  AppLifecycleListener? _lifecycle;
  int _micOrphanTicks = 0;

  /// Big talk button: reply privately for 30 s after a friend's private
  /// talk / voice message (see [PrivateReply]).
  final privateReply = PrivateReply();
  late final _mainTalk = MainTalkRouter(
    reply: privateReply,
    talkPrivate: (id, down) async {
      await talkToFriend(id, down);
      return !down || privateTalkTo == id;
    },
    talkChannel: pushToTalk,
    privateTalkTo: () => privateTalkTo,
  );

  /// The big talk button (and talk keys): private reply or channel.
  Future<void> mainTalk(bool down) => _mainTalk.talk(down);

  /// Friend the big button replies to right now (null = the channel).
  int? get replyTarget {
    // Still talking privately from the big button after the window ran out.
    final p = privateTalkTo;
    if (transmitting && p != null && p == privateReply.lastId) return p;
    final t = privateReply.target;
    return t != null && friendLinks.isFriend(t) ? t : null;
  }

  void talkToChannelInstead() {
    privateReply.dismiss();
    notifyListeners();
  }

  /// People on this channel who hear the big button (not counting you).
  int get channelListeners => peers.where((p) => p.channel == scope).length;

  /// Which live audio may play (see [LiveAudioGate]).
  final liveGate = LiveAudioGate();

  /// What triggered each playback (Settings > Details).
  final playbackLog = PlaybackLog();
  DateTime? _lastLiveAt;
  bool _liveShown = false;

  /// Something played in the last 2 s (talk keys are ignored then).
  bool get _playedRecently {
    if (playingKey != null || playingTake != null || _audio.playingClip) {
      return true;
    }
    final t = _lastLiveAt;
    return t != null &&
        DateTime.now().difference(t) < const Duration(seconds: 2);
  }

  /// Live talk played in the last second (the Stop banner shows).
  bool get liveActive {
    final t = _lastLiveAt;
    return t != null &&
        DateTime.now().difference(t) < const Duration(milliseconds: 1000);
  }

  List<Peer> peers = const [];

  // ------------------------------------------- private security (v1.9.4)

  /// This phone's one-to-one key (made at app start, announced as `kx`).
  PeerBox? peerBox;

  /// Unknown listeners from the relays' room rosters.
  final ListenerWatch listenerWatch = ListenerWatch();

  /// Sockets in this channel's relay room that never showed up (relay
  /// 1.4.0+). Shown as "Unknown listener" on private channels.
  int hiddenListeners = 0;

  /// The relays send rosters (relay 1.4.0+), so [hiddenListeners] means
  /// something.
  bool get listenerCheckOn => listenerWatch.supported(DateTime.now());

  /// No join alerts until then (just switched channel / started: everyone
  /// already there would "join").
  DateTime _joinQuietUntil = DateTime.now();
  final Map<int, DateTime> _joinAlerted = {};

  /// The last join alert ("Bob joined CH 3"), for the UI.
  ({String text, DateTime at})? lastJoinAlert;

  bool transmitting = false;
  String? error;
  bool started = false;
  bool _starting = false;

  /// App on screen (not just running in the background).
  bool foreground = false;
  bool _wasVisible = false;

  /// Rings currently ringing on this phone.
  final List<IncomingRing> activeRings = [];
  final Map<(int, int), Timer> _ringTimers = {};

  Recording? recording;
  Timer? _recordLimit;

  /// Inbox key of the message playing now.
  String? playingKey;

  /// Replay missed talk (see [TalkHistory]).
  TalkHistory? history;

  /// Transmission being replayed now, and where it is (ms).
  TalkTake? playingTake;
  int playingPosMs = 0;

  /// 1, 1.5 or 2.
  double playbackSpeed = 1;

  /// "Play all missed" is running.
  bool playingAll = false;
  final Map<int, int> _resumeAt = {};
  int _replayToken = 0;
  DateTime _lastPosNotify = DateTime(0);

  /// Talking started by a tap (toggle mode / headset / notification):
  /// stops on the next tap, or after [toggleTalkLimit].
  bool talkLatched = false;
  static const toggleTalkLimit = Duration(minutes: 2);
  Timer? _talkLimit;

  Set<int> _talkingPrev = {};
  String _serviceText = '';
  bool serviceRunning = false;

  final _notices = StreamController<String>.broadcast();
  final _uiRequests = StreamController<String>.broadcast();

  /// Short messages for a snackbar ("Delivered to Bandit").
  Stream<String> get notices => _notices.stream;

  /// Navigation requests from notifications: 'inbox'.
  Stream<String> get uiRequests => _uiRequests.stream;

  int get channel => manager.channel;

  /// Channel number, or a private-channel scope; see [TransportManager.scope].
  int get scope => manager.scope;

  /// Current channel is private (encrypted, passcode protected).
  bool get isPrivate => manager.isPrivate;

  /// e.g. "CH 3" or "CH 3 (private group)".
  String get channelLabel =>
      'CH $channel${isPrivate ? ' (private group)' : ''}';

  /// Label for a scope stored with a ring / message.
  String labelFor(int scope) {
    if (scope == friendScope) return 'Direct chat';
    if (!TransportManager.isPrivateScope(scope)) return 'CH $scope';
    return scope == this.scope ? channelLabel : 'a private group';
  }

  /// Channel number to show / switch to for [scope] (private scopes are
  /// only ever the current channel).
  int displayChannel(int scope) =>
      TransportManager.isPrivateScope(scope) ? channel : scope;

  /// True while a passcode key is being derived (takes ~1 s).
  bool switchingChannel = false;
  final Map<String, ChannelKey> _keys = {};
  int _channelToken = 0;
  List<Uri> get relayUris => _relay.serverUris;

  /// One line for the UI: "Internet: connected via mobile data", ...
  ({TransportStatus status, String text}) get internetStatus => _relay.summary;

  /// "Home relay" / "Backup relay" in use (null = none connected).
  String? get relayInUse => _relay.activeLabel;

  /// Phones reached over a direct internet link right now (v1.8.9).
  Set<int> get directPeers => _relay.direct?.upPeers ?? const {};

  /// "Direct" when [p] is reached over a direct internet link.
  String? pathOf(Peer p) => manager.pathOf(p);

  /// What the Settings field shows: the saved override, or empty (= default).
  String get relayOverride => settings.relayUrl?.trim() ?? '';
  List<Transport> get transports => manager.transports;
  int get playbackDropped => _audio.playbackDropped;
  List<InboxEntry> get inbox {
    final a = messenger?.inbox.entries ?? const <InboxEntry>[];
    final b = friendMessenger?.inbox.entries ?? const <InboxEntry>[];
    if (b.isEmpty) return a;
    return [...a, ...b]..sort((x, y) => y.receivedAt.compareTo(x.receivedAt));
  }

  int get unplayedMessages =>
      (messenger?.inbox.unplayed ?? 0) + (friendMessenger?.inbox.unplayed ?? 0);
  List<OutgoingStatus> get outgoing => [
    ...?messenger?.outgoing,
    ...?friendMessenger?.outgoing,
  ];
  List<OutboxEntry> get waitingForAnyone =>
      messenger?.waitingForAnyone ?? const [];

  Messenger? _messengerFor(InboxEntry e) =>
      e.channel == friendScope ? friendMessenger : messenger;

  int? get talkingPeer {
    for (final p in peers) {
      if (p.talking && p.channel == scope) return p.id;
    }
    return null;
  }

  String nameOf(int peerId) =>
      manager.peer(peerId)?.displayName ??
      friendLinks.friend(peerId)?.name ??
      callSignFor(peerId);

  Future<void> start() async {
    if (started || _starting) return;
    _starting = true;
    try {
      await _start();
      started = true;
    } finally {
      _starting = false;
    }
  }

  Future<void> _start() async {
    await _attachDebugLog();
    await bridge.init();
    _subs.add(bridge.actions.listen(_onAction));
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    final st = WidgetsBinding.instance.lifecycleState;
    foreground = st == AppLifecycleState.resumed;
    _wasVisible = foreground;

    await _requestPermissions();
    _audio.setVolumes(settings.peerVolumes);
    try {
      await _audio.init();
    } catch (e) {
      error = 'Audio init failed: $e';
    }
    _subs.add(manager.peerChanges.listen(_onPeers));
    _subs.add(_relay.rosters.listen(_onRoster));
    _joinQuietUntil = DateTime.now().add(const Duration(seconds: 8));
    _subs.add(
      manager.transportChanges.listen((_) {
        _logLinks();
        notifyListeners();
      }),
    );
    _subs.add(
      manager.audio.listen((a) {
        final live = !transmitting && recording == null;
        final who = '${nameOf(a.peerId)} #${a.peerId}';
        final via = a.transport?.name ?? '?';
        final talking = manager.peer(a.peerId)?.talking ?? false;
        final why = liveGate.admit(a.peerId, a.opus, talking: talking);
        if (why != null) {
          // A mic left on (older app), a repeat, or stopped by the user:
          // not played and not kept for "Missed" either.
          playbackLog.stream(
            'ch${a.peerId}',
            'live-blocked',
            '$who via $via: $why',
          );
          return;
        }
        final auto = settings.autoPlay;
        history?.addPacket(
          scope: scope,
          sender: a.peerId,
          name: nameOf(a.peerId),
          opus: a.opus,
          heard: live && foreground && auto && !silenced,
          hops: a.hops,
        );
        if (!live) return;
        if (silenced) {
          playbackLog.stream(
            'ch${a.peerId}',
            'live-held',
            '$who: ${quietStatus ?? 'muted'}, saved in Missed',
          );
          return;
        }
        if (!auto) {
          playbackLog.stream(
            'ch${a.peerId}',
            'live-held',
            '$who: auto-play off, saved in Missed',
          );
          return;
        }
        if (isMuted(a.peerId)) return;
        if (announcementMode && a.peerId != adminId) return;
        playbackLog.stream(
          'ch${a.peerId}',
          'live',
          '$who via $via${talking ? '' : ' (talk end / start pending)'}',
        );
        final wasLive = liveActive;
        _lastLiveAt = DateTime.now();
        if (!wasLive) notifyListeners();
        if (_audio.playingClip) {
          _stopReplay();
          _audio.stopClip();
          playingKey = null;
        }
        _audio.play(a.peerId, a.seq, a.opus);
      }),
    );
    await manager.setPowerSaver(settings.powerSaver);
    await manager.setOfflineSaver(settings.offlineSaver);
    // v1.9.8: connection speed plan and network-change reconnects.
    manager.setSpeed(settings.connectionSpeed);
    // v2.0.0: idle (background, nothing for a minute) slows friend
    // presence; busy again restores it at once.
    manager.onIdleChanged = (idle) => friendLinks.setIdle(idle);
    manager.setActivity(
      foreground ? ProbeActivity.foreground : ProbeActivity.idle,
    );
    await manager.start();
    _subs.add(
      networkChanges.listen((net) {
        if (settings.offlineSaver) return;
        debugLog.add('net', 'network changed ($net): reconnecting now');
        unawaited(manager.onNetworkChanged());
      }),
    );
    _subs.add(manager.lobby.listen(whosWhere.onLobby));
    _subs.add(manager.probes.listen(whosWhere.onProbe));
    await whosWhere.setForeground(foreground);
    await whosWhere.setPlan(powerPlan);
    unawaited(whosWhere.start());
    _timers.add(
      Timer.periodic(const Duration(seconds: 1), (_) => whosWhere.tick()),
    );
    if (bridge.supported) {
      unawaited(refreshPhoneNet());
      // v2.0.0: every 5 s on screen, every 30 s in the background (it
      // only feeds the status text; the network callback handles changes).
      var netTicks = 0;
      _timers.add(
        Timer.periodic(const Duration(seconds: 5), (_) {
          if (!foreground && ++netTicks % 6 != 0) return;
          unawaited(refreshPhoneNet());
        }),
      );
    }
    _subs.add(radioDevice.changes.listen((_) => notifyListeners()));
    radioDevice.start();
    _subs.add(
      manager.controls.listen((c) {
        switch (c.message.kind) {
          case ControlKind.friendReq:
          case ControlKind.friendAcc:
          case ControlKind.friendDec:
            unawaited(_onFriendControl(c));
          case ControlKind.rekey:
          case ControlKind.rekeyAck:
            unawaited(_onRekey(c));
          default:
        }
      }),
    );

    // Friends: presence, private talk.
    friendLinks.setPowerSaver(settings.powerSaver);
    friendLinks.setOfflineSaver(settings.offlineSaver);
    friendLinks.start();
    _subs.add(friendLinks.changes.listen((_) => notifyListeners()));
    _subs.add(friendLinks.inbound.listen(_onFriendFrame));
    _subs.add(friendLinks.paired.listen((e) => unawaited(_onPaired(e))));

    // Chats.
    try {
      final c = ChatStore(
        FileMessageStorage(
          Directory('${(await _messageDir()).parent.path}/chat'),
        ),
      );
      await c.load();
      chats = c;
      _subs.add(c.changes.listen((_) => notifyListeners()));
    } catch (_) {}

    // Replay missed talk.
    try {
      final h = TalkHistory(
        storage: FileMessageStorage(
          Directory('${(await _messageDir()).parent.path}/history'),
        ),
      );
      await h.load();
      history = h;
      _subs.add(h.changes.listen((_) => notifyListeners()));
      _timers.add(Timer.periodic(const Duration(seconds: 1), (_) => h.tick()));
      unawaited(_refreshBattery());
      _timers.add(
        Timer.periodic(
          const Duration(minutes: 2),
          (_) => unawaited(_refreshBattery()),
        ),
      );
    } catch (_) {}

    // Voice messages.
    try {
      final m = Messenger(
        link: ManagerMessengerLink(manager),
        storage: FileMessageStorage(await _messageDir()),
      );
      m.radioClipToVoice = _radioClipToVoice;
      await m.start();
      messenger = m;
      _wireMessenger(m, friend: false);
    } catch (e) {
      error = 'Voice messages unavailable: $e';
    }
    try {
      final m = Messenger(
        link: FriendMessengerLink(friendLinks, friendScope),
        storage: FileMessageStorage(
          Directory('${(await _messageDir()).parent.path}/friendmsg'),
        ),
      );
      // Friend voice messages over the radio arrive as Codec 2 (v1.8.3).
      m.radioClipToVoice = _radioClipToVoice;
      await m.start();
      friendMessenger = m;
      _wireMessenger(m, friend: true);
    } catch (_) {}
    await _migrate152();

    // Rings / beeps.
    ringer.start();
    _subs.add(ringer.incoming.listen(_onIncomingRing));
    _subs.add(ringer.changes.listen((_) => notifyListeners()));
    _timers.add(
      Timer.periodic(const Duration(milliseconds: 500), (_) => ringer.tick()),
    );
    _timers.add(
      Timer.periodic(const Duration(seconds: 5), (_) {
        _updateServiceText();
        // Quiet hours start / end, a timed mute runs out.
        final q = quietStatus;
        if (q != _lastQuietStatus) {
          _lastQuietStatus = q;
          debugLog.add('quiet', q ?? 'sound back on');
          notifyListeners();
        }
      }),
    );
    // Safety net: the mic must never stay on while we are not talking or
    // recording (see MicGate for the v1.5.0 bug this guards against).
    _timers.add(
      Timer.periodic(const Duration(seconds: 1), (_) {
        if (_liveShown != liveActive) {
          _liveShown = liveActive;
          notifyListeners();
        }
        if (_audio.isTransmitting && !transmitting && recording == null) {
          if (++_micOrphanTicks >= 2) {
            _micOrphanTicks = 0;
            unawaited(_audio.forceStopTransmit());
          }
        } else {
          _micOrphanTicks = 0;
        }
      }),
    );

    // Trip tab.
    try {
      var ver = '1.8';
      try {
        ver = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
      final t = TripController(
        host: _WalkieTripHost(this),
        settings: settings.trip,
        dir: Directory('${(await _messageDir()).parent.path}/trip'),
        userAgent:
            'WalkieTalkie/$ver (+https://github.com/Brionwickstrom/walkie-talkie)',
      );
      t.battery = () => batteryPct;
      await t.start();
      await t.setOfflineSaver(settings.offlineSaver);
      trip = t;
    } catch (e) {
      debugPrint('trip: $e');
    }

    await applyBackgroundSettings();
    await _applyPttConfig();
    notifyListeners();
  }

  void _wireMessenger(Messenger m, {required bool friend}) {
    m.alreadyHaveChat = (s, id) => chats?.contains(s, id) ?? false;
    _subs.add(m.received.listen(_onVoiceMessage));
    _subs.add(
      m.read.listen((r) async {
        final (id, peer) = r;
        final store = chats;
        if (store != null && await store.markSeen(nodeId, id, peer)) return;
        // Not a chat: one of our voice messages was listened to.
        _notice(
          '${friend ? friendName(peer) : nameOf(peer)} listened to your '
          'voice message',
        );
      }),
    );
    _subs.add(m.chats.listen((a) => unawaited(_onChat(a, friend: friend))));
    _subs.add(
      m.delivered.listen((d) {
        if (d.$1.isChat) {
          unawaited(
            chats?.markDelivered(
              nodeId,
              d.$1.msgId,
              d.$2,
              viaRadio: m.deliveredOverRadio(d.$1.msgId, d.$2),
            ),
          );
        } else {
          _notice(
            'Voice message delivered to '
            '${friend ? friendName(d.$2) : nameOf(d.$2)}',
          );
        }
      }),
    );
    _subs.add(m.changes.listen((_) => notifyListeners()));
  }

  Future<Directory> _messageDir() async {
    final base = await bridge.filesDir();
    final root = base != null
        ? Directory(base)
        : await getApplicationSupportDirectory();
    return Directory('${root.path}/voice');
  }

  Future<void> _requestPermissions({bool force = false}) async {
    // First run: the setup wizard explains and asks (v1.8.7).
    if (permissionsBySetup && !force) return;
    final perms = <Permission>[Permission.microphone];
    if (Platform.isAndroid) {
      perms.addAll([
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse, // needed for BLE scan on Android <= 11
        Permission.nearbyWifiDevices,
        Permission.notification, // rings / voice messages (Android 13+)
      ]);
    } else if (Platform.isIOS) {
      perms.addAll([Permission.bluetooth, Permission.notification]);
    }
    try {
      final missing = <Permission>[];
      for (final p in perms) {
        if (!await p.isGranted) missing.add(p);
      }
      // Without an Activity (started after a reboot) this throws; the
      // permissions were granted earlier, so that is fine.
      if (missing.isNotEmpty) await missing.request();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- background

  /// Start / stop the "listening" foreground service to match settings.
  Future<void> applyBackgroundSettings() async {
    await bridge.setBootStart(settings.stayReachable && settings.startOnBoot);
    if (settings.stayReachable) {
      _serviceText = '';
      serviceRunning = await bridge.startService(
        title: _serviceTitle,
        text: _serviceBody,
        // Claim the mic while on screen so talking from the notification,
        // a headset or volume-down also works in the background.
        mic: foreground,
        talk: settings.notificationTalk,
        talking: transmitting,
      );
      _serviceText = '$_serviceTitle|$_serviceBody|$transmitting';
      if (!serviceRunning) {
        debugLog.add('service', 'listening service did not start');
      }
    } else {
      await bridge.stopService();
      serviceRunning = false;
    }
    notifyListeners();
  }

  String get _serviceTitle {
    final q = quietStatus;
    return q != null
        ? '\u{1F507} $q · $channelLabel'
        : 'Walkie Talkie is listening on $channelLabel';
  }

  String get _serviceBody {
    if (silenced) {
      return 'Talk, rings and voice messages are saved for later. '
          'Tap to open.';
    }
    final n = peers.length;
    return n == 0
        ? 'Rings and voice messages still come through. Tap to open.'
        : '$n ${n == 1 ? 'phone' : 'phones'} in range. Tap to open.';
  }

  void _updateServiceText() {
    if (!settings.stayReachable) return;
    final t = '$_serviceTitle|$_serviceBody|$transmitting';
    if (t == _serviceText) return;
    _serviceText = t;
    bridge.updateService(
      title: _serviceTitle,
      text: _serviceBody,
      talk: settings.notificationTalk,
      talking: transmitting,
    );
  }

  Future<void> setStayReachable(bool on) async {
    settings.stayReachable = on;
    await settingsStore.save(settings);
    await applyBackgroundSettings();
  }

  Future<void> setStartOnBoot(bool on) async {
    settings.startOnBoot = on;
    await settingsStore.save(settings);
    await bridge.setBootStart(settings.stayReachable && on);
    notifyListeners();
  }

  Future<void> markBatteryPromptShown() async {
    settings.batteryPromptShown = true;
    await settingsStore.save(settings);
  }

  void _onLifecycle(AppLifecycleState s) {
    final wasForeground = foreground;
    foreground = s == AppLifecycleState.resumed;
    if (foreground != wasForeground) {
      debugLog.add('app', foreground ? 'on screen' : 'background (${s.name})');
    }
    unawaited(whosWhere.setForeground(foreground));
    manager.setActivity(
      foreground ? ProbeActivity.foreground : ProbeActivity.idle,
    );
    // v2.0.0: the Trip tab's fast GPS and compass only run on screen.
    trip?.setAppForeground(foreground);
    if (foreground && !wasForeground && bridge.supported) {
      unawaited(refreshPhoneNet());
    }
    if (s != AppLifecycleState.detached) _wasVisible = true;
    if (foreground && !wasForeground) {
      for (final id in _talkingPrev) {
        bridge.cancelTalking(id);
      }
      if (settings.stayReachable) unawaited(applyBackgroundSettings());
      unawaited(_applyPttConfig());
      // v1.8.8: warm the relay before the next push-to-talk: reconnect
      // what is down (home first), ping what is up.
      if (!settings.offlineSaver) unawaited(_relay.wake());
    }
    if (s == AppLifecycleState.detached) {
      // App swiped away / closed: nothing may keep playing or talking.
      unawaited(stopAllAudio());
    }
    if (s == AppLifecycleState.detached &&
        _wasVisible &&
        !settings.stayReachable &&
        Platform.isAndroid) {
      // Closed with "stay reachable" off: stop everything like before.
      _shutdown();
    }
    notifyListeners();
  }

  Future<void> _shutdown() async {
    await bridge.stopService();
    try {
      await manager.stop();
    } catch (_) {}
    exit(0);
  }

  Future<void> _onAction(Map<String, Object?> a) async {
    int n(String k) => (a[k] as num?)?.toInt() ?? 0;
    switch (a['type']) {
      case 'stopAudio':
        await stopAllAudio();
      case 'stop':
        await stopAllAudio();
        serviceRunning = false;
        if (!foreground) {
          // Stop from the notification with the app closed: quit fully so
          // the phone really stops listening until the app is opened.
          await _shutdown();
        }
        _notice('Background listening is off until you reopen the app.');
        notifyListeners();
      case 'answer':
        final r = ringer.incomingById(n('from'), n('id'));
        if (r != null) {
          await answerRing(r);
        } else if (n('channel') > 0 &&
            n('channel') <= 0xFFFF &&
            n('channel') != channel) {
          await setChannel(n('channel'));
        }
      case 'dismiss':
        final r = ringer.incomingById(n('from'), n('id'));
        if (r != null) await dismissRing(r);
      case 'play':
        final key = a['key'] as String? ?? '';
        final e =
            messenger?.inbox.byKey(key) ?? friendMessenger?.inbox.byKey(key);
        if (e != null) await playMessage(e, trigger: 'notification');
      case 'openInbox':
        final k = a['key'] as String? ?? '';
        final fe = friendMessenger?.inbox.byKey(k);
        _uiRequests.add(fe != null ? 'friend:${fe.sender}' : 'inbox');
      case 'openFriend':
        final id = n('friend');
        if (friendLinks.isFriend(id)) _uiRequests.add('friend:$id');
      case 'hwKey':
        await onHardwareKey(a['src'] as String? ?? '', a['down'] == true);
      case 'loc':
        final lat = a['lat'], lng = a['lng'];
        if (lat is num && lng is num) {
          final t = (a['t'] as num?)?.toInt();
          trip?.onFix(
            Fix(
              GeoPoint(lat.toDouble(), lng.toDouble()),
              t == null || t <= 0
                  ? DateTime.now()
                  : DateTime.fromMillisecondsSinceEpoch(t),
              accuracyM: (a['acc'] as num?)?.toDouble(),
              speedMps: (a['spd'] as num?)?.toDouble(),
              altM: (a['alt'] as num?)?.toDouble(),
            ),
          );
        }
      case 'sosOpen':
        _uiRequests.add('sos');
      case 'joinLink':
        // walkietalkie://join?... opened (v1.8.7): confirm in the UI.
        final url = a['url'];
        if (url is String) _uiRequests.add('join:$url');
      case 'importFile':
        // A trail / map file opened with the app: import on the Trip tab.
        final path = a['path'] as String? ?? '';
        if (path.isNotEmpty && trip != null) {
          _uiRequests.add(
            'import:${jsonEncode({'path': path, 'name': a['name'] ?? ''})}',
          );
        }
      case 'importFailed':
        _notice(
          'Could not open ${a['name'] ?? 'the file'}: ${a['error'] ?? ''}',
        );
    }
  }

  // ------------------------------------------------------ hardware talk keys

  bool _hwStarted = false;
  DateTime? _hwDownAt;

  /// A hardware talk button: volume-down ('vol'), headset play/pause
  /// ('headset') or the notification's Talk button ('notif', taps only).
  /// Holding talks while held; a quick tap latches talking on (always for
  /// headsets and the notification, for volume-down only in toggle mode)
  /// and the next tap stops it.
  Future<void> onHardwareKey(String src, bool down) async {
    // Bluetooth devices / car kits send play-pause by themselves when audio
    // starts or stops; while (or right after) something plays, a talk key
    // must not start talking, or the mic would send the speaker back out.
    if (!transmitting && (down || src == 'notif') && _playedRecently) {
      playbackLog.add('hw-key-ignored', '$src: audio was playing');
      return;
    }
    if (src == 'notif') {
      await _hwTalk(!transmitting, latched: true);
      return;
    }
    if (down) {
      if (transmitting) {
        _hwStarted = false;
        await pushToTalk(false);
        return;
      }
      _hwStarted = true;
      _hwDownAt = DateTime.now();
      await _hwTalk(true, latched: false);
      return;
    }
    if (!_hwStarted) return;
    _hwStarted = false;
    final held =
        DateTime.now().difference(_hwDownAt ?? DateTime.now()) >=
        const Duration(milliseconds: 500);
    final tapLatches = src == 'headset' || settings.toggleTalk;
    if (held || !tapLatches) {
      await pushToTalk(false);
    } else {
      _latch();
    }
  }

  Future<void> _hwTalk(bool on, {required bool latched}) async {
    if (on && !foreground && !await bridge.micInBackground()) {
      await bridge.showInfo(
        nid: 77,
        title: 'Open Walkie Talkie once to talk from here',
        text:
            'Android only lets the app use the mic in the background after '
            'it was opened with "Stay reachable" on.',
      );
      return;
    }
    await mainTalk(on);
    if (on && latched) _latch();
  }

  void _latch() {
    if (!transmitting) return;
    talkLatched = true;
    _talkLimit?.cancel();
    _talkLimit = Timer(toggleTalkLimit, () {
      if (talkLatched) {
        pushToTalk(false);
        _notice('Stopped talking after 2 minutes.');
      }
    });
    notifyListeners();
  }

  /// Toggle mode: tap to start, tap to stop.
  Future<void> toggleTalk() async {
    if (transmitting) {
      await mainTalk(false);
    } else {
      await mainTalk(true);
      _latch();
    }
  }

  Future<void> _applyPttConfig() => bridge.setPttConfig(
    volume: settings.volumeKeyPtt,
    headset: settings.headsetPtt,
  );

  Future<void> setVolumeKeyPtt(bool on) async {
    settings.volumeKeyPtt = on;
    await _saveAndApplyPtt();
  }

  Future<void> setHeadsetPtt(bool on) async {
    settings.headsetPtt = on;
    await _saveAndApplyPtt();
  }

  Future<void> setAutoPlay(bool on) async {
    settings.autoPlay = on;
    if (!on) await stopAllAudio();
    playbackLog.add('setting', 'Auto-play incoming talk ${on ? 'on' : 'off'}');
    notifyListeners();
    await settingsStore.save(settings);
  }

  // ------------------------------------------------ mute / quiet hours

  QuietHours get quiet => settings.quiet;

  /// Mute or quiet hours: incoming talk is kept in Missed, rings, beeps,
  /// join tones and notification sounds stay quiet (v1.9.5).
  bool get silenced => quiet.silenced;
  String? _lastQuietStatus;

  /// "Muted", "Quiet hours until 7:00", or null.
  String? get quietStatus => quiet.statusText(quietClock);

  static String quietClock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} '
        '${t.hour < 12 ? 'AM' : 'PM'}';
  }

  /// Mute until turned off (v1.9.7: no time limit).
  Future<void> mute() async {
    quiet.mute();
    _lastQuietStatus = quietStatus;
    debugLog.add('quiet', _lastQuietStatus ?? 'muted');
    // Whatever live talk is still in the speaker stops now.
    unawaited(_audio.flushSpeaker().catchError((_) {}));
    notifyListeners();
    _updateServiceText();
    await settingsStore.save(settings);
  }

  Future<void> unmute() async {
    quiet.unmute();
    _lastQuietStatus = quietStatus;
    debugLog.add('quiet', 'unmuted');
    notifyListeners();
    _updateServiceText();
    await settingsStore.save(settings);
  }

  Future<void> saveQuietHours() async {
    _lastQuietStatus = quietStatus;
    notifyListeners();
    _updateServiceText();
    await settingsStore.save(settings);
  }

  Future<void> setLetUrgentThrough(bool on) async {
    quiet.letUrgentThrough = on;
    await saveQuietHours();
  }

  bool alwaysAllowed(int id) => quiet.alwaysAllow.contains(id);

  Future<void> setAlwaysAllow(int id, bool on) async {
    if (on) {
      quiet.alwaysAllow.add(id);
    } else {
      quiet.alwaysAllow.remove(id);
    }
    await saveQuietHours();
  }

  // ------------------------------------------------ LoRa gateways (v1.9.5)

  /// Gateways in this channel's relay room (Home gateway, phones sharing
  /// their radio).
  List<GatewayInfo> get gateways => manager.gateways;

  Future<void> setShareRadio(bool on) async {
    settings.shareRadio = on;
    manager.shareRadio = on;
    notifyListeners();
    await settingsStore.save(settings);
  }

  /// "Relay for others" (off-grid mesh).
  Future<void> setRelayForOthers(bool on) async {
    settings.relayForOthers = on;
    manager.relayForOthers = on;
    notifyListeners();
    await settingsStore.save(settings);
  }

  /// Base camp (Off-grid): this phone stays put as a relay and holds Trip
  /// messages for people who are out of range. Turns relaying on.
  Future<void> setBaseCamp(bool on) async {
    if (on && !settings.relayForOthers) await setRelayForOthers(true);
    await trip?.update((s) => s.baseCamp = on);
    if (trip == null) {
      settings.trip.baseCamp = on;
      await settingsStore.save(settings);
    }
    notifyListeners();
  }

  /// Wi-Fi Direct on/off (Android).
  Future<void> setWifiDirect(bool on) async {
    settings.wifiDirect = on;
    notifyListeners();
    await settingsStore.save(settings);
    final wd = _wifiDirect;
    if (wd == null) return;
    wd.enabled = on;
    try {
      await wd.stop();
      if (on && manager.isRunning) {
        await wd.start(localNodeId: nodeId, channel: manager.scope);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setToggleTalk(bool on) async {
    settings.toggleTalk = on;
    await _saveAndApplyPtt();
  }

  Future<void> setNotificationTalk(bool on) async {
    settings.notificationTalk = on;
    await _saveAndApplyPtt();
    if (settings.stayReachable) await applyBackgroundSettings();
  }

  Future<void> _saveAndApplyPtt() async {
    notifyListeners();
    await settingsStore.save(settings);
    await _applyPttConfig();
  }

  Future<void> setPowerSaver(bool on) async {
    settings.powerSaver = on;
    notifyListeners();
    await settingsStore.save(settings);
    await manager.setPowerSaver(on);
    friendLinks.setPowerSaver(on);
    await whosWhere.setPlan(powerPlan);
    await trip?.onPowerChanged();
  }

  /// v1.9.8: "Max speed (more battery)" or "Balanced".
  Future<void> setConnectionSpeed(ConnectionSpeed s) async {
    if (settings.connectionSpeed == s) return;
    settings.connectionSpeed = s;
    debugLog.add('net', 'Connection speed: ${s.name}');
    notifyListeners();
    await settingsStore.save(settings);
    manager.setSpeed(s);
  }

  /// Android network callbacks (Wi-Fi / mobile data up or down) or the
  /// desktop adapter watch; tests may replace it.
  Stream<String> networkChanges = RelayConnector.platform().networkChanges;

  /// The status line (v1.9.8): "Direct 42 ms · 3 backups ready".
  ConnectionSummary get connectionSummary => manager.connectionSummary();

  /// Offline power save on (the app theme listens: dim + dark).
  late final ValueNotifier<bool> offlineUi = ValueNotifier(
    settings.offlineSaver,
  );

  /// What runs in the current battery mode.
  PowerPlan get powerPlan =>
      PowerPlan(saver: settings.powerSaver, offline: settings.offlineSaver);

  /// Offline power save (Settings > Off-grid, or the Trip tab chip): the
  /// internet relay and friend relay rooms close, discovery slows right
  /// down, live location stops and the app goes dim and dark. Talk,
  /// receive, phone relay, the radio, SOS and quick messages keep working.
  Future<void> setOfflineSaver(bool on) async {
    if (settings.offlineSaver == on) return;
    settings.offlineSaver = on;
    debugLog.add('saver', 'Offline power save ${on ? 'on' : 'off'}');
    offlineUi.value = on;
    notifyListeners();
    await settingsStore.save(settings);
    await manager.setOfflineSaver(on);
    friendLinks.setOfflineSaver(on);
    await whosWhere.setPlan(powerPlan);
    await trip?.setOfflineSaver(on);
    if (on) {
      for (final conv in _live.keys.toList()) {
        await stopLiveLocation(conv);
      }
    }
    notifyListeners();
  }

  /// "Look for phones now" (offline power save keeps discovery slow).
  void scanNearbyNow() {
    _wifiDirect?.discoverNow();
    unawaited(manager.sendHello());
  }

  Future<void> setUrgentLoud(bool on) async {
    settings.urgentLoud = on;
    notifyListeners();
    await settingsStore.save(settings);
  }

  // --------------------------------------------------------------- peers

  /// Phones that dropped off in the last [leftShownFor], shown greyed out
  /// as "left" so people can see who just went away.
  static const leftShownFor = Duration(seconds: 30);
  final Map<int, ({String name, int channel, DateTime at})> _left = {};

  List<({int id, String name, int channel, DateTime at})> get recentlyLeft {
    final now = DateTime.now();
    _left.removeWhere((_, v) => now.difference(v.at) > leftShownFor);
    return [
      for (final e in _left.entries)
        (
          id: e.key,
          name: e.value.name,
          channel: e.value.channel,
          at: e.value.at,
        ),
    ]..sort((a, b) => b.at.compareTo(a.at));
  }

  /// Per-person playback volume, 0..2 (1 = 100 %).
  double volumeOf(int peerId) => settings.peerVolumes[peerId] ?? 1.0;

  Future<void> setPeerVolume(int peerId, double v) async {
    final x = v.clamp(0.0, 2.0);
    if ((x - 1.0).abs() < 0.02) {
      settings.peerVolumes.remove(peerId);
    } else {
      settings.peerVolumes[peerId] = x;
    }
    _audio.setVolumes(settings.peerVolumes);
    notifyListeners();
    await settingsStore.save(settings);
  }

  /// Media volume 0..1 on Android (voices play on the media stream).
  double? mediaVolume;

  Future<void> refreshMediaVolume() async {
    final v = await bridge.mediaVolume();
    if (v != mediaVolume) {
      mediaVolume = v;
      notifyListeners();
    }
  }

  Future<void> setShowDiagnostics(bool on) async {
    settings.showDiagnostics = on;
    notifyListeners();
    await settingsStore.save(settings);
  }

  void _onPeers(List<Peer> list) {
    _checkJoins(list);
    if (list.length != peers.length) {
      debugLog.add(
        'people',
        '${list.length} here: ${[for (final p in list) '${p.displayName} via ${manager.bestLinkTo(p.id)?.name ?? '?'}'].join(', ')}',
      );
    }
    final ids = {for (final p in list) p.id};
    for (final old in peers) {
      if (!ids.contains(old.id)) {
        _left[old.id] = (
          name: old.displayName,
          channel: old.channel,
          at: DateTime.now(),
        );
      }
    }
    _left.removeWhere((id, _) => ids.contains(id));
    final wasTalking = {
      for (final p in peers)
        if (p.talking) p.id,
    };
    for (final p in list) {
      liveGate.talkChanged(p.id, p.talking);
      if (!p.talking) {
        _audio.peerStopped(p.id);
        // Talk ended: close the recorded transmission now (silence also
        // closes it, see TalkHistory.tick).
        if (wasTalking.contains(p.id)) history?.endTake(p.id);
      }
    }
    peers = list;
    _refreshListeners();
    _adoptChannelInfo(list);
    trip?.onPeersChanged();
    final talking = {
      for (final p in list)
        if (p.talking && p.channel == scope) p.id,
    };
    for (final id in talking.difference(_talkingPrev)) {
      if (!foreground) {
        bridge.showTalking(peer: id, name: nameOf(id), channel: channel);
      }
    }
    for (final id in _talkingPrev.difference(talking)) {
      bridge.cancelTalking(id);
    }
    _talkingPrev = talking;
    if (talking.isNotEmpty) {
      _audio.setFocus(true);
    } else if (!_audio.playingClip) {
      _audio.setFocus(false);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- PTT

  Future<void> pushToTalk(bool down) async {
    if (privateTalkTo != null) {
      if (!down) await talkToFriend(privateTalkTo!, false);
      return;
    }
    if (down == transmitting) return;
    if (down && recording != null) return;
    if (down && announcementMode && !isAdmin) {
      _notice('Announcement mode: only the admin can talk on $channelTitle.');
      return;
    }
    transmitting = down;
    if (!down) {
      talkLatched = false;
      _talkLimit?.cancel();
    }
    notifyListeners();
    _updateServiceText();
    try {
      if (down) {
        _stopReplay();
        _audio.stopClip();
        playingKey = null;
        await manager.setTalking(true);
        await _audio.startTransmit(_sendAndKeep);
      } else {
        await _audio.stopTransmit(_sendAndKeep);
        history?.endTake(nodeId);
        await manager.setTalking(false);
      }
    } catch (e) {
      error = 'Mic error: $e';
      transmitting = false;
      notifyListeners();
      _updateServiceText();
    }
  }

  /// Send a mic packet and keep it in the history (marked "You").
  void _sendAndKeep(Uint8List opus) {
    // Never on the channel while not talking on it (or while talking
    // privately to a friend).
    if (privateTalkTo != null) return;
    manager.sendAudio(opus);
    history?.addPacket(
      scope: scope,
      sender: nodeId,
      name: name,
      opus: opus,
      heard: true,
      mine: true,
    );
  }

  // ------------------------------------------------------ replay missed talk

  List<TalkTake> get takes => history?.takesFor(scope) ?? const [];
  int get unheardTakes => history?.unheardIn(scope) ?? 0;

  /// Play [t] (from where it was paused), or pause it if it is playing.
  Future<void> playTake(TalkTake t) async {
    if (playingTake?.id == t.id) {
      pauseTake();
      return;
    }
    playingAll = false;
    await _play(t);
  }

  void pauseTake() {
    final t = playingTake;
    if (t == null) return;
    _resumeAt[t.id] = playingPosMs;
    playingAll = false;
    _stopReplay();
    _audio.stopClip();
    notifyListeners();
  }

  /// Plays every unheard transmission on this channel, oldest first.
  Future<void> playAllMissed() async {
    if (playingAll) return;
    final queue = takes.where((t) => !t.heard).toList().reversed.toList();
    if (queue.isEmpty) {
      _notice('Nothing missed on $channelLabel.');
      return;
    }
    playingAll = true;
    for (final t in queue) {
      if (!playingAll) break;
      final ok = await _play(t);
      if (!ok) break;
    }
    playingAll = false;
    notifyListeners();
  }

  Future<void> setPlaybackSpeed(double x) async {
    playbackSpeed = x;
    notifyListeners();
    final t = playingTake;
    if (t != null) {
      // Restart where we are at the new speed.
      _resumeAt[t.id] = playingPosMs;
      final all = playingAll;
      _stopReplay();
      _audio.stopClip();
      playingAll = all;
      await _play(t);
    }
  }

  /// Returns true if it played to the end.
  Future<bool> _play(TalkTake t) async {
    final h = history;
    if (h == null || transmitting || recording != null) return false;
    final packets = await h.packetsOf(t);
    if (packets == null || packets.isEmpty) {
      _notice('That recording is gone.');
      return false;
    }
    final token = ++_replayToken;
    playbackLog.add(
      'history',
      '${t.mine ? 'you' : '${t.name} #${t.sender}'} take ${t.id}: '
          '${playingAll ? 'play all missed' : 'play (tap)'}',
    );
    playingKey = null;
    playingTake = t;
    final from = _resumeAt.remove(t.id) ?? 0;
    playingPosMs = from >= t.durationMs - 300 ? 0 : from;
    h.markHeard(t);
    notifyListeners();
    final finished = await _audio.playClip(
      packets,
      fromPeer: t.mine ? null : t.sender,
      speed: playbackSpeed,
      startMs: playingPosMs,
      onPosition: (ms) {
        if (token != _replayToken) return;
        playingPosMs = ms;
        final now = DateTime.now();
        if (now.difference(_lastPosNotify).inMilliseconds > 200) {
          _lastPosNotify = now;
          notifyListeners();
        }
      },
    );
    if (token == _replayToken) {
      playingTake = null;
      playingPosMs = 0;
      if (_talkingPrev.isEmpty) await _audio.setFocus(false);
      notifyListeners();
    }
    return finished;
  }

  void _stopReplay() {
    _replayToken++;
    playingTake = null;
    playingAll = false;
  }

  Future<void> deleteTake(TalkTake t) async {
    if (playingTake?.id == t.id) pauseTake();
    _resumeAt.remove(t.id);
    await history?.delete(t);
  }

  Future<void> clearHistory() async {
    if (playingTake != null) pauseTake();
    await history?.clear(scope);
  }

  void markAllHeard() => history?.markAllHeard(scope);

  // ---------------------------------------------------------------- rings

  /// Ring one phone, or everyone on the channel when [toPeer] is null.
  Future<void> ring({
    int? toPeer,
    bool beep = false,
    bool urgent = false,
  }) async {
    final r = await ringer.ring(toPeer: toPeer, beep: beep, urgent: urgent);
    final what = beep ? 'Beep' : (urgent ? 'Urgent ring' : 'Ring');
    if (r.status.isEmpty) {
      _notice(
        'Nobody on $channelLabel to ${beep ? 'beep' : 'ring'} right now.',
      );
    } else if (toPeer != null && r.status[toPeer] == RingStatus.unreachable) {
      _notice('${nameOf(toPeer)} is out of reach right now.');
    } else {
      _notice(
        toPeer == null
            ? '$what sent to ${r.status.length} on $channelLabel'
            : '$what sent to ${nameOf(toPeer)}',
      );
    }
    notifyListeners();
  }

  void _onIncomingRing(IncomingRing r) {
    final from = nameOf(r.from);
    // v1.9.5: mute / quiet hours keep rings and beeps silent unless they
    // are let through (urgent, a second ring, an "Always allow" person).
    final sounds = r.beep
        ? !silenced
        : quiet.ringSounds(from: r.from, ringId: r.id, urgent: r.urgent);
    if (r.beep) {
      if (sounds) {
        bridge.beep(from: r.from, name: from, notify: !foreground);
      }
      if (foreground) _notice('$from beeped you${sounds ? '' : ' (muted)'}');
      return;
    }
    activeRings.add(r);
    if (sounds) {
      bridge.showRing(
        from: r.from,
        id: r.id,
        name: from,
        channel: displayChannel(r.channel),
        urgent: r.urgent,
        loud: settings.urgentLoud,
      );
    } else {
      debugLog.add(
        'quiet',
        'ring from $from kept silent (${quietStatus ?? ''})',
      );
      if (foreground) _notice('Ring from $from (muted)');
    }
    final ringFor = r.urgent ? urgentRingDuration : ringDuration;
    _ringTimers[(r.from, r.id)] = Timer(ringFor, () async {
      if (r.status != RingStatus.delivered) return;
      await ringer.respond(r, RingStatus.missed);
      await bridge.stopRing(from: r.from, id: r.id);
      activeRings.remove(r);
      await bridge.showInfo(
        nid: r.from & 0xFFFF,
        title: 'Missed ring from $from',
        text: labelFor(r.channel),
      );
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> answerRing(IncomingRing r) async {
    _ringTimers.remove((r.from, r.id))?.cancel();
    activeRings.remove(r);
    await bridge.stopRing(from: r.from, id: r.id);
    await ringer.respond(r, RingStatus.answered);
    if (!TransportManager.isPrivateScope(r.channel) &&
        r.channel != scope &&
        r.channel > 0) {
      await setChannel(r.channel);
    }
    notifyListeners();
  }

  Future<void> dismissRing(IncomingRing r) async {
    _ringTimers.remove((r.from, r.id))?.cancel();
    activeRings.remove(r);
    await bridge.stopRing(from: r.from, id: r.id);
    await ringer.respond(r, RingStatus.dismissed);
    notifyListeners();
  }

  /// e.g. "Ring: answered" for the peer tile, or null.
  String? ringStatusText(int peerId) {
    final s = ringer.statusFor(peerId);
    if (s == null) return null;
    final what = s.$2 ? 'Beep' : 'Ring';
    return switch (s.$1) {
      RingStatus.sending => '$what: sending...',
      RingStatus.delivered => s.$2 ? 'Beep delivered' : 'Ringing...',
      RingStatus.answered => 'Ring answered',
      RingStatus.dismissed => 'Ring declined',
      RingStatus.missed => 'Ring: no answer',
      RingStatus.unreachable => '$what: could not reach',
    };
  }

  // ------------------------------------------------------- voice messages

  Future<void> startRecording({int? toPeer, bool toFriend = false}) async {
    if (recording != null || transmitting) return;
    final rec = Recording(toPeer, DateTime.now(), toFriend: toFriend);
    recording = rec;
    _audio.stopClip();
    playingKey = null;
    notifyListeners();
    try {
      await _audio.startTransmit(rec.packets.add);
    } catch (e) {
      recording = null;
      error = 'Mic error: $e';
      notifyListeners();
      return;
    }
    _recordLimit = Timer(
      const Duration(milliseconds: VoiceClip.maxDurationMs),
      () => stopRecording(),
    );
  }

  /// Stops recording and sends (unless [cancel]).
  Future<void> stopRecording({bool cancel = false}) async {
    final rec = recording;
    if (rec == null) return;
    _recordLimit?.cancel();
    try {
      await _audio.stopTransmit(rec.packets.add);
    } catch (_) {}
    recording = null;
    notifyListeners();
    if (cancel) return;
    final maxPackets = VoiceClip.maxDurationMs ~/ VoiceClip.frameMs;
    final packets = rec.packets.length > maxPackets
        ? rec.packets.sublist(0, maxPackets)
        : rec.packets;
    final clip = VoiceClip(packets);
    if (clip.durationMs < 600) {
      _notice('Too short. Hold the button while you talk.');
      return;
    }
    final m = rec.toFriend ? friendMessenger : messenger;
    if (m == null) return;
    // With a radio paired, also keep a Codec 2 copy for phones (and, since
    // v1.8.3, friends) that only the radio reaches. Friend copies are
    // sealed with the pair key like everything else to that friend.
    final radioClip = _makeRadioClip(clip);
    if (radioPaired && radioClip == null && radioVoiceSupported) {
      _notice(
        'Over the radio voice messages can be up to '
        '${RadioClip.maxDurationMs ~/ 1000} s: this one goes by Wi-Fi, '
        'Bluetooth or internet only.',
      );
    }
    final e = await m.send(
      clip,
      toPeer: rec.toPeer,
      channel: rec.toFriend ? friendScope : scope,
      radioClip: radioClip,
    );
    final who = rec.toPeer == null
        ? channelLabel
        : (rec.toFriend ? friendName(rec.toPeer!) : nameOf(rec.toPeer!));
    final reachable = rec.toPeer == null
        ? e.recipients.isNotEmpty
        : (rec.toFriend
              ? friendLinks.isOnline(rec.toPeer!)
              : manager.isReachable(rec.toPeer!));
    _notice(
      reachable
          ? 'Sending voice message (${formatDuration(clip.durationMs)}) to $who'
          : 'Saved. It will be delivered to $who when they are in range (up to 24 h).',
    );
  }

  // ------------------------------------------------------- LoRa radio

  bool get radioPaired => radioDevice.deviceId != null;

  /// Codec 2 copy of [clip] for the radio, or null (no radio, no codec,
  /// longer than [RadioClip.maxDurationMs] of speech).
  RadioClip? _makeRadioClip(VoiceClip clip) {
    final codec = _radioCodec;
    if (codec == null || !radioPaired) return null;
    try {
      final dec = OpusVoiceDecoder();
      final pcm = BytesBuilder(copy: false);
      try {
        for (final p in clip.packets) {
          final f = dec.decode(p);
          pcm.add(f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes));
        }
      } finally {
        dec.dispose();
      }
      final raw = pcm.takeBytes();
      final samples = Int16List.view(raw.buffer, 0, raw.length ~/ 2);
      return codec.encode(samples, sentAt: DateTime.now());
    } catch (_) {
      return null;
    }
  }

  /// A Codec 2 clip from the radio -> a normal (Opus) voice message body.
  Future<Uint8List?> _radioClipToVoice(Uint8List body) async {
    final codec = _radioCodec;
    final clip = RadioClip.tryDecode(body);
    if (codec == null || clip == null) return null;
    try {
      final pcm = codec.decode(clip);
      final enc = OpusVoiceEncoder();
      final packets = <Uint8List>[];
      try {
        const n = VoiceFormat.samplesPerFrame;
        for (var o = 0; o + n <= pcm.length; o += n) {
          packets.add(enc.encode(Int16List.fromList(pcm.sublist(o, o + n))));
        }
      } finally {
        enc.dispose();
      }
      return VoiceClip(packets, sentAt: clip.sentAt).encode();
    } catch (_) {
      return null;
    }
  }

  /// Look for Meshtastic radios nearby (Settings > Long-range radio).
  Future<List<FoundRadio>> scanRadios() async {
    try {
      return await radioDevice.scan();
    } catch (e) {
      _notice(e is StateError ? e.message : 'Scan failed: $e');
      return const [];
    }
  }

  Future<void> pairRadio(FoundRadio r) async {
    settings.radioId = r.id;
    settings.radioName = r.name;
    await settingsStore.save(settings);
    await radioDevice.use(r.id, r.name);
    notifyListeners();
  }

  Future<void> forgetRadio() async {
    await radioDevice.forget();
    settings.radioId = null;
    settings.radioName = null;
    await settingsStore.save(settings);
    notifyListeners();
  }

  // ----------------------------------- Meshtastic channels (v1.9.7)

  /// Link of an inner frame's Walkie channel: open channels only (sealed
  /// frames, private channels, friends, gateways and the lobby never).
  MeshChannelRef? meshLinkForFrame(Frame f) {
    if (f.type == FrameType.sealed ||
        f.type == FrameType.gateway ||
        f.type == FrameType.lobby ||
        f.type == FrameType.mesh) {
      return null;
    }
    final ch = f.channel;
    if (ch < 1 || ch > 16 || settings.isPrivate(ch)) return null;
    return settings.meshLinks[ch]?.ref;
  }

  /// The Meshtastic channel [ch] is shared with, or null.
  MeshLink? meshLinkOf(int ch) =>
      settings.isPrivate(ch) ? null : settings.meshLinks[ch];

  /// The paired radio's channels (primary and secondary, by slot).
  List<MeshRadioChannel> get radioChannels {
    final s = radioDevice.session;
    if (s == null) return const [];
    return s.channels.values.where((c) => !c.isDisabled).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
  }

  MeshChannelRef? radioChannelRef(MeshRadioChannel c) =>
      radioDevice.session?.refOf(c);

  /// Walkie channel linked to [ref], or null.
  int? walkieChannelFor(MeshChannelRef ref) {
    for (final e in settings.meshLinks.entries) {
      if (e.value.ref == ref && !settings.isPrivate(e.key)) return e.key;
    }
    return null;
  }

  /// Open channel numbers that can be linked (not private, not linked).
  List<int> get linkableChannels => [
    for (var ch = 1; ch <= 16; ch++)
      if (!settings.isPrivate(ch) && !settings.meshLinks.containsKey(ch)) ch,
  ];

  MeshChannelWriter meshWriter() =>
      MeshChannelWriter(() => radioDevice.session);

  /// Link open Walkie channel [ch] to [ref]; [name] names a new channel
  /// ("Shared with Meshtastic" when the user made one). Null when done,
  /// else what is wrong.
  Future<String?> linkMeshChannel(int ch, MeshLink link, {String? name}) async {
    if (ch < 1 || ch > 16) return 'Pick a channel 1-16.';
    if (settings.isPrivate(ch)) {
      return 'Private groups cannot be shared with Meshtastic.';
    }
    final other = walkieChannelFor(link.ref);
    if (other != null && other != ch) {
      return 'That Meshtastic channel is already shared with CH $other.';
    }
    settings.meshLinks[ch] = link;
    if (name != null && name.trim().isNotEmpty) {
      settings.channelNames[ch] = ChannelName(
        name.trim().length > 30 ? name.trim().substring(0, 30) : name.trim(),
        settings.channelNames[ch]?.emoji ?? '',
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    await settingsStore.save(settings);
    debugLog.add('mesh', 'CH $ch shared with a Meshtastic channel');
    notifyListeners();
    return null;
  }

  /// Unlink CH [ch]; [removeFromRadio] also turns that channel off on the
  /// paired radio (secondary channels only). Null when done.
  Future<String?> unlinkMeshChannel(
    int ch, {
    bool removeFromRadio = false,
    void Function(MeshWriteStep step)? onStep,
  }) async {
    final link = settings.meshLinks[ch];
    if (link == null) return null;
    String? err;
    if (removeFromRadio) {
      final s = radioDevice.session;
      final i = s?.indexOf(link.ref);
      if (s == null) {
        err =
            'Unlinked, but the radio is not connected, so the channel is '
            'still on it.';
      } else if (i == null) {
        // Not on this radio: nothing to remove.
      } else if (i == 0) {
        err =
            'Unlinked. That is your radio\'s main channel, so it stays on '
            'the radio.';
      } else {
        try {
          await meshWriter().removeChannel(i, onStep: onStep);
        } on MeshWriteException catch (e) {
          err = 'Unlinked, but: ${e.message}';
        } catch (_) {
          err = 'Unlinked, but the radio did not take the change.';
        }
      }
    }
    settings.meshLinks.remove(ch);
    await settingsStore.save(settings);
    debugLog.add('mesh', 'CH $ch no longer shared with Meshtastic');
    notifyListeners();
    return err;
  }

  /// App phones heard over the radio recently (for Settings).
  int get radioPeers =>
      loraTransport.peerSignals.keys.where(loraTransport.canReach).length;

  /// Voice messages recorded longer ago than this arrive quietly.
  static const staleMessage = Duration(minutes: 10);

  void _onVoiceMessage(InboxEntry e) {
    final name = e.senderName.isEmpty ? nameOf(e.sender) : e.senderName;
    if (isMuted(e.sender)) {
      notifyListeners();
      return;
    }
    // Apps older than 1.5.2 send no time with a message and may keep
    // re-sending old ones, and anything older than 10 min is stale: keep it
    // in Voice messages, marked played, without a notification.
    final sent = e.sentAt;
    final age = sent == null ? null : DateTime.now().difference(sent);
    if (sent == null || age! > staleMessage) {
      playbackLog.add(
        'voice-msg-quiet',
        '$name #${e.sender} id ${e.msgId}: '
            '${sent == null ? 'older app (no time)' : '${age!.inMinutes} min old'}'
            ', filed without notification',
      );
      unawaited(_messengerFor(e)?.markPlayed(e));
      notifyListeners();
      return;
    }
    playbackLog.add(
      'voice-msg',
      '$name #${e.sender} id ${e.msgId}: arrived, notification only',
    );
    if (e.channel == friendScope) privateReply.heard(e.sender);
    if (foreground) {
      _notice('Voice message from $name (${formatDuration(e.durationMs)})');
    }
    bridge.showVoiceMessage(
      key: e.key,
      nid: e.notificationId,
      name: name,
      duration: formatDuration(e.durationMs),
      silent: silenced,
    );
    notifyListeners();
  }

  Future<void> playMessage(InboxEntry e, {String trigger = 'tap'}) async {
    final m = _messengerFor(e);
    if (m == null || transmitting || recording != null) return;
    if (playingKey == e.key) return; // already playing: never restart it
    playbackLog.add(
      'voice-msg',
      '${e.senderName.isEmpty ? nameOf(e.sender) : e.senderName} '
          '#${e.sender} id ${e.msgId}: play ($trigger)',
    );
    final body = await m.bodyOf(e);
    final clip = body == null ? null : VoiceClip.tryDecode(body);
    if (clip == null) {
      _notice('That message could not be played.');
      return;
    }
    _stopReplay();
    playingKey = e.key;
    await m.markPlayed(e);
    if (settings.readReceipts) m.markRead(e.sender, e.msgId);
    notifyListeners();
    await _audio.playClip(clip.packets, fromPeer: e.sender);
    if (playingKey == e.key) playingKey = null;
    if (_talkingPrev.isEmpty) await _audio.setFocus(false);
    notifyListeners();
  }

  /// Stop a saved voice message / replay / "Play all missed" (leaving the
  /// Voice messages or History screen). Live talk is not affected.
  void stopSavedPlayback() {
    if (playingKey == null && playingTake == null && !playingAll) return;
    playbackLog.add('stop', 'Left the screen: saved playback stopped');
    _stopReplay();
    _audio.stopClip();
    playingKey = null;
    notifyListeners();
  }

  void stopPlayback() {
    _audio.stopClip();
    playingKey = null;
    notifyListeners();
  }

  /// Something is playing that the Stop button can stop.
  bool get playingSomething =>
      playingKey != null || playingTake != null || liveActive;

  /// Stop everything: voice message / replay playback, the "play all
  /// missed" queue, talking, recording and the mic itself.
  Future<void> stopAllAudio() async {
    // Live streams stay silent until that phone starts talking again.
    liveGate.silenceAll();
    _lastLiveAt = null;
    playbackLog.add('stop', 'Stop: everything stopped and silenced');
    _stopReplay();
    _resumeAt.clear();
    _audio.stopClip();
    playingKey = null;
    if (privateTalkTo != null) await talkToFriend(privateTalkTo!, false);
    if (transmitting) await pushToTalk(false);
    if (recording != null) await stopRecording(cancel: true);
    await _audio.forceStopTransmit();
    // Whatever is still queued in the speaker goes too.
    await _audio.flushSpeaker();
    await _audio.setFocus(false);
    notifyListeners();
  }

  /// Settings > "Clear all messages and queues": nothing queued is sent or
  /// played again; voice messages and missed talk are deleted.
  Future<void> clearAllMessages() async {
    await stopAllAudio();
    await messenger?.clearAll(deleteInbox: true);
    await friendMessenger?.clearAll(deleteInbox: true);
    await history?.clearAll();
    playbackLog.add('cleared', 'All messages, queues and missed talk cleared');
    _notice('All voice messages, queues and missed talk cleared.');
    notifyListeners();
  }

  /// One time after updating to 1.5.2: drop every queued message (so this
  /// phone never re-sends an old one) and count everything received or
  /// recorded so far as played / seen (so nothing old plays or pops up).
  Future<void> _migrate152() async {
    try {
      final marker = File(
        '${(await _messageDir()).parent.path}/migrated_1_5_2',
      );
      if (await marker.exists()) return;
      await messenger?.clearAll();
      await friendMessenger?.clearAll();
      history?.markEverythingHeard();
      await marker.writeAsString(DateTime.now().toIso8601String());
      playbackLog.add('cleared', '1.5.2 update: old queues cleared');
    } catch (_) {}
  }

  Future<void> deleteMessage(InboxEntry e) async {
    if (playingKey == e.key) stopPlayback();
    await _messengerFor(e)?.deleteReceived(e);
    notifyListeners();
  }

  Future<void> cancelOutgoing(int msgId) async {
    await messenger?.cancel(msgId);
    await friendMessenger?.cancel(msgId);
    notifyListeners();
  }

  // ================================================================ v1.5

  /// Scope used for friend voice messages / chats (not a real channel).
  static const friendScope = 0x40000;

  late final FriendLinks friendLinks;
  Messenger? friendMessenger;
  ChatStore? chats;

  // ------------------------------------------------------------- hello x

  Map<String, Object?> _helloExtras() {
    final n = settings.channelNames[scope];
    return {
      'v': featureLevel,
      'bt': ?batteryPct,
      if (n != null && !n.isEmpty) ...{
        'cn': n.name,
        'ce': n.emoji,
        'ct': n.updated,
      },
      if (!settings.showInWhosWhere) 'hw': 0,
      'kx': ?peerBox?.publicKey,
      if (isPrivate && settings.channelAdmins[scope] == nodeId) 'adm': 1,
      if (isPrivate &&
          settings.channelAdmins[scope] == nodeId &&
          settings.announceScopes.contains(scope))
        'ann': 1,
    };
  }

  /// Learn the channel name / admin / announcement mode from presence.
  void _adoptChannelInfo(List<Peer> list) {
    var dirty = false;
    final admin = settings.channelAdmins[scope];
    for (final p in list) {
      if (p.channel != scope) continue;
      final x = p.info;
      // Admin: trust the first phone that claims it (see README).
      if (isPrivate && admin == null && x['adm'] == 1) {
        settings.channelAdmins[scope] = p.id;
        dirty = true;
      }
      if (isPrivate && settings.channelAdmins[scope] == p.id) {
        _annSeen[scope] = x['ann'] == 1;
      }
      final t = (x['ct'] as num?)?.toInt();
      final cn = x['cn'], ce = x['ce'];
      if (t == null || cn is! String || ce is! String) continue;
      final adminNow = settings.channelAdmins[scope];
      if (isPrivate && adminNow != null && adminNow != p.id) continue;
      final mine = settings.channelNames[scope];
      if (mine == null || t > mine.updated) {
        settings.channelNames[scope] = ChannelName(
          cn.length > 30 ? cn.substring(0, 30) : cn,
          ce.length > 8 ? ce.substring(0, 8) : ce,
          t,
        );
        dirty = true;
      }
    }
    if (dirty) unawaited(settingsStore.save(settings));
  }

  final Map<int, bool> _annSeen = {};

  /// Name + emoji of the current channel, or null.
  ChannelName? get channelName {
    final n = settings.channelNames[scope];
    return n == null || n.isEmpty ? null : n;
  }

  ChannelName? channelNameOf(int scope) {
    final n = settings.channelNames[scope];
    return n == null || n.isEmpty ? null : n;
  }

  /// "🔥 Family" or "CH 3".
  String get channelTitle {
    final n = channelName;
    if (n == null) return channelLabel;
    return [n.emoji, n.name].where((s) => s.isNotEmpty).join(' ');
  }

  Future<void> setChannelName(String name, String emoji) async {
    if (isPrivate && adminId != null && !isAdmin) {
      _notice('Only the channel admin can rename this channel.');
      return;
    }
    final n = name.trim(), e = emoji.trim();
    settings.channelNames[scope] = ChannelName(
      n.length > 30 ? n.substring(0, 30) : n,
      e.length > 8 ? e.substring(0, 8) : e,
      DateTime.now().millisecondsSinceEpoch,
    );
    await settingsStore.save(settings);
    await manager.sendHello();
    whosWhere.announceSoon();
    _updateServiceText();
    notifyListeners();
  }

  // ------------------------------------------------------------- admin

  int? get adminId => isPrivate ? settings.channelAdmins[scope] : null;
  bool get isAdmin => adminId == nodeId;

  /// Only the admin may talk on this channel.
  bool get announcementMode {
    if (!isPrivate) return false;
    if (isAdmin) return settings.announceScopes.contains(scope);
    return _annSeen[scope] ?? false;
  }

  /// Make me admin of the current private channel (the creator does this
  /// when setting it up).
  Future<void> claimAdmin() async {
    if (!isPrivate) return;
    settings.channelAdmins[scope] = nodeId;
    await settingsStore.save(settings);
    await manager.sendHello();
    notifyListeners();
  }

  Future<void> setAnnouncementMode(bool on) async {
    if (!isAdmin) return;
    if (on) {
      settings.announceScopes.add(scope);
    } else {
      settings.announceScopes.remove(scope);
    }
    await settingsStore.save(settings);
    await manager.sendHello();
    notifyListeners();
  }

  final Map<int, Completer<void>> _rekeyAcks = {};
  final Set<int> _rekeysHandled = {};
  bool kicking = false;

  /// How the new passcode reaches [member] in [kick] (v1.9.4); see
  /// [Rekey] for the ways (`friend`, `key`, `legacy`, `conflict`).
  ({Map<String, Object?>? x, String how}) rekeyFor(
    int member,
    String passcode,
    int rid,
    int removed,
  ) {
    final p = manager.peer(member);
    return Rekey.build(
      from: nodeId,
      to: member,
      rid: rid,
      passcode: passcode,
      removed: removed,
      toFeature: p?.feature ?? 0,
      toKx: p?.kxSeen ?? const {},
      box: peerBox,
      friendSecret: friendLinks.friend(member)?.key.secret,
    );
  }

  /// The new passcode in a rekey from [from] (our admin), or null.
  String? passcodeFromRekey(int from, ControlMessage m) {
    final rid = m.id;
    if (rid == null) return null;
    return Rekey.open(
      from: from,
      me: nodeId,
      rid: rid,
      x: m.x,
      fromKx: manager.peer(from)?.kxSeen ?? const {},
      box: peerBox,
      friendSecret: friendLinks.friend(from)?.key.secret,
      minLength: Passcodes.minJoin,
    );
  }

  /// Remove [peerId] from this private channel: everyone else moves to a
  /// new random passcode, delivered to each phone separately (v1.9.4, see
  /// [rekeyFor]); the removed phone is not told it and cannot read it.
  Future<void> kick(int peerId) async {
    if (!isAdmin || kicking) return;
    final ch = channel, oldScope = scope;
    final members = manager.reachablePeersOn(oldScope)..remove(peerId);
    final kickedName = nameOf(peerId);
    kicking = true;
    notifyListeners();
    final pass = _randomPasscode();
    final rid = Random().nextInt(0x7FFFFFFF) + 1;
    final acked = <int>{};
    final legacy = <int>{};
    final unsafe = <int>{};
    try {
      await Future.wait([
        for (final m in members)
          () async {
            final r = rekeyFor(m, pass, rid, peerId);
            debugLog.add('admin', 'rekey to #$m: ${r.how}');
            if (r.x == null) {
              unsafe.add(m);
              return;
            }
            if (r.how == 'legacy') legacy.add(m);
            final done = Completer<void>();
            final key = rid ^ m;
            _rekeyAcks[key] = done;
            for (var i = 0; i < 10 && !done.isCompleted; i++) {
              await manager.sendControlTo(
                m,
                ControlMessage(ControlKind.rekey, to: m, id: rid, x: r.x!),
              );
              await Future.any([
                done.future,
                Future<void>.delayed(const Duration(seconds: 1)),
              ]);
            }
            _rekeyAcks.remove(key);
            if (done.isCompleted) acked.add(m);
          }(),
      ]);
      final name = settings.channelNames[oldScope];
      final ann = settings.announceScopes.contains(oldScope);
      settings.privateChannels[ch] = pass;
      await settingsStore.save(settings);
      await setChannel(ch);
      settings.channelAdmins[scope] = nodeId;
      if (name != null) settings.channelNames[scope] = name;
      if (ann) settings.announceScopes.add(scope);
      await chats?.rename(
        channelConversation(oldScope),
        channelConversation(scope),
      );
      await settingsStore.save(settings);
      await manager.sendHello();
      final missed = members.difference(acked);
      final parts = <String>[
        missed.isEmpty
            ? 'Removed $kickedName. ${acked.length} phones moved to the new '
                  'passcode.'
            : 'Removed $kickedName. Not confirmed: '
                  '${missed.map(nameOf).join(', ')}. Give them the new '
                  'passcode (tap the lock).',
      ];
      final old = legacy.intersection(acked);
      if (old.isNotEmpty) {
        parts.add(
          '${old.map(nameOf).join(', ')} ${old.length == 1 ? 'has' : 'have'} '
          'an older app and got it the old way, which $kickedName could '
          'read. Update their app; the next removal is private for them '
          'too.',
        );
      }
      if (unsafe.isNotEmpty) {
        parts.add(
          'Two phones claimed to be ${unsafe.map(nameOf).join(', ')}, so '
          'nothing was sent to them.',
        );
      }
      _notice(parts.join(' '));
    } finally {
      kicking = false;
      notifyListeners();
    }
  }

  static String _randomPasscode() => Passcodes.generate();

  Future<void> _onRekey(InboundControl c) async {
    final m = c.message;
    final rid = m.id;
    if (rid == null) return;
    if (m.kind == ControlKind.rekeyAck) {
      _rekeyAcks[rid ^ c.peerId]?.complete();
      return;
    }
    // A new passcode from our admin, for the channel we are on.
    if (!isPrivate || c.channel != scope || adminId != c.peerId) return;
    final pc = passcodeFromRekey(c.peerId, m);
    if (pc == null) return;
    final ack = ControlMessage(ControlKind.rekeyAck, to: c.peerId, id: rid);
    await manager.sendControlTo(c.peerId, ack);
    if (!_rekeysHandled.add(rid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await manager.sendControlTo(c.peerId, ack);
    final ch = channel, oldScope = scope, admin = c.peerId;
    final name = settings.channelNames[oldScope];
    settings.privateChannels[ch] = pc;
    await settingsStore.save(settings);
    await setChannel(ch);
    settings.channelAdmins[scope] = admin;
    if (name != null) settings.channelNames[scope] = name;
    await chats?.rename(
      channelConversation(oldScope),
      channelConversation(scope),
    );
    await settingsStore.save(settings);
    _notice(
      '${nameOf(admin)} (admin) changed the passcode of $channelTitle; '
      'you were moved automatically.',
    );
  }

  // ------------------------------------- private security (v1.9.4)

  /// Direct link setup (dx) sealed to the other phone's own key when it
  /// has one (v1.9.4), so nobody else in the relay room (a hidden listener
  /// on a public channel, a removed member on a private one) learns its
  /// addresses or link tokens. Phones on older apps get it as before. And
  /// a link is only started for / accepted from phones we have heard a
  /// hello from.
  void _wrapDirectSignals() {
    final d = _relay.direct!;
    d.signal = (to, x) =>
        unawaited(manager.sendDirectSignal(to, sealDirectSignal(to, x)));
    manager.onDirectSignal = (from, x) {
      final open = openDirectSignal(from, x);
      if (open == null) return;
      final op = open['op'];
      if ((op == 'o' || op == 'r') &&
          (manager.peer(from)?.feature ?? 0) < directFeature) {
        return; // never heard its hello: not in the people list
      }
      d.onSignal(from, open);
    };
  }

  /// [x] sealed for [to] (`{e, pk}`), or [x] unchanged for older phones.
  Map<String, Object?> sealDirectSignal(int to, Map<String, Object?> x) {
    final p = manager.peer(to);
    return DirectSeal.seal(
      from: nodeId,
      to: to,
      x: x,
      toFeature: p?.feature ?? 0,
      toKx: p?.kxSeen ?? const {},
      box: peerBox,
    );
  }

  /// The dx payload from [from], opened if sealed; null if it does not open.
  Map<String, Object?>? openDirectSignal(int from, Map<String, Object?> x) =>
      DirectSeal.open(
        from: from,
        me: nodeId,
        x: x,
        fromKx: manager.peer(from)?.kxSeen ?? const {},
        box: peerBox,
      );

  void _onRoster((RelayTransport, RelayRoster) e) {
    final heard = <String>{
      nodeId.toRadixString(16),
      for (final p in peers)
        if (p.channel == scope) p.id.toRadixString(16),
      for (final id in settings.blocked.keys) id.toRadixString(16),
      // v1.9.5: announced LoRa gateways are visible, not unknown.
      for (final id in manager.gatewayIds) id.toRadixString(16),
    };
    listenerWatch.update(e.$1, e.$2, heard);
    _refreshListeners();
  }

  void _refreshListeners() {
    final n = listenerWatch.count(DateTime.now());
    if (n == hiddenListeners) return;
    debugLog.add(
      'people',
      '$n unknown listener(s) in relay room ${RelayTransport.roomFor(scope)}',
    );
    hiddenListeners = n;
    notifyListeners();
  }

  /// Alert when someone joins (v1.9.4): on by default for private
  /// channels, off for open ones (Settings).
  bool get joinAlertOn =>
      isPrivate ? settings.joinAlertPrivate : settings.joinAlertPublic;

  Future<void> setJoinAlert({bool? private, bool? public}) async {
    if (private != null) settings.joinAlertPrivate = private;
    if (public != null) settings.joinAlertPublic = public;
    notifyListeners();
    await settingsStore.save(settings);
  }

  void _checkJoins(List<Peer> list) {
    final now = DateTime.now();
    final before = {
      for (final p in peers)
        if (p.channel == scope) p.id,
    };
    final fresh = [
      for (final p in list)
        if (p.channel == scope &&
            !before.contains(p.id) &&
            !isBlocked(p.id) &&
            // Back after a short drop-out: not a new join.
            !_left.containsKey(p.id))
          p,
    ];
    if (fresh.isEmpty || !started || !joinAlertOn) return;
    if (now.isBefore(_joinQuietUntil)) return;
    final names = <String>[];
    int? first;
    for (final p in fresh) {
      final last = _joinAlerted[p.id];
      if (last != null && now.difference(last) < const Duration(minutes: 10)) {
        continue;
      }
      _joinAlerted[p.id] = now;
      names.add(p.displayName);
      first ??= p.id;
    }
    if (names.isEmpty) return;
    final text = '${names.join(', ')} joined $channelTitle';
    lastJoinAlert = (text: text, at: now);
    debugLog.add('people', 'join alert: $text');
    _notice(isPrivate ? '\u{1F512} $text' : text);
    if (foreground && bridge.supported && !silenced) {
      unawaited(
        bridge
            .beep(from: first!, name: names.first, notify: false)
            .catchError((_) {}),
      );
    }
  }

  /// Name of channel number [ch] as this phone knows it (a private
  /// channel's name is kept under its key, known once it was opened).
  ChannelName? nameForChannel(int ch) {
    final pass = settings.passcodeFor(ch);
    if (pass == null) return channelNameOf(ch);
    final key = _keys['$ch\u0000$pass'];
    if (key == null) return null;
    return channelNameOf(TransportManager.scopeFor(ch, key));
  }

  /// Private channels saved on this phone (channel numbers, sorted).
  List<int> get privateChannelNumbers =>
      settings.privateChannels.keys.toList()..sort();

  /// A channel number for a new private channel: the highest one that is
  /// not private yet and not the one we are on (CH 16 down), so the low
  /// numbers stay free for open talk. Null when all 16 are private.
  int? freeChannelForPrivate() {
    for (var ch = 16; ch >= 1; ch--) {
      if (!settings.isPrivate(ch) && ch != channel) return ch;
    }
    return settings.isPrivate(channel) ? null : channel;
  }

  /// Set up a new private channel (v1.9.4): [passcode] must be strong
  /// ([Passcodes.problemForNew]); I become its admin and move there.
  /// Returns the problem with the passcode, or null when done.
  Future<String?> createPrivateChannel({
    required int ch,
    required String passcode,
    String name = '',
    String emoji = '',
  }) async {
    final p = ChannelKey.normalize(passcode);
    final problem = Passcodes.problemForNew(p);
    if (problem != null) return problem;
    settings.privateChannels[ch] = p;
    await settingsStore.save(settings);
    await setChannel(ch);
    await claimAdmin();
    if (name.trim().isNotEmpty || emoji.trim().isNotEmpty) {
      await setChannelName(name, emoji);
    }
    return null;
  }

  // -------------------------------------------------------- mute / block

  bool isMuted(int id) => settings.muted.contains(id);
  bool isBlocked(int id) => settings.blocked.containsKey(id);

  Future<void> setMuted(int id, bool on) async {
    if (on) {
      settings.muted.add(id);
      _audio.peerStopped(id);
    } else {
      settings.muted.remove(id);
    }
    notifyListeners();
    await settingsStore.save(settings);
  }

  Future<void> setBlocked(int id, bool on, {String? name}) async {
    if (on) {
      settings.blocked[id] = name ?? nameOf(id);
      _audio.peerStopped(id);
    } else {
      settings.blocked.remove(id);
    }
    manager.blocked
      ..clear()
      ..addAll(settings.blocked.keys);
    notifyListeners();
    await settingsStore.save(settings);
  }

  // ------------------------------------------------------------- friends

  List<Friend> get friends => friendLinks.friends;
  bool isFriend(int id) => friendLinks.isFriend(id);
  bool friendOnline(int id) => friendLinks.isOnline(id);

  /// "Wi-Fi", "Bluetooth", "Internet", "phone mesh (2 hops)", "radio" or
  /// null when not reachable.
  String? friendVia(int id) => friendLinks.pathTo(id)?.label;

  /// Friend chat header line (v1.8.3, see [friendStatusLineFor]).
  String friendStatusLine(int id) => friendStatusLineFor(
    friendLinks.statusOf(id),
    DateTime.now(),
    name: friendName(id),
  );

  /// Not reachable now but heard privately within the last two minutes.
  bool friendRecentlyHeard(int id) {
    final s = friendLinks.statusOf(id);
    final t = s.lastHeard;
    return !s.connected &&
        t != null &&
        DateTime.now().difference(t) <= FriendLinks.recentFor;
  }

  int get onlineFriends => friends.where((f) => friendOnline(f.id)).length;

  /// Friend requests waiting for an answer.
  final List<FriendRequest> friendRequests = [];
  final _friendRequestStream = StreamController<FriendRequest>.broadcast();
  Stream<FriendRequest> get friendRequestStream => _friendRequestStream.stream;

  final Map<int, ({SimpleKeyPair kp, int id, DateTime at})> _outgoingReqs = {};

  /// Ask [peerId] (on this channel, in reach) to be friends. They see a
  /// prompt; if they accept, both phones get the same pair key.
  Future<void> requestFriend(int peerId) async {
    final p = manager.peer(peerId);
    if (p == null || !manager.isReachable(peerId)) {
      _notice('${nameOf(peerId)} is out of reach.');
      return;
    }
    if (!p.supportsChat) {
      _notice('${nameOf(peerId)} needs to update the app (1.5 or newer).');
      return;
    }
    final kp = await PairKey.newKeyPair();
    final pk = await PairKey.publicKeyOf(kp);
    final rid = Random().nextInt(0x7FFFFFFF) + 1;
    _outgoingReqs[peerId] = (kp: kp, id: rid, at: DateTime.now());
    for (var i = 0; i < 3; i++) {
      if (_outgoingReqs[peerId]?.id != rid) return;
      await manager.sendControlTo(
        peerId,
        ControlMessage(
          ControlKind.friendReq,
          to: peerId,
          name: name,
          id: rid,
          x: {'pk': pk},
        ),
      );
      if (i == 0) _notice('Friend request sent to ${nameOf(peerId)}.');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
  }

  Future<void> _onFriendControl(InboundControl c) async {
    final m = c.message;
    final rid = m.id;
    final pk = m.x['pk'];
    switch (m.kind) {
      case ControlKind.friendReq:
        if (rid == null || pk is! String) return;
        if (friendRequests.any((r) => r.from == c.peerId && r.id == rid)) {
          return;
        }
        friendRequests.removeWhere((r) => r.from == c.peerId);
        final r = FriendRequest(
          from: c.peerId,
          name: (m.name?.isNotEmpty ?? false) ? m.name! : nameOf(c.peerId),
          id: rid,
          publicKey: pk,
          at: DateTime.now(),
        );
        friendRequests.add(r);
        if (!_friendRequestStream.isClosed) _friendRequestStream.add(r);
        if (!foreground) {
          await bridge.showInfo(
            nid: 0x30000 + (c.peerId & 0xFFFF),
            title: 'Friend request from ${r.name}',
            text: 'Open Walkie Talkie to accept or decline.',
          );
        }
        notifyListeners();
      case ControlKind.friendAcc:
        final o = _outgoingReqs[c.peerId];
        if (o == null || o.id != rid || pk is! String) return;
        _outgoingReqs.remove(c.peerId);
        final key = await PairKey.agree(o.kp, pk, nodeId, c.peerId);
        await _addFriend(
          c.peerId,
          (m.name?.isNotEmpty ?? false) ? m.name! : nameOf(c.peerId),
          key,
        );
        _notice(
          '${nameOf(c.peerId)} accepted. Safety code ${key.safetyCode} '
          '(should match on both phones).',
        );
      case ControlKind.friendDec:
        final o = _outgoingReqs[c.peerId];
        if (o == null || o.id != rid) return;
        _outgoingReqs.remove(c.peerId);
        _notice('${nameOf(c.peerId)} declined the friend request.');
      default:
        return;
    }
  }

  /// Answer a friend request. Returns the safety code when accepted.
  Future<String?> answerFriendRequest(FriendRequest r, bool accept) async {
    friendRequests.remove(r);
    notifyListeners();
    if (!accept) {
      await manager.sendControlTo(
        r.from,
        ControlMessage(ControlKind.friendDec, to: r.from, id: r.id),
      );
      return null;
    }
    final kp = await PairKey.newKeyPair();
    final pk = await PairKey.publicKeyOf(kp);
    final key = await PairKey.agree(kp, r.publicKey, nodeId, r.from);
    final msg = ControlMessage(
      ControlKind.friendAcc,
      to: r.from,
      name: name,
      id: r.id,
      x: {'pk': pk},
    );
    await _addFriend(r.from, r.name, key);
    for (var i = 0; i < 3; i++) {
      await manager.sendControlTo(r.from, msg);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return key.safetyCode;
  }

  Future<void> _addFriend(int id, String name, PairKey key) async {
    settings.friends.removeWhere((f) => f.id == id);
    settings.friends.add(
      Friend(id: id, name: name, key: key, added: DateTime.now()),
    );
    friendLinks.setFriends(settings.friends);
    await settingsStore.save(settings);
    unawaited(friendLinks.sendPresence());
    notifyListeners();
  }

  Future<void> removeFriend(int id) async {
    settings.friends.removeWhere((f) => f.id == id);
    friendLinks.setFriends(settings.friends);
    await settingsStore.save(settings);
    notifyListeners();
  }

  PairKey? _qrPending;
  Timer? _qrExpiry;

  /// Text for "my friend QR": valid for 10 minutes, for one scan.
  String friendQrText({Duration validFor = const Duration(minutes: 10)}) {
    final code = PairKey.randomSecret();
    final key = PairKey.fromQrCode(code, nodeId);
    final old = _qrPending;
    if (old != null) friendLinks.removePending(old);
    _qrPending = key;
    friendLinks.addPending(key);
    unawaited(friendLinks.sendPresence());
    _qrExpiry?.cancel();
    _qrExpiry = Timer(validFor, () {
      friendLinks.removePending(key);
      if (_qrPending == key) _qrPending = null;
    });
    return PairKey.qrText(ownerId: nodeId, ownerName: name, code: code);
  }

  /// Someone's friend QR was scanned. Returns an error text, or null.
  Future<String?> addFriendFromQr(String text) async {
    final q = PairKey.parseQr(text);
    if (q == null) return 'That is not a Walkie Talkie friend code.';
    if (q.id == nodeId) return 'That is your own code.';
    await _addFriend(
      q.id,
      q.name.isEmpty ? callSignFor(q.id) : q.name,
      PairKey.fromQrCode(q.code, q.id),
    );
    _notice('Added ${q.name}. They see you as soon as you are both online.');
    return null;
  }

  Future<void> _onPaired((int, String, PairKey) e) async {
    final (id, n, key) = e;
    friendLinks.removePending(key);
    if (_qrPending == key) _qrPending = null;
    await _addFriend(id, n.isEmpty ? callSignFor(id) : n, key);
    _notice(
      '${n.isEmpty ? callSignFor(id) : n} scanned your code: friends now.',
    );
  }

  String friendName(int id) => friendLinks.friend(id)?.name ?? nameOf(id);

  // ------------------------------------------------- private talk (1:1)

  /// Friend we are talking to privately right now.
  int? privateTalkTo;
  final Map<int, Timer> _friendTalkTimers = {};

  /// Friends whose private talk is playing now.
  Set<int> get friendsTalking => _friendTalkTimers.keys.toSet();

  Future<void> talkToFriend(int id, bool down) async {
    if (down) {
      if (transmitting || recording != null) return;
      // Private talk only ever goes out sealed with the pair key over the
      // friend link; there is no fallback to the channel.
      if (!canTalkPrivately(id)) {
        _notice(
          friendLinks.isFriend(id) && friendLinks.radioPathTo(id)
              ? '${friendName(id)} is only reachable over the radio: send a '
                    'voice message (up to 8 s) instead.'
              : friendLinks.isFriend(id)
              ? '${friendName(id)} is out of reach. Send a voice message '
                    "instead: it will send when they're back."
              : 'No Direct chat with ${friendName(id)} yet: you are not '
                    'friends on both phones.',
        );
        return;
      }
      if (friendLinks.needsUpdate(id)) {
        // Older apps answer private talk with their big button, which
        // goes to the whole channel.
        _notice(
          '${friendName(id)} needs to update the app to use Direct chat talk.',
        );
        return;
      }
      privateTalkTo = id;
      transmitting = true;
      _stopReplay();
      _audio.stopClip();
      playingKey = null;
      notifyListeners();
      try {
        await _audio.startTransmit(_sendPrivate);
      } catch (e) {
        error = 'Mic error: $e';
        privateTalkTo = null;
        transmitting = false;
        notifyListeners();
      }
    } else {
      if (privateTalkTo == null) return;
      try {
        await _audio.stopTransmit(_sendPrivate);
      } catch (_) {}
      privateTalkTo = null;
      transmitting = false;
      talkLatched = false;
      notifyListeners();
    }
  }

  /// The friend is paired (pair key) and reachable on a path that carries
  /// live audio (a direct link or the phone mesh; never the radio).
  bool canTalkPrivately(int id) =>
      friendLinks.friend(id) != null && friendLinks.canTalkLive(id);

  void _sendPrivate(Uint8List opus) {
    final id = privateTalkTo;
    if (id == null || !transmitting) return;
    manager.noteTraffic();
    unawaited(
      friendLinks.send(
        id,
        friendLinks.frame(
          FrameType.audio,
          opus,
          seq: friendLinks.nextAudioSeq(),
        ),
      ),
    );
  }

  void _onFriendFrame(FriendInbound f) {
    manager.noteTraffic(); // friend talk / chat: leave idle at once
    if (f.frame.type != FrameType.audio) return;
    final id = f.friendId;
    final why = liveGate.admit(-1 - id, f.frame.payload, talking: null);
    if (why != null) {
      playbackLog.stream(
        'fr$id',
        'private-blocked',
        '${friendName(id)} #$id via ${f.via.name}: $why',
      );
      return;
    }
    if (transmitting || recording != null || isMuted(id)) return;
    if (!settings.autoPlay) {
      playbackLog.stream(
        'fr$id',
        'private-held',
        '${friendName(id)} #$id: auto-play off',
      );
      return;
    }
    playbackLog.stream(
      'fr$id',
      'private',
      '${friendName(id)} #$id via ${f.via.name}',
    );
    _lastLiveAt = DateTime.now();
    if (_audio.playingClip) {
      _stopReplay();
      _audio.stopClip();
      playingKey = null;
    }
    final isNew = !_friendTalkTimers.containsKey(id);
    _friendTalkTimers[id]?.cancel();
    _friendTalkTimers[id] = Timer(const Duration(milliseconds: 800), () {
      _friendTalkTimers.remove(id);
      _audio.peerStopped(id);
      bridge.cancelTalking(id);
      if (_talkingPrev.isEmpty && _friendTalkTimers.isEmpty) {
        _audio.setFocus(false);
      }
      notifyListeners();
    });
    if (isNew) {
      _audio.setFocus(true);
      if (!foreground) {
        bridge.showTalking(
          peer: id,
          name: friendName(id),
          channel: channel,
          friend: true,
        );
      }
      notifyListeners();
    }
    if (privateReply.target != id) {
      privateReply.heard(id);
      notifyListeners();
    } else {
      privateReply.heard(id);
    }
    _audio.play(id, f.frame.seq, f.frame.payload);
  }

  // ---------------------------------------------------------------- chat

  /// Chat for the current channel.
  String get channelChat => channelConversation(scope);

  int get unreadChannelChat => chats?.unread(channelChat) ?? 0;
  int unreadFriendChat(int id) => chats?.unread(friendConversation(id)) ?? 0;
  int get unreadFriendChats =>
      chats?.unreadWhere((c) => c.startsWith('f')) ?? 0;

  List<ChatMessage> chatMessages(String conv) =>
      chats?.messages(conv) ?? const [];

  Future<void> markChatRead(String conv) async {
    final store = chats;
    if (store == null) return;
    await store.markRead(conv);
    // Read receipts (v1.8.3): the friend's messenger for friend chats.
    final list = await store.takeUnreceipted(conv);
    if (!settings.readReceipts || list.isEmpty) return;
    final m = friendOf(conv) != null ? friendMessenger : messenger;
    for (final x in list) {
      m?.markRead(x.sender, x.id);
    }
  }

  int? friendOf(String conv) =>
      conv.startsWith('f') ? int.tryParse(conv.substring(1)) : null;

  String chatTitle(String conv) {
    final f = friendOf(conv);
    if (f != null) return friendName(f);
    final s = int.tryParse(conv.substring(1)) ?? 0;
    if (s == scope) return channelTitle;
    final n = channelNameOf(s);
    return n != null ? '${n.emoji} ${n.name}'.trim() : labelFor(s);
  }

  /// Phones here that cannot see chats (older app versions).
  List<Peer> get peersWithoutChat => [
    for (final p in peers)
      if (p.channel == scope && !p.supportsChat) p,
  ];

  Future<ChatMessage?> _sendChat(
    String conv,
    ChatBody body, {
    ChatBody? bleBody,
    bool quiet = false,
  }) async {
    final friend = friendOf(conv);
    final m = friend != null ? friendMessenger : messenger;
    final store = chats;
    if (m == null || store == null) return null;
    if (friend == null && conv != channelChat) {
      _notice('Switch to that channel to chat there.');
      return null;
    }
    final e = await m.sendChat(
      body,
      toPeer: friend,
      channel: friend != null ? friendScope : scope,
      bleBody: bleBody,
    );
    final msg = ChatMessage.fromBody(
      body,
      id: e.msgId,
      sender: nodeId,
      senderName: name,
      mine: true,
      at: DateTime.now(),
    );
    await store.add(conv, msg, photo: body.data);
    if (!quiet) {
      if (friend != null && !friendLinks.isOnline(friend)) {
        _notice(
          "${friendName(friend)} is out of reach: your message will send when "
          "they're back (up to 24 h).",
        );
      } else if (friend == null && e.recipients.isEmpty) {
        _notice(
          peersWithoutChat.isNotEmpty
              ? 'Saved. Phones here need app 1.5 or newer to see chats.'
              : 'Saved. It is delivered to the first phones on $channelTitle '
                    '(up to 24 h).',
        );
      }
    }
    notifyListeners();
    return msg;
  }

  Future<void> sendChatText(String conv, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _sendChat(
      conv,
      ChatBody.text(
        t.length > 2000 ? t.substring(0, 2000) : t,
        sentAt: DateTime.now(),
      ),
    );
  }

  /// Compress (<= 150 KB) and send a photo; Bluetooth gets a thumbnail.
  Future<void> sendPhoto(String conv, Uint8List raw) async {
    final p = await preparePhoto(raw);
    if (p == null) {
      _notice('That picture could not be read.');
      return;
    }
    final body = ChatBody(
      type: ChatType.photo,
      data: p.jpeg,
      width: p.width,
      height: p.height,
      sentAt: DateTime.now(),
    );
    await _sendChat(
      conv,
      body,
      bleBody: body.copyWith(data: p.thumbnail, thumbnailOnly: true),
    );
  }

  Future<({double lat, double lng, double? acc})?> _locate() async {
    try {
      if (!await Permission.locationWhenInUse.isGranted &&
          !(await Permission.locationWhenInUse.request()).isGranted) {
        _notice('Location permission is needed to share where you are.');
        return null;
      }
    } catch (_) {}
    final l = await bridge.getLocation();
    if (l == null) _notice('Could not get your location. Is location on?');
    return l;
  }

  final Map<String, _LiveShare> _live = {};
  bool isSharingLive(String conv) => _live.containsKey(conv);
  DateTime? liveUntil(String conv) => _live[conv]?.until;

  /// Share where I am now; with [live], keep updating it every 30 s for
  /// that long (while the app runs).
  Future<void> shareLocation(String conv, {Duration? live}) async {
    final l = await _locate();
    if (l == null) return;
    if (live != null && !powerPlan.liveLocation) {
      _notice(
        'Live location is off in Offline power save. Sent where you are now.',
      );
      live = null;
    }
    if (live == null) {
      await _sendChat(
        conv,
        ChatBody(
          type: ChatType.location,
          lat: l.lat,
          lng: l.lng,
          accuracy: l.acc,
          sentAt: DateTime.now(),
        ),
      );
      return;
    }
    await stopLiveLocation(conv, announce: false);
    final share = _LiveShare(
      Random().nextInt(0x7FFFFFFF) + 1,
      DateTime.now().add(live),
    );
    _live[conv] = share;
    await _sendLive(conv, share, l);
    share.timer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (DateTime.now().isAfter(share.until) ||
          (friendOf(conv) == null && conv != channelChat)) {
        await stopLiveLocation(conv);
        return;
      }
      final l = await bridge.getLocation();
      if (l != null && _live[conv] == share) await _sendLive(conv, share, l);
    });
    notifyListeners();
  }

  Future<void> _sendLive(
    String conv,
    _LiveShare s,
    ({double lat, double lng, double? acc}) l, {
    DateTime? until,
  }) async {
    // Only the newest position matters: drop an older update that has
    // not gone out yet.
    final prev = s.lastMsgId;
    if (prev != null) {
      final m = friendOf(conv) != null ? friendMessenger : messenger;
      final e = m?.outbox.byId(prev);
      if (e != null && e.delivered.isEmpty) await m!.cancel(prev);
    }
    final msg = await _sendChat(
      conv,
      ChatBody(
        type: ChatType.location,
        lat: l.lat,
        lng: l.lng,
        accuracy: l.acc,
        liveUntil: until ?? s.until,
        liveId: s.liveId,
        sentAt: DateTime.now(),
      ),
      quiet: s.lastMsgId != null,
    );
    s.lastMsgId = msg?.id;
    s.last = l;
  }

  Future<void> stopLiveLocation(String conv, {bool announce = true}) async {
    final s = _live.remove(conv);
    if (s == null) return;
    s.timer?.cancel();
    final l = s.last;
    if (announce && l != null) {
      await _sendLive(conv, s, l, until: DateTime.now());
    }
    notifyListeners();
  }

  Future<void> openMap(ChatMessage m) async {
    final url = m.mapsUrl;
    if (url == null) return;
    if (!await bridge.openUrl(url)) _notice(url);
  }

  Future<Uint8List?> chatPhoto(ChatMessage m) =>
      chats?.photo(m) ?? Future.value(null);

  Future<void> _onChat(ChatArrival a, {required bool friend}) async {
    final store = chats;
    if (store == null) return;
    final conv = friend
        ? friendConversation(a.sender)
        : channelConversation(a.channel);
    final name = friend
        ? friendName(a.sender)
        : (a.senderName.isEmpty ? nameOf(a.sender) : a.senderName);
    final m = ChatMessage.fromBody(
      a.body,
      id: a.msgId,
      sender: a.sender,
      senderName: name,
      mine: false,
      at: a.body.sentAt != null && a.body.liveId != null
          ? a.body.sentAt!
          : a.receivedAt,
      viaRadio: a.viaRadio,
    );
    final lid = a.body.liveId;
    final update = lid != null && store.hasLive(a.sender, lid);
    final isNew = await store.add(conv, m, photo: a.body.data);
    if (!isNew || update) {
      notifyListeners();
      return;
    }
    if (openChat != conv) {
      final what = switch (a.body.type) {
        ChatType.text => a.body.text,
        ChatType.photo => 'Photo',
        ChatType.location =>
          a.body.liveUntil != null ? 'Live location' : 'Location',
      };
      if (foreground) {
        _notice('$name: $what');
      } else {
        await bridge.showInfo(
          nid: 0x20000 + (a.sender & 0xFFFF),
          title: friend ? '$name (Direct chat)' : '$name on ${chatTitle(conv)}',
          text: what.length > 120 ? '${what.substring(0, 120)}...' : what,
        );
      }
    }
    notifyListeners();
  }

  /// Conversation on screen now (no notices for it).
  String? openChat;

  // ---------------------------------------------------------------- settings

  Future<void> setChannel(int ch) async {
    final token = ++_channelToken;
    final pass = settings.passcodeFor(ch);
    ChannelKey? key;
    if (pass != null) {
      final cacheKey = '$ch\u0000$pass';
      key = _keys[cacheKey];
      if (key == null) {
        switchingChannel = true;
        notifyListeners();
        try {
          key = await ChannelKey.derive(ch, pass);
          _keys[cacheKey] = key;
        } finally {
          if (token == _channelToken) switchingChannel = false;
        }
      }
    }
    if (token != _channelToken) return; // a newer switch won
    await manager.setChannel(ch, key: key);
    listenerWatch.clear();
    hiddenListeners = 0;
    _joinQuietUntil = DateTime.now().add(const Duration(seconds: 8));
    debugLog.add(
      'channel',
      'CH $ch${key != null ? ' (private group, room ${RelayTransport.roomFor(manager.scope)})' : ''}',
    );
    whosWhere.announceSoon();
    _left.clear(); // a private switch forgets everyone; not "left"

    settings.channel = ch;
    unawaited(settingsStore.save(settings));
    _updateServiceText();
    notifyListeners();
  }

  /// Make [ch] private with [passcode], or public again with null. Applies
  /// right away when [ch] is the current channel.
  /// [makeAdmin]: I am setting this channel up and become its admin
  /// (can rename it, remove people and turn on announcement mode).
  Future<void> setChannelPrivacy(
    int ch,
    String? passcode, {
    bool makeAdmin = false,
  }) async {
    final p = passcode == null ? null : ChannelKey.normalize(passcode);
    if (p == null || p.isEmpty) {
      settings.privateChannels.remove(ch);
    } else {
      settings.privateChannels[ch] = p;
    }
    await settingsStore.save(settings);
    if (ch == channel) {
      await setChannel(ch);
      if (makeAdmin && isPrivate) await claimAdmin();
    } else {
      notifyListeners();
    }
  }

  /// Empty resets to the call sign.
  void setName(String n) {
    final t = n.trim();
    settings.customName = t.isEmpty ? null : t;
    _applyName();
  }

  /// New random-looking call sign (only shown if no custom name is set).
  void rerollCallSign() {
    settings.callSignSalt++;
    _applyName();
  }

  void _applyName() {
    name = settings.name;
    manager.localName = name;
    if (started) {
      manager.sendHello();
      whosWhere.announceSoon();
    }
    unawaited(settingsStore.save(settings));
    notifyListeners();
  }

  /// Comma separated relay URLs, "off" to disable, empty for the default.
  Future<void> setRelayUrl(String url) async {
    final t = url.trim();
    if (t == (settings.relayUrl?.trim() ?? '')) return;
    settings.relayUrl = t.isEmpty ? null : t;
    unawaited(settingsStore.save(settings));
    await _relay.setServerUris(relayUrisFor(settings));
    await whosWhere.setRelayFactory(_lobbyRelayFactory(relayUrisFor(settings)));
    notifyListeners();
  }

  void _notice(String s) {
    if (!_notices.isClosed) _notices.add(s);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final t in _timers) {
      t.cancel();
    }
    for (final t in _ringTimers.values) {
      t.cancel();
    }
    _talkLimit?.cancel();
    _qrExpiry?.cancel();
    unawaited(debugLog.close());
    for (final t in _friendTalkTimers.values) {
      t.cancel();
    }
    for (final l in _live.values) {
      l.timer?.cancel();
    }
    trip?.dispose();
    friendLinks.dispose();
    friendMessenger?.dispose();
    chats?.dispose();
    _friendRequestStream.close();
    history?.dispose();
    _lifecycle?.dispose();
    messenger?.dispose();
    ringer.dispose();
    whosWhere.removeListener(notifyListeners);
    whosWhere.dispose();
    manager.dispose();
    radioDevice.dispose();
    _audio.dispose();
    _notices.close();
    _uiRequests.close();
    super.dispose();
  }
}

/// The Trip tab's view of the app.
class _WalkieTripHost implements TripHost {
  _WalkieTripHost(this.c);
  final WalkieController c;
  bool _askedLocation = false;

  @override
  int get localId => c.nodeId;
  @override
  int get scope => c.scope;
  @override
  bool get privateScope => c.isPrivate;
  @override
  String nameOf(int id) => c.nameOf(id);
  @override
  bool get powerSaver => c.settings.powerSaver;

  @override
  Future<Set<int>> sendTrip(Uint8List payload, TripRoute r) =>
      c.manager.sendTrip(
        payload,
        to: r.to,
        fast: r.fast,
        radio: r.radio,
        flood: r.flood,
      );

  @override
  Stream<InboundTrip> get trips => c.manager.trips;

  @override
  List<TripPeer> channelPeers() => [
    for (final p in c.peers)
      if (p.channel == c.scope)
        TripPeer(
          p.id,
          lastHeard: [
            ...p.lastSeen.values,
            ?p.meshSeen,
          ].fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a),
          reachable: c.manager.isReachable(p.id),
        ),
  ];

  @override
  Future<void> saveTripSettings() => c.settingsStore.save(c.settings);

  Future<bool> _permission() async {
    try {
      if (await Permission.locationWhenInUse.isGranted) return true;
      if (_askedLocation) return false;
      _askedLocation = true;
      return (await Permission.locationWhenInUse.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> startLocation(Duration interval) async {
    if (!await _permission()) return false;
    return c.bridge.startLocationUpdates(interval);
  }

  @override
  Future<void> stopLocation() => c.bridge.stopLocationUpdates();

  @override
  Future<Fix?> locateOnce() async {
    final l = await c._locate();
    if (l == null) return null;
    return Fix(GeoPoint(l.lat, l.lng), DateTime.now(), accuracyM: l.acc);
  }

  @override
  Future<void> backgroundLocation(bool on) => c.bridge.setServiceLocation(on);

  @override
  void showSosAlarm(IncomingSos s, String text) {
    // v1.9.5: an SOS is urgent; it only stays quiet when "Let urgent rings
    // through" is off during mute / quiet hours.
    if (!c.quiet.ringSounds(from: s.origin, ringId: s.id, urgent: true)) {
      unawaited(
        c.bridge.showInfo(
          nid: 7000000 + (s.id & 0xFFFF),
          title: 'SOS from ${c.nameOf(s.origin)} (muted)',
          text: text,
        ),
      );
      return;
    }
    unawaited(
      c.bridge.showSos(
        from: s.origin,
        id: s.id,
        name: c.nameOf(s.origin),
        text: text,
      ),
    );
  }

  @override
  void stopSosAlarm(IncomingSos s) =>
      unawaited(c.bridge.stopSos(from: s.origin, id: s.id));

  @override
  void notify(String title, String text) {
    if (c.foreground) {
      c._notice('$title: $text');
    } else {
      unawaited(
        c.bridge.showInfo(
          nid: 8000000 + (title.hashCode & 0xFFFF),
          title: title,
          text: text,
        ),
      );
    }
  }

  @override
  void notice(String text) => c._notice(text);

  @override
  Future<bool> shareFile(String path, String mime, String title) =>
      c.bridge.shareFile(path, mime: mime, title: title);
}
