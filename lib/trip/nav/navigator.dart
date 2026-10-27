import 'dart:math';

import '../geo.dart';
import 'trail_graph.dart';

/// Where you are on a route right now.
class NavState {
  NavState({
    required this.alongM,
    required this.leftM,
    required this.offM,
    required this.offRoute,
    required this.bearingToRoute,
    required this.bearingAhead,
    required this.eta,
    required this.gainLeftM,
    required this.lossLeftM,
    required this.arrived,
    this.next,
    this.nextInM,
  });

  /// Distance done along the route and left to the target.
  final double alongM, leftM;

  /// Distance from the route; [offRoute] once past the limit.
  final double offM;
  final bool offRoute;

  /// Bearing back to the nearest point of the route (when off route) and
  /// along the route ~30 m ahead (the way to go).
  final double bearingToRoute, bearingAhead;
  final Duration eta;
  final double gainLeftM, lossLeftM;
  final RouteJunction? next;
  final double? nextInM;
  final bool arrived;
}

/// Follows GPS fixes along a [TrailRoute]: progress, next junction,
/// off-route detection (more than [offRouteM] away, twice in a row), ETA.
class RouteFollower {
  RouteFollower(this.route, {this.offRouteM = 40, this.arriveM = 25});

  TrailRoute route;
  final double offRouteM, arriveM;
  int _seg = 0;
  int _offCount = 0;
  bool _off = false;

  /// Times we went off route (the app vibrates on each new one).
  int offEvents = 0;
  NavState? last;

  /// Closest point on segment [i] to [p]: (fraction, metres).
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

  NavState update(GeoPoint me) {
    final pts = route.points;
    if (pts.length < 2) {
      return last = NavState(
        alongM: 0,
        leftM: 0,
        offM: 0,
        offRoute: false,
        bearingToRoute: 0,
        bearingAhead: 0,
        eta: Duration.zero,
        gainLeftM: 0,
        lossLeftM: 0,
        arrived: true,
      );
    }
    // Search near the last position first (routes can double back), then
    // everywhere if that is far.
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

    var lo = _seg, hi = _seg;
    while (lo > 0 && route.cum[_seg] - route.cum[lo] < 100) {
      lo--;
    }
    while (hi < pts.length - 1 && route.cum[hi] - route.cum[_seg] < 600) {
      hi++;
    }
    var (i, t, d) = bestIn(lo, hi + 1);
    if (d > offRouteM) {
      final all = bestIn(0, pts.length);
      if (all.$3 < d - 5) (i, t, d) = all;
    }
    _seg = i;
    final segLen = route.cum[i + 1] - route.cum[i];
    final along = route.cum[i] + segLen * t;
    final here = _lerp(pts[i], pts[i + 1], t);
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
    RouteJunction? next;
    for (final j in route.junctions) {
      if (j.alongM > along + 5) {
        next = j;
        break;
      }
    }
    final c = route.climb(fromM: along);
    final ahead = _pointAt(along + 30);
    final arrived =
        distanceM(me, pts.last) <= arriveM || (left <= arriveM && !_off);
    return last = NavState(
      alongM: along,
      leftM: left,
      offM: d,
      offRoute: _off,
      bearingToRoute: bearingDeg(me, here),
      bearingAhead: bearingDeg(d > 15 ? me : here, ahead),
      eta: naismith(left, c.gain),
      gainLeftM: c.gain,
      lossLeftM: c.loss,
      next: next,
      nextInM: next == null ? null : next.alongM - along,
      arrived: arrived,
    );
  }

  GeoPoint _pointAt(double m) {
    final c = route.cum;
    if (m >= c.last) return route.points.last;
    var i = 0;
    while (i < c.length - 2 && c[i + 1] < m) {
      i++;
    }
    final seg = c[i + 1] - c[i];
    return _lerp(
      route.points[i],
      route.points[i + 1],
      seg == 0 ? 0 : (m - c[i]) / seg,
    );
  }

  static GeoPoint _lerp(GeoPoint a, GeoPoint b, double t) =>
      GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);

  /// After a re-route.
  void replace(TrailRoute r) {
    route = r;
    _seg = 0;
    _offCount = 0;
    _off = false;
  }
}
