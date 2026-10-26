import 'package:flutter/material.dart';

import '../trip/geo.dart';
import '../trip/imports/map_layers.dart';
import '../trip/trip_controller.dart';
import 'map_import.dart';
import 'overlay_place_page.dart';
import 'trip_widgets.dart';

/// Imported layers on the Trip map: trails / routes / waypoints, offline
/// MBTiles base maps and park map overlays. Toggle, rename, recolour,
/// share, place, set opacity, delete; shows what each one uses on the
/// device.
class MapLayersPage extends StatelessWidget {
  const MapLayersPage({super.key, required this.trip, this.onShow});
  final TripController trip;

  /// Centre the Trip map here.
  final void Function(GeoPoint center)? onShow;

  @override
  Widget build(BuildContext context) {
    final layers = trip.layers;
    return Scaffold(
      appBar: AppBar(title: const Text('Map layers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => pickAndImportMap(context, trip),
        icon: const Icon(Icons.file_open),
        label: const Text('Import'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([layers, trip]),
        builder: (context, _) {
          final used = layers.usedBytes;
          final frac = layers.limitBytes == 0 ? 0.0 : used / layers.limitBytes;
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              ListTile(
                leading: const Icon(Icons.sd_storage),
                title: Text(
                  'Using ${formatBytes(used)} of ${formatBytes(layers.limitBytes)}',
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: LinearProgressIndicator(value: frac.clamp(0, 1)),
                ),
              ),
              if (layers.all.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Import trails and maps you exported from AllTrails, '
                    'CalTopo, Gaia GPS or Google My Maps (GPX, KML, KMZ), an '
                    'offline map (MBTiles), or a park map picture or PDF. '
                    'You can also open such a file with Walkie Talkie from '
                    'your file manager, browser or email.',
                  ),
                ),
              _section(context, 'Trails, routes and waypoints', layers.trails),
              _section(context, 'Offline base maps (MBTiles)', layers.tileSets),
              _section(context, 'Park map overlays', layers.overlays),
            ],
          );
        },
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<MapLayer> list) {
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final l in list) _tile(context, l),
      ],
    );
  }

  Widget _tile(BuildContext context, MapLayer l) {
    final layers = trip.layers;
    final isBase = trip.baseTiles?.id == l.id;
    final size = l.sourceBytes != 0 && l.sourceBytes != l.bytes
        ? '${formatBytes(l.bytes)} (file ${formatBytes(l.sourceBytes)})'
        : formatBytes(l.bytes);
    final from = l.from == null ? '' : ' · from ${trip.host.nameOf(l.from!)}';
    final Widget lead = switch (l.kind) {
      MapLayerKind.trail => CircleAvatar(
        radius: 14,
        backgroundColor: Color(l.color),
        child: const Icon(Icons.route, size: 16, color: Colors.white),
      ),
      MapLayerKind.tiles => const Icon(Icons.map),
      MapLayerKind.overlay => const Icon(Icons.image),
    };
    return Column(
      children: [
        ListTile(
          leading: lead,
          title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
                  if (l.summary.isNotEmpty) l.summary,
                  size,
                  if (l.kind == MapLayerKind.overlay && !l.placed)
                    'not placed yet',
                  if (isBase) 'base map',
                ].join(' · ') +
                from +
                (l.attribution.isEmpty ? '' : '\n${l.attribution}'),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (l.kind == MapLayerKind.tiles)
                Switch(
                  value: isBase,
                  onChanged: (v) => trip.update(
                    (s) => s.mapSource = v ? 'mbtiles:${l.id}' : 'topo',
                  ),
                )
              else
                Switch(
                  value: l.visible,
                  onChanged: l.kind == MapLayerKind.overlay && !l.placed
                      ? null
                      : (v) => layers.setVisible(l, v),
                ),
              PopupMenuButton<String>(
                onSelected: (v) => _action(context, l, v),
                itemBuilder: (_) => [
                  if (onShow != null)
                    const PopupMenuItem(
                      value: 'show',
                      child: Text('Show on map'),
                    ),
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  if (l.kind == MapLayerKind.trail) ...[
                    const PopupMenuItem(value: 'color', child: Text('Colour')),
                    const PopupMenuItem(
                      value: 'share',
                      child: Text('Share with the group'),
                    ),
                  ],
                  if (l.kind == MapLayerKind.overlay)
                    PopupMenuItem(
                      value: 'place',
                      child: Text(
                        l.placed ? 'Adjust placement' : 'Place on the map',
                      ),
                    ),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
        if (l.kind == MapLayerKind.overlay && l.placed)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 4),
            child: Row(
              children: [
                const Text('Opacity'),
                Expanded(
                  child: Slider(
                    value: l.opacity,
                    min: 0.1,
                    max: 1,
                    onChanged: (v) => layers.setOpacity(l, v),
                  ),
                ),
                Text('${(l.opacity * 100).round()}%'),
              ],
            ),
          ),
      ],
    );
  }

  GeoPoint? _centerOf(MapLayer l) {
    switch (l.kind) {
      case MapLayerKind.trail:
        final pts = l.data?.allPoints.toList() ?? const [];
        if (pts.isEmpty) return null;
        var la = 0.0, ln = 0.0;
        for (final p in pts) {
          la += p.lat;
          ln += p.lng;
        }
        return GeoPoint(la / pts.length, ln / pts.length);
      case MapLayerKind.tiles:
        final mb = trip.layers.tilesOf(l.id);
        final c = mb?.center;
        if (c != null) return GeoPoint(c.$1, c.$2);
        final b = mb?.bounds;
        return b == null
            ? null
            : GeoPoint((b.south + b.north) / 2, (b.west + b.east) / 2);
      case MapLayerKind.overlay:
        return l.georef?.toMap((u: l.imageW / 2, v: l.imageH / 2));
    }
  }

  Future<void> _action(BuildContext context, MapLayer l, String v) async {
    final layers = trip.layers;
    switch (v) {
      case 'show':
        final c = _centerOf(l);
        if (c != null) {
          if (!l.visible) await layers.setVisible(l, true);
          onShow?.call(c);
          if (context.mounted) Navigator.pop(context);
        }
      case 'rename':
        final n = await askText(context, title: 'Layer name', initial: l.name);
        if (n != null) await layers.rename(l, n);
      case 'color':
        final c = await showDialog<int>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Line colour'),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final c in layerColors)
                      InkWell(
                        onTap: () => Navigator.pop(ctx, c),
                        child: CircleAvatar(
                          backgroundColor: Color(c),
                          child: c == l.color
                              ? const Icon(Icons.check, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        if (c != null) await layers.recolor(l, c);
      case 'share':
        final r = trip.shareLayer(l);
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(
                r.parts == 0
                    ? 'Nothing to share.'
                    : 'Shared ${l.name} with the group (${r.parts} '
                          'compressed part${r.parts == 1 ? '' : 's'} over '
                          'Wi-Fi, Bluetooth, internet and the phone mesh)'
                          '${r.radio ? ', and a 16-point outline over the LoRa radio' : '; too detailed for the LoRa radio'}.',
              ),
            ),
          );
        }
      case 'place':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => OverlayPlacePage(trip: trip, layer: l),
          ),
        );
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${l.name}?'),
            content: Text('Frees ${formatBytes(l.bytes)} on this phone.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        if (trip.baseTiles?.id == l.id) {
          await trip.update((s) => s.mapSource = 'topo');
        }
        await layers.delete(l);
    }
  }
}
