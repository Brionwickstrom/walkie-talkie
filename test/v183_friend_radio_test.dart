import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/mesh.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/friends/friend_links.dart';
import 'package:walkie_talkie/friends/friend_messenger_link.dart';
import 'package:walkie_talkie/friends/friend_ring_link.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/radio_clip.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/ringer.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';

import 'fake_transport.dart';
import 'lora_test.dart' show FakeCodec, speech, containsBytes;
import 'messaging_fakes.dart';

const alice = 0x1111, bob = 0x2222, relayer = 0x3333;
const aliceRadio = 0xA1A1, bobRadio = 0xB0B0;
const friendScope = 0x40000;

/// Two Meshtastic radios in range of each other: what one sends, the
/// other hears (from its node number).
class AirRadio implements RadioLink {
  AirRadio(this.node);
  final int node;
  AirRadio? other;
  final sent = <(Uint8List, int, bool)>[];
  final _packets = StreamController<MeshPacketPb>.broadcast(sync: true);
  final _ready = StreamController<bool>.broadcast(sync: true);

  @override
  bool get ready => true;
  @override
  Stream<bool> get readyChanges => _ready.stream;
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;
  @override
  int? get queueFree => null;

  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
  }) async {
    sent.add((payload, to, wantAck));
    final o = other;
    if (o == null) return;
    scheduleMicrotask(
      () => o._packets.add(
        MeshPacketPb(
          from: node,
          to: to,
          rxSnr: 3,
          rxRssi: -110,
          hopLimit: 3,
          hopStart: 3,
          decoded: MeshData(portnum: PortNum.privateApp, payload: payload),
        ),
      ),
    );
  }
}

/// One phone: a manager with only a LoRa radio, friend links and the
/// friend messenger.
class Phone {
  Phone(this.id, this.radio, this.clock, PairKey key, int friendId) {
    lora = LoraTransport(
      radio: radio,
      clock: clock.call,
      limiter: LoraRateLimiter(burst: 1000, clock: clock.call),
      pumpInterval: const Duration(hours: 1),
    );
    m = TransportManager(
      transports: [lora],
      localNodeId: id,
      localName: 'P$id',
      channel: 1,
      clock: clock.call,
      helloInterval: const Duration(hours: 1),
    );
    links = FriendLinks(
      localId: id,
      radio: ManagerFriendRadio(m),
      far: ManagerFriendFarPaths(m),
      localName: () => 'P$id',
      clock: clock.call,
    );
    links.setFriends([
      Friend(id: friendId, name: 'F', key: key, added: clock.now),
    ]);
    m.sealedHandler = links.handle;
    messenger = Messenger(
      link: FriendMessengerLink(links, friendScope),
      storage: MemoryMessageStorage(),
      clock: clock.call,
      random: Random(id),
    );
    messenger.radioClipToVoice = (b) async =>
        VoiceClip([Uint8List(5)], sentAt: clock.now).encode();
  }

  final int id;
  final AirRadio radio;
  final FakeClock clock;
  late final LoraTransport lora;
  late final TransportManager m;
  late final FriendLinks links;
  late final Messenger messenger;

  Future<void> start() async {
    await m.start();
    await messenger.start();
  }

  Future<void> dispose() async {
    await messenger.dispose();
    await links.dispose();
    await m.dispose();
  }
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Fake mesh / radio paths for FriendLinks unit tests.
class FakeFar implements FriendFarPaths {
  bool neighbours = true;
  bool radio = false;
  final Set<(TransportKind, int)> heard = {};
  final mesh = <Uint8List>[];
  final radioSent = <Frame>[];
  @override
  bool get hasMeshNeighbours => neighbours;
  @override
  bool meshReachable(int peer) => false;
  @override
  bool sendMesh(Uint8List bytes, int peer) {
    mesh.add(bytes);
    return neighbours;
  }

  @override
  bool radioReachable(int peer) => radio;
  @override
  bool sendRadio(Frame inner, Uint8List bytes, int peer) {
    if (inner.type == FrameType.audio) return false;
    radioSent.add(Frame.tryDecode(bytes)!);
    return true;
  }

  @override
  bool heardOn(TransportKind kind, int peer) => heard.contains((kind, peer));
}

class LinkRadio implements FriendRadio {
  bool up = true;
  final sent = <(TransportKind, Uint8List)>[];
  @override
  Future<void> broadcast(Uint8List bytes) async {}
  @override
  Future<void> sendOn(TransportKind kind, Uint8List bytes, int peer) async =>
      sent.add((kind, bytes));
  @override
  bool canReach(TransportKind kind, int peer) => up;
}

void main() {
  group('friend messages over the LoRa radio', () {
    late FakeClock clock;
    late PairKey key;
    late Phone a, b;

    setUp(() async {
      clock = FakeClock();
      key = PairKey(PairKey.randomSecret());
      final ra = AirRadio(aliceRadio), rb = AirRadio(bobRadio);
      ra.other = rb;
      rb.other = ra;
      a = Phone(alice, ra, clock, key, bob);
      b = Phone(bob, rb, clock, key, alice);
      await a.start();
      await b.start();
      // Each phone's radio presence hello tells the other its radio node.
      await a.m.sendRadioHello();
      await b.m.sendRadioHello();
      await settle();
      ra.sent.clear();
      rb.sent.clear();
    });

    tearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    Future<void> run(Duration total) async {
      final steps = total.inMilliseconds ~/ 500;
      for (var i = 0; i < steps; i++) {
        clock.advance(const Duration(milliseconds: 500));
        await a.messenger.tick();
        await b.messenger.tick();
        await a.lora.pump();
        await b.lora.pump();
        await settle();
      }
    }

    test('only the radio reaches: friend shows connected via radio', () {
      expect(a.links.isOnline(bob), isTrue);
      expect(a.links.pathTo(bob)!.kind, FriendPathKind.radio);
      expect(a.links.bestLink(bob), TransportKind.lora);
      // No live private talk over LoRa.
      expect(a.links.canTalkLive(bob), isFalse);
      expect(
        friendStatusLineFor(a.links.statusOf(bob), clock.now),
        startsWith('Connected privately via radio (slow)'),
      );
    });

    test(
      'text and location: chunked, sealed (radio sees only ciphertext), '
      'addressed to the friend radio, delivered and shown via radio',
      () async {
        final got = <ChatArrival>[];
        b.messenger.chats.listen(got.add);
        await a.messenger.outbox.load();
        await b.messenger.outbox.load();
        final text =
            'Meet at the north trailhead by the big pine, bring '
                'water and the spare headlamp. ' *
            4; // ~350 B: several chunks
        final e = await a.messenger.sendChat(
          ChatBody.text(text),
          toPeer: bob,
          channel: friendScope,
        );
        await a.messenger.sendChat(
          ChatBody(type: ChatType.location, lat: 45.52, lng: -122.68),
          toPeer: bob,
          channel: friendScope,
        );
        await run(const Duration(minutes: 2));

        expect(
          got.map((x) => x.body.type),
          unorderedEquals([ChatType.text, ChatType.location]),
        );
        expect(
          got.firstWhere((x) => x.body.type == ChatType.text).body.text,
          text,
        );
        expect(got.every((x) => x.viaRadio), isTrue);
        expect(a.messenger.outbox.entries, isEmpty); // acked over LoRa
        expect(a.messenger.deliveredOverRadio(e.msgId, bob), isTrue);

        final sent = a.radio.sent;
        // Chunked: several packets, each within the LoRa payload budget.
        expect(sent.length, greaterThan(3));
        for (final (bytes, to, ack) in sent) {
          expect(bytes.length, lessThanOrEqualTo(loraPayloadBudget));
          final f = Frame.tryDecode(bytes)!;
          expect(f.type, FrameType.sealed);
          expect(f.channel, key.tag);
          // Opaque: no plaintext words, and a channel phone without the
          // pair key cannot open it.
          expect(containsBytes(bytes, utf8.encode('trailhead')), isFalse);
          expect(containsBytes(bytes, utf8.encode('spare')), isFalse);
          expect(PairKey(PairKey.randomSecret()).open(f), isNull);
          expect(key.open(f), isNotNull);
          // Directed to Bob's radio (Meshtastic retries until acked).
          expect(to, bobRadio);
          expect(ack, isTrue);
        }
      },
    );

    test('photos wait for a faster link', () async {
      await a.messenger.outbox.load();
      await a.messenger.sendChat(
        ChatBody(
          type: ChatType.photo,
          data: Uint8List(4000),
          width: 10,
          height: 10,
        ),
        toPeer: bob,
        channel: friendScope,
      );
      await run(const Duration(seconds: 30));
      expect(a.radio.sent, isEmpty);
      expect(a.messenger.outbox.entries, hasLength(1));
    });

    test('short voice clip: the Codec 2 copy goes sealed in chunks', () async {
      final got = <Object>[];
      b.messenger.received.listen(got.add);
      await a.messenger.outbox.load();
      await b.messenger.outbox.load();
      final radio = RadioClipCodec(FakeCodec.new).encode(speech(3000))!;
      await a.messenger.send(
        VoiceClip([
          for (var i = 0; i < 150; i++) Uint8List.fromList(List.filled(30, i)),
        ]),
        toPeer: bob,
        channel: friendScope,
        radioClip: radio,
      );
      await run(const Duration(minutes: 3));
      expect(got, hasLength(1));
      expect(b.messenger.inbox.entries.single.viaRadio, isTrue);
      expect(a.messenger.outbox.entries, isEmpty);
      for (final (bytes, _, _) in a.radio.sent) {
        expect(bytes.length, lessThanOrEqualTo(loraPayloadBudget));
        expect(Frame.tryDecode(bytes)!.type, FrameType.sealed);
      }
    });

    test('live private audio never goes over the radio', () async {
      final ok = await a.links.send(
        bob,
        a.links.frame(
          FrameType.audio,
          Uint8List(40),
          seq: a.links.nextAudioSeq(),
        ),
      );
      await a.lora.pump();
      expect(ok, isFalse);
      expect(a.radio.sent, isEmpty);
    });

    test('rings go over the radio to a friend and are answered', () async {
      final ra = Ringer(
        link: FriendAwareRingLink(
          ManagerRingLink(a.m),
          () => a.links,
          friendScope,
        ),
        clock: clock.call,
      );
      final rb = Ringer(
        link: FriendAwareRingLink(
          ManagerRingLink(b.m),
          () => b.links,
          friendScope,
        ),
        clock: clock.call,
      );
      ra.start();
      rb.start();
      final incoming = <IncomingRing>[];
      rb.incoming.listen(incoming.add);
      final r = await ra.ring(toPeer: bob);
      for (var i = 0; i < 4; i++) {
        await a.lora.pump();
        await b.lora.pump();
        await settle();
      }
      expect(incoming.single.from, alice);
      expect(incoming.single.channel, friendScope);
      expect(r.status[bob], RingStatus.delivered);
      for (final (bytes, _, _) in a.radio.sent) {
        expect(Frame.tryDecode(bytes)!.type, FrameType.sealed);
      }
      await ra.dispose();
      await rb.dispose();
    });
  });

  group('friend frames relayed by the phone mesh', () {
    late FakeClock clock;
    late PairKey key;
    late FakeTransport ble;
    late TransportManager m;
    late FriendLinks links;

    setUp(() async {
      clock = FakeClock();
      key = PairKey(PairKey.randomSecret());
      ble = FakeTransport(TransportKind.ble)
        ..unreachable.add(bob); // Bob is out of Bluetooth range
      m = TransportManager(
        transports: [ble],
        localNodeId: alice,
        localName: 'A',
        channel: 1,
        clock: clock.call,
        helloInterval: const Duration(hours: 1),
      );
      links = FriendLinks(
        localId: alice,
        radio: ManagerFriendRadio(m),
        far: ManagerFriendFarPaths(m),
        localName: () => 'A',
        clock: clock.call,
      );
      links.setFriends([
        Friend(id: bob, name: 'B', key: key, added: clock.now),
      ]);
      m.sealedHandler = links.handle;
      await m.start();
    });

    tearDown(() async {
      await links.dispose();
      await m.dispose();
    });

    Frame relayed(Uint8List inner, {int seq = 1}) => Frame.tryDecode(
      MeshPacket.encode(
        relayer: relayer,
        seq: seq,
        hops: 2, // Bob -> relayer -> us
        maxHops: 4,
        to: alice,
        inner: inner,
      ),
    )!;

    test('accepted via the pair key, path = phone mesh, deduped', () async {
      final got = <FriendInbound>[];
      links.inbound.listen(got.add);
      // The relayer is a direct Bluetooth neighbour.
      ble.deliver(
        Frame.control(
          senderId: relayer,
          channel: 1,
          seq: 1,
          message: ControlMessage(ControlKind.hello, name: 'R'),
        ),
      );
      // ...and runs the mesh (its beacon).
      ble.deliver(Frame.tryDecode(MeshBeacon.encode(relayer, 2, [alice]))!);
      final inner = Frame(
        type: FrameType.data,
        senderId: bob,
        channel: 0,
        seq: 77,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      final sealed = key.seal(inner);
      ble.deliver(relayed(sealed, seq: 5));
      await settle();
      expect(got, hasLength(1));
      expect(got.single.frame.payload, [1, 2, 3]);
      expect(got.single.hops, greaterThan(1));
      expect(links.pathTo(bob)!.kind, FriendPathKind.mesh);
      expect(
        friendStatusLineFor(links.statusOf(bob), clock.now),
        startsWith('Connected privately via phone mesh'),
      );
      // With no direct link, our replies go back through the mesh.
      ble.sent.clear();
      final ok = await links.send(
        bob,
        links.frame(FrameType.data, Uint8List.fromList([9])),
      );
      expect(ok, isTrue);
      final out = ble.sent.last.frame;
      expect(out.type, FrameType.mesh);
      final pkt = MeshPacket.tryDecode(out)!;
      expect(pkt.to, bob);
      expect(Frame.tryDecode(pkt.inner)!.type, FrameType.sealed);

      // The same inner frame again over other paths: delivered once.
      ble.deliver(relayed(sealed, seq: 6));
      links.handle(InboundFrame(Frame.tryDecode(sealed)!, TransportKind.ble));
      links.handle(InboundFrame(Frame.tryDecode(sealed)!, TransportKind.lora));
      await settle();
      expect(got, hasLength(1));
    });

    test('a frame sealed with another key is rejected on every path', () async {
      final got = <FriendInbound>[];
      links.inbound.listen(got.add);
      final wrong = PairKey(PairKey.randomSecret());
      final bytes = wrong.seal(
        Frame(
          type: FrameType.data,
          senderId: bob,
          channel: 0,
          seq: 3,
          payload: Uint8List(4),
        ),
      );
      final f = Frame.tryDecode(bytes)!;
      expect(links.handle(InboundFrame(f, TransportKind.ble)), isFalse);
      expect(links.handle(InboundFrame(f, TransportKind.lora)), isFalse);
      expect(
        links.handle(InboundFrame(f, TransportKind.ble, hops: 3)),
        isFalse,
      );
      // A tampered frame with the right key fails the AEAD check too.
      final good = Uint8List.fromList(
        key.seal(
          Frame(
            type: FrameType.data,
            senderId: bob,
            channel: 0,
            seq: 4,
            payload: Uint8List(4),
          ),
        ),
      );
      good[good.length - 1] ^= 1;
      expect(
        links.handle(InboundFrame(Frame.tryDecode(good)!, TransportKind.lora)),
        isFalse,
      );
      await settle();
      expect(got, isEmpty);
      expect(links.isOnline(bob), isFalse);
      expect(links.statusOf(bob).lastHeard, isNull);
    });
  });

  group('friend status line', () {
    late DateTime now;
    late PairKey key;
    late LinkRadio radio;
    late FakeFar far;
    late FriendLinks a;

    setUp(() {
      now = DateTime(2026, 10, 26, 10, 5);
      key = PairKey(PairKey.randomSecret());
      radio = LinkRadio();
      far = FakeFar()..neighbours = false;
      a = FriendLinks(
        localId: alice,
        radio: radio,
        far: far,
        localName: () => 'A',
        clock: () => now,
      );
      a.setFriends([Friend(id: bob, name: 'B', key: key, added: now)]);
    });

    tearDown(() => a.dispose());

    InboundFrame from(TransportKind k, int seq, {int hops = 1}) => InboundFrame(
      Frame.tryDecode(
        key.seal(
          Frame.control(
            senderId: bob,
            channel: 0,
            seq: seq,
            message: ControlMessage(ControlKind.fhello, name: 'B'),
          ),
        ),
      )!,
      k,
      hops: hops,
    );

    String line() => friendStatusLineFor(a.statusOf(bob), now);

    test('never heard: not connected yet, messages wait', () {
      expect(line(), 'Not connected privately yet · messages wait up to 24 h');
      expect(a.isOnline(bob), isFalse);
    });

    test('heard on Bluetooth: connected via Bluetooth', () {
      a.handle(from(TransportKind.ble, 1));
      expect(
        line(),
        'Connected privately via Bluetooth · end-to-end encrypted',
      );
    });

    test('lost beacons while the phone is still heard on Bluetooth stay '
        'connected (the screenshot case)', () {
      a.handle(from(TransportKind.ble, 1));
      now = now.add(const Duration(seconds: 25)); // > 15 s, beacons lost
      expect(a.isOnline(bob), isFalse); // old rule would say "not"
      far.heard.add((TransportKind.ble, bob)); // its channel hellos arrive
      expect(a.isOnline(bob), isTrue);
      expect(line(), startsWith('Connected privately via Bluetooth'));
      now = now.add(const Duration(seconds: 40)); // > 60 s: trust ends
      expect(a.isOnline(bob), isFalse);
    });

    test('link gone: connected (reconnecting) for 2 min, then not', () {
      a.handle(from(TransportKind.ble, 1));
      radio.up = false;
      now = now.add(const Duration(seconds: 30));
      expect(a.isOnline(bob), isFalse);
      expect(
        line(),
        'Connected privately via Bluetooth · last heard 30 s ago, '
        'reconnecting',
      );
      now = now.add(const Duration(minutes: 3));
      expect(
        line(),
        'Not connected privately · last heard 3 min ago · messages wait up '
        'to 24 h',
      );
    });

    test('relayed by the mesh or only on the radio', () {
      far.neighbours = true;
      a.handle(from(TransportKind.ble, 1, hops: 3));
      radio.up = false; // no direct link
      expect(a.pathTo(bob)!.kind, FriendPathKind.mesh);
      expect(line(), startsWith('Connected privately via phone mesh (3 hops)'));
      far.neighbours = false;
      far.radio = true;
      expect(line(), startsWith('Connected privately via radio (slow)'));
      expect(a.canTalkLive(bob), isFalse);
    });

    test('a path that times out emits a change (header refreshes)', () async {
      var changes = 0;
      a.changes.listen((_) => changes++);
      a.handle(from(TransportKind.ble, 1));
      await settle();
      final before = changes;
      expect(a.checkPaths(), isFalse);
      now = now.add(const Duration(seconds: 20));
      expect(a.checkPaths(), isTrue);
      await settle();
      expect(changes, greaterThan(before));
    });

    test('pure line: every path label', () {
      final t = DateTime(2026);
      String l(FriendPath p) =>
          friendStatusLineFor(FriendLinkStatus(path: p), t);
      expect(
        l(const FriendPath(FriendPathKind.direct, TransportKind.lan)),
        'Connected privately via Wi-Fi · end-to-end encrypted',
      );
      expect(
        l(const FriendPath(FriendPathKind.direct, TransportKind.internet)),
        'Connected privately via Internet · end-to-end encrypted',
      );
      expect(
        l(const FriendPath(FriendPathKind.mesh, TransportKind.ble, hops: 2)),
        'Connected privately via phone mesh (2 hops) · end-to-end encrypted',
      );
      expect(
        l(const FriendPath(FriendPathKind.radio, TransportKind.lora)),
        'Connected privately via radio (slow) · end-to-end encrypted',
      );
    });
  });
}
