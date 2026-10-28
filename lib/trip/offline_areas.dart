import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'imports/map_layers.dart';
import 'imports/map_packs.dart' show layerBounds, unionBounds;
import 'route_save.dart' show SavedRoute;
import 'tile_cache.dart';

/// One saved offline area (v1.9.3): the map tiles (any styles), trails
/// and road data of a box on the map, saved, updated, renamed and deleted
/// together.
class OfflineArea {
  OfflineArea({
    required this.id,
    required this.name,
    required this.bounds,
    required this.at,
    this.styles = const [],
    this.minZoom = 0,
    this.maxZoom = 0,
    this.roads = false,
    this.trails = false,
  });

  final String id;
  String name;
  GeoBounds bounds;
  DateTime at;

  /// Map styles chosen ([MapSource] ids) and their zooms.
  List<String> styles;
  int minZoom, maxZoom;

  /// Roads for offline driving / trails were asked for.
  bool roads, trails;

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    'b': bounds.toJson(),
    'at': at.millisecondsSinceEpoch,
    's': styles,
    'z0': minZoom,
    'z1': maxZoom,
    'r': roads,
    't': trails,
  };

  static OfflineArea? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = GeoBounds.fromJson(j['b']);
    final id = j['id'];
    if (b == null || id is! String) return null;
    try {
      return OfflineArea(
        id: id,
        name: (j['n'] as String?) ?? 'Offline area',
        bounds: b,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
        styles: [for (final s in (j['s'] as List? ?? const [])) '$s'],
        minZoom: (j['z0'] as num?)?.toInt() ?? 0,
        maxZoom: (j['z1'] as num?)?.toInt() ?? 0,
        roads: j['r'] == true,
        trails: j['t'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A row of the "Offline areas" list: a saved area, or a ready-made pack.
class AreaEntry {
  AreaEntry({
    required this.id,
    required this.name,
    required this.bounds,
    required this.regions,
    required this.layers,
    this.area,
    this.pack,
    this.route,
  });

  /// v2.2.0: set when this item is a route saved for offline.
  final SavedRoute? route;
  bool get isRoute => route != null;

  /// [OfflineArea.id], or `pack:<id>`.
  final String id;
  final String name;
  final GeoBounds? bounds;
  final OfflineArea? area;

  /// Ready-made pack id.
  final String? pack;
  final List<OfflineRegion> regions;
  final List<MapLayer> layers;

  bool get isPack => pack != null;
  int get bytes =>
      regions.fold(0, (s, r) => s + r.bytes) +
      layers.fold(0, (s, l) => s + l.bytes);

  List<MapLayer> get roadLayers =>
      layers.where((l) => l.kind == MapLayerKind.roads).toList();
  List<MapLayer> get trailLayers =>
      layers.where((l) => l.kind == MapLayerKind.trail).toList();
  List<MapLayer> get mapLayers => layers
      .where(
        (l) => l.kind == MapLayerKind.tiles || l.kind == MapLayerKind.overlay,
      )
      .toList();

  bool get hasRoads => roadLayers.isNotEmpty;

  /// "Map: USGS Topo, Elevation data (zoom 10-15) · Roads · Trails".
  List<String> get parts {
    final out = <String>[];
    final styles = <String>[];
    for (final r in regions) {
      final n = MapSource.byId(r.sourceId)?.name ?? r.sourceId;
      if (!styles.contains(n)) styles.add(n);
    }
    if (styles.isNotEmpty) {
      final z0 = regions.map((r) => r.minZoom).reduce(min);
      final z1 = regions.map((r) => r.maxZoom).reduce(max);
      out.add('Map: ${styles.join(', ')} (zoom $z0-$z1)');
    }
    for (final l in mapLayers) {
      out.add('Map: ${l.name}');
    }
    if (hasRoads) {
      final s = roadLayers.map((l) => l.summary).where((s) => s.isNotEmpty);
      out.add('Roads${s.isEmpty ? '' : ' (${s.join(', ')})'}');
    }
    if (trailLayers.isNotEmpty) {
      out.add(
        trailLayers.length == 1 && trailLayers.first.summary.isNotEmpty
            ? 'Trails (${trailLayers.first.summary})'
            : 'Trails',
      );
    }
    return out;
  }
}

/// Two boxes are about the same place (duplicate check).
bool sameArea(GeoBounds a, GeoBounds b) {
  final h = max(a.north - a.south, b.north - b.south);
  final w = max(a.east - a.west, b.east - b.west);
  final tol = max(0.005, 0.1 * max(h, w));
  return (a.south - b.south).abs() <= tol &&
      (a.north - b.north).abs() <= tol &&
      (a.west - b.west).abs() <= tol &&
      (a.east - b.east).abs() <= tol;
}

/// The saved offline areas, joined from the tile cache's regions and the
/// map layers that belong to each area; ready-made packs are listed too.
class OfflineAreas extends ChangeNotifier {
  OfflineAreas(
    this.file, {
    required this.tiles,
    required this.layers,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final File file;
  final TileCache tiles;
  final MapLayers layers;
  final DateTime Function() _clock;
  final List<OfflineArea> _areas = [];
  int _seq = 0;

  /// v2.2.0: the saved route of an area (set by the Trip controller).
  SavedRoute? Function(String areaId)? routeFor;

  /// Pack id -> its name (from the pack list), for the rows of packs.
  Map<String, String> packNames = {};

  List<OfflineArea> get areas => List.unmodifiable(_areas);
  OfflineArea? byId(String id) => _areas.where((a) => a.id == id).firstOrNull;

  String newId() =>
      'a${_clock().millisecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

  Future<void> load() async {
    _areas.clear();
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString()) as List;
        for (final a in j) {
          final x = OfflineArea.fromJson(a);
          if (x != null) _areas.add(x);
        }
      }
    } catch (_) {}
    await migrate();
    notifyListeners();
  }

  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode([for (final a in _areas) a.toJson()]),
      );
    } catch (_) {}
  }

  /// Older saves (v1.9.1 map tiles, v1.9.2 offline roads) become areas:
  /// tile regions saved together (same name and box) are one area; a road
  /// area joins a map area of the same place, else is its own area.
  /// Returns how many areas were made.
  Future<int> migrate() async {
    var made = 0;
    var tilesChanged = false;
    for (final r in tiles.regions) {
      if (r.areaId != null && byId(r.areaId!) != null) continue;
      var a = _areas
          .where((a) => a.name == r.name && sameArea(a.bounds, r.bounds))
          .firstOrNull;
      if (a == null) {
        a = OfflineArea(
          id: newId(),
          name: r.name,
          bounds: r.bounds,
          at: r.at,
          minZoom: r.minZoom,
          maxZoom: r.maxZoom,
        );
        _areas.add(a);
        made++;
      }
      if (r.sourceId != MapSource.terrarium.id &&
          !a.styles.contains(r.sourceId)) {
        a.styles = [...a.styles, r.sourceId];
      }
      a.minZoom = a.minZoom == 0 ? r.minZoom : min(a.minZoom, r.minZoom);
      a.maxZoom = max(a.maxZoom, r.maxZoom);
      r.areaId = a.id;
      tilesChanged = true;
    }
    for (final l in layers.roads) {
      if (l.pack != null) continue;
      if (l.offlineArea != null && byId(l.offlineArea!) != null) continue;
      final b = l.area;
      if (b == null) continue;
      var a = _areas.where((a) => sameArea(a.bounds, b)).firstOrNull;
      if (a == null) {
        a = OfflineArea(id: newId(), name: l.name, bounds: b, at: l.added);
        _areas.add(a);
        made++;
      }
      a.roads = true;
      await layers.tagArea(l, a.id);
    }
    // Areas left with nothing in them (deleted elsewhere).
    _areas.removeWhere(
      (a) =>
          routeFor?.call(a.id) == null &&
          !tiles.regions.any((r) => r.areaId == a.id) &&
          !layers.all.any((l) => l.offlineArea == a.id),
    );
    if (tilesChanged) await tiles.saveRegions();
    await save();
    return made;
  }

  /// Everything saved, newest first; ready-made packs after.
  List<AreaEntry> get entries {
    final out = <AreaEntry>[
      for (final a in _areas.reversed)
        AreaEntry(
          id: a.id,
          name: a.name,
          bounds: a.bounds,
          area: a,
          route: routeFor?.call(a.id),
          regions: tiles.regions.where((r) => r.areaId == a.id).toList(),
          layers: layers.all.where((l) => l.offlineArea == a.id).toList(),
        ),
    ];
    final packs = <String>[];
    for (final l in layers.all) {
      final p = l.pack;
      if (p != null && !packs.contains(p)) packs.add(p);
    }
    for (final p in packs) {
      final ls = layers.all.where((l) => l.pack == p).toList();
      out.add(
        AreaEntry(
          id: 'pack:$p',
          name: packNames[p] ?? ls.first.name,
          bounds: unionBounds([for (final l in ls) layerBounds(layers, l)]),
          pack: p,
          regions: const [],
          layers: ls,
        ),
      );
    }
    return out;
  }

  AreaEntry? entry(String id) => entries.where((e) => e.id == id).firstOrNull;

  /// A saved area of (about) the same place: the duplicate check.
  AreaEntry? similar(GeoBounds b, {String? except}) => entries
      .where(
        (e) =>
            !e.isPack &&
            e.id != except &&
            e.bounds != null &&
            sameArea(e.bounds!, b),
      )
      .firstOrNull;

  Future<OfflineArea> create(
    String name,
    GeoBounds bounds, {
    List<String> styles = const [],
    int minZoom = 0,
    int maxZoom = 0,
    bool roads = false,
    bool trails = false,
  }) async {
    final a = OfflineArea(
      id: newId(),
      name: name,
      bounds: bounds,
      at: _clock(),
      styles: styles,
      minZoom: minZoom,
      maxZoom: maxZoom,
      roads: roads,
      trails: trails,
    );
    _areas.add(a);
    await save();
    notifyListeners();
    return a;
  }

  Future<void> touch(OfflineArea a) async {
    a.at = _clock();
    await save();
    notifyListeners();
  }

  /// Rename the area and what is in it.
  Future<void> rename(AreaEntry e, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final a = e.area;
    if (a != null) {
      a.name = n;
      await save();
      for (final l in e.layers) {
        await layers.rename(
          l,
          l.kind == MapLayerKind.roads
              ? '$n roads'
              : (l.kind == MapLayerKind.trail ? '$n trails' : n),
        );
      }
    } else {
      packNames[e.pack!] = n;
      for (final l in e.layers.where((l) => l.kind == MapLayerKind.roads)) {
        await layers.rename(l, n);
      }
    }
    notifyListeners();
  }

  /// Delete everything in the area (tiles, roads, trails, pack files).
  Future<void> delete(AreaEntry e) async {
    for (final r in List.of(e.regions)) {
      await tiles.deleteRegion(r);
    }
    for (final l in List.of(e.layers)) {
      await layers.delete(l);
    }
    final a = e.area;
    if (a != null) {
      _areas.remove(a);
      await save();
    }
    notifyListeners();
  }
}

/// What "Save this area offline" saves.
class AreaSaveOptions {
  const AreaSaveOptions({
    required this.bounds,
    required this.name,
    this.styles = const [MapSource.topo],
    this.minZoom = 10,
    this.maxZoom = 15,
    this.elevation = true,
    this.roads = true,
    this.trails = true,
  });
  final GeoBounds bounds;
  final String name;

  /// Map styles to save (base maps and overlays that allow it).
  final List<MapSource> styles;
  final int minZoom, maxZoom;

  /// Elevation data (profiles; slope shading when chosen).
  final bool elevation;
  final bool roads, trails;
}

/// Tile downloads for [o]: each style within its zooms, and elevation.
List<({MapSource src, int z0, int z1})> areaTileJobs(AreaSaveOptions o) {
  final out = <({MapSource src, int z0, int z1})>[];
  final z0 = o.minZoom, z1 = o.maxZoom;
  var slope = false;
  for (final s in o.styles) {
    if (!s.allowsOffline || s.onlineOnly) continue;
    if (s.id == MapSource.slope.id) {
      slope = true; // drawn from the elevation data
      continue;
    }
    final a = max(z0, s.minZoom), b = min(z1, s.maxZoom);
    if (a <= b && !out.any((j) => j.src.id == s.id)) {
      out.add((src: s, z0: a, z1: b));
    }
  }
  if (o.elevation || slope) {
    final dz1 = slope ? min(z1, MapSource.slope.maxZoom) : 12;
    final dz0 = slope ? max(MapSource.slope.minZoom, min(z0, 12)) : 12;
    out.add((src: MapSource.terrarium, z0: min(dz0, dz1), z1: dz1));
  }
  return out;
}

/// The road data of [b] in pieces small enough to save (1 square degree
/// each, at most [maxPieces]); null = too big for roads.
List<GeoBounds>? roadPieces(
  GeoBounds b, {
  double maxSqDeg = 1.0,
  int maxPieces = 4,
}) {
  final h = b.north - b.south, w = b.east - b.west;
  if (h <= 0 || w <= 0) return null;
  if (h * w <= maxSqDeg) return [b];
  final side = sqrt(maxSqDeg);
  final ny = (h / side).ceil(), nx = (w / side).ceil();
  if (nx * ny > maxPieces) return null;
  final dy = h / ny, dx = w / nx;
  return [
    for (var y = 0; y < ny; y++)
      for (var x = 0; x < nx; x++)
        GeoBounds(
          b.south + y * dy,
          b.west + x * dx,
          b.south + (y + 1) * dy,
          b.west + (x + 1) * dx,
        ),
  ];
}

/// Size before saving: tiles (known now), roads (asked from the server).
class AreaEstimate {
  const AreaEstimate({
    required this.tiles,
    required this.tileBytes,
    this.roadBytes,
    this.tooBig,
  });
  final int tiles, tileBytes;

  /// Null = not known (yet, or no signal).
  final int? roadBytes;

  /// Why the map part cannot be saved, if so.
  final String? tooBig;
  int get bytes => tileBytes + (roadBytes ?? 0);
}

class AreaSaveProgress {
  const AreaSaveProgress(this.step, this.stepNo, this.steps, this.fraction);
  final String step;
  final int stepNo, steps;
  final double? fraction;
}

class AreaSaveResult {
  const AreaSaveResult(this.entry, this.problems, {this.cancelled = false});
  final AreaEntry? entry;

  /// Parts that could not be saved (the rest was).
  final List<String> problems;
  final bool cancelled;
}

/// How saving a route for offline went (v2.2.0).
class RouteSaveResult {
  const RouteSaveResult(
    this.entry,
    this.route,
    this.problems, {
    this.cancelled = false,
  });
  final AreaEntry? entry;
  final SavedRoute route;
  final List<String> problems;
  final bool cancelled;

  /// Everything was saved.
  bool get complete => route.isReady && !cancelled;
}
