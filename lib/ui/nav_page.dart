import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../trip/geo.dart';
import '../trip/nav/foot_router.dart' show FootRouter;
import '../trip/nav/gentle_route.dart' show gentleLabel;
import '../trip/nav/nav_session.dart';
import '../trip/nav/trail_graph.dart';
import '../trip/trip_controller.dart';
import 'trip_widgets.dart';

String _dur(Duration d) {
  if (d.inMinutes < 1) return '< 1 min';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${d.inMinutes % 60} min';
}

String _elev(double m, bool imperial) =>
    imperial ? '${(m * 3.28084).round()} ft' : '${m.round()} m';

/// Buzz the phone: off route (three long) / arrived (two short).
Future<void> navBuzz({bool arrived = false}) async {
  for (var i = 0; i < (arrived ? 2 : 3); i++) {
    await (arrived ? HapticFeedback.mediumImpact() : HapticFeedback.vibrate());
    await Future<void>.delayed(Duration(milliseconds: arrived ? 150 : 400));
  }
}

/// Summary lines for a navigation session.
({String main, String sub}) navSummary(NavSession s, bool imperial) {
  final st = s.state;
  if (s.compass || st == null) {
    final m = s.straightM;
    return (
      main: m == null
          ? 'Waiting for GPS'
          : '${formatDistance(m, imperial: imperial)} '
                '${cardinal(s.straightBearing!)} (straight line)',
      sub: s.note.isNotEmpty ? s.note : 'Compass to ${s.name}',
    );
  }
  final next = st.next;
  return (
    main:
        '${formatDistance(st.leftM, imperial: imperial)} left · '
        '${_dur(st.eta)}',
    sub: st.offRoute
        ? 'Off route by ${formatDistance(st.offM, imperial: imperial)}: '
              'head ${cardinal(st.bearingToRoute)}'
        : next != null
        ? 'In ${formatDistance(st.nextInM!, imperial: imperial)}: ${next.text}'
        : 'Follow the trail to ${s.name}',
  );
}

/// Small card on the Trip map while navigating.
class NavCard extends StatelessWidget {
  const NavCard({
    super.key,
    required this.trip,
    required this.session,
    required this.onFollow,
  });
  final TripController trip;
  final NavSession session;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final imperial = trip.settings.imperial;
    final sum = navSummary(s, imperial);
    final off = s.state?.offRoute ?? false;
    final bearing = off
        ? s.state!.bearingToRoute
        : s.compass
        ? s.straightBearing
        : s.state?.bearingAhead;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Card(
        key: const Key('navCard'),
        margin: EdgeInsets.zero,
        color: off ? Colors.red.shade100 : null,
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
                    if (bearing != null)
                      BearingArrow(
                        angleDeg: arrowAngleDeg(bearing, trip.heading),
                        size: 28,
                        color: off ? Colors.red : Colors.blue,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'To ${s.name}',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          Text(
                            sum.main,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            sum.sub,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const Key('navStop'),
                      onPressed: trip.stopNav,
                      child: const Text('Stop'),
                    ),
                    FilledButton.tonal(
                      key: const Key('navFollow'),
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

/// The follow screen: big arrow, next junction, distance left, ETA,
/// climb left and the elevation profile.
class NavFollowPage extends StatelessWidget {
  const NavFollowPage({super.key, required this.trip});
  final TripController trip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: trip,
      builder: (context, _) {
        final s = trip.nav;
        if (s == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Navigation')),
            body: const Center(child: Text('Navigation stopped.')),
          );
        }
        return ListenableBuilder(
          listenable: s,
          builder: (context, _) => _body(context, s),
        );
      },
    );
  }

  Widget _body(BuildContext context, NavSession s) {
    final theme = Theme.of(context);
    final imperial = trip.settings.imperial;
    final st = s.state;
    final off = st?.offRoute ?? false;
    final bearing = off
        ? st!.bearingToRoute
        : s.compass || st == null
        ? s.straightBearing
        : st.bearingAhead;
    final sum = navSummary(s, imperial);
    final r = s.route;
    return Scaffold(
      appBar: AppBar(title: Text('To ${s.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (off)
            Card(
              key: const Key('offRoute'),
              color: Colors.red.shade100,
              child: ListTile(
                leading: const Icon(Icons.warning_amber, color: Colors.red),
                title: Text(
                  'Off route: ${formatDistance(st!.offM, imperial: imperial)} '
                  'away',
                ),
                subtitle: Text(
                  'Follow the red arrow back (${cardinal(st.bearingToRoute)}), '
                  'or route again from here.',
                ),
                trailing: TextButton(
                  key: const Key('reroute'),
                  onPressed: () => trip.reroute(),
                  child: const Text('Re-route'),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Center(
            child: bearing == null
                ? const Icon(Icons.gps_not_fixed, size: 120)
                : BearingArrow(
                    angleDeg: arrowAngleDeg(bearing, trip.heading),
                    size: 160,
                    color: off ? Colors.red : theme.colorScheme.primary,
                  ),
          ),
          if (trip.heading == null)
            Text(
              'No compass: the arrow points as if the top of the phone faces north.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 12),
          Text(
            sum.main,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          Text(
            sum.sub,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          if (st?.next != null && !off) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: Icon(_turnIcon(st!.next!.turn), size: 36),
                title: Text('Next junction: ${st.next!.text}'),
                subtitle: Text(
                  'In ${formatDistance(st.nextInM!, imperial: imperial)}',
                ),
              ),
            ),
          ],
          if (r != null && st != null) ...[
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              children: [
                _fact(
                  'Total',
                  formatDistance(r.lengthM, imperial: imperial),
                  theme,
                ),
                _fact('Time left', _dur(st.eta), theme),
                if (r.hasElevation) ...[
                  _fact('Climb left', _elev(st.gainLeftM, imperial), theme),
                  _fact('Descent left', _elev(st.lossLeftM, imperial), theme),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (r.hasElevation)
              SizedBox(
                height: 140,
                child: ElevationProfile(
                  key: const Key('profile'),
                  route: r,
                  atM: st.alongM,
                  imperial: imperial,
                ),
              )
            else
              Text(
                s.note.isEmpty ? 'No elevation data for this route.' : s.note,
                style: theme.textTheme.bodySmall,
              ),
            if (r.terrainOnly)
              Card(
                key: const Key('terrainOnly'),
                color: Colors.orange.shade100,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    '$gentleLabel.\nThe plain straight line to ${s.name} is '
                    '${formatDistance(s.straightM ?? r.lengthM, imperial: imperial)} '
                    '${s.straightBearing == null ? '' : cardinal(s.straightBearing!)} '
                    '(the dashed grey line on the map).',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            if (r.isOnline)
              Text(FootRouter.attribution, style: theme.textTheme.bodySmall),
            if (r.startOffM > 30 && !r.isOnline)
              Text(
                'Starts with ${formatDistance(r.startOffM, imperial: imperial)} '
                'off trail to the nearest trail.',
                style: theme.textTheme.bodySmall,
              ),
            if (r.endOffM > 30)
              Text(
                'Ends with ${formatDistance(r.endOffM, imperial: imperial)} '
                'without a mapped path to the point.',
                style: theme.textTheme.bodySmall,
              ),
          ],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!s.compass)
                OutlinedButton.icon(
                  onPressed: () => trip.reroute(),
                  icon: const Icon(Icons.alt_route),
                  label: const Text('Re-route'),
                ),
              OutlinedButton.icon(
                key: const Key('trailVoice'),
                onPressed: () => trip.setTrailVoice(!trip.settings.trailVoice),
                icon: Icon(
                  trip.settings.trailVoice ? Icons.volume_up : Icons.volume_off,
                ),
                label: Text(
                  trip.settings.trailVoice ? 'Voice on' : 'Voice off',
                ),
              ),
              OutlinedButton.icon(
                key: const Key('shareRoute'),
                onPressed: () {
                  final res = trip.shareNavRoute();
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        res.parts == 0
                            ? 'Nothing to share yet.'
                            : 'Shared the route with the group'
                                  '${res.radio ? ' (an outline goes over the LoRa radio too)' : ''}.',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.share),
                label: const Text('Share route'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  await trip.stopNav();
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Works with no signal: GPS and the trails on this phone. GPS '
            'checks every ${trip.plan.navInterval.inSeconds} s while navigating'
            '${trip.plan.transportSaver ? ' (power save)' : ''}. Times use '
            "Naismith's rule (5 km/h + 1 h per 600 m climb).",
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  static IconData _turnIcon(String t) => switch (t) {
    'left' => Icons.turn_left,
    'right' => Icons.turn_right,
    'sharp left' => Icons.turn_sharp_left,
    'sharp right' => Icons.turn_sharp_right,
    'slight left' => Icons.turn_slight_left,
    'slight right' => Icons.turn_slight_right,
    'around' => Icons.u_turn_left,
    _ => Icons.straight,
  };

  Widget _fact(String k, String v, ThemeData t) => Column(
    children: [
      Text(v, style: t.textTheme.titleMedium),
      Text(k, style: t.textTheme.bodySmall),
    ],
  );
}

/// Elevation profile chart with "you are here".
class ElevationProfile extends StatelessWidget {
  const ElevationProfile({
    super.key,
    required this.route,
    this.atM,
    this.imperial = true,
  });
  final TrailRoute route;
  final double? atM;
  final bool imperial;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ProfilePainter(
      route.profile(),
      route.lengthM,
      atM,
      imperial,
      Theme.of(context).colorScheme.primary,
      Theme.of(context).textTheme.bodySmall?.color ?? Colors.black54,
    ),
    size: Size.infinite,
  );
}

class _ProfilePainter extends CustomPainter {
  _ProfilePainter(
    this.pts,
    this.length,
    this.at,
    this.imperial,
    this.color,
    this.text,
  );
  final List<(double, double)> pts;
  final double length;
  final double? at;
  final bool imperial;
  final Color color, text;

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.length < 2 || length <= 0) return;
    final lo = pts.map((p) => p.$2).reduce(math.min);
    final hi = pts.map((p) => p.$2).reduce(math.max);
    final span = math.max(20.0, hi - lo);
    const left = 44.0, bottom = 16.0;
    final w = size.width - left, h = size.height - bottom;
    Offset o(double m, double e) =>
        Offset(left + m / length * w, h - (e - lo) / span * (h - 8) - 4);
    final path = Path()..moveTo(o(pts.first.$1, pts.first.$2).dx, h);
    for (final p in pts) {
      final q = o(p.$1, p.$2);
      path.lineTo(q.dx, q.dy);
    }
    path
      ..lineTo(o(pts.last.$1, pts.last.$2).dx, h)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.25));
    final line = Path();
    for (var i = 0; i < pts.length; i++) {
      final q = o(pts[i].$1, pts[i].$2);
      i == 0 ? line.moveTo(q.dx, q.dy) : line.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    void label(String s, Offset at) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(fontSize: 10, color: text),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at);
    }

    label(_elev(hi, imperial), const Offset(0, 0));
    label(_elev(lo, imperial), Offset(0, h - 12));
    label('0', Offset(left, h + 2));
    label(
      formatDistance(length, imperial: imperial),
      Offset(size.width - 40, h + 2),
    );
    final a = at;
    if (a != null) {
      final x = left + (a / length).clamp(0.0, 1.0) * w;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, h),
        Paint()
          ..color = Colors.red
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_ProfilePainter old) =>
      old.at != at || old.pts != pts || old.imperial != imperial;
}
