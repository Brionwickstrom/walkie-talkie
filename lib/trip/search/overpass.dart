import 'dart:convert';
import 'dart:math' as math;

import '../geo.dart';
import '../imports/geo_import.dart';
import '../tile_cache.dart';
import 'fetch.dart';
import 'rate_limiter.dart';

/// OpenStreetMap data licence line shown on layers made from Overpass.
const String osmAttribution = '© OpenStreetMap contributors, ODbL';

/// Biggest area "Get trails" asks for (side in km); bigger areas are
/// trimmed around their middle.
const double maxTrailAreaKm = 40;

/// Smallest area (side in km), so a peak or trailhead still gets the
/// trails around it.
const double minTrailAreaKm = 4;

const double _kmPerDegLat = 111.32;

double _kmPerDegLng(double lat) =>
    math.max(0.01, _kmPerDegLat * math.cos(lat * math.pi / 180));

/// Width and height of [b] in km.
({double w, double h}) boundsSizeKm(GeoBounds b) {
  final mid = (b.south + b.north) / 2;
  return (
    w: (b.east - b.west) * _kmPerDegLng(mid),
    h: (b.north - b.south) * _kmPerDegLat,
  );
}

/// [b] clipped to at most [maxKm] a side around [center] (default its
/// middle) and grown to at least [minKm]. `trimmed` says if it was cut.
({GeoBounds bounds, bool trimmed}) capBounds(
  GeoBounds b, {
  GeoPoint? center,
  double maxKm = maxTrailAreaKm,
  double minKm = minTrailAreaKm,
}) {
  final c = center ?? b.center;
  final kx = _kmPerDegLng(c.lat);
  var s = b.south, n = b.north, w = b.west, e = b.east;
  var trimmed = false;
  final maxLat = maxKm / _kmPerDegLat / 2, maxLng = maxKm / kx / 2;
  if (n - s > maxLat * 2) {
    final mid = c.lat.clamp(s + maxLat, n - maxLat);
    s = mid - maxLat;
    n = mid + maxLat;
    trimmed = true;
  }
  if (e - w > maxLng * 2) {
    final mid = c.lng.clamp(w + maxLng, e - maxLng);
    w = mid - maxLng;
    e = mid + maxLng;
    trimmed = true;
  }
  final minLat = minKm / _kmPerDegLat / 2, minLng = minKm / kx / 2;
  if (n - s < minLat * 2) {
    final m = (s + n) / 2;
    s = m - minLat;
    n = m + minLat;
  }
  if (e - w < minLng * 2) {
    final m = (w + e) / 2;
    w = m - minLng;
    e = m + minLng;
  }
  return (
    bounds: GeoBounds(
      s.clamp(-85.0, 85.0),
      w.clamp(-180.0, 180.0),
      n.clamp(-85.0, 85.0),
      e.clamp(-180.0, 180.0),
    ),
    trimmed: trimmed,
  );
}

String _f(double v) => v.toStringAsFixed(5);

/// Overpass QL for hiking data in [b] (and inside the outline [areaId] when
/// given): named paths / footways / tracks / bridleways and hiking route
/// relations with their geometry, then trailheads, peaks, lakes, springs,
/// drinking water, campsites and shelters as points.
String buildTrailQuery(
  GeoBounds b, {
  int? areaId,
  int timeoutS = 30,
  int maxSizeBytes = 64 * 1024 * 1024,
}) {
  final bbox = '${_f(b.south)},${_f(b.west)},${_f(b.north)},${_f(b.east)}';
  final f = areaId != null ? '(area.a)($bbox)' : '($bbox)';
  return [
    '[out:json][timeout:$timeoutS][maxsize:$maxSizeBytes];',
    if (areaId != null) 'area($areaId)->.a;',
    '(',
    '  way["highway"~"^(path|footway|track|bridleway)\$"]["name"]$f;',
    '  relation["route"="hiking"]$f;',
    ')->.t;',
    '.t out geom qt;',
    '(',
    '  node["highway"="trailhead"]$f;',
    '  node["natural"~"^(peak|volcano|spring)\$"]$f;',
    '  node["amenity"~"^(drinking_water|water_point|shelter)\$"]$f;',
    '  way["amenity"="shelter"]$f;',
    '  nwr["tourism"~"^(camp_site|wilderness_hut|alpine_hut)\$"]$f;',
    '  nwr["natural"="water"]["name"]$f;',
    ')->.p;',
    '.p out center qt;',
  ].join('\n');
}

/// What one "Get trails" produced.
class OverpassResult {
  OverpassResult(this.data, {this.partial = false, this.remark = ''});
  final ImportedData data;

  /// The server stopped early (time or memory): some data may be missing.
  final bool partial;
  final String remark;
  int get trails => data.lines.map((l) => l.name).toSet().length;
  int get places => data.waypoints.length;
}

/// Kind of a point from its OSM tags: (kind, label) or null.
({String kind, String label})? osmPlaceKind(Map tags) {
  final hw = tags['highway'], nat = tags['natural'];
  final am = tags['amenity'], tour = tags['tourism'];
  if (hw == 'trailhead') return (kind: 'trailhead', label: 'Trailhead');
  if (nat == 'peak' || nat == 'volcano') return (kind: 'peak', label: 'Peak');
  if (nat == 'spring') return (kind: 'spring', label: 'Spring');
  if (am == 'drinking_water' || am == 'water_point') {
    return (kind: 'water', label: 'Drinking water');
  }
  if (tour == 'camp_site') return (kind: 'campsite', label: 'Campsite');
  if (tour == 'wilderness_hut' || tour == 'alpine_hut') {
    return (kind: 'shelter', label: 'Hut');
  }
  if (am == 'shelter') return (kind: 'shelter', label: 'Shelter');
  if (nat == 'water') {
    final w = tags['water'];
    if (w == 'river' || w == 'stream' || w == 'canal') {
      return (kind: 'water', label: 'River');
    }
    return (kind: 'lake', label: w == 'pond' ? 'Pond' : 'Lake');
  }
  return null;
}

bool _near(GeoPoint a, GeoPoint b) =>
    (a.lat - b.lat).abs() < 2e-6 && (a.lng - b.lng).abs() < 2e-6;

/// Join pieces that touch end to end (OSM splits a trail into many ways),
/// flipping pieces as needed. Pieces that do not touch stay separate.
List<List<GeoPoint>> chainSegments(List<List<GeoPoint>> segs) {
  final left = [
    for (final s in segs)
      if (s.length > 1) List<GeoPoint>.of(s),
  ];
  final out = <List<GeoPoint>>[];
  while (left.isNotEmpty) {
    final cur = left.removeAt(0);
    var grew = true;
    while (grew) {
      grew = false;
      for (var i = 0; i < left.length; i++) {
        final s = left[i];
        if (_near(cur.last, s.first)) {
          cur.addAll(s.skip(1));
        } else if (_near(cur.last, s.last)) {
          cur.addAll(s.reversed.skip(1));
        } else if (_near(cur.first, s.last)) {
          cur.insertAll(0, s.take(s.length - 1));
        } else if (_near(cur.first, s.first)) {
          cur.insertAll(0, s.reversed.take(s.length - 1));
        } else {
          continue;
        }
        left.removeAt(i);
        grew = true;
        break;
      }
    }
    out.add(cur);
  }
  return out;
}

List<GeoPoint> _geom(Object? g) {
  final out = <GeoPoint>[];
  if (g is! List) return out;
  for (final p in g) {
    if (p is Map && p['lat'] is num && p['lon'] is num) {
      final q = GeoPoint(
        (p['lat'] as num).toDouble(),
        (p['lon'] as num).toDouble(),
      );
      if (q.valid) out.add(q);
    }
  }
  return out;
}

String _trailName(Map tags) {
  final n = '${tags['name'] ?? ''}'.trim();
  final ref = '${tags['ref'] ?? ''}'.trim();
  if (n.isNotEmpty && ref.isNotEmpty && !n.contains(ref)) return '$n #$ref';
  if (n.isNotEmpty) return n;
  return ref.isEmpty ? '' : 'Trail $ref';
}

/// Turn an Overpass JSON answer (from [buildTrailQuery]) into a trail layer:
/// one line per connected piece of each named trail (ways that belong to a
/// hiking route are drawn once, as the route) and a waypoint per place.
OverpassResult overpassToData(Object? json, {String name = 'OSM trails'}) {
  final Map j;
  if (json is String) {
    try {
      j = jsonDecode(json) as Map;
    } catch (_) {
      throw FetchException('Map data came back in a form the app cannot read.');
    }
  } else if (json is Map) {
    j = json;
  } else {
    throw FetchException('Map data came back in a form the app cannot read.');
  }
  final elements = (j['elements'] as List?) ?? const [];
  final remark = '${j['remark'] ?? ''}';
  final d = ImportedData(name: name);

  // Ways that are part of a hiking route (drawn as the route instead).
  final inRoute = <int>{};
  final routes = <String, List<List<GeoPoint>>>{};
  final ways = <String, List<List<GeoPoint>>>{};
  final places = <ImportedWaypoint>[];

  for (final e in elements) {
    if (e is! Map) continue;
    final tags = (e['tags'] as Map?) ?? const {};
    final type = e['type'];
    if (type == 'relation' && tags['route'] == 'hiking') {
      final n = _trailName(tags);
      if (n.isEmpty) continue;
      for (final m in (e['members'] as List?) ?? const []) {
        if (m is! Map || m['type'] != 'way') continue;
        final role = '${m['role'] ?? ''}';
        if (role == 'platform' || role == 'stop') continue;
        final g = _geom(m['geometry']);
        if (g.length < 2) continue;
        if (m['ref'] is num) inRoute.add((m['ref'] as num).toInt());
        (routes[n] ??= []).add(g);
      }
    }
  }
  for (final e in elements) {
    if (e is! Map) continue;
    final tags = (e['tags'] as Map?) ?? const {};
    final type = e['type'];
    final id = (e['id'] as num?)?.toInt() ?? 0;
    final pk = osmPlaceKind(tags);
    if (type == 'way' && pk == null && e['geometry'] != null) {
      final hw = tags['highway'];
      if (hw != 'path' &&
          hw != 'footway' &&
          hw != 'track' &&
          hw != 'bridleway') {
        continue;
      }
      if (inRoute.contains(id)) continue;
      final n = _trailName(tags);
      final g = _geom(e['geometry']);
      if (n.isEmpty || g.length < 2) continue;
      (ways[n] ??= []).add(g);
      continue;
    }
    if (pk == null) continue;
    GeoPoint? pos;
    if (type == 'node' && e['lat'] is num && e['lon'] is num) {
      pos = GeoPoint(
        (e['lat'] as num).toDouble(),
        (e['lon'] as num).toDouble(),
      );
    } else if (e['center'] is Map) {
      final c = e['center'] as Map;
      if (c['lat'] is num && c['lon'] is num) {
        pos = GeoPoint(
          (c['lat'] as num).toDouble(),
          (c['lon'] as num).toDouble(),
        );
      }
    }
    if (pos == null || !pos.valid) continue;
    final nm = '${tags['name'] ?? ''}'.trim();
    final ele = double.tryParse(
      '${tags['ele'] ?? ''}'.replaceAll(RegExp(r'[^0-9.\-]'), ''),
    );
    final desc = [
      pk.label,
      if (ele != null && pk.kind == 'peak') '${ele.round()} m',
    ].join(' · ');
    final w = ImportedWaypoint(
      nm.isEmpty ? pk.label : nm,
      pos,
      description: desc,
      kind: pk.kind,
    );
    final dup = places.any(
      (o) =>
          o.kind == w.kind && o.name == w.name && distanceM(o.pos, w.pos) < 50,
    );
    if (!dup) places.add(w);
  }

  void addLines(Map<String, List<List<GeoPoint>>> m) {
    final names = m.keys.toList()..sort();
    for (final n in names) {
      for (final c in chainSegments(m[n]!)) {
        d.lines.add(ImportedLine(n, c));
      }
    }
  }

  addLines(routes);
  addLines(ways);
  // Trailheads and water first: most useful if the cap cuts the list.
  const order = [
    'trailhead',
    'water',
    'spring',
    'campsite',
    'shelter',
    'lake',
    'peak',
  ];
  places.sort((a, b) {
    final c = order.indexOf(a.kind).compareTo(order.indexOf(b.kind));
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  d.waypoints.addAll(places);
  final partial =
      remark.contains('runtime error') ||
      remark.contains('timed out') ||
      remark.contains('out of memory');
  return OverpassResult(tidyImport(d), partial: partial, remark: remark);
}

/// Hiking data for an area from the Overpass API (OpenStreetMap). Polite:
/// one request at a time, a few seconds apart, with a server timeout and a
/// size cap on the answer.
class OverpassClient {
  OverpassClient({
    required this.fetch,
    RateLimiter? limiter,
    this.endpoint = 'https://overpass-api.de/api/interpreter',
  }) : limiter = limiter ?? shared;

  static final RateLimiter shared = RateLimiter(const Duration(seconds: 3));

  final Fetch fetch;
  final RateLimiter limiter;
  final String endpoint;

  /// Most bytes accepted from one answer.
  static const int maxAnswerBytes = 12 * 1024 * 1024;

  /// Busy-server answers retried once (after the limiter's pause).
  static const Set<int> retryStatus = {502, 503, 504};

  Future<String> _send(String q) => limiter.run(
    () => fetch(
      FetchRequest(
        Uri.parse(endpoint),
        method: 'POST',
        headers: const {
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
          'Accept': 'application/json',
        },
        body: 'data=${Uri.encodeQueryComponent(q)}',
        timeout: const Duration(seconds: 60),
        maxBytes: maxAnswerBytes,
      ),
    ),
  );

  Future<String> _post(String q) async {
    try {
      return await _send(q);
    } on FetchException catch (e) {
      if (!retryStatus.contains(e.status)) rethrow;
      return _send(q);
    }
  }

  /// Trails and places in [bounds] (inside the outline [areaId] when
  /// given; if the outline gives nothing, the box alone is tried).
  Future<OverpassResult> trails(
    GeoBounds bounds, {
    int? areaId,
    String name = 'OSM trails',
  }) async {
    var r = overpassToData(
      await _post(buildTrailQuery(bounds, areaId: areaId)),
      name: name,
    );
    if (areaId != null && r.data.isEmpty) {
      r = overpassToData(await _post(buildTrailQuery(bounds)), name: name);
    }
    if (r.data.isEmpty && r.partial) {
      throw FetchException(
        'Too much map data in this area for the server. Zoom in and try '
        '"Get trails" for the area on screen.',
      );
    }
    return r;
  }
}
