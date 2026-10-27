import 'package:flutter/foundation.dart';

import '../geo.dart';
import '../imports/geo_import.dart';
import 'drive_nav.dart';
import 'road_router.dart';

/// "Drive here" in progress (v1.9.2).
class DriveSession extends ChangeNotifier {
  DriveSession({
    required this.target,
    required this.name,
    required this.route,
    required bool imperial,
    this.hikeTo,
    this.hikeName = '',
  }) : follower = DriveFollower(route),
       voice = VoicePrompter(imperial: imperial);

  final GeoPoint target;
  final String name;
  DriveRoute route;
  final DriveFollower follower;
  final VoicePrompter voice;

  /// "Drive to trailhead, then hike": where to walk to after arriving.
  final GeoPoint? hikeTo;
  final String hikeName;

  DriveState? state;
  GeoPoint? me;

  /// Direction of travel from GPS (degrees), null until moving.
  double? course;
  double speedMps = 0;
  bool rerouting = false;
  bool arrived = false;
  int _seenOff = 0;
  GeoPoint? _last;
  DateTime? _lastAt;

  /// New fix: what happened ('off' / 'arrived' / null) and what to say.
  ({String? event, String? say}) update(
    GeoPoint p, {
    double? speed,
    DateTime? at,
  }) {
    final prev = _last;
    if (prev == null || distanceM(prev, p) >= 8) {
      if (prev != null) {
        course = bearingDeg(prev, p);
        final dt = at != null && _lastAt != null
            ? at.difference(_lastAt!).inMilliseconds / 1000
            : 0.0;
        if (speed == null && dt > 0) speedMps = distanceM(prev, p) / dt;
      }
      _last = p;
      _lastAt = at;
    }
    if (speed != null && speed >= 0) speedMps = speed;
    me = p;
    final s = state = follower.update(p);
    String? event;
    if (follower.offEvents > _seenOff) {
      _seenOff = follower.offEvents;
      event = 'off';
    }
    if (s.arrived && !arrived) {
      arrived = true;
      event = 'arrived';
    }
    final say = voice.next(route, s, speedMps: speedMps);
    notifyListeners();
    return (event: event, say: say);
  }

  void replaceRoute(DriveRoute r) {
    route = r;
    follower.replace(r);
    voice.reset();
    rerouting = false;
    if (me != null) state = follower.update(me!);
    notifyListeners();
  }

  /// The route as trail data (to share like a trail).
  ImportedData asData() => ImportedData(
    name: 'Drive to $name',
    lines: [ImportedLine('Drive to $name', route.points, isRoute: true)],
    waypoints: [ImportedWaypoint(name, target)],
  );
}
