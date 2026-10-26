import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/mic_gate.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/friends/friend_links.dart';

import 'fake_transport.dart';

/// One Wi-Fi network: every frame reaches every other phone on it.
class Bus {
  final List<BusTransport> members = [];
}

class BusTransport extends FakeTransport {
  BusTransport(this.bus) : super(TransportKind.lan) {
    bus.members.add(this);
  }
  final Bus bus;

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    await super.send(frame, peerIds: peerIds);
    final f = Frame.tryDecode(frame)!;
    for (final t in bus.members) {
      if (t != this) t.deliver(f);
    }
  }
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Phone {
  Phone(Bus bus, this.id) : lan = BusTransport(bus) {
    manager = TransportManager(
      transports: [lan],
      localNodeId: id,
      localName: 'P$id',
      channel: 1,
      helloInterval: const Duration(hours: 1),
    );
    links = FriendLinks(
      localId: id,
      radio: ManagerFriendRadio(manager),
      localName: () => 'P$id',
    );
    manager.sealedHandler = links.handle;
    manager.audio.listen(channelAudio.add);
    links.inbound.listen((f) {
      if (f.frame.type == FrameType.audio) privateAudio.add(f);
    });
  }
  final int id;
  final BusTransport lan;
  late final TransportManager manager;
  late final FriendLinks links;
  final channelAudio = <ReceivedAudio>[];
  final privateAudio = <FriendInbound>[];

  Future<void> talkPrivately(int to, int packets) async {
    for (var i = 0; i < packets; i++) {
      final ok = await links.send(
        to,
        links.frame(
          FrameType.audio,
          Uint8List.fromList([id, i]),
          seq: links.nextAudioSeq(),
        ),
      );
      expect(ok, isTrue, reason: 'friend link ready');
    }
  }
}

void main() {
  late Bus bus;
  late Phone a, b, c;

  setUp(() async {
    bus = Bus();
    a = Phone(bus, 1); // initiator
    b = Phone(bus, 2); // acceptor
    c = Phone(bus, 3); // someone else on the same channel
    for (final p in [a, b, c]) {
      await p.manager.start();
      p.links.start();
    }
    for (final p in [a, b, c]) {
      await p.manager.sendHello();
    }
    // Request / accept: both sides derive the same key from ECDH.
    final ka = await PairKey.newKeyPair(), kb = await PairKey.newKeyPair();
    final keyA = await PairKey.agree(ka, await PairKey.publicKeyOf(kb), 1, 2);
    final keyB = await PairKey.agree(kb, await PairKey.publicKeyOf(ka), 2, 1);
    final now = DateTime.now();
    a.links.setFriends([Friend(id: 2, name: 'P2', key: keyA, added: now)]);
    b.links.setFriends([Friend(id: 1, name: 'P1', key: keyB, added: now)]);
    await a.links.sendPresence();
    await b.links.sendPresence();
    await settle();
  });

  tearDown(() async {
    for (final p in [a, b, c]) {
      await p.links.dispose();
      p.manager.dispose();
    }
  });

  test('friendship is symmetric after accept', () {
    expect(a.links.isOnline(2), isTrue);
    expect(b.links.isOnline(1), isTrue);
    expect(c.links.isOnline(1), isFalse);
    expect(a.links.friend(2)!.key.encoded, b.links.friend(1)!.key.encoded);
  });

  test('initiator -> acceptor: only the friend hears it', () async {
    await a.talkPrivately(2, 20);
    await settle();
    expect(b.privateAudio, hasLength(20));
    expect(b.channelAudio, isEmpty);
    expect(c.channelAudio, isEmpty);
    expect(c.privateAudio, isEmpty);
    // Nothing went out as a plain audio frame.
    expect(a.lan.sent.where((s) => s.frame.type == FrameType.audio), isEmpty);
  });

  test('acceptor -> initiator: only the friend hears it', () async {
    await b.talkPrivately(1, 20);
    await settle();
    expect(a.privateAudio, hasLength(20));
    expect(a.channelAudio, isEmpty);
    expect(c.channelAudio, isEmpty);
    expect(c.privateAudio, isEmpty);
    expect(b.lan.sent.where((s) => s.frame.type == FrameType.audio), isEmpty);
  });

  test('QR add is symmetric too, and a stranger hears nothing', () async {
    final code = PairKey.randomSecret();
    final shower = PairKey.fromQrCode(code, 3);
    c.links.addPending(shower);
    final paired = <(int, String, PairKey)>[];
    c.links.paired.listen(paired.add);
    final now = DateTime.now();
    // A scans C's code.
    a.links.setFriends([
      ...a.links.friends,
      Friend(id: 3, name: 'P3', key: PairKey.fromQrCode(code, 3), added: now),
    ]);
    await a.links.sendPresence();
    await settle();
    expect(paired.single.$1, 1);
    c.links.removePending(shower);
    c.links.setFriends([
      Friend(id: 1, name: 'P1', key: paired.single.$3, added: now),
    ]);
    await c.links.sendPresence();
    await settle();
    expect(a.links.isOnline(3), isTrue);
    expect(c.links.isOnline(1), isTrue);
    await c.talkPrivately(1, 5);
    await settle();
    expect(a.privateAudio, hasLength(5));
    expect(b.privateAudio, isEmpty);
    expect(b.channelAudio, isEmpty);
  });

  test(
    'no friend link: nothing is sent at all (no channel fallback)',
    () async {
      expect(
        await c.links.send(1, c.links.frame(FrameType.audio, Uint8List(3))),
        isFalse,
      );
      await settle();
      expect(a.channelAudio, isEmpty);
      expect(b.channelAudio, isEmpty);
    },
  );

  test('mic restarted for a new destination never feeds the old one', () async {
    final mics = <StreamController<Uint8List>>[];
    final gate = MicGate(
      open: () async {
        final m = StreamController<Uint8List>();
        mics.add(m);
        return m.stream;
      },
      close: () async {},
    );
    final channel = <Uint8List>[], private = <Uint8List>[];
    await gate.start(channel.add); // a channel session left the mic on
    await gate.start(private.add); // then "Hold to talk" to a friend
    for (final m in mics) {
      m.add(Uint8List(1));
    }
    await settle();
    expect(channel, isEmpty);
    expect(private, hasLength(1));
    await gate.stop();
  });
}
