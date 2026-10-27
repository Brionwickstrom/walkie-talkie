import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../app/power_plan.dart';
import '../lora/lora_transport.dart';

import 'channel_crypto.dart';
import 'lobby.dart';
import 'frame.dart';
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
  Duration get currentHelloInterval => _offline
      ? PowerPlan.offlineHello
      : (_saver ? saverHelloInterval : helloInterval);

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
  bool _talking = false;

  /// Phones blocked by the user: everything from them is dropped.
  final Set<int> blocked = {};

  /// Sealed frames our channel key does not open (friend links, see
  /// FriendLinks). Return true if handled.
  bool Function(InboundFrame inbound)? sealedHandler;

  /// Extra hello fields (feature level, channel name, admin...).
  Map<String, Object?> Function()? helloExtras;

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
      _subs.add(t.statusChanges.listen((_) => _transportChanges.add(null)));
    }
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
    _pruneTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => prune(),
    );
    await sendHello();
    await sendBeacon();
  }

  void _startHelloTimer() {
    _helloTimer?.cancel();
    _helloTimer = Timer.periodic(currentHelloInterval, (_) async {
      await sendHello();
      _maybeRadioHello();
      if (!_slow) await sendPings();
      final now = _clock();
      final last = _lastBeacon;
      if (last == null ||
          now.difference(last) >=
              beaconInterval - const Duration(milliseconds: 100)) {
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
    _helloTimer?.cancel();
    _radioHelloSoon?.cancel();
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

  /// Broadcast presence on every running transport.
  Future<void> sendHello() => _broadcastControl(
    ControlMessage(
      ControlKind.hello,
      name: localName,
      interval: _slow ? currentHelloInterval.inMilliseconds : null,
      x: helloExtras?.call() ?? const {},
      lanAddrs: [
        for (final t in _transports)
          if (t.status == TransportStatus.running) ...t.localAddresses,
      ],
    ),
  );

  /// Ping every peer on every usable link (for round-trip display). Cheap:
  /// ~40 bytes per link per [helloInterval].
  Future<void> sendPings() async {
    final now = _clock();
    final futures = <Future<void>>[];
    for (final p in _peers.values) {
      for (final kind in fastLinks(p, now)) {
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
    final now = _clock();
    final links = fastLinks(p, now);
    if (links.isEmpty) return const [];
    final bestSeen = p.lastSeen[links.first];
    if (links.length > 1 &&
        bestSeen != null &&
        now.difference(bestSeen) > staleAfter) {
      return [links[0], links[1]];
    }
    return [links.first];
  }

  /// Best usable link to [peerId], or null if it is not reachable now. A
  /// peer reachable only through the mesh reports [TransportKind.ble] (the
  /// slowest off-grid link) so transfers pace themselves conservatively.
  /// [TransportKind.lora] only when nothing else reaches it.
  TransportKind? bestLinkTo(int peerId) {
    final r = routeTo(peerId);
    if (r.isNotEmpty) return r.first;
    if (meshReachable(peerId)) return TransportKind.ble;
    return radioReachable(peerId) ? TransportKind.lora : null;
  }

  bool isReachable(int peerId) =>
      routeTo(peerId).isNotEmpty ||
      meshReachable(peerId) ||
      radioReachable(peerId);

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
    final route = routeTo(peerId);
    if (route.isEmpty) {
      if (meshReachable(peerId)) {
        final r = mesh.originate(_wire(frame), to: peerId);
        if (r != null) {
          _sendMesh(r);
          return true;
        }
      }
      // Last resort: the LoRa radio (only what it may carry).
      if (radioReachable(peerId)) {
        return _sendRadio(frame, _wire(frame), {peerId});
      }
      return false;
    }
    final bytes = _wire(frame);
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
    if (to != null) {
      if (fast) {
        final route = routeTo(to);
        if (route.isNotEmpty) {
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
      return targets;
    }
    if (fast) {
      final routes = routeForChannel();
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
      final links = fastLinks(p, now);
      if (links.isEmpty) continue;
      routes.putIfAbsent(links.first, () => <int>{}).add(p.id);
      final bestSeen = p.lastSeen[links.first];
      if (links.length > 1 &&
          bestSeen != null &&
          now.difference(bestSeen) > staleAfter) {
        routes.putIfAbsent(links[1], () => <int>{}).add(p.id);
      }
    }
    return routes;
  }

  Future<void> _sendToChannel(Frame frame) async {
    final bytes = _wire(frame);
    final routes = routeForChannel();
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
      if (far.isNotEmpty) _sendRadio(frame, bytes, far);
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
      // traffic moves to the next best transport.
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
    ts.sort((a, b) => b.priority.compareTo(a.priority));
    return [for (final t in ts) t.kind];
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

  void _receive(Frame frame, InboundFrame inbound, int hops) {
    var f = frame;
    final relayed = hops > 1;
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
    } else if (key != null) {
      return;
    }
    final frameScope = key == null ? f.channel : scope;

    final now = _clock();
    final peer = _peers.putIfAbsent(f.senderId, () => Peer(f.senderId));
    final wasMeshHops = peer.meshHops;
    final viaSlow = _transportOf(inbound.transport)?.lowBandwidth ?? false;
    if (viaSlow && !relayed) {
      final prev = peer.lastSeen[inbound.transport];
      final t = _transportOf(inbound.transport)!;
      if (prev == null || now.difference(prev) > _linkTimeout(t, peer)) {
        _radioHelloSoonAfterNewPeer();
      }
    }
    if (relayed) {
      peer.meshSeen = now;
      peer.hops = hops;
    } else {
      peer.lastSeen[inbound.transport] = now;
      final rssi = inbound.rssi;
      if (rssi != null && rssi != 0) peer.rssi[inbound.transport] = rssi;
    }
    peer.channel = frameScope;
    _updateMeshHops(peer, now);
    var meshChanged = wasMeshHops != peer.meshHops;

    final window = (f.type == FrameType.audio ? _seenAudio : _seen).putIfAbsent(
      f.senderId,
      _SeqWindow.new,
    );
    final duplicate = !window.add(f.seq);

    final before = peer.activeLink;
    peer.activeLink = _bestLink(peer, now);
    var changed = before != peer.activeLink || meshChanged;

    if (!duplicate) {
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
                    peer.rtt[inbound.transport] = Duration(milliseconds: rtt);
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
      final best = _bestLink(p, now);
      if (best != p.activeLink) {
        p.activeLink = best;
        changed = true;
      }
      final ms = p.meshSeen;
      if (ms != null && now.difference(ms) > meshTimeout) p.meshSeen = null;
      final hopsBefore = p.meshHops;
      _updateMeshHops(p, now);
      if (hopsBefore != p.meshHops) changed = true;
      if (p.lastSeen.isEmpty && p.meshSeen == null) gone.add(p.id);
    }
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
