import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../trip/drive/road_download.dart';
import '../trip/imports/map_layers.dart';
import '../trip/imports/map_packs.dart';
import '../trip/offline_areas.dart';
import '../trip/route_save.dart';
import '../trip/search/overpass.dart' show boundsSizeKm;
import '../trip/tile_cache.dart';
import '../trip/trip_controller.dart';
import 'map_layer_widgets.dart';
import 'map_packs_page.dart';
import 'save_route_sheet.dart';
import 'trip_widgets.dart' show askText;

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String areaSize(GeoBounds b) {
  final k = boundsSizeKm(b);
  return '${k.w.round()} x ${k.h.round()} km';
}

/// The first line of a saved route's row: what it is and how complete.
String routeRowLine(SavedRoute r, TripController trip) =>
    'Route: ${r.summary(imperial: trip.settings.imperial)} · '
    '${r.turns} turns'
    '${r.isReady ? '' : ' · partly saved (menu: Resume)'}';

/// Map styles that may be saved for offline use (base maps, overlays).
List<MapSource> get offlineStyles => [
  for (final s in [...MapSource.bases, ...MapSource.overlays])
    if (s.allowsOffline && !s.onlineOnly) s,
];

/// The "Saved X: ..." line after saving or updating an area.
String areaResultMessage(AreaSaveResult r, {bool update = false}) {
  final e = r.entry;
  if (r.cancelled && e == null) return 'Cancelled. Nothing was saved.';
  if (e == null) return 'Nothing was saved.';
  return [
    '${r.cancelled ? 'Stopped; kept' : (update ? 'Updated' : 'Saved')} '
        '${e.name} (${formatBytes(e.bytes)}).',
    if (r.problems.isNotEmpty) 'Not saved: ${r.problems.join('; ')}.',
  ].join(' ');
}

/// Open "Save this area offline" and report how it went.
Future<AreaSaveResult?> openSaveArea(
  BuildContext context,
  TripController trip, {
  GeoBounds? initial,
  double? zoom,
  String? name,
  AreaEntry? update,
  RoadDownloader? downloader,
}) async {
  final m = ScaffoldMessenger.maybeOf(context);
  final r = await Navigator.of(context).push<AreaSaveResult>(
    MaterialPageRoute(
      builder: (_) => SaveAreaPage(
        trip: trip,
        initial: initial,
        zoom: zoom,
        name: name,
        update: update,
        downloader: downloader,
      ),
    ),
  );
  if (r != null) {
    m?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(areaResultMessage(r, update: update != null)),
      ),
    );
  }
  return r;
}

/// "Offline areas" (v1.9.3): one list of everything saved for no-signal
/// use. Each area holds its map tiles, trails and roads; Show on map,
/// Update, Rename and Delete act on all of it. Ready-made packs are here
/// too.
class OfflineAreasPage extends StatefulWidget {
  const OfflineAreasPage({
    super.key,
    required this.trip,
    this.view,
    this.zoom,
    this.onFit,
    this.downloader,
  });
  final TripController trip;

  /// The Trip map's view (a starting box for a new area).
  final GeoBounds? view;
  final double? zoom;
  final void Function(GeoBounds b)? onFit;

  /// Tests.
  final RoadDownloader? downloader;

  @override
  State<OfflineAreasPage> createState() => _OfflineAreasPageState();
}

class _OfflineAreasPageState extends State<OfflineAreasPage> {
  TripController get trip => widget.trip;
  int? _cache;

  @override
  void initState() {
    super.initState();
    _measure();
    unawaited(trip.areas.migrate());
    unawaited(_packNames());
  }

  Future<void> _packNames() async {
    try {
      final packs = await packCatalog(trip).load(refresh: false);
      trip.areas.packNames = {
        for (final p in packs) p.id: p.name,
        ...trip.areas.packNames,
      };
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _measure() async {
    final s = await trip.tiles.sizeOnDisk();
    if (mounted) setState(() => _cache = s);
  }

  Future<void> _add() async {
    await openSaveArea(
      context,
      trip,
      initial: widget.view,
      zoom: widget.zoom,
      downloader: widget.downloader,
    );
    await _measure();
  }

  Future<void> _updatePack(AreaEntry e) async {
    final m = ScaffoldMessenger.maybeOf(context);
    final packs = await packCatalog(trip).load();
    final p = packs.where((p) => p.id == e.pack).firstOrNull;
    if (p == null) {
      m?.showSnackBar(
        const SnackBar(content: Text('This pack is no longer listed.')),
      );
      return;
    }
    final old = <MapLayer>[];
    for (final l in e.layers) {
      final f = p.files.where((f) => f.name == l.packFile).firstOrNull;
      if (f == null || f.sha256 == null) continue;
      final sha = l.sha ?? await layerSha(trip.layers, l);
      if (sha != f.sha256) old.add(l);
    }
    final missing = p.files.any(
      (f) => !e.layers.any((l) => l.packFile == f.name),
    );
    if (old.isEmpty && !missing) {
      m?.showSnackBar(SnackBar(content: Text('${e.name} is up to date.')));
      return;
    }
    m?.showSnackBar(SnackBar(content: Text('Updating ${e.name}…')));
    try {
      final inst = PackInstaller(
        layers: trip.layers,
        tempDir: Directory('${(await getTemporaryDirectory()).path}/packs'),
        readAsset: (k) async => (await rootBundle.load(k)).buffer.asUint8List(),
      );
      for (final l in old) {
        await trip.layers.delete(l);
      }
      await inst.add(p);
      m?.showSnackBar(SnackBar(content: Text('Updated ${e.name}.')));
    } catch (err) {
      m?.showSnackBar(SnackBar(content: Text('Update failed: $err')));
    }
  }

  Future<void> _menu(AreaEntry e, String v) async {
    switch (v) {
      case 'show':
        final b = e.bounds;
        if (b != null) {
          for (final l in e.layers) {
            if (!l.visible && l.kind != MapLayerKind.roads) {
              await trip.layers.setVisible(l, true);
            }
          }
          widget.onFit?.call(b);
          if (mounted) Navigator.pop(context);
        }
      case 'update':
        if (e.isRoute) {
          await showSaveRoute(context, trip, route: e.route);
        } else if (e.isPack) {
          await _updatePack(e);
        } else {
          await openSaveArea(
            context,
            trip,
            update: e,
            downloader: widget.downloader,
          );
        }
      case 'rename':
        final n = await askText(context, title: 'Area name', initial: e.name);
        if (n != null) await trip.areas.rename(e, n);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            scrollable: true,
            title: Text('Delete ${e.name}?'),
            content: Text(
              'Deletes its ${e.parts.isEmpty ? 'files' : 'map, trails and roads'} '
              'from this phone (frees ${formatBytes(e.bytes)}).'
              '${e.isPack ? ' You can add it again from Ready-made maps.' : ''}'
              '${e.hasRoads ? ' Offline driving there stops working (online still works with signal).' : ''}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('areaDeleteOk'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok == true) await trip.deleteArea(e);
    }
    await _measure();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Offline areas')),
      body: ListenableBuilder(
        listenable: Listenable.merge([trip.areas, trip.layers]),
        builder: (context, _) {
          final list = trip.areas.entries;
          final total = list.fold(0, (s, e) => s + e.bytes);
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Save an area while you have internet: its map, trails and '
                  'roads (for driving directions) then work with no signal. '
                  'Pick any box, any map styles, and remove what you do not '
                  'need.',
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.icon(
                      key: const Key('saveArea'),
                      onPressed: trip.plan.mapTileDownloads ? _add : null,
                      icon: const Icon(Icons.download_for_offline),
                      label: const Text('Save this area offline'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('areaPacks'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              MapPacksPage(trip: trip, onFit: widget.onFit),
                        ),
                      ),
                      icon: const Icon(Icons.terrain),
                      label: const Text('Ready-made maps'),
                    ),
                  ],
                ),
              ),
              if (!trip.plan.mapTileDownloads)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    'Offline power save is on: saving areas needs the '
                    'internet.',
                  ),
                ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Nothing saved yet. Tip: Ready-made maps has Silver Star, '
                    'Trapper Creek and "Portland to Gifford Pinchot roads" '
                    '(one tap).',
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '${list.length} saved ${list.length == 1 ? 'area' : 'areas'} · ${formatBytes(total)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              for (final e in list)
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: ListTile(
                    key: Key('area:${e.id}'),
                    leading: Icon(
                      e.isRoute
                          ? Icons.alt_route
                          : e.isPack
                          ? Icons.terrain
                          : Icons.download_for_offline,
                    ),
                    title: Text(e.name),
                    isThreeLine: e.parts.length > 1 || e.isRoute,
                    subtitle: Text(
                      [
                        if (e.isRoute) routeRowLine(e.route!, trip),
                        ...e.parts,
                        [
                          formatBytes(e.bytes),
                          if (e.bounds != null) areaSize(e.bounds!),
                          e.isPack
                              ? 'Ready-made'
                              : 'Saved ${_date(e.area!.at)}',
                        ].join(' · '),
                      ].join('\n'),
                    ),
                    onTap: () => _menu(e, 'show'),
                    trailing: PopupMenuButton<String>(
                      key: Key('areaMenu:${e.id}'),
                      onSelected: (v) => _menu(e, v),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'show',
                          child: Text('Show on map'),
                        ),
                        PopupMenuItem(
                          value: 'update',
                          child: Text(
                            !e.isRoute
                                ? 'Update'
                                : e.route!.isReady
                                ? 'Download again'
                                : 'Resume',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Map tiles on the phone: ${_cache == null ? '…' : formatBytes(_cache!)} '
                  '(limit ${formatBytes(trip.tiles.maxBytes)}; maps you just '
                  'looked at are kept at least 7 days, saved areas are kept '
                  'until you delete them).\n\n'
                  'Map data © OpenStreetMap contributors (ODbL), OpenTopoMap, '
                  'USGS, USFS. Roads tagged rough, high-clearance (4WD), private '
                  'or closed for the season are marked or avoided.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// "Save this area offline": drag a box (or Use current view), choose the
/// map styles and detail, see the size, save the map, trails and roads
/// together. Also updates a saved area ([update]).
class SaveAreaPage extends StatefulWidget {
  const SaveAreaPage({
    super.key,
    required this.trip,
    this.initial,
    this.zoom,
    this.name,
    this.update,
    this.downloader,
    this.showTiles = true,
    this.tilePause = const Duration(milliseconds: 150),
  });
  final TripController trip;
  final GeoBounds? initial;
  final double? zoom;
  final String? name;
  final AreaEntry? update;
  final RoadDownloader? downloader;

  /// Tests: no tile layers, no pause between tiles.
  final bool showTiles;
  final Duration tilePause;

  @override
  State<SaveAreaPage> createState() => _SaveAreaPageState();
}

class _SaveAreaPageState extends State<SaveAreaPage> {
  final _map = MapController();
  final _name = TextEditingController();
  late GeoBounds _box;
  bool _ready = false;
  late Set<String> _styles;
  late RangeValues _zoom;
  bool _roads = true, _trails = true, _elev = true;
  AreaEntry? _update;
  AreaEstimate? _est;
  bool _estimating = false;
  String? _error;
  AreaSaveProgress? _progress;
  bool _busy = false, _cancel = false;
  Timer? _debounce;
  int _estSeq = 0;

  TripController get trip => widget.trip;

  @override
  void initState() {
    super.initState();
    _update = widget.update;
    final a = _update?.area;
    final i = widget.initial;
    final c = trip.myFix?.pos;
    _box =
        a?.bounds ??
        (i != null
            ? _inset(i, 0.12)
            : c != null
            ? GeoBounds(c.lat - 0.05, c.lng - 0.07, c.lat + 0.05, c.lng + 0.07)
            : const GeoBounds(45.72, -122.30, 45.82, -122.19));
    _name.text = a?.name ?? widget.name ?? '';
    final cur = trip.mapSource.allowsOffline ? trip.mapSource : MapSource.topo;
    _styles =
        a != null && a.styles.isNotEmpty
              ? a.styles.toSet()
              : {
                  cur.id,
                  for (final o in trip.overlays)
                    if (o.allowsOffline && !o.onlineOnly) o.id,
                }
          ..removeWhere((id) => !offlineStyles.any((s) => s.id == id));
    final z = (widget.zoom ?? 13).floor();
    final z0 = a != null && a.minZoom > 0 ? a.minZoom : math.max(8, z - 3);
    final z1 = a != null && a.maxZoom > 0
        ? a.maxZoom
        : math.min(16, math.max(z0 + 1, z + 2));
    _zoom = RangeValues(z0.toDouble(), z1.toDouble());
    if (a != null) {
      _roads = a.roads || _update!.hasRoads;
      _trails = a.trails || _update!.trailLayers.isNotEmpty;
      _elev = _update!.regions.any((r) => r.sourceId == MapSource.terrarium.id);
    }
    _changed(now: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel = true;
    _name.dispose();
    super.dispose();
  }

  static GeoBounds _inset(GeoBounds b, double f) {
    final dy = (b.north - b.south) * f, dx = (b.east - b.west) * f;
    return GeoBounds(b.south + dy, b.west + dx, b.north - dy, b.east - dx);
  }

  AreaSaveOptions get _opts => AreaSaveOptions(
    bounds: _box,
    name: _name.text.trim().isEmpty ? _defaultName : _name.text.trim(),
    styles: [
      for (final s in offlineStyles)
        if (_styles.contains(s.id)) s,
    ],
    minZoom: _zoom.start.round(),
    maxZoom: _zoom.end.round(),
    elevation: _elev,
    roads: _roads,
    trails: _trails,
  );

  String get _defaultName {
    final c = _box.center;
    return 'Area near ${c.lat.abs().toStringAsFixed(2)}° ${c.lat >= 0 ? 'N' : 'S'}, '
        '${c.lng.abs().toStringAsFixed(2)}° ${c.lng >= 0 ? 'E' : 'W'}';
  }

  /// Something changed: tile size now, road size after a pause.
  void _changed({bool now = false}) {
    final seq = ++_estSeq;
    setState(() {
      _error = null;
      _estimating = _roads;
    });
    unawaited(_estimate(seq, withRoads: false));
    _debounce?.cancel();
    if (_roads) {
      _debounce = Timer(
        Duration(milliseconds: now ? 0 : 900),
        () => _estimate(seq, withRoads: true),
      );
    }
  }

  Future<void> _estimate(int seq, {required bool withRoads}) async {
    try {
      final e = await trip.estimateArea(
        _opts,
        withRoads: withRoads,
        downloader: widget.downloader,
      );
      if (!mounted || seq != _estSeq) return;
      setState(() {
        _est = e;
        if (withRoads) _estimating = false;
      });
    } catch (e) {
      if (!mounted || seq != _estSeq) return;
      setState(() => _estimating = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _cancel = false;
      _error = null;
      _progress = null;
    });
    try {
      final r = await trip.saveArea(
        _opts,
        updateId: _update?.area?.id,
        downloader: widget.downloader,
        tilePause: widget.tilePause,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        cancelled: () => _cancel,
      );
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is StateError ? e.message : '$e';
      });
    }
  }

  void _useView() {
    if (!_ready) return;
    final v = _map.camera.visibleBounds;
    _box = _inset(GeoBounds(v.south, v.west, v.north, v.east), 0.04);
    _changed();
  }

  LatLng _ll(double lat, double lng) => LatLng(lat, lng);

  /// Move corner [k] (0 SW, 1 SE, 2 NE, 3 NW, 4 = whole box) by [d] px.
  void _drag(int k, Offset d) {
    final cam = _map.camera;
    Offset px(double lat, double lng) =>
        cam.latLngToScreenOffset(_ll(lat, lng));
    LatLng ll(Offset o) => cam.screenOffsetToLatLng(o);
    var b = _box;
    if (k == 4) {
      final c = ll(px(b.center.lat, b.center.lng) + d);
      final dy = c.latitude - b.center.lat, dx = c.longitude - b.center.lng;
      b = GeoBounds(b.south + dy, b.west + dx, b.north + dy, b.east + dx);
    } else {
      final lat = k <= 1 ? b.south : b.north;
      final lng = k == 0 || k == 3 ? b.west : b.east;
      final p = ll(px(lat, lng) + d);
      var s = b.south, w = b.west, n = b.north, e = b.east;
      if (k <= 1) {
        s = math.min(p.latitude, n - 0.003);
      } else {
        n = math.max(p.latitude, s + 0.003);
      }
      if (k == 0 || k == 3) {
        w = math.min(p.longitude, e - 0.003);
      } else {
        e = math.max(p.longitude, w + 0.003);
      }
      b = GeoBounds(s, w, n, e);
    }
    setState(() => _box = b);
  }

  Widget _handle(int k, IconData icon) => GestureDetector(
    key: Key('areaHandle$k'),
    behavior: HitTestBehavior.opaque,
    onPanUpdate: (d) => _drag(k, d.delta),
    onPanEnd: (_) => _changed(),
    child: Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.blue.shade800, width: 3),
        ),
        child: Icon(icon, size: 14, color: Colors.blue.shade800),
      ),
    ),
  );

  String _sizeText() {
    final e = _est;
    if (e == null) return 'Checking the size…';
    final road = !_roads
        ? ''
        : e.roadBytes != null
        ? ' + roads ${formatBytes(e.roadBytes!)}'
        : (_estimating
              ? ' + roads (checking…)'
              : ' + roads (size not known yet)');
    return 'About ${e.tiles} map tiles, map ~${formatBytes(e.tileBytes)}$road'
        '${e.roadBytes != null || !_roads ? ' = ~${formatBytes(e.bytes)}' : ''}'
        '${_trails ? ' (+ trails, small)' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final b = _box;
    final theme = Theme.of(context);
    final others = [
      for (final e in trip.areas.entries)
        if (e.bounds != null && e.id != _update?.id) e.bounds!,
    ];
    final dup = _update == null ? trip.areas.similar(b) : null;
    List<LatLng> rect(GeoBounds r) => [
      _ll(r.south, r.west),
      _ll(r.south, r.east),
      _ll(r.north, r.east),
      _ll(r.north, r.west),
    ];
    final est = _est;
    final pieces = roadPieces(b);
    final nothing = _opts.styles.isEmpty && !_elev && !_roads && !_trails;
    final canSave =
        !_busy && !nothing && est?.tooBig == null && trip.plan.mapTileDownloads;
    final saveLabel = _update == null ? 'Save this area' : 'Update area';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _update == null
              ? 'Save this area offline'
              : 'Update ${_update!.name}',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCameraFit: CameraFit.bounds(
                      bounds: LatLngBounds(
                        _ll(b.south, b.west),
                        _ll(b.north, b.east),
                      ),
                      padding: const EdgeInsets.all(40),
                    ),
                    onMapReady: () => setState(() => _ready = true),
                    onPositionChanged: (_, _) => setState(() {}),
                  ),
                  children: [
                    if (widget.showTiles) ...baseTileLayers(trip),
                    PolygonLayer(
                      polygons: [
                        for (final o in others)
                          Polygon(
                            points: rect(o),
                            color: Colors.green.withValues(alpha: 0.15),
                            borderColor: Colors.green.shade700,
                            borderStrokeWidth: 1.5,
                          ),
                        Polygon(
                          points: rect(b),
                          color: Colors.blue.withValues(alpha: 0.12),
                          borderColor: Colors.blue.shade800,
                          borderStrokeWidth: 3,
                        ),
                      ],
                    ),
                  ],
                ),
                if (_ready && !_busy)
                  Builder(
                    builder: (context) {
                      final cam = _map.camera;
                      Offset px(double lat, double lng) =>
                          cam.latLngToScreenOffset(_ll(lat, lng));
                      final corners = [
                        px(b.south, b.west),
                        px(b.south, b.east),
                        px(b.north, b.east),
                        px(b.north, b.west),
                        px(b.center.lat, b.center.lng),
                      ];
                      const icons = [
                        Icons.south_west,
                        Icons.south_east,
                        Icons.north_east,
                        Icons.north_west,
                        Icons.open_with,
                      ];
                      return Stack(
                        children: [
                          for (var k = 0; k < 5; k++)
                            Positioned(
                              left: corners[k].dx - 20,
                              top: corners[k].dy - 20,
                              child: _handle(k, icons[k]),
                            ),
                        ],
                      );
                    },
                  ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'Drag the corners (or the middle) to set the area.\n'
                        'Green: areas already saved.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5,
            ),
            child: SafeArea(
              top: false,
              bottom: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Area ${areaSize(b)}',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('areaUseView'),
                          onPressed: _busy ? null : _useView,
                          icon: const Icon(Icons.fit_screen),
                          label: const Text('Use current view'),
                        ),
                      ],
                    ),
                    if (dup != null)
                      Card(
                        key: const Key('areaDuplicate'),
                        color: theme.colorScheme.secondaryContainer,
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.content_copy),
                          title: Text('Already saved: ${dup.name}'),
                          subtitle: const Text(
                            'This box is about the same as a saved area. '
                            'Update that one instead of making a copy?',
                          ),
                          trailing: dup.isPack
                              ? null
                              : TextButton(
                                  key: const Key('areaUseExisting'),
                                  onPressed: _busy
                                      ? null
                                      : () {
                                          setState(() {
                                            _update = dup;
                                            _box = dup.area!.bounds;
                                            _name.text = dup.name;
                                          });
                                          _changed();
                                        },
                                  child: const Text('Update it'),
                                ),
                        ),
                      ),
                    TextField(
                      key: const Key('areaName'),
                      controller: _name,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: 'Name (optional)',
                        hintText: _defaultName,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Map styles', style: theme.textTheme.labelLarge),
                    Wrap(
                      spacing: 6,
                      runSpacing: 0,
                      children: [
                        for (final s in offlineStyles)
                          FilterChip(
                            key: Key('style:${s.id}'),
                            label: Text(s.name),
                            selected: _styles.contains(s.id),
                            onSelected: _busy
                                ? null
                                : (on) {
                                    setState(() {
                                      on
                                          ? _styles.add(s.id)
                                          : _styles.remove(s.id);
                                    });
                                    _changed();
                                  },
                          ),
                      ],
                    ),
                    Text(
                      'Detail: zoom ${_zoom.start.round()} to ${_zoom.end.round()}',
                    ),
                    RangeSlider(
                      key: const Key('areaZoom'),
                      values: _zoom,
                      min: 6,
                      max: 18,
                      divisions: 12,
                      labels: RangeLabels(
                        '${_zoom.start.round()}',
                        '${_zoom.end.round()}',
                      ),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _zoom = v),
                      onChangeEnd: (_) => _changed(),
                    ),
                    if (_zoom.end.round() >= 18)
                      Text(
                        'Zoom 18 is only saved for the Satellite styles; '
                        'it is the biggest download.',
                        style: theme.textTheme.bodySmall,
                      ),
                    SwitchListTile(
                      key: const Key('areaRoads'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _roads,
                      title: const Text('Roads for offline driving'),
                      subtitle: Text(
                        pieces == null
                            ? 'Box too big for road data (up to 2° x 2°); the '
                                  'map and trails still save.'
                            : pieces.length > 1
                            ? 'Saved in ${pieces.length} parts (big box).'
                            : 'Turn-by-turn driving with no signal.',
                      ),
                      onChanged: _busy
                          ? null
                          : (v) {
                              setState(() => _roads = v);
                              _changed();
                            },
                    ),
                    SwitchListTile(
                      key: const Key('areaTrails'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _trails,
                      title: const Text('Trails and places'),
                      subtitle: const Text(
                        'From OpenStreetMap, for Navigate here and search.',
                      ),
                      onChanged: _busy
                          ? null
                          : (v) {
                              setState(() => _trails = v);
                              _changed();
                            },
                    ),
                    SwitchListTile(
                      key: const Key('areaElev'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _elev,
                      title: const Text('Elevation'),
                      subtitle: const Text('Hike profiles and slope shading.'),
                      onChanged: _busy
                          ? null
                          : (v) {
                              setState(() => _elev = v);
                              _changed();
                            },
                    ),
                    Text(
                      _sizeText(),
                      key: const Key('areaEstimate'),
                      style: theme.textTheme.titleSmall,
                    ),
                    if (est?.tooBig != null)
                      Text(
                        est!.tooBig!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    if (_error != null)
                      Text(
                        _error!,
                        key: const Key('areaError'),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'Downloads slowly on purpose to be fair to the free map '
                      'servers. Tiles already on the phone are not downloaded '
                      'again.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_busy) ...[
                    LinearProgressIndicator(value: _progress?.fraction),
                    Text(
                      _progress == null
                          ? 'Starting…'
                          : 'Saving ${_progress!.step} '
                                '(${_progress!.stepNo} of ${_progress!.steps})',
                    ),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_busy)
                        TextButton(
                          onPressed: () => setState(() => _cancel = true),
                          child: const Text('Cancel'),
                        ),
                      FilledButton.icon(
                        key: const Key('areaSave'),
                        onPressed: canSave ? _save : null,
                        icon: const Icon(Icons.download),
                        label: Text(
                          est == null
                              ? saveLabel
                              : '$saveLabel (~${formatBytes(est.bytes)})',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
