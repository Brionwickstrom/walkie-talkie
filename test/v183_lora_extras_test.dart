import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/whos_where.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/chat/chat_store.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/lobby.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';
import 'package:walkie_talkie/messaging/voice_transfer.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_route.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';

import 'messaging_fakes.dart';
import 'trip_integration_test.dart' show FakeHost;
import 'v183_friend_radio_test.dart' show AirRadio, settle;

const alice = 0x1111, bob = 0x2222;
const here = GeoPoint(45.5, -122.6);

/// A phone with only a LoRa radio: the manager, plus a trip host on it.
class RadioPhone {
  RadioPhone(this.id, this.radio, this.clock) {
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
  }
  final int id;
  final AirRadio radio;
  final FakeClock clock;
  late final LoraTransport lora;
  late final TransportManager m;
}

/// Trip host on a real TransportManager (as the app's _WalkieTripHost).
class ManagerHost extends FakeHost {
  ManagerHost(this.m, this.fix) : super(m.localNodeId);
  final TransportManager m;
  Fix? fix;
  @override
  Future<Set<int>> sendTrip(Uint8List payload, TripRoute r) {
    sent.add((msg: TripMsg.tryDecode(payload)!, route: r));
    return m.sendTrip(
      payload,
      to: r.to,
      fast: r.fast,
      radio: r.radio,
      flood: r.flood,
    );
  }

  @override
  Stream<InboundTrip> get trips => m.trips;
  @override
  Future<Fix?> locateOnce() async => fix;
}

void main() {
  late FakeClock clock;
  late RadioPhone a, b;
  late Directory dir;

  setUp(() async {
    clock = FakeClock();
    dir = await Directory.systemTemp.createTemp('v183');
    final ra = AirRadio(0xA1), rb = AirRadio(0xB1);
    ra.other = rb;
    rb.other = ra;
    a = RadioPhone(alice, ra, clock);
    b = RadioPhone(bob, rb, clock);
    await a.m.start();
    await b.m.start();
    await a.m.sendRadioHello();
    await b.m.sendRadioHello();
    await settle();
    ra.sent.clear();
    rb.sent.clear();
  });

  tearDown(() async {
    await a.m.dispose();
    await b.m.dispose();
    await dir.delete(recursive: true);
  });

  Future<TripController> trip(RadioPhone p, {Fix? fix}) async {
    final t = TripController(
      host: ManagerHost(p.m, fix),
      settings: TripSettings(),
      dir: Directory('${dir.path}/${p.id}'),
      userAgent: 'test',
      clock: clock.call,
    );
    t.tiles.online = false;
    await t.start();
    return t;
  }

  group('check-ins and lost contact over LoRa only', () {
    test('a check-in crosses the radio, clears and re-arms lost contact, '
        'and carries the battery', () async {
      final ta = await trip(a, fix: Fix(here, clock.now, accuracyM: 8));
      final tb = await trip(b);
      ta.battery = () => 64;
      await tb.update((s) {
        s.tripMode = true;
        s.lostContactMinutes = 20;
      });
      expect(await ta.checkInNow(), isTrue);
      await settle();
      final sent = a.radio.sent.map((s) => s.$1).toList();
      expect(sent, hasLength(1));
      expect(sent.single.length, lessThanOrEqualTo(40)); // tiny
      expect(Frame.tryDecode(sent.single)!.type, FrameType.trip);
      expect(tb.people[alice]!.pos.lat, closeTo(here.lat, 1e-4));
      expect(tb.people[alice]!.via, TransportKind.lora);
      expect(tb.batteries[alice]!.pct, 64);

      // 20 min of radio silence: lost contact (with the last position).
      for (var i = 0; i < 20 * 60 + 10; i++) {
        clock.advance(const Duration(seconds: 1));
        tb.tick();
      }
      expect(tb.lost.lost.single.id, alice);
      expect(tb.lost.lost.single.lastPos, isNotNull);
      // The next check-in over the radio clears it.
      // Radio presence hellos (every 5 min in the app) keep the phones
      // known to each other's radio layer.
      await a.m.sendRadioHello();
      await b.m.sendRadioHello();
      await settle();
      (ta.host as ManagerHost).fix = Fix(here, clock.now);
      await ta.checkInNow();
      await settle();
      expect(tb.lost.lost, isEmpty);
      ta.dispose();
      tb.dispose();
    });

    test('battery byte: old decoders ignore it, new ones read it', () {
      final m = PosMsg(7, here, checkIn: true, accuracyM: 5, battery: 12);
      final bytes = m.encode();
      expect(
        bytes.length,
        PosMsg(7, here, checkIn: true, accuracyM: 5).encode().length + 1,
      );
      final back = TripMsg.tryDecode(bytes) as PosMsg;
      expect(back.battery, 12);
      expect(back.checkIn, isTrue);
      // Without the flag no battery is read.
      final none = TripMsg.tryDecode(PosMsg(8, here).encode()) as PosMsg;
      expect(none.battery, isNull);
    });
  });

  group('map pins over LoRa', () {
    test('camp / water / meet-up / custom label: one small packet each, '
        'shown on the far phone', () async {
      final ta = await trip(a);
      final tb = await trip(b);
      await ta.addPin(PinType.camp, here);
      await ta.addPin(PinType.water, const GeoPoint(45.51, -122.61));
      await ta.addPin(PinType.meetup, const GeoPoint(45.52, -122.62));
      await ta.addPin(
        PinType.custom,
        const GeoPoint(45.53, -122.63),
        label: 'Big rock',
      );
      await settle();
      final sizes = [for (final s in a.radio.sent) s.$1.length];
      expect(sizes, hasLength(4));
      expect(sizes.every((n) => n <= 60), isTrue);
      expect(tb.pins.map((p) => p.type), [
        PinType.camp,
        PinType.water,
        PinType.meetup,
        PinType.custom,
      ]);
      expect(tb.pins.last.label, 'Big rock');
      expect(
        PinMsg(
          1,
          pinId: 2,
          type: PinType.custom,
          pos: here,
          label: 'x' * 99,
        ).encode().length,
        lessThanOrEqualTo(3 + 2 + 1 + 8 + 1 + PinMsg.maxLabel),
      );
      ta.dispose();
      tb.dispose();
    });
  });

  group('read receipts', () {
    late FakeNet net;
    Messenger make(int id) {
      final node = net.add(id);
      final m = Messenger(
        link: node,
        storage: MemoryMessageStorage(),
        clock: clock.call,
        random: Random(id),
      );
      node.data.listen(m.onData);
      return m;
    }

    Future<void> run(List<Messenger> ms, Duration total) async {
      for (var i = 0; i < total.inMilliseconds ~/ 500; i++) {
        clock.advance(const Duration(milliseconds: 500));
        for (final m in ms) {
          await m.tick();
        }
        await net.settle();
      }
    }

    setUp(() => net = FakeNet());

    test('batched into one tiny packet, decoded by the sender', () async {
      final x = make(1), y = make(2);
      final read = <(int, int)>[];
      x.read.listen(read.add);
      final sizes = <int>[];
      net.drop = (from, to, p) {
        if (DataPacket.tryDecode(p) is ReadPacket) sizes.add(p.length);
        return false;
      };
      y.markRead(1, 101);
      y.markRead(1, 102);
      y.markRead(1, 103);
      y.markRead(1, 101); // once only
      await run([x, y], const Duration(seconds: 3));
      expect(read, [(101, 2), (102, 2), (103, 2)]);
      expect(sizes, [10 + 3 * 4]); // one packet
      expect(y.readPacketsSent, 1);
    });

    test('over the radio they wait longer to batch more', () async {
      net.linkKind = TransportKind.lora;
      final x = make(1), y = make(2);
      final read = <(int, int)>[];
      x.read.listen(read.add);
      y.markRead(1, 5);
      await run([x, y], const Duration(seconds: 5));
      expect(read, isEmpty);
      for (var i = 6; i < 13; i++) {
        y.markRead(1, i); // 8 ids: a full batch goes at once
      }
      await run([x, y], const Duration(seconds: 1));
      expect(read.length, 8);
      expect(y.readPacketsSent, 1);
    });

    test('unreachable: kept until the sender is back', () async {
      final x = make(1), y = make(2);
      final read = <(int, int)>[];
      x.read.listen(read.add);
      net.allConnected = false;
      y.markRead(1, 9);
      await run([x, y], const Duration(seconds: 5));
      expect(read, isEmpty);
      net.allConnected = true;
      await run([x, y], const Duration(seconds: 3));
      expect(read, [(9, 2)]);
    });

    test('voice: chat + voice end to end, chat store shows "seen"', () async {
      final x = make(1), y = make(2);
      await x.outbox.load();
      await y.outbox.load();
      final e = await x.sendChat(ChatBody.text('hi'), toPeer: 2, channel: 1);
      final v = await x.send(
        VoiceClip([Uint8List(20), Uint8List(20)]),
        toPeer: 2,
        channel: 1,
      );
      await run([x, y], const Duration(seconds: 3));
      final store = ChatStore(MemoryMessageStorage());
      await store.load();
      await store.add(
        'c1',
        ChatMessage.fromBody(
          ChatBody.text('hi'),
          id: e.msgId,
          sender: 1,
          senderName: 'X',
          mine: true,
          at: clock.now,
        ),
      );
      final seen = <int>[];
      x.read.listen((r) async {
        if (!await store.markSeen(1, r.$1, r.$2)) seen.add(r.$1);
      });
      y.markRead(1, e.msgId);
      y.markRead(1, v.msgId);
      await run([x, y], const Duration(seconds: 3));
      final m = store.messages('c1').single;
      expect(m.seenBy, {2});
      expect(seen, [v.msgId]); // the voice message: not a chat
      // Persisted.
      expect(ChatMessage.fromJson(m.toJson())!.seenBy, {2});
    });

    test('received chats are receipted once', () async {
      final store = ChatStore(MemoryMessageStorage());
      await store.load();
      for (var i = 0; i < 3; i++) {
        await store.add(
          'c1',
          ChatMessage.fromBody(
            ChatBody.text('m$i'),
            id: i,
            sender: 9,
            senderName: 'N',
            mine: false,
            at: clock.now,
          ),
        );
      }
      expect((await store.takeUnreceipted('c1')).length, 3);
      expect(await store.takeUnreceipted('c1'), isEmpty);
    });
  });

  group('battery in presence', () {
    test('hellos and the radio hello carry it; peers keep it', () async {
      a.m.helloExtras = () => {'v': 18, 'bt': 42};
      await a.m.sendRadioHello();
      await settle();
      expect(b.m.peer(alice)!.battery, 42);
      final f = Frame.tryDecode(a.radio.sent.last.$1)!;
      expect(f.control!.x['bt'], 42);
    });

    test('lobby beacon battery byte round trip, old beacons have none', () {
      final p = LobbyBeacon.public(name: 'A', channel: 3, battery: 77);
      final back = LobbyBeacon.tryDecodePayload(p.encodePayload())!;
      expect(back.battery, 77);
      final old = LobbyBeacon.public(name: 'A', channel: 3);
      expect(
        LobbyBeacon.tryDecodePayload(old.encodePayload())!.battery,
        isNull,
      );
      final priv = LobbyBeacon.private(callSign: 'Fox 12', battery: 5);
      final pb = LobbyBeacon.tryDecodePayload(priv.encodePayload())!;
      expect(pb.battery, 5);
      expect(pb.channel, isNull);
    });

    test("Who's where shows it", () {
      final groups = buildWhosWhere(
        myId: alice,
        myName: 'A',
        myChannel: 1,
        myScope: 1,
        iAmPrivate: false,
        seen: [const WhoSeen(id: bob, name: 'B', scope: 1, battery: 33)],
        now: clock.now,
      );
      expect(groups.first.people.firstWhere((p) => p.id == bob).battery, 33);
    });
  });

  group("Who's where over LoRa", () {
    test('a rare compact lobby beacon reaches a radio-only phone', () async {
      final got = <InboundLobby>[];
      b.m.lobby.listen(got.add);
      final wa = WhosWhere(
        localId: alice,
        sendLocal: (_) async {},
        sendRadio: a.m.sendLobbyRadio,
        beacon: (every) =>
            LobbyBeacon.private(callSign: 'Fox 12', every: every, battery: 50),
        clock: clock.call,
      );
      final wb = WhosWhere(
        localId: bob,
        sendLocal: (_) async {},
        beacon: (_) => null,
        clock: clock.call,
      );
      b.m.lobby.listen(wb.onLobby);
      await wa.start();
      await wa.tick();
      await settle();
      expect(wa.sentRadio, 1);
      final pkt = a.radio.sent.single.$1;
      expect(pkt.length, lessThan(60));
      expect(got.single.transport, TransportKind.lora);
      expect(got.single.beacon.isPrivate, isTrue);
      expect(got.single.beacon.channel, isNull);
      final e = wb.entries.single;
      expect(e.beacon.battery, 50);
      // Ticks for 14 min: nothing more on the radio.
      for (var i = 0; i < 14 * 60; i++) {
        clock.advance(const Duration(seconds: 1));
        await wa.tick();
      }
      expect(wa.sentRadio, 1);
      clock.advance(const Duration(minutes: 1, seconds: 1));
      await wa.tick();
      await settle();
      expect(wa.sentRadio, 2);
      expect(got, hasLength(2));
      // The radio entry lives 45 min (3x 15 min).
      clock.advance(const Duration(minutes: 40));
      expect(wb.entries, hasLength(1));
      clock.advance(const Duration(minutes: 30));
      wb.prune();
      expect(wb.entries, isEmpty);
      wa.dispose();
      wb.dispose();
    });

    test('it goes at the lowest radio priority (bulk)', () async {
      expect(a.m.sendLobbyRadio(Uint8List(30)), isTrue);
      await settle();
      expect(a.radio.sent.single.$1.length, 30);
    });
  });

  group('trail summaries over LoRa', () {
    test('every N minutes while recording in trip mode, Off = never', () async {
      final ta = await trip(a, fix: Fix(here, clock.now));
      await ta.update((s) {
        s.tripMode = true;
        s.radioTrailMinutes = 5;
        s.checkInMinutes = 0;
      });
      ta.startTrack();
      for (var i = 0; i < 30; i++) {
        ta.recorder.add(
          GeoPoint(45.5 + i * 0.001, -122.6 + i * 0.0007),
          clock.now.add(Duration(seconds: i * 30)),
        );
      }
      ta.maybeSendRadioTrail();
      expect(ta.radioTrailsSent, 1);
      clock.advance(const Duration(minutes: 4));
      ta.maybeSendRadioTrail();
      expect(ta.radioTrailsSent, 1);
      clock.advance(const Duration(minutes: 1));
      ta.maybeSendRadioTrail();
      expect(ta.radioTrailsSent, 2);
      await settle();
      final trails = [
        for (final s in a.radio.sent)
          if (TripMsg.tryDecode(Frame.tryDecode(s.$1)!.payload)
              case final TrackMsg t)
            t,
      ];
      expect(trails, hasLength(2));
      expect(trails.every((t) => t.summary && t.points.length <= 16), isTrue);
      expect(
        a.radio.sent.every((s) => s.$1.length <= loraPayloadBudget),
        isTrue,
      );
      await ta.update((s) => s.radioTrailMinutes = 0);
      clock.advance(const Duration(minutes: 30));
      ta.maybeSendRadioTrail();
      expect(ta.radioTrailsSent, 2);
      ta.dispose();
    });

    test('setting round trip and bad values', () {
      final s = TripSettings(radioTrailMinutes: 10);
      expect(TripSettings.decode(s.encode()).radioTrailMinutes, 10);
      expect(TripSettings.decode('{"rtm":7}').radioTrailMinutes, 15);
      expect(TripSettings.decode('{}').radioTrailMinutes, 15);
    });
  });
}
