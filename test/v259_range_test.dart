// v2.5.9: range test markers on the Trip map (green connect, red drop).
// RANGE_PNG=path renders a screenshot; RANGE_TILES=dir supplies real OSM
// tiles (z13_x_y.png) for it.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/range_test.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_layers_page.dart';
import 'package:walkie_talkie/ui/range_test_ui.dart';

import 'home_layout_test.dart' show loadFonts;
import 'trip_integration_test.dart' as ti;

/// The real range_state.json of the 5:44 PM test (Oct 30 2026), trimmed.
const realState =
    '{"state": "CONNECTED", "last": {"time": "06:22:04 PM", "result": "ERR", '
    '"snr": null, "hops": null, "lat": 45.5868416, "lon": -122.290176, '
    '"dist_m": 978, "note": "serial could not open port"}, "events": ['
    '{"time": "05:14:34 PM", "result": "NO_CONTACT", "snr": null, '
    '"hops": null, "lat": null, "lon": null, "dist_m": null, '
    '"note": "no reply 15s", "kind": "START_NO_CONTACT"}, '
    '{"time": "05:44:34 PM", "result": "CONNECTED", "snr": -7.0, "hops": 0, '
    '"lat": 45.5868416, "lon": -122.290176, "dist_m": 978, "note": "", '
    '"kind": "CONNECT"}], "end": 1793412874.679147, "running": true}';

final fixedEnd = DateTime.fromMillisecondsSinceEpoch(1793412874679);

Directory tmp(String n) {
  final d = Directory.systemTemp.createTempSync(n);
  addTearDown(() {
    try {
      d.deleteSync(recursive: true);
    } catch (_) {}
  });
  return d;
}

RangeEvent ev(
  RangeKind k,
  DateTime at, {
  double lat = 45.5868416,
  double lon = -122.290176,
  bool approx = true,
}) => RangeEvent(
  kind: k,
  at: at,
  pos: GeoPoint(lat, lon),
  snr: -7,
  hops: 0,
  distM: 978,
  approximate: approx,
);

void main() {
  setUpAll(loadFonts);

  group('parsing the range test files', () {
    test(
      'the real 5:44 PM file: one connect, the no-contact start ignored',
      () async {
        final rt = RangeTest(File('${tmp('rt').path}/r.json'));
        final r = await rt.importText(realState);
        expect(r.added, 1);
        expect(rt.length, 1);
        final e = rt.events.single;
        expect(e.kind, RangeKind.connect);
        expect(e.at.millisecondsSinceEpoch ~/ 1000, 1793407474);
        expect(e.pos.lat, 45.5868416);
        expect(e.pos.lng, -122.290176);
        expect(e.snr, -7.0);
        expect(e.hops, 0);
        expect(e.distM, 978);
        expect(e.approximate, isTrue, reason: 'blurred by default');
        expect(
          e.at.toLocal().hour * 3600 +
              e.at.toLocal().minute * 60 +
              e.at.toLocal().second,
          17 * 3600 + 44 * 60 + 34,
        );
      },
    );

    test('dates roll back over midnight and drops are read', () {
      final out = <RangeEvent>[];
      final r = parseRangeState(
        jsonEncode({
          'end': DateTime(2026, 10, 31, 0, 30).millisecondsSinceEpoch / 1000,
          'events': [
            {
              'time': '11:50:00 PM',
              'kind': 'CONNECT',
              'lat': 45.5,
              'lon': -122.2,
              'snr': 3.5,
              'hops': 1,
              'dist_m': 500,
            },
            {
              'time': '12:10:00 AM',
              'kind': 'DROP',
              'lat': 45.6,
              'lon': -122.3,
              'snr': null,
              'hops': null,
              'dist_m': 4000,
            },
            {'time': '12:11:00 AM', 'kind': 'DROP', 'lat': null, 'lon': null},
            {'time': '12:12:00 AM', 'kind': 'START_NO_CONTACT'},
          ],
        }),
        approximate: false,
        into: out,
        anchor: DateTime(2026, 10, 31, 1),
      );
      expect(out.length, 2);
      expect(r.noPlace, 1);
      expect(out[0].at, DateTime(2026, 10, 30, 23, 50));
      expect(out[1].at, DateTime(2026, 10, 31, 0, 10));
      expect(out[1].kind, RangeKind.drop);
      expect(out[1].approximate, isFalse);
      expect(out[0].hops, 1);
    });

    test('24 hour times work; junk is refused', () async {
      final rt = RangeTest(File('${tmp('rt').path}/r.json'));
      await rt.importText(
        '{"events":[{"time":"17:44:34","kind":"CONNECT","lat":1.0,"lon":2.0}]}',
        anchor: DateTime(2026, 10, 30, 20),
      );
      expect(rt.events.single.at, DateTime(2026, 10, 30, 17, 44, 34));
      expect(() => rt.importText('hello'), throwsFormatException);
      expect(() => rt.importText('{"a":1}'), throwsFormatException);
      expect(rt.length, 1);
    });

    test('copied lines round trip, in any chat text around them', () async {
      final a = RangeTest(File('${tmp('rt').path}/a.json'));
      await a.add([
        ev(
          RangeKind.connect,
          DateTime.fromMillisecondsSinceEpoch(1793407474000),
        ),
        ev(
          RangeKind.drop,
          DateTime.fromMillisecondsSinceEpoch(1793408000000),
          lat: 45.7,
          lon: -122.1,
          approx: false,
        ),
      ]);
      final text = a.toText();
      expect(text, startsWith('STALKIE-RANGE-1 CONNECT 1793407474 '));
      final b = RangeTest(File('${tmp('rt').path}/b.json'));
      final r = await b.importText('Here you go:\n$text\nthanks');
      expect(r.added, 2);
      expect(b.events.map((e) => e.toLine()), a.events.map((e) => e.toLine()));
      expect(b.events.last.approximate, isFalse);
    });

    test('the same event twice is one marker', () async {
      final rt = RangeTest(File('${tmp('rt').path}/r.json'));
      await rt.importText(realState);
      final r = await rt.importText(realState);
      expect(r.added, 0);
      expect(r.updated, 1);
      expect(rt.length, 1);
    });

    test('exact switch applies to new imports only', () async {
      final rt = RangeTest(File('${tmp('rt').path}/r.json'));
      await rt.importText(realState);
      await rt.setImportExact(true);
      await rt.importText(
        '{"end":1793412874,"events":[{"time":"06:00:00 PM","kind":"DROP","lat":45.6,"lon":-122.3}]}',
      );
      expect(rt.events.first.approximate, isTrue);
      expect(rt.events.last.approximate, isFalse);
    });
  });

  group('storage and the PC file', () {
    test(
      'markers, visibility and the exact switch survive a restart',
      () async {
        final f = File('${tmp('rt').path}/r.json');
        final a = RangeTest(f);
        await a.importText(realState);
        await a.setVisible(false);
        await a.setImportExact(true);
        final b = RangeTest(f);
        await b.load();
        expect(b.length, 1);
        expect(b.visible, isFalse);
        expect(b.importExact, isTrue);
        expect(b.events.single.snr, -7.0);
        await b.remove(b.events.single);
        expect(b.isEmpty, isTrue);
        await b.add([ev(RangeKind.drop, DateTime(2026, 10, 30, 18))]);
        await b.clear();
        final c = RangeTest(f);
        await c.load();
        expect(c.isEmpty, isTrue);
      },
    );

    test('a damaged file loads as empty', () async {
      final f = File('${tmp('rt').path}/r.json')..writeAsStringSync('{{{');
      final rt = RangeTest(f);
      await rt.load();
      expect(rt.isEmpty, isTrue);
    });

    test('PC file: imported once, again only when it changes', () async {
      final d = tmp('pc');
      final pc = File('${d.path}/range_state.json')
        ..writeAsStringSync(realState);
      final rt = RangeTest(File('${d.path}/store.json'));
      final r1 = await rt.importFromPc(file: pc);
      expect(r1?.added, 1);
      expect(await rt.importFromPc(file: pc), isNull, reason: 'unchanged');
      // The script writes a new result.
      final next = jsonDecode(realState) as Map<String, Object?>;
      (next['events'] as List).add({
        'time': '06:30:00 PM',
        'result': 'NO_CONTACT',
        'snr': null,
        'hops': null,
        'lat': 45.61,
        'lon': -122.4,
        'dist_m': 5200,
        'note': '',
        'kind': 'DROP',
      });
      pc.writeAsStringSync(jsonEncode(next));
      pc.setLastModified(DateTime.now().add(const Duration(minutes: 1)));
      final r2 = await rt.importFromPc(file: pc);
      expect(r2?.added, 1);
      expect(r2?.updated, 1);
      expect(rt.length, 2);
      expect(rt.events.last.kind, RangeKind.drop);
    });

    test('PC file missing or broken is ignored quietly', () async {
      final d = tmp('pc');
      final rt = RangeTest(File('${d.path}/store.json'));
      expect(await rt.importFromPc(file: File('${d.path}/none.json')), isNull);
      final bad = File('${d.path}/bad.json')..writeAsStringSync('nope');
      expect(await rt.importFromPc(file: bad), isNull);
      expect(rt.isEmpty, isTrue);
    });

    test('TripController owns the store in its folder', () async {
      final d = tmp('trip');
      final c = TripController(
        host: ti.FakeHost(1),
        settings: TripSettings(),
        dir: d,
        userAgent: 'test',
      );
      addTearDown(c.dispose);
      await c.start();
      await c.range.importText(realState);
      expect(File('${d.path}/range_test.json').existsSync(), isTrue);
      final json = File('${d.path}/range_test.json').readAsStringSync();
      expect(json.toUpperCase(), isNot(contains('PSK')));
    });
  });

  group('the map layer and its pages', () {
    Widget mapHost(RangeTest rt, {RangeEvent? sel, Widget? below}) {
      return MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ListenableBuilder(
              listenable: rt,
              builder: (_, _) => FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(45.5868416, -122.290176),
                  initialZoom: 14,
                ),
                children: [
                  CircleLayer(circles: rangeCircles(rt, sel)),
                  MarkerLayer(
                    markers: rangeMarkers(
                      rt,
                      onTap: (e) => showRangeEventSheet(ctx, rt, e),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('green connect + red drop, tap shows the popup', (t) async {
      final rt = RangeTest(null);
      await rt.importText(realState);
      await rt.add([
        ev(
          RangeKind.drop,
          DateTime(2026, 10, 30, 18, 3),
          lat: 45.5868416,
          lon: -122.2851,
        ),
      ]);
      await t.pumpWidget(mapHost(rt));
      expect(find.byKey(const Key('range-connect:1793407474')), findsOneWidget);
      expect(find.byType(Marker), findsNothing); // widgets, not the model
      expect(find.text('5:44 PM ~'), findsOneWidget);
      expect(find.text('6:03 PM ~'), findsOneWidget);
      final greens = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == rangeGreen,
      );
      final reds = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == rangeRed,
      );
      expect(greens, findsOneWidget);
      expect(reds, findsOneWidget);

      await t.tap(find.byKey(const Key('range-connect:1793407474')));
      await t.pumpAndSettle();
      expect(find.text('Connected to the home radio'), findsOneWidget);
      expect(find.text('Fri Oct 30, 5:44:34 PM'), findsOneWidget);
      expect(find.text('-7.0 dB'), findsOneWidget);
      expect(find.text('Direct (no relays)'), findsOneWidget);
      expect(find.text('0.6 mi'), findsOneWidget);
      expect(find.text('45.58684, -122.29018'), findsOneWidget);
      expect(
        (t.widget<Text>(find.byKey(const Key('rangeAccuracy'))).data ?? ''),
        contains('Approximate, blurred position'),
      );
      await t.tap(find.byKey(const Key('rangeRemove')));
      await t.pumpAndSettle();
      expect(rt.length, 1);
    });

    testWidgets('hidden = no markers; exact = no blur note or circle', (
      t,
    ) async {
      final rt = RangeTest(null);
      final e = ev(
        RangeKind.connect,
        DateTime(2026, 10, 30, 17, 44, 34),
        approx: false,
      );
      await rt.add([e]);
      expect(rangeCircles(rt, e), isEmpty, reason: 'exact: no blur circle');
      final blurred = ev(
        RangeKind.drop,
        DateTime(2026, 10, 30, 18),
        lat: 45.62,
      );
      await rt.add([blurred]);
      final c = rangeCircles(rt, blurred);
      expect(c.length, 1);
      expect(c.single.radius, rangeBlurM);
      expect(c.single.useRadiusInMeter, isTrue);
      expect(rangeCircles(rt, null), isEmpty);
      await rt.setVisible(false);
      expect(rangeMarkers(rt), isEmpty);
      expect(rangeCircles(rt, blurred), isEmpty);
      await rt.setVisible(true);
      expect(rangeMarkers(rt).length, 2);
      await t.pumpWidget(mapHost(rt));
      await t.tap(find.byKey(Key('range-${e.id}')));
      await t.pumpAndSettle();
      expect(
        t.widget<Text>(find.byKey(const Key('rangeAccuracy'))).data,
        'Exact position.',
      );
    });

    testWidgets('page: paste copied markers, hide, copy, clear', (t) async {
      final rt = RangeTest(null);
      String? clip =
          'Brion, paste this:\n'
          '${ev(RangeKind.connect, DateTime.fromMillisecondsSinceEpoch(1793407474000)).toLine()}';
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': clip};
          if (call.method == 'Clipboard.setData') {
            clip = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      t.view.physicalSize = const Size(800, 1800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      RangeEvent? shown;
      await t.pumpWidget(
        MaterialApp(
          home: RangeTestPage(range: rt, onShow: (e) => shown = e),
        ),
      );
      expect(find.text('No markers yet.'), findsOneWidget);
      await t.tap(find.byKey(const Key('rangePaste')));
      await t.pumpAndSettle();
      expect(rt.length, 1);
      expect(find.textContaining('1 marker (1 new)'), findsOneWidget);
      expect(find.text('Connected · 5:44:34 PM'), findsOneWidget);
      expect(
        find.textContaining('SNR -7.0 · Direct (no relays)'),
        findsOneWidget,
      );
      await t.tap(find.byKey(Key('rangeRow-${rt.events.single.id}')));
      expect(shown?.id, rt.events.single.id);

      await t.tap(find.byKey(const Key('rangeVisible')));
      await t.pumpAndSettle();
      expect(rt.visible, isFalse);
      await t.tap(find.byKey(const Key('rangeExact')));
      await t.pumpAndSettle();
      expect(rt.importExact, isTrue);

      clip = null;
      await t.tap(find.byKey(const Key('rangeCopy')));
      await t.pumpAndSettle();
      expect(clip, startsWith('STALKIE-RANGE-1 CONNECT 1793407474'));

      ScaffoldMessenger.of(t.element(find.byType(Scaffold))).clearSnackBars();
      await t.pumpAndSettle();
      clip = 'garbage';
      await t.tap(find.byKey(const Key('rangePaste')));
      await t.pumpAndSettle();
      expect(find.textContaining('no range test markers'), findsOneWidget);
      expect(rt.length, 1);

      await t.tap(find.byKey(const Key('rangeClear')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('rangeClearYes')));
      await t.pumpAndSettle();
      expect(rt.isEmpty, isTrue);
    });

    testWidgets('Map layers page has the Range test markers row', (t) async {
      final d = tmp('trip');
      final c = TripController(
        host: ti.FakeHost(1),
        settings: TripSettings(),
        dir: d,
        userAgent: 'test',
      );
      addTearDown(c.dispose);
      await t.runAsync(c.start);
      var opened = 0;
      await t.pumpWidget(
        MaterialApp(
          home: MapLayersPage(trip: c, onRange: () => opened++),
        ),
      );
      expect(find.text('Range test markers'), findsOneWidget);
      expect(
        find.text('Green and red markers from a range test.'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('rangeLayerTile')));
      expect(opened, 1);
      await t.runAsync(() => c.range.importText(realState));
      await t.pump();
      expect(find.text('1 marker · shown'), findsOneWidget);
    });
  });

  testWidgets('screenshot (RANGE_PNG=path)', (t) async {
    final out = Platform.environment['RANGE_PNG'];
    if (out == null) return;
    final tiles = Platform.environment['RANGE_TILES'];
    final rt = RangeTest(null);
    await rt.importText(realState);
    final e = rt.events.single;
    t.view.physicalSize = const Size(360, 780) * 3;
    t.view.devicePixelRatio = 3;
    t.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 16 * 3);
    addTearDown(t.view.reset);
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await t.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => FlutterMap(
                options: const MapOptions(
                  // Marker in the upper half so the popup does not cover it.
                  initialCenter: LatLng(45.5868416 - 0.012, -122.290176),
                  initialZoom: 13,
                ),
                children: [
                  if (tiles != null)
                    TileLayer(
                      tileProvider: _LocalTiles(tiles),
                      urlTemplate: 'x/{z}/{x}/{y}',
                    ),
                  CircleLayer(circles: rangeCircles(rt, e)),
                  MarkerLayer(markers: rangeMarkers(rt)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await settle();
    final ctx = t.element(find.byType(FlutterMap));
    // ignore: unawaited_futures
    showRangeEventSheet(ctx, rt, e);
    await settle();
    await t.pumpAndSettle();
    final b = t.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await t.runAsync(() async {
      final img = await b.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}

class _LocalTiles extends TileProvider {
  _LocalTiles(this.dir);
  final String dir;
  @override
  ImageProvider getImage(TileCoordinates c, TileLayer o) {
    final f = File('$dir/${c.z}_${c.x}_${c.y}.png');
    return f.existsSync()
        ? FileImage(f)
        : MemoryImage(
            Uint8List.fromList(const [
              0x89,
              0x50,
              0x4E,
              0x47,
              0x0D,
              0x0A,
              0x1A,
              0x0A,
              0,
              0,
              0,
              0x0D,
              0x49,
              0x48,
              0x44,
              0x52,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              1,
              8,
              6,
              0,
              0,
              0,
              0x1F,
              0x15,
              0xC4,
              0x89,
              0,
              0,
              0,
              0x0D,
              0x49,
              0x44,
              0x41,
              0x54,
              0x78,
              0x9C,
              0x63,
              0xF8,
              0xFF,
              0xFF,
              0x3F,
              0,
              5,
              0xFE,
              2,
              0xFE,
              0xA7,
              0x35,
              0x81,
              0x84,
              0,
              0,
              0,
              0,
              0x49,
              0x45,
              0x4E,
              0x44,
              0xAE,
              0x42,
              0x60,
              0x82,
            ]),
          );
  }
}
