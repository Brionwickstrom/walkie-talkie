import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/lost_contact.dart';
import 'package:walkie_talkie/trip/sos.dart';
import 'package:walkie_talkie/trip/store_forward.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_route.dart';

import 'messaging_fakes.dart';

const me = 0x1111, bob = 0x2222, carol = 0x3333, dave = 0x4444;
const here = GeoPoint(45.5, -122.6);

class Sent {
  Sent(this.msg, this.route);
  final TripMsg msg;
  final TripRoute route;
}

void main() {
  group('SOS repeat and acknowledge', () {
    late FakeClock clock;
    late List<Sent> sent;
    late SosManager sos;
    var ids = 100;

    setUp(() {
      clock = FakeClock();
      sent = [];
      sos = SosManager(
        localId: me,
        send: (m, r) => sent.add(Sent(m, r)),
        nextId: () => ids++,
        clock: clock.call,
      );
    });

    void run(Duration d) {
      for (var i = 0; i < d.inSeconds; i++) {
        clock.advance(const Duration(seconds: 1));
        sos.tick();
      }
    }

    int radio() => sent.where((s) => s.route.radio).length;
    int fast() => sent.where((s) => s.route.fast).length;

    test('sent at once over every path incl. LoRa, flooded', () {
      final s = sos.start(here, accuracyM: 6);
      expect(sent.single.msg, isA<SosMsg>());
      final m = sent.single.msg as SosMsg;
      expect(m.id, s.id);
      expect(m.pos, here);
      expect(sent.single.route.flood, isTrue);
      expect(sent.single.route.radio, isTrue);
      expect(sent.single.route.fast, isTrue);
    });

    test('repeats every 10 s on fast links and 30 s by radio until acked', () {
      sos.start(here);
      run(const Duration(seconds: 60));
      // t=0 plus every 10 s.
      expect(fast(), 7);
      // Radio at t=0, 30, 60.
      expect(radio(), 3);
      final reps = sent.map((s) => (s.msg as SosMsg).repeat).toList();
      expect(reps, List.generate(reps.length, (i) => i));
    });

    test('after an ack: no more radio, fast only once a minute', () {
      final s = sos.start(here);
      int? ackFrom;
      sos.onAcked = (f) => ackFrom = f;
      run(const Duration(seconds: 12));
      sos.onAck(bob, SosAckMsg(5, origin: me, sosId: s.id));
      expect(ackFrom, bob);
      expect(s.acknowledged, isTrue);
      sent.clear();
      run(const Duration(seconds: 125));
      expect(radio(), 0);
      expect(fast(), 2);
      // Someone else's ack for a different SOS does not count.
      sos.onAck(carol, const SosAckMsg(6, origin: me, sosId: 9999));
      expect(s.acks.keys, [bob]);
    });

    test('radio copies are capped (duty cycle)', () {
      sos.start(here);
      run(const Duration(minutes: 30));
      expect(radio(), sos.maxRadioSends);
    });

    test('position updates go into the next repeat', () {
      sos.start(null);
      expect((sent.last.msg as SosMsg).pos, isNull);
      sos.updatePosition(here, accuracyM: 4);
      run(const Duration(seconds: 10));
      expect((sent.last.msg as SosMsg).pos, here);
    });

    test('cancel: 3 fast copies, 2 radio copies, then silence', () {
      final s = sos.start(here);
      sent.clear();
      sos.cancel();
      expect(sos.active, isNull);
      run(const Duration(minutes: 3));
      final cancels = sent.map((x) => x.msg as SosMsg).toList();
      expect(cancels.every((m) => m.cancel && m.id == s.id), isTrue);
      expect(fast(), 3);
      expect(radio(), 2);
    });

    test('receiver: one alarm per SOS, repeats update the location', () {
      final alerts = <IncomingSos>[];
      final stops = <IncomingSos>[];
      sos.onAlert = alerts.add;
      sos.onStop = stops.add;
      sos.onSos(bob, const SosMsg(7, pos: here));
      clock.advance(const Duration(seconds: 10));
      const moved = GeoPoint(45.501, -122.6);
      sos.onSos(bob, const SosMsg(7, pos: moved, repeat: 1));
      expect(alerts.length, 1);
      expect(sos.incoming.single.pos, moved);
      expect(sos.incoming.single.repeat, 1);
      expect(sos.unanswered.length, 1);
      // A second SOS from someone else is its own alert.
      sos.onSos(carol, const SosMsg(7));
      expect(alerts.length, 2);
      // My own SOS echoed back is ignored.
      expect(sos.onSos(me, const SosMsg(1)), isNull);
      // Cancel stops the alarm.
      sos.onSos(bob, const SosMsg(7, cancel: true));
      expect(stops.single.origin, bob);
      expect(sos.unanswered.single.origin, carol);
    });

    test(
      'acknowledge: tells everyone (radio too), resends if they keep repeating',
      () {
        sos.onSos(bob, const SosMsg(7, pos: here));
        final s = sos.incoming.single;
        sos.acknowledge(s);
        final ack = sent.single.msg as SosAckMsg;
        expect(ack.origin, bob);
        expect(ack.sosId, 7);
        expect(sent.single.route.flood, isTrue);
        expect(sent.single.route.radio, isTrue);
        expect(sos.unanswered, isEmpty);
        // Bob still repeating 5 s later: not yet (rate limit)...
        clock.advance(const Duration(seconds: 5));
        sos.onSos(bob, const SosMsg(7, pos: here, repeat: 1));
        expect(sent.length, 1);
        // ...but after 15 s our ack goes again.
        clock.advance(const Duration(seconds: 11));
        sos.onSos(bob, const SosMsg(7, pos: here, repeat: 2));
        expect(sent.length, 2);
        // Others see who answered.
        sos.onAck(carol, const SosAckMsg(1, origin: bob, sosId: 7));
        expect(s.ackers.keys, containsAll([me, carol]));
      },
    );

    test('a cancel that overtakes the alert keeps it from sounding', () {
      var alerts = 0;
      sos.onAlert = (_) => alerts++;
      sos.onSos(bob, const SosMsg(8, cancel: true));
      sos.onSos(bob, const SosMsg(8, pos: here));
      expect(alerts, 0);
    });

    test('old alerts are forgotten after 2 h of silence', () {
      sos.onSos(bob, const SosMsg(7, pos: here));
      run(const Duration(minutes: 121));
      expect(sos.incoming, isEmpty);
    });
  });

  group('lost-contact timing', () {
    late FakeClock clock;
    late LostContactMonitor lost;
    setUp(() {
      clock = FakeClock();
      lost = LostContactMonitor(clock: clock.call);
    });

    test('warns once after 20 min of silence, with last location', () {
      final warned = <int>[];
      lost.onLost = (s) => warned.add(s.id);
      lost.heard(bob, pos: here);
      clock.advance(const Duration(minutes: 5));
      lost.heard(carol);
      clock.advance(const Duration(minutes: 14, seconds: 59));
      expect(lost.tick(), isEmpty);
      clock.advance(const Duration(seconds: 1));
      final now = lost.tick();
      expect(now.single.id, bob);
      expect(now.single.lastPos, here);
      expect(lost.tick(), isEmpty, reason: 'only once');
      clock.advance(const Duration(minutes: 5));
      expect(lost.tick().single.id, carol);
      expect(warned, [bob, carol]);
      expect(lost.lost.map((s) => s.id), [bob, carol]);
    });

    test('hearing them again clears it; older reports do not', () {
      final found = <int>[];
      lost.onFound = (s) => found.add(s.id);
      lost.heard(bob);
      clock.advance(const Duration(minutes: 25));
      lost.tick();
      // A stale (base camp) report from 22 min ago does not count.
      lost.heard(bob, at: clock.now.subtract(const Duration(minutes: 22)));
      expect(lost.lost, isNotEmpty);
      lost.heard(bob);
      expect(found, [bob]);
      expect(lost.lost, isEmpty);
      // And it can warn again later.
      clock.advance(const Duration(minutes: 20));
      expect(lost.tick().single.id, bob);
    });

    test('custom threshold and off switch', () {
      lost.threshold = const Duration(minutes: 10);
      lost.heard(bob);
      clock.advance(const Duration(minutes: 10));
      lost.enabled = false;
      expect(lost.tick(), isEmpty);
      lost.enabled = true;
      expect(lost.tick().single.id, bob);
    });

    test('newest location wins even if reports arrive out of order', () {
      final t = clock.now;
      lost.heard(bob, pos: here, posAt: t);
      lost.heard(
        bob,
        pos: const GeoPoint(1, 1),
        posAt: t.subtract(const Duration(minutes: 3)),
      );
      expect(lost.state(bob)!.lastPos, here);
    });
  });

  group('base camp store-and-forward', () {
    late FakeClock clock;
    late StoreForward store;
    var ids = 1;
    setUp(() {
      clock = FakeClock();
      store = StoreForward(clock: clock.call)..enabled = true;
    });

    test('holds for absent phones and delivers once when they come back', () {
      expect(
        store.hold(bob, const CannedMsg(1, 4), 0xA1, {carol, dave}),
        isTrue,
      );
      expect(store.pendingFor(carol), isTrue);
      clock.advance(const Duration(minutes: 30));
      final forCarol = store.takeFor(carol, () => ids++);
      expect(forCarol.single.origin, bob);
      expect(forCarol.single.age, const Duration(minutes: 30));
      expect((forCarol.single.inner as CannedMsg).display, 'At camp');
      expect(store.takeFor(carol, () => ids++), isEmpty);
      expect(store.items.length, 1, reason: 'still waiting for Dave');
      expect(store.takeFor(dave, () => ids++).length, 1);
      expect(store.items, isEmpty);
      expect(store.delivered, 2);
    });

    test('dedupe by mesh packet id and by message id', () {
      expect(store.hold(bob, const CannedMsg(1, 4), 0xA1, {carol}), isTrue);
      expect(store.hold(bob, const CannedMsg(1, 4), 0xA1, {carol}), isFalse);
      // Same message relayed through another path (different packet id).
      expect(store.hold(bob, const CannedMsg(1, 4), 0xB2, {carol}), isFalse);
      expect(store.items.length, 1);
    });

    test('newest check-in / SOS copy replaces the older one', () {
      store.hold(bob, const PosMsg(1, here, checkIn: true), 1, {carol});
      store.hold(
        bob,
        const PosMsg(2, GeoPoint(45.6, -122.6), checkIn: true),
        2,
        {dave},
      );
      expect(store.items.length, 1);
      expect(store.items.single.pendingFor, {carol, dave});
      store.hold(bob, const SosMsg(9, pos: here), 3, {carol});
      store.hold(bob, const SosMsg(9, pos: here, repeat: 4), 4, {carol});
      store.hold(bob, const SosMsg(9, cancel: true), 5, {carol});
      final sos = store.items.where((i) => i.msg is SosMsg).toList();
      expect(sos.length, 1);
      expect((sos.single.msg as SosMsg).cancel, isTrue);
    });

    test('live positions, full trails and nested deliveries are not held', () {
      expect(store.hold(bob, const PosMsg(1, here), 1, {carol}), isFalse);
      expect(
        store.hold(
          bob,
          const TrackMsg(2, trackId: 1, index: 0, count: 2, points: []),
          2,
          {carol},
        ),
        isFalse,
      );
      expect(
        store.hold(
          bob,
          const HeldMsg(
            3,
            origin: dave,
            age: Duration.zero,
            inner: CannedMsg(1, 1),
          ),
          3,
          {carol},
        ),
        isFalse,
      );
      // Nobody missing, or only the sender itself: nothing to hold.
      expect(store.hold(bob, const CannedMsg(4, 1), 4, {}), isFalse);
      expect(store.hold(bob, const CannedMsg(5, 1), 5, {bob}), isFalse);
      store.enabled = false;
      expect(store.hold(bob, const CannedMsg(6, 1), 6, {carol}), isFalse);
    });

    test('TTL and size caps', () {
      final small = StoreForward(clock: clock.call, maxItems: 3)
        ..enabled = true;
      for (var i = 0; i < 5; i++) {
        small.hold(bob, CannedMsg(i, 1), i + 1, {carol});
      }
      expect(small.items.map((i) => i.msg.id), [2, 3, 4]);
      expect(small.dropped, 2);
      final bytes = StoreForward(clock: clock.call, maxBytes: 20)
        ..enabled = true;
      bytes.hold(bob, const CannedMsg(1, 0, text: 'aaaaaaaaaa'), 1, {carol});
      bytes.hold(bob, const CannedMsg(2, 0, text: 'bbbbbbbbbb'), 2, {carol});
      expect(bytes.items.single.msg.id, 2);
      clock.advance(const Duration(hours: 6, minutes: 1));
      expect(small.takeFor(carol, () => ids++), isEmpty);
      expect(small.items, isEmpty);
    });
  });

  group('distance and bearing', () {
    test('known distances', () {
      expect(
        distanceM(const GeoPoint(0, 0), const GeoPoint(1, 0)),
        closeTo(111195, 50),
      );
      expect(distanceM(here, here), 0);
      // Portland -> Paris, about 8,200 km.
      expect(
        distanceM(
              const GeoPoint(45.5152, -122.6784),
              const GeoPoint(48.8566, 2.3522),
            ) /
            1000,
        closeTo(8200, 60),
      );
    });

    test('bearings and compass points', () {
      const o = GeoPoint(45, -122);
      expect(bearingDeg(o, const GeoPoint(45.01, -122)), closeTo(0, 0.01));
      expect(bearingDeg(o, const GeoPoint(45, -121.99)), closeTo(90, 0.01));
      expect(bearingDeg(o, const GeoPoint(44.99, -122)), closeTo(180, 0.01));
      expect(bearingDeg(o, const GeoPoint(45, -122.01)), closeTo(270, 0.01));
      expect(cardinal(0), 'N');
      expect(cardinal(44), 'NE');
      expect(cardinal(359), 'N');
      expect(cardinal(202), 'S');
      expect(cardinal(250), 'W');
      expect(cardinal(-45), 'NW');
    });

    test('"0.8 mi NE" style text', () {
      const o = GeoPoint(45, -122);
      // ~0.8 mi north-east.
      final ne = GeoPoint(45 + 0.00818, -122 + 0.01157);
      expect(formatDistanceBearing(o, ne), '0.8 mi NE');
      expect(formatDistance(100), '330 ft');
      expect(formatDistance(1609.344 * 12.4), '12 mi');
      expect(formatDistance(450, imperial: false), '450 m');
      expect(formatDistance(2345, imperial: false), '2.3 km');
    });

    test('arrow angle follows the phone heading', () {
      expect(arrowAngleDeg(90, null), 90);
      expect(arrowAngleDeg(90, 90), 0);
      expect(arrowAngleDeg(10, 350), 20);
      expect(deltaDeg(10, 350), 20);
      expect(deltaDeg(350, 10), -20);
      expect(smoothAngle(350, 10, 0.5), closeTo(0, 1e-9));
    });

    test('tilt-compensated heading from accelerometer + magnetometer', () {
      // Flat phone, field pointing north and down (northern hemisphere).
      expect(headingFromSensors(0, 0, 9.8, 0, 20, -40), closeTo(0, 0.5));
      // Field towards the phone's left (-x) => the phone's top points east.
      expect(headingFromSensors(0, 0, 9.8, -20, 0, -40), closeTo(90, 0.5));
      expect(headingFromSensors(0, 0, 9.8, 20, 0, -40), closeTo(270, 0.5));
      expect(headingFromSensors(0, 0, 0, 1, 1, 1), isNull);
    });

    test('sunrise / sunset offline (Portland, late October)', () {
      final s = sunTimes(
        DateTime.utc(2026, 10, 26),
        const GeoPoint(45.52, -122.68),
      );
      // About 7:40 AM and 6:00 PM PDT (UTC-7).
      final rise = s.sunrise!.subtract(const Duration(hours: 7));
      final set = s.sunset!.subtract(const Duration(hours: 7));
      expect(rise.hour * 60 + rise.minute, closeTo(7 * 60 + 40, 10));
      expect(set.hour * 60 + set.minute, closeTo(18 * 60 + 2, 10));
      expect(s.sunset!.isAfter(s.sunrise!), isTrue);
      // Polar night: no sunrise.
      expect(
        sunTimes(DateTime.utc(2026, 12, 21), const GeoPoint(78, 15)).sunrise,
        isNull,
      );
    });

    test('trail simplification keeps the shape within the limit', () {
      final pts = [
        for (var i = 0; i <= 100; i++)
          GeoPoint(45 + i * 0.0001, -122 + (i < 50 ? 0 : (i - 50) * 0.0001)),
      ];
      final s = simplify<GeoPoint>(pts, (p) => p, 2);
      expect(s.length, 3);
      expect(s[1], pts[50]);
      expect(thinTo<GeoPoint>(pts, (p) => p, 2), [pts.first, pts.last]);
      expect(
        pathLengthM(pts),
        closeTo(distanceM(pts[0], pts[50]) + distanceM(pts[50], pts[100]), 1),
      );
    });
  });
}
