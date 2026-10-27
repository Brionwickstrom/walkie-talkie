import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../geo.dart';
import '../imports/geo_import.dart';
import '../imports/map_layers.dart';
import '../slope.dart';
import 'navigator.dart';
import 'trail_graph.dart';

/// The trail lines on the phone (visible trail layers) for the graph.
List<GraphLine> graphLinesOf(MapLayers layers) => [
  for (final l in layers.trails)
    if (l.visible && l.data != null)
      for (final line in l.data!.lines)
        if (line.points.length > 1)
          GraphLine(
            line.name.isNotEmpty ? line.name : l.name,
            line.points,
            line.ele,
          ),
];

/// "Navigate here" (v1.9.1): a route along trails to [target] (or a
/// straight compass line when there is no trail), followed with GPS.
class NavSession extends ChangeNotifier {
  NavSession({
    required this.target,
    required this.name,
    this.route,
    this.note = '',
    double offRouteM = 40,
  }) : follower = route == null
           ? null
           : RouteFollower(route, offRouteM: offRouteM);

  final GeoPoint target;
  final String name;

  /// Null = compass mode (straight line).
  TrailRoute? route;
  final RouteFollower? follower;

  /// Why compass mode / how the route was made ("No trails here").
  String note;

  NavState? state;
  GeoPoint? me;
  int _seenOff = 0;
  bool _arrivedSaid = false;

  bool get compass => route == null;

  /// Straight-line distance and bearing to the target.
  double? get straightM => me == null ? null : distanceM(me!, target);
  double? get straightBearing => me == null ? null : bearingDeg(me!, target);

  /// New fix. Returns 'off' when we just went off route, 'arrived' when
  /// we just got there, else null.
  String? update(GeoPoint p) {
    me = p;
    String? event;
    final f = follower;
    if (f != null) {
      state = f.update(p);
      if (f.offEvents > _seenOff) {
        _seenOff = f.offEvents;
        event = 'off';
      }
      if (state!.arrived && !_arrivedSaid) {
        _arrivedSaid = true;
        event = 'arrived';
      }
    } else if (distanceM(p, target) <= 25 && !_arrivedSaid) {
      _arrivedSaid = true;
      event = 'arrived';
    }
    notifyListeners();
    return event;
  }

  void replaceRoute(TrailRoute r) {
    route = r;
    follower?.replace(r);
    state = me == null ? null : follower?.update(me!);
    notifyListeners();
  }

  /// The planned route as trail data (to share with the group).
  ImportedData asData() => ImportedData(
    name: 'Route to $name',
    lines: [
      ImportedLine(
        'Route to $name',
        route?.points ?? [?me, target],
        isRoute: true,
      ),
    ],
    waypoints: [ImportedWaypoint(name, target)],
  );
}

/// Builds the trail graph off the UI thread and caches it until the trail
/// layers change.
class GraphCache {
  String _key = '';
  TrailGraph? _g;

  Future<TrailGraph> of(MapLayers layers) async {
    final lines = graphLinesOf(layers);
    final key = [
      for (final l in layers.trails)
        if (l.visible) '${l.id}:${l.bytes}',
    ].join(',');
    if (_g != null && key == _key) return _g!;
    final g = lines.fold<int>(0, (s, l) => s + l.points.length) > 3000
        ? await Isolate.run(() => TrailGraph.build(lines))
        : TrailGraph.build(lines);
    _key = key;
    return _g = g;
  }
}

/// Fill [r]'s elevations from the DEM where tiles are available (cached
/// offline, or downloaded when online); GPX elevations stay where the DEM
/// has nothing. Returns where they came from: 'dem', 'gpx' or ''.
Future<String> fillElevation(
  TrailRoute r,
  Future<Uint8List?> Function(int z, int x, int y) demTile,
) async {
  final dem = DemSampler(demTile);
  final out = List<double>.of(r.ele);
  var got = 0;
  var lastM = -1e9;
  double? lastE;
  for (var i = 0; i < r.points.length; i++) {
    // Sample about every 20 m (and always the ends).
    if (r.cum[i] - lastM < 20 && i != r.points.length - 1 && lastE != null) {
      out[i] = r.ele[i].isFinite ? r.ele[i] : double.nan;
      continue;
    }
    final e = await dem.elevationAt(r.points[i].lat, r.points[i].lng);
    if (e != null && e > -500 && e < 9000) {
      out[i] = e;
      got++;
      lastM = r.cum[i];
      lastE = e;
    }
  }
  if (got >= 2) {
    // Points skipped between samples: linear between DEM samples.
    final known = [
      for (var i = 0; i < out.length; i++)
        if (out[i].isFinite) i,
    ];
    for (var k = 0; k + 1 < known.length; k++) {
      final a = known[k], b = known[k + 1];
      for (var i = a + 1; i < b; i++) {
        final t = (r.cum[i] - r.cum[a]) / max(1e-9, r.cum[b] - r.cum[a]);
        out[i] = out[a] + (out[b] - out[a]) * t;
      }
    }
    r.ele = out;
    return 'dem';
  }
  return r.hasElevation ? 'gpx' : '';
}
