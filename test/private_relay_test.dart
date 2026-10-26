// v1.5.4: private talk over the internet relay only (no LAN / BLE), both
// directions, after accept and after QR add. A third phone in the same
// channel room must receive nothing.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/friends/friend_links.dart';

import 'fake_transport.dart';

/// The relay server: forwards a frame to everyone else in the same room.
class RelayHub {
  final Map<String, List<RoomTransport>> rooms = {};
  final log = <(String, Frame)>[];
  List<Frame> inRoom(String room) => [
    for (final e in log)
      if (e.$1 == room) e.$2,
  ];
}

class RoomTransport extends FakeTransport {
  RoomTransport(this.hub, this.room) : super(TransportKind.internet);
  final RelayHub hub;
  final String room;

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    hub.rooms.putIfAbsent(room, () => []).add(this);
    await super.start(localNodeId: localNodeId, channel: channel);
  }

  @override
  Future<void> stop() async {
    hub.rooms[room]?.remove(this);
    await super.stop();
  }

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    await super.send(frame, peerIds: peerIds);
    final f = Frame.tryDecode(frame)!;
    hub.log.add((room, f));
    for (final t in [...?hub.rooms[room]]) {
      if (t != this) t.deliver(f);
    }
  }
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const channelRoom = 'ch1';

class Phone {
  Phone(this.hub, this.id, {int feature = featureLevel})
    : relay = RoomTransport(hub, channelRoom) {
    manager = TransportManager(
      transports: [relay],
      localNodeId: id,
      localName: 'P$id',
      channel: 1,
      helloInterval: const Duration(hours: 1),
    );
    links = FriendLinks(
      localId: id,
      radio: ManagerFriendRadio(manager),
      localName: () => 'P$id',
      relayFactory: (room) => RoomTransport(hub, room),
      feature: feature,
    );
    manager.sealedHandler = links.handle;
    manager.audio.listen(channelAudio.add);
    links.inbound.listen((f) {
      if (f.frame.type == FrameType.audio) privateAudio.add(f);
    });
  }
  final RelayHub hub;
  final int id;
  final RoomTransport relay;
  late final TransportManager manager;
  late final FriendLinks links;
  final channelAudio = <ReceivedAudio>[];
  final privateAudio = <FriendInbound>[];

  /// Everything that arrived on this phone's channel-room socket.
  int get channelRoomInbound =>
      hub.inRoom(channelRoom).where((f) => f.senderId != id).length;

  Future<void> talkPrivately(int to, int packets) async {
    for (var i = 0; i < packets; i++) {
      final ok = await links.send(
        to,
        links.frame(
          FrameType.audio,
          Uint8List.fromList([id, i, 7, 7]),
          seq: links.nextAudioSeq(),
        ),
      );
      expect(ok, isTrue, reason: 'friend link ready');
    }
  }
}

void main() {
  late RelayHub hub;
  late Phone a, b, c;

  Future<void> befriend(Phone x, Phone y) async {
    final kx = await PairKey.newKeyPair(), ky = await PairKey.newKeyPair();
    final keyX = await PairKey.agree(
      kx,
      await PairKey.publicKeyOf(ky),
      x.id,
      y.id,
    );
    final keyY = await PairKey.agree(
      ky,
      await PairKey.publicKeyOf(kx),
      y.id,
      x.id,
    );
    final now = DateTime.now();
    x.links.setFriends([
      ...x.links.friends,
      Friend(id: y.id, name: 'P${y.id}', key: keyX, added: now),
    ]);
    y.links.setFriends([
      ...y.links.friends,
      Friend(id: x.id, name: 'P${x.id}', key: keyY, added: now),
    ]);
    await x.links.sendPresence();
    await y.links.sendPresence();
    await settle();
  }

  setUp(() async {
    hub = RelayHub();
    a = Phone(hub, 1); // sends the friend request
    b = Phone(hub, 2); // accepts it
    c = Phone(hub, 3); // someone else on CH 1
    for (final p in [a, b, c]) {
      await p.manager.start();
      p.links.start();
    }
    for (final p in [a, b, c]) {
      await p.manager.sendHello();
    }
    await settle();
  });

  tearDown(() async {
    for (final p in [a, b, c]) {
      await p.links.dispose();
      p.manager.dispose();
    }
  });

  void expectThirdPhoneHeardNothing() {
    expect(c.channelAudio, isEmpty, reason: 'channel audio on 3rd phone');
    expect(c.privateAudio, isEmpty, reason: 'private audio on 3rd phone');
    expect(a.channelAudio, isEmpty);
    expect(b.channelAudio, isEmpty);
  }

  test('channel peers see each other over the relay only', () {
    expect(a.manager.peers.map((p) => p.id), containsAll([2, 3]));
    expect(hub.rooms[channelRoom], hasLength(3));
  });

  test('after accept: both sides join the friend relay room', () async {
    await befriend(a, b);
    final room = a.links.friend(2)!.key.room;
    expect(b.links.friend(1)!.key.room, room);
    expect(room, isNot(channelRoom));
    expect(hub.rooms[room]!.length, 2, reason: 'both phones in friend room');
    expect(a.links.bestLink(2), TransportKind.internet);
    expect(b.links.bestLink(1), TransportKind.internet);
    expect(a.links.featureOf(2), featureLevel);
    expect(b.links.featureOf(1), featureLevel);
    expect(a.links.needsUpdate(2), isFalse);
  });

  for (final dir in ['requester -> acceptor', 'acceptor -> requester']) {
    test('after accept, $dir over relay: 3rd phone hears nothing', () async {
      await befriend(a, b);
      final from = dir.startsWith('requester') ? a : b;
      final to = from == a ? b : a;
      final before = hub.inRoom(channelRoom).length;
      await from.talkPrivately(to.id, 25);
      await settle();
      expect(to.privateAudio, hasLength(25));
      expect(
        to.privateAudio.every((f) => f.via == TransportKind.internet),
        isTrue,
      );
      expectThirdPhoneHeardNothing();
      // Not one private frame went into the channel room.
      expect(
        hub.inRoom(channelRoom).length,
        before,
        reason: 'private frames leaked into the channel room',
      );
      expect(
        from.relay.sent.where((s) => s.frame.type == FrameType.audio),
        isEmpty,
      );
    });
  }

  for (final dir in ['scanner -> shower', 'shower -> scanner']) {
    test('after QR add, $dir over relay: 3rd phone hears nothing', () async {
      // B shows a QR code, A scans it.
      final code = PairKey.randomSecret();
      final shower = PairKey.fromQrCode(code, 2);
      b.links.addPending(shower);
      final paired = <(int, String, PairKey)>[];
      b.links.paired.listen(paired.add);
      a.links.setFriends([
        Friend(
          id: 2,
          name: 'P2',
          key: PairKey.fromQrCode(code, 2),
          added: DateTime.now(),
        ),
      ]);
      await a.links.sendPresence();
      await settle();
      expect(paired.single.$1, 1, reason: 'shower heard the scanner');
      b.links.removePending(shower);
      b.links.setFriends([
        Friend(id: 1, name: 'P1', key: paired.single.$3, added: DateTime.now()),
      ]);
      await b.links.sendPresence();
      await a.links.sendPresence();
      await settle();
      final room = a.links.friend(2)!.key.room;
      expect(b.links.friend(1)!.key.room, room);
      expect(hub.rooms[room]!.length, 2);
      expect(a.links.bestLink(2), TransportKind.internet);
      expect(b.links.bestLink(1), TransportKind.internet);

      final from = dir.startsWith('scanner') ? a : b;
      final to = from == a ? b : a;
      final before = hub.inRoom(channelRoom).length;
      await from.talkPrivately(to.id, 10);
      await settle();
      expect(to.privateAudio, hasLength(10));
      expectThirdPhoneHeardNothing();
      expect(hub.inRoom(channelRoom).length, before);
    });
  }

  test('3rd phone in the friend room cannot open the frames', () async {
    await befriend(a, b);
    // Worst case: a relay mix-up puts C into A and B's friend room.
    final room = a.links.friend(2)!.key.room;
    final spy = RoomTransport(hub, room);
    final seen = <Frame>[];
    spy.frames.listen((f) {
      seen.add(f.frame);
      c.manager.handleInbound(f); // sealed -> channel key / friend links
    });
    await spy.start(localNodeId: 3, channel: 0);
    await a.talkPrivately(2, 5);
    await settle();
    expect(seen.where((f) => f.type == FrameType.sealed), hasLength(5));
    expect(seen.where((f) => f.type == FrameType.audio), isEmpty);
    expect(b.privateAudio, hasLength(5));
    expectThirdPhoneHeardNothing();
  });

  test('version gate: a friend on an older app needs to update', () async {
    final old = Phone(hub, 4, feature: 15); // v1.5.0 - v1.5.3
    await old.manager.start();
    old.links.start();
    await befriend(a, old);
    expect(a.links.isOnline(4), isTrue);
    expect(a.links.featureOf(4), 15);
    expect(a.links.needsUpdate(4), isTrue);
    expect(old.links.featureOf(1), featureLevel);
    await old.links.dispose();
    old.manager.dispose();
  });
}
