import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../drive/online_router.dart';
import '../drive/road_router.dart';
import '../geo.dart';
import 'trail_graph.dart';

/// Reads answers from a Valhalla routing server (valhalla1.openstreetmap.de,
/// run by FOSSGIS for OpenStreetMap), v2.1.0: walking routes (turn text
/// along roads, tracks and paths) and driving routes as a second opinion
/// when the OSRM car servers do not answer.
class Valhalla {
  Valhalla._();

  static const endpoint = 'https://valhalla1.openstreetmap.de/route';

  static const attribution =
      'Walking routes: Valhalla on the FOSSGIS server '
      '(valhalla1.openstreetmap.de). Paths © OpenStreetMap contributors.';

  /// Request body for a walking route: a little hill-shy, tracks and paths
  /// welcome, hiking speed.
  static String pedestrianBody(GeoPoint from, GeoPoint to) => jsonEncode({
    'locations': [
      {'lat': from.lat, 'lon': from.lng},
      {'lat': to.lat, 'lon': to.lng},
    ],
    'costing': 'pedestrian',
    'costing_options': {
      'pedestrian': {'walking_speed': 4.5, 'use_hills': 0.3, 'use_tracks': 0.6},
    },
    'directions_options': {'units': 'kilometers', 'language': 'en-US'},
  });

  static String autoBody(GeoPoint from, GeoPoint to) => jsonEncode({
    'locations': [
      {'lat': from.lat, 'lon': from.lng},
      {'lat': to.lat, 'lon': to.lng},
    ],
    'costing': 'auto',
    'directions_options': {'units': 'kilometers', 'language': 'en-US'},
  });

  static Map _trip(String body) {
    Map j;
    try {
      j = jsonDecode(body) as Map;
    } catch (_) {
      throw OnlineRouteException(OnlineFail.failed, 'Bad answer from router.');
    }
    if (j['trip'] is! Map) {
      final code = j['error_code'];
      final msg = '${j['error'] ?? 'no route'}';
      // 442 / 171: no road or path near a point; 442 no route found.
      if (code == 171 || code == 442 || code == 443 || code == 442) {
        throw OnlineRouteException(OnlineFail.noRoute, msg);
      }
      throw OnlineRouteException(OnlineFail.failed, 'Online router: $msg');
    }
    return j['trip'] as Map;
  }

  static String _clean(String s) =>
      s.endsWith('.') ? s.substring(0, s.length - 1) : s;

  static String _street(Map m) {
    final n = m['street_names'];
    if (n is List && n.isNotEmpty) return '${n.first}';
    return '';
  }

  /// A walking answer as a [TrailRoute] (source 'valhalla').
  static TrailRoute parseWalk(
    String body, {
    required GeoPoint from,
    required GeoPoint to,
  }) {
    final t = _trip(body);
    try {
      final leg = (t['legs'] as List).first as Map;
      final pts = OnlineRouter.decodePolyline(leg['shape'] as String);
      if (pts.length < 2) {
        throw OnlineRouteException(OnlineFail.failed, 'Empty route.');
      }
      final ele = List<double>.filled(pts.length, double.nan);
      final r = TrailRoute(
        pts,
        ele,
        [],
        startOffM: distanceM(from, pts.first),
        endOffM: distanceM(to, pts.last),
      )..source = 'valhalla';
      final ms = [for (final m in leg['maneuvers'] as List) m as Map];
      for (final m in ms) {
        final type = (m['type'] as num?)?.toInt() ?? 0;
        final idx = ((m['begin_shape_index'] as num?)?.toInt() ?? 0).clamp(
          0,
          pts.length - 1,
        );
        if (idx == 0 || idx >= pts.length - 1) continue;
        final turn = switch (type) {
          9 || 16 => 'slight ${type == 9 ? 'right' : 'left'}',
          10 => 'right',
          11 => 'sharp right',
          14 => 'sharp left',
          15 => 'left',
          12 || 13 => 'around',
          18 || 20 || 23 => 'slight right',
          19 || 21 || 24 => 'slight left',
          _ => '',
        };
        if (turn.isEmpty) continue;
        r.junctions.add(RouteJunction(idx, r.cum[idx], turn, _street(m)));
      }
      return r;
    } on OnlineRouteException {
      rethrow;
    } catch (e) {
      throw OnlineRouteException(
        OnlineFail.failed,
        'Could not read the walking route ($e).',
      );
    }
  }

  /// A driving answer as a [DriveRoute] (online).
  static DriveRoute parseDrive(
    String body, {
    required GeoPoint from,
    required GeoPoint to,
    String name = '',
    bool imperial = true,
  }) {
    final t = _trip(body);
    try {
      final leg = (t['legs'] as List).first as Map;
      var pts = OnlineRouter.decodePolyline(leg['shape'] as String);
      if (pts.isEmpty) {
        throw OnlineRouteException(OnlineFail.failed, 'Empty route.');
      }
      if (pts.length == 1) pts = [pts.first, pts.first];
      final cum = <double>[0];
      for (var i = 1; i < pts.length; i++) {
        cum.add(cum.last + distanceM(pts[i - 1], pts[i]));
      }
      final so = distanceM(from, pts.first), eo = distanceM(to, pts.last);
      if (so > OnlineRouter.maxSnapM || eo > OnlineRouter.maxSnapM) {
        throw OnlineRouteException(
          OnlineFail.noRoute,
          'No road near the start or the destination.',
        );
      }
      final ms = [for (final m in leg['maneuvers'] as List) m as Map];
      final time = List<double>.filled(pts.length, 0);
      final segRoad = List<String>.filled(pts.length - 1, '');
      final steps = <DriveStep>[];
      var tAcc = 0.0;
      for (var k = 0; k < ms.length; k++) {
        final m = ms[k];
        final b = ((m['begin_shape_index'] as num?)?.toInt() ?? 0).clamp(
          0,
          pts.length - 1,
        );
        final e = k + 1 < ms.length
            ? ((ms[k + 1]['begin_shape_index'] as num?)?.toInt() ??
                      pts.length - 1)
                  .clamp(b, pts.length - 1)
            : pts.length - 1;
        final mt = (m['time'] as num?)?.toDouble() ?? 0;
        final span = max(1e-6, cum[e] - cum[b]);
        for (var i = b; i <= e; i++) {
          time[i] = tAcc + mt * (cum[i] - cum[b]) / span;
        }
        for (var i = b; i < e && i < segRoad.length; i++) {
          segRoad[i] = _street(m);
        }
        tAcc += mt;
        final type = (m['type'] as num?)?.toInt() ?? 0;
        final mv = _maneuver(type);
        final inst = _clean('${m['instruction'] ?? ''}');
        final verbal = _clean(
          '${m['verbal_pre_transition_instruction'] ?? inst}',
        );
        if (mv == Maneuver.arrive) {
          final tn = name.isEmpty ? 'your destination' : name;
          steps.add(
            DriveStep(
              alongM: cum[b],
              maneuver: Maneuver.arrive,
              text:
                  'Arrive at $tn${eo > 40 ? ' (${formatDistance(eo, imperial: imperial)} from the road)' : ''}',
              spoken: 'you have arrived at $tn',
              pos: pts[b],
            ),
          );
          continue;
        }
        if (mv == null) continue;
        steps.add(
          DriveStep(
            alongM: cum[b],
            maneuver: mv,
            text: inst,
            spoken: verbal.isEmpty
                ? inst.toLowerCase()
                : verbal[0].toLowerCase() + verbal.substring(1),
            pos: pts[b],
            road: _street(m),
            exit: (m['roundabout_exit_count'] as num?)?.toInt() ?? 0,
          ),
        );
      }
      final total = (t['summary'] as Map?)?['time'] as num?;
      if (total != null && time.last > 0) {
        final k = total.toDouble() / time.last;
        for (var i = 0; i < time.length; i++) {
          time[i] *= k;
        }
      }
      if (steps.isEmpty || steps.first.maneuver != Maneuver.depart) {
        steps.insert(
          0,
          DriveStep(
            alongM: 0,
            maneuver: Maneuver.depart,
            text: 'Head ${cardinal(bearingDeg(pts.first, pts[1]))}',
            spoken: 'head ${cardinalWord(bearingDeg(pts.first, pts[1]))}',
            pos: pts.first,
          ),
        );
      }
      if (steps.last.maneuver != Maneuver.arrive) {
        final tn = name.isEmpty ? 'your destination' : name;
        steps.add(
          DriveStep(
            alongM: cum.last,
            maneuver: Maneuver.arrive,
            text: 'Arrive at $tn',
            spoken: 'you have arrived at $tn',
            pos: pts.last,
          ),
        );
      }
      return DriveRoute(
        points: pts,
        cum: cum,
        timeCum: time,
        segRough: Uint8List(pts.length - 1),
        segRoad: segRoad,
        steps: steps,
        warnings: const [],
        startOffM: so,
        endOffM: eo,
        source: DriveRoute.online,
      );
    } on OnlineRouteException {
      rethrow;
    } catch (e) {
      throw OnlineRouteException(
        OnlineFail.failed,
        'Could not read the online route ($e).',
      );
    }
  }

  /// Valhalla maneuver type -> our turn kind (null = not worth a step).
  static Maneuver? _maneuver(int type) => switch (type) {
    1 || 2 || 3 => Maneuver.depart,
    4 || 5 || 6 => Maneuver.arrive,
    9 => Maneuver.slightRight,
    10 => Maneuver.right,
    11 => Maneuver.sharpRight,
    12 || 13 => Maneuver.uturn,
    14 => Maneuver.sharpLeft,
    15 => Maneuver.left,
    16 => Maneuver.slightLeft,
    17 => Maneuver.ramp,
    18 || 20 => Maneuver.rampRight,
    19 || 21 => Maneuver.rampLeft,
    22 => Maneuver.straight,
    23 => Maneuver.keepRight,
    24 => Maneuver.keepLeft,
    25 => Maneuver.merge,
    26 => Maneuver.roundabout,
    _ => null,
  };
}
