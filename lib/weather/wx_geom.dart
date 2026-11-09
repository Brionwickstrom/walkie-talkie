/// Alert-area geometry for the Trip map (v2.6.14).
///
/// Where a shape comes from:
/// * The alert's own polygon, when the National Weather Service included
///   one in the warning this phone already downloaded (or a relay copy
///   carried a simplified outline).
/// * Otherwise the county / forecast zone named by the alert's zone code.
///   Those outlines are fetched once from the NWS zones service and kept
///   on the phone. A radio packet is too small to carry a polygon: it
///   names the zone, and the map uses the saved outline.
///
/// Point-in-area uses the same ray cast as geofences ([pointInPolygon]).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../trip/geo.dart';
import '../trip/geofence.dart';

/// One polygon: an outer ring and any holes. Rings are not repeated at
/// the end; the edge from the last point back to the first is implied.
class WxPolygon {
  const WxPolygon(this.outer, [this.holes = const []]);

  final List<GeoPoint> outer;
  final List<List<GeoPoint>> holes;

  bool get ok => outer.length >= 3 && outer.every((p) => p.valid);
}

/// True when [p] is inside [poly], and not inside one of its holes.
bool pointInWxPolygon(GeoPoint p, WxPolygon poly) {
  if (!poly.ok || !pointInPolygon(p, poly.outer)) return false;
  for (final h in poly.holes) {
    if (h.length >= 3 && pointInPolygon(p, h)) return false;
  }
  return true;
}

bool pointInWxPolygons(GeoPoint p, List<WxPolygon> polys) {
  for (final g in polys) {
    if (pointInWxPolygon(p, g)) return true;
  }
  return false;
}

/// GeoJSON geometry (`Polygon` or `MultiPolygon`, coordinates `[lng, lat]`)
/// into simplified polygons. Null geometry, a bad shape, or a point is an
/// empty list: the alert is still valid, it just has no area to draw.
List<WxPolygon> wxPolygonsFromGeoJson(Object? geometry) {
  if (geometry is! Map) return const [];
  final type = geometry['type'];
  final coords = geometry['coordinates'];
  if (coords is! List) return const [];
  final raw = <WxPolygon>[];
  if (type == 'Polygon') {
    final p = _polygon(coords);
    if (p != null) raw.add(p);
  } else if (type == 'MultiPolygon') {
    for (final part in coords) {
      if (part is! List) continue;
      final p = _polygon(part);
      if (p != null) raw.add(p);
    }
  }
  return _capPolygons(raw);
}

/// A whole GeoJSON feature or feature collection (a zone answer).
List<WxPolygon> wxPolygonsFromFeature(Object? body) {
  if (body is! Map) return const [];
  if (body['type'] == 'FeatureCollection' && body['features'] is List) {
    final all = <WxPolygon>[];
    for (final f in body['features'] as List) {
      if (f is Map) all.addAll(wxPolygonsFromGeoJson(f['geometry']));
    }
    return _capPolygons(all);
  }
  if (body['geometry'] != null) return wxPolygonsFromGeoJson(body['geometry']);
  return wxPolygonsFromGeoJson(body);
}

WxPolygon? _polygon(List<dynamic> rings) {
  if (rings.isEmpty) return null;
  final outer = _ring(rings.first);
  if (outer == null) return null;
  final holes = <List<GeoPoint>>[];
  for (var i = 1; i < rings.length; i++) {
    final h = _ring(rings[i]);
    if (h != null) holes.add(h);
  }
  return WxPolygon(outer, holes);
}

List<GeoPoint>? _ring(Object? raw) {
  if (raw is! List) return null;
  final pts = <GeoPoint>[];
  for (final c in raw) {
    if (c is! List || c.length < 2) continue;
    final lng = c[0];
    final lat = c[1];
    if (lng is! num || lat is! num) continue;
    final p = GeoPoint(lat.toDouble(), lng.toDouble());
    if (!p.valid) continue;
    if (pts.isNotEmpty && _same(pts.last, p)) continue;
    pts.add(p);
  }
  if (pts.length >= 2 && _same(pts.first, pts.last)) pts.removeLast();
  final simple = simplifyRing(pts);
  if (simple.length < 3) return null;
  return simple;
}

bool _same(GeoPoint a, GeoPoint b) =>
    (a.lat - b.lat).abs() < 1e-6 && (a.lng - b.lng).abs() < 1e-6;

/// Keep the largest rings. A county can arrive as dozens of islands.
List<WxPolygon> _capPolygons(List<WxPolygon> ps, {int max = 12}) {
  if (ps.length <= max) return ps;
  final ranked = [...ps]
    ..sort((a, b) => b.outer.length.compareTo(a.outer.length));
  return ranked.take(max).toList();
}

/// Douglas-Peucker in degrees, then a hard cap so a county outline stays
/// small enough to draw and to keep on the phone.
List<GeoPoint> simplifyRing(
  List<GeoPoint> pts, {
  double tolerance = 0.004,
  int maxPoints = 80,
}) {
  if (pts.length < 3) return const [];
  var ring = pts.length > 500 ? _stride(pts, 500) : pts;
  var tol = tolerance;
  var out = _dp(ring, tol);
  var spins = 0;
  while (out.length > maxPoints && spins < 6) {
    tol *= 1.8;
    out = _dp(ring, tol);
    spins++;
  }
  if (out.length > maxPoints) out = _stride(out, maxPoints);
  return out.length >= 3 ? out : const [];
}

List<GeoPoint> _stride(List<GeoPoint> pts, int max) {
  if (pts.length <= max) return pts;
  final step = (pts.length / max).ceil();
  final out = <GeoPoint>[pts.first];
  for (var i = step; i < pts.length - 1; i += step) {
    out.add(pts[i]);
  }
  out.add(pts.last);
  return out;
}

List<GeoPoint> _dp(List<GeoPoint> pts, double tol) {
  if (pts.length < 3) return pts;
  var maxD = 0.0;
  var idx = 0;
  final a = pts.first;
  final b = pts.last;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _perp(pts[i], a, b);
    if (d > maxD) {
      maxD = d;
      idx = i;
    }
  }
  if (maxD <= tol) return [a, b];
  final left = _dp(pts.sublist(0, idx + 1), tol);
  final right = _dp(pts.sublist(idx), tol);
  return [...left.sublist(0, left.length - 1), ...right];
}

double _perp(GeoPoint p, GeoPoint a, GeoPoint b) {
  final dx = b.lng - a.lng;
  final dy = b.lat - a.lat;
  final len2 = dx * dx + dy * dy;
  if (len2 < 1e-18) {
    return math.sqrt(math.pow(p.lng - a.lng, 2) + math.pow(p.lat - a.lat, 2));
  }
  var t = ((p.lng - a.lng) * dx + (p.lat - a.lat) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final qx = a.lng + t * dx;
  final qy = a.lat + t * dy;
  return math.sqrt(math.pow(p.lng - qx, 2) + math.pow(p.lat - qy, 2));
}

double _round5(double v) => (v * 1e5).roundToDouble() / 1e5;

List<Object?> wxPolygonsToJson(List<WxPolygon> ps) => [
  for (final p in ps)
    {
      'o': [
        for (final g in p.outer) [_round5(g.lat), _round5(g.lng)],
      ],
      if (p.holes.isNotEmpty)
        'h': [
          for (final h in p.holes)
            [
              for (final g in h) [_round5(g.lat), _round5(g.lng)],
            ],
        ],
    },
];

List<WxPolygon> wxPolygonsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <WxPolygon>[];
  for (final item in raw) {
    if (out.length >= 12) break;
    if (item is! Map) continue;
    final outer = _pts(item['o'], max: 120);
    if (outer.length < 3) continue;
    final holes = <List<GeoPoint>>[];
    final hs = item['h'];
    if (hs is List) {
      for (final h in hs) {
        if (holes.length >= 8) break;
        final ring = _pts(h, max: 80);
        if (ring.length >= 3) holes.add(ring);
      }
    }
    out.add(WxPolygon(outer, holes));
  }
  return out;
}

List<GeoPoint> _pts(Object? raw, {required int max}) {
  if (raw is! List) return const [];
  final out = <GeoPoint>[];
  for (final c in raw) {
    if (out.length >= max) break;
    if (c is! List || c.length < 2) continue;
    final lat = c[0];
    final lng = c[1];
    if (lat is! num || lng is! num) continue;
    final p = GeoPoint(lat.toDouble(), lng.toDouble());
    if (p.valid) out.add(p);
  }
  return out;
}

/// A smaller copy for the relay. Null when it would not fit: the zones
/// still go, and the receiver draws the saved zone outline instead.
/// Older apps ignore this field.
Object? wxWireGeometry(List<WxPolygon> ps, {int maxBytes = 1200}) {
  if (ps.isEmpty) return null;
  final slim = <WxPolygon>[];
  for (final p in ps.take(3)) {
    final outer = p.outer.length <= 48
        ? p.outer
        : simplifyRing(p.outer, tolerance: 0.01, maxPoints: 48);
    if (outer.length < 3) continue;
    slim.add(WxPolygon(outer));
  }
  if (slim.isEmpty) return null;
  final j = wxPolygonsToJson(slim);
  if (utf8.encode(jsonEncode(j)).length > maxBytes) return null;
  return j;
}

/// One saved zone outline (`ORZ006`, `ORC051`). [missing] means the NWS
/// said this code has no shape (or it is not a zone code): do not ask
/// again for a week.
class WxZoneRecord {
  const WxZoneRecord({
    required this.code,
    required this.at,
    required this.polygons,
    required this.missing,
  });

  final String code;
  final DateTime at;
  final List<WxPolygon> polygons;
  final bool missing;

  Map<String, Object?> toJson() => {
    't': at.millisecondsSinceEpoch,
    if (missing) 'm': true,
    if (polygons.isNotEmpty) 'p': wxPolygonsToJson(polygons),
  };

  static WxZoneRecord? fromJson(String code, Object? j) {
    if (j is! Map || j['t'] is! num || code.isEmpty) return null;
    return WxZoneRecord(
      code: code,
      at: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
      polygons: wxPolygonsFromJson(j['p']),
      missing: j['m'] == true,
    );
  }
}

/// Zone outlines on disk (`wx_zones.json`). A fresh outline is kept 30
/// days; a known miss is kept 7 days. No timer of its own.
class WxZoneCache {
  WxZoneCache({this.file, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final File? file;
  final DateTime Function() _clock;
  final Map<String, WxZoneRecord> _items = {};

  static const freshFor = Duration(days: 30);
  static const missingFor = Duration(days: 7);

  /// The record when it is still fresh, else null (ask again).
  WxZoneRecord? lookup(String code, [DateTime? now]) {
    final r = _items[code];
    if (r == null) return null;
    final age = (now ?? _clock()).difference(r.at);
    if (age.isNegative) return null;
    final ttl = r.missing || r.polygons.isEmpty ? missingFor : freshFor;
    if (age > ttl) return null;
    return r;
  }

  /// Codes whose outline can be drawn right now.
  Map<String, List<WxPolygon>> outlines([DateTime? now]) {
    final t = now ?? _clock();
    return {
      for (final e in _items.entries)
        if (lookup(e.key, t) case final r?)
          if (r.polygons.isNotEmpty) e.key: r.polygons,
    };
  }

  void put(WxZoneRecord r) {
    if (r.code.isEmpty) return;
    _items[r.code] = r;
  }

  Future<void> load() async {
    final f = file;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      final z = j['z'];
      if (z is! Map) return;
      _items.clear();
      for (final e in z.entries) {
        final r = WxZoneRecord.fromJson('${e.key}', e.value);
        if (r != null) _items[r.code] = r;
      }
    } catch (_) {}
  }

  Future<void> save() async {
    final f = file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'v': 1,
          'z': {for (final e in _items.entries) e.key: e.value.toJson()},
        }),
      );
      await tmp.rename(f.path);
    } catch (_) {}
  }
}

/// `ORZ006` -> forecast, `ORC051` -> county, `ORF001` -> fire.
/// Null when it is not a zone code (nothing to ask the NWS).
Uri? wxZoneUrl(String ugc) {
  final m = RegExp(r'^([A-Z]{2})([ZCF])(\d{3})$').firstMatch(ugc);
  if (m == null) return null;
  final kind = switch (m.group(2)) {
    'C' => 'county',
    'F' => 'fire',
    'Z' => 'forecast',
    _ => null,
  };
  if (kind == null) return null;
  return Uri.https('api.weather.gov', '/zones/$kind/$ugc');
}
