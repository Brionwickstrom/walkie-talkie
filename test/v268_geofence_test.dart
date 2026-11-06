// v2.6.8: geofences — point-in-circle/polygon, hysteresis, enter/leave.
// Example data only; nothing here has run against a live radio.
//   V268_SHOTS=/workspace flutter test test/v268_geofence_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/geofence.dart';
import 'package:walkie_talkie/ui/settings_index.dart';

import 'home_layout_test.dart' show loadFonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  final home = const GeoPoint(45.5868, -122.2901); // Skunk Ape example
  final near = const GeoPoint(45.5870, -122.2900); // ~25 m NE
  final far = const GeoPoint(45.6000, -122.2901); // ~1.5 km N
  // 200 m square around home (rough degrees).
  final square = [
    const GeoPoint(45.5850, -122.2920),
    const GeoPoint(45.5850, -122.2880),
    const GeoPoint(45.5885, -122.2880),
    const GeoPoint(45.5885, -122.2920),
  ];

  group('point-in-circle', () {
    test('inside, on edge, outside', () {
      expect(pointInCircle(home, home, 100), isTrue);
      expect(pointInCircle(near, home, 50), isTrue);
      expect(pointInCircle(far, home, 100), isFalse);
      // Buffer shrinks for enter.
      expect(pointInCircle(near, home, 30, bufferM: -25), isFalse);
      expect(pointInCircle(home, home, 30, bufferM: -25), isTrue);
    });
  });

  group('point-in-polygon', () {
    test('inside and outside a square', () {
      expect(pointInPolygon(home, square), isTrue);
      expect(pointInPolygon(far, square), isFalse);
      expect(pointInPolygon(home, square.take(2).toList()), isFalse);
    });
  });

  group('pointInZone', () {
    test('circle and polygon', () {
      final c = GeofenceZone(
        id: 'c1',
        name: 'Yard',
        shape: GeofenceShape.circle,
        center: home,
        radiusM: 100,
      );
      final p = GeofenceZone(
        id: 'p1',
        name: 'Block',
        shape: GeofenceShape.polygon,
        vertices: square,
      );
      expect(pointInZone(home, c), isTrue);
      expect(pointInZone(far, c), isFalse);
      expect(pointInZone(home, p), isTrue);
      expect(pointInZone(far, p), isFalse);
    });
  });

  group('hysteresis / enter / leave', () {
    test('seeds without alert, then enter and leave with buffer', () {
      var t = DateTime.utc(2026, 11, 6, 12);
      final mon = GeofenceMonitor(clock: () => t, bufferM: 25);
      final z = GeofenceZone(
        id: 'yard',
        name: 'Yard',
        shape: GeofenceShape.circle,
        center: home,
        radiusM: 80,
      );
      mon.setZones([z]);

      // First sighting outside: seed, no alert.
      expect(mon.observe(1, far), isEmpty);
      expect(mon.isInside('yard', 1), isFalse);

      // Jump deep inside → enter.
      t = t.add(const Duration(minutes: 1));
      final enter = mon.observe(1, home);
      expect(enter, hasLength(1));
      expect(enter.first.cross, GeofenceCross.enter);
      expect(enter.first.zoneName, 'Yard');
      expect(enter.first.title, 'Entered Yard');

      // Jitter just outside the shrink but inside the grow: no leave.
      t = t.add(const Duration(seconds: 30));
      final edge = GeoPoint(
        home.lat + (60 / 111320), // ~60 m north
        home.lng,
      );
      expect(mon.observe(1, edge), isEmpty);
      expect(mon.isInside('yard', 1), isTrue);

      // Deep outside → leave.
      t = t.add(const Duration(minutes: 4));
      final leave = mon.observe(1, far);
      expect(leave, hasLength(1));
      expect(leave.first.cross, GeofenceCross.leave);
      expect(leave.first.textFor('Yowie'), 'Yowie left Yard');
    });

    test('cooldown suppresses spam', () {
      var t = DateTime.utc(2026, 11, 6, 13);
      final mon = GeofenceMonitor(
        clock: () => t,
        bufferM: 10,
        cooldown: const Duration(minutes: 3),
      );
      mon.setZones([
        GeofenceZone(
          id: 'c',
          name: 'Camp',
          shape: GeofenceShape.circle,
          center: home,
          radiusM: 50,
        ),
      ]);
      mon.observe(7, far);
      t = t.add(const Duration(seconds: 1));
      expect(mon.observe(7, home), hasLength(1));
      t = t.add(const Duration(seconds: 30));
      mon.observe(7, far); // leave would fire…
      // …but immediately re-enter within cooldown: suppressed.
      t = t.add(const Duration(seconds: 10));
      expect(mon.observe(7, home), isEmpty);
      t = t.add(const Duration(minutes: 4));
      expect(mon.observe(7, home), isEmpty); // already inside
      mon.observe(7, far);
      t = t.add(const Duration(minutes: 4));
      expect(mon.observe(7, home).first.cross, GeofenceCross.enter);
    });

    test('muted, specific watch, excluded public id', () {
      final mon = GeofenceMonitor();
      mon.excluded.add(99); // public node
      mon.setZones([
        GeofenceZone(
          id: 'a',
          name: 'A',
          shape: GeofenceShape.circle,
          center: home,
          radiusM: 100,
          muted: true,
        ),
        GeofenceZone(
          id: 'b',
          name: 'B',
          shape: GeofenceShape.circle,
          center: home,
          radiusM: 100,
          watch: GeofenceWatch.specific,
          watchIds: {42},
        ),
      ]);
      mon.observe(42, far);
      expect(mon.observe(42, home), hasLength(1)); // only B
      expect(mon.observe(99, far), isEmpty);
      expect(mon.observe(99, home), isEmpty);
      expect(mon.observe(7, far), isEmpty);
      expect(mon.observe(7, home), isEmpty); // not on B's list
    });
  });

  group('store + validate', () {
    test('round-trip JSON and validate draft', () async {
      final dir = await Directory.systemTemp.createTemp('gf268');
      final store = GeofenceStore(File('${dir.path}/geofences.json'));
      await store.load();
      expect(store.zones, isEmpty);
      final z = await store.add(
        GeofenceZone(
          id: '',
          name: 'Yard',
          shape: GeofenceShape.circle,
          center: home,
          radiusM: 120,
          colorArgb: 0xFFE91E63,
        ),
      );
      expect(z, isNotNull);
      expect(z!.id, startsWith('gf_'));
      await store.rename(z.id, 'Front yard');
      await store.setMuted(z.id, true);
      final store2 = GeofenceStore(File('${dir.path}/geofences.json'));
      await store2.load();
      expect(store2.zones, hasLength(1));
      expect(store2.zones.first.name, 'Front yard');
      expect(store2.zones.first.muted, isTrue);
      expect(store2.zones.first.radiusM, 120);
      expect(
        validateGeofenceDraft(
          shape: GeofenceShape.circle,
          center: home,
          radiusM: 2,
          name: 'x',
        ),
        contains('5 metres'),
      );
      expect(
        validateGeofenceDraft(
          shape: GeofenceShape.polygon,
          vertices: square.take(2).toList(),
          name: 'x',
        ),
        contains('three'),
      );
      expect(
        validateGeofenceDraft(
          shape: GeofenceShape.circle,
          center: home,
          radiusM: 50,
          name: 'Yard',
        ),
        isNull,
      );
      await dir.delete(recursive: true);
    });
  });

  group('settings search', () {
    test('geofence entries exist with required words', () {
      final entries =
          settingsIndex.where((e) => e.id.startsWith('geofence')).toList();
      expect(entries.length, greaterThanOrEqualTo(2));
      for (final w in ['geofence', 'zone', 'fence', 'alert area']) {
        expect(
          entries.any(
            (e) =>
                e.words.contains(w) ||
                e.title.toLowerCase().contains(w) ||
                e.about.toLowerCase().contains(w),
          ),
          isTrue,
          reason: 'missing search word $w',
        );
      }
      expect(
        entries.every((e) => e.home == SettingsHome.trip),
        isTrue,
      );
    });

    test('anchor ids are in source', () {
      final src = File('lib/ui/geofences_page.dart').readAsStringSync();
      expect(
        RegExp(r"SettingAnchor\(\s*id:\s*'geofences'").hasMatch(src),
        isTrue,
      );
      expect(
        RegExp(r"SettingAnchor\(\s*id:\s*'geofence-draw'").hasMatch(src),
        isTrue,
      );
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V268_SHOTS'];
    if (dir == null) return;

    Future<void> shot(WidgetTester t, String name, Widget body) async {
      t.view.physicalSize = const Size(400, 760) * 2;
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: Scaffold(
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.amber,
                    padding: const EdgeInsets.fromLTRB(8, 30, 8, 6),
                    child: const Text(
                      'EXAMPLE DATA: made-up zones, not a live radio',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black, fontSize: 13),
                    ),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v268_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    testWidgets('zone list', (t) async {
      final zones = [
        GeofenceZone(
          id: '1',
          name: 'Yard',
          shape: GeofenceShape.circle,
          center: home,
          radiusM: 100,
          colorArgb: 0xFF4CAF50,
        ),
        GeofenceZone(
          id: '2',
          name: 'Property line',
          shape: GeofenceShape.polygon,
          vertices: square,
          colorArgb: 0xFF2196F3,
          muted: true,
        ),
      ];
      await shot(
        t,
        'zones',
        ListView(
          children: [
            for (final z in zones)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(z.colorArgb),
                  radius: 10,
                ),
                title: Text(z.name),
                subtitle: Text(
                  z.isCircle
                      ? 'Circle · ${z.radiusM!.round()} m'
                      : 'Polygon · ${z.vertices.length} corners · muted',
                ),
                trailing: Icon(
                  z.muted
                      ? Icons.notifications_off
                      : Icons.notifications_active,
                ),
              ),
          ],
        ),
      );
      expect(find.text('Yard'), findsOneWidget);
    });
  });
}
