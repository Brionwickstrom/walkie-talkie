// v2.6.11: faster map start, the tile cache. Stale tiles are drawn from
// the phone at once and refreshed behind the map (once, two at a time);
// the cache drops the least recently used tiles first, off the main
// thread, and never the saved offline areas; Clear map cache keeps them.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';

import 'trip_integration_test.dart' show FakeHost;

final _png = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  ...List.filled(500, 1),
]);
final _newPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  ...List.filled(600, 2),
]);

/// A tile server: [delay] per answer, 304 for a known ETag unless
/// [changed], counts requests.
class Server {
  late HttpServer _s;
  int hits = 0;
  int conditional = 0;
  bool changed = false;
  Duration delay = const Duration(milliseconds: 150);
  int open = 0, maxOpen = 0;
  Future<void> start() async {
    _s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _s.listen((r) async {
      hits++;
      open++;
      if (open > maxOpen) maxOpen = open;
      await Future<void>.delayed(delay);
      final etag = r.headers.value(HttpHeaders.ifNoneMatchHeader);
      if (etag != null) conditional++;
      if (etag == '"a"' && !changed) {
        r.response.statusCode = 304;
      } else {
        r.response.headers.set(HttpHeaders.etagHeader, '"b"');
        r.response.add(changed ? _newPng : _png);
      }
      open--;
      await r.response.close();
    });
  }

  String get url => 'http://127.0.0.1:${_s.port}/{z}/{x}/{y}.png';
  Future<void> close() => _s.close(force: true);
}

Future<File> put(
  Directory dir,
  String src,
  int z,
  int x,
  int y, {
  Duration age = Duration.zero,
  Uint8List? bytes,
}) async {
  final f = File('${dir.path}/$src/$z/$x/$y.png');
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes ?? _png);
  await File('${dir.path}/$src/$z/$x/$y.meta')
      .writeAsString(jsonEncode({'etag': '"a"'}));
  if (age > Duration.zero) {
    await f.setLastModified(DateTime.now().subtract(age));
  }
  return f;
}

void main() {
  late Directory tmp;
  late TileCache cache;
  late Server srv;
  late MapSource src;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('v2611c');
    srv = Server();
    await srv.start();
    src = MapSource.custom(srv.url);
    cache = TileCache(Directory('${tmp.path}/tiles'), userAgent: 't');
  });
  tearDown(() async {
    cache.close();
    await srv.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('stale tiles: drawn at once, refreshed behind the map', () {
    test('a stale tile comes from the phone without waiting', () async {
      await put(cache.dir, src.id, 15, 1, 2, age: const Duration(days: 9));
      final sw = Stopwatch()..start();
      final b = await cache.get(src, 15, 1, 2);
      expect(sw.elapsedMilliseconds, lessThan(srv.delay.inMilliseconds));
      expect(b, _png);
      await cache.refreshesDone();
      expect(srv.hits, 1);
      expect(srv.conditional, 1, reason: 'asked with its ETag (304 = keep)');
    });

    test('304: marked fresh, so the next start asks nothing', () async {
      final f = await put(
        cache.dir,
        src.id,
        15,
        1,
        2,
        age: const Duration(days: 9),
      );
      await cache.get(src, 15, 1, 2);
      await cache.refreshesDone();
      expect(
        DateTime.now().difference(await f.lastModified()).inMinutes,
        lessThan(1),
      );
      final again = TileCache(cache.dir, userAgent: 't');
      await again.get(src, 15, 1, 2);
      await again.refreshesDone();
      expect(srv.hits, 1);
      again.close();
    });

    test('a changed tile is saved for next time', () async {
      srv.changed = true;
      await put(cache.dir, src.id, 15, 1, 2, age: const Duration(days: 9));
      expect(await cache.get(src, 15, 1, 2), _png);
      await cache.refreshesDone();
      expect(
        await File('${cache.dir.path}/${src.id}/15/1/2.png').readAsBytes(),
        _newPng,
      );
    });

    test('each tile is refreshed once a run; two at a time at most', () async {
      for (var y = 0; y < 8; y++) {
        await put(cache.dir, src.id, 15, 1, y, age: const Duration(days: 9));
      }
      await Future.wait([
        for (var i = 0; i < 3; i++)
          for (var y = 0; y < 8; y++) cache.get(src, 15, 1, y),
      ]);
      await cache.refreshesDone();
      expect(srv.hits, 8);
      expect(srv.maxOpen, lessThanOrEqualTo(TileCache.maxBackgroundRefreshes));
    });

    test('offline: no refresh at all (no battery, no data)', () async {
      cache.net = false;
      await put(cache.dir, src.id, 15, 1, 2, age: const Duration(days: 9));
      expect(await cache.get(src, 15, 1, 2), isNotNull);
      await cache.refreshesDone();
      expect(srv.hits, 0);
    });

    test('fresh tiles: nothing asked, as before', () async {
      await put(cache.dir, src.id, 15, 1, 2);
      await cache.get(src, 15, 1, 2);
      await cache.refreshesDone();
      expect(srv.hits, 0);
    });

    test(
      'a tile not on the phone is still downloaded and waited for',
      () async {
        final b = await cache.get(src, 15, 3, 3);
        expect(b, _png);
        expect(srv.hits, 1);
        expect(await cache.has(src, 15, 3, 3), isTrue);
      },
    );

    test('switch off: the old wait-for-the-server behaviour', () async {
      cache.staleWhileRevalidate = false;
      await put(cache.dir, src.id, 15, 1, 2, age: const Duration(days: 9));
      final sw = Stopwatch()..start();
      await cache.get(src, 15, 1, 2);
      expect(
        sw.elapsedMilliseconds,
        greaterThanOrEqualTo(srv.delay.inMilliseconds - 20),
      );
    });

    test(
      'satellite: stale old USGS photos (wide views) come at once',
      () async {
        cache.oldPhotos = MapSource(
          id: 'usgs_imagery',
          name: 'old',
          urlTemplate: srv.url,
          attribution: '',
        );
        await put(
          cache.dir,
          'usgs_imagery',
          10,
          1,
          2,
          age: const Duration(days: 9),
        );
        final sw = Stopwatch()..start();
        final b = await cache.get(MapSource.usgsImagery, 10, 1, 2);
        expect(sw.elapsedMilliseconds, lessThan(srv.delay.inMilliseconds));
        expect(b, _png);
        await cache.refreshesDone();
        expect(srv.conditional, 1);
      },
    );
  });

  group('size cap, least recently used first', () {
    test(
      'a tile looked at recently outlives a newer one never looked at',
      () async {
        final old = await put(
          cache.dir,
          src.id,
          15,
          1,
          1,
          age: const Duration(days: 3),
        );
        final newer = await put(
          cache.dir,
          src.id,
          15,
          1,
          2,
          age: const Duration(days: 1),
        );
        cache.online = false;
        await cache.get(src, 15, 1, 1); // looked at now
        cache.maxBytes = 600; // room for one
        await cache.trim();
        expect(await old.exists(), isTrue);
        expect(await newer.exists(), isFalse);
        expect(
          await File('${cache.dir.path}/${src.id}/15/1/2.meta').exists(),
          isFalse,
          reason: 'its ETag goes with it',
        );
      },
    );

    test('the use times survive a restart', () async {
      await put(cache.dir, src.id, 15, 1, 1, age: const Duration(days: 3));
      await put(cache.dir, src.id, 15, 1, 2, age: const Duration(days: 1));
      cache.online = false;
      await cache.get(src, 15, 1, 1);
      await cache.trim(); // under the cap: saves the use times
      final again = TileCache(cache.dir, userAgent: 't')..maxBytes = 600;
      await again.trim();
      expect(
        await File('${cache.dir.path}/${src.id}/15/1/1.png').exists(),
        isTrue,
      );
      expect(
        await File('${cache.dir.path}/${src.id}/15/1/2.png').exists(),
        isFalse,
      );
      again.close();
    });

    test('saved offline areas are never trimmed', () async {
      final kept = await put(
        cache.dir,
        'topo',
        12,
        654,
        1468,
        age: const Duration(days: 30),
      );
      cache.regions.add(
        OfflineRegion(
          name: 'Home',
          sourceId: 'topo',
          bounds: const GeoBounds(45.0, -122.9, 45.6, -122.0),
          minZoom: 12,
          maxZoom: 12,
          tiles: 1,
          bytes: 504,
          at: DateTime.now(),
        ),
      );
      expect(cache.inRegion('topo', 12, 654, 1468), isTrue);
      cache.maxBytes = 0;
      await cache.trim();
      expect(await kept.exists(), isTrue);
    });

    test('the limit follows Settings (MB)', () async {
      final dir = Directory('${tmp.path}/trip');
      final t = TripController(
        host: FakeHost(1),
        settings: TripSettings(mapCacheMb: 250),
        dir: dir,
        userAgent: 't',
      );
      expect(t.tiles.maxBytes, 250 * 1024 * 1024);
      await t.update((s) => s.mapCacheMb = 1000);
      expect(t.tiles.maxBytes, 1000 * 1024 * 1024);
      t.dispose();
    });

    test('trim waits until after the map has opened', () async {
      final dir = Directory('${tmp.path}/trip');
      await put(Directory('${dir.path}/tiles'), 'topo', 15, 1, 1);
      final t = TripController(
        host: FakeHost(1),
        settings: TripSettings(),
        dir: dir,
        userAgent: 't',
      )..trimDelay = const Duration(milliseconds: 200);
      t.tiles.online = false;
      t.tiles.maxBytes = 0;
      await t.start();
      final f = File('${dir.path}/tiles/topo/15/1/1.png');
      expect(await f.exists(), isTrue, reason: 'not at start');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(await f.exists(), isFalse, reason: 'a moment later');
      t.dispose();
    });
  });

  group('size and Clear map cache', () {
    Future<void> seedBoth() async {
      await put(cache.dir, 'topo', 12, 654, 1468); // saved area
      await put(cache.dir, 'topo', 15, 1, 1); // viewed
      await put(cache.dir, 'osm', 15, 1, 2); // viewed
      cache.regions.add(
        OfflineRegion(
          name: 'Home',
          sourceId: 'topo',
          bounds: const GeoBounds(45.0, -122.9, 45.6, -122.0),
          minZoom: 12,
          maxZoom: 12,
          tiles: 1,
          bytes: 504,
          at: DateTime.now(),
        ),
      );
    }

    test('the size: viewed and saved counted apart', () async {
      await seedBoth();
      final s = await cache.stats();
      expect(s.viewedTiles, 2);
      expect(s.viewedBytes, 2 * _png.length);
      expect(s.savedTiles, 1);
      expect(s.totalBytes, 3 * _png.length);
    });

    test('Clear map cache deletes viewed tiles, keeps saved areas', () async {
      await seedBoth();
      final freed = await cache.clearViewed();
      expect(freed, 2 * _png.length);
      final s = await cache.stats();
      expect(s.viewedTiles, 0);
      expect(s.savedTiles, 1);
      expect(cache.regions, hasLength(1));
      expect(await File('${cache.dir.path}/osm/15/1/2.meta').exists(), isFalse);
    });

    test('an empty cache counts as nothing (no folder yet)', () async {
      final s = await cache.stats();
      expect(s.totalBytes, 0);
      expect(await cache.clearViewed(), 0);
    });
  });

  group('settings', () {
    test('limit and home warm-up saved; defaults stay out of the file', () {
      final d = TripSettings();
      expect(d.mapCacheMb, 500);
      expect(d.warmHome, isTrue);
      expect(d.encode(), isNot(contains('"mc"')));
      expect(d.encode(), isNot(contains('"wh"')));
      final s = TripSettings(mapCacheMb: 2000, warmHome: false);
      final back = TripSettings.decode(s.encode());
      expect(back.mapCacheMb, 2000);
      expect(back.warmHome, isFalse);
      expect(TripSettings.decode('{"mc":123}').mapCacheMb, 500);
    });
  });
}
