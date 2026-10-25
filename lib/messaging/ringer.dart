import 'dart:async';
import 'dart:math';

import '../core/frame.dart';
import '../core/transport_manager.dart';

/// What the [Ringer] needs from the transport layer.
abstract class RingLink {
  int get channel;
  Set<int> reachablePeersOn(int channel);
  bool isReachable(int peerId);
  Future<bool> sendControlTo(int peerId, ControlMessage msg);
  Future<Set<int>> sendControlToChannel(ControlMessage msg);
  Stream<InboundControl> get controls;
}

class ManagerRingLink implements RingLink {
  ManagerRingLink(this.m);
  final TransportManager m;
  @override
  int get channel => m.channel;
  @override
  Set<int> reachablePeersOn(int channel) => m.reachablePeersOn(channel);
  @override
  bool isReachable(int peerId) => m.isReachable(peerId);
  @override
  Future<bool> sendControlTo(int peerId, ControlMessage msg) =>
      m.sendControlTo(peerId, msg);
  @override
  Future<Set<int>> sendControlToChannel(ControlMessage msg) =>
      m.sendControlToChannel(msg);
  @override
  Stream<InboundControl> get controls => m.controls;
}

/// A ring or beep we sent.
class OutgoingRing {
  OutgoingRing(this.id, this.beep, this.toPeer, this.sentAt);
  final int id;
  final bool beep;
  final int? toPeer;
  final DateTime sentAt;
  final Map<int, RingStatus> status = {};
  int attempts = 1;
  DateTime lastSent = DateTime.fromMillisecondsSinceEpoch(0);
}

/// A ring or beep someone sent us.
class IncomingRing {
  IncomingRing(this.from, this.id, this.beep, this.channel, this.at);
  final int from;
  final int id;
  final bool beep;
  final int channel;
  final DateTime at;
  RingStatus status = RingStatus.delivered;
}

/// Ring / beep: send with retries until each phone acknowledges, answer /
/// dismiss / time out incoming rings, track delivery status per phone.
class Ringer {
  Ringer({
    required this.link,
    Clock? clock,
    Random? random,
    this.retryInterval = const Duration(seconds: 1),
    this.maxAttempts = 6,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random();

  final RingLink link;
  final Clock _clock;
  final Random _random;
  final Duration retryInterval;
  final int maxAttempts;

  final List<OutgoingRing> _out = [];
  final Map<(int, int), IncomingRing> _in = {};
  StreamSubscription<InboundControl>? _sub;

  final _incoming = StreamController<IncomingRing>.broadcast();
  final _changes = StreamController<void>.broadcast();

  /// New (not duplicate) incoming ring/beep.
  Stream<IncomingRing> get incoming => _incoming.stream;
  Stream<void> get changes => _changes.stream;

  void start() => _sub ??= link.controls.listen(onControl);

  Future<void> dispose() async {
    await _sub?.cancel();
    await _incoming.close();
    await _changes.close();
  }

  /// Latest status of a ring/beep we sent to [peer], if recent.
  (RingStatus, bool beep)? statusFor(
    int peer, {
    Duration within = const Duration(seconds: 60),
  }) {
    final now = _clock();
    for (final r in _out.reversed) {
      if (now.difference(r.sentAt) > within) break;
      final s = r.status[peer];
      if (s != null) return (s, r.beep);
    }
    return null;
  }

  OutgoingRing? get last => _out.isEmpty ? null : _out.last;

  /// Ring (or beep) [toPeer], or everyone on our channel when null.
  Future<OutgoingRing> ring({int? toPeer, bool beep = false}) async {
    final now = _clock();
    final r = OutgoingRing(_random.nextInt(0x7FFFFFFF) + 1, beep, toPeer, now);
    _out.add(r);
    if (_out.length > 20) _out.removeAt(0);
    final kind = beep ? ControlKind.beep : ControlKind.ring;
    r.lastSent = now;
    if (toPeer != null) {
      final ok = await link.sendControlTo(
        toPeer,
        ControlMessage(kind, to: toPeer, id: r.id),
      );
      r.status[toPeer] = ok ? RingStatus.sending : RingStatus.unreachable;
    } else {
      final targets = await link.sendControlToChannel(
        ControlMessage(kind, id: r.id),
      );
      for (final p in targets) {
        r.status[p] = RingStatus.sending;
      }
    }
    _changed();
    return r;
  }

  /// Resend unacknowledged rings. Call about every second.
  Future<void> tick() async {
    final now = _clock();
    var changed = false;
    for (final r in _out) {
      if (!r.status.values.contains(RingStatus.sending)) continue;
      if (now.difference(r.lastSent) < retryInterval) continue;
      r.lastSent = now;
      r.attempts++;
      for (final e in r.status.entries.toList()) {
        if (e.value != RingStatus.sending) continue;
        if (r.attempts > maxAttempts) {
          r.status[e.key] = RingStatus.unreachable;
          changed = true;
          continue;
        }
        if (!link.isReachable(e.key)) continue;
        await link.sendControlTo(
          e.key,
          ControlMessage(
            r.beep ? ControlKind.beep : ControlKind.ring,
            to: e.key,
            id: r.id,
          ),
        );
      }
    }
    if (changed) _changed();
  }

  Future<void> onControl(InboundControl c) async {
    final m = c.message;
    final id = m.id;
    if (id == null) return;
    switch (m.kind) {
      case ControlKind.ring:
      case ControlKind.beep:
        // Channel-wide rings only for phones on that channel.
        if (m.to == null && c.channel != link.channel) return;
        final key = (c.peerId, id);
        final existing = _in[key];
        if (existing != null) {
          // Our ack was lost; repeat the current state.
          await _ack(existing);
          return;
        }
        final r = IncomingRing(
          c.peerId,
          id,
          m.kind == ControlKind.beep,
          c.channel,
          _clock(),
        );
        _in[key] = r;
        if (_in.length > 50) _in.remove(_in.keys.first);
        await _ack(r);
        if (!_incoming.isClosed) _incoming.add(r);
        _changed();
      case ControlKind.ringAck:
        final st = RingStatus.values.asNameMap()[m.status];
        if (st == null) return;
        for (final r in _out) {
          if (r.id != id) continue;
          final cur = r.status[c.peerId];
          // Never go back from a final answer to "delivered".
          if (cur == null ||
              cur == RingStatus.sending ||
              cur == RingStatus.unreachable ||
              (cur == RingStatus.delivered && st != RingStatus.delivered)) {
            r.status[c.peerId] = st;
            _changed();
          }
        }
      default:
        return;
    }
  }

  IncomingRing? incomingById(int from, int id) => _in[(from, id)];

  /// The user answered / dismissed, or it timed out (missed).
  Future<void> respond(IncomingRing r, RingStatus status) async {
    if (r.status != RingStatus.delivered) return;
    r.status = status;
    await _ack(r);
    _changed();
  }

  Future<void> _ack(IncomingRing r) => link.sendControlTo(
    r.from,
    ControlMessage(
      ControlKind.ringAck,
      to: r.from,
      id: r.id,
      status: r.status.name,
    ),
  );

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
