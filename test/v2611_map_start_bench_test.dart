// v2.6.11: what makes the Trip map slow to open, measured. Run with
//   flutter test test/v2611_map_start_bench_test.dart
// It prints one line per measurement ("bench: ...") and checks the
// v2.6.11 targets. The same file ran on v2.6.10 (915941d) for the
// "before" numbers in the README.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_layer_widgets.dart';

import 'trip_integration_test.dart' show FakeHost;

/// A tiny PNG (the bytes do not matter to the cache).
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  ...List.filled(1200, 7),
]);

void _say(String s) => debugPrint('bench: $s');

/// A slow tile server (a phone on a weak cell signal): every answer takes
/// [delay]; a tile asked with its ETag answers 304.
class SlowServer {
  late HttpServer _s;
  int hits = 0;
  Duration delay = const Duration(milliseconds: 250);
  Future<void> start() async {
    _s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _s.listen((r) async {
      hits++;
      await Future<void>.delayed(delay);
      if (r.headers.value(HttpHeaders.ifNoneMatchHeader) == '"t"') {
        r.response.statusCode = 304;
      } else {
        r.response.headers.set(HttpHeaders.etagHeader, '"t"');
        r.response.add(_png);
      }
      await r.response.close();
    });
  }

  String get url => 'http://127.0.0.1:${_s.port}/{z}/{x}/{y}.png';
  Future<void> close() => _s.close(force: true);
}

/// One phone screen of tiles (4 x 6) at zoom 15.
List<(int, int, int)> screen() => [
  for (var x = 0; x < 4; x++)
    for (var y = 0; y < 6; y++) (15, 5240 + x, 11720 + y),
];

Future<void> seed(
  Directory dir,
  String src,
  List<(int, int, int)> tiles, {
  Duration age = Duration.zero,
}) async {
  final t = DateTime.now().subtract(age);
  for (final (z, x, y) in tiles) {
    final f = File('${dir.path}/$src/$z/$x/$y.png');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(_png);
    await File('${dir.path}/$src/$z/$x/$y.meta')
        .writeAsString(jsonEncode({'etag': '"t"'}));
    if (age > Duration.zero) await f.setLastModified(t);
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('b2611'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('a screen of tiles saved more than 7 days ago', () async {
    final srv = SlowServer();
    await srv.start();
    final src = MapSource.custom(srv.url);
    final cache = TileCache(Directory('${tmp.path}/tiles'), userAgent: 't');
    await seed(cache.dir, src.id, screen(), age: const Duration(days: 8));
    final sw = Stopwatch()..start();
    final got = await Future.wait([
      for (final (z, x, y) in screen()) cache.get(src, z, x, y),
    ]);
    final ms = sw.elapsedMilliseconds;
    _say(
      'stale screen (24 tiles, 250 ms signal): $ms ms, '
      '${srv.hits} requests before the map could draw',
    );
    expect(got.every((b) => b != null), isTrue);
    // Let any refresh behind the scenes finish before closing.
    await Future<void>.delayed(const Duration(seconds: 4));
    _say('stale screen: ${srv.hits} requests in total (refreshes)');
    cache.close();
    await srv.close();
    // v2.6.11: drawn from the phone at once, refreshed behind it.
    expect(ms, lessThan(1000));
  });

  test('a screen of fresh tiles (the fast case, unchanged)', () async {
    final srv = SlowServer();
    await srv.start();
    final src = MapSource.custom(srv.url);
    final cache = TileCache(Directory('${tmp.path}/tiles'), userAgent: 't');
    await seed(cache.dir, src.id, screen());
    final sw = Stopwatch()..start();
    await Future.wait([
      for (final (z, x, y) in screen()) cache.get(src, z, x, y),
    ]);
    _say('fresh screen: ${sw.elapsedMilliseconds} ms, ${srv.hits} requests');
    expect(srv.hits, 0);
    cache.close();
    await srv.close();
  });

  test('opening the Trip map with 8000 viewed tiles on the phone', () async {
    final dir = Directory('${tmp.path}/trip');
    final many = [
      for (var x = 0; x < 80; x++)
        for (var y = 0; y < 100; y++) (14, 2600 + x, 5800 + y),
    ];
    await seed(Directory('${dir.path}/tiles'), 'topo', many);
    final t = TripController(
      host: FakeHost(0x1234),
      settings: TripSettings(),
      dir: dir,
      userAgent: 't',
    );
    t.tiles.online = false;
    final sw = Stopwatch()..start();
    await t.start();
    final startMs = sw.elapsedMilliseconds;
    // The first screen right after start (the cache trim may be walking
    // the folder at the same time).
    sw.reset();
    await Future.wait([
      for (final (z, x, y) in many.take(24))
        t.tiles.get(MapSource.topo, z, x, y),
    ]);
    final firstMs = sw.elapsedMilliseconds;
    sw.reset();
    await t.tiles.trim();
    final trimMs = sw.elapsedMilliseconds;
    _say(
      'trip start: $startMs ms; first screen right after: $firstMs ms; '
      'cache trim walk (8000 tiles): $trimMs ms',
    );
    t.dispose();
  });

  test('imported trails: building the map layer (50 000 points)', () async {
    final dir = Directory('${tmp.path}/trip');
    final t = TripController(
      host: FakeHost(0x1234),
      settings: TripSettings(),
      dir: dir,
      userAgent: 't',
    );
    t.tiles.online = false;
    await t.start();
    final b = StringBuffer(
      '<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>',
    );
    for (var i = 0; i < 50000; i++) {
      // A wiggly track (a straight one is thinned to two points).
      final w = (i % 7) * 3e-4 * (i.isEven ? 1 : -1);
      b.write('<trkpt lat="${45 + i * 2e-5}" lon="${-122 + w}"/>');
    }
    b.write('</trkseg></trk></gpx>');
    await t.layers.importTrail('big.gpx', utf8.encode(b.toString()));
    // Warm up, then time ten rebuilds (the map rebuilds every 2 s while
    // friends are on it, and on every change).
    final pts = t.layers.trails.first.data!.lines.fold<int>(
      0,
      (n, l) => n + l.points.length,
    );
    importedLayers(t);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      importedLayers(t);
    }
    final per = sw.elapsedMicroseconds / 10 / 1000;
    _say(
      'imported trail layer ($pts points kept) per map rebuild: '
      '${per.toStringAsFixed(2)} ms',
    );
    t.dispose();
  });
}
