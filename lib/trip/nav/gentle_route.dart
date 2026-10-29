import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../geo.dart';
import 'foot_router.dart';
import 'trail_graph.dart';

/// "Gentle compass route" (v2.1.0): off-trail walking line over the
/// elevation grid, for places with no trail or road to follow.
///
/// It looks only at the shape of the ground. It cannot see cliffs, brush,
/// water, fences or private land, so it is a suggestion, never a safe path.

/// How steep the suggested line may get.
enum SlopeLimit {
  gentle('Gentle', 'about 10% (a gentle walking slope)', 10),
  moderate('Moderate', 'about 20% (steady uphill)', 20),
  any('Any', 'no limit (just avoids the steepest ground)', null);

  const SlopeLimit(this.label, this.blurb, this.percent);
  final String label, blurb;

  /// Steepest slope the line is allowed (percent), null = no limit.
  final double? percent;
}

/// Label shown wherever a gentle route is shown.
const String gentleLabel =
    "Suggested by terrain only: can't see cliffs, brush, water or private "
    'land';

/// A rotated grid over the corridor from start to target: [u] runs along
/// the straight line to the target, [v] to its right.
class GentleInput {
  GentleInput({
    required this.lat0,
    required this.lng0,
    required this.bearing,
    required this.length,
    required this.cell,
    required this.u0,
    required this.v0,
    required this.nu,
    required this.nv,
    required this.elev,
    required this.trails,
    required this.maxSlopePct,
    this.maxGradePct,
  });

  /// Where the start is (the grid is projected around it).
  final double lat0, lng0;

  /// Degrees clockwise from north of the start -> target line.
  final double bearing;

  /// Straight distance start -> target (m).
  final double length;
  final double cell;

  /// Grid corner (m, in the u/v frame) and size in cells.
  final double u0, v0;
  final int nu, nv;

  /// Elevation of each cell (row-major, v rows of u cells); NaN = unknown.
  final Float32List elev;

  /// Trail / track lines clipped to the grid, each as u,v pairs (m).
  final List<Float64List> trails;

  /// Steepest slope allowed (percent), null = no limit.
  final double? maxSlopePct;

  /// Hard cutoff (percent): steps steeper than this are not used unless
  /// there is no other way. Null = the mode's own ([gentleCutoffFor]).
  final double? maxGradePct;

  double get _kx => 111319.49 * cos(lat0 * pi / 180);
  static const double _ky = 111132.954;

  ({double u, double v}) toUV(GeoPoint p) {
    final x = (p.lng - lng0) * _kx, y = (p.lat - lat0) * _ky;
    final b = bearing * pi / 180;
    return (u: x * sin(b) + y * cos(b), v: x * cos(b) - y * sin(b));
  }

  GeoPoint fromUV(double u, double v) {
    final b = bearing * pi / 180;
    final x = u * sin(b) + v * cos(b), y = u * cos(b) - v * sin(b);
    return GeoPoint(lat0 + y / _ky, lng0 + x / _kx);
  }
}

class GentleOutput {
  GentleOutput({
    required this.u,
    required this.v,
    required this.elev,
    required this.maxSlopePct,
    required this.onTrailFraction,
    required this.lengthM,
    required this.exceedsLimit,
    this.relaxedCutoff = false,
  });
  final List<double> u, v, elev;

  /// Steepest stretch of the suggested line (percent): the climb or drop
  /// along the line over about one grid cell of walking.
  final double maxSlopePct;

  /// Share of the line that follows a trail or track (0..1).
  final double onTrailFraction;
  final double lengthM;

  /// The line had to cross ground steeper than the chosen limit.
  final bool exceedsLimit;

  /// There was no way round the very steep ground (over the hard grade
  /// cutoff), so the line crosses it anyway.
  final bool relaxedCutoff;
}

/// Chosen grid cell size (m) for a route of [lengthM].
double gentleCellFor(double lengthM) =>
    lengthM <= 6000 ? 30 : (lengthM <= 12000 ? 45 : 70);

/// Longest straight distance the planner accepts.
const double gentleMaxM = 25000;

/// Half-width of the corridor (m) around the straight line.
double gentleHalfWidthFor(double lengthM) =>
    (lengthM * 0.25).clamp(350.0, 1500.0);

/// Walking time per metre against flat ground (Tobler's hiking function),
/// [s] = rise / run (+ uphill). Best going down about 5%: 0.84.
double toblerFactor(double s) => exp(3.5 * ((s + 0.05).abs() - 0.05));

/// The cheapest any step can be per metre: Tobler's best times the trail
/// discount. The search heuristic is this times the straight distance, so
/// it can never overestimate (admissible and consistent).
const double gentleToblerBest = 0.8394; // toblerFactor(-0.05)

/// A step along a trail costs this much of the same step off the trail.
const double gentleTrailFactor = 0.5;

/// Hard grade cutoff (percent) for [limit]: about twice the mode's limit,
/// 45% for "Any". Steps over it are not allowed unless there is no other
/// way (then the search is repeated without it and the result flagged).
double gentleCutoffFor(double? limitPct) =>
    limitPct == null ? 45 : min(45, limitPct * 2);

/// Least-cost path over [g]: step cost = walking time (Tobler) x a mode
/// penalty for steep ground, over a one-cell baseline, with trail-to-trail
/// steps discounted. Pure and synchronous (run it in an isolate for big
/// grids).
GentleOutput? computeGentle(GentleInput g) {
  final nu = g.nu, nv = g.nv, n = nu * nv;
  if (nu < 3 || nv < 3 || g.elev.length != n) return null;
  // Fill unknown cells from known neighbours (a few holes are fine; many
  // mean there is no elevation data here).
  var unknown = 0;
  for (final e in g.elev) {
    if (!e.isFinite) unknown++;
  }
  if (unknown > n * 0.2) return null;
  final z = Float32List.fromList(g.elev);
  if (unknown > 0) {
    for (var pass = 0; pass < 4 && unknown > 0; pass++) {
      for (var i = 0; i < n; i++) {
        if (z[i].isFinite) continue;
        var s = 0.0, c = 0;
        final x = i % nu, y = i ~/ nu;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final xx = x + dx, yy = y + dy;
            if (xx < 0 || yy < 0 || xx >= nu || yy >= nv) continue;
            final e = z[yy * nu + xx];
            if (e.isFinite) {
              s += e;
              c++;
            }
          }
        }
        if (c > 0) {
          z[i] = s / c;
          unknown--;
        }
      }
    }
    if (unknown > 0) return null;
  }

  double zAt(double u, double v) {
    final fx = (u - g.u0) / g.cell - 0.5, fy = (v - g.v0) / g.cell - 0.5;
    final x0 = fx.floor().clamp(0, nu - 2), y0 = fy.floor().clamp(0, nv - 2);
    final ax = (fx - x0).clamp(0.0, 1.0), ay = (fy - y0).clamp(0.0, 1.0);
    double e(int x, int y) => z[y * nu + x];
    return (e(x0, y0) * (1 - ax) + e(x0 + 1, y0) * ax) * (1 - ay) +
        (e(x0, y0 + 1) * (1 - ax) + e(x0 + 1, y0 + 1) * ax) * ay;
  }

  // Trail cells and the trail-to-trail steps between them: a step is
  // cheaper only when it goes from one cell of a trail to the next cell of
  // the same trail (any direction: switchbacks and contour trails count),
  // so the line follows the trail instead of running beside it.
  final trailCell = Uint8List(n);
  // Where the trail really runs inside each trail cell (mean of its points),
  // so the line sits on the trail, not on the cell centres.
  final trailSumU = Float64List(n), trailSumV = Float64List(n);
  final trailCount = Int32List(n);
  // Grade (rise / run) of each trail-to-trail step, read from the ground
  // under the trail itself (not from the cell centres, which would turn a
  // gentle diagonal trail into steep little stairs).
  final trailEdge = <int, double>{};
  for (final t in g.trails) {
    var prev = -1;
    var pu = 0.0, pv = 0.0, pz = 0.0;
    for (var k = 0; k + 3 < t.length; k += 2) {
      final ax = t[k], ay = t[k + 1], bx = t[k + 2], by = t[k + 3];
      final len = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
      if (len < 1e-6) continue;
      final steps = max(1, (len / (g.cell * 0.5)).ceil());
      for (var s = 0; s <= steps; s++) {
        final u = ax + (bx - ax) * s / steps, v = ay + (by - ay) * s / steps;
        final cx = ((u - g.u0) / g.cell).floor();
        final cy = ((v - g.v0) / g.cell).floor();
        if (cx < 0 || cy < 0 || cx >= nu || cy >= nv) {
          prev = -1;
          continue;
        }
        final i = cy * nu + cx;
        trailCell[i] = 1;
        trailSumU[i] += u;
        trailSumV[i] += v;
        trailCount[i]++;
        final zz = zAt(u, v);
        if (prev >= 0 && prev != i) {
          final d = sqrt((u - pu) * (u - pu) + (v - pv) * (v - pv));
          if (d > 1) {
            final gr = (zz - pz) / d;
            trailEdge[prev * n + i] = gr;
            trailEdge[i * n + prev] = -gr;
          }
        }
        if (prev != i) {
          prev = i;
          pu = u;
          pv = v;
          pz = zz;
        }
      }
    }
  }

  /// Trail-to-trail step grade, or null when the step is not along a trail.
  double? trailGrade(int a, int b) => trailEdge[a * n + b];
  bool nearTrail(int a, int b) {
    if (trailCell[a] == 0 || trailCell[b] == 0) return false;
    final dx = (a % nu - b % nu).abs(), dy = (a ~/ nu - b ~/ nu).abs();
    return dx <= 1 && dy <= 1;
  }

  // Steepest slope at each cell (percent), over a one-cell baseline (the
  // steeper of the two neighbours on each axis), so a short steep face is
  // not averaged away. Side slopes count too, so the line does not run
  // along the face of a steep hillside.
  final grad = Float32List(n);
  for (var y = 0; y < nv; y++) {
    for (var x = 0; x < nu; x++) {
      double axis(double c, double? lo, double? hi) {
        final a = lo == null ? 0.0 : (c - lo).abs();
        final b = hi == null ? 0.0 : (hi - c).abs();
        return max(a, b) / g.cell;
      }

      final c = z[y * nu + x];
      final gx = axis(
        c,
        x > 0 ? z[y * nu + x - 1] : null,
        x < nu - 1 ? z[y * nu + x + 1] : null,
      );
      final gy = axis(
        c,
        y > 0 ? z[(y - 1) * nu + x] : null,
        y < nv - 1 ? z[(y + 1) * nu + x] : null,
      );
      grad[y * nu + x] = sqrt(gx * gx + gy * gy) * 100;
    }
  }
  const sideWeight = 0.6;

  int cellOf(double u, double v) {
    final cx = ((u - g.u0) / g.cell).floor().clamp(0, nu - 1);
    final cy = ((v - g.v0) / g.cell).floor().clamp(0, nv - 1);
    return cy * nu + cx;
  }

  final start = cellOf(0, 0), goal = cellOf(g.length, 0);
  final limit = g.maxSlopePct;
  final cutoffPct = g.maxGradePct ?? gentleCutoffFor(limit);

  /// Penalty for steep ground in this mode (1 = none).
  double modePenalty(double pct) {
    if (limit != null) {
      final r = pct / limit;
      return r <= 1
          ? 1 + 0.3 * r * r
          : 1.3 + 8 * (r - 1) + 3 * (r - 1) * (r - 1);
    }
    final r = pct / 35;
    return 1 + r * r;
  }

  /// Cost of walking [len] m at signed grade [s] (rise/run) with side slope
  /// [sidePct]; infinity when over the hard cutoff and [cut] is on.
  double legCost(double s, double sidePct, double len, bool onTrail, bool cut) {
    final alongPct = s.abs() * 100;
    final side = onTrail ? 0.0 : sideWeight * sidePct;
    final eff = max(alongPct, side);
    if (cut && !onTrail && eff > cutoffPct) return double.infinity;
    final sg = side > alongPct ? side / 100 : s;
    return len *
        toblerFactor(sg) *
        modePenalty(eff) *
        (onTrail ? gentleTrailFactor : 1);
  }

  double stepCost(int a, int b, int dx, int dy, bool cut) {
    final d = sqrt((dx * dx + dy * dy).toDouble()) * g.cell;
    final side = max(grad[a], grad[b]);
    final tg = trailGrade(a, b);
    final onTrail = tg != null;
    final exempt = a == start || b == goal;
    final cutNow = cut && !exempt;
    if (dx.abs() == 2 || dy.abs() == 2) {
      // A long (knight) step is two half steps over the height halfway
      // between the cells it passes, so the baseline stays about a cell.
      final ax = a % nu, ay = a ~/ nu;
      // The two cells either side of the half-way point.
      final c1 = dx.abs() == 2
          ? ay * nu + ax + dx ~/ 2
          : (ay + dy ~/ 2) * nu + ax;
      final c2 = dx.abs() == 2
          ? (ay + dy) * nu + ax + dx ~/ 2
          : (ay + dy ~/ 2) * nu + ax + dx;
      final zm = (z[c1] + z[c2]) / 2;
      final h = d / 2;
      final c =
          legCost((zm - z[a]) / h, side, h, onTrail, cutNow) +
          legCost((z[b] - zm) / h, side, h, onTrail, cutNow);
      return c;
    }
    return legCost(tg ?? (z[b] - z[a]) / d, side, d, onTrail, cutNow);
  }

  const dirs = [
    (1, 0), (-1, 0), (0, 1), (0, -1), //
    (1, 1), (1, -1), (-1, 1), (-1, -1),
    (2, 1), (2, -1), (-2, 1), (-2, -1), (1, 2), (1, -2), (-1, 2), (-1, -2),
  ];
  final gx = goal % nu, gy = goal ~/ nu;
  const hFactor = gentleToblerBest * gentleTrailFactor;
  double h(int i) {
    final dx = (i % nu - gx) * g.cell, dy = (i ~/ nu - gy) * g.cell;
    return sqrt(dx * dx + dy * dy) * hFactor;
  }

  /// A* over the grid; null when the goal cannot be reached.
  List<int>? search(bool cut) {
    final cost = Float64List(n)..fillRange(0, n, double.infinity);
    final from = Int32List(n)..fillRange(0, n, -1);
    final done = Uint8List(n);
    final heap = _Heap();
    cost[start] = 0;
    heap.add(h(start), start);
    while (heap.isNotEmpty) {
      final cur = heap.removeFirst();
      if (done[cur] == 1) continue;
      done[cur] = 1;
      if (cur == goal) break;
      final cx = cur % nu, cy = cur ~/ nu;
      for (final (dx, dy) in dirs) {
        final x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= nu || y >= nv) continue;
        final nb = y * nu + x;
        if (done[nb] == 1) continue;
        final sc = stepCost(cur, nb, dx, dy, cut);
        if (sc.isInfinite) continue;
        final c = cost[cur] + sc;
        if (c < cost[nb]) {
          cost[nb] = c;
          from[nb] = cur;
          heap.add(c + h(nb), nb);
        }
      }
    }
    if (from[goal] < 0 && start != goal) return null;
    final path = <int>[];
    for (var c = goal; c >= 0; c = from[c]) {
      path.add(c);
      if (c == start) break;
    }
    return path.reversed.toList();
  }

  var relaxed = false;
  var cells = search(true);
  if (cells == null) {
    // No way round the steepest ground: allow it (still dear), and say so.
    relaxed = true;
    cells = search(false);
    if (cells == null) return null;
  }
  final cut = !relaxed;

  // Cell centres in the u/v frame; the true start and target at the ends.
  var pu = <double>[0];
  var pv = <double>[0];
  for (var k = 1; k + 1 < cells.length; k++) {
    final c = cells[k];
    if (trailCount[c] > 0) {
      pu.add(trailSumU[c] / trailCount[c]);
      pv.add(trailSumV[c] / trailCount[c]);
    } else {
      pu.add(g.u0 + (c % nu + 0.5) * g.cell);
      pv.add(g.v0 + (c ~/ nu + 0.5) * g.cell);
    }
  }
  pu.add(g.length);
  pv.add(0);

  // Straight-line cost between two path points, sampled every ~3/4 cell
  // (the same baseline as the search). [strict]: infinity over the hard
  // cutoff, so a shortcut can never cut across a wall.
  double segCost(double u1, double v1, double u2, double v2, bool strict) {
    final d = sqrt((u2 - u1) * (u2 - u1) + (v2 - v1) * (v2 - v1));
    final steps = max(1, (d / (g.cell * 0.75)).ceil());
    var total = 0.0;
    var pz = zAt(u1, v1);
    var prev = cellOf(u1, v1);
    for (var s = 1; s <= steps; s++) {
      final u = u1 + (u2 - u1) * s / steps, v = v1 + (v2 - v1) * s / steps;
      final cz = zAt(u, v);
      final sd = d / steps;
      final i = cellOf(u, v);
      final onTrail = i == prev ? trailCell[i] == 1 : nearTrail(prev, i);
      total += legCost((cz - pz) / sd, grad[i], sd, onTrail, strict && cut);
      pz = cz;
      prev = i;
    }
    return total;
  }

  // Pull the line tight where the straight way is about as good as the
  // winding one (cost-aware, so it never cuts across a steep bit).
  if (pu.length > 3) {
    final cum = <double>[0];
    for (var k = 1; k < pu.length; k++) {
      // The search's own price for this step (trail steps at their real
      // grade), so a shortcut is judged against what the search paid.
      final a = cells[k - 1], b = cells[k];
      cum.add(
        cum.last + stepCost(a, b, b % nu - a % nu, b ~/ nu - a ~/ nu, false),
      );
    }
    final su = <double>[pu.first], sv = <double>[pv.first];
    var i = 0;
    while (i < pu.length - 1) {
      var next = i + 1;
      for (var j = pu.length - 1; j > i + 1; j--) {
        final direct = segCost(pu[i], pv[i], pu[j], pv[j], true);
        if (direct <= (cum[j] - cum[i]) * 1.06) {
          next = j;
          break;
        }
      }
      su.add(pu[next]);
      sv.add(pv[next]);
      i = next;
    }
    pu = su;
    pv = sv;
  }

  // Round the corners a little (a bend of at most ~80 m each side of the
  // corner), so the line does not turn on a sixpence. Each corner is judged
  // on its own and kept only when it does not cost more (and never over the
  // hard cutoff): rounding never cuts a detour or a switchback short.
  if (pu.length > 2) {
    const r = 80.0;
    final ru = <double>[pu.first], rv = <double>[pv.first];
    for (var k = 1; k + 1 < pu.length; k++) {
      final d1 = sqrt(pow(pu[k] - pu[k - 1], 2) + pow(pv[k] - pv[k - 1], 2));
      final d2 = sqrt(pow(pu[k + 1] - pu[k], 2) + pow(pv[k + 1] - pv[k], 2));
      final t = min(r, min(d1, d2) * 0.4);
      // A hairpin (turning back on itself, like a switchback) stays sharp.
      final cosTurn =
          ((pu[k] - pu[k - 1]) * (pu[k + 1] - pu[k]) +
              (pv[k] - pv[k - 1]) * (pv[k + 1] - pv[k])) /
          (d1 * d2);
      if (t < 8 || cosTurn < -0.5) {
        ru.add(pu[k]);
        rv.add(pv[k]);
        continue;
      }
      final au = pu[k] + (pu[k - 1] - pu[k]) * t / d1;
      final av = pv[k] + (pv[k - 1] - pv[k]) * t / d1;
      final bu = pu[k] + (pu[k + 1] - pu[k]) * t / d2;
      final bv = pv[k] + (pv[k + 1] - pv[k]) * t / d2;
      final cu = <double>[], cv = <double>[];
      for (var s = 0; s <= 6; s++) {
        final q = s / 6, w = 1 - q;
        cu.add(w * w * au + 2 * w * q * pu[k] + q * q * bu);
        cv.add(w * w * av + 2 * w * q * pv[k] + q * q * bv);
      }
      var curve = 0.0;
      for (var s = 1; s < cu.length; s++) {
        curve += segCost(cu[s - 1], cv[s - 1], cu[s], cv[s], true);
      }
      final sharp =
          segCost(au, av, pu[k], pv[k], false) +
          segCost(pu[k], pv[k], bu, bv, false);
      if (curve <= sharp * 1.03) {
        ru.addAll(cu);
        rv.addAll(cv);
      } else {
        ru.add(pu[k]);
        rv.add(pv[k]);
      }
    }
    ru.add(pu.last);
    rv.add(pv.last);
    pu = ru;
    pv = rv;
  }

  // Resample about every 25 m, with the ground height at each point.
  final ou = <double>[], ov = <double>[], oe = <double>[];
  var lengthM = 0.0;
  for (var k = 0; k + 1 < pu.length; k++) {
    final d = sqrt(pow(pu[k + 1] - pu[k], 2) + pow(pv[k + 1] - pv[k], 2));
    final steps = max(1, (d / 25).ceil());
    for (var s = 0; s < steps; s++) {
      final u = pu[k] + (pu[k + 1] - pu[k]) * s / steps;
      final v = pv[k] + (pv[k + 1] - pv[k]) * s / steps;
      ou.add(u);
      ov.add(v);
    }
    lengthM += d;
  }
  ou.add(pu.last);
  ov.add(pv.last);
  for (var k = 0; k < ou.length; k++) {
    oe.add(zAt(ou[k], ov[k]));
  }
  // The steepest stretch you actually walk: the climb or drop along the line
  // over about one cell of walking (the baseline the planner uses), and the
  // share along trails.
  var maxSlope = 0.0;
  var onTrail = 0;
  final window = max(g.cell * 0.9, 25.0);
  for (var k = 0; k < ou.length; k++) {
    var j = k + 1;
    var dist = 0.0;
    while (j < ou.length && dist < window) {
      dist += sqrt(pow(ou[j] - ou[j - 1], 2) + pow(ov[j] - ov[j - 1], 2));
      j++;
    }
    if (dist >= window * 0.6 && j - 1 < ou.length) {
      maxSlope = max(maxSlope, (oe[j - 1] - oe[k]).abs() / dist * 100);
    }
    if (trailCell[cellOf(ou[k], ov[k])] == 1) onTrail++;
  }
  return GentleOutput(
    u: ou,
    v: ov,
    elev: oe,
    maxSlopePct: maxSlope,
    onTrailFraction: ou.isEmpty ? 0 : onTrail / ou.length,
    lengthM: lengthM,
    exceedsLimit: limit != null && maxSlope > limit * 1.05,
    relaxedCutoff: relaxed,
  );
}

/// What the planner makes of the terrain between two points.
class GentlePlan {
  GentlePlan(this.route, this.output, this.limit);
  final TrailRoute route;
  final GentleOutput output;
  final SlopeLimit limit;

  /// Plain-words summary.
  String summary({bool imperial = true}) {
    final m = output.lengthM;
    final dist = formatDistance(m, imperial: imperial);
    final steep = '${output.maxSlopePct.round()}%';
    final trail = output.onTrailFraction >= 0.15
        ? ' About ${(output.onTrailFraction * 100).round()}% follows a trail '
              'or track.'
        : '';
    final over = output.exceedsLimit
        ? ' Warning: it has to cross ground steeper than ${limit.label} '
              '(${limit.percent?.round()}%).'
        : (output.relaxedCutoff
              ? ' Warning: no way round very steep ground ($steep).'
              : '');
    return '$dist, steepest about $steep.$trail$over';
  }
}

/// Build the grid for [from] -> [to] from [demAt] (elevation lookup; null =
/// no data) and the trail lines on the phone, then find the line in an
/// isolate. Null when the grid has no (or too little) elevation data or
/// the way is too far; [reason] says why.
Future<({GentlePlan? plan, String reason})> planGentle(
  GeoPoint from,
  GeoPoint to,
  Future<double?> Function(double lat, double lng) demAt, {
  SlopeLimit limit = SlopeLimit.gentle,
  List<GraphLine> trails = const [],
  bool useIsolate = true,
}) async {
  final length = distanceM(from, to);
  if (length < 40) {
    return (plan: null, reason: 'You are already there.');
  }
  if (length > gentleMaxM) {
    return (
      plan: null,
      reason:
          'Too far for a terrain route (${(gentleMaxM / 1000).round()} km is '
          'the most). Use the compass, or drive closer first.',
    );
  }
  final cell = gentleCellFor(length);
  final half = gentleHalfWidthFor(length);
  final pad = cell * 3;
  final u0 = -pad - half * 0.3, uEnd = length + pad + half * 0.3;
  final v0 = -half;
  final nu = ((uEnd - u0) / cell).ceil(), nv = (2 * half / cell).ceil();
  final bearing = bearingDeg(from, to);
  final proto = GentleInput(
    lat0: from.lat,
    lng0: from.lng,
    bearing: bearing,
    length: length,
    cell: cell,
    u0: u0,
    v0: v0,
    nu: nu,
    nv: nv,
    elev: Float32List(0),
    trails: const [],
    maxSlopePct: limit.percent,
  );
  final elev = Float32List(nu * nv);
  var known = 0;
  for (var y = 0; y < nv; y++) {
    for (var x = 0; x < nu; x++) {
      final p = proto.fromUV(u0 + (x + 0.5) * cell, v0 + (y + 0.5) * cell);
      final e = await demAt(p.lat, p.lng);
      if (e != null && e > -500 && e < 9000) {
        elev[y * nu + x] = e;
        known++;
      } else {
        elev[y * nu + x] = double.nan;
      }
    }
  }
  if (known < nu * nv * 0.8) {
    return (
      plan: null,
      reason:
          'No elevation data here. Save the area first (Offline areas > Save '
          'this area offline, with Elevation on) or get signal.',
    );
  }
  // Trail lines inside the corridor, in the grid frame.
  final tl = <Float64List>[];
  for (final line in trails) {
    final buf = <double>[];
    for (final p in line.points) {
      final c = proto.toUV(p);
      final inside =
          c.u >= u0 - cell &&
          c.u <= uEnd + cell &&
          c.v >= v0 - cell &&
          c.v <= v0 + nv * cell + cell;
      if (inside) {
        buf
          ..add(c.u)
          ..add(c.v);
      } else if (buf.length >= 4) {
        tl.add(Float64List.fromList(buf));
        buf.clear();
      } else {
        buf.clear();
      }
    }
    if (buf.length >= 4) tl.add(Float64List.fromList(buf));
  }
  final input = GentleInput(
    lat0: from.lat,
    lng0: from.lng,
    bearing: bearing,
    length: length,
    cell: cell,
    u0: u0,
    v0: v0,
    nu: nu,
    nv: nv,
    elev: elev,
    trails: tl,
    maxSlopePct: limit.percent,
  );
  final out = useIsolate
      ? await Isolate.run(() => computeGentle(input))
      : computeGentle(input);
  if (out == null) {
    return (
      plan: null,
      reason: 'Could not make a terrain route (not enough elevation data).',
    );
  }
  final pts = [
    for (var k = 0; k < out.u.length; k++) input.fromUV(out.u[k], out.v[k]),
  ];
  pts[0] = from;
  pts[pts.length - 1] = to;
  final r = TrailRoute(
    pts,
    [for (final e in out.elev) e.toDouble()],
    [],
    startOffM: 0,
    endOffM: 0,
  )..source = 'gentle';
  r.junctions.addAll(FootRouter.junctionsFromGeometry(r));
  return (plan: GentlePlan(r, out, limit), reason: '');
}

/// Minimal binary min-heap of (priority, cell).
class _Heap {
  final List<double> _p = [];
  final List<int> _v = [];

  bool get isNotEmpty => _p.isNotEmpty;

  void add(double p, int v) {
    _p.add(p);
    _v.add(v);
    var i = _p.length - 1;
    while (i > 0) {
      final up = (i - 1) >> 1;
      if (_p[up] <= _p[i]) break;
      _swap(i, up);
      i = up;
    }
  }

  int removeFirst() {
    final top = _v.first;
    final lp = _p.removeLast(), lv = _v.removeLast();
    if (_p.isNotEmpty) {
      _p[0] = lp;
      _v[0] = lv;
      var i = 0;
      for (;;) {
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
    final tv = _v[a];
    _v[a] = _v[b];
    _v[b] = tv;
  }
}
