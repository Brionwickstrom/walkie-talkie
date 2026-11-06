/// v2.6.8: geofences on the Trip map. Pure geometry, hysteresis and a
/// local zone store. No radio requests and no extra GPS polling: the Trip
/// controller feeds positions it already has (mesh, friends, home).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min, pi, cos, sqrt;

import 'package:flutter/foundation.dart';

import 'geo.dart';
import 'trip_route.dart' show Clock;

/// Circle or polygon zone.
enum GeofenceShape { circle, polygon }

/// Who a zone watches.
enum GeofenceWatch { all, specific }

/// Enter or leave.
enum GeofenceCross { enter, leave }

/// One named zone drawn on the Trip map.
class GeofenceZone {
  GeofenceZone({
    required this.id,
    required this.name,
    required this.shape,
    this.center,
    this.radiusM,
    List<GeoPoint>? vertices,
    this.colorArgb = 0xFF2196F3,
    this.watch = GeofenceWatch.all,
    Set<int>? watchIds,
    this.muted = false,
    DateTime? createdAt,
  }) : vertices = List.unmodifiable(vertices ?? const []),
       watchIds = Set.unmodifiable(watchIds ?? const {}),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  GeofenceShape shape;

  /// Circle centre. Null for a polygon.
  GeoPoint? center;

  /// Circle radius in metres. Null for a polygon.
  double? radiusM;

  /// Polygon vertices in order (closed implicitly). Empty for a circle.
  final List<GeoPoint> vertices;

  /// ARGB colour for the map fill / stroke.
  int colorArgb;

  GeofenceWatch watch;

  /// Node / friend ids when [watch] is [GeofenceWatch.specific].
  /// Public nodes are never listed here.
  final Set<int> watchIds;

  /// Mute: still drawn, no alerts.
  bool muted;

  final DateTime createdAt;

  bool get isCircle => shape == GeofenceShape.circle;
  bool get isPolygon => shape == GeofenceShape.polygon;

  bool watches(int id) {
    if (watch == GeofenceWatch.all) return true;
    return watchIds.contains(id);
  }

  GeofenceZone copyWith({
    String? name,
    GeoPoint? center,
    double? radiusM,
    List<GeoPoint>? vertices,
    int? colorArgb,
    GeofenceWatch? watch,
    Set<int>? watchIds,
    bool? muted,
  }) => GeofenceZone(
    id: id,
    name: name ?? this.name,
    shape: shape,
    center: center ?? this.center,
    radiusM: radiusM ?? this.radiusM,
    vertices: vertices ?? this.vertices,
    colorArgb: colorArgb ?? this.colorArgb,
    watch: watch ?? this.watch,
    watchIds: watchIds ?? this.watchIds,
    muted: muted ?? this.muted,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    's': shape == GeofenceShape.circle ? 'c' : 'p',
    if (center != null) 'lat': center!.lat,
    if (center != null) 'lng': center!.lng,
    if (radiusM != null) 'r': radiusM,
    if (vertices.isNotEmpty)
      'v': [
        for (final p in vertices) [p.lat, p.lng],
      ],
    'col': colorArgb,
    'w': watch == GeofenceWatch.all ? 'a' : 's',
    if (watchIds.isNotEmpty) 'ids': watchIds.toList(),
    if (muted) 'm': true,
    'at': createdAt.millisecondsSinceEpoch,
  };

  static GeofenceZone? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    try {
      final shape = j['s'] == 'p'
          ? GeofenceShape.polygon
          : GeofenceShape.circle;
      GeoPoint? center;
      final lat = (j['lat'] as num?)?.toDouble();
      final lng = (j['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) center = GeoPoint(lat, lng);
      final verts = <GeoPoint>[];
      for (final raw in (j['v'] as List? ?? const [])) {
        if (raw is List && raw.length >= 2) {
          final a = (raw[0] as num?)?.toDouble();
          final b = (raw[1] as num?)?.toDouble();
          if (a != null && b != null) verts.add(GeoPoint(a, b));
        }
      }
      final ids = <int>{
        for (final x in (j['ids'] as List? ?? const []))
          if (x is num) x.toInt(),
      };
      final z = GeofenceZone(
        id: id,
        name: (j['n'] as String?)?.trim().isNotEmpty == true
            ? (j['n'] as String).trim()
            : 'Zone',
        shape: shape,
        center: center,
        radiusM: (j['r'] as num?)?.toDouble(),
        vertices: verts,
        colorArgb: (j['col'] as num?)?.toInt() ?? 0xFF2196F3,
        watch: j['w'] == 's' ? GeofenceWatch.specific : GeofenceWatch.all,
        watchIds: ids,
        muted: j['m'] == true,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (j['at'] as num?)?.toInt() ?? 0,
        ),
      );
      if (!z.isValid) return null;
      return z;
    } catch (_) {
      return null;
    }
  }

  /// A circle needs a centre and a positive radius; a polygon needs ≥ 3
  /// valid vertices.
  bool get isValid {
    if (name.trim().isEmpty) return false;
    if (isCircle) {
      final c = center, r = radiusM;
      return c != null && c.valid && r != null && r.isFinite && r >= 5;
    }
    if (vertices.length < 3) return false;
    return vertices.every((p) => p.valid);
  }
}

/// One enter / leave event.
class GeofenceEvent {
  const GeofenceEvent({
    required this.zoneId,
    required this.zoneName,
    required this.nodeId,
    required this.cross,
    required this.at,
    required this.pos,
  });

  final String zoneId;
  final String zoneName;
  final int nodeId;
  final GeofenceCross cross;
  final DateTime at;
  final GeoPoint pos;

  String get title => cross == GeofenceCross.enter
      ? 'Entered $zoneName'
      : 'Left $zoneName';

  String textFor(String who) => cross == GeofenceCross.enter
      ? '$who entered $zoneName'
      : '$who left $zoneName';
}

/// Point-in-circle with an optional buffer. [bufferM] > 0 shrinks the
/// circle for "enter" and grows it for "leave" (caller picks the sense).
bool pointInCircle(
  GeoPoint p,
  GeoPoint center,
  double radiusM, {
  double bufferM = 0,
}) {
  if (!p.valid || !center.valid || !radiusM.isFinite || radiusM < 0) {
    return false;
  }
  final r = max(0.0, radiusM + bufferM);
  return distanceM(p, center) <= r;
}

/// Ray-casting point-in-polygon. Vertices are not closed; the edge from
/// the last back to the first is implied. Degenerate (< 3) is outside.
bool pointInPolygon(GeoPoint p, List<GeoPoint> vertices) {
  if (!p.valid || vertices.length < 3) return false;
  if (!vertices.every((v) => v.valid)) return false;
  var inside = false;
  for (var i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
    final vi = vertices[i], vj = vertices[j];
    final intersect =
        ((vi.lat > p.lat) != (vj.lat > p.lat)) &&
        (p.lng <
            (vj.lng - vi.lng) * (p.lat - vi.lat) / (vj.lat - vi.lat + 0.0) +
                vi.lng);
    if (intersect) inside = !inside;
  }
  return inside;
}

/// Shortest distance in metres from [p] to any edge of [vertices]
/// (closed). Used for polygon hysteresis.
double distanceToPolygonEdgeM(GeoPoint p, List<GeoPoint> vertices) {
  if (vertices.length < 2) return double.infinity;
  var best = double.infinity;
  for (var i = 0; i < vertices.length; i++) {
    final a = vertices[i];
    final b = vertices[(i + 1) % vertices.length];
    best = min(best, _distToSegmentM(p, a, b));
  }
  return best;
}

double _distToSegmentM(GeoPoint p, GeoPoint a, GeoPoint b) {
  // Local equirectangular metres around [a].
  final kx = cos(a.lat * pi / 180) * earthRadiusM * pi / 180;
  const ky = earthRadiusM * pi / 180;
  final ax = 0.0, ay = 0.0;
  final bx = (b.lng - a.lng) * kx, by = (b.lat - a.lat) * ky;
  final px = (p.lng - a.lng) * kx, py = (p.lat - a.lat) * ky;
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  if (len2 < 1e-6) return distanceM(p, a);
  var t = ((px - ax) * dx + (py - ay) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final qx = ax + t * dx, qy = ay + t * dy;
  return sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
}

/// Whether [p] is inside [z], with an optional signed buffer in metres
/// (negative = shrink for enter, positive = grow for leave).
bool pointInZone(GeoPoint p, GeofenceZone z, {double bufferM = 0}) {
  if (z.isCircle) {
    final c = z.center, r = z.radiusM;
    if (c == null || r == null) return false;
    return pointInCircle(p, c, r, bufferM: bufferM);
  }
  final inside = pointInPolygon(p, z.vertices);
  if (bufferM == 0) return inside;
  final d = distanceToPolygonEdgeM(p, z.vertices);
  if (inside) {
    // Shrink: still "deeply" inside when farther than |buffer| from edge.
    if (bufferM < 0) return d >= -bufferM;
    return true;
  }
  // Outside: grow so leave needs to clear the buffer.
  if (bufferM > 0) return d <= bufferM;
  return false;
}

/// Default hysteresis buffer (metres) and alert cooldown.
const double geofenceBufferM = 25;
const Duration geofenceCooldown = Duration(minutes: 3);

/// Tracks inside/outside with hysteresis so GPS jitter at the edge does
/// not spam alerts. Pure; no I/O.
class GeofenceMonitor {
  GeofenceMonitor({
    Clock? clock,
    this.bufferM = geofenceBufferM,
    this.cooldown = geofenceCooldown,
  }) : _clock = clock ?? DateTime.now;

  final Clock _clock;
  final double bufferM;
  final Duration cooldown;

  /// zoneId → nodeId → currently inside (after hysteresis).
  final Map<String, Map<int, bool>> _inside = {};

  /// zoneId → nodeId → last alert time.
  final Map<String, Map<int, DateTime>> _lastAlert = {};

  /// Public / excluded node ids that never trigger alerts.
  final Set<int> excluded = {};

  List<GeofenceZone> zones = [];

  void setZones(List<GeofenceZone> z) {
    zones = List.of(z);
    final ids = {for (final x in zones) x.id};
    _inside.removeWhere((k, _) => !ids.contains(k));
    _lastAlert.removeWhere((k, _) => !ids.contains(k));
  }

  /// Feed a position the app already has. Returns zero or more events.
  List<GeofenceEvent> observe(int nodeId, GeoPoint pos, {DateTime? at}) {
    if (!pos.valid || excluded.contains(nodeId)) return const [];
    final now = at ?? _clock();
    final out = <GeofenceEvent>[];
    for (final z in zones) {
      if (z.muted || !z.isValid || !z.watches(nodeId)) continue;
      final prev = _inside[z.id]?[nodeId];
      // Enter needs to clear the inner (shrunk) edge; leave the outer.
      final deepIn = pointInZone(pos, z, bufferM: -bufferM);
      final deepOut = !pointInZone(pos, z, bufferM: bufferM);
      bool? next;
      if (prev == null) {
        // First sighting: seed state without alerting.
        next = pointInZone(pos, z);
      } else if (prev && deepOut) {
        next = false;
      } else if (!prev && deepIn) {
        next = true;
      } else {
        next = prev;
      }
      _inside.putIfAbsent(z.id, () => {})[nodeId] = next;
      if (prev == null || prev == next) continue;
      final last = _lastAlert[z.id]?[nodeId];
      if (last != null && now.difference(last) < cooldown) continue;
      _lastAlert.putIfAbsent(z.id, () => {})[nodeId] = now;
      out.add(
        GeofenceEvent(
          zoneId: z.id,
          zoneName: z.name,
          nodeId: nodeId,
          cross: next ? GeofenceCross.enter : GeofenceCross.leave,
          at: now,
          pos: pos,
        ),
      );
    }
    return out;
  }

  /// Current inside state, or null if never seen.
  bool? isInside(String zoneId, int nodeId) => _inside[zoneId]?[nodeId];

  void forgetNode(int nodeId) {
    for (final m in _inside.values) {
      m.remove(nodeId);
    }
    for (final m in _lastAlert.values) {
      m.remove(nodeId);
    }
  }

  void clear() {
    _inside.clear();
    _lastAlert.clear();
  }
}

/// Local JSON store for zones (phone and desktop). Same folder as offline
/// areas / saved routes.
class GeofenceStore extends ChangeNotifier {
  GeofenceStore(this.file, {Clock? clock}) : _clock = clock ?? DateTime.now;

  final File file;
  final Clock _clock;
  final List<GeofenceZone> _zones = [];
  bool _loaded = false;

  List<GeofenceZone> get zones => List.unmodifiable(_zones);
  bool get loaded => _loaded;

  GeofenceZone? byId(String id) {
    for (final z in _zones) {
      if (z.id == id) return z;
    }
    return null;
  }

  Future<void> load() async {
    try {
      if (await file.exists()) {
        final raw = await file.readAsString();
        final j = jsonDecode(raw);
        _zones
          ..clear()
          ..addAll([
            for (final e in (j is Map ? j['z'] as List? : j as List?) ??
                const [])
              ?GeofenceZone.fromJson(e),
          ]);
      }
    } catch (_) {
      // Keep whatever we had; a corrupt file is ignored.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'z': [for (final z in _zones) z.toJson()],
        }),
      );
    } catch (_) {}
  }

  String _newId() =>
      'gf_${_clock().millisecondsSinceEpoch.toRadixString(36)}';

  Future<GeofenceZone?> add(GeofenceZone draft) async {
    if (!draft.isValid) return null;
    final z = GeofenceZone(
      id: draft.id.isEmpty ? _newId() : draft.id,
      name: draft.name.trim(),
      shape: draft.shape,
      center: draft.center,
      radiusM: draft.radiusM,
      vertices: draft.vertices,
      colorArgb: draft.colorArgb,
      watch: draft.watch,
      watchIds: draft.watchIds,
      muted: draft.muted,
      createdAt: _clock(),
    );
    _zones.add(z);
    await _save();
    notifyListeners();
    return z;
  }

  Future<bool> update(GeofenceZone z) async {
    final i = _zones.indexWhere((x) => x.id == z.id);
    if (i < 0 || !z.isValid) return false;
    _zones[i] = z;
    await _save();
    notifyListeners();
    return true;
  }

  Future<bool> rename(String id, String name) async {
    final z = byId(id);
    if (z == null) return false;
    final n = name.trim();
    if (n.isEmpty) return false;
    return update(z.copyWith(name: n));
  }

  Future<bool> setMuted(String id, bool muted) async {
    final z = byId(id);
    if (z == null) return false;
    return update(z.copyWith(muted: muted));
  }

  Future<bool> remove(String id) async {
    final n = _zones.length;
    _zones.removeWhere((z) => z.id == id);
    if (_zones.length == n) return false;
    await _save();
    notifyListeners();
    return true;
  }

  /// Optional share: one zone as JSON text. Null when the id is unknown.
  String? exportOne(String id) {
    final z = byId(id);
    if (z == null) return null;
    return jsonEncode(z.toJson());
  }
}

/// Plain error for a bad drawn zone (shown via friendly_error).
String? validateGeofenceDraft({
  required GeofenceShape shape,
  GeoPoint? center,
  double? radiusM,
  List<GeoPoint>? vertices,
  String? name,
}) {
  final n = name?.trim() ?? '';
  if (n.isEmpty) return 'Give this zone a name.';
  if (shape == GeofenceShape.circle) {
    if (center == null || !center.valid) {
      return 'Tap the map to set the centre.';
    }
    if (radiusM == null || !radiusM.isFinite || radiusM < 5) {
      return 'Drag farther — the zone needs to be at least 5 metres across.';
    }
    if (radiusM > 100000) {
      return 'That zone is too big (100 km max).';
    }
    return null;
  }
  final v = vertices ?? const <GeoPoint>[];
  if (v.length < 3) return 'Tap at least three corners, then tap Done.';
  if (!v.every((p) => p.valid)) return 'One of the corners is not a place.';
  return null;
}
