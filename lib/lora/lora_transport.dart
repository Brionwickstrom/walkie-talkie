import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/transport.dart';
import 'meshtastic_proto.dart';

/// What the LoRa transport needs from a paired Meshtastic radio
/// ([MeshtasticRadio] in the app, a fake in tests).
abstract class RadioLink {
  /// Connected and configured: packets can go out.
  bool get ready;
  Stream<bool> get readyChanges;

  /// Decoded mesh packets from other nodes.
  Stream<MeshPacketPb> get packets;

  /// Free slots in the radio's transmit queue, null if unknown.
  int? get queueFree;

  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
  });
}

/// Order in which queued radio packets go out.
///
/// [sos] (Trip SOS and its answers) jumps the queue but still uses the
/// same rate limiter, so the radio stays within its duty cycle.
enum LoraPriority { sos, urgent, normal, bulk, presence }

/// Token bucket: at most [burst] packets at once, then one every
/// [refillEvery]. LoRa LongFast needs ~1-2 s of airtime per full packet
/// and every Meshtastic node repeats it, so the app keeps to a few packets
/// per minute.
class LoraRateLimiter {
  LoraRateLimiter({
    this.burst = 4,
    this.refillEvery = const Duration(seconds: 8),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _tokens = burst.toDouble();

  final int burst;
  final Duration refillEvery;
  final DateTime Function() _clock;
  double _tokens;
  DateTime? _at;

  double get tokens {
    _refill();
    return _tokens;
  }

  void _refill() {
    final now = _clock();
    final last = _at;
    _at = now;
    if (last == null) return;
    final dt = now.difference(last).inMicroseconds;
    if (dt <= 0) return;
    _tokens = min(burst.toDouble(), _tokens + dt / refillEvery.inMicroseconds);
  }

  bool tryTake() {
    _refill();
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }

  /// Time until the next packet may go.
  Duration get wait {
    _refill();
    if (_tokens >= 1) return Duration.zero;
    return Duration(
      microseconds: ((1 - _tokens) * refillEvery.inMicroseconds).ceil(),
    );
  }
}

class _Queued {
  _Queued(this.bytes, this.peers, this.priority, this.at, this.seq);
  final Uint8List bytes;
  final Set<int>? peers;
  final LoraPriority priority;
  final DateTime at;
  final int seq;
}

/// Signal of the last LoRa packet heard from an app phone.
class LoraPeerSignal {
  LoraPeerSignal(this.node, this.snr, this.rssi, this.hopsAway, this.at);

  /// Meshtastic node number of that phone's radio.
  final int node;
  final double snr;
  final int rssi;
  final int? hopsAway;
  final DateTime at;
}

/// App frames over a Meshtastic LoRa radio (v1.7.0).
///
/// * Each LoRa packet carries one app [Frame] (sealed on private channels
///   and for friends, so the radio mesh only ever sees ciphertext) as a
///   `PRIVATE_APP` (256) payload, which the stock Meshtastic apps ignore.
/// * It is the slowest link ([TransportKind.lora], lowest priority) and
///   [lowBandwidth]: the [TransportManager] never sends hellos every second,
///   pings, mesh beacons, live audio or relayed mesh frames here, only what
///   it hands to [sendRadio] for phones it cannot reach any other way.
///   Plain [send] calls (friend presence and the like) are dropped.
/// * Everything goes through a priority queue and a [LoraRateLimiter];
///   stale entries expire after [maxQueueAge] (the messenger re-sends).
/// * Meshtastic repeats packets itself (hop limit), so the app mesh never
///   relays LoRa frames again.
class LoraTransport extends Transport {
  LoraTransport({
    required this.radio,
    LoraRateLimiter? limiter,
    DateTime Function()? clock,
    this.peerTimeout = const Duration(minutes: 16),
    this.maxQueue = 24,
    this.maxQueueAge = const Duration(minutes: 3),
    this.pumpInterval = const Duration(milliseconds: 500),
  }) : _clock = clock ?? DateTime.now,
       limiter = limiter ?? LoraRateLimiter(clock: clock);

  final RadioLink radio;
  final LoraRateLimiter limiter;
  final DateTime Function() _clock;

  /// A phone heard over LoRa counts as reachable this long (its presence
  /// beacon comes every ~5 min).
  final Duration peerTimeout;
  final int maxQueue;
  final Duration maxQueueAge;
  final Duration pumpInterval;

  final _status = StreamController<TransportStatus>.broadcast();
  final _frames = StreamController<InboundFrame>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];
  final List<_Queued> _queue = [];
  final Map<int, LoraPeerSignal> _peers = {};
  Timer? _pump;
  bool _started = false;
  int _seq = 0;

  int sentPackets = 0;
  int receivedPackets = 0;
  int droppedGeneric = 0;
  int expired = 0;
  int overflow = 0;

  @override
  TransportKind get kind => TransportKind.lora;
  @override
  bool get lowBandwidth => true;
  @override
  Duration? get linkTimeout => peerTimeout;

  @override
  TransportStatus get status => !_started
      ? TransportStatus.stopped
      : radio.ready
      ? TransportStatus.running
      : TransportStatus.unavailable;

  @override
  String? get statusDetail => radio.ready ? null : 'No radio connected';

  @override
  Stream<TransportStatus> get statusChanges => _status.stream;
  @override
  Stream<InboundFrame> get frames => _frames.stream;

  /// Packets waiting for airtime.
  int get queued => _queue.length;

  /// Phones heard over LoRa (app node id -> last signal).
  Map<int, LoraPeerSignal> get peerSignals => Map.unmodifiable(_peers);

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    if (_started) return;
    _started = true;
    _subs.add(radio.packets.listen(onPacket));
    _subs.add(
      radio.readyChanges.listen((_) {
        if (!_status.isClosed) _status.add(status);
      }),
    );
    _pump = Timer.periodic(pumpInterval, (_) => pump());
    if (!_status.isClosed) _status.add(status);
  }

  @override
  Future<void> stop() async {
    _started = false;
    _pump?.cancel();
    _pump = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _queue.clear();
    if (!_status.isClosed) _status.add(status);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _status.close();
    await _frames.close();
  }

  /// A mesh packet from the radio (public for tests).
  void onPacket(MeshPacketPb p) {
    final d = p.decoded;
    if (d == null || d.portnum != PortNum.privateApp) return;
    final f = Frame.tryDecode(d.payload);
    if (f == null) return;
    receivedPackets++;
    _peers[f.senderId] = LoraPeerSignal(
      p.from,
      p.rxSnr,
      p.rxRssi,
      p.hopsAway,
      _clock(),
    );
    if (!_frames.isClosed) {
      _frames.add(
        InboundFrame(
          f,
          TransportKind.lora,
          rssi: p.rxRssi == 0 ? null : p.rxRssi,
        ),
      );
    }
  }

  @override
  bool canReach(int peerId) {
    if (status != TransportStatus.running) return false;
    final s = _peers[peerId];
    return s != null && _clock().difference(s.at) <= peerTimeout;
  }

  /// Generic sends are not allowed on the radio (see class doc).
  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    droppedGeneric++;
  }

  /// Queue an encoded frame for [peerIds] (null = every app phone in radio
  /// range). Returns false if it does not fit a LoRa packet or the radio is
  /// not connected.
  bool sendRadio(
    Uint8List frame, {
    Set<int>? peerIds,
    LoraPriority priority = LoraPriority.normal,
  }) {
    if (status != TransportStatus.running) return false;
    if (frame.length > loraPayloadBudget) return false;
    final now = _clock();
    // The same bytes queued twice (a retry racing the first copy).
    for (final q in _queue) {
      if (_same(q.bytes, frame)) return true;
    }
    if (priority == LoraPriority.presence) {
      _queue.removeWhere((q) => q.priority == LoraPriority.presence);
    }
    _queue.add(_Queued(frame, peerIds, priority, now, _seq++));
    while (_queue.length > maxQueue) {
      // Drop the least important, oldest packet.
      _Queued? worst;
      for (final q in _queue) {
        if (worst == null ||
            q.priority.index > worst.priority.index ||
            (q.priority == worst.priority && q.seq < worst.seq)) {
          worst = q;
        }
      }
      _queue.remove(worst);
      overflow++;
    }
    unawaited(pump());
    return true;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _pumping = false;

  /// Send whatever the rate limit allows now (public for tests).
  Future<void> pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final now = _clock();
      _queue.removeWhere((q) {
        final old = now.difference(q.at) > maxQueueAge;
        if (old) expired++;
        return old;
      });
      while (_queue.isNotEmpty && radio.ready) {
        final free = radio.queueFree;
        if (free != null && free <= 0) break;
        if (!limiter.tryTake()) break;
        _queue.sort((a, b) {
          final p = a.priority.index.compareTo(b.priority.index);
          return p != 0 ? p : a.seq.compareTo(b.seq);
        });
        final q = _queue.removeAt(0);
        final peers = q.peers;
        var to = meshBroadcast;
        var ack = false;
        if (peers != null && peers.length == 1) {
          final s = _peers[peers.first];
          if (s != null && s.node != 0) {
            // Directed: Meshtastic retries until that radio acknowledges.
            to = s.node;
            ack = true;
          }
        }
        try {
          await radio.send(
            q.bytes,
            to: to,
            wantAck: ack,
            priority:
                q.priority == LoraPriority.urgent ||
                    q.priority == LoraPriority.sos
                ? MeshPacketPb.priorityHigh
                : q.priority == LoraPriority.presence
                ? MeshPacketPb.priorityDefault
                : MeshPacketPb.priorityReliable,
          );
          sentPackets++;
        } catch (_) {}
      }
    } finally {
      _pumping = false;
    }
  }

  @override
  String? get debugInfo =>
      '${radio.ready ? 'radio ready' : 'no radio'} · sent $sentPackets · '
      'rx $receivedPackets · queue ${_queue.length}'
      '${expired > 0 ? ' · expired $expired' : ''}';
}
