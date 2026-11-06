// v2.6.10: one-tap range test (RangeRun on top of v2.5.9 Range logging):
// start / stop, live numbers, summary, CSV / GPX, auto-stop with a
// notification, resume after a restart, battery (same as Range logging),
// plain errors, Settings search, the version and the release script.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/friendly_error.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/range_logger.dart';
import 'package:walkie_talkie/trip/range_run.dart';
import 'package:walkie_talkie/trip/range_test.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart' show searchSettings;

import 'trip_integration_test.dart' show FakeHost;
import 'v259_range_log_test.dart' show FakeRadio, homePos;

class Clock {
  DateTime now = DateTime(2026, 11, 6, 9, 0, 0);
  DateTime call() => now;
  void add(Duration d) => now = now.add(d);
}

typedef Rig = ({
  RangeTest store,
  RangeLogger log,
  RangeRun run,
  FakeRadio radio,
  Clock clock,
  List<Fix?> fixes,
  List<RangeRunSummary> autoStops,
});

Directory tmp(String n) {
  final d = Directory.systemTemp.createTempSync(n);
  addTearDown(() {
    try {
      d.deleteSync(recursive: true);
    } catch (_) {}
  });
  return d;
}

Rig rig({Directory? dir, bool logging = false}) {
  final clock = Clock();
  final store = RangeTest(dir == null ? null : File('${dir.path}/r.json'));
  store.logging = logging;
  final fixes = <Fix?>[Fix(const GeoPoint(45.58, -122.29), clock.now)];
  final log = RangeLogger(
    store: store,
    fix: () => fixes.last,
    plugged: () => false,
    clock: clock.call,
    ackTimeout: const Duration(milliseconds: 40),
    firstPing: const Duration(hours: 1),
  );
  final radio = FakeRadio();
  log.bind(radio);
  final stops = <RangeRunSummary>[];
  final run = RangeRun(
    store: store,
    logger: log,
    file: dir == null ? null : File('${dir.path}/run.json'),
    clock: clock.call,
    homePos: (n) => radio.positionOf(n),
    onAutoStop: stops.add,
  );
  addTearDown(run.dispose);
  addTearDown(log.dispose);
  return (
    store: store,
    log: log,
    run: run,
    radio: radio,
    clock: clock,
    fixes: fixes,
    autoStops: stops,
  );
}

Future<void> ping(
  Rig r, {
  required bool answer,
  GeoPoint? at,
  double snr = 5.5,
  int hops = 0,
}) async {
  r.clock.add(const Duration(seconds: 90));
  r.fixes.add(Fix(at ?? r.fixes.last!.pos, r.clock.now));
  final f = r.log.pingNow();
  if (answer) {
    await Future<void>.delayed(Duration.zero);
    r.radio.ack(r.radio.lastId, snr: snr, hops: hops);
  }
  await f;
}

/// About 1.1 km, 2.2 km, 3.3 km north of home.
GeoPoint north(double km) => GeoPoint(homePos.lat + km / 111.2, homePos.lng);

void main() {
  group('start and stop', () {
    test(
      'one tap turns Range logging on against Skunk Ape by default',
      () async {
        final r = rig();
        expect(r.run.running, isFalse);
        expect(r.store.logging, isFalse);
        await r.run.start();
        expect(r.run.running, isTrue);
        expect(r.store.logging, isTrue);
        expect(r.store.homeNode, defaultRangeHomeNode);
        expect(r.radio.heardC.hasListener, isTrue, reason: 'logger listening');
      },
    );

    test('a picked home radio is used and kept', () async {
      final r = rig();
      await r.run.start(home: 0x1234abcd);
      expect(r.store.homeNode, 0x1234abcd);
      await r.run.stop();
      expect(r.store.homeNode, 0x1234abcd);
    });

    test('Stop puts Range logging back the way it was', () async {
      final off = rig();
      await off.run.start();
      await off.run.stop();
      expect(off.store.logging, isFalse, reason: 'was off before');
      expect(off.radio.heardC.hasListener, isFalse);

      final on = rig(logging: true);
      await on.run.start();
      await on.run.stop();
      expect(on.store.logging, isTrue, reason: 'was on before: stays on');
    });

    test('turning Range logging off on its page ends the run', () async {
      final r = rig();
      await r.run.start();
      await r.store.setLogging(false);
      await Future<void>.delayed(Duration.zero);
      expect(r.run.running, isFalse);
      expect(r.run.last, isNotNull);
    });

    test('start twice is one run; stop with none running is null', () async {
      final r = rig();
      expect(await r.run.stop(), isNull);
      await r.run.start();
      final t0 = r.run.startedAt;
      r.clock.add(const Duration(minutes: 1));
      await r.run.start();
      expect(r.run.startedAt, t0);
    });
  });

  group('live strip numbers', () {
    test(
      'elapsed, last reply, SNR, hops, distance, replies vs no reply',
      () async {
        final r = rig();
        await r.run.start();
        r.clock.add(const Duration(minutes: 2));
        expect(r.run.elapsed, const Duration(minutes: 2));
        await ping(r, answer: true, at: north(1), snr: 6.25, hops: 0);
        await ping(r, answer: true, at: north(2), snr: -3.5, hops: 1);
        await ping(r, answer: false, at: north(3));
        final l = r.run.live;
        expect(l.replies, 2);
        expect(l.noReplies, 1);
        expect(l.snr, -3.5);
        expect(l.hops, 1);
        expect(l.distM, closeTo(2000, 20));
        expect(l.lastReplyAt, isNotNull);
        expect(r.run.elapsed, const Duration(minutes: 6, seconds: 30));
      },
    );

    test('points from before the run are not counted', () async {
      final r = rig(logging: true);
      await ping(r, answer: true, at: north(5));
      r.clock.add(const Duration(seconds: 1));
      await r.run.start();
      expect(r.run.samples, isEmpty);
      expect(r.run.live.replies, 0);
    });
  });

  group('summary', () {
    test('furthest reply, best and worst SNR, connected %', () async {
      final r = rig();
      await r.run.start();
      await ping(r, answer: true, at: north(1), snr: 8);
      await ping(r, answer: true, at: north(3), snr: -12.25);
      await ping(r, answer: false, at: north(4));
      await ping(r, answer: false, at: north(4.5));
      await ping(r, answer: true, at: north(2), snr: 1);
      r.radio.packet(snr: 9.5); // heard packet: counts for SNR, not for %
      await Future<void>.delayed(Duration.zero);
      final s = (await r.run.stop())!;
      expect(s.replies, 3);
      expect(s.noReplies, 2);
      expect(s.heard, 1);
      expect(s.connectedPct, 60);
      expect(s.furthestReplyM, closeTo(3000, 30));
      expect(s.bestSnr, 9.5);
      expect(s.worstSnr, -12.25);
      expect(s.connects, 2, reason: 'connect, drop, connect again');
      expect(s.drops, 1);
      expect(s.homeName, 'Skunk Ape');
      expect(s.autoStopped, isFalse);
      expect(r.run.last, same(s));
    });

    test('no pings: connected % is null, nothing crashes', () async {
      final r = rig();
      await r.run.start();
      final s = (await r.run.stop())!;
      expect(s.connectedPct, isNull);
      expect(s.furthestReplyM, isNull);
      expect(s.toText(), contains('no pings sent'));
    });

    test('Copy summary text: plain, no keys, no exact home spot', () async {
      final r = rig();
      await r.run.start();
      await ping(r, answer: true, at: north(1.609344), snr: 4);
      r.clock.add(const Duration(minutes: 70));
      final s = (await r.run.stop())!;
      final txt = s.toText(imperial: true);
      expect(txt, contains('range test to Skunk Ape'));
      expect(txt, contains('1 h 11 min'));
      expect(txt, contains('Furthest reply: 1.0 mi'));
      expect(txt, contains('Best SNR: 4.0 dB'));
      expect(txt, contains('Connected: 100% (1 of 1 pings answered)'));
      expect(txt, isNot(contains(homePos.lat.toStringAsFixed(3))));
      expect(txt.toLowerCase(), isNot(contains('psk')));
      expect(txt.toLowerCase(), isNot(contains('key')));
      expect(txt, isNot(contains('http')));
    });

    test('summary survives a restart (Last range test)', () async {
      final d = tmp('rr');
      final a = rig(dir: d);
      await a.run.start();
      await ping(a, answer: true, at: north(2));
      final s = (await a.run.stop())!;
      final b = RangeRun(
        store: RangeTest(null),
        logger: a.log,
        file: File('${d.path}/run.json'),
      );
      addTearDown(b.dispose);
      await b.load();
      expect(b.running, isFalse);
      expect(b.last!.replies, 1);
      expect(b.last!.furthestReplyM, closeTo(s.furthestReplyM!, 0.5));
      expect(b.last!.startedAt, s.startedAt);
    });
  });

  group('exports', () {
    test(
      'CSV: the Range logging columns plus distance, this run only',
      () async {
        final r = rig(logging: true);
        await ping(r, answer: true, at: north(9)); // before the run
        r.clock.add(const Duration(seconds: 1));
        await r.run.start();
        await ping(r, answer: true, at: north(1), snr: 5);
        await ping(r, answer: false, at: north(2));
        final s = (await r.run.stop())!;
        final lines = r.run.csvOf(s).trim().split('\n');
        expect(lines.first, '${RangeSample.csvHeader},dist_m');
        expect(lines.length, 3);
        expect(lines[1], contains(',reply,'));
        expect(lines[2], contains(',no_reply,'));
        expect(int.parse(lines[1].split(',').last), closeTo(1000, 15));
      },
    );

    test(
      'GPX: a track plus connect / drop / no-reply / furthest waypoints',
      () async {
        final r = rig();
        await r.run.start();
        await ping(r, answer: true, at: north(1));
        await ping(r, answer: false, at: north(2));
        await ping(r, answer: false, at: north(2.5));
        final s = (await r.run.stop())!;
        final g = r.run.gpxOf(s);
        expect(g, startsWith('<?xml'));
        expect(g, contains('<gpx version="1.1"'));
        expect('<trkpt'.allMatches(g).length, 3);
        expect(g, contains('<type>connect</type>'));
        expect(g, contains('<type>drop</type>'));
        expect('<type>no_reply</type>'.allMatches(g).length, 2);
        expect(g, contains('<type>furthest</type>'));
        expect(g, contains('<time>'));
      },
    );
  });

  group('time limit', () {
    test('default 3 h, configurable, kept', () async {
      final d = tmp('rr');
      final r = rig(dir: d);
      expect(r.run.maxMinutes, 180);
      expect(RangeRun.defaultMaxMinutes, 180);
      await r.run.setMaxMinutes(60);
      final b = RangeRun(
        store: RangeTest(null),
        logger: r.log,
        file: File('${d.path}/run.json'),
      );
      addTearDown(b.dispose);
      await b.load();
      expect(b.maxMinutes, 60);
      await b.setMaxMinutes(1);
      expect(b.maxMinutes, 15, reason: 'clamped');
      await b.setMaxMinutes(100000);
      expect(b.maxMinutes, 720);
    });

    test('stops by itself, says so, and logging goes back off', () async {
      final r = rig();
      await r.run.start();
      expect(r.run.stopsAt, r.clock.now.add(const Duration(hours: 3)));
      await ping(r, answer: true, at: north(1));
      r.clock.add(const Duration(hours: 3, minutes: 5));
      await r.run.autoStopNow();
      expect(r.run.running, isFalse);
      expect(r.store.logging, isFalse);
      final s = r.autoStops.single;
      expect(s.autoStopped, isTrue);
      expect(s.duration, const Duration(hours: 3), reason: 'capped at limit');
    });

    test('a run found due on start-up stops at once', () async {
      // A due run found on load stops at once.
      final d = tmp('rr');
      final a = rig(dir: d);
      await a.run.setMaxMinutes(15);
      await a.run.start();
      final b = RangeRun(
        store: a.store,
        logger: a.log,
        file: File('${d.path}/run.json'),
        clock: () => a.clock.now.add(const Duration(minutes: 20)),
      );
      final stops = <RangeRunSummary>[];
      b.onAutoStop = stops.add;
      addTearDown(b.dispose);
      await b.load();
      expect(b.running, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(b.running, isFalse);
      expect(stops.single.autoStopped, isTrue);
    });

    test('a run carries on after the app restarts', () async {
      final d = tmp('rr');
      final a = rig(dir: d);
      await a.run.start();
      final store2 = RangeTest(File('${d.path}/r.json'));
      await store2.load();
      final b = RangeRun(
        store: store2,
        logger: a.log,
        file: File('${d.path}/run.json'),
        clock: a.clock.call,
      );
      addTearDown(b.dispose);
      await b.load();
      expect(b.running, isTrue);
      expect(b.startedAt, a.run.startedAt);
      expect(store2.logging, isTrue);
    });
  });

  group('on the Trip controller', () {
    late Directory dir;
    late FakeHost host;
    late TripController t;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trip2610');
      host = FakeHost(0x1234);
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: dir,
        userAgent: 'test',
      );
      t.tiles.online = false;
      await t.start();
    });
    tearDown(() async {
      t.dispose();
      await dir.delete(recursive: true);
    });

    test(
      'battery: the same GPS as Range logging (10 s, high accuracy)',
      () async {
        await t.rangeRun.start();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(t.range.logging, isTrue);
        expect(
          host.locationStarts.last.interval,
          TripController.rangeGpsInterval,
        );
        expect(host.locationStarts.last.highAccuracy, isTrue);
        expect(TripController.rangeGpsInterval, const Duration(seconds: 10));
        await t.rangeRun.stop();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(t.range.logging, isFalse);
      },
    );

    test('the auto-stop notification says what it found', () async {
      await t.rangeRun.start();
      await t.rangeRun.autoStopNow();
      expect(
        host.notes.single,
        startsWith('Range test stopped: Stopped by itself after'),
      );
      expect(host.notes.single, contains('No pings were sent.'));
      expect(host.notes.single, contains('Open the Trip map for the summary.'));
    });

    test(
      'ping pace is unchanged: 30 s plugged, 60-120 s (90) on battery',
      () async {
        expect(t.rangeLog.interval, const Duration(seconds: 90));
        await t.setPluggedIn(true);
        expect(t.rangeLog.interval, const Duration(seconds: 30));
      },
    );
  });

  group('plain errors', () {
    test('no radio: Connect radio', () {
      final e = rangeTestProblem(radioReady: false)!;
      expect(e.message, contains('needs your radio connected'));
      expect(e.fix, FixAction.connectRadio);
      expect(e.cause, ErrorCause.radioNotConnected);
      final e2 = rangeTestProblem(radioReady: false, running: true)!;
      expect(e2.message, contains('carries on when the radio is back'));
    });

    test('no GPS fix while running: Turn on location', () {
      final e = rangeTestProblem(
        radioReady: true,
        running: true,
        waitingForGps: true,
      )!;
      expect(e.message, contains('No GPS fix'));
      expect(e.fix, FixAction.turnOnLocation);
      expect(e.fix2, FixAction.allowLocation);
    });

    test('all good: null', () {
      expect(rangeTestProblem(radioReady: true), isNull);
      expect(rangeTestProblem(radioReady: true, running: true), isNull);
    });

    test('the logger says when it waits for GPS', () async {
      final r = rig();
      await r.run.start();
      r.fixes.add(null);
      await r.log.pingNow();
      expect(r.log.waitingForGps, isTrue);
      expect(r.radio.pings, isEmpty, reason: 'no ping without a fix');
      await ping(r, answer: true, at: north(1));
      expect(r.log.waitingForGps, isFalse);
    });
  });

  group('Settings search', () {
    List<String> ids(String q) => [for (final e in searchSettings(q)) e.id];

    test('range test, coverage and ping test find One-tap range test', () {
      expect(ids('range test'), contains('range-run'));
      expect(ids('coverage'), contains('range-run'));
      expect(ids('ping test'), contains('range-run'));
      expect(ids('range test').first, 'range-run');
    });

    test('the entry has its anchor on the Range test page', () {
      final page = File('lib/ui/range_test_ui.dart').readAsStringSync();
      expect(page, contains("SettingAnchor(\n        id: 'range-run'"));
      final e = settingsIndex.firstWhere((e) => e.id == 'range-run');
      expect(e.home, SettingsHome.trip);
      expect(e.path, 'Trip map › Range test');
      expect(page, contains("Text('${e.label}')"));
    });

    test('Range logging and markers are still found', () {
      expect(ids('range'), containsAll(['range-logging', 'range-markers']));
    });
  });

  group('version and release', () {
    test('pubspec is 2.6.10+70 or later (versionCode 2070+)', () {
      final p = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'\nversion: 2\.6\.(\d+)\+(\d+)\n').firstMatch(p)!;
      expect(int.parse(m.group(1)!), greaterThanOrEqualTo(10));
      expect(int.parse(m.group(2)!), greaterThanOrEqualTo(70));
      expect(2000 + 70, 2070);
    });

    test('release.ps1 takes a two-digit patch (2.6.10)', () {
      final s = File('tool/release.ps1').readAsStringSync();
      final m = RegExp(r"-notmatch '([^']+)'").firstMatch(s)!;
      final re = RegExp(m.group(1)!);
      expect(re.hasMatch('2.6.10'), isTrue);
      expect(re.hasMatch('2.6.9'), isTrue);
      expect(re.hasMatch('2.6'), isFalse);
      expect(s, contains(r'version: $Version+$Build'));
      expect(s, contains(r'2000 + $Build'));
    });

    test('README describes the one-tap range test', () {
      final r = File('README.md').readAsStringSync();
      expect(r, contains('One-tap range test'));
      expect(r, contains('2.6.10'));
    });
  });

  test('timers: the strip ticker is the only new timer (UI only)', () {
    final src = File('lib/trip/range_run.dart').readAsStringSync();
    expect('Timer('.allMatches(src).length, 1, reason: 'one auto-stop timer');
    expect(src, isNot(contains('Timer.periodic')));
    unawaited(Future<void>.value());
  });
}
