import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../app/power_plan.dart';
import '../lora/lora_transport.dart';
import '../lora/meshtastic_proto.dart' show loraPayloadBudget;
import '../lora/meshtastic_channels.dart' show MeshChannelRef;

import 'channel_crypto.dart';
import 'link_policy.dart';
import 'lobby.dart';
import 'frame.dart';
import 'gateway_protocol.dart';
import 'mesh.dart';
import 'peer.dart';
import 'peer_box.dart';
import 'transport.dart';

/// Audio received from a peer, ready for the decoder.
class ReceivedAudio {
  ReceivedAudio(
    this.peerId,
    this.seq,
    this.opus, [
    this.transport,
    this.hops = 1,
  ]);
  final int peerId;
  final TransportKind? transport;

  /// Radio hops it travelled: 1 = direct, 2+ = relayed by other phones.
  final int hops;
  final int seq;
  final Uint8List opus;
}

/// A [FrameType.data] payload from a peer (voice message chunk / ack).
class InboundData {
  InboundData(this.peerId, this.channel, this.payload, this.transport);
  final int peerId;
  final int channel;
  final Uint8List payload;
  final TransportKind transport;
}

/// A Trip message ([FrameType.trip], v1.8.0) from a peer.
class InboundTrip {
  InboundTrip(
    this.peerId,
    this.channel,
    this.payload,
    this.transport, {
    this.hops = 1,
    this.packetId = 0,
    this.rssi,
  });
  final int peerId;

  /// Scope it was sent on (see [TransportManager.scope]).
  final int channel;
  final Uint8List payload;
  final TransportKind transport;

  /// 1 = direct, 2+ = relayed by other phones.
  final int hops;

  /// Mesh packet id of the frame as it travelled (see [meshPacketId]).
  final int packetId;
  final int? rssi;
}

/// A ring / beep / ring-ack control message from a peer.
/// A "Who's where" lobby beacon (see core/lobby.dart).
class InboundLobby {
  InboundLobby(
    this.peerId,
    this.beacon,
    this.transport, {
    this.hops = 1,
    this.rssi,
  });
  final int peerId;
  final LobbyBeacon beacon;
  final TransportKind transport;

  /// Radio hops (1 = heard directly, 2+ = passed on by the phone mesh).
  final int hops;
  final int? rssi;
}

/// A signed weather alert frame (v2.5.2, see `weather/wx_codec.dart`)
/// heard on the radio or a link. [group]: it came sealed inside the private
/// group we are in (so only its members could have sent it).
class InboundAlert {
  InboundAlert(
    this.frame,
    this.transport, {
    this.group = false,
    this.hops = 1,
    this.rssi,
  });
  final Frame frame;
  final TransportKind transport;
  final bool group;
  final int hops;
  final int? rssi;
}

/// A "who's here?" probe (v1.8.5, see [LobbyProbe]): someone refreshed
/// their people list and wants everyone to answer now.
class InboundProbe {
  InboundProbe(this.peerId, this.probe, this.transport, {this.hops = 1});
  final int peerId;
  final LobbyProbe probe;
  final TransportKind transport;
  final int hops;
}

class InboundControl {
  InboundControl(this.peerId, this.channel, this.message, this.transport);
  final int peerId;
  final int channel;
  final ControlMessage message;
  final TransportKind transport;
}

typedef Clock = DateTime Function();

/// Runs every available [Transport] at once and, per peer, routes outgoing
/// frames over the best link that is currently alive.
///
/// * Peers are learned from the sender id of any frame on any transport.
/// * A link is "alive" if we heard from that peer on that transport within
///   [linkTimeout]. Hello beacons every [helloInterval] keep links fresh.
/// * The best alive link is the one whose transport has the highest
///   [Transport.priority] (LAN > BLE > internet by default). If it goes
///   quiet, traffic fails over to the next one automatically.
/// * The same frame can arrive over several transports; it is
///   de-duplicated by (sender, seq).
/// * Route choice is re-evaluated for every frame sent, never latched.
///   When the best link has not been heard for [staleAfter] (it may be
///   dying), frames also go out on the next best link until one recovers
///   or times out (make-before-break), so walking out of range does not
///   cause a multi-second gap.
/// * Hello beacons carry our LAN endpoints, so a peer heard only over
///   Bluetooth can try direct UDP to us even when the router blocks
///   broadcast/mDNS.
/// * Ping/pong per link measures round-trip time for the debug UI.
class TransportManager {
  TransportManager({
    required List<Transport> transports,
    required this.localNodeId,
    required this.localName,
    this._channel = 1,
    ChannelKey? channelKey,
    this.linkTimeout = const Duration(seconds: 4),
    this.helloInterval = const Duration(seconds: 1),
    this.staleAfter = const Duration(milliseconds: 1600),
    this.meshTimeout = const Duration(seconds: 10),
    this.beaconInterval = const Duration(seconds: 2),
    this.radioHelloInterval = const Duration(minutes: 5),
    this.radioRingRepeat = const Duration(seconds: 20),
    MeshRouter? mesh,
    Clock? clock,
    Random? random,
  }) : _transports = List.unmodifiable(transports),
       _clock = clock ?? DateTime.now,
       _rng = random ?? Random(),
       _key = channelKey,
       mesh = mesh ?? MeshRouter(localId: localNodeId, clock: clock);

  /// Off-grid multi-hop relay (see core/mesh.dart).
  final MeshRouter mesh;

  /// Presence over a LoRa radio: one small hello this often (v1.7.0).
  final Duration radioHelloInterval;

  /// A ring / beep / ring answer with the same id goes over LoRa at most
  /// once per this (the ringer repeats every second on fast links).
  final Duration radioRingRepeat;
  final Random _rng;
  DateTime? _lastRadioHello;
  bool _radioWasRunning = false;
  Timer? _radioHelloSoon;
  final Map<String, (DateTime, int)> _radioRingSent = {};

  /// A peer heard only through the mesh counts as reachable this long.
  final Duration meshTimeout;

  /// How often we tell neighbours which phones we hear directly.
  final Duration beaconInterval;
  DateTime? _lastBeacon;

  final List<Transport> _transports;
  final int localNodeId;
  final Duration linkTimeout;

  /// Hello interval in normal mode; see [powerSaver].
  final Duration helloInterval;

  /// Battery saver: hellos every [saverHelloInterval] (announced in the
  /// hello so newer phones wait longer) and no RTT pings. Older phones
  /// still see us because they ping us every second and we answer.
  bool get powerSaver => _saver;
  bool _saver = false;
  static const saverHelloInterval = Duration(milliseconds: 2500);
  Duration get currentHelloInterval {
    if (_offline) return PowerPlan.offlineHello;
    final base = _saver ? saverHelloInterval : helloInterval;
    if (!_idleHello) return base;
    final idle = LinkPolicy.idleHelloInterval(_speed);
    return idle > base ? idle : base;
  }

  /// Hellos are on the idle (slow) cadence (set by [_applyProbePlan]).
  bool _idleHello = false;

  /// Offline power save (see [PowerPlan]): internet transports stopped,
  /// every other transport in its strongest saver, slow hellos / beacons.
  bool get offlineSaver => _offline;
  bool _offline = false;
  bool get _slow => _saver || _offline;

  /// How long [p] may stay silent before a link counts as dead: longer for
  /// phones that announced a slow (battery saver) hello.
  Duration timeoutFor(Peer p) {
    final iv = p.helloInterval;
    if (iv == null) return linkTimeout;
    final t = iv * 2.5;
    return t > linkTimeout ? t : linkTimeout;
  }

  /// Best link quiet for longer than this => also send on the runner-up.
  final Duration staleAfter;
  final Clock _clock;

  /// Display name sent in hello beacons.
  String localName;
  int _channel;

  /// Set while on a private channel: every frame we send is sealed with it,
  /// and only sealed frames that open with it are accepted.
  ChannelKey? _key;
  int _seq = 0;

  /// Audio has its own sequence so the receiver's loss concealment only
  /// sees real audio gaps (hello/ping frames used to share one counter, so
  /// every beacon looked like a lost packet and inserted extra audio,
  /// which made the speaker buffer overflow and drop frames). Starts far
  /// from the control counter to avoid clashing in v1.1.0 receivers.
  int _audioSeq = 0x8000;
  bool _running = false;
  bool _started = false;
  bool _talking = false;

  // ------------------------------------------ resilience (v1.9.8)

  /// "Max speed (more battery)" (default) or "Balanced" (Settings).
  ConnectionSpeed get speed => _speed;
  ConnectionSpeed _speed = ConnectionSpeed.maxSpeed;

  /// What the app is doing (set by the app: on screen, background); the
  /// manager itself goes to [ProbeActivity.active] while anyone talks or
  /// an urgent ring / SOS went out in the last [urgentActiveFor].
  ProbeActivity _activity = ProbeActivity.foreground;
  DateTime? _urgentAt;
  static const urgentActiveFor = Duration(seconds: 60);

  ProbeActivity get activity {
    if (_talking || _peers.values.any((p) => p.talking)) {
      return ProbeActivity.active;
    }
    final now = _clock();
    final u = _urgentAt;
    if (u != null && now.difference(u) < urgentActiveFor) {
      return ProbeActivity.active;
    }
    // v2.0.0: a missed check, a failed send or a network change: burst.
    final b = _burstUntil;
    if (b != null && now.isBefore(b)) return ProbeActivity.active;
    if (_activity == ProbeActivity.idle) {
      // Background, but something real happened lately (a conversation):
      // keep checking at the screen-on rate until it has been quiet.
      final t = _trafficAt;
      if (t != null && now.difference(t) < LinkPolicy.idleAfter) {
        return ProbeActivity.foreground;
      }
    }
    return _activity;
  }

  // ------------------------------------------ adaptive probing (v2.0.0)

  /// Last real traffic in or out: push-to-talk, audio, chat / clips, rings,
  /// beeps, SOS / Trip, friend talk. Not hellos, pings, pongs or beacons
  /// (those arrive every second from busy phones and would keep this
  /// phone awake for ever).
  DateTime? _trafficAt;
  DateTime? _burstUntil;
  DateTime? _burstEnded;

  /// Times a burst of fast probes started (tests / Details).
  int bursts = 0;

  /// Callback when the idle state changes (the app slows friend presence).
  void Function(bool idle)? onIdleChanged;

  /// Real traffic happened (the app calls this for friend talk too).
  /// Leaves idle at once.
  void noteTraffic() {
    _trafficAt = _clock();
    if (_appliedActivity == ProbeActivity.idle) _applyProbePlan();
  }

  static bool _isTraffic(Frame f) {
    switch (f.type) {
      case FrameType.audio:
      case FrameType.data:
      case FrameType.trip:
        return true;
      case FrameType.control:
        final k = f.control?.kind;
        return k == ControlKind.talkStart ||
            k == ControlKind.talkEnd ||
            k == ControlKind.ring ||
            k == ControlKind.beep ||
            k == ControlKind.ringAck ||
            k == ControlKind.friendReq ||
            k == ControlKind.friendAcc ||
            k == ControlKind.friendDec;
      default:
        return false;
    }
  }

  /// A link looks broken (a check was missed, a send failed, the network
  /// changed): every probe at full speed for [LinkPolicy.burstFor], every
  /// link pinged right now, whatever the idle state. [force] skips the
  /// cool-down (network changes).
  void _startBurst({bool force = false}) {
    if (!_running) return;
    final now = _clock();
    final b = _burstUntil;
    if (b != null && now.isBefore(b)) return; // already bursting
    final ended = _burstEnded;
    if (!force &&
        ended != null &&
        now.difference(ended) < LinkPolicy.burstCooldown) {
      return;
    }
    bursts++;
    _burstUntil = now.add(LinkPolicy.burstFor);
    _burstEnded = _burstUntil;
    _applyProbePlan();
    if (_started && !_slow) unawaited(sendPings(force: true));
  }

  ProbeActivity? _appliedActivity;
  ConnectionSpeed? _appliedSpeed;

  /// Current interval for checking idle links ([LinkPolicy.probeInterval]).
  Duration get probeInterval => LinkPolicy.probeInterval(_speed, activity);

  DateTime? _lastPings;
  Timer? _missTimer;

  /// Frames sent again on another link after a miss (tests / Details).
  int resent = 0;

  /// Times a link to some phone started failing (tests / Details).
  int degradedEvents = 0;

  /// Network changes handled (tests / Details).
  int networkChanges = 0;

  /// Recently sent frames, for resending on another link after a miss.
  final List<_RecentSend> _recent = [];

  /// Set "Max speed" / "Balanced".
  void setSpeed(ConnectionSpeed s) {
    if (s == _speed) return;
    _speed = s;
    _applyProbePlan();
  }

  /// The app moved on / off screen.
  void setActivity(ProbeActivity a) {
    if (a == _activity) return;
    _activity = a;
    _applyProbePlan();
  }

  /// Push the probe / reconnect intervals for the current activity to the
  /// transports (only when they change).
  void _applyProbePlan() {
    final a = activity;
    if (a == _appliedActivity && _speed == _appliedSpeed) return;
    final wasActive = _appliedActivity == ProbeActivity.active;
    final wasIdle = _appliedActivity == ProbeActivity.idle;
    _appliedActivity = a;
    _appliedSpeed = _speed;
    final probe = LinkPolicy.probeInterval(_speed, a);
    final cap = LinkPolicy.reconnectCap(_speed, a);
    for (final t in _transports) {
      try {
        t.setProbePlan(probe: probe, reconnectCap: cap);
      } catch (_) {}
    }
    final idle = a == ProbeActivity.idle;
    if (idle != wasIdle || (idle && !_idleHello)) {
      _idleHello = idle;
      for (final t in _transports) {
        try {
          t.setIdle(idle);
        } catch (_) {}
      }
      try {
        onIdleChanged?.call(idle);
      } catch (_) {}
      _startPruneTimer();
      if (_started) {
        // Back to full speed: say so now and go back to one hello a
        // second; going idle: slow hellos from here on.
        _startHelloTimer();
        if (!idle && !_slow) unawaited(sendHello());
      }
    }
    // Something started (talk, ring): check every link right now instead
    // of at the next tick.
    if (_started && a == ProbeActivity.active && !wasActive && !_slow) {
      unawaited(sendPings(force: true));
    } else if (_started && wasIdle && !idle && !_slow) {
      unawaited(sendPings(force: true));
    }
  }

  /// Android said the network changed (Wi-Fi or mobile data up / down,
  /// v1.9.8): reconnect now instead of waiting for a probe. Presence goes
  /// out on every link at once, every link to every phone is pinged (a
  /// link that died with the old network misses within a second and its
  /// traffic moves), and the local links look for phones again. The relays
  /// open new sockets on their own (make-before-break, see RelayTransport).
  Future<void> onNetworkChanged() async {
    if (!_running) return;
    networkChanges++;
    _startBurst(force: true);
    for (final t in _transports) {
      if (t.lowBandwidth || t.kind == TransportKind.internet) continue;
      if (t.kind == TransportKind.ble) continue; // not tied to a network
      try {
        t.kickDiscovery();
      } catch (_) {}
    }
    await sendHello();
    await sendPings(force: true);
  }

  /// Phones blocked by the user: everything from them is dropped.
  final Set<int> blocked = {};

  /// Sealed frames our channel key does not open (friend links, see
  /// FriendLinks). Return true if handled.
  bool Function(InboundFrame inbound)? sealedHandler;

  /// Extra hello fields (feature level, channel name, admin...).
  Map<String, Object?> Function()? helloExtras;

  // ------------------------------------------------ LoRa gateways (v1.9.5)

  /// Gateways that announced themselves in our relay room (the Synology
  /// "Home gateway", phones sharing their radio), by node id.
  final Map<int, GatewayInfo> _gateways = {};

  /// Phones heard through a gateway count as reachable this long (their
  /// LoRa presence comes every ~5 min), like phones heard on our own radio.
  Duration gatewayPeerTimeout = const Duration(minutes: 16);

  /// A gateway that has not announced itself for this long is gone.
  Duration gatewayTimeout = const Duration(minutes: 2);

  /// Share our paired LoRa radio with phones on the internet (v1.9.5):
  /// app frames our radio hears on our channel go into our relay room,
  /// and phones there can ask us to put frames on the air.
  bool shareRadio = true;

  /// How long a sharing phone waits before bringing a LoRa frame onto the
  /// internet, so the Home gateway (or another phone) that heard it too
  /// gets there first and we stay quiet.
  Duration gatewayForwardDelayMin = const Duration(milliseconds: 400);
  Duration gatewayForwardDelayMax = const Duration(milliseconds: 1600);

  /// Inner frame ids this phone forwarded / transmitted / saw as gateway
  /// envelopes (loop prevention and dedupe across gateways).
  final SeenIds gatewaySeenIds = SeenIds();
  DateTime? _lastGatewayHello;
  DateTime? _lastGatewayAnnounce;
  Timer? _gatewayHelloSoon;
  int gatewayForwarded = 0;
  int gatewayTransmitted = 0;

  final Map<int, Peer> _peers = {};
  final Map<int, _SeqWindow> _seen = {};
  final Map<int, _SeqWindow> _seenAudio = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _helloTimer;
  Timer? _pruneTimer;

  final _audio = StreamController<ReceivedAudio>.broadcast();
  final _data = StreamController<InboundData>.broadcast();
  final _controls = StreamController<InboundControl>.broadcast();
  final _trips = StreamController<InboundTrip>.broadcast();
  final _lobby = StreamController<InboundLobby>.broadcast();
  final _alerts = StreamController<InboundAlert>.broadcast();
  final _probes = StreamController<InboundProbe>.broadcast();
  final _peerChanges = StreamController<List<Peer>>.broadcast();
  final _transportChanges = StreamController<void>.broadcast();

  List<Transport> get transports => _transports;

  /// Channel number the user picked (1..16).
  int get channel => _channel;

  /// Private channel key, or null on a public channel.
  ChannelKey? get channelKey => _key;
  bool get isPrivate => _key != null;

  /// Identifies "where we are" for peers, rings and voice messages: the
  /// channel number on a public channel, or [privateScopeBit] | tag on a
  /// private one (never equal to a public channel number).
  int get scope => scopeFor(_channel, _key);

  static const int privateScopeBit = 0x10000;
  static int scopeFor(int channel, ChannelKey? key) =>
      key == null ? channel : (privateScopeBit | key.tag);
  static bool isPrivateScope(int scope) => scope >= privateScopeBit;

  /// Extra bytes per frame on the current channel (encryption overhead).
  int get frameOverhead => _key == null ? 0 : ChannelKey.overhead;

  /// Channel number written in outgoing frame headers.
  int get _wireChannel => _key?.tag ?? _channel;

  /// Encode [f] for the air: plain on public channels, sealed on private.
  Uint8List _wire(Frame f) => _key?.seal(f) ?? f.encode();
  bool get isRunning => _running;

  Stream<ReceivedAudio> get audio => _audio.stream;

  /// Reliable-transfer payloads ([FrameType.data]).
  Stream<InboundData> get data => _data.stream;

  /// Ring / beep / ring-ack messages.
  Stream<InboundControl> get controls => _controls.stream;

  /// Trip messages (location, SOS, pins...).
  Stream<InboundTrip> get trips => _trips.stream;

  /// "Who's where" beacons heard on the local links / phone mesh. They
  /// never create a [Peer] (people list) entry.
  Stream<InboundLobby> get lobby => _lobby.stream;

  /// Signed weather alerts heard (v2.5.2). They never create a [Peer]; the
  /// weather layer checks the signature.
  Stream<InboundAlert> get alerts => _alerts.stream;

  /// "Who's here?" probes (v1.8.5) heard on any link, the mesh or LoRa.
  Stream<InboundProbe> get probes => _probes.stream;
  Stream<List<Peer>> get peerChanges => _peerChanges.stream;
  Stream<void> get transportChanges => _transportChanges.stream;

  List<Peer> get peers {
    final list = _peers.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return List.unmodifiable(list);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    for (final t in _transports) {
      _subs.add(t.frames.listen(_onInbound));
      var last = t.status;
      _subs.add(
        t.statusChanges.listen((st) {
          _transportChanges.add(null);
          final became = st == TransportStatus.running && last != st;
          last = st;
          // v1.9.8: first success wins. A link that just came up (a relay
          // connected, Wi-Fi joined) is announced at once, so phones start
          // using it now instead of at the next hello tick.
          if (became && _started && _running) _onLinkUp(t);
        }),
      );
    }
    _applyProbePlan();
    // Start transports independently: one failing (e.g. Bluetooth off) must
    // not prevent the others from working.
    await Future.wait(
      _transports.map((t) async {
        // Offline power save: the internet relay stays off.
        if (_offline && t.kind == TransportKind.internet) return;
        try {
          await t.start(localNodeId: localNodeId, channel: scope);
        } catch (_) {
          // Transport reports its own status; keep going.
        }
      }),
    );
    _startHelloTimer();
    _startPruneTimer();
    _missTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => checkMisses(),
    );
    await sendHello();
    await sendBeacon();
    _started = true;
  }

  void _onLinkUp(Transport t) {
    if (t.lowBandwidth) return;
    unawaited(() async {
      await _safeSend(
        t,
        _wire(
          Frame.control(
            senderId: localNodeId,
            channel: _wireChannel,
            seq: _nextSeq(),
            message: _helloMessage(),
          ),
        ),
        null,
      );
      if (!_slow) await sendPings(force: true);
    }());
  }

  /// Peers are dropped and links aged every 500 ms (every 2 s while idle).
  void _startPruneTimer() {
    if (!_running) return;
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(
      _idleHello
          ? const Duration(seconds: 2)
          : const Duration(milliseconds: 500),
      (_) => prune(),
    );
  }

  void _startHelloTimer() {
    _helloTimer?.cancel();
    _helloTimer = Timer.periodic(currentHelloInterval, (_) async {
      await sendHello();
      _maybeRadioHello();
      _maybeGatewayTick();
      _applyProbePlan();
      if (!_slow) await _maybePings();
      final now = _clock();
      final last = _lastBeacon;
      final beaconEvery = _idleHello && !_offline
          ? LinkPolicy.idleBeaconInterval
          : beaconInterval;
      if (last == null ||
          now.difference(last) >=
              beaconEvery - const Duration(milliseconds: 100)) {
        await sendBeacon();
      }
    });
  }

  /// Turn battery saver on/off for the manager and every transport.
  Future<void> setPowerSaver(bool on) async {
    if (on == _saver) return;
    _saver = on;
    for (final t in _transports) {
      try {
        t.setPowerSaver(_slow);
      } catch (_) {}
    }
    if (_running) {
      _startHelloTimer();
      await sendHello();
    }
  }

  /// Turn offline power save on/off: stops (or restarts) the internet
  /// transports and puts the rest in their strongest saver. Stacks with
  /// [setPowerSaver] (turning offline off goes back to the saver setting).
  Future<void> setOfflineSaver(bool on) async {
    if (on == _offline) return;
    _offline = on;
    mesh.timeoutScale = on ? 2 : 1;
    for (final t in _transports) {
      try {
        t.setOfflineSaver(on);
        t.setPowerSaver(_slow);
      } catch (_) {}
    }
    if (_running) {
      await Future.wait(
        _transports.where((t) => t.kind == TransportKind.internet).map((
          t,
        ) async {
          try {
            if (on) {
              await t.stop();
            } else {
              await t.start(localNodeId: localNodeId, channel: scope);
            }
          } catch (_) {}
        }),
      );
      _startHelloTimer();
      await sendHello();
    }
    if (!_transportChanges.isClosed) _transportChanges.add(null);
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _started = false;
    _helloTimer?.cancel();
    _missTimer?.cancel();
    _radioHelloSoon?.cancel();
    _gatewayHelloSoon?.cancel();
    _pruneTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await Future.wait(
      _transports.map((t) async {
        try {
          await t.stop();
        } catch (_) {}
      }),
    );
  }

  Future<void> dispose() async {
    await stop();
    await _audio.close();
    await _data.close();
    await _controls.close();
    await _trips.close();
    await _lobby.close();
    await _alerts.close();
    await _probes.close();
    await _peerChanges.close();
    await _transportChanges.close();
  }

  /// Switch channel. Pass [key] for a private channel, null for public.
  Future<void> setChannel(int channel, {ChannelKey? key}) async {
    final oldScope = scope;
    final wasPrivate = _key != null;
    _channel = channel;
    _key = key;
    final newScope = scope;
    if (oldScope != newScope && (wasPrivate || key != null)) {
      // Entering / leaving / changing a private channel: forget everyone so
      // nothing meant for the old group is sent in the new mode (they
      // reappear within a second if they are in the same group).
      _peers.clear();
      _seen.clear();
      _seenAudio.clear();
    }
    // Other room, other gateways (they announce again within 30 s).
    if (oldScope != newScope) _gateways.clear();
    for (final t in _transports) {
      try {
        await t.setChannel(newScope);
      } catch (_) {}
    }
    _recomputeAll();
    await sendHello();
  }

  int _nextSeq() {
    final s = _seq;
    _seq = (_seq + 1) & 0xFFFF;
    return s;
  }

  int _nextAudioSeq() {
    final s = _audioSeq;
    _audioSeq = (_audioSeq + 1) & 0xFFFF;
    return s;
  }

  /// Tell neighbours (off-grid transports only) which phones we hear
  /// directly, so they skip relaying packets we already got.
  Future<void> sendBeacon() async {
    _lastBeacon = _clock();
    final bytes = mesh.beacon();
    await Future.wait(
      _transports
          .where(
            (t) => isOffGrid(t.kind) && t.status == TransportStatus.running,
          )
          .map((t) => _safeSend(t, bytes, null)),
    );
  }

  /// "Who's where" beacon ([bytes] from [LobbyBeacon.encode]) on the
  /// local links only: Wi-Fi / LAN, Wi-Fi Direct, Bluetooth. Never the
  /// internet relay (the lobby room is separate) and never LoRa. Phones
  /// heard only through the mesh get it via a mesh neighbour.
  Future<void> sendLobbyLocal(Uint8List bytes) async {
    final local = _transports
        .where(
          (t) =>
              isOffGrid(t.kind) &&
              !t.lowBandwidth &&
              t.status == TransportStatus.running,
        )
        .toList();
    if (local.isEmpty) return;
    mesh.markSeen(meshPacketId(bytes));
    await Future.wait(local.map((t) => _safeSend(t, bytes, null)));
  }

  /// The rare LoRa copy of our lobby beacon (v1.8.3, see WhosWhere): one
  /// broadcast packet at the lowest priority, through the radio's rate
  /// limiter. False when no radio is connected.
  bool sendLobbyRadio(
    Uint8List bytes, {
    LoraPriority priority = LoraPriority.bulk,
  }) {
    final r = radio;
    if (r == null || r.status != TransportStatus.running) return false;
    return r.sendRadio(bytes, priority: priority);
  }

  /// Pull-to-refresh (v1.8.5): ask everyone "who's here?" right now.
  ///
  /// Sends our presence hello, then the probe ([bytes] from
  /// [LobbyProbe.encode]) once on every running link except LoRa: Wi-Fi /
  /// LAN broadcast + multicast, Wi-Fi Direct, Bluetooth and the internet
  /// relay's channel room. Phones in the phone mesh pass it on up to the
  /// probe's TTL. Then every transport gets a discovery kick
  /// ([Transport.kickDiscovery]: subnet sweep, Wi-Fi Direct discovery,
  /// a Bluetooth scan burst, a relay reconnect when it is down). In
  /// offline power save the internet relay is left alone.
  Future<void> probePeople(Uint8List bytes) async {
    if (!_running) return;
    probesSent++;
    // The hello first: the LAN sweep reuses the last hello we sent.
    await sendHello();
    mesh.markSeen(meshPacketId(bytes));
    final targets = _transports
        .where(
          (t) =>
              !t.lowBandwidth &&
              t.status == TransportStatus.running &&
              !(_offline && t.kind == TransportKind.internet),
        )
        .toList();
    await Future.wait(targets.map((t) => _safeSend(t, bytes, null)));
    for (final t in _transports) {
      if (t.lowBandwidth) continue;
      if (_offline && t.kind == TransportKind.internet) continue;
      try {
        t.kickDiscovery();
      } catch (_) {}
    }
  }

  /// Probes sent by [probePeople] (tests / Details).
  int probesSent = 0;

  /// The LoRa copy of a "who's here?" probe (only when the user asked for
  /// it; the caller rate limits). False when no radio is connected.
  bool sendProbeRadio(Uint8List bytes) =>
      sendLobbyRadio(bytes, priority: LoraPriority.presence);

  // ------------------------------------------- direct links (v1.8.9)

  /// Direct link signaling from [peerId] (a [ControlKind.dx] message).
  void Function(int peerId, Map<String, Object?> x)? onDirectSignal;

  /// Send direct link signaling to [peerId] over the internet transport
  /// (the relays), sealed on a private channel like any other frame.
  Future<void> sendDirectSignal(int peerId, Map<String, Object?> x) async {
    final t = _transportOf(TransportKind.internet);
    if (t == null || !_running) return;
    final bytes = _wire(
      Frame.control(
        senderId: localNodeId,
        channel: _wireChannel,
        seq: _nextSeq(),
        message: ControlMessage(ControlKind.dx, to: peerId, x: x),
      ),
    );
    await _safeSend(t, bytes, {peerId});
  }

  /// Phones that should get a direct internet link: on our channel, new
  /// enough, heard over the internet and with no local Wi-Fi, Wi-Fi Direct
  /// or Bluetooth link (those stay the fast paths).
  List<int> directCandidates() {
    final now = _clock();
    final out = <int>[];
    for (final p in _peers.values) {
      if (p.channel != scope || p.feature < directFeature) continue;
      if (blocked.contains(p.id)) continue;
      final links = usableLinks(p, now);
      if (!links.contains(TransportKind.internet)) continue;
      if (links.any(
        (k) =>
            k == TransportKind.lan ||
            k == TransportKind.wifiDirect ||
            k == TransportKind.ble,
      )) {
        continue;
      }
      out.add(p.id);
    }
    return out;
  }

  /// "Direct" when [p] is reached over a direct internet link, else null.
  String? pathOf(Peer p) {
    final k = p.activeLink;
    if (k == null) return null;
    return _transportOf(k)?.pathTo(p.id);
  }

  ControlMessage _helloMessage() => ControlMessage(
    ControlKind.hello,
    name: localName,
    interval: (_slow || _idleHello)
        ? currentHelloInterval.inMilliseconds
        : null,
    x: helloExtras?.call() ?? const {},
    lanAddrs: [
      for (final t in _transports)
        if (t.status == TransportStatus.running) ...t.localAddresses,
    ],
  );

  Future<void> _maybePings() async {
    final last = _lastPings;
    if (last != null &&
        _clock().difference(last) <
            LinkPolicy.peerPingInterval(_speed, activity) -
                const Duration(milliseconds: 100)) {
      return;
    }
    await sendPings();
  }

  /// Broadcast presence on every running transport.
  Future<void> sendHello() => _broadcastControl(_helloMessage());

  /// Ping every peer on every usable link: round trip for the ranking and
  /// the status line, and (v1.9.8) failure detection: a ping not answered
  /// within [LinkPolicy.missDeadline] marks that link failing (see
  /// [checkMisses]). Cheap: ~40 bytes per link. Rides on the hello tick,
  /// at most every [LinkPolicy.peerPingInterval] (see [_maybePings]).
  Future<void> sendPings({bool force = true}) async {
    final now = _clock();
    _lastPings = now;
    final futures = <Future<void>>[];
    for (final p in _peers.values) {
      for (final kind in fastLinks(p, now)) {
        p.pingOut.putIfAbsent(kind, () => now);
        final bytes = _wire(
          Frame.control(
            senderId: localNodeId,
            channel: _wireChannel,
            seq: _nextSeq(),
            message: ControlMessage(
              ControlKind.ping,
              to: p.id,
              time: now.millisecondsSinceEpoch,
            ),
          ),
        );
        futures.add(_safeSend(_transportOf(kind)!, bytes, {p.id}));
      }
    }
    await Future.wait(futures);
  }

  Future<void> setTalking(bool talking) async {
    if (_talking == talking) return;
    _talking = talking;
    _heldRoutes.clear(); // a burst starts (or ended) with a fresh choice
    if (talking) _trafficAt = _clock();
    _applyProbePlan(); // push-to-talk: full speed right now, even idle
    await _sendToChannel(
      Frame.control(
        senderId: localNodeId,
        channel: _wireChannel,
        seq: _nextSeq(),
        message: ControlMessage(
          talking ? ControlKind.talkStart : ControlKind.talkEnd,
        ),
      ),
    );
  }

  /// Send one encoded Opus packet to every peer on our channel.
  Future<void> sendAudio(Uint8List opus) => _sendToChannel(
    Frame(
      type: FrameType.audio,
      senderId: localNodeId,
      channel: _wireChannel,
      seq: _nextAudioSeq(),
      payload: opus,
    ),
  );

  Peer? peer(int id) => _peers[id];

  /// Links that a frame to [peerId] would go out on right now: the best
  /// usable one, plus the runner-up while the best looks stale.
  List<TransportKind> routeTo(int peerId) {
    final p = _peers[peerId];
    if (p == null) return const [];
    return _route(p, _clock());
  }

  /// The links a frame to [p] goes out on (v1.9.8): the best one while it
  /// is healthy; while it misses pings or has gone quiet for [staleAfter],
  /// also every next one down to the first healthy link (at most 3), so
  /// the backup carries the traffic at once and the best one can still
  /// recover (make-before-break).
  List<TransportKind> _route(Peer p, DateTime now) {
    final fast = fastLinks(p, now);
    if (fast.isEmpty) return const [];
    // Ranked as if nothing failed: a failing link that would be best still
    // gets a copy (it may only be lossy, and recovers without a gap) until
    // it misses [LinkPolicy.missesForDown] checks in a row. v2.3.3: on the
    // smoothed round trip, with hysteresis for the "clearly faster" rule.
    final links = LinkPolicy.rank(
      fast,
      rtt: (k) => _rttOf(p, k),
      incumbent: p.rankFront,
    );
    p.rankFront = links.first;
    bool down(TransportKind k) =>
        (p.misses[k] ?? 0) >= LinkPolicy.missesForDown;
    bool healthy(TransportKind k) {
      if (isDegraded(p, k)) return false;
      final seen = p.lastSeen[k];
      return seen == null || now.difference(seen) <= staleAfter;
    }

    final out = <TransportKind>[];
    for (final k in links) {
      if (down(k) && fast.length > 1) continue;
      out.add(k);
      if (healthy(k) || out.length >= 3) break;
    }
    if (out.isEmpty) out.add(fast.first);
    // A failing best link: the healthy backup goes first.
    if (out.length > 1 && isDegraded(p, out.first) && healthy(out.last)) {
      out.insert(0, out.removeLast());
    }
    return out;
  }

  /// The round trip routing ranks on (v2.3.3): the smoothed one, else the
  /// latest ping.
  Duration? _rttOf(Peer p, TransportKind k) => p.rttSmooth[k] ?? p.rtt[k];

  /// Routes held for the length of our own talk burst (v2.3.3), per peer.
  final Map<int, List<TransportKind>> _heldRoutes = {};

  /// How many times a held route changed its first link in a burst (debug /
  /// tests).
  int routeSwitches = 0;

  /// [_route] for sending live audio: while we talk, the route chosen at the
  /// start of the burst is kept, so a sentence never changes path because a
  /// round trip wobbled. It changes only when a link it uses is gone or has
  /// missed [LinkPolicy.holdMissesToSwitch] pings in a row (real loss: the
  /// backup is used at once). The first miss only adds the healthy backup
  /// next to the held link (both carry the audio, receivers drop copies).
  List<TransportKind> _routeHeld(Peer p, DateTime now) {
    if (!_talking) return _route(p, now);
    final held = _heldRoutes[p.id];
    if (held == null || held.isEmpty) {
      return _heldRoutes[p.id] = _route(p, now);
    }
    final fast = fastLinks(p, now);
    final lost = held.any(
      (k) =>
          !fast.contains(k) ||
          (p.misses[k] ?? 0) >= LinkPolicy.holdMissesToSwitch,
    );
    if (lost) {
      final fresh = _route(p, now);
      if (fresh.isNotEmpty && fresh.first != held.first) routeSwitches++;
      return _heldRoutes[p.id] = fresh;
    }
    if (held.any((k) => isDegraded(p, k))) {
      // Make-before-break: add the backups, keep the held links.
      final add = [
        for (final k in _route(p, now))
          if (!held.contains(k)) k,
      ];
      if (add.isNotEmpty) {
        return _heldRoutes[p.id] = [...held, ...add];
      }
    }
    return held;
  }

  /// The link to [p] on [k] missed a ping (v1.9.8, see [checkMisses]).
  bool isDegraded(Peer p, TransportKind k) => (p.misses[k] ?? 0) >= 1;

  /// Best usable link to [peerId], or null if it is not reachable now. A
  /// peer reachable only through the mesh reports [TransportKind.ble] (the
  /// slowest off-grid link) so transfers pace themselves conservatively.
  /// [TransportKind.lora] only when nothing else reaches it.
  TransportKind? bestLinkTo(int peerId) {
    final r = routeTo(peerId);
    if (r.isNotEmpty) return r.first;
    if (meshReachable(peerId)) return TransportKind.ble;
    return radioReachable(peerId) || gatewayReachable(peerId)
        ? TransportKind.lora
        : null;
  }

  bool isReachable(int peerId) =>
      routeTo(peerId).isNotEmpty ||
      meshReachable(peerId) ||
      radioReachable(peerId) ||
      gatewayReachable(peerId);

  /// Meshtastic channel linked to an inner frame's Walkie channel
  /// (v1.9.7; open channels only, never sealed frames), set by the app.
  MeshChannelRef? Function(Frame inner)? meshLinkFor;

  /// The paired LoRa radio transport, if any.
  LoraTransport? get radio {
    for (final t in _transports) {
      if (t is LoraTransport) return t;
    }
    return null;
  }

  /// [peerId] was heard over the LoRa radio recently.
  bool radioReachable(int peerId) {
    final p = _peers[peerId];
    if (p == null) return false;
    return usableLinks(p, _clock()).contains(TransportKind.lora);
  }

  /// The only way to [peerId] is the LoRa radio: no direct fast link and
  /// no phone mesh path.
  bool onlyRadio(int peerId) {
    final p = _peers[peerId];
    if (p == null) return false;
    final now = _clock();
    if (fastLinks(p, now).isNotEmpty) return false;
    if (meshReachable(peerId)) return false;
    return usableLinks(p, now).contains(TransportKind.lora);
  }

  /// What may go over LoRa (decided on the plain frame, before sealing):
  /// rings, beeps and their answers (each id at most once per
  /// [radioRingRepeat], three times in all), messenger data (chat, voice
  /// clips, acks; the messenger keeps them small and slow), rekeys and the
  /// radio presence hello. Never live audio, talk start/end, pings, mesh
  /// frames or per-second hellos.
  bool radioAllowed(Frame f, {bool presence = false}) {
    switch (f.type) {
      case FrameType.lobby:
        return false; // Who's where never goes over the radio
      case FrameType.data:
        return true;
      case FrameType.control:
        final m = f.control;
        if (m == null) return false;
        switch (m.kind) {
          case ControlKind.hello:
            return presence;
          case ControlKind.ring:
          case ControlKind.beep:
          case ControlKind.ringAck:
            final key = '${m.kind.name}:${m.id}:${m.status}:${m.to}';
            final now = _clock();
            final prev = _radioRingSent[key];
            if (prev != null) {
              if (prev.$2 >= 3) return false;
              if (now.difference(prev.$1) < radioRingRepeat) return false;
            }
            _radioRingSent[key] = (now, (prev?.$2 ?? 0) + 1);
            if (_radioRingSent.length > 200) {
              _radioRingSent.remove(_radioRingSent.keys.first);
            }
            return true;
          case ControlKind.rekey:
          case ControlKind.rekeyAck:
            return true;
          case ControlKind.talkStart:
          case ControlKind.talkEnd:
          case ControlKind.ping:
          case ControlKind.pong:
          case ControlKind.friendReq:
          case ControlKind.friendAcc:
          case ControlKind.friendDec:
          case ControlKind.fhello:
          case ControlKind.dx:
            return false;
        }
      case FrameType.trip:
        // The Trip layer decides what may use the radio (see sendTrip).
        return true;
      case FrameType.audio:
      case FrameType.sealed:
      case FrameType.mesh:
      case FrameType.gateway:
      case FrameType.alert: // weather alerts have their own path
        return false;
    }
  }

  LoraPriority _radioPriority(Frame f) {
    if (f.type == FrameType.trip) return tripRadioPriority(f.payload);
    if (f.type == FrameType.control) {
      final k = f.control?.kind;
      if (k == ControlKind.hello) return LoraPriority.presence;
      if (k == ControlKind.ring ||
          k == ControlKind.ringAck ||
          k == ControlKind.beep) {
        return LoraPriority.urgent;
      }
      return LoraPriority.normal;
    }
    // Voice clip chunks are bulk; acks and small chat chunks normal.
    final p = f.payload;
    if (p.isNotEmpty && p[0] == 1 && p.length > 120) return LoraPriority.bulk;
    return LoraPriority.normal;
  }

  /// Hand [f] (already encoded as [bytes]) to the radio for [peers].
  bool _sendRadio(
    Frame f,
    Uint8List bytes,
    Set<int>? peers, {
    bool presence = false,
  }) {
    final r = radio;
    if (r == null || r.status != TransportStatus.running) return false;
    if (!radioAllowed(f, presence: presence)) return false;
    return r.sendRadio(bytes, peerIds: peers, priority: _radioPriority(f));
  }

  /// One small hello over the radio so far-away phones know we are there
  /// (every [radioHelloInterval], when the radio connects, and soon after
  /// a new phone is heard over LoRa).
  Future<void> sendRadioHello() async {
    final r = radio;
    if (r == null || r.status != TransportStatus.running) return;
    _lastRadioHello = _clock();
    final v = helloExtras?.call()['v'];
    final f = Frame.control(
      senderId: localNodeId,
      channel: _wireChannel,
      seq: _nextSeq(),
      message: ControlMessage(
        ControlKind.hello,
        name: localName,
        x: {'v': ?v, 'lr': 1, 'bt': ?helloExtras?.call()['bt']},
      ),
    );
    _sendRadio(f, _wire(f), null, presence: true);
  }

  void _maybeRadioHello() {
    final r = radio;
    final running = r != null && r.status == TransportStatus.running;
    final became = running && !_radioWasRunning;
    _radioWasRunning = running;
    if (!running) return;
    final last = _lastRadioHello;
    if (became ||
        last == null ||
        _clock().difference(last) >= radioHelloInterval) {
      unawaited(sendRadioHello());
    }
  }

  /// Answer a phone we just heard over LoRa for the first time, after a
  /// short random wait (so several phones do not all answer at once).
  void _radioHelloSoonAfterNewPeer() {
    final last = _lastRadioHello;
    if (last != null &&
        _clock().difference(last) < const Duration(seconds: 60)) {
      return;
    }
    if (_radioHelloSoon?.isActive ?? false) return;
    _radioHelloSoon = Timer(
      Duration(milliseconds: 2000 + _rng.nextInt(4000)),
      () {
        if (_running) unawaited(sendRadioHello());
      },
    );
  }

  // ------------------------------------------------ LoRa gateways (v1.9.5)

  /// Gateways in our relay room right now (freshest first).
  List<GatewayInfo> get gateways {
    final now = _clock();
    final l = [
      for (final g in _gateways.values)
        if (now.difference(g.at) <= gatewayTimeout) g,
    ]..sort((a, b) => b.at.compareTo(a.at));
    return l;
  }

  /// Some gateway (not us) with a radio up is in our room.
  bool get hasGateway => gateways.any((g) => g.radiosUp > 0);

  /// Node ids of gateways in our room (not "unknown listeners").
  Set<int> get gatewayIds => {for (final g in gateways) g.id};

  /// We share our radio right now (radio connected, internet up).
  bool get sharingRadio {
    if (!shareRadio) return false;
    final r = radio;
    final net = _transportOf(TransportKind.internet);
    return r != null &&
        r.status == TransportStatus.running &&
        net != null &&
        net.status == TransportStatus.running;
  }

  /// [peerId] was heard through a LoRa gateway recently and the relay is up.
  bool gatewayReachable(int peerId) {
    final p = _peers[peerId];
    final seen = p?.gatewaySeen;
    if (seen == null) return false;
    if (_clock().difference(seen) > gatewayPeerTimeout) return false;
    final net = _transportOf(TransportKind.internet);
    return net != null && net.status == TransportStatus.running;
  }

  /// Only a gateway reaches [peerId]: no fast link, no phone mesh, not our
  /// own radio.
  bool onlyGateway(int peerId) {
    final p = _peers[peerId];
    if (p == null || !gatewayReachable(peerId)) return false;
    final now = _clock();
    if (fastLinks(p, now).isNotEmpty) return false;
    if (meshReachable(peerId)) return false;
    return !radioReachable(peerId);
  }

  void _updateGatewayLabel(Peer p, DateTime now) {
    final seen = p.gatewaySeen;
    if (seen == null ||
        now.difference(seen) > gatewayPeerTimeout ||
        fastLinks(p, now).isNotEmpty ||
        p.meshHops != null ||
        usableLinks(p, now).contains(TransportKind.lora)) {
      p.viaGateway = null;
      return;
    }
    final g = _gateways[p.gatewayId];
    p.viaGateway = g?.name ?? 'LoRa gateway';
  }

  /// Ask the gateways in our room to put [bytes] (an already sealed frame
  /// that [radioAllowed] passed) on the air, for [to] or everyone.
  bool _sendGateway(Uint8List bytes, LoraPriority priority, {int? to}) {
    final net = _transportOf(TransportKind.internet);
    if (net == null || net.status != TransportStatus.running) return false;
    if (bytes.length > loraPayloadBudget) return false;
    gatewaySeenIds.add(gatewayPacketId(bytes));
    // v1.9.7: a Walkie channel linked to a Meshtastic channel asks for that
    // channel first (newer gateways), then the plain request (older ones;
    // newer gateways drop it as a duplicate).
    final link = meshLinkFor;
    final inner = link == null ? null : Frame.tryDecode(bytes);
    final mesh = inner == null ? null : link!(inner);
    if (mesh != null) {
      final m = GatewayEnvelope.toRadio(
        bytes,
        priority: priority.index,
        to: to ?? 0,
        mesh: mesh,
      ).toFrame(senderId: localNodeId, channel: _wireChannel, seq: _nextSeq());
      unawaited(_safeSend(net, m.encode(), null));
    }
    final env = GatewayEnvelope.toRadio(
      bytes,
      priority: priority.index,
      to: to ?? 0,
    ).toFrame(senderId: localNodeId, channel: _wireChannel, seq: _nextSeq());
    unawaited(_safeSend(net, env.encode(), null));
    return true;
  }

  void _onGatewayFrame(InboundFrame inbound) {
    // Envelopes only ever travel over the internet relay.
    if (inbound.transport != TransportKind.internet) return;
    final f = inbound.frame;
    final env = GatewayEnvelope.tryDecode(f);
    if (env == null) return;
    final now = _clock();
    switch (env.kind) {
      case GatewayKind.announce:
        final prev = _gateways[f.senderId];
        _gateways[f.senderId] = GatewayInfo(
          f.senderId,
          env.name,
          env.radiosUp,
          env.radios,
          env.isPhone,
          now,
        );
        if (prev == null ||
            prev.name != env.name ||
            prev.radiosUp != env.radiosUp) {
          _emitPeers();
        }
      case GatewayKind.fromRadio:
        final inner = env.innerFrame;
        if (inner == null) return;
        if (inner.senderId == localNodeId) return;
        if (inner.type == FrameType.gateway || inner.type == FrameType.mesh) {
          return;
        }
        // Heard on the air by that gateway: never bring it in again.
        gatewaySeenIds.add(env.packetId);
        mesh.markSeen(env.packetId);
        final g =
            _gateways[f.senderId] ??
            GatewayInfo(f.senderId, 'LoRa gateway', 1, 1, false, now);
        _gateways.putIfAbsent(f.senderId, () => g);
        _receive(
          inner,
          InboundFrame(inner, TransportKind.lora),
          1,
          viaGateway: g,
        );
      case GatewayKind.toRadio:
        _onGatewayRequest(f.senderId, env);
    }
  }

  void _emitAlert(
    Frame f,
    InboundFrame inbound,
    int hops, {
    required bool group,
  }) {
    if (_alerts.isClosed) return;
    _alerts.add(
      InboundAlert(
        f,
        inbound.transport,
        group: group,
        hops: hops,
        rssi: inbound.rssi,
      ),
    );
  }

  /// A signed weather alert on the LoRa radio (v2.5.2): [f] is the plain
  /// alert frame; on a private group it is sealed with the group key (so
  /// only members read it), on an open channel it goes out plain. One
  /// broadcast packet, the radio's rate limiter, Meshtastic priority ALERT,
  /// hop limit 3, no ack. False when no radio is connected, or it does not
  /// fit one packet. Phones never pass these on: the radio mesh floods them.
  bool sendAlertRadio(Frame f) {
    final r = radio;
    if (r == null || r.status != TransportStatus.running) return false;
    return r.sendRadio(_wire(f), priority: LoraPriority.alert);
  }

  /// Payload bytes left for an alert frame on the radio on this channel.
  int get alertRadioBudget =>
      loraPayloadBudget - frameOverhead - Frame.headerSize;

  /// A radio is connected and ready for [sendAlertRadio].
  bool get alertRadioReady {
    final r = radio;
    return r != null && r.status == TransportStatus.running;
  }

  /// A phone in our room asks gateways to transmit: do it when we share
  /// our radio and it can reach the target.
  void _onGatewayRequest(int sender, GatewayEnvelope env) {
    if (!sharingRadio) return;
    final r = radio!;
    final inner = env.innerFrame;
    if (inner == null || inner.type == FrameType.audio) return;
    if (inner.type == FrameType.lobby || inner.type == FrameType.alert) return;
    if (!gatewaySeenIds.add(env.packetId)) return;
    final to = env.to;
    if (to != 0 && !r.peerSignals.containsKey(to)) return;
    final pr = env.priority < LoraPriority.values.length
        ? LoraPriority.values[env.priority]
        : LoraPriority.normal;
    if (r.sendRadio(
      env.inner!,
      peerIds: to == 0 ? null : {to},
      priority: pr,
      meshChannel: env.mesh,
    )) {
      gatewayTransmitted++;
    }
  }

  /// Our radio heard [inbound]: when we share it, bring the frame into our
  /// relay room after a short random wait, unless a gateway did already.
  void _maybeShareLoraFrame(InboundFrame inbound) {
    if (!sharingRadio) return;
    final f = inbound.frame;
    if (f.type == FrameType.lobby ||
        f.type == FrameType.mesh ||
        f.type == FrameType.gateway ||
        f.type == FrameType.alert) {
      return;
    }
    final ourRoom = isPrivateScope(scope)
        ? 'p${(scope & 0xFFFF).toRadixString(16).padLeft(4, '0')}'
        : '$scope';
    if (gatewayRoomOf(f) != ourRoom) return;
    final bytes = f.encode();
    final id = gatewayPacketId(bytes);
    if (gatewaySeenIds.contains(id)) return;
    final span =
        gatewayForwardDelayMax.inMilliseconds -
        gatewayForwardDelayMin.inMilliseconds;
    final wait = Duration(
      milliseconds:
          gatewayForwardDelayMin.inMilliseconds +
          (span > 0 ? _rng.nextInt(span) : 0),
    );
    void go() {
      if (!_running || !sharingRadio) return;
      if (!gatewaySeenIds.add(id)) return; // a gateway beat us to it
      final net = _transportOf(TransportKind.internet)!;
      final env = GatewayEnvelope.fromRadio(
        bytes,
        radioNode: 0,
        snr: 0,
      ).toFrame(senderId: localNodeId, channel: f.channel, seq: _nextSeq());
      gatewayForwarded++;
      unawaited(_safeSend(net, env.encode(), null));
    }

    if (wait == Duration.zero) {
      go();
    } else {
      Timer(wait, go);
    }
  }

  /// Hello timer hook: announce ourselves when sharing our radio, and let
  /// LoRa-only phones know we are here through a gateway.
  void _maybeGatewayTick() {
    final now = _clock();
    final net = _transportOf(TransportKind.internet);
    if (net == null || net.status != TransportStatus.running) return;
    if (sharingRadio) {
      final last = _lastGatewayAnnounce;
      if (last == null || now.difference(last) >= const Duration(seconds: 60)) {
        _lastGatewayAnnounce = now;
        final env =
            GatewayEnvelope.announce(
              name: '${localName.isEmpty ? 'Phone' : localName} (radio)',
              radiosUp: 1,
              radios: 1,
              phone: true,
            ).toFrame(
              senderId: localNodeId,
              channel: _wireChannel,
              seq: _nextSeq(),
            );
        unawaited(_safeSend(net, env.encode(), null));
      }
    }
    if (!hasGateway) return;
    final last = _lastGatewayHello;
    if (last == null || now.difference(last) >= radioHelloInterval) {
      sendGatewayHello();
    }
  }

  /// Our LoRa presence hello through the gateways in our room.
  bool sendGatewayHello() {
    if (!hasGateway) return false;
    _lastGatewayHello = _clock();
    final v = helloExtras?.call()['v'];
    final f = Frame.control(
      senderId: localNodeId,
      channel: _wireChannel,
      seq: _nextSeq(),
      message: ControlMessage(
        ControlKind.hello,
        name: localName,
        x: {'v': ?v, 'lr': 1, 'bt': ?helloExtras?.call()['bt']},
      ),
    );
    return _sendGateway(_wire(f), LoraPriority.presence);
  }

  void _gatewayHelloSoonAfterNewPeer() {
    final last = _lastGatewayHello;
    if (last != null &&
        _clock().difference(last) < const Duration(seconds: 60)) {
      return;
    }
    if (_gatewayHelloSoon?.isActive ?? false) return;
    _gatewayHelloSoon = Timer(
      Duration(milliseconds: 2000 + _rng.nextInt(4000)),
      () {
        if (_running) sendGatewayHello();
      },
    );
  }

  /// [peerId] has no direct link but was heard through other phones
  /// recently and a mesh neighbour can carry packets towards it.
  bool meshReachable(int peerId) {
    final p = _peers[peerId];
    if (p == null) return false;
    final seen = p.meshSeen;
    if (seen == null || _clock().difference(seen) > meshTimeout) return false;
    return mesh.meshNeighbours().isNotEmpty;
  }

  /// "Relay for others" switch.
  bool get relayForOthers => mesh.enabled;
  set relayForOthers(bool on) => mesh.enabled = on;

  void _sendMesh(MeshRelay r, [Set<int>? targets]) {
    final byKind = <TransportKind, Set<int>>{};
    for (final id in targets ?? r.targets) {
      final kind = _bestMeshLink(id);
      if (kind != null) byKind.putIfAbsent(kind, () => <int>{}).add(id);
    }
    for (final e in byKind.entries) {
      unawaited(_safeSend(_transportOf(e.key)!, r.bytes, e.value));
    }
  }

  /// Fastest off-grid transport neighbour [id] was heard on directly.
  TransportKind? _bestMeshLink(int id) {
    Transport? best;
    for (final kind in mesh.linksTo(id)) {
      final t = _transportOf(kind);
      if (t == null || t.status != TransportStatus.running) continue;
      if (!t.canReach(id)) continue;
      if (best == null || t.priority > best.priority) best = t;
    }
    return best?.kind;
  }

  /// Peers currently reachable and on [channel].
  Set<int> reachablePeersOn(int channel) => {
    for (final p in _peers.values)
      if (p.channel == channel && isReachable(p.id)) p.id,
  };

  /// Unicast [frame] to one peer over its best link(s). False if the peer
  /// is not reachable right now.
  Future<bool> sendFrameTo(int peerId, Frame frame) async {
    _noteActivity(frame);
    if (isUrgentFrame(frame)) {
      await _sendEverywhere(frame, to: peerId);
      return isReachable(peerId) || hasGateway;
    }
    final route = routeTo(peerId);
    if (route.isEmpty) {
      if (meshReachable(peerId)) {
        final r = mesh.originate(_wire(frame), to: peerId);
        if (r != null) {
          _sendMesh(r);
          return true;
        }
      }
      // Last resort: the LoRa radio (only what it may carry), ours or a
      // gateway's.
      if (radioReachable(peerId)) {
        return _sendRadio(frame, _wire(frame), {peerId});
      }
      if (gatewayReachable(peerId)) {
        if (!radioAllowed(frame)) return false;
        return _sendGateway(_wire(frame), _radioPriority(frame), to: peerId);
      }
      return false;
    }
    final bytes = _wire(frame);
    _remember(frame, bytes, {
      for (final k in route) k: {peerId},
    });
    await Future.wait(
      route.map((k) => _safeSend(_transportOf(k)!, bytes, {peerId})),
    );
    return true;
  }

  Future<bool> sendControlTo(int peerId, ControlMessage msg) => sendFrameTo(
    peerId,
    Frame.control(
      senderId: localNodeId,
      channel: _wireChannel,
      seq: _nextSeq(),
      message: msg,
    ),
  );

  /// Send [msg] to every reachable peer on our channel. Returns their ids.
  Future<Set<int>> sendControlToChannel(ControlMessage msg) async {
    final targets = reachablePeersOn(scope);
    await _sendToChannel(
      Frame.control(
        senderId: localNodeId,
        channel: _wireChannel,
        seq: _nextSeq(),
        message: msg,
      ),
    );
    return targets;
  }

  /// Unicast a [FrameType.data] payload to one peer.
  Future<bool> sendData(int peerId, Uint8List payload) => sendFrameTo(
    peerId,
    Frame(
      type: FrameType.data,
      senderId: localNodeId,
      channel: _wireChannel,
      seq: _nextSeq(),
      payload: payload,
    ),
  );

  /// LoRa queue order for a Trip payload: SOS and SOS answers first, quick
  /// messages and pins normal, locations and trails last.
  static LoraPriority tripRadioPriority(Uint8List payload) {
    if (payload.isEmpty) return LoraPriority.bulk;
    var kind = payload[0] & 0xF;
    // A base camp delivery carries the original message after 9 bytes.
    if (kind == 8 && payload.length > 9) kind = payload[9] & 0xF;
    switch (kind) {
      case 2: // sos
      case 3: // sos ack
        return LoraPriority.sos;
      case 4: // canned
      case 5: // pin
      case 6: // pin delete
        return LoraPriority.normal;
      default:
        return LoraPriority.bulk;
    }
  }

  /// Send a Trip message (v1.8.0) over whatever reaches:
  /// * [to] set: that phone only, on its best link, else through the
  ///   phone mesh, else (if [radio]) the LoRa radio.
  /// * [flood]: to everyone every running fast transport can reach (not
  ///   only known phones on our channel; phones in range relay it on
  ///   through the mesh), plus a radio broadcast if [radio].
  /// * otherwise: phones on our channel on their best links, the mesh for
  ///   phones only it reaches, and (if [radio]) one radio packet for
  ///   phones only the radio reaches.
  /// [fast] false = radio only. Returns the phones it was handed to.
  Future<Set<int>> sendTrip(
    Uint8List payload, {
    int? to,
    bool fast = true,
    bool radio = false,
    bool flood = false,
  }) async {
    final frame = Frame(
      type: FrameType.trip,
      senderId: localNodeId,
      channel: _wireChannel,
      seq: _nextSeq(),
      payload: payload,
    );
    final bytes = _wire(frame);
    final pr = tripRadioPriority(payload);
    final r = this.radio;
    // Shared map layers (kind 9) are fast-link only, never the radio.
    final big = payload.isNotEmpty && payload[0] & 0xF == 9;
    final radioUp =
        radio && !big && r != null && r.status == TransportStatus.running;
    // v1.9.8: SOS (and SOS answers) on every path at once. Floods already
    // do; one addressed to a phone goes on every running fast link too.
    final sos = pr == LoraPriority.sos;
    if (sos) {
      urgentSends++;
      _urgentAt = _clock();
      _applyProbePlan();
    }
    if (to != null) {
      if (fast && sos) {
        final all = _transports
            .where(
              (t) => t.status == TransportStatus.running && !t.lowBandwidth,
            )
            .toList();
        mesh.markSeen(meshPacketId(bytes));
        if (hasMeshNeighbours) {
          final m = mesh.originate(bytes, to: to);
          if (m != null) _sendMesh(m);
        }
        await Future.wait(all.map((t) => _safeSend(t, bytes, {to})));
        var ok = all.isNotEmpty;
        if (radioUp && r.sendRadio(bytes, peerIds: {to}, priority: pr)) {
          ok = true;
        }
        if (radio && !big && hasGateway && _sendGateway(bytes, pr, to: to)) {
          ok = true;
        }
        return ok && isReachable(to) ? {to} : const {};
      }
      if (fast) {
        final route = routeTo(to);
        if (route.isNotEmpty) {
          _remember(frame, bytes, {
            for (final k in route) k: {to},
          });
          await Future.wait(
            route.map((k) => _safeSend(_transportOf(k)!, bytes, {to})),
          );
          return {to};
        }
        if (meshReachable(to)) {
          final m = mesh.originate(bytes, to: to);
          if (m != null) {
            _sendMesh(m);
            return {to};
          }
        }
      }
      if (radioUp && radioReachable(to)) {
        if (r.sendRadio(bytes, peerIds: {to}, priority: pr)) return {to};
      }
      if (radio && !big && gatewayReachable(to)) {
        if (_sendGateway(bytes, pr, to: to)) return {to};
      }
      return const {};
    }
    final targets = reachablePeersOn(scope);
    if (flood) {
      if (fast) {
        mesh.markSeen(meshPacketId(bytes));
        await Future.wait(
          _transports
              .where(
                (t) => t.status == TransportStatus.running && !t.lowBandwidth,
              )
              .map((t) => _safeSend(t, bytes, null)),
        );
        if (_hasMeshOnlyPeers()) {
          final m = mesh.originate(bytes);
          if (m != null) _sendMesh(m);
        }
      }
      if (radioUp) r.sendRadio(bytes, priority: pr);
      if (radio && !big && hasGateway) _sendGateway(bytes, pr);
      return targets;
    }
    if (fast) {
      final routes = routeForChannel();
      _remember(frame, bytes, routes);
      if (_hasMeshOnlyPeers()) {
        final direct = <int>{for (final s in routes.values) ...s};
        final m = mesh.originate(bytes, skip: direct);
        if (m != null) _sendMesh(m);
      }
      await Future.wait(
        routes.entries.map((e) {
          final t = _transports.firstWhere((t) => t.kind == e.key);
          return _safeSend(t, bytes, e.value);
        }),
      );
    }
    if (radioUp) {
      final far = <int>{
        for (final p in _peers.values)
          if (p.channel == scope &&
              (fast ? onlyRadio(p.id) : radioReachable(p.id)))
            p.id,
      };
      if (far.isNotEmpty) r.sendRadio(bytes, peerIds: far, priority: pr);
    }
    if (radio && !big) {
      final farGw = <int>{
        for (final p in _peers.values)
          if (p.channel == scope &&
              (fast ? onlyGateway(p.id) : gatewayReachable(p.id)) &&
              !(radioUp && radioReachable(p.id)))
            p.id,
      };
      if (farGw.isNotEmpty) {
        _sendGateway(bytes, pr, to: farGw.length == 1 ? farGw.first : null);
      }
    }
    return targets;
  }

  Future<void> _broadcastControl(ControlMessage msg) async {
    final bytes = _wire(
      Frame.control(
        senderId: localNodeId,
        channel: _wireChannel,
        seq: _nextSeq(),
        message: msg,
      ),
    );
    await Future.wait(
      _transports
          .where((t) => t.status == TransportStatus.running && !t.lowBandwidth)
          .map((t) => _safeSend(t, bytes, null)),
    );
  }

  /// Which transport(s) each peer on our channel would be sent to right
  /// now. Normally one link per peer; two while the best one looks stale.
  Map<TransportKind, Set<int>> routeForChannel() {
    final now = _clock();
    final routes = <TransportKind, Set<int>>{};
    for (final p in _peers.values) {
      if (p.channel != scope) continue;
      for (final k in _routeHeld(p, now)) {
        routes.putIfAbsent(k, () => <int>{}).add(p.id);
      }
    }
    return routes;
  }

  // -------------------------------------- failover (v1.9.8)

  /// Frames worth sending again on another link when the one they went
  /// out on fails: chat / voice clip chunks and acks, rings, beeps, ring
  /// answers, rekeys, Trip messages. Never live audio (it just continues
  /// on the new path), presence or pings.
  static bool _resendable(Frame f) {
    switch (f.type) {
      case FrameType.data:
      case FrameType.trip:
        return true;
      case FrameType.control:
        final k = f.control?.kind;
        return k == ControlKind.ring ||
            k == ControlKind.beep ||
            k == ControlKind.ringAck ||
            k == ControlKind.rekey ||
            k == ControlKind.rekeyAck;
      default:
        return false;
    }
  }

  void _remember(Frame f, Uint8List bytes, Map<TransportKind, Set<int>> to) {
    if (!_resendable(f) || to.isEmpty) return;
    final now = _clock();
    _recent.removeWhere((r) => now.difference(r.at) > LinkPolicy.resendWindow);
    _recent.add(
      _RecentSend(now, bytes, {
        for (final e in to.entries) e.key: {...e.value},
      }),
    );
    if (_recent.length > 200) _recent.removeAt(0);
  }

  /// Run every 250 ms: a ping not answered within
  /// [LinkPolicy.missDeadline] is a miss. On the first miss the link
  /// counts as failing: routing sends on the next best link at once and
  /// what went out on the failing link in the last
  /// [LinkPolicy.resendWindow] is sent again there (receivers drop the
  /// copies by sender + sequence). Public for tests.
  void checkMisses() {
    if (!_running) return;
    final now = _clock();
    var changed = false;
    for (final p in _peers.values) {
      final out = Map.of(p.pingOut);
      for (final e in out.entries) {
        final k = e.key;
        if (now.difference(e.value) <= LinkPolicy.missDeadline(p.rtt[k])) {
          continue;
        }
        // Window over: the next ping opens a new one.
        p.pingOut.remove(k);
        final m = (p.misses[k] ?? 0) + 1;
        p.misses[k] = m;
        if (m == 1) {
          degradedEvents++;
          changed = true;
          _failover(p, k, now);
          // v2.0.0: trouble: probe fast for a while, idle or not.
          _startBurst();
        }
        if (m == LinkPolicy.missesForDown) changed = true;
      }
    }
    if (changed) {
      for (final p in _peers.values) {
        p.activeLink = _bestLink(p, now);
      }
      _emitPeers();
    }
  }

  void _failover(Peer p, TransportKind failed, DateTime now) {
    final route = [
      for (final k in _route(p, now))
        if (k != failed) k,
    ];
    if (route.isEmpty) return;
    for (final r in _recent) {
      if (now.difference(r.at) > LinkPolicy.resendWindow) continue;
      final onFailed = r.to[failed]?.contains(p.id) ?? false;
      if (!onFailed) continue;
      final elsewhere = r.to.entries.any(
        (e) => e.key != failed && e.value.contains(p.id),
      );
      if (elsewhere) continue;
      final k = route.first;
      final t = _transportOf(k);
      if (t == null) continue;
      resent++;
      r.to.putIfAbsent(k, () => <int>{}).add(p.id);
      unawaited(_safeSend(t, r.bytes, {p.id}));
    }
  }

  // -------------------------------------------- status line (v1.9.8)

  static String _plainLabel(TransportKind k) => switch (k) {
    TransportKind.internet => 'Internet',
    TransportKind.lan => 'Wi-Fi',
    TransportKind.wifiDirect => 'Wi-Fi Direct',
    TransportKind.ble => 'Bluetooth',
    TransportKind.lora => 'LoRa radio',
  };

  /// The best path right now and how many others are ready, e.g.
  /// "Direct 42 ms · 3 backups ready" (see [ConnectionSummary]).
  ConnectionSummary connectionSummary() {
    final now = _clock();
    // Paths that work right now, best first: (label, kind, round trip).
    final paths = <(String, TransportKind, Duration?)>[];
    final seen = <String>{};
    void add(String label, TransportKind k, Duration? rtt) {
      if (seen.add(label)) paths.add((label, k, rtt));
    }

    // 1. What phones on our channel are reached over, fastest first.
    final used = <(String, TransportKind, Duration?)>[];
    for (final p in _peers.values) {
      if (p.channel != scope) continue;
      for (final k in fastLinks(p, now)) {
        final t = _transportOf(k)!;
        final label = k == TransportKind.internet
            ? (t.pathTo(p.id) ?? t.pathLabel ?? 'Internet')
            : _plainLabel(k);
        used.add((label, k, isDegraded(p, k) ? null : p.rtt[k]));
      }
    }
    final ranked = LinkPolicy.rank(
      {for (final u in used) u.$2},
      rtt: (k) {
        Duration? best;
        for (final u in used) {
          if (u.$2 == k && u.$3 != null && (best == null || u.$3! < best)) {
            best = u.$3;
          }
        }
        return best;
      },
    );
    for (final k in ranked) {
      final mine = used.where((u) => u.$2 == k).toList()
        ..sort((a, b) {
          final ra = a.$3, rb = b.$3;
          if (ra == null) return rb == null ? 0 : 1;
          if (rb == null) return -1;
          return ra.compareTo(rb);
        });
      for (final u in mine) {
        add(u.$1, u.$2, u.$3);
      }
    }
    // 2. Links that are up and ready even with nobody on them yet.
    for (final t in _transports) {
      if (t.status != TransportStatus.running) continue;
      if (t.kind == TransportKind.internet) {
        final rp = t.readyPaths;
        if (rp.isEmpty) add('Internet', t.kind, t.probeRtt);
        for (final (label, rtt) in rp) {
          add(label, t.kind, rtt);
        }
      } else if (t.kind == TransportKind.lora) {
        add('LoRa radio', t.kind, null);
      }
    }
    if (hasGateway) add('Home gateway (LoRa)', TransportKind.lora, null);
    if (paths.isEmpty) {
      return ConnectionSummary(
        best: null,
        bestRtt: null,
        backups: 0,
        checkEvery: probeInterval,
      );
    }
    final best = paths.first;
    return ConnectionSummary(
      best: best.$1,
      bestRtt: best.$3,
      backups: paths.length - 1,
      checkEvery: probeInterval,
      failing: _peers.values.any(
        (p) => p.channel == scope && p.misses.values.any((m) => m > 0),
      ),
    );
  }

  /// Urgent: an urgent ring or an SOS (start, repeat, answer). These go
  /// out on every path at once (v1.9.8).
  static bool isUrgentFrame(Frame f) {
    if (f.type == FrameType.control) {
      final m = f.control;
      return m != null && m.kind == ControlKind.ring && m.urgent;
    }
    if (f.type == FrameType.trip) {
      return tripRadioPriority(f.payload) == LoraPriority.sos;
    }
    return false;
  }

  /// Urgent frames sent on every path (tests / Details).
  int urgentSends = 0;

  /// Send [frame] on every running fast link (to [to], or everyone), the
  /// phone mesh, the LoRa radio (through its ring repeat limits and
  /// airtime queue, at urgent priority) and the LoRa gateways, all at
  /// once. Returns the phones it was handed to.
  Future<Set<int>> _sendEverywhere(Frame frame, {int? to}) async {
    urgentSends++;
    _urgentAt = _clock();
    _applyProbePlan();
    final bytes = _wire(frame);
    final targets = to != null ? {to} : reachablePeersOn(scope);
    final fast = _transports
        .where((t) => t.status == TransportStatus.running && !t.lowBandwidth)
        .toList();
    mesh.markSeen(meshPacketId(bytes));
    if (hasMeshNeighbours) {
      final m = mesh.originate(bytes, to: to ?? 0);
      if (m != null) _sendMesh(m);
    }
    if (radioAllowed(frame)) {
      final pr = _radioPriority(frame);
      final r = radio;
      if (r != null && r.status == TransportStatus.running) {
        r.sendRadio(bytes, peerIds: to == null ? null : {to}, priority: pr);
      }
      if (hasGateway) _sendGateway(bytes, pr, to: to);
    }
    await Future.wait(
      fast.map((t) => _safeSend(t, bytes, to == null ? null : {to})),
    );
    return targets;
  }

  /// Rings, beeps and SOS make the app check links at the fastest rate
  /// for [urgentActiveFor].
  void _noteActivity(Frame f) {
    if (_isTraffic(f)) {
      _trafficAt = _clock();
      if (_appliedActivity == ProbeActivity.idle) _applyProbePlan();
    }
    final k = f.type == FrameType.control ? f.control?.kind : null;
    final ring =
        k == ControlKind.ring ||
        k == ControlKind.beep ||
        k == ControlKind.ringAck;
    final sos =
        f.type == FrameType.trip &&
        tripRadioPriority(f.payload) == LoraPriority.sos;
    if (!ring && !sos) return;
    _urgentAt = _clock();
    _applyProbePlan();
  }

  Future<void> _sendToChannel(Frame frame) async {
    _noteActivity(frame);
    if (isUrgentFrame(frame)) {
      await _sendEverywhere(frame);
      return;
    }
    final bytes = _wire(frame);
    final routes = routeForChannel();
    _remember(frame, bytes, routes);
    // Phones on our channel heard only through the mesh: also hand the
    // packet to mesh neighbours that are not getting the direct copy. The
    // direct sends above are unchanged and never wait for this.
    if (_hasMeshOnlyPeers()) {
      final direct = <int>{for (final s in routes.values) ...s};
      final r = mesh.originate(bytes, skip: direct);
      if (r != null) _sendMesh(r);
    }
    // Phones on our channel that only the LoRa radio reaches: one radio
    // packet for all of them (never for live audio).
    if (frame.type != FrameType.audio) {
      final far = <int>{
        for (final p in _peers.values)
          if (p.channel == scope && onlyRadio(p.id)) p.id,
      };
      // ... and phones only a LoRa gateway reaches (v1.9.5).
      final farGw = <int>{
        for (final p in _peers.values)
          if (p.channel == scope && onlyGateway(p.id)) p.id,
      };
      if (far.isNotEmpty || farGw.isNotEmpty) {
        // Decide once (ring repeat counters).
        if (radioAllowed(frame)) {
          final pr = _radioPriority(frame);
          final r = radio;
          if (far.isNotEmpty && r != null) {
            r.sendRadio(bytes, peerIds: far, priority: pr);
          }
          if (farGw.isNotEmpty) {
            _sendGateway(bytes, pr, to: farGw.length == 1 ? farGw.first : null);
          }
        }
      }
    }
    await Future.wait(
      routes.entries.map((e) {
        final t = _transports.firstWhere((t) => t.kind == e.key);
        return _safeSend(t, bytes, e.value);
      }),
    );
  }

  bool _hasMeshOnlyPeers() {
    final now = _clock();
    for (final p in _peers.values) {
      if (p.channel != scope) continue;
      if (fastLinks(p, now).isNotEmpty) continue;
      if (meshReachable(p.id)) return true;
    }
    return false;
  }

  Future<void> _safeSend(Transport t, Uint8List bytes, Set<int>? to) async {
    try {
      await t.send(bytes, peerIds: to);
    } catch (_) {
      // A failed send on one link is not fatal; the link will time out and
      // traffic moves to the next best transport. v2.0.0: and every link
      // is checked at full speed for a few seconds (idle or not).
      if (!t.lowBandwidth) _startBurst();
    }
  }

  /// Links to [p] that are alive (heard recently), running and still
  /// addressable, best first.
  List<TransportKind> usableLinks(Peer p, DateTime now) {
    final ts = <Transport>[];
    for (final e in p.lastSeen.entries) {
      final t = _transportOf(e.key);
      if (t == null || t.status != TransportStatus.running) continue;
      if (now.difference(e.value) > _linkTimeout(t, p)) continue;
      if (!t.canReach(p.id)) continue;
      ts.add(t);
    }
    // v1.9.8: tiers (internet, Wi-Fi, nearby, LoRa), measured round trip
    // inside a tier, failing links last, and a clearly faster link first
    // (see LinkPolicy.rank). A transport with a custom priority (tests,
    // friend rooms) keeps the old order among equals.
    ts.sort((a, b) => b.priority.compareTo(a.priority));
    return LinkPolicy.rank(
      [for (final t in ts) t.kind],
      rtt: (k) => _rttOf(p, k),
      degraded: (k) => isDegraded(p, k),
      incumbent: p.rankFront,
    );
  }

  /// Links heard recently (each with its own timeout), any state: for the
  /// people list.
  List<TransportKind> liveLinksOf(Peer p, DateTime now) => [
    for (final e in p.lastSeen.entries)
      if (now.difference(e.value) <=
          (_transportOf(e.key)?.linkTimeout ?? timeoutFor(p)))
        e.key,
  ];

  /// [usableLinks] without the slow ones (LoRa): what routing, pings and
  /// make-before-break use.
  List<TransportKind> fastLinks(Peer p, DateTime now) => [
    for (final k in usableLinks(p, now))
      if (!(_transportOf(k)?.lowBandwidth ?? false)) k,
  ];

  Duration _linkTimeout(Transport t, Peer p) => t.linkTimeout ?? timeoutFor(p);

  /// The link the peer card shows: the best fast link, else nothing while
  /// the phone mesh carries it ("via N hops"), else the radio.
  TransportKind? _bestLink(Peer p, DateTime now) {
    final l = usableLinks(p, now);
    if (l.isEmpty) return null;
    final fast = fastLinks(p, now);
    if (fast.isNotEmpty) return fast.first;
    final seen = p.meshSeen;
    if (seen != null &&
        now.difference(seen) <= meshTimeout &&
        mesh.meshNeighbours().isNotEmpty) {
      return null;
    }
    return l.first;
  }

  Transport? _transportOf(TransportKind kind) {
    for (final t in _transports) {
      if (t.kind == kind) return t;
    }
    return null;
  }

  /// A sealed friend frame towards [peerId] through the phone mesh (other
  /// app phones carry it opaquely). False when no mesh neighbour exists.
  bool sendSealedMesh(Uint8List bytes, int peerId) {
    final r = mesh.originate(bytes, to: peerId);
    if (r == null) return false;
    _sendMesh(r);
    return true;
  }

  /// Some phone carries mesh packets for us right now.
  bool get hasMeshNeighbours => mesh.meshNeighbours().isNotEmpty;

  /// A sealed friend frame over the LoRa radio. What may go (and how
  /// urgently) is decided on the plain [inner] frame, as for channel
  /// traffic; the radio only ever sees [bytes] (ciphertext). Addressed to
  /// the friend's radio node when it is known, else broadcast.
  bool sendSealedRadio(Frame inner, Uint8List bytes, int peerId) {
    final r = radio;
    if (r == null || r.status != TransportStatus.running) return false;
    if (!radioAllowed(inner)) return false;
    return r.sendRadio(
      bytes,
      peerIds: {peerId},
      priority: _radioPriority(inner),
    );
  }

  /// [peerId]'s phone was heard on [kind] recently (any frame it sent on
  /// our channel, e.g. its hellos), by the normal link timeouts.
  bool heardOn(TransportKind kind, int peerId) {
    final p = _peers[peerId];
    if (p == null) return false;
    return usableLinks(p, _clock()).contains(kind);
  }

  /// Send already-encoded bytes on one transport (friend links).
  Future<void> sendRaw(
    TransportKind kind,
    Uint8List bytes,
    Set<int>? peerIds,
  ) async {
    final t = _transportOf(kind);
    if (t == null || t.status != TransportStatus.running) return;
    await _safeSend(t, bytes, peerIds);
  }

  /// Whether [kind] currently has a way to address [peerId].
  bool canReachOn(TransportKind kind, int peerId) {
    final t = _transportOf(kind);
    return t != null &&
        t.status == TransportStatus.running &&
        t.canReach(peerId);
  }

  /// Visible for tests: feed a frame as if a transport delivered it.
  void handleInbound(InboundFrame inbound) => _onInbound(inbound);

  void _onInbound(InboundFrame inbound) {
    if (inbound.frame.senderId == localNodeId) return; // own echo
    if (inbound.frame.type == FrameType.gateway) {
      _onGatewayFrame(inbound);
      return;
    }
    if (inbound.transport == TransportKind.lora) _maybeShareLoraFrame(inbound);
    // Mesh first: learns neighbours, unwraps relayed copies, and decides
    // whether this packet must be passed on (blocked senders included:
    // blocking is about what we hear, relaying is for the others).
    final d = mesh.onFrame(inbound.frame, inbound.transport);
    // Only phones that run the mesh read beacons.
    if (d.newNeighbour && _running && mesh.meshNeighbours().isNotEmpty) {
      unawaited(sendBeacon());
    }
    final relay = d.relay;
    if (relay != null) {
      if (relay.delay == Duration.zero) {
        _sendMesh(relay);
      } else {
        Timer(relay.delay, () {
          if (!_running) return;
          final targets = relay.currentTargets();
          if (targets.isEmpty) {
            mesh.suppressed++;
            return;
          }
          _sendMesh(relay, targets);
        });
      }
    }
    final deliver = d.deliver;
    if (deliver == null) return;
    _receive(deliver, inbound, d.hops);
  }

  void _receive(
    Frame frame,
    InboundFrame inbound,
    int hops, {
    GatewayInfo? viaGateway,
  }) {
    var f = frame;
    final relayed = hops > 1;
    final viaGw = viaGateway != null;
    if (f.senderId == localNodeId) return; // our own broadcast echoed back
    if (blocked.contains(f.senderId)) return;

    // Lobby beacons are public on purpose and never sealed: hand them to
    // Who's where before the channel / key checks, without touching the
    // people list. LoRa never carries them.
    if (f.type == FrameType.lobby) {
      // "Who's here?" probe (v1.8.5): same frame type, its own payload.
      final probe = LobbyProbe.tryDecode(f);
      if (probe != null) {
        if (!_probes.isClosed) {
          _probes.add(
            InboundProbe(f.senderId, probe, inbound.transport, hops: hops),
          );
        }
        return;
      }
      // LoRa copies come rarely (every 15 min, v1.8.3).
      final b = LobbyBeacon.tryDecode(f);
      if (b != null && !_lobby.isClosed) {
        _lobby.add(
          InboundLobby(
            f.senderId,
            b,
            inbound.transport,
            hops: hops,
            rssi: inbound.rssi,
          ),
        );
      }
      return;
    }

    // Weather alerts (v2.5.2) are signed by the device that sends them, so
    // a plain one is read on any channel (the weather layer labels it
    // "unconfirmed" unless its key is trusted). They never touch the people
    // list. A sealed one is handled below, once the group key opened it.
    if (f.type == FrameType.alert) {
      _emitAlert(f, inbound, hops, group: false);
      return;
    }

    // Private channels: only frames that decrypt with our key count. Plain
    // frames are ignored while private, sealed ones while public, so phones
    // without the passcode never show up, ring or play audio (and vice
    // versa). Nothing is recorded about rejected frames.
    final key = _key;
    if (f.type == FrameType.sealed) {
      final opened = key?.open(f);
      if (opened == null) {
        // Friend frames (v1.8.3): taken from direct links, the phone mesh
        // and the LoRa radio alike. FriendLinks only accepts what opens
        // with a pair key (AEAD), so the path proves nothing either way;
        // the hop count tells it how the frame came.
        sealedHandler?.call(
          identical(f, inbound.frame) && !relayed
              ? inbound
              : InboundFrame(
                  f,
                  inbound.transport,
                  rssi: inbound.rssi,
                  hops: hops,
                ),
        );
        return;
      }
      f = opened;
      if (f.type == FrameType.alert) {
        // Sealed with our group's key: only a member can have sent it.
        _emitAlert(f, inbound, hops, group: true);
        return;
      }
    } else if (key != null) {
      return;
    }
    final frameScope = key == null ? f.channel : scope;

    final now = _clock();
    final knownBefore = _peers.containsKey(f.senderId);
    final peer = _peers.putIfAbsent(f.senderId, () => Peer(f.senderId));
    // Idle (slow hellos): a phone we have not heard yet gets our hello now,
    // not up to a few seconds later.
    if (!knownBefore && _idleHello && _running && _started) {
      unawaited(sendHello());
    }
    final wasMeshHops = peer.meshHops;
    final viaSlow =
        viaGw || (_transportOf(inbound.transport)?.lowBandwidth ?? false);
    if (viaGw) {
      final prev = peer.gatewaySeen;
      if (prev == null || now.difference(prev) > gatewayPeerTimeout) {
        _gatewayHelloSoonAfterNewPeer();
      }
    } else if (viaSlow && !relayed) {
      final prev = peer.lastSeen[inbound.transport];
      final t = _transportOf(inbound.transport)!;
      if (prev == null || now.difference(prev) > _linkTimeout(t, peer)) {
        _radioHelloSoonAfterNewPeer();
      }
    }
    if (viaGw) {
      peer.gatewaySeen = now;
      peer.gatewayId = viaGateway.id;
    } else if (relayed) {
      peer.meshSeen = now;
      peer.hops = hops;
    } else {
      peer.lastSeen[inbound.transport] = now;
      final rssi = inbound.rssi;
      if (rssi != null && rssi != 0) peer.rssi[inbound.transport] = rssi;
    }
    peer.channel = frameScope;
    _updateMeshHops(peer, now);
    final gwBefore = peer.viaGateway;
    _updateGatewayLabel(peer, now);
    var meshChanged =
        wasMeshHops != peer.meshHops || gwBefore != peer.viaGateway;

    final window = (f.type == FrameType.audio ? _seenAudio : _seen).putIfAbsent(
      f.senderId,
      _SeqWindow.new,
    );
    final duplicate = !window.add(f.seq);

    final before = peer.activeLink;
    peer.activeLink = _bestLink(peer, now);
    var changed = before != peer.activeLink || meshChanged;

    if (!duplicate) {
      _noteActivity(f);
      switch (f.type) {
        case FrameType.control:
          final msg = f.control;
          if (msg != null) {
            if (msg.kind == ControlKind.hello) {
              final bt = msg.x['bt'];
              final b = bt is num && bt >= 0 && bt <= 100 ? bt.toInt() : null;
              if (b != null && b != peer.battery) {
                peer.battery = b;
                changed = true;
              }
            }
            switch (msg.kind) {
              case ControlKind.hello when viaSlow:
                // Radio presence: just enough to show the phone; do not
                // overwrite what its fast-link hellos told us.
                if (peer.info.isEmpty) {
                  final v = (msg.x['v'] as num?)?.toInt() ?? 0;
                  if (v != peer.feature) {
                    peer.feature = v;
                    changed = true;
                  }
                }
                if (msg.name != null && msg.name != peer.name) {
                  peer.name = msg.name!;
                  changed = true;
                }
              case ControlKind.hello:
                // v1.9.4: per-phone key, every hello (fake hellos with
                // another key show up as a conflict, see KxBook).
                KxBook.record(peer.kxSeen, msg.x['kx'], now);
                final iv = msg.interval;
                peer.helloInterval = iv != null && iv > 0 && iv <= 30000
                    ? Duration(milliseconds: iv)
                    : null;
                if (msg.x.isNotEmpty || peer.info.isNotEmpty) {
                  final v = (msg.x['v'] as num?)?.toInt() ?? 0;
                  if (v != peer.feature ||
                      msg.x.toString() != peer.info.toString()) {
                    peer.feature = v;
                    peer.info = msg.x;
                    changed = true;
                  }
                }
                if (msg.name != null && msg.name != peer.name) {
                  peer.name = msg.name!;
                  changed = true;
                }
                if (msg.lanAddrs.isNotEmpty) {
                  peer.lanAddrs = msg.lanAddrs;
                  for (final t in _transports) {
                    t.learnPeerAddresses(peer.id, msg.lanAddrs);
                  }
                }
              case ControlKind.ping:
                if (!relayed &&
                    !viaSlow &&
                    (msg.to == null || msg.to == localNodeId)) {
                  final t = _transportOf(inbound.transport);
                  if (t != null) {
                    _safeSend(
                      t,
                      _wire(
                        Frame.control(
                          senderId: localNodeId,
                          channel: _wireChannel,
                          seq: _nextSeq(),
                          message: ControlMessage(
                            ControlKind.pong,
                            to: peer.id,
                            time: msg.time,
                          ),
                        ),
                      ),
                      {peer.id},
                    );
                  }
                }
              case ControlKind.pong:
                if (!relayed && msg.to == localNodeId && msg.time != null) {
                  final rtt = now.millisecondsSinceEpoch - msg.time!;
                  if (rtt >= 0 && rtt < 30000) {
                    final sample = Duration(milliseconds: rtt);
                    peer.rtt[inbound.transport] = sample;
                    peer.rttSmooth[inbound.transport] = LinkPolicy.smoothRtt(
                      peer.rttSmooth[inbound.transport],
                      sample,
                    );
                    changed = true;
                  }
                  // v1.9.8: answered, so the link works (again).
                  peer.pingOut.remove(inbound.transport);
                  if ((peer.misses.remove(inbound.transport) ?? 0) > 0) {
                    peer.activeLink = _bestLink(peer, now);
                    changed = true;
                  }
                }
              case ControlKind.talkStart:
                peer.talking = true;
                changed = true;
              case ControlKind.talkEnd:
                peer.talking = false;
                changed = true;
              case ControlKind.fhello:
                break; // only between friends (FriendLinks)
              case ControlKind.dx:
                // Direct link signaling (v1.8.9): only straight from the
                // relay (never through the phone mesh), only for us.
                if (!relayed &&
                    inbound.transport == TransportKind.internet &&
                    msg.to == localNodeId &&
                    frameScope == scope) {
                  onDirectSignal?.call(peer.id, msg.x);
                }
              case ControlKind.ring:
              case ControlKind.beep:
              case ControlKind.ringAck:
              case ControlKind.friendReq:
              case ControlKind.friendAcc:
              case ControlKind.friendDec:
              case ControlKind.rekey:
              case ControlKind.rekeyAck:
                if (msg.to == null || msg.to == localNodeId) {
                  if (!_controls.isClosed) {
                    _controls.add(
                      InboundControl(
                        f.senderId,
                        frameScope,
                        msg,
                        inbound.transport,
                      ),
                    );
                  }
                }
            }
          }
        case FrameType.audio:
          if (frameScope == scope) {
            _audio.add(
              ReceivedAudio(
                f.senderId,
                f.seq,
                f.payload,
                inbound.transport,
                hops,
              ),
            );
          }
        case FrameType.data:
          if (!_data.isClosed) {
            _data.add(
              InboundData(f.senderId, frameScope, f.payload, inbound.transport),
            );
          }
        case FrameType.trip:
          if (!_trips.isClosed) {
            _trips.add(
              InboundTrip(
                f.senderId,
                frameScope,
                f.payload,
                inbound.transport,
                hops: hops,
                packetId: meshPacketId(frame.encode()),
                rssi: inbound.rssi,
              ),
            );
          }
        case FrameType.sealed:
        case FrameType.mesh:
        case FrameType.lobby:
        case FrameType.gateway:
        case FrameType.alert:
          break; // never nested / handled above
      }
    }
    if (changed || before == null) _emitPeers();
  }

  /// Mesh-only peers show "via N hops"; direct ones show their link.
  void _updateMeshHops(Peer p, DateTime now) {
    final seen = p.meshSeen;
    final meshAlive = seen != null && now.difference(seen) <= meshTimeout;
    p.meshHops = meshAlive && fastLinks(p, now).isEmpty ? p.hops : null;
  }

  /// Drop dead links/peers. Runs every second; public for tests.
  void prune() {
    final now = _clock();
    var changed = false;
    final gone = <int>[];
    mesh.prune();
    for (final p in _peers.values) {
      final timeout = timeoutFor(p);
      p.lastSeen.removeWhere((k, t) {
        final lt = _transportOf(k)?.linkTimeout ?? timeout;
        return now.difference(t) > lt;
      });
      p.rtt.removeWhere((k, _) => !p.lastSeen.containsKey(k));
      p.rttSmooth.removeWhere((k, _) => !p.lastSeen.containsKey(k));
      p.pingOut.removeWhere((k, _) => !p.lastSeen.containsKey(k));
      p.misses.removeWhere((k, _) => !p.lastSeen.containsKey(k));
      final best = _bestLink(p, now);
      if (best != p.activeLink) {
        p.activeLink = best;
        changed = true;
      }
      final ms = p.meshSeen;
      if (ms != null && now.difference(ms) > meshTimeout) p.meshSeen = null;
      final gs = p.gatewaySeen;
      if (gs != null && now.difference(gs) > gatewayPeerTimeout) {
        p.gatewaySeen = null;
        p.gatewayId = null;
      }
      final hopsBefore = p.meshHops;
      _updateMeshHops(p, now);
      if (hopsBefore != p.meshHops) changed = true;
      final gwBefore = p.viaGateway;
      _updateGatewayLabel(p, now);
      if (gwBefore != p.viaGateway) changed = true;
      if (p.lastSeen.isEmpty && p.meshSeen == null && p.gatewaySeen == null) {
        gone.add(p.id);
      }
    }
    final gwCount = _gateways.length;
    _gateways.removeWhere((_, g) => now.difference(g.at) > gatewayTimeout);
    if (gwCount != _gateways.length) changed = true;
    for (final id in gone) {
      _peers.remove(id);
      _seen.remove(id);
      _seenAudio.remove(id);
      changed = true;
    }
    if (changed) _emitPeers();
  }

  void _recomputeAll() {
    final now = _clock();
    for (final p in _peers.values) {
      p.activeLink = _bestLink(p, now);
    }
    _emitPeers();
  }

  void _emitPeers() {
    if (!_peerChanges.isClosed) _peerChanges.add(peers);
  }
}

/// The status line (v1.9.8): "Direct 42 ms · 3 backups ready".
class ConnectionSummary {
  const ConnectionSummary({
    required this.best,
    required this.bestRtt,
    required this.backups,
    required this.checkEvery,
    this.failing = false,
  });

  /// "Direct", "Home relay", "Wi-Fi", "Bluetooth", ... null = nothing up.
  final String? best;
  final Duration? bestRtt;

  /// Other paths that are up and ready to take over.
  final int backups;
  final Duration checkEvery;

  /// Some link to a phone just missed a check (backups are carrying it).
  final bool failing;

  String get text {
    final b = best;
    if (b == null) {
      return 'Looking for a connection · checking every '
          '${checkEvery.inSeconds} s';
    }
    final ms = bestRtt == null ? '' : ' ${bestRtt!.inMilliseconds} ms';
    final ready = switch (backups) {
      0 => 'no backup yet',
      1 => '1 backup ready',
      _ => '$backups backups ready',
    };
    return '$b$ms · $ready';
  }
}

/// A frame we sent recently and where it went (v1.9.8 failover).
class _RecentSend {
  _RecentSend(this.at, this.bytes, this.to);
  final DateTime at;
  final Uint8List bytes;
  final Map<TransportKind, Set<int>> to;
}

/// Remembers the last [size] sequence numbers seen from one sender.
class _SeqWindow {
  static const int size = 128;
  final _order = Queue<int>();
  final _set = <int>{};

  /// Returns false if [seq] was already seen.
  bool add(int seq) {
    if (_set.contains(seq)) return false;
    _set.add(seq);
    _order.addLast(seq);
    if (_order.length > size) _set.remove(_order.removeFirst());
    return true;
  }
}
