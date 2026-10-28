import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/drive/online_router.dart';
import 'package:walkie_talkie/trip/drive/road_download.dart';
import 'package:walkie_talkie/trip/drive/road_service.dart';
import 'package:walkie_talkie/trip/drive/speech.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/nav/trail_graph.dart';
import 'package:walkie_talkie/trip/route_save.dart';
import 'package:walkie_talkie/trip/search/fetch.dart';
import 'package:walkie_talkie/trip/search/rate_limiter.dart';
import 'package:walkie_talkie/trip/smart_plan.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/drive_page.dart';
import 'package:walkie_talkie/ui/nav_page.dart';
import 'package:walkie_talkie/ui/offline_areas_page.dart';
import 'package:walkie_talkie/ui/save_route_sheet.dart';
import 'package:walkie_talkie/ui/sheets.dart';

import 'trip_integration_test.dart' show FakeHost;
import 'v192_drive_test.dart' show Osm, at;
import 'v193_offline_area_drive_test.dart' show network, osrmJson;

TrailRoute hikeRoute() {
  final pts = [for (var n = 0.0; n <= 1200; n += 100) at(3000, 2000 + n)];
  return TrailRoute(
    pts,
    [for (var i = 0; i < pts.length; i++) 1000.0 + i * 3],
    [RouteJunction(4, 400, 'left', 'Silver Star Trail')],
    startOffM: 5,
    endOffM: 12,
  )..source = 'valhalla';
}

void main() {
  group('corridors and windows', () {
    test('a strip along the route, not the whole box', () {
      // 40 km east along 45 N.
      final pts = [const GeoPoint(45, -123), const GeoPoint(45, -122.5)];
      final strip = corridorTiles(pts, bufferM: 3000, z0: 10, z1: 12);
      final box = countTiles(routeBounds(pts, 3000), 10, 12);
      expect(strip.length, lessThan(box + 1));
      expect(strip.length, greaterThan(10));
      // Both ends are covered at every zoom.
      for (var z = 10; z <= 12; z++) {
        for (final p in [pts.first, pts.last]) {
          expect(
            strip.any(
              (t) =>
                  t.z == z && t.x == tileX(p.lng, z) && t.y == tileY(p.lat, z),
            ),
            isTrue,
          );
        }
      }
      // A diagonal route: far fewer tiles than its box.
      final diag = [const GeoPoint(45, -123), const GeoPoint(45.5, -122.4)];
      final d = corridorTiles(diag, bufferM: 1500, z0: 13, z1: 13).length;
      expect(d, lessThan(countTiles(routeBounds(diag, 1500), 13, 13) ~/ 3));
    });

    test('the zoom drops until the tile budget fits', () {
      final pts = [const GeoPoint(45, -123), const GeoPoint(45, -121.5)];
      final c = corridorForBudget(
        pts,
        bufferM: 3000,
        z0: 8,
        z1: 15,
        maxTiles: 300,
      )!;
      expect(c.tiles.length, lessThanOrEqualTo(300));
      expect(c.z1, lessThan(15));
      expect(c.z1, greaterThanOrEqualTo(8));
      expect(
        corridorForBudget(pts, bufferM: 3000, z0: 12, z1: 15, maxTiles: 5),
        isNull,
      );
    });

    test('windows follow the route and are capped', () {
      final pts = [
        for (var i = 0; i <= 100; i++) GeoPoint(45, -123 + i * 0.01),
      ];
      final w = routeWindows(pts, chunkM: 12000, bufferM: 2500);
      expect(w.length, inInclusiveRange(6, 10));
      for (final p in pts) {
        expect(w.any((b) => b.contains(p)), isTrue);
      }
      for (final b in w) {
        expect((b.north - b.south) * (b.east - b.west), lessThan(0.1));
      }
      expect(
        routeWindows(pts, chunkM: 1000, bufferM: 500, maxWindows: 5).length,
        lessThanOrEqualTo(6),
      );
    });

    test('trail routes and saved routes survive JSON', () {
      final h = hikeRoute();
      final back = trailRouteFromJson(
        jsonDecode(jsonEncode(trailRouteToJson(h))),
      )!;
      expect(back.points.length, h.points.length);
      expect(back.lengthM, closeTo(h.lengthM, 1));
      expect(back.junctions.single.text, h.junctions.single.text);
      expect(back.source, 'valhalla');
      expect(back.ele[3], closeTo(h.ele[3], 0.1));
      final r = SavedRoute(
        id: 'a1',
        name: 'Silver Star',
        destination: at(3000, 3200),
        hike: h,
        trailheadName: 'Silver Star Trailhead',
        trailheadPos: at(3000, 2000),
        status: SavedRoute.ready,
        problems: const ['Trails: none found'],
      );
      final r2 = SavedRoute.fromJson(jsonDecode(jsonEncode(r.toJson())))!;
      expect(r2.name, 'Silver Star');
      expect(r2.isReady, isTrue);
      expect(r2.turns, 1);
      expect(r2.problems, ['Trails: none found']);
      expect(r2.trailheadName, 'Silver Star Trailhead');
      expect(r2.hike!.points.length, h.points.length);
    });

    test('jobs: wide and low for the drive, tight and high for the walk', () {
      final r = SavedRoute(
        name: 'Peak',
        destination: at(3000, 3200),
        hike: hikeRoute(),
        trailheadPos: at(3000, 2000),
      );
      final j = routeSaveJobs(r, MapSource.topo);
      final map = j.tiles.firstWhere((x) => x.label.contains('walk'));
      expect(map.z1, 16);
      expect(map.z0, 12);
      expect(j.tiles.any((x) => x.src.id == 'terrarium'), isTrue);
      expect(j.trailWindows, isNotEmpty);
      expect(j.roadWindows, isNotEmpty);
      expect(j.bytes(r), greaterThan(0));
      // A walk-only route has no drive map or road corridor for a drive.
      expect(j.tiles.any((x) => x.label.contains('drive')), isFalse);
    });

    test('distance to a line', () {
      final line = [at(0, 0), at(1000, 0)];
      expect(distanceToLineM(line, at(500, 300)), closeTo(300, 2));
      expect(distanceToLineM(line, at(1500, 0)), closeTo(500, 2));
    });
  });

  group('tile download: polite, cancel, resume, no signal', () {
    late HttpServer server;
    late Directory dir;
    late TileCache cache;
    late MapSource src;
    final hits = <String>[];
    var status = 200;
    setUpAll(() => HttpOverrides.global = null);
    setUp(() async {
      hits.clear();
      status = 200;
      dir = Directory.systemTemp.createTempSync('tc220');
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        hits.add(req.uri.path);
        req.response.statusCode = status;
        req.response.add(List.filled(50, 7));
        req.response.close();
      });
      src = MapSource.custom('http://127.0.0.1:${server.port}/{z}/{x}/{y}.png');
      cache = TileCache(
        Directory('${dir.path}/tiles'),
        userAgent: 'WalkieTest/1',
      );
    });
    tearDown(() async {
      cache.close();
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    final ids = [for (var i = 0; i < 8; i++) (z: 12, x: 100 + i, y: 200)];
    const b = GeoBounds(45, -123, 45.1, -122.9);

    test(
      'one at a time with a pause; cancel keeps what came; resume skips',
      () async {
        final p = DownloadProgress(ids.length);
        final t0 = DateTime.now();
        final r = await cache.downloadTiles(
          src,
          ids,
          name: 'X',
          bounds: b,
          progress: p,
          pause: const Duration(milliseconds: 40),
          onProgress: (p) {
            if (p.done >= 3) p.cancelled = true;
          },
        );
        expect(hits.length, 3);
        expect(
          DateTime.now().difference(t0).inMilliseconds,
          greaterThanOrEqualTo(80),
        );
        expect(r.tiles, 3);
        expect(cache.regions.length, 1, reason: 'partial work is kept');
        // Resume: the 3 on the phone are skipped, 5 are fetched.
        hits.clear();
        final p2 = DownloadProgress(ids.length);
        final r2 = await cache.downloadTiles(
          src,
          ids,
          name: 'X',
          bounds: b,
          progress: p2,
          pause: Duration.zero,
        );
        expect(hits.length, 5);
        expect(r2.tiles, 8);
        expect(p2.failed, 0);
      },
    );

    test('no signal: gives up after a few failures in a row', () async {
      status = 500;
      final p = DownloadProgress(ids.length);
      await cache.downloadTiles(
        src,
        ids,
        name: 'X',
        bounds: b,
        progress: p,
        pause: Duration.zero,
        giveUpAfter: 3,
      );
      expect(hits.length, 3);
      expect(p.stalled, isTrue);
      expect(cache.regions, isEmpty);
    });

    test('the real User-Agent is sent', () async {
      String? ua;
      await server.close(force: true);
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        ua = req.headers.value('user-agent');
        req.response.add([1, 2, 3]);
        req.response.close();
      });
      final s2 = MapSource.custom(
        'http://127.0.0.1:${server.port}/{z}/{x}/{y}.png',
      );
      await cache.downloadTiles(
        s2,
        [ids.first],
        name: 'X',
        bounds: b,
        pause: Duration.zero,
      );
      expect(ua, 'WalkieTest/1');
    });
  });

  group('saving a route', () {
    late Directory tmp;
    late FakeHost host;
    late TripController t;
    late Osm o;
    String? osrm;

    Future<String> fetch(FetchRequest r) async {
      if (r.uri.path.contains('/route/v1/driving/')) {
        if (osrm == null) throw NoSignalException();
        return osrm!;
      }
      final body = r.body ?? '';
      final q = Uri.decodeQueryComponent(
        body.startsWith('data=') ? body.substring(5) : body,
      );
      if (q.contains('out count')) {
        return '{"elements":[{"type":"count","tags":{"ways":"40"}}]}';
      }
      if (q.contains('route"="hiking') || q.contains('trailhead')) {
        final a = at(2900, 1900), b = at(3400, 2600);
        return jsonEncode({
          'elements': [
            {
              'type': 'way',
              'id': 7,
              'tags': {'highway': 'path'},
              'geometry': [
                {'lat': a.lat, 'lon': a.lng},
                {'lat': b.lat, 'lon': b.lng},
              ],
            },
          ],
        });
      }
      if (osrm == null && o.overpassJson().isEmpty) throw NoSignalException();
      return o.overpassJson();
    }

    Future<TripController> make() async {
      final c = TripController(
        host: host,
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
        fetch: fetch,
        searchLimiter: RateLimiter(Duration.zero),
      );
      c.roads = RoadService.inline();
      c.speaker = SilentSpeaker();
      c.onlineRouter = OnlineRouter(
        fetch: fetch,
        limiter: RateLimiter(Duration.zero),
      );
      await c.start();
      return c;
    }

    RoadDownloader dl() => RoadDownloader(
      fetch: fetch,
      limiter: RateLimiter(Duration.zero),
      endpoints: const ['https://example.com/api'],
    );

    void seed(SavedRoute r) {
      final jobs = routeSaveJobs(r, MapSource.topo);
      for (final j in jobs.tiles) {
        for (final id in j.tiles) {
          final f = File(
            '${tmp.path}/tiles/${j.src.id}/${id.z}/${id.x}/${id.y}.png',
          );
          f.parent.createSync(recursive: true);
          f.writeAsBytesSync(List.filled(100, 1));
        }
      }
    }

    Future<SavedRoute> startDrive() async {
      osrm = osrmJson();
      t.onFix(Fix(at(0, 0), DateTime.now()));
      await t.driveTo(at(3000, 2000), name: 'Silver Star Trailhead');
      final r = t.currentRouteForSave()!;
      seed(r);
      return r;
    }

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('v220');
      host = FakeHost(1);
      o = network();
      osrm = null;
      t = await make();
    });
    tearDown(() {
      t.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    test('nothing to save without a route; compass has none', () async {
      expect(t.currentRouteForSave(), isNull);
      t.onFix(Fix(at(0, 0), DateTime.now()));
      await t.navigateTo(at(500, 500), name: 'X', compass: true);
      expect(t.currentRouteForSave(), isNull);
    });

    test(
      'one item named after the destination: map, roads, trails, turns',
      () async {
        final r = await startDrive();
        expect(r.name, 'Silver Star Trailhead');
        expect(r.turns, greaterThan(1));
        final est = t.estimateRouteSave(r);
        expect(est.bytes, greaterThan(0));
        expect(est.jobs.tileCount, greaterThan(0));
        final steps = <String>[];
        final res = await t.saveRoute(
          r,
          downloader: dl(),
          tilePause: Duration.zero,
          onProgress: (p) {
            if (!steps.contains(p.step)) steps.add(p.step);
          },
        );
        expect(res.complete, isTrue, reason: res.problems.join(';'));
        expect(steps, containsAll(['Map along the drive', 'Roads', 'Trails']));
        expect(t.areas.entries.length, 1);
        final e = t.areas.entries.single;
        expect(e.name, 'Silver Star Trailhead');
        expect(e.isRoute, isTrue);
        expect(e.route!.isReady, isTrue);
        expect(e.regions.map((x) => x.sourceId), contains('topo'));
        expect(e.roadLayers.length, 1);
        expect(e.trailLayers.length, 1);
        expect(e.route!.drive!.steps.length, r.drive!.steps.length);
        // Survives a restart.
        t.dispose();
        t = await make();
        expect(t.areas.entries.single.isRoute, isTrue);
        expect(t.routes.all.single.drive!.steps, isNotEmpty);
        // Download again keeps it one item with one road layer.
        final again = t.routes.all.single;
        final res2 = await t.saveRoute(
          again,
          downloader: dl(),
          tilePause: Duration.zero,
        );
        expect(res2.complete, isTrue);
        expect(t.areas.entries.length, 1);
        expect(t.layers.roads.length, 1);
        expect(t.layers.trails.length, 1);
        // Delete removes everything.
        await t.deleteArea(t.areas.entries.single);
        expect(t.areas.entries, isEmpty);
        expect(t.routes.all, isEmpty);
        expect(t.tiles.regions, isEmpty);
        expect(t.layers.roads, isEmpty);
        expect(t.layers.trails, isEmpty);
      },
    );

    test('cancel keeps the route; resume finishes the same item', () async {
      final r = await startDrive();
      var stop = false;
      final res = await t.saveRoute(
        r,
        downloader: dl(),
        tilePause: Duration.zero,
        cancelled: () => stop,
        onProgress: (p) {
          if (p.step == 'Roads') stop = true;
        },
      );
      expect(res.cancelled, isTrue);
      expect(res.complete, isFalse);
      var e = t.areas.entries.single;
      expect(e.route!.isReady, isFalse);
      expect(e.regions, isNotEmpty);
      expect(e.roadLayers, isEmpty);
      // Resume.
      final res2 = await t.saveRoute(
        t.routes.all.single,
        downloader: dl(),
        tilePause: Duration.zero,
      );
      expect(res2.complete, isTrue, reason: res2.problems.join(';'));
      e = t.areas.entries.single;
      expect(e.route!.isReady, isTrue);
      expect(e.roadLayers.length, 1);
    });

    test('cancel before anything is kept leaves nothing behind', () async {
      final r = await startDrive();
      final res = await t.saveRoute(
        r,
        downloader: dl(),
        tilePause: Duration.zero,
        cancelled: () => true,
      );
      expect(res.cancelled, isTrue);
      expect(res.entry, isNull);
      expect(t.areas.entries, isEmpty);
      expect(t.routes.all, isEmpty);
    });

    test('Offline power save: no downloads', () async {
      final r = await startDrive();
      await t.setOfflineSaver(true);
      await expectLater(
        () => t.saveRoute(r, downloader: dl(), tilePause: Duration.zero),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'drive then hike: both legs, trailhead, elevation, one item',
      () async {
        osrm = osrmJson();
        t.onFix(Fix(at(0, 0), DateTime.now()));
        final s = (await t.driveTo(
          at(3000, 2000),
          name: 'Silver Star Trailhead',
          hikeTo: at(3000, 3200),
          hikeName: 'Silver Star Summit',
        )).session!;
        s.hikePreview = hikeRoute();
        final r = t.currentRouteForSave()!;
        expect(r.name, 'Silver Star Summit');
        expect(r.trailheadName, 'Silver Star Trailhead');
        expect(r.hike, isNotNull);
        seed(r);
        final res = await t.saveRoute(
          r,
          downloader: dl(),
          tilePause: Duration.zero,
        );
        expect(res.complete, isTrue, reason: res.problems.join(';'));
        final e = t.areas.entries.single;
        expect(e.name, 'Silver Star Summit');
        expect(e.regions.map((x) => x.sourceId).toSet(), {'topo', 'terrarium'});
        expect(e.route!.hike!.junctions, isNotEmpty);
        expect(e.route!.trailheadName, 'Silver Star Trailhead');
      },
    );

    test('no signal and no new route: the saved route carries on, then online again', () async {
      final r = await startDrive();
      await t.saveRoute(r, downloader: dl(), tilePause: Duration.zero);
      // Lose the roads (nothing to plan from) and the signal.
      for (final l in List.of(t.layers.roads)) {
        await t.layers.delete(l);
      }
      osrm = null;
      final d = t.drive!;
      t.onFix(Fix(at(1500, 700), DateTime.now())); // beside the route
      expect(await t.rerouteDrive(), isTrue);
      expect(t.drive!.route.isSaved, isTrue);
      expect(t.drive!.sourceLabel, 'Saved route');
      expect(t.drive!.notice, contains('saved route'));
      expect(identical(t.drive, d), isTrue);
      // Signal back: switches to an online route by itself.
      osrm = osrmJson();
      t.mapNet.fail(hard: true);
      t.mapNet.ok();
      for (var i = 0; i < 20 && !t.drive!.route.isOnline; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(t.drive!.route.isOnline, isTrue);
      expect(t.drive!.savedFallback, isFalse);
    });

    test(
      'Navigate here with no signal uses the saved route to the same place',
      () async {
        final r = await startDrive();
        await t.saveRoute(r, downloader: dl(), tilePause: Duration.zero);
        await t.stopDrive();
        for (final l in List.of(t.layers.roads)) {
          await t.layers.delete(l);
        }
        for (final l in List.of(t.layers.trails)) {
          await t.layers.delete(l);
        }
        osrm = null;
        t.onFix(Fix(at(100, 50), DateTime.now()));
        final p = await t.planSmart(
          at(3000, 2000),
          name: 'Silver Star Trailhead',
        );
        expect(p.kind, SmartKind.drive);
        expect(p.drive!.isSaved, isTrue);
        expect(p.message, contains('saved route'));
        // Far from the saved route: not used.
        t.onFix(Fix(at(-60000, 40000), DateTime.now()));
        final far = await t.planSmart(at(3000, 2000));
        expect(far.ok, isFalse);
      },
    );
  });

  group('screens', () {
    late Directory tmp;
    late TripController t;
    String? osrm = osrmJson();

    Future<String> fetch(FetchRequest r) async {
      if (r.uri.path.contains('/route/v1/driving/')) {
        if (osrm == null) throw NoSignalException();
        return osrm!;
      }
      final body = r.body ?? '';
      final q = Uri.decodeQueryComponent(
        body.startsWith('data=') ? body.substring(5) : body,
      );
      if (q.contains('route"="hiking') || q.contains('trailhead')) {
        return '{"elements":[]}';
      }
      return network().overpassJson();
    }

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('v220ui');
      osrm = osrmJson();
      t = TripController(
        host: FakeHost(1),
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
        fetch: fetch,
        searchLimiter: RateLimiter(Duration.zero),
      );
      t.roads = RoadService.inline();
      t.speaker = SilentSpeaker();
      t.onlineRouter = OnlineRouter(
        fetch: fetch,
        limiter: RateLimiter(Duration.zero),
      );
      await t.start();
    });
    tearDown(() {
      t.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    Future<void> small(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
    }

    testWidgets(
      'the drive card has the button; the sheet shows size, saves, resumes',
      (tester) async {
        await small(tester);
        await tester.runAsync(() async {
          t.onFix(Fix(at(0, 0), DateTime.now()));
          await t.driveTo(at(3000, 2000), name: 'Silver Star Trailhead');
          // Tiles already there, so the test needs no tile server.
          final r = t.currentRouteForSave()!;
          for (final j in routeSaveJobs(r, MapSource.topo).tiles) {
            for (final id in j.tiles) {
              final f = File(
                '${tmp.path}/tiles/${j.src.id}/${id.z}/${id.x}/${id.y}.png',
              );
              f.parent.createSync(recursive: true);
              f.writeAsBytesSync(List.filled(100, 1));
            }
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: DriveCard(trip: t, session: t.drive!, onFollow: () {}),
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('saveRouteBtn')), findsOneWidget);
        expect(find.text('Save route for offline'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('saveRouteBtn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('saveRouteSheet')), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('saveRouteEstimate'))).data,
          startsWith('About '),
        );
        expect(
          find.textContaining('named Silver Star Trailhead'),
          findsOneWidget,
        );
        expect(find.text('Save'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => t.stopDrive());
      },
    );

    testWidgets('sheet: Save runs, shows the result, Done closes', (
      tester,
    ) async {
      await small(tester);
      late SavedRoute r;
      await tester.runAsync(() async {
        t.onFix(Fix(at(0, 0), DateTime.now()));
        await t.driveTo(at(3000, 2000), name: 'Silver Star Trailhead');
        r = t.currentRouteForSave()!;
        for (final j in routeSaveJobs(r, MapSource.topo).tiles) {
          for (final id in j.tiles) {
            final f = File(
              '${tmp.path}/tiles/${j.src.id}/${id.z}/${id.x}/${id.y}.png',
            );
            f.parent.createSync(recursive: true);
            f.writeAsBytesSync(List.filled(100, 1));
          }
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSheetBody(
              builder: (_) => SaveRouteSheetBody(
                trip: t,
                route: r,
                tilePause: Duration.zero,
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('saveRouteGo')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('saveRouteGo')));
        // Up to 12 s: the PC runs the whole suite in parallel and 3 s was
        // not always enough there (v2.3.0 release build).
        for (var i = 0; i < 400; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          if (t.routes.all.isNotEmpty && t.routes.all.first.isReady) break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('saveRouteResult')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('saveRouteResult'))).data,
        startsWith('Saved Silver Star Trailhead'),
      );
      expect(find.byKey(const Key('saveRouteGo')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => t.stopDrive());
    });

    testWidgets('the walk card has the button too; compass has none', (
      tester,
    ) async {
      await small(tester);
      await tester.runAsync(() async {
        t.onFix(Fix(at(0, 0), DateTime.now()));
        await t.navigateTo(at(500, 500), name: 'Spot', compass: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NavCard(trip: t, session: t.nav!, onFollow: () {}),
          ),
        ),
      );
      expect(find.byKey(const Key('saveRouteBtn')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => t.stopNav());
    });

    testWidgets(
      'Offline areas lists the route as one item with Download again',
      (tester) async {
        await small(tester);
        await tester.runAsync(() async {
          t.onFix(Fix(at(0, 0), DateTime.now()));
          await t.driveTo(at(3000, 2000), name: 'Silver Star Trailhead');
          final r = t.currentRouteForSave()!;
          for (final j in routeSaveJobs(r, MapSource.topo).tiles) {
            for (final id in j.tiles) {
              final f = File(
                '${tmp.path}/tiles/${j.src.id}/${id.z}/${id.x}/${id.y}.png',
              );
              f.parent.createSync(recursive: true);
              f.writeAsBytesSync(List.filled(100, 1));
            }
          }
          await t.saveRoute(r, tilePause: Duration.zero);
        });
        await tester.pumpWidget(MaterialApp(home: OfflineAreasPage(trip: t)));
        await tester.pump();
        expect(find.text('Silver Star Trailhead'), findsOneWidget);
        expect(find.textContaining('Route: drive'), findsOneWidget);
        await tester.tap(find.byKey(Key('areaMenu:${t.routes.all.single.id}')));
        await tester.pumpAndSettle();
        expect(find.text('Download again'), findsOneWidget);
        expect(find.text('Update'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => t.stopDrive());
      },
    );
  });
}
