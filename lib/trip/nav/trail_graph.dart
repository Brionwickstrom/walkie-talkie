import 'dart:math';

import '../geo.dart';

/// One trail line for the graph (a GPX track / route, a KML line).
class GraphLine {
  const GraphLine(this.name, this.points, [this.ele]);
  final String name;
  final List<GeoPoint> points;

  /// Elevation per point (NaN = unknown), or null.
  final List<double>? ele;
}

/// Local flat projection (metres) around a reference latitude; plenty
/// accurate for a hiking area (tens of km).
class _Proj {
  _Proj(this.lat0, this.lng0) : kx = 111319.49 * cos(lat0 * pi / 180);
  final double lat0, lng0, kx;
  static const ky = 111132.954;
  double x(GeoPoint p) => (p.lng - lng0) * kx;
  double y(GeoPoint p) => (p.lat - lat0) * ky;
  GeoPoint back(double x, double y) => GeoPoint(lat0 + y / ky, lng0 + x / kx);
}

class _Edge {
  _Edge(this.to, this.m, this.line);
  final int to;
  final double m;
  final int line;
}

/// Where a point meets the trail network: on edge [a]-[b] at [t] (0..1).
class GraphSnap {
  GraphSnap(this.a, this.b, this.t, this.at, this.offM);
  final int a, b;
  final double t;
  final GeoPoint at;

  /// Straight distance from the asked point to [at].
  final double offM;
}

/// A junction along a route: where trails meet.
class RouteJunction {
  RouteJunction(this.index, this.alongM, this.turn, this.next);

  /// Index into [TrailRoute.points].
  final int index;
  final double alongM;

  /// 'left', 'right', 'straight', 'sharp left', 'sharp right'.
  final String turn;

  /// Name of the trail taken after the junction ('' if unnamed).
  final String next;

  String get text => [
    turn == 'straight'
        ? 'Go straight'
        : turn == 'around'
        ? 'Turn around'
        : turn.startsWith('slight')
        ? 'Bear ${turn.substring(7)}'
        : 'Turn $turn',
    if (next.isNotEmpty && turn != 'around')
      next.startsWith('Unnamed ')
          ? 'onto the ${next.toLowerCase()}'
          : 'onto $next',
  ].join(' ');
}

/// A planned route along trails (plus straight off-trail bits at the ends).
class TrailRoute {
  TrailRoute(
    this.points,
    this.ele,
    this.junctions, {
    required this.startOffM,
    required this.endOffM,
  }) : cum = _cum(points);

  final List<GeoPoint> points;

  /// Elevation per point (NaN = unknown), filled from GPX or the DEM.
  List<double> ele;
  final List<double> cum;
  final List<RouteJunction> junctions;

  /// Off-trail straight legs: GPS position -> trail, trail -> target.
  final double startOffM, endOffM;

  /// Where the route came from (v2.1.0): '' = saved trails, 'valhalla',
  /// 'brouter', 'osrm' = online walking routers, 'gentle' = suggested from
  /// the terrain only (no trail or road data behind it).
  String source = '';

  /// Made by the online walking routers.
  bool get isOnline =>
      source == 'valhalla' || source == 'brouter' || source == 'osrm';

  /// Suggested from the elevation grid only.
  bool get terrainOnly => source == 'gentle';

  double get lengthM => cum.isEmpty ? 0 : cum.last;
  bool get hasElevation => ele.where((e) => e.isFinite).length >= 2;

  static List<double> _cum(List<GeoPoint> p) {
    final c = List<double>.filled(p.length, 0);
    for (var i = 1; i < p.length; i++) {
      c[i] = c[i - 1] + distanceM(p[i - 1], p[i]);
    }
    return c;
  }

  /// Elevation gain / loss (m) from [fromM] on, ignoring wiggles under
  /// [hysteresisM] (GPS / DEM noise).
  ({double gain, double loss}) climb({
    double fromM = 0,
    double hysteresisM = 3,
  }) {
    var gain = 0.0, loss = 0.0;
    double? ref;
    for (var i = 0; i < points.length; i++) {
      if (cum[i] < fromM) continue;
      final e = ele[i];
      if (!e.isFinite) continue;
      if (ref == null) {
        ref = e;
        continue;
      }
      final d = e - ref;
      if (d >= hysteresisM) {
        gain += d;
        ref = e;
      } else if (d <= -hysteresisM) {
        loss -= d;
        ref = e;
      }
    }
    return (gain: gain, loss: loss);
  }

  /// Elevation profile: (distance m, elevation m) for the known points.
  List<(double, double)> profile() => [
    for (var i = 0; i < points.length; i++)
      if (ele[i].isFinite) (cum[i], ele[i]),
  ];
}

/// Walking time (Naismith's rule): 5 km/h, plus 1 h per 600 m of ascent,
/// plus 10 min per 300 m of steep descent is ignored (Naismith's original).
Duration naismith(double metres, double gainM, {double kmh = 5}) {
  final h = metres / 1000 / kmh + gainM / 600;
  return Duration(seconds: (h * 3600).round());
}

/// Lines that are not paths (a wilderness boundary in a trail file).
bool isBoundaryName(String name) =>
    RegExp(r'boundary|border|perimeter', caseSensitive: false).hasMatch(name);

/// The trail network: trail lines joined where they cross, touch or end
/// near another trail; shortest paths along it (Dijkstra).
class TrailGraph {
  TrailGraph._(this.pos, this.ele, this._adj, this._comp, this._names, this._p);

  final List<GeoPoint> pos;
  final List<double> ele;
  final List<List<_Edge>> _adj;
  final List<int> _comp;
  final List<String> _names;
  final _Proj _p;
  late final _SegIndex _segs = _SegIndex(this);

  int get nodeCount => pos.length;
  int get edgeCount => _adj.fold(0, (s, a) => s + a.length) ~/ 2;
  int degree(int n) => _adj[n].map((e) => e.to).toSet().length;
  int componentOf(int n) => _comp[n];
  int get components => _comp.isEmpty ? 0 : _comp.reduce(max) + 1;
  bool get isEmpty => pos.isEmpty;

  /// Build from [lines]. Trails within [joinM] of another trail are joined
  /// there; a trail end within [endSnapM] of another trail is joined to it.
  static TrailGraph build(
    List<GraphLine> lines, {
    double joinM = 8,
    double endSnapM = 25,
    double bridgeM = 80,
  }) {
    final usable = [
      for (final l in lines)
        if (l.points.length > 1 && !isBoundaryName(l.name)) l,
    ];
    if (usable.isEmpty) {
      return TrailGraph._([], [], [], [], [], _Proj(0, 0));
    }
    var sLat = 0.0, sLng = 0.0, n = 0;
    for (final l in usable) {
      for (final p in l.points) {
        sLat += p.lat;
        sLng += p.lng;
        n++;
      }
    }
    final pj = _Proj(sLat / n, sLng / n);

    // Vertices per line: original points plus inserted junction points.
    final lx = [
      for (final l in usable) [for (final p in l.points) pj.x(p)],
    ];
    final ly = [
      for (final l in usable) [for (final p in l.points) pj.y(p)],
    ];

    // Segment grid.
    final cell = max(60.0, endSnapM * 2);
    final grid = <int, List<(int, int)>>{};
    int key(int cx, int cy) => cx * 1000003 + cy;
    for (var i = 0; i < usable.length; i++) {
      for (var j = 0; j + 1 < lx[i].length; j++) {
        final x0 = min(lx[i][j], lx[i][j + 1]) - endSnapM;
        final x1 = max(lx[i][j], lx[i][j + 1]) + endSnapM;
        final y0 = min(ly[i][j], ly[i][j + 1]) - endSnapM;
        final y1 = max(ly[i][j], ly[i][j + 1]) + endSnapM;
        for (var cx = (x0 / cell).floor(); cx <= (x1 / cell).floor(); cx++) {
          for (var cy = (y0 / cell).floor(); cy <= (y1 / cell).floor(); cy++) {
            grid.putIfAbsent(key(cx, cy), () => []).add((i, j));
          }
        }
      }
    }

    // Splits: segment -> [(t, x, y, tag)]; vertices with the same tag join.
    final splits = <(int, int), List<(double, double, double, int)>>{};
    final endTags = <(int, int), List<int>>{}; // (line, point) -> tags
    var tags = 0;
    final seen = <(int, int, int, int)>{};
    for (final segs in grid.values) {
      for (var a = 0; a < segs.length; a++) {
        for (var b = a + 1; b < segs.length; b++) {
          var (i1, j1) = segs[a];
          var (i2, j2) = segs[b];
          if (i1 > i2 || (i1 == i2 && j1 > j2)) {
            (i1, j1, i2, j2) = (i2, j2, i1, j1);
          }
          if (i1 == i2 && (j1 - j2).abs() <= 1) continue;
          if (!seen.add((i1, j1, i2, j2))) continue;
          final hit = _cross(
            lx[i1][j1],
            ly[i1][j1],
            lx[i1][j1 + 1],
            ly[i1][j1 + 1],
            lx[i2][j2],
            ly[i2][j2],
            lx[i2][j2 + 1],
            ly[i2][j2 + 1],
          );
          if (hit == null) continue;
          final (t, u, x, y) = hit;
          final tag = tags++;
          // On a vertex of a segment: tag that vertex, else split there.
          void put(int i, int j, double f) {
            if (f <= 1e-6) {
              endTags.putIfAbsent((i, j), () => []).add(tag);
            } else if (f >= 1 - 1e-6) {
              endTags.putIfAbsent((i, j + 1), () => []).add(tag);
            } else {
              splits.putIfAbsent((i, j), () => []).add((f, x, y, tag));
            }
          }

          put(i1, j1, t);
          put(i2, j2, u);
        }
      }
    }
    // Trail ends near another trail (or another part of the same one).
    for (var i = 0; i < usable.length; i++) {
      for (final j in {0, lx[i].length - 1}) {
        final px = lx[i][j], py = ly[i][j];
        final cands = grid[key((px / cell).floor(), (py / cell).floor())];
        if (cands == null) continue;
        (int, int, double, double, double)? best;
        var bestD = endSnapM;
        for (final (i2, j2) in cands) {
          if (i2 == i && (j2 - j).abs() <= 2 ||
              i2 == i && (j2 + 1 - j).abs() <= 2) {
            continue;
          }
          final (t, x, y, d) = _project(
            px,
            py,
            lx[i2][j2],
            ly[i2][j2],
            lx[i2][j2 + 1],
            ly[i2][j2 + 1],
          );
          if (d < bestD) {
            bestD = d;
            best = (i2, j2, t, x, y);
          }
        }
        if (best == null) continue;
        final (i2, j2, t, x, y) = best;
        if (t <= 1e-6 || t >= 1 - 1e-6) continue; // a vertex: merged below
        final tag = tags++;
        endTags.putIfAbsent((i, j), () => []).add(tag);
        splits.putIfAbsent((i2, j2), () => []).add((t, x, y, tag));
      }
    }

    // Expand every line into its vertex list.
    final vx = <double>[], vy = <double>[], ve = <double>[];
    final vLine = <int>[], vEnd = <bool>[];
    final lineVerts = <List<int>>[];
    final tagVerts = <int, List<int>>{};
    int addV(double x, double y, double e, int line, bool end, List<int>? tag) {
      vx.add(x);
      vy.add(y);
      ve.add(e);
      vLine.add(line);
      vEnd.add(end || tag != null);
      final v = vx.length - 1;
      for (final t in tag ?? const <int>[]) {
        tagVerts.putIfAbsent(t, () => []).add(v);
      }
      return v;
    }

    for (var i = 0; i < usable.length; i++) {
      final ids = <int>[];
      final m = lx[i].length;
      final el = usable[i].ele;
      double eAt(int j) => el == null || j >= el.length ? double.nan : el[j];
      for (var j = 0; j < m; j++) {
        final isEnd = j == 0 || j == m - 1;
        ids.add(addV(lx[i][j], ly[i][j], eAt(j), i, isEnd, endTags[(i, j)]));
        final sp = splits[(i, j)];
        if (sp != null && j + 1 < m) {
          sp.sort((a, b) => a.$1.compareTo(b.$1));
          for (final (t, x, y, tag) in sp) {
            final e = eAt(j) + (eAt(j + 1) - eAt(j)) * t;
            ids.add(addV(x, y, e, i, false, [tag]));
          }
        }
      }
      lineVerts.add(ids);
    }

    // Union-find: same tag; close vertices of different trails; ends.
    final parent = List<int>.generate(vx.length, (k) => k);
    int find(int a) {
      while (parent[a] != a) {
        parent[a] = parent[parent[a]];
        a = parent[a];
      }
      return a;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[max(ra, rb)] = min(ra, rb);
    }

    for (final vs in tagVerts.values) {
      for (var k = 1; k < vs.length; k++) {
        union(vs[0], vs[k]);
      }
    }
    final vg = <int, List<int>>{};
    final vc = max(joinM, endSnapM);
    for (var v = 0; v < vx.length; v++) {
      vg
          .putIfAbsent(
            key((vx[v] / vc).floor(), (vy[v] / vc).floor()),
            () => [],
          )
          .add(v);
    }
    for (var v = 0; v < vx.length; v++) {
      final cx = (vx[v] / vc).floor(), cy = (vy[v] / vc).floor();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (final w in vg[key(cx + dx, cy + dy)] ?? const <int>[]) {
            if (w <= v) continue;
            final d = sqrt(pow(vx[v] - vx[w], 2) + pow(vy[v] - vy[w], 2));
            final other = vLine[v] != vLine[w];
            final ends = vEnd[v] || vEnd[w];
            if ((other && d <= joinM) ||
                (ends && d <= (other ? endSnapM : joinM))) {
              // Same trail: only its ends join (a loop), never switchbacks.
              if (!other && !(vEnd[v] && vEnd[w])) continue;
              union(v, w);
            }
          }
        }
      }
    }

    // Nodes.
    final nodeOf = <int, int>{};
    final pos = <GeoPoint>[], ele = <double>[];
    final vNode = List<int>.filled(vx.length, 0);
    for (var v = 0; v < vx.length; v++) {
      final r = find(v);
      final id = nodeOf.putIfAbsent(r, () {
        pos.add(pj.back(vx[r], vy[r]));
        ele.add(ve[r]);
        return pos.length - 1;
      });
      vNode[v] = id;
      if (!ele[id].isFinite && ve[v].isFinite) ele[id] = ve[v];
    }
    final adj = List.generate(pos.length, (_) => <_Edge>[]);
    for (var i = 0; i < lineVerts.length; i++) {
      final ids = lineVerts[i];
      for (var k = 1; k < ids.length; k++) {
        final a = vNode[ids[k - 1]], b = vNode[ids[k]];
        if (a == b) continue;
        final m = distanceM(pos[a], pos[b]);
        if (adj[a].any((e) => e.to == b && e.m <= m)) continue;
        adj[a].add(_Edge(b, m, i));
        adj[b].add(_Edge(a, m, i));
      }
    }
    // Components; trail networks a short gap apart (a road bit missing
    // from the file) get an "off-trail link" across the gap.
    final linkLine = usable.length;
    var comp = _components(adj);
    if (bridgeM > 0) {
      final ng = <int, List<int>>{};
      final nx = [for (final p in pos) pj.x(p)];
      final ny = [for (final p in pos) pj.y(p)];
      for (var v = 0; v < pos.length; v++) {
        ng
            .putIfAbsent(
              key((nx[v] / bridgeM).floor(), (ny[v] / bridgeM).floor()),
              () => [],
            )
            .add(v);
      }
      for (var round = 0; round < 8; round++) {
        final best = <int, (int, int, double)>{};
        for (var v = 0; v < pos.length; v++) {
          final cx = (nx[v] / bridgeM).floor(), cy = (ny[v] / bridgeM).floor();
          for (var dx = -1; dx <= 1; dx++) {
            for (var dy = -1; dy <= 1; dy++) {
              for (final w in ng[key(cx + dx, cy + dy)] ?? const <int>[]) {
                if (comp[w] == comp[v]) continue;
                final d = sqrt(pow(nx[v] - nx[w], 2) + pow(ny[v] - ny[w], 2));
                if (d > bridgeM) continue;
                final b = best[comp[v]];
                if (b == null || d < b.$3) best[comp[v]] = (v, w, d);
              }
            }
          }
        }
        if (best.isEmpty) break;
        for (final (a, b, _) in best.values) {
          if (adj[a].any((e) => e.to == b)) continue;
          final m = distanceM(pos[a], pos[b]);
          adj[a].add(_Edge(b, m, linkLine));
          adj[b].add(_Edge(a, m, linkLine));
        }
        comp = _components(adj);
      }
    }
    return TrailGraph._(pos, ele, adj, comp, [
      for (final l in usable) l.name,
      'a short off-trail link',
    ], pj);
  }

  static List<int> _components(List<List<_Edge>> adj) {
    final comp = List<int>.filled(adj.length, -1);
    var c = 0;
    for (var s = 0; s < adj.length; s++) {
      if (comp[s] >= 0) continue;
      final stack = [s];
      comp[s] = c;
      while (stack.isNotEmpty) {
        final u = stack.removeLast();
        for (final e in adj[u]) {
          if (comp[e.to] < 0) {
            comp[e.to] = c;
            stack.add(e.to);
          }
        }
      }
      c++;
    }
    return comp;
  }

  /// Proper crossing of segments p1-p2 and p3-p4: (t, u, x, y).
  static (double, double, double, double)? _cross(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    double x4,
    double y4,
  ) {
    final d = (x2 - x1) * (y4 - y3) - (y2 - y1) * (x4 - x3);
    if (d.abs() < 1e-9) return null;
    final t = ((x3 - x1) * (y4 - y3) - (y3 - y1) * (x4 - x3)) / d;
    final u = ((x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1)) / d;
    // Ends included (a crossing exactly at a vertex); both at ends = the
    // lines just touch there (joined by distance anyway).
    const eps = 1e-9;
    if (t < -eps || t > 1 + eps || u < -eps || u > 1 + eps) return null;
    final tEnd = t <= 1e-6 || t >= 1 - 1e-6, uEnd = u <= 1e-6 || u >= 1 - 1e-6;
    if (tEnd && uEnd) return null;
    return (t, u, x1 + t * (x2 - x1), y1 + t * (y2 - y1));
  }

  /// Closest point to (px, py) on a-b: (t, x, y, distance).
  static (double, double, double, double) _project(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / l2;
    t = t.clamp(0.0, 1.0);
    final x = ax + t * dx, y = ay + t * dy;
    return (t, x, y, sqrt(pow(px - x, 2) + pow(py - y, 2)));
  }

  /// Nearest point of the network to [p] (optionally only in component
  /// [comp]), within [maxM].
  GraphSnap? snap(GeoPoint p, {int? comp, double maxM = 50000}) {
    if (isEmpty) return null;
    return _segs.nearest(_p.x(p), _p.y(p), comp: comp, maxM: maxM, at: p);
  }

  /// Shortest route along trails from [from] to [to]. The start snaps to
  /// the trail nearest to it that connects to the trail nearest [to].
  /// Null if there are no trails.
  TrailRoute? route(GeoPoint from, GeoPoint to) {
    // Trails that do not connect: use the network part that needs the
    // least walking off trail (near the target, or near you).
    final d1 = snap(to);
    if (d1 == null) return null;
    final s1 = snap(from, comp: _comp[d1.a]);
    final s2 = snap(from);
    final d2 = s2 == null ? null : snap(to, comp: _comp[s2.a]);
    final off1 = s1 == null ? double.infinity : s1.offM + d1.offM;
    final off2 = d2 == null ? double.infinity : s2!.offM + d2.offM;
    if (off1.isInfinite && off2.isInfinite) return null;
    final (s, d) = off1 <= off2 ? (s1!, d1) : (s2!, d2!);
    return _route(from, to, s, d);
  }

  TrailRoute? _route(GeoPoint from, GeoPoint to, GraphSnap s, GraphSnap d) {
    // Dijkstra from the start snap's two ends.
    final n = pos.length;
    final dist = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);
    final prevLine = List<int>.filled(n, -1);
    final heap = _Heap();
    final sa = distanceM(s.at, pos[s.a]), sb = distanceM(s.at, pos[s.b]);
    dist[s.a] = sa;
    dist[s.b] = min(dist[s.b], sb);
    heap.push(dist[s.a], s.a);
    heap.push(dist[s.b], s.b);
    final da = distanceM(d.at, pos[d.a]), db = distanceM(d.at, pos[d.b]);
    var best = double.infinity;
    var bestEnd = -1;
    final sameEdge = (s.a == d.a && s.b == d.b) || (s.a == d.b && s.b == d.a);
    if (sameEdge) {
      best = distanceM(s.at, d.at);
      bestEnd = -2;
    }
    while (heap.isNotEmpty) {
      final (du, u) = heap.pop();
      if (du > dist[u]) continue;
      if (du >= best) break;
      if (u == d.a && du + da < best) {
        best = du + da;
        bestEnd = u;
      }
      if (u == d.b && du + db < best) {
        best = du + db;
        bestEnd = u;
      }
      for (final e in _adj[u]) {
        final nd = du + e.m;
        if (nd < dist[e.to]) {
          dist[e.to] = nd;
          prev[e.to] = u;
          prevLine[e.to] = e.line;
          heap.push(nd, e.to);
        }
      }
    }
    if (bestEnd == -1) return null;
    final nodes = <int>[];
    for (var u = bestEnd; u >= 0; u = prev[u]) {
      nodes.add(u);
    }
    final path = nodes.reversed.toList();
    final pts = <GeoPoint>[from, s.at];
    final el = <double>[double.nan, _interp(s)];
    final lineAfter = <int>[-1, -1];
    for (var k = 0; k < path.length && bestEnd != -2; k++) {
      pts.add(pos[path[k]]);
      el.add(ele[path[k]]);
      lineAfter.add(k + 1 < path.length ? prevLine[path[k + 1]] : -1);
    }
    pts
      ..add(d.at)
      ..add(to);
    el
      ..add(_interp(d))
      ..add(double.nan);
    lineAfter
      ..add(-1)
      ..add(-1);
    // Drop zero-length steps (snap point on a node).
    final outP = <GeoPoint>[], outE = <double>[], outL = <int>[];
    final outNode = <int?>[];
    for (var k = 0; k < pts.length; k++) {
      final node = k >= 2 && k < pts.length - 2 && bestEnd != -2
          ? path[k - 2]
          : null;
      if (outP.isNotEmpty && distanceM(outP.last, pts[k]) < 0.5) {
        outNode[outNode.length - 1] ??= node;
        if (outL.last < 0) outL[outL.length - 1] = lineAfter[k];
        continue;
      }
      outP.add(pts[k]);
      outE.add(el[k]);
      outL.add(lineAfter[k]);
      outNode.add(node);
    }
    final r = TrailRoute(outP, outE, [], startOffM: s.offM, endOffM: d.offM);
    for (var k = 1; k + 1 < outP.length; k++) {
      final node = outNode[k];
      if (node == null) continue;
      var before = -1;
      for (var q = k - 1; q >= 0 && before < 0; q--) {
        before = outL[q];
      }
      final renamed =
          outL[k] >= 0 && before >= 0 && _names[outL[k]] != _names[before];
      if (degree(node) < 3 && !renamed) continue;
      final inB = bearingDeg(_back(r, k, 25), outP[k]);
      final outB = bearingDeg(outP[k], _ahead(r, k, 25));
      final t = deltaDeg(outB, inB);
      final turn = t.abs() < 25
          ? 'straight'
          : t.abs() > 120
          ? (t < 0 ? 'sharp left' : 'sharp right')
          : (t < 0 ? 'left' : 'right');
      final l = outL[k];
      // Staying on the same trail, straight on: not worth a call-out.
      if (turn == 'straight' &&
          l >= 0 &&
          before >= 0 &&
          _names[l] == _names[before]) {
        continue;
      }
      r.junctions.add(
        RouteJunction(k, r.cum[k], turn, l >= 0 ? _names[l] : ''),
      );
    }
    return r;
  }

  double _interp(GraphSnap s) {
    final a = ele[s.a], b = ele[s.b];
    if (a.isFinite && b.isFinite) return a + (b - a) * s.t;
    return a.isFinite ? a : b;
  }

  static GeoPoint _back(TrailRoute r, int k, double m) {
    var i = k - 1;
    while (i > 0 && r.cum[k] - r.cum[i] < m) {
      i--;
    }
    return r.points[max(0, i)];
  }

  static GeoPoint _ahead(TrailRoute r, int k, double m) {
    var i = k + 1;
    while (i < r.points.length - 1 && r.cum[i] - r.cum[k] < m) {
      i++;
    }
    return r.points[min(r.points.length - 1, i)];
  }
}

/// Edge grid for nearest-trail queries.
class _SegIndex {
  _SegIndex(this.g) {
    for (var a = 0; a < g.pos.length; a++) {
      for (final e in g._adj[a]) {
        if (e.to < a) continue;
        final x0 = min(_x(a), _x(e.to)), x1 = max(_x(a), _x(e.to));
        final y0 = min(_y(a), _y(e.to)), y1 = max(_y(a), _y(e.to));
        for (var cx = (x0 / cell).floor(); cx <= (x1 / cell).floor(); cx++) {
          for (var cy = (y0 / cell).floor(); cy <= (y1 / cell).floor(); cy++) {
            _grid.putIfAbsent(_k(cx, cy), () => []).add((a, e.to));
          }
        }
        maxCell = max(
          maxCell,
          max((x1 / cell).floor().abs(), (y1 / cell).floor().abs()),
        );
      }
    }
  }
  final TrailGraph g;
  static const cell = 200.0;
  final Map<int, List<(int, int)>> _grid = {};
  int maxCell = 0;
  int _k(int cx, int cy) => cx * 1000003 + cy;
  double _x(int n) => g._p.x(g.pos[n]);
  double _y(int n) => g._p.y(g.pos[n]);

  GraphSnap? nearest(
    double px,
    double py, {
    int? comp,
    required double maxM,
    required GeoPoint at,
  }) {
    final cx = (px / cell).floor(), cy = (py / cell).floor();
    GraphSnap? best;
    var bestD = double.infinity;
    final rings = (maxM / cell).ceil() + 1;
    for (var r = 0; r <= rings; r++) {
      if (best != null && (r - 1) * cell > bestD) break;
      for (var dx = -r; dx <= r; dx++) {
        for (var dy = -r; dy <= r; dy++) {
          if (max(dx.abs(), dy.abs()) != r) continue;
          for (final (a, b)
              in _grid[_k(cx + dx, cy + dy)] ?? const <(int, int)>[]) {
            if (comp != null && g._comp[a] != comp) continue;
            final (t, x, y, d) = TrailGraph._project(
              px,
              py,
              _x(a),
              _y(a),
              _x(b),
              _y(b),
            );
            if (d < bestD) {
              bestD = d;
              final p = g._p.back(x, y);
              best = GraphSnap(a, b, t, p, distanceM(at, p));
            }
          }
        }
      }
      // Far outside the network: stop when past every cell.
      if (r > maxCell + (max(cx.abs(), cy.abs()))) break;
    }
    return best != null && bestD <= maxM ? best : null;
  }
}

/// Minimal binary heap of (priority, node).
class _Heap {
  final _p = <double>[];
  final _v = <int>[];
  bool get isNotEmpty => _p.isNotEmpty;
  void push(double p, int v) {
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

  (double, int) pop() {
    final top = (_p[0], _v[0]);
    final last = _p.length - 1;
    _swap(0, last);
    _p.removeLast();
    _v.removeLast();
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
