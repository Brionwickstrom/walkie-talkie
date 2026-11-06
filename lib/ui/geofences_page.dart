/// v2.6.8: list, edit, mute and delete geofence zones.
library;

import 'package:flutter/material.dart';

import '../trip/geo.dart';
import '../trip/geofence.dart';
import '../trip/trip_controller.dart';
import 'friendly_error.dart';
import 'settings_search.dart';

/// Manage zones drawn on the Trip map.
class GeofencesPage extends StatefulWidget {
  const GeofencesPage({
    super.key,
    required this.trip,
    this.nameOf,
    this.candidateIds = const [],
    this.onDraw,
  });

  final TripController trip;

  /// Display name for a node / friend id.
  final String Function(int id)? nameOf;

  /// Radios / friends the user can watch (never public nodes).
  final List<({int id, String name})> candidateIds;

  /// Start draw mode on the Trip map: 'circle' or 'polygon'.
  final void Function(GeofenceShape shape)? onDraw;

  @override
  State<GeofencesPage> createState() => _GeofencesPageState();
}

class _GeofencesPageState extends State<GeofencesPage> {
  TripController get trip => widget.trip;
  GeofenceStore get store => trip.geofences;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final zones = store.zones;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Geofences'),
            actions: [
              PopupMenuButton<GeofenceShape>(
                key: const Key('geofence-draw'),
                tooltip: 'Draw a zone',
                icon: const Icon(Icons.add),
                onSelected: (s) {
                  final draw = widget.onDraw;
                  if (draw == null) return;
                  Navigator.of(context).pop();
                  draw(s);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: GeofenceShape.circle,
                    child: Text('Draw a circle'),
                  ),
                  PopupMenuItem(
                    value: GeofenceShape.polygon,
                    child: Text('Draw a polygon'),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              SettingAnchor(
                id: 'geofences',
                child: Text(
                  'Zones on the Trip map. The app alerts when a watched '
                  'radio or friend enters or leaves one. It uses positions '
                  'it already has — no extra radio requests or GPS polling.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 8),
              SettingAnchor(
                id: 'geofence-draw',
                child: Text(
                  'Battery: almost none. Alerts only fire on positions the '
                  'app already receives (mesh, friends, home location). A '
                  '25 m edge buffer and a 3-minute cooldown stop GPS jitter '
                  'from spamming you.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
              if (zones.isEmpty)
                const ListTile(
                  key: Key('geofence-empty'),
                  leading: Icon(Icons.fence),
                  title: Text('No zones yet'),
                  subtitle: Text('Tap + to draw a circle or a polygon.'),
                )
              else
                for (final z in zones) _zoneTile(context, z),
            ],
          ),
        );
      },
    );
  }

  Widget _zoneTile(BuildContext context, GeofenceZone z) {
    final who = z.watch == GeofenceWatch.all
        ? 'All radios & friends'
        : z.watchIds.isEmpty
        ? 'Nobody (pick who to watch)'
        : z.watchIds
              .map((id) => widget.nameOf?.call(id) ?? id.toRadixString(16))
              .join(', ');
    final shape = z.isCircle
        ? 'Circle · ${z.radiusM!.round()} m'
        : 'Polygon · ${z.vertices.length} corners';
    return Card(
      key: Key('geofence-zone-${z.id}'),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Color(z.colorArgb),
          radius: 12,
        ),
        title: Text(z.name),
        subtitle: Text(
          '$shape\n$who${z.muted ? '\nMuted' : ''}',
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (a) => _act(context, z, a),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'watch', child: Text('Who to watch')),
            PopupMenuItem(
              value: 'mute',
              child: Text(z.muted ? 'Unmute alerts' : 'Mute alerts'),
            ),
            const PopupMenuItem(
              value: 'color',
              child: Text('Change colour'),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete'),
            ),
          ],
        ),
        onTap: () => _act(context, z, 'watch'),
      ),
    );
  }

  Future<void> _act(BuildContext context, GeofenceZone z, String a) async {
    switch (a) {
      case 'rename':
        final name = await _askName(context, z.name);
        if (name == null || !context.mounted) return;
        if (!await store.rename(z.id, name)) {
          if (context.mounted) {
            showFriendlySnack(
              context,
              const FriendlyError('Give this zone a name.'),
              null,
            );
          }
        }
      case 'mute':
        await store.setMuted(z.id, !z.muted);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${z.name}?'),
            content: const Text('This cannot be undone.'),
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
        if (ok == true) await store.remove(z.id);
      case 'watch':
        await _editWatch(context, z);
      case 'color':
        await _editColor(context, z);
    }
  }

  Future<String?> _askName(BuildContext context, String current) async {
    final ctl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Zone name'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Yard, Gate, …'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _editWatch(BuildContext context, GeofenceZone z) async {
    var mode = z.watch;
    final picked = Set<int>.of(z.watchIds);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text('Watch for ${z.name}'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('All radios & friends'),
                  subtitle: const Text('Not public LongFast radios'),
                  leading: Icon(
                    mode == GeofenceWatch.all
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  onTap: () => setSt(() => mode = GeofenceWatch.all),
                ),
                ListTile(
                  title: const Text('Specific people'),
                  leading: Icon(
                    mode == GeofenceWatch.specific
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  onTap: () => setSt(() => mode = GeofenceWatch.specific),
                ),
                if (mode == GeofenceWatch.specific)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final c in widget.candidateIds)
                          CheckboxListTile(
                            dense: true,
                            value: picked.contains(c.id),
                            title: Text(c.name),
                            onChanged: (on) => setSt(() {
                              if (on == true) {
                                picked.add(c.id);
                              } else {
                                picked.remove(c.id);
                              }
                            }),
                          ),
                        if (widget.candidateIds.isEmpty)
                          const ListTile(
                            title: Text('No radios or friends to pick yet.'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await store.update(
      z.copyWith(watch: mode, watchIds: mode == GeofenceWatch.all ? {} : picked),
    );
  }

  Future<void> _editColor(BuildContext context, GeofenceZone z) async {
    const colours = <int>[
      0xFF2196F3,
      0xFF4CAF50,
      0xFFE91E63,
      0xFFFF9800,
      0xFF9C27B0,
      0xFFF44336,
      0xFF00BCD4,
      0xFF795548,
    ];
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Zone colour'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in colours)
              InkWell(
                onTap: () => Navigator.pop(ctx, c),
                child: CircleAvatar(
                  backgroundColor: Color(c),
                  radius: 18,
                  child: z.colorArgb == c
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await store.update(z.copyWith(colorArgb: picked));
  }
}

/// Finish a drawn draft: name it and save.
Future<GeofenceZone?> saveGeofenceDraft(
  BuildContext context, {
  required GeofenceStore store,
  required GeofenceShape shape,
  GeoPoint? center,
  double? radiusM,
  List<GeoPoint>? vertices,
}) async {
  final err = validateGeofenceDraft(
    shape: shape,
    center: center,
    radiusM: radiusM,
    vertices: vertices,
    name: 'Zone',
  );
  if (err != null) {
    showFriendlySnack(context, FriendlyError(err), null);
    return null;
  }
  final ctl = TextEditingController(
    text: shape == GeofenceShape.circle ? 'Yard' : 'Area',
  );
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Name this zone'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Yard, Gate, …'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name == null || !context.mounted) return null;
  final bad = validateGeofenceDraft(
    shape: shape,
    center: center,
    radiusM: radiusM,
    vertices: vertices,
    name: name,
  );
  if (bad != null) {
    showFriendlySnack(context, FriendlyError(bad), null);
    return null;
  }
  return store.add(
    GeofenceZone(
      id: '',
      name: name.trim(),
      shape: shape,
      center: center,
      radiusM: radiusM,
      vertices: vertices ?? const [],
    ),
  );
}
