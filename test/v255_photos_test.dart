import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imagery.dart';
import 'package:walkie_talkie/trip/offline_areas.dart';
import 'package:walkie_talkie/trip/route_save.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_layer_widgets.dart';

import 'trip_integration_test.dart' show FakeHost;

// v2.5.5: newer satellite photos. The photo services are pretend servers on
// this machine; nothing here reaches the internet.

final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));
final blankPng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]);
final oldBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

// Tiles: Portland (Oregon) and Seattle (Washington).
const pdx17 = (z: 17, x: 20870, y: 46879);
const pdx16 = (z: 16, x: 10435, y: 23439);
const pdx13 = (z: 13, x: 1304, y: 2929);
const sea17 = (z: 17, x: 20996, y: 45775);

class Server {
  Server._(this.http);
  final HttpServer http;
  final hits = <String>[];
  Uint8List osip = jpeg, naip = jpeg, old = oldBytes;
  int osipStatus = 200, naipStatus = 200;

  static Future<Server> start() async {
    final s = Server._(await HttpServer.bind('127.0.0.1', 0));
    s.http.listen((r) async {
      s.hits.add(r.uri.path);
      Uint8List body;
      var status = 200;
      if (r.uri.path == '/osip') {
        body = s.osip;
        status = s.osipStatus;
      } else if (r.uri.path == '/naip') {
        body = s.naip;
        status = s.naipStatus;
      } else {
        body = s.old;
      }
      r.response.statusCode = status;
      r.response.add(body);
      await r.response.close();
    });
    return s;
  }

  int get port => http.port;
  int count(String p) => hits.where((h) => h == p).length;
  Future<void> stop() => http.close(force: true);
}

MapSource fake(MapSource of, String url) => MapSource(
  id: of.id,
  name: of.name,
  urlTemplate: url,
  attribution: '',
  maxZoom: of.maxZoom,
  allowsOffline: true,
);

class World {
  World(this.dir, this.srv, this.cache);
  final Directory dir;
  final Server srv;
  final TileCache cache;
  File file(String d, TileId t) =>
      File('${dir.path}/$d/${t.z}/${t.x}/${t.y}.png');
}

Future<World> world({Duration? fresh}) async {
  final srv = await Server.start();
  final dir = Directory.systemTemp.createTempSync('photos');
  final c = TileCache(
    dir,
    userAgent: 'test',
    photoFresh: fresh ?? const Duration(days: 60),
  );
  c.oregonPhotos = fake(
    MapSource.osip2024,
    'http://127.0.0.1:${srv.port}/osip?bbox={bbox}',
  );
  c.usPhotos = fake(
    MapSource.naipLive,
    'http://127.0.0.1:${srv.port}/naip?bbox={bbox}',
  );
  c.oldPhotos = fake(
    MapSource.usgsImagery,
    'http://127.0.0.1:${srv.port}/old/{z}/{y}/{x}',
  );
  addTearDown(() async {
    c.close();
    await srv.stop();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return World(dir, srv, c);
}

void main() {
  const sat = MapSource.usgsImagery;
  // The pretend servers are on this machine: let real sockets through.
  setUpAll(() => HttpOverrides.global = null);

  group('where the photos come from', () {
    test('Oregon inside, neighbours outside', () {
      for (final p in const {
        'Portland': (45.52, -122.68),
        'Bend': (44.06, -121.31),
        'Medford': (42.33, -122.87),
        'Pendleton': (45.67, -118.79),
        'Ontario OR': (44.03, -116.96),
        'Astoria': (46.19, -123.83),
      }.entries) {
        expect(inOregon(p.value.$1, p.value.$2), isTrue, reason: p.key);
      }
      for (final p in const {
        'Seattle': (47.61, -122.33),
        'Vancouver WA': (45.70, -122.67),
        'Boise': (43.62, -116.20),
        'Sacramento': (38.58, -121.49),
        'Reno': (39.53, -119.81),
        'Pacific': (45.5, -126.0),
        'Yakima': (46.60, -120.51),
        'Lewiston': (46.42, -117.02),
      }.entries) {
        expect(inOregon(p.value.$1, p.value.$2), isFalse, reason: p.key);
      }
    });

    test('tile centre maths', () {
      final (lat, lng) = tileCenterLatLng(17, 20870, 46879);
      expect(lat, closeTo(45.5231, 0.002));
      expect(lng, closeTo(-122.6765, 0.002));
    });

    test('a real photo is a JPEG, the empty answer is not', () {
      expect(isJpeg(jpeg), isTrue);
      expect(isJpeg(blankPng), isFalse);
      expect(isJpeg(Uint8List(0)), isFalse);
    });

    test('Oregon tiles use OSIP, the rest NAIP', () async {
      final w = await world();
      expect(w.cache.photoSourceFor(17, 20870, 46879).id, 'osip_2024');
      expect(w.cache.photoSourceFor(17, 20996, 45775).id, 'naip_live');
    });

    test('the real service addresses are the ones asked for', () {
      final o = Uri.parse(MapSource.osip2024.urlFor(17, 20870, 46879));
      expect(o.host, 'imagery.oregonexplorer.info');
      expect(
        o.path,
        '/arcgis/rest/services/OSIP_2024/OSIP_2024_WM/ImageServer/exportImage',
      );
      expect(
        o.queryParameters['bbox'],
        '-13656545.22,5704036.80,-13656239.47,5704342.55',
      );
      expect(o.queryParameters['size'], '256,256');
      expect(MapSource.osip2024.maxZoom, 18);
      expect(MapSource.osip2024.allowsOffline, isTrue);
      expect(
        MapSource.osip2024.attribution,
        'Oregon Statewide Imagery Program (OSIP) – Oregon Imagery '
        'Framework Implementation Team',
      );
      final n = Uri.parse(MapSource.naipLive.urlFor(17, 20996, 45775));
      expect(n.host, 'imagery.nationalmap.gov');
      expect(n.path, endsWith('/USGSNAIPImagery/ImageServer/exportImage'));
    });
  });

  group('viewing', () {
    test('Oregon: the 2024 photos, kept on the phone', () async {
      final w = await world();
      final b = await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y);
      expect(b, jpeg);
      expect(w.srv.count('/osip'), 1);
      expect(w.srv.count('/naip'), 0);
      expect(w.file('osip_2024', pdx17).existsSync(), isTrue);
      await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y);
      expect(w.srv.count('/osip'), 1, reason: 'fresh: no second request');
    });

    test('elsewhere: live NAIP', () async {
      final w = await world();
      expect(await w.cache.get(sat, sea17.z, sea17.x, sea17.y), jpeg);
      expect(w.srv.count('/naip'), 1);
      expect(w.srv.count('/osip'), 0);
      expect(w.file('naip_live', sea17).existsSync(), isTrue);
    });

    test('hybrid asks the same photos', () async {
      final w = await world();
      await w.cache.get(MapSource.usgsHybrid, pdx17.z, pdx17.x, pdx17.y);
      expect(w.srv.count('/osip'), 1);
    });

    test('a photo older than the fresh time is fetched again', () async {
      final w = await world(fresh: const Duration(milliseconds: 1));
      await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y);
      expect(w.srv.count('/osip'), 2);
    });

    test('Oregon has no photos at the edge: NAIP fills in', () async {
      final w = await world();
      w.srv.osip = blankPng;
      expect(await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y), jpeg);
      expect(w.srv.count('/osip'), 1);
      expect(w.srv.count('/naip'), 1);
      expect(w.file('naip_live', pdx17).existsSync(), isTrue);
      // remembered: no second ask of Oregon, nothing re-fetched
      await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y);
      expect(w.srv.count('/osip'), 1);
      expect(w.srv.count('/naip'), 1);
    });

    test('no photos anywhere: the old USGS tile (zoom 16)', () async {
      final w = await world();
      w.srv.naip = blankPng;
      expect(await w.cache.get(sat, 16, 10498, 22887), oldBytes);
      expect(w.srv.count('/old/16/22887/10498'), 1);
      expect(
        w.file('usgs_imagery', (z: 16, x: 10498, y: 22887)).existsSync(),
        isTrue,
      );
    });

    test(
      'a service that fails: old tile, and it is left alone after 3',
      () async {
        final w = await world();
        w.srv.naipStatus = 500;
        for (var i = 0; i < 3; i++) {
          // distinct tiles so nothing is "remembered"
          expect(await w.cache.get(sat, 16, 10498 + i, 22887), oldBytes);
        }
        final asked = w.srv.count('/naip');
        expect(asked, 3);
        expect(await w.cache.get(sat, 16, 10520, 22887), oldBytes);
        expect(w.srv.count('/naip'), asked, reason: 'paused after 3 failures');
        // Oregon is a different service and still works
        expect(await w.cache.get(sat, pdx16.z, pdx16.x, pdx16.y), jpeg);
      },
    );

    test('zoom 17 with no new photos: the zoom 16 tile enlarged', () async {
      final w = await world();
      w.srv.naip = blankPng;
      final calls = <(int, int, int)>[];
      w.cache.cropper = (b, s, dx, dy) async {
        expect(b, oldBytes);
        calls.add((s, dx, dy));
        return Uint8List.fromList([7]);
      };
      // Seattle z17 (20996, 45775) -> z16 (10498, 22887), quarter (0, 1)
      expect(await w.cache.get(sat, 17, 20996, 45775), Uint8List.fromList([7]));
      expect(calls, [(1, 0, 1)]);
    });

    test('low zoom: the cached USGS photos, no photo service', () async {
      final w = await world();
      expect(await w.cache.get(sat, pdx13.z - 3, 130, 293), oldBytes);
      expect(w.srv.count('/osip'), 0);
      expect(w.srv.count('/naip'), 0);
    });

    test('zoom 18 outside a saved area is the zoom 17 tile enlarged', () async {
      final w = await world();
      final calls = <(int, int, int)>[];
      w.cache.cropper = (b, s, dx, dy) async {
        calls.add((s, dx, dy));
        return Uint8List.fromList([8]);
      };
      // z18 (41741, 93758) -> z17 (20870, 46879), quarter (1, 0)
      expect(await w.cache.get(sat, 18, 41741, 93758), Uint8List.fromList([8]));
      expect(calls, [(1, 1, 0)]);
      expect(w.srv.count('/osip'), 1, reason: 'only the zoom 17 tile');
      expect(
        w.file('osip_2024', (z: 18, x: 41741, y: 93758)).existsSync(),
        isFalse,
      );
    });

    test('zoom 18 saved with an area is used as it is', () async {
      final w = await world();
      final t = (z: 18, x: 41741, y: 93758);
      w.file('osip_2024', t)
        ..createSync(recursive: true)
        ..writeAsBytesSync(jpeg);
      w.cache.cropper = (b, s, dx, dy) async => fail('should not crop');
      expect(await w.cache.get(sat, t.z, t.x, t.y), jpeg);
      expect(w.srv.hits, isEmpty);
    });
  });

  group('offline and old saved areas', () {
    test('offline: a saved new photo, else the old tile', () async {
      final w = await world();
      await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y);
      w.cache.online = false;
      final before = w.srv.hits.length;
      expect(await w.cache.get(sat, pdx17.z, pdx17.x, pdx17.y), jpeg);
      // an old area saved by an earlier version
      final oldT = (z: 15, x: 5217, y: 11719);
      w.file('usgs_imagery', oldT)
        ..createSync(recursive: true)
        ..writeAsBytesSync(oldBytes);
      expect(await w.cache.get(sat, 15, 5217, 11719), oldBytes);
      expect(w.cache.photoSourceFor(16, 10435, 23439).id, 'osip_2024');
      final t16 = (z: 16, x: 10435, y: 23439);
      w.file('usgs_imagery', t16)
        ..createSync(recursive: true)
        ..writeAsBytesSync(oldBytes);
      expect(await w.cache.get(sat, t16.z, t16.x, t16.y), oldBytes);
      expect(await w.cache.get(sat, 16, 1, 1), isNull);
      expect(w.srv.hits.length, before, reason: 'no requests offline');
    });

    test(
      'online, a tile of an old area is upgraded to the new photo',
      () async {
        final w = await world();
        final t16 = (z: 16, x: 10435, y: 23439);
        w.file('usgs_imagery', t16)
          ..createSync(recursive: true)
          ..writeAsBytesSync(oldBytes);
        expect(await w.cache.get(sat, t16.z, t16.x, t16.y), jpeg);
      },
    );

    test('an old hybrid area still shows offline', () async {
      final w = await world();
      final t = (z: 14, x: 2609, y: 5859);
      w.file('usgs_hybrid', t)
        ..createSync(recursive: true)
        ..writeAsBytesSync(oldBytes);
      w.cache.online = false;
      expect(await w.cache.get(MapSource.usgsHybrid, t.z, t.x, t.y), oldBytes);
    });

    test('old regions keep covering their tiles, new photos too', () {
      final w = TileCache(Directory.systemTemp, userAgent: 't');
      w.regions.add(
        OfflineRegion(
          name: 'old',
          sourceId: 'usgs_imagery',
          bounds: const GeoBounds(45.5, -122.7, 45.6, -122.6),
          minZoom: 10,
          maxZoom: 16,
          tiles: 1,
          bytes: 1,
          at: DateTime(2026),
        ),
      );
      final x = tileX(-122.65, 14), y = tileY(45.55, 14);
      expect(w.inRegion('usgs_imagery', 14, x, y), isTrue);
      expect(w.inRegion('osip_2024', 14, x, y), isTrue);
      expect(w.inRegion('naip_live', 14, x, y), isTrue);
      expect(w.inRegion('topo', 14, x, y), isFalse);
      expect(w.inRegion('usgs_hybrid', 14, x, y), isFalse);
    });
  });

  group('downloads', () {
    GeoBounds box() => const GeoBounds(45.520, -122.680, 45.524, -122.675);

    test(
      'a download saves the newest photos under the Satellite area',
      () async {
        final w = await world();
        final r = await w.cache.download(
          sat,
          box(),
          15,
          16,
          name: 'pdx',
          pause: Duration.zero,
        );
        expect(r.sourceId, 'usgs_imagery');
        expect(r.tiles, greaterThan(0));
        expect(w.srv.count('/osip'), r.tiles);
        expect(w.srv.count('/naip'), 0);
        for (final t in tilesIn(box(), 15, 16)) {
          expect(w.file('osip_2024', t).existsSync(), isTrue);
          expect(w.cache.inRegion('osip_2024', t.z, t.x, t.y), isTrue);
        }
        // saved again: nothing is fetched twice
        await w.cache.download(
          sat,
          box(),
          15,
          16,
          name: 'pdx2',
          pause: Duration.zero,
        );
        expect(w.srv.count('/osip'), r.tiles);
      },
    );

    test('zoom 18 can be saved and is then used as it is', () async {
      final w = await world();
      final r = await w.cache.download(
        sat,
        box(),
        17,
        18,
        name: 'pdx',
        pause: Duration.zero,
      );
      expect(r.maxZoom, 18);
      final t18 = tilesIn(box(), 18, 18).first;
      expect(w.file('osip_2024', t18).existsSync(), isTrue);
      w.cache.online = false;
      w.cache.cropper = (b, s, dx, dy) async => fail('saved: no crop');
      expect(await w.cache.get(sat, t18.z, t18.x, t18.y), jpeg);
    });

    test('a place with no new photos keeps the old tiles', () async {
      final w = await world();
      w.srv.naip = blankPng;
      final b = const GeoBounds(47.600, -122.335, 47.604, -122.330);
      final r = await w.cache.download(
        sat,
        b,
        15,
        16,
        name: 'sea',
        pause: Duration.zero,
      );
      expect(r.tiles, greaterThan(0));
      for (final t in tilesIn(b, 15, 16)) {
        expect(w.file('usgs_imagery', t).existsSync(), isTrue);
      }
    });

    test('big photo areas are capped and sized', () async {
      final w = await world();
      expect(w.cache.limitFor(sat), 2000);
      expect(w.cache.limitFor(MapSource.topo), 3000);
      const big = GeoBounds(45.0, -123.5, 46.0, -122.0);
      expect(
        w.cache.estimate(sat, big, 14, 18).bytes,
        17000 * w.cache.estimate(sat, big, 14, 18).tiles,
      );
      expect(
        () => w.cache.download(sat, big, 14, 18, name: 'big'),
        throwsA(isA<StateError>()),
      );
    });

    test('downloads wait between requests (3 times the usual pause)', () async {
      final w = await world();
      final sw = Stopwatch()..start();
      final r = await w.cache.download(
        sat,
        const GeoBounds(45.520, -122.680, 45.5205, -122.6795),
        16,
        16,
        name: 'one',
        pause: const Duration(milliseconds: 40),
      );
      sw.stop();
      expect(r.tiles, 1);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(110));
    });

    test(
      'deleting an area removes its photos but not another area\'s',
      () async {
        final w = await world();
        final a = await w.cache.download(
          sat,
          box(),
          16,
          16,
          name: 'a',
          pause: Duration.zero,
        );
        final b = await w.cache.download(
          MapSource.usgsHybrid,
          box(),
          16,
          16,
          name: 'b',
          pause: Duration.zero,
        );
        final t = tilesIn(box(), 16, 16).first;
        await w.cache.deleteRegion(a);
        expect(
          w.file('osip_2024', t).existsSync(),
          isTrue,
          reason: 'hybrid still has it',
        );
        await w.cache.deleteRegion(b);
        expect(w.file('osip_2024', t).existsSync(), isFalse);
      },
    );

    test('trimming keeps the photos of saved areas', () async {
      final w = await world();
      await w.cache.download(
        sat,
        box(),
        16,
        16,
        name: 'a',
        pause: Duration.zero,
      );
      final other = (z: 16, x: 1, y: 1);
      w.file('naip_live', other)
        ..createSync(recursive: true)
        ..writeAsBytesSync(jpeg);
      w.cache.maxBytes = 1;
      await w.cache.trim();
      final t = tilesIn(box(), 16, 16).first;
      expect(w.file('osip_2024', t).existsSync(), isTrue);
      expect(w.file('naip_live', other).existsSync(), isFalse);
    });
  });

  group('hybrid', () {
    test('roads and names are a layer on top of the same photos', () {
      expect(MapSource.usgsHybrid.labels?.id, 'tnm_roads');
      expect(MapSource.usgsImagery.labels, isNull);
      expect(MapSource.usgsHybrid.photos, isTrue);
      final u = Uri.parse(MapSource.photoLabels.urlFor(17, 20870, 46879));
      expect(u.host, 'carto.nationalmap.gov');
      expect(u.queryParameters['transparent'], 'true');
      expect(u.queryParameters['layers'], startsWith('show:'));
    });

    test('saving a hybrid area also saves the roads and names', () {
      final o = AreaSaveOptions(
        bounds: const GeoBounds(45.5, -122.7, 45.6, -122.6),
        name: 'x',
        styles: const [MapSource.usgsHybrid],
        minZoom: 12,
        maxZoom: 18,
      );
      final jobs = areaTileJobs(o);
      expect(jobs.map((j) => j.src.id), contains('usgs_hybrid'));
      final l = jobs.firstWhere((j) => j.src.id == 'tnm_roads');
      expect((l.z0, l.z1), (12, 18));
      final plain = areaTileJobs(
        AreaSaveOptions(
          bounds: o.bounds,
          name: 'x',
          styles: const [MapSource.usgsImagery],
          minZoom: 12,
          maxZoom: 18,
        ),
      );
      expect(plain.map((j) => j.src.id), isNot(contains('tnm_roads')));
      expect(plain.first.z1, 18);
    });

    test('a route saved with the hybrid gets the roads layer too', () {
      final r = SavedRoute(
        name: 'n',
        destination: const GeoPoint(45.52, -122.68),
        baseId: 'usgs_hybrid',
      );
      final jobs = routeSaveJobs(r, MapSource.usgsHybrid);
      expect(jobs.tiles.map((j) => j.src.id), contains('tnm_roads'));
      final plain = routeSaveJobs(r, MapSource.usgsImagery);
      expect(plain.tiles.map((j) => j.src.id), isNot(contains('tnm_roads')));
    });

    test('the style picker has one Satellite and one hybrid', () {
      final names = MapSource.bases.map((s) => s.name).toList();
      expect(names.where((n) => n.contains('Satellite')).toList(), [
        'Satellite',
        'Satellite + roads and names',
      ]);
      expect(names, isNot(contains('USGS Satellite')));
      expect(MapSource.byId('osip_2024'), isNotNull);
      expect(MapSource.byId('tnm_roads')?.name, 'Roads and names');
    });
  });

  group('photo date', () {
    test('the line says where and when', () {
      expect(photoDateText(oregon: true), 'Photos: summer 2024 (Oregon)');
      expect(
        photoDateText(oregon: false, naipYear: 2021),
        'Photos: 2021 (NAIP)',
      );
      expect(photoDateText(oregon: false), 'Photos: about 2022 (NAIP)');
      expect(
        photoDateText(oregon: true, offline: true),
        'Photos: as saved on this phone',
      );
    });

    test('the NAIP year comes from the real photo of the pixel', () {
      const body =
          '{"catalogItems":{"features":['
          '{"attributes":{"Name":"m_4712230_nw_10_1_20170815","Category":1,"Year":2017}},'
          '{"attributes":{"Name":"Ov_i02_L01_R1.tif","Category":2,"Year":2025}}]}}';
      expect(NaipYears.parseYear(body), 2017);
      expect(
        NaipYears.parseYear(
          '{"catalogItems":{"features":[{"attributes":{"Name":"m_1_20220526","Category":1}}]}}',
        ),
        2022,
      );
      expect(NaipYears.parseYear('{"catalogItems":{"features":[]}}'), isNull);
      expect(NaipYears.parseYear('nope'), isNull);
    });

    test('one request per cell, none again; a failure is not kept', () async {
      var asked = 0;
      var ok = false;
      final n = NaipYears(
        get: (u) async {
          asked++;
          expect(u.queryParameters['returnCatalogItems'], 'true');
          return ok
              ? '{"catalogItems":{"features":[{"attributes":{"Name":"a_20190101","Category":1}}]}}'
              : null;
        },
      );
      expect(n.known(47.6, -122.3), isNull);
      expect(await n.year(47.6, -122.3), isNull);
      expect(asked, 1);
      ok = true;
      expect(await n.year(47.61, -122.31), 2019);
      expect(asked, 2);
      expect(await n.year(47.62, -122.32), 2019);
      expect(n.known(47.7, -122.4), 2019, reason: 'same half degree');
      expect(asked, 2);
      expect(await n.year(35.0, -106.6), 2019);
      expect(asked, 3);
    });
  });

  group('enlarging a tile', () {
    testWidgets('the right quarter, scaled to 256', (t) async {
      final im = img.Image(width: 256, height: 256);
      img.fill(im, color: img.ColorRgb8(255, 0, 0));
      img.fillRect(
        im,
        x1: 128,
        y1: 0,
        x2: 255,
        y2: 127,
        color: img.ColorRgb8(0, 255, 0),
      );
      img.fillRect(
        im,
        x1: 0,
        y1: 128,
        x2: 127,
        y2: 255,
        color: img.ColorRgb8(0, 0, 255),
      );
      final png = Uint8List.fromList(img.encodePng(im));
      final out = await t.runAsync(() async {
        final a = await cropTileUp(png, 1, 1, 0);
        final b = await cropTileUp(png, 1, 0, 1);
        final c = await cropTileUp(png, 2, 3, 3);
        return [a, b, c].map((x) => img.decodePng(x)!).toList();
      });
      for (final o in out!) {
        expect((o.width, o.height), (256, 256));
      }
      final g = out[0].getPixel(128, 128);
      expect((g.r.toInt(), g.g.toInt(), g.b.toInt()), (0, 255, 0));
      final b = out[1].getPixel(128, 128);
      expect((b.r.toInt(), b.g.toInt(), b.b.toInt()), (0, 0, 255));
      final r = out[2].getPixel(128, 128);
      expect((r.r.toInt(), r.g.toInt(), r.b.toInt()), (255, 0, 0));
    });
  });

  group('the map', () {
    Future<TripController> trip(WidgetTester t, String style) async {
      final tmp = Directory.systemTemp.createTempSync('v255');
      final c = TripController(
        host: FakeHost(1),
        settings: TripSettings(mapSource: style),
        dir: tmp,
        userAgent: 'test',
      );
      c.tiles.online = false;
      addTearDown(() {
        c.dispose();
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      return c;
    }

    Widget host(TripController c, LatLng at, double zoom) => MaterialApp(
      home: FlutterMap(
        options: MapOptions(initialCenter: at, initialZoom: zoom),
        children: [PhotoDateLine(trip: c)],
      ),
    );

    testWidgets('Oregon says summer 2024', (t) async {
      final c = await trip(t, 'usgs_imagery');
      c.tiles.online = true;
      c.tiles.net = true;
      await t.pumpWidget(host(c, const LatLng(45.52, -122.68), 15));
      expect(find.text('Photos: summer 2024 (Oregon)'), findsOneWidget);
    });

    testWidgets('elsewhere: about 2022 until the year is known', (t) async {
      final c = await trip(t, 'usgs_hybrid');
      c.tiles.online = true;
      c.tiles.net = true;
      await t.pumpWidget(host(c, const LatLng(35.08, -106.65), 15));
      expect(find.text('Photos: about 2022 (NAIP)'), findsOneWidget);
      await t.pumpWidget(const SizedBox()); // gone before the year is asked
    });

    testWidgets('elsewhere: the year of the real photo, asked once', (t) async {
      final c = await trip(t, 'usgs_imagery');
      c.tiles.online = true;
      c.tiles.net = true;
      var asked = 0;
      c.photoYears = NaipYears(
        get: (u) async {
          asked++;
          return '{"catalogItems":{"features":[{"attributes":'
              '{"Category":1,"Year":2021}}]}}';
        },
      );
      await t.pumpWidget(host(c, const LatLng(35.08, -106.65), 15));
      await t.pump(const Duration(seconds: 2));
      await t.pump();
      expect(find.text('Photos: 2021 (NAIP)'), findsOneWidget);
      expect(asked, 1);
    });

    testWidgets('offline says so, zoomed out says to zoom in', (t) async {
      final c = await trip(t, 'usgs_imagery');
      await t.pumpWidget(host(c, const LatLng(45.52, -122.68), 15));
      expect(find.text('Photos: as saved on this phone'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(host(c, const LatLng(45.52, -122.68), 9));
      expect(find.text('Zoom in for the newest photos'), findsOneWidget);
    });

    testWidgets('no line on other maps', (t) async {
      final c = await trip(t, 'topo');
      await t.pumpWidget(host(c, const LatLng(45.52, -122.68), 15));
      expect(find.byKey(const Key('photoDate')), findsNothing);
    });
  });
}
