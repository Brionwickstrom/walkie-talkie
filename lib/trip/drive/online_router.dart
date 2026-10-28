import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../geo.dart';
import '../search/fetch.dart';
import '../search/rate_limiter.dart';
import 'road_data.dart' show RoadRules;
import 'road_router.dart';
import '../nav/valhalla.dart';

/// Why an online route was not made.
enum OnlineFail {
  /// No signal / no answer in time.
  noSignal,

  /// The server answered with an error, or nonsense.
  failed,

  /// The start or the destination is not near any road the server knows,
  /// or there is no road route between them.
  noRoute,
}

class OnlineRouteException implements Exception {
  OnlineRouteException(this.kind, this.message);
  final OnlineFail kind;
  final String message;
  @override
  String toString() => message;
}

/// Driving directions from a free public OSRM server while there is
/// signal (v1.9.3). The servers are run by FOSSGIS for OpenStreetMap:
/// at most one request a second, a real User-Agent (set by the app's
/// [Fetch]), attribution and a "fix the map" link shown with the route.
/// No live traffic: times are from road speeds only.
class OnlineRouter {
  OnlineRouter({
    required this.fetch,
    RateLimiter? limiter,
    this.endpoints = defaultEndpoints,
    this.timeout = const Duration(seconds: 7),
    this.valhallaAuto = false,
    DateTime Function()? clock,
  }) : limiter = limiter ?? RateLimiter(const Duration(milliseconds: 1100)),
       _clock = clock ?? DateTime.now;

  final Fetch fetch;
  final RateLimiter limiter;

  /// OSRM servers (car profile), tried in order while time is left.
  final List<String> endpoints;
  static const defaultEndpoints = [
    'https://routing.openstreetmap.de/routed-car',
    'https://router.project-osrm.org',
  ];

  /// The whole wait, all servers together.
  final Duration timeout;

  /// v2.1.0: when the OSRM servers answer with an error, ask Valhalla
  /// (valhalla1.openstreetmap.de, car) as a second opinion.
  final bool valhallaAuto;
  final DateTime Function() _clock;

  /// Farther than this from a road the server knows: not covered.
  static const maxSnapM = 3000.0;

  static const attribution =
      'Online route: OSRM on the FOSSGIS server (routing.openstreetmap.de). '
      'Roads © OpenStreetMap contributors. Something wrong? Fix the map: '
      'openstreetmap.org/fixthemap';

  static Uri routeUri(
    String base,
    GeoPoint from,
    GeoPoint to, {
    double? course,
  }) {
    String c(GeoPoint p) =>
        '${p.lng.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}';
    final q = <String, String>{
      'overview': 'full',
      'geometries': 'polyline6',
      'steps': 'true',
      'annotations': 'duration',
      'generate_hints': 'false',
      if (course != null) 'bearings': '${normDeg(course).round() % 360},60;',
    };
    return Uri.parse('$base/route/v1/driving/${c(from)};${c(to)}')
        .replace(queryParameters: q);
  }

  /// A route from [from] to [to]; throws [OnlineRouteException].
  /// [course]: direction of travel now (a re-route keeps going forward).
  Future<DriveRoute> route(
    GeoPoint from,
    GeoPoint to, {
    String name = '',
    bool imperial = true,
    double? course,
    Duration? timeout,
  }) async {
    final budget = timeout ?? this.timeout;
    final start = _clock();
    Duration left() => budget - _clock().difference(start);
    OnlineRouteException? last;
    for (final base in endpoints) {
      final t = left();
      if (t <= const Duration(milliseconds: 500)) break;
      String body;
      try {
        body = await limiter
            .run(
              () => fetch(
                FetchRequest(
                  routeUri(base, from, to, course: course),
                  headers: const {'Accept': 'application/json'},
                  timeout: t,
                  maxBytes: 6 * 1024 * 1024,
                ),
              ),
            )
            .timeout(t);
      } on TimeoutException {
        throw OnlineRouteException(
          OnlineFail.noSignal,
          'No answer from the online router (weak signal?).',
        );
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
        return parse(body, name: name, imperial: imperial);
      } on OnlineRouteException catch (e) {
        if (e.kind == OnlineFail.noRoute) rethrow;
        last = e;
      }
    }
    if (valhallaAuto && last != null && left() > const Duration(seconds: 1)) {
      final t = left();
      try {
        final body = await limiter
            .run(
              () => fetch(
                FetchRequest(
                  Uri.parse(Valhalla.endpoint),
                  method: 'POST',
                  headers: const {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                  },
                  body: Valhalla.autoBody(from, to),
                  timeout: t,
                  maxBytes: 6 * 1024 * 1024,
                ),
              ),
            )
            .timeout(t);
        return Valhalla.parseDrive(
          body,
          from: from,
          to: to,
          name: name,
          imperial: imperial,
        );
      } on TimeoutException {
        throw OnlineRouteException(
          OnlineFail.noSignal,
          'No answer from the online router (weak signal?).',
        );
      } on NoSignalException {
        throw OnlineRouteException(OnlineFail.noSignal, 'No signal.');
      } on OnlineRouteException catch (e) {
        if (e.kind == OnlineFail.noRoute) rethrow;
        last = e;
      } catch (e) {
        last = OnlineRouteException(OnlineFail.failed, '$e');
      }
    }
    throw last ??
        OnlineRouteException(
          OnlineFail.noSignal,
          'No answer from the online router (weak signal?).',
        );
  }

  /// Google's encoded polyline with 6 digits (OSRM `polyline6`).
  static List<GeoPoint> decodePolyline(String s, {int precision = 6}) {
    final out = <GeoPoint>[];
    final f = pow(10, precision).toDouble();
    var i = 0, lat = 0, lng = 0;
    int next() {
      var result = 0, shift = 0, b = 0;
      do {
        b = s.codeUnitAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && i < s.length);
      return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
    }

    while (i < s.length) {
      lat += next();
      if (i >= s.length) break;
      lng += next();
      out.add(GeoPoint(lat / f, lng / f));
    }
    return out;
  }

  /// Turn an OSRM answer into a [DriveRoute] (source: online).
  static DriveRoute parse(
    String body, {
    String name = '',
    bool imperial = true,
  }) {
    Map j;
    try {
      j = jsonDecode(body) as Map;
    } catch (_) {
      throw OnlineRouteException(OnlineFail.failed, 'Bad answer from router.');
    }
    final code = j['code'];
    if (code == 'NoRoute' || code == 'NoSegment') {
      throw OnlineRouteException(
        OnlineFail.noRoute,
        'The online router found no road route there.',
      );
    }
    if (code != 'Ok') {
      throw OnlineRouteException(
        OnlineFail.failed,
        'Online router: ${j['message'] ?? code}',
      );
    }
    try {
      final wps = j['waypoints'] as List;
      final so = ((wps.first as Map)['distance'] as num?)?.toDouble() ?? 0;
      final eo = ((wps.last as Map)['distance'] as num?)?.toDouble() ?? 0;
      if (so > maxSnapM || eo > maxSnapM) {
        throw OnlineRouteException(
          OnlineFail.noRoute,
          so > maxSnapM
              ? 'You are far from any road the online router knows.'
              : 'The destination is far from any road the online router knows.',
        );
      }
      final r = (j['routes'] as List).first as Map;
      var pts = decodePolyline(r['geometry'] as String);
      final leg = (r['legs'] as List).first as Map;
      final durs = ((leg['annotation'] as Map?)?['duration'] as List?)
          ?.map((d) => (d as num).toDouble())
          .toList();
      if (pts.isEmpty) {
        throw OnlineRouteException(OnlineFail.failed, 'Empty route.');
      }
      if (pts.length == 1) pts = [pts.first, pts.first];
      final cum = <double>[0];
      for (var i = 1; i < pts.length; i++) {
        cum.add(cum.last + distanceM(pts[i - 1], pts[i]));
      }
      final total = (r['duration'] as num?)?.toDouble() ?? 0;
      final time = <double>[0];
      final useAnn = durs != null && durs.length == pts.length - 1;
      for (var i = 1; i < pts.length; i++) {
        final dt = useAnn
            ? durs[i - 1]
            : (cum.last <= 0 ? 0.0 : total * (cum[i] - cum[i - 1]) / cum.last);
        time.add(time.last + dt);
      }
      final dist = (r['distance'] as num?)?.toDouble() ?? cum.last;
      final k = dist <= 0 ? 1.0 : cum.last / dist;
      final raw = [for (final s in leg['steps'] as List) s as Map];
      // Where each step starts along our line.
      final starts = <double>[];
      var acc = 0.0;
      for (final s in raw) {
        starts.add(min(cum.last, acc * k));
        acc += (s['distance'] as num?)?.toDouble() ?? 0;
      }
      final steps = <DriveStep>[];
      final stepRoad = <String>[];
      for (var i = 0; i < raw.length; i++) {
        final st = _step(
          raw[i],
          starts[i],
          i == raw.length - 1,
          name,
          eo,
          imperial,
        );
        stepRoad.add(_label(raw[i]));
        if (st != null) steps.add(st);
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
        steps.add(_arrive(cum.last, pts.last, name, eo, imperial));
      }
      final segRoad = <String>[];
      var si = 0;
      for (var i = 0; i + 1 < pts.length; i++) {
        final mid = (cum[i] + cum[i + 1]) / 2;
        while (si + 1 < starts.length && starts[si + 1] <= mid) {
          si++;
        }
        segRoad.add(stepRoad.isEmpty ? '' : stepRoad[si]);
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

  /// Road name the way the offline roads write it ("Silverstar Road
  /// (FR 4109)", "I-5").
  static String _label(Map s) {
    final name = ((s['name'] as String?) ?? '').trim();
    final ref = ((s['ref'] as String?) ?? '').split(';').first.trim();
    return RoadRules.nameOf(
      {if (name.isNotEmpty) 'name': name, if (ref.isNotEmpty) 'ref': ref},
      2,
      false,
    );
  }

  static String _toward(Map s) {
    final d = ((s['destinations'] as String?) ?? '').trim();
    if (d.isEmpty) return '';
    // "I 5: Seattle, Portland" -> "I-5 (Seattle, Portland)".
    final parts = d.split(':');
    if (parts.length == 2) {
      final refs = parts[0]
          .split(',')
          .map((r) => RoadRules.normRef(r.trim()))
          .join(' / ');
      return '$refs (${parts[1].trim()})';
    }
    return d.split(',').map((r) => RoadRules.normRef(r.trim())).join(', ');
  }

  static DriveStep _arrive(
    double along,
    GeoPoint pos,
    String target,
    double endOff,
    bool imperial,
  ) {
    final tn = target.isEmpty ? 'your destination' : target;
    return DriveStep(
      alongM: along,
      maneuver: Maneuver.arrive,
      text:
          'Arrive at $tn${endOff > 40 ? ' (${formatDistance(endOff, imperial: imperial)} from the road)' : ''}',
      spoken: 'you have arrived at $tn',
      pos: pos,
    );
  }

  static String _ord(int n) => switch (n) {
    1 => '1st',
    2 => '2nd',
    3 => '3rd',
    _ => '${n}th',
  };
  static String _spokenOrd(int n) => switch (n) {
    1 => 'first',
    2 => 'second',
    3 => 'third',
    4 => 'fourth',
    5 => 'fifth',
    6 => 'sixth',
    _ => '${n}th',
  };

  static DriveStep? _step(
    Map s,
    double along,
    bool last,
    String target,
    double endOff,
    bool imperial,
  ) {
    final m = s['maneuver'] as Map;
    final type = (m['type'] as String?) ?? '';
    final mod = (m['modifier'] as String?) ?? 'straight';
    final loc = m['location'] as List;
    final pos = GeoPoint(
      (loc[1] as num).toDouble(),
      (loc[0] as num).toDouble(),
    );
    final road = _label(s);
    if (type == 'arrive' || last) {
      return _arrive(along, pos, target, endOff, imperial);
    }
    if (type == 'depart') {
      final b = (m['bearing_after'] as num?)?.toDouble() ?? 0;
      return DriveStep(
        alongM: along,
        maneuver: Maneuver.depart,
        text: 'Head ${cardinal(b)}${road.isEmpty ? '' : ' on $road'}',
        spoken: 'head ${cardinalWord(b)}${road.isEmpty ? '' : ' on $road'}',
        pos: pos,
        road: road,
      );
    }
    Maneuver turn() => switch (mod) {
      'uturn' => Maneuver.uturn,
      'sharp right' => Maneuver.sharpRight,
      'right' => Maneuver.right,
      'slight right' => Maneuver.slightRight,
      'slight left' => Maneuver.slightLeft,
      'left' => Maneuver.left,
      'sharp left' => Maneuver.sharpLeft,
      _ => Maneuver.straight,
    };
    final toward = _toward(s);
    Maneuver mv;
    var exit = 0;
    var ramp = false;
    switch (type) {
      case 'new name' || 'continue' || 'notification':
        mv = turn();
        // Just the road changing name (or going on): not a turn.
        if (mv == Maneuver.straight ||
            mv == Maneuver.slightLeft ||
            mv == Maneuver.slightRight) {
          return null;
        }
      case 'exit roundabout' || 'exit rotary':
        return null;
      case 'roundabout' || 'rotary':
        mv = Maneuver.roundabout;
        exit = max(1, (m['exit'] as num?)?.toInt() ?? 1);
      case 'fork':
        mv = mod.contains('left')
            ? Maneuver.keepLeft
            : mod.contains('right')
            ? Maneuver.keepRight
            : Maneuver.straight;
      case 'merge':
        mv = Maneuver.merge;
      case 'on ramp' || 'off ramp':
        ramp = true;
        mv = mod.contains('left')
            ? Maneuver.rampLeft
            : mod.contains('right')
            ? Maneuver.rampRight
            : Maneuver.ramp;
      default: // turn, end of road, roundabout turn
        mv = turn();
    }
    final named = road.isNotEmpty;
    final onto = ramp || (!named && toward.isNotEmpty)
        ? (toward.isNotEmpty ? ' toward $toward' : (named ? ' onto $road' : ''))
        : (named ? ' onto $road' : '');
    final exitWord = type == 'off ramp' ? 'exit' : 'ramp';
    final verb = switch (mv) {
      Maneuver.ramp => 'Take the $exitWord',
      Maneuver.rampLeft => 'Take the $exitWord on the left',
      Maneuver.rampRight => 'Take the $exitWord on the right',
      Maneuver.merge => 'Merge',
      Maneuver.keepLeft => 'Keep left',
      Maneuver.keepRight => 'Keep right',
      Maneuver.straight => named ? 'Continue' : 'Continue straight',
      Maneuver.slightLeft => 'Turn slight left',
      Maneuver.slightRight => 'Turn slight right',
      Maneuver.left => 'Turn left',
      Maneuver.right => 'Turn right',
      Maneuver.sharpLeft => 'Turn sharp left',
      Maneuver.sharpRight => 'Turn sharp right',
      Maneuver.uturn => 'Make a U-turn',
      Maneuver.roundabout => 'At the roundabout, take the ${_ord(exit)} exit',
      _ => 'Continue',
    };
    final text = '$verb$onto';
    final spoken = mv == Maneuver.roundabout
        ? 'at the roundabout, take the ${_spokenOrd(exit)} exit$onto'
        : text[0].toLowerCase() + text.substring(1);
    return DriveStep(
      alongM: along,
      maneuver: mv,
      text: text,
      spoken: spoken,
      pos: pos,
      road: road,
      exit: exit,
    );
  }
}
