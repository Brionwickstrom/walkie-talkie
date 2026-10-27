import 'dart:math';
import 'dart:typed_data';

import '../geo.dart';
import 'road_data.dart';

/// A spot on a road: edge [edge], [along] metres from its a end.
class RoadSnap {
  const RoadSnap(this.edge, this.along, this.pos, this.distM);
  final int edge;
  final double along;
  final GeoPoint pos;

  /// From the asked point to the road.
  final double distM;
}

/// Turn kinds (for the arrow and the words).
enum Maneuver {
  depart,
  straight,
  slightLeft,
  left,
  sharpLeft,
  slightRight,
  right,
  sharpRight,
  uturn,
  keepLeft,
  keepRight,
  rampLeft,
  rampRight,
  ramp,
  merge,
  roundabout,
  arrive,
}

/// One turn-by-turn step.
class DriveStep {
  const DriveStep({
    required this.alongM,
    required this.maneuver,
    required this.text,
    required this.spoken,
    required this.pos,
    this.road = '',
    this.exit = 0,
  });

  /// Where it happens, metres from the start of the route.
  final double alongM;
  final Maneuver maneuver;

  /// "Turn left onto Silverstar Road (FR 4109)".
  final String text;

  /// Words for the voice ("turn left onto Silverstar Road").
  final String spoken;
  final GeoPoint pos;

  /// Road taken after the step.
  final String road;

  /// Roundabout exit number.
  final int exit;
}

/// A rough / closed / special stretch of the route.
class RoadWarning {
  const RoadWarning(this.kind, this.road, this.lengthM, this.alongM, this.text);

  /// rough / clearance / unpaved / closed / seasonal / gate / ford /
  /// destination
  final String kind;
  final String road;
  final double lengthM, alongM;
  final String text;
}

/// A driving route.
class DriveRoute {
  DriveRoute({
    required this.points,
    required this.cum,
    required this.timeCum,
    required this.segRough,
    required this.segRoad,
    required this.steps,
    required this.warnings,
    required this.startOffM,
    required this.endOffM,
  });

  final List<GeoPoint> points;

  /// Metres from the start at each point.
  final List<double> cum;

  /// Seconds from the start at each point.
  final List<double> timeCum;

  /// Roughness 0..3 of each segment (points[i] -> points[i+1]).
  final Uint8List segRough;

  /// Road name of each segment.
  final List<String> segRoad;
  final List<DriveStep> steps;
  final List<RoadWarning> warnings;

  /// Straight distance from the start / to the target to the road.
  final double startOffM, endOffM;

  double get lengthM => cum.isEmpty ? 0 : cum.last;
  Duration get duration =>
      Duration(seconds: timeCum.isEmpty ? 0 : timeCum.last.round());

  /// Worst roughness on the route.
  int get worstRough => segRough.fold(0, max);

  /// Seconds from the start at [m] metres.
  double timeAt(double m) {
    if (cum.length < 2) return 0;
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= m) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = cum[hi] - cum[lo];
    final t = seg <= 0 ? 0.0 : ((m - cum[lo]) / seg).clamp(0.0, 1.0);
    return timeCum[lo] + (timeCum[hi] - timeCum[lo]) * t;
  }
}

/// Routing over [RoadData] (A* on travel time, car profile).
class RoadGraph {
  RoadGraph(this.d) {
    final n = d.nodeCount;
    final deg = Int32List(n + 1);
    for (var e = 0; e < d.edgeCount; e++) {
      deg[d.edgeA[e]]++;
      deg[d.edgeB[e]]++;
    }
    _adjStart = Int32List(n + 1);
    for (var i = 0; i < n; i++) {
      _adjStart[i + 1] = _adjStart[i] + deg[i];
    }
    _adj = Int32List(_adjStart[n]);
    final fill = Int32List.fromList(_adjStart.sublist(0, n));
    for (var e = 0; e < d.edgeCount; e++) {
      // Encoded edge*2 + (1 = leaving from b).
      _adj[fill[d.edgeA[e]]++] = e * 2;
      _adj[fill[d.edgeB[e]]++] = e * 2 + 1;
    }
  }

  final RoadData d;
  late final Int32List _adjStart, _adj;

  bool get isEmpty => d.edgeCount == 0;

  int degree(int n) => _adjStart[n + 1] - _adjStart[n];

  bool canForward(int e) => d.edgeFlags[e] & EdgeFlag.onewayBack == 0;
  bool canBackward(int e) => d.edgeFlags[e] & EdgeFlag.oneway == 0;

  // ------------------------------------------------------------ snapping

  static const _cell = 0.01; // degrees
  Map<int, List<int>>? _grid;

  int _key(int cx, int cy) => cx * 100000 + cy;

  Map<int, List<int>> get _cells {
    final g = _grid;
    if (g != null) return g;
    final out = <int, List<int>>{};
    for (var e = 0; e < d.edgeCount; e++) {
      final pts = d.edgePoints(e);
      final seen = <int>{};
      for (var i = 0; i + 1 < pts.length; i++) {
        final a = pts[i], b = pts[i + 1];
        final x0 = (min(a.lng, b.lng) / _cell).floor() + 20000;
        final x1 = (max(a.lng, b.lng) / _cell).floor() + 20000;
        final y0 = (min(a.lat, b.lat) / _cell).floor() + 10000;
        final y1 = (max(a.lat, b.lat) / _cell).floor() + 10000;
        for (var x = x0; x <= x1; x++) {
          for (var y = y0; y <= y1; y++) {
            final k = _key(x, y);
            if (seen.add(k)) (out[k] ??= []).add(e);
          }
        }
      }
    }
    return _grid = out;
  }

  /// Closest point of a road to [p] within [maxM].
  RoadSnap? snap(GeoPoint p, {double maxM = 3000}) {
    final cells = _cells;
    final cx = (p.lng / _cell).floor() + 20000;
    final cy = (p.lat / _cell).floor() + 10000;
    final kx = 111319.49 * cos(p.lat * pi / 180);
    const ky = 111132.954;
    final cellM = _cell * min(kx, ky);
    RoadSnap? best;
    final maxRing = (maxM / cellM).ceil() + 1;
    for (var r = 0; r <= maxRing; r++) {
      if (best != null && (r - 1) * cellM > best.distM) break;
      for (var x = cx - r; x <= cx + r; x++) {
        for (var y = cy - r; y <= cy + r; y++) {
          if (max((x - cx).abs(), (y - cy).abs()) != r) continue;
          final list = cells[_key(x, y)];
          if (list == null) continue;
          for (final e in list) {
            final pts = d.edgePoints(e);
            var along = 0.0;
            for (var i = 0; i + 1 < pts.length; i++) {
              final a = pts[i], b = pts[i + 1];
              final ax = (a.lng - p.lng) * kx, ay = (a.lat - p.lat) * ky;
              final bx = (b.lng - p.lng) * kx, by = (b.lat - p.lat) * ky;
              final dx = bx - ax, dy = by - ay;
              final l2 = dx * dx + dy * dy;
              var t = l2 == 0 ? 0.0 : -(ax * dx + ay * dy) / l2;
              t = t.clamp(0.0, 1.0);
              final x0 = ax + t * dx, y0 = ay + t * dy;
              final dist = sqrt(x0 * x0 + y0 * y0);
              final segLen = sqrt(l2);
              if (dist <= maxM && (best == null || dist < best.distM)) {
                best = RoadSnap(
                  e,
                  along + segLen * t,
                  GeoPoint(
                    a.lat + (b.lat - a.lat) * t,
                    a.lng + (b.lng - a.lng) * t,
                  ),
                  dist,
                );
              }
              along += segLen;
            }
          }
        }
      }
    }
    if (best == null) return null;
    // Shape lengths are flat-earth; scale to the stored length.
    final flat = _flatLen(best.edge);
    final k = flat <= 0 ? 1.0 : d.edgeLen[best.edge] / flat;
    return RoadSnap(best.edge, best.along * k, best.pos, best.distM);
  }

  double _flatLen(int e) {
    final pts = d.edgePoints(e);
    var s = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      s += distanceM(pts[i], pts[i + 1]);
    }
    return s;
  }

  // ------------------------------------------------------------ cost

  /// Seconds to drive all of edge [e] ([doy] = day of year, for closures).
  double edgeCost(int e, int doy, {bool allowDestination = false}) {
    final speed = d.edgeSpeed[e] / 3.6;
    var t = d.edgeLen[e] / speed;
    final f = d.edgeFlags[e];
    if (f & EdgeFlag.destination != 0 && !allowDestination) t = t * 3 + 120;
    final r = d.edgeRough[e];
    if (r == 3) t *= 2.5;
    if (r == 2) t *= 1.3;
    if (closedOn(doy, d.edgeClose[2 * e], d.edgeClose[2 * e + 1])) {
      t = t * 20 + 3600;
    }
    if (f & EdgeFlag.ford != 0) t += 600;
    return t + 1; // a little for each junction
  }

  // ------------------------------------------------------------ route

  /// Fastest route by car from [from] to [to] (null = no roads near, or
  /// not connected).
  ///
  /// Locked gates and barriers are not driven through, unless there is no
  /// other way (a trailhead behind a gate): then the route goes through
  /// with a warning.
  DriveRoute? route(
    GeoPoint from,
    GeoPoint to, {
    DateTime? now,
    String targetName = '',
    bool imperial = true,
  }) =>
      _route(from, to, now, targetName, imperial, false) ??
      _route(from, to, now, targetName, imperial, true);

  DriveRoute? _route(
    GeoPoint from,
    GeoPoint to,
    DateTime? now,
    String targetName,
    bool imperial,
    bool throughBlocked,
  ) {
    if (isEmpty) return null;
    final s = snap(from), t = snap(to);
    if (s == null || t == null) return null;
    final doy = dayOfYear(now ?? DateTime.now());
    final n = d.nodeCount;
    final g = Float64List(n)..fillRange(0, n, double.infinity);
    final prev = Int32List(n)..fillRange(0, n, -1); // adj code used to arrive
    final heap = _Heap();
    final tl = t.pos;
    const vmax = 110 / 3.6;
    double h(int node) => distanceM(d.nodePos(node), tl) / vmax;
    double frac(int e, double m) =>
        d.edgeLen[e] <= 0 ? 0 : (m / d.edgeLen[e]).clamp(0.0, 1.0);

    // Start on edge s.edge.
    final se = s.edge;
    final seCost = edgeCost(se, doy, allowDestination: true);
    if (canForward(se)) {
      final c = seCost * (1 - frac(se, s.along));
      final b = d.edgeB[se];
      g[b] = c;
      prev[b] = -2; // from the start edge, forward
      heap.push(c + h(b), b);
    }
    if (canBackward(se)) {
      final c = seCost * frac(se, s.along);
      final a = d.edgeA[se];
      if (c < g[a]) {
        g[a] = c;
        prev[a] = -3; // from the start edge, backward
        heap.push(c + h(a), a);
      }
    }
    // Target on edge t.edge.
    final te = t.edge;
    final teCost = edgeCost(te, doy, allowDestination: true);
    var best = double.infinity;
    var bestVia = -1; // node we enter the target edge from (-1 direct)
    if (se == te) {
      if (t.along >= s.along && canForward(se)) {
        best = seCost * frac(se, t.along - s.along);
      } else if (t.along < s.along && canBackward(se)) {
        best = seCost * frac(se, s.along - t.along);
      }
    }
    while (heap.isNotEmpty) {
      final (f, u) = heap.pop();
      if (f >= best) break;
      final gu = g[u];
      if (f - h(u) > gu + 1e-6) continue; // stale
      // A locked gate: no further (unless reached straight from the start,
      // i.e. we are already behind it).
      final blocked = d.nodeFlags[u] & NodeFlag.blocked != 0 && prev[u] >= 0;
      if (blocked && !throughBlocked) continue;
      // Reach the target from u?
      final pen = blocked ? 7200 : 0;
      if (u == d.edgeA[te] && canForward(te)) {
        final c = gu + pen + teCost * frac(te, t.along);
        if (c < best) {
          best = c;
          bestVia = u;
        }
      }
      if (u == d.edgeB[te] && canBackward(te)) {
        final c = gu + pen + teCost * (1 - frac(te, t.along));
        if (c < best) {
          best = c;
          bestVia = u;
        }
      }
      for (var k = _adjStart[u]; k < _adjStart[u + 1]; k++) {
        final code = _adj[k];
        final e = code >> 1;
        final fromB = code & 1 == 1;
        if (fromB ? !canBackward(e) : !canForward(e)) continue;
        final v = fromB ? d.edgeA[e] : d.edgeB[e];
        final c = gu + edgeCost(e, doy) + (blocked ? 7200 : 0);
        if (c < g[v]) {
          g[v] = c;
          prev[v] = code;
          heap.push(c + h(v), v);
        }
      }
    }
    if (best == double.infinity) return null;
    // Walk back: list of (edge, forward, fromAlong, toAlong).
    final legs = <(int, bool, double, double)>[];
    if (bestVia == -1) {
      legs.add((se, t.along >= s.along, s.along, t.along));
    } else {
      final fwdT =
          bestVia == d.edgeA[te] &&
          canForward(te) &&
          (bestVia != d.edgeB[te] || true);
      final onA = bestVia == d.edgeA[te];
      legs.add((te, onA && fwdT, onA ? 0 : d.edgeLen[te], t.along));
      var u = bestVia;
      var guard = 0;
      while (prev[u] >= 0 && guard++ < n) {
        final code = prev[u];
        final e = code >> 1;
        final fromB = code & 1 == 1;
        legs.add((
          e,
          !fromB,
          fromB ? d.edgeLen[e] : 0,
          fromB ? 0 : d.edgeLen[e],
        ));
        u = fromB ? d.edgeB[e] : d.edgeA[e];
      }
      final fwdS = prev[u] == -2;
      legs.add((se, fwdS, s.along, fwdS ? d.edgeLen[se] : 0));
    }
    return _assemble(
      legs.reversed.toList(),
      s,
      t,
      from,
      to,
      doy,
      targetName,
      imperial,
    );
  }

  /// Points of edge [e] between [m0] and [m1] metres from its a end
  /// (reversed when m1 < m0).
  List<GeoPoint> _piece(int e, double m0, double m1) {
    final pts = d.edgePoints(e);
    final len = d.edgeLen[e];
    final flat = <double>[0];
    for (var i = 0; i + 1 < pts.length; i++) {
      flat.add(flat.last + distanceM(pts[i], pts[i + 1]));
    }
    final k = flat.last <= 0 ? 1.0 : len / flat.last;
    GeoPoint at(double m) {
      final f = m / k;
      var i = 0;
      while (i < flat.length - 2 && flat[i + 1] < f) {
        i++;
      }
      final seg = flat[i + 1] - flat[i];
      final t = seg <= 0 ? 0.0 : ((f - flat[i]) / seg).clamp(0.0, 1.0);
      final a = pts[i], b = pts[i + 1];
      return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
    }

    final lo = min(m0, m1), hi = max(m0, m1);
    final out = <GeoPoint>[at(lo)];
    for (var i = 1; i < pts.length - 1; i++) {
      final m = flat[i] * k;
      if (m > lo && m < hi) out.add(pts[i]);
    }
    out.add(at(hi));
    return m1 < m0 ? out.reversed.toList() : out;
  }

  DriveRoute _assemble(
    List<(int, bool, double, double)> legs,
    RoadSnap s,
    RoadSnap t,
    GeoPoint from,
    GeoPoint to,
    int doy,
    String targetName,
    bool imperial,
  ) {
    final pts = <GeoPoint>[];
    final cum = <double>[];
    final time = <double>[];
    final rough = <int>[];
    final roads = <String>[];
    final segEdge = <int>[];
    // Where each leg starts along the route, and the junction node.
    final legStart = <double>[];
    for (final (e, _, m0, m1) in legs) {
      final piece = _piece(e, m0, m1);
      final speed = d.edgeSpeed[e] / 3.6;
      legStart.add(cum.isEmpty ? 0 : cum.last);
      for (var i = 0; i < piece.length; i++) {
        if (pts.isNotEmpty && i == 0) continue; // shared junction point
        if (pts.isEmpty) {
          pts.add(piece[0]);
          cum.add(0);
          time.add(0);
          continue;
        }
        final dm = distanceM(pts.last, piece[i]);
        pts.add(piece[i]);
        cum.add(cum.last + dm);
        time.add(time.last + dm / speed);
        rough.add(d.edgeRough[e]);
        roads.add(d.names[d.edgeName[e]]);
        segEdge.add(e);
      }
    }
    if (pts.length == 1) {
      pts.add(pts.first);
      cum.add(0);
      time.add(0);
      rough.add(0);
      roads.add('');
      segEdge.add(legs.first.$1);
    }
    final r = DriveRoute(
      points: pts,
      cum: cum,
      timeCum: time,
      segRough: Uint8List.fromList(rough),
      segRoad: roads,
      steps: const [],
      warnings: const [],
      startOffM: s.distM,
      endOffM: t.distM,
    );
    return DriveRoute(
      points: pts,
      cum: cum,
      timeCum: time,
      segRough: r.segRough,
      segRoad: roads,
      steps: _steps(r, legs, legStart, targetName, imperial),
      warnings: _warnings(r, legs, legStart, doy),
      startOffM: s.distM,
      endOffM: t.distM,
    );
  }

  // ------------------------------------------------------------ steps

  GeoPoint _pointAt(DriveRoute r, double m) {
    final c = r.cum;
    if (m <= 0) return r.points.first;
    if (m >= c.last) return r.points.last;
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
    final a = r.points[lo], b = r.points[hi];
    return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
  }

  /// Initial bearing of edge [e] leaving node [n] (over ~25 m).
  double _leaveBearing(int e, bool fromB) {
    final pts = d.edgePoints(e);
    final p = fromB ? pts.reversed.toList() : pts;
    var i = 1;
    var acc = 0.0;
    while (i < p.length - 1 && acc + distanceM(p[i - 1], p[i]) < 25) {
      acc += distanceM(p[i - 1], p[i]);
      i++;
    }
    return bearingDeg(p[0], p[i]);
  }

  static String _nameOr(String n, int cls) => n.isNotEmpty
      ? n
      : cls == 9
      ? 'a forest track'
      : cls == 8
      ? 'a service road'
      : 'an unnamed road';

  static String _ordinal(int n) => switch (n) {
    1 => '1st',
    2 => '2nd',
    3 => '3rd',
    _ => '${n}th',
  };

  static String _spokenOrdinal(int n) => switch (n) {
    1 => 'first',
    2 => 'second',
    3 => 'third',
    4 => 'fourth',
    5 => 'fifth',
    _ => '${n}th',
  };

  /// Same road under another label ("SR 14" / "Lewis and Clark Trail
  /// Highway (SR 14)", "Forest Road 64" / "Dry Creek Road (FR 64)").
  static bool sameRoad(String a, String b) {
    if (a == b) return true;
    if (a.isEmpty || b.isEmpty) return false;
    String? key(String s) {
      final m = RegExp(r'(?:FR|Forest Road) (\d+)').firstMatch(s);
      if (m != null) return 'FR${m.group(1)}';
      final r = RegExp(r'\(([^)]+)\)$').firstMatch(s);
      if (r != null) return r.group(1);
      if (RegExp(r'^[A-Z]{1,3}[- ]\d+$').hasMatch(s)) return s;
      return null;
    }

    final ka = key(a), kb = key(b);
    if (ka != null && ka == kb) return true;
    return a.startsWith(b) || b.startsWith(a);
  }

  List<DriveStep> _steps(
    DriveRoute r,
    List<(int, bool, double, double)> legs,
    List<double> legStart,
    String targetName,
    bool imperial,
  ) {
    final out = <DriveStep>[];
    final first = legs.first.$1;
    final b0 = bearingDeg(r.points.first, _pointAt(r, 40));
    final n0 = d.names[d.edgeName[first]];
    out.add(
      DriveStep(
        alongM: 0,
        maneuver: Maneuver.depart,
        text: 'Head ${cardinal(b0)}${n0.isEmpty ? '' : ' on $n0'}',
        spoken: 'head ${cardinalWord(b0)}${n0.isEmpty ? '' : ' on $n0'}',
        pos: r.points.first,
        road: n0,
      ),
    );
    // Candidates: (along, maneuver, road, class, |angle|, link).
    final cand = <(double, Maneuver, String, int, double, bool, int)>[];
    var i = 1;
    while (i < legs.length) {
      final (pe, pfwd, _, _) = legs[i - 1];
      final (e, _, _, _) = legs[i];
      final node = pfwd ? d.edgeB[pe] : d.edgeA[pe];
      final at = legStart[i];
      final deg = degree(node);
      final pName = d.names[d.edgeName[pe]], name = d.names[d.edgeName[e]];
      final pf = d.edgeFlags[pe], f = d.edgeFlags[e];
      final bin = bearingDeg(_pointAt(r, at - 25), _pointAt(r, at));
      final bout = bearingDeg(_pointAt(r, at), _pointAt(r, at + 25));
      final turn = deltaDeg(bout, bin); // + right
      final enteringRoundabout =
          f & EdgeFlag.roundabout != 0 && pf & EdgeFlag.roundabout == 0;
      if (enteringRoundabout) {
        // Count exits until we leave the roundabout.
        var exits = 0, j = i;
        while (j < legs.length &&
            d.edgeFlags[legs[j].$1] & EdgeFlag.roundabout != 0) {
          final (je, jf, _, _) = legs[j];
          final end = jf ? d.edgeB[je] : d.edgeA[je];
          if (j + 1 < legs.length) {
            for (var k = _adjStart[end]; k < _adjStart[end + 1]; k++) {
              final oe = _adj[k] >> 1;
              if (d.edgeFlags[oe] & EdgeFlag.roundabout != 0) continue;
              final fromB = _adj[k] & 1 == 1;
              if (fromB ? canBackward(oe) : canForward(oe)) {
                exits++;
                break;
              }
            }
          }
          j++;
        }
        final outLeg = j < legs.length ? legs[j].$1 : e;
        cand.add((
          at,
          Maneuver.roundabout,
          d.names[d.edgeName[outLeg]],
          d.edgeCls[outLeg],
          90,
          false,
          max(1, exits),
        ));
        i = j + 1;
        continue;
      }
      if (deg < 3 || f & EdgeFlag.roundabout != 0) {
        i++;
        continue;
      }
      final isLink = f & EdgeFlag.link != 0, wasLink = pf & EdgeFlag.link != 0;
      final same = sameRoad(name, pName) || (isLink && wasLink);
      final cls = d.edgeCls[e];
      // Another way out close to ours, of a comparable road: a fork.
      double? forkOther;
      for (var k = _adjStart[node]; k < _adjStart[node + 1]; k++) {
        final oe = _adj[k] >> 1;
        final fromB = _adj[k] & 1 == 1;
        if (oe == e || oe == pe) continue;
        if (!(fromB ? canBackward(oe) : canForward(oe))) continue;
        final oLink = d.edgeFlags[oe] & EdgeFlag.link != 0;
        if (oLink && !isLink) continue; // an exit we pass
        if (d.edgeCls[oe] > cls + (same ? 0 : 1)) continue; // a side road
        final ob = _leaveBearing(oe, fromB);
        if (deltaDeg(ob, bout).abs() < 35) forkOther = ob;
      }
      final a = turn.abs();
      final linkIn = isLink && !wasLink;
      final linkOut = !isLink && wasLink;
      if (same && !linkIn && !linkOut && a < 40 && forkOther == null) {
        i++;
        continue;
      }
      final Maneuver m;
      if (linkIn) {
        m = a < 15
            ? Maneuver.ramp
            : (turn < 0 ? Maneuver.rampLeft : Maneuver.rampRight);
      } else if (linkOut && cls <= 1 && a < 45) {
        m = Maneuver.merge;
      } else if (a < 40 && forkOther != null) {
        m = deltaDeg(bout, forkOther) < 0
            ? Maneuver.keepLeft
            : Maneuver.keepRight;
      } else if (a < 20) {
        m = Maneuver.straight;
      } else if (a < 45) {
        m = turn < 0 ? Maneuver.slightLeft : Maneuver.slightRight;
      } else if (a < 130) {
        m = turn < 0 ? Maneuver.left : Maneuver.right;
      } else if (a < 170) {
        m = turn < 0 ? Maneuver.sharpLeft : Maneuver.sharpRight;
      } else {
        m = Maneuver.uturn;
      }
      cand.add((at, m, name, cls, a, isLink, 0));
      i++;
    }
    // Several changes within 40 m are one step: the sharpest turn, onto
    // the last road.
    final merged = <(double, Maneuver, String, int, double, bool, int)>[];
    for (final c in cand) {
      final last = merged.isEmpty ? null : merged.last;
      if (last != null && c.$1 - last.$1 < 40) {
        final keep = c.$5 > last.$5 && last.$2 != Maneuver.roundabout
            ? c
            : last;
        merged[merged.length - 1] = (
          last.$1,
          keep.$2,
          c.$3,
          c.$4,
          max(c.$5, last.$5),
          c.$6,
          keep.$7,
        );
        continue;
      }
      merged.add(c);
    }
    for (final (at, m, name, cls, _, link, exit) in merged) {
      final road = _nameOr(name, cls);
      final named = name.isNotEmpty;
      final onto = link
          ? (named ? ' toward $name' : '')
          : (named
                ? ' onto $name'
                : (m == Maneuver.straight ? '' : ' onto $road'));
      final verb = switch (m) {
        Maneuver.ramp => 'Take the ramp',
        Maneuver.rampLeft => 'Take the ramp on the left',
        Maneuver.rampRight => 'Take the ramp on the right',
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
        Maneuver.roundabout =>
          'At the roundabout, take the ${_ordinal(exit)} exit',
        _ => 'Continue',
      };
      final text = '$verb$onto';
      final spoken = m == Maneuver.roundabout
          ? 'at the roundabout, take the ${_spokenOrdinal(exit)} exit$onto'
          : text[0].toLowerCase() + text.substring(1);
      out.add(
        DriveStep(
          alongM: at,
          maneuver: m,
          text: text,
          spoken: spoken,
          pos: _pointAt(r, at),
          road: name,
          exit: exit,
        ),
      );
    }
    final tn = targetName.isEmpty ? 'your destination' : targetName;
    out.add(
      DriveStep(
        alongM: r.lengthM,
        maneuver: Maneuver.arrive,
        text:
            'Arrive at $tn${r.endOffM > 40 ? ' (${formatDistance(r.endOffM, imperial: imperial)} from the road)' : ''}',
        spoken: 'you have arrived at $tn',
        pos: r.points.last,
      ),
    );
    return out;
  }

  // ------------------------------------------------------------ warnings

  List<RoadWarning> _warnings(
    DriveRoute r,
    List<(int, bool, double, double)> legs,
    List<double> legStart,
    int doy,
  ) {
    final out = <RoadWarning>[];
    // Group rough stretches by road and level.
    final byKey = <String, (String, int, double, double)>{};
    for (var k = 0; k < legs.length; k++) {
      final (e, fwd, m0, m1) = legs[k];
      final len = (m1 - m0).abs();
      final name = d.names[d.edgeName[e]];
      final label = _nameOr(name, d.edgeCls[e]);
      final rl = d.edgeRough[e];
      if (rl >= 1) {
        final key = '$label|$rl';
        final o = byKey[key];
        byKey[key] = (label, rl, (o?.$3 ?? 0) + len, o?.$4 ?? legStart[k]);
      }
      final f = d.edgeFlags[e];
      final cf = d.edgeClose[2 * e], ct = d.edgeClose[2 * e + 1];
      if (cf != 0 &&
          !out.any((w) => w.road == label && w.kind.startsWith('clos'))) {
        final now = closedOn(doy, cf, ct);
        out.add(
          RoadWarning(
            now ? 'closed' : 'seasonal',
            label,
            len,
            legStart[k],
            '$label: closed ${dayLabel(cf)} to ${dayLabel(ct)}'
            '${now ? ' (closed now; no other way found)' : ''}',
          ),
        );
      } else if (f & EdgeFlag.seasonal != 0 &&
          !out.any((w) => w.road == label && w.kind == 'seasonal')) {
        out.add(
          RoadWarning(
            'seasonal',
            label,
            len,
            legStart[k],
            '$label: seasonal road (may be closed in winter)',
          ),
        );
      }
      if (f & EdgeFlag.ford != 0) {
        out.add(
          RoadWarning(
            'ford',
            label,
            len,
            legStart[k],
            'Ford (water crossing) on $label',
          ),
        );
      }
      if (f & EdgeFlag.destination != 0 &&
          !out.any((w) => w.road == label && w.kind == 'destination')) {
        out.add(
          RoadWarning(
            'destination',
            label,
            len,
            legStart[k],
            '$label: local / permit traffic only',
          ),
        );
      }
      // Gates at the far end of this leg.
      if (k + 1 < legs.length) {
        final node = fwd ? d.edgeB[e] : d.edgeA[e];
        if (d.nodeFlags[node] & NodeFlag.blocked != 0) {
          out.add(
            RoadWarning(
              'gate',
              label,
              0,
              legStart[k + 1],
              'Locked gate or barrier on $label: no other way by road',
            ),
          );
        } else if (d.nodeFlags[node] & NodeFlag.gate != 0 &&
            degree(node) <= 2 &&
            d.edgeCls[e] >= 4 &&
            !out.any((w) => w.kind == 'gate' && w.road == label)) {
          out.add(
            RoadWarning(
              'gate',
              label,
              0,
              legStart[k + 1],
              'Gate on $label (may be closed)',
            ),
          );
        }
      }
    }
    final rough = byKey.values.toList()..sort((a, b) => b.$2.compareTo(a.$2));
    var i = 0;
    for (final (label, rl, len, at) in rough) {
      if (len < 50) continue;
      out.insert(
        i++,
        RoadWarning(
          rl == 3 ? 'clearance' : (rl == 2 ? 'rough' : 'unpaved'),
          label,
          len,
          at,
          '$label: ${formatDistance(len, imperial: false)} ${roughLabels[rl]}'
          '${rl == 3 ? ' (high-clearance vehicle)' : ''}',
        ),
      );
    }
    return out;
  }
}

/// Binary min-heap of (priority, node).
class _Heap {
  final _p = <double>[];
  final _n = <int>[];
  bool get isNotEmpty => _p.isNotEmpty;

  void push(double p, int n) {
    _p.add(p);
    _n.add(n);
    var i = _p.length - 1;
    while (i > 0) {
      final up = (i - 1) >> 1;
      if (_p[up] <= _p[i]) break;
      _swap(i, up);
      i = up;
    }
  }

  (double, int) pop() {
    final top = (_p[0], _n[0]);
    final lp = _p.removeLast(), ln = _n.removeLast();
    if (_p.isNotEmpty) {
      _p[0] = lp;
      _n[0] = ln;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < _p.length && _p[l] < _p[m]) m = l;
        if (r < _p.length && _p[r] < _p[m]) m = r;
        if (m == i) break;
        _swap(i, m);
        i = m;
      }
    }
    return top;
  }

  void _swap(int a, int b) {
    final tp = _p[a];
    _p[a] = _p[b];
    _p[b] = tp;
    final tn = _n[a];
    _n[a] = _n[b];
    _n[b] = tn;
  }
}
