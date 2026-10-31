import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../app/walkie_controller.dart';
import '../lora/meshtastic_session.dart' show RadioNode;
import '../trip/friend_motion.dart';
import '../trip/geo.dart';
import '../trip/imports/map_layers.dart';
import '../trip/imports/map_packs.dart';
import '../trip/map_net.dart';
import '../trip/nav/gentle_route.dart';
import '../trip/range_test.dart';
import '../trip/nav/nav_session.dart';
import '../trip/smart_plan.dart';
import '../trip/search/fetch.dart';
import '../trip/search/map_search.dart';
import '../trip/search/nominatim.dart';
import '../trip/search/offline_search.dart';
import '../trip/search/overpass.dart';
import '../trip/tile_cache.dart';
import '../trip/track.dart';
import '../trip/trip_controller.dart';
import '../trip/trip_packet.dart';
import '../trip/trip_settings.dart';
import '../trip/weather.dart';
import 'home_view.dart';
import 'map_import.dart';
import 'map_layer_widgets.dart';
import 'map_layers_page.dart';
import 'map_packs_page.dart';
import 'map_search_page.dart';
import 'drive_page.dart';
import 'friend_marker.dart';
import 'nav_page.dart';
import 'network_map_page.dart';
import 'offline_areas_page.dart';
import 'range_test_ui.dart';
import 'sheets.dart';
import 'smart_sheets.dart';
import 'trip_widgets.dart';
import '../platform/platform_caps.dart';

LatLng ll(GeoPoint p) => LatLng(p.lat, p.lng);
GeoPoint gp(LatLng p) => GeoPoint(p.latitude, p.longitude);

/// The Trip tab: offline map with everyone, SOS, quick messages, people
/// with distance and direction, trails, weather, network and offline maps.
/// Works online and offline (every message takes whatever path reaches).
class TripPage extends StatefulWidget {
  const TripPage({
    super.key,
    required this.controller,
    this.focus,
    this.onFullScreen,
  });
  final WalkieController controller;

  /// The map went full screen / back (the home screen hides its bars).
  final ValueChanged<bool>? onFullScreen;

  /// Center the map here when opened (e.g. from an SOS alert).
  final GeoPoint? focus;
  @override
  State<TripPage> createState() => TripPageState();
}

class TripPageState extends State<TripPage> with WidgetsBindingObserver {
  WalkieController get c => widget.controller;
  TripController? get t => c.trip;
  final MapController _map = MapController();
  final List<StreamSubscription<dynamic>> _sensors = [];
  List<double>? _acc;
  bool _mapReady = false;
  bool _follow = true;
  bool _backtrack = false;
  bool _full = false;
  Track? _shown;

  /// Search result being highlighted on the map (cleared after a while).
  SearchHit? _hl;
  Timer? _hlTimer;

  bool get fullScreen => _full;

  Future<void> _importPcRange() async {
    final tc = t;
    if (tc == null || !_fg || !mounted) return;
    final r = await tc.range.importFromPc();
    if (r == null || r.added == 0 || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'Range test: ${r.added} new marker${r.added == 1 ? '' : 's'} on the map.',
        ),
      ),
    );
  }

  void setFullScreen(bool on) {
    if (on == _full) return;
    setState(() => _full = on);
    widget.onFullScreen?.call(on);
  }

  /// Redraws the friends' ages and moving dots (v2.5.6) every 2 s while the
  /// page is on screen and someone shares a place; stopped in the background.
  Timer? _tick;
  bool _fg = true;

  /// Range test marker whose blur circle is shown (v2.5.9).
  RangeEvent? _rangeSel;

  /// Windows: look for new range test results from the PC every 30 s
  /// while the map is open (one file-time check, nothing else).
  Timer? _rangePc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      final tc = t;
      if (mounted && _fg && tc != null && tc.people.isNotEmpty) {
        setState(() {});
      }
    });
    t?.setVisible(true);
    if (Platform.isWindows) {
      unawaited(_importPcRange());
      _rangePc = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_importPcRange()),
      );
    }
    _startCompass();
    if (widget.focus != null) _follow = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hlTimer?.cancel();
    _tick?.cancel();
    _rangePc?.cancel();
    t?.setVisible(false);
    for (final s in _sensors) {
      s.cancel();
    }
    super.dispose();
  }

  /// v2.0.0: the compass sensors only run with the app on screen (a phone
  /// left on the Trip tab with the screen off used to keep them going).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _fg = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      if (_sensors.isEmpty) _startCompass();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      for (final s in _sensors) {
        s.cancel();
      }
      _sensors.clear();
      _acc = null;
    }
  }

  void _startCompass() {
    if (!PlatformCaps.sensors) return; // desktop: no compass
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
      listenable: Listenable.merge([
        trip,
        trip.layers,
        trip.range,
        trip.rangeLog,
      ]),
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
        _buzz(trip);
        _maybeHandoff(trip);
        final active = trip.sos.active;
        return TripLayout(
          full: _full,
          onFull: setFullScreen,
          map: _mapView(context, trip),
          panel: _panel(context, trip),
          sos: active != null
              ? SosActivePill(
                  acks: active.acks.length,
                  onTap: () => _activeSosSheet(context, trip),
                )
              : SosSlideButton(onSend: trip.startSos),
          controls: _mapControls(context, trip),
          fullControls: _zoomControls(),
          topLeft: [
            if (trip.drive != null)
              DriveCard(
                trip: trip,
                session: trip.drive!,
                onFollow: () => _openDriveFollow(trip),
              ),
            if (trip.nav != null)
              NavCard(
                trip: trip,
                session: trip.nav!,
                onFollow: () => _openFollow(trip),
              ),
            ?_packBanner(context, trip),
            MapNetChip(
              state: trip.mapNet.state,
              onTap: () => _netChipTap(context, trip),
            ),
            OfflineSaverChip(
              on: c.settings.offlineSaver,
              onTap: () => _toggleOffline(context),
            ),
            if (trip.myFix == null)
              Card(
                margin: EdgeInsets.zero,
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
          ],
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
    final track = _shown ?? trip.currentTrack;
    final hl = _hl;
    final nav = trip.nav;
    final navRoute = nav?.route;
    final drive = trip.drive;
    final lines = <Polyline>[
      if (drive != null) ...driveLines(drive.route),
      if (drive?.hikePreview != null) hikePreviewLine(drive!.hikePreview!),
      if (nav != null && navRoute != null && navRoute.terrainOnly && me != null)
        Polyline(
          points: [ll(me.pos), ll(nav.target)],
          strokeWidth: 3,
          color: Colors.blueGrey,
          pattern: StrokePattern.dashed(segments: const [10, 8]),
        ),
      if (navRoute != null)
        Polyline(
          points: [for (final p in navRoute.points) ll(p)],
          strokeWidth: 6,
          // Walking leg: green (the drive is blue / brown / red); a route
          // from terrain alone is orange so it is not mistaken for a trail.
          color: (navRoute.terrainOnly ? Colors.deepOrange : hikeColor)
              .withValues(alpha: 0.85),
          borderStrokeWidth: 1.5,
          borderColor: Colors.white,
        ),
      if (nav != null && nav.compass && me != null)
        Polyline(
          points: [ll(me.pos), ll(nav.target)],
          strokeWidth: 3,
          color: Colors.deepPurple,
          pattern: StrokePattern.dashed(segments: const [10, 8]),
        ),
      if (hl != null && hl.doc.line != null && hl.doc.line!.length > 1)
        Polyline(
          points: [for (final p in hl.doc.line!) ll(p)],
          strokeWidth: 9,
          color: Colors.yellow.withValues(alpha: 0.75),
          borderStrokeWidth: 1.5,
          borderColor: Colors.orange.withValues(alpha: 0.8),
        ),
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
      if (drive != null)
        Marker(
          key: const Key('driveTarget'),
          point: ll(drive.target),
          width: 40,
          height: 40,
          child: const Icon(Icons.flag, color: Color(0xFF1565C0), size: 32),
        ),
      if (nav != null)
        Marker(
          key: const Key('navTarget'),
          point: ll(nav.target),
          width: 40,
          height: 40,
          child: const Icon(Icons.flag, color: Colors.deepPurple, size: 32),
        ),
      if (hl != null)
        Marker(
          key: const Key('searchHighlight'),
          point: ll(hl.doc.pos),
          width: 160,
          height: 72,
          child: GestureDetector(
            onTap: () =>
                _pointSheet(context, trip, hl.doc.pos, hl.title, search: true),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 18),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.yellow.withValues(alpha: 0.35),
                    border: Border.all(color: Colors.orange, width: 3),
                  ),
                  child: Icon(
                    searchKindIcon(hl.doc),
                    size: 16,
                    color: Colors.black87,
                  ),
                ),
                _label(hl.title, Colors.orange),
              ],
            ),
          ),
        ),
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
      ...rangeMarkers(
        trip.range,
        onTap: (e) {
          setState(() => _rangeSel = e);
          showRangeEventSheet(
            context,
            trip.range,
            e,
            imperial: trip.settings.imperial,
          ).whenComplete(() {
            if (mounted) setState(() => _rangeSel = null);
          });
        },
      ),
      for (final pp in trip.people.values)
        friendMarker(
          trip,
          pp,
          c.nameOf(pp.id),
          onTap: () => _personSheet(context, trip, pp.id),
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
            onLongPress: (_, point) =>
                _pointSheet(context, trip, gp(point), 'Dropped point'),
          ),
          children: [
            ...baseTileLayers(trip),
            ...importedLayers(
              trip,
              onWaypoint: (l, name, at) => _pointSheet(
                context,
                trip,
                at,
                name.isEmpty ? 'Waypoint' : name,
              ),
            ),
            PolylineLayer(polylines: lines),
            CircleLayer(circles: friendCircles(trip)),
            CircleLayer(circles: rangeCircles(trip.range, _rangeSel)),
            CircleLayer(circles: rangeSampleCircles(trip.range)),
            MarkerLayer(markers: markers),
            PhotoDateLine(trip: trip),
            SimpleAttributionWidget(
              source: Text(
                {
                  src.attribution,
                  if (trip.baseTiles != null)
                    trip.layers.tilesOf(trip.baseTiles!.id)?.attribution ?? '',
                  for (final l in trip.layers.trails)
                    if (l.visible && l.attribution.isNotEmpty)
                      'Trails ${l.attribution}',
                  for (final o in trip.overlays) o.attribution,
                }.where((x) => x.isNotEmpty).join(' · '),
                style: const TextStyle(fontSize: 10),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.85),
            ),
          ],
        ),
        if (trip.range.logging)
          Positioned(
            top: trip.drivingMode ? 36 : 8,
            left: 8,
            child: GestureDetector(
              onTap: () => _openRange(context, trip),
              child: DecoratedBox(
                key: const Key('rangeChip'),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cell_tower,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Range logging · ${trip.rangeLog.status}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (trip.drivingMode)
          Positioned(
            top: 8,
            left: 8,
            child: DecoratedBox(
              key: const Key('drivingChip'),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.directions_car, size: 14, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      'Driving mode · plugged in',
                      style: TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _mapControls(BuildContext context, TripController trip) {
    final cs = Theme.of(context).colorScheme;
    return [
      RoundMapButton(
        key: const Key('mapSearch'),
        icon: Icons.search,
        tip: 'Search maps, trails and places',
        onTap: () => _openSearch(context, trip),
      ),
      RoundMapButton(
        icon: _follow ? Icons.my_location : Icons.location_searching,
        tip: _follow ? 'Following you' : 'Center on me',
        onTap: () {
          setState(() => _follow = true);
          final f = trip.myFix;
          if (f != null && _mapReady) {
            _map.move(ll(f.pos), _map.camera.zoom < 12 ? 15 : _map.camera.zoom);
          }
        },
        color: _follow ? cs.primary : null,
      ),
      RoundMapButton(
        icon: Icons.layers,
        tip: 'Map style',
        onTap: () => _styleSheet(context, trip),
      ),
      RoundMapButton(
        icon: Icons.file_open,
        tip: 'Imported trails and maps',
        onTap: () => _openLayers(context, trip),
      ),
      if (trip.range.hasAny)
        RoundMapButton(
          key: const Key('mapRange'),
          icon: Icons.cell_tower,
          tip: 'Range test markers',
          onTap: () => _openRange(context, trip),
          color: trip.range.visible ? rangeGreen : null,
        ),
      RoundMapButton(
        key: const Key('mapDrive'),
        icon: Icons.directions_car,
        tip: 'Directions (drive)',
        onTap: () => _directionsSheet(context, trip),
      ),
      RoundMapButton(
        key: const Key('mapOffline'),
        icon: Icons.download_for_offline,
        tip: 'Offline areas',
        onTap: () => _openOffline(context, trip),
      ),
      RoundMapButton(
        icon: Icons.add_location_alt,
        tip: 'Drop a pin here',
        onTap: () => _addPin(context, trip, gp(_map.camera.center)),
      ),
    ];
  }

  List<Widget> _zoomControls() => [
    RoundMapButton(icon: Icons.add, tip: 'Zoom in', onTap: () => _zoom(1)),
    RoundMapButton(icon: Icons.remove, tip: 'Zoom out', onTap: () => _zoom(-1)),
  ];

  void _zoom(double by) {
    if (!_mapReady) return;
    final cam = _map.camera;
    _map.move(cam.center, (cam.zoom + by).clamp(2.0, 19.0));
  }

  Future<void> _toggleOffline(BuildContext context) async {
    final on = !c.settings.offlineSaver;
    await c.setOfflineSaver(on);
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          on
              ? 'Offline power save on: no internet relay, slower searching '
                    'and GPS, dim screen. Talk, relay, radio and SOS still work.'
              : 'Offline power save off.',
        ),
      ),
    );
  }

  Future<void> _activeSosSheet(BuildContext context, TripController trip) =>
      showAppSheet<void>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ListenableBuilder(
              listenable: trip,
              builder: (ctx, _) {
                final a = trip.sos.active;
                if (a == null) {
                  return const ListTile(title: Text('SOS cancelled.'));
                }
                return ActiveSosCard(
                  sos: a,
                  nameOf: c.nameOf,
                  onCancel: () {
                    trip.cancelSos();
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
        ),
      );

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

  /// Opens the Range test page (from the Settings search, v2.6.2).
  void openRangeTest() {
    final tc = t;
    if (tc == null || !mounted) return;
    _openRange(context, tc);
  }

  void _openRange(BuildContext context, TripController trip) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RangeTestPage(
          range: trip.range,
          imperial: trip.settings.imperial,
          logger: trip.rangeLog,
          homeChoices: () => [
            for (final n
                in c.radioDevice.session?.nodes.values ?? const <RadioNode>[])
              if (n.num != c.radioDevice.session?.myNodeNum &&
                  n.readable &&
                  n.longName.isNotEmpty)
                (num: n.num, name: n.longName),
          ],
          share: trip.host.shareFile,
          onShow: (e) {
            Navigator.of(context).popUntil((r) => r.isFirst);
            setState(() {
              _follow = false;
              _rangeSel = e;
            });
            if (_mapReady) _map.move(ll(e.pos), 14);
          },
        ),
      ),
    );
  }

  void _openLayers(BuildContext context, TripController trip) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MapLayersPage(
          trip: trip,
          onRange: () => _openRange(context, trip),
          onShow: (p) {
            setState(() => _follow = false);
            if (_mapReady) {
              _map.move(ll(p), _map.camera.zoom < 12 ? 14 : _map.camera.zoom);
            }
          },
          onFit: _showNewLayer,
        ),
      ),
    );
  }

  /// After an import or a map pack: back to the map, moved to the layer.
  void _showNewLayer(GeoBounds b) {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() => _follow = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fit(b, maxZoom: 15);
    });
  }

  void _openPacks(TripController trip, {Set<String> add = const {}}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            MapPacksPage(trip: trip, onFit: _showNewLayer, autoAdd: add),
      ),
    );
  }

  /// Packs offered by the one-time "maps are ready" banner.
  List<MapPack>? _offer;

  Future<void> _loadOffer(TripController trip) async {
    if (_offer != null || trip.settings.packsOffered) return;
    _offer = const [];
    try {
      final all = await packCatalog(trip).load(refresh: false);
      if (mounted) setState(() => _offer = all);
    } catch (_) {}
  }

  Widget? _packBanner(BuildContext context, TripController trip) {
    if (trip.settings.packsOffered) return null;
    unawaited(_loadOffer(trip));
    final todo = [
      for (final p in _offer ?? const <MapPack>[])
        if (!packAdded(p, trip.layers)) p,
    ];
    if (todo.isEmpty) return null;
    final names = todo.map((p) => p.short).join(' & ');
    Future<void> answered() => trip.update((s) => s.packsOffered = true);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Card(
        key: const Key('packBanner'),
        margin: EdgeInsets.zero,
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$names maps are ready',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Text('Trails and topo maps, added with one tap.'),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(onPressed: answered, child: const Text('Not now')),
                  FilledButton(
                    key: const Key('packBannerAdd'),
                    onPressed: () {
                      unawaited(answered());
                      _openPacks(trip, add: {for (final p in todo) p.id});
                    },
                    child: const Text('Add maps'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A file shared to the app ("Open with"): import it on this tab.
  Future<void> importShared(String path, String name) async {
    final trip = t;
    if (trip == null || !mounted) return;
    final l = await importMapFile(
      context,
      trip,
      File(path),
      name,
      temporary: true,
    );
    final b = l == null ? null : layerBounds(trip.layers, l);
    if (b != null) _showNewLayer(b);
  }

  // ------------------------------------------------------------ search

  GeoBounds? get _visibleBounds {
    if (!_mapReady) return null;
    final v = _map.camera.visibleBounds;
    return GeoBounds(v.south, v.west, v.north, v.east);
  }

  void _fit(GeoBounds b, {double maxZoom = 16}) {
    if (!_mapReady) return;
    if ((b.north - b.south).abs() < 1e-4 && (b.east - b.west).abs() < 1e-4) {
      _map.move(ll(b.center), maxZoom.clamp(2, 15));
      return;
    }
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(LatLng(b.south, b.west), LatLng(b.north, b.east)),
        padding: const EdgeInsets.all(40),
        maxZoom: maxZoom,
      ),
    );
  }

  Future<void> _openSearch(BuildContext context, TripController trip) async {
    final near = trip.myFix?.pos ?? (_mapReady ? gp(_map.camera.center) : null);
    final pick = await Navigator.of(context).push<MapSearchPick>(
      MaterialPageRoute(
        builder: (_) => MapSearchPage(trip: trip, near: near),
      ),
    );
    if (!mounted || pick == null) return;
    switch (pick) {
      case OfflinePick(:final hit):
        showHit(hit);
      case PlacePick(:final place):
        if (!context.mounted) return;
        await _placeSheet(context, trip, place);
    }
  }

  /// Center the map on a search result and highlight it.
  void showHit(SearchHit hit) {
    _hlTimer?.cancel();
    setState(() {
      _follow = false;
      _hl = hit;
    });
    final b = hit.doc.bounds;
    if (b != null && hit.doc.kind != SearchKind.person) {
      _fit(b);
    } else if (_mapReady) {
      _map.move(ll(hit.doc.pos), _map.camera.zoom < 14 ? 15 : _map.camera.zoom);
    }
    _hlTimer = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => _hl = null);
    });
  }

  Future<void> _placeSheet(
    BuildContext context,
    TripController trip,
    PlaceResult place,
  ) async {
    setState(() => _follow = false);
    if (place.bounds != null) {
      _fit(place.bounds!, maxZoom: 15);
    } else if (_mapReady) {
      _map.move(ll(place.center), 14);
    }
    var busy = false;
    String? error;
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          Future<void> getTrails({bool onScreen = false}) async {
            set(() {
              busy = true;
              error = null;
            });
            try {
              final r = await trip.importTrailsFor(
                place: onScreen ? null : place,
                visible: _visibleBounds,
              );
              if (ctx.mounted) Navigator.pop(ctx);
              final b = boundsOfPoints(r.layer.data?.allPoints ?? const []);
              if (b != null) _fit(b, maxZoom: 15);
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 6),
                  content: Text(
                    'Saved "${r.layer.name}": ${r.result.trails} trails and '
                    '${r.result.places} places, ready offline.'
                    '${r.trimmed ? ' Big area, so only the middle ${maxTrailAreaKm.round()} km was fetched.' : ''}'
                    '${r.result.partial ? ' The server stopped early, so some may be missing.' : ''}',
                  ),
                ),
              );
            } on NoSignalException catch (e) {
              set(
                () => error = e.message
                    .replaceAll(
                      'offline search below',
                      'try again when you have signal',
                    )
                    .replaceAll(
                      'Offline search below.',
                      'Try again when you have signal.',
                    ),
              );
            } on FetchException catch (e) {
              set(() => error = e.message);
            } on StorageLimitException catch (e) {
              set(() => error = e.message);
            } catch (e) {
              set(() => error = 'Could not get trails: $e');
            } finally {
              if (ctx.mounted) set(() => busy = false);
            }
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(place.name, style: Theme.of(ctx).textTheme.titleLarge),
                Text(
                  place.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('getTrails'),
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.route),
                  label: Text(
                    busy ? 'Getting trails...' : 'Get trails for this area',
                  ),
                  onPressed: busy ? null : () => getTrails(),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  key: const Key('placeDrive'),
                  icon: const Icon(Icons.directions_car),
                  label: const Text('Drive here'),
                  onPressed: busy
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _startDrive(trip, place.center, place.name);
                        },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download_for_offline),
                  label: const Text('Save this area offline'),
                  onPressed: busy
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          _downloadPlace(context, trip, place);
                        },
                ),
                TextButton(
                  onPressed: busy ? null : () => getTrails(onScreen: true),
                  child: const Text(
                    'Get trails for the area on screen instead',
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      error!,
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  'Trails and places from OpenStreetMap ($osmAttribution). '
                  'Search by Nominatim. Saved on the phone, so they work with '
                  'no signal. Always check official maps and closures.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _downloadPlace(
    BuildContext context,
    TripController trip,
    PlaceResult place,
  ) {
    final area = areaForPlace(place, visible: _visibleBounds);
    final zoom = _mapReady ? _map.camera.zoom : 12.0;
    unawaited(
      openSaveArea(
        context,
        trip,
        initial: area.bounds,
        zoom: zoom.clamp(10.0, 14.0) + 1,
        name: place.name,
      ),
    );
  }

  void _openDriveFollow(TripController trip) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => DriveFollowPage(trip: trip)));

  /// "Drive here" / "Drive, then hike" (v1.9.2).
  Future<void> _startDrive(
    TripController trip,
    GeoPoint to,
    String name, {
    bool hike = false,
  }) async {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Finding a road route…'),
      ),
    );
    final res = hike
        ? await trip.driveThenHike(to, name: name)
        : await trip.driveTo(to, name: name);
    if (!mounted) return;
    final s = res.session;
    if (s == null) {
      m?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(res.message),
          action: SnackBarAction(
            label: 'Offline areas',
            onPressed: () => _openOffline(context, trip),
          ),
        ),
      );
      return;
    }
    setState(() => _follow = false);
    final r = s.route;
    final b = boundsOfPoints(r.points);
    if (b != null) _fit(b, maxZoom: 16);
    final warn = mainWarnings(r);
    m?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          '${s.sourceLabel}. '
          '${hike ? 'Drive to ${s.name}, then hike to ${s.hikeName}. ' : ''}'
          'Drive: ${formatDistance(r.lengthM, imperial: trip.settings.imperial)}, '
          'about ${driveDuration(r.duration)}.'
          '${warn.isEmpty ? '' : ' ${warn.first.text}.'}'
          '${s.notice.isEmpty ? '' : ' ${s.notice}'}',
        ),
        action: SnackBarAction(
          label: 'Follow',
          onPressed: () => _openDriveFollow(trip),
        ),
      ),
    );
  }

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
        builder: (_) => OfflineAreasPage(
          trip: trip,
          view: b,
          zoom: zoom,
          onFit: _showNewLayer,
        ),
      ),
    );
  }

  /// Search (map search: places online, trails and pins offline) for
  /// somewhere to drive to.
  Future<({GeoPoint at, String name})?> _pickPlace(
    BuildContext context,
    TripController trip,
  ) async {
    final near = trip.myFix?.pos ?? (_mapReady ? gp(_map.camera.center) : null);
    final pick = await Navigator.of(context).push<MapSearchPick>(
      MaterialPageRoute(
        builder: (_) => MapSearchPage(trip: trip, near: near),
      ),
    );
    return switch (pick) {
      OfflinePick(:final hit) => (at: hit.doc.pos, name: hit.title),
      PlacePick(:final place) => (
        at: place.center,
        name: place.name.isEmpty ? 'Destination' : place.name,
      ),
      null => null,
    };
  }

  /// "Directions" (v1.9.3): where to drive to (search, the middle of the
  /// map, a pin), and "then hike".
  Future<void> _directionsSheet(
    BuildContext context,
    TripController trip,
  ) async {
    var hike = false;
    final pins = trip.pins.reversed.take(5).toList();
    await showAppSheet<void>(
      context: context,
      scrollable: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          void go(GeoPoint at, String name) {
            Navigator.pop(ctx);
            _startDrive(trip, at, name, hike: hike);
          }

          final d = trip.drive;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Directions', style: Theme.of(ctx).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  if (d != null)
                    Card(
                      child: ListTile(
                        key: const Key('driveContinue'),
                        leading: const Icon(Icons.navigation),
                        title: Text('Driving to ${d.name}'),
                        subtitle: Text(d.sourceLabel),
                        trailing: TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            trip.stopDrive();
                          },
                          child: const Text('Stop'),
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _openDriveFollow(trip);
                        },
                      ),
                    ),
                  OutlinedButton.icon(
                    key: const Key('driveSearch'),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.all(14),
                    ),
                    icon: const Icon(Icons.search),
                    label: const Text('Search for a place to drive to'),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final p = await _pickPlace(context, trip);
                      if (p != null && mounted) {
                        await _startDrive(trip, p.at, p.name, hike: hike);
                      }
                    },
                  ),
                  ListTile(
                    key: const Key('driveCenter'),
                    leading: const Icon(Icons.filter_center_focus),
                    title: const Text('The middle of the map'),
                    subtitle: const Text('Move the map there first'),
                    onTap: _mapReady
                        ? () => go(gp(_map.camera.center), 'Map point')
                        : null,
                  ),
                  for (final p in pins)
                    ListTile(
                      key: Key('drivePin:${p.key}'),
                      leading: const Icon(Icons.place),
                      title: Text(p.title),
                      onTap: () => go(p.pos, p.title),
                    ),
                  SwitchListTile(
                    key: const Key('driveHikeSwitch'),
                    contentPadding: EdgeInsets.zero,
                    value: hike,
                    title: const Text('Drive to the trailhead, then hike'),
                    onChanged: (v) => set(() => hike = v),
                  ),
                  Text(
                    'Tip: you can also long-press any spot on the map and tap '
                    'Drive here. With signal, routes come from the online '
                    'router (newest roads); with no signal, from your saved '
                    'areas. No live traffic.',
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

  Future<void> _styleSheet(BuildContext context, TripController trip) async {
    String saves(MapSource s) => s.onlineOnly
        ? 'Online only'
        : s.allowsOffline
        ? 'Can be saved offline (Download area)'
        : 'View only: cached as you look, not saved ahead';
    await showAppSheet<void>(
      context: context,
      scrollable: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Map style', style: Theme.of(ctx).textTheme.titleLarge),
                  for (final s in MapSource.bases)
                    ListTile(
                      key: Key('style:${s.id}'),
                      leading: Icon(
                        trip.settings.mapSource == s.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(s.name),
                      subtitle: Text(
                        '${s.about.isNotEmpty
                            ? s.about
                            : s.allowsOffline
                            ? 'Trails and contour lines.'
                            : 'Streets.'}\n${saves(s)}',
                      ),
                      isThreeLine: true,
                      onTap: () {
                        trip.update((x) => x.mapSource = s.id);
                        Navigator.pop(ctx);
                      },
                    ),
                  const Divider(),
                  Text('Overlays', style: Theme.of(ctx).textTheme.titleMedium),
                  Text(
                    'On top of any map. Tap to switch on or off.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  for (final o in MapSource.overlays)
                    CheckboxListTile(
                      key: Key('overlay:${o.id}'),
                      value: trip.settings.overlays.contains(o.id),
                      title: Text(o.name),
                      subtitle: Text('${o.about}\n${saves(o)}'),
                      isThreeLine: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (on) async {
                        await trip.update((x) {
                          x.overlays.remove(o.id);
                          if (on == true) x.overlays.add(o.id);
                        });
                        set(() {});
                      },
                    ),
                  const Divider(),
                  for (final l in trip.layers.tileSets)
                    ListTile(
                      leading: Icon(
                        trip.baseTiles?.id == l.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(l.name),
                      subtitle: Text(
                        'Offline map on this phone · ${l.summary} · ${formatBytes(l.bytes)}',
                      ),
                      onTap: () {
                        trip.update((x) => x.mapSource = 'mbtiles:${l.id}');
                        Navigator.pop(ctx);
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.terrain),
                    title: const Text('Ready-made maps'),
                    subtitle: const Text(
                      'Silver Star & Trapper Creek maps, Portland to Gifford '
                      'Pinchot roads, one tap',
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _openPacks(trip);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.file_open),
                    title: const Text('Import a map or trail…'),
                    subtitle: const Text(
                      'GPX, KML, KMZ, MBTiles, or a park map picture / PDF',
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _openLayers(context, trip);
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
        ),
      ),
    );
  }

  // ------------------------------------------------------------ navigate

  int _buzzedOff = 0;
  NavSession? _buzzSession;
  bool _buzzedArrived = false;

  /// Vibrate when navigation goes off route / arrives.
  void _buzz(TripController trip) {
    final s = trip.nav;
    if (s != _buzzSession) {
      _buzzSession = s;
      _buzzedOff = 0;
      _buzzedArrived = false;
    }
    if (s == null) return;
    final off = s.follower?.offEvents ?? 0;
    if (off > _buzzedOff) {
      _buzzedOff = off;
      unawaited(navBuzz());
    }
    final arrived =
        s.state?.arrived ?? (s.straightM != null && s.straightM! <= 25);
    if (arrived && !_buzzedArrived) {
      _buzzedArrived = true;
      unawaited(navBuzz(arrived: true));
    }
  }

  void _openFollow(TripController trip) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => NavFollowPage(trip: trip)));

  // ------------------------------------------------ smart navigation (2.1.0)

  void _netChipTap(BuildContext context, TripController trip) {
    final m = ScaffoldMessenger.maybeOf(context);
    final st = trip.mapNet.state;
    m?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(switch (st) {
          MapNetState.online =>
            'Online: maps, search and routes come from the internet and '
                'are kept for later.',
          MapNetState.weak =>
            'Weak signal: online routes get a couple of seconds, then the '
                'saved maps are used.',
          MapNetState.offline =>
            'Offline maps: using what you saved on this phone. It switches '
                'back by itself when the signal returns.',
        }),
      ),
    );
    unawaited(trip.mapNet.probeNow());
  }

  /// "Navigate here": drive, hike, or drive then hike, picked for you.
  Future<void> _startSmart(
    TripController trip,
    GeoPoint to,
    String name,
  ) async {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 3),
        content: Text('Finding the best way there…'),
      ),
    );
    final plan = await trip.planSmart(to, name: name);
    if (!mounted) return;
    m?.hideCurrentSnackBar();
    switch (plan.kind) {
      case SmartKind.needRoadEnd:
        await _roadEndDialog(trip, plan, to, name);
        return;
      case SmartKind.noRoute:
        await _noRouteDialog(trip, plan, to, name);
        return;
      default:
        break;
    }
    await trip.startPlan(plan, to, name);
    if (!mounted) return;
    setState(() => _follow = false);
    final pts = [
      ...?plan.drive?.points,
      ...?plan.hike?.points,
      if (plan.drive == null && plan.hike == null) to,
    ];
    final b = boundsOfPoints(pts);
    if (b != null) _fit(b, maxZoom: 16);
    final imp = trip.settings.imperial;
    final t = plan.totals;
    final what = switch (plan.kind) {
      SmartKind.drive => 'Driving to $name.',
      SmartKind.hike => 'Walking to $name.',
      _ =>
        'Drive to ${plan.trailhead?.name ?? 'the trailhead'}, then hike '
            'to $name.',
    };
    m?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 9),
        content: Text(
          '$what Total ${formatDistance(t.metres, imperial: imp)}, about '
          '${driveDuration(t.time)}.'
          '${plan.message.isEmpty ? '' : ' ${plan.message}'}'
          '${plan.hikeNote.isEmpty ? '' : ' ${plan.hikeNote}'}',
        ),
        action: SnackBarAction(
          label: 'Follow',
          onPressed: () =>
              trip.drive != null ? _openDriveFollow(trip) : _openFollow(trip),
        ),
      ),
    );
  }

  Future<void> _noRouteDialog(
    TripController trip,
    SmartPlan plan,
    GeoPoint to,
    String name,
  ) async {
    final pick = await showDialog<String>(
      context: context,
      builder: (_) => NoRouteDialog(message: plan.message),
    );
    if (!mounted) return;
    switch (pick) {
      case 'offline':
        _openOffline(context, trip);
      case 'gentle':
        await _gentleSheet(trip, to, name);
      case 'compass':
        await _startNav(trip, to, name, compass: true);
    }
  }

  Future<void> _roadEndDialog(
    TripController trip,
    SmartPlan plan,
    GeoPoint to,
    String name,
  ) async {
    final end = plan.roadEnd;
    final pick = await showDialog<String>(
      context: context,
      builder: (_) => RoadEndDialog(
        name: name,
        message: plan.message,
        hasRoadEnd: end != null,
        awayText: end == null
            ? ''
            : formatDistance(
                plan.roadEndOffM ?? distanceM(end, to),
                imperial: trip.settings.imperial,
              ),
      ),
    );
    if (!mounted) return;
    if (pick == 'use' && end != null) {
      final res = await trip.driveToRoadEnd(end, to, name: name);
      if (!mounted) return;
      final s = res.session;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            s == null ? res.message : 'Driving to the road end, then hiking.',
          ),
          action: s == null
              ? null
              : SnackBarAction(
                  label: 'Follow',
                  onPressed: () => _openDriveFollow(trip),
                ),
        ),
      );
    } else if (pick == 'gentle') {
      await _gentleSheet(trip, to, name);
    }
  }

  /// "Gentle compass route": choose how steep is too steep, then compute.
  Future<void> _gentleSheet(
    TripController trip,
    GeoPoint to,
    String name,
  ) async {
    final pick = await showAppSheet<SlopeLimit>(
      context: context,
      builder: (_) => GentleSheetBody(name: name),
    );
    if (pick == null || !mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 3),
        content: Text('Working out a gentle route…'),
      ),
    );
    final res = await trip.gentleTo(to, name: name, limit: pick);
    if (!mounted) return;
    setState(() => _follow = false);
    final s = res.session;
    final me = trip.myFix?.pos;
    final b = s?.route != null
        ? boundsOfPoints(s!.route!.points)
        : (me == null ? null : boundsOfPoints([me, to]));
    if (b != null) _fit(b, maxZoom: 16);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(res.message),
        action: s == null
            ? null
            : SnackBarAction(
                label: 'Follow',
                onPressed: () => _openFollow(trip),
              ),
      ),
    );
  }

  /// The drive reached the trailhead: the walk has started; say so.
  void _maybeHandoff(TripController trip) {
    final h = trip.handoff;
    if (h == null || h.shown) return;
    h.shown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handoffSheet(trip, h);
    });
  }

  Future<void> _handoffSheet(TripController trip, TrailheadHandoff h) {
    return showAppSheet<void>(
      context: context,
      builder: (ctx) => HandoffSheetBody(
        handoff: h,
        imperial: trip.settings.imperial,
        onFollow: () {
          Navigator.pop(ctx);
          _openFollow(trip);
        },
        onRetry: () {
          Navigator.pop(ctx);
          trip.walkOn();
        },
        onGentle: () {
          Navigator.pop(ctx);
          final to = trip.drive?.hikeTo;
          if (to != null) _gentleSheet(trip, to, h.targetName);
        },
      ),
    );
  }

  Future<void> _startNav(
    TripController trip,
    GeoPoint to,
    String name, {
    bool compass = false,
  }) async {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(compass ? 'Compass to $name' : 'Finding a trail route…'),
      ),
    );
    final s = await trip.navigateTo(to, name: name, compass: compass);
    if (!mounted) return;
    setState(() => _follow = false);
    final r = s.route;
    final me = trip.myFix?.pos;
    if (r != null) {
      final b = boundsOfPoints(r.points);
      if (b != null) _fit(b, maxZoom: 16);
      m?.showSnackBar(
        SnackBar(
          content: Text(
            'Route: ${formatDistance(r.lengthM, imperial: trip.settings.imperial)} '
            'along trails, about ${_dur(s.state?.eta)}'
            '${r.junctions.isEmpty ? '' : ', ${r.junctions.length} junctions'}.'
            '${s.note.isEmpty ? '' : ' ${s.note}'}',
          ),
        ),
      );
    } else {
      final b = me == null ? null : boundsOfPoints([me, to]);
      if (b != null) _fit(b, maxZoom: 16);
      if (s.note.isNotEmpty) {
        m?.showSnackBar(SnackBar(content: Text(s.note)));
      }
    }
  }

  static String _dur(Duration? d) => d == null
      ? '?'
      : d.inHours < 1
      ? '${d.inMinutes} min'
      : '${d.inHours} h ${d.inMinutes % 60} min';

  /// Tap a waypoint / long-press the map: navigate, compass or pin.
  Future<void> _pointSheet(
    BuildContext context,
    TripController trip,
    GeoPoint at,
    String name, {
    bool search = false,
  }) async {
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
                leading: const Icon(Icons.place, size: 36),
                title: Text(name, style: Theme.of(ctx).textTheme.titleLarge),
                subtitle: Text(
                  '${at.lat.toStringAsFixed(5)}, ${at.lng.toStringAsFixed(5)}'
                  '${me == null ? '' : '\n${formatDistanceBearing(me, at, imperial: trip.settings.imperial)} straight line'}',
                ),
              ),
              FilledButton.icon(
                key: const Key('navigateHere'),
                icon: const Icon(Icons.directions_walk),
                label: const Text('Navigate here'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _startSmart(trip, at, name);
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Text(
                  'Picks the way: drive, hike, or drive to a trailhead and '
                  'then hike.',
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 6),
              FilledButton.tonalIcon(
                key: const Key('driveHere'),
                icon: const Icon(Icons.directions_car),
                label: const Text('Drive here'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _startDrive(trip, at, name);
                },
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                key: const Key('driveThenHike'),
                icon: const Icon(Icons.hiking),
                label: const Text('Drive to trailhead, then hike'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _startDrive(trip, at, name, hike: true);
                },
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                key: const Key('compassHere'),
                icon: const Icon(Icons.explore),
                label: const Text('Compass to here (straight line)'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _startNav(trip, at, name, compass: true);
                },
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                key: const Key('gentleHere'),
                icon: const Icon(Icons.terrain),
                label: const Text('Gentle compass route'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _gentleSheet(trip, at, name);
                },
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                icon: const Icon(Icons.push_pin_outlined),
                label: const Text('Drop a pin here'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _addPin(context, trip, at);
                },
              ),
              if (search)
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() => _hl = null);
                  },
                  child: const Text('Clear search result'),
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
          scrollable: true,
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
              FilledButton.icon(
                key: const Key('pinNavigate'),
                icon: const Icon(Icons.directions_walk),
                label: const Text('Navigate here'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _startSmart(trip, p.pos, p.title);
                },
              ),
              FilledButton.tonalIcon(
                key: const Key('pinDrive'),
                icon: const Icon(Icons.directions_car),
                label: const Text('Drive here'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _startDrive(trip, p.pos, p.title);
                },
              ),
              OutlinedButton.icon(
                key: const Key('pinCompass'),
                icon: const Icon(Icons.explore),
                label: const Text('Compass to here (straight line)'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _startNav(trip, p.pos, p.title, compass: true);
                },
              ),
              OutlinedButton.icon(
                key: const Key('pinGentle'),
                icon: const Icon(Icons.terrain),
                label: const Text('Gentle compass route'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _gentleSheet(trip, p.pos, p.title);
                },
              ),
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

  /// "\nMoving 34 mph heading NE; dot is a guess 120 m ahead" (v2.5.6).
  String _movingLine(TripController trip, PersonPos pp) {
    final v = pp.speedMps, h = pp.headingDeg;
    if (v == null || h == null || v < deadReckonMinSpeedMps) return '';
    final est = trip.friendEstimate(pp);
    final speed = trip.settings.imperial
        ? '${(v * 2.23694).round()} mph'
        : '${(v * 3.6).round()} km/h';
    return '\nMoving $speed heading ${cardinal(h)}'
        '${est.projected ? '; the dot is a guess ${formatDistance(est.aheadM, imperial: trip.settings.imperial)} ahead' : ''}';
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
                'Fix taken ${hhmm(pp.at)} (${exactAge(DateTime.now().difference(pp.at))} ago)${pp.held ? ' (via base camp)' : ''}'
                '${_movingLine(trip, pp)}',
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
          ActiveSosCard(
            sos: active,
            nameOf: c.nameOf,
            onCancel: trip.cancelSos,
          ),
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
        SwitchListTile(
          key: const Key('tripOfflineSaver'),
          contentPadding: EdgeInsets.zero,
          secondary: Icon(
            Icons.energy_savings_leaf,
            color: c.settings.offlineSaver ? Colors.green : null,
          ),
          title: const Text('Offline power save'),
          subtitle: Text(
            c.settings.offlineSaver
                ? 'On: internet relay, live location and map downloads off; '
                      'GPS every ${trip.plan.gpsInterval(visible: false, sosActive: false).inSeconds} s in the background'
                      '${trip.settings.checkInMinutes > 0 ? ', check-in every ${trip.checkInMinutesNow} min' : ''}. '
                      'Talk, relay, radio, SOS and quick messages still work.'
                : 'For hikes with no signal: longest battery life '
                      '(about 1.5-2x standby, estimate).',
          ),
          value: c.settings.offlineSaver,
          onChanged: (v) => c.setOfflineSaver(v),
        ),
        if (c.settings.offlineSaver)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.radar, size: 18),
              label: const Text('Look for nearby phones now'),
              onPressed: c.scanNearbyNow,
            ),
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
              key: const Key('openDrive'),
              icon: const Icon(Icons.directions_car),
              label: const Text('Directions'),
              onPressed: () => _directionsSheet(context, trip),
            ),
            OutlinedButton.icon(
              key: const Key('openOffline'),
              icon: const Icon(Icons.download_for_offline),
              label: const Text('Offline areas'),
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
        scrollable: true,
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
      scrollable: false,
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
                  Text(
                    'Trail summary over the LoRa radio',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final m in TripSettings.radioTrailChoices)
                        ChoiceChip(
                          label: Text(m == 0 ? 'Off' : 'Every $m min'),
                          selected: s.radioTrailMinutes == m,
                          onSelected: (_) =>
                              trip.update((x) => x.radioTrailMinutes = m),
                        ),
                    ],
                  ),
                  Text(
                    'While you record a trail: a thinned copy (up to 16 '
                    'points, one small packet) to phones only the radio '
                    'reaches.',
                    style: Theme.of(ctx).textTheme.bodySmall,
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
