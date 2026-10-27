import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/gateway_protocol.dart';
import '../lora/lora_transport.dart' show LoraRateLimiter, LoraPriority;
import '../lora/meshtastic_channels.dart' show MeshChannelRef;
import '../lora/meshtastic_proto.dart';

/// One radio as the gateway sees it (a USB / TCP [GatewayRadio] in the
/// container, a fake in tests).
abstract class GatewayRadioLink {
  String get name;
  bool get ready;

  /// The radio's own Meshtastic node number, once known.
  int? get myNode;

  /// Free slots in the radio's transmit queue, null if unknown.
  int? get queueFree;

  /// Decoded packets from other nodes.
  Stream<MeshPacketPb> get packets;

  /// [channel]: Meshtastic channel slot on this radio (0 = primary).
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
  });

  /// Slot of the linked Meshtastic channel [ref] on this radio (by name
  /// and hash), null when it does not have it (v1.9.7).
  int? meshChannelIndex(MeshChannelRef ref);
}

/// One relay room socket (WebSocket in the container, a fake in tests).
abstract class GatewayRoom {
  String get room;
  bool get connected;

  /// Binary messages from the other sockets in the room.
  Stream<Uint8List> get frames;
  void send(Uint8List bytes);
  Future<void> close();
}

typedef GatewayRoomFactory = GatewayRoom Function(String room);

class GatewayTxItem {
  GatewayTxItem(
    this.bytes,
    this.to,
    this.priority,
    this.at,
    this.seq,
    this.sender, [
    this.mesh,
  ]);
  final Uint8List bytes;

  /// Linked Meshtastic channel to send it on (resolved per radio).
  final MeshChannelRef? mesh;
  final int to; // Meshtastic node (broadcast = meshBroadcast)
  final LoraPriority priority;
  final DateTime at;
  final int seq;
  final int sender;
}

/// Per-radio state inside the gateway: its transmit queue and limiter.
class GatewayRadioSlot {
  GatewayRadioSlot(this.link, this.limiter);
  final GatewayRadioLink link;
  final LoraRateLimiter limiter;
  final List<GatewayTxItem> queue = [];
  StreamSubscription<MeshPacketPb>? sub;
  int fromRadio = 0; // app frames heard on this radio
  int toRadio = 0; // packets this gateway transmitted on it
  DateTime? lastHeard;
}

/// An app phone heard over LoRa: which radio heard it and its radio node.
class LoraHeard {
  LoraHeard(this.slot, this.node, this.at);
  final GatewayRadioSlot slot;
  final int node;
  final DateTime at;
}

class _RoomState {
  _RoomState(this.link, this.fixed);
  final GatewayRoom link;
  bool fixed;
  DateTime? leaseUntil;
  DateTime? lastAnnounce;
  StreamSubscription<Uint8List>? sub;
  final List<(Uint8List, DateTime)> pending = [];
  int phonesHeard = 0;
  final Map<int, DateTime> senders = {};
}

/// Another gateway announcing itself in one of our rooms.
class OtherGateway {
  OtherGateway(this.id, this.name, this.room, this.at, this.phone);
  final int id;
  final String name;
  final String room;
  final DateTime at;
  final bool phone;
}

/// The gateway's brain: LoRa radios <-> relay rooms (v1.9.5).
///
/// * LoRa -> internet: every app frame heard on any radio is wrapped in a
///   [GatewayKind.fromRadio] envelope and sent to the relay room of its
///   channel (public channel number or private "p" + tag; the gateway
///   joins that room for [roomLease] after the last LoRa frame for it).
/// * internet -> LoRa: only [GatewayKind.toRadio] requests from phones
///   (they decided, before sealing, that the frame may use the radio:
///   rings, chat, voice clips, rekeys, Trip messages, rare presence),
///   never live audio. Directed requests go only out of the radio(s) that
///   heard that phone, broadcasts out of every connected radio.
/// * Dedupe and loop prevention: one [SeenIds] cache across all radios
///   and rooms ([gatewayPacketId] of the inner frame). Nothing that came
///   from the internet is forwarded back to it, nothing heard on the air
///   is put back on the air.
/// * Airtime: per radio a [LoraRateLimiter] and a priority queue (stale
///   entries expire), plus a per-phone request limit.
class GatewayCore {
  GatewayCore({
    required this.name,
    required this.nodeId,
    required this.roomFactory,
    Set<String> rooms = const {},
    DateTime Function()? clock,
    Random? random,
    this.roomLease = const Duration(minutes: 30),
    this.maxDynamicRooms = 32,
    this.announceEvery = const Duration(seconds: 30),
    this.loraPeerTimeout = const Duration(minutes: 16),
    this.presenceEvery = const Duration(minutes: 4),
    this.maxRequestsPerMinute = 12,
    this.maxQueue = 32,
    this.maxQueueAge = const Duration(minutes: 3),
    this.limiterBurst = 4,
    this.limiterRefill = const Duration(seconds: 8),
  }) : _clock = clock ?? DateTime.now,
       _rng = random ?? Random() {
    seen = SeenIds(clock: _clock);
    roomSeen = SeenIds(
      ttl: const Duration(minutes: 3),
      max: 20000,
      clock: _clock,
    );
    setRooms(rooms);
  }

  final String name;
  final int nodeId;
  final GatewayRoomFactory roomFactory;
  final DateTime Function() _clock;
  final Random _rng;
  final Duration roomLease;
  final int maxDynamicRooms;
  final Duration announceEvery;
  final Duration loraPeerTimeout;
  final Duration presenceEvery;
  final int maxRequestsPerMinute;
  final int maxQueue;
  final Duration maxQueueAge;
  final int limiterBurst;
  final Duration limiterRefill;

  /// Inner frames forwarded / transmitted / seen as envelopes.
  late final SeenIds seen;

  /// Plain frames phones sent straight into a room (so a LoRa copy of the
  /// same frame, sent by a phone with its own radio, is not echoed back).
  late final SeenIds roomSeen;

  final List<GatewayRadioSlot> radios = [];
  final Map<String, _RoomState> _rooms = {};
  final Map<int, LoraHeard> loraPeers = {};
  final Map<int, OtherGateway> others = {};

  /// Walkie channel number -> linked Meshtastic channel (v1.9.7, from
  /// gateway.json "meshChannels"), for requests from phones that do not
  /// name one. Open channels only (sealed frames never use it).
  Map<int, MeshChannelRef> meshLinks = {};

  /// Sent on a linked channel / linked channel not on that radio (primary
  /// used instead).
  int sentOnLinked = 0;
  int linkMissing = 0;
  final Map<int, List<DateTime>> _requests = {};
  final Map<String, DateTime> _presenceSent = {};
  int _seq = 0;
  int _txSeq = 0;
  Future<void>? _pumpRun;
  bool _pumpAgain = false;

  // ---- counters (healthz)
  int radioToInternet = 0;
  int internetToRadio = 0;
  int duplicates = 0;
  int rateLimited = 0;
  int expired = 0;
  int overflow = 0;
  int rejected = 0;
  int noRoute = 0;
  DateTime? lastRadioToInternet;
  DateTime? lastInternetToRadio;

  int get radiosUp => radios.where((r) => r.link.ready).length;

  Iterable<String> get rooms => _rooms.keys;
  bool inRoom(String room) => _rooms.containsKey(room);
  bool roomConnected(String room) => _rooms[room]?.link.connected ?? false;

  // ------------------------------------------------------------ radios

  void addRadio(GatewayRadioLink link) {
    final slot = GatewayRadioSlot(
      link,
      LoraRateLimiter(
        burst: limiterBurst,
        refillEvery: limiterRefill,
        clock: _clock,
      ),
    );
    slot.sub = link.packets.listen((p) => onRadioPacket(slot, p));
    radios.add(slot);
  }

  Future<void> removeRadio(GatewayRadioLink link) async {
    final i = radios.indexWhere((s) => identical(s.link, link));
    if (i < 0) return;
    final slot = radios.removeAt(i);
    await slot.sub?.cancel();
    loraPeers.removeWhere((_, h) => identical(h.slot, slot));
  }

  /// A packet one of the radios heard (public for tests).
  void onRadioPacket(GatewayRadioSlot slot, MeshPacketPb p) {
    final d = p.decoded;
    if (d == null || d.portnum != PortNum.privateApp) return;
    if (p.from != 0 && radios.any((r) => r.link.myNode == p.from)) {
      return; // another of our own radios transmitting
    }
    final f = Frame.tryDecode(d.payload);
    if (f == null) return;
    if (f.type == FrameType.gateway || f.type == FrameType.mesh) {
      rejected++;
      return;
    }
    final now = _clock();
    slot.lastHeard = now;
    if (f.senderId != nodeId && p.from != 0) {
      loraPeers[f.senderId] = LoraHeard(slot, p.from, now);
    }
    final id = gatewayPacketId(d.payload);
    if (roomSeen.contains(id) || !seen.add(id)) {
      duplicates++;
      return;
    }
    if (f.type == FrameType.lobby) {
      rejected++; // Who's where stays local
      return;
    }
    slot.fromRadio++;
    final room = gatewayRoomOf(f);
    final st = _ensureRoom(room, lease: true);
    if (st == null) {
      noRoute++;
      return;
    }
    final env = GatewayEnvelope.fromRadio(
      Uint8List.fromList(d.payload),
      hops: 1,
      radioNode: slot.link.myNode ?? 0,
      snr: p.rxSnr,
    ).toFrame(senderId: nodeId, channel: f.channel, seq: _nextSeq());
    _sendToRoom(st, env.encode());
    radioToInternet++;
    lastRadioToInternet = now;
  }

  // ------------------------------------------------------------ rooms

  /// Rooms the gateway always sits in (config); others come and go with
  /// LoRa traffic.
  void setRooms(Set<String> rooms) {
    for (final r in rooms) {
      final st = _ensureRoom(r);
      st?.fixed = true;
    }
    for (final e in _rooms.entries.toList()) {
      if (e.value.fixed && !rooms.contains(e.key)) {
        e.value.fixed = false;
        e.value.leaseUntil ??= _clock().add(roomLease);
      }
    }
  }

  static final _roomRe = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

  _RoomState? _ensureRoom(String room, {bool lease = false}) {
    if (!_roomRe.hasMatch(room)) return null;
    var st = _rooms[room];
    if (st == null) {
      if (lease &&
          _rooms.values.where((s) => !s.fixed).length >= maxDynamicRooms) {
        return null;
      }
      final link = roomFactory(room);
      st = _RoomState(link, !lease);
      final s = st;
      st.sub = link.frames.listen((b) => _onRoomFrame(room, b, s));
      _rooms[room] = st;
    }
    if (lease) {
      final until = _clock().add(roomLease);
      final cur = st.leaseUntil;
      if (cur == null || until.isAfter(cur)) st.leaseUntil = until;
    }
    return st;
  }

  void _sendToRoom(_RoomState st, Uint8List bytes) {
    if (st.link.connected) {
      st.link.send(bytes);
    } else {
      st.pending.add((bytes, _clock()));
      if (st.pending.length > 32) st.pending.removeAt(0);
    }
  }

  /// A binary message from a room (public for tests).
  void onRoomFrame(String room, Uint8List bytes) {
    final st = _rooms[room];
    if (st != null) _onRoomFrame(room, bytes, st);
  }

  void _onRoomFrame(String room, Uint8List bytes, _RoomState st) {
    final f = Frame.tryDecode(bytes);
    if (f == null) return;
    if (f.senderId == nodeId) return; // our own echo
    final now = _clock();
    if (f.type != FrameType.gateway) {
      // A phone talking in the room. Remember non-audio frames so a LoRa
      // copy of the same frame is not echoed back.
      if (st.senders[f.senderId] == null) st.phonesHeard++;
      st.senders[f.senderId] = now;
      if (f.type != FrameType.audio) roomSeen.add(gatewayPacketId(bytes));
      return;
    }
    final env = GatewayEnvelope.tryDecode(f);
    if (env == null) {
      rejected++;
      return;
    }
    switch (env.kind) {
      case GatewayKind.announce:
        others[f.senderId] = OtherGateway(
          f.senderId,
          env.name,
          room,
          now,
          env.isPhone,
        );
      case GatewayKind.fromRadio:
        // Another gateway already brought it in: never again from us.
        seen.add(env.packetId);
      case GatewayKind.toRadio:
        _onToRadio(f.senderId, env, now);
    }
  }

  void _onToRadio(int sender, GatewayEnvelope env, DateTime now) {
    final inner = env.inner!;
    final f = env.innerFrame!;
    if (inner.length > loraPayloadBudget) {
      rejected++;
      return;
    }
    // Never live audio, envelopes, Who's where or the phone mesh.
    if (f.type == FrameType.audio ||
        f.type == FrameType.lobby ||
        f.type == FrameType.mesh ||
        f.type == FrameType.gateway) {
      rejected++;
      return;
    }
    if (f.type == FrameType.control) {
      final k = f.control?.kind;
      if (k == ControlKind.talkStart ||
          k == ControlKind.talkEnd ||
          k == ControlKind.ping ||
          k == ControlKind.pong ||
          k == ControlKind.dx) {
        rejected++;
        return;
      }
    }
    final id = env.packetId;
    if (!seen.add(id)) {
      duplicates++;
      return;
    }
    // Per phone request limit (a misbehaving phone cannot hog the air).
    final reqs = _requests.putIfAbsent(sender, () => []);
    reqs.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (reqs.length >= maxRequestsPerMinute) {
      rateLimited++;
      return;
    }
    reqs.add(now);
    if (_requests.length > 500) _requests.remove(_requests.keys.first);

    final pr = env.priority < LoraPriority.values.length
        ? LoraPriority.values[env.priority]
        : LoraPriority.normal;
    if (pr == LoraPriority.presence) {
      final key = '${f.senderId}:${f.channel}';
      final last = _presenceSent[key];
      if (last != null && now.difference(last) < presenceEvery) {
        rateLimited++;
        return;
      }
      _presenceSent[key] = now;
      if (_presenceSent.length > 1000) {
        _presenceSent.remove(_presenceSent.keys.first);
      }
    }
    final mesh =
        env.mesh ?? (f.type == FrameType.sealed ? null : meshLinks[f.channel]);
    final targets = <GatewayRadioSlot, int>{};
    if (env.to != 0) {
      final h = loraPeers[env.to];
      if (h == null ||
          now.difference(h.at) > loraPeerTimeout ||
          !radios.contains(h.slot)) {
        noRoute++;
        return;
      }
      targets[h.slot] = h.node;
    } else {
      for (final s in radios) {
        if (s.link.ready) targets[s] = meshBroadcast;
      }
    }
    if (targets.isEmpty) {
      noRoute++;
      return;
    }
    for (final e in targets.entries) {
      final q = e.key.queue;
      if (pr == LoraPriority.presence) {
        q.removeWhere(
          (i) => i.priority == LoraPriority.presence && i.sender == f.senderId,
        );
      }
      q.add(GatewayTxItem(inner, e.value, pr, now, _txSeq++, f.senderId, mesh));
      while (q.length > maxQueue) {
        GatewayTxItem? worst;
        for (final i in q) {
          if (worst == null ||
              i.priority.index > worst.priority.index ||
              (i.priority == worst.priority && i.seq < worst.seq)) {
            worst = i;
          }
        }
        q.remove(worst);
        overflow++;
      }
    }
    unawaited(pump());
  }

  /// Transmit what the rate limits allow (public for tests).
  Future<void> pump() {
    final running = _pumpRun;
    if (running != null) {
      _pumpAgain = true;
      return running;
    }
    final f = _pumpLoop().whenComplete(() => _pumpRun = null);
    _pumpRun = f;
    return f;
  }

  Future<void> _pumpLoop() async {
    do {
      _pumpAgain = false;
      await _pumpOnce();
    } while (_pumpAgain);
  }

  Future<void> _pumpOnce() async {
    {
      final now = _clock();
      for (final s in radios) {
        s.queue.removeWhere((i) {
          final old = now.difference(i.at) > maxQueueAge;
          if (old) expired++;
          return old;
        });
        while (s.queue.isNotEmpty && s.link.ready) {
          final free = s.link.queueFree;
          if (free != null && free <= 0) break;
          if (!s.limiter.tryTake()) break;
          s.queue.sort((a, b) {
            final p = a.priority.index.compareTo(b.priority.index);
            return p != 0 ? p : a.seq.compareTo(b.seq);
          });
          final i = s.queue.removeAt(0);
          var slot = 0;
          final mesh = i.mesh;
          if (mesh != null) {
            final idx = s.link.meshChannelIndex(mesh);
            if (idx != null) {
              slot = idx;
              sentOnLinked++;
            } else {
              linkMissing++;
            }
          }
          try {
            await s.link.send(
              i.bytes,
              to: i.to,
              channel: slot,
              wantAck: i.to != meshBroadcast,
              priority:
                  i.priority == LoraPriority.urgent ||
                      i.priority == LoraPriority.sos
                  ? MeshPacketPb.priorityHigh
                  : i.priority == LoraPriority.presence
                  ? MeshPacketPb.priorityDefault
                  : MeshPacketPb.priorityReliable,
            );
            s.toRadio++;
            internetToRadio++;
            lastInternetToRadio = _clock();
          } catch (_) {}
        }
      }
    }
  }

  /// Housekeeping, every ~0.5 s: transmit, flush rooms that connected,
  /// announce, drop expired rooms and peers.
  Future<void> tick() async {
    final now = _clock();
    await pump();
    for (final e in _rooms.entries.toList()) {
      final st = e.value;
      if (!st.fixed && st.leaseUntil != null && now.isAfter(st.leaseUntil!)) {
        await _closeRoom(e.key);
        continue;
      }
      if (!st.link.connected) continue;
      if (st.pending.isNotEmpty) {
        for (final (b, at) in st.pending) {
          if (now.difference(at) < const Duration(minutes: 2)) {
            st.link.send(b);
          }
        }
        st.pending.clear();
      }
      final last = st.lastAnnounce;
      if (last == null || now.difference(last) >= announceEvery) {
        // Small random spread so many rooms do not announce at once.
        st.lastAnnounce = now.subtract(
          Duration(milliseconds: _rng.nextInt(2000)),
        );
        st.link.send(announceFrame(e.key).encode());
      }
      st.senders.removeWhere(
        (_, t) => now.difference(t) > const Duration(minutes: 3),
      );
    }
    loraPeers.removeWhere((_, h) => now.difference(h.at) > loraPeerTimeout);
    others.removeWhere(
      (_, o) => now.difference(o.at) > const Duration(minutes: 3),
    );
  }

  /// This gateway's announcement for [room].
  Frame announceFrame(String room) {
    final ch = room.startsWith('p')
        ? int.tryParse(room.substring(1), radix: 16) ?? 0
        : int.tryParse(room) ?? 0;
    return GatewayEnvelope.announce(
      name: name,
      radiosUp: radiosUp,
      radios: radios.length,
    ).toFrame(senderId: nodeId, channel: ch, seq: _nextSeq());
  }

  Future<void> _closeRoom(String room) async {
    final st = _rooms.remove(room);
    if (st == null) return;
    await st.sub?.cancel();
    await st.link.close();
  }

  int _nextSeq() => _seq = (_seq + 1) & 0xFFFF;

  Map<String, Object?> status() {
    final now = _clock();
    String? ago(DateTime? t) =>
        t == null ? null : '${now.difference(t).inSeconds}s';
    return {
      'radiosUp': radiosUp,
      'radios': radios.length,
      'framesRadioToInternet': radioToInternet,
      'framesInternetToRadio': internetToRadio,
      'lastRadioToInternet': ago(lastRadioToInternet),
      'lastInternetToRadio': ago(lastInternetToRadio),
      'duplicatesDropped': duplicates,
      'rateLimited': rateLimited,
      'expired': expired,
      'queueOverflow': overflow,
      'rejected': rejected,
      'noRoute': noRoute,
      'sentOnLinkedMeshChannel': sentOnLinked,
      'linkedMeshChannelMissing': linkMissing,
      'meshChannelLinks': {
        for (final e in meshLinks.entries) '${e.key}': e.value.toJson(),
      },
      'loraPhones': loraPeers.length,
      'rooms': [
        for (final e in _rooms.entries)
          {
            'room': e.key,
            'connected': e.value.link.connected,
            'fixed': e.value.fixed,
            'phones': e.value.senders.length,
            if (!e.value.fixed && e.value.leaseUntil != null)
              'leaseLeftMin': e.value.leaseUntil!.difference(now).inMinutes,
          },
      ],
      'otherGateways': [
        for (final o in others.values)
          {'name': o.name, 'room': o.room, 'phone': o.phone},
      ],
    };
  }

  Future<void> close() async {
    for (final r in _rooms.keys.toList()) {
      await _closeRoom(r);
    }
    for (final s in radios) {
      await s.sub?.cancel();
    }
    radios.clear();
  }
}
