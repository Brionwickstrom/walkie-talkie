import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../app/walkie_controller.dart';
import '../trip/geo.dart';
import '../trip/tile_cache.dart';
import '../trip/tile_provider.dart';
import '../trip/track.dart';
import '../trip/trip_controller.dart';
import '../trip/trip_packet.dart';
import '../trip/trip_settings.dart';
import '../trip/weather.dart';
import 'home_view.dart';
import 'network_map_page.dart';
import 'offline_maps_page.dart';
import 'sheets.dart';
import 'trip_widgets.dart';

LatLng ll(GeoPoint p) => LatLng(p.lat, p.lng);
GeoPoint gp(LatLng p) => GeoPoint(p.latitude, p.longitude);

/// The Trip tab: offline map with everyone, SOS, quick messages, people
/// with distance and direction, trails, weather, network and offline maps.
/// Works online and offline (every message takes whatever path reaches).
class TripPage extends StatefulWidget {
  const TripPage({super.key, required this.controller, this.focus});
  final WalkieController controller;

  /// Center the map here when opened (e.g. from an SOS alert).
  final GeoPoint? focus;
  @override
  State<TripPage> createState() => TripPageState();
}

class TripPageState extends State<TripPage> {
  WalkieController get c => widget.controller;
  TripController? get t => c.trip;
  final MapController _map = MapController();
  final List<StreamSubscription<dynamic>> _sensors = [];
  List<double>? _acc;
  bool _mapReady = false;
  bool _follow = true;
  bool _backtrack = false;
  Track? _shown;

  @override
  void initState() {
    super.initState();
    t?.setVisible(true);
    _startCompass();
    if (widget.focus != null) _follow = false;
  }

  @override
  void dispose() {
    t?.setVisible(false);
    for (final s in _sensors) {
      s.cancel();
    }
    super.dispose();
  }

  void _startCompass() {
    try {
      _sensors.add(
        accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval)
            .listen(
              (e) => _acc = [e.x, e.y, e.z],
              onError: (_) {},
              cancelOnError: true,
            ),
      );
      _sensors.add(
        magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval)
            .listen(
              (m) {
                final a = _acc;
                if (a == null) return;
                final h = headingFromSensors(a[0], a[1], a[2], m.x, m.y, m.z);
                if (h != null) t?.onHeading(h);
              },
              onError: (_) {},
              cancelOnError: true,
            ),
      );
    } catch (_) {}
  }

  /// Center on a point (SOS alert "Map" button).
  void focusOn(GeoPoint p) {
    _follow = false;
    if (_mapReady) _map.move(ll(p), 15);
  }

  @override
  Widget build(BuildContext context) {
    final trip = t;
    if (trip == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListenableBuilder(
      listenable: trip,
      builder: (context, _) {
        final me = trip.myFix;
        if (_follow && me != null && _mapReady) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_follow) return;
            final cam = _map.camera;
            if (distanceM(gp(cam.center), me.pos) > 5) {
              _map.move(ll(me.pos), cam.zoom);
            }
          });
        }
        return LayoutBuilder(
          builder: (context, box) {
            final mapH = (box.maxHeight * 0.48).clamp(200.0, 520.0);
            return Column(
              children: [
                SizedBox(height: mapH, child: _mapView(context, trip)),
                Expanded(child: _panel(context, trip)),
              ],
            );
          },
        );
      },
    );
  }

  // ------------------------------------------------------------ map

  Widget _mapView(BuildContext context, TripController trip) {
    final src = trip.mapSource;
    final me = trip.myFix;
    final start =
        widget.focus ??
        me?.pos ??
        (trip.people.values.isNotEmpty ? trip.people.values.first.pos : null) ??
        (trip.pins.isNotEmpty ? trip.pins.first.pos : null);
    final cs = Theme.of(context).colorScheme;
    final track = _shown ?? trip.currentTrack;
    final lines = <Polyline>[
      for (final s in trip.sharedTracks.values)
        if (s.points.length > 1)
          Polyline(
            points: [for (final p in s.points) ll(p.pos)],
            strokeWidth: 3,
            color: avatarColor(s.origin).withValues(alpha: 0.8),
            pattern: s.summary
                ? StrokePattern.dashed(segments: const [8, 6])
                : const StrokePattern.solid(),
          ),
      if (track != null && track.points.length > 1)
        Polyline(
          points: [for (final p in track.points) ll(p.pos)],
          strokeWidth: 4,
          color: trip.recorder.recording ? Colors.red : Colors.blue,
        ),
      if (_backtrack && track != null && track.points.isNotEmpty && me != null)
        Polyline(
          points: [
            ll(me.pos),
            ll(track.points[backtrack(track.points, me.pos)!.index].pos),
          ],
          strokeWidth: 2,
          color: Colors.orange,
          pattern: StrokePattern.dotted(),
        ),
    ];
    final markers = <Marker>[
      for (final p in trip.pins)
        Marker(
          point: ll(p.pos),
          width: 110,
          height: 58,
          child: GestureDetector(
            onTap: () => _pinSheet(context, trip, p),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 15),
                Icon(pinIcon(p.type), color: pinColor(p.type), size: 28),
                _label(p.title, pinColor(p.type)),
              ],
            ),
          ),
        ),
      for (final pp in trip.people.values)
        Marker(
          point: ll(pp.pos),
          width: 130,
          height: 66,
          child: GestureDetector(
            onTap: () => _personSheet(context, trip, pp.id),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 17),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: avatarColor(pp.id),
                      child: Text(
                        initials(c.nameOf(pp.id)),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Positioned(
                      right: -8,
                      bottom: -4,
                      child: CircleAvatar(
                        radius: 8,
                        backgroundColor: Colors.white,
                        child: Icon(
                          pp.hops > 1 ? Icons.hub : transportIcon(pp.via),
                          size: 11,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                _label(
                  '${c.nameOf(pp.id)} · ${formatAge(DateTime.now().difference(pp.at))}',
                  avatarColor(pp.id),
                ),
              ],
            ),
          ),
        ),
      if (me != null)
        Marker(
          point: ll(me.pos),
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
              if (trip.heading != null)
                BearingArrow(
                  angleDeg: trip.heading!,
                  size: 40,
                  color: Colors.blue.withValues(alpha: 0.6),
                ),
            ],
          ),
        ),
    ];
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: start != null
                ? ll(start)
                : const LatLng(39.5, -98.35),
            initialZoom: start != null ? 15 : 4,
            maxZoom: 19,
            minZoom: 2,
            onMapReady: () {
              _mapReady = true;
              if (widget.focus != null) _map.move(ll(widget.focus!), 15);
            },
            onPositionChanged: (cam, gesture) {
              if (gesture && _follow) setState(() => _follow = false);
            },
            onLongPress: (_, point) => _addPin(context, trip, gp(point)),
          ),
          children: [
            TileLayer(
              key: ValueKey('${src.id}:${src.urlTemplate}'),
              urlTemplate: src.urlTemplate,
              subdomains: src.subdomains,
              maxNativeZoom: src.maxZoom,
              userAgentPackageName: 'com.walkie.walkie_talkie',
              tileProvider: CachedTileProvider(trip.tiles, src),
            ),
            PolylineLayer(polylines: lines),
            MarkerLayer(markers: markers),
            SimpleAttributionWidget(
              source: Text(
                src.attribution,
                style: const TextStyle(fontSize: 10),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.85),
            ),
          ],
        ),
        Positioned(
          right: 8,
          top: 8,
          child: Column(
            children: [
              _mapButton(
                _follow ? Icons.my_location : Icons.location_searching,
                _follow ? 'Following you' : 'Center on me',
                () {
                  setState(() => _follow = true);
                  final f = trip.myFix;
                  if (f != null) {
                    _map.move(
                      ll(f.pos),
                      _map.camera.zoom < 12 ? 15 : _map.camera.zoom,
                    );
                  }
                },
                color: _follow ? cs.primary : null,
              ),
              _mapButton(
                Icons.layers,
                'Map style',
                () => _styleSheet(context, trip),
              ),
              _mapButton(
                Icons.download_for_offline,
                'Offline maps',
                () => _openOffline(context, trip),
              ),
              _mapButton(
                Icons.add_location_alt,
                'Drop a pin here',
                () => _addPin(context, trip, gp(_map.camera.center)),
              ),
            ],
          ),
        ),
        if (me == null)
          Positioned(
            left: 8,
            top: 8,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(
                  'Waiting for GPS...',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _label(String s, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color, width: 1),
    ),
    child: Text(
      s,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 10,
        color: Colors.black87,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _mapButton(
    IconData icon,
    String tip,
    VoidCallback onTap, {
    Color? color,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        tooltip: tip,
        icon: Icon(icon, color: color),
        onPressed: onTap,
      ),
    ),
  );

  void _openOffline(BuildContext context, TripController trip) {
    GeoBounds? b;
    double? zoom;
    if (_mapReady) {
      final v = _map.camera.visibleBounds;
      b = GeoBounds(v.south, v.west, v.north, v.east);
      zoom = _map.camera.zoom;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OfflineMapsPage(trip: trip, bounds: b, zoom: zoom),
      ),
    );
  }

  Future<void> _styleSheet(BuildContext context, TripController trip) async {
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Map style', style: Theme.of(ctx).textTheme.titleLarge),
              for (final s in [MapSource.topo, MapSource.osm])
                ListTile(
                  leading: Icon(
                    trip.settings.mapSource == s.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(s.name),
                  subtitle: Text(
                    s.allowsOffline
                        ? 'Trails and contour lines. Small areas can be saved for offline use.'
                        : 'Streets. Cached as you look around; OpenStreetMap does not allow saving areas ahead.',
                  ),
                  onTap: () {
                    trip.update((x) => x.mapSource = s.id);
                    Navigator.pop(ctx);
                  },
                ),
              ListTile(
                leading: Icon(
                  trip.settings.mapSource == 'custom'
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: const Text('Custom tile server'),
                subtitle: Text(
                  trip.settings.customTileUrl.isEmpty
                      ? 'Your own server (e.g. on a Synology): https://host/{z}/{x}/{y}.png'
                      : trip.settings.customTileUrl,
                ),
                onTap: () async {
                  final url = await askText(
                    ctx,
                    title: 'Tile server URL',
                    hint: 'https://example.com/tiles/{z}/{x}/{y}.png',
                    initial: trip.settings.customTileUrl,
                  );
                  if (url == null) return;
                  final ok =
                      url.contains('{z}') &&
                      url.contains('{x}') &&
                      url.contains('{y}') &&
                      url.startsWith('http');
                  await trip.update((x) {
                    x.customTileUrl = url.trim();
                    if (ok) x.mapSource = 'custom';
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              const ListTile(
                dense: true,
                leading: Icon(Icons.info_outline),
                title: Text(
                  'Report a map problem: openstreetmap.org/fixthemap',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addPin(
    BuildContext context,
    TripController trip,
    GeoPoint at,
  ) async {
    var type = PinType.meetup;
    final label = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Drop a pin'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final t in [
                      PinType.camp,
                      PinType.water,
                      PinType.trailhead,
                      PinType.meetup,
                      PinType.car,
                      PinType.danger,
                      PinType.custom,
                    ])
                      ChoiceChip(
                        avatar: Icon(pinIcon(t), size: 18, color: pinColor(t)),
                        label: Text(t.label),
                        selected: type == t,
                        onSelected: (_) => set(() => type = t),
                      ),
                  ],
                ),
                TextField(
                  controller: label,
                  maxLength: PinMsg.maxLabel,
                  decoration: const InputDecoration(
                    labelText: 'Name (optional)',
                  ),
                ),
                Text(
                  '${at.lat.toStringAsFixed(5)}, ${at.lng.toStringAsFixed(5)}\n'
                  'Shared with everyone on this channel.',
                  style: Theme.of(ctx).textTheme.bodySmall,
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
              child: const Text('Share pin'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await trip.addPin(type, at, label: label.text.trim());
  }

  Future<void> _pinSheet(
    BuildContext context,
    TripController trip,
    MapPin p,
  ) async {
    final me = trip.myFix?.pos;
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: Icon(
                  pinIcon(p.type),
                  color: pinColor(p.type),
                  size: 36,
                ),
                title: Text(p.title, style: Theme.of(ctx).textTheme.titleLarge),
                subtitle: Text(
                  '${p.type.label} · by ${p.origin == c.nodeId ? 'you' : c.nameOf(p.origin)} · ${hhmm(p.at)}\n'
                  '${p.pos.lat.toStringAsFixed(5)}, ${p.pos.lng.toStringAsFixed(5)}',
                ),
                trailing: me == null
                    ? null
                    : BearingArrow(
                        angleDeg: arrowAngleDeg(
                          bearingDeg(me, p.pos),
                          trip.heading,
                        ),
                        size: 32,
                      ),
              ),
              if (me != null)
                Text(
                  formatDistanceBearing(
                    me,
                    p.pos,
                    imperial: trip.settings.imperial,
                  ),
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.headlineSmall,
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: Text(
                  p.origin == c.nodeId
                      ? 'Delete for everyone'
                      : 'Hide on this phone',
                ),
                onPressed: () {
                  trip.deletePin(p);
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _personSheet(
    BuildContext context,
    TripController trip,
    int id,
  ) async {
    final pp = trip.people[id];
    if (pp == null) return;
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TripPersonTile(id: id, name: c.nameOf(id), trip: trip),
              Text(
                '${pp.pos.lat.toStringAsFixed(5)}, ${pp.pos.lng.toStringAsFixed(5)}'
                '${pp.accuracyM != null ? ' (±${pp.accuracyM!.round()} m)' : ''}\n'
                'Fix taken ${hhmm(pp.at)}${pp.held ? ' (via base camp)' : ''}',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.ring_volume),
                    label: const Text('Ring'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      c.ring(toPeer: id);
                    },
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.center_focus_strong),
                    label: const Text('Show on map'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      focusOn(pp.pos);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ panel

  Widget _panel(BuildContext context, TripController trip) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = c.peers.where((p) => p.channel == c.scope).toList()
      ..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      );
    final ids = {for (final p in mine) p.id, ...trip.people.keys};
    final active = trip.sos.active;
    final lost = trip.lost.lost;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      children: [
        if (active != null)
          ActiveSosCard(sos: active, nameOf: c.nameOf, onCancel: trip.cancelSos)
        else
          SosButton(onSend: trip.startSos),
        for (final s in trip.sos.incoming.where((s) => !s.cancelled))
          Card(
            color: s.ackedAt == null ? cs.errorContainer : null,
            child: ListTile(
              leading: const Icon(Icons.sos, color: Colors.red, size: 32),
              title: Text('SOS from ${c.nameOf(s.origin)}'),
              subtitle: Text(
                [
                  trip.sosText(s),
                  'since ${hhmm(s.firstAt)}',
                  if (s.ackers.isNotEmpty)
                    'answered by ${s.ackers.keys.map((i) => i == c.nodeId ? 'you' : c.nameOf(i)).join(', ')}',
                ].join(' · '),
              ),
              trailing: s.ackedAt == null
                  ? FilledButton(
                      onPressed: () => trip.acknowledgeSos(s),
                      child: const Text('Ack'),
                    )
                  : IconButton(
                      tooltip: 'Show on map',
                      icon: const Icon(Icons.map),
                      onPressed: s.pos == null ? null : () => focusOn(s.pos!),
                    ),
            ),
          ),
        for (final l in lost)
          Card(
            color: cs.errorContainer,
            child: ListTile(
              leading: const Icon(Icons.person_off),
              title: Text('Lost contact: ${c.nameOf(l.id)}'),
              subtitle: Text(
                'Silent ${formatAge(DateTime.now().difference(l.lastHeard))} (since ${hhmm(l.lastHeard)})'
                '${l.lastPos == null ? '' : '. Last seen ${trip.myFix == null ? 'at ${l.lastPos}' : formatDistanceBearing(trip.myFix!.pos, l.lastPos!, imperial: trip.settings.imperial)}${l.lastPosAt == null ? '' : ' at ${hhmm(l.lastPosAt!)}'}'}',
              ),
              trailing: l.lastPos == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.map),
                      onPressed: () => focusOn(l.lastPos!),
                    ),
            ),
          ),
        const SizedBox(height: 4),
        SwitchListTile(
          key: const Key('tripMode'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Share my location with the group'),
          subtitle: Text(
            trip.settings.tripMode
                ? 'Live on the map, check-in every ${trip.settings.checkInMinutes == 0 ? '(off)' : '${trip.settings.checkInMinutes} min'}'
                      '${trip.settings.lostContactMinutes > 0 ? ', lost-contact alert after ${trip.settings.lostContactMinutes} min' : ''}.'
                : 'Off: others do not see you on the map. SOS always sends your location.',
          ),
          value: trip.settings.tripMode,
          onChanged: (v) => trip.update((s) => s.tripMode = v),
        ),
        Text('Quick messages', style: theme.textTheme.titleSmall),
        CannedBar(trip: trip, onEdit: () => _editCanned(context, trip)),
        const Divider(),
        Row(
          children: [
            Expanded(
              child: Text(
                'People (${ids.length})',
                style: theme.textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.how_to_reg, size: 18),
              label: const Text('Check in now'),
              onPressed: () async {
                if (await trip.checkInNow() && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Check-in sent')),
                  );
                }
              },
            ),
          ],
        ),
        if (ids.isEmpty)
          Text('Nobody on this channel yet.', style: theme.textTheme.bodySmall),
        for (final id in ids)
          TripPersonTile(
            id: id,
            name: c.nameOf(id),
            trip: trip,
            lost: trip.lost.state(id)?.lost ?? false,
            onTap: trip.people[id] == null
                ? null
                : () => focusOn(trip.people[id]!.pos),
          ),
        const Divider(),
        _trailSection(context, trip),
        const Divider(),
        _weatherSection(context, trip),
        const Divider(),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.hub),
              label: const Text('Network map'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NetworkMapPage(controller: c),
                ),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.download_for_offline),
              label: const Text('Offline maps'),
              onPressed: () => _openOffline(context, trip),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.tune),
              label: const Text('Trip settings'),
              onPressed: () => _settingsSheet(context, trip),
            ),
          ],
        ),
        if (trip.feed.isNotEmpty) ...[
          const Divider(),
          Text('Recent', style: theme.textTheme.titleSmall),
          for (final e in trip.feed.take(15))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                switch (e.kind) {
                  'sos' => Icons.sos,
                  'ack' => Icons.check_circle,
                  'lost' => Icons.person_off,
                  'found' => Icons.person,
                  'pin' => Icons.place,
                  'track' => Icons.timeline,
                  'held' => Icons.inventory_2,
                  _ => Icons.chat_bubble_outline,
                },
                color: e.kind == 'sos' || e.kind == 'lost' ? Colors.red : null,
              ),
              title: Text(e.text),
              subtitle: Text(
                '${hhmm(e.at)}${e.via != null ? ' · via ${transportName(e.via!)}' : ''}',
              ),
              onTap: e.pos == null ? null : () => focusOn(e.pos!),
            ),
        ],
      ],
    );
  }

  Widget _trailSection(BuildContext context, TripController trip) {
    final theme = Theme.of(context);
    final rec = trip.recorder.track;
    final cur = _shown ?? trip.currentTrack;
    final me = trip.myFix?.pos;
    final bt = cur != null && me != null && _backtrack
        ? backtrack(cur.points, me)
        : null;
    final imp = trip.settings.imperial;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Trail', style: theme.textTheme.titleSmall),
        if (rec != null)
          Text(
            'Recording ${formatDistance(rec.lengthM, imperial: imp)} · ${rec.points.length} points',
            style: const TextStyle(color: Colors.red),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (rec == null)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.fiber_manual_record, color: Colors.red),
                label: const Text('Record trail'),
                onPressed: () {
                  setState(() => _shown = null);
                  trip.startTrack();
                },
              )
            else
              FilledButton.tonalIcon(
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                onPressed: trip.stopTrack,
              ),
            if (cur != null && cur.points.length > 1) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.share_location),
                label: const Text('Share with group'),
                onPressed: () {
                  trip.shareTrack(cur);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Trail shared (a short summary goes by radio to far phones)',
                      ),
                    ),
                  );
                },
              ),
              OutlinedButton.icon(
                icon: Icon(_backtrack ? Icons.u_turn_left : Icons.undo),
                label: Text(_backtrack ? 'Backtrack on' : 'Backtrack'),
                onPressed: () => setState(() => _backtrack = !_backtrack),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.file_download),
                label: const Text('Export GPX'),
                onPressed: () async {
                  final tmp = await getTemporaryDirectory();
                  await trip.exportGpx(cur, Directory(tmp.path));
                },
              ),
            ],
          ],
        ),
        if (bt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                BearingArrow(
                  angleDeg: arrowAngleDeg(
                    bearingDeg(me!, cur!.points[bt.index].pos),
                    trip.heading,
                  ),
                  size: 28,
                  color: Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${bt.toTrailM < 30 ? 'On the trail' : 'Trail is ${formatDistanceBearing(me, cur.points[bt.index].pos, imperial: imp)}'}. '
                    '${formatDistance(bt.backM, imperial: imp)} back to the start along the trail '
                    '(start is ${formatDistanceBearing(me, cur.points.first.pos, imperial: imp)} straight line).',
                  ),
                ),
              ],
            ),
          ),
        for (final tr in trip.savedTracks.take(5))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.timeline,
              color: identical(tr, cur) ? Colors.blue : null,
            ),
            title: Text(tr.name.isEmpty ? 'Trail' : tr.name),
            subtitle: Text(
              '${formatDistance(tr.lengthM, imperial: imp)} · ${tr.points.length} points',
            ),
            onTap: () => setState(() => _shown = tr),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                if (identical(_shown, tr)) _shown = null;
                trip.deleteTrack(tr);
              },
            ),
          ),
      ],
    );
  }

  Widget _weatherSection(BuildContext context, TripController trip) {
    final theme = Theme.of(context);
    final f = trip.weather.forecast;
    final now = DateTime.now();
    final place = trip.myFix?.pos ?? f?.place;
    final sun = place == null ? null : sunTimes(now, place);
    final rows = <Widget>[
      Row(
        children: [
          Expanded(
            child: Text(
              'Weather & daylight',
              style: theme.textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: 'Update forecast (needs internet)',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final ok = await trip.refreshWeather(force: true);
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      place == null ? 'Need a GPS fix first.' : 'Could not download the forecast (offline?). Showing the saved one.',
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
    ];
    if (f == null) {
      rows.add(
        Text(
          'No forecast saved. Open this tab once with internet before you go and it is kept for offline use.',
          style: theme.textTheme.bodySmall,
        ),
      );
    } else {
      final age = now.difference(f.at);
      final today = f.days.isNotEmpty ? f.days.first : null;
      rows.add(
        Text(
          'Saved ${formatAge(age)} ago${age > const Duration(hours: 12) ? ' - may be out of date' : ''}'
          '${place != null && distanceM(place, f.place) > 20000 ? ' (for ${formatDistance(distanceM(place, f.place), imperial: f.imperial)} away)' : ''}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: age > const Duration(hours: 12)
                ? theme.colorScheme.error
                : null,
          ),
        ),
      );
      if (today != null) {
        final (txt, emoji) = weatherText(today.code);
        rows.add(
          Text(
            '$emoji $txt · ${today.tMax.round()}${f.tempUnit} / ${today.tMin.round()}${f.tempUnit}'
            '${today.precipProb != null ? ' · rain ${today.precipProb}%' : ''}'
            '${today.windMax != null ? ' · wind ${today.windMax!.round()} ${f.windUnit}' : ''}',
            style: theme.textTheme.titleMedium,
          ),
        );
      }
      final hours = f.nextHours(now, 8);
      if (hours.isNotEmpty) {
        rows.add(
          SizedBox(
            height: 64,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final h in hours)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Column(
                      children: [
                        Text(
                          '${h.time.hour % 12 == 0 ? 12 : h.time.hour % 12}${h.time.hour < 12 ? 'a' : 'p'}',
                        ),
                        Text(weatherText(h.code).$2),
                        Text(
                          '${h.temp.round()}°${h.precipProb != null && h.precipProb! > 20 ? ' ${h.precipProb}%' : ''}',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      }
      for (final d in f.days.skip(1)) {
        final (txt, emoji) = weatherText(d.code);
        rows.add(
          Text(
            '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.date.weekday - 1]}: $emoji $txt '
            '${d.tMax.round()}/${d.tMin.round()}${f.tempUnit}${d.precipProb != null ? ', rain ${d.precipProb}%' : ''}',
          ),
        );
      }
    }
    // Daylight: from the forecast for today, else computed on the phone.
    DateTime? rise, set;
    if (f != null &&
        f.days.isNotEmpty &&
        DateUtils.isSameDay(f.days.first.date, now)) {
      rise = f.days.first.sunrise;
      set = f.days.first.sunset;
    }
    rise ??= sun?.sunrise?.toLocal();
    set ??= sun?.sunset?.toLocal();
    if (rise != null || set != null) {
      final left = set?.difference(now);
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '🌅 ${rise == null ? '-' : hhmm(rise)}   🌇 ${set == null ? '-' : hhmm(set)}'
            '${left != null && !left.isNegative ? '   (${left.inHours} h ${left.inMinutes % 60} min of daylight left)' : ''}',
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Future<void> _editCanned(BuildContext context, TripController trip) async {
    final ctrl = TextEditingController(text: trip.settings.canned.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('My quick messages'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          decoration: const InputDecoration(
            helperText: 'One per line, up to 48 letters each. The built-in ones are always there.',
            helperMaxLines: 3,
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
    );
    if (ok != true) return;
    final list = [
      for (final l in ctrl.text.split('\n'))
        if (l.trim().isNotEmpty)
          l.trim().length > CannedMsg.maxText
              ? l.trim().substring(0, CannedMsg.maxText)
              : l.trim(),
    ].take(8).toList();
    await trip.update((s) => s.canned = list);
  }

  Future<void> _settingsSheet(BuildContext context, TripController trip) async {
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: trip,
        builder: (ctx, _) {
          final s = trip.settings;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Trip settings',
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Check-in every',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final m in TripSettings.checkInChoices)
                        ChoiceChip(
                          label: Text(m == 0 ? 'Off' : '$m min'),
                          selected: s.checkInMinutes == m,
                          onSelected: (_) =>
                              trip.update((x) => x.checkInMinutes = m),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lost-contact alert after',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final m in TripSettings.lostChoices)
                        ChoiceChip(
                          label: Text(m == 0 ? 'Off' : '$m min'),
                          selected: s.lostContactMinutes == m,
                          onSelected: (_) =>
                              trip.update((x) => x.lostContactMinutes = m),
                        ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Check-ins over the LoRa radio too'),
                    subtitle: const Text(
                      'Only to phones nothing faster reaches. Tiny (about 50 bytes).',
                    ),
                    value: s.radioCheckIns,
                    onChanged: (v) => trip.update((x) => x.radioCheckIns = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Miles and feet'),
                    subtitle: const Text('Off = kilometres and metres'),
                    value: s.imperial,
                    onChanged: (v) => trip.update((x) => x.imperial = v),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_sweep),
                    label: const Text('Clear shared trip data'),
                    onPressed: () => trip.clearTripData(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Base camp mode and the radio are in Settings > Off-grid.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
