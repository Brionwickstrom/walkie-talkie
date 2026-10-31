import 'dart:async';

import 'package:flutter/foundation.dart';

import '../lora/meshtastic_proto.dart';
import '../lora/meshtastic_session.dart';
import '../lora/protobuf.dart';
import 'geo.dart';
import 'range_test.dart';
import 'trip_controller.dart' show Fix;

/// What range logging needs from the connected radio (a thin view on the
/// radio session, so it can be tested without one).
abstract class RangeRadio {
  /// Packets heard from other nodes.
  Stream<RadioHeard> get heard;

  /// Answers from our own radio (routing errors for a packet we sent).
  Stream<MeshPacketPb> get replies;

  /// The radio is set up and has room in its transmit queue.
  bool get canPing;

  /// Send a small want-ack packet to [node]; returns its id.
  Future<int> ping(int node);

  /// Where [node] says it is, if it shares a position.
  GeoPoint? positionOf(int node);

  String nameOf(int node);
}

class SessionRangeRadio implements RangeRadio {
  SessionRangeRadio(this.s);
  final MeshtasticSession s;

  @override
  Stream<RadioHeard> get heard => s.heard;

  @override
  Stream<MeshPacketPb> get replies => s.adminReplies;

  @override
  bool get canPing =>
      s.configured && s.myNodeNum != null && (s.queueFree ?? 3) >= 2;

  /// One byte on the private port to the home radio, reliable (the radio
  /// answers with an ack), one relay at most so a ping does not flood the
  /// public slot. The packet is unreadable to anyone but the home radio's
  /// channel key holders; it holds no name, place or key.
  @override
  Future<int> ping(int node) => s.send(
    Uint8List.fromList(const [0x50]),
    to: node,
    wantAck: true,
    priority: MeshPacketPb.priorityReliable,
    hopLimitOverride: 1,
  );

  @override
  GeoPoint? positionOf(int node) {
    final n = s.nodes[node];
    if (n?.lat == null || n?.lng == null) return null;
    return GeoPoint(n!.lat!, n.lng!);
  }

  @override
  String nameOf(int node) {
    final n = s.nodes[node];
    return n != null && n.longName.isNotEmpty
        ? n.longName
        : radioNodeLabel(node);
  }
}

String radioNodeLabel(int n) => '!${n.toRadixString(16).padLeft(8, '0')}';

/// Range logging on the phone (v2.5.9). OFF until switched on: nothing runs,
/// nothing is sent, no GPS is asked for.
///
/// On:
///  * every packet the connected radio hears from the home radio is logged
///    with the phone's own GPS fix (a point per packet, at most one every
///    2 s; free, the radio hears it anyway);
///  * a ping (small want-ack packet) goes to the home radio every 30 s while
///    the phone is plugged in, else every 60 to 120 s (default 90). A ping
///    is a radio transmit (plus up to 3 retries when unanswered) and costs
///    battery on the radio; never faster than 30 s, to spare the airtime of
///    the shared public slot;
///  * an unanswered ping is a "no reply" point at the phone's GPS, so the
///    edge of the coverage shows;
///  * the first answered ping after nothing / a drop is a CONNECT marker; two
///    unanswered pings in a row after a connect are a DROP marker (at the
///    first one), like the PC range test.
/// No ping and no point without a GPS fix younger than [fixMaxAge].
class RangeLogger extends ChangeNotifier {
  RangeLogger({
    required this.store,
    required this.fix,
    required this.plugged,
    DateTime Function()? clock,
    this.ackTimeout = const Duration(seconds: 20),
    this.fixMaxAge = const Duration(seconds: 30),
    this.firstPing = const Duration(seconds: 2),
  }) : _clock = clock ?? DateTime.now {
    store.addListener(_onStore);
  }

  final RangeTest store;
  final Fix? Function() fix;
  final bool Function() plugged;
  final DateTime Function() _clock;
  final Duration ackTimeout;
  final Duration fixMaxAge;
  final Duration firstPing;

  /// The fastest a ping may go (LoRa airtime).
  static const Duration minPingGap = Duration(seconds: 30);
  static const Duration passiveGap = Duration(seconds: 2);

  RangeRadio? _radio;
  StreamSubscription<RadioHeard>? _heardSub;
  StreamSubscription<MeshPacketPb>? _replySub;
  Timer? _timer;
  DateTime? _lastPing;
  DateTime? _lastPassive;
  bool _busy = false;
  bool _on = false;
  bool _disposed = false;
  int? _pendingId;
  Completer<({bool ok, RadioHeard? h})>? _answer;

  // connect / drop state
  bool? _connected;
  int _failStreak = 0;
  ({DateTime at, GeoPoint pos})? _firstFail;

  /// What is going on, in plain words (shown on the page).
  String status = 'Off';
  DateTime? lastPingAt;
  SampleKind? lastResult;
  int pings = 0;
  int replies = 0;
  int skippedNoGps = 0;

  /// The radio to use (null = none connected).
  RangeRadio? get radio => _radio;

  void bind(RangeRadio? r) {
    if (identical(r, _radio)) return;
    _stopListening();
    _radio = r;
    _connected = null;
    _failStreak = 0;
    _firstFail = null;
    _sync();
  }

  /// Seconds between pings right now.
  Duration get interval {
    if (plugged()) return minPingGap;
    final d = Duration(seconds: store.pingSecs.clamp(60, 120));
    return d < minPingGap ? minPingGap : d;
  }

  void _onStore() {
    if (store.homeNode != _homeSeen) {
      _connected = null;
      _failStreak = 0;
      _firstFail = null;
    }
    if (store.logging != _on || store.homeNode != _homeSeen) _sync();
  }

  int? _homeSeen;

  /// Plugged in / unplugged: pick the ping interval again.
  void powerChanged() {
    if (_on) _schedule();
  }

  void _sync() {
    if (_disposed) return;
    final want = store.logging && _radio != null;
    _homeSeen = store.homeNode;
    if (want != _on || (want && _heardSub == null)) {
      _on = want;
      _stopListening();
      if (want) {
        _heardSub = _radio!.heard.listen(_onHeard);
        _replySub = _radio!.replies.listen(_onReply);
        status = 'Waiting for the first ping';
        _schedule();
      } else {
        _timer?.cancel();
        _timer = null;
        status = store.logging ? 'No radio connected' : 'Off';
      }
    } else if (!want) {
      status = store.logging ? 'No radio connected' : 'Off';
    }
    if (_on && _heardSub != null) _schedule();
    notifyListeners();
  }

  void _stopListening() {
    _heardSub?.cancel();
    _replySub?.cancel();
    _heardSub = _replySub = null;
    _timer?.cancel();
    _timer = null;
    final a = _answer;
    if (a != null && !a.isCompleted) a.complete((ok: false, h: null));
    _pendingId = null;
  }

  void _schedule() {
    _timer?.cancel();
    if (!_on || _disposed) return;
    final now = _clock();
    final due = _lastPing == null
        ? now.add(firstPing)
        : _lastPing!.add(interval);
    var wait = due.difference(now);
    if (wait < Duration.zero) wait = Duration.zero;
    _timer = Timer(wait, () => unawaited(_pingOnce()));
  }

  Fix? _freshFix() {
    final f = fix();
    if (f == null || !f.pos.valid) return null;
    if (_clock().difference(f.at) > fixMaxAge) return null;
    return f;
  }

  /// One ping now (the timer calls this; tests too).
  @visibleForTesting
  Future<void> pingNow() => _pingOnce();

  Future<void> _pingOnce() async {
    if (!_on || _busy || _disposed) return;
    final r = _radio;
    if (r == null) return;
    _busy = true;
    try {
      final f = _freshFix();
      if (f == null) {
        skippedNoGps++;
        status = 'Waiting for a GPS fix (no ping sent)';
        return;
      }
      if (!r.canPing) {
        status = 'Radio busy or not ready (no ping sent)';
        return;
      }
      final sentAt = _clock();
      final home = store.homeNode;
      final answer = Completer<({bool ok, RadioHeard? h})>();
      _answer = answer;
      int id;
      try {
        id = await r.ping(home);
      } catch (_) {
        _answer = null;
        status = 'Could not send the ping';
        return;
      }
      _pendingId = id;
      _lastPing = sentAt;
      pings++;
      final res = await answer.future.timeout(
        ackTimeout,
        onTimeout: () => (ok: false, h: null),
      );
      _pendingId = null;
      _answer = null;
      if (!_on || _disposed) return;
      _result(f, sentAt, res.ok, res.h, r);
    } finally {
      _busy = false;
      if (_on && !_disposed) _schedule();
      if (!_disposed) notifyListeners();
    }
  }

  void _result(Fix f, DateTime at, bool ok, RadioHeard? h, RangeRadio r) {
    lastPingAt = at;
    final home = store.homeNode;
    final dist = r.positionOf(home);
    final distM = dist == null ? null : distanceM(dist, f.pos);
    if (ok) {
      replies++;
      lastResult = SampleKind.ok;
      unawaited(
        store.addSample(
          RangeSample(
            at: at,
            pos: f.pos,
            kind: SampleKind.ok,
            snr: h?.snr == 0 ? null : h?.snr,
            rssi: h?.rssi == 0 ? null : h?.rssi,
            hops: h?.hops,
            from: home,
          ),
        ),
      );
      _failStreak = 0;
      _firstFail = null;
      if (_connected != true) {
        _connected = true;
        unawaited(
          store.add([
            RangeEvent(
              kind: RangeKind.connect,
              at: at,
              pos: f.pos,
              snr: h?.snr == 0 ? null : h?.snr,
              hops: h?.hops,
              distM: distM,
              approximate: false,
            ),
          ]),
        );
      }
      status =
          'Reply from ${r.nameOf(home)}'
          '${h != null && h.snr != 0 ? ', SNR ${h.snr}' : ''}';
    } else {
      lastResult = SampleKind.fail;
      unawaited(
        store.addSample(
          RangeSample(at: at, pos: f.pos, kind: SampleKind.fail, from: home),
        ),
      );
      _failStreak++;
      _firstFail ??= (at: at, pos: f.pos);
      if (_failStreak == 2 && _connected == true) {
        _connected = false;
        final ff = _firstFail!;
        unawaited(
          store.add([
            RangeEvent(
              kind: RangeKind.drop,
              at: ff.at,
              pos: ff.pos,
              distM: dist == null ? null : distanceM(dist, ff.pos),
              approximate: false,
            ),
          ]),
        );
      } else if (_connected == null && _failStreak >= 2) {
        _connected = false; // never connected: no drop to mark
      }
      status = 'No reply from ${r.nameOf(home)}';
    }
  }

  void _onHeard(RadioHeard h) {
    if (!_on || h.from != store.homeNode) return;
    final id = _pendingId;
    if (id != null && h.port == PortNum.routing && h.requestId == id) {
      final a = _answer;
      if (a != null && !a.isCompleted) a.complete((ok: true, h: h));
      return; // logged as the ping's result, not twice
    }
    final now = _clock();
    if (_lastPassive != null && now.difference(_lastPassive!) < passiveGap) {
      return;
    }
    final f = _freshFix();
    if (f == null) return;
    _lastPassive = now;
    unawaited(
      store.addSample(
        RangeSample(
          at: now,
          pos: f.pos,
          kind: SampleKind.heard,
          snr: h.snr == 0 ? null : h.snr,
          rssi: h.rssi == 0 ? null : h.rssi,
          hops: h.hops,
          from: h.from,
        ),
      ),
    );
  }

  /// Our own radio says the ping failed (no route, retries used up).
  void _onReply(MeshPacketPb p) {
    final d = p.decoded;
    final id = _pendingId;
    if (d == null || id == null || d.portnum != PortNum.routing) return;
    if (d.requestId != id) return;
    var err = 0;
    try {
      for (final f in pbDecode(d.payload)) {
        if (f.number == 3) err = f.asInt;
      }
    } catch (_) {}
    if (err != 0) {
      final a = _answer;
      if (a != null && !a.isCompleted) a.complete((ok: false, h: null));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_onStore);
    _stopListening();
    super.dispose();
  }
}
