import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../drive/online_router.dart';
import '../drive/road_router.dart' show DriveRoute, Maneuver;
import '../geo.dart';
import '../search/fetch.dart';
import '../search/rate_limiter.dart';
import 'trail_graph.dart';
import 'valhalla.dart';

/// Online walking and hiking routes (v2.1.0), free servers, no keys:
///
///  1. Valhalla "pedestrian" (valhalla1.openstreetmap.de): turn text, likes
///     tracks and paths, a little shy of hills.
///  2. BRouter "hiking-mountain" (brouter.de): hiking profile with
///     elevation.
///  3. OSRM foot on routing.openstreetmap.de/routed-foot: plain walking.
///
/// NEVER router.project-osrm.org for walking: that demo server only does
/// cars and silently answers a car route whatever profile is asked for.
/// At most one request a second, a real User-Agent (the app's [Fetch]), and
/// OpenStreetMap credit shown with the route.
class FootRouter {
  FootRouter({
    required this.fetch,
    RateLimiter? limiter,
    this.timeout = const Duration(seconds: 7),
    this.osrmFoot = defaultOsrmFoot,
    this.brouter = defaultBrouter,
    this.valhalla = Valhalla.endpoint,
    DateTime Function()? clock,
  }) : limiter = limiter ?? RateLimiter(const Duration(milliseconds: 1100)),
       _clock = clock ?? DateTime.now {
    if (osrmFoot.contains('project-osrm.org')) {
      throw ArgumentError(
        'router.project-osrm.org only does cars; never use it for walking',
      );
    }
  }

  final Fetch fetch;
  final RateLimiter limiter;

  /// The whole wait, all servers together (the caller shortens it while
  /// the connection is weak).
  final Duration timeout;
  final String osrmFoot, brouter, valhalla;
  final DateTime Function() _clock;

  static const defaultOsrmFoot = 'https://routing.openstreetmap.de/routed-foot';
  static const defaultBrouter = 'https://brouter.de/brouter';

  static const attribution =
      'Walking route: Valhalla / BRouter / OSRM on free OpenStreetMap '
      'servers. Paths © OpenStreetMap contributors. Something wrong? Fix the '
      'map: openstreetmap.org/fixthemap';

  static Uri brouterUri(String base, GeoPoint from, GeoPoint to) =>
      Uri.parse(base).replace(
        queryParameters: {
          'lonlats':
              '${from.lng.toStringAsFixed(6)},${from.lat.toStringAsFixed(6)}|'
              '${to.lng.toStringAsFixed(6)},${to.lat.toStringAsFixed(6)}',
          'profile': 'hiking-mountain',
          'alternativeidx': '0',
          'format': 'geojson',
        },
      );

  static Uri osrmFootUri(String base, GeoPoint from, GeoPoint to) {
    String c(GeoPoint p) =>
        '${p.lng.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}';
    return Uri.parse('$base/route/v1/foot/${c(from)};${c(to)}').replace(
      queryParameters: const {
        'overview': 'full',
        'geometries': 'polyline6',
        'steps': 'true',
        'generate_hints': 'false',
      },
    );
  }

  /// Which server answered the last route ('valhalla' / 'brouter' / 'osrm').
  String? lastProvider;

  /// A walking route from [from] to [to]; throws [OnlineRouteException].
  /// [timeout] overrides the default wait.
  Future<TrailRoute> route(
    GeoPoint from,
    GeoPoint to, {
    Duration? timeout,
  }) async {
    final budget = timeout ?? this.timeout;
    final start = _clock();
    Duration left() => budget - _clock().difference(start);
    final tries =
        <
          ({
            String name,
            FetchRequest Function(Duration t) request,
            TrailRoute Function(String body) parse,
          })
        >[
          (
            name: 'valhalla',
            request: (t) => FetchRequest(
              Uri.parse(valhalla),
              method: 'POST',
              headers: const {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: Valhalla.pedestrianBody(from, to),
              timeout: t,
              maxBytes: 6 * 1024 * 1024,
            ),
            parse: (b) => Valhalla.parseWalk(b, from: from, to: to),
          ),
          (
            name: 'brouter',
            request: (t) => FetchRequest(
              brouterUri(brouter, from, to),
              headers: const {'Accept': 'application/json'},
              timeout: t,
              maxBytes: 6 * 1024 * 1024,
            ),
            parse: (b) => parseBrouter(b, from: from, to: to),
          ),
          (
            name: 'osrm',
            request: (t) => FetchRequest(
              osrmFootUri(osrmFoot, from, to),
              headers: const {'Accept': 'application/json'},
              timeout: t,
              maxBytes: 6 * 1024 * 1024,
            ),
            parse: (b) => parseOsrmFoot(b, from: from, to: to),
          ),
        ];
    OnlineRouteException? last;
    for (var i = 0; i < tries.length; i++) {
      final l = left();
      if (l <= const Duration(milliseconds: 400)) break;
      // Leave time for the next server unless this is the last one.
      final t = i == tries.length - 1
          ? l
          : Duration(milliseconds: max(400, (l.inMilliseconds * 0.6).round()));
      final p = tries[i];
      String body;
      try {
        body = await limiter.run(() => fetch(p.request(t))).timeout(t);
      } on TimeoutException {
        last = OnlineRouteException(
          OnlineFail.noSignal,
          'No answer from the walking router (weak signal?).',
        );
        continue;
      } on NoSignalException {
        throw OnlineRouteException(OnlineFail.noSignal, 'No signal.');
      } on FetchException catch (e) {
        last = OnlineRouteException(OnlineFail.failed, e.message);
        continue;
      } catch (e) {
        last = OnlineRouteException(OnlineFail.failed, '$e');
        continue;
      }
      try {
        final r = p.parse(body);
        lastProvider = p.name;
        return r;
      } on OnlineRouteException catch (e) {
        last = e;
        // "No path there" from one router: another may still know one.
      }
    }
    throw last ??
        OnlineRouteException(
          OnlineFail.noSignal,
          'No answer from the walking router (weak signal?).',
        );
  }

  /// BRouter GeoJSON -> route (source 'brouter'), with its elevations.
  static TrailRoute parseBrouter(
    String body, {
    required GeoPoint from,
    required GeoPoint to,
  }) {
    Map j;
    try {
      j = jsonDecode(body) as Map;
    } catch (_) {
      // BRouter answers plain text when it cannot route.
      throw OnlineRouteException(
        OnlineFail.noRoute,
        'BRouter found no path there.',
      );
    }
    try {
      final f = (j['features'] as List).first as Map;
      final coords = (f['geometry'] as Map)['coordinates'] as List;
      final pts = <GeoPoint>[];
      final ele = <double>[];
      for (final c in coords) {
        final l = c as List;
        pts.add(GeoPoint((l[1] as num).toDouble(), (l[0] as num).toDouble()));
        ele.add(l.length > 2 ? (l[2] as num).toDouble() : double.nan);
      }
      if (pts.length < 2) {
        throw OnlineRouteException(OnlineFail.failed, 'Empty route.');
      }
      final r = TrailRoute(
        pts,
        ele,
        [],
        startOffM: distanceM(from, pts.first),
        endOffM: distanceM(to, pts.last),
      )..source = 'brouter';
      r.junctions.addAll(junctionsFromGeometry(r));
      return r;
    } on OnlineRouteException {
      rethrow;
    } catch (e) {
      throw OnlineRouteException(
        OnlineFail.failed,
        'Could not read the hiking route ($e).',
      );
    }
  }

  /// OSRM foot answer -> route (source 'osrm').
  static TrailRoute parseOsrmFoot(
    String body, {
    required GeoPoint from,
    required GeoPoint to,
  }) {
    final d = OnlineRouter.parse(body);
    final r = TrailRoute(
      d.points,
      List<double>.filled(d.points.length, double.nan),
      [],
      startOffM: d.startOffM,
      endOffM: d.endOffM,
    )..source = 'osrm';
    r.junctions.addAll(junctionsFromSteps(r, d));
    return r;
  }

  /// Junctions from a driving-style step list (OSRM).
  static List<RouteJunction> junctionsFromSteps(TrailRoute r, DriveRoute d) {
    final out = <RouteJunction>[];
    for (final s in d.steps) {
      final turn = switch (s.maneuver) {
        Maneuver.left => 'left',
        Maneuver.right => 'right',
        Maneuver.sharpLeft => 'sharp left',
        Maneuver.sharpRight => 'sharp right',
        Maneuver.slightLeft || Maneuver.keepLeft => 'slight left',
        Maneuver.slightRight || Maneuver.keepRight => 'slight right',
        Maneuver.uturn => 'around',
        _ => '',
      };
      if (turn.isEmpty) continue;
      var k = 0;
      while (k + 1 < r.cum.length && r.cum[k] < s.alongM - 0.5) {
        k++;
      }
      if (k <= 0 || k >= r.points.length - 1) continue;
      out.add(RouteJunction(k, r.cum[k], turn, s.road));
    }
    return out;
  }

  /// Turns found from the line itself (when the server gives no turn text):
  /// a change of heading of 45 degrees or more over ~25 m each side, at
  /// least 60 m after the last one.
  static List<RouteJunction> junctionsFromGeometry(TrailRoute r) {
    final out = <RouteJunction>[];
    var lastAt = -1e9;
    GeoPoint back(int k) {
      var i = k - 1;
      while (i > 0 && r.cum[k] - r.cum[i] < 25) {
        i--;
      }
      return r.points[max(0, i)];
    }

    GeoPoint ahead(int k) {
      var i = k + 1;
      while (i < r.points.length - 1 && r.cum[i] - r.cum[k] < 25) {
        i++;
      }
      return r.points[min(r.points.length - 1, i)];
    }

    for (var k = 1; k + 1 < r.points.length; k++) {
      if (r.cum[k] - lastAt < 60) continue;
      final inB = bearingDeg(back(k), r.points[k]);
      final outB = bearingDeg(r.points[k], ahead(k));
      final t = deltaDeg(outB, inB);
      if (t.abs() < 45) continue;
      final turn = t.abs() > 120
          ? (t < 0 ? 'sharp left' : 'sharp right')
          : (t < 0 ? 'left' : 'right');
      out.add(RouteJunction(k, r.cum[k], turn, ''));
      lastAt = r.cum[k];
    }
    return out;
  }
}

/// [r] with the real start and target added at the ends when the router
/// snapped them to a path some distance away (a peak off the trail): the
/// last bit is then an honest straight off-trail leg ([TrailRoute.startOffM]
/// / [TrailRoute.endOffM]).
TrailRoute routeWithEnds(
  TrailRoute r,
  GeoPoint from,
  GeoPoint to, {
  double minGapM = 12,
}) {
  final addStart = distanceM(from, r.points.first) > minGapM;
  final addEnd = distanceM(to, r.points.last) > minGapM;
  if (!addStart && !addEnd) return r;
  final pts = [if (addStart) from, ...r.points, if (addEnd) to];
  final ele = [if (addStart) r.ele.first, ...r.ele, if (addEnd) r.ele.last];
  final shift = addStart ? 1 : 0;
  final out = TrailRoute(
    pts,
    ele,
    [],
    startOffM: addStart ? distanceM(from, r.points.first) : 0,
    endOffM: addEnd ? distanceM(to, r.points.last) : 0,
  )..source = r.source;
  for (final j in r.junctions) {
    final k = j.index + shift;
    out.junctions.add(RouteJunction(k, out.cum[k], j.turn, j.next));
  }
  return out;
}
