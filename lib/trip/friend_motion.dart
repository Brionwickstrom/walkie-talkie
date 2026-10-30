import 'dart:math';

import 'geo.dart';

/// Where a friend probably is between two location updates (v2.5.6), how
/// sure that is, how faded their dot should be and how old the fix is.
///
/// Pure functions so they are easy to test. Nothing here talks to the
/// network or the GPS: it only turns the last fix plus its speed and
/// heading into a guess for the screen.

/// Below this speed (m/s, about 4.5 mph) a friend is treated as standing
/// still or walking: the dot stays where the fix is.
const double deadReckonMinSpeedMps = 2.0;

/// Fixes less sure than this (metres) are not extrapolated.
const double deadReckonMaxAccuracyM = 50;

/// The dot is moved ahead for at most this long after the fix was taken
/// (a bit over the 60 s a live update can be late), and at most this far.
const Duration deadReckonMaxAhead = Duration(seconds: 75);
const double deadReckonMaxDistanceM = 500;

/// The friend's place for drawing.
class FriendEstimate {
  const FriendEstimate({
    required this.pos,
    required this.radiusM,
    required this.projected,
    this.aheadM = 0,
    this.ahead = Duration.zero,
  });

  /// Where to draw the dot.
  final GeoPoint pos;

  /// Accuracy circle radius in metres (null accuracy = no circle, 0).
  final double radiusM;

  /// The dot was moved ahead of the last fix.
  final bool projected;
  final double aheadM;
  final Duration ahead;
}

/// The point [metres] from [from] along compass [bearing] (degrees).
GeoPoint movedBy(GeoPoint from, double bearing, double metres) {
  final d = metres / earthRadiusM;
  final b = bearing * pi / 180;
  final p1 = from.lat * pi / 180, l1 = from.lng * pi / 180;
  final p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b));
  final l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2));
  return GeoPoint(p2 * 180 / pi, normDeg(l2 * 180 / pi + 180) - 180);
}

/// Dead reckoning for one friend.
///
/// Moves [pos] along [headingDeg] at [speedMps] for the time since the fix
/// was taken ([at] to [now]), only when:
///  * speed and heading are known and the speed is [deadReckonMinSpeedMps]
///    or more (no guessing for people standing still or walking),
///  * the fix is accurate ([deadReckonMaxAccuracyM] or better, and known),
///  * the fix came straight from them (not held at base camp),
///  * it is not older than [deadReckonMaxAhead] (then the dot goes back to
///    the real last fix, which is all that is known),
///  * and the move is at most [deadReckonMaxDistanceM].
///
/// The accuracy circle grows a little with the guessed distance.
FriendEstimate estimateFriend({
  required GeoPoint pos,
  required DateTime at,
  required DateTime now,
  double? speedMps,
  double? headingDeg,
  double? accuracyM,
  bool held = false,
}) {
  final base = (accuracyM ?? 0).clamp(0, 3000).toDouble();
  final elapsed = now.difference(at);
  final s = speedMps;
  final h = headingDeg;
  final ok =
      !held &&
      s != null &&
      h != null &&
      s.isFinite &&
      h.isFinite &&
      s >= deadReckonMinSpeedMps &&
      accuracyM != null &&
      accuracyM <= deadReckonMaxAccuracyM &&
      !elapsed.isNegative &&
      elapsed.inMilliseconds > 500 &&
      elapsed <= deadReckonMaxAhead;
  if (!ok) {
    return FriendEstimate(pos: pos, radiusM: base, projected: false);
  }
  final dist = min(s * elapsed.inMilliseconds / 1000, deadReckonMaxDistanceM);
  return FriendEstimate(
    pos: movedBy(pos, h, dist),
    radiusM: base + 0.2 * dist,
    projected: true,
    aheadM: dist,
    ahead: elapsed,
  );
}

/// How solid a friend's dot is drawn, by how old the fix is: full for the
/// first 2 minutes, then fading to 45% at 30 minutes and staying there.
double friendOpacity(Duration age) {
  final m = age.inSeconds / 60;
  if (m <= 2) return 1;
  if (m >= 30) return 0.45;
  return 1 - 0.55 * (m - 2) / 28;
}

/// The real age of a fix: "3 s", "45 s", "2 min 5 s", "12 min", "3 h 5 min",
/// "2 d". Never "just now".
String exactAge(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (s < 60) return '$s s';
  if (s < 600) {
    final r = s % 60;
    return r == 0 ? '${s ~/ 60} min' : '${s ~/ 60} min $r s';
  }
  if (s < 3600) return '${s ~/ 60} min';
  final h = s ~/ 3600;
  if (s < 48 * 3600) {
    final m = (s % 3600) ~/ 60;
    return m == 0 ? '$h h' : '$h h $m min';
  }
  return '${s ~/ 86400} d';
}
