import 'dart:async';
import 'dart:io' show Directory, File, Platform, exit;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart' show SimpleKeyPair;
import 'package:permission_handler/permission_handler.dart';

import '../audio/audio_engine.dart';
import '../audio/live_gate.dart';
import '../chat/chat_body.dart';
import '../chat/chat_store.dart';
import '../chat/photo.dart';
import '../core/channel_crypto.dart';
import '../core/frame.dart';
import '../core/pair_key.dart';
import '../core/peer.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
import '../friends/friend_links.dart';
import '../friends/friend_messenger_link.dart';
import '../history/talk_history.dart';
import '../messaging/inbox.dart';
import '../messaging/messenger.dart';
import '../messaging/outbox.dart';
import '../messaging/ringer.dart';
import '../messaging/storage.dart';
import '../messaging/voice_clip.dart';
import '../platform/background_bridge.dart';
import '../transports/ble_transport.dart';
import '../transports/lan_transport.dart';
import '../transports/mdns_discovery.dart';
import '../transports/relay_socket.dart';
import '../transports/relay_transport.dart';
import 'call_signs.dart';
import 'config.dart';
import 'playback_log.dart';
import 'settings.dart';

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
       ) {
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
      channelKey: channelKey,
    );
    if (channelKey != null) {
      _keys['${channelKey.channel}\u0000${settings.passcodeFor(channelKey.channel)}'] =
          channelKey;
    }
    ringer = Ringer(link: ManagerRingLink(manager));
    manager.helloExtras = _helloExtras;
    manager.blocked.addAll(settings.blocked.keys);
    final relays = relayUrisFor(settings);
    friendLinks = FriendLinks(
      localId: nodeId,
      radio: ManagerFriendRadio(manager),
      localName: () => name,
      relayFactory: relays.isEmpty
          ? null
          : (room) => RelayTransport(
              serverUri: relays.first,
              connector: RelayConnector.platform(),
              room: room,
            ),
    );
    friendLinks.setFriends(settings.friends);
    manager.sealedHandler = friendLinks.handle;
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
  static List<Uri> relayUrisFor(AppSettings s) {
    final saved = s.relayUrl?.trim() ?? '';
    return MultiRelayTransport.parseList(
      saved.isEmpty ? AppConfig.relayUrl : saved,
    );
  }

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
  final MultiRelayTransport _relay;
  final AudioEngine _audio = AudioEngine();
  final BackgroundBridge bridge = BackgroundBridge();
  final List<StreamSubscription<dynamic>> _subs = [];
  final List<Timer> _timers = [];
  AppLifecycleListener? _lifecycle;
  int _micOrphanTicks = 0;

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

  /// e.g. "CH 3" or "CH 3 (private)".
  String get channelLabel => 'CH $channel${isPrivate ? ' (private)' : ''}';

  /// Label for a scope stored with a ring / message.
  String labelFor(int scope) {
    if (scope == friendScope) return 'private (friend)';
    if (!TransportManager.isPrivateScope(scope)) return 'CH $scope';
    return scope == this.scope ? channelLabel : 'a private channel';
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
  ({TransportStatus status, String text}) get internetStatus {
    final rs = _relay.relays;
    if (rs.isEmpty) {
      return (
        status: TransportStatus.unavailable,
        text: 'Internet: off (no relay set in Settings)',
      );
    }
    String host(RelayTransport r) => r.serverUri?.host ?? '';
    final up = rs.where((r) => r.status == TransportStatus.running).toList();
    if (up.isNotEmpty) {
      final r = up.first;
      final others = up.length > 1 ? ' (${up.length} relays)' : '';
      return (
        status: TransportStatus.running,
        text:
            'Internet: connected${r.network != null ? ' via ${r.network}' : ''}'
            '$others',
      );
    }
    final starting = rs.where((r) => r.status == TransportStatus.starting);
    if (starting.isNotEmpty) {
      return (
        status: TransportStatus.starting,
        text:
            'Internet: connecting... (${starting.first.statusDetail ?? host(starting.first)})',
      );
    }
    final r = rs.first;
    final why = r.lastError ?? r.statusDetail ?? 'not connected';
    final retry = r.retryIn;
    return (
      status: TransportStatus.error,
      text:
          'Internet: offline ($why)${retry != null ? ', retrying in ${retry.inSeconds}s' : ''}',
    );
  }

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
    _subs.add(manager.transportChanges.listen((_) => notifyListeners()));
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
          heard: live && foreground && auto,
        );
        if (!live) return;
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
    await manager.start();
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
    } catch (_) {}

    // Voice messages.
    try {
      final m = Messenger(
        link: ManagerMessengerLink(manager),
        storage: FileMessageStorage(await _messageDir()),
      );
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
      Timer.periodic(const Duration(seconds: 5), (_) => _updateServiceText()),
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

    await applyBackgroundSettings();
    await _applyPttConfig();
    notifyListeners();
  }

  void _wireMessenger(Messenger m, {required bool friend}) {
    m.alreadyHaveChat = (s, id) => chats?.contains(s, id) ?? false;
    _subs.add(m.received.listen(_onVoiceMessage));
    _subs.add(m.chats.listen((a) => unawaited(_onChat(a, friend: friend))));
    _subs.add(
      m.delivered.listen((d) {
        if (d.$1.isChat) {
          unawaited(chats?.markDelivered(nodeId, d.$1.msgId, d.$2));
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

  Future<void> _requestPermissions() async {
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
    } else {
      await bridge.stopService();
      serviceRunning = false;
    }
    notifyListeners();
  }

  String get _serviceTitle => 'Walkie Talkie is listening on $channelLabel';
  String get _serviceBody {
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
    if (s != AppLifecycleState.detached) _wasVisible = true;
    if (foreground && !wasForeground) {
      for (final id in _talkingPrev) {
        bridge.cancelTalking(id);
      }
      if (settings.stayReachable) unawaited(applyBackgroundSettings());
      unawaited(_applyPttConfig());
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
        _uiRequests.add('inbox');
      case 'hwKey':
        await onHardwareKey(a['src'] as String? ?? '', a['down'] == true);
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
    await pushToTalk(on);
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
      await pushToTalk(false);
    } else {
      await pushToTalk(true);
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
    _adoptChannelInfo(list);
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
    if (r.beep) {
      bridge.beep(from: r.from, name: from, notify: !foreground);
      if (foreground) _notice('$from beeped you');
      return;
    }
    activeRings.add(r);
    bridge.showRing(
      from: r.from,
      id: r.id,
      name: from,
      channel: displayChannel(r.channel),
      urgent: r.urgent,
      loud: settings.urgentLoud,
    );
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
    final e = await m.send(
      clip,
      toPeer: rec.toPeer,
      channel: rec.toFriend ? friendScope : scope,
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
    if (foreground) {
      _notice('Voice message from $name (${formatDuration(e.durationMs)})');
    }
    bridge.showVoiceMessage(
      key: e.key,
      nid: e.notificationId,
      name: name,
      duration: formatDuration(e.durationMs),
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
    notifyListeners();
    await _audio.playClip(clip.packets, fromPeer: e.sender);
    if (playingKey == e.key) playingKey = null;
    if (_talkingPrev.isEmpty) await _audio.setFocus(false);
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
      if (n != null && !n.isEmpty) ...{
        'cn': n.name,
        'ce': n.emoji,
        'ct': n.updated,
      },
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

  /// Remove [peerId] from this private channel: everyone else moves to a
  /// new random passcode (sent to them encrypted with the old one); the
  /// removed phone is not told it.
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
    try {
      await Future.wait([
        for (final m in members)
          () async {
            final done = Completer<void>();
            final key = rid ^ m;
            _rekeyAcks[key] = done;
            for (var i = 0; i < 10 && !done.isCompleted; i++) {
              await manager.sendControlTo(
                m,
                ControlMessage(
                  ControlKind.rekey,
                  to: m,
                  id: rid,
                  x: {
                    'pc': pass,
                    'ex': [peerId],
                  },
                ),
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
      _notice(
        missed.isEmpty
            ? 'Removed $kickedName. ${acked.length} phones moved to the new passcode.'
            : 'Removed $kickedName. Not confirmed: '
                  '${missed.map(nameOf).join(', ')}. Give them the new '
                  'passcode (tap the lock).',
      );
    } finally {
      kicking = false;
      notifyListeners();
    }
  }

  static String _randomPasscode() {
    const a = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(10, (_) => a[r.nextInt(a.length)]).join();
  }

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
    final pc = m.x['pc'];
    if (pc is! String || pc.length < 6) return;
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

  /// "Wi-Fi", "Bluetooth", "Internet" or null when offline.
  String? friendVia(int id) => switch (friendLinks.bestLink(id)) {
    TransportKind.lan => 'Wi-Fi',
    TransportKind.ble => 'Bluetooth',
    TransportKind.internet => 'Internet',
    _ => null,
  };

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
  String friendQrText() {
    final code = PairKey.randomSecret();
    final key = PairKey.fromQrCode(code, nodeId);
    final old = _qrPending;
    if (old != null) friendLinks.removePending(old);
    _qrPending = key;
    friendLinks.addPending(key);
    unawaited(friendLinks.sendPresence());
    _qrExpiry?.cancel();
    _qrExpiry = Timer(const Duration(minutes: 10), () {
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
          friendLinks.isFriend(id)
              ? 'Not connected privately yet: ${friendName(id)} is not '
                    'reachable. Send a voice message instead.'
              : 'Not connected privately yet: you are not friends on both '
                    'phones.',
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

  /// The friend is paired (pair key) and heard recently on some path.
  bool canTalkPrivately(int id) =>
      friendLinks.friend(id) != null && friendLinks.isOnline(id);

  void _sendPrivate(Uint8List opus) {
    final id = privateTalkTo;
    if (id == null || !transmitting) return;
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
        bridge.showTalking(peer: id, name: friendName(id), channel: channel);
      }
      notifyListeners();
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

  Future<void> markChatRead(String conv) async => chats?.markRead(conv);

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
          '${friendName(friend)} is offline: it is sent when they are back '
          '(up to 24 h).',
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
          title: friend ? '$name (private)' : '$name on ${chatTitle(conv)}',
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
    manager.sendHello();
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
    for (final t in _friendTalkTimers.values) {
      t.cancel();
    }
    for (final l in _live.values) {
      l.timer?.cancel();
    }
    friendLinks.dispose();
    friendMessenger?.dispose();
    chats?.dispose();
    _friendRequestStream.close();
    history?.dispose();
    _lifecycle?.dispose();
    messenger?.dispose();
    ringer.dispose();
    manager.dispose();
    _audio.dispose();
    _notices.close();
    _uiRequests.close();
    super.dispose();
  }
}
