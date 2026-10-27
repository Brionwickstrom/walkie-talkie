import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import '../search/fetch.dart';
import '../search/overpass.dart' show OverpassClient, boundsSizeKm;
import '../search/rate_limiter.dart';
import '../tile_cache.dart' show GeoBounds;
import 'road_data.dart';

/// Biggest area saved in one go (square degrees, about 110 x 80 km at
/// 45 N); bigger regions: save a few areas, they join up for routing.
const double maxRoadAreaSqDeg = 1.0;

/// Bytes on the phone per road way (from the Portland - Gifford Pinchot
/// build: 7.9 MB for 223k ways), with some headroom.
const int roadBytesPerWay = 42;

/// Overpass answer bytes per way (to say how much will download).
const int roadDownloadBytesPerWay = 1100;

/// Size of an area's roads before saving them.
class RoadEstimate {
  const RoadEstimate(this.ways);
  final int ways;
  int get bytes => max(20 * 1024, ways * roadBytesPerWay);
  int get downloadBytes => ways * roadDownloadBytesPerWay;
}

/// Progress of a roads download.
class RoadProgress {
  const RoadProgress(this.done, this.total, this.ways);
  final int done, total, ways;
  double get fraction => total == 0 ? 0 : done / total;
}

class RoadDownloadException implements Exception {
  RoadDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parse an Overpass JSON answer (ways with their nodes) into road data.
RoadData roadsFromOverpass(String json, GeoBounds bounds, DateTime at) {
  final j = jsonDecode(json) as Map<String, Object?>;
  final coords = <int, (double, double)>{};
  final nodeTags = <int, Map<String, String>>{};
  final ways = <OsmWay>[];
  for (final e in (j['elements'] as List? ?? const [])) {
    if (e is! Map) continue;
    final id = (e['id'] as num?)?.toInt();
    if (id == null) continue;
    final tags = e['tags'] is Map
        ? (e['tags'] as Map).map((k, v) => MapEntry('$k', '$v'))
        : const <String, String>{};
    if (e['type'] == 'node') {
      final lat = (e['lat'] as num?)?.toDouble();
      final lon = (e['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      coords[id] = (lat, lon);
      if (tags.isNotEmpty) nodeTags[id] = tags;
    } else if (e['type'] == 'way') {
      final ns = e['nodes'];
      if (ns is! List) continue;
      ways.add(OsmWay(id, [for (final n in ns) (n as num).toInt()], tags));
    }
  }
  return RoadData.build(
    ways,
    coords,
    nodeTags: nodeTags,
    bounds: bounds,
    builtAt: at,
  );
}

/// Saves the drivable roads of an area from OpenStreetMap (Overpass), in
/// pieces small enough for the server; the pieces are joined into one
/// network.
class RoadDownloader {
  RoadDownloader({
    required this.fetch,
    RateLimiter? limiter,
    this.endpoints = defaultEndpoints,
    DateTime Function()? clock,
  }) : limiter = limiter ?? OverpassClient.shared,
       _clock = clock ?? DateTime.now;

  final Fetch fetch;
  final RateLimiter limiter;

  /// Overpass servers, tried in turn when one is busy or unreachable.
  final List<String> endpoints;
  static const defaultEndpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];
  int _server = 0;
  final DateTime Function() _clock;

  /// Piece size (degrees); a piece the server finds too big is split.
  static const double piece = 0.25;
  static const int maxPieceBytes = 48 * 1024 * 1024;

  static String _bbox(GeoBounds b) =>
      '${b.south.toStringAsFixed(5)},${b.west.toStringAsFixed(5)},'
      '${b.north.toStringAsFixed(5)},${b.east.toStringAsFixed(5)}';

  static String countQuery(GeoBounds b) =>
      '[out:json][timeout:60];'
      'way["highway"~"${RoadRules.overpassHighways}"](${_bbox(b)});out count;';

  static String roadsQuery(GeoBounds b) =>
      '[out:json][timeout:180];'
      'way["highway"~"${RoadRules.overpassHighways}"](${_bbox(b)})->.w;'
      '(.w;.w>;);out body qt;';

  Future<String> _post(String q, {int maxBytes = 2 * 1024 * 1024}) async {
    Future<String> send(String url) => limiter.run(
      () => fetch(
        FetchRequest(
          Uri.parse(url),
          method: 'POST',
          headers: const {
            'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
            'Accept': 'application/json',
          },
          body: 'data=${Uri.encodeQueryComponent(q)}',
          timeout: const Duration(seconds: 200),
          maxBytes: maxBytes,
        ),
      ),
    );
    Object? last;
    for (var k = 0; k < endpoints.length; k++) {
      final url = endpoints[(_server + k) % endpoints.length];
      try {
        final r = await send(url);
        _server = (_server + k) % endpoints.length; // keep the one that works
        return r;
      } on FetchException catch (e) {
        if (e.message.startsWith('Too much map data')) rethrow;
        if (e.status != null &&
            !const {429, 502, 503, 504}.contains(e.status)) {
          rethrow;
        }
        last = e;
      } on NoSignalException catch (e) {
        last = e;
      }
    }
    // All busy: the area may be too much for them (split), or no signal.
    if (last is NoSignalException) throw last;
    throw last is FetchException
        ? last
        : FetchException('The road servers are busy. Try again later.');
  }

  /// Area check: null = fine, else why not.
  static String? checkArea(GeoBounds b) {
    final sq = (b.north - b.south) * (b.east - b.west);
    if (sq <= 0) return 'Pick an area first.';
    if (sq > maxRoadAreaSqDeg) {
      final km = boundsSizeKm(b);
      return 'That area is too big to save at once '
          '(${km.w.round()} x ${km.h.round()} km). Save it as a few smaller '
          'areas: routes cross from one saved area to the next.';
    }
    return null;
  }

  /// How many roads (and so how many MB) the area has.
  Future<RoadEstimate> estimate(GeoBounds b) async {
    final s = await _post(countQuery(b));
    try {
      final j = jsonDecode(s) as Map;
      final c = (j['elements'] as List).first as Map;
      final tags = c['tags'] as Map;
      return RoadEstimate(int.parse('${tags['ways'] ?? tags['total']}'));
    } catch (_) {
      throw RoadDownloadException('Could not read the road count.');
    }
  }

  /// The pieces [b] is fetched in.
  static List<GeoBounds> pieces(GeoBounds b, {double size = piece}) {
    final out = <GeoBounds>[];
    final ny = max(1, ((b.north - b.south) / size).ceil());
    final nx = max(1, ((b.east - b.west) / size).ceil());
    final dy = (b.north - b.south) / ny, dx = (b.east - b.west) / nx;
    for (var y = 0; y < ny; y++) {
      for (var x = 0; x < nx; x++) {
        out.add(
          GeoBounds(
            b.south + y * dy,
            b.west + x * dx,
            b.south + (y + 1) * dy,
            b.west + (x + 1) * dx,
          ),
        );
      }
    }
    return out;
  }

  /// Download and build. [onProgress] after each piece.
  Future<RoadData> download(
    GeoBounds b, {
    void Function(RoadProgress p)? onProgress,
    bool Function()? cancelled,
  }) async {
    final why = checkArea(b);
    if (why != null) throw RoadDownloadException(why);
    final todo = pieces(b);
    final parts = <RoadData>[];
    final at = _clock();
    var done = 0, ways = 0;
    var total = todo.length;
    while (todo.isNotEmpty) {
      if (cancelled?.call() ?? false) {
        throw RoadDownloadException('Cancelled');
      }
      final p = todo.removeAt(0);
      String body;
      try {
        body = await _post(roadsQuery(p), maxBytes: maxPieceBytes);
      } on FetchException catch (e) {
        final tooBig =
            e.status == 504 || e.message.startsWith('Too much map data');
        if (tooBig && (p.north - p.south) > 0.03) {
          final four = pieces(
            p,
            size: max(p.north - p.south, p.east - p.west) / 2,
          );
          todo.insertAll(0, four);
          total += four.length - 1;
          continue;
        }
        rethrow;
      }
      final d = body.length > 2 * 1024 * 1024
          ? await Isolate.run(() => roadsFromOverpass(body, p, at))
          : roadsFromOverpass(body, p, at);
      parts.add(d);
      ways += d.edgeCount;
      done++;
      onProgress?.call(RoadProgress(done, total, ways));
    }
    final all = parts.length == 1
        ? parts.first
        : await Isolate.run(() => RoadData.merge(parts));
    return all.withBounds(b);
  }
}
