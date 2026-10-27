import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:walkie_talkie/app/power_plan.dart';
import 'package:walkie_talkie/trip/fires.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imports/geo_import.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/nav/nav_session.dart';
import 'package:walkie_talkie/trip/nav/navigator.dart';
import 'package:walkie_talkie/trip/nav/trail_graph.dart';
import 'package:walkie_talkie/trip/slope.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_layer_widgets.dart';
import 'package:walkie_talkie/ui/nav_page.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'trip_integration_test.dart' show FakeHost;

const lat0 = 45.75, lng0 = -122.25;

/// A point [e] metres east and [n] metres north of the test origin.
GeoPoint at(double e, double n) => GeoPoint(
  lat0 + n / 111132.954,
  lng0 + e / (111319.49 * cos(lat0 * pi / 180)),
);

List<GeoPoint> line(
  double e0,
  double n0,
  double e1,
  double n1, {
  int steps = 20,
}) => [
  for (var i = 0; i <= steps; i++)
    at(e0 + (e1 - e0) * i / steps, n0 + (n1 - n0) * i / steps),
];

/// A terrarium PNG tile from an elevation function of pixel x, y.
Uint8List terrariumTile(double Function(int x, int y) f, {int n = 64}) {
  final im = img.Image(width: n, height: n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final v = f(x, y) + 32768;
      final r = v ~/ 256,
          g = v.floor() % 256,
          b = ((v - v.floor()) * 256).floor();
      im.setPixelRgb(x, y, r, g, b);
    }
  }
  return img.encodePng(im);
}

void main() {
  group('map styles and overlays', () {
    test('every style and overlay, offline rules', () {
      expect(MapSource.bases.map((s) => s.id), [
        'usgs_topo',
        'topo',
        'usgs_imagery',
        'usgs_hybrid',
        'usgs_relief',
        'osm',
      ]);
      expect(MapSource.overlays.map((s) => s.id), [
        'ov_land',
        'ov_wild',
        'ov_fs_trails',
        'ov_fs_roads',
        'ov_slope',
        'ov_fires',
      ]);
      for (final s in [...MapSource.bases, ...MapSource.overlays]) {
        expect(s.attribution, isNotEmpty, reason: s.id);
        expect(MapSource.byId(s.id), same(s));
      }
      expect(MapSource.osm.allowsOffline, isFalse);
      expect(MapSource.fires.onlineOnly, isTrue);
      expect(
        MapSource.bases.where((s) => s.allowsOffline).map((s) => s.id),
        isNot(contains('osm')),
      );
      expect(MapSource.overlays.every((o) => o.overlay), isTrue);
    });

    test('ArcGIS tile order {z}/{y}/{x} and export bbox', () {
      expect(
        MapSource.usgsTopo.urlFor(14, 2628, 5845),
        'https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/'
        'MapServer/tile/14/5845/2628',
      );
      final u = Uri.parse(MapSource.fsTrails.urlFor(13, 1314, 2922));
      expect(u.path, endsWith('EDW_TrailNFSPublish_01/MapServer/export'));
      expect(
        u.queryParameters['bbox'],
        '-13609460.01,5738280.59,-13604568.04,5743172.56',
      );
      expect(u.queryParameters['transparent'], 'true');
      expect(
        MapSource.terrarium.urlFor(12, 657, 1461),
        endsWith('/terrarium/12/657/1461.png'),
      );
    });

    test('settings: base map and overlays persist', () {
      final s = TripSettings()
        ..mapSource = 'usgs_relief'
        ..overlays = ['ov_slope', 'ov_land'];
      final d = TripSettings.decode(s.encode());
      expect(d.mapSource, 'usgs_relief');
      expect(d.overlays, ['ov_slope', 'ov_land']);
      expect(TripSettings.decode('{}').overlays, isEmpty);
    });

    test('trip picks the style; overlays in drawing order', () {
      final tmp = Directory.systemTemp.createTempSync('style');
      final t = TripController(
        host: FakeHost(1),
        settings: TripSettings(
          mapSource: 'usgs_imagery',
          overlays: ['ov_fires', 'ov_land', 'nope'],
        ),
        dir: tmp,
        userAgent: 'test',
      );
      expect(t.mapSource.id, 'usgs_imagery');
      expect(t.overlays.map((o) => o.id), ['ov_land', 'ov_fires']);
      t.settings.mapSource = 'mbtiles:x';
      expect(t.mapSource.id, 'topo', reason: 'online map under an MBTiles');
      t.dispose();
      tmp.deleteSync(recursive: true);
    });
  });

  group('slope shading and elevation', () {
    test('terrarium decoding', () {
      expect(terrariumElevation(128, 0, 0), 0);
      expect(terrariumElevation(131, 232, 128), closeTo(1000.5, 1e-9));
      final t = terrariumTile((x, y) => 1234.25, n: 8);
      final d = decodeTerrarium(t)!;
      expect(d.size, 8);
      expect(d.h.every((e) => (e - 1234.25).abs() < 0.01), isTrue);
    });

    test('pixel size and slope classes', () {
      // Zoom 14 at ~45 deg N: about 6.7 m per pixel.
      final m = tilePixelMetres(14, 5845);
      expect(m, closeTo(6.8, 0.3));
      expect(slopeColor(10)[3], 0);
      expect(slopeColor(28), [247, 228, 0, 255]);
      expect(slopeColor(32), [247, 148, 0, 255]);
      expect(slopeColor(40), [230, 0, 0, 255]);
      expect(slopeColor(50), [150, 0, 200, 255]);
    });

    test('a 38 degree plane is shaded red, a flat one is clear', () {
      const z = 14, y = 5845;
      final px = tilePixelMetres(z, y, size: 64);
      final rise = tan(38 * pi / 180) * px;
      final steep = slopeTilePng(
        terrariumTile((x, _) => 1000 + x * rise),
        z,
        y,
      )!;
      final s = img.decodePng(steep)!;
      final c = s.getPixel(32, 32);
      expect([c.r, c.g, c.b, c.a], [230, 0, 0, 255]);
      final flat = img.decodePng(
        slopeTilePng(terrariumTile((_, _) => 500), z, y)!,
      )!;
      expect(flat.getPixel(10, 10).a, 0);
      final deg = slopeDegrees(
        decodeTerrarium(terrariumTile((x, _) => x * rise))!.h,
        64,
        px,
      );
      expect(deg[64 * 30 + 30], closeTo(38, 0.5));
    });

    test('DEM sampler reads the right tile and interpolates', () async {
      final asked = <String>[];
      final dem = DemSampler((z, x, y) async {
        asked.add('$z/$x/$y');
        return terrariumTile((px, py) => 100.0 + px, n: 256);
      });
      final e = await dem.elevationAt(45.75, -122.24);
      expect(asked.single, '12/${tileX(-122.24, 12)}/${tileY(45.75, 12)}');
      expect(e, inInclusiveRange(100, 356));
      await dem.elevationAt(45.7501, -122.2401);
      expect(asked, hasLength(1), reason: 'tile kept');
      final none = DemSampler((_, _, _) async => null);
      expect(await none.elevationAt(45, -122), isNull);
    });
  });

  group('wildfire perimeters', () {
    test('query and GeoJSON parsing', () async {
      final u = FireService.queryUri(const GeoBounds(45, -123, 46, -122));
      expect(u.host, 'services3.arcgis.com');
      expect(u.path, contains('WFIGS_Interagency_Perimeters_Current'));
      expect(u.queryParameters['f'], 'geojson');
      expect(u.queryParameters['geometry'], '-123.0,45.0,-122.0,46.0');
      final geo = jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'properties': {
              'poly_IncidentName': 'Rock Creek',
              'attr_IncidentSize': 1234.4,
              'attr_PercentContained': 40,
              'poly_DateCurrent': 1788897132000,
            },
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [-122.3, 45.7],
                  [-122.2, 45.7],
                  [-122.2, 45.8],
                  [-122.3, 45.7],
                ],
              ],
            },
          },
          {
            'properties': {'poly_IncidentName': 'Two Parts'},
            'geometry': {
              'type': 'MultiPolygon',
              'coordinates': [
                [
                  [
                    [-121, 45],
                    [-121.1, 45],
                    [-121.1, 45.1],
                  ],
                ],
                [
                  [
                    [-120, 45],
                    [-120.1, 45],
                    [-120.1, 45.1],
                  ],
                ],
              ],
            },
          },
          {'properties': {}, 'geometry': null},
        ],
      });
      final f = FireService.parse(geo);
      expect(f, hasLength(2));
      expect(f.first.label, 'Rock Creek · 1234 ac · 40% contained');
      expect(f.first.rings.single.first, const GeoPoint(45.7, -122.3));
      expect(f.last.rings, hasLength(2));
      expect(FireService.parse('nope'), isEmpty);
      final svc = FireService(get: (_) async => null);
      expect(await svc.inArea(const GeoBounds(45, -123, 46, -122)), isEmpty);
    });
  });

  group('GPX elevations', () {
    test('kept through parsing, simplifying and storage', () async {
      final pts = [
        for (var i = 0; i < 600; i++)
          '<trkpt lat="${45.7 + i * 0.0001}" lon="-122.2"><ele>${100 + i}</ele></trkpt>',
      ].join();
      final gpx =
          '<gpx version="1.1"><trk><name>Up</name><trkseg>$pts</trkseg></trk></gpx>';
      final d = tidyImport(parseTrailFile('up.gpx', utf8.encode(gpx)));
      final l = d.lines.single;
      expect(l.ele, isNotNull);
      expect(l.ele!.length, l.points.length);
      expect(l.points.length, lessThan(600), reason: 'straight: simplified');
      expect(l.ele!.first, 100);
      expect(l.ele!.last, 699);
      final tmp = Directory.systemTemp.createTempSync('ele');
      final layers = MapLayers(Directory('${tmp.path}/l'));
      await layers.importTrail('up.gpx', utf8.encode(gpx));
      final again = MapLayers(Directory('${tmp.path}/l'));
      await again.load();
      final e = again.trails.single.data!.lines.single.ele!;
      expect(e.first, 100);
      expect(e.last, 699);
      layers.close();
      again.close();
      tmp.deleteSync(recursive: true);
      final noEle = parseGpx(
        '<gpx><trk><trkseg><trkpt lat="45" lon="-122"/><trkpt lat="45.1" lon="-122"/></trkseg></trk></gpx>',
      );
      expect(noEle.lines.single.ele, isNull);
    });
  });

  group('trail graph', () {
    test('crossing trails meet at a junction; turn and name', () {
      // A west-east trail and a south-north trail crossing at the origin.
      final g = TrailGraph.build([
        GraphLine('East West', line(-500, 0, 500, 0)),
        GraphLine('North South', line(0, -500, 0, 500, steps: 7)),
      ]);
      expect(g.components, 1);
      final r = g.route(at(-500, 0), at(0, 500))!;
      expect(r.lengthM, closeTo(1000, 15));
      expect(r.startOffM, lessThan(1));
      expect(r.junctions, hasLength(1));
      expect(r.junctions.single.turn, 'left');
      expect(r.junctions.single.next, 'North South');
      expect(r.junctions.single.text, 'Turn left onto North South');
      expect(r.junctions.single.alongM, closeTo(500, 15));
      final straight = g.route(at(-500, 0), at(500, 0))!;
      expect(straight.junctions, isEmpty, reason: 'same trail, straight on');
    });

    test('a trail ending near another joins it (T junction)', () {
      final g = TrailGraph.build([
        GraphLine('Main', line(-500, 0, 500, 0)),
        // Ends 15 m short of Main, between its points.
        GraphLine('Spur', line(13, 500, 13, 15, steps: 10)),
      ]);
      expect(g.components, 1);
      final r = g.route(at(-500, 0), at(13, 500))!;
      expect(r.lengthM, closeTo(513 + 500, 30));
      expect(r.junctions.single.turn, 'left');
    });

    test('a short gap gets an off-trail link; a big one does not', () {
      final near = TrailGraph.build([
        GraphLine('A', line(-500, 0, 0, 0)),
        GraphLine('B', line(60, 0, 560, 0)),
      ]);
      expect(near.components, 1);
      final r = near.route(at(-500, 0), at(560, 0))!;
      expect(r.lengthM, closeTo(1060, 20));
      expect(
        r.junctions.map((j) => j.next),
        contains('a short off-trail link'),
      );
      final far = TrailGraph.build([
        GraphLine('A', line(-500, 0, 0, 0)),
        GraphLine('B', line(300, 0, 800, 0)),
      ]);
      expect(far.components, 2);
      // Start near A, target on B: the less off-trail option is used.
      final r2 = far.route(at(-500, 5), at(800, 0))!;
      expect(r2.startOffM + r2.endOffM, closeTo(805, 10));
    });

    test('switchbacks of one trail are not short-cut', () {
      // Zig-zag: legs 6 m apart (closer than the join distance).
      final pts = <GeoPoint>[];
      for (var k = 0; k < 6; k++) {
        pts.addAll(line(0, k * 6.0, 300, k * 6.0, steps: 10));
        pts.addAll(line(300, k * 6.0 + 3, 0, k * 6.0 + 3, steps: 10));
      }
      final g = TrailGraph.build([GraphLine('Zig', pts)]);
      final r = g.route(pts.first, pts.last)!;
      expect(r.lengthM, greaterThan(3000), reason: 'walks every leg');
    });

    test('wilderness boundary lines are not trails', () {
      final g = TrailGraph.build([
        GraphLine('Trapper Creek Wilderness boundary', line(-500, 0, 500, 0)),
      ]);
      expect(g.isEmpty, isTrue);
      expect(g.route(at(0, 0), at(1, 1)), isNull);
    });

    test('start and target on the same stretch', () {
      final g = TrailGraph.build([
        GraphLine('A', line(0, 0, 1000, 0, steps: 1)),
      ]);
      final r = g.route(at(100, 10), at(400, -10))!;
      expect(r.lengthM, closeTo(10 + 300 + 10, 3));
      expect(r.startOffM, closeTo(10, 1));
    });

    test('Naismith and climb', () {
      expect(naismith(10000, 0), const Duration(hours: 2));
      expect(naismith(5000, 600), const Duration(hours: 2));
      final r = TrailRoute(
        [at(0, 0), at(100, 0), at(200, 0), at(300, 0), at(400, 0)],
        [100, 101, 150, 149, 120],
        [],
        startOffM: 0,
        endOffM: 0,
      );
      final c = r.climb();
      expect(c.gain, closeTo(50, 1e-9));
      expect(c.loss, closeTo(30, 1e-9));
      expect(r.climb(fromM: 250).gain, 0);
      expect(r.profile(), hasLength(5));
    });

    test('real map pack trails route between waypoints', () {
      final d = tidyImport(
        parseTrailFile(
          'Silver_Star_Trails.gpx',
          File('assets/map_packs/Silver_Star_Trails.gpx').readAsBytesSync(),
        ),
      );
      final g = TrailGraph.build([
        for (final l in d.lines) GraphLine(l.name, l.points, l.ele),
      ]);
      expect(g.nodeCount, greaterThan(3000));
      GeoPoint wp(String n) => d.waypoints.firstWhere((w) => w.name == n).pos;
      final r = g.route(wp('Grouse Vista Trailhead'), wp('Hidden Falls'))!;
      expect(r.lengthM, inInclusiveRange(7000, 9500));
      expect(r.startOffM, lessThan(50));
      final s = g.route(
        wp('Silver Star Mountain Trailhead'),
        wp('Silver Star Mountain'),
      )!;
      expect(s.lengthM, inInclusiveRange(2000, 6000));
      expect(s.endOffM, lessThan(150));
    });
  });

  group('following a route', () {
    TrailRoute route() {
      final g = TrailGraph.build([
        GraphLine('East West', line(-500, 0, 500, 0)),
        GraphLine('North South', line(0, -500, 0, 500, steps: 7)),
      ]);
      return g.route(at(-500, 0), at(0, 500))!;
    }

    test('progress, next junction, ETA', () {
      final f = RouteFollower(route());
      final s = f.update(at(-200, 3));
      expect(s.alongM, closeTo(300, 15));
      expect(s.leftM, closeTo(700, 20));
      expect(s.offRoute, isFalse);
      expect(s.next!.text, 'Turn left onto North South');
      expect(s.nextInM, closeTo(200, 15));
      expect(s.bearingAhead, closeTo(90, 10));
      expect(s.eta.inMinutes, closeTo(8, 1));
      final past = f.update(at(2, 200));
      expect(past.next, isNull);
      expect(past.bearingAhead, closeTo(0, 10));
      final end = f.update(at(0, 495));
      expect(end.arrived, isTrue);
    });

    test('off route after 40 m twice: one alert, arrow back', () {
      final f = RouteFollower(route());
      f.update(at(-300, 0));
      expect(f.update(at(-300, 60)).offRoute, isFalse, reason: 'one fix');
      final s = f.update(at(-300, 65));
      expect(s.offRoute, isTrue);
      expect(f.offEvents, 1);
      expect(s.bearingToRoute, closeTo(180, 5), reason: 'south, back to it');
      f.update(at(-290, 70));
      expect(f.offEvents, 1, reason: 'still the same excursion');
      expect(f.update(at(-280, 5)).offRoute, isFalse);
      f.update(at(-250, 80));
      f.update(at(-250, 80));
      expect(f.offEvents, 2);
    });

    test('session events and the route as shareable data', () {
      final s = NavSession(target: at(0, 500), name: 'Peak', route: route());
      expect(s.update(at(-300, 0)), isNull);
      s.update(at(-300, 70));
      expect(s.update(at(-300, 70)), 'off');
      expect(s.update(at(0, 498)), 'arrived');
      final d = s.asData();
      expect(d.lines.single.isRoute, isTrue);
      expect(d.waypoints.single.name, 'Peak');
      final c = NavSession(target: at(0, 500), name: 'X');
      expect(c.compass, isTrue);
      c.update(at(0, 0));
      expect(c.straightM, closeTo(500, 2));
      expect(c.straightBearing, closeTo(0, 1));
    });

    test('elevation from the DEM, else the GPX', () async {
      final r = route();
      // DEM: elevation rises to the north (pixel row up).
      final src = await fillElevation(
        r,
        (z, x, y) async => terrariumTile((px, py) => 1000.0 - py * 2, n: 256),
      );
      expect(src, 'dem');
      expect(r.hasElevation, isTrue);
      final r2 = route();
      expect(await fillElevation(r2, (_, _, _) async => null), '');
    });
  });

  group('navigation in the trip', () {
    late Directory tmp;
    late FakeHost host;
    late TripController t;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('nav');
      host = FakeHost(1);
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
      )..tiles.online = false;
      await t.layers.load();
      await t.start();
    });
    tearDown(() {
      t.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('navigate along an imported trail, faster GPS, stop', () async {
      await t.layers.addTrail(
        ImportedData(
          name: 'Cross',
          lines: [
            ImportedLine('East West', line(-500, 0, 500, 0)),
            ImportedLine('North South', line(0, -500, 0, 500, steps: 7)),
          ],
        ),
      );
      t.onFix(Fix(at(-500, 0), DateTime.now()));
      final before = t.locationInterval;
      final s = await t.navigateTo(at(0, 500), name: 'Lookout');
      expect(s.compass, isFalse);
      expect(s.route!.lengthM, closeTo(1000, 20));
      expect(s.note, contains('No elevation data'));
      expect(t.locationInterval, const PowerPlan().navInterval);
      expect(t.locationInterval, isNot(before));
      await t.setOfflineSaver(true);
      expect(t.locationInterval, const Duration(seconds: 10));
      // Going off route: notification.
      t.onFix(Fix(at(-300, 70), DateTime.now()));
      t.onFix(Fix(at(-300, 70), DateTime.now()));
      expect(host.notes.last, startsWith('Off route:'));
      expect(host.notes.last, contains('Head S'));
      // Share the planned route.
      final n = host.sent.length;
      final sh = t.shareNavRoute();
      expect(sh.parts, greaterThan(0));
      expect(host.sent.length, greaterThan(n));
      expect(host.sent.last.msg, isA<TripMsg>());
      await t.stopNav();
      expect(t.nav, isNull);
      expect(t.locationInterval, isNot(const Duration(seconds: 10)));
    });

    test('no trails: compass mode', () async {
      t.onFix(Fix(at(0, 0), DateTime.now()));
      final s = await t.navigateTo(at(300, 400), name: 'Lake');
      expect(s.compass, isTrue);
      expect(s.note, contains('No trails'));
      expect(s.straightM, closeTo(500, 3));
    });

    testWidgets('follow screen and map card', (tester) async {
      await tester.runAsync(() async {
        await t.layers.addTrail(
          ImportedData(
            name: 'Cross',
            lines: [
              ImportedLine('East West', line(-500, 0, 500, 0)),
              ImportedLine('North South', line(0, -500, 0, 500, steps: 7)),
            ],
          ),
        );
        t.onFix(Fix(at(-500, 0), DateTime.now()));
        final s = await t.navigateTo(at(0, 500), name: 'Lookout');
        s.route!.ele = [
          for (var i = 0; i < s.route!.points.length; i++) 100.0 + i,
        ];
        t.onFix(Fix(at(-200, 0), DateTime.now()));
      });
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: NavFollowPage(trip: t)));
      expect(find.text('To Lookout'), findsOneWidget);
      expect(
        find.textContaining('Next junction: Turn left onto North South'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('profile')), findsOneWidget);
      expect(find.text('Share route'), findsOneWidget);
      expect(find.text('Re-route'), findsOneWidget);
      await tester.runAsync(() async {
        t.onFix(Fix(at(-200, 80), DateTime.now()));
        t.onFix(Fix(at(-200, 85), DateTime.now()));
      });
      await tester.pump();
      expect(find.byKey(const Key('offRoute')), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NavCard(trip: t, session: t.nav!, onFollow: () {}),
          ),
        ),
      );
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(find.textContaining('Off route by'), findsOneWidget);
    });
  });

  testWidgets('base map + every overlay builds on the map; fires drawn', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('ovw');
    final t = TripController(
      host: FakeHost(1),
      settings: TripSettings(
        mapSource: 'usgs_topo',
        overlays: [for (final o in MapSource.overlays) o.id],
      ),
      dir: tmp,
      userAgent: 'test',
    )..tiles.online = false;
    var asked = 0;
    final fake = FireService(
      get: (u) async {
        asked++;
        return jsonEncode({
          'features': [
            {
              'properties': {'poly_IncidentName': 'Test Fire'},
              'geometry': {
                'type': 'Polygon',
                'coordinates': [
                  [
                    [lng0, lat0],
                    [lng0 + 0.01, lat0],
                    [lng0, lat0 + 0.01],
                  ],
                ],
              },
            },
          ],
        });
      },
    );
    final layers = [
      ...baseTileLayers(t).where((w) => w.key != const ValueKey('ov_fires')),
      overlayLayer(t, MapSource.fires, fires: fake)!,
    ];
    expect(
      layers.whereType<TileLayer>().length + layers.whereType<Opacity>().length,
      6,
      reason: 'base + 5 tile overlays',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(lat0, lng0),
            initialZoom: 13,
          ),
          children: layers,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(asked, 1);
    expect(find.byType(PolygonLayer), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    t.dispose();
    tmp.deleteSync(recursive: true);
  });
}
