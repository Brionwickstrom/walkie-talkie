import 'drive/road_router.dart' show DriveRoute;
import 'geo.dart';
import 'nav/trail_graph.dart';
import 'search/trailhead_finder.dart';

/// What "Navigate here" decided (v2.1.0).
enum SmartKind {
  /// The place is on a road (or close): drive there.
  drive,

  /// Close by, or no road is needed: walk the whole way.
  hike,

  /// Drive to a trailhead, then walk.
  driveThenHike,

  /// A trailhead could not be found: ask which road end to use.
  needRoadEnd,

  /// Nothing could be planned (no signal and nothing saved, no GPS...).
  noRoute,
}

/// A planned trip, before it is started.
class SmartPlan {
  const SmartPlan(
    this.kind, {
    this.message = '',
    this.drive,
    this.hike,
    this.trailhead,
    this.roadEnd,
    this.roadEndOffM,
    this.driveNote = '',
    this.hikeNote = '',
    this.hikePending = false,
  });

  final SmartKind kind;

  /// Plain words about what happened (why no route, which server answered,
  /// that the trailhead lookup fell back to a backup).
  final String message;

  /// The driving leg (for [SmartKind.drive] / [SmartKind.driveThenHike]).
  final DriveRoute? drive;

  /// The walking leg: planned when possible, else null and [hikePending]
  /// (it is planned when you reach the trailhead).
  final TrailRoute? hike;

  /// Where to park: the trailhead the driving leg ends at.
  final TrailheadCandidate? trailhead;

  /// For [SmartKind.needRoadEnd]: the closest road end the router knows.
  final GeoPoint? roadEnd;
  final double? roadEndOffM;
  final String driveNote, hikeNote;
  final bool hikePending;

  bool get ok =>
      kind == SmartKind.drive ||
      kind == SmartKind.hike ||
      kind == SmartKind.driveThenHike;

  /// Distance and time of both legs together (null parts left out).
  ({double metres, Duration time}) get totals {
    var m = 0.0;
    var t = Duration.zero;
    final d = drive;
    if (d != null) {
      m += d.lengthM;
      t += d.duration;
    }
    final h = hike;
    if (h != null) {
      m += h.lengthM;
      t += naismith(h.lengthM, h.climb().gain);
    }
    return (metres: m, time: t);
  }
}

/// Shown when the drive reaches the trailhead: the walk starts by itself.
class TrailheadHandoff {
  TrailheadHandoff({
    required this.trailheadName,
    required this.targetName,
    required this.at,
    this.route,
    this.message = '',
  });

  final String trailheadName, targetName;
  final DateTime at;

  /// The walking route that was started (null: none could be made, the
  /// message says what to do).
  final TrailRoute? route;
  final String message;

  /// The handoff screen was shown.
  bool shown = false;
}
