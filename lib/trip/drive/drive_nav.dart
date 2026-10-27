import 'dart:math';

import '../geo.dart';
import 'road_router.dart';

/// Where you are on a driving route.
class DriveState {
  const DriveState({
    required this.alongM,
    required this.leftM,
    required this.timeLeft,
    required this.offM,
    required this.offRoute,
    required this.bearingToRoute,
    required this.bearingAhead,
    required this.nextStep,
    required this.nextInM,
    required this.arrived,
    required this.road,
  });
  final double alongM, leftM;
  final Duration timeLeft;
  final double offM;
  final bool offRoute;
  final double bearingToRoute, bearingAhead;

  /// Index into the route's steps of the next turn (the last = arrive).
  final int nextStep;
  final double nextInM;
  final bool arrived;

  /// Road you are on.
  final String road;
}

/// Follows GPS fixes along a [DriveRoute].
class DriveFollower {
  DriveFollower(this.route, {this.offRouteM = 50, this.arriveM = 30});

  DriveRoute route;
  final double offRouteM, arriveM;
  int _seg = 0;
  int _offCount = 0;
  bool _off = false;
  int offEvents = 0;
  DriveState? last;

  (double, double) _onSeg(int i, GeoPoint p) {
    final a = route.points[i], b = route.points[i + 1];
    final kx = 111319.49 * cos(p.lat * pi / 180);
    const ky = 111132.954;
    final ax = (a.lng - p.lng) * kx, ay = (a.lat - p.lat) * ky;
    final bx = (b.lng - p.lng) * kx, by = (b.lat - p.lat) * ky;
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : -(ax * dx + ay * dy) / l2;
    t = t.clamp(0.0, 1.0);
    final x = ax + t * dx, y = ay + t * dy;
    return (t, sqrt(x * x + y * y));
  }

  GeoPoint pointAt(double m) {
    final c = route.cum;
    if (m <= 0) return route.points.first;
    if (m >= c.last) return route.points.last;
    var lo = 0, hi = c.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (c[mid] <= m) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = c[hi] - c[lo];
    final t = seg <= 0 ? 0.0 : (m - c[lo]) / seg;
    final a = route.points[lo], b = route.points[hi];
    return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
  }

  DriveState update(GeoPoint me) {
    final pts = route.points;
    (int, double, double) bestIn(int from, int to) {
      var bi = from, bt = 0.0, bd = double.infinity;
      for (var i = max(0, from); i < min(pts.length - 1, to); i++) {
        final (t, d) = _onSeg(i, me);
        if (d < bd - 0.01) {
          bi = i;
          bt = t;
          bd = d;
        }
      }
      return (bi, bt, bd);
    }

    // Near the last spot first (forward ~3 km), then anywhere.
    var lo = _seg, hi = _seg;
    while (lo > 0 && route.cum[_seg] - route.cum[lo] < 200) {
      lo--;
    }
    while (hi < pts.length - 1 && route.cum[hi] - route.cum[_seg] < 3000) {
      hi++;
    }
    var (i, t, d) = bestIn(lo, hi + 1);
    if (d > offRouteM) {
      final all = bestIn(0, pts.length);
      if (all.$3 < d - 5) (i, t, d) = all;
    }
    _seg = i;
    final seg = route.cum[i + 1] - route.cum[i];
    final along = route.cum[i] + seg * t;
    final here = pointAt(along);
    final left = max(0.0, route.lengthM - along);
    if (d > offRouteM) {
      _offCount++;
    } else {
      _offCount = 0;
      _off = false;
    }
    if (_offCount >= 2 && !_off) {
      _off = true;
      offEvents++;
    }
    var next = route.steps.length - 1;
    for (var k = 1; k < route.steps.length; k++) {
      if (route.steps[k].alongM > along + 3) {
        next = k;
        break;
      }
    }
    final timeLeft = route.timeCum.last - route.timeAt(along);
    final arrived =
        distanceM(me, pts.last) <= arriveM || (left <= arriveM && !_off);
    return last = DriveState(
      alongM: along,
      leftM: left,
      timeLeft: Duration(seconds: max(0, timeLeft.round())),
      offM: d,
      offRoute: _off,
      bearingToRoute: bearingDeg(me, here),
      bearingAhead: bearingDeg(here, pointAt(along + 40)),
      nextStep: next,
      nextInM: max(0, route.steps[next].alongM - along),
      arrived: arrived,
      road: i < route.segRoad.length ? route.segRoad[i] : '',
    );
  }

  void replace(DriveRoute r) {
    route = r;
    _seg = 0;
    _offCount = 0;
    _off = false;
  }
}

/// "500 feet", "half a mile", "2 miles", "300 meters", "1.5 kilometers".
String spokenDistance(double m, {required bool imperial}) {
  if (imperial) {
    final ft = m * 3.28084;
    if (ft < 1000) {
      final r = ft < 300 ? (ft / 50).round() * 50 : (ft / 100).round() * 100;
      return '${max(50, r)} feet';
    }
    final mi = m / 1609.344;
    if (mi < 0.375) return 'a quarter mile';
    if (mi < 0.625) return 'half a mile';
    if (mi < 0.875) return 'three quarters of a mile';
    final h = (mi * 2).round() / 2;
    final s = h == h.roundToDouble() ? '${h.round()}' : h.toStringAsFixed(1);
    return h == 1 ? '1 mile' : '$s miles';
  }
  if (m < 1000) {
    final r = m < 200 ? (m / 10).round() * 10 : (m / 50).round() * 50;
    return '${max(10, r)} meters';
  }
  final km = (m / 100).round() / 10;
  final s = km >= 10 ? '${km.round()}' : km.toStringAsFixed(1);
  return km == 1 ? '1 kilometer' : '$s kilometers';
}

/// When to say what while driving: an early "In 1 mile, turn left onto
/// X", then "Turn left onto X" just before (with "then ..." when the next
/// turn comes right after), and "You have arrived".
class VoicePrompter {
  VoicePrompter({required this.imperial});
  bool imperial;
  final Map<int, int> _said = {};
  bool _started = false, _arrived = false;

  /// Something to say now, or null.
  String? next(DriveRoute r, DriveState s, {double speedMps = 0}) {
    if (s.arrived) {
      if (_arrived) return null;
      _arrived = true;
      return _cap(r.steps.last.spoken);
    }
    final i = s.nextStep;
    if (i <= 0 || i >= r.steps.length) return null;
    final step = r.steps[i];
    final d = s.nextInM;
    final v = max(speedMps, 5.0);
    final far = v > 22 ? 2000.0 : (v > 13 ? 1000.0 : 400.0);
    final near = max(60.0, v * 8);
    final level = _said[i] ?? 0;
    String withThen(String t) {
      if (i + 1 < r.steps.length &&
          r.steps[i + 1].alongM - step.alongM < max(150.0, v * 10)) {
        return '$t, then ${r.steps[i + 1].spoken}';
      }
      return t;
    }

    if (!_started) {
      _started = true;
      final head = r.steps.first.spoken;
      _said[i] = d <= near ? 2 : (d <= far ? 1 : 0);
      if (d <= near) return _cap('$head, then ${step.spoken}');
      if (d <= far) {
        return _cap(
          '$head. In ${spokenDistance(d, imperial: imperial)}, ${step.spoken}',
        );
      }
      return _cap(head);
    }
    if (s.offRoute) return null;
    if (d <= near && level < 2) {
      _said[i] = 2;
      return _cap(withThen(step.spoken));
    }
    final gap = step.alongM - r.steps[i - 1].alongM;
    if (d <= far && d > near * 1.5 && level < 1 && gap > far * 0.6) {
      _said[i] = 1;
      return _cap(
        'In ${spokenDistance(d, imperial: imperial)}, ${step.spoken}',
      );
    }
    return null;
  }

  /// After a re-route: start counting again.
  void reset() {
    _said.clear();
    _started = true;
    _arrived = false;
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}.';
}
