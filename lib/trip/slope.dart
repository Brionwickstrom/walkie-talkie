import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Elevation (m) of a terrarium pixel: R*256 + G + B/256 - 32768.
double terrariumElevation(int r, int g, int b) => r * 256 + g + b / 256 - 32768;

/// Elevations of a terrarium PNG tile (row-major, [size] x [size]).
({Float32List h, int size})? decodeTerrarium(Uint8List png) {
  final im = img.decodePng(png);
  if (im == null || im.width != im.height) return null;
  final n = im.width;
  final h = Float32List(n * n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final p = im.getPixel(x, y);
      h[y * n + x] = terrariumElevation(p.r.toInt(), p.g.toInt(), p.b.toInt());
    }
  }
  return (h: h, size: n);
}

/// Ground size of one pixel (m) of a 256 px Web Mercator tile at [z], row
/// [y] (latitude of the tile middle).
double tilePixelMetres(int z, int y, {int size = 256}) {
  final n = 1 << z;
  final lat = atan(_sinh(pi * (1 - 2 * (y + 0.5) / n)));
  return 40075016.686 * cos(lat) / (n * size);
}

double _sinh(double x) => (exp(x) - exp(-x)) / 2;

/// Slope angle (degrees) at every pixel (Horn's method; edges clamped).
Float32List slopeDegrees(Float32List h, int n, double pixelM) {
  final out = Float32List(n * n);
  double at(int x, int y) => h[y.clamp(0, n - 1) * n + x.clamp(0, n - 1)];
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final a = at(x - 1, y - 1), b = at(x, y - 1), c = at(x + 1, y - 1);
      final d = at(x - 1, y), f = at(x + 1, y);
      final g = at(x - 1, y + 1), hh = at(x, y + 1), i = at(x + 1, y + 1);
      final dx = ((c + 2 * f + i) - (a + 2 * d + g)) / (8 * pixelM);
      final dy = ((g + 2 * hh + i) - (a + 2 * b + c)) / (8 * pixelM);
      out[y * n + x] = atan(sqrt(dx * dx + dy * dy)) * 180 / pi;
    }
  }
  return out;
}

/// Avalanche-angle colours (RGBA), transparent under 27 degrees.
List<int> slopeColor(double deg) {
  if (deg < 27) return const [0, 0, 0, 0];
  if (deg < 30) return const [247, 228, 0, 255]; // yellow
  if (deg < 35) return const [247, 148, 0, 255]; // orange
  if (deg < 45) return const [230, 0, 0, 255]; // red
  return const [150, 0, 200, 255]; // purple
}

/// Terrarium tile -> slope shading PNG (same size). Null if unreadable.
Uint8List? slopeTilePng(Uint8List terrariumPng, int z, int y) {
  final d = decodeTerrarium(terrariumPng);
  if (d == null) return null;
  final n = d.size;
  final s = slopeDegrees(d.h, n, tilePixelMetres(z, y, size: n));
  final out = img.Image(width: n, height: n, numChannels: 4);
  for (var py = 0; py < n; py++) {
    for (var px = 0; px < n; px++) {
      final c = slopeColor(s[py * n + px]);
      out.setPixelRgba(px, py, c[0], c[1], c[2], c[3]);
    }
  }
  return img.encodePng(out, level: 1);
}

/// Elevation at a point from terrarium tiles (bilinear).
class DemSampler {
  DemSampler(this.tile, {this.zoom = 12, this.keep = 24});

  /// Terrarium tile bytes (cached or downloaded), null if not available.
  final Future<Uint8List?> Function(int z, int x, int y) tile;
  final int zoom, keep;
  final Map<String, ({Float32List h, int size})?> _tiles = {};

  Future<double?> elevationAt(double lat, double lng) async {
    final n = 1 << zoom;
    final fx = (lng + 180) / 360 * n;
    final r = lat * pi / 180;
    final fy = (1 - log(tan(r) + 1 / cos(r)) / pi) / 2 * n;
    final tx = fx.floor(), ty = fy.floor();
    final key = '$tx/$ty';
    if (!_tiles.containsKey(key)) {
      Uint8List? b;
      try {
        b = await tile(zoom, tx, ty);
      } catch (_) {}
      if (_tiles.length >= keep) _tiles.remove(_tiles.keys.first);
      _tiles[key] = b == null ? null : decodeTerrarium(b);
    }
    final d = _tiles[key];
    if (d == null) return null;
    final s = d.size;
    final px = (fx - tx) * s - 0.5, py = (fy - ty) * s - 0.5;
    final x0 = px.floor().clamp(0, s - 1), y0 = py.floor().clamp(0, s - 1);
    final x1 = (x0 + 1).clamp(0, s - 1), y1 = (y0 + 1).clamp(0, s - 1);
    final ax = (px - x0).clamp(0.0, 1.0), ay = (py - y0).clamp(0.0, 1.0);
    double v(int x, int y) => d.h[y * s + x];
    final top = v(x0, y0) * (1 - ax) + v(x1, y0) * ax;
    final bot = v(x0, y1) * (1 - ax) + v(x1, y1) * ax;
    return top * (1 - ay) + bot * ay;
  }
}
