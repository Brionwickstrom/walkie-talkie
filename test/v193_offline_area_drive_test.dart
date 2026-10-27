import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/drive/drive_session.dart';
import 'package:walkie_talkie/trip/drive/online_router.dart';
import 'package:walkie_talkie/trip/drive/road_data.dart';
import 'package:walkie_talkie/trip/drive/road_download.dart';
import 'package:walkie_talkie/trip/drive/road_router.dart';
import 'package:walkie_talkie/trip/drive/road_service.dart';
import 'package:walkie_talkie/trip/drive/speech.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/offline_areas.dart';
import 'package:walkie_talkie/trip/search/fetch.dart';
import 'package:walkie_talkie/trip/search/rate_limiter.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/drive_page.dart';

import 'trip_integration_test.dart' show FakeHost;
import 'v192_drive_test.dart' show Osm, at, chain;

/// Google polyline, 6 digits (what OSRM sends).
String encodePolyline(List<GeoPoint> pts) {
  final b = StringBuffer();
  var plat = 0, plng = 0;
  void enc(int v) {
    var x = v < 0 ? ~(v << 1) : v << 1;
    while (x >= 0x20) {
      b.writeCharCode((0x20 | (x & 0x1f)) + 63);
      x >>= 5;
    }
    b.writeCharCode(x + 63);
  }

  for (final p in pts) {
    final la = (p.lat * 1e6).round(), ln = (p.lng * 1e6).round();
    enc(la - plat);
    enc(ln - plng);
    plat = la;
    plng = ln;
  }
  return b.toString();
}

/// An OSRM answer: east on First Street 3 km, left (north) onto
/// Silverstar Road 2 km.
String osrmJson({double startOff = 3, double endOff = 4}) {
  final pts = [
    for (var e = 0.0; e <= 3000; e += 250) at(e, 0),
    for (var n = 250.0; n <= 2000; n += 250) at(3000, n),
  ];
  final durs = [for (var i = 0; i + 1 < pts.length; i++) 250 / 15.0];
  List<double> ll(GeoPoint p) => [p.lng, p.lat];
  return jsonEncode({
    'code': 'Ok',
    'routes': [
      {
        'geometry': encodePolyline(pts),
        'distance': 5000.0,
        'duration': durs.fold(0.0, (a, b) => a + b),
        'legs': [
          {
            'annotation': {'duration': durs},
            'steps': [
              {
                'name': 'First Street',
                'distance': 3000.0,
                'maneuver': {
                  'type': 'depart',
                  'bearing_after': 90,
                  'location': ll(pts.first),
                },
              },
              {
                'name': 'Silverstar Road',
                'ref': 'FS 4109',
                'distance': 2000.0,
                'maneuver': {
                  'type': 'turn',
                  'modifier': 'left',
                  'location': ll(at(3000, 0)),
                },
              },
              {
                'name': 'Silverstar Road',
                'distance': 0.0,
                'maneuver': {'type': 'arrive', 'location': ll(pts.last)},
              },
            ],
          },
        ],
      },
    ],
    'waypoints': [
      {'location': ll(pts.first), 'distance': startOff},
      {'location': ll(pts.last), 'distance': endOff},
    ],
  });
}

/// Saved-roads test network (same as v1.9.2's): First Street east, gravel
/// FR 4109 north at 3 km, a spur south.
Osm network({bool lockedGate = false}) {
  final o = Osm();
  final first = chain(o, 100, 0, 0, 3000, 0);
  o.road(first, {'highway': 'primary', 'name': 'First Street'});
  final fr = chain(o, 200, 3000, 0, 3000, 2000, first: first.last);
  if (lockedGate) o.nodeTags[fr[4]] = {'barrier': 'gate', 'access': 'no'};
  o.road(fr, {
    'highway': 'unclassified',
    'name': 'Silverstar Road',
    'ref': 'FS 4109',
    'surface': 'gravel',
    'smoothness': 'bad',
  });
  o.road(chain(o, 300, 3000, 0, 3000, -500, first: first.last), {
    'highway': 'residential',
    'name': 'Spur',
  });
  return o;
}

void main() {
  late Directory tmp;
  late FakeHost host;
  late TripController t;
  late SilentSpeaker voice;
  late Osm o;
  var online = 0;
  String? osrm; // null = no signal
  Object? osrmError;

  Future<MapLayer> addRoads(RoadData d, String name) => t.layers.importRoads(
    name,
    d.encode(),
    area: d.bounds,
    summary: TripController.roadsSummary(d.roadKm, d.builtAt),
  );

  String overpass(FetchRequest r) {
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
            'tags': {'highway': 'path', 'name': 'Silver Star Trail'},
            'geometry': [
              {'lat': a.lat, 'lon': a.lng},
              {'lat': b.lat, 'lon': b.lng},
            ],
          },
          {
            'type': 'node',
            'id': 8,
            'lat': a.lat,
            'lon': a.lng,
            'tags': {'highway': 'trailhead', 'name': 'Silver Star Trailhead'},
          },
        ],
      });
    }
    return o.overpassJson();
  }

  Future<String> fetch(FetchRequest r) async {
    if (r.uri.path.contains('/route/v1/driving/')) {
      online++;
      if (osrmError != null) throw osrmError!;
      if (osrm == null) throw NoSignalException();
      return osrm!;
    }
    return overpass(r);
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
    c.speaker = voice = SilentSpeaker();
    c.onlineRouter = OnlineRouter(
      fetch: fetch,
      limiter: RateLimiter(Duration.zero),
    );
    await c.start();
    return c;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('v193');
    host = FakeHost(1);
    online = 0;
    osrm = null;
    osrmError = null;
    o = network();
    t = await make();
  });
  tearDown(() {
    t.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Put tiles on the "phone" so saving needs no tile server.
  void seedTiles(MapSource s, GeoBounds b, int z0, int z1) {
    for (final id in tilesIn(b, z0, z1)) {
      final f = File('${tmp.path}/tiles/${s.id}/${id.z}/${id.x}/${id.y}.png');
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(List.filled(100, 1));
    }
  }

  group('one offline area', () {
    test('migration: old map downloads and road areas become areas', () async {
      t.dispose();
      final b = GeoBounds(
        at(-200, -200).lat,
        at(-200, -200).lng,
        at(3200, 2200).lat,
        at(3200, 2200).lng,
      );
      // v1.9.1: "Trip area" saved as topo + elevation (no area id).
      final cache = TileCache(Directory('${tmp.path}/tiles'), userAgent: 't');
      for (final src in ['topo', 'terrarium']) {
        cache.regions.add(
          OfflineRegion(
            name: 'Trip area',
            sourceId: src,
            bounds: b,
            minZoom: 12,
            maxZoom: src == 'topo' ? 14 : 12,
            tiles: 10,
            bytes: 1000,
            at: DateTime(2026, 10, 20),
          ),
        );
      }
      await cache.saveRegions();
      // v1.9.2: a road area of the same place, one elsewhere, a pack.
      final layers = MapLayers(Directory('${tmp.path}/layers'));
      await layers.load();
      final d = o.build();
      await layers.importRoads('Silver Star roads', d.encode(), area: b);
      final far = GeoBounds(b.south + 1, b.west, b.north + 1, b.east);
      await layers.importRoads('Far roads', d.encode(), area: far);
      final pack = await layers.importRoads(
        'GP roads',
        d.encode(),
        area: d.bounds,
      );
      await layers.tagPack(pack, 'gp-roads', 'gp_roads.wtr');
      t = await make();
      final e = t.areas.entries;
      expect(e.length, 3);
      final trip = e.firstWhere((x) => x.name == 'Trip area');
      expect(trip.regions.map((r) => r.sourceId).toSet(), {
        'topo',
        'terrarium',
      });
      expect(trip.roadLayers.single.name, 'Silver Star roads');
      expect(trip.parts.first, contains('Topo'));
      expect(trip.parts, contains(startsWith('Roads')));
      expect(trip.area!.styles, ['topo']);
      expect(e.firstWhere((x) => x.name == 'Far roads').hasRoads, isTrue);
      final p = e.firstWhere((x) => x.isPack);
      expect(p.id, 'pack:gp-roads');
      expect(p.layers.single.id, pack.id);
      // Kept on disk: a restart finds the same areas, makes no new ones.
      final ids = e.map((x) => x.id).toList();
      t.dispose();
      t = await make();
      expect(t.areas.entries.map((x) => x.id), ids);
      expect(await t.areas.migrate(), 0);
      expect(t.tiles.regions.every((r) => r.areaId == trip.id), isTrue);
      // Removing the pack from the list deletes its file.
      await t.deleteArea(t.areas.entries.firstWhere((x) => x.isPack));
      expect(t.layers.byId(pack.id), isNull);
    });

    test(
      'save map + elevation + roads + trails together; update; delete',
      () async {
        t.tiles.online = true;
        final b = GeoBounds(
          at(-200, -200).lat,
          at(-200, -200).lng,
          at(3200, 2200).lat,
          at(3200, 2200).lng,
        );
        seedTiles(MapSource.topo, b, 12, 13);
        seedTiles(MapSource.terrarium, b, 12, 12);
        final dl = RoadDownloader(
          fetch: fetch,
          limiter: RateLimiter(Duration.zero),
          endpoints: const ['https://example.com/api'],
        );
        final opts = AreaSaveOptions(
          bounds: b,
          name: 'Silver Star',
          styles: const [MapSource.topo],
          minZoom: 12,
          maxZoom: 13,
        );
        final est = await t.estimateArea(opts, downloader: dl);
        expect(est.tiles, countTiles(b, 12, 13) + countTiles(b, 12, 12));
        expect(est.roadBytes, RoadEstimate(40).bytes);
        expect(est.tooBig, isNull);
        final steps = <String>[];
        final r = await t.saveArea(
          opts,
          downloader: dl,
          tilePause: Duration.zero,
          onProgress: (p) {
            if (!steps.contains(p.step)) steps.add(p.step);
          },
        );
        expect(r.problems, isEmpty);
        expect(steps, [
          'Map: Topo (OpenTopoMap)',
          'Map: Elevation data',
          'Roads',
          'Trails',
        ]);
        final e = r.entry!;
        expect(e.name, 'Silver Star');
        expect(e.regions.map((x) => x.sourceId), ['topo', 'terrarium']);
        expect(e.roadLayers.single.name, 'Silver Star roads');
        expect(e.trailLayers.single.name, 'Silver Star trails');
        expect(t.areas.entries.length, 1);
        // Driving works offline from the area's roads.
        t.tiles.online = false;
        t.onFix(Fix(at(0, 0), DateTime.now()));
        expect((await t.driveTo(at(3000, 2000))).session, isNotNull);
        await t.stopDrive();
        t.tiles.online = true;
        // Duplicate check: the same box is found.
        expect(t.areas.similar(b)?.id, e.id);
        expect(
          t.areas.similar(
            GeoBounds(b.south + 0.5, b.west, b.north + 0.5, b.east),
          ),
          isNull,
        );
        // Customizable: update without trails and with hillshade added.
        seedTiles(MapSource.usgsRelief, b, 12, 13);
        final u = await t.saveArea(
          AreaSaveOptions(
            bounds: b,
            name: 'Silver Star',
            styles: const [MapSource.topo, MapSource.usgsRelief],
            minZoom: 12,
            maxZoom: 13,
            trails: false,
          ),
          updateId: e.id,
          downloader: dl,
          tilePause: Duration.zero,
        );
        final e2 = u.entry!;
        expect(e2.id, e.id);
        expect(e2.trailLayers, isEmpty);
        expect(e2.regions.map((x) => x.sourceId).toSet(), {
          'topo',
          'usgs_relief',
          'terrarium',
        });
        expect(e2.regions.length, 3);
        expect(e2.roadLayers.length, 1);
        expect(t.layers.trails, isEmpty);
        // Rename names everything in it.
        await t.areas.rename(e2, 'Silver Star Mtn');
        expect(t.layers.roads.single.name, 'Silver Star Mtn roads');
        // Delete: tiles, roads and the area go.
        await t.deleteArea(t.areas.entry(e.id)!);
        expect(t.areas.entries, isEmpty);
        expect(t.tiles.regions, isEmpty);
        expect(t.layers.roads, isEmpty);
        final id = tilesIn(b, 12, 12).first;
        expect(
          File('${tmp.path}/tiles/topo/${id.z}/${id.x}/${id.y}.png')
              .existsSync(),
          isFalse,
        );
      },
    );

    test('too big: map refused per style; roads split or left out', () async {
      final huge = const GeoBounds(45.0, -123.0, 46.5, -121.5);
      await expectLater(
        () => t.saveArea(AreaSaveOptions(bounds: huge, name: 'Big')),
        throwsA(isA<StateError>()),
      );
      expect(t.areas.entries, isEmpty);
      expect(roadPieces(const GeoBounds(45, -123, 45.9, -122.1))!.length, 1);
      expect(roadPieces(const GeoBounds(45, -123, 46.5, -121.5))!.length, 4);
      expect(roadPieces(const GeoBounds(45, -124, 47.5, -121)), isNull);
      final e = await t.estimateArea(
        AreaSaveOptions(bounds: huge, name: 'x'),
        withRoads: false,
      );
      expect(e.tooBig, isNotNull);
    });
  });

  group('online driving, offline fallback', () {
    test('online route with signal; checked against saved roads', () async {
      t.tiles.online = true;
      osrm = osrmJson();
      await addRoads(o.build(), 'Test roads');
      t.onFix(Fix(at(0, 0), DateTime.now(), speedMps: 15));
      final res = await t.driveTo(at(3000, 2000), name: 'Trailhead');
      final s = res.session!;
      expect(online, 1);
      expect(s.route.isOnline, isTrue);
      expect(s.sourceLabel, 'Online route');
      expect(s.route.steps[1].text, 'Turn left onto Silverstar Road (FR 4109)');
      expect(voice.said.first, startsWith('Head east on First Street'));
      // Rough road known from the saved roads, even on the online route.
      expect(mainWarnings(s.route).first.text, contains('rough'));
      expect(s.route.segRough.last, 2);
      expect(s.route.warnings.any((w) => w.kind == 'unknown'), isFalse);
    });

    test(
      'online route with no roads saved: works, gates not checked',
      () async {
        t.tiles.online = true;
        osrm = osrmJson();
        t.onFix(Fix(at(0, 0), DateTime.now()));
        final s = (await t.driveTo(at(3000, 2000))).session!;
        expect(s.route.isOnline, isTrue);
        expect(
          s.route.warnings.single.text,
          contains('Gates and road surface not checked'),
        );
        expect(mainWarnings(s.route), isEmpty);
      },
    );

    test('no signal (or a slow / failing server): offline route', () async {
      t.tiles.online = true;
      await addRoads(o.build(), 'Test roads');
      t.onFix(Fix(at(0, 0), DateTime.now()));
      var s = (await t.driveTo(at(3000, 2000))).session!;
      expect(online, 1);
      expect(s.route.isOnline, isFalse);
      expect(s.sourceLabel, 'Offline route');
      // Server error: next server, then offline, and it says why.
      osrmError = FetchException('Map search failed (HTTP 500).', status: 500);
      final r = await t.driveTo(at(3000, 2000));
      expect(online, 3);
      s = r.session!;
      expect(s.route.isOnline, isFalse);
      expect(r.message, contains('HTTP 500'));
      // Too slow: gives up after the timeout.
      osrmError = null;
      t.onlineRouter = OnlineRouter(
        fetch: (_) => Completer<String>().future,
        limiter: RateLimiter(Duration.zero),
        timeout: const Duration(milliseconds: 600),
      );
      final sw = Stopwatch()..start();
      s = (await t.driveTo(at(3000, 2000))).session!;
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(s.route.isOnline, isFalse);
      // Offline power save: online is not even tried.
      t.onlineRouter = OnlineRouter(
        fetch: fetch,
        limiter: RateLimiter(Duration.zero),
      );
      online = 0;
      await t.setOfflineSaver(true);
      s = (await t.driveTo(at(3000, 2000))).session!;
      expect(online, 0);
      expect(s.route.isOnline, isFalse);
    });

    test(
      'destination outside online coverage: offline, else says so',
      () async {
        t.tiles.online = true;
        osrm = osrmJson(endOff: 50000);
        t.onFix(Fix(at(0, 0), DateTime.now()));
        var r = await t.driveTo(at(3000, 2000));
        expect(r.session, isNull);
        expect(r.message, contains('far from any road'));
        await addRoads(o.build(), 'Test roads');
        r = await t.driveTo(at(3000, 2000));
        expect(r.session!.route.isOnline, isFalse);
      },
    );

    test('no signal and no saved roads: says so', () async {
      t.tiles.online = true;
      t.onFix(Fix(at(0, 0), DateTime.now()));
      final r = await t.driveTo(at(3000, 2000));
      expect(r.session, isNull);
      expect(r.message, TripController.noRoadsMessage);
    });

    test(
      'locked gate on the online route: the offline route is used',
      () async {
        t.tiles.online = true;
        osrm = osrmJson();
        o = network(lockedGate: true);
        await addRoads(o.build(), 'Test roads');
        final g = RoadGraph(o.build());
        final online = OnlineRouter.parse(osrmJson());
        final c = g.check(online);
        expect(c.lockedGate, isTrue);
        expect(c.warnings.map((w) => w.kind), contains('gate'));
        t.onFix(Fix(at(0, 0), DateTime.now()));
        final r = await t.driveTo(at(3000, 2000));
        // Through the gate is the only way: offline goes through with a
        // warning, and says why it is not the online one.
        expect(r.session!.route.isOnline, isFalse);
        expect(r.message, contains('locked gate'));
        expect(r.session!.notice, contains('locked gate'));
      },
    );

    test(
      'drive to the trailhead, then hike, online with no saved roads',
      () async {
        t.tiles.online = true;
        osrm = osrmJson();
        t.onFix(Fix(at(0, 0), DateTime.now()));
        final r = await t.driveThenHike(at(3300, 2500), name: 'Summit');
        expect(r.session!.route.isOnline, isTrue);
        expect(r.session!.hikeTo!.lat, closeTo(at(3300, 2500).lat, 1e-9));
      },
    );
  });

  group('route kept on the phone', () {
    test('online route keeps guiding after the signal drops; off route '
        'with no roads says so; survives a restart', () async {
      t.tiles.online = true;
      osrm = osrmJson();
      t.onFix(Fix(at(0, 0), DateTime.now(), speedMps: 20));
      final s = (await t.driveTo(at(3000, 2000), name: 'Trailhead')).session!;
      expect(s.route.isOnline, isTrue);
      expect(File('${tmp.path}/drive_active.json').existsSync(), isTrue);
      // Signal gone.
      osrm = null;
      var time = DateTime.now();
      for (var e = 100.0; e <= 2900; e += 100) {
        time = time.add(const Duration(seconds: 5));
        t.onFix(Fix(at(e, 0), time, speedMps: 20));
      }
      expect(t.drive, same(s));
      expect(voice.said, contains('Turn left onto Silverstar Road (FR 4109).'));
      expect(s.state!.leftM, closeTo(2100, 60));
      // Wrong turn down the spur, no signal, no saved roads.
      t.onFix(Fix(at(3000, -200), time, speedMps: 10));
      t.onFix(Fix(at(3000, -300), time, speedMps: 10));
      for (var i = 0; i < 20 && s.rerouting; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await pumpEventQueue();
      expect(voice.said, contains('Rerouting.'));
      expect(s.notice, TripController.offRouteNoRoads);
      expect(voice.said, contains(TripController.offRouteNoRoads));
      expect(t.drive!.route.isOnline, isTrue); // the kept route stays
      // App restart mid-drive: carries on with the kept route.
      t.dispose();
      t = await make();
      final back = t.drive!;
      expect(back.route.isOnline, isTrue);
      expect(back.name, 'Trailhead');
      expect(back.route.steps.length, s.route.steps.length);
      expect(back.notice, contains('Carrying on'));
      await t.stopDrive();
      expect(File('${tmp.path}/drive_active.json').existsSync(), isFalse);
    });

    test(
      'off route with signal: re-routed online; without: from saved roads',
      () async {
        t.tiles.online = true;
        osrm = osrmJson();
        await addRoads(o.build(), 'Test roads');
        t.onFix(Fix(at(0, 0), DateTime.now(), speedMps: 20));
        await t.driveTo(at(3000, 2000));
        osrm = null; // no signal
        var time = DateTime.now();
        for (var e = 100.0; e <= 3000; e += 100) {
          time = time.add(const Duration(seconds: 5));
          t.onFix(Fix(at(e, 0), time, speedMps: 20));
        }
        t.onFix(Fix(at(3000, -200), time, speedMps: 10));
        t.onFix(Fix(at(3000, -300), time, speedMps: 10));
        for (var i = 0; i < 50 && t.drive!.route.isOnline; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(t.drive!.route.isOnline, isFalse);
        expect(
          t.drive!.route.points.first.lat,
          closeTo(at(3000, -300).lat, 1e-4),
        );
        // Signal back: the next re-route is online again.
        osrm = osrmJson();
        expect(await t.rerouteDrive(), isTrue);
        expect(t.drive!.route.isOnline, isTrue);
      },
    );

    test('route JSON round trip', () {
      final r = OnlineRouter.parse(osrmJson(), name: 'X');
      final back = DriveRoute.fromJson(jsonDecode(jsonEncode(r.toJson())))!;
      expect(back.isOnline, isTrue);
      expect(back.points.length, r.points.length);
      expect(back.lengthM, closeTo(r.lengthM, 1));
      expect(back.duration.inSeconds, closeTo(r.duration.inSeconds, 1));
      expect(back.steps.map((s) => s.text), r.steps.map((s) => s.text));
      final s = DriveSession.fromJson(
        DriveSession(
          target: at(1, 2),
          name: 'X',
          route: r,
          imperial: true,
        ).toJson(DateTime(2026)),
        imperial: true,
      )!;
      expect(s.session.name, 'X');
      expect(s.at, DateTime(2026));
    });
  });

  testWidgets('the card and steps say Online route / Offline route', (
    tester,
  ) async {
    t.tiles.online = true;
    osrm = osrmJson();
    await tester.runAsync(() async {
      t.onFix(Fix(at(0, 0), DateTime.now()));
      await t.driveTo(at(3000, 2000), name: 'Trailhead');
    });
    final s = t.drive!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DriveCard(trip: t, session: s, onFollow: () {}),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('driveSource'))).data,
      startsWith('Online route'),
    );
    expect(find.byKey(const Key('driveUnknown')), findsOneWidget);
    await tester.tap(find.byKey(const Key('driveSteps')));
    await tester.pumpAndSettle();
    expect(find.textContaining('routing.openstreetmap.de'), findsOneWidget);
    expect(find.textContaining('no live traffic'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => t.stopDrive());
  });

  group('OSRM answers', () {
    test('polyline6 decode', () {
      final pts = [at(0, 0), at(100, 50), at(-3000, 2000)];
      final d = OnlineRouter.decodePolyline(encodePolyline(pts));
      for (var i = 0; i < pts.length; i++) {
        expect(d[i].lat, closeTo(pts[i].lat, 1e-6));
        expect(d[i].lng, closeTo(pts[i].lng, 1e-6));
      }
    });

    test('request: car profile, full geometry, steps, polite', () {
      final u = OnlineRouter.routeUri(
        OnlineRouter.defaultEndpoints.first,
        const GeoPoint(45.519, -122.6795),
        const GeoPoint(45.772598, -122.244409),
        course: 370,
      );
      expect(u.host, 'routing.openstreetmap.de');
      expect(
        u.path,
        '/routed-car/route/v1/driving/-122.679500,45.519000;-122.244409,45.772598',
      );
      expect(u.queryParameters['steps'], 'true');
      expect(u.queryParameters['geometries'], 'polyline6');
      expect(u.queryParameters['bearings'], '10,60;');
      expect(OnlineRouter.attribution, contains('OpenStreetMap'));
      expect(OnlineRouter.attribution, contains('fixthemap'));
    });

    test('maneuvers become our steps (ramps, forks, roundabouts)', () {
      Map step(
        String type,
        String? mod, {
        String name = '',
        String? ref,
        String? dest,
        int? exit,
      }) => {
        'name': name,
        'ref': ?ref,
        'destinations': ?dest,
        'distance': 100.0,
        'maneuver': {
          'type': type,
          'modifier': ?mod,
          'exit': ?exit,
          'bearing_after': 0,
          'location': [-122.0, 45.0],
        },
      };
      final pts = [const GeoPoint(45, -122), const GeoPoint(45.01, -122)];
      final j = jsonEncode({
        'code': 'Ok',
        'waypoints': [
          {'distance': 1},
          {'distance': 1},
        ],
        'routes': [
          {
            'geometry': encodePolyline(pts),
            'distance': 1000.0,
            'duration': 60.0,
            'legs': [
              {
                'steps': [
                  step('depart', null, name: 'A Street'),
                  step('on ramp', 'slight right', dest: 'I 5: Seattle'),
                  step('fork', 'slight left', ref: 'I 205'),
                  step('new name', 'straight', name: 'B Street'),
                  step('roundabout', 'right', name: 'C Road', exit: 2),
                  step('exit roundabout', 'right', name: 'C Road'),
                  step('off ramp', 'right', dest: 'SR 14: Camas'),
                  step('end of road', 'left', name: 'D Road', ref: 'NF 41'),
                  step('arrive', null),
                ],
              },
            ],
          },
        ],
      });
      final r = OnlineRouter.parse(j, name: 'Camp');
      expect(r.steps.map((s) => s.text), [
        'Head N on A Street',
        'Take the ramp on the right toward I-5 (Seattle)',
        'Keep left onto I-205',
        'At the roundabout, take the 2nd exit onto C Road',
        'Take the exit on the right toward SR 14 (Camas)',
        'Turn left onto D Road (FR 41)',
        'Arrive at Camp',
      ]);
      expect(
        r.steps[3].spoken,
        'at the roundabout, take the second exit onto C Road',
      );
      expect(r.timeCum.last, closeTo(60, 0.01));
      expect(
        () => OnlineRouter.parse('{"code":"NoRoute"}'),
        throwsA(
          isA<OnlineRouteException>().having(
            (e) => e.kind,
            'kind',
            OnlineFail.noRoute,
          ),
        ),
      );
    });

    test(
      'real online route from the routing server (ONLINE=1)',
      () async {
        final router = OnlineRouter(
          fetch: ioFetch(
            'WalkieTalkie/1.9.3 test (+https://github.com/Brionwickstrom/walkie-talkie)',
          ),
        );
        final r = await router.route(
          const GeoPoint(45.5190, -122.6795),
          const GeoPoint(45.772598, -122.244409),
          name: 'Silver Star Mountain Trailhead',
        );
        expect(r.isOnline, isTrue);
        expect(r.lengthM / 1609.344, inInclusiveRange(35, 70));
        expect(r.steps.map((s) => s.text), contains(contains('FR 4109')));
        expect(r.steps.last.maneuver, Maneuver.arrive);
      },
      skip: Platform.environment['ONLINE'] == null ? 'set ONLINE=1' : false,
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
