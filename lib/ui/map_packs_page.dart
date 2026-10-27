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
    if (!l.visible) await trip.layers.setVisible(l, true);
    if (l.kind == MapLayerKind.tiles && trip.baseTiles == null) {
      await trip.update((s) => s.mapSource = 'mbtiles:${l.id}');
    }
  }
  return unionBounds([for (final l in added) layerBounds(trip.layers, l)]);
}

/// "Added 1 map layer; 2 were already on this phone (not copied again)".
String addedMessage(List<MapLayer> added, String? baseId) {
  final found = added.where((l) => l.packMatched).length;
  final fresh = added.length - found;
  final parts = [
    if (fresh > 0) 'Added $fresh map ${fresh == 1 ? 'layer' : 'layers'}',
    if (found > 0)
      '${fresh > 0 ? '' : 'Already added: '}$found ${found == 1 ? 'was' : 'were'} '
          'already on this phone (not copied again)',
    if (baseId != null && added.any((l) => l.id == baseId))
      'the topo map is the base map',
  ];
  final m = parts.join('; ');
  return '${m[0].toUpperCase()}${m.substring(1)}.';
}

/// "Remove duplicate maps": shown when the same map or trail was imported
/// more than once; keeps one copy of each.
class DuplicateMapsCard extends StatefulWidget {
  const DuplicateMapsCard({super.key, required this.trip});
  final TripController trip;

  @override
  State<DuplicateMapsCard> createState() => _DuplicateMapsCardState();
}

class _DuplicateMapsCardState extends State<DuplicateMapsCard> {
  List<List<MapLayer>> _dups = const [];
  bool _hidden = false, _busy = false;
  String _seen = '';

  @override
  Widget build(BuildContext context) {
    final layers = widget.trip.layers;
    final key = layers.all.map((l) => l.id).join(',');
    if (key != _seen) {
      _seen = key;
      unawaited(
        findDuplicates(layers).then((d) {
          if (mounted) setState(() => _dups = d);
        }),
      );
    }
    if (_hidden || _dups.isEmpty) return const SizedBox.shrink();
    final extra = _dups.fold(0, (s, g) => s + g.length - 1);
    final bytes = _dups.fold(
      0,
      (s, g) => s + g.skip(1).fold(0, (t, l) => t + l.bytes),
    );
    final names = _dups.map((g) => g.first.name).toSet().join(', ');
    return Card(
      key: const Key('duplicateMaps'),
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$extra duplicate ${extra == 1 ? 'copy' : 'copies'} '
              '(${formatBytes(bytes)})',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text('$names: imported more than once. Keeps one of each.'),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => setState(() => _hidden = true),
                  child: const Text('Keep them'),
                ),
                FilledButton(
                  key: const Key('removeDuplicates'),
                  onPressed: _busy ? null : _clean,
                  child: const Text('Remove duplicate maps'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clean() async {
    setState(() => _busy = true);
    final trip = widget.trip;
    final r = await cleanDuplicates(trip);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _dups = const [];
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Removed ${r.removed} duplicate '
          '${r.removed == 1 ? 'copy' : 'copies'}, freed ${formatBytes(r.freedBytes)}.',
        ),
      ),
    );
  }
}

/// Remove duplicate layers, keeping the base map selection working.
Future<DuplicateCleanup> cleanDuplicates(TripController trip) async {
  final base = trip.baseTiles?.id;
  final r = await removeDuplicates(trip.layers, prefer: base);
  final moved = base == null ? null : r.kept[base];
  if (moved != null) {
    await trip.update((s) => s.mapSource = 'mbtiles:${moved.id}');
  }
  return r;
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
      SnackBar(content: Text(addedMessage(added, trip.baseTiles?.id))),
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
                'Trails, topo maps and roads for these areas, ready to use. Tap '
                'Add: the app downloads them and puts them on the map, no '
                'files to find. Once added they work with no signal.',
              ),
            ),
            DuplicateMapsCard(trip: trip),
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

  Widget _fileRow(BuildContext context, MapPack p, PackFile f) {
    final l = trip.layers.all
        .where((l) => l.pack == p.id && l.packFile == f.name)
        .firstOrNull;
    final status = l == null
        ? (f.asset != null ? 'in the app' : formatBytes(f.size))
        : l.packMatched
        ? 'Already added'
        : 'Added';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(
            l != null ? Icons.check : Icons.circle_outlined,
            size: 16,
            color: l != null ? Colors.green : null,
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(f.title.isEmpty ? f.name : f.title)),
          Text(status, style: Theme.of(context).textTheme.bodySmall),
        ],
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
      if (p.files.any((f) => f.kind == PackFileKind.roads))
        'offline roads for driving directions',
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
                  added
                      ? Icons.check_circle
                      : p.files.every((f) => f.kind == PackFileKind.roads)
                      ? Icons.alt_route
                      : Icons.terrain,
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
            for (final f in p.files) _fileRow(context, p, f),
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
