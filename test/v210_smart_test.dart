import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/drive/online_router.dart';
import 'package:walkie_talkie/trip/drive/road_service.dart';
import 'package:walkie_talkie/trip/drive/speech.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imports/geo_import.dart';
import 'package:walkie_talkie/trip/tile_cache.dart' show GeoBounds;
import 'package:walkie_talkie/trip/map_net.dart';
import 'package:walkie_talkie/trip/nav/foot_router.dart';
import 'package:walkie_talkie/trip/nav/gentle_route.dart';
import 'package:walkie_talkie/trip/nav/nav_session.dart';
import 'package:walkie_talkie/trip/nav/trail_graph.dart';
import 'package:walkie_talkie/trip/nav/valhalla.dart';
import 'package:walkie_talkie/trip/search/fetch.dart';
import 'package:walkie_talkie/trip/search/overpass.dart';
import 'package:walkie_talkie/trip/search/rate_limiter.dart';
import 'package:walkie_talkie/trip/search/trailhead_finder.dart';
import 'package:walkie_talkie/trip/smart_plan.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/drive_page.dart';
import 'package:walkie_talkie/ui/nav_page.dart';
import 'package:walkie_talkie/ui/smart_sheets.dart';
import 'package:walkie_talkie/ui/trip_widgets.dart';

import 'trip_integration_test.dart' show FakeHost;
import 'v192_drive_test.dart' show at;
import 'v193_offline_area_drive_test.dart' show network, osrmJson;
import 'v210_gentle_test.dart' as gentle;

String fixture(String n) => File('test/fixtures/live210/$n').readAsStringSync();

void main() {
  // ----------------------------------------------------------- MapNet
  group('MapNet: online / weak / offline', () {
    test('request outcomes move the state; a success brings it back', () {
      final n = MapNet();
      expect(n.state, MapNetState.online);
      n.fail();
      expect(n.state, MapNetState.weak);
      expect(n.routingTimeout, const Duration(milliseconds: 2500));
      expect(n.routingTimeoutOverride, const Duration(milliseconds: 2500));
      n.fail();
      expect(n.state, MapNetState.offline);
      n.ok();
      expect(n.state, MapNetState.online);
      expect(n.routingTimeoutOverride, isNull);
      expect(n.routingTimeout, const Duration(seconds: 7));
    });

    test('a failed connection check means offline at once', () async {
      final n = MapNet(probe: (_) async => false);
      expect(await n.probeNow(), isFalse);
      expect(n.state, MapNetState.offline);
      n.probe = (_) async => true;
      expect(await n.probeNow(), isTrue);
      expect(n.state, MapNetState.online);
    });

    test('offline: one online try every 10 s, not on every request', () {
      var now = DateTime(2026, 10, 27, 12);
      final n = MapNet(clock: () => now);
      n.fail(hard: true);
      expect(n.allowOnline, isTrue); // never tried yet
      n.attempt();
      expect(n.allowOnline, isFalse);
      now = now.add(const Duration(seconds: 11));
      expect(n.allowOnline, isTrue);
    });

    test('checks are slow while idle and only run when needed', () async {
      var now = DateTime(2026, 10, 27, 12);
      var probes = 0;
      final n = MapNet(
        clock: () => now,
        probe: (_) async {
          probes++;
          return true;
        },
      );
      // Pocket: not on screen, not routing: never.
      expect(n.probeEvery(onScreen: false, routing: false), isNull);
      now = now.add(const Duration(minutes: 30));
      n.tick(onScreen: false, routing: false);
      expect(probes, 0);
      // On screen, online: every 20 s (8 s while following a route).
      expect(
        n.probeEvery(onScreen: true, routing: false),
        const Duration(seconds: 20),
      );
      expect(
        n.probeEvery(onScreen: true, routing: true),
        const Duration(seconds: 8),
      );
      // Routing with the screen off: only every 30 s.
      expect(
        n.probeEvery(onScreen: false, routing: true),
        const Duration(seconds: 30),
      );
      n.tick(onScreen: true, routing: false);
      await pumpEventQueue();
      expect(probes, 1);
      now = now.add(const Duration(seconds: 5));
      n.tick(onScreen: true, routing: false);
      await pumpEventQueue();
      expect(probes, 1, reason: 'too soon');
      now = now.add(const Duration(seconds: 20));
      n.tick(onScreen: true, routing: false);
      await pumpEventQueue();
      expect(probes, 2);
      // Down: look again sooner so the switch back is quick.
      n.fail(hard: true);
      expect(
        n.probeEvery(onScreen: true, routing: false),
        const Duration(seconds: 4),
      );
      expect(
        n.probeEvery(onScreen: false, routing: true),
        const Duration(seconds: 12),
      );
    });

    testWidgets('the chip says Online / Weak signal / Offline maps', (
      tester,
    ) async {
      for (final s in MapNetState.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MapNetChip(state: s, onTap: () {}),
            ),
          ),
        );
        expect(
          find.text(switch (s) {
            MapNetState.online => 'Online',
            MapNetState.weak => 'Weak signal',
            MapNetState.offline => 'Offline maps',
          }),
          findsOneWidget,
        );
      }
    });
  });

  // ------------------------------------------------- routers: parsing
  group('walking and driving answers from the real servers (fixtures)', () {
    const from = GeoPoint(45.52965, -122.71574);
    const to = GeoPoint(45.5420, -122.7290);

    test('Valhalla pedestrian', () {
      final r = Valhalla.parseWalk(
        fixture('valhalla_ped.json'),
        from: from,
        to: to,
      );
      expect(r.source, 'valhalla');
      expect(r.isOnline, isTrue);
      expect(r.lengthM, greaterThan(1500));
      expect(r.lengthM, lessThan(8000));
      expect(distanceM(r.points.first, from), lessThan(60));
      expect(r.junctions, isNotEmpty);
      expect(r.junctions.first.text, isNotEmpty);
    });

    test('BRouter hiking has elevation', () {
      final r = FootRouter.parseBrouter(
        fixture('brouter.json'),
        from: from,
        to: to,
      );
      expect(r.source, 'brouter');
      expect(r.hasElevation, isTrue);
      expect(r.climb().gain, greaterThan(50));
      expect(r.lengthM, greaterThan(1500));
    });

    test('OSRM foot', () {
      final r = FootRouter.parseOsrmFoot(
        fixture('osrm_foot.json'),
        from: from,
        to: to,
      );
      expect(r.source, 'osrm');
      expect(r.lengthM, greaterThan(1500));
      expect(r.junctions, isNotEmpty);
    });

    test('Valhalla auto (driving) and OSRM car parse as drive routes', () {
      final v = Valhalla.parseDrive(
        fixture('valhalla_auto.json'),
        from: from,
        to: to,
        name: 'Test',
      );
      expect(v.points.length, greaterThan(10));
      expect(v.steps, isNotEmpty);
      expect(v.lengthM, greaterThan(1500));
      final o = OnlineRouter.parse(fixture('osrm_car.json'));
      expect(o.lengthM, greaterThan(1500));
    });

    test('Valhalla "no route" is a no-route answer, not a failure', () {
      expect(
        () => Valhalla.parseWalk(
          '{"error_code":442,"error":"No path could be found"}',
          from: from,
          to: to,
        ),
        throwsA(
          isA<OnlineRouteException>().having(
            (e) => e.kind,
            'kind',
            OnlineFail.noRoute,
          ),
        ),
      );
    });

    test('the car-only demo server is refused for walking', () {
      expect(
        () => FootRouter(
          fetch: (r) async => '',
          osrmFoot: 'https://router.project-osrm.org',
        ),
        throwsArgumentError,
      );
      expect(
        FootRouter.defaultOsrmFoot,
        'https://routing.openstreetmap.de/routed-foot',
      );
    });
  });

  group('FootRouter order, fallback and fair use', () {
    const from = GeoPoint(45.52965, -122.71574);
    const to = GeoPoint(45.5420, -122.7290);

    test('Valhalla first; BRouter if it fails; OSRM foot last', () async {
      final hosts = <String>[];
      final times = <DateTime>[];
      String? bad;
      Future<String> f(FetchRequest r) async {
        hosts.add(r.uri.host);
        times.add(DateTime.now());
        if (r.uri.host.startsWith('valhalla')) {
          if (bad == 'v' || bad == 'vb') {
            throw FetchException('HTTP 500', status: 500);
          }
          return fixture('valhalla_ped.json');
        }
        if (r.uri.host == 'brouter.de') {
          if (bad == 'vb') {
            throw FetchException('HTTP 500', status: 500);
          }
          return fixture('brouter.json');
        }
        expect(r.uri.host, 'routing.openstreetmap.de');
        expect(r.uri.path, contains('/routed-foot/route/v1/foot/'));
        return fixture('osrm_foot.json');
      }

      final fr = FootRouter(
        fetch: f,
        limiter: RateLimiter(const Duration(milliseconds: 120)),
      );
      expect((await fr.route(from, to)).source, 'valhalla');
      expect(hosts, ['valhalla1.openstreetmap.de']);
      hosts.clear();
      bad = 'v';
      expect((await fr.route(from, to)).source, 'brouter');
      expect(hosts, ['valhalla1.openstreetmap.de', 'brouter.de']);
      hosts.clear();
      times.clear();
      bad = 'vb';
      expect((await fr.route(from, to)).source, 'osrm');
      expect(fr.lastProvider, 'osrm');
      expect(hosts, [
        'valhalla1.openstreetmap.de',
        'brouter.de',
        'routing.openstreetmap.de',
      ]);
      // Fair use: requests are spaced out by the limiter.
      for (var i = 1; i < times.length; i++) {
        expect(
          times[i].difference(times[i - 1]).inMilliseconds,
          greaterThanOrEqualTo(100),
        );
      }
      expect(hosts.contains('router.project-osrm.org'), isFalse);
    });

    test('asks with the request headers the app sets (JSON POST)', () async {
      FetchRequest? first;
      final fr = FootRouter(
        fetch: (r) async {
          first ??= r;
          return fixture('valhalla_ped.json');
        },
        limiter: RateLimiter(Duration.zero),
      );
      await fr.route(from, to);
      expect(first!.method, 'POST');
      expect(first!.headers['Content-Type'], 'application/json');
      final body = jsonDecode(first!.body!) as Map;
      expect(body['costing'], 'pedestrian');
    });

    test(
      'no signal throws at once; a hanging server gives up in time',
      () async {
        final a = FootRouter(
          fetch: (r) async => throw NoSignalException(),
          limiter: RateLimiter(Duration.zero),
        );
        await expectLater(
          a.route(from, to),
          throwsA(
            isA<OnlineRouteException>().having(
              (e) => e.kind,
              'kind',
              OnlineFail.noSignal,
            ),
          ),
        );
        final sw = Stopwatch()..start();
        final b = FootRouter(
          fetch: (r) => Completer<String>().future,
          limiter: RateLimiter(Duration.zero),
        );
        await expectLater(
          b.route(from, to, timeout: const Duration(milliseconds: 2500)),
          throwsA(isA<OnlineRouteException>()),
        );
        expect(sw.elapsedMilliseconds, lessThan(3500));
      },
    );

    test('every server says no path: the error says so', () async {
      final fr = FootRouter(
        fetch: (r) async => r.uri.host == 'brouter.de'
            ? 'no track found'
            : r.uri.host.startsWith('valhalla')
            ? '{"error_code":442,"error":"No path"}'
            : '{"code":"NoRoute","message":"x"}',
        limiter: RateLimiter(Duration.zero),
      );
      await expectLater(
        fr.route(from, to),
        throwsA(
          isA<OnlineRouteException>().having(
            (e) => e.kind,
            'kind',
            OnlineFail.noRoute,
          ),
        ),
      );
    });
  });

  // ---------------------------------------------- trailhead finding
  group('TrailheadFinder', () {
    const to = GeoPoint(45.5300, -122.7200);

    String overpassBody(FetchRequest r) =>
        Uri.decodeQueryComponent((r.body ?? '').substring(5));

    test('query: trailheads and public parking with road access', () {
      final q = TrailheadFinder.query(to, 12000);
      expect(q, contains('"highway"="trailhead"'));
      expect(q, contains('"amenity"="parking"'));
      expect(q, contains('private'));
    });

    test('Overpass answers: trailheads first, parking after', () async {
      final f = TrailheadFinder(
        fetch: (r) async {
          expect(overpassBody(r), contains('trailhead'));
          return jsonEncode({
            'elements': [
              {
                'type': 'node',
                'lat': 45.531,
                'lon': -122.721,
                'tags': {'highway': 'trailhead', 'name': 'Lower Trailhead'},
              },
              {
                'type': 'way',
                'center': {'lat': 45.5305, 'lon': -122.7202},
                'tags': {'amenity': 'parking'},
              },
            ],
          });
        },
        limiter: RateLimiter(Duration.zero),
      );
      final s = await f.find(to);
      expect(s.found.first.name, 'Lower Trailhead');
      expect(s.found.first.kind, 'trailhead');
      expect(s.found.length, 2);
      expect(s.overpassFailed, isFalse);
    });

    test('every Overpass server fails: Photon backup, and says so', () async {
      final seen = <String>[];
      final f = TrailheadFinder(
        fetch: (r) async {
          seen.add(r.uri.host);
          if (r.uri.host.contains('photon')) {
            return jsonEncode({
              'features': [
                {
                  'geometry': {
                    'coordinates': [-122.7205, 45.5302],
                  },
                  'properties': {'name': 'Wild Cherry Trailhead'},
                },
              ],
            });
          }
          if (r.uri.host.contains('nominatim')) return '[]';
          throw FetchException('HTTP 504', status: 504);
        },
        limiter: RateLimiter(Duration.zero),
        perTry: const Duration(seconds: 2),
      );
      final s = await f.find(to);
      expect(s.overpassFailed, isTrue);
      expect(s.found.single.name, 'Wild Cherry Trailhead');
      expect(s.found.single.source, 'photon');
      expect(s.note, contains('did not answer'));
      expect(seen.where((h) => h.contains('photon')), isNotEmpty);
    });

    test('Overpass times out, Photon empty: Nominatim backup', () async {
      final f = TrailheadFinder(
        fetch: (r) async {
          if (r.uri.host.contains('nominatim')) {
            return jsonEncode([
              {
                'lat': '45.5303',
                'lon': '-122.7203',
                'type': 'trailhead',
                'display_name': 'Nominatim Trailhead, Somewhere',
              },
            ]);
          }
          if (r.uri.host.contains('photon')) return '{"features":[]}';
          throw TimeoutException('slow');
        },
        limiter: RateLimiter(Duration.zero),
        perTry: const Duration(seconds: 2),
      );
      final s = await f.find(to);
      expect(s.found.single.source, 'nominatim');
      expect(s.found.single.name, 'Nominatim Trailhead');
    });

    test('Overpass hangs or is unreachable: the backups still get their '
        'time', () async {
      for (final hang in [true, false]) {
        final f = TrailheadFinder(
          fetch: (r) {
            if (r.uri.host.contains('photon')) {
              return Future.value(
                jsonEncode({
                  'features': [
                    {
                      'geometry': {
                        'coordinates': [-122.7205, 45.5302],
                      },
                      'properties': {'name': 'Backup TH'},
                    },
                  ],
                }),
              );
            }
            if (r.uri.host.contains('nominatim')) return Future.value('[]');
            return hang
                // like the app's fetch: gives up after its own timeout
                ? Future<String>.delayed(
                    r.timeout,
                    () => throw TimeoutException('slow'),
                  )
                : Future.error(NoSignalException());
          },
          limiter: RateLimiter(Duration.zero),
          perTry: const Duration(seconds: 3),
        );
        final s = await f.find(to, budget: const Duration(seconds: 5));
        expect(s.found.single.name, 'Backup TH', reason: 'hang: $hang');
        expect(s.noSignal, isFalse);
        expect(s.overpassFailed, isTrue);
      }
    });

    test('real Photon and Nominatim answers parse (fixtures)', () {
      final p = TrailheadFinder.parsePhoton(fixture('photon.json'), to);
      expect(p, isA<List<TrailheadCandidate>>());
      final n = TrailheadFinder.parseNominatim(fixture('nominatim.json'), to);
      expect(n, isA<List<TrailheadCandidate>>());
    });

    test('no signal at all is reported as no signal, no crash', () async {
      final f = TrailheadFinder(
        fetch: (r) async => throw NoSignalException(),
        limiter: RateLimiter(Duration.zero),
      );
      final s = await f.find(to);
      expect(s.noSignal, isTrue);
      expect(s.found, isEmpty);
    });
  });

  // ------------------------------------------------ unnamed trail data
  group('trail download keeps unnamed paths', () {
    test('query asks for unnamed paths, tracks and footways', () {
      final q = buildTrailQuery(GeoBounds(45.0, -122.0, 45.1, -121.9));
      expect(q, contains('[!"name"]'));
      expect(q, contains('sidewalk|crossing'));
    });
  });

  // ------------------------------------------- smart navigation plans
  group('Navigate here: the plan', () {
    late Directory tmp;
    late FakeHost host;
    late TripController t;
    String? osrm; // null = no signal
    var overpassMode = 'ok'; // ok | fail | empty
    var photonMode = 'empty';
    final calls = <String>[];
    // The off-road destination and the trailhead the test world has.
    final dest = at(3300, 2500);
    final th = at(3000, 2000);

    String brouter(Uri u) {
      final ll = u.queryParameters['lonlats']!.split('|');
      List<double> p(String s) =>
          s.split(',').map(double.parse).toList(); // lon, lat
      final a = p(ll[0]), b = p(ll[1]);
      final coords = [
        for (var i = 0; i <= 10; i++)
          [
            a[0] + (b[0] - a[0]) * i / 10,
            a[1] + (b[1] - a[1]) * i / 10,
            1000.0 + 20 * i,
          ],
      ];
      return jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'track-length': '600'},
            'geometry': {'type': 'LineString', 'coordinates': coords},
          },
        ],
      });
    }

    Future<String> fetch(FetchRequest r) async {
      calls.add(r.uri.host);
      final h = r.uri.host;
      if (r.uri.path.contains('/route/v1/driving/')) {
        if (osrm == null) throw NoSignalException();
        // The destination off the road is 900 m from the nearest road.
        final end = r.uri.path.split(';').last.split(',').last;
        final far = (double.parse(end) - dest.lat).abs() < 1e-6;
        return osrmJson(endOff: far ? 900 : 4);
      }
      if (h == 'brouter.de') {
        if (osrm == null) throw NoSignalException();
        return brouter(r.uri);
      }
      if (h.startsWith('valhalla')) {
        if (osrm == null) throw NoSignalException();
        throw FetchException('HTTP 500', status: 500);
      }
      if (h.contains('photon')) {
        if (osrm == null) throw NoSignalException();
        return photonMode == 'empty'
            ? '{"features":[]}'
            : jsonEncode({
                'features': [
                  {
                    'geometry': {
                      'coordinates': [th.lng, th.lat],
                    },
                    'properties': {'name': 'Photon Trailhead'},
                  },
                ],
              });
      }
      if (h.contains('nominatim')) {
        if (osrm == null) throw NoSignalException();
        return '[]';
      }
      // Overpass
      if (osrm == null) throw NoSignalException();
      final q = Uri.decodeQueryComponent((r.body ?? '').substring(5));
      if (q.contains('"highway"="trailhead"') && !q.contains('out geom')) {
        if (overpassMode == 'fail') throw FetchException('HTTP 504');
        if (overpassMode == 'empty') return '{"elements":[]}';
        return jsonEncode({
          'elements': [
            {
              'type': 'node',
              'lat': th.lat,
              'lon': th.lng,
              'tags': {'highway': 'trailhead', 'name': 'Silver Star TH'},
            },
          ],
        });
      }
      return '{"elements":[]}';
    }

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('v210');
      host = FakeHost(1);
      osrm = osrmJson();
      overpassMode = 'ok';
      photonMode = 'empty';
      calls.clear();
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
        fetch: fetch,
        searchLimiter: RateLimiter(Duration.zero),
        netProbe: (_) async => osrm != null,
      );
      t.roads = RoadService.inline();
      t.speaker = SilentSpeaker();
      await t.start();
      t.tiles.online = true;
      t.onFix(Fix(at(0, 0), DateTime.now(), speedMps: 10));
    });
    tearDown(() {
      t.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    test('near by: walk the whole way, a real route, not a line', () async {
      final p = await t.planSmart(at(900, 0), name: 'Lake');
      expect(p.kind, SmartKind.hike);
      expect(p.hike!.source, 'brouter');
      expect(p.hike!.points.length, greaterThan(5));
      expect(p.hike!.terrainOnly, isFalse);
    });

    test('on a road: drive', () async {
      final p = await t.planSmart(at(3000, 1500), name: 'Camp');
      expect(p.kind, SmartKind.drive);
      expect(p.drive!.isOnline, isTrue);
      expect(p.hike, isNull);
    });

    test('off the roads: drive to the trailhead, then hike; both legs and '
        'the total', () async {
      final p = await t.planSmart(dest, name: 'Summit');
      expect(p.kind, SmartKind.driveThenHike, reason: p.message);
      expect(p.trailhead!.name, 'Silver Star TH');
      expect(p.trailhead!.source, 'overpass');
      expect(p.drive!.lengthM, closeTo(5000, 50));
      expect(p.hike!.source, 'brouter');
      expect(p.hike!.lengthM, greaterThan(300));
      final tot = p.totals;
      expect(tot.metres, closeTo(p.drive!.lengthM + p.hike!.lengthM, 1));
      expect(
        tot.time,
        greaterThan(p.drive!.duration),
        reason: 'the hike adds time',
      );
    });

    test(
      'Overpass down: Photon finds the trailhead, and the plan says so',
      () async {
        overpassMode = 'fail';
        photonMode = 'one';
        final p = await t.planSmart(dest, name: 'Summit');
        expect(p.kind, SmartKind.driveThenHike, reason: p.message);
        expect(p.trailhead!.name, 'Photon Trailhead');
        expect(p.message, contains('did not answer'));
      },
    );

    test('no trailhead anywhere: ask which road end, no guessing', () async {
      overpassMode = 'empty';
      final p = await t.planSmart(dest, name: 'Summit');
      expect(p.kind, SmartKind.needRoadEnd);
      expect(p.message, contains('Which road end'));
      expect(p.roadEnd, isNotNull);
      // Picking one: drive there, then hike.
      final r = await t.driveToRoadEnd(p.roadEnd!, dest, name: 'Summit');
      expect(r.session, isNotNull);
      expect(r.session!.hikeTo, isNotNull);
    });

    test(
      'no signal and nothing saved: says so, never a straight line',
      () async {
        osrm = null;
        t.mapNet.fail(hard: true);
        final sw = Stopwatch()..start();
        final p = await t.planSmart(dest, name: 'Summit');
        expect(sw.elapsedMilliseconds, lessThan(3500));
        expect(p.kind, SmartKind.noRoute);
        expect(p.message, isNotEmpty);
        await t.startPlan(p, dest, 'Summit');
        expect(t.nav, isNull);
        expect(t.drive, isNull);
      },
    );

    test(
      'offline with saved roads and a saved trailhead: still plans',
      () async {
        final o = network();
        final d = o.build();
        await t.layers.importRoads(
          'Test roads',
          d.encode(),
          area: d.bounds,
          summary: 'roads',
        );
        await t.layers.addTrail(
          ImportedData(
            name: 'Trails',
            lines: [
              ImportedLine('Summit Trail', [th, dest]),
            ],
            waypoints: [
              ImportedWaypoint('Silver Star Trailhead', th, kind: 'trailhead'),
            ],
          ),
        );
        osrm = null;
        t.mapNet.fail(hard: true);
        final p = await t.planSmart(dest, name: 'Summit');
        expect(p.kind, SmartKind.driveThenHike, reason: p.message);
        expect(p.drive!.isOnline, isFalse);
        expect(p.trailhead!.source, 'saved');
        expect(p.hike, isNotNull);
        expect(p.hike!.isOnline, isFalse);
      },
    );

    test('a slow server while weak: gives up after about 2.5 s and uses '
        'the saved roads', () async {
      final o = network();
      final d = o.build();
      await t.layers.importRoads(
        'Test roads',
        d.encode(),
        area: d.bounds,
        summary: 'roads',
      );
      t.dispose();
      tmp = Directory.systemTemp.createTempSync('v210b');
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
        fetch: (r) => Completer<String>().future,
        searchLimiter: RateLimiter(Duration.zero),
        netProbe: (_) async => false,
      );
      t.roads = RoadService.inline();
      await t.start();
      t.tiles.online = true;
      await t.layers.importRoads(
        'Test roads',
        d.encode(),
        area: d.bounds,
        summary: 'roads',
      );
      t.onFix(Fix(at(0, 0), DateTime.now()));
      t.mapNet.fail(); // weak
      final sw = Stopwatch()..start();
      final p = await t.planDrive(at(0, 0), at(3000, 1000));
      expect(p.route, isNotNull, reason: p.message);
      expect(p.route!.isOnline, isFalse);
      expect(sw.elapsedMilliseconds, lessThan(4500));
    });

    test('start the plan, arrive at the trailhead: handoff, hike starts by '
        'itself, colours differ', () async {
      final p = await t.planSmart(dest, name: 'Summit');
      await t.startPlan(p, dest, 'Summit');
      expect(t.drive, isNotNull);
      expect(t.drive!.name, 'Silver Star TH');
      expect(t.drive!.hikePreview, isNotNull);
      expect(t.drive!.hikeTo, isNotNull);
      // The drive card shows both legs and the total.
      expect(hikeLegLine(t.drive!, true), contains('Then hike to Summit'));
      expect(hikeLegLine(t.drive!, true), contains('Total'));
      // Drive along the route.
      final time = DateTime.now();
      for (final e in [for (var x = 0.0; x <= 3000; x += 100) x]) {
        t.onFix(Fix(at(e, 0), time, speedMps: 10));
      }
      for (var n = 100.0; n <= 2000; n += 100) {
        t.onFix(Fix(at(3000, n), time, speedMps: 10));
      }
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      final h = t.handoff;
      expect(h, isNotNull);
      expect(h!.trailheadName, 'Silver Star TH');
      expect(h.targetName, 'Summit');
      expect(h.route, isNotNull);
      expect(h.route!.lengthM, greaterThan(300));
      expect(t.nav, isNotNull, reason: 'the hike started by itself');
      expect(t.nav!.route, isNotNull);
      expect(t.drive, isNull);
      expect(hikeColor, isNot(const Color(0xFF1565C0)));
    });

    test('at the trailhead with no signal: the planned hike is used', () async {
      final p = await t.planSmart(dest, name: 'Summit');
      expect(p.hike, isNotNull);
      await t.startPlan(p, dest, 'Summit');
      osrm = null;
      t.mapNet.fail(hard: true);
      final time = DateTime.now();
      for (final e in [for (var x = 0.0; x <= 3000; x += 100) x]) {
        t.onFix(Fix(at(e, 0), time, speedMps: 10));
      }
      for (var n = 100.0; n <= 2000; n += 100) {
        t.onFix(Fix(at(3000, n), time, speedMps: 10));
      }
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(t.handoff, isNotNull);
      expect(t.handoff!.route, isNotNull);
      expect(t.handoff!.message, contains('planned earlier'));
    });

    test('signal drops mid-route: the route is kept; back online, a saved-'
        'data route is upgraded', () async {
      final o = network();
      final d = o.build();
      await t.layers.importRoads(
        'Test roads',
        d.encode(),
        area: d.bounds,
        summary: 'roads',
      );
      // Start offline: a route from saved roads.
      osrm = null;
      t.mapNet.fail(hard: true);
      t.onFix(Fix(at(0, 0), DateTime.now(), speedMps: 10));
      final s = (await t.driveTo(at(3000, 2000), name: 'TH')).session!;
      expect(s.route.isOnline, isFalse);
      final before = s.route;
      // Signal comes back.
      osrm = osrmJson();
      t.mapNet.ok();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pumpEventQueue();
      expect(t.drive, same(s));
      expect(s.route.isOnline, isTrue, reason: 'upgraded');
      expect(identical(s.route, before), isFalse);
      // Signal drops again: the online route stays.
      osrm = null;
      t.mapNet.fail(hard: true);
      await pumpEventQueue();
      expect(t.drive!.route.isOnline, isTrue);
      expect(t.mapNet.state, MapNetState.offline);
    });

    test('a failing router never drops the current walk', () async {
      final p = await t.planSmart(at(900, 0), name: 'Lake');
      await t.startPlan(p, at(900, 0), 'Lake');
      final r0 = t.nav!.route;
      osrm = null;
      t.mapNet.fail(hard: true);
      await pumpEventQueue();
      expect(t.nav!.route, same(r0));
    });
  });

  // -------------------------------------------------- gentle compass
  group('Gentle compass route', () {
    late Directory tmp;
    late FakeHost host;
    late TripController t;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('v210g');
      host = FakeHost(1);
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
        fetch: (r) async => throw NoSignalException(),
        searchLimiter: RateLimiter(Duration.zero),
      );
      await t.start();
      t.onFix(Fix(at(0, 0), DateTime.now()));
    });
    tearDown(() {
      t.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    test('with no elevation saved: the plain compass, with a note', () async {
      final r = await t.gentleTo(at(1500, 1500), name: 'Peak');
      expect(r.session, isNotNull);
      expect(r.session!.compass, isTrue);
      expect(r.message, contains('plain compass'));
      expect(r.message.toLowerCase(), contains('elevation'));
    });

    test('slope limits are 10 %, 20 % and any', () {
      expect(SlopeLimit.gentle.percent, 10);
      expect(SlopeLimit.moderate.percent, 20);
      expect(SlopeLimit.any.percent, isNull);
      expect(
        gentleLabel,
        contains("can't see cliffs, brush, water or private"),
      );
    });

    testWidgets('follow screen: the terrain-only label and the straight '
        'line next to it', (tester) async {
      final plan = (await planGentle(
        gentle.base,
        gentle.at(3000, 0),
        gentle.hill(e: 1500, r: 500, h: 300),
        useIsolate: false,
      )).plan!;
      final s = NavSession(
        target: gentle.at(3000, 0),
        name: 'Peak',
        route: plan.route,
        note: 'x',
      );
      t.nav = s;
      s.update(gentle.base);
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: NavFollowPage(trip: t)));
      expect(find.byKey(const Key('terrainOnly')), findsOneWidget);
      expect(find.textContaining("can't see cliffs"), findsOneWidget);
      expect(find.textContaining('plain straight line'), findsOneWidget);
    });
  });

  // ------------------------------------------------------ the screens
  group('screens', () {
    Future<void> show(WidgetTester tester, Widget w) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    }

    TrailheadHandoff handoff({bool route = true}) => TrailheadHandoff(
      trailheadName: 'Silver Star TH',
      targetName: 'Summit',
      at: DateTime(2026, 10, 27),
      route: route
          ? (TrailRoute(
              [at(0, 0), at(300, 0), at(600, 0)],
              [1000, 1050, 1120],
              [],
              startOffM: 0,
              endOffM: 0,
            )..source = 'brouter')
          : null,
      message: route ? 'Walking route, online (brouter).' : 'No signal.',
    );

    testWidgets('trailhead handoff: hike distance, climb, follow', (
      tester,
    ) async {
      var followed = false;
      await show(
        tester,
        HandoffSheetBody(
          handoff: handoff(),
          imperial: false,
          onFollow: () => followed = true,
          onRetry: () {},
          onGentle: () {},
        ),
      );
      expect(find.text('You are at Silver Star TH'), findsOneWidget);
      final facts = tester.widget<Text>(find.byKey(const Key('handoffFacts')));
      expect(facts.data, contains('Summit'));
      expect(facts.data, contains('up 120 m'));
      expect(find.textContaining('OpenStreetMap'), findsOneWidget);
      await tester.tap(find.byKey(const Key('handoffFollow')));
      expect(followed, isTrue);
    });

    testWidgets('handoff with no walking route: retry or gentle route', (
      tester,
    ) async {
      var retried = false, gentleTapped = false;
      await show(
        tester,
        HandoffSheetBody(
          handoff: handoff(route: false),
          imperial: true,
          onFollow: () {},
          onRetry: () => retried = true,
          onGentle: () => gentleTapped = true,
        ),
      );
      expect(find.byKey(const Key('handoffNoRoute')), findsOneWidget);
      await tester.tap(find.byKey(const Key('handoffRetry')));
      await tester.tap(find.byKey(const Key('handoffGentle')));
      expect(retried && gentleTapped, isTrue);
    });

    testWidgets('gentle sheet: the label and three slope limits', (
      tester,
    ) async {
      SlopeLimit? got;
      await show(
        tester,
        Builder(
          builder: (c) => TextButton(
            onPressed: () async {
              got = await showModalBottomSheet<SlopeLimit>(
                context: c,
                builder: (_) => const GentleSheetBody(name: 'Peak'),
              );
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining("can't see cliffs"), findsOneWidget);
      expect(find.textContaining('about 10%'), findsOneWidget);
      expect(find.textContaining('about 20%'), findsOneWidget);
      expect(find.textContaining('no limit'), findsOneWidget);
      await tester.tap(find.byKey(const Key('slope_moderate')));
      await tester.pumpAndSettle();
      expect(got, SlopeLimit.moderate);
    });

    testWidgets('no route: offers offline areas, gentle route, compass', (
      tester,
    ) async {
      String? got;
      await show(
        tester,
        Builder(
          builder: (c) => TextButton(
            onPressed: () async => got = await showDialog<String>(
              context: c,
              builder: (_) => const NoRouteDialog(message: 'No signal.'),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('will not draw a straight line'),
        findsOneWidget,
      );
      expect(find.text('Offline areas'), findsOneWidget);
      expect(find.text('Gentle compass route'), findsOneWidget);
      await tester.tap(find.byKey(const Key('noRouteCompass')));
      await tester.pumpAndSettle();
      expect(got, 'compass');
    });

    testWidgets('which road end: asks, with the road end offered', (
      tester,
    ) async {
      String? got;
      await show(
        tester,
        Builder(
          builder: (c) => TextButton(
            onPressed: () async => got = await showDialog<String>(
              context: c,
              builder: (_) => const RoadEndDialog(
                name: 'Summit',
                message: 'Which road end should I take you to?',
                hasRoadEnd: true,
                awayText: '900 m',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Which road end?'), findsOneWidget);
      expect(find.textContaining('900 m'), findsOneWidget);
      await tester.tap(find.byKey(const Key('roadEndUse')));
      await tester.pumpAndSettle();
      expect(got, 'use');
    });
  });
}
