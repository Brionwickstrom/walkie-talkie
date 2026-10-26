import 'dart:math';

import '../geo.dart';

/// Spherical Web Mercator (EPSG:3857), the projection the map draws in, so
/// a straight-edged image placed here stays straight on screen.
const double _r = 6378137.0;

/// Mercator metres per ground metre at the equator (the app measures
/// ground distance on the mean-radius sphere, see [distanceM]).
const double _k0 = _r / earthRadiusM;

(double, double) toMercator(GeoPoint p) {
  final lat = p.lat.clamp(-85.05112878, 85.05112878);
  return (_r * p.lng * pi / 180, _r * log(tan(pi / 4 + lat * pi / 360)));
}

GeoPoint fromMercator(double x, double y) =>
    GeoPoint((2 * atan(exp(y / _r)) - pi / 2) * 180 / pi, x / _r * 180 / pi);

/// A pixel on the overlay image (u right, v down, in image pixels).
typedef ImagePx = ({double u, double v});

/// One control point: this pixel of the image lies at that place.
class ControlPoint {
  const ControlPoint(this.px, this.pos);
  final ImagePx px;
  final GeoPoint pos;
}

/// Image pixels -> map (Mercator metres) affine transform:
/// x = a·u + b·v + c, y = d·u + e·v + f.
class Georef {
  const Georef(this.a, this.b, this.c, this.d, this.e, this.f);
  final double a, b, c, d, e, f;

  GeoPoint toMap(ImagePx p) =>
      fromMercator(a * p.u + b * p.v + c, d * p.u + e * p.v + f);

  /// Map position -> image pixel (null if the transform is degenerate).
  ImagePx? toImage(GeoPoint g) {
    final det = a * e - b * d;
    if (det.abs() < 1e-12) return null;
    final (x, y) = toMercator(g);
    final dx = x - c, dy = y - f;
    return (u: (e * dx - b * dy) / det, v: (-d * dx + a * dy) / det);
  }

  bool get valid =>
      [a, b, c, d, e, f].every((x) => x.isFinite) && (a * e - b * d).abs() > 0;

  /// Ground metres per image pixel (geometric mean of both axes).
  double metresPerPixel(GeoPoint at) {
    final sx = sqrt(a * a + d * d), sy = sqrt(b * b + e * e);
    return sqrt(sx * sy) * cos(at.lat * pi / 180) / _k0;
  }

  /// Image rotation, degrees clockwise from north-up.
  double get rotationDeg => normDeg(-atan2(d, a) * 180 / pi);

  /// The three corners flutter_map's RotatedOverlayImage wants
  /// (top-left, bottom-left, bottom-right) plus top-right, for an image of
  /// [w] x [h] pixels.
  ({
    GeoPoint topLeft,
    GeoPoint topRight,
    GeoPoint bottomLeft,
    GeoPoint bottomRight,
  })
  corners(double w, double h) => (
    topLeft: toMap((u: 0, v: 0)),
    topRight: toMap((u: w, v: 0)),
    bottomLeft: toMap((u: 0, v: h)),
    bottomRight: toMap((u: w, v: h)),
  );

  Map<String, Object?> toJson() => {
    'm': [a, b, c, d, e, f],
  };

  static Georef? fromJson(Object? j) {
    if (j is! Map || j['m'] is! List) return null;
    final m = [for (final x in j['m'] as List) (x as num).toDouble()];
    if (m.length != 6) return null;
    final g = Georef(m[0], m[1], m[2], m[3], m[4], m[5]);
    return g.valid ? g : null;
  }

  /// Fit from 2 control points: scale + rotation + shift (no stretch or
  /// mirror). Null if the points coincide.
  static Georef? fromTwo(ControlPoint p1, ControlPoint p2) {
    // Complex numbers: z = u - i·v (flip v so north is up), w = x + i·y,
    // w = s·z + t.
    final (x1, y1) = toMercator(p1.pos);
    final (x2, y2) = toMercator(p2.pos);
    final zr = p2.px.u - p1.px.u, zi = -(p2.px.v - p1.px.v);
    final wr = x2 - x1, wi = y2 - y1;
    final den = zr * zr + zi * zi;
    if (den < 1e-9 || (wr * wr + wi * wi) < 1e-6) return null;
    final sr = (wr * zr + wi * zi) / den;
    final si = (wi * zr - wr * zi) / den;
    // x = sr·u + si·v + c ; y = si·u - sr·v + f
    final c = x1 - (sr * p1.px.u + si * p1.px.v);
    final f = y1 - (si * p1.px.u - sr * p1.px.v);
    return Georef(sr, si, c, si, -sr, f);
  }

  /// Exact affine fit from 3 control points (allows the stretch / skew of
  /// a scanned or not-to-scale map). Null if the points are in a line.
  static Georef? fromThree(ControlPoint p1, ControlPoint p2, ControlPoint p3) {
    final m = [
      [p1.px.u, p1.px.v, 1.0],
      [p2.px.u, p2.px.v, 1.0],
      [p3.px.u, p3.px.v, 1.0],
    ];
    final xs = [toMercator(p1.pos), toMercator(p2.pos), toMercator(p3.pos)];
    final det = _det3(m);
    // Relative to the triangle size so pixel units don't matter.
    final size = [
      for (final p in [p1, p2, p3]) p.px.u.abs() + p.px.v.abs(),
    ].reduce(max);
    if (det.abs() < 1e-6 * max(1.0, size * size)) return null;
    final abc = _solve3(m, [for (final p in xs) p.$1], det);
    final def = _solve3(m, [for (final p in xs) p.$2], det);
    final g = Georef(abc[0], abc[1], abc[2], def[0], def[1], def[2]);
    return g.valid ? g : null;
  }

  /// From 2 or 3 control points.
  static Georef? fromControlPoints(List<ControlPoint> pts) =>
      switch (pts.length) {
        2 => fromTwo(pts[0], pts[1]),
        >= 3 => fromThree(pts[0], pts[1], pts[2]),
        _ => null,
      };

  /// Corner fit: image of [w] x [h] px centred on [center], [widthM] ground
  /// metres across, rotated [rotationDeg] clockwise.
  static Georef fit({
    required GeoPoint center,
    required double widthM,
    required double rotationDeg,
    required double w,
    required double h,
  }) {
    // Ground metres -> Mercator metres grows with 1/cos(lat).
    final k = widthM * _k0 / w / cos(center.lat * pi / 180);
    final t = rotationDeg * pi / 180;
    final (cx, cy) = toMercator(center);
    // Clockwise rotation (y up): image right -> (cos t, -sin t),
    // image down -> (-sin t, -cos t).
    final g0 = Georef(k * cos(t), -k * sin(t), 0, -k * sin(t), -k * cos(t), 0);
    // Shift so the image centre lands on [center].
    final mx = g0.a * w / 2 + g0.b * h / 2;
    final my = g0.d * w / 2 + g0.e * h / 2;
    return Georef(g0.a, g0.b, cx - mx, g0.d, g0.e, cy - my);
  }
}

double _det3(List<List<double>> m) =>
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
    m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
    m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);

/// Cramer's rule.
List<double> _solve3(List<List<double>> m, List<double> r, double det) {
  List<List<double>> col(int i) => [
    for (var row = 0; row < 3; row++)
      [for (var c = 0; c < 3; c++) c == i ? r[row] : m[row][c]],
  ];
  return [for (var i = 0; i < 3; i++) _det3(col(i)) / det];
}
