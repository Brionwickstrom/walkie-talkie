import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/trip/friend_motion.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/friend_marker.dart';

import 'messaging_fakes.dart';
import 'trip_integration_test.dart' as ti;

const here = GeoPoint(45.5231, -122.6765);

/// What an app before v2.5.6 reads from a location message (its decoder
/// stops after the battery byte and ignores the rest).
({GeoPoint p, int acc, int age, int? bt, int flags}) legacyRead(Uint8List b) {
  final bd = ByteData.sublistView(b);
  var o = 3;
  final flags = b[o++];
  final lat = bd.getInt32(o);
  o += 4;
  final lng = bd.getInt32(o);
  o += 4;
  final acc = b[o++];
  final age = b[o++];
  final bt = flags & 4 != 0 ? b[o++] : null;
  return (
    p: GeoPoint.fromE5(lat, lng),
    acc: acc,
    age: age,
    bt: bt,
    flags: flags,
  );
}

void main() {
  group('speed and heading in the location message', () {
    test('round trip: 0.5 m/s and 1.4 degree steps', () {
      final m = PosMsg(
        7,
        here,
        accuracyM: 8,
        battery: 80,
        speedMps: 13.4,
        headingDeg: 271,
        checkIn: true,
      );
      final d = TripMsg.tryDecode(m.encode()) as PosMsg;
      expect(d.speedMps, 13.5);
      expect(d.headingDeg, closeTo(271, 0.8));
      expect(d.battery, 80);
      expect(d.accuracyM, 8);
      expect(d.checkIn, isTrue);
      expect(d.pos, here);
    });

    test('small: 17 bytes at most, 14 when nothing is added', () {
      expect(const PosMsg(1, here).encode().length, 14);
      expect(
        const PosMsg(
          1,
          here,
          battery: 50,
          speedMps: 20,
          headingDeg: 359,
        ).encode().length,
        17,
      );
      expect(
        const PosMsg(1, here, speedMps: 20).encode().length,
        15,
        reason: 'speed alone, no heading, is one byte',
      );
    });

    test('heading wraps and clamps; speed clamps', () {
      final a = TripMsg.tryDecode(
        const PosMsg(1, here, speedMps: 500, headingDeg: 359.9).encode(),
      ) as PosMsg;
      expect(a.speedMps, 127.5);
      expect(a.headingDeg, 0);
      final b = TripMsg.tryDecode(
        const PosMsg(1, here, speedMps: 3, headingDeg: -90).encode(),
      ) as PosMsg;
      expect(b.headingDeg, closeTo(270, 1));
    });

    test('older messages decode with no speed or heading', () {
      final d = TripMsg.tryDecode(
        const PosMsg(2, here, accuracyM: 5, battery: 60).encode(),
      ) as PosMsg;
      expect(d.speedMps, isNull);
      expect(d.headingDeg, isNull);
    });

    test('an older app reads the same place, accuracy and battery', () {
      final bytes = const PosMsg(
        9,
        here,
        accuracyM: 12,
        battery: 71,
        speedMps: 9,
        headingDeg: 45,
      ).encode();
      final old = legacyRead(bytes);
      expect(old.p, here);
      expect(old.acc, 12);
      expect(old.bt, 71);
      // And the new fields sit after everything an older app reads.
      expect(bytes.length, 17);
      // The message type and id are in the same places.
      final plain = const PosMsg(9, here, accuracyM: 12, battery: 71).encode();
      expect(bytes.sublist(0, 3), plain.sublist(0, 3));
      expect(bytes.sublist(4, 15), plain.sublist(4, 15));
    });

    test('a message cut after the speed byte is not accepted as a place', () {
      final bytes = const PosMsg(1, here, speedMps: 9).encode();
      expect(TripMsg.tryDecode(bytes.sublist(0, bytes.length - 1)), isNull);
    });
  });

  group('dead reckoning', () {
    final at = DateTime(2026, 10, 30, 12);
    FriendEstimate est({
      double? speed = 10,
      double? heading = 0,
      double? acc = 8,
      int secs = 10,
      bool held = false,
    }) => estimateFriend(
      pos: here,
      at: at,
      now: at.add(Duration(seconds: secs)),
      speedMps: speed,
      headingDeg: heading,
      accuracyM: acc,
      held: held,
    );

    test('moves along the heading by speed x time', () {
      final e = est();
      expect(e.projected, isTrue);
      expect(distanceM(here, e.pos), closeTo(100, 1));
      expect(
        bearingDeg(here, e.pos),
        anyOf(closeTo(0, 0.5), closeTo(360, 0.5)),
      );
      final east = est(heading: 90, secs: 20);
      expect(distanceM(here, east.pos), closeTo(200, 1));
      expect(bearingDeg(here, east.pos), closeTo(90, 0.5));
    });

    test('the circle grows with the guess', () {
      expect(est().radiusM, closeTo(8 + 0.2 * 100, 1));
      expect(est(secs: 0).radiusM, 8);
    });

    test('no guess for slow, still, unsure, unknown or held fixes', () {
      for (final e in [
        est(speed: 1.5),
        est(speed: 0),
        est(speed: null),
        est(heading: null),
        est(acc: 80),
        est(acc: null),
        est(held: true),
      ]) {
        expect(e.projected, isFalse);
        expect(e.pos, here);
      }
    });

    test('capped in distance and time, then back to the real fix', () {
      expect(distanceM(here, est(speed: 40, secs: 60).pos), closeTo(500, 1));
      expect(est(secs: 75).projected, isTrue);
      final stale = est(secs: 76);
      expect(stale.projected, isFalse);
      expect(stale.pos, here);
    });

    test('a fix from the future or the same instant is not moved', () {
      expect(est(secs: -5).projected, isFalse);
      expect(est(secs: 0).projected, isFalse);
    });

    test('fade: solid for 2 minutes, then to 45% at 30 minutes', () {
      expect(friendOpacity(const Duration(seconds: 5)), 1);
      expect(friendOpacity(const Duration(minutes: 2)), 1);
      expect(friendOpacity(const Duration(minutes: 16)), closeTo(0.725, 0.01));
      expect(friendOpacity(const Duration(minutes: 30)), 0.45);
      expect(friendOpacity(const Duration(hours: 5)), 0.45);
    });

    test('the real age, never just now', () {
      expect(exactAge(Duration.zero), '0 s');
      expect(exactAge(const Duration(seconds: 4)), '4 s');
      expect(exactAge(const Duration(seconds: 59)), '59 s');
      expect(exactAge(const Duration(seconds: 60)), '1 min');
      expect(exactAge(const Duration(seconds: 125)), '2 min 5 s');
      expect(exactAge(const Duration(minutes: 12, seconds: 40)), '12 min');
      expect(exactAge(const Duration(hours: 3, minutes: 5)), '3 h 5 min');
      expect(exactAge(const Duration(hours: 3)), '3 h');
      expect(exactAge(const Duration(days: 3)), '3 d');
      expect(exactAge(const Duration(seconds: -3)), '0 s');
    });

    test('movedBy: a metre north is about 9e-6 degrees', () {
      final p = movedBy(here, 0, 111.19);
      expect(p.lat - here.lat, closeTo(0.001, 1e-5));
      expect(p.lng, closeTo(here.lng, 1e-9));
    });
  });

  group('the controller', () {
    late Directory dir;
    late ti.FakeHost host;
    late TripController t;
    late FakeClock clock;
    Future<void> settle() => Future<void>.delayed(Duration.zero);
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trip256');
      host = ti.FakeHost(1);
      clock = FakeClock();
      t = TripController(
        host: host,
        settings: TripSettings()..tripMode = true,
        dir: dir,
        userAgent: 'test',
        clock: clock.call,
      );
      t.tiles.online = false;
      await t.start();
      t.setAppForeground(false);
      await settle();
    });
    tearDown(() async {
      t.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Fix fix(
      GeoPoint p, {
      double? speed,
      double? bearing,
      double acc = 6,
      int? secs,
    }) => Fix(
      p,
      secs == null ? clock.now : clock.now.add(Duration(seconds: secs)),
      accuracyM: acc,
      speedMps: speed,
      bearingDeg: bearing,
    );

    List<PosMsg> posSent() =>
        host.sent.map((s) => s.msg).whereType<PosMsg>().toList();

    test('what we send carries speed and heading (heading only moving)', () {
      t.onFix(fix(here, speed: 12, bearing: 90));
      expect(posSent().last.speedMps, 12);
      expect(posSent().last.headingDeg, 90);
      clock.advance(const Duration(seconds: 70));
      t.onFix(fix(here, speed: 0.5, bearing: 200));
      expect(posSent().last.speedMps, 0.5);
      expect(posSent().last.headingDeg, isNull, reason: 'a still phone');
      clock.advance(const Duration(seconds: 70));
      t.onFix(fix(here));
      expect(posSent().last.speedMps, isNull);
      expect(posSent().last.headingDeg, isNull);
    });

    test('a friend\'s speed and heading are kept and move the dot', () {
      host.inbound.add(
        ti.trip(
          7,
          const PosMsg(1, here, accuracyM: 5, speedMps: 15, headingDeg: 90),
        ),
      );
      final pp = t.people[7]!;
      expect(pp.speedMps, 15);
      expect(pp.headingDeg, closeTo(90, 1));
      expect(t.friendEstimate(pp).projected, isFalse, reason: 'just now');
      clock.advance(const Duration(seconds: 20));
      final e = t.friendEstimate(pp);
      expect(e.projected, isTrue);
      expect(distanceM(here, e.pos), closeTo(300, 3));
      // A newer message without speed (an older app) stops the guessing.
      host.inbound.add(ti.trip(7, PosMsg(2, here, accuracyM: 5), packetId: 2));
      expect(t.people[7]!.speedMps, isNull);
      expect(t.friendEstimate(t.people[7]!).projected, isFalse);
    });

    test('a held (base camp) location is never moved', () {
      final pp = PersonPos(7, here, clock.now, TransportKind.ble, 1)
        ..accuracyM = 5
        ..speedMps = 15
        ..headingDeg = 0
        ..held = true;
      clock.advance(const Duration(seconds: 10));
      expect(t.friendEstimate(pp).projected, isFalse);
    });

    group('Driving mode', () {
      test('never on battery: fast driving changes nothing', () async {
        final n = host.locationStarts.length;
        for (var i = 0; i < 5; i++) {
          t.onFix(fix(here, speed: 25, bearing: 0));
          clock.advance(const Duration(seconds: 6));
        }
        await settle();
        expect(t.drivingMode, isFalse);
        expect(host.locationStarts.length, n);
        expect(host.locationStarts.last.interval, const Duration(seconds: 45));
        expect(host.locationStarts.last.highAccuracy, isFalse);
      });

      test('plugged in but not driving: nothing changes', () async {
        await t.setPluggedIn(true);
        t.onFix(fix(here, speed: 1.2, bearing: 0));
        await settle();
        expect(t.pluggedIn, isTrue);
        expect(t.drivingMode, isFalse);
        expect(host.locationStarts.last.interval, const Duration(seconds: 45));
        expect(host.locationStarts.last.highAccuracy, isFalse);
      });

      test(
        'plugged in and driving: precise GPS every 2 s, then back',
        () async {
          await t.setPluggedIn(true);
          t.onFix(fix(here, speed: 20, bearing: 0));
          await settle();
          expect(t.drivingMode, isTrue);
          expect(host.locationStarts.last.interval, const Duration(seconds: 2));
          expect(host.locationStarts.last.highAccuracy, isTrue);
          // Unplugged: back to the background plan at once.
          await t.setPluggedIn(false);
          expect(t.drivingMode, isFalse);
          expect(
            host.locationStarts.last.interval,
            const Duration(seconds: 45),
          );
          expect(host.locationStarts.last.highAccuracy, isFalse);
          // Plugged in again while still moving.
          await t.setPluggedIn(true);
          expect(t.drivingMode, isTrue);
          expect(host.locationStarts.last.interval, const Duration(seconds: 2));
        },
      );

      test('it ends 2 minutes after the last fast fix', () async {
        await t.setPluggedIn(true);
        t.onFix(fix(here, speed: 20, bearing: 0));
        await settle();
        expect(t.drivingMode, isTrue);
        clock.advance(const Duration(seconds: 100));
        t.onFix(fix(here, speed: 0, bearing: 0));
        await settle();
        expect(t.drivingMode, isTrue, reason: 'a short stop');
        clock.advance(const Duration(seconds: 30));
        t.onFix(fix(here, speed: 0, bearing: 0));
        await settle();
        expect(t.drivingMode, isFalse);
        expect(host.locationStarts.last.interval, const Duration(seconds: 45));
      });

      test(
        'speed from the distance between fixes when the phone gives none',
        () async {
          await t.setPluggedIn(true);
          t.onFix(fix(here));
          clock.advance(const Duration(seconds: 45));
          // About 600 m in 45 s = 13 m/s.
          t.onFix(fix(movedBy(here, 0, 600)));
          await settle();
          expect(t.drivingMode, isTrue);
        },
      );

      test('a jump from a poor fix is not driving', () async {
        await t.setPluggedIn(true);
        t.onFix(fix(here));
        clock.advance(const Duration(seconds: 45));
        t.onFix(fix(movedBy(here, 0, 600), acc: 500));
        await settle();
        expect(t.drivingMode, isFalse);
      });

      test('off without Trip mode and in Offline power save', () async {
        await t.setPluggedIn(true);
        t.onFix(fix(here, speed: 20, bearing: 0));
        await settle();
        expect(t.drivingMode, isTrue);
        await t.setOfflineSaver(true);
        expect(t.drivingMode, isFalse);
        await t.setOfflineSaver(false);
        expect(t.drivingMode, isTrue);
        t.settings.tripMode = false;
        expect(t.drivingMode, isFalse);
      });

      test('live updates every 5 s when plugged in and driving', () async {
        await t.setPluggedIn(true);
        var p = here;
        t.onFix(fix(p, speed: 20, bearing: 0));
        final first = posSent().length;
        for (var i = 0; i < 6; i++) {
          clock.advance(const Duration(seconds: 6));
          p = movedBy(p, 0, 120);
          t.onFix(fix(p, speed: 20, bearing: 0));
        }
        expect(posSent().length - first, 6);
      });

      test('on battery the same drive sends at the usual pace', () async {
        var p = here;
        t.onFix(fix(p, speed: 20, bearing: 0));
        final first = posSent().length;
        for (var i = 0; i < 6; i++) {
          clock.advance(const Duration(seconds: 6));
          p = movedBy(p, 0, 120);
          t.onFix(fix(p, speed: 20, bearing: 0));
        }
        expect(posSent().length - first, lessThan(3));
      });
    });
  });

  group('the map', () {
    Future<TripController> trip(WidgetTester t, FakeClock clock) async {
      final tmp = Directory.systemTemp.createTempSync('v256');
      final c = TripController(
        host: ti.FakeHost(1),
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
        clock: clock.call,
      );
      c.tiles.online = false;
      addTearDown(() {
        c.dispose();
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      return c;
    }

    Widget host(TripController c, FakeClock clock) => MaterialApp(
      home: FlutterMap(
        options: MapOptions(
          initialCenter: LatLng(here.lat, here.lng),
          initialZoom: 17,
        ),
        children: [
          CircleLayer(circles: friendCircles(c, now: clock.now)),
          MarkerLayer(
            markers: [
              for (final pp in c.people.values)
                friendMarker(c, pp, 'Anna Bell', now: clock.now),
            ],
          ),
        ],
      ),
    );

    testWidgets('a friend: real age, arrow, circle, fading', (t) async {
      final clock = FakeClock();
      final c = await trip(t, clock);
      c.people[7] = PersonPos(7, here, clock.now, TransportKind.ble, 1)
        ..accuracyM = 30
        ..speedMps = 12
        ..headingDeg = 90;
      clock.advance(const Duration(seconds: 4));
      await t.pumpWidget(host(c, clock));
      expect(find.text('Anna Bell · 4 s'), findsOneWidget);
      expect(find.byKey(const Key('friendHeading7')), findsOneWidget);
      expect(friendCircles(c, now: clock.now).length, 1);
      var o = t.widget<Opacity>(
        find.descendant(
          of: find.byKey(const Key('friend7')),
          matching: find.byType(Opacity),
        ),
      );
      expect(o.opacity, 1);
      clock.advance(const Duration(minutes: 40));
      await t.pumpWidget(host(c, clock));
      expect(find.text('Anna Bell · 40 min'), findsOneWidget);
      o = t.widget<Opacity>(
        find.descendant(
          of: find.byKey(const Key('friend7')),
          matching: find.byType(Opacity),
        ),
      );
      expect(o.opacity, 0.45);
    });

    testWidgets('no arrow when still, no circle when sure', (t) async {
      final clock = FakeClock();
      final c = await trip(t, clock);
      c.people[7] = PersonPos(7, here, clock.now, TransportKind.lan, 1)
        ..accuracyM = 4
        ..speedMps = 0.2
        ..headingDeg = 10;
      await t.pumpWidget(host(c, clock));
      expect(find.byKey(const Key('friendHeading7')), findsNothing);
      expect(friendCircles(c, now: clock.now), isEmpty);
      expect(find.text('Anna Bell · 0 s'), findsOneWidget);
    });
  });
}
