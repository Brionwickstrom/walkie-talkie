import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../trip/drive/drive_session.dart';
import '../trip/drive/online_router.dart';
import '../trip/drive/road_router.dart';
import '../trip/geo.dart';
import '../trip/trip_controller.dart';
import 'map_layer_widgets.dart';
import 'nav_page.dart' show navBuzz;
import 'sheets.dart';

String driveDuration(Duration d) {
  if (d.inMinutes < 1) return '< 1 min';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${d.inMinutes % 60} min';
}

String _clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Icon for a turn.
IconData maneuverIcon(Maneuver m) => switch (m) {
  Maneuver.depart => Icons.navigation,
  Maneuver.straight => Icons.straight,
  Maneuver.slightLeft => Icons.turn_slight_left,
  Maneuver.left => Icons.turn_left,
  Maneuver.sharpLeft => Icons.turn_sharp_left,
  Maneuver.slightRight => Icons.turn_slight_right,
  Maneuver.right => Icons.turn_right,
  Maneuver.sharpRight => Icons.turn_sharp_right,
  Maneuver.uturn => Icons.u_turn_left,
  Maneuver.keepLeft => Icons.fork_left,
  Maneuver.keepRight => Icons.fork_right,
  Maneuver.rampLeft => Icons.ramp_left,
  Maneuver.rampRight => Icons.ramp_right,
  Maneuver.ramp => Icons.straight,
  Maneuver.merge => Icons.merge,
  Maneuver.roundabout => Icons.roundabout_right,
  Maneuver.arrive => Icons.flag,
};

/// Colour of a road stretch by roughness (normal, gravel, rough, 4WD).
Color roughColor(int r) => switch (r) {
  0 => const Color(0xFF1565C0),
  1 => const Color(0xFF6D4C41),
  2 => const Color(0xFFEF6C00),
  _ => const Color(0xFFC62828),
};

/// The route on the map, coloured by roughness.
List<Polyline> driveLines(DriveRoute r) {
  final out = <Polyline>[];
  var start = 0;
  for (var i = 1; i <= r.segRough.length; i++) {
    if (i < r.segRough.length && r.segRough[i] == r.segRough[start]) continue;
    final rough = r.segRough.isEmpty ? 0 : r.segRough[start];
    out.add(
      Polyline(
        points: [
          for (var k = start; k <= i && k < r.points.length; k++)
            LatLng(r.points[k].lat, r.points[k].lng),
        ],
        strokeWidth: 7,
        color: roughColor(rough).withValues(alpha: 0.85),
        borderStrokeWidth: 1.5,
        borderColor: Colors.white,
        pattern: rough >= 2
            ? StrokePattern.dashed(segments: const [14, 6])
            : const StrokePattern.solid(),
      ),
    );
    start = i;
  }
  return out;
}

/// "12.3 mi · 25 min · arrive 6:42 AM".
String driveSummary(DriveSession s, bool imperial, DateTime now) {
  final st = s.state;
  final left = st?.leftM ?? s.route.lengthM;
  final t = st?.timeLeft ?? s.route.duration;
  return '${formatDistance(left, imperial: imperial)} · ${driveDuration(t)} · '
      'arrive ${_clock(now.add(t))}';
}

/// The warnings worth a line on the card ("not checked" is shown with
/// the route source instead).
List<RoadWarning> mainWarnings(DriveRoute r) => [
  for (final w in r.warnings)
    if (w.kind != 'unknown' && (w.kind != 'unpaved' || w.lengthM > 1000)) w,
];

/// "Online route" / "Offline route", and what is not known.
class DriveSourceLine extends StatelessWidget {
  const DriveSourceLine({super.key, required this.session, this.color});
  final DriveSession session;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final r = session.route;
    final unknown = r.warnings.where((w) => w.kind == 'unknown').firstOrNull;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              r.isOnline ? Icons.cloud_done : Icons.offline_pin,
              size: 15,
              color:
                  color ?? (r.isOnline ? Colors.blue : Colors.green.shade700),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '${session.sourceLabel}'
                '${r.isOnline ? ' · kept on the phone if signal drops' : ' · from saved roads'}',
                key: const Key('driveSource'),
                style: style,
              ),
            ),
          ],
        ),
        if (unknown != null)
          Text(unknown.text, key: const Key('driveUnknown'), style: style),
        if (session.notice.isNotEmpty)
          Text(
            session.notice,
            key: const Key('driveNotice'),
            style: style?.copyWith(fontWeight: FontWeight.w600),
          ),
      ],
    );
  }
}

/// Small card on the Trip map while driving.
class DriveCard extends StatelessWidget {
  const DriveCard({
    super.key,
    required this.trip,
    required this.session,
    required this.onFollow,
  });
  final TripController trip;
  final DriveSession session;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final imperial = trip.settings.imperial;
    final st = s.state;
    final r = s.route;
    final next = st == null ? null : r.steps[st.nextStep];
    final warn = mainWarnings(r);
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 330),
      child: Card(
        key: const Key('driveCard'),
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onFollow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      next == null
                          ? Icons.directions_car
                          : maneuverIcon(next.maneuver),
                      size: 30,
                      color: Colors.blue.shade800,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Drive to ${s.name}',
                            style: theme.textTheme.labelMedium,
                          ),
                          Text(
                            driveSummary(s, imperial, DateTime.now()),
                            style: theme.textTheme.titleSmall,
                          ),
                          DriveSourceLine(session: s),
                          if (s.arrived)
                            Text('Arrived.', style: theme.textTheme.bodySmall)
                          else if (next != null)
                            Text(
                              'In ${formatDistance(st!.nextInM, imperial: imperial)}: ${next.text}',
                              style: theme.textTheme.bodySmall,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                for (final w in warn.take(3))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          size: 16,
                          color: w.kind == 'clearance' || w.kind == 'closed'
                              ? Colors.red
                              : Colors.orange.shade800,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            w.text,
                            key: const Key('driveWarning'),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (warn.length > 3)
                  Text(
                    '+${warn.length - 3} more (Steps)',
                    style: theme.textTheme.bodySmall,
                  ),
                Wrap(
                  children: [
                    TextButton(
                      key: const Key('driveStop'),
                      onPressed: trip.stopDrive,
                      child: const Text('Stop'),
                    ),
                    TextButton(
                      key: const Key('driveSteps'),
                      onPressed: () => showDriveSteps(context, trip, s),
                      child: const Text('Steps'),
                    ),
                    if (s.arrived && (s.hikeTo != null || r.endOffM > 30))
                      FilledButton.tonal(
                        key: const Key('walkOn'),
                        onPressed: trip.walkOn,
                        child: const Text('Navigate here'),
                      )
                    else
                      FilledButton.tonal(
                        key: const Key('driveFollow'),
                        onPressed: onFollow,
                        child: const Text('Follow'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// All the turns and warnings.
Future<void> showDriveSteps(
  BuildContext context,
  TripController trip,
  DriveSession s,
) => showAppSheet<void>(
  context: context,
  scrollable: false,
  showDragHandle: false,
  builder: (ctx) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    builder: (ctx, scroll) {
      final r = s.route;
      final imperial = trip.settings.imperial;
      return ListView(
        key: const Key('driveStepList'),
        controller: scroll,
        children: [
          ListTile(
            title: Text(
              'Drive to ${s.name}',
              style: Theme.of(ctx).textTheme.titleLarge,
            ),
            trailing: Text(s.sourceLabel, key: const Key('driveStepsSource')),
            subtitle: Text(
              '${formatDistance(r.lengthM, imperial: imperial)} · '
              '${driveDuration(r.duration)} by road'
              '${r.startOffM > 40 ? '\nStart: ${formatDistance(r.startOffM, imperial: imperial)} to the nearest ${r.isOnline ? '' : 'saved '}road' : ''}',
            ),
          ),
          for (final w in r.warnings)
            ListTile(
              dense: true,
              leading: const Icon(Icons.warning_amber, color: Colors.orange),
              title: Text(w.text),
            ),
          const Divider(),
          for (var i = 0; i < r.steps.length; i++)
            ListTile(
              dense: true,
              leading: Icon(maneuverIcon(r.steps[i].maneuver)),
              title: Text(r.steps[i].text),
              trailing: i + 1 < r.steps.length
                  ? Text(
                      formatDistance(
                        r.steps[i + 1].alongM - r.steps[i].alongM,
                        imperial: imperial,
                      ),
                    )
                  : null,
            ),
          ListTile(
            dense: true,
            title: Text(
              '${r.isOnline ? OnlineRouter.attribution : 'Offline route from the roads saved on this phone. Roads © OpenStreetMap contributors.'}\n'
              'Times are estimates from road speeds (no live traffic). Check '
              'road and gate status with the Forest Service before you go.',
            ),
          ),
        ],
      );
    },
  ),
);

/// Full-screen driving: next turn, big arrow, distance, spoken prompts,
/// map that follows you heading-up, re-route, mute.
class DriveFollowPage extends StatefulWidget {
  const DriveFollowPage({super.key, required this.trip, this.showMap = true});
  final TripController trip;

  /// Tests: no tiles.
  final bool showMap;

  @override
  State<DriveFollowPage> createState() => _DriveFollowPageState();
}

class _DriveFollowPageState extends State<DriveFollowPage> {
  final _map = MapController();
  bool _ready = false;
  bool _follow = true;
  bool _headingUp = true;
  int _buzzedOff = 0;
  Timer? _resume;

  TripController get trip => widget.trip;

  @override
  void dispose() {
    _resume?.cancel();
    super.dispose();
  }

  double _zoomFor(double speed) => speed > 22
      ? 14.5
      : speed > 12
      ? 15.5
      : 16.5;

  void _track(DriveSession s) {
    if (!_ready || !_follow) return;
    final me = s.me;
    if (me == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_follow) return;
      final rot = _headingUp && s.course != null ? -s.course! : 0.0;
      _map.moveAndRotate(LatLng(me.lat, me.lng), _zoomFor(s.speedMps), rot);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trip,
      builder: (context, _) {
        final s = trip.drive;
        if (s == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Driving')),
            body: const Center(child: Text('Not driving anywhere.')),
          );
        }
        final off = s.follower.offEvents;
        if (off > _buzzedOff) {
          _buzzedOff = off;
          unawaited(navBuzz());
        }
        _track(s);
        return Scaffold(
          body: Stack(
            children: [
              if (widget.showMap) _mapView(s) else const SizedBox.expand(),
              SafeArea(child: _banner(context, s)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(child: _bottom(context, s)),
              ),
              if (!_follow)
                Positioned(
                  right: 16,
                  bottom: 170,
                  child: FloatingActionButton.extended(
                    key: const Key('driveRecenter'),
                    onPressed: () => setState(() => _follow = true),
                    icon: const Icon(Icons.my_location),
                    label: const Text('Re-center'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _mapView(DriveSession s) {
    final me = s.me;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: LatLng(
          (me ?? s.route.points.first).lat,
          (me ?? s.route.points.first).lng,
        ),
        initialZoom: 15,
        onMapReady: () => setState(() => _ready = true),
        onPositionChanged: (_, gesture) {
          if (!gesture || !_follow) return;
          setState(() => _follow = false);
          // Back to following after a while.
          _resume?.cancel();
          _resume = Timer(const Duration(seconds: 15), () {
            if (mounted) setState(() => _follow = true);
          });
        },
      ),
      children: [
        ...baseTileLayers(trip),
        PolylineLayer(polylines: driveLines(s.route)),
        MarkerLayer(
          markers: [
            Marker(
              point: LatLng(s.target.lat, s.target.lng),
              width: 36,
              height: 36,
              child: const Icon(Icons.flag, color: Colors.red, size: 32),
            ),
            if (me != null)
              Marker(
                point: LatLng(me.lat, me.lng),
                width: 44,
                height: 44,
                rotate: false,
                child: Transform.rotate(
                  angle:
                      ((s.course ?? s.state?.bearingAhead ?? 0) -
                          (_headingUp && s.course != null ? s.course! : 0)) *
                      3.14159265 /
                      180,
                  child: const Icon(
                    Icons.navigation,
                    size: 40,
                    color: Color(0xFF1565C0),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _banner(BuildContext context, DriveSession s) {
    final imperial = trip.settings.imperial;
    final st = s.state;
    final r = s.route;
    final theme = Theme.of(context);
    if (s.rerouting || (st?.offRoute ?? false)) {
      return Card(
        key: const Key('driveOffRoute'),
        color: Colors.red.shade700,
        margin: const EdgeInsets.all(8),
        child: ListTile(
          leading: const Icon(Icons.alt_route, color: Colors.white, size: 40),
          title: Text(
            s.rerouting ? 'Rerouting…' : 'Off route',
            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
          ),
          subtitle: st == null
              ? null
              : Text(
                  '${formatDistance(st.offM, imperial: imperial)} from the route'
                  '${s.notice.isNotEmpty && !s.rerouting ? '\n${s.notice}' : ''}',
                  style: const TextStyle(color: Colors.white),
                ),
        ),
      );
    }
    if (s.arrived) {
      return Card(
        key: const Key('driveArrived'),
        color: Colors.green.shade700,
        margin: const EdgeInsets.all(8),
        child: ListTile(
          leading: const Icon(Icons.flag, color: Colors.white, size: 40),
          title: Text(
            'Arrived at ${s.name}',
            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
          ),
          subtitle: s.hikeTo != null || r.endOffM > 30
              ? Text(
                  s.hikeTo != null
                      ? 'Hiking to ${s.hikeName}: trail directions are on.'
                      : '${formatDistance(r.endOffM, imperial: imperial)} more on foot.',
                  style: const TextStyle(color: Colors.white),
                )
              : null,
          trailing: s.hikeTo == null && r.endOffM > 30
              ? FilledButton(
                  key: const Key('walkOnFollow'),
                  onPressed: () async {
                    await trip.walkOn();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Navigate here'),
                )
              : null,
        ),
      );
    }
    final i = st?.nextStep ?? 1.clamp(0, r.steps.length - 1);
    final step = r.steps[i];
    final then = i + 1 < r.steps.length ? r.steps[i + 1] : null;
    final dist = st?.nextInM ?? step.alongM;
    return Card(
      key: const Key('driveNext'),
      color: const Color(0xFF0D47A1),
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  maneuverIcon(step.maneuver),
                  size: 64,
                  color: Colors.white,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatDistance(dist, imperial: imperial),
                        key: const Key('driveNextDist'),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        step.text,
                        key: const Key('driveNextText'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (then != null && then.alongM - step.alongM < 400)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Text(
                      'Then ',
                      style: TextStyle(color: Colors.white70),
                    ),
                    Icon(
                      maneuverIcon(then.maneuver),
                      color: Colors.white70,
                      size: 20,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        then.text,
                        style: const TextStyle(color: Colors.white70),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            if (st != null && st.road.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'On ${st.road}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottom(BuildContext context, DriveSession s) {
    final voice = trip.settings.driveVoice;
    final r = s.route;
    final st = s.state;
    // Rough road coming up (or now).
    RoadWarning? soon;
    final along = st?.alongM ?? 0;
    for (final w in mainWarnings(r)) {
      if (w.alongM + w.lengthM >= along && w.alongM - along < 3000) {
        soon = w;
        break;
      }
    }
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              driveSummary(s, trip.settings.imperial, DateTime.now()),
              key: const Key('driveSummary'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            DriveSourceLine(session: s),
            if (soon != null)
              Row(
                children: [
                  const Icon(
                    Icons.warning_amber,
                    color: Colors.orange,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      soon.text,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  key: const Key('driveMute'),
                  tooltip: voice ? 'Mute directions' : 'Speak directions',
                  icon: Icon(voice ? Icons.volume_up : Icons.volume_off),
                  onPressed: () => trip.setDriveVoice(!voice),
                ),
                IconButton(
                  key: const Key('driveHeading'),
                  tooltip: _headingUp
                      ? 'Heading up (tap: north up)'
                      : 'North up',
                  icon: Icon(_headingUp ? Icons.navigation : Icons.north),
                  onPressed: () => setState(() {
                    _headingUp = !_headingUp;
                    _follow = true;
                  }),
                ),
                TextButton(
                  key: const Key('driveReroute'),
                  onPressed: s.rerouting ? null : trip.rerouteDrive,
                  child: const Text('Re-route'),
                ),
                TextButton(
                  key: const Key('driveStepsFollow'),
                  onPressed: () => showDriveSteps(context, trip, s),
                  child: const Text('Steps'),
                ),
                TextButton(
                  key: const Key('driveStopFollow'),
                  onPressed: () async {
                    await trip.stopDrive();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Stop'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
