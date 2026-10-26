import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'frame.dart';
import 'lobby.dart';
import 'transport.dart';

/// Off-grid mesh relay ("Relay for others", v1.6.0).
///
/// With no internet, a phone only reaches phones in direct radio range
/// (Bluetooth LE, a shared Wi-Fi / hotspot, Wi-Fi Direct). The mesh lets
/// phones pass packets on for each other so a group spread along a trail
/// can still talk, while never slowing down phones that are close:
///
/// * The original sender sends exactly as before (plain frames on the best
///   direct link, no extra header, no delay).
/// * Every packet is identified by a 64 bit hash of the origin's encoded
///   frame (sender id + sequence number + payload; sealed frames also carry
///   a random nonce), so the direct copy and every relayed copy of the same
///   packet share one id. A seen-id cache drops duplicates: each phone
///   relays a packet at most once and the receiver keeps playing the first
///   copy that arrives.
/// * A relayed copy travels in a [FrameType.mesh] envelope:
///
/// ```
/// mesh frame header (12 B: sender = relaying phone, channel 0, relay seq)
/// kind     1 B  (1 = packet)
/// hops     1 B  radio hops travelled when received (direct = 1)
/// maxHops  1 B  TTL: not relayed further once hops >= maxHops
/// to       4 B  destination node id, 0 = everyone
/// inner    n B  the origin's frame bytes, unchanged (sealed stays sealed)
/// ```
///
/// * Relay suppression: phones send a tiny [MeshKind.beacon] every couple of
///   seconds listing the phones they hear directly. A packet is only
///   relayed to neighbours that did not hear it directly from the source
///   (and did not get it from the phone we got it from). When everyone is
///   close together nobody relays anything.
/// * Relayed hops wait a small random jitter so neighbours do not all
///   transmit at once; the original send never waits.
/// * Relaying is rate limited (packets and bytes per second) to protect
///   Bluetooth bandwidth.
/// * Relays forward private-channel and friend frames as the ciphertext
///   they received: they cannot read or change them.
/// * Mesh frames never go over the internet relay (it already reaches
///   everyone it can).
///
/// Older phones (v1.5.x) drop frame type 5, so they neither relay nor see
/// relayed copies, and they are not chosen as relay targets.
enum MeshKind {
  beacon(0),
  packet(1);

  const MeshKind(this.code);
  final int code;
}

/// Transports the mesh runs on (everything that works without internet,
/// except LoRa radios: Meshtastic repeats LoRa packets itself, so the app
/// mesh never relays them again).
bool isOffGrid(TransportKind k) =>
    k != TransportKind.internet && k != TransportKind.lora;

/// 64 bit FNV-1a hash of [bytes]: the mesh packet id.
int meshPacketId(List<int> bytes) {
  var h = 0xcbf29ce484222325;
  for (final b in bytes) {
    h ^= b;
    h *= 0x100000001b3;
  }
  return h;
}

/// A decoded [MeshKind.packet] envelope.
class MeshPacket {
  MeshPacket({
    required this.relayer,
    required this.hops,
    required this.maxHops,
    required this.to,
    required this.inner,
  });

  /// Phone that sent this copy (the previous hop).
  final int relayer;
  final int hops;
  final int maxHops;

  /// Destination node id, 0 = everyone.
  final int to;

  /// The origin's encoded frame, byte for byte.
  final Uint8List inner;

  static const int headerSize = 7;

  static Uint8List encode({
    required int relayer,
    required int seq,
    required int hops,
    required int maxHops,
    required int to,
    required Uint8List inner,
  }) {
    final p = Uint8List(headerSize + inner.length);
    p[0] = MeshKind.packet.code;
    p[1] = hops.clamp(0, 255);
    p[2] = maxHops.clamp(0, 255);
    ByteData.sublistView(p).setUint32(3, to & 0xFFFFFFFF);
    p.setRange(headerSize, p.length, inner);
    return Frame(
      type: FrameType.mesh,
      senderId: relayer,
      channel: 0,
      seq: seq & 0xFFFF,
      payload: p,
    ).encode();
  }

  static MeshPacket? tryDecode(Frame f) {
    if (f.type != FrameType.mesh) return null;
    final p = f.payload;
    if (p.length < headerSize + Frame.headerSize) return null;
    if (p[0] != MeshKind.packet.code) return null;
    return MeshPacket(
      relayer: f.senderId,
      hops: p[1],
      maxHops: p[2],
      to: ByteData.sublistView(p).getUint32(3),
      inner: Uint8List.sublistView(p, headerSize),
    );
  }
}

/// Beacon: "these are the phones I hear directly".
class MeshBeacon {
  MeshBeacon(this.sender, this.neighbours);
  final int sender;
  final Set<int> neighbours;

  static const int maxListed = 40;

  static Uint8List encode(int sender, int seq, Iterable<int> neighbours) {
    final ids = neighbours.take(maxListed).toList();
    final p = Uint8List(2 + 4 * ids.length);
    p[0] = MeshKind.beacon.code;
    p[1] = ids.length;
    final bd = ByteData.sublistView(p);
    for (var i = 0; i < ids.length; i++) {
      bd.setUint32(2 + 4 * i, ids[i] & 0xFFFFFFFF);
    }
    return Frame(
      type: FrameType.mesh,
      senderId: sender,
      channel: 0,
      seq: seq & 0xFFFF,
      payload: p,
    ).encode();
  }

  static MeshBeacon? tryDecode(Frame f) {
    if (f.type != FrameType.mesh) return null;
    final p = f.payload;
    if (p.length < 2 || p[0] != MeshKind.beacon.code) return null;
    final n = p[1];
    if (p.length < 2 + 4 * n) return null;
    final bd = ByteData.sublistView(p);
    return MeshBeacon(f.senderId, {
      for (var i = 0; i < n; i++) bd.getUint32(2 + 4 * i),
    });
  }
}

/// What to relay, to whom, after how long.
class MeshRelay {
  MeshRelay(this.bytes, this.targets, this.delay, [this._retarget]);
  final Set<int> Function()? _retarget;

  /// Targets worked out again when the jitter ends: beacons that arrived
  /// meanwhile (e.g. a phone that just came into range of the source) can
  /// make the relay unnecessary.
  Set<int> currentTargets() => _retarget?.call() ?? targets;

  /// Encoded mesh envelope.
  final Uint8List bytes;

  /// Neighbour node ids to unicast it to.
  final Set<int> targets;

  /// Random forwarding jitter (relayed hops only).
  final Duration delay;
}

/// Result of [MeshRouter.onFrame].
class MeshDecision {
  const MeshDecision({
    this.deliver,
    this.hops = 1,
    this.relay,
    this.newNeighbour = false,
  });

  /// First frame from this phone in a while: tell neighbours right away
  /// (beacon) so they stop relaying to phones that hear each other.
  final bool newNeighbour;

  /// Frame for the normal receive path, or null (beacon, duplicate relayed
  /// copy, our own packet coming back).
  final Frame? deliver;

  /// Radio hops [deliver] travelled (1 = heard directly from its sender).
  final int hops;

  /// Copy to pass on, or null.
  final MeshRelay? relay;
}

class _Neighbour {
  final Map<TransportKind, DateTime> heard = {};
  Set<int> hears = const {};
  DateTime? beaconAt;
}

/// Pure (radio-free) mesh logic; [TransportManager] does the sending.
class MeshRouter {
  MeshRouter({
    required this.localId,
    DateTime Function()? clock,
    Random? random,
    this.maxHops = 4,
    this.neighbourTimeout = const Duration(seconds: 5),
    this.beaconTimeout = const Duration(seconds: 8),
    this.seenTtl = const Duration(seconds: 30),
    this.seenCapacity = 4096,
    this.maxPacketsPerSecond = 100,
    this.maxBytesPerSecond = 12 * 1024,
    this.helloRelayInterval = const Duration(seconds: 3),
    this.lobbyRelayInterval = const Duration(seconds: 8),
    this.probeRelayInterval = const Duration(seconds: 5),
    this.jitterMin = const Duration(milliseconds: 2),
    this.jitterMax = const Duration(milliseconds: 12),
  }) : _clock = clock ?? DateTime.now,
       _rng = random ?? Random();

  final int localId;
  final DateTime Function() _clock;
  final Random _rng;

  /// Default TTL for packets we put into the mesh.
  final int maxHops;
  final Duration neighbourTimeout;

  /// A neighbour's beacon (who it hears) is trusted this long.
  final Duration beaconTimeout;
  final Duration seenTtl;
  final int seenCapacity;
  final int maxPacketsPerSecond;
  final int maxBytesPerSecond;

  /// Presence (hello) of one phone is relayed at most this often.
  final Duration helloRelayInterval;

  /// "Who's where" beacons of one phone are relayed at most this often.
  final Duration lobbyRelayInterval;
  final Map<int, DateTime> _lobbyRelayed = {};

  /// One "who's here?" probe per origin passed on this often (v1.8.5).
  final Duration probeRelayInterval;
  final Map<int, DateTime> _probeRelayed = {};
  final Duration jitterMin;
  final Duration jitterMax;

  /// "Relay for others" switch. Off: we still receive relayed packets and
  /// send beacons, we just do not pass anything on.
  bool enabled = true;

  /// Offline power save: our own hellos / beacons are slower, so trust
  /// what neighbours told us for longer (2x).
  double timeoutScale = 1;
  Duration get _nbTimeout => neighbourTimeout * timeoutScale;
  Duration get _bcTimeout => beaconTimeout * timeoutScale;

  final Map<int, _Neighbour> _neighbours = {};
  final LinkedHashMap<int, DateTime> _seen = LinkedHashMap();
  final Map<int, DateTime> _helloRelayed = {};
  int _relaySeq = 0;

  // Token buckets.
  double _pktTokens = 0;
  double _byteTokens = 0;
  DateTime? _refillAt;

  /// Counters for the debug line / tests.
  int relayed = 0;
  int suppressed = 0;
  int rateLimited = 0;
  int duplicates = 0;

  int _nextSeq() => _relaySeq = (_relaySeq + 1) & 0xFFFF;

  // ----------------------------------------------------------- neighbours

  /// Phones heard directly on an off-grid transport recently.
  Set<int> directNeighbours() {
    final now = _clock();
    return {
      for (final e in _neighbours.entries)
        if (e.value.heard.values.any((t) => now.difference(t) <= _nbTimeout))
          e.key,
    };
  }

  /// Neighbours that run the mesh (sent a beacon): the only ones worth
  /// relaying to, older phones drop mesh frames.
  Set<int> meshNeighbours() {
    final now = _clock();
    return {
      for (final id in directNeighbours())
        if (_neighbours[id]!.beaconAt != null &&
            now.difference(_neighbours[id]!.beaconAt!) <= _bcTimeout)
          id,
    };
  }

  /// Off-grid transports [id] was heard on recently, any order.
  Set<TransportKind> linksTo(int id) {
    final n = _neighbours[id];
    if (n == null) return const {};
    final now = _clock();
    return {
      for (final e in n.heard.entries)
        if (now.difference(e.value) <= _nbTimeout) e.key,
    };
  }

  /// Whether neighbour [n] told us (beacon) it hears [id] directly.
  bool neighbourHears(int n, int id) {
    final nb = _neighbours[n];
    if (nb == null || nb.beaconAt == null) return false;
    if (_clock().difference(nb.beaconAt!) > _bcTimeout) return false;
    return nb.hears.contains(id);
  }

  /// Our beacon (encoded mesh frame).
  Uint8List beacon() =>
      MeshBeacon.encode(localId, _nextSeq(), directNeighbours());

  /// Drop old state; call every second or so.
  void prune() {
    final now = _clock();
    _neighbours.removeWhere((_, n) {
      n.heard.removeWhere((_, t) => now.difference(t) > _nbTimeout * 3);
      return n.heard.isEmpty;
    });
    _expireSeen(now);
    _helloRelayed.removeWhere((_, t) => now.difference(t) > seenTtl);
    _lobbyRelayed.removeWhere((_, t) => now.difference(t) > seenTtl);
    _probeRelayed.removeWhere((_, t) => now.difference(t) > seenTtl);
  }

  // ----------------------------------------------------------- seen cache

  /// Records [id]; false if it was already seen.
  bool markSeen(int id) {
    final now = _clock();
    _expireSeen(now);
    if (_seen.containsKey(id)) return false;
    _seen[id] = now;
    while (_seen.length > seenCapacity) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  bool hasSeen(int id) => _seen.containsKey(id);

  void _expireSeen(DateTime now) {
    while (_seen.isNotEmpty && now.difference(_seen.values.first) > seenTtl) {
      _seen.remove(_seen.keys.first);
    }
  }

  // ----------------------------------------------------------- receive

  /// Handle any frame a transport delivered. Direct frames are always
  /// delivered (the manager de-duplicates per sender as before); relayed
  /// copies only the first time.
  MeshDecision onFrame(Frame f, TransportKind via) {
    final d = _onFrame(f, via);
    if (!_wasNew) return d;
    return MeshDecision(
      deliver: d.deliver,
      hops: d.hops,
      relay: d.relay,
      newNeighbour: true,
    );
  }

  bool _wasNew = false;

  MeshDecision _onFrame(Frame f, TransportKind via) {
    _wasNew = false;
    if (f.senderId == localId) return const MeshDecision();
    final offGrid = isOffGrid(via);
    if (offGrid) {
      final now = _clock();
      final n = _neighbours.putIfAbsent(f.senderId, _Neighbour.new);
      _wasNew = !n.heard.values.any((t) => now.difference(t) <= _nbTimeout);
      n.heard[via] = now;
    }
    if (f.type != FrameType.mesh) {
      if (!offGrid) {
        // A LoRa copy shares the packet id of the direct and relayed
        // copies, so a later relayed copy is dropped and never relayed.
        if (via == TransportKind.lora) markSeen(meshPacketId(f.encode()));
        return MeshDecision(deliver: f);
      }
      final bytes = f.encode();
      final id = meshPacketId(bytes);
      if (!markSeen(id)) {
        duplicates++;
        return MeshDecision(deliver: f);
      }
      return MeshDecision(
        deliver: f,
        relay: _relayFor(
          bytes: bytes,
          inner: f,
          origin: f.senderId,
          prev: f.senderId,
          hops: 1,
          maxHops: maxHops,
          to: 0,
        ),
      );
    }

    final beacon = MeshBeacon.tryDecode(f);
    if (beacon != null) {
      if (offGrid) {
        final n = _neighbours[f.senderId]!;
        n.hears = beacon.neighbours;
        n.beaconAt = _clock();
      }
      return const MeshDecision();
    }
    final pkt = MeshPacket.tryDecode(f);
    if (pkt == null || !offGrid) return const MeshDecision();
    final inner = Frame.tryDecode(pkt.inner);
    if (inner == null || inner.type == FrameType.mesh) {
      return const MeshDecision();
    }
    if (inner.senderId == localId) return const MeshDecision();
    final id = meshPacketId(pkt.inner);
    if (!markSeen(id)) {
      duplicates++;
      return const MeshDecision();
    }
    final hops = pkt.hops < 1 ? 1 : pkt.hops;
    return MeshDecision(
      deliver: pkt.to == 0 || pkt.to == localId ? inner : null,
      hops: hops,
      relay: pkt.to == localId
          ? null
          : _relayFor(
              bytes: pkt.inner,
              inner: inner,
              origin: inner.senderId,
              prev: pkt.relayer,
              hops: hops,
              maxHops: pkt.maxHops,
              to: pkt.to,
            ),
    );
  }

  MeshRelay? _relayFor({
    required Uint8List bytes,
    required Frame inner,
    required int origin,
    required int prev,
    required int hops,
    required int maxHops,
    required int to,
  }) {
    if (!enabled) return null;
    if (hops >= maxHops) return null; // TTL used up
    if (origin == localId) return null;
    final now = _clock();
    if (inner.type == FrameType.control) {
      final k = inner.control?.kind;
      // Round-trip probes only make sense on one link.
      if (k == ControlKind.ping || k == ControlKind.pong) return null;
      if (k == ControlKind.hello) {
        final last = _helloRelayed[origin];
        if (last != null && now.difference(last) < helloRelayInterval) {
          return null;
        }
      }
    }
    final probe = inner.type == FrameType.lobby
        ? LobbyProbe.tryDecodePayload(inner.payload)
        : null;
    if (probe != null) {
      // "Who's here?" probes (v1.8.5) carry their own hop limit and have
      // their own per-origin limit, so a refresh is not swallowed by the
      // lobby beacon limit (and a refresh storm is).
      if (hops >= probe.ttl) return null;
      final last = _probeRelayed[origin];
      if (last != null && now.difference(last) < probeRelayInterval) {
        return null;
      }
    } else if (inner.type == FrameType.lobby) {
      final last = _lobbyRelayed[origin];
      if (last != null && now.difference(last) < lobbyRelayInterval) {
        return null;
      }
    }
    final targets = relayTargets(origin: origin, prev: prev, to: to);
    if (targets.isEmpty) {
      suppressed++;
      return null;
    }
    final out = MeshPacket.encode(
      relayer: localId,
      seq: _nextSeq(),
      hops: hops + 1,
      maxHops: probe != null && probe.ttl < maxHops ? probe.ttl : maxHops,
      to: to,
      inner: bytes,
    );
    if (!_take(out.length)) {
      rateLimited++;
      return null;
    }
    if (inner.type == FrameType.control &&
        inner.control?.kind == ControlKind.hello) {
      _helloRelayed[origin] = now;
    }
    if (probe != null) {
      _probeRelayed[origin] = now;
    } else if (inner.type == FrameType.lobby) {
      _lobbyRelayed[origin] = now;
    }
    relayed++;
    return MeshRelay(
      out,
      targets,
      _jitter(),
      () => relayTargets(origin: origin, prev: prev, to: to),
    );
  }

  /// Neighbours that still need a packet from [origin] that reached us from
  /// [prev]: every mesh neighbour except the source and previous hop,
  /// anyone who hears the source directly, and anyone the previous hop
  /// hears (it already passed the packet to them). A packet for one phone
  /// that we hear directly goes only to that phone.
  Set<int> relayTargets({required int origin, required int prev, int to = 0}) {
    final mesh = meshNeighbours();
    if (to != 0 && mesh.contains(to)) {
      return neighbourHears(to, origin) || neighbourHears(prev, to)
          ? const {}
          : {to};
    }
    return {
      for (final n in mesh)
        if (n != origin &&
            n != prev &&
            !neighbourHears(n, origin) &&
            !(prev != origin && neighbourHears(prev, n)))
          n,
    };
  }

  /// Wrap a packet we originate for phones reachable only through the mesh
  /// (sent right away, no jitter). Null when no mesh neighbour exists.
  MeshRelay? originate(Uint8List frameBytes, {int to = 0, Set<int>? skip}) {
    markSeen(meshPacketId(frameBytes));
    final targets = meshNeighbours()..removeAll(skip ?? const {});
    if (targets.isEmpty) return null;
    return MeshRelay(
      MeshPacket.encode(
        relayer: localId,
        seq: _nextSeq(),
        hops: 1,
        maxHops: maxHops,
        to: to,
        inner: frameBytes,
      ),
      targets,
      Duration.zero,
    );
  }

  bool _take(int bytes) {
    final now = _clock();
    final last = _refillAt;
    if (last == null) {
      _pktTokens = maxPacketsPerSecond.toDouble();
      _byteTokens = maxBytesPerSecond.toDouble();
    } else {
      final dt = now.difference(last).inMicroseconds / 1e6;
      if (dt > 0) {
        _pktTokens = min(
          maxPacketsPerSecond.toDouble(),
          _pktTokens + dt * maxPacketsPerSecond,
        );
        _byteTokens = min(
          maxBytesPerSecond.toDouble(),
          _byteTokens + dt * maxBytesPerSecond,
        );
      }
    }
    _refillAt = now;
    if (_pktTokens < 1 || _byteTokens < bytes) return false;
    _pktTokens -= 1;
    _byteTokens -= bytes;
    return true;
  }

  Duration _jitter() {
    final lo = jitterMin.inMicroseconds;
    final span = jitterMax.inMicroseconds - lo;
    return Duration(
      microseconds: lo + (span <= 0 ? 0 : _rng.nextInt(span + 1)),
    );
  }

  String get debugInfo =>
      'mesh ${enabled ? 'on' : 'off'} · ${meshNeighbours().length}/'
      '${directNeighbours().length} nb · relayed $relayed · '
      'skipped $suppressed · limited $rateLimited';
}
