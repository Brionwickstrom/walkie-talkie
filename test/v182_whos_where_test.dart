// v1.8.2 "Who's where": lobby beacon codec, privacy, grouping, rate
// limits, power save.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/power_plan.dart';
import 'package:walkie_talkie/app/whos_where.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/lobby.dart';
import 'package:walkie_talkie/core/mesh.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';

import 'fake_transport.dart';

class SlowFake extends FakeTransport {
  SlowFake() : super(TransportKind.lora);
  @override
  bool get lowBandwidth => true;
}

Future<ChannelKey> key(int ch, String pass) =>
    ChannelKey.deriveInline(ch, pass, iterations: 1000);

bool _contains(List<int> hay, List<int> needle) {
  if (needle.isEmpty) return false;
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

InboundLobby lobbyMsg(
  int id,
  LobbyBeacon b, {
  TransportKind via = TransportKind.lan,
  int hops = 1,
}) => InboundLobby(id, b, via, hops: hops);

void main() {
  group('lobby beacon codec', () {
    test('public beacon round trips with channel name and emoji', () {
      final b = LobbyBeacon.public(
        name: 'Bandit',
        channel: 3,
        channelName: 'Family',
        channelEmoji: '🔥',
        every: const Duration(seconds: 10),
      );
      final bytes = b.encode(senderId: 0xABCD1234, seq: 7);
      expect(bytes.length, lessThan(80), reason: 'fits one BLE packet');
      final f = Frame.tryDecode(bytes)!;
      expect(f.type, FrameType.lobby);
      expect(f.senderId, 0xABCD1234);
      expect(f.channel, 0, reason: 'header never carries a channel');
      final d = LobbyBeacon.tryDecode(f)!;
      expect(d.isPrivate, isFalse);
      expect(d.channel, 3);
      expect(d.name, 'Bandit');
      expect(d.channelName, 'Family');
      expect(d.channelEmoji, '🔥');
      expect(d.feature, featureLevel);
      expect(d.every, const Duration(seconds: 10));
    });

    test('private beacon round trips with only the call sign', () {
      final b = LobbyBeacon.private(callSign: 'Night Owl');
      final d = LobbyBeacon.tryDecode(
        Frame.tryDecode(b.encode(senderId: 5, seq: 1))!,
      )!;
      expect(d.isPrivate, isTrue);
      expect(d.channel, isNull);
      expect(d.channelName, isNull);
      expect(d.channelEmoji, isNull);
      expect(d.name, 'Night Owl');
    });

    test('long names are clipped on a character boundary', () {
      final b = LobbyBeacon.public(
        name: 'Captain 🚀🚀🚀🚀🚀🚀🚀🚀🚀 Crunchwrap Supreme',
        channel: 9,
        channelName: 'x' * 80,
        channelEmoji: '🔥🔥🔥🔥🔥',
      );
      expect(utf8.encode(b.name).length, lessThanOrEqualTo(24));
      expect(utf8.encode(b.channelName!).length, 30);
      expect(utf8.encode(b.channelEmoji!).length, lessThanOrEqualTo(8));
      final d = LobbyBeacon.tryDecodePayload(b.encodePayload())!;
      expect(d.name, b.name);
      expect(d.name.contains('\uFFFD'), isFalse);
    });

    test('malformed payloads are rejected', () {
      final good = LobbyBeacon.public(name: 'A', channel: 2).encodePayload();
      expect(LobbyBeacon.tryDecodePayload(Uint8List(0)), isNull);
      expect(LobbyBeacon.tryDecodePayload(good.sublist(0, 5)), isNull);
      final badVer = Uint8List.fromList(good)..[0] = 9;
      expect(LobbyBeacon.tryDecodePayload(badVer), isNull);
      final longLen = Uint8List.fromList(good)..[6] = 200;
      expect(LobbyBeacon.tryDecodePayload(longLen), isNull);
      // Public with channel 0 makes no sense.
      final zero = Uint8List.fromList(good)
        ..[2] = 0
        ..[3] = 0;
      expect(LobbyBeacon.tryDecodePayload(zero), isNull);
      // Other frame types are not lobby beacons.
      expect(
        LobbyBeacon.tryDecode(
          Frame(
            type: FrameType.control,
            senderId: 1,
            channel: 1,
            seq: 1,
            payload: good,
          ),
        ),
        isNull,
      );
    });

    test('older phones (unknown type 7) are not confused: v1.8.2 only', () {
      expect(FrameType.fromCode(7), FrameType.lobby);
      expect(featureLevel, greaterThanOrEqualTo(lobbyFeature));
    });
  });

  group('privacy', () {
    test('private beacon carries no channel, name, emoji or tag', () async {
      final k = await key(7, 'secret pass');
      final b = LobbyBeacon.private(callSign: 'Iceberg');
      final p = b.encodePayload();
      expect(p[2], 0);
      expect(p[3], 0);
      // name + two empty strings: nothing else after the call sign.
      expect(p.length, 6 + 1 + utf8.encode('Iceberg').length + 2);
      final wire = b.encode(senderId: 1, seq: 1);
      final tag = [(k.tag >> 8) & 0xFF, k.tag & 0xFF];
      expect(_contains(wire.sublist(Frame.headerSize), tag), isFalse);
      expect(_contains(wire, utf8.encode('secret')), isFalse);
    });

    test('a forged private beacon with channel bytes reveals nothing', () {
      final forged = LobbyBeacon.public(
        name: 'Spy',
        channel: 7,
        channelName: 'Secret Club',
        channelEmoji: '🕵️',
      ).encodePayload();
      forged[1] = 1; // private flag, channel bytes left in
      final d = LobbyBeacon.tryDecodePayload(forged)!;
      expect(d.isPrivate, isTrue);
      expect(d.channel, isNull);
      expect(d.channelName, isNull);
      expect(d.channelEmoji, isNull);
      final groups = buildWhosWhere(
        myId: 1,
        myName: 'Me',
        myChannel: 1,
        myScope: 1,
        iAmPrivate: false,
        lobby: [
          LobbyEntry(9, d)..heard[TransportKind.internet] = DateTime(2026),
        ],
        now: DateTime(2026),
      );
      final priv = groups.singleWhere((g) => g.kind == WhoGroupKind.private);
      expect(priv.channel, isNull);
      expect(priv.title, isNot(contains('7')));
      expect(priv.name, isNull);
      expect(groups.any((g) => g.channel == 7), isFalse);
    });

    test('on a private channel the manager sends lobby plain, hello sealed, '
        'and lobby frames never add people', () async {
      final lan = FakeTransport(TransportKind.lan);
      final net = FakeTransport(TransportKind.internet);
      final m = TransportManager(
        transports: [lan, net],
        localNodeId: 1,
        localName: 'Me',
        channel: 7,
        channelKey: await key(7, 'pw'),
      );
      await m.start();
      lan.sent.clear();
      net.sent.clear();
      await m.sendLobbyLocal(
        LobbyBeacon.private(callSign: 'Iceberg').encode(senderId: 1, seq: 1),
      );
      expect(lan.sent.single.frame.type, FrameType.lobby);
      expect(net.sent, isEmpty, reason: 'lobby room is separate');
      await m.sendHello();
      expect(
        lan.sent.where((s) => s.frame.type == FrameType.control),
        isEmpty,
        reason: 'presence on a private channel stays sealed',
      );
      final got = <InboundLobby>[];
      m.lobby.listen(got.add);
      lan.deliver(
        Frame.tryDecode(
          LobbyBeacon.public(name: 'B', channel: 2).encode(senderId: 2, seq: 1),
        )!,
      );
      await Future<void>.delayed(Duration.zero);
      expect(got.single.beacon.channel, 2, reason: 'heard while private');
      expect(m.peers, isEmpty, reason: 'not added to the people list');
      await m.dispose();
    });

    test('my own private channel is shown only to me; others are Private', () {
      const myScope = TransportManager.privateScopeBit | 0x1a2b;
      final now = DateTime(2026);
      final groups = buildWhosWhere(
        myId: 1,
        myName: 'Me',
        myChannel: 7,
        myScope: myScope,
        iAmPrivate: true,
        seen: const [
          WhoSeen(
            id: 2,
            name: 'Mate',
            scope: myScope,
            links: {TransportKind.lan},
          ),
        ],
        lobby: [
          // Mate's own lobby beacon says only "private".
          LobbyEntry(2, LobbyBeacon.private(callSign: 'Bandit'))
            ..heard[TransportKind.lan] = now,
          LobbyEntry(3, LobbyBeacon.private(callSign: 'Viper'))
            ..heard[TransportKind.internet] = now,
        ],
        now: now,
      );
      final mine = groups.first;
      expect(mine.kind, WhoGroupKind.mine);
      expect(mine.isPrivate, isTrue);
      expect(mine.people.map((p) => p.id), [1, 2]);
      final priv = groups.singleWhere((g) => g.kind == WhoGroupKind.private);
      expect(priv.people.single.name, 'Viper');
      expect(priv.canJump, isFalse);
    });

    test(
      '"Show me" off: no beacons, and hidden phones stay off the list',
      () async {
        final sent = <Uint8List>[];
        final w = WhosWhere(
          localId: 1,
          sendLocal: (b) async => sent.add(b),
          beacon: (_) => null,
        );
        await w.start();
        await w.tick();
        w.announceSoon();
        expect(sent, isEmpty);
        final groups = buildWhosWhere(
          myId: 1,
          myName: 'Me',
          myChannel: 1,
          myScope: 1,
          iAmPrivate: false,
          seen: const [
            WhoSeen(id: 2, name: 'Hidden', scope: 4, info: {'hw': 0}),
            WhoSeen(id: 3, name: 'HereHidden', scope: 1, info: {'hw': 0}),
          ],
          now: DateTime(2026),
        );
        expect(groups.length, 1, reason: 'no CH 4 group');
        expect(groups.first.people.map((p) => p.name), contains('HereHidden'));
        await w.stop();
      },
    );
  });

  group('grouping', () {
    test('groups by channel, names, friends first, counts', () {
      final now = DateTime(2026, 10, 26, 9);
      final groups = buildWhosWhere(
        myId: 1,
        myName: 'Me',
        myChannel: 1,
        myScope: 1,
        iAmPrivate: false,
        myChannelName: 'Base',
        myChannelEmoji: '🏕️',
        seen: const [
          WhoSeen(id: 2, name: 'Zulu', scope: 1, links: {TransportKind.ble}),
          // Pre-1.8.2 phone nearby on CH 3 (plain hello, no lobby).
          WhoSeen(
            id: 3,
            name: 'Oldie',
            scope: 3,
            links: {TransportKind.lan},
            info: {'cn': 'Hunters', 'ce': '🦌'},
          ),
          WhoSeen(id: 4, name: 'Far', scope: 3, hops: 2),
        ],
        lobby: [
          LobbyEntry(5, LobbyBeacon.public(name: 'Alpha', channel: 3))
            ..heard[TransportKind.internet] = now,
          LobbyEntry(6, LobbyBeacon.public(name: 'Bravo', channel: 12))
            ..heard[TransportKind.internet] = now,
          LobbyEntry(7, LobbyBeacon.private(callSign: 'Maverick'))
            ..heard[TransportKind.ble] = now,
          // Duplicate of a seen peer: merged, not listed twice.
          LobbyEntry(3, LobbyBeacon.public(name: 'Oldie', channel: 3))
            ..heard[TransportKind.internet] = now,
          // Expired.
          LobbyEntry(8, LobbyBeacon.public(name: 'Gone', channel: 5))
            ..heard[TransportKind.lan] = now.subtract(
              const Duration(minutes: 5),
            ),
        ],
        friends: {7: 'Mom', 6: 'Dad', 9: 'Uncle'},
        onlineFriends: {9},
        knownNames: {12: (name: 'Fishing', emoji: '🎣')},
        now: now,
      );
      expect(groups.map((g) => (g.kind, g.channel)).toList(), [
        (WhoGroupKind.mine, 1),
        (WhoGroupKind.public, 3),
        (WhoGroupKind.public, 12),
        (WhoGroupKind.private, null),
        (WhoGroupKind.friends, null),
      ]);
      final ch3 = groups[1];
      expect(ch3.title, '🦌 Hunters · CH 3');
      expect(ch3.people.map((p) => p.name), ['Alpha', 'Far', 'Oldie']);
      final oldie = ch3.people.firstWhere((p) => p.id == 3);
      expect(oldie.links, {TransportKind.lan, TransportKind.internet});
      expect(oldie.known, isTrue);
      expect(ch3.people.firstWhere((p) => p.id == 4).hops, 2);
      expect(ch3.canJump, isTrue);
      expect(groups[2].name, 'Fishing');
      expect(groups[2].people.single.name, 'Dad');
      expect(groups[2].people.single.friend, isTrue);
      expect(groups[3].people.single.name, 'Mom', reason: 'friend name');
      expect(groups[4].people.single.name, 'Uncle');
      expect(groups.first.people.first.me, isTrue);
      expect(whosWhereElsewhere(groups), 6);
      expect(whosWhereTotal(groups), 7);
      expect(groups.any((g) => g.channel == 5), isFalse);
    });

    test('public beacon on my number while I am private is a public group', () {
      final now = DateTime(2026);
      final groups = buildWhosWhere(
        myId: 1,
        myName: 'Me',
        myChannel: 4,
        myScope: TransportManager.privateScopeBit | 9,
        iAmPrivate: true,
        lobby: [
          LobbyEntry(2, LobbyBeacon.public(name: 'Pub', channel: 4))
            ..heard[TransportKind.lan] = now,
        ],
        now: now,
      );
      expect(groups[1].kind, WhoGroupKind.public);
      expect(groups[1].channel, 4);
      expect(groups[0].count, 0);
    });
  });

  group('WhosWhere service', () {
    test('rate limit: per sender per path and a global bucket', () {
      var now = DateTime(2026);
      final l = LobbyLimiter(
        perSecond: 5,
        burst: 5,
        perSender: const Duration(seconds: 2),
        clock: () => now,
      );
      expect(l.allow(1, TransportKind.lan), isTrue);
      expect(l.allow(1, TransportKind.lan), isFalse);
      expect(l.allow(1, TransportKind.ble), isTrue, reason: 'other path');
      for (var i = 2; i < 5; i++) {
        expect(l.allow(i, TransportKind.lan), isTrue);
      }
      expect(l.allow(99, TransportKind.lan), isFalse, reason: 'bucket empty');
      now = now.add(const Duration(seconds: 2));
      expect(l.allow(1, TransportKind.lan), isTrue);
      expect(l.dropped, 2);
    });

    test('entries expire, are capped and updates notify', () async {
      var now = DateTime(2026);
      final w = WhosWhere(
        localId: 1,
        sendLocal: (_) async {},
        beacon: (_) => null,
        clock: () => now,
        limiter: LobbyLimiter(perSecond: 10000, burst: 10000, clock: () => now),
      );
      var notes = 0;
      w.addListener(() => notes++);
      w.onLobby(lobbyMsg(1, LobbyBeacon.public(name: 'me', channel: 1)));
      expect(w.entries, isEmpty, reason: 'own echo');
      w.onLobby(lobbyMsg(2, LobbyBeacon.public(name: 'B', channel: 2)));
      w.onLobby(lobbyMsg(3, LobbyBeacon.private(callSign: 'C')));
      w.onLobby(
        lobbyMsg(
          4,
          LobbyBeacon.public(name: 'D', channel: 2),
          via: TransportKind.ble,
          hops: 3,
        ),
      );
      w.onLobby(
        lobbyMsg(
          5,
          LobbyBeacon.public(name: 'E', channel: 2),
          via: TransportKind.lora,
        ),
      );
      // v1.8.3: the rare LoRa copy counts too (5).
      expect(w.entries.map((e) => e.id).toSet(), {2, 3, 4, 5});
      expect(w.entries.firstWhere((e) => e.id == 4).liveHops(now), 3);
      expect(notes, 4);
      now = now.add(const Duration(seconds: 31));
      w.prune();
      // The radio copy lives 3 x 15 min (v1.8.3).
      expect(w.entries.map((e) => e.id), [5], reason: '3 x 10 s');
      now = now.add(const Duration(minutes: 46));
      w.prune();
      expect(w.entries, isEmpty);
      for (var i = 0; i < WhosWhere.maxEntries + 20; i++) {
        now = now.add(const Duration(milliseconds: 1));
        w.onLobby(lobbyMsg(100 + i, LobbyBeacon.public(name: 'x', channel: 1)));
      }
      expect(w.entries.length, WhosWhere.maxEntries);
      expect(w.entries.any((e) => e.id == 100), isFalse, reason: 'oldest out');
    });

    test(
      'beacon rate follows the power plan; offline has no relay lobby',
      () async {
        var now = DateTime(2026);
        final sent = <Uint8List>[];
        final opened = <FakeTransport>[];
        final every = <Duration>[];
        final w = WhosWhere(
          localId: 1,
          sendLocal: (b) async => sent.add(b),
          beacon: (e) {
            every.add(e);
            return LobbyBeacon.public(name: 'Me', channel: 1, every: e);
          },
          relayFactory: () {
            final t = FakeTransport(TransportKind.internet);
            opened.add(t);
            return t;
          },
          clock: () => now,
        );
        await w.start();
        expect(w.relayOpen, isTrue);
        expect(opened.single.sent.single.frame.type, FrameType.lobby);
        Future<void> run(Duration d) async {
          final end = now.add(d);
          while (now.isBefore(end)) {
            now = now.add(const Duration(seconds: 1));
            await w.tick();
          }
        }

        sent.clear();
        opened.single.sent.clear();
        await run(const Duration(seconds: 60));
        expect(sent.length, 6, reason: 'every 10 s nearby');
        expect(opened.single.sent.length, 2, reason: 'every 30 s online');

        await w.setPlan(const PowerPlan(saver: true));
        sent.clear();
        await run(const Duration(seconds: 60));
        expect(sent.length, 3, reason: 'every 20 s in battery saver');
        await w.setForeground(false);
        expect(
          w.relayOpen,
          isFalse,
          reason: 'saver: lobby room only on screen',
        );
        await w.setForeground(true);
        expect(w.relayOpen, isTrue);

        await w.setPlan(const PowerPlan(offline: true));
        expect(w.relayOpen, isFalse, reason: 'offline power save: no relay');
        expect(opened.last.status, TransportStatus.stopped);
        sent.clear();
        every.clear();
        await run(const Duration(seconds: 120));
        expect(sent.length, 2, reason: 'every 60 s offline');
        expect(every.every((e) => e == const Duration(seconds: 60)), isTrue);
        final d = LobbyBeacon.tryDecode(Frame.tryDecode(sent.last)!)!;
        expect(d.every, const Duration(seconds: 60), reason: 'expiry hint');

        // Channel switch: announced within about a second.
        sent.clear();
        w.announceSoon();
        await run(const Duration(seconds: 1));
        expect(sent.length, 1);
        await w.stop();
      },
    );

    test('relay lobby room: only lobby frames are read', () async {
      final relay = FakeTransport(TransportKind.internet);
      final w = WhosWhere(
        localId: 1,
        sendLocal: (_) async {},
        beacon: (_) => null,
        relayFactory: () => relay,
      );
      await w.start();
      relay.deliver(
        Frame.tryDecode(
          LobbyBeacon.public(
            name: 'Net',
            channel: 6,
          ).encode(senderId: 2, seq: 1),
        )!,
      );
      relay.deliver(
        Frame.control(
          senderId: 3,
          channel: 6,
          seq: 1,
          message: const ControlMessage(ControlKind.hello, name: 'X'),
        ),
      );
      expect(w.entries.single.id, 2);
      expect(w.entries.single.heard.keys, [TransportKind.internet]);
      await w.stop();
    });

    test('never over LoRa; the mesh passes lobby on, rate limited', () async {
      final lan = FakeTransport(TransportKind.lan);
      final ble = FakeTransport(TransportKind.ble);
      final lora = SlowFake();
      final m = TransportManager(
        transports: [lan, ble, lora],
        localNodeId: 1,
        localName: 'Me',
      );
      await m.start();
      lora.sent.clear();
      lan.sent.clear();
      await m.sendLobbyLocal(
        LobbyBeacon.public(name: 'Me', channel: 1).encode(senderId: 1, seq: 1),
      );
      expect(lan.sent.length, 1);
      expect(lora.sent, isEmpty);
      expect(
        m.radioAllowed(
          Frame.tryDecode(
            LobbyBeacon.public(
              name: 'Me',
              channel: 1,
            ).encode(senderId: 1, seq: 2),
          )!,
        ),
        isFalse,
      );
      // v1.8.3: inbound over LoRa is accepted (the rare radio copy; it
      // only goes out through sendLobbyRadio, never the generic path).
      final got = <InboundLobby>[];
      m.lobby.listen(got.add);
      lora.deliver(
        Frame.tryDecode(
          LobbyBeacon.public(name: 'R', channel: 2).encode(senderId: 9, seq: 1),
        )!,
      );
      await Future<void>.delayed(Duration.zero);
      expect(got.single.transport, TransportKind.lora);
      await m.dispose();

      // Mesh: a relay passes one lobby beacon per origin per 8 s.
      var now = DateTime(2026);
      final r = MeshRouter(localId: 10, clock: () => now);
      // Neighbours 20 (source side) and 30 (far side, mesh capable).
      Frame beaconFrom(int id) =>
          Frame.tryDecode(MeshBeacon.encode(id, 1, {10}))!;
      r.onFrame(beaconFrom(30), TransportKind.ble);
      Frame lob(int seq) => Frame.tryDecode(
        LobbyBeacon.public(
          name: 'S',
          channel: 2,
        ).encode(senderId: 20, seq: seq),
      )!;
      expect(r.onFrame(lob(1), TransportKind.lan).relay, isNotNull);
      now = now.add(const Duration(seconds: 2));
      r.onFrame(beaconFrom(30), TransportKind.ble);
      expect(r.onFrame(lob(2), TransportKind.lan).relay, isNull);
      now = now.add(const Duration(seconds: 7));
      r.onFrame(beaconFrom(30), TransportKind.ble);
      expect(r.onFrame(lob(3), TransportKind.lan).relay, isNotNull);
    });
  });

  group('power plan', () {
    test('lobby intervals and relay per mode', () {
      const n = PowerPlan();
      const s = PowerPlan(saver: true);
      const o = PowerPlan(offline: true);
      expect(n.lobbyLocalInterval, const Duration(seconds: 10));
      expect(s.lobbyLocalInterval, const Duration(seconds: 20));
      expect(o.lobbyLocalInterval, const Duration(seconds: 60));
      expect(n.lobbyRelay, isTrue);
      expect(o.lobbyRelay, isFalse);
      expect(n.lobbyRelayInBackground, isTrue);
      expect(s.lobbyRelayInBackground, isFalse);
      expect(n.lobbyRelayInterval, const Duration(seconds: 30));
      expect(s.lobbyRelayInterval, const Duration(seconds: 60));
    });
  });
}
