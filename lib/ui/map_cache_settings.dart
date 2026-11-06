// v2.6.11: Settings > Map. The map cache (its size, a limit, Clear map
// cache) and "Keep home area ready" (Wi-Fi or charging only).
import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../trip/imports/map_layers.dart' show formatBytes;
import '../trip/map_start.dart';
import '../trip/tile_cache.dart';
import '../trip/trip_controller.dart';
import '../trip/trip_settings.dart';
import 'friendly_error.dart';
import 'settings_search.dart';

/// The map cache size in one line.
String mapCacheLine(MapCacheStats s, int limitMb) {
  final viewed = s.viewedTiles == 0
      ? 'No map tiles from looking around'
      : '${formatBytes(s.viewedBytes)} of map tiles from looking around';
  final saved = s.savedTiles == 0
      ? ''
      : ' · ${formatBytes(s.savedBytes)} in saved offline areas';
  return '$viewed$saved. Limit ${formatMb(limitMb)}.';
}

String formatMb(int mb) =>
    mb >= 1000 && mb % 1000 == 0 ? '${mb ~/ 1000} GB' : '$mb MB';

class MapCacheSettings extends StatefulWidget {
  const MapCacheSettings({super.key, required this.trip, this.controller});
  final TripController trip;

  /// For fix buttons that act on the app (none needed so far).
  final WalkieController? controller;

  @override
  State<MapCacheSettings> createState() => _MapCacheSettingsState();
}

class _MapCacheSettingsState extends State<MapCacheSettings> {
  MapCacheStats? _stats;
  bool _busy = false;
  FriendlyError? _error;

  TripController get t => widget.trip;

  @override
  void initState() {
    super.initState();
    _count();
  }

  Future<void> _count() async {
    final s = await t.mapCacheStats();
    if (mounted) setState(() => _stats = s);
  }

  Future<void> _clear() async {
    final s = _stats;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear map cache?'),
        content: Text(
          'Deletes ${s == null ? 'the' : formatBytes(s.viewedBytes)} map '
          'tiles you have looked at. Saved offline areas stay. The map '
          'downloads tiles again as you look around, so the next start '
          'is slower and uses some data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('map-cache-clear-ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final freed = await t.clearMapCache();
      PaintingBinding.instance.imageCache.clear();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Map cache cleared: ${formatBytes(freed)} freed. Saved offline '
            'areas kept.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = mapCacheClearError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _count();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final limit = t.settings.mapCacheMb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingAnchor(
          id: 'map-cache',
          child: ListTile(
            key: const Key('map-cache'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.layers_clear),
            title: const Text('Map cache'),
            subtitle: Text(
              s == null
                  ? 'Counting...'
                  : '${mapCacheLine(s, limit)} Tiles you have looked at '
                        'open the map at once, even with no signal.',
              key: const Key('map-cache-size'),
            ),
            trailing: TextButton(
              key: const Key('map-cache-clear'),
              onPressed: _busy || s == null || s.viewedTiles == 0
                  ? null
                  : _clear,
              child: Text(_busy ? 'Clearing...' : 'Clear'),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FriendlyErrorView(
              error: _error!,
              onFix: (a) => runFix(
                context,
                widget.controller,
                a,
                callbacks: FixCallbacks(retry: _clear),
              ),
              onDismiss: () => setState(() => _error = null),
            ),
          ),
        SettingAnchor(
          id: 'map-cache-limit',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storage),
            title: const Text('Map cache limit'),
            subtitle: const Text(
              'Past this, the tiles not looked at for longest are deleted '
              'first. Saved offline areas are never deleted.',
            ),
            trailing: DropdownButton<int>(
              key: const Key('map-cache-limit'),
              value: limit,
              onChanged: (v) async {
                if (v == null) return;
                await t.update((x) => x.mapCacheMb = v);
                if (mounted) setState(() {});
              },
              items: [
                for (final v in TripSettings.mapCacheChoices)
                  DropdownMenuItem(value: v, child: Text(formatMb(v))),
              ],
            ),
          ),
        ),
        SettingAnchor(
          id: 'map-warm-home',
          child: SwitchListTile(
            key: const Key('map-warm-home'),
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.home_work_outlined),
            title: const Text('Keep home area ready'),
            subtitle: Text(
              'Saves the map within about '
              '${(HomeWarmer.radiusM / 1000).toStringAsFixed(1)} km of home (the home '
              'location, else where the map was last left) so it opens at '
              'once. Only on Wi-Fi or while charging, about 1-3 MB once a '
              'week. Not for Street (OpenStreetMap), which does not allow '
              'saving ahead.'
              '${t.settings.warmHome && t.warmStatus != null ? ' Now: ${t.warmStatus}' : ''}',
            ),
            value: t.settings.warmHome,
            onChanged: (v) async {
              await t.update((x) => x.warmHome = v);
              if (!v) t.warmer.cancel();
              if (mounted) setState(() {});
            },
          ),
        ),
      ],
    );
  }
}
