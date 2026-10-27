import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../trip/imports/map_layers.dart';
import '../trip/imports/map_packs.dart';
import '../trip/tile_cache.dart';
import '../trip/trip_controller.dart';

/// The pack list for this app run (bundled + latest from GitHub).
PackCatalog? _catalog;

PackCatalog packCatalog(TripController trip) => _catalog ??= PackCatalog(
  bundled: () => rootBundle.loadString('map_packs.json'),
  fetch: PackCatalog.httpFetch,
  cacheFile: File('${trip.layers.dir.path}/map_packs_cache.json'),
);

/// After adding layers: an offline base map becomes the base map when none
/// is selected yet (the first one), then the map moves to them.
Future<GeoBounds?> afterAdding(
  TripController trip,
  List<MapLayer> added,
) async {
  for (final l in added) {
    if (l.kind == MapLayerKind.tiles && trip.baseTiles == null) {
      await trip.update((s) => s.mapSource = 'mbtiles:${l.id}');
    }
  }
  return unionBounds([for (final l in added) layerBounds(trip.layers, l)]);
}

/// "Ready-made maps" (v1.9.0): packs that download and add themselves.
class MapPacksPage extends StatefulWidget {
  const MapPacksPage({
    super.key,
    required this.trip,
    this.onFit,
    this.autoAdd = const {},
    this.catalog,
    this.installer,
  });
  final TripController trip;

  /// Move the Trip map to these bounds (and close the pages above it).
  final void Function(GeoBounds b)? onFit;

  /// Pack ids to add right away (the "maps are ready" banner).
  final Set<String> autoAdd;

  /// Tests.
  final PackCatalog? catalog;
  final PackInstaller? installer;

  @override
  State<MapPacksPage> createState() => _MapPacksPageState();
}

class _MapPacksPageState extends State<MapPacksPage> {
  List<MapPack> _packs = const [];
  bool _loading = true;
  final Map<String, PackProgress?> _busy = {};
  final Map<String, String> _errors = {};
  bool _cancel = false;
  bool _queue = false;

  TripController get trip => widget.trip;
  PackCatalog get _cat => widget.catalog ?? packCatalog(trip);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _cancel = true;
    super.dispose();
  }

  Future<void> _load() async {
    // Bundled list first (instant, works offline), then the latest.
    final first = await _cat.load(refresh: false);
    if (!mounted) return;
    setState(() {
      _packs = first;
      _loading = false;
    });
    if (widget.autoAdd.isNotEmpty) {
      unawaited(
        _addAll([
          for (final p in first)
            if (widget.autoAdd.contains(p.id)) p,
        ]),
      );
    }
    final latest = await _cat.load();
    if (mounted) setState(() => _packs = latest);
  }

  Future<PackInstaller> _installer() async =>
      widget.installer ??
      PackInstaller(
        layers: trip.layers,
        tempDir: Directory('${(await getTemporaryDirectory()).path}/packs'),
        readAsset: (k) async => (await rootBundle.load(k)).buffer.asUint8List(),
      );

  Future<void> _addAll(List<MapPack> packs) async {
    if (_queue) return;
    _queue = true;
    _cancel = false;
    final added = <MapLayer>[];
    try {
      for (final p in packs) {
        if (packAdded(p, trip.layers)) continue;
        added.addAll(await _add(p, fit: false));
        if (_cancel) return;
      }
    } finally {
      _queue = false;
    }
    await _finish(added);
  }

  Future<List<MapLayer>> _add(MapPack p, {bool fit = true}) async {
    if (fit) _cancel = false;
    setState(() {
      _errors.remove(p.id);
      _busy[p.id] = null;
    });
    final inst = await _installer();
    try {
      final out = await inst.add(
        p,
        onProgress: (pr) {
          if (mounted) setState(() => _busy[p.id] = pr);
        },
        cancelled: () => _cancel,
      );
      if (mounted) setState(() => _busy.remove(p.id));
      if (fit) await _finish(out);
      return out;
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy.remove(p.id);
          _errors[p.id] = '$e';
        });
      }
      return const [];
    }
  }

  Future<void> _finish(List<MapLayer> added) async {
    if (added.isEmpty || !mounted) return;
    final b = await afterAdding(trip, added);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Added ${added.length} map ${added.length == 1 ? 'layer' : 'layers'}'
          '${trip.baseTiles != null && added.any((l) => l.id == trip.baseTiles!.id) ? '; the topo map is now the base map' : ''}.',
        ),
      ),
    );
    if (b != null) widget.onFit?.call(b);
  }

  Future<void> _remove(MapPack p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: const Text(
          'Deletes its trails and maps from this phone. You can add the '
          'pack again any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final l in trip.layers.all.where((l) => l.pack == p.id).toList()) {
      if (trip.baseTiles?.id == l.id) {
        await trip.update((s) => s.mapSource = 'topo');
      }
      await trip.layers.delete(l);
    }
    if (mounted) setState(() {});
  }

  void _show(MapPack p) {
    final b =
        unionBounds([
          for (final l in trip.layers.all.where((l) => l.pack == p.id))
            layerBounds(trip.layers, l),
        ]) ??
        p.bounds;
    if (b != null) widget.onFit?.call(b);
  }

  @override
  Widget build(BuildContext context) {
    final missing = [
      for (final p in _packs)
        if (!packAdded(p, trip.layers)) p,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Ready-made maps')),
      body: ListenableBuilder(
        listenable: trip.layers,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Trails and topo maps for these areas, ready to use. Tap '
                'Add: the app downloads them and puts them on the map, no '
                'files to find. Once added they work with no signal.',
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (missing.length > 1 && _busy.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FilledButton.icon(
                  key: const Key('addAllPacks'),
                  onPressed: () => _addAll(missing),
                  icon: const Icon(Icons.download),
                  label: Text(
                    'Add all (${formatBytes(missing.fold(0, (s, p) => s + p.downloadSize))})',
                  ),
                ),
              ),
            for (final p in _packs) _card(context, p),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, MapPack p) {
    final layers = trip.layers;
    final added = packAdded(p, layers);
    final some = addedFiles(p, layers).isNotEmpty;
    final busy = _busy.containsKey(p.id);
    final pr = _busy[p.id];
    final err = _errors[p.id];
    final dl = p.downloadSize;
    final kinds = [
      if (p.files.any((f) => f.kind == PackFileKind.trail)) 'trails',
      if (p.files.any((f) => f.kind == PackFileKind.tiles)) 'offline topo map',
      if (p.files.any((f) => f.kind == PackFileKind.overlay))
        'topo map picture',
    ].join(' + ');
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  added ? Icons.check_circle : Icons.terrain,
                  color: added ? Colors.green : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (added)
                  const Chip(
                    label: Text('Added'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (p.area.isNotEmpty)
              Text(p.area, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(p.about.isNotEmpty ? p.about : kinds),
            const SizedBox(height: 4),
            Text(
              '$kinds · ${formatBytes(p.size)}'
              '${dl != p.size ? ' (${formatBytes(dl)} to download)' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: pr?.fraction),
              const SizedBox(height: 4),
              Text(
                pr == null
                    ? 'Starting…'
                    : '${pr.step} ${pr.file} · ${formatBytes(pr.done)} of ${formatBytes(pr.total)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (err != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  err,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (!added && !busy)
                  FilledButton.icon(
                    key: Key('addPack:${p.id}'),
                    onPressed: _queue ? null : () => _add(p),
                    icon: const Icon(Icons.download),
                    label: Text(
                      some ? 'Finish adding' : 'Add (${formatBytes(dl)})',
                    ),
                  ),
                if (some && !busy)
                  OutlinedButton.icon(
                    onPressed: () => _show(p),
                    icon: const Icon(Icons.map),
                    label: const Text('Show on map'),
                  ),
                if (busy)
                  TextButton(
                    onPressed: () => setState(() => _cancel = true),
                    child: const Text('Cancel'),
                  ),
                if (some && !busy)
                  TextButton(
                    onPressed: () => _remove(p),
                    child: const Text('Remove'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
