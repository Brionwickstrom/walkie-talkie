import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/mesh.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';

import 'fake_transport.dart';

const a = 0xA1, b = 0xB2, c = 0xC3, d = 0xD4;

Frame audio(int from, int seq, {int channel = 1, int len = 30}) => Frame(
  type: FrameType.audio,
  senderId: from,
  channel: channel,
  seq: seq,
  payload: Uint8List.fromList(List.generate(len, (i) => (seq + i) & 0xFF)),
);

Frame hello(int from, int seq) => Frame.control(
  senderId: from,
  channel: 1,
  seq: seq,
  message: const ControlMessage(ControlKind.hello, name: 'x'),
);

Frame beaconFrom(int from, Set<int> hears) =>
    Frame.tryDecode(MeshBeacon.encode(from, 1, hears))!;

Frame envelope(
  Uint8List inner, {
  required int relayer,
  int hops = 2,
  int max = 4,
  int to = 0,
}) => Frame.tryDecode(
  MeshPacket.encode(
    relayer: relayer,
    seq: 7,
    hops: hops,
    maxHops: max,
    to: to,
    inner: inner,
  ),
)!;

/// Router for phone [b] that hears a, c and d directly, all mesh capable.
MeshRouter routerB({
  Set<int> cHears = const {b},
  Set<int> dHears = const {b},
  int perSecond = 100,
}) {
  final r = MeshRouter(
    localId: b,
    random: Random(1),
    maxPacketsPerSecond: perSecond,
  );
  r.onFrame(beaconFrom(a, {b}), TransportKind.ble);
  r.onFrame(beaconFrom(c, cHears), TransportKind.ble);
  r.onFrame(beaconFrom(d, dHears), TransportKind.lan);
  return r;
}

// ------------------------------------------------------------ fake radio

/// Radio with range: a phone only hears phones it is linked to.
class RangeAir {
  final Map<int, RangeTransport> nodes = {};
  final Set<(int, int)> links = {};
  int mesh = 0, direct = 0;

  void link(int x, int y) => links
    ..add((x, y))
    ..add((y, x));
  void unlink(int x, int y) => links
    ..remove((x, y))
    ..remove((y, x));
  bool inRange(int x, int y) => links.contains((x, y));
}

class RangeTransport extends Transport {
  RangeTransport(this.air, this.kind);
  final RangeAir air;
  @override
  final TransportKind kind;
  int id = 0;
  final _frames = StreamController<InboundFrame>.broadcast(sync: true);
  final _status = StreamController<TransportStatus>.broadcast(sync: true);
  TransportStatus _s = TransportStatus.stopped;
  final List<Uint8List> wire = [];

  @override
  TransportStatus get status => _s;
  @override
  Stream<TransportStatus> get statusChanges => _status.stream;
  @override
  Stream<InboundFrame> get frames => _frames.stream;
  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    id = localNodeId;
    air.nodes[id] = this;
    _s = TransportStatus.running;
  }

  @override
  Future<void> stop() async => _s = TransportStatus.stopped;

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    wire.add(frame);
    final f = Frame.tryDecode(frame)!;
    if (f.type == FrameType.mesh) {
      air.mesh++;
    } else {
      air.direct++;
    }
    for (final e in air.nodes.entries) {
      if (e.key == id || !air.inRange(id, e.key)) continue;
      if (peerIds != null && !peerIds.contains(e.key)) continue;
      if (e.value._s != TransportStatus.running) continue;
      e.value._frames.add(InboundFrame(Frame.tryDecode(frame)!, kind));
    }
  }
}

Future<TransportManager> phone(RangeAir air, int id, {ChannelKey? key}) async {
  final m = TransportManager(
    transports: [RangeTransport(air, TransportKind.ble)],
    localNodeId: id,
    localName: 'p$id',
    channel: 1,
    channelKey: key,
    helloInterval: const Duration(hours: 1), // driven by the test
  );
  await m.start();
  return m;
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

/// Two rounds of hello + beacon so everyone knows who hears whom.
Future<void> introduce(List<TransportManager> ms) async {
  for (var i = 0; i < 2; i++) {
    for (final m in ms) {
      await m.sendHello();
    }
    for (final m in ms) {
      await m.sendBeacon();
    }
    await settle();
  }
}

void main() {
  group('MeshRouter dedupe', () {
    test('a packet is relayed once; later copies are duplicates', () {
      final r = routerB(cHears: {b}, dHears: {b});
      final f = audio(a, 1);
      final first = r.onFrame(f, TransportKind.ble);
      expect(first.deliver, isNotNull);
      expect(first.relay, isNotNull);
      // Same frame over another transport: delivered (manager dedupes per
      // sender), never relayed again.
      final second = r.onFrame(f, TransportKind.lan);
      expect(second.deliver, isNotNull);
      expect(second.relay, isNull);
      // A relayed copy of the same packet: not delivered again either.
      final third = r.onFrame(
        envelope(f.encode(), relayer: d),
        TransportKind.lan,
      );
      expect(third.deliver, isNull);
      expect(third.relay, isNull);
      expect(r.duplicates, 2);
    });

    test('relayed copy delivers the inner frame with its hop count', () {
      final r = routerB();
      final inner = audio(0xEE, 3).encode();
      final out = r.onFrame(
        envelope(inner, relayer: a, hops: 2),
        TransportKind.ble,
      );
      expect(out.deliver!.senderId, 0xEE);
      expect(out.deliver!.seq, 3);
      expect(out.hops, 2);
    });

    test('our own packets coming back are ignored', () {
      final r = routerB();
      final mine = audio(b, 1).encode();
      final out = r.onFrame(envelope(mine, relayer: a), TransportKind.ble);
      expect(out.deliver, isNull);
      expect(out.relay, isNull);
    });

    test('the seen cache expires and is bounded', () {
      var now = DateTime(2026);
      final r = MeshRouter(localId: b, clock: () => now, seenCapacity: 3);
      for (var i = 0; i < 5; i++) {
        expect(r.markSeen(i), isTrue);
      }
      expect(r.hasSeen(0), isFalse); // evicted (capacity)
      expect(r.hasSeen(4), isTrue);
      now = now.add(const Duration(seconds: 31));
      expect(r.markSeen(4), isTrue); // expired (ttl)
    });
  });

  group('MeshRouter TTL', () {
    test('hop count goes up by one per relay', () {
      final r = routerB();
      final out = r.onFrame(
        envelope(audio(0xEE, 1).encode(), relayer: a, hops: 2),
        TransportKind.ble,
      );
      final relayed = MeshPacket.tryDecode(Frame.tryDecode(out.relay!.bytes)!)!;
      expect(relayed.hops, 3);
      expect(relayed.maxHops, 4);
      expect(relayed.relayer, b);
    });

    test('not relayed once max hops is reached (default 4)', () {
      final r = routerB();
      expect(r.maxHops, 4);
      final atLimit = r.onFrame(
        envelope(audio(0xEE, 1).encode(), relayer: a, hops: 4, max: 4),
        TransportKind.ble,
      );
      expect(atLimit.deliver, isNotNull); // still heard here
      expect(atLimit.relay, isNull);
      final below = r.onFrame(
        envelope(audio(0xEE, 2).encode(), relayer: a, hops: 3, max: 4),
        TransportKind.ble,
      );
      expect(below.relay, isNotNull);
    });

    test('a direct packet starts at hop 1 with the default TTL', () {
      final r = routerB();
      final out = r.onFrame(audio(a, 1), TransportKind.ble);
      expect(out.hops, 1);
      final p = MeshPacket.tryDecode(Frame.tryDecode(out.relay!.bytes)!)!;
      expect(p.hops, 2);
      expect(p.maxHops, 4);
    });
  });

  group('MeshRouter relay suppression', () {
    test('never relays to phones that heard the source directly', () {
      // c hears a directly, d does not.
      final r = routerB(cHears: {a, b}, dHears: {b});
      final out = r.onFrame(audio(a, 1), TransportKind.ble);
      expect(out.relay!.targets, {d});
    });

    test('everyone close together: nothing is relayed at all', () {
      final r = routerB(cHears: {a, b, d}, dHears: {a, b, c});
      final out = r.onFrame(audio(a, 1), TransportKind.ble);
      expect(out.relay, isNull);
      expect(r.suppressed, 1);
    });

    test('skips the previous hop and phones it already reaches', () {
      // a relays 0xEE's packet to us; d hears a, so a already gave it to d.
      final r = routerB(cHears: {b}, dHears: {b, a});
      r.onFrame(beaconFrom(a, {b, d}), TransportKind.ble);
      final out = r.onFrame(
        envelope(audio(0xEE, 1).encode(), relayer: a),
        TransportKind.ble,
      );
      expect(out.relay!.targets, {c});
    });

    test('older phones (no beacon) are not relay targets', () {
      final r = MeshRouter(localId: b);
      r.onFrame(hello(c, 1), TransportKind.ble); // v1.5 phone: no beacon
      final out = r.onFrame(audio(a, 1), TransportKind.ble);
      expect(r.directNeighbours(), {a, c});
      expect(r.meshNeighbours(), isEmpty);
      expect(out.relay, isNull);
    });

    test('a packet for one neighbour goes only to it', () {
      final r = routerB();
      final out = r.onFrame(
        envelope(audio(0xEE, 1).encode(), relayer: a, to: c),
        TransportKind.ble,
      );
      expect(out.deliver, isNull); // not for us
      expect(out.relay!.targets, {c});
    });

    test('jitter only on relayed hops; originate sends at once', () {
      final r = routerB();
      final relayed = r.onFrame(audio(a, 1), TransportKind.ble).relay!;
      expect(relayed.delay, greaterThan(Duration.zero));
      expect(
        relayed.delay,
        lessThanOrEqualTo(const Duration(milliseconds: 12)),
      );
      final own = r.originate(audio(b, 1).encode())!;
      expect(own.delay, Duration.zero);
    });

    test('relay switch off: still hears relayed talk, passes nothing on', () {
      final r = routerB()..enabled = false;
      final out = r.onFrame(
        envelope(audio(0xEE, 1).encode(), relayer: a),
        TransportKind.ble,
      );
      expect(out.deliver, isNotNull);
      expect(out.relay, isNull);
    });

    test('rate limited to protect Bluetooth', () {
      final r = routerB(perSecond: 5);
      var relayed = 0;
      for (var i = 0; i < 20; i++) {
        if (r.onFrame(audio(a, i), TransportKind.ble).relay != null) relayed++;
      }
      expect(relayed, 5);
      expect(r.rateLimited, 15);
    });

    test('pings are never relayed, hellos at most every 3 s', () {
      final r = routerB();
      final ping = Frame.control(
        senderId: a,
        channel: 1,
        seq: 1,
        message: const ControlMessage(ControlKind.ping, to: b, time: 1),
      );
      expect(r.onFrame(ping, TransportKind.ble).relay, isNull);
      expect(r.onFrame(hello(a, 2), TransportKind.ble).relay, isNotNull);
      expect(r.onFrame(hello(a, 3), TransportKind.ble).relay, isNull);
    });

    test('nothing heard over the internet relay goes into the mesh', () {
      final r = routerB();
      final out = r.onFrame(audio(a, 1), TransportKind.internet);
      expect(out.deliver, isNotNull);
      expect(out.relay, isNull);
    });
  });

  test(
    'a planned relay is dropped if the target turns out to hear the source',
    () {
      final r = routerB();
      final relay = r.onFrame(audio(a, 1), TransportKind.ble).relay!;
      expect(relay.currentTargets(), {c, d});
      // During the jitter c and d report that they hear a themselves.
      r.onFrame(beaconFrom(c, {a, b}), TransportKind.ble);
      r.onFrame(beaconFrom(d, {a, b}), TransportKind.lan);
      expect(relay.currentTargets(), isEmpty);
    },
  );

  test('transport priority: Wi-Fi, then Wi-Fi Direct, then Bluetooth, then '
      'internet', () async {
    final lan = FakeTransport(TransportKind.lan);
    final wd = FakeTransport(TransportKind.wifiDirect);
    final ble = FakeTransport(TransportKind.ble);
    final net = FakeTransport(TransportKind.internet);
    final m = TransportManager(
      transports: [net, ble, wd, lan],
      localNodeId: a,
      localName: 'a',
      helloInterval: const Duration(hours: 1),
    );
    await m.start();
    final h = hello(b, 1);
    net.deliver(h);
    expect(m.bestLinkTo(b), TransportKind.internet);
    ble.deliver(hello(b, 2));
    expect(m.bestLinkTo(b), TransportKind.ble);
    wd.deliver(hello(b, 3));
    expect(m.bestLinkTo(b), TransportKind.wifiDirect);
    lan.deliver(hello(b, 4));
    expect(m.bestLinkTo(b), TransportKind.lan);
    await m.dispose();
  });

  group('encrypted forwarding', () {
    test(
      'relays pass private frames on byte for byte without reading them',
      () async {
        final key = await ChannelKey.deriveInline(
          5,
          'trail-mix',
          iterations: 1000,
        );
        final sealed = key.seal(audio(a, 9, channel: key.tag));
        final r = routerB();
        final out = r.onFrame(Frame.tryDecode(sealed)!, TransportKind.ble);
        final env = MeshPacket.tryDecode(Frame.tryDecode(out.relay!.bytes)!)!;
        expect(env.inner, sealed); // unchanged ciphertext
        final inner = Frame.tryDecode(env.inner)!;
        expect(inner.type, FrameType.sealed); // still opaque to the relay
        // Plain audio bytes never appear in what the relay sends.
        final plain = audio(a, 9).payload;
        expect(_contains(out.relay!.bytes, plain), isFalse);
        expect(key.open(inner)!.payload, plain);
      },
    );
  });

  group('TransportManager over a mesh', () {
    test('a - b - c chain: c hears a once, via 2 hops', () async {
      final air = RangeAir()
        ..link(a, b)
        ..link(b, c);
      final pa = await phone(air, a);
      final pb = await phone(air, b);
      final pc = await phone(air, c);
      await introduce([pa, pb, pc]);

      expect(pc.peer(a)?.meshHops, 2);
      expect(pa.peer(c)?.meshHops, 2);
      expect(pa.isReachable(c), isTrue);

      final heard = <ReceivedAudio>[];
      pc.audio.listen(heard.add);
      await pa.sendAudio(Uint8List.fromList([1, 2, 3]));
      await settle();
      expect(heard, hasLength(1));
      expect(heard.single.peerId, a);
      expect(heard.single.hops, 2);

      // And back: a hears c through b.
      final heardA = <ReceivedAudio>[];
      pa.audio.listen(heardA.add);
      await pc.sendAudio(Uint8List.fromList([4, 5]));
      await settle();
      expect(heardA.single.hops, 2);
      for (final m in [pa, pb, pc]) {
        await m.dispose();
      }
    });

    test('phones close together: direct only, no relaying, no delay', () async {
      final air = RangeAir()
        ..link(a, b)
        ..link(b, c)
        ..link(a, c);
      final pa = await phone(air, a);
      final pb = await phone(air, b);
      final pc = await phone(air, c);
      await introduce([pa, pb, pc]);
      air.mesh = 0;
      for (final m in [pa, pb, pc]) {
        expect(m.peers.every((p) => p.meshHops == null), isTrue);
      }

      final heard = <ReceivedAudio>[];
      pc.audio.listen(heard.add);
      await pa.sendAudio(Uint8List.fromList([1, 2, 3]));
      // Delivered synchronously by the direct send, before any timer runs.
      expect(heard.single.hops, 1);
      await settle();
      expect(heard, hasLength(1));
      expect(air.mesh, 0); // nobody relayed anything
      for (final m in [pa, pb, pc]) {
        await m.dispose();
      }
    });

    test(
      'a relay without the passcode carries private talk it cannot hear',
      () async {
        final key = await ChannelKey.deriveInline(
          5,
          'trail-mix',
          iterations: 1000,
        );
        final air = RangeAir()
          ..link(a, b)
          ..link(b, c);
        final pa = await phone(air, a, key: key);
        final pb = await phone(air, b); // public channel, no key
        final pc = await phone(air, c, key: key);
        await introduce([pa, pb, pc]);

        final heardB = <ReceivedAudio>[], heardC = <ReceivedAudio>[];
        pb.audio.listen(heardB.add);
        pc.audio.listen(heardC.add);
        await pa.sendAudio(Uint8List.fromList([7, 7, 7]));
        await settle();
        expect(heardC.single.hops, 2);
        expect(heardB, isEmpty);
        expect(pb.peers, isEmpty); // the relay learns nothing about them
        for (final m in [pa, pb, pc]) {
          await m.dispose();
        }
      },
    );

    test('max hops bounds the reach of a long line of phones', () async {
      // a - b - c - d - e - f : f is 5 hops from a, beyond the TTL of 4.
      const e = 0xE5, f = 0xF6;
      final ids = [a, b, c, d, e, f];
      final air = RangeAir();
      for (var i = 0; i + 1 < ids.length; i++) {
        air.link(ids[i], ids[i + 1]);
      }
      final ms = [for (final id in ids) await phone(air, id)];
      await introduce(ms);
      await introduce(ms);
      final heard = <int, int>{};
      for (var i = 1; i < ms.length; i++) {
        ms[i].audio.listen((x) => heard[ids[i]] = x.hops);
      }
      await ms.first.sendAudio(Uint8List.fromList([1]));
      await settle();
      expect(heard, {b: 1, c: 2, d: 3, e: 4});
      for (final m in ms) {
        await m.dispose();
      }
    });
  });
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
