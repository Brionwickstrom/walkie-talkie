// v2.6.10: one-tap range test screens: the start sheet, the live strip, the
// summary (Copy summary, Export CSV / GPX), the line on Talk's connection
// sheet, the Range test page and the buttons on the real app.
//   V2610_SHOTS=/workspace flutter test test/v2610_range_run_ui_test.dart
// writes /workspace/v2610_*.png (example data; RANGE_TILES=dir real tiles).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walkie_talkie/app/friendly_error.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart' show RadioState;
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/range_logger.dart';
import 'package:walkie_talkie/trip/range_run.dart';
import 'package:walkie_talkie/trip/range_test.dart';
import 'package:walkie_talkie/trip/trip_controller.dart' show Fix;
import 'package:walkie_talkie/ui/connection_health.dart';
import 'package:walkie_talkie/ui/range_run_ui.dart';
import 'package:walkie_talkie/ui/range_test_ui.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v259_range_log_test.dart' show FakeRadio, home, homePos;

class Clock {
  DateTime now = DateTime(2026, 11, 6, 9, 0, 0);
  DateTime call() => now;
  void add(Duration d) => now = now.add(d);
}

class Rig {
  Rig({bool ready = true}) : radioReady = ready {
    store = RangeTest(null);
    log = RangeLogger(
      store: store,
      fix: () => fixes.last,
      plugged: () => false,
      clock: clock.call,
      ackTimeout: const Duration(milliseconds: 40),
      firstPing: const Duration(hours: 1),
    );
    log.bind(radio);
    run = RangeRun(
      store: store,
      logger: log,
      clock: clock.call,
      homePos: radio.positionOf,
    );
  }
  final clock = Clock();
  final radio = FakeRadio();
  late final RangeTest store;
  late final RangeLogger log;
  late final RangeRun run;
  late final List<Fix?> fixes = [Fix(homePos, clock.now)];
  bool radioReady;
  final fixes0 = <FixAction>[];
  final shared = <({String path, String mime})>[];
  bool shareOk = true;
  Directory? dir;

  RangeRunActions actions() => RangeRunActions(
    run: run,
    logger: log,
    radioReady: () => radioReady,
    homeChoices: () => [
      (num: home, name: 'Skunk Ape'),
      (num: 0x0aa11bb2, name: 'Yowie'),
    ],
    onFix: fixes0.add,
    exportDir: dir,
    share: (p, m, _) async {
      shared.add((path: p, mime: m));
      return shareOk;
    },
  );

  /// Example data: a drive north-east of home, replies getting weaker,
  /// then no reply at the edge.
  Future<void> drive({int n = 8}) async {
    for (var i = 0; i < n; i++) {
      clock.add(const Duration(seconds: 90));
      final p = GeoPoint(homePos.lat + 0.004 * i, homePos.lng + 0.005 * i);
      fixes.add(Fix(p, clock.now));
      final ok = i < n - 2;
      final f = log.pingNow();
      if (ok) {
        await Future<void>.delayed(Duration.zero);
        radio.ack(radio.lastId, snr: 8.0 - 2.75 * i, hops: i > 3 ? 1 : 0);
      }
      await f;
    }
  }

  /// Stops every timer (tests may not leave one running).
  void close() {
    run.dispose();
    log.dispose();
  }
}

/// Example data: on the relay, Bluetooth radio, Skunk Ape heard 2 min ago.
ConnectionHealth exampleHealth() {
  final now = DateTime(2026, 11, 6, 9);
  return ConnectionHealth.from(
    now: now,
    bestKind: TransportKind.internet,
    internet: TransportStatus.running,
    internetText: 'Home relay',
    radio: RadioHealth(
      paired: true,
      state: RadioState.ready,
      link: RadioLinkKind.bluetooth,
      homeName: 'Skunk Ape',
      homeHeard: now.subtract(const Duration(minutes: 2)),
      homeSnr: 5.75,
      homeRssi: -88,
      homeHops: 0,
    ),
  );
}

Widget app(Widget body) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
  home: Scaffold(body: body),
);

String? clip;
void mockClipboard(WidgetTester t) {
  clip = null;
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        clip = (call.arguments as Map)['text'] as String?;
      }
      if (call.method == 'Clipboard.getData') return {'text': clip};
      return null;
    },
  );
  addTearDown(
    () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

Future<void> openStart(WidgetTester t, Rig r) async {
  await t.pumpWidget(
    app(
      Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            key: const Key('go'),
            onPressed: () => rangeRunTap(ctx, r.actions()),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const Key('go')));
  await t.pumpAndSettle();
}

Future<void> done(WidgetTester t, Rig r) async {
  await t.pumpWidget(const SizedBox());
  r.close();
  imageCache
    ..clear()
    ..clearLiveImages();
  await t.pump(const Duration(seconds: 2));
}

void main() {
  setUpAll(loadFonts);

  group('start sheet', () {
    testWidgets('Skunk Ape by default, 3 h, battery note, Start starts', (
      t,
    ) async {
      final r = Rig();
      await openStart(t, r);
      expect(find.byKey(const Key('rangeStartSheet')), findsOneWidget);
      expect(find.text('Skunk Ape (!0b4f84fb)'), findsOneWidget);
      expect(find.text('3 h'), findsOneWidget);
      final note = t.widget<Text>(find.byKey(const Key('rangeStartBattery')));
      expect(note.data, contains('same as Range logging'));
      expect(note.data, contains('high-accuracy GPS every 10 s'));
      expect(note.data, contains('every 90 s'));
      expect(find.byKey(const Key('fe-view')), findsNothing);
      await t.tap(find.byKey(const Key('rangeStartGo')));
      await t.pumpAndSettle();
      expect(r.run.running, isTrue);
      expect(r.store.logging, isTrue);
      expect(r.store.homeNode, home);
      expect(r.run.maxMinutes, 180);
      await done(t, r);
    });

    testWidgets('pick Yowie and 1 h', (t) async {
      final r = Rig();
      await openStart(t, r);
      await t.tap(find.byKey(const Key('rangeStartHome')));
      await t.pumpAndSettle();
      await t.tap(find.text('Yowie (!0aa11bb2)').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('rangeStartMax')));
      await t.pumpAndSettle();
      await t.tap(find.text('1 h').last);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('rangeStartGo')));
      await t.pumpAndSettle();
      expect(r.store.homeNode, 0x0aa11bb2);
      expect(r.run.maxMinutes, 60);
      await done(t, r);
    });

    testWidgets('no radio: plain error, Connect radio, Start disabled', (
      t,
    ) async {
      final r = Rig(ready: false);
      await openStart(t, r);
      expect(find.textContaining('needs your radio connected'), findsOneWidget);
      final go = t.widget<FilledButton>(
        find.ancestor(
          of: find.text('Start range test'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(go.onPressed, isNull);
      await t.tap(find.text('Connect radio'));
      await t.pumpAndSettle();
      expect(r.fixes0, [FixAction.connectRadio]);
      expect(r.run.running, isFalse);
      await done(t, r);
    });
  });

  group('live strip', () {
    testWidgets('elapsed, last reply, SNR, hops, distance, counts, GPS flag', (
      t,
    ) async {
      final r = Rig();
      await r.run.start();
      await t.runAsync(() => r.drive(n: 5));
      await t.pumpWidget(app(RangeRunStrip(actions: r.actions())));
      expect(find.byKey(const Key('rangeRunStrip')), findsOneWidget);
      expect(
        find.textContaining('Range test · 07:30 · Skunk Ape'),
        findsOneWidget,
      );
      final reply = t.widget<Text>(find.byKey(const Key('rangeRunReply')));
      expect(reply.data, contains('Last reply 9:04:30 AM'));
      expect(reply.data, contains('SNR 2.5 dB'));
      expect(reply.data, contains('Direct (no relays)'));
      expect(reply.data, contains(' mi'));
      expect(find.text('3 replies · 2 no reply'), findsOneWidget);
      expect(find.text('High-accuracy GPS on'), findsOneWidget);
      r.clock.add(const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('07:35'), findsOneWidget, reason: 'ticks');
      await done(t, r);
    });

    testWidgets('no GPS: plain error with Turn on location', (t) async {
      final r = Rig();
      await r.run.start();
      r.fixes.add(null);
      await r.log.pingNow();
      await t.pumpWidget(app(RangeRunStrip(actions: r.actions())));
      expect(find.byKey(const Key('rangeRunProblem')), findsOneWidget);
      await t.tap(find.byKey(const Key('rangeRunFix')));
      expect(r.fixes0, [FixAction.turnOnLocation]);
      await done(t, r);
    });

    testWidgets('Stop ends the run and shows the summary', (t) async {
      final r = Rig();
      mockClipboard(t);
      await r.run.start();
      await t.runAsync(() => r.drive());
      await t.pumpWidget(app(RangeRunStrip(actions: r.actions())));
      await t.tap(find.byKey(const Key('rangeRunStop')));
      await t.pumpAndSettle();
      expect(r.run.running, isFalse);
      expect(r.store.logging, isFalse);
      expect(find.byKey(const Key('rangeSummary')), findsOneWidget);
      String v(String k) => t.widget<Text>(find.byKey(Key(k))).data!;
      expect(v('rangeSumPct'), '75% (6 of 8 pings)');
      expect(v('rangeSumBest'), '8.0 dB');
      expect(v('rangeSumWorst'), '-5.75 dB');
      expect(v('rangeSumFar'), endsWith(' mi'));
      await t.tap(find.byKey(const Key('rangeCopySummary')));
      await t.pump();
      expect(clip, contains('Stalkie Talkie range test to Skunk Ape'));
      expect(clip, contains('Connected: 75%'));
      await done(t, r);
    });
  });

  group('exports', () {
    testWidgets('Export CSV and GPX share files; no share sheet copies', (
      t,
    ) async {
      final r = Rig();
      r.dir = Directory.systemTemp.createTempSync('rr_ui');
      addTearDown(() => r.dir!.deleteSync(recursive: true));
      mockClipboard(t);
      await r.run.start();
      await t.runAsync(() => r.drive(n: 4));
      final s = (await r.run.stop())!;
      await t.pumpWidget(
        app(
          SingleChildScrollView(
            child: RangeSummaryView(actions: r.actions(), summary: s),
          ),
        ),
      );
      Future<void> tapAndWait(String k) async {
        await t.tap(find.byKey(Key(k)));
        for (var i = 0; i < 4; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await t.pump();
        }
      }

      await tapAndWait('rangeExportRunCsv');
      expect(r.shared.last.mime, 'text/csv');
      expect(r.shared.last.path, endsWith('.csv'));
      final csv = await t.runAsync(
        () => File(r.shared.last.path).readAsString(),
      );
      expect(csv, startsWith('${RangeSample.csvHeader},dist_m'));
      await tapAndWait('rangeExportRunGpx');
      expect(r.shared.last.mime, 'application/gpx+xml');
      final gpx = await t.runAsync(
        () => File(r.shared.last.path).readAsString(),
      );
      expect(gpx, contains('<trkpt'));
      r.shareOk = false;
      await tapAndWait('rangeExportRunGpx');
      expect(clip, startsWith('<?xml'));
      expect(find.textContaining('Copied it instead'), findsOneWidget);
      await done(t, r);
    });
  });

  group('connection sheet on Talk', () {
    testWidgets('Range test to Skunk Ape · Start; running · Stop', (t) async {
      var taps = 0;
      Widget sheet(bool running) => app(
        SingleChildScrollView(
          child: ConnectionHealthSheet(
            health: exampleHealth(),
            rangeTest: RangeRunLine(
              running: running,
              homeName: 'Skunk Ape',
              elapsed: const Duration(minutes: 12),
              onTap: () => taps++,
            ),
          ),
        ),
      );
      await t.pumpWidget(sheet(false));
      expect(find.text('Range test to Skunk Ape'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);
      await t.tap(find.byKey(const Key('connection-range-test-go')));
      expect(taps, 1);
      await t.pumpWidget(sheet(true));
      expect(find.text('Range test running · 12 min'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      await t.tap(find.byKey(const Key('connection-range-test')));
      expect(taps, 2);
    });

    testWidgets('the real Talk sheet shows the line; the Trip map the button', (
      t,
    ) async {
      phone(t, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const Key('connection-chip')));
      await settle(t);
      expect(find.byKey(const Key('connection-sheet')), findsOneWidget);
      if (c.trip != null) {
        expect(find.byKey(const Key('connection-range-test')), findsOneWidget);
        expect(find.text('Range test to Skunk Ape'), findsOneWidget);
      } else {
        // No Trip map in this test build: no line (and nothing breaks).
        expect(find.byKey(const Key('connection-range-test')), findsNothing);
      }
      await finish(t);
    });
  });

  group('Range test page', () {
    testWidgets('One-tap range test tile, Start / Stop, Last range test', (
      t,
    ) async {
      final r = Rig();
      await t.pumpWidget(
        MaterialApp(
          home: RangeTestPage(
            range: r.store,
            logger: r.log,
            runActions: r.actions(),
          ),
        ),
      );
      expect(find.text('One-tap range test'), findsOneWidget);
      expect(
        find.textContaining('Stops by itself after 3 h 00 min'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('rangeRunLast')), findsNothing);
      await t.tap(find.byKey(const Key('rangeRunTileGo')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('rangeStartGo')));
      await t.pumpAndSettle();
      expect(r.run.running, isTrue);
      expect(find.textContaining('Running for'), findsOneWidget);
      // Range logging below shows it is on.
      expect(
        t.widget<SwitchListTile>(find.byKey(const Key('rangeLogging'))).value,
        isTrue,
      );
      await t.tap(find.byKey(const Key('rangeRunTileGo')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rangeSummary')), findsOneWidget);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rangeRunLast')), findsOneWidget);
      await done(t, r);
    });

    testWidgets('without runActions the page is as before', (t) async {
      final r = Rig();
      await t.pumpWidget(
        MaterialApp(
          home: RangeTestPage(range: r.store, logger: r.log),
        ),
      );
      expect(find.text('One-tap range test'), findsNothing);
      expect(find.text('Range logging'), findsOneWidget);
      await done(t, r);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V2610_SHOTS'];
    if (dir == null) return;
    final tiles = Platform.environment['RANGE_TILES'];

    Future<void> shot(WidgetTester t, String name) async {
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 3);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v2610_$name.png')
            .writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    void size(WidgetTester t, double h) {
      t.view.physicalSize = Size(360, h) * 3;
      t.view.devicePixelRatio = 3;
      t.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 16 * 3);
      addTearDown(t.view.reset);
    }

    Widget label() => Positioned(
      right: 8,
      bottom: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.deepOrange,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          'EXAMPLE DATA',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );

    Widget framed(Widget child) => RepaintBoundary(
      key: const Key('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
        home: Scaffold(
          body: SafeArea(
            child: Stack(fit: StackFit.expand, children: [child, label()]),
          ),
        ),
      ),
    );

    testWidgets('trip map with the live strip', (t) async {
      size(t, 720);
      final r = Rig();
      await r.run.start();
      await t.runAsync(() => r.drive(n: 10));
      if (tiles != null) {
        // Decode the tiles first (real time), so the map shows them.
        await t.pumpWidget(framed(const SizedBox()));
        final ctx = t.element(find.byType(Scaffold));
        await t.runAsync(() async {
          for (final f in Directory(tiles).listSync().whereType<File>()) {
            await precacheImage(
              FileImage(f),
              ctx,
            ).timeout(const Duration(seconds: 5), onTimeout: () {});
          }
        });
      }
      await t.pumpWidget(
        framed(
          Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  initialCenter: LatLng(
                    homePos.lat + 0.017,
                    homePos.lng + 0.02,
                  ),
                  initialZoom: 13,
                ),
                children: [
                  if (tiles != null)
                    TileLayer(
                      tileProvider: _LocalTiles(tiles),
                      urlTemplate: 'x/{z}/{x}/{y}',
                    ),
                  CircleLayer(circles: rangeSampleCircles(r.store)),
                  MarkerLayer(markers: rangeMarkers(r.store)),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(homePos.lat, homePos.lng),
                        width: 40,
                        height: 40,
                        child: const Icon(
                          Icons.home,
                          color: Colors.blue,
                          size: 28,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                left: 8,
                top: 8,
                right: 64,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: RangeRunStrip(actions: r.actions()),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: Material(
                  color: Colors.white,
                  shape: const CircleBorder(),
                  elevation: 2,
                  child: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.stop_circle, color: rangeRed),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await shot(t, 'trip_strip');
      await done(t, r);
    });

    testWidgets('start sheet', (t) async {
      size(t, 720);
      final r = Rig();
      await t.pumpWidget(
        framed(
          Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                key: const Key('go'),
                onPressed: () => rangeRunTap(ctx, r.actions()),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('go')));
      await t.pumpAndSettle();
      await shot(t, 'start_sheet');
      await done(t, r);
    });

    testWidgets('summary', (t) async {
      size(t, 720);
      final r = Rig();
      await r.run.start();
      await t.runAsync(() => r.drive(n: 10));
      r.clock.add(const Duration(minutes: 40));
      final s = (await r.run.stop())!;
      await t.pumpWidget(
        framed(
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: RangeSummaryView(actions: r.actions(), summary: s),
          ),
        ),
      );
      await shot(t, 'summary');
      await done(t, r);
    });

    testWidgets('Talk connection sheet line', (t) async {
      size(t, 720);
      await t.pumpWidget(
        framed(
          SingleChildScrollView(
            child: ConnectionHealthSheet(
              health: exampleHealth(),
              rangeTest: RangeRunLine(
                running: false,
                homeName: 'Skunk Ape',
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await shot(t, 'connection_sheet');
    });
  });
}

class _LocalTiles extends TileProvider {
  _LocalTiles(this.dir);
  final String dir;
  @override
  ImageProvider getImage(TileCoordinates c, TileLayer o) {
    final f = File('$dir/${c.z}_${c.x}_${c.y}.png');
    return f.existsSync() ? FileImage(f) : MemoryImage(Uint8List(0));
  }
}
