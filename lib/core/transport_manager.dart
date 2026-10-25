import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

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
    this.linkTimeout = const Duration(seconds: 4),
    this.helloInterval = const Duration(seconds: 1),
    this.staleAfter = const Duration(milliseconds: 1600),
    Clock? clock,
  }) : _transports = List.unmodifiable(transports),
       _clock = clock ?? DateTime.now;

  final List<Transport> _transports;
  final int localNodeId;
  final Duration linkTimeout;
  final Duration helloInterval;

  /// Best link quiet for longer than this => also send on the runner-up.
  final Duration staleAfter;
  final Clock _clock;

  /// Display name sent in hello beacons.
  String localName;
  int _channel;
  int _seq = 0;
  bool _running = false;
  bool _talking = false;

  final Map<int, Peer> _peers = {};
  final Map<int, _SeqWindow> _seen = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _helloTimer;
  Timer? _pruneTimer;

  final _audio = StreamController<ReceivedAudio>.broadcast();
  final _peerChanges = StreamController<List<Peer>>.broadcast();
  final _transportChanges = StreamController<void>.broadcast();

  List<Transport> get transports => _transports;
  int get channel => _channel;
  bool get isRunning => _running;

  Stream<ReceivedAudio> get audio => _audio.stream;
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
          await t.start(localNodeId: localNodeId, channel: _channel);
        } catch (_) {
          // Transport reports its own status; keep going.
        }
      }),
    );
    _helloTimer = Timer.periodic(helloInterval, (_) async {
      await sendHello();
      await sendPings();
    });
    _pruneTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => prune(),
    );
    await sendHello();
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
    await _peerChanges.close();
    await _transportChanges.close();
  }

  Future<void> setChannel(int channel) async {
    _channel = channel;
    for (final t in _transports) {
      try {
        await t.setChannel(channel);
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

  /// Broadcast presence on every running transport.
  Future<void> sendHello() => _broadcastControl(
    ControlMessage(
      ControlKind.hello,
      name: localName,
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
        final bytes = Frame.control(
          senderId: localNodeId,
          channel: _channel,
          seq: _nextSeq(),
          message: ControlMessage(
            ControlKind.ping,
            to: p.id,
            time: now.millisecondsSinceEpoch,
          ),
        ).encode();
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
        channel: _channel,
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
      channel: _channel,
      seq: _nextSeq(),
      payload: opus,
    ),
  );

  Future<void> _broadcastControl(ControlMessage msg) async {
    final bytes = Frame.control(
      senderId: localNodeId,
      channel: _channel,
      seq: _nextSeq(),
      message: msg,
    ).encode();
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
      if (p.channel != _channel) continue;
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
    final bytes = frame.encode();
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
    for (final kind in p.liveLinks(now, linkTimeout)) {
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

  /// Visible for tests: feed a frame as if a transport delivered it.
  void handleInbound(InboundFrame inbound) => _onInbound(inbound);

  void _onInbound(InboundFrame inbound) {
    final f = inbound.frame;
    if (f.senderId == localNodeId) return; // our own broadcast echoed back

    final now = _clock();
    final peer = _peers.putIfAbsent(f.senderId, () => Peer(f.senderId));
    peer.lastSeen[inbound.transport] = now;
    peer.channel = f.channel;

    final window = _seen.putIfAbsent(f.senderId, _SeqWindow.new);
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
                      Frame.control(
                        senderId: localNodeId,
                        channel: _channel,
                        seq: _nextSeq(),
                        message: ControlMessage(
                          ControlKind.pong,
                          to: peer.id,
                          time: msg.time,
                        ),
                      ).encode(),
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
            }
          }
        case FrameType.audio:
          if (f.channel == _channel) {
            _audio.add(ReceivedAudio(f.senderId, f.seq, f.payload));
          }
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
      p.lastSeen.removeWhere((_, t) => now.difference(t) > linkTimeout);
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
