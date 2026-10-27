// v1.9.5: hold-to-mute and programmable quiet hours.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/quiet.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/ui/quiet_widgets.dart';

// 2026-10-26 is a Monday.
DateTime mon(int h, [int m = 0]) => DateTime(2026, 10, 26, h, m);
DateTime day(int d, int h, [int m = 0]) => DateTime(2026, 10, 26 + d, h, m);

void main() {
  group('quiet hours schedule', () {
    test('daytime span', () {
      final s = QuietSchedule(start: 13 * 60, end: 15 * 60);
      expect(s.covers(mon(12, 59)), isFalse);
      expect(s.covers(mon(13)), isTrue);
      expect(s.covers(mon(14, 59)), isTrue);
      expect(s.covers(mon(15)), isFalse);
      expect(s.endAfter(mon(14)), mon(15));
    });

    test('overnight 10 PM - 7 AM works across midnight', () {
      final s = QuietSchedule(start: 22 * 60, end: 7 * 60);
      expect(s.covers(mon(21, 59)), isFalse);
      expect(s.covers(mon(22)), isTrue);
      expect(s.covers(mon(23, 30)), isTrue);
      expect(s.covers(day(1, 0, 10)), isTrue);
      expect(s.covers(day(1, 6, 59)), isTrue);
      expect(s.covers(day(1, 7)), isFalse);
      expect(s.endAfter(mon(23)), day(1, 7));
      expect(s.endAfter(day(1, 3)), day(1, 7));
    });

    test('days are the nights it starts on', () {
      // Friday nights only (Fri = 5): Saturday morning stays quiet.
      final s = QuietSchedule(start: 22 * 60, end: 7 * 60, days: {5});
      expect(s.covers(day(4, 23)), isTrue); // Fri 23:00
      expect(s.covers(day(5, 6)), isTrue); // Sat 06:00
      expect(s.covers(day(5, 23)), isFalse); // Sat 23:00
      expect(s.covers(day(6, 6)), isFalse); // Sun 06:00
      expect(s.covers(day(3, 6)), isFalse); // Thu 06:00
    });

    test('a switched-off schedule does nothing', () {
      final s = QuietSchedule(start: 0, end: 23 * 60, enabled: false);
      expect(s.covers(mon(12)), isFalse);
    });

    test('back-to-back schedules: "until" follows the chain', () {
      var now = mon(23);
      final q = QuietHours(
        schedules: [
          QuietSchedule(start: 22 * 60, end: 7 * 60),
          QuietSchedule(start: 7 * 60, end: 8 * 60, days: {2}),
        ],
        clock: () => now,
      );
      expect(q.inQuietHours, isTrue);
      expect(q.quietUntil, day(1, 8));
      expect(q.statusText(QuietHours.clockFor24), 'Quiet hours until 8:00');
      now = day(1, 8);
      expect(q.silenced, isFalse);
      expect(q.statusText(QuietHours.clockFor24), isNull);
    });
  });

  group('mute', () {
    test('v1.9.7: mute is on/off, no time limit, until unmuted', () {
      var now = mon(15);
      final q = QuietHours(clock: () => now);
      expect(q.silenced, isFalse);
      q.mute();
      expect(q.muted, isTrue);
      expect(q.statusText(QuietHours.clockFor24), 'Muted');
      now = mon(18);
      expect(q.muted, isTrue);
      now = day(3, 9);
      expect(q.muted, isTrue);
      expect(q.statusText(QuietHours.clockFor24), 'Muted');
      q.unmute();
      expect(q.silenced, isFalse);
    });
  });

  group('let urgent rings through', () {
    late DateTime now;
    late QuietHours q;
    setUp(() {
      now = mon(23);
      q = QuietHours(clock: () => now)..mute();
    });

    test('not silenced: every ring sounds', () {
      q.unmute();
      expect(q.ringSounds(from: 1, ringId: 1), isTrue);
    });

    test('urgent rings and SOS get through', () {
      expect(q.ringSounds(from: 1, ringId: 1, urgent: true), isTrue);
    });

    test('a second ring from the same person within 2 min', () {
      expect(q.ringSounds(from: 1, ringId: 10), isFalse);
      // Re-sends of the same ring do not count.
      expect(q.ringSounds(from: 1, ringId: 10), isFalse);
      // Someone else ringing once does not count either.
      expect(q.ringSounds(from: 2, ringId: 11), isFalse);
      now = now.add(const Duration(seconds: 90));
      expect(q.ringSounds(from: 1, ringId: 12), isTrue);
      now = now.add(const Duration(minutes: 5));
      expect(q.ringSounds(from: 1, ringId: 13), isFalse);
    });

    test('"Always allow" people', () {
      q.alwaysAllow.add(7);
      expect(q.ringSounds(from: 7, ringId: 1), isTrue);
      expect(q.allowRing(from: 7, ringId: 2), QuietBypass.alwaysAllow);
    });

    test('switched off: nothing gets through', () {
      q.letUrgentThrough = false;
      q.alwaysAllow.add(7);
      expect(q.ringSounds(from: 7, ringId: 1, urgent: true), isFalse);
      expect(q.ringSounds(from: 1, ringId: 2), isFalse);
      expect(q.ringSounds(from: 1, ringId: 3), isFalse);
    });

    test('default is on', () {
      expect(QuietHours().letUrgentThrough, isTrue);
      expect(QuietHours.decode(null).letUrgentThrough, isTrue);
    });
  });

  group('persistence', () {
    test('encode / decode round trip', () {
      final q = QuietHours(
        muted: true,
        schedules: [
          QuietSchedule(start: 22 * 60, end: 7 * 60, days: {1, 2, 3}),
          QuietSchedule(start: 60, end: 120, enabled: false),
        ],
        letUrgentThrough: false,
        alwaysAllow: {0xBEEF},
      );
      final r = QuietHours.decode(q.encode());
      expect(r.muted, isTrue);
      expect(r.schedules.length, 2);
      expect(r.schedules[0].days, {1, 2, 3});
      expect(r.schedules[0].start, 22 * 60);
      expect(r.schedules[1].enabled, isFalse);
      expect(r.letUrgentThrough, isFalse);
      expect(r.alwaysAllow, {0xBEEF});
      expect(QuietHours.decode('not json').schedules, isEmpty);
    });

    test('survives an app restart (settings store)', () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsSettingsStore();
      final s = await store.load(defaultChannel: 1);
      expect(s.quiet.silenced, isFalse);
      expect(s.shareRadio, isTrue);
      s.quiet.mute();
      s.quiet.schedules.add(QuietSchedule(start: 22 * 60, end: 7 * 60));
      s.shareRadio = false;
      await store.save(s);
      final again = await store.load(defaultChannel: 1);
      expect(again.quiet.muted, isTrue);
      expect(again.quiet.schedules.single.label, '22:00–7:00 · Every day');
      expect(again.shareRadio, isFalse);
    });
  });

  group('mute button', () {
    Future<(List<String>, StateSetter?)> pump(
      WidgetTester t, {
      required bool muted,
      required List<String> log,
    }) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MuteButton(
                muted: muted,
                onMute: () => log.add('mute'),
                onUnmute: () => log.add('unmute'),
              ),
            ),
          ),
        ),
      );
      return (log, null);
    }

    testWidgets('a tap only shows "Hold to mute"', (t) async {
      final log = <String>[];
      await pump(t, muted: false, log: log);
      await t.tap(find.byKey(const Key('muteButton')));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Hold to mute'), findsOneWidget);
      expect(log, isEmpty);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('holding about a second mutes, with a progress ring', (
      t,
    ) async {
      final log = <String>[];
      await pump(t, muted: false, log: log);
      final g = await t.startGesture(
        t.getCenter(find.byKey(const Key('muteButton'))),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      final ring = t.widget<CircularProgressIndicator>(
        find.byKey(const Key('muteButtonProgress')),
      );
      expect(ring.value, closeTo(0.5, 0.1));
      expect(log, isEmpty);
      await t.pump(const Duration(milliseconds: 600));
      expect(log, ['mute']);
      await g.up();
      await t.pump();
      expect(find.text('Hold to mute'), findsNothing);
    });

    testWidgets('letting go early does not mute', (t) async {
      final log = <String>[];
      await pump(t, muted: false, log: log);
      final g = await t.startGesture(
        t.getCenter(find.byKey(const Key('muteButton'))),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      await g.up();
      await t.pump(const Duration(seconds: 1));
      expect(log, isEmpty);
    });

    testWidgets('v1.9.7 muted: a tap only shows "Hold to unmute"', (t) async {
      final log = <String>[];
      await pump(t, muted: true, log: log);
      expect(find.text('Muted · hold to unmute'), findsOneWidget);
      await t.tap(find.byKey(const Key('muteButton')));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Hold to unmute'), findsOneWidget);
      expect(log, isEmpty);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('v1.9.7 muted: holding about a second unmutes', (t) async {
      final log = <String>[];
      await pump(t, muted: true, log: log);
      final g = await t.startGesture(
        t.getCenter(find.byKey(const Key('muteButton'))),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      final ring = t.widget<CircularProgressIndicator>(
        find.byKey(const Key('muteButtonProgress')),
      );
      expect(ring.value, closeTo(0.5, 0.1));
      expect(log, isEmpty);
      await t.pump(const Duration(milliseconds: 600));
      expect(log, ['unmute']);
      await g.up();
      await t.pump();
    });
  });
}
