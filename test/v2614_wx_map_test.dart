// v2.6.14: weather alert areas on the Trip map.
// Sample geometry only. Screenshots when WX_SHOTS is set:
//   WX_SHOTS=/opt/cursor/artifacts flutter test test/v2614_wx_map_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';
import 'package:walkie_talkie/ui/wx_map_layer.dart';
import 'package:walkie_talkie/weather/alert_store.dart';
import 'package:walkie_talkie/weather/nws_client.dart';
import 'package:walkie_talkie/weather/weather_alerts.dart';
import 'package:walkie_talkie/weather/wx_alert.dart';
import 'package:walkie_talkie/weather/wx_areas.dart';
import 'package:walkie_talkie/weather/wx_codec.dart';
import 'package:walkie_talkie/weather/wx_geom.dart';
import 'package:walkie_talkie/weather/wx_keys.dart';
import 'package:walkie_talkie/weather/wx_sample.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v250_weather_test.dart' show feat;

final t0 = DateTime.utc(2026, 11, 9, 18);

List<String> ids(String q) => [for (final e in searchSettings(q)) e.id];

/// A box around Portland-ish sample coordinates. Not a real warning.
List<WxPolygon> box(double south, double west, double north, double east) {
  return wxPolygonsFromGeoJson({
    'type': 'Polygon',
    'coordinates': [
      [
        [west, north],
        [east, north],
        [east, south],
        [west, south],
        [west, north],
      ],
    ],
  });
}

WxAlert sampleAlert({
  required String key,
  required String event,
  required WxSeverity severity,
  List<WxPolygon> polygons = const [],
  List<String> ugc = const [],
  WxSource source = WxSource.nws,
  DateTime? expires,
  String headline = '',
  String description = 'Sample text for a test alert. Not a real warning.',
}) {
  return WxAlert(
    key: key,
    event: event,
    severity: severity,
    headline: headline,
    description: description,
    areaDesc: 'Sample County',
    issued: t0.subtract(const Duration(minutes: 10)),
    rev: t0.millisecondsSinceEpoch,
    expires: expires ?? t0.add(const Duration(hours: 1)),
    ugc: ugc,
    polygons: polygons,
    source: source,
    trust: WxTrust.nws,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('polygon data', () {
    test('GeoJSON polygon and multipolygon become rings', () {
      final one = box(45.40, -122.70, 45.60, -122.50);
      expect(one, hasLength(1));
      expect(one.single.outer.length, greaterThanOrEqualTo(3));
      final multi = wxPolygonsFromGeoJson({
        'type': 'MultiPolygon',
        'coordinates': [
          [
            [
              [-122.7, 45.6],
              [-122.6, 45.6],
              [-122.6, 45.5],
              [-122.7, 45.5],
              [-122.7, 45.6],
            ],
          ],
          [
            [
              [-122.4, 45.3],
              [-122.3, 45.3],
              [-122.3, 45.2],
              [-122.4, 45.2],
              [-122.4, 45.3],
            ],
          ],
        ],
      });
      expect(multi, hasLength(2));
      expect(wxPolygonsFromGeoJson(null), isEmpty);
      expect(
        wxPolygonsFromGeoJson({
          'type': 'Point',
          'coordinates': [1, 2],
        }),
        isEmpty,
      );
    });

    test('a hole is outside the area', () {
      final poly = wxPolygonsFromGeoJson({
        'type': 'Polygon',
        'coordinates': [
          [
            [-122.8, 45.7],
            [-122.4, 45.7],
            [-122.4, 45.3],
            [-122.8, 45.3],
            [-122.8, 45.7],
          ],
          [
            [-122.62, 45.52],
            [-122.58, 45.52],
            [-122.58, 45.48],
            [-122.62, 45.48],
            [-122.62, 45.52],
          ],
        ],
      });
      expect(
        pointInWxPolygon(const GeoPoint(45.65, -122.75), poly.single),
        isTrue,
      );
      expect(
        pointInWxPolygon(const GeoPoint(45.50, -122.60), poly.single),
        isFalse,
      );
      expect(
        pointInWxPolygon(const GeoPoint(46.2, -122.6), poly.single),
        isFalse,
      );
    });

    test('NWS feature geometry is kept on the alert and round-trips', () {
      final f = feat();
      f['geometry'] = {
        'type': 'Polygon',
        'coordinates': [
          [
            [-122.7, 45.6],
            [-122.5, 45.6],
            [-122.5, 45.4],
            [-122.7, 45.4],
            [-122.7, 45.6],
          ],
        ],
      };
      final a = WxAlert.fromNws(f)!;
      expect(a.polygons, isNotEmpty);
      final back = WxAlert.fromJson(a.toJson())!;
      expect(back.polygons.single.outer.length, a.polygons.single.outer.length);
      expect(
        pointInWxPolygon(const GeoPoint(45.5, -122.6), back.polygons.single),
        isTrue,
      );
    });

    test('colours follow warning, watch and advisory', () {
      int color(WxKind k, WxSeverity s, {bool extreme = false}) =>
          wxAreaColor(kind: k, severity: s, extreme: extreme);
      expect(color(WxKind.warning, WxSeverity.severe), 0xFFE53935);
      expect(
        color(WxKind.warning, WxSeverity.extreme, extreme: true),
        0xFFB71C1C,
      );
      expect(color(WxKind.watch, WxSeverity.moderate), 0xFFF9A825);
      expect(color(WxKind.advisory, WxSeverity.minor), 0xFF1E88E5);
      final areas = wxMapAreas(
        alerts: [
          sampleAlert(
            key: 'w',
            event: 'Severe Thunderstorm Warning',
            severity: WxSeverity.severe,
            polygons: box(45.4, -122.7, 45.6, -122.5),
          ),
          sampleAlert(
            key: 'a',
            event: 'Wind Advisory',
            severity: WxSeverity.minor,
            polygons: box(45.1, -122.9, 45.3, -122.7),
          ),
        ],
        zones: const {},
        now: t0,
      );
      final drawn = wxPolygonsToDraw(areas);
      expect(drawn, hasLength(2));
      expect(drawn.last.color, isNotNull);
      // The more severe area is painted last, so it sits on top.
      expect(
        drawn.last.borderColor,
        const Color(0xFFE53935).withValues(alpha: 0.9),
      );
    });

    test('zone code without a polygon uses the saved outline', () {
      final zones = {'ORC051': box(45.4, -122.7, 45.6, -122.5)};
      final areas = wxMapAreas(
        alerts: [
          sampleAlert(
            key: 'z',
            event: 'Flood Warning',
            severity: WxSeverity.severe,
            ugc: ['ORC051'],
          ),
        ],
        zones: zones,
        now: t0,
      );
      expect(areas, hasLength(1));
      expect(areas.single.fromZone, isTrue);
      expect(areas.single.containsPoint(const GeoPoint(45.5, -122.6)), isTrue);
      expect(wxAreaOriginSentence(areas.single), contains('county or zone'));
    });

    test('a zone the NWS knows is addressed by its code', () {
      expect(wxZoneUrl('ORZ006')!.path, '/zones/forecast/ORZ006');
      expect(wxZoneUrl('ORC051')!.path, '/zones/county/ORC051');
      expect(wxZoneUrl('ORF001')!.path, '/zones/fire/ORF001');
      expect(wxZoneUrl('not-a-zone'), isNull);
    });
  });

  group('badges and expiry', () {
    final warning = sampleAlert(
      key: 'w',
      event: 'Tornado Warning',
      severity: WxSeverity.severe,
      polygons: box(45.4, -122.7, 45.6, -122.5),
    );
    final watch = sampleAlert(
      key: 'c',
      event: 'Flood Watch',
      severity: WxSeverity.moderate,
      polygons: box(45.45, -122.65, 45.7, -122.4),
    );

    test('a point inside is badged, a point outside is not', () {
      final areas = wxMapAreas(
        alerts: [watch, warning],
        zones: const {},
        now: t0,
      );
      final inside = wxAreasAt(const GeoPoint(45.5, -122.6), areas);
      expect(inside.map((a) => a.event), ['Tornado Warning', 'Flood Watch']);
      expect(wxInAlertLine(inside), 'In 2 weather alerts: Tornado Warning');
      expect(wxAreasAt(const GeoPoint(44.0, -122.6), areas), isEmpty);
      expect(wxInAlertLine(const []), isEmpty);
      final nodes = wxNodesInside(
        nodes: const [
          WxNodeSpot(id: 7, name: 'Ridge', pos: GeoPoint(45.5, -122.6)),
          WxNodeSpot(id: 8, name: 'Far', pos: GeoPoint(44.0, -122.6)),
          WxNodeSpot(
            id: 9,
            name: 'Public',
            pos: GeoPoint(45.5, -122.6),
            public: true,
          ),
          WxNodeSpot(
            id: 1,
            name: 'Me',
            pos: GeoPoint(45.5, -122.6),
            self: true,
          ),
          WxNodeSpot(id: 4, name: 'Friend radio', pos: GeoPoint(45.5, -122.6)),
        ],
        skipIds: {4},
        areas: areas,
      );
      expect(nodes.map((n) => n.id), [7]);
    });

    test('an expired alert is not drawn and does not badge anyone', () {
      final old = sampleAlert(
        key: 'old',
        event: 'Tornado Warning',
        severity: WxSeverity.severe,
        polygons: box(45.4, -122.7, 45.6, -122.5),
        expires: t0.subtract(const Duration(minutes: 1)),
      );
      final areas = wxMapAreas(alerts: [old], zones: const {}, now: t0);
      expect(areas, isEmpty);
      expect(
        wxInAlertLine(wxAreasAt(const GeoPoint(45.5, -122.6), areas)),
        isEmpty,
      );
      expect(
        wxLayerEmptyNote(layerOn: true, activeCount: 0),
        'No active alerts',
      );
      expect(wxLayerEmptyNote(layerOn: false, activeCount: 0), isNull);
      expect(wxLayerEmptyNote(layerOn: true, activeCount: 1), isNull);
    });

    test('a later radio copy does not wipe a saved shape', () {
      final store = AlertStore(clock: () => t0, kinds: WxKind.values.toSet());
      final shaped = sampleAlert(
        key: 'vtec:KPQR.TO.W.0012.2026',
        event: 'Tornado Warning',
        severity: WxSeverity.severe,
        polygons: box(45.4, -122.7, 45.6, -122.5),
        ugc: ['ORZ006'],
      );
      store.ingest([shaped]);
      expect(shaped.copyWith().polygons, isNotEmpty);
      final bare = WxAlert(
        key: shaped.key,
        event: shaped.event,
        severity: shaped.severity,
        issued: shaped.issued,
        rev: shaped.rev + 1000,
        expires: shaped.expires,
        ugc: shaped.ugc,
        source: WxSource.lora,
        trust: WxTrust.confirmed,
      );
      store.ingest([bare]);
      expect(store.byKey(shaped.key)!.polygons, isNotEmpty);
    });
  });

  group('Saver and the wire', () {
    test('zone outlines are not fetched in Saver or with the layer off', () {
      expect(
        wxZoneFetchAllowed(
          layerOn: true,
          alertsOn: true,
          saver: true,
          networkOk: true,
        ),
        isFalse,
      );
      expect(
        wxZoneFetchAllowed(
          layerOn: false,
          alertsOn: true,
          saver: false,
          networkOk: true,
        ),
        isFalse,
      );
      expect(
        wxZoneFetchAllowed(
          layerOn: true,
          alertsOn: true,
          saver: false,
          networkOk: false,
        ),
        isFalse,
      );
      expect(
        wxZoneFetchAllowed(
          layerOn: true,
          alertsOn: true,
          saver: false,
          networkOk: true,
        ),
        isTrue,
      );
      expect(
        wxOutlineHint(
          layerOn: true,
          saver: true,
          pending: true,
          fetchFailed: true,
        ),
        contains('Saver'),
      );
    });

    test('fillZones does nothing while Saver blocks it, then caches', () async {
      var fetches = 0;
      var allow = false;
      final cache = WxZoneCache(clock: () => t0);
      final service = WeatherAlerts(
        store: AlertStore(clock: () => t0),
        client: NwsClient(
          userAgent: 'WalkieTalkie/test',
          fetch: (_, _) async => const WxResponse(500, ''),
        ),
        points: () => const [],
        zoneCache: cache,
        fetchZone: (code) async {
          fetches++;
          return WxZoneRecord(
            code: code,
            at: t0,
            polygons: box(45.4, -122.7, 45.6, -122.5),
            missing: false,
          );
        },
        allowZoneFetch: () => allow,
        clock: () => t0,
      );
      await service.handle([
        sampleAlert(
          key: 'vtec:KPQR.FF.W.0001.2026',
          event: 'Flash Flood Warning',
          severity: WxSeverity.severe,
          ugc: ['ORZ006'],
        ),
      ]);
      expect(fetches, 0, reason: 'Saver (allow is false) must not download');
      expect(service.zoneFetches, 0);
      allow = true;
      await service.fillZones();
      expect(fetches, 1);
      expect(service.zoneOutlines(t0)['ORZ006'], isNotEmpty);
      await service.fillZones();
      expect(fetches, 1, reason: 'a fresh outline is not downloaded again');
      final areas = wxMapAreas(
        alerts: service.active,
        zones: service.zoneOutlines(t0),
        now: t0,
      );
      expect(areas.single.fromZone, isTrue);
      expect(areas.single.source, WxSource.nws);
    });

    test('an alert that already has a shape does not fetch its zone', () async {
      var fetches = 0;
      final service = WeatherAlerts(
        store: AlertStore(clock: () => t0),
        client: NwsClient(
          userAgent: 'WalkieTalkie/test',
          fetch: (_, _) async => const WxResponse(500, ''),
        ),
        points: () => const [],
        zoneCache: WxZoneCache(clock: () => t0),
        fetchZone: (code) async {
          fetches++;
          return null;
        },
        allowZoneFetch: () => true,
        clock: () => t0,
      );
      await service.handle([
        sampleAlert(
          key: 'shaped',
          event: 'Tornado Warning',
          severity: WxSeverity.severe,
          ugc: ['ORZ006'],
          polygons: box(45.4, -122.7, 45.6, -122.5),
        ),
      ]);
      expect(fetches, 0);
    });

    test('the radio packet is unchanged when a shape is added', () async {
      final key = await WxDeviceKey.generate();
      final base = sampleAlert(
        key: 'vtec:KPQR.TO.W.0012.2026',
        event: 'Tornado Warning',
        severity: WxSeverity.severe,
        ugc: ['ORZ006'],
      );
      final shaped = base.copyWith(polygons: box(45.4, -122.7, 45.6, -122.5));
      final plain = await wxEncodeCompact(base, key: key, nodeId: 0xA1);
      final extra = await wxEncodeCompact(shaped, key: key, nodeId: 0xA1);
      expect(plain, isNotNull);
      expect(extra!.packets.first, plain!.packets.first);
      final decoded = wxDecode(extra.packets.first)!;
      expect(decoded.alert!.polygons, isEmpty);
      expect(
        wxAreaOriginSentence(
          wxMapAreas(
            alerts: [decoded.alert!.copyWith(polygons: const [])],
            zones: {'ORZ006': box(45.4, -122.7, 45.6, -122.5)},
            now: t0,
          ).single,
        ),
        contains('too small'),
      );
    });

    test(
      'a relay copy can carry a simplified shape older apps ignore',
      () async {
        final key = await WxDeviceKey.generate();
        final shaped = sampleAlert(
          key: 'vtec:KPQR.TO.W.0012.2026',
          event: 'Tornado Warning',
          severity: WxSeverity.severe,
          ugc: ['ORZ006'],
          polygons: box(45.4, -122.7, 45.6, -122.5),
        );
        final full = await wxEncodeFull(shaped, key: key, nodeId: 0xA1);
        final decoded = wxDecode(full)!;
        expect(await decoded.verify(0xA1), isTrue);
        expect(decoded.alert!.polygons, isNotEmpty);
        expect(
          pointInWxPolygon(
            const GeoPoint(45.5, -122.6),
            decoded.alert!.polygons.single,
          ),
          isTrue,
        );
      },
    );
  });

  group('sample weather hook', () {
    test('release and a normal debug run do not turn it on', () {
      expect(sampleWeatherActive(debug: false, enabled: true), isFalse);
      expect(sampleWeatherActive(debug: true, enabled: false), isFalse);
      expect(sampleWeatherActive(debug: false, enabled: false), isFalse);
      expect(sampleWeatherActive(debug: true, enabled: true), isTrue);
      // This test binary was not built with SAMPLE_WX, so the default is off
      // even though widget tests run as debug.
      expect(sampleWeatherActive(), isFalse);
    });

    test(
      'sample alerts sit on real Oregon counties and a friend is inside one',
      () {
        final now = DateTime.utc(2026, 11, 10, 16);
        final alerts = sampleOregonAlerts(now);
        expect(alerts.map((a) => a.event), [
          'Winter Storm Warning',
          'Wind Advisory',
          'Flood Watch',
        ]);
        expect(alerts.map((a) => a.kind), [
          WxKind.warning,
          WxKind.advisory,
          WxKind.watch,
        ]);
        expect(alerts.every((a) => a.key.startsWith('sample:')), isTrue);
        expect(alerts.every((a) => a.polygons.length == 1), isTrue);
        final areas = wxMapAreas(alerts: alerts, zones: const {}, now: now);
        expect(areas, hasLength(3));
        final here = wxAreasAt(sampleFriendPoint, areas);
        expect(here.map((a) => a.event), ['Winter Storm Warning']);
        expect(wxInAlertLine(here), contains('Winter Storm Warning'));
        // Hillsboro is Washington County, not Multnomah.
        expect(
          wxAreasAt(const GeoPoint(45.5229, -122.9898), areas).single.event,
          'Wind Advisory',
        );
      },
    );

    test('cancels remove the samples and they do not notify', () async {
      final now = DateTime.utc(2026, 11, 10, 16);
      final notified = <WxAlert>[];
      final service = WeatherAlerts(
        store: AlertStore(clock: () => now),
        client: NwsClient(
          userAgent: 'WalkieTalkie/test',
          fetch: (_, _) async => const WxResponse(500, ''),
        ),
        points: () => const [],
        onNotify: (a) async => notified.add(a),
        clock: () => now,
      );
      await service.replaceSamples(sampleOregonAlerts(now));
      expect(service.active.map((a) => a.event), [
        'Winter Storm Warning',
        'Flood Watch',
        'Wind Advisory',
      ]);
      expect(notified, isEmpty);
      expect(service.zoneFetches, 0);
      await service.replaceSamples(
        sampleAlertCancels(now.add(const Duration(seconds: 1))),
      );
      expect(service.active, isEmpty);
      expect(notified, isEmpty);
    });
  });

  group('settings search', () {
    test('weather, alerts, storm and warning find the map switch', () {
      for (final q in ['weather', 'alerts', 'storm', 'warning']) {
        expect(ids(q), contains('wx-map'), reason: q);
      }
      expect(ids('weather').first, 'weather');
      final entry = settingsIndex.firstWhere((e) => e.id == 'wx-map');
      expect(entry.label, 'Show alert areas on the map');
      expect(entry.needs, SettingNeeds.weatherOn);
      final page = File('lib/ui/weather_alerts_page.dart').readAsStringSync();
      expect(page, contains("id: 'wx-map'"));
      expect(page, contains(entry.label));
    });

    test('version is 2.6.14+74', () {
      final p = File('pubspec.yaml').readAsStringSync();
      expect(p, contains('version: 2.6.14+74'));
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains('## v2.6.14: Weather on the Trip map'));
      expect(readme, contains('No active alerts'));
      expect(readme, contains('Battery mode Saver'));
    });
  });

  group('No active alerts', () {
    testWidgets(
      'the note shows only while the layer is on and nothing is active',
      (t) async {
        Future<void> pump({required bool on, required int n}) => t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WxMapLayerTile(on: on, activeCount: n, onChanged: (_) {}),
            ),
          ),
        );
        await pump(on: true, n: 0);
        expect(find.byKey(const Key('wx-no-alerts')), findsOneWidget);
        expect(find.text('No active alerts'), findsOneWidget);
        expect(find.byKey(const Key('wx-map-layer')), findsOneWidget);

        await pump(on: false, n: 0);
        expect(find.byKey(const Key('wx-no-alerts')), findsNothing);

        await pump(on: true, n: 2);
        expect(find.byKey(const Key('wx-no-alerts')), findsNothing);
      },
    );

    testWidgets('the sheet says headline, severity, expiry and description', (
      t,
    ) async {
      final now = DateTime.now().toUtc();
      final area = wxMapAreas(
        alerts: [
          sampleAlert(
            key: 'w',
            event: 'Severe Thunderstorm Warning',
            severity: WxSeverity.severe,
            headline: 'Sample tornado warning',
            description: 'This is sample text, not a real storm.',
            polygons: box(45.4, -122.7, 45.6, -122.5),
            expires: now.add(const Duration(hours: 2)),
          ),
        ],
        zones: const {},
        now: now,
      ).single;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: WxAreaSheet(area: area)),
          ),
        ),
      );
      expect(find.byKey(const Key('wx-area-headline')), findsOneWidget);
      expect(find.text('Sample tornado warning'), findsOneWidget);
      expect(find.textContaining('Severe warning'), findsOneWidget);
      expect(find.textContaining('Ends'), findsOneWidget);
      expect(find.textContaining('sample text'), findsOneWidget);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['WX_SHOTS'];
    if (dir == null) return;

    setUpAll(loadFonts);

    Future<void> shot(
      WidgetTester t,
      String name,
      Widget body,
      Size size,
    ) async {
      t.view.physicalSize = size * 2;
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
            home: Scaffold(
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: const Color(0xFFFFF3C4),
                    padding: const EdgeInsets.fromLTRB(12, 28, 12, 8),
                    child: const Text(
                      'SAMPLE DATA — not a live weather warning',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    List<WxMapArea> samples() => wxMapAreas(
      alerts: [
        sampleAlert(
          key: 'tor',
          event: 'Sample Tornado Warning',
          severity: WxSeverity.extreme,
          headline: 'Sample tornado warning',
          description: 'Sample text. Take cover in an interior room.',
          polygons: box(45.48, -122.72, 45.62, -122.52),
        ),
        sampleAlert(
          key: 'watch',
          event: 'Sample Flood Watch',
          severity: WxSeverity.moderate,
          polygons: box(45.30, -122.80, 45.50, -122.40),
        ),
        sampleAlert(
          key: 'adv',
          event: 'Sample Wind Advisory',
          severity: WxSeverity.minor,
          polygons: box(45.55, -122.50, 45.75, -122.25),
        ),
      ],
      zones: const {},
      now: t0,
    );

    testWidgets('map, badge, sheet and empty toggle', (t) async {
      final areas = samples();
      await shot(
        t,
        'wx_map_areas',
        ColoredBox(
          color: const Color(0xFFD7E6C8),
          child: FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(45.52, -122.55),
              initialZoom: 9.4,
              interactionOptions: InteractionOptions(
                flags: InteractiveFlag.none,
              ),
            ),
            children: [
              PolygonLayer(polygons: wxPolygonsToDraw(areas)),
              MarkerLayer(
                markers: [
                  Marker(
                    point: const LatLng(45.55, -122.62),
                    width: 150,
                    height: 56,
                    child: WxNodeMarker(
                      name: 'Sample Node',
                      alertLine: wxInAlertLine(
                        wxAreasAt(const GeoPoint(45.55, -122.62), areas),
                      ),
                      badgeKey: const Key('shot-badge'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Size(420, 640),
      );

      await shot(
        t,
        'wx_node_badge',
        const Center(
          child: SizedBox(
            width: 180,
            height: 80,
            child: WxNodeMarker(
              name: 'Sample Node',
              alertLine: 'In a weather alert: Sample Tornado Warning',
              badgeKey: Key('shot-badge-close'),
            ),
          ),
        ),
        const Size(420, 280),
      );

      final top = wxAreasAt(const GeoPoint(45.55, -122.62), areas).first;
      await shot(
        t,
        'wx_alert_sheet',
        SingleChildScrollView(child: WxAreaSheet(area: top)),
        const Size(420, 640),
      );

      await shot(
        t,
        'wx_no_alerts',
        WxMapLayerTile(on: true, activeCount: 0, onChanged: (_) {}),
        const Size(420, 280),
      );
      expect(find.text('No active alerts'), findsOneWidget);
    });
  });
}
