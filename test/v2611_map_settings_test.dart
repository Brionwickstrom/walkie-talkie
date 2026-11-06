// v2.6.11: Settings > Map: the map cache (its size, Clear map cache, the
// limit) and Keep home area ready; their Settings search entries and
// anchors; plain errors; the version.
//   V2611_SHOTS=/workspace flutter test test/v2611_map_settings_test.dart
// writes /workspace/v2611_*.png (example data).
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/friendly_error.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_cache_settings.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'trip_integration_test.dart' show FakeHost;

List<String> ids(String q, {SettingsEnv env = const SettingsEnv()}) => [
  for (final e in searchSettings(q, env: env)) e.id,
];

/// Example data: 40 viewed tiles of 25 KB, 12 saved-area tiles.
Future<TripController> rig(WidgetTester t, Directory dir) async {
  late TripController trip;
  await t.runAsync(() async {
    final tiles = Directory('${dir.path}/tiles');
    Future<void> put(String src, int z, int x, int y) async {
      final f = File('${tiles.path}/$src/$z/$x/$y.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(Uint8List(25 * 1024));
    }

    for (var i = 0; i < 40; i++) {
      await put('usgs_topo', 15, 5240 + i, 11720);
    }
    for (var i = 0; i < 12; i++) {
      await put('usgs_topo', 12, 654, 1460 + i);
    }
    trip =
        TripController(
            host: FakeHost(1),
            settings: TripSettings(mapSource: 'usgs_topo'),
            dir: dir,
            userAgent: 't',
          )
          ..trimDelay = const Duration(hours: 1)
          ..warmDelay = const Duration(hours: 1);
    trip.tiles.online = false;
    await trip.start();
    trip.tiles.regions.add(
      OfflineRegion(
        name: 'Home',
        sourceId: 'usgs_topo',
        bounds: const GeoBounds(44.5, -122.9, 46.0, -122.0),
        minZoom: 12,
        maxZoom: 12,
        tiles: 12,
        bytes: 12 * 25 * 1024,
        at: DateTime(2026, 11, 1),
      ),
    );
  });
  return trip;
}

Widget app(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
  home: Scaffold(
    body: SettingsSearchLayout(
      padding: const EdgeInsets.all(16),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < 12; i++) const ListTile(title: Text('Other')),
          const Text('Map', style: TextStyle(fontWeight: FontWeight.bold)),
          child,
        ],
      ),
    ),
  ),
);

/// Isolate work (counting, clearing) runs in real time.
Future<void> real(WidgetTester t, [int ms = 400]) async {
  await t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await t.pump();
  await t.pump();
}

void main() {
  setUpAll(loadFonts);
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('v2611w'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('Settings search', () {
    test('clear cache, map cache and offline map find the Map settings', () {
      expect(ids('clear cache').first, 'map-cache');
      expect(ids('map cache').first, 'map-cache');
      expect(ids('cache'), containsAll(['map-cache', 'map-cache-limit']));
      expect(ids('offline map'), containsAll(['map-cache', 'map-warm-home']));
      expect(ids('home area').first, 'map-warm-home');
      expect(ids('precache'), contains('map-warm-home'));
    });

    test('not offered without the Trip map', () {
      const env = SettingsEnv(hasTrip: false);
      expect(ids('clear cache', env: env), isNot(contains('map-cache')));
      expect(ids('offline map', env: env), isNot(contains('map-warm-home')));
    });

    test('paths read well', () {
      final e = settingsIndex.firstWhere((e) => e.id == 'map-cache');
      expect(e.path, 'Settings › Map');
    });

    test('anchors: every Map entry has its SettingAnchor, on the sheet', () {
      final page = File('lib/ui/map_cache_settings.dart').readAsStringSync();
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      for (final e in settingsIndex.where((e) => e.section == 'Map')) {
        expect(page, contains("id: '${e.id}'"), reason: e.id);
        expect(page, contains("Text('${e.label}')"), reason: e.label);
      }
      expect(home, contains("_SectionTitle('Map')"));
      expect(home, contains('MapCacheSettings('));
    });

    testWidgets('tapping the result scrolls to Map cache', (t) async {
      final trip = await rig(t, tmp);
      t.view.physicalSize = const Size(360, 640) * 3;
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(app(MapCacheSettings(trip: trip)));
      await real(t);
      expect(find.byKey(const Key('map-cache')).hitTestable(), findsNothing);
      await t.enterText(
        find.byKey(const Key('settings-search')),
        'clear cache',
      );
      await t.pump();
      await t.tap(find.byKey(const Key('search-result-map-cache')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('map-cache')).hitTestable(), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      trip.dispose();
    });
  });

  group('Map cache settings', () {
    testWidgets('the size, viewed and saved apart, and the limit', (t) async {
      final trip = await rig(t, tmp);
      await t.pumpWidget(app(MapCacheSettings(trip: trip)));
      expect(find.text('Counting...'), findsOneWidget);
      await real(t);
      final size = t.widget<Text>(find.byKey(const Key('map-cache-size')));
      expect(size.data, contains('1000 KB of map tiles from looking around'));
      expect(size.data, contains('300 KB in saved offline areas'));
      expect(size.data, contains('Limit 500 MB'));
      trip.dispose();
    });

    testWidgets('Clear map cache: asks, clears, keeps saved areas', (t) async {
      final trip = await rig(t, tmp);
      await t.pumpWidget(app(MapCacheSettings(trip: trip)));
      await real(t);
      await t.ensureVisible(find.byKey(const Key('map-cache-clear')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('map-cache-clear')));
      await t.pumpAndSettle();
      expect(find.text('Clear map cache?'), findsOneWidget);
      expect(find.textContaining('Saved offline areas stay'), findsOneWidget);
      await t.tap(find.byKey(const Key('map-cache-clear-ok')));
      await t.pump();
      await real(t, 800);
      await real(t, 400);
      expect(
        find.textContaining('Map cache cleared: 1000 KB freed'),
        findsOneWidget,
      );
      final s = await t.runAsync(trip.mapCacheStats);
      expect(s!.viewedTiles, 0);
      expect(s.savedTiles, 12);
      for (var i = 0; i < 10; i++) {
        final x = t.widget<Text>(find.byKey(const Key('map-cache-size')));
        if (x.data!.startsWith('No map tiles')) break;
        await real(t, 200);
      }
      final size = t.widget<Text>(find.byKey(const Key('map-cache-size')));
      expect(size.data, contains('No map tiles from looking around'));
      // Nothing left to clear: the button is off.
      final b = t.widget<TextButton>(find.byKey(const Key('map-cache-clear')));
      expect(b.onPressed, isNull);
      trip.dispose();
    });

    testWidgets('Cancel clears nothing', (t) async {
      final trip = await rig(t, tmp);
      await t.pumpWidget(app(MapCacheSettings(trip: trip)));
      await real(t);
      await t.ensureVisible(find.byKey(const Key('map-cache-clear')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('map-cache-clear')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      final s = await t.runAsync(trip.mapCacheStats);
      expect(s!.viewedTiles, 40);
      trip.dispose();
    });

    testWidgets('the limit and Keep home area ready change the settings', (
      t,
    ) async {
      final trip = await rig(t, tmp);
      await t.pumpWidget(app(MapCacheSettings(trip: trip)));
      await real(t);
      await t.scrollUntilVisible(
        find.byKey(const Key('map-warm-home')),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('settings-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      await t.tap(find.byKey(const Key('map-cache-limit')));
      await t.pumpAndSettle();
      await t.tap(find.text('1 GB').last);
      await t.pumpAndSettle();
      expect(trip.settings.mapCacheMb, 1000);
      expect(trip.tiles.maxBytes, 1000 * 1024 * 1024);
      expect(trip.settings.warmHome, isTrue);
      await t.tap(find.byKey(const Key('map-warm-home')));
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump();
      expect(trip.settings.warmHome, isFalse);
      expect(
        find.textContaining('Only on Wi-Fi or while charging'),
        findsOneWidget,
      );
      trip.dispose();
    });

    test('a failed clear is one plain sentence with Try again', () {
      final fe = mapCacheClearError(
        const FileSystemException('Deletion failed', '/x/tiles/osm/1/2/3.png'),
      );
      expect(fe.message, startsWith('Could not clear the map cache'));
      expect(fe.message, contains('Saved offline areas were not touched'));
      expect(fe.fix, FixAction.retry);
      expect(fe.details, isNotNull);
      final full = mapCacheClearError(
        const FileSystemException('No space left on device'),
      );
      expect(full.message, contains('out of storage'));
    });

    test('sizes read well', () {
      expect(formatMb(250), '250 MB');
      expect(formatMb(1000), '1 GB');
      expect(formatMb(2000), '2 GB');
      expect(
        mapCacheLine(const MapCacheStats(), 500),
        'No map tiles from looking around. Limit 500 MB.',
      );
    });
  });

  group('the Trip map', () {
    final page = File('lib/ui/trip_page.dart').readAsStringSync();
    test('opens at the last view (no wait for GPS), remembers moves', () {
      expect(page, contains('mapStartView('));
      expect(page, contains('saved: trip.camera.camera'));
      expect(page, contains('trip.rememberCamera('));
      expect(page, isNot(contains('const LatLng(39.5, -98.35)')));
    });

    test('heavy layers one frame later; imported ones reused', () {
      expect(page, contains('_layersReady'));
      expect(page, contains('ImportedLayersCache'));
      // Every layer is still there.
      for (final l in [
        'baseTileLayers(trip)',
        '_geofenceLayers(trip)',
        'friendCircles(trip)',
        'rangeCircles(trip.range',
        'rangeSampleCircles(trip.range)',
        'MarkerLayer(markers: markers)',
        'PhotoDateLine(trip: trip)',
      ]) {
        expect(page, contains(l), reason: l);
      }
    });
  });

  group('version', () {
    test('pubspec is 2.6.11+71 (versionCode 2071)', () {
      final p = File('pubspec.yaml').readAsStringSync();
      expect(p, contains('\nversion: 2.6.11+71\n'));
      expect(2000 + 71, 2071);
    });

    test('README describes faster map start', () {
      final r = File('README.md').readAsStringSync();
      expect(r, contains('Faster map start'));
      expect(r, contains('2.6.11'));
      expect(r, contains('Clear map cache'));
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V2611_SHOTS'];
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
        File('$dir/v2611_$name.png')
            .writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Widget framed(Widget child) => RepaintBoundary(
      key: const Key('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
        home: Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: Stack(
            fit: StackFit.expand,
            children: [
              SettingsSearchLayout(
                padding: const EdgeInsets.all(16),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Map',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade800,
                      ),
                    ),
                    child,
                  ],
                ),
              ),
              label(),
            ],
          ),
        ),
      ),
    );

    void size(WidgetTester t, double h) {
      t.view.physicalSize = Size(360, h) * 3;
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
    }

    testWidgets('settings map section', (t) async {
      size(t, 640);
      final trip = await rig(t, tmp);
      await t.pumpWidget(framed(MapCacheSettings(trip: trip)));
      await real(t);
      await shot(t, 'settings_map');
      trip.dispose();
    });

    testWidgets('clear dialog', (t) async {
      size(t, 640);
      final trip = await rig(t, tmp);
      await t.pumpWidget(framed(MapCacheSettings(trip: trip)));
      await real(t);
      await t.ensureVisible(find.byKey(const Key('map-cache-clear')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('map-cache-clear')));
      await t.pumpAndSettle();
      await shot(t, 'clear_dialog');
      trip.dispose();
    });

    testWidgets('search clear cache', (t) async {
      size(t, 640);
      final trip = await rig(t, tmp);
      await t.pumpWidget(framed(MapCacheSettings(trip: trip)));
      await real(t);
      await t.enterText(
        find.byKey(const Key('settings-search')),
        'offline map',
      );
      await t.pump();
      await shot(t, 'search');
      trip.dispose();
    });
  });
}
