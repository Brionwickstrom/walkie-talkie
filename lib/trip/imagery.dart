import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Newer satellite photos (v2.5.5): which photo source covers a place, and
/// the small helpers around it.

/// Oregon's outline (lng, lat), a little rough on purpose: the photo
/// service answers with an empty tile outside its own coverage and the app
/// then takes the nationwide photos instead.
const List<(double, double)> oregonOutline = [
  (-123.95, 46.20),
  (-123.20, 46.15),
  (-122.95, 46.10),
  (-122.77, 45.65),
  (-122.40, 45.60),
  (-121.50, 45.70),
  (-120.50, 45.72),
  (-119.60, 45.93),
  (-119.00, 45.93),
  (-118.98, 46.00),
  (-116.92, 46.00),
  (-116.70, 45.80),
  (-116.46, 45.58),
  (-116.56, 45.30),
  (-116.78, 45.00),
  (-116.90, 44.50),
  (-116.93, 44.05),
  (-117.03, 43.80),
  (-117.03, 42.00),
  (-124.15, 42.00),
  (-124.55, 42.84),
  (-124.15, 43.70),
  (-124.05, 44.60),
  (-123.95, 45.60),
];

/// [lat], [lng] inside the (rough) outline of Oregon.
bool inOregon(double lat, double lng) {
  var inside = false;
  final n = oregonOutline.length;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final (xi, yi) = oregonOutline[i];
    final (xj, yj) = oregonOutline[j];
    if ((yi > lat) != (yj > lat) &&
        lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Latitude / longitude of the middle of tile [z]/[x]/[y].
(double lat, double lng) tileCenterLatLng(int z, int x, int y) {
  final n = 1 << z;
  final lng = (x + 0.5) / n * 360 - 180;
  final lat =
      atan(
        (exp(pi * (1 - 2 * (y + 0.5) / n)) -
                exp(-pi * (1 - 2 * (y + 0.5) / n))) /
            2,
      ) *
      180 /
      pi;
  return (lat, lng);
}

/// A real photo tile (JPEG). The image services answer with a small empty
/// PNG where they have no photos.
bool isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

/// A 256 x 256 PNG made from one part of [parent] (a tile [shift] zoom
/// levels up): the quarter (shift 1) or sixteenth (shift 2) at ([dx], [dy])
/// scaled up. Used for zoom 17 and 18 where only the zoom 16 USGS photos
/// exist, and for zoom 18 outside downloaded areas.
Future<Uint8List> cropTileUp(
  Uint8List parent,
  int shift,
  int dx,
  int dy,
) async {
  final codec = await ui.instantiateImageCodec(parent);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  try {
    final parts = 1 << shift;
    final w = img.width / parts, h = img.height / parts;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH(dx * w, dy * h, w, h),
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final out = await rec.endRecording().toImage(256, 256);
    try {
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    } finally {
      out.dispose();
    }
  } finally {
    img.dispose();
    codec.dispose();
  }
}

/// What the "Photos: ..." line on the satellite map says.
String photoDateText({
  required bool oregon,
  int? naipYear,
  bool offline = false,
}) {
  if (offline) return 'Photos: as saved on this phone';
  if (oregon) return 'Photos: summer 2024 (Oregon)';
  if (naipYear != null) return 'Photos: $naipYear (NAIP)';
  return 'Photos: about 2022 (NAIP)';
}

/// The year of the NAIP photos at a place, asked once per ~0.5 degree cell
/// of the USGS image service (one small request, never repeated for a cell
/// that was asked). Null when it cannot be told.
class NaipYears {
  NaipYears({Future<String?> Function(Uri url)? get, this.base = _base})
    : _get = get ?? _fetch;

  static const _base =
      'https://imagery.nationalmap.gov/arcgis/rest/services/'
      'USGSNAIPImagery/ImageServer/identify';

  final String base;
  final Future<String?> Function(Uri url) _get;
  final Map<String, int?> _cells = {};
  final Set<String> _asking = {};

  static String cellKey(double lat, double lng) =>
      '${(lat * 2).floor()},${(lng * 2).floor()}';

  /// Known year for the cell of ([lat], [lng]), without asking.
  int? known(double lat, double lng) => _cells[cellKey(lat, lng)];

  /// The year, asking the service when the cell is new. A failed ask is
  /// tried again at most once more (later).
  Future<int?> year(double lat, double lng) async {
    final k = cellKey(lat, lng);
    if (_cells.containsKey(k)) return _cells[k];
    if (!_asking.add(k)) return null;
    try {
      final geom = jsonEncode({
        'x': lng,
        'y': lat,
        'spatialReference': {'wkid': 4326},
      });
      final url = Uri.parse(
        '$base?geometry=${Uri.encodeComponent(geom)}'
        '&geometryType=esriGeometryPoint&returnGeometry=false'
        '&returnCatalogItems=true&returnPixelValues=false&f=json',
      );
      final body = await _get(url);
      final y = body == null ? null : parseYear(body);
      if (body != null) _cells[k] = y;
      return y;
    } catch (_) {
      return null;
    } finally {
      _asking.remove(k);
    }
  }

  /// The photo year in an identify answer: the newest real photo
  /// (category 1) of the pixel, from its Year or the date in its name.
  static int? parseYear(String body) {
    try {
      final j = jsonDecode(body);
      final items = (j as Map)['catalogItems']?['features'];
      if (items is! List) return null;
      int? best;
      for (final f in items) {
        final a = (f as Map)['attributes'];
        if (a is! Map || a['Category'] != 1) continue;
        var y = a['Year'] is num ? (a['Year'] as num).toInt() : null;
        if (y == null) {
          final m = RegExp(r'_(\d{4})\d{4}$').firstMatch('${a['Name']}');
          y = m == null ? null : int.parse(m.group(1)!);
        }
        if (y != null && y > 1990 && y < 2100 && (best == null || y > best)) {
          best = y;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _fetch(Uri url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await c.getUrl(url);
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      return await res.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }
}
