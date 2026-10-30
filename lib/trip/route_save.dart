import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'drive/road_router.dart' show DriveRoute;
import 'geo.dart';
import 'nav/trail_graph.dart';
import 'tile_cache.dart';

/// "Save route for offline" (v2.2.0): one tap saves a corridor of map
/// tiles, the roads and trails near the route, the elevation for the walk,
/// the turn list and the trailhead info, as ONE item in Offline areas.
///
/// Everything here is plain maths and data (no network, no GPS), so it is
/// cheap and easy to test. The controller does the downloading, only when
/// the user taps Save, one request at a time.

/// Tiles of the map saved along the drive (wide, low zoom) and the walk
/// (tight, high zoom).
const double driveTileBufferM = 3000;
const double hikeTileBufferM = 700;
const double hikeApproxBufferM = 1500;

/// Roads and trails buffers.
const double driveRoadBufferM = 2500;
const double hikeRoadBufferM = 1000;
const double hikeTrailBufferM = 1200;

/// Most tiles saved for one leg and map (keeps it polite and small).
const int maxDriveTiles = 600;
const int maxHikeTiles = 900;
const int maxElevationTiles = 400;

/// One tile request per second to the free map servers.
const Duration routeTilePause = Duration(seconds: 1);

/// Longest drive whose roads are saved (km); online directions still work
/// beyond it, and the turn list and map tiles are saved anyway.
const double maxRoadKm = 500;

/// A saved route: the plan (what to download) and what was kept (turns).
class SavedRoute {
  SavedRoute({
    this.id = '',
    required this.name,
    required this.destination,
    this.drive,
    this.hike,
    this.trailheadName = '',
    this.trailheadPos,
    this.hikeApprox = false,
    DateTime? at,
    this.status = partial,
    this.problems = const [],
    this.baseId = 'topo',
  }) : at = at ?? DateTime.now();

  static const partial = 'partial';
  static const ready = 'ready';

  /// The offline area this belongs to ('' until first saved).
  String id;

  /// Named after the destination.
  String name;
  final GeoPoint destination;
  final DriveRoute? drive;
  final TrailRoute? hike;

  /// Drive then hike: where to park (the end of the drive).
  final String trailheadName;
  final GeoPoint? trailheadPos;

  /// The walk was not planned yet (it is planned at the trailhead): the
  /// corridor is a wide strip along the straight line.
  final bool hikeApprox;
  DateTime at;
  String status;
  List<String> problems;

  /// The base map style saved ([MapSource.id]).
  String baseId;

  bool get isReady => status == ready;
  bool get hasDrive => drive != null;
  bool get hasHike => hike != null || hikeApprox;

  /// Turns saved (drive steps + walk junctions).
  int get turns => (drive?.steps.length ?? 0) + (hike?.junctions.length ?? 0);

  /// The walking line to use: the route, or a straight strip.
  List<GeoPoint> get hikePoints {
    final h = hike;
    if (h != null && h.points.length > 1) return h.points;
    final a = trailheadPos;
    if (hikeApprox && a != null) return [a, destination];
    return const [];
  }

  /// "Drive 120 km, hike 5 km" style summary.
  String summary({bool imperial = false}) {
    final parts = <String>[];
    if (drive != null) {
      parts.add('drive ${formatDistance(drive!.lengthM, imperial: imperial)}');
    }
    if (hike != null) {
      parts.add('hike ${formatDistance(hike!.lengthM, imperial: imperial)}');
    } else if (hikeApprox) {
      parts.add('hike (planned at the trailhead)');
    }
    return parts.isEmpty ? 'route' : parts.join(' + ');
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    'to': [destination.lat, destination.lng],
    if (drive != null) 'd': drive!.toJson(),
    if (hike != null) 'h': trailRouteToJson(hike!),
    if (trailheadName.isNotEmpty) 'tn': trailheadName,
    if (trailheadPos != null) 'tp': [trailheadPos!.lat, trailheadPos!.lng],
    if (hikeApprox) 'ha': true,
    'at': at.millisecondsSinceEpoch,
    's': status,
    if (problems.isNotEmpty) 'pr': problems,
    'b': baseId,
  };

  static SavedRoute? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      GeoPoint pt(Object? o) => GeoPoint(
        ((o as List)[0] as num).toDouble(),
        (o[1] as num).toDouble(),
      );
      return SavedRoute(
        id: (j['id'] as String?) ?? '',
        name: (j['n'] as String?) ?? 'Route',
        destination: pt(j['to']),
        drive: j['d'] == null ? null : DriveRoute.fromJson(j['d']),
        hike: j['h'] == null ? null : trailRouteFromJson(j['h']),
        trailheadName: (j['tn'] as String?) ?? '',
        trailheadPos: j['tp'] == null ? null : pt(j['tp']),
        hikeApprox: j['ha'] == true,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
        status: (j['s'] as String?) ?? partial,
        problems: [for (final p in (j['pr'] as List? ?? const [])) '$p'],
        baseId: (j['b'] as String?) ?? 'topo',
      );
    } catch (_) {
      return null;
    }
  }
}

Map<String, Object?> trailRouteToJson(TrailRoute r) => {
  'p': [
    for (final p in r.points) [(p.lat * 1e6).round(), (p.lng * 1e6).round()],
  ],
  'e': [for (final e in r.ele) e.isFinite ? (e * 10).round() : null],
  'j': [
    for (final j in r.junctions) [j.index, j.alongM.round(), j.turn, j.next],
  ],
  'so': r.startOffM.round(),
  'eo': r.endOffM.round(),
  'src': r.source,
};

TrailRoute? trailRouteFromJson(Object? j) {
  if (j is! Map) return null;
  try {
    final pts = [
      for (final o in (j['p'] as List))
        GeoPoint((o[0] as num) / 1e6, (o[1] as num) / 1e6),
    ];
    final ele = [
      for (final e in (j['e'] as List))
        e == null ? double.nan : (e as num) / 10,
    ];
    if (pts.length < 2 || ele.length != pts.length) return null;
    final r = TrailRoute(
      pts,
      ele,
      [
        for (final o in (j['j'] as List))
          RouteJunction(
            (o[0] as num).toInt(),
            (o[1] as num).toDouble(),
            o[2] as String,
            o[3] as String,
          ),
      ],
      startOffM: (j['so'] as num).toDouble(),
      endOffM: (j['eo'] as num).toDouble(),
    );
    r.source = (j['src'] as String?) ?? '';
    return r;
  } catch (_) {
    return null;
  }
}

/// A copy of [r] (own elevation list) with another [source].
TrailRoute copyTrailRoute(TrailRoute r, {String? source}) {
  final c = TrailRoute(
    r.points,
    List<double>.of(r.ele),
    r.junctions,
    startOffM: r.startOffM,
    endOffM: r.endOffM,
  );
  c.source = source ?? r.source;
  return c;
}

/// Metres from [p] to the nearest point of the line [pts].
double distanceToLineM(List<GeoPoint> pts, GeoPoint p) {
  if (pts.isEmpty) return double.infinity;
  if (pts.length == 1) return distanceM(pts.first, p);
  final kx = 111319.49 * cos(p.lat * pi / 180);
  const ky = 111132.954;
  var best = double.infinity;
  for (var i = 0; i + 1 < pts.length; i++) {
    final ax = (pts[i].lng - p.lng) * kx, ay = (pts[i].lat - p.lat) * ky;
    final bx = (pts[i + 1].lng - p.lng) * kx,
        by = (pts[i + 1].lat - p.lat) * ky;
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : -(ax * dx + ay * dy) / l2;
    t = t.clamp(0.0, 1.0);
    final x = ax + t * dx, y = ay + t * dy;
    best = min(best, sqrt(x * x + y * y));
  }
  return best;
}

/// Points along [pts] no more than [stepM] apart.
List<GeoPoint> densify(List<GeoPoint> pts, double stepM) {
  if (pts.length < 2) return List.of(pts);
  final out = <GeoPoint>[pts.first];
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], b = pts[i + 1];
    final d = distanceM(a, b);
    final n = max(1, (d / stepM).ceil());
    for (var k = 1; k <= n; k++) {
      final t = k / n;
      out.add(
        GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t),
      );
    }
  }
  return out;
}

double _tileMetres(int z, double lat) =>
    40075016.686 * cos(lat * pi / 180) / (1 << z);

/// The tiles within [bufferM] of the line [pts] at zooms [z0]..[z1]: a
/// strip along the route, not the whole box around it.
List<TileId> corridorTiles(
  List<GeoPoint> pts, {
  required double bufferM,
  required int z0,
  required int z1,
}) {
  final out = <TileId>{};
  if (pts.isEmpty) return const [];
  for (var z = z0; z <= z1; z++) {
    final lat0 = pts.first.lat;
    final samples = densify(pts, max(15.0, _tileMetres(z, lat0) / 2));
    for (final p in samples) {
      final dLat = bufferM / 111132.954;
      final dLng = bufferM / (111319.49 * max(0.05, cos(p.lat * pi / 180)));
      final x0 = tileX(p.lng - dLng, z), x1 = tileX(p.lng + dLng, z);
      final y0 = tileY(p.lat + dLat, z), y1 = tileY(p.lat - dLat, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          out.add((z: z, x: x, y: y));
        }
      }
    }
  }
  return out.toList()..sort((a, b) {
    final c = a.z.compareTo(b.z);
    if (c != 0) return c;
    final d = a.x.compareTo(b.x);
    return d != 0 ? d : a.y.compareTo(b.y);
  });
}

/// The most detail ([z1] lowered as needed, never below [z0]) that keeps
/// the corridor under [maxTiles]; null when even [z0] is too much.
({int z0, int z1, List<TileId> tiles})? corridorForBudget(
  List<GeoPoint> pts, {
  required double bufferM,
  required int z0,
  required int z1,
  required int maxTiles,
}) {
  for (var z = z1; z >= z0; z--) {
    final t = corridorTiles(pts, bufferM: bufferM, z0: z0, z1: z);
    if (t.length <= maxTiles) return (z0: z0, z1: z, tiles: t);
  }
  return null;
}

/// The box around [pts] grown by [bufferM].
GeoBounds routeBounds(List<GeoPoint> pts, double bufferM) {
  var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
  for (final p in pts) {
    s = min(s, p.lat);
    n = max(n, p.lat);
    w = min(w, p.lng);
    e = max(e, p.lng);
  }
  final dLat = bufferM / 111132.954;
  final dLng = bufferM / (111319.49 * max(0.05, cos(((s + n) / 2) * pi / 180)));
  return GeoBounds(s - dLat, w - dLng, n + dLat, e + dLng);
}

/// Small boxes along [pts] (each about [chunkM] of route long, grown by
/// [bufferM]) for the road and trail servers: a strip, not a big box.
/// More than [maxWindows] boxes: longer ones.
List<GeoBounds> routeWindows(
  List<GeoPoint> pts, {
  required double chunkM,
  required double bufferM,
  int maxWindows = 40,
}) {
  if (pts.length < 2) {
    return pts.isEmpty ? const [] : [routeBounds(pts, bufferM)];
  }
  var total = 0.0;
  for (var i = 0; i + 1 < pts.length; i++) {
    total += distanceM(pts[i], pts[i + 1]);
  }
  final chunk = max(chunkM, total / maxWindows);
  final out = <GeoBounds>[];
  var cur = <GeoPoint>[pts.first];
  var acc = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final d = distanceM(pts[i - 1], pts[i]);
    cur.add(pts[i]);
    acc += d;
    if (acc >= chunk && i < pts.length - 1) {
      out.add(routeBounds(cur, bufferM));
      cur = [pts[i]];
      acc = 0;
    }
  }
  if (cur.length > 1 || out.isEmpty) out.add(routeBounds(cur, bufferM));
  return out;
}

/// One map download: a style over a corridor.
class RouteTileJob {
  RouteTileJob({
    required this.label,
    required this.src,
    required this.tiles,
    required this.bounds,
    required this.z0,
    required this.z1,
  });
  final String label;
  final MapSource src;
  final List<TileId> tiles;
  final GeoBounds bounds;
  final int z0, z1;
}

/// What saving a route downloads.
class RouteSaveJobs {
  RouteSaveJobs({
    required this.tiles,
    required this.roadWindows,
    required this.trailWindows,
    required this.bounds,
    required this.notes,
  });
  final List<RouteTileJob> tiles;
  final List<GeoBounds> roadWindows, trailWindows;

  /// Everything together (the area's box).
  final GeoBounds bounds;
  final List<String> notes;

  int get tileCount => tiles.fold(0, (s, j) => s + j.tiles.length);
  int get tileBytes =>
      tiles.fold(0, (s, j) => s + j.tiles.length * j.src.avgTileBytes);

  /// Roads and trails are not asked about first (that would be one more
  /// request each): about 30 KB a km of drive, 12 KB a km of walk.
  int roadBytes(SavedRoute r) =>
      ((r.drive?.lengthM ?? 0) / 1000 * 30 * 1024 +
              (r.hikePoints.length > 1 ? _lineKm(r.hikePoints) * 12 * 1024 : 0))
          .round();
  int trailBytes(SavedRoute r) =>
      (r.hikePoints.length > 1 ? _lineKm(r.hikePoints) * 15 * 1024 : 20 * 1024)
          .round();

  int requests(SavedRoute r) =>
      tileCount +
      (roadWindows.isEmpty ? 0 : 3 * roadWindows.length) +
      3 * trailWindows.length;

  /// Rough time: one tile a second; roads and trails every 3 seconds.
  Duration time(SavedRoute r) => Duration(
    seconds:
        tileCount * routeTilePause.inSeconds +
        (roadWindows.length + trailWindows.length) * 4,
  );

  int bytes(SavedRoute r) => tileBytes + roadBytes(r) + trailBytes(r);
}

double _lineKm(List<GeoPoint> pts) {
  var m = 0.0;
  for (var i = 0; i + 1 < pts.length; i++) {
    m += distanceM(pts[i], pts[i + 1]);
  }
  return m / 1000;
}

/// What to download for [r], with [base] as the map style.
RouteSaveJobs routeSaveJobs(SavedRoute r, MapSource base) {
  final notes = <String>[];
  final tiles = <RouteTileJob>[];
  final all = <GeoPoint>[];
  final drive = r.drive?.points ?? const <GeoPoint>[];
  final hike = r.hikePoints;
  all
    ..addAll(drive)
    ..addAll(hike);
  if (all.isEmpty) all.add(r.destination);
  final hikeBuf = r.hikeApprox ? hikeApproxBufferM : hikeTileBufferM;

  RouteTileJob? job(
    String label,
    MapSource src,
    List<GeoPoint> pts,
    double buf,
    int z0,
    int z1,
    int cap,
  ) {
    final lo = max(z0, src.minZoom), hi = min(z1, src.maxZoom);
    if (lo > hi) return null;
    final c = corridorForBudget(
      pts,
      bufferM: buf,
      z0: lo,
      z1: hi,
      maxTiles: cap,
    );
    if (c == null) {
      notes.add('$label: the route is too long for map tiles.');
      return null;
    }
    if (c.z1 < hi) {
      notes.add(
        '$label: lower detail (zoom ${c.z0}-${c.z1}) because it is long.',
      );
    }
    return RouteTileJob(
      label: label,
      src: src,
      tiles: c.tiles,
      bounds: routeBounds(pts, buf),
      z0: c.z0,
      z1: c.z1,
    );
  }

  if (drive.length > 1) {
    final j = job(
      'Map along the drive',
      base,
      drive,
      driveTileBufferM,
      8,
      14,
      maxDriveTiles,
    );
    if (j != null) tiles.add(j);
  }
  if (hike.length > 1) {
    final j = job(
      'Map along the walk',
      base,
      hike,
      hikeBuf,
      12,
      16,
      maxHikeTiles,
    );
    if (j != null) tiles.add(j);
    final e = job(
      'Elevation along the walk',
      MapSource.terrarium,
      hike,
      1500,
      12,
      12,
      maxElevationTiles,
    );
    if (e != null) tiles.add(e);
  } else if (drive.length < 2) {
    // A single point: a small map around it.
    final j = job('Map', base, [r.destination], 1500, 12, 15, maxHikeTiles);
    if (j != null) tiles.add(j);
  }

  final roads = <GeoBounds>[];
  if (drive.length > 1) {
    if (_lineKm(drive) > maxRoadKm) {
      notes.add(
        'Roads: the drive is longer than ${maxRoadKm.round()} km, so its '
        'roads are not saved (the turn list and map are).',
      );
    } else {
      roads.addAll(
        routeWindows(drive, chunkM: 12000, bufferM: driveRoadBufferM),
      );
    }
  }
  if (hike.length > 1) {
    roads.addAll(routeWindows(hike, chunkM: 10000, bufferM: hikeRoadBufferM));
  }
  final trails = hike.length > 1
      ? routeWindows(hike, chunkM: 8000, bufferM: hikeTrailBufferM)
      : [
          routeBounds([r.destination], 1500),
        ];

  // Hybrid photos: the roads and names layer over the same tiles.
  for (final j in List.of(tiles)) {
    final l = j.src.labels;
    if (l == null) continue;
    tiles.add(
      RouteTileJob(
        label: '${j.label} (roads and names)',
        src: l,
        tiles: j.tiles,
        bounds: j.bounds,
        z0: j.z0,
        z1: min(j.z1, l.maxZoom),
      ),
    );
  }

  return RouteSaveJobs(
    tiles: tiles,
    roadWindows: roads,
    trailWindows: trails,
    bounds: routeBounds(all, max(driveTileBufferM, hikeBuf)),
    notes: notes,
  );
}

/// The saved routes (one file); each belongs to an offline area.
class SavedRoutes extends ChangeNotifier {
  SavedRoutes(this.file);
  final File file;
  final List<SavedRoute> _all = [];

  List<SavedRoute> get all => List.unmodifiable(_all);
  SavedRoute? byId(String id) => _all.where((r) => r.id == id).firstOrNull;

  Future<void> load() async {
    _all.clear();
    try {
      if (await file.exists()) {
        for (final j in jsonDecode(await file.readAsString()) as List) {
          final r = SavedRoute.fromJson(j);
          if (r != null && r.id.isNotEmpty) _all.add(r);
        }
      }
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode([for (final r in _all) r.toJson()]));
    } catch (_) {}
  }

  Future<void> put(SavedRoute r) async {
    _all.removeWhere((x) => x.id == r.id);
    _all.add(r);
    await save();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    final n = _all.length;
    _all.removeWhere((x) => x.id == id);
    if (_all.length != n) {
      await save();
      notifyListeners();
    }
  }

  /// Forget routes whose offline area is gone.
  Future<void> prune(Set<String> areaIds) async {
    final n = _all.length;
    _all.removeWhere((x) => !areaIds.contains(x.id));
    if (_all.length != n) await save();
  }
}
