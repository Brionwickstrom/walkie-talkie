import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'geo.dart';
import 'imagery.dart';

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
    this.about = '',
    this.overlay = false,
    this.opacity = 1,
    this.minZoom = 0,
    this.onlineOnly = false,
    this.photos = false,
    this.labels,
    this.downloadTileCap,
  });

  /// Satellite photos with the newest photos for the place (v2.5.5): the
  /// cache asks Oregon's 2024 photos inside Oregon, the USGS NAIP photos
  /// elsewhere, and falls back to this source's own (older) tiles.
  final bool photos;

  /// Roads, trails and names drawn on top of the photos (hybrid).
  final MapSource? labels;

  /// Most tiles one download of this source may fetch (below the cache's
  /// own limit), for the big photo services.
  final int? downloadTileCap;

  /// One line for the style picker ("Satellite photos").
  final String about;

  /// Drawn on top of any base map (transparent tiles), toggled on/off.
  final bool overlay;
  final double opacity;

  /// Not drawn below this zoom (e.g. slope shading needs detail).
  final int minZoom;

  /// Live data, never cached for offline (e.g. wildfire perimeters).
  final bool onlineOnly;
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

  // ---------------------------------------------- v1.9.1: more styles
  // USGS The National Map, BLM and USFS services are US Government works
  // (public domain), so areas may be saved for offline use. AWS Terrain
  // Tiles (Mapzen terrarium) are open data.

  static const _tnm = 'https://basemap.nationalmap.gov/arcgis/rest/services';
  static const _edw = 'https://apps.fs.usda.gov/arcx/rest/services/EDW';
  static const _export =
      '/MapServer/export?bbox={bbox}&bboxSR=3857&imageSR=3857'
      '&size=256,256&format=png32&transparent=true&f=image';

  /// USGS US Topo style map (contours, trails, names), US only.
  static const usgsTopo = MapSource(
    id: 'usgs_topo',
    name: 'USGS Topo',
    urlTemplate: '$_tnm/USGSTopo/MapServer/tile/{z}/{y}/{x}',
    attribution: 'USGS The National Map',
    maxZoom: 16,
    allowsOffline: true,
    avgTileBytes: 25000,
    about: 'Official US topo map: contours, trails, forest roads.',
  );

  /// Oregon Statewide Imagery Program, summer 2024, 1 foot. The service
  /// has no standard tile grid, so a tile is a bbox export (like the EDW
  /// overlays); outside Oregon it answers with an empty PNG.
  static const osip2024 = MapSource(
    id: 'osip_2024',
    name: 'Oregon photos 2024',
    urlTemplate:
        'https://imagery.oregonexplorer.info/arcgis/rest/services/'
        'OSIP_2024/OSIP_2024_WM/ImageServer/exportImage?bbox={bbox}'
        '&bboxSR=3857&imageSR=3857&size=256,256&format=jpgpng&f=image',
    attribution:
        'Oregon Statewide Imagery Program (OSIP) – Oregon Imagery '
        'Framework Implementation Team',
    maxZoom: 18,
    allowsOffline: true,
    avgTileBytes: 17000,
  );

  /// USGS NAIP photos, live (mostly 2019 to 2023, 0.6 m), US only.
  static const naipLive = MapSource(
    id: 'naip_live',
    name: 'US photos (NAIP)',
    urlTemplate:
        'https://imagery.nationalmap.gov/arcgis/rest/services/'
        'USGSNAIPImagery/ImageServer/exportImage?bbox={bbox}'
        '&bboxSR=3857&imageSR=3857&size=256,256&format=jpgpng&f=image',
    attribution: 'USGS The National Map: Orthoimagery (USDA NAIP)',
    maxZoom: 18,
    allowsOffline: true,
    avgTileBytes: 17000,
  );

  /// Roads, trails and their names (USGS The National Map, TIGER and
  /// Forest Service data), transparent, drawn over the photos of the
  /// hybrid.
  static const photoLabels = MapSource(
    id: 'tnm_roads',
    name: 'Roads and names',
    urlTemplate:
        'https://carto.nationalmap.gov/arcgis/rest/services/transportation/'
        'MapServer/export?bbox={bbox}&bboxSR=3857&imageSR=3857&size=256,256'
        '&format=png32&transparent=true&layers=show:1,2,3,5,7,8,9,11,13,14,'
        '15,16,17,18,19,20,21,22,24,26,29,30,31,32,33,35,37&f=image',
    attribution: 'Roads and trails: USGS The National Map',
    maxZoom: 18,
    minZoom: 9,
    allowsOffline: true,
    avgTileBytes: 5000,
    overlay: true,
  );

  /// The single Satellite choice (id kept from the old USGS satellite, so
  /// saved settings and offline areas carry on): the newest photos for
  /// the place, zoom up to 18 inside saved areas.
  static const usgsImagery = MapSource(
    id: 'usgs_imagery',
    name: 'Satellite',
    urlTemplate: '$_tnm/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}',
    attribution:
        'Photos: Oregon Statewide Imagery Program (OSIP) – Oregon Imagery '
        'Framework Implementation Team (Oregon); USGS The National Map: '
        'Orthoimagery (USDA NAIP)',
    maxZoom: 18,
    allowsOffline: true,
    avgTileBytes: 17000,
    about: 'Newest aerial photos: Oregon 2024 (1 ft), US NAIP elsewhere.',
    photos: true,
    downloadTileCap: 2000,
  );

  static const usgsHybrid = MapSource(
    id: 'usgs_hybrid',
    name: 'Satellite + roads and names',
    urlTemplate: '$_tnm/USGSImageryOnly/MapServer/tile/{z}/{y}/{x}',
    attribution:
        'Photos: Oregon Statewide Imagery Program (OSIP) – Oregon Imagery '
        'Framework Implementation Team (Oregon); USGS The National Map: '
        'Orthoimagery (USDA NAIP). Roads and trails: USGS The National Map',
    maxZoom: 18,
    allowsOffline: true,
    avgTileBytes: 17000,
    about: 'The same photos with roads, trails and their names on top.',
    photos: true,
    labels: photoLabels,
    downloadTileCap: 2000,
  );

  static const usgsRelief = MapSource(
    id: 'usgs_relief',
    name: 'USGS Hillshade',
    urlTemplate: '$_tnm/USGSShadedReliefOnly/MapServer/tile/{z}/{y}/{x}',
    attribution: 'USGS The National Map: 3D Elevation Program',
    maxZoom: 16,
    allowsOffline: true,
    avgTileBytes: 9000,
    about: 'Shaded terrain: ridges, gullies and valleys stand out.',
  );

  /// Base maps in the style picker (plus imported MBTiles and custom).
  static const bases = [
    usgsTopo,
    topo,
    usgsImagery,
    usgsHybrid,
    usgsRelief,
    osm,
  ];

  /// Raw elevation tiles (AWS Terrain Tiles, terrarium PNG): slope shading
  /// and the elevation profile. Not drawn as is.
  static const terrarium = MapSource(
    id: 'terrarium',
    name: 'Elevation data',
    urlTemplate: 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
    attribution: 'Elevation: Mapzen Terrain Tiles (AWS Open Data), USGS 3DEP',
    maxZoom: 15,
    allowsOffline: true,
    avgTileBytes: 110000,
  );

  // Overlays (on top of any base map).

  static const landOwnership = MapSource(
    id: 'ov_land',
    name: 'Land ownership',
    urlTemplate:
        'https://gis.blm.gov/arcgis/rest/services/lands/'
        'BLM_Natl_SMA_Cached_without_PriUnk/MapServer/tile/{z}/{y}/{x}',
    attribution: 'Land: BLM Surface Management Agency',
    maxZoom: 14,
    allowsOffline: true,
    avgTileBytes: 3000,
    overlay: true,
    opacity: 0.45,
    about:
        'Who manages the land: National Forest (green), BLM (yellow), '
        'National Park (purple), state (blue); private land is clear.',
  );

  static const wilderness = MapSource(
    id: 'ov_wild',
    name: 'Wilderness areas',
    urlTemplate: '$_edw/EDW_Wilderness_02$_export',
    attribution: 'Wilderness: USDA Forest Service',
    maxZoom: 15,
    allowsOffline: true,
    avgTileBytes: 1500,
    overlay: true,
    opacity: 0.6,
    about: 'Designated Wilderness (no bikes or motors).',
  );

  static const fsTrails = MapSource(
    id: 'ov_fs_trails',
    name: 'USFS trails',
    urlTemplate: '$_edw/EDW_TrailNFSPublish_01$_export',
    attribution: 'Trails: USDA Forest Service',
    maxZoom: 16,
    minZoom: 10,
    allowsOffline: true,
    avgTileBytes: 2500,
    overlay: true,
    about: 'National Forest System trails (official).',
  );

  static const fsRoads = MapSource(
    id: 'ov_fs_roads',
    name: 'USFS roads',
    urlTemplate: '$_edw/EDW_RoadBasic_01$_export',
    attribution: 'Roads: USDA Forest Service',
    maxZoom: 16,
    minZoom: 10,
    allowsOffline: true,
    avgTileBytes: 2000,
    overlay: true,
    about: 'National Forest roads.',
  );

  /// Slope angle shading, computed on the phone from [terrarium].
  static const slope = MapSource(
    id: 'ov_slope',
    name: 'Slope angle',
    urlTemplate: 'slope:{z}/{x}/{y}',
    attribution: 'Slope from Mapzen Terrain Tiles (AWS Open Data)',
    maxZoom: 14,
    minZoom: 11,
    allowsOffline: true,
    avgTileBytes: 110000,
    overlay: true,
    opacity: 0.55,
    about:
        'Avalanche terrain: yellow 27-30°, orange 30-35°, red 35-45°, '
        'purple 45°+.',
  );

  /// Current wildfire perimeters (NIFC WFIGS), live from the internet.
  static const fires = MapSource(
    id: 'ov_fires',
    name: 'Wildfire perimeters',
    urlTemplate: 'wfigs:',
    attribution: 'Fire perimeters: NIFC WFIGS',
    overlay: true,
    onlineOnly: true,
    about: 'Current fire perimeters. Online only, updated every few minutes.',
  );

  static const overlays = [
    landOwnership,
    wilderness,
    fsTrails,
    fsRoads,
    slope,
    fires,
  ];

  static MapSource? byId(String id) => [
    ...bases,
    ...overlays,
    terrarium,
    photoLabels,
    osip2024,
    naipLive,
  ].where((s) => s.id == id).firstOrNull;

  /// Folders of the cache a saved area of this source id keeps its tiles
  /// in: the newer photos live next to the old USGS tiles (v2.5.5).
  static List<String> cacheDirsOf(String id) => switch (id) {
    'usgs_imagery' => const ['usgs_imagery', 'osip_2024', 'naip_live'],
    'usgs_hybrid' => const [
      'usgs_hybrid',
      'usgs_imagery',
      'osip_2024',
      'naip_live',
    ],
    _ => [id],
  };

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
    var u = urlTemplate;
    if (u.contains('{bbox}')) {
      // ArcGIS "export" map services: the tile's Web Mercator box.
      const r = 20037508.342789244;
      final size = 2 * r / (1 << z);
      final x0 = -r + x * size, y1 = r - y * size;
      String f(double v) => v.toStringAsFixed(2);
      u = u.replaceAll(
        '{bbox}',
        '${f(x0)},${f(y1 - size)},${f(x0 + size)},${f(y1)}',
      );
    }
    u = u
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
    this.areaId,
  });
  final String name;

  /// The offline area (v1.9.3) this belongs to.
  String? areaId;
  final String sourceId;
  final GeoBounds bounds;
  final int minZoom;
  final int maxZoom;
  int tiles;
  int bytes;
  final DateTime at;

  bool covers(String source, int z, int x, int y) {
    if (z < minZoom || z > maxZoom) return false;
    if (source != sourceId &&
        !MapSource.cacheDirsOf(sourceId).contains(source)) {
      return false;
    }
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
    'ai': ?areaId,
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
        areaId: j['ai'] as String?,
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

  /// Stopped by itself after many failures in a row (no signal).
  bool stalled = false;
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
    this.photoFresh = const Duration(days: 60),
  });

  /// How long a photo tile is kept before it is fetched again (v2.5.5);
  /// the photos change once a year.
  final Duration photoFresh;

  /// The photo services (tests point these at a local server).
  MapSource oregonPhotos = MapSource.osip2024;
  MapSource usPhotos = MapSource.naipLive;

  /// The older USGS photos behind them.
  MapSource oldPhotos = MapSource.usgsImagery;

  /// Zoom the photos are fetched at when looking around; zoom 18 comes
  /// from saved areas, or from the zoom 17 tile enlarged (no extra request).
  static const photoViewMaxZoom = 17;

  /// The zoom the old USGS photos end at.
  static const oldPhotoMaxZoom = 16;

  /// Below this zoom the (fast, cached) USGS photos are used: the live
  /// services are slow for wide views and the difference is not visible.
  static const photoMinZoom = 13;

  /// Cuts a part out of a tile and enlarges it (tests replace it).
  Future<Uint8List> Function(Uint8List parent, int shift, int dx, int dy)
  cropper = cropTileUp;

  /// Tile keys the photo service answered "no photos here" for (this run).
  final Set<String> _noPhotos = {};
  final Map<String, int> _photoFails = {};
  final Map<String, DateTime> _photoPause = {};

  final Directory dir;
  final String userAgent;
  int maxBytes;
  final Duration minFresh;

  /// Most tiles one "Download area" may fetch (keeps it polite to the free
  /// tile servers and the phone's storage).
  final int maxDownloadTiles;

  /// False = never use the network (tests, airplane mode).
  bool online = true;

  /// v2.1.0: the map network check says there is no signal right now: use
  /// the saved and cached tiles at once instead of waiting for timeouts.
  bool net = true;

  /// Told how each download went (true = answered, false = no signal).
  void Function(bool ok)? onNet;

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
    if (s.photos) return _getPhoto(s, z, x, y);
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
    final off = !online || !net;
    if (cached != null && (fresh || off)) return cached;
    if (off) return null;
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

  // ------------------------------------------- newer photos (v2.5.5)

  /// The photo service for tile [z]/[x]/[y]: Oregon's own 2024 photos
  /// inside Oregon, the nationwide NAIP photos elsewhere.
  MapSource photoSourceFor(int z, int x, int y) {
    final (lat, lng) = tileCenterLatLng(z, x, y);
    return inOregon(lat, lng) ? oregonPhotos : usPhotos;
  }

  /// Photo services to try for a tile, best first: a tile of Oregon that
  /// Oregon's service has no photos for (the edge of the state) comes from
  /// the nationwide photos.
  List<MapSource> _photoChain(int z, int x, int y) {
    final c = photoSourceFor(z, x, y);
    return identical(c, oregonPhotos) ? [oregonPhotos, usPhotos] : [c];
  }

  HttpClient? _photoClient;
  HttpClient get _photoHttp => _photoClient ??= (HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = 4
    ..userAgent = userAgent);

  bool _photoPaused(MapSource c) {
    final t = _photoPause[c.id];
    if (t == null) return false;
    if (DateTime.now().isAfter(t)) {
      _photoPause.remove(c.id);
      _photoFails[c.id] = 0;
      return false;
    }
    return true;
  }

  /// One photo tile from [c]: the JPEG bytes, stored; null when the
  /// service has no photos there (remembered for this run) or did not
  /// answer. Three failures in a row pause that service for two minutes,
  /// so a slow or down service costs no more battery.
  Future<Uint8List?> _fetchPhoto(MapSource c, int z, int x, int y) async {
    final key = '${c.id}/$z/$x/$y';
    if (_noPhotos.contains(key) || _photoPaused(c)) return null;
    try {
      final req = await _photoHttp.getUrl(Uri.parse(c.urlFor(z, x, y)));
      final res = await req.close().timeout(const Duration(seconds: 15));
      onNet?.call(true);
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw StateError('status ${res.statusCode}');
      }
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
      }
      final bytes = b.takeBytes();
      _photoFails[c.id] = 0;
      if (!isJpeg(bytes)) {
        if (_noPhotos.length > 4000) _noPhotos.clear();
        _noPhotos.add(key);
        return null;
      }
      final f = _file(c.id, z, x, y);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: false);
      return bytes;
    } catch (_) {
      onNet?.call(false);
      final n = (_photoFails[c.id] ?? 0) + 1;
      _photoFails[c.id] = n;
      if (n >= 3) {
        _photoPause[c.id] = DateTime.now().add(const Duration(minutes: 2));
      }
      return null;
    }
  }

  Future<Uint8List?> _read(File f) async {
    try {
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  Future<bool> _isFresh(File f, Duration d) async {
    try {
      return DateTime.now().difference(await f.lastModified()) < d;
    } catch (_) {
      return false;
    }
  }

  /// A photo tile for the Satellite styles: the newest photos on the
  /// phone or from the service, else the older USGS photos.
  Future<Uint8List?> _getPhoto(MapSource s, int z, int x, int y) async {
    final off = !online || !net;
    if (z < photoMinZoom) return _oldPhoto(s, z, x, y, off);
    final chain = _photoChain(z, x, y);
    Uint8List? cached;
    for (final c in chain) {
      final f = _file(c.id, z, x, y);
      final b = await _read(f);
      if (b == null) continue;
      if (off || await _isFresh(f, photoFresh)) return b;
      cached ??= b;
    }
    if (z > photoViewMaxZoom && cached == null) {
      // Zoom 18 only exists inside saved areas: otherwise the zoom 17
      // tile, enlarged.
      final shift = z - photoViewMaxZoom;
      final parent = await _getPhoto(
        s,
        photoViewMaxZoom,
        x >> shift,
        y >> shift,
      );
      if (parent == null) return null;
      return cropper(
        parent,
        shift,
        x & ((1 << shift) - 1),
        y & ((1 << shift) - 1),
      );
    }
    if (!off && z <= photoViewMaxZoom) {
      for (final c in chain) {
        final got = await _fetchPhoto(c, z, x, y);
        if (got != null) return got;
      }
    }
    if (cached != null) return cached;
    return _oldPhoto(s, z, x, y, off);
  }

  /// The older USGS photos (zoom 16 and below; enlarged above). Offline
  /// this also finds what saved areas of the old hybrid hold.
  Future<Uint8List?> _oldPhoto(
    MapSource s,
    int z,
    int x,
    int y,
    bool off,
  ) async {
    if (z > oldPhotoMaxZoom) {
      final shift = z - oldPhotoMaxZoom;
      final parent = await _oldPhoto(
        s,
        oldPhotoMaxZoom,
        x >> shift,
        y >> shift,
        off,
      );
      if (parent == null) return null;
      return cropper(
        parent,
        shift,
        x & ((1 << shift) - 1),
        y & ((1 << shift) - 1),
      );
    }
    if (off && s.id == MapSource.usgsHybrid.id) {
      final composite = await _read(_file(s.id, z, x, y));
      if (composite != null) return composite;
    }
    final old = oldPhotos;
    final f = _file(old.id, z, x, y);
    final cached = await _read(f);
    final fresh = cached != null && await _isFresh(f, minFresh);
    if (cached != null && (fresh || off)) return cached;
    if (off) return null;
    final got = await _fetch(old, z, x, y, conditional: cached != null);
    if (got == null) return cached;
    if (got.isEmpty) {
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
      return cached;
    }
    return got;
  }

  /// Saves one tile of a photo style for offline use ([refresh]: ask again
  /// when the saved one is older than [photoFresh]). Returns its size, or
  /// null when it could not be saved.
  Future<int?> _savePhoto(MapSource s, TileId t, {bool refresh = false}) async {
    if (t.z >= photoMinZoom) {
      final chain = _photoChain(t.z, t.x, t.y);
      int? stale;
      for (final c in chain) {
        final f = _file(c.id, t.z, t.x, t.y);
        try {
          if (await f.exists()) {
            if (!refresh || await _isFresh(f, photoFresh)) {
              return await f.length();
            }
            stale ??= await f.length();
          }
        } catch (_) {}
      }
      for (final c in chain) {
        final got = await _fetchPhoto(c, t.z, t.x, t.y);
        if (got != null) return got.length;
      }
      if (stale != null) return stale;
    }
    // No newer photos there: keep the old USGS tile (zoom 16 and below).
    if (t.z <= oldPhotoMaxZoom) {
      final old = oldPhotos;
      final of = _file(old.id, t.z, t.x, t.y);
      try {
        if (await of.exists()) return await of.length();
      } catch (_) {}
      final b = await _fetch(old, t.z, t.x, t.y);
      if (b != null && b.isNotEmpty) return b.length;
    }
    return null;
  }

  /// Most tiles one download of [s] may fetch.
  int limitFor(MapSource s) => s.downloadTileCap == null
      ? maxDownloadTiles
      : min(maxDownloadTiles, s.downloadTileCap!);

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
      onNet?.call(true);
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
      onNet?.call(false);
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
    String? areaId,
    bool refresh = false,
  }) async {
    if (!s.allowsOffline) {
      throw StateError('${s.name} does not allow offline downloads');
    }
    final maxZ = min(maxZoom, s.maxZoom);
    final n = countTiles(b, minZoom, maxZ);
    if (n > limitFor(s)) {
      throw StateError(
        'Area too big: $n tiles (limit ${limitFor(s)}). Zoom in or '
        'lower the detail.',
      );
    }
    // The big photo services get a longer pause between requests.
    if (s.photos && pause > Duration.zero) pause = pause * 3;
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
      areaId: areaId,
    );
    final it = tilesIn(b, minZoom, maxZ).iterator;
    Future<void> worker() async {
      while (!p.cancelled) {
        TileId t;
        if (!it.moveNext()) return;
        t = it.current;
        if (s.photos) {
          final got = await _savePhoto(s, t, refresh: refresh);
          if (got != null) {
            p.bytes += got;
            p.done++;
          } else {
            p.failed++;
          }
          await Future<void>.delayed(pause);
          onProgress?.call(p);
          continue;
        }
        final f = _file(s.id, t.z, t.x, t.y);
        var ok = false;
        var have = false;
        try {
          if (await f.exists()) {
            have = true;
            // Update: tiles fetched in the last [minFresh] are kept as is.
            final fresh =
                DateTime.now().difference(await f.lastModified()) < minFresh;
            if (!refresh || fresh) {
              p.bytes += await f.length();
              ok = true;
            }
          }
        } catch (_) {}
        if (!ok && have) {
          // Update: ask the server whether the tile changed (304 = keep).
          final got = await _fetch(s, t.z, t.x, t.y, conditional: true);
          try {
            if (got != null && got.isEmpty) {
              await f.setLastModified(DateTime.now());
            }
            p.bytes += got != null && got.isNotEmpty
                ? got.length
                : await f.length();
          } catch (_) {}
          ok = true;
          await Future<void>.delayed(pause);
        }
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

  /// Save exactly these tiles (a strip along a route, v2.2.0) for offline
  /// use: one request at a time, [pause] between requests (1 a second for
  /// the free tile servers), tiles already on the phone skipped. Stops at
  /// once when [progress] is cancelled, and after [giveUpAfter] failures in
  /// a row (no signal: no point draining the battery). What was fetched is
  /// kept as a region either way, so saving again carries on from there.
  Future<OfflineRegion> downloadTiles(
    MapSource s,
    List<TileId> list, {
    required String name,
    required GeoBounds bounds,
    DownloadProgress? progress,
    void Function(DownloadProgress p)? onProgress,
    Duration pause = const Duration(seconds: 1),
    String? areaId,
    bool refresh = false,
    int giveUpAfter = 6,
  }) async {
    if (!s.allowsOffline) {
      throw StateError('${s.name} does not allow offline downloads');
    }
    final p = progress ?? DownloadProgress(list.length);
    var minZ = 99, maxZ = 0;
    for (final t in list) {
      minZ = min(minZ, t.z);
      maxZ = max(maxZ, t.z);
    }
    final region = OfflineRegion(
      name: name,
      sourceId: s.id,
      bounds: bounds,
      minZoom: list.isEmpty ? 0 : minZ,
      maxZoom: list.isEmpty ? 0 : maxZ,
      tiles: 0,
      bytes: 0,
      at: DateTime.now(),
      areaId: areaId,
    );
    var failsInRow = 0;
    for (final t in list) {
      if (p.cancelled) break;
      if (s.photos) {
        final got = await _savePhoto(s, t, refresh: refresh);
        if (got != null) {
          p.bytes += got;
          p.done++;
          failsInRow = 0;
        } else {
          p.failed++;
          if (++failsInRow >= giveUpAfter) {
            p.stalled = true;
            p.cancelled = true;
          }
        }
        onProgress?.call(p);
        if (!p.cancelled && pause > Duration.zero) {
          await Future<void>.delayed(pause);
        }
        continue;
      }
      final f = _file(s.id, t.z, t.x, t.y);
      var ok = false;
      var asked = false;
      try {
        if (await f.exists()) {
          final fresh =
              DateTime.now().difference(await f.lastModified()) < minFresh;
          if (!refresh || fresh) {
            p.bytes += await f.length();
            ok = true;
          } else {
            asked = true;
            final got = await _fetch(s, t.z, t.x, t.y, conditional: true);
            if (got != null && got.isEmpty) {
              await f.setLastModified(DateTime.now());
            }
            p.bytes += got != null && got.isNotEmpty
                ? got.length
                : await f.length();
            ok = true;
          }
        }
      } catch (_) {}
      if (!ok) {
        asked = true;
        final got = await _fetch(s, t.z, t.x, t.y);
        if (got != null && got.isNotEmpty) {
          p.bytes += got.length;
          ok = true;
        }
      }
      if (ok) {
        p.done++;
        failsInRow = 0;
      } else {
        p.failed++;
        if (++failsInRow >= giveUpAfter) {
          p.stalled = true;
          p.cancelled = true;
        }
      }
      onProgress?.call(p);
      if (asked && !p.cancelled && pause > Duration.zero) {
        await Future<void>.delayed(pause);
      }
    }
    p.finished = true;
    onProgress?.call(p);
    region
      ..tiles = p.done
      ..bytes = p.bytes;
    if (p.done > 0) {
      regions.add(region);
      await _saveRegions();
    }
    return region;
  }

  Future<void> saveRegions() => _saveRegions();

  Future<void> deleteRegion(OfflineRegion r) async {
    regions.remove(r);
    await _saveRegions();
    // Remove its tiles unless another region still covers them.
    for (final t in tilesIn(r.bounds, r.minZoom, r.maxZoom)) {
      for (final dir in MapSource.cacheDirsOf(r.sourceId)) {
        if (inRegion(dir, t.z, t.x, t.y)) continue;
        try {
          await _file(dir, t.z, t.x, t.y).delete();
        } catch (_) {}
      }
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
        final parts = e.path
            .substring(dir.path.length + 1)
            .split(RegExp(r'[\\/]'));
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
    _photoClient?.close(force: true);
    _photoClient = null;
  }
}
