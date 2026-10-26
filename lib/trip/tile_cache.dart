import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'geo.dart';

/// A raster map source.
class MapSource {
  const MapSource({
    required this.id,
    required this.name,
    required this.urlTemplate,
    required this.attribution,
    this.subdomains = const [],
    this.maxZoom = 18,
    this.allowsOffline = false,
    this.avgTileBytes = 20000,
  });
  final String id;
  final String name;
  final String urlTemplate;
  final String attribution;
  final List<String> subdomains;
  final int maxZoom;

  /// Whether "Download area" may use it. tile.openstreetmap.org forbids
  /// offline / prefetch use, so only the topo map and a custom server do.
  final bool allowsOffline;

  /// For the size estimate before a download.
  final int avgTileBytes;

  /// Topographic map: contour lines and trails, good for hiking. Small
  /// areas may be saved for offline use (rate limited, capped).
  static const topo = MapSource(
    id: 'topo',
    name: 'Topo (OpenTopoMap)',
    urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    subdomains: ['a', 'b', 'c'],
    attribution:
        'Map data: © OpenStreetMap contributors, SRTM | '
        'Map style: © OpenTopoMap (CC-BY-SA)',
    maxZoom: 17,
    allowsOffline: true,
    avgTileBytes: 30000,
  );

  /// Standard OpenStreetMap: viewing only (cached as you look around, never
  /// downloaded ahead, per the OSM tile usage policy).
  static const osm = MapSource(
    id: 'osm',
    name: 'Street (OpenStreetMap)',
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    attribution: '© OpenStreetMap contributors',
    maxZoom: 19,
    allowsOffline: false,
    avgTileBytes: 15000,
  );

  /// Your own tile server (e.g. on a Synology), any {z}/{x}/{y} URL.
  static MapSource custom(String url) => MapSource(
    id: 'custom',
    name: 'Custom server',
    urlTemplate: url,
    attribution: 'Map tiles: your server, data © OpenStreetMap contributors',
    maxZoom: 18,
    allowsOffline: true,
  );

  String urlFor(int z, int x, int y) {
    var u = urlTemplate
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
    if (subdomains.isNotEmpty) {
      u = u.replaceAll('{s}', subdomains[(x + y) % subdomains.length]);
    }
    return u;
  }
}

/// Slippy-map tile maths.
int tileX(double lng, int z) =>
    ((lng + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);

int tileY(double lat, int z) {
  final r = lat.clamp(-85.0511, 85.0511) * pi / 180;
  final n = 1 << z;
  return ((1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * n).floor().clamp(0, n - 1);
}

/// A rectangle of the map.
class GeoBounds {
  const GeoBounds(this.south, this.west, this.north, this.east);
  final double south, west, north, east;

  bool contains(GeoPoint p) =>
      p.lat >= south && p.lat <= north && p.lng >= west && p.lng <= east;

  Map<String, Object?> toJson() => {
    's': south,
    'w': west,
    'n': north,
    'e': east,
  };
  static GeoBounds? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return GeoBounds(
        (j['s'] as num).toDouble(),
        (j['w'] as num).toDouble(),
        (j['n'] as num).toDouble(),
        (j['e'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  GeoPoint get center => GeoPoint((south + north) / 2, (west + east) / 2);
}

typedef TileId = ({int z, int x, int y});

/// Every tile covering [b] from [minZoom] to [maxZoom].
Iterable<TileId> tilesIn(GeoBounds b, int minZoom, int maxZoom) sync* {
  for (var z = minZoom; z <= maxZoom; z++) {
    final x0 = tileX(b.west, z), x1 = tileX(b.east, z);
    final y0 = tileY(b.north, z), y1 = tileY(b.south, z);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        yield (z: z, x: x, y: y);
      }
    }
  }
}

int countTiles(GeoBounds b, int minZoom, int maxZoom) {
  var n = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final w = tileX(b.east, z) - tileX(b.west, z) + 1;
    final h = tileY(b.south, z) - tileY(b.north, z) + 1;
    n += w * h;
  }
  return n;
}

/// A saved offline area.
class OfflineRegion {
  OfflineRegion({
    required this.name,
    required this.sourceId,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.tiles,
    required this.bytes,
    required this.at,
  });
  final String name;
  final String sourceId;
  final GeoBounds bounds;
  final int minZoom;
  final int maxZoom;
  int tiles;
  int bytes;
  final DateTime at;

  bool covers(String source, int z, int x, int y) {
    if (source != sourceId || z < minZoom || z > maxZoom) return false;
    return x >= tileX(bounds.west, z) &&
        x <= tileX(bounds.east, z) &&
        y >= tileY(bounds.north, z) &&
        y <= tileY(bounds.south, z);
  }

  Map<String, Object?> toJson() => {
    'n': name,
    'src': sourceId,
    'b': bounds.toJson(),
    'z0': minZoom,
    'z1': maxZoom,
    't': tiles,
    'by': bytes,
    'at': at.millisecondsSinceEpoch,
  };

  static OfflineRegion? fromJson(Object? j) {
    if (j is! Map) return null;
    final b = GeoBounds.fromJson(j['b']);
    if (b == null) return null;
    try {
      return OfflineRegion(
        name: j['n'] as String,
        sourceId: j['src'] as String,
        bounds: b,
        minZoom: (j['z0'] as num).toInt(),
        maxZoom: (j['z1'] as num).toInt(),
        tiles: (j['t'] as num).toInt(),
        bytes: (j['by'] as num).toInt(),
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Progress of an area download.
class DownloadProgress {
  DownloadProgress(this.total);
  final int total;
  int done = 0;
  int failed = 0;
  int bytes = 0;
  bool cancelled = false;
  bool finished = false;
  double get fraction => total == 0 ? 1 : (done + failed) / total;
}

/// Map tiles on the phone: what you looked at (kept at least
/// [minFresh], refreshed with conditional requests when online) and saved
/// offline areas, under [maxBytes] in all.
class TileCache {
  TileCache(
    this.dir, {
    required this.userAgent,
    this.maxBytes = 500 * 1024 * 1024,
    this.minFresh = const Duration(days: 7),
    this.maxDownloadTiles = 3000,
  });

  final Directory dir;
  final String userAgent;
  int maxBytes;
  final Duration minFresh;

  /// Most tiles one "Download area" may fetch (keeps it polite to the free
  /// tile servers and the phone's storage).
  final int maxDownloadTiles;

  /// False = never use the network (tests, airplane mode).
  bool online = true;

  final List<OfflineRegion> regions = [];
  HttpClient? _client;
  HttpClient get _http => _client ??= (HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = 2
    ..userAgent = userAgent);

  File _file(String src, int z, int x, int y) =>
      File('${dir.path}/$src/$z/$x/$y.png');
  File _meta(String src, int z, int x, int y) =>
      File('${dir.path}/$src/$z/$x/$y.meta');
  File get _regionsFile => File('${dir.path}/regions.json');

  Future<void> load() async {
    try {
      if (!await _regionsFile.exists()) return;
      final j = jsonDecode(await _regionsFile.readAsString()) as List;
      regions
        ..clear()
        ..addAll([
          for (final r in j)
            if (OfflineRegion.fromJson(r) != null) OfflineRegion.fromJson(r)!,
        ]);
    } catch (_) {}
  }

  Future<void> _saveRegions() async {
    try {
      await dir.create(recursive: true);
      await _regionsFile.writeAsString(
        jsonEncode([for (final r in regions) r.toJson()]),
      );
    } catch (_) {}
  }

  bool inRegion(String src, int z, int x, int y) =>
      regions.any((r) => r.covers(src, z, x, y));

  /// Tile bytes: from the phone if fresh (or if offline), else downloaded.
  Future<Uint8List?> get(MapSource s, int z, int x, int y) async {
    final f = _file(s.id, z, x, y);
    Uint8List? cached;
    DateTime? mtime;
    try {
      if (await f.exists()) {
        cached = await f.readAsBytes();
        mtime = await f.lastModified();
      }
    } catch (_) {}
    final fresh = mtime != null && DateTime.now().difference(mtime) < minFresh;
    if (cached != null && (fresh || !online)) return cached;
    if (!online) return null;
    final got = await _fetch(s, z, x, y, conditional: cached != null);
    if (got == null) return cached; // offline / error: stale is fine
    if (got.isEmpty && cached != null) {
      // 304 Not Modified: keep, mark fresh.
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
      return cached;
    }
    return got.isEmpty ? cached : got;
  }

  /// Downloads one tile and stores it. Empty list = not modified, null =
  /// failed.
  Future<Uint8List?> _fetch(
    MapSource s,
    int z,
    int x,
    int y, {
    bool conditional = false,
  }) async {
    try {
      final req = await _http.getUrl(Uri.parse(s.urlFor(z, x, y)));
      if (conditional) {
        try {
          final m = _meta(s.id, z, x, y);
          if (await m.exists()) {
            final j = jsonDecode(await m.readAsString()) as Map;
            if (j['etag'] is String) {
              req.headers.set(HttpHeaders.ifNoneMatchHeader, j['etag']);
            }
            if (j['lm'] is String) {
              req.headers.set(HttpHeaders.ifModifiedSinceHeader, j['lm']);
            }
          }
        } catch (_) {}
      }
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode == 304) {
        await res.drain<void>();
        return Uint8List(0);
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final b = BytesBuilder(copy: false);
      await for (final c in res) {
        b.add(c);
      }
      final bytes = b.takeBytes();
      if (bytes.isEmpty) return null;
      final f = _file(s.id, z, x, y);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: false);
      final etag = res.headers.value(HttpHeaders.etagHeader);
      final lm = res.headers.value(HttpHeaders.lastModifiedHeader);
      if (etag != null || lm != null) {
        await _meta(
          s.id,
          z,
          x,
          y,
        ).writeAsString(jsonEncode({'etag': ?etag, 'lm': ?lm}));
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Size estimate for an area before downloading.
  ({int tiles, int bytes}) estimate(
    MapSource s,
    GeoBounds b,
    int minZoom,
    int maxZoom,
  ) {
    final n = countTiles(b, minZoom, maxZoom);
    return (tiles: n, bytes: n * s.avgTileBytes);
  }

  /// Save an area for offline use. Throws [StateError] if the source does
  /// not allow it or the area is too big. Polite: 2 at a time with a short
  /// pause, tiles already on the phone are skipped.
  Future<OfflineRegion> download(
    MapSource s,
    GeoBounds b,
    int minZoom,
    int maxZoom, {
    required String name,
    DownloadProgress? progress,
    void Function(DownloadProgress p)? onProgress,
    Duration pause = const Duration(milliseconds: 150),
  }) async {
    if (!s.allowsOffline) {
      throw StateError('${s.name} does not allow offline downloads');
    }
    final maxZ = min(maxZoom, s.maxZoom);
    final n = countTiles(b, minZoom, maxZ);
    if (n > maxDownloadTiles) {
      throw StateError(
        'Area too big: $n tiles (limit $maxDownloadTiles). Zoom in or '
        'lower the detail.',
      );
    }
    final p = progress ?? DownloadProgress(n);
    final region = OfflineRegion(
      name: name,
      sourceId: s.id,
      bounds: b,
      minZoom: minZoom,
      maxZoom: maxZ,
      tiles: 0,
      bytes: 0,
      at: DateTime.now(),
    );
    final it = tilesIn(b, minZoom, maxZ).iterator;
    Future<void> worker() async {
      while (!p.cancelled) {
        TileId t;
        if (!it.moveNext()) return;
        t = it.current;
        final f = _file(s.id, t.z, t.x, t.y);
        var ok = false;
        try {
          if (await f.exists()) {
            p.bytes += await f.length();
            ok = true;
          }
        } catch (_) {}
        if (!ok) {
          final got = await _fetch(s, t.z, t.x, t.y);
          if (got != null && got.isNotEmpty) {
            p.bytes += got.length;
            ok = true;
          }
          await Future<void>.delayed(pause);
        }
        if (ok) {
          p.done++;
        } else {
          p.failed++;
        }
        onProgress?.call(p);
      }
    }

    await Future.wait([worker(), worker()]);
    p.finished = true;
    onProgress?.call(p);
    region
      ..tiles = p.done
      ..bytes = p.bytes;
    if (!p.cancelled && p.done > 0) {
      regions.add(region);
      await _saveRegions();
    }
    return region;
  }

  Future<void> deleteRegion(OfflineRegion r) async {
    regions.remove(r);
    await _saveRegions();
    // Remove its tiles unless another region still covers them.
    for (final t in tilesIn(r.bounds, r.minZoom, r.maxZoom)) {
      if (inRegion(r.sourceId, t.z, t.x, t.y)) continue;
      try {
        await _file(r.sourceId, t.z, t.x, t.y).delete();
      } catch (_) {}
    }
  }

  /// Total bytes of every tile on the phone.
  Future<int> sizeOnDisk() async {
    var n = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File && e.path.endsWith('.png')) n += await e.length();
      }
    } catch (_) {}
    return n;
  }

  /// Delete viewed tiles (oldest first) until under [maxBytes]; saved
  /// areas are kept.
  Future<void> trim() async {
    final files = <(File, DateTime, int, bool)>[];
    var total = 0;
    try {
      if (!await dir.exists()) return;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File || !e.path.endsWith('.png')) continue;
        final st = await e.stat();
        total += st.size;
        final parts = e.path.substring(dir.path.length + 1).split('/');
        var keep = false;
        if (parts.length == 4) {
          final z = int.tryParse(parts[1]), x = int.tryParse(parts[2]);
          final y = int.tryParse(parts[3].split('.').first);
          if (z != null && x != null && y != null) {
            keep = inRegion(parts[0], z, x, y);
          }
        }
        files.add((e, st.modified, st.size, keep));
      }
    } catch (_) {
      return;
    }
    if (total <= maxBytes) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final f in files) {
      if (total <= maxBytes) break;
      if (f.$4) continue;
      try {
        await f.$1.delete();
        total -= f.$3;
      } catch (_) {}
    }
  }

  /// Delete every tile and saved area.
  Future<void> clear() async {
    regions.clear();
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
