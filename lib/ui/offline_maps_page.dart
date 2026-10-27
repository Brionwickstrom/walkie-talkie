import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../trip/tile_cache.dart';
import '../trip/trip_controller.dart';
import 'trip_widgets.dart';

String mb(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).ceil()} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Saved offline map areas, cache size, and "download what I see".
class OfflineMapsPage extends StatefulWidget {
  const OfflineMapsPage({
    super.key,
    required this.trip,
    this.bounds,
    this.zoom,
    this.autoDownload = false,
    this.suggestedName,
  });
  final TripController trip;
  final GeoBounds? bounds;
  final double? zoom;

  /// Open the download dialog right away (from map search).
  final bool autoDownload;
  final String? suggestedName;
  @override
  State<OfflineMapsPage> createState() => _OfflineMapsPageState();
}

class _OfflineMapsPageState extends State<OfflineMapsPage> {
  TripController get t => widget.trip;
  int? _size;
  DownloadProgress? _progress;

  @override
  void initState() {
    super.initState();
    _measure();
    final b = widget.bounds;
    if (widget.autoDownload && b != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _download(context, b);
      });
    }
  }

  Future<void> _measure() async {
    final s = await t.tiles.sizeOnDisk();
    if (mounted) setState(() => _size = s);
  }

  MapSource get _downloadSource =>
      t.mapSource.allowsOffline ? t.mapSource : MapSource.topo;

  /// What "Download" saves besides the base map: the overlays that are on
  /// and may be saved, and elevation data (profiles, slope shading).
  List<({MapSource src, int z0, int z1})> _extras(int z0, int z1) {
    final out = <({MapSource src, int z0, int z1})>[];
    for (final o in t.overlays) {
      if (!o.allowsOffline || o.onlineOnly || o.id == MapSource.slope.id) {
        continue;
      }
      final a = math.max(z0, o.minZoom), b = math.min(z1, o.maxZoom);
      if (a <= b) out.add((src: o, z0: a, z1: b));
    }
    final slope = t.overlays.any((o) => o.id == MapSource.slope.id);
    // Elevation: zoom 12 for the profile; slope shading needs its zooms.
    final dz1 = slope ? math.min(z1, MapSource.slope.maxZoom) : 12;
    final dz0 = slope
        ? math.max(MapSource.slope.minZoom, math.min(z0, 12))
        : 12;
    out.add((src: MapSource.terrarium, z0: math.min(dz0, dz1), z1: dz1));
    return out;
  }

  String? _step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = widget.bounds;
    final busy = _progress != null && !_progress!.finished;
    return Scaffold(
      appBar: AppBar(title: const Text('Offline maps')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Save the area you will hike while you still have internet. Saved '
              'maps work with no signal. Areas you just look at are kept too (at '
              'least 7 days).',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (!t.mapSource.allowsOffline)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text('Downloads use ${_downloadSource.name}'),
                  subtitle: const Text(
                    'OpenStreetMap\'s own tile servers do not allow saving areas '
                    'ahead of time, so offline areas are saved from the topo map.',
                  ),
                ),
              ),
            if (b != null)
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('Download the area on screen'),
                onPressed: busy ? null : () => _download(context, b),
              )
            else
              const Text('Open the map first to pick an area.'),
            if (_progress != null) ...[
              const SizedBox(height: 12),
              if (_step != null) Text('Saving $_step'),
              LinearProgressIndicator(value: _progress!.fraction),
              Text(
                '${_progress!.done + _progress!.failed} of ${_progress!.total} tiles · '
                '${mb(_progress!.bytes)}'
                '${_progress!.failed > 0 ? ' · ${_progress!.failed} failed' : ''}'
                '${_progress!.finished ? (_progress!.cancelled ? ' · cancelled' : ' · done') : ''}',
              ),
              if (busy)
                TextButton(
                  onPressed: () => setState(() => _progress!.cancelled = true),
                  child: const Text('Cancel'),
                ),
            ],
            const Divider(height: 32),
            Text('Saved areas', style: theme.textTheme.titleMedium),
            if (t.tiles.regions.isEmpty) const Text('None yet.'),
            for (final r in List.of(t.tiles.regions))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.map),
                title: Text(r.name),
                subtitle: Text(
                  '${r.tiles} tiles · ${mb(r.bytes)} · zoom ${r.minZoom}-${r.maxZoom} · '
                  '${r.sourceId} · saved ${r.at.month}/${r.at.day} ${hhmm(r.at)}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await t.tiles.deleteRegion(r);
                    await _measure();
                  },
                ),
              ),
            const Divider(height: 32),
            Text(
              'Map storage: ${_size == null ? '...' : mb(_size!)} of ${mb(t.tiles.maxBytes)} limit',
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Delete all saved maps'),
              onPressed: busy
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete all saved maps?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await t.tiles.clear();
                        await _measure();
                      }
                    },
            ),
            const SizedBox(height: 16),
            Text(_downloadSource.attribution, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Future<void> _download(BuildContext context, GeoBounds b) async {
    final src = _downloadSource;
    final z0 = math.max(8, (widget.zoom ?? 13).floor() - 2);
    var z1 = math.min(
      src.maxZoom,
      math.max(z0, (widget.zoom ?? 13).floor() + 2),
    );
    final name = TextEditingController(
      text: widget.suggestedName ?? 'Trip area',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final est = t.tiles.estimate(src, b, z0, z1);
          final extras = _extras(z0, z1);
          final extraEst = [
            for (final e in extras) t.tiles.estimate(e.src, b, e.z0, e.z1),
          ];
          final tooBig =
              est.tiles > t.tiles.maxDownloadTiles ||
              extraEst.any((x) => x.tiles > t.tiles.maxDownloadTiles);
          final extraBytes = extraEst.fold(0, (s, x) => s + x.bytes);
          return AlertDialog(
            title: const Text('Download this area'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                Text('Detail: up to zoom $z1 (from $z0)'),
                Slider(
                  value: z1.toDouble(),
                  min: z0.toDouble(),
                  max: src.maxZoom.toDouble(),
                  divisions: math.max(1, src.maxZoom - z0),
                  label: '$z1',
                  onChanged: (v) => set(() => z1 = v.round()),
                ),
                Text(
                  'Saves ${src.name}'
                  '${extras.isEmpty ? '' : ' + ${extras.map((e) => e.src.name).join(', ')}'}',
                ),
                Text(
                  'About ${est.tiles} tiles, ~${mb(est.bytes + extraBytes)}'
                  '${tooBig ? '\nToo big (limit ${t.tiles.maxDownloadTiles} tiles): zoom the map in or lower the detail.' : ''}',
                  style: TextStyle(
                    color: tooBig ? Theme.of(ctx).colorScheme.error : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Downloads slowly on purpose to be fair to the free map servers.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: tooBig ? null : () => Navigator.pop(ctx, true),
                child: const Text('Download'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !mounted) return;
    final label = name.text.trim().isEmpty ? 'Trip area' : name.text.trim();
    final jobs = [(src: src, z0: z0, z1: z1), ..._extras(z0, z1)];
    try {
      for (var i = 0; i < jobs.length; i++) {
        final j = jobs[i];
        final p = DownloadProgress(countTiles(b, j.z0, j.z1));
        setState(() {
          _progress = p;
          _step = jobs.length > 1
              ? '${j.src.name} (${i + 1} of ${jobs.length})'
              : null;
        });
        await t.tiles.download(
          j.src,
          b,
          j.z0,
          j.z1,
          name: label,
          progress: p,
          onProgress: (_) {
            if (mounted) setState(() {});
          },
        );
        if (p.cancelled || !mounted) break;
      }
    } on StateError catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
    await t.tiles.trim();
    await _measure();
  }
}
