import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../geo.dart';
import '../search/offline_search.dart' show boundsOfPoints;
import '../tile_cache.dart';
import 'georef.dart';
import 'map_layers.dart';

/// Ready-made map packs (v1.9.0): trails, offline topo base maps and
/// pre-placed park maps that download straight from the app's GitHub
/// releases and import themselves (no file picker).
///
/// The list lives in `map_packs.json` at the repo root. A copy is bundled
/// in the APK; the app also fetches the latest from GitHub ([remoteUrl]),
/// so new packs show up without an app update.
enum PackFileKind { trail, tiles, overlay, roads }

class PackFile {
  const PackFile({
    required this.name,
    required this.kind,
    required this.url,
    this.title = '',
    this.asset,
    this.size = 0,
    this.sha256,
    this.attribution = '',
    this.bounds,
    this.opacity = 0.8,
    this.summary = '',
  });

  /// Shown with the added layer ("32,000 km of road").
  final String summary;

  /// File name (also how an added layer is matched to this file).
  final String name;
  final PackFileKind kind;
  final String url;

  /// Layer name, e.g. "Silver Star trails".
  final String title;

  /// Copy bundled in the APK (used instead of downloading).
  final String? asset;
  final int size;
  final String? sha256;
  final String attribution;

  /// Overlay images: the picture is in Web Mercator and covers exactly
  /// this box, so it is placed automatically.
  final GeoBounds? bounds;
  final double opacity;

  static PackFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], url = j['url'];
    final kind = PackFileKind.values
        .where((k) => k.name == j['kind'])
        .firstOrNull;
    if (name is! String || url is! String || kind == null) return null;
    if (name.contains('/') || name.contains('\\') || name.contains('..')) {
      return null;
    }
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'https') return null;
    final asset = j['asset'];
    return PackFile(
      name: name,
      kind: kind,
      url: url,
      title: (j['title'] as String?) ?? '',
      asset:
          asset is String &&
              asset.startsWith('assets/map_packs/') &&
              !asset.contains('..')
          ? asset
          : null,
      size: (j['size'] as num?)?.toInt() ?? 0,
      sha256: (j['sha256'] as String?)?.toLowerCase(),
      attribution: (j['attribution'] as String?) ?? '',
      bounds: GeoBounds.fromJson(j['bounds']),
      opacity: ((j['opacity'] as num?)?.toDouble() ?? 0.8).clamp(0.1, 1.0),
      summary: (j['summary'] as String?) ?? '',
    );
  }

  /// Bytes to download (bundled files download nothing).
  int get downloadSize => asset != null ? 0 : size;
}

class MapPack {
  const MapPack({
    required this.id,
    required this.name,
    required this.files,
    this.area = '',
    this.about = '',
    this.bounds,
    String? short,
  }) : short = short ?? name;

  final String id;
  final String name;

  /// Short name for the "maps are ready" banner ("Silver Star").
  final String short;
  final String area;
  final String about;
  final GeoBounds? bounds;
  final List<PackFile> files;

  int get size => files.fold(0, (s, f) => s + f.size);
  int get downloadSize => files.fold(0, (s, f) => s + f.downloadSize);

  static MapPack? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    if (id is! String || name is! String || id.isEmpty) return null;
    final files = [
      for (final f in (j['files'] as List? ?? const [])) ?PackFile.fromJson(f),
    ];
    if (files.isEmpty) return null;
    return MapPack(
      id: id,
      name: name,
      short: j['short'] is String ? j['short'] as String : null,
      area: (j['area'] as String?) ?? '',
      about: (j['about'] as String?) ?? '',
      bounds: GeoBounds.fromJson(j['bounds']),
      files: files,
    );
  }

  /// Parse a `map_packs.json` document (bad entries are skipped).
  static List<MapPack> parseList(String json) {
    try {
      final j = jsonDecode(json);
      final list = j is Map ? j['packs'] : j;
      if (list is! List) return const [];
      return [for (final p in list) ?MapPack.fromJson(p)];
    } catch (_) {
      return const [];
    }
  }
}

/// Which files of [p] are already on the phone (as layers).
Set<String> addedFiles(MapPack p, MapLayers layers) => {
  for (final l in layers.all)
    if (l.pack == p.id && l.packFile != null) l.packFile!,
};

/// All files of [p] are added.
bool packAdded(MapPack p, MapLayers layers) {
  final have = addedFiles(p, layers);
  return p.files.every((f) => have.contains(f.name));
}

/// Placement for an image in Web Mercator covering exactly [b] (the image
/// is [w] x [h] pixels, north up).
Georef georefForBounds(GeoBounds b, int w, int h) {
  final (x0, y0) = toMercator(GeoPoint(b.north, b.west));
  final (x1, y1) = toMercator(GeoPoint(b.south, b.east));
  return Georef((x1 - x0) / w, 0, x0, 0, (y1 - y0) / h, y0);
}

/// Progress of adding a pack: [done] of [total] bytes, the file in work.
class PackProgress {
  const PackProgress(this.file, this.done, this.total, {this.step = ''});
  final String file;
  final int done, total;

  /// "Downloading", "Checking", "Adding".
  final String step;
  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

class PackException implements Exception {
  PackException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads a URL into [to], reporting received / total bytes.
typedef PackDownloader = Future<void> Function(
  Uri url,
  File to,
  void Function(int got, int? total) onProgress,
);

/// Reads a bundled asset (rootBundle in the app).
typedef AssetReader = Future<Uint8List> Function(String key);

/// Adds packs: downloads (or takes the bundled copy of) each file, checks
/// its SHA-256, imports it as a layer tagged with the pack and places
/// overlay pictures. Files already added are skipped, so a failed or
/// cancelled add can simply be repeated.
class PackInstaller {
  PackInstaller({
    required this.layers,
    required this.tempDir,
    PackDownloader? download,
    this.readAsset,
  }) : _download = download ?? httpDownload;

  final MapLayers layers;
  final Directory tempDir;
  final PackDownloader _download;
  final AssetReader? readAsset;

  /// Files of the last [add] that were already on the phone (matched).
  List<MapLayer> found = [];

  /// Add the missing files of [p]. Returns the layers added this time.
  Future<List<MapLayer>> add(
    MapPack p, {
    void Function(PackProgress)? onProgress,
    bool Function()? cancelled,
  }) async {
    final have = addedFiles(p, layers);
    var todo = [
      for (final f in p.files)
        if (!have.contains(f.name)) f,
    ];
    // Already imported by hand (same file)? Use that layer, no copy.
    final out = <MapLayer>[];
    found = [];
    for (final f in todo.toList()) {
      if (cancelled?.call() ?? false) throw PackException('Cancelled');
      onProgress?.call(PackProgress(f.name, 0, 0, step: 'Looking for'));
      final c = await findCopy(p, f, layers);
      if (c == null) continue;
      await layers.tagPack(c, p.id, f.name, matched: true);
      found.add(c);
      out.add(c);
      todo = [...todo]..remove(f);
    }
    final need = todo.fold<int>(0, (s, f) => s + f.size);
    if (need > layers.freeBytes) {
      throw StorageLimitException(
        'Not enough room for ${p.name} (${formatBytes(need)}): imported maps '
        'use ${formatBytes(layers.usedBytes)} of '
        '${formatBytes(layers.limitBytes)}. Delete a layer first.',
      );
    }
    final total = todo.fold<int>(0, (s, f) => s + max(f.size, 1));
    var before = 0;
    for (final f in todo) {
      if (cancelled?.call() ?? false) throw PackException('Cancelled');
      void report(int got, String step) => onProgress?.call(
        PackProgress(f.name, before + got, total, step: step),
      );
      final l = await _addFile(p, f, report, cancelled);
      out.add(l);
      before += max(f.size, 1);
      report(0, 'Added');
    }
    return out;
  }

  Future<MapLayer> _addFile(
    MapPack p,
    PackFile f,
    void Function(int got, String step) report,
    bool Function()? cancelled,
  ) async {
    Uint8List? bytes;
    File? tmp;
    final asset = f.asset;
    if (asset != null && readAsset != null) {
      try {
        bytes = await readAsset!(asset);
      } catch (_) {
        bytes = null; // fall back to the download
      }
    }
    if (bytes == null) {
      await tempDir.create(recursive: true);
      tmp = File(
        '${tempDir.path}/${DateTime.now().microsecondsSinceEpoch}_${f.name}',
      );
      try {
        await _download(Uri.parse(f.url), tmp, (got, _) {
          if (cancelled?.call() ?? false) throw PackException('Cancelled');
          report(got, 'Downloading');
        });
      } catch (e) {
        await _rm(tmp);
        if (e is PackException) rethrow;
        throw PackException('Could not download ${f.name}: ${_short(e)}');
      }
    }
    try {
      report(f.size, 'Checking');
      final want = f.sha256;
      if (want != null) {
        final got = bytes != null ? await shaOf(bytes) : await shaOfFile(tmp!);
        if (got != want) {
          throw PackException(
            '${f.name} did not download correctly (checksum). Try again.',
          );
        }
      }
      report(f.size, 'Adding');
      final MapLayer l;
      switch (f.kind) {
        case PackFileKind.trail:
          l = await layers.importTrail(
            f.name,
            bytes ?? await tmp!.readAsBytes(),
            attribution: f.attribution,
          );
        case PackFileKind.tiles:
          final src = tmp ?? await _write(f.name, bytes!);
          l = await layers.importMbtiles(src, move: true);
          tmp = null; // moved
        case PackFileKind.roads:
          final b = f.bounds ?? p.bounds;
          if (b == null) throw PackException('${f.name}: no area given');
          l = await layers.importRoads(
            f.title.isEmpty ? f.name : f.title,
            bytes ?? await tmp!.readAsBytes(),
            area: b,
            summary: f.summary,
            attribution: f.attribution,
          );
        case PackFileKind.overlay:
          final img = bytes ?? await tmp!.readAsBytes();
          final ext = f.name.contains('.') ? f.name.split('.').last : 'png';
          l = await layers.importOverlay(
            f.title.isEmpty ? f.name : f.title,
            img,
            ext: ext,
          );
          final b = f.bounds;
          if (b != null) {
            await layers.setGeoref(l, georefForBounds(b, l.imageW, l.imageH));
            await layers.setOpacity(l, f.opacity);
          }
      }
      if (f.title.isNotEmpty &&
          f.kind != PackFileKind.overlay &&
          f.kind != PackFileKind.roads) {
        await layers.rename(l, f.title);
      }
      await layers.tagPack(l, p.id, f.name);
      if (f.sha256 != null && f.kind != PackFileKind.trail) {
        await layers.setSha(l, f.sha256!);
      }
      return l;
    } finally {
      if (tmp != null) await _rm(tmp);
    }
  }

  Future<File> _write(String name, Uint8List b) async {
    await tempDir.create(recursive: true);
    final t = File(
      '${tempDir.path}/${DateTime.now().microsecondsSinceEpoch}_$name',
    );
    await t.writeAsBytes(b, flush: true);
    return t;
  }

  static Future<void> _rm(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<String> shaOf(List<int> b) async =>
      _hex((await Sha256().hash(b)).bytes);

  static Future<String> shaOfFile(File f) async {
    final sink = Sha256().newHashSink();
    await for (final c in f.openRead()) {
      sink.add(c);
    }
    sink.close();
    return _hex((await sink.hash()).bytes);
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static String _short(Object e) {
    final s = '$e';
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  /// dart:io download with redirects (GitHub release assets redirect to
  /// their storage host) and progress.
  static Future<void> httpDownload(
    Uri url,
    File to,
    void Function(int got, int? total) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'WalkieTalkie map packs';
    try {
      final req = await client.getUrl(url);
      req.followRedirects = true;
      req.maxRedirects = 8;
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: url);
      }
      final total = res.contentLength > 0 ? res.contentLength : null;
      final sink = to.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          got += chunk.length;
          onProgress(got, total);
        }
      } finally {
        await sink.close();
      }
      if (total != null && got != total) {
        throw HttpException('download cut off ($got of $total bytes)');
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// Bounds of a layer on the map (to move the map there after adding it).
GeoBounds? layerBounds(MapLayers layers, MapLayer l) {
  switch (l.kind) {
    case MapLayerKind.trail:
      final pts = l.data?.allPoints.toList() ?? const <GeoPoint>[];
      return boundsOfPoints(pts);
    case MapLayerKind.tiles:
      return layers.tilesOf(l.id)?.bounds;
    case MapLayerKind.roads:
      return l.area;
    case MapLayerKind.overlay:
      final g = l.georef;
      if (g == null) return null;
      final c = g.corners(l.imageW.toDouble(), l.imageH.toDouble());
      return boundsOfPoints([
        c.topLeft,
        c.topRight,
        c.bottomLeft,
        c.bottomRight,
      ]);
  }
}

/// Union of several boxes (null entries skipped).
GeoBounds? unionBounds(Iterable<GeoBounds?> bs) {
  GeoBounds? out;
  for (final b in bs) {
    if (b == null) continue;
    out = out == null
        ? b
        : GeoBounds(
            min(out.south, b.south),
            min(out.west, b.west),
            max(out.north, b.north),
            max(out.east, b.east),
          );
  }
  return out;
}

/// The pack list: the copy bundled in the APK, replaced by the latest one
/// from GitHub when it can be fetched (cached on the phone for offline).
class PackCatalog {
  PackCatalog({required this.bundled, this.fetch, this.cacheFile});

  /// `map_packs.json` from the APK.
  final Future<String> Function() bundled;

  /// The latest `map_packs.json` (null = offline / not available).
  final Future<String?> Function()? fetch;
  final File? cacheFile;

  static final remoteUrl = Uri.parse(
    'https://raw.githubusercontent.com/Brionwickstrom/walkie-talkie/main/map_packs.json',
  );

  List<MapPack> packs = const [];

  /// Bundled (or cached) list right away; [refresh] also asks GitHub.
  Future<List<MapPack>> load({bool refresh = true}) async {
    var list = <MapPack>[];
    try {
      list = MapPack.parseList(await bundled());
    } catch (_) {}
    final cached = await _readCache();
    if (cached.isNotEmpty) list = merge(list, cached);
    packs = list;
    if (refresh && fetch != null) {
      try {
        final s = await fetch!();
        final remote = s == null ? const <MapPack>[] : MapPack.parseList(s);
        if (remote.isNotEmpty) {
          packs = merge(list, remote);
          try {
            await cacheFile?.writeAsString(s!);
          } catch (_) {}
        }
      } catch (_) {}
    }
    return packs;
  }

  Future<List<MapPack>> _readCache() async {
    final f = cacheFile;
    if (f == null) return const [];
    try {
      if (!await f.exists()) return const [];
      return MapPack.parseList(await f.readAsString());
    } catch (_) {
      return const [];
    }
  }

  /// [newer] wins per pack id, packs only in [base] are kept; a bundled
  /// copy of a file stays usable when the newer entry is the same file.
  static List<MapPack> merge(List<MapPack> base, List<MapPack> newer) {
    final byId = {for (final p in base) p.id: p};
    final out = <MapPack>[];
    for (final n in newer) {
      final old = byId.remove(n.id);
      if (old == null) {
        out.add(n);
        continue;
      }
      final assets = {
        for (final f in old.files)
          if (f.asset != null) '${f.name}|${f.sha256}': f.asset,
      };
      out.add(
        MapPack(
          id: n.id,
          name: n.name,
          short: n.short,
          area: n.area,
          about: n.about,
          bounds: n.bounds,
          files: [
            for (final f in n.files)
              f.asset != null || !assets.containsKey('${f.name}|${f.sha256}')
                  ? f
                  : PackFile(
                      name: f.name,
                      kind: f.kind,
                      url: f.url,
                      title: f.title,
                      asset: assets['${f.name}|${f.sha256}'],
                      size: f.size,
                      sha256: f.sha256,
                      attribution: f.attribution,
                      bounds: f.bounds,
                      opacity: f.opacity,
                      summary: f.summary,
                    ),
          ],
        ),
      );
    }
    out.addAll(byId.values);
    return out;
  }

  /// Fetch [remoteUrl] (small JSON) with dart:io.
  static Future<String?> httpFetch() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(remoteUrl);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      return body.length > 512 * 1024 ? null : body;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

// ------------------------------------------------ copies and duplicates

/// SHA-256 of a layer's stored file (cached on the layer).
Future<String?> layerSha(MapLayers layers, MapLayer l) async {
  if (l.sha != null) return l.sha;
  try {
    final h = await PackInstaller.shaOfFile(layers.fileOf(l));
    await layers.setSha(l, h);
    return h;
  } catch (_) {
    return null;
  }
}

/// "Silver_Star_Trails.gpx" / "Silver Star trails" -> "silverstartrails".
String normName(String s) {
  final n = s.toLowerCase().replaceFirst(RegExp(r'\.[a-z0-9]{1,7}$'), '');
  return n.replaceAll(RegExp('[^a-z0-9]'), '');
}

bool _near(GeoBounds a, GeoBounds b, {double tol = 0.01}) =>
    (a.south - b.south).abs() <= tol &&
    (a.west - b.west).abs() <= tol &&
    (a.north - b.north).abs() <= tol &&
    (a.east - b.east).abs() <= tol;

bool _inside(GeoBounds inner, GeoBounds outer, {double tol = 0.02}) =>
    inner.south >= outer.south - tol &&
    inner.north <= outer.north + tol &&
    inner.west >= outer.west - tol &&
    inner.east <= outer.east + tol;

/// An imported layer that is the same as pack file [f] (the user imported
/// it by hand): same content hash; or same original size (trails: inside the
/// pack area); or the same name and the same area.
Future<MapLayer?> findCopy(MapPack p, PackFile f, MapLayers layers) async {
  final kind = switch (f.kind) {
    PackFileKind.trail => MapLayerKind.trail,
    PackFileKind.tiles => MapLayerKind.tiles,
    PackFileKind.overlay => MapLayerKind.overlay,
    PackFileKind.roads => MapLayerKind.roads,
  };
  final area = f.bounds ?? p.bounds;
  final names = {normName(f.name), if (f.title.isNotEmpty) normName(f.title)};
  final cands = [
    for (final l in layers.all)
      if (l.kind == kind && l.pack == null) l,
  ];
  if (cands.isEmpty) return null;
  // 1. Same content (tiles / pictures are stored as imported).
  if (kind != MapLayerKind.trail && f.sha256 != null) {
    for (final l in cands) {
      if (l.bytes != f.size && l.sourceBytes != f.size) continue;
      if (await layerSha(layers, l) == f.sha256) return l;
    }
  }
  for (final l in cands) {
    final b = layerBounds(layers, l);
    final sameSize = l.sourceBytes == f.size || l.bytes == f.size;
    final sameName = names.contains(normName(l.name));
    switch (kind) {
      case MapLayerKind.trail:
        // The GPX file's size is kept as sourceBytes.
        // Same trails from another format (KML): the same extent.
        final here = area == null || (b != null && _inside(b, area));
        final fb = f.bounds;
        final same = fb != null && b != null && _near(b, fb, tol: 0.003);
        if (((sameSize || sameName) && here) || same) return l;
      case MapLayerKind.tiles:
        final same = area != null && b != null && _near(b, area);
        if ((sameSize && (area == null || same)) || (sameName && same)) {
          return l;
        }
      case MapLayerKind.overlay:
        // Pictures: same content (above), or same name and size.
        if (sameSize && sameName) return l;
      case MapLayerKind.roads:
        if (sameSize && sameName) return l;
    }
  }
  return null;
}

/// Groups of identical layers (same kind, size and content), oldest first.
Future<List<List<MapLayer>>> findDuplicates(MapLayers layers) async {
  final bySize = <String, List<MapLayer>>{};
  for (final l in layers.all) {
    if (l.from != null) continue; // shared routes are someone else's
    bySize.putIfAbsent('${l.kind.name}|${l.bytes}', () => []).add(l);
  }
  final out = <List<MapLayer>>[];
  for (final g in bySize.values.where((g) => g.length > 1)) {
    final byHash = <String, List<MapLayer>>{};
    for (final l in g) {
      final h = await layerSha(layers, l);
      if (h != null) byHash.putIfAbsent(h, () => []).add(l);
    }
    for (final d in byHash.values.where((d) => d.length > 1)) {
      d.sort((a, b) => a.added.compareTo(b.added));
      out.add(d);
    }
  }
  return out;
}

/// What a duplicate cleanup did.
class DuplicateCleanup {
  DuplicateCleanup(this.removed, this.freedBytes, this.kept);
  final int removed, freedBytes;

  /// removed layer id -> kept layer (e.g. to move the base map).
  final Map<String, MapLayer> kept;
}

/// Keep one copy of each duplicate group: the pack one, else [prefer] (the
/// base map), else a visible one, else the oldest. Pack tags move to it.
Future<DuplicateCleanup> removeDuplicates(
  MapLayers layers, {
  String? prefer,
}) async {
  var removed = 0, freed = 0;
  final kept = <String, MapLayer>{};
  for (final g in await findDuplicates(layers)) {
    final keep =
        g.where((l) => l.pack != null).firstOrNull ??
        g.where((l) => l.id == prefer).firstOrNull ??
        g.where((l) => l.visible).firstOrNull ??
        g.first;
    for (final l in g) {
      if (identical(l, keep)) continue;
      if (keep.pack == null && l.pack != null) {
        await layers.tagPack(keep, l.pack, l.packFile, matched: true);
      }
      kept[l.id] = keep;
      freed += l.bytes;
      removed++;
      await layers.delete(l);
    }
  }
  return DuplicateCleanup(removed, freed, kept);
}
