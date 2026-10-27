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
import '../trip/search/overpass.dart' show boundsSizeKm;
import '../trip/tile_cache.dart';
import '../trip/trip_controller.dart';
import 'map_layer_widgets.dart';
import 'map_packs_page.dart';
import 'trip_widgets.dart' show askText;

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String areaSize(GeoBounds b) {
  final k = boundsSizeKm(b);
  return '${k.w.round()} x ${k.h.round()} km';
}

/// "Offline roads" (v1.9.2): the road areas saved for driving directions;
/// save a new one, update, rename, delete.
class RoadAreasPage extends StatelessWidget {
  const RoadAreasPage({
    super.key,
    required this.trip,
    this.view,
    this.onFit,
    this.downloader,
  });
  final TripController trip;

  /// The Trip map's view (a starting box for a new area).
  final GeoBounds? view;
  final void Function(GeoBounds b)? onFit;

  /// Tests.
  final RoadDownloader? downloader;

  Future<void> _pick(BuildContext context, {MapLayer? replace}) async {
    final l = await Navigator.of(context).push<MapLayer>(
      MaterialPageRoute(
        builder: (_) => RoadAreaPickerPage(
          trip: trip,
          initial: replace?.area ?? view,
          replace: replace,
          downloader: downloader,
        ),
      ),
    );
    if (l != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '${replace == null ? 'Saved' : 'Updated'} ${l.name}: ${l.summary} '
            '(${formatBytes(l.bytes)}).',
          ),
        ),
      );
    }
  }

  Future<void> _updatePack(BuildContext context, MapLayer l) async {
    final m = ScaffoldMessenger.maybeOf(context);
    final packs = await packCatalog(trip).load();
    final p = packs.where((p) => p.id == l.pack).firstOrNull;
    final f = p?.files.where((f) => f.name == l.packFile).firstOrNull;
    if (p == null || f == null) {
      m?.showSnackBar(
        const SnackBar(content: Text('This pack is no longer listed.')),
      );
      return;
    }
    if (f.sha256 != null && f.sha256 == l.sha) {
      m?.showSnackBar(
        SnackBar(content: Text('${l.name} is up to date (${l.summary}).')),
      );
      return;
    }
    m?.showSnackBar(SnackBar(content: Text('Updating ${l.name}…')));
    try {
      final inst = PackInstaller(
        layers: trip.layers,
        tempDir: Directory('${(await getTemporaryDirectory()).path}/packs'),
        readAsset: (k) async => (await rootBundle.load(k)).buffer.asUint8List(),
      );
      await trip.layers.delete(l);
      await inst.add(p);
      m?.showSnackBar(SnackBar(content: Text('Updated ${l.name}.')));
    } catch (e) {
      m?.showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _menu(BuildContext context, MapLayer l, String v) async {
    switch (v) {
      case 'show':
        final b = l.area;
        if (b != null) {
          onFit?.call(b);
          Navigator.pop(context);
        }
      case 'update':
        if (l.pack != null) {
          await _updatePack(context, l);
        } else {
          await _pick(context, replace: l);
        }
      case 'rename':
        final n = await askText(context, title: 'Area name', initial: l.name);
        if (n != null) await trip.layers.rename(l, n);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${l.name}?'),
            content: Text(
              'Frees ${formatBytes(l.bytes)}. Driving directions there stop '
              'working until you save the area again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('roadDeleteOk'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok == true) await trip.layers.delete(l);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline roads')),
      body: ListenableBuilder(
        listenable: trip.layers,
        builder: (context, _) {
          final areas = trip.layers.roads;
          final total = areas.fold(0, (s, l) => s + l.bytes);
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Roads saved on this phone give driving directions with no '
                  'signal (Drive here). All saved areas are used together, so '
                  'a route can run from one area into the next.',
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FilledButton.icon(
                      key: const Key('addRoadArea'),
                      onPressed: () => _pick(context),
                      icon: const Icon(Icons.crop_free),
                      label: const Text('Save roads for an area'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('roadPacks'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              MapPacksPage(trip: trip, onFit: onFit),
                        ),
                      ),
                      icon: const Icon(Icons.terrain),
                      label: const Text('Ready-made maps'),
                    ),
                  ],
                ),
              ),
              if (areas.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No roads saved yet. Tip: Ready-made maps has "Portland '
                    'to Gifford Pinchot roads" (one tap).',
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    '${areas.length} saved ${areas.length == 1 ? 'area' : 'areas'} · ${formatBytes(total)}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              for (final l in areas)
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: ListTile(
                    key: Key('roadArea:${l.id}'),
                    leading: const Icon(Icons.alt_route),
                    title: Text(l.name),
                    subtitle: Text(
                      [
                        if (l.summary.isNotEmpty) l.summary,
                        formatBytes(l.bytes),
                        if (l.area != null) areaSize(l.area!),
                        '${l.pack != null ? 'Ready-made' : 'Saved'} ${_date(l.added)}',
                      ].join(' · '),
                    ),
                    onTap: () => _menu(context, l, 'show'),
                    trailing: PopupMenuButton<String>(
                      key: Key('roadMenu:${l.id}'),
                      onSelected: (v) => _menu(context, l, v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'show',
                          child: Text('Show on map'),
                        ),
                        PopupMenuItem(value: 'update', child: Text('Update')),
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Roads © OpenStreetMap contributors (ODbL). Forest roads '
                  'tagged rough, high-clearance (4WD), private or closed '
                  'for the season are marked or avoided.',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Pick an area (drag the corners, or use the map view), see its size,
/// save its roads.
class RoadAreaPickerPage extends StatefulWidget {
  const RoadAreaPickerPage({
    super.key,
    required this.trip,
    this.initial,
    this.replace,
    this.downloader,
    this.showTiles = true,
  });
  final TripController trip;
  final GeoBounds? initial;

  /// Updating this saved area.
  final MapLayer? replace;
  final RoadDownloader? downloader;

  /// Tests: no tile layers.
  final bool showTiles;

  @override
  State<RoadAreaPickerPage> createState() => _RoadAreaPickerPageState();
}

class _RoadAreaPickerPageState extends State<RoadAreaPickerPage> {
  final _map = MapController();
  final _name = TextEditingController();
  late GeoBounds _box;
  bool _ready = false;
  RoadEstimate? _est;
  bool _estimating = false;
  String? _error;
  RoadProgress? _progress;
  bool _busy = false, _cancel = false;
  Timer? _debounce;
  int _estSeq = 0;

  TripController get trip => widget.trip;
  RoadDownloader get _dl =>
      widget.downloader ?? RoadDownloader(fetch: trip.fetch);

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    final c = trip.myFix?.pos;
    _box =
        widget.replace?.area ??
        (i != null
            ? _inset(i, widget.replace == null ? 0.15 : 0)
            : c != null
            ? GeoBounds(c.lat - 0.1, c.lng - 0.14, c.lat + 0.1, c.lng + 0.14)
            : const GeoBounds(45.65, -122.45, 45.85, -122.15));
    _name.text = widget.replace?.name ?? '';
    _estimate();
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

  void _changed() {
    setState(() {
      _est = null;
      _error = RoadDownloader.checkArea(_box);
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), _estimate);
  }

  Future<void> _estimate() async {
    final why = RoadDownloader.checkArea(_box);
    if (why != null) {
      setState(() => _error = why);
      return;
    }
    if (!trip.plan.mapTileDownloads) {
      setState(
        () => _error =
            'Offline power save is on: saving roads needs the internet.',
      );
      return;
    }
    final seq = ++_estSeq;
    setState(() {
      _estimating = true;
      _error = null;
    });
    try {
      final e = await _dl.estimate(_box);
      if (!mounted || seq != _estSeq) return;
      setState(() {
        _est = e;
        _estimating = false;
      });
    } catch (e) {
      if (!mounted || seq != _estSeq) return;
      setState(() {
        _estimating = false;
        _error = 'Could not check the size: $e';
      });
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
      final l = await trip.saveRoads(
        _box,
        name: _name.text.trim(),
        replace: widget.replace,
        downloader: widget.downloader,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        cancelled: () => _cancel,
      );
      if (mounted) Navigator.pop(context, l);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
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
        s = math.min(p.latitude, n - 0.005);
      } else {
        n = math.max(p.latitude, s + 0.005);
      }
      if (k == 0 || k == 3) {
        w = math.min(p.longitude, e - 0.005);
      } else {
        e = math.max(p.longitude, w + 0.005);
      }
      b = GeoBounds(s, w, n, e);
    }
    setState(() => _box = b);
  }

  Widget _handle(int k, IconData icon) => GestureDetector(
    key: Key('roadHandle$k'),
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

  @override
  Widget build(BuildContext context) {
    final b = _box;
    final others = [
      for (final l in trip.layers.roads)
        if (l.area != null && l.id != widget.replace?.id) l.area!,
    ];
    List<LatLng> rect(GeoBounds r) => [
      _ll(r.south, r.west),
      _ll(r.south, r.east),
      _ll(r.north, r.east),
      _ll(r.north, r.west),
    ];
    final est = _est;
    final canSave =
        !_busy &&
        RoadDownloader.checkArea(b) == null &&
        trip.plan.mapTileDownloads;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.replace == null ? 'Save roads' : 'Update roads'),
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
                      padding: const EdgeInsets.all(48),
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
                        'Green: roads already saved.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
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
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('roadUseView'),
                        onPressed: _busy ? null : _useView,
                        icon: const Icon(Icons.fit_screen),
                        label: const Text('Use current view'),
                      ),
                    ],
                  ),
                  Text(
                    _estimating
                        ? 'Checking the size…'
                        : est != null
                        ? 'About ${est.ways} roads · ${formatBytes(est.bytes)} on '
                              'the phone (${formatBytes(est.downloadBytes)} to download)'
                        : '',
                    key: const Key('roadEstimate'),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      key: const Key('roadError'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (widget.replace == null)
                    TextField(
                      key: const Key('roadName'),
                      controller: _name,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: 'Name (optional)',
                        hintText: TripController.defaultRoadsName(b),
                      ),
                    ),
                  if (_busy) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _progress?.fraction),
                    Text(
                      _progress == null
                          ? 'Starting…'
                          : 'Saving roads: piece ${_progress!.done} of '
                                '${_progress!.total} (${_progress!.ways} road pieces)',
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_busy)
                        TextButton(
                          onPressed: () => setState(() => _cancel = true),
                          child: const Text('Cancel'),
                        ),
                      FilledButton.icon(
                        key: const Key('roadSave'),
                        onPressed: canSave ? _save : null,
                        icon: const Icon(Icons.download),
                        label: Text(
                          widget.replace == null
                              ? 'Save roads${est == null ? '' : ' (${formatBytes(est.bytes)})'}'
                              : 'Update roads',
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
