// v2.6.12: Battery mode on screen: the picker (Settings > Battery and the
// Talk connection sheet), the chip icon, locked switches, the range test
// start sheet in Saver, the Tracking-on-battery note, and Settings search.
//   V2612_SHOTS=/workspace flutter test test/v2612_battery_mode_ui_test.dart
// writes /workspace/v2612_*.png (example data).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/trip/battery_mode.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/battery_mode_ui.dart';
import 'package:walkie_talkie/ui/connection_health.dart';
import 'package:walkie_talkie/ui/map_cache_settings.dart';
import 'package:walkie_talkie/ui/range_run_ui.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'trip_integration_test.dart' show FakeHost;

class Clock {
  DateTime now = DateTime(2026, 11, 6, 9, 0, 0);
  DateTime call() => now;
  void add(Duration d) => now = now.add(d);
}

/// File work runs in real time.
Future<void> real(WidgetTester t, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await t.pump();
  }
}

Future<void> tapReal(WidgetTester t, Finder f) async {
  await t.tap(f);
  await real(t);
}

ConnectionHealth health() => ConnectionHealth.from(
  now: DateTime(2026, 11, 6, 9),
  bestKind: TransportKind.internet,
  internet: TransportStatus.running,
);

void main() {
  setUpAll(loadFonts);
  late Directory tmp;
  late FakeHost host;
  late Clock clock;
  TripController? made;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('v2612w'));
  tearDown(() async {
    made?.dispose();
    made = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<TripController> rig(WidgetTester t, {TripSettings? s}) async {
    late TripController trip;
    host = FakeHost(1);
    clock = Clock();
    await t.runAsync(() async {
      trip =
          TripController(
              host: host,
              settings: s ?? TripSettings(tripMode: true),
              dir: tmp,
              userAgent: 't',
              clock: clock.call,
            )
            ..trimDelay = const Duration(hours: 1)
            ..warmDelay = const Duration(hours: 1);
      trip.tiles.online = false;
      await trip.start();
    });
    made = trip;
    return trip;
  }

  Future<void> setMode(WidgetTester t, TripController trip, BatteryMode m) =>
      t.runAsync(() => trip.setBatteryMode(m));

  Widget app(Widget child) => MaterialApp(
    theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );

  group('picker', () {
    testWidgets('three modes; tapping one switches it', (t) async {
      final trip = await rig(t);
      await t.pumpWidget(app(BatteryModePicker(trip: trip)));
      for (final m in BatteryMode.values) {
        expect(find.byKey(Key('battery-mode-${m.id}')), findsOneWidget);
      }
      await tapReal(t, find.byKey(const Key('battery-mode-saver')));
      expect(trip.batteryMode, BatteryMode.saver);
      expect(trip.settings.tripMode, isFalse);
      expect(
        t.widget<Text>(find.byKey(const Key('battery-mode-about'))).data,
        startsWith('Least battery.'),
      );
      await tapReal(t, find.byKey(const Key('battery-mode-normal')));
      expect(trip.batteryMode, BatteryMode.normal);
      expect(trip.settings.tripMode, isTrue, reason: 'put back');
    });

    testWidgets('Saver during a range test: plain error, Stop range test', (
      t,
    ) async {
      final trip = await rig(t);
      await t.runAsync(() => trip.rangeRun.start());
      await t.pumpWidget(app(BatteryModePicker(trip: trip)));
      await tapReal(t, find.byKey(const Key('battery-mode-saver')));
      expect(trip.batteryMode, BatteryMode.normal);
      expect(find.byKey(const Key('fe-message')), findsOneWidget);
      expect(find.text('Stop range test'), findsOneWidget);
      expect(find.text('Switch to Tracking'), findsOneWidget);
      await tapReal(t, find.byKey(const Key('fe-fix-stopRangeTest')));
      expect(trip.rangeRun.running, isFalse);
      expect(trip.batteryMode, BatteryMode.saver, reason: 'then switched');
      expect(find.byKey(const Key('fe-message')), findsNothing);
    });

    testWidgets('Tracking on battery for 3 h: the note and Switch to Normal', (
      t,
    ) async {
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.tracking);
      trip.tick();
      clock.add(const Duration(hours: 3, minutes: 1));
      trip.tick();
      await t.pumpWidget(app(BatteryModePicker(trip: trip)));
      expect(find.byKey(const Key('battery-mode-nudge')), findsOneWidget);
      await tapReal(t, find.byKey(const Key('battery-mode-nudge-normal')));
      expect(trip.batteryMode, BatteryMode.normal);
      expect(find.byKey(const Key('battery-mode-nudge')), findsNothing);
    });
  });

  group('Talk connection chip and sheet', () {
    testWidgets('a leaf for Saver, a target for Tracking, nothing for Normal', (
      t,
    ) async {
      var mode = BatteryMode.normal;
      Widget chip() => app(
        ConnectionChip(source: health, onTap: () {}, batteryMode: () => mode),
      );
      await t.pumpWidget(chip());
      expect(find.byKey(const Key('connection-chip-mode-saver')), findsNothing);
      expect(find.byIcon(Icons.eco), findsNothing);
      mode = BatteryMode.saver;
      await t.pumpWidget(chip());
      expect(find.byKey(const Key('connection-chip-mode-saver')), findsOne);
      expect(find.byIcon(Icons.eco), findsOneWidget);
      mode = BatteryMode.tracking;
      await t.pumpWidget(chip());
      expect(find.byKey(const Key('connection-chip-mode-tracking')), findsOne);
      expect(find.byIcon(Icons.track_changes), findsOneWidget);
    });

    testWidgets('the sheet has the picker', (t) async {
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.saver);
      await t.pumpWidget(
        app(
          ConnectionHealthSheet(
            health: health(),
            battery: BatteryModePicker(trip: trip, compact: true),
          ),
        ),
      );
      expect(find.byKey(const Key('connection-battery-mode')), findsOneWidget);
      expect(find.text('Battery mode: Saver'), findsOneWidget);
      await tapReal(t, find.byKey(const Key('battery-mode-tracking')));
      expect(trip.batteryMode, BatteryMode.tracking);
      expect(find.text('Battery mode: Tracking'), findsOneWidget);
    });
  });

  group('locked switches', () {
    testWidgets('Keep home area ready is locked in Saver, with the note', (
      t,
    ) async {
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.saver);
      await t.pumpWidget(app(MapCacheSettings(trip: trip)));
      await real(t);
      final sw = t.widget<SwitchListTile>(
        find.byKey(const Key('map-warm-home')),
      );
      expect(sw.onChanged, isNull);
      expect(sw.value, isFalse);
      expect(find.textContaining(controlledNote), findsOneWidget);
      await setMode(t, trip, BatteryMode.normal);
      await t.pump();
      final sw2 = t.widget<SwitchListTile>(
        find.byKey(const Key('map-warm-home')),
      );
      expect(sw2.onChanged, isNotNull);
      expect(sw2.value, isTrue);
    });
  });

  group('range test start sheet', () {
    testWidgets('in Saver: plain error, Switch to Tracking, then Start', (
      t,
    ) async {
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.saver);
      final a = RangeRunActions(
        run: trip.rangeRun,
        logger: trip.rangeLog,
        radioReady: () => true,
        saverOn: () => trip.batteryMode == BatteryMode.saver,
        setMode: trip.setBatteryMode,
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showRangeStartSheet(ctx, a),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.textContaining('Battery mode is Saver'), findsOneWidget);
      expect(
        t.widget<FilledButton>(find.byKey(const Key('rangeStartGo'))).onPressed,
        isNull,
      );
      await tapReal(t, find.byKey(const Key('fe-fix-useTrackingMode')));
      expect(trip.batteryMode, BatteryMode.tracking);
      expect(find.textContaining('Battery mode is Saver'), findsNothing);
      expect(
        t.widget<FilledButton>(find.byKey(const Key('rangeStartGo'))).onPressed,
        isNotNull,
      );
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V2612_SHOTS'];
    if (dir == null) return;

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

    Future<void> shot(WidgetTester t, String name) async {
      await t.pump(const Duration(milliseconds: 300));
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 3);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v2612_$name.png')
            .writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Widget framed(String title, Widget body) => RepaintBoundary(
      key: const Key('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
        home: Scaffold(
          appBar: AppBar(title: Text(title)),
          body: Stack(fit: StackFit.expand, children: [body, label()]),
        ),
      ),
    );

    Widget settings(TripController trip) => SettingsSearchLayout(
      padding: const EdgeInsets.all(16),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Battery',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.blue.shade800,
            ),
          ),
          const SizedBox(height: 8),
          SettingAnchor(
            id: 'battery-mode',
            child: BatteryModePicker(trip: trip),
          ),
        ],
      ),
    );

    void size(WidgetTester t, double h) {
      t.view.physicalSize = Size(360, h) * 3;
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
    }

    testWidgets('settings saver', (t) async {
      size(t, 640);
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.saver);
      await t.pumpWidget(framed('Settings', settings(trip)));
      await real(t);
      await shot(t, 'settings_saver');
    });

    testWidgets('settings tracking with the 3 h note', (t) async {
      size(t, 700);
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.tracking);
      trip.tick();
      clock.add(const Duration(hours: 3, minutes: 1));
      trip.tick();
      await t.pumpWidget(framed('Settings', settings(trip)));
      await real(t);
      await shot(t, 'settings_tracking_nudge');
    });

    testWidgets('search power mode', (t) async {
      size(t, 640);
      final trip = await rig(t);
      await t.pumpWidget(framed('Settings', settings(trip)));
      await real(t);
      await t.enterText(find.byKey(const Key('settings-search')), 'power mode');
      await t.pump();
      await shot(t, 'search');
    });

    testWidgets('talk chip and sheet', (t) async {
      size(t, 700);
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.saver);
      await t.pumpWidget(
        framed(
          'Talk',
          ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: ConnectionChip(
                  source: health,
                  onTap: () {},
                  batteryMode: () => trip.batteryMode,
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: ConnectionHealthSheet(
                    health: health(),
                    battery: BatteryModePicker(trip: trip, compact: true),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await real(t);
      await shot(t, 'talk_chip_sheet');
    });

    testWidgets('range test start in Saver', (t) async {
      size(t, 760);
      final trip = await rig(t);
      await setMode(t, trip, BatteryMode.saver);
      final a = RangeRunActions(
        run: trip.rangeRun,
        logger: trip.rangeLog,
        radioReady: () => true,
        saverOn: () => trip.batteryMode == BatteryMode.saver,
        setMode: trip.setBatteryMode,
      );
      await t.pumpWidget(
        framed(
          'Trip map',
          Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showRangeStartSheet(ctx, a),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await shot(t, 'range_start_saver');
    });
  });
}
