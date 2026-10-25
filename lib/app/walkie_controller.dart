import 'dart:async';
import 'dart:io' show Directory, Platform, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio/audio_engine.dart';
import '../core/channel_crypto.dart';
import '../core/frame.dart';
import '../core/peer.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
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
import 'settings.dart';

/// Voice message being recorded.
class Recording {
  Recording(this.toPeer, this.startedAt);
  final int? toPeer;
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
      final others = up.length > 1 ? ' +${up.length - 1} more' : '';
      return (
        status: TransportStatus.running,
        text:
            'Internet: connected${r.network != null ? ' via ${r.network}' : ''}'
            ' (${host(r)}$others)',
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
  List<InboxEntry> get inbox => messenger?.inbox.entries ?? const [];
  int get unplayedMessages => messenger?.inbox.unplayed ?? 0;
  List<OutgoingStatus> get outgoing => messenger?.outgoing ?? const [];
  List<OutboxEntry> get waitingForAnyone =>
      messenger?.waitingForAnyone ?? const [];

  int? get talkingPeer {
    for (final p in peers) {
      if (p.talking && p.channel == scope) return p.id;
    }
    return null;
  }

  String nameOf(int peerId) =>
      manager.peer(peerId)?.displayName ?? callSignFor(peerId);

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
    try {
      await _audio.init();
    } catch (e) {
      error = 'Audio init failed: $e';
    }
    _subs.add(manager.peerChanges.listen(_onPeers));
    _subs.add(manager.transportChanges.listen((_) => notifyListeners()));
    _subs.add(
      manager.audio.listen((a) {
        if (transmitting || recording != null) return;
        if (_audio.playingClip) {
          _audio.stopClip();
          playingKey = null;
        }
        _audio.play(a.peerId, a.seq, a.opus);
      }),
    );
    await manager.start();

    // Voice messages.
    try {
      final m = Messenger(
        link: ManagerMessengerLink(manager),
        storage: FileMessageStorage(await _messageDir()),
      );
      await m.start();
      messenger = m;
      _subs.add(m.received.listen(_onVoiceMessage));
      _subs.add(
        m.delivered.listen(
          (d) => _notice('Voice message delivered to ${nameOf(d.$2)}'),
        ),
      );
      _subs.add(m.changes.listen((_) => notifyListeners()));
    } catch (e) {
      error = 'Voice messages unavailable: $e';
    }

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

    await applyBackgroundSettings();
    notifyListeners();
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
      );
      _serviceText = '$_serviceTitle|$_serviceBody';
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
    final t = '$_serviceTitle|$_serviceBody';
    if (t == _serviceText) return;
    _serviceText = t;
    bridge.updateService(title: _serviceTitle, text: _serviceBody);
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
      case 'stop':
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
        final e = messenger?.inbox.byKey(a['key'] as String? ?? '');
        if (e != null) await playMessage(e);
      case 'openInbox':
        _uiRequests.add('inbox');
    }
  }

  // --------------------------------------------------------------- peers

  void _onPeers(List<Peer> list) {
    for (final p in list) {
      if (!p.talking) _audio.peerStopped(p.id);
    }
    peers = list;
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
    if (down == transmitting) return;
    if (down && recording != null) return;
    transmitting = down;
    notifyListeners();
    try {
      if (down) {
        _audio.stopClip();
        playingKey = null;
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

  // ---------------------------------------------------------------- rings

  /// Ring one phone, or everyone on the channel when [toPeer] is null.
  Future<void> ring({int? toPeer, bool beep = false}) async {
    final r = await ringer.ring(toPeer: toPeer, beep: beep);
    final what = beep ? 'Beep' : 'Ring';
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
    );
    _ringTimers[(r.from, r.id)] = Timer(ringDuration, () async {
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

  Future<void> startRecording({int? toPeer}) async {
    if (recording != null || transmitting) return;
    final rec = Recording(toPeer, DateTime.now());
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
    final m = messenger;
    if (m == null) return;
    final e = await m.send(clip, toPeer: rec.toPeer, channel: scope);
    final who = rec.toPeer == null ? channelLabel : nameOf(rec.toPeer!);
    final reachable = rec.toPeer == null
        ? e.recipients.isNotEmpty
        : manager.isReachable(rec.toPeer!);
    _notice(
      reachable
          ? 'Sending voice message (${formatDuration(clip.durationMs)}) to $who'
          : 'Saved. It will be delivered to $who when they are in range (up to 24 h).',
    );
  }

  void _onVoiceMessage(InboxEntry e) {
    final name = e.senderName.isEmpty ? nameOf(e.sender) : e.senderName;
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

  Future<void> playMessage(InboxEntry e) async {
    final m = messenger;
    if (m == null || transmitting || recording != null) return;
    final body = await m.bodyOf(e);
    final clip = body == null ? null : VoiceClip.tryDecode(body);
    if (clip == null) {
      _notice('That message could not be played.');
      return;
    }
    playingKey = e.key;
    await m.markPlayed(e);
    notifyListeners();
    await _audio.playClip(clip.packets);
    if (playingKey == e.key) playingKey = null;
    if (_talkingPrev.isEmpty) await _audio.setFocus(false);
    notifyListeners();
  }

  void stopPlayback() {
    _audio.stopClip();
    playingKey = null;
    notifyListeners();
  }

  Future<void> deleteMessage(InboxEntry e) async {
    if (playingKey == e.key) stopPlayback();
    await messenger?.deleteReceived(e);
    notifyListeners();
  }

  Future<void> cancelOutgoing(int msgId) async {
    await messenger?.cancel(msgId);
    notifyListeners();
  }

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
    settings.channel = ch;
    unawaited(settingsStore.save(settings));
    _updateServiceText();
    notifyListeners();
  }

  /// Make [ch] private with [passcode], or public again with null. Applies
  /// right away when [ch] is the current channel.
  Future<void> setChannelPrivacy(int ch, String? passcode) async {
    final p = passcode == null ? null : ChannelKey.normalize(passcode);
    if (p == null || p.isEmpty) {
      settings.privateChannels.remove(ch);
    } else {
      settings.privateChannels[ch] = p;
    }
    await settingsStore.save(settings);
    if (ch == channel) {
      await setChannel(ch);
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
