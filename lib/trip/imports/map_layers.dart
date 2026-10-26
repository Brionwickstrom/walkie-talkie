import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../geo.dart';
import '../search/offline_search.dart';
import 'geo_import.dart';
import 'georef.dart';
import 'mbtiles.dart';

/// Imported map layers on the Trip tab (v1.8.3): trails / routes / pins
/// from GPX, KML, KMZ (or shared by someone), offline MBTiles base maps,
/// and georeferenced image / PDF park maps. Kept on the device under the
/// trip folder with an index file.
enum MapLayerKind { trail, tiles, overlay }

/// Palette for imported lines (ARGB).
const List<int> layerColors = [
  0xFF1E88E5, // blue
  0xFFE53935, // red
  0xFF43A047, // green
  0xFFFB8C00, // orange
  0xFF8E24AA, // purple
  0xFF00ACC1, // cyan
  0xFF6D4C41, // brown
  0xFF212121, // black
];

class MapLayer {
  MapLayer({
    required this.id,
    required this.kind,
    required this.name,
    required this.file,
    required this.bytes,
    this.visible = true,
    this.color = 0xFF1E88E5,
    this.opacity = 0.7,
    this.georef,
    this.imageW = 0,
    this.imageH = 0,
    this.from,
    this.sourceBytes = 0,
    this.summary = '',
    this.attribution = '',
    DateTime? added,
  }) : added = added ?? DateTime.now();

  final String id;
  final MapLayerKind kind;
  String name;

  /// File name inside the layers folder.
  final String file;

  /// Bytes used on the device.
  final int bytes;

  /// Size of the file as imported (before conversion).
  final int sourceBytes;
  bool visible;
  int color;

  /// Overlay opacity 0.1 .. 1.
  double opacity;

  /// Overlay placement (null = not placed yet).
  Georef? georef;
  final int imageW, imageH;

  /// Shared by this phone id (null = imported here).
  final int? from;

  /// e.g. "2 tracks · 14 waypoints · 12.4 km" or "z10-16 · 1830 tiles".
  String summary;

  /// Data licence to show with the layer (e.g. OpenStreetMap ODbL for
  /// trails from map search).
  final String attribution;
  final DateTime added;

  /// Parsed lines / waypoints (trail layers, loaded on demand).
  ImportedData? data;

  bool get placed => georef != null;

  Map<String, Object?> toJson() => {
    'id': id,
    'k': kind.name,
    'n': name,
    'f': file,
    'b': bytes,
    'sb': sourceBytes,
    'v': visible,
    'c': color,
    'o': opacity,
    if (georef != null) 'g': georef!.toJson(),
    'w': imageW,
    'h': imageH,
    'from': ?from,
    's': summary,
    if (attribution.isNotEmpty) 'at': attribution,
    'a': added.millisecondsSinceEpoch,
  };

  static MapLayer? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = MapLayerKind.values.where((k) => k.name == j['k']).firstOrNull;
    final id = j['id'], file = j['f'];
    if (kind == null || id is! String || file is! String) return null;
    if (file.contains('/') || file.contains('\\') || file.contains('..')) {
      return null;
    }
    return MapLayer(
      id: id,
      kind: kind,
      name: (j['n'] as String?) ?? '',
      file: file,
      bytes: (j['b'] as num?)?.toInt() ?? 0,
      sourceBytes: (j['sb'] as num?)?.toInt() ?? 0,
      visible: j['v'] != false,
      color: (j['c'] as num?)?.toInt() ?? layerColors.first,
      opacity: ((j['o'] as num?)?.toDouble() ?? 0.7).clamp(0.1, 1.0),
      georef: Georef.fromJson(j['g']),
      imageW: (j['w'] as num?)?.toInt() ?? 0,
      imageH: (j['h'] as num?)?.toInt() ?? 0,
      from: (j['from'] as num?)?.toInt(),
      summary: (j['s'] as String?) ?? '',
      attribution: (j['at'] as String?) ?? '',
      added: DateTime.fromMillisecondsSinceEpoch(
        (j['a'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

class StorageLimitException implements Exception {
  StorageLimitException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// "12.4 MB"
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// Width and height of a PNG, JPEG or WebP from its header (no decoding).
({int w, int h})? imageSize(Uint8List b) {
  try {
    final bd = ByteData.sublistView(b);
    // PNG: IHDR at 16.
    if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {
      return (w: bd.getUint32(16), h: bd.getUint32(20));
    }
    // JPEG: walk segments to a SOFn.
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var o = 2;
      while (o + 9 < b.length) {
        if (b[o] != 0xFF) return null;
        final m = b[o + 1];
        if (m == 0xFF) {
          o++;
          continue;
        }
        final len = bd.getUint16(o + 2);
        final sof =
            m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;
        if (sof) return (w: bd.getUint16(o + 7), h: bd.getUint16(o + 5));
        o += 2 + len;
      }
      return null;
    }
    // WebP.
    if (b.length > 30 &&
        ascii.decode(b.sublist(0, 4)) == 'RIFF' &&
        ascii.decode(b.sublist(8, 12)) == 'WEBP') {
      final chunk = ascii.decode(b.sublist(12, 16));
      if (chunk == 'VP8X') {
        final w = 1 + (b[24] | b[25] << 8 | b[26] << 16);
        final h = 1 + (b[27] | b[28] << 8 | b[29] << 16);
        return (w: w, h: h);
      }
      if (chunk == 'VP8 ') {
        return (
          w: bd.getUint16(26, Endian.little) & 0x3FFF,
          h: bd.getUint16(28, Endian.little) & 0x3FFF,
        );
      }
      if (chunk == 'VP8L') {
        final v = bd.getUint32(21, Endian.little);
        return (w: 1 + (v & 0x3FFF), h: 1 + ((v >> 14) & 0x3FFF));
      }
    }
  } catch (_) {}
  return null;
}

class MapLayers extends ChangeNotifier {
  MapLayers(
    this.dir, {
    this.limitBytes = defaultLimit,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Directory dir;

  /// Total storage for imported layers.
  int limitBytes;
  final DateTime Function() _clock;

  static const int defaultLimit = 2 * 1024 * 1024 * 1024; // 2 GB
  static const int maxMbtilesBytes = 1536 * 1024 * 1024; // 1.5 GB
  static const int maxImageBytes = 40 * 1024 * 1024;
  static const int maxPdfBytes = 60 * 1024 * 1024;
  static const int maxImagePixels = 8192;

  final List<MapLayer> _layers = [];
  final Map<String, MbTiles> _open = {};

  /// Offline search over imported trails and places (v1.8.4), kept up to
  /// date on import, load, rename and delete.
  final SearchIndex index = SearchIndex();
  int _seq = 0;

  List<MapLayer> get all => List.unmodifiable(_layers);
  List<MapLayer> get trails =>
      _layers.where((l) => l.kind == MapLayerKind.trail).toList();
  List<MapLayer> get tileSets =>
      _layers.where((l) => l.kind == MapLayerKind.tiles).toList();
  List<MapLayer> get overlays =>
      _layers.where((l) => l.kind == MapLayerKind.overlay).toList();
  MapLayer? byId(String id) => _layers.where((l) => l.id == id).firstOrNull;

  int get usedBytes => _layers.fold(0, (s, l) => s + l.bytes);
  int get freeBytes => (limitBytes - usedBytes).clamp(0, limitBytes);

  File _f(String name) => File('${dir.path}/$name');
  File get _index => _f('layers.json');

  Future<void> load() async {
    try {
      if (!await _index.exists()) return;
      final j = jsonDecode(await _index.readAsString());
      _layers.clear();
      for (final x in (j as List)) {
        final l = MapLayer.fromJson(x);
        if (l != null && await _f(l.file).exists()) _layers.add(l);
      }
      index.clear();
      for (final l in _layers) {
        if (l.kind == MapLayerKind.trail) await _loadData(l);
        index.indexLayer(l);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await dir.create(recursive: true);
      final tmp = _f('layers.json.tmp');
      await tmp.writeAsString(
        jsonEncode([for (final l in _layers) l.toJson()]),
      );
      await tmp.rename(_index.path);
    } catch (_) {}
  }

  String _newId() =>
      '${_clock().millisecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

  void _ensureRoom(int bytes, String what) {
    if (usedBytes + bytes > limitBytes) {
      throw StorageLimitException(
        'Not enough room for $what (${formatBytes(bytes)}): imported maps use '
        '${formatBytes(usedBytes)} of ${formatBytes(limitBytes)}. '
        'Delete a layer first.',
      );
    }
  }

  // ------------------------------------------------------------ trails

  static String trailSummary(ImportedData d) {
    final tracks = d.lines.where((l) => !l.isRoute).length;
    final routes = d.lines.where((l) => l.isRoute).length;
    final km = d.lines.fold<double>(0, (s, l) => s + pathLengthM(l.points));
    String n(int c, String w) => '$c $w${c == 1 ? '' : 's'}';
    return [
      if (tracks > 0) n(tracks, 'track'),
      if (routes > 0) n(routes, 'route'),
      if (d.waypoints.isNotEmpty) n(d.waypoints.length, 'waypoint'),
      if (km > 0) formatDistance(km, imperial: false),
    ].join(' · ');
  }

  static Map<String, Object?> _dataJson(ImportedData d) => {
    'n': d.name,
    'l': [
      for (final l in d.lines)
        {
          'n': l.name,
          'r': l.isRoute,
          'p': [
            for (final p in l.points) ...[p.latE5, p.lngE5],
          ],
        },
    ],
    'w': [
      for (final w in d.waypoints)
        [
          w.name,
          w.pos.latE5,
          w.pos.lngE5,
          w.description,
          if (w.kind.isNotEmpty) w.kind,
        ],
    ],
  };

  static ImportedData _dataFromJson(Map<String, Object?> j) {
    final d = ImportedData(name: (j['n'] as String?) ?? '');
    for (final l in (j['l'] as List? ?? const [])) {
      final m = l as Map;
      final p = (m['p'] as List).cast<num>();
      d.lines.add(
        ImportedLine((m['n'] as String?) ?? '', [
          for (var i = 0; i + 1 < p.length; i += 2)
            GeoPoint.fromE5(p[i].toInt(), p[i + 1].toInt()),
        ], isRoute: m['r'] == true),
      );
    }
    for (final w in (j['w'] as List? ?? const [])) {
      final v = w as List;
      d.waypoints.add(
        ImportedWaypoint(
          '${v[0]}',
          GeoPoint.fromE5((v[1] as num).toInt(), (v[2] as num).toInt()),
          description: v.length > 3 ? '${v[3]}' : '',
          kind: v.length > 4 ? '${v[4]}' : '',
        ),
      );
    }
    return d;
  }

  Future<void> _loadData(MapLayer l) async {
    try {
      final j = jsonDecode(await _f(l.file).readAsString());
      l.data = _dataFromJson((j as Map).cast<String, Object?>());
    } catch (_) {}
  }

  int _nextColor() => layerColors[trails.length % layerColors.length];

  /// Import a GPX / KML / KMZ file. Throws [ImportFormatException] or
  /// [StorageLimitException].
  Future<MapLayer> importTrail(String fileName, Uint8List bytes) async {
    if (bytes.length > maxTrailFileBytes) {
      throw ImportFormatException(
        'File too big (${formatBytes(bytes.length)}; up to '
        '${formatBytes(maxTrailFileBytes)})',
      );
    }
    final d = bytes.length > 256 * 1024
        ? await Isolate.run(() => tidyImport(parseTrailFile(fileName, bytes)))
        : tidyImport(parseTrailFile(fileName, bytes));
    return addTrail(d, sourceBytes: bytes.length);
  }

  /// Store parsed trail data as a layer (an import or a shared route).
  Future<MapLayer> addTrail(
    ImportedData d, {
    int? color,
    int? from,
    int sourceBytes = 0,
    String attribution = '',
  }) async {
    final json = utf8.encode(jsonEncode(_dataJson(d)));
    _ensureRoom(json.length, d.name.isEmpty ? 'this trail' : d.name);
    final id = _newId();
    final file = 'trail_$id.json';
    await dir.create(recursive: true);
    await _f(file).writeAsBytes(json, flush: true);
    final l = MapLayer(
      id: id,
      kind: MapLayerKind.trail,
      name: d.name.isEmpty ? 'Imported trail' : d.name,
      file: file,
      bytes: json.length,
      sourceBytes: sourceBytes == 0 ? json.length : sourceBytes,
      color: color ?? (d.color ?? _nextColor()),
      from: from,
      summary: trailSummary(d),
      attribution: attribution,
      added: _clock(),
    )..data = d;
    _layers.insert(0, l);
    index.indexLayer(l);
    await _save();
    notifyListeners();
    return l;
  }

  // ------------------------------------------------------------ MBTiles

  /// Copy an MBTiles file in and check it opens. [move] deletes [src]
  /// afterwards (a temporary copy from a share).
  Future<MapLayer> importMbtiles(
    File src, {
    String? name,
    bool move = false,
  }) async {
    final size = await src.length();
    if (size > maxMbtilesBytes) {
      throw StorageLimitException(
        'MBTiles file too big (${formatBytes(size)}; up to '
        '${formatBytes(maxMbtilesBytes)})',
      );
    }
    _ensureRoom(size, 'this map');
    final id = _newId();
    final file = 'tiles_$id.mbtiles';
    await dir.create(recursive: true);
    final dst = _f(file);
    if (move) {
      try {
        await src.rename(dst.path);
      } catch (_) {
        await src.copy(dst.path);
        await src.delete();
      }
    } else {
      await src.copy(dst.path);
    }
    final MbTiles mb;
    try {
      mb = MbTiles.open(dst.path);
    } catch (e) {
      await dst.delete();
      rethrow;
    }
    final n = mb.tileCount;
    if (n == 0) {
      mb.close();
      await dst.delete();
      throw const FormatException('The MBTiles file has no tiles');
    }
    final base = src.uri.pathSegments.isEmpty ? '' : src.uri.pathSegments.last;
    final l = MapLayer(
      id: id,
      kind: MapLayerKind.tiles,
      name: (name ?? (mb.name.isNotEmpty ? mb.name : base)).replaceAll(
        RegExp(r'\.mbtiles$', caseSensitive: false),
        '',
      ),
      file: file,
      bytes: size,
      sourceBytes: size,
      summary:
          'z${mb.minZoom}-${mb.maxZoom} · $n tiles · ${mb.format.toUpperCase()}',
      added: _clock(),
    );
    _open[id] = mb;
    _layers.insert(0, l);
    await _save();
    notifyListeners();
    return l;
  }

  /// Open reader for a tiles layer (cached).
  MbTiles? tilesOf(String id) {
    final o = _open[id];
    if (o != null) return o;
    final l = byId(id);
    if (l == null || l.kind != MapLayerKind.tiles) return null;
    try {
      return _open[id] = MbTiles.open(_f(l.file).path);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ overlays

  /// Import a park map image (PNG / JPEG / WebP; a PDF arrives here as the
  /// PNG of its first page). Not placed until [setGeoref].
  Future<MapLayer> importOverlay(
    String name,
    Uint8List image, {
    int sourceBytes = 0,
    String ext = 'png',
  }) async {
    if (image.length > maxImageBytes) {
      throw StorageLimitException(
        'Image too big (${formatBytes(image.length)}; up to '
        '${formatBytes(maxImageBytes)})',
      );
    }
    final size = imageSize(image);
    if (size == null || size.w <= 0 || size.h <= 0) {
      throw ImportFormatException('Not a PNG, JPEG or WebP image');
    }
    if (size.w > maxImagePixels * 2 || size.h > maxImagePixels * 2) {
      throw ImportFormatException(
        'Image too large (${size.w} x ${size.h} px; up to '
        '${maxImagePixels * 2} px a side)',
      );
    }
    _ensureRoom(image.length, 'this map');
    final id = _newId();
    final e = ext.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    final file = 'overlay_$id.${e.isEmpty ? 'png' : e}';
    await dir.create(recursive: true);
    await _f(file).writeAsBytes(image, flush: true);
    final l = MapLayer(
      id: id,
      kind: MapLayerKind.overlay,
      name: name.isEmpty ? 'Park map' : name,
      file: file,
      bytes: image.length,
      sourceBytes: sourceBytes == 0 ? image.length : sourceBytes,
      imageW: size.w,
      imageH: size.h,
      summary: '${size.w} x ${size.h} px',
      added: _clock(),
    );
    _layers.insert(0, l);
    await _save();
    notifyListeners();
    return l;
  }

  File fileOf(MapLayer l) => _f(l.file);

  // ------------------------------------------------------------ edits

  Future<void> setVisible(MapLayer l, bool v) => _edit(() => l.visible = v);
  Future<void> rename(MapLayer l, String name) => _edit(() {
    l.name = name.trim().isEmpty ? l.name : name.trim();
    index.indexLayer(l);
  });
  Future<void> recolor(MapLayer l, int argb) => _edit(() => l.color = argb);
  Future<void> setOpacity(MapLayer l, double o) =>
      _edit(() => l.opacity = o.clamp(0.1, 1.0));
  Future<void> setGeoref(MapLayer l, Georef? g) => _edit(() {
    l.georef = g;
    if (g != null) l.visible = true;
  });

  Future<void> _edit(void Function() f) async {
    f();
    notifyListeners();
    await _save();
  }

  Future<void> delete(MapLayer l) async {
    _layers.remove(l);
    index.removeLayer(l.id);
    _open.remove(l.id)?.close();
    try {
      await _f(l.file).delete();
    } catch (_) {}
    await _save();
    notifyListeners();
  }

  void close() {
    for (final m in _open.values) {
      m.close();
    }
    _open.clear();
  }
}
