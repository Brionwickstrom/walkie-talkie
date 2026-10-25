import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/chat/chat_store.dart';
import 'package:walkie_talkie/chat/photo.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/friends/friend_links.dart';
import 'package:walkie_talkie/friends/friend_messenger_link.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/outbox.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart';

/// LAN/BLE between friend links in a test: everyone hears everyone.
class FakeAir {
  final Map<int, FriendLinks> links = {};
  bool up = true;
  int sent = 0;
}

class FakeRadio implements FriendRadio {
  FakeRadio(this.air, this.me);
  final FakeAir air;
  final int me;

  void _deliver(Uint8List bytes, int? to) {
    if (!air.up) return;
    air.sent++;
    final f = Frame.tryDecode(bytes)!;
    for (final e in air.links.entries) {
      if (e.key == me || (to != null && e.key != to)) continue;
      scheduleMicrotask(
        () => e.value.handle(InboundFrame(f, TransportKind.lan)),
      );
    }
  }

  @override
  Future<void> broadcast(Uint8List bytes) async => _deliver(bytes, null);
  @override
  Future<void> sendOn(TransportKind kind, Uint8List bytes, int peer) async =>
      _deliver(bytes, peer);
  @override
  bool canReach(TransportKind kind, int peer) =>
      air.up && kind == TransportKind.lan && air.links.containsKey(peer);
}

/// A relay room shared by transports with the same name.
class RoomHub {
  final Map<String, List<RoomTransport>> rooms = {};
}

class RoomTransport extends FakeTransport {
  RoomTransport(this.hub, this.room) : super(TransportKind.internet) {
    hub.rooms.putIfAbsent(room, () => []).add(this);
  }
  final RoomHub hub;
  final String room;

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    final f = Frame.tryDecode(frame)!;
    for (final t in hub.rooms[room]!) {
      if (t != this) scheduleMicrotask(() => t.deliver(f));
    }
  }
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('PairKey', () {
    test('ECDH agree gives the same key on both phones', () async {
      final a = await PairKey.newKeyPair(), b = await PairKey.newKeyPair();
      final ka = await PairKey.agree(a, await PairKey.publicKeyOf(b), 1, 2);
      final kb = await PairKey.agree(b, await PairKey.publicKeyOf(a), 2, 1);
      expect(ka.encoded, kb.encoded);
      expect(ka.room, kb.room);
      expect(ka.safetyCode, kb.safetyCode);
      expect(RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(ka.room), isTrue);
      final sealed = ka.seal(
        Frame(
          type: FrameType.data,
          senderId: 1,
          channel: 0,
          seq: 5,
          payload: Uint8List.fromList([1, 2, 3]),
        ),
      );
      final opened = kb.open(Frame.tryDecode(sealed)!);
      expect(opened!.payload, [1, 2, 3]);
      final other = PairKey(PairKey.randomSecret());
      expect(other.open(Frame.tryDecode(sealed)!), isNull);
    });

    test('QR text round trip and shared key', () {
      final code = PairKey.randomSecret();
      final t = PairKey.qrText(
        ownerId: 0xABCD1234,
        ownerName: 'Bandit 7',
        code: code,
      );
      final q = PairKey.parseQr(t)!;
      expect(q.id, 0xABCD1234);
      expect(q.name, 'Bandit 7');
      expect(
        PairKey.fromQrCode(q.code, q.id).encoded,
        PairKey.fromQrCode(code, 0xABCD1234).encoded,
      );
      expect(PairKey.parseQr('hello'), isNull);
    });
  });

  group('wire compatibility', () {
    test('new control kinds and x survive a round trip', () {
      final m = ControlMessage(
        ControlKind.friendReq,
        to: 7,
        id: 3,
        x: const {'pk': 'abc'},
      );
      final d = ControlMessage.tryDecode(m.encode())!;
      expect(d.kind, ControlKind.friendReq);
      expect(d.x['pk'], 'abc');
    });

    test('a kind this version does not know is ignored, not a crash', () {
      final bytes = Uint8List.fromList(
        '{"k":"fromTheFuture","x":{}}'.codeUnits,
      );
      expect(ControlMessage.tryDecode(bytes), isNull);
    });

    test('hello extras reach the other phone (feature level, name)', () async {
      final lan = FakeTransport(TransportKind.lan);
      final a =
          TransportManager(
              transports: [lan],
              localNodeId: 1,
              localName: 'a',
              helloInterval: const Duration(hours: 1),
            )
            ..helloExtras = () => {
              'v': featureLevel,
              'cn': 'Family',
              'ce': '🔥',
              'ct': 5,
            };
      await a.start();
      await a.sendHello();
      final hello = lan.sent.last.frame;
      final lan2 = FakeTransport(TransportKind.lan);
      final b = TransportManager(
        transports: [lan2],
        localNodeId: 2,
        localName: 'b',
        helloInterval: const Duration(hours: 1),
      );
      await b.start();
      b.handleInbound(InboundFrame(hello, TransportKind.lan));
      expect(b.peer(1)!.supportsChat, isTrue);
      expect(b.peer(1)!.info['cn'], 'Family');
      // Blocked phones are dropped completely.
      b.blocked.add(3);
      b.handleInbound(
        InboundFrame(
          Frame.control(
            senderId: 3,
            channel: 1,
            seq: 1,
            message: const ControlMessage(ControlKind.hello, name: 'x'),
          ),
          TransportKind.lan,
        ),
      );
      expect(b.peer(3), isNull);
      a.dispose();
      b.dispose();
    });

    test(
      'sealed frames nobody on the channel can open go to friends',
      () async {
        final lan = FakeTransport(TransportKind.lan);
        final m = TransportManager(
          transports: [lan],
          localNodeId: 2,
          localName: 'b',
          helloInterval: const Duration(hours: 1),
        );
        final got = <Frame>[];
        m.sealedHandler = (f) {
          got.add(f.frame);
          return true;
        };
        await m.start();
        final k = PairKey(PairKey.randomSecret());
        final sealed = k.seal(
          Frame.control(
            senderId: 1,
            channel: 0,
            seq: 1,
            message: const ControlMessage(ControlKind.fhello, name: 'a'),
          ),
        );
        m.handleInbound(
          InboundFrame(Frame.tryDecode(sealed)!, TransportKind.lan),
        );
        expect(got, hasLength(1));
        expect(m.peer(1), isNull); // not a channel member
        m.dispose();
      },
    );
  });

  group('FriendLinks', () {
    late FakeAir air;
    late RoomHub hub;
    late DateTime now;
    late FriendLinks a, b;
    late PairKey key;

    FriendLinks make(int id, String name) {
      final l = FriendLinks(
        localId: id,
        radio: FakeRadio(air, id),
        localName: () => name,
        relayFactory: (room) => RoomTransport(hub, room),
        clock: () => now,
      );
      air.links[id] = l;
      return l;
    }

    setUp(() {
      air = FakeAir();
      hub = RoomHub();
      now = DateTime(2026, 10, 25, 12);
      a = make(1, 'Alpha');
      b = make(2, 'Bravo');
      key = PairKey(PairKey.randomSecret());
    });

    tearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    test('presence over Wi-Fi, then over the relay room only', () async {
      a.setFriends([Friend(id: 2, name: 'B', key: key, added: now)]);
      b.setFriends([Friend(id: 1, name: 'A', key: key, added: now)]);
      a.start();
      b.start();
      await settle();
      await a.sendPresence();
      await b.sendPresence();
      await settle();
      expect(b.isOnline(1), isTrue);
      expect(b.bestLink(1), TransportKind.lan);
      expect(b.friend(1)!.name, 'Alpha'); // learned from presence
      expect(hub.rooms[key.room], hasLength(2));

      // Different networks: no LAN, relay room still works.
      air.up = false;
      now = now.add(const Duration(seconds: 20));
      expect(b.isOnline(1), isFalse);
      await a.sendPresence();
      await b.sendPresence();
      await settle();
      expect(b.bestLink(1), TransportKind.internet);
      expect(a.bestLink(2), TransportKind.internet);

      final got = <FriendInbound>[];
      b.inbound.listen(got.add);
      await a.send(2, a.frame(FrameType.data, Uint8List.fromList([9, 9])));
      await settle();
      expect(got.single.frame.payload, [9, 9]);
      expect(got.single.via, TransportKind.internet);
      // A phone without the key learns nothing.
      final c = make(3, 'Charlie');
      expect(
        c.handle(
          InboundFrame(
            Frame.tryDecode(key.seal(a.frame(FrameType.data, Uint8List(1))))!,
            TransportKind.lan,
          ),
        ),
        isFalse,
      );
      await c.dispose();
    });

    test('QR pairing: the shower learns who scanned', () async {
      a.start();
      b.start();
      final code = PairKey.randomSecret();
      final k = PairKey.fromQrCode(code, 1);
      a.addPending(k);
      final paired = <(int, String, PairKey)>[];
      a.paired.listen(paired.add);
      // B scanned A's code.
      b.setFriends([
        Friend(
          id: 1,
          name: 'Alpha',
          key: PairKey.fromQrCode(code, 1),
          added: now,
        ),
      ]);
      await b.sendPresence();
      await settle();
      expect(paired.single.$1, 2);
      expect(paired.single.$2, 'Bravo');
      expect(paired.single.$3.encoded, k.encoded);
    });

    test('voice messages and chats between friends', () async {
      a.setFriends([Friend(id: 2, name: 'B', key: key, added: now)]);
      b.setFriends([Friend(id: 1, name: 'A', key: key, added: now)]);
      a.start();
      b.start();
      await a.sendPresence();
      await b.sendPresence();
      await settle();
      const scope = 0x40000;
      final ma = Messenger(
        link: FriendMessengerLink(a, scope),
        storage: MemoryMessageStorage(),
        clock: () => now,
      );
      final mb = Messenger(
        link: FriendMessengerLink(b, scope),
        storage: MemoryMessageStorage(),
        clock: () => now,
      );
      await ma.start();
      await mb.start();
      final chats = <ChatArrival>[];
      mb.chats.listen(chats.add);
      await ma.sendChat(ChatBody.text('hi there'), toPeer: 2, channel: scope);
      await ma.send(
        VoiceClip([for (var i = 0; i < 40; i++) Uint8List(60)]),
        toPeer: 2,
        channel: scope,
      );
      for (var i = 0; i < 40; i++) {
        now = now.add(const Duration(milliseconds: 50));
        await ma.tick();
        await mb.tick();
        await settle();
      }
      expect(chats.single.body.text, 'hi there');
      expect(chats.single.channel, scope);
      expect(mb.inbox.entries, hasLength(1));
      expect(ma.outbox.entries, isEmpty);
      await ma.dispose();
      await mb.dispose();
    });
  });

  group('chat over the channel messenger', () {
    test(
      'only phones with chat get it; Bluetooth gets the thumbnail',
      () async {
        final net = FakeNet();
        final a = net.add(1), b = net.add(2), old = net.add(3);
        a.chatPeers = {2};
        final clock = FakeClock();
        Messenger make(FakeNode n) => Messenger(
          link: n,
          storage: MemoryMessageStorage(),
          clock: clock.call,
        );
        final ma = make(a), mb = make(b), mo = make(old);
        for (final m in [ma, mb, mo]) {
          await m.start();
        }
        final got = <ChatArrival>[];
        final gotOld = <ChatArrival>[];
        mb.chats.listen(got.add);
        mo.chats.listen(gotOld.add);
        net.linkKind = TransportKind.ble;
        final full = ChatBody(
          type: ChatType.photo,
          data: Uint8List(5000),
          width: 100,
          height: 80,
        );
        final e = await ma.sendChat(
          full,
          channel: 1,
          bleBody: full.copyWith(data: Uint8List(300), thumbnailOnly: true),
        );
        expect(e.recipients, {2});
        expect(e.isChat, isTrue);
        for (var i = 0; i < 200 && got.isEmpty; i++) {
          clock.advance(const Duration(milliseconds: 50));
          for (final m in [ma, mb, mo]) {
            await m.tick();
          }
          await net.settle();
        }
        expect(got.single.body.thumbnailOnly, isTrue);
        expect(got.single.body.data, hasLength(300));
        expect(gotOld, isEmpty);
        expect(mb.inbox.entries, isEmpty); // chats are not voice messages
        expect(ma.outgoing, isEmpty); // not shown as queued voice messages
        // Outbox entries keep their kind across a restart.
        final j = OutboxEntry.fromJson(e.toJson())!;
        expect(j.isChat, isTrue);
        expect(j.hasBleBody, isTrue);
      },
    );
  });

  group('ChatBody / ChatStore', () {
    test('body round trip', () {
      final until = DateTime.fromMillisecondsSinceEpoch(1800000000000);
      final b = ChatBody(
        type: ChatType.location,
        lat: 45.5,
        lng: -122.6,
        accuracy: 12,
        liveUntil: until,
        liveId: 77,
      );
      final d = ChatBody.tryDecode(b.encode())!;
      expect(d.type, ChatType.location);
      expect(d.lat, 45.5);
      expect(d.liveUntil, until);
      expect(d.liveId, 77);
      expect(d.mapsUrl, contains('query=45.500000,-122.600000'));
      final t = ChatBody.tryDecode(ChatBody.text('héllo 👋').encode())!;
      expect(t.text, 'héllo 👋');
      // A voice clip is not a chat.
      expect(ChatBody.tryDecode(VoiceClip([Uint8List(10)]).encode()), isNull);
    });

    test(
      'store: dedupe, live updates in place, unread, rename, reload',
      () async {
        final storage = MemoryMessageStorage();
        final s = ChatStore(storage, maxPerConversation: 3);
        final t0 = DateTime(2026, 10, 25, 12);
        ChatMessage msg(int id, {int? lid, DateTime? at, double lat = 1}) =>
            ChatMessage.fromBody(
              lid == null
                  ? ChatBody.text('m$id')
                  : ChatBody(
                      type: ChatType.location,
                      lat: lat,
                      lng: 2,
                      liveId: lid,
                    ),
              id: id,
              sender: 9,
              senderName: 'N',
              mine: false,
              at: at ?? t0,
            );
        expect(await s.add('c1', msg(1)), isTrue);
        expect(await s.add('c1', msg(1)), isFalse);
        expect(s.unread('c1'), 1);
        await s.add(
          'c1',
          msg(2, lid: 5, at: t0.add(const Duration(seconds: 1))),
        );
        await s.add(
          'c1',
          msg(3, lid: 5, at: t0.add(const Duration(seconds: 31)), lat: 3),
        );
        expect(s.messages('c1'), hasLength(2));
        expect(s.messages('c1').last.lat, 3);
        expect(s.unread('c1'), 2);
        await s.add('c1', msg(4));
        await s.add('c1', msg(5));
        expect(s.messages('c1'), hasLength(3)); // capped
        await s.rename('c1', 'c2');
        expect(s.messages('c1'), isEmpty);
        expect(s.unread('c2'), 4);
        await s.markRead('c2');
        final s2 = ChatStore(storage);
        await Future<void>.delayed(Duration.zero);
        await s2.load();
        expect(s2.messages('c2'), hasLength(3));
        expect(s2.unread('c2'), 0);
        expect(s2.contains(9, 5), isTrue);
      },
    );

    test('photos are compressed to at most 150 KB with a thumbnail', () {
      final r = Random(1);
      final im = img.Image(width: 2400, height: 1600);
      for (final p in im) {
        p
          ..r = r.nextInt(256)
          ..g = r.nextInt(256)
          ..b = r.nextInt(256);
      }
      final p = preparePhotoSync(img.encodeJpg(im, quality: 95))!;
      expect(p.jpeg.length, lessThanOrEqualTo(maxPhotoBytes));
      expect(p.thumbnail.length, lessThan(20000));
      expect(p.width, greaterThan(p.height));
      expect(preparePhotoSync(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  test('settings: friends and social settings survive a save', () {
    final k = PairKey(PairKey.randomSecret());
    final f = Friend(id: 5, name: 'Pal', key: k, added: DateTime(2026));
    final back = Friend.decodeList(Friend.encodeList([f]));
    expect(back.single.key.encoded, k.encoded);
    final s = AppSettings(
      nodeId: 1,
      channel: 1,
      channelNames: {3: const ChannelName('Family', '🔥', 10)},
      channelAdmins: {0x10005: 1},
      announceScopes: {0x10005},
      muted: {7},
      blocked: {8: 'Spammer'},
    );
    final names = <int, ChannelName>{};
    final admins = <int, int>{};
    final ann = <int>{}, muted = <int>{};
    final blocked = <int, String>{};
    AppSettings.decodeSocial(
      AppSettings.encodeSocial(s),
      names: names,
      admins: admins,
      announce: ann,
      muted: muted,
      blocked: blocked,
    );
    expect(names[3]!.name, 'Family');
    expect(admins[0x10005], 1);
    expect(ann, {0x10005});
    expect(muted, {7});
    expect(blocked[8], 'Spammer');
  });
}
