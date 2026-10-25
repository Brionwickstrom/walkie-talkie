import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'channel_crypto.dart';
import 'frame.dart';
import 'peer.dart';
import 'transport.dart';

/// Audio received from a peer, ready for the decoder.
class ReceivedAudio {
  ReceivedAudio(this.peerId, this.seq, this.opus);
  final int peerId;
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

/// A ring / beep / ring-ack control message from a peer.
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
    Clock? clock,
  }) : _transports = List.unmodifiable(transports),
       _clock = clock ?? DateTime.now,
       _key = channelKey;

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
  Duration get currentHelloInterval =>
      _saver ? saverHelloInterval : helloInterval;

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
  }

  void _startHelloTimer() {
    _helloTimer?.cancel();
    _helloTimer = Timer.periodic(currentHelloInterval, (_) async {
      await sendHello();
      if (!_saver) await sendPings();
    });
  }

  /// Turn battery saver on/off for the manager and every transport.
  Future<void> setPowerSaver(bool on) async {
    if (on == _saver) return;
    _saver = on;
    for (final t in _transports) {
      try {
        t.setPowerSaver(on);
      } catch (_) {}
    }
    if (_running) {
      _startHelloTimer();
      await sendHello();
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _helloTimer?.cancel();
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

  /// Broadcast presence on every running transport.
  Future<void> sendHello() => _broadcastControl(
    ControlMessage(
      ControlKind.hello,
      name: localName,
      interval: _saver ? saverHelloInterval.inMilliseconds : null,
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
      for (final kind in usableLinks(p, now)) {
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
    final links = usableLinks(p, now);
    if (links.isEmpty) return const [];
    final bestSeen = p.lastSeen[links.first];
    if (links.length > 1 &&
        bestSeen != null &&
        now.difference(bestSeen) > staleAfter) {
      return [links[0], links[1]];
    }
    return [links.first];
  }

  /// Best usable link to [peerId], or null if it is not reachable now.
  TransportKind? bestLinkTo(int peerId) {
    final r = routeTo(peerId);
    return r.isEmpty ? null : r.first;
  }

  bool isReachable(int peerId) => routeTo(peerId).isNotEmpty;

  /// Peers currently reachable and on [channel].
  Set<int> reachablePeersOn(int channel) => {
    for (final p in _peers.values)
      if (p.channel == channel && isReachable(p.id)) p.id,
  };

  /// Unicast [frame] to one peer over its best link(s). False if the peer
  /// is not reachable right now.
  Future<bool> sendFrameTo(int peerId, Frame frame) async {
    final route = routeTo(peerId);
    if (route.isEmpty) return false;
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
          .where((t) => t.status == TransportStatus.running)
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
      final links = usableLinks(p, now);
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
    await Future.wait(
      routes.entries.map((e) {
        final t = _transports.firstWhere((t) => t.kind == e.key);
        return _safeSend(t, bytes, e.value);
      }),
    );
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
    for (final kind in p.liveLinks(now, timeoutFor(p))) {
      final t = _transportOf(kind);
      if (t == null || t.status != TransportStatus.running) continue;
      if (!t.canReach(p.id)) continue;
      ts.add(t);
    }
    ts.sort((a, b) => b.priority.compareTo(a.priority));
    return [for (final t in ts) t.kind];
  }

  TransportKind? _bestLink(Peer p, DateTime now) {
    final l = usableLinks(p, now);
    return l.isEmpty ? null : l.first;
  }

  Transport? _transportOf(TransportKind kind) {
    for (final t in _transports) {
      if (t.kind == kind) return t;
    }
    return null;
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
    var f = inbound.frame;
    if (f.senderId == localNodeId) return; // our own broadcast echoed back
    if (blocked.contains(f.senderId)) return;

    // Private channels: only frames that decrypt with our key count. Plain
    // frames are ignored while private, sealed ones while public, so phones
    // without the passcode never show up, ring or play audio (and vice
    // versa). Nothing is recorded about rejected frames.
    final key = _key;
    if (f.type == FrameType.sealed) {
      final opened = key?.open(f);
      if (opened == null) {
        sealedHandler?.call(inbound);
        return;
      }
      f = opened;
    } else if (key != null) {
      return;
    }
    final frameScope = key == null ? f.channel : scope;

    final now = _clock();
    final peer = _peers.putIfAbsent(f.senderId, () => Peer(f.senderId));
    peer.lastSeen[inbound.transport] = now;
    peer.channel = frameScope;

    final window = (f.type == FrameType.audio ? _seenAudio : _seen).putIfAbsent(
      f.senderId,
      _SeqWindow.new,
    );
    final duplicate = !window.add(f.seq);

    final before = peer.activeLink;
    peer.activeLink = _bestLink(peer, now);
    var changed = before != peer.activeLink;

    if (!duplicate) {
      switch (f.type) {
        case FrameType.control:
          final msg = f.control;
          if (msg != null) {
            switch (msg.kind) {
              case ControlKind.hello:
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
                if (msg.to == null || msg.to == localNodeId) {
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
                if (msg.to == localNodeId && msg.time != null) {
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
            _audio.add(ReceivedAudio(f.senderId, f.seq, f.payload));
          }
        case FrameType.data:
          if (!_data.isClosed) {
            _data.add(
              InboundData(f.senderId, frameScope, f.payload, inbound.transport),
            );
          }
        case FrameType.sealed:
          break; // never nested
      }
    }
    if (changed || before == null) _emitPeers();
  }

  /// Drop dead links/peers. Runs every second; public for tests.
  void prune() {
    final now = _clock();
    var changed = false;
    final gone = <int>[];
    for (final p in _peers.values) {
      final timeout = timeoutFor(p);
      p.lastSeen.removeWhere((_, t) => now.difference(t) > timeout);
      p.rtt.removeWhere((k, _) => !p.lastSeen.containsKey(k));
      final best = _bestLink(p, now);
      if (best != p.activeLink) {
        p.activeLink = best;
        changed = true;
      }
      if (p.lastSeen.isEmpty) gone.add(p.id);
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
