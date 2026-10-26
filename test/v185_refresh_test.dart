// v1.8.5 pull-to-refresh: "who's here?" probe codec, reply rate limit and
// jitter, the refresh flow (spinner settle / max wait, "Found N people"),
// the LoRa gating and the UI hooks.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/people_refresh.dart';
import 'package:walkie_talkie/app/whos_where.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/lobby.dart';
import 'package:walkie_talkie/core/mesh.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/whos_where_page.dart';

import 'fake_transport.dart';
import 'mesh_test.dart' show RangeAir, phone, introduce;
import 'messaging_fakes.dart' show FakeClock;
import 'v183_friend_radio_test.dart' show AirRadio, settle;
import 'v183_lora_extras_test.dart' show RadioPhone;

class KickFake extends FakeTransport {
  KickFake(super.kind);
  int kicks = 0;
  @override
  void kickDiscovery() => kicks++;
}

class SlowKick extends KickFake {
  SlowKick() : super(TransportKind.lora);
  @override
  bool get lowBandwidth => true;
}

Uint8List probeBytes(
  int from, {
  int nonce = 1,
  int ttl = 3,
  bool radio = false,
}) => LobbyProbe(
  nonce: nonce,
  ttl: ttl,
  radio: radio,
).encode(senderId: from, seq: 1);

InboundProbe probeFrom(
  int id, {
  TransportKind via = TransportKind.lan,
  int hops = 1,
}) => InboundProbe(id, LobbyProbe(nonce: 1), via, hops: hops);

/// A WhosWhere responder with captured delays and replies.
class Responder {
  Responder({FakeClock? clock, bool visible = true, Duration? jitter})
    : clock = clock ?? FakeClock() {
    w = WhosWhere(
      localId: 1,
      sendLocal: (b) async => local.add(b),
      sendRadio: (b) {
        radioBeacons.add(b);
        return true;
      },
      beacon: (every) => visible
          ? LobbyBeacon.public(name: 'Me', channel: 2, every: every)
          : null,
      clock: this.clock.call,
      replyJitter: jitter == null ? null : () => jitter,
      schedule: (d, run) {
        delays.add(d);
        pending.add(run);
      },
    );
    w.replyPresence = ({required bool radio}) async =>
        radio ? radioHellos++ : hellos++;
  }
  final FakeClock clock;
  late final WhosWhere w;
  final local = <Uint8List>[];
  final radioBeacons = <Uint8List>[];
  final delays = <Duration>[];
  final pending = <void Function()>[];
  int hellos = 0, radioHellos = 0;

  Future<void> start() async {
    await w.start();
    local.clear();
  }

  Future<void> runPending() async {
    final p = List.of(pending);
    pending.clear();
    for (final r in p) {
      r();
    }
    await settle();
  }
}

void main() {
  group('probe codec', () {
    test('round trips nonce, ttl and the radio flag in a tiny frame', () {
      final bytes = probeBytes(0xABCD1234, nonce: 0xBEEF, ttl: 2, radio: true);
      expect(bytes.length, Frame.headerSize + LobbyProbe.size);
      final f = Frame.tryDecode(bytes)!;
      expect(f.type, FrameType.lobby);
      expect(f.senderId, 0xABCD1234);
      expect(f.channel, 0);
      final p = LobbyProbe.tryDecode(f)!;
      expect(p.nonce, 0xBEEF);
      expect(p.ttl, 2);
      expect(p.radio, isTrue);
      expect(
        LobbyProbe.tryDecode(Frame.tryDecode(probeBytes(5))!)!.radio,
        isFalse,
      );
    });

    test('older phones ignore it: not a valid lobby beacon', () {
      final f = Frame.tryDecode(probeBytes(9))!;
      expect(LobbyBeacon.tryDecode(f), isNull);
      // And a beacon is never mistaken for a probe.
      final b = LobbyBeacon.public(
        name: 'A',
        channel: 3,
      ).encode(senderId: 2, seq: 1);
      expect(LobbyProbe.tryDecode(Frame.tryDecode(b)!), isNull);
      expect(LobbyBeacon.tryDecode(Frame.tryDecode(b)!), isNotNull);
    });

    test('malformed probes are rejected, ttl is clamped, extras ignored', () {
      final good = LobbyProbe(nonce: 7).encodePayload();
      expect(LobbyProbe.tryDecodePayload(Uint8List(0)), isNull);
      expect(LobbyProbe.tryDecodePayload(good.sublist(0, 5)), isNull);
      expect(
        LobbyProbe.tryDecodePayload(Uint8List.fromList(good)..[1] = 9),
        isNull,
      );
      expect(
        LobbyProbe.tryDecodePayload(Uint8List.fromList(good)..[3] = 0),
        isNull,
      );
      final longer = Uint8List.fromList([...good, 1, 2, 3]);
      expect(LobbyProbe.tryDecodePayload(longer)!.nonce, 7);
      expect(LobbyProbe(nonce: 1, ttl: 99).ttl, LobbyProbe.maxTtl);
      expect(LobbyProbe(nonce: 1, ttl: 0).ttl, 1);
      expect(LobbyProbe(nonce: 0x12345).encodePayload()[4], 0x23);
      // Other frame types are never probes.
      expect(
        LobbyProbe.tryDecode(
          Frame(
            type: FrameType.trip,
            senderId: 1,
            channel: 1,
            seq: 1,
            payload: good,
          ),
        ),
        isNull,
      );
    });
  });

  group('reply rate limit and jitter', () {
    test('ProbeReplyLimiter: once per 5 s per requester, bounded', () {
      final clock = FakeClock();
      final l = ProbeReplyLimiter(clock: clock.call, maxTracked: 4);
      expect(l.allow(7), isTrue);
      expect(l.allow(7), isFalse);
      expect(l.allow(8), isTrue, reason: 'other requesters are independent');
      clock.advance(const Duration(milliseconds: 4900));
      expect(l.allow(7), isFalse);
      clock.advance(const Duration(milliseconds: 100));
      expect(l.allow(7), isTrue);
      for (var i = 100; i < 120; i++) {
        l.allow(i);
      }
      expect(l.dropped, 2);
    });

    test(
      'a probe is answered with presence + lobby beacon after 0-500 ms',
      () async {
        final r = Responder();
        await r.start();
        for (var id = 10; id < 60; id++) {
          r.w.onProbe(probeFrom(id));
        }
        expect(r.delays, hasLength(50));
        for (final d in r.delays) {
          expect(d, greaterThanOrEqualTo(Duration.zero));
          expect(d, lessThanOrEqualTo(WhosWhere.maxReplyJitter));
        }
        expect(r.delays.toSet().length, greaterThan(1), reason: 'jittered');
        expect(r.hellos, 0, reason: 'nothing before the delay');
        await r.runPending();
        expect(r.hellos, 50);
        expect(r.local, hasLength(50));
        expect(
          LobbyBeacon.tryDecode(Frame.tryDecode(r.local.first)!)!.name,
          'Me',
        );
        expect(r.w.probeReplies, 50);
      },
    );

    test('the same requester is answered at most once per 5 s', () async {
      final r = Responder(jitter: Duration.zero);
      await r.start();
      r.w.onProbe(probeFrom(7));
      r.w.onProbe(probeFrom(7, via: TransportKind.ble));
      r.w.onProbe(probeFrom(7, hops: 3));
      await r.runPending();
      expect(r.hellos, 1);
      r.clock.advance(const Duration(seconds: 4));
      r.w.onProbe(probeFrom(7));
      await r.runPending();
      expect(r.hellos, 1);
      r.clock.advance(const Duration(seconds: 1));
      r.w.onProbe(probeFrom(7));
      await r.runPending();
      expect(r.hellos, 2);
    });

    test('our own probe, a stopped responder and hidden phones', () async {
      final r = Responder(jitter: Duration.zero);
      r.w.onProbe(probeFrom(7));
      expect(r.pending, isEmpty, reason: 'not running');
      await r.start();
      r.w.onProbe(probeFrom(1));
      expect(r.pending, isEmpty, reason: 'our own echo');
      final hidden = Responder(jitter: Duration.zero, visible: false);
      await hidden.start();
      hidden.w.onProbe(probeFrom(7));
      await hidden.runPending();
      expect(hidden.hellos, 1, reason: 'channel presence still answers');
      expect(
        hidden.local,
        isEmpty,
        reason: "no Who's where beacon when hidden",
      );
    });

    test(
      'a LoRa probe is answered over the radio at most every 2 min',
      () async {
        final r = Responder(jitter: Duration.zero);
        await r.start();
        r.radioBeacons.clear();
        r.w.onProbe(probeFrom(7, via: TransportKind.lora));
        r.w.onProbe(probeFrom(8, via: TransportKind.lora));
        await r.runPending();
        expect(r.radioHellos, 1);
        expect(r.radioBeacons, hasLength(1));
        expect(r.hellos, 0, reason: 'no fast-link reply to a radio probe');
        r.clock.advance(const Duration(seconds: 119));
        r.w.onProbe(probeFrom(9, via: TransportKind.lora));
        await r.runPending();
        expect(r.radioHellos, 1);
        r.clock.advance(const Duration(seconds: 1));
        r.w.onProbe(probeFrom(9, via: TransportKind.lora));
        await r.runPending();
        expect(r.radioHellos, 2);
        expect(r.w.probeRadioReplies, 2);
      },
    );
  });

  group('sending the probe', () {
    late KickFake lan, ble, net;
    late SlowKick lora;
    late TransportManager m;

    setUp(() async {
      lan = KickFake(TransportKind.lan);
      ble = KickFake(TransportKind.ble);
      net = KickFake(TransportKind.internet);
      lora = SlowKick();
      m = TransportManager(
        transports: [lan, ble, net, lora],
        localNodeId: 1,
        localName: 'Me',
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      for (final t in [lan, ble, net, lora]) {
        t.sent.clear();
      }
    });

    tearDown(() => m.dispose());

    bool sentProbe(FakeTransport t) =>
        t.sent.any((s) => LobbyProbe.tryDecode(s.frame) != null);
    bool sentHello(FakeTransport t) =>
        t.sent.any((s) => s.frame.control?.kind == ControlKind.hello);

    test(
      'every fast path gets hello + probe + a discovery kick; never LoRa',
      () async {
        await m.probePeople(probeBytes(1));
        for (final t in [lan, ble, net]) {
          expect(sentProbe(t), isTrue, reason: '${t.kind}');
          expect(sentHello(t), isTrue, reason: '${t.kind}');
          expect(t.kicks, 1, reason: '${t.kind}');
        }
        expect(lora.sent, isEmpty);
        expect(lora.kicks, 0);
        expect(m.probesSent, 1);
      },
    );

    test(
      'offline power save: nothing to or kicked on the internet relay',
      () async {
        await m.setOfflineSaver(true);
        net.sent.clear();
        await m.probePeople(probeBytes(1));
        expect(sentProbe(lan), isTrue);
        expect(sentProbe(net), isFalse);
        expect(net.kicks, 0);
      },
    );

    test('an inbound probe goes to the probes stream, not the lobby', () async {
      final probes = <InboundProbe>[];
      final lobby = <InboundLobby>[];
      final s1 = m.probes.listen(probes.add);
      final s2 = m.lobby.listen(lobby.add);
      ble.deliver(Frame.tryDecode(probeBytes(9, nonce: 42))!);
      await settle();
      expect(probes.single.peerId, 9);
      expect(probes.single.probe.nonce, 42);
      expect(probes.single.transport, TransportKind.ble);
      expect(lobby, isEmpty);
      expect(m.peers, isEmpty, reason: 'a probe creates no people entry');
      await s1.cancel();
      await s2.cancel();
    });

    test('no radio connected: the LoRa probe reports false', () {
      expect(m.sendProbeRadio(probeBytes(1, radio: true)), isFalse);
    });
  });

  group('phone mesh TTL', () {
    MeshRouter router() {
      final r = MeshRouter(localId: 0xB2, maxPacketsPerSecond: 100);
      for (final n in [0xA1, 0xC3, 0xD4]) {
        r.onFrame(
          Frame.tryDecode(MeshBeacon.encode(n, 1, {0xB2}))!,
          TransportKind.ble,
        );
      }
      return r;
    }

    test('relayed with the probe TTL as the hop limit', () {
      final r = router();
      final d = r.onFrame(
        Frame.tryDecode(probeBytes(0xA1, ttl: 2))!,
        TransportKind.ble,
      );
      expect(d.deliver, isNotNull);
      final pkt = MeshPacket.tryDecode(Frame.tryDecode(d.relay!.bytes)!)!;
      expect(pkt.maxHops, 2);
      expect(pkt.hops, 2);
      // ttl 1: heard directly only.
      final one = router().onFrame(
        Frame.tryDecode(probeBytes(0xA1, ttl: 1))!,
        TransportKind.ble,
      );
      expect(one.relay, isNull);
    });

    test('not swallowed by the lobby beacon limit, but limited per origin', () {
      final r = router();
      final beacon = LobbyBeacon.public(
        name: 'A',
        channel: 1,
      ).encode(senderId: 0xA1, seq: 1);
      expect(
        r.onFrame(Frame.tryDecode(beacon)!, TransportKind.ble).relay,
        isNotNull,
      );
      expect(
        r
            .onFrame(
              Frame.tryDecode(probeBytes(0xA1, nonce: 1))!,
              TransportKind.ble,
            )
            .relay,
        isNotNull,
      );
      expect(
        r
            .onFrame(
              Frame.tryDecode(probeBytes(0xA1, nonce: 2))!,
              TransportKind.ble,
            )
            .relay,
        isNull,
        reason: 'second probe from the same phone within 5 s',
      );
    });

    test('A - B - C chain: C hears the probe through B and answers', () async {
      final air = RangeAir()
        ..link(0xA1, 0xB2)
        ..link(0xB2, 0xC3);
      final a = await phone(air, 0xA1);
      final b = await phone(air, 0xB2);
      final c = await phone(air, 0xC3);
      await introduce([a, b, c]);
      WhosWhere who(TransportManager m) {
        final w = WhosWhere(
          localId: m.localNodeId,
          sendLocal: m.sendLobbyLocal,
          beacon: (e) => LobbyBeacon.public(
            name: 'P${m.localNodeId}',
            channel: 1,
            every: e,
          ),
          replyJitter: () => Duration.zero,
        );
        w.replyPresence = ({required bool radio}) => m.sendHello();
        m.lobby.listen(w.onLobby);
        m.probes.listen(w.onProbe);
        return w;
      }

      final wa = who(a), wc = who(c);
      await wa.start();
      await wc.start();
      await settle();
      // A forgets C's startup beacon so only the reply counts.
      wa.prune();
      final seenBefore = wc.probeReplies;
      await Future<void>.delayed(const Duration(seconds: 3));
      await a.probePeople(probeBytes(0xA1, nonce: 5));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(wc.probeReplies, seenBefore + 1);
      final e = wa.entries.where((e) => e.id == 0xC3);
      expect(e, isNotEmpty);
      expect(e.first.liveHops(DateTime.now()), 2);
      wa.dispose();
      wc.dispose();
      for (final m in [a, b, c]) {
        await m.dispose();
      }
    });
  });

  group('refresh flow', () {
    PeopleRefresh quick({
      required Future<void> Function() probe,
      bool Function()? radio,
      FakeClock? clock,
    }) => PeopleRefresh(
      probe: probe,
      probeRadio: radio,
      minWait: const Duration(milliseconds: 60),
      settle: const Duration(milliseconds: 80),
      maxWait: const Duration(milliseconds: 400),
      pollEvery: const Duration(milliseconds: 10),
      clock: clock?.call,
    );

    test('probes once, waits for answers to settle, reports Found N', () async {
      var count = 0;
      var probes = 0;
      final r = quick(
        probe: () async {
          probes++;
          Timer(const Duration(milliseconds: 30), () => count = 2);
        },
      );
      final sw = Stopwatch()..start();
      final res = await r.refresh(count: () => count);
      expect(probes, 1);
      expect(res.before, 0);
      expect(res.found, 2);
      expect(res.added, 2);
      expect(res.message, 'Found 2 people');
      expect(sw.elapsedMilliseconds, lessThan(400), reason: 'settled early');
    });

    test('keeps waiting while people keep arriving, up to the max', () async {
      var count = 0;
      final tick = Timer.periodic(
        const Duration(milliseconds: 30),
        (_) => count++,
      );
      final sw = Stopwatch()..start();
      final res = await quick(probe: () async {}).refresh(count: () => count);
      tick.cancel();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(380));
      expect(sw.elapsedMilliseconds, lessThan(800));
      expect(res.found, greaterThan(5));
    });

    test('quiet network: spinner stops after the minimum wait', () async {
      final sw = Stopwatch()..start();
      final res = await quick(probe: () async {}).refresh(count: () => 0);
      expect(sw.elapsedMilliseconds, lessThan(300));
      expect(res.message, 'No one found yet');
    });

    test('a second pull while refreshing joins the first', () async {
      var probes = 0;
      final r = quick(probe: () async => probes++);
      final f1 = r.refresh(count: () => 1);
      expect(r.refreshing, isTrue);
      final f2 = r.refresh(count: () => 1);
      final res = await Future.wait([f1, f2]);
      expect(probes, 1);
      expect(res[1].message, 'Found 1 person');
      expect(r.refreshing, isFalse);
    });

    test('the default spinner ends by about 3 s', () {
      final r = PeopleRefresh(probe: () async {});
      expect(r.maxWait, const Duration(seconds: 3));
      expect(WhosWhere.maxReplyJitter, lessThan(r.maxWait));
    });
  });

  group('LoRa gating', () {
    test(
      'plain refresh never touches the radio; asked: once per 2 min',
      () async {
        final clock = FakeClock();
        var radio = 0;
        final r = PeopleRefresh(
          probe: () async {},
          probeRadio: () {
            radio++;
            return true;
          },
          minWait: Duration.zero,
          settle: Duration.zero,
          maxWait: const Duration(milliseconds: 50),
          clock: clock.call,
        );
        final plain = await r.refresh(count: () => 0);
        expect(radio, 0);
        expect(plain.radio, RadioProbe.none);
        final first = await r.refresh(count: () => 0, radio: true);
        expect(radio, 1);
        expect(first.radio, RadioProbe.sent);
        expect(first.message, contains('Asked over radio'));
        clock.advance(const Duration(seconds: 30));
        final again = await r.refresh(count: () => 0, radio: true);
        expect(radio, 1);
        expect(again.radio, RadioProbe.limited);
        expect(again.radioWait, const Duration(seconds: 90));
        expect(again.message, contains('try again in 2 min'));
        clock.advance(const Duration(seconds: 90));
        expect(r.radioWait, Duration.zero);
        final later = await r.refresh(count: () => 0, radio: true);
        expect(radio, 2);
        expect(later.radio, RadioProbe.sent);
      },
    );

    test(
      'no radio connected: reported, and the 2 min window is not used',
      () async {
        var connected = false;
        var radio = 0;
        final r = PeopleRefresh(
          probe: () async {},
          probeRadio: () {
            if (!connected) return false;
            radio++;
            return true;
          },
          minWait: Duration.zero,
          settle: Duration.zero,
          maxWait: const Duration(milliseconds: 50),
        );
        final no = await r.refresh(count: () => 0, radio: true);
        expect(no.radio, RadioProbe.noRadio);
        connected = true;
        final yes = await r.refresh(count: () => 0, radio: true);
        expect(yes.radio, RadioProbe.sent);
        expect(radio, 1);
      },
    );

    test('the radio probe crosses LoRa; a plain refresh never does', () async {
      final clock = FakeClock();
      final ra = AirRadio(0xA1), rb = AirRadio(0xB1);
      ra.other = rb;
      rb.other = ra;
      final a = RadioPhone(0x1111, ra, clock);
      final b = RadioPhone(0x2222, rb, clock);
      await a.m.start();
      await b.m.start();
      await settle();
      final got = <InboundProbe>[];
      b.m.probes.listen(got.add);
      // A plain refresh puts nothing on the radio.
      ra.sent.clear();
      await a.m.probePeople(probeBytes(0x1111));
      await settle();
      expect(ra.sent, isEmpty);
      expect(got, isEmpty);
      expect(a.m.sendProbeRadio(probeBytes(0x1111, radio: true)), isTrue);
      await settle();
      expect(got.single.transport, TransportKind.lora);
      expect(got.single.probe.radio, isTrue);
      await a.m.dispose();
      await b.m.dispose();
    });
  });

  group('UI', () {
    Widget home({
      required Future<RefreshResult> Function({required bool radio}) onRefresh,
      bool radio = false,
    }) => MaterialApp(
      home: Scaffold(
        body: HomeBody(
          links: const [(TransportKind.lan, TransportStatus.running)],
          internet: (status: TransportStatus.running, text: 'Internet'),
          showDetails: false,
          onToggleDetails: (_) {},
          channelLabel: 'CH 1',
          me: const PersonView(id: 1, name: 'Me', me: true),
          people: const [],
          onRing: (_) {},
          onBeep: (_) {},
          onMessage: (_) {},
          onRefresh: onRefresh,
          radioAvailable: () => radio,
          actions: const SizedBox(),
          ptt: const SizedBox(height: 40),
        ),
      ),
    );

    testWidgets('Talk screen: button, pull and long-press refresh', (t) async {
      final calls = <bool>[];
      await t.pumpWidget(
        home(
          onRefresh: ({required bool radio}) async {
            calls.add(radio);
            return RefreshResult(
              found: 1,
              before: 0,
              radio: radio ? RadioProbe.sent : RadioProbe.none,
            );
          },
        ),
      );
      expect(find.byKey(const Key('people-refresh')), findsOneWidget);
      await t.tap(find.byKey(const Key('people-refresh')));
      await t.pumpAndSettle();
      expect(calls, [false]);
      expect(find.text('Found 1 person'), findsOneWidget);
      // Pull down.
      await t.fling(
        find.byKey(const Key('people-count')),
        const Offset(0, 400),
        1000,
      );
      await t.pumpAndSettle();
      expect(calls, [false, false]);
      // Hold the button: also over the radio.
      await t.longPress(find.byKey(const Key('people-refresh')));
      await t.pumpAndSettle();
      expect(calls, [false, false, true]);
      expect(find.textContaining('Asked over radio'), findsOneWidget);
    });

    testWidgets(
      '"Also ask over radio (slow)" offered when a radio is connected',
      (t) async {
        final calls = <bool>[];
        await t.pumpWidget(
          home(
            radio: true,
            onRefresh: ({required bool radio}) async {
              calls.add(radio);
              return const RefreshResult(found: 0, before: 0);
            },
          ),
        );
        await t.tap(find.byKey(const Key('people-refresh')));
        await t.pumpAndSettle();
        expect(find.text('Also ask over radio (slow)'), findsOneWidget);
        await t.tap(find.text('Also ask over radio (slow)'));
        await t.pumpAndSettle();
        expect(calls, [false, true]);
      },
    );

    testWidgets("Who's where: refresh button and pull", (t) async {
      final calls = <bool>[];
      await t.pumpWidget(
        MaterialApp(
          home: WhosWhereView(
            groups: buildWhosWhere(
              myId: 1,
              myName: 'Me',
              myChannel: 1,
              myScope: 1,
              iAmPrivate: false,
              now: DateTime(2026),
            ),
            showMe: true,
            onRefresh: ({required bool radio}) async {
              calls.add(radio);
              return const RefreshResult(found: 3, before: 1);
            },
          ),
        ),
      );
      await t.tap(find.byKey(const Key('people-refresh')));
      await t.pumpAndSettle();
      expect(calls, [false]);
      expect(find.text('Found 3 people'), findsOneWidget);
      await t.fling(
        find.byKey(const Key('whos-where-summary')),
        const Offset(0, 400),
        1000,
      );
      await t.pumpAndSettle();
      expect(calls, [false, false]);
    });
  });
}
