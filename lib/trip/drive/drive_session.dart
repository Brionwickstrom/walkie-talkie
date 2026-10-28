import 'package:flutter/foundation.dart';

import '../geo.dart';
import '../imports/geo_import.dart';
import '../nav/trail_graph.dart';
import 'drive_nav.dart';
import 'road_router.dart';

/// "Drive here" in progress (v1.9.2).
class DriveSession extends ChangeNotifier {
  DriveSession({
    required this.target,
    required this.name,
    required this.route,
    required this.imperial,
    this.hikeTo,
    this.hikeName = '',
  }) : follower = DriveFollower(route),
       voice = VoicePrompter(imperial: imperial);

  final GeoPoint target;
  final String name;
  final bool imperial;
  DriveRoute route;
  final DriveFollower follower;
  final VoicePrompter voice;

  /// "Drive to trailhead, then hike": where to walk to after arriving.
  final GeoPoint? hikeTo;
  final String hikeName;

  /// v2.1.0: the walking leg planned ahead (shown on the map and in the
  /// combined distance and time). Null when it is planned on arrival.
  TrailRoute? hikePreview;
  String hikeNote = '';

  DriveState? state;
  GeoPoint? me;

  /// Direction of travel from GPS (degrees), null until moving.
  double? course;
  double speedMps = 0;
  bool rerouting = false;
  bool arrived = false;

  /// Something to tell the driver about the route (v1.9.3): why it is the
  /// offline one, or that a re-route was not possible.
  String notice = '';

  /// [notice] was spoken.
  String spokenNotice = '';

  /// "Online route" / "Offline route".
  String get sourceLabel => route.isOnline
      ? 'Online route'
      : route.isSaved
      ? 'Saved route'
      : 'Offline route';

  /// v2.2.0: following the route saved for offline because no new one
  /// could be made (so it is not tried again until the signal is back).
  bool savedFallback = false;
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

  /// Kept on the phone while driving (v1.9.3): guidance carries on after
  /// the signal drops, and after an app restart.
  Map<String, Object?> toJson(DateTime at) => {
    'at': at.millisecondsSinceEpoch,
    'to': [target.lat, target.lng],
    'n': name,
    if (hikeTo != null) 'h': [hikeTo!.lat, hikeTo!.lng],
    if (hikeName.isNotEmpty) 'hn': hikeName,
    'r': route.toJson(),
  };

  static ({DriveSession session, DateTime at})? fromJson(
    Object? j, {
    required bool imperial,
  }) {
    if (j is! Map) return null;
    try {
      GeoPoint pt(Object? o) => GeoPoint(
        ((o as List)[0] as num).toDouble(),
        (o[1] as num).toDouble(),
      );
      final r = DriveRoute.fromJson(j['r']);
      if (r == null) return null;
      return (
        session: DriveSession(
          target: pt(j['to']),
          name: (j['n'] as String?) ?? 'Destination',
          route: r,
          imperial: imperial,
          hikeTo: j['h'] == null ? null : pt(j['h']),
          hikeName: (j['hn'] as String?) ?? '',
        ),
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }

  /// The route as trail data (to share like a trail).
  ImportedData asData() => ImportedData(
    name: 'Drive to $name',
    lines: [ImportedLine('Drive to $name', route.points, isRoute: true)],
    waypoints: [ImportedWaypoint(name, target)],
  );
}
