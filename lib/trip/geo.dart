import 'dart:math';

/// Small geo helpers for the Trip tab (no map package needed, testable).
class GeoPoint {
  const GeoPoint(this.lat, this.lng);
  final double lat;
  final double lng;

  /// Fixed point (1e-5 degree, about 1.1 m) used on the wire.
  int get latE5 => (lat * 1e5).round();
  int get lngE5 => (lng * 1e5).round();
  static GeoPoint fromE5(int lat, int lng) => GeoPoint(lat / 1e5, lng / 1e5);

  bool get valid =>
      lat.isFinite &&
      lng.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lng >= -180 &&
      lng <= 180;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;
  @override
  int get hashCode => Object.hash(lat, lng);
  @override
  String toString() => '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
}

const double earthRadiusM = 6371008.8;
double _rad(double d) => d * pi / 180;
double _deg(double r) => r * 180 / pi;

/// Great-circle distance in metres (haversine).
double distanceM(GeoPoint a, GeoPoint b) {
  final dLat = _rad(b.lat - a.lat);
  final dLng = _rad(b.lng - a.lng);
  final h =
      pow(sin(dLat / 2), 2) +
      cos(_rad(a.lat)) * cos(_rad(b.lat)) * pow(sin(dLng / 2), 2);
  return 2 * earthRadiusM * asin(min(1.0, sqrt(h.toDouble())));
}

/// Initial bearing from [a] to [b], degrees clockwise from true north
/// (0..360).
double bearingDeg(GeoPoint a, GeoPoint b) {
  final p1 = _rad(a.lat), p2 = _rad(b.lat);
  final dl = _rad(b.lng - a.lng);
  final y = sin(dl) * cos(p2);
  final x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl);
  return normDeg(_deg(atan2(y, x)));
}

double normDeg(double d) {
  final r = d % 360;
  return r < 0 ? r + 360 : r;
}

/// Signed smallest difference a - b in degrees (-180..180].
double deltaDeg(double a, double b) {
  var d = normDeg(a - b);
  if (d > 180) d -= 360;
  return d;
}

const _points8 = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];

/// 8-point compass name for a bearing.
String cardinal(double bearing) =>
    _points8[((normDeg(bearing) + 22.5) ~/ 45) % 8];

/// "north", "southwest" (for speech).
String cardinalWord(double bearing) => const {
  'N': 'north',
  'NE': 'northeast',
  'E': 'east',
  'SE': 'southeast',
  'S': 'south',
  'SW': 'southwest',
  'W': 'west',
  'NW': 'northwest',
}[cardinal(bearing)]!;

/// "0.8 mi", "350 ft", "1.2 km", "80 m".
String formatDistance(double metres, {bool imperial = true}) {
  if (imperial) {
    final feet = metres * 3.28084;
    if (feet < 1000) return '${(feet / 10).round() * 10} ft';
    final mi = metres / 1609.344;
    return mi < 10 ? '${mi.toStringAsFixed(1)} mi' : '${mi.round()} mi';
  }
  if (metres < 1000) return '${(metres / 5).round() * 5} m';
  final km = metres / 1000;
  return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
}

/// "0.8 mi NE".
String formatDistanceBearing(
  GeoPoint from,
  GeoPoint to, {
  bool imperial = true,
}) =>
    '${formatDistance(distanceM(from, to), imperial: imperial)} '
    '${cardinal(bearingDeg(from, to))}';

/// Angle to draw an arrow pointing at [target] on a screen whose top faces
/// [heading] (compass, degrees). Null heading = north up.
double arrowAngleDeg(double bearing, double? heading) =>
    normDeg(bearing - (heading ?? 0));

/// "just now", "45 s", "12 min", "3 h", "2 d".
String formatAge(Duration d) {
  if (d.isNegative || d.inSeconds < 10) return 'just now';
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} d';
}

/// Length of a polyline in metres.
double pathLengthM(List<GeoPoint> pts) {
  var s = 0.0;
  for (var i = 1; i < pts.length; i++) {
    s += distanceM(pts[i - 1], pts[i]);
  }
  return s;
}

/// Ramer-Douglas-Peucker simplification with tolerance [epsM] metres
/// (local equirectangular projection; fine for trail-sized tracks).
List<T> simplify<T>(List<T> pts, GeoPoint Function(T) at, double epsM) {
  if (pts.length < 3) return List.of(pts);
  final ref = at(pts.first);
  final kx = cos(_rad(ref.lat)) * earthRadiusM * pi / 180;
  const ky = earthRadiusM * pi / 180;
  final xy = [for (final p in pts) (at(p).lng * kx, at(p).lat * ky)];
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = keep[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (s, e) = stack.removeLast();
    if (e <= s + 1) continue;
    final (x1, y1) = xy[s];
    final (x2, y2) = xy[e];
    final dx = x2 - x1, dy = y2 - y1;
    final len2 = dx * dx + dy * dy;
    var best = -1.0;
    var idx = -1;
    for (var i = s + 1; i < e; i++) {
      final (x, y) = xy[i];
      double d;
      if (len2 == 0) {
        d = sqrt(pow(x - x1, 2) + pow(y - y1, 2));
      } else {
        final t = (((x - x1) * dx + (y - y1) * dy) / len2).clamp(0.0, 1.0);
        d = sqrt(pow(x - (x1 + t * dx), 2) + pow(y - (y1 + t * dy), 2));
      }
      if (d > best) {
        best = d;
        idx = i;
      }
    }
    if (best > epsM) {
      keep[idx] = true;
      stack
        ..add((s, idx))
        ..add((idx, e));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

/// Simplify until at most [maxPoints] remain (doubling the tolerance).
List<T> thinTo<T>(List<T> pts, GeoPoint Function(T) at, int maxPoints) {
  if (pts.length <= maxPoints) return List.of(pts);
  var eps = 5.0;
  var out = simplify(pts, at, eps);
  while (out.length > maxPoints && eps < 1e6) {
    eps *= 2;
    out = simplify(pts, at, eps);
  }
  if (out.length > maxPoints) {
    // Degenerate input: keep evenly spaced points incl. both ends.
    final step = (out.length - 1) / (maxPoints - 1);
    out = [for (var i = 0; i < maxPoints; i++) out[(i * step).round()]];
  }
  return out;
}

/// Tilt-compensated compass heading (degrees from magnetic north, 0..360)
/// from an accelerometer (gravity) and magnetometer reading in the phone's
/// axes, same maths as Android's SensorManager.getRotationMatrix +
/// getOrientation. Null if the readings are degenerate (free fall, magnet).
double? headingFromSensors(
  double ax,
  double ay,
  double az,
  double ex,
  double ey,
  double ez,
) {
  // H = E x A (east), M = A x H (north).
  var hx = ey * az - ez * ay;
  var hy = ez * ax - ex * az;
  var hz = ex * ay - ey * ax;
  final normH = sqrt(hx * hx + hy * hy + hz * hz);
  if (normH < 0.1) return null;
  final normA = sqrt(ax * ax + ay * ay + az * az);
  if (normA < 0.1) return null;
  hx /= normH;
  hy /= normH;
  hz /= normH;
  final nax = ax / normA, naz = az / normA;
  final my = naz * hx - nax * hz;
  // Azimuth = atan2(Hy, My).
  return normDeg(_deg(atan2(hy, my)));
}

/// Low-pass filter for angles (handles the 359 -> 0 wrap).
double smoothAngle(double? prev, double next, double alpha) {
  if (prev == null) return normDeg(next);
  return normDeg(prev + deltaDeg(next, prev) * alpha);
}

/// Sunrise / sunset (UTC) for [date] at [p], NOAA algorithm. Either is null
/// on polar day / night. Used offline when the cached forecast is old.
({DateTime? sunrise, DateTime? sunset}) sunTimes(DateTime date, GeoPoint p) {
  final day = DateTime.utc(date.year, date.month, date.day);
  final n = day.difference(DateTime.utc(date.year, 1, 1)).inDays + 1;
  final lngHour = p.lng / 15;
  DateTime? calc(bool rise) {
    final t = n + ((rise ? 6 : 18) - lngHour) / 24;
    final m = 0.9856 * t - 3.289;
    var l = m + 1.916 * sin(_rad(m)) + 0.020 * sin(_rad(2 * m)) + 282.634;
    l = normDeg(l);
    var ra = normDeg(_deg(atan(0.91764 * tan(_rad(l)))));
    final lQuad = (l / 90).floor() * 90;
    final raQuad = (ra / 90).floor() * 90;
    ra = (ra + (lQuad - raQuad)) / 15;
    final sinDec = 0.39782 * sin(_rad(l));
    final cosDec = cos(asin(sinDec));
    final cosH =
        (cos(_rad(90.833)) - sinDec * sin(_rad(p.lat))) /
        (cosDec * cos(_rad(p.lat)));
    if (cosH > 1 || cosH < -1) return null;
    final h = (rise ? 360 - _deg(acos(cosH)) : _deg(acos(cosH))) / 15;
    final localT = h + ra - 0.06571 * t - 6.622;
    var ut = (localT - lngHour) % 24;
    if (ut < 0) ut += 24;
    var r = day.add(Duration(seconds: (ut * 3600).round()));
    // Keep the event within 12 h of local solar noon (UT wraps).
    final noon = day.add(Duration(seconds: ((12 - lngHour) * 3600).round()));
    if (r.difference(noon).inHours > 12) {
      r = r.subtract(const Duration(days: 1));
    }
    if (r.difference(noon).inHours < -12) r = r.add(const Duration(days: 1));
    return r;
  }

  return (sunrise: calc(true), sunset: calc(false));
}
