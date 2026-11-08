// v2.6.12: Battery modes (Saver / Normal / Tracking): what each mode turns
// on and off, snapshot and exact restore, locked settings, the range test
// rules, the Tracking-on-battery suggestion, plain errors, saving, Settings
// search and the version.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/friendly_error.dart';
import 'package:walkie_talkie/trip/battery_mode.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart' show searchSettings;

import 'trip_integration_test.dart' show FakeHost, trip;

class Clock {
  DateTime now = DateTime(2026, 11, 6, 9, 0, 0);
  DateTime call() => now;
  void add(Duration d) => now = now.add(d);
}

/// saveTripSettings can be made to fail.
class SaveHost extends FakeHost {
  SaveHost(super.localId);
  Object? failWith;
  int saves = 0;
  @override
  Future<void> saveTripSettings() async {
    saves++;
    final e = failWith;
    if (e != null) throw e;
  }
}

List<String> ids(String q, {SettingsEnv env = const SettingsEnv()}) => [
  for (final e in searchSettings(q, env: env)) e.id,
];

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late Directory dir;
  late SaveHost host;
  late TripController t;
  late Clock clock;
  var made = false;

  Future<void> make({TripSettings? s}) async {
    dir = await Directory.systemTemp.createTemp('v2612');
    host = SaveHost(0x1234);
    clock = Clock();
    t = TripController(
      host: host,
      settings: s ?? TripSettings(),
      dir: dir,
      userAgent: 'test',
      clock: clock.call,
    )..warmDelay = const Duration(hours: 1);
    t.tiles.online = false;
    made = true;
    await t.start();
  }

  tearDown(() async {
    if (!made) return;
    made = false;
    t.dispose();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  ({bool share, bool range, bool warm}) values() => (
    share: t.settings.tripMode,
    range: t.range.logging,
    warm: t.settings.warmHome,
  );

  group('modes', () {
    test('Normal by default: nothing changes, nothing extra saved', () async {
      await make();
      expect(t.batteryMode, BatteryMode.normal);
      expect(t.settings.batterySnapshot, isNull);
      expect(t.settings.encode(), isNot(contains('"bm"')));
      expect(t.settings.encode(), isNot(contains('"bs"')));
      expect(t.range.controlledNote, isNull);
    });

    test('Saver: sharing, Range logging and precaching off', () async {
      await make(s: TripSettings(tripMode: true));
      await t.range.setLogging(true);
      expect(await t.setBatteryMode(BatteryMode.saver), isNull);
      await settle();
      expect(values(), (share: false, range: false, warm: false));
      expect(t.range.controlledNote, controlledNote);
      // Off screen with nothing else running: the phone's GPS is off.
      expect(t.locationInterval, isNull);
    });

    test('Saver: no live position or check-ins go out', () async {
      await make(s: TripSettings(tripMode: true, checkInMinutes: 2));
      await t.setBatteryMode(BatteryMode.saver);
      host.sent.clear();
      t.onFix(Fix(const GeoPoint(45.58, -122.29), clock.now));
      for (var i = 0; i < 5; i++) {
        clock.add(const Duration(minutes: 1));
        t.tick();
      }
      expect(host.sent.where((s) => s.msg is PosMsg), isEmpty);
    });

    test('Saver: still receives (a friend\'s position shows)', () async {
      await make();
      await t.setBatteryMode(BatteryMode.saver);
      host.peers = [];
      t.onTrip(trip(0x77, PosMsg(9, const GeoPoint(45.6, -122.3))));
      expect(t.people[0x77]?.pos.lat, closeTo(45.6, 1e-4));
    });

    test('Saver: SOS still works and sends the location', () async {
      await make();
      await t.setBatteryMode(BatteryMode.saver);
      t.onFix(Fix(const GeoPoint(45.58, -122.29), clock.now));
      host.sent.clear();
      await t.startSos();
      await settle();
      expect(host.sent.where((s) => s.msg is SosMsg), isNotEmpty);
      expect(t.sos.active, isNotNull);
      expect(t.locationInterval, const Duration(seconds: 5));
    });

    test('Saver: Keep home area ready does not run', () async {
      await make();
      await t.setBatteryMode(BatteryMode.saver);
      t.onWifi = () async => true;
      expect(await t.maybeWarmHome(), 0);
      expect(t.warmStatus, isNotNull);
    });

    test(
      'Tracking: sharing and Range logging on, GPS 10 s high accuracy',
      () async {
        await make();
        expect(await t.setBatteryMode(BatteryMode.tracking), isNull);
        await settle();
        expect(t.settings.tripMode, isTrue);
        expect(t.range.logging, isTrue);
        expect(host.locationStarts.last.interval, const Duration(seconds: 10));
        expect(host.locationStarts.last.highAccuracy, isTrue);
      },
    );

    test(
      'Tracking: pings 90 s on battery (60-120 kept), 30 s charging',
      () async {
        await make();
        await t.setBatteryMode(BatteryMode.tracking);
        expect(t.rangeLog.interval, const Duration(seconds: 90));
        await t.range.setPingSecs(120);
        expect(t.rangeLog.interval, const Duration(seconds: 120));
        await t.setPluggedIn(true);
        expect(t.rangeLog.interval, const Duration(seconds: 30));
      },
    );

    test('Location source is never changed by a mode', () async {
      await make(s: TripSettings(locationSource: 'radio'));
      for (final m in [BatteryMode.saver, BatteryMode.tracking]) {
        await t.setBatteryMode(m);
        expect(t.settings.locationSource, 'radio');
      }
      await t.setBatteryMode(BatteryMode.normal);
      expect(t.settings.locationSource, 'radio');
    });
  });

  group('snapshot and restore', () {
    test('Normal puts every combination back exactly', () async {
      await make();
      for (final m in [BatteryMode.saver, BatteryMode.tracking]) {
        for (var bits = 0; bits < 8; bits++) {
          final want = (
            share: bits & 1 != 0,
            range: bits & 2 != 0,
            warm: bits & 4 != 0,
          );
          await t.update((s) {
            s.tripMode = want.share;
            s.warmHome = want.warm;
          });
          await t.range.setLogging(want.range);
          await t.setBatteryMode(m);
          await settle();
          await t.setBatteryMode(BatteryMode.normal);
          await settle();
          expect(values(), want, reason: '${m.id} $bits');
          expect(t.settings.batterySnapshot, isNull);
        }
      }
    });

    test('Saver -> Tracking -> Normal: still your own values', () async {
      await make(s: TripSettings(tripMode: false, warmHome: true));
      await t.setBatteryMode(BatteryMode.saver);
      expect(t.settings.warmHome, isFalse);
      await t.setBatteryMode(BatteryMode.tracking);
      // Tracking does not control the precaching: yours again.
      expect(t.settings.warmHome, isTrue);
      await t.update((s) => s.warmHome = false); // free to change
      await t.setBatteryMode(BatteryMode.normal);
      await settle();
      expect(values(), (share: false, range: false, warm: false));
    });

    test('kept across a restart (saved in the Trip settings)', () async {
      await make(s: TripSettings(tripMode: true));
      await t.setBatteryMode(BatteryMode.saver);
      final again = TripSettings.decode(t.settings.encode());
      expect(again.batteryMode, BatteryMode.saver);
      expect(
        again.batterySnapshot,
        const BatterySnapshot(
          shareLocation: true,
          rangeLogging: false,
          warmHome: true,
        ),
      );
      expect(
        TripSettings.decode('{"bm":"bogus"}').batteryMode,
        BatteryMode.normal,
      );
    });
  });

  group('locked while a mode is on', () {
    test('a change to a controlled setting does not stick', () async {
      await make();
      await t.setBatteryMode(BatteryMode.saver);
      await t.update((s) => s.tripMode = true);
      expect(t.settings.tripMode, isFalse);
      await t.setBatteryMode(BatteryMode.tracking);
      await t.range.setLogging(false);
      await settle();
      expect(t.range.logging, isTrue);
      expect(t.range.controlledNote, controlledNote);
      await t.setBatteryMode(BatteryMode.normal);
      expect(t.range.controlledNote, isNull);
    });

    test('settings the mode does not control stay yours', () async {
      await make();
      await t.setBatteryMode(BatteryMode.tracking);
      await t.update((s) => s.checkInMinutes = 10);
      expect(t.settings.checkInMinutes, 10);
      await t.setBatteryMode(BatteryMode.normal);
      expect(t.settings.checkInMinutes, 10);
    });

    test('controls(): what each mode locks', () {
      expect(
        [for (final s in BatterySetting.values) controls(BatteryMode.saver, s)],
        [true, true, true],
      );
      expect(
        [
          for (final s in BatterySetting.values)
            controls(BatteryMode.tracking, s),
        ],
        [true, true, false],
      );
      expect(
        [
          for (final s in BatterySetting.values)
            controls(BatteryMode.normal, s),
        ],
        [false, false, false],
      );
    });
  });

  group('one-tap range test', () {
    test('Saver is refused while a test runs; nothing changes', () async {
      await make();
      await t.rangeRun.start();
      final e = await t.setBatteryMode(BatteryMode.saver);
      expect(e, isNotNull);
      expect(e!.message, contains('range test is running'));
      expect(e.fix, FixAction.stopRangeTest);
      expect(e.fix2, FixAction.useTrackingMode);
      expect(t.batteryMode, BatteryMode.normal);
      expect(t.range.logging, isTrue);
      await t.rangeRun.stop();
    });

    test('Tracking during a test: logging stays on after Stop', () async {
      await make();
      await t.rangeRun.start();
      await t.setBatteryMode(BatteryMode.tracking);
      await t.rangeRun.stop();
      await settle();
      expect(t.range.logging, isTrue);
      await t.setBatteryMode(BatteryMode.normal);
      await settle();
      expect(t.range.logging, isFalse, reason: 'your own: off');
    });

    test('Normal during a test: on until Stop, then your own', () async {
      await make();
      await t.setBatteryMode(BatteryMode.tracking);
      await t.rangeRun.start();
      await t.setBatteryMode(BatteryMode.normal);
      await settle();
      expect(t.range.logging, isTrue, reason: 'the test is running');
      expect(t.rangeRun.running, isTrue);
      await t.rangeRun.stop();
      await settle();
      expect(t.range.logging, isFalse);
    });

    test('the start sheet error in Saver', () {
      expect(rangeTestSaverError.message, contains('Saver'));
      expect(rangeTestSaverError.fix, FixAction.useTrackingMode);
      expect(rangeTestSaverError.fix2, FixAction.useNormalMode);
      expect(
        batteryModeProblem(want: BatteryMode.saver, rangeTestRunning: false),
        isNull,
      );
      expect(
        batteryModeProblem(want: BatteryMode.tracking, rangeTestRunning: true),
        isNull,
      );
    });
  });

  group('Tracking on battery for 3 hours', () {
    test('one gentle suggestion, not while charging', () async {
      await make();
      await t.setBatteryMode(BatteryMode.tracking);
      t.tick();
      clock.add(const Duration(hours: 2, minutes: 59));
      t.tick();
      expect(t.trackingNudge, isFalse);
      clock.add(const Duration(minutes: 2));
      t.tick();
      expect(t.trackingNudge, isTrue);
      expect(
        host.notes.where((n) => n.startsWith('Tracking is using battery')),
        hasLength(1),
      );
      t.tick();
      expect(
        host.notes.where((n) => n.startsWith('Tracking is using battery')),
        hasLength(1),
        reason: 'once',
      );
      t.dismissTrackingNudge();
      expect(t.trackingNudge, isFalse);
    });

    test('charging resets the clock', () async {
      await make();
      await t.setBatteryMode(BatteryMode.tracking);
      t.tick();
      clock.add(const Duration(hours: 2));
      t.tick();
      await t.setPluggedIn(true);
      t.tick();
      await t.setPluggedIn(false);
      t.tick();
      clock.add(const Duration(hours: 2));
      t.tick();
      expect(t.trackingNudge, isFalse);
      expect(host.notes, isEmpty);
    });

    test('never in Saver or Normal', () async {
      await make();
      for (final m in [BatteryMode.normal, BatteryMode.saver]) {
        await t.setBatteryMode(m);
        t.tick();
        clock.add(const Duration(hours: 5));
        t.tick();
        expect(t.trackingNudge, isFalse);
      }
      expect(host.notes, isEmpty);
    });
  });

  group('plain errors', () {
    test('could not save: nothing changes, Try again', () async {
      await make(s: TripSettings(tripMode: true));
      host.failWith = const FileSystemException(
        'Write failed',
        '/data/user/0/app/files/trip.json',
      );
      final e = await t.setBatteryMode(BatteryMode.saver);
      expect(e, isNotNull);
      expect(e!.message, contains('Could not change the Battery mode'));
      expect(e.fix, FixAction.retry);
      expect(t.batteryMode, BatteryMode.normal);
      expect(t.settings.tripMode, isTrue);
      expect(t.settings.batterySnapshot, isNull);
      host.failWith = null;
      expect(await t.setBatteryMode(BatteryMode.saver), isNull);
    });
  });

  group('Settings search', () {
    test('battery, saver, tracking and power mode find Battery mode', () {
      for (final q in ['battery', 'saver', 'tracking', 'power mode']) {
        expect(ids(q), contains('battery-mode'), reason: q);
      }
      expect(ids('battery mode').first, 'battery-mode');
      expect(ids('power mode').first, 'battery-mode');
      expect(ids('tracking').first, 'battery-mode');
    });

    test('not offered without the Trip map', () {
      expect(
        ids('battery mode', env: const SettingsEnv(hasTrip: false)),
        isNot(contains('battery-mode')),
      );
    });

    test('the entry has its anchor on the Settings sheet', () {
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      expect(home, contains("id: 'battery-mode'"));
      final e = settingsIndex.firstWhere((e) => e.id == 'battery-mode');
      expect(e.path, 'Settings › Battery');
      expect(e.label, 'Battery mode');
    });
  });

  test('version is 2.6.12+72 or later', () {
    final p = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'\nversion: 2\.6\.(\d+)\+(\d+)\n').firstMatch(p)!;
    final patch = int.parse(m.group(1)!);
    final build = int.parse(m.group(2)!);
    expect(
      patch > 12 || (patch == 12 && build >= 72),
      isTrue,
      reason: 'pubspec is ${m.group(0)}',
    );
  });
}
