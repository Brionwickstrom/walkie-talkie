// Live: every map style / overlay URL returns real tiles (LIVE_MAPS=1).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:walkie_talkie/trip/fires.dart';
import 'package:walkie_talkie/trip/slope.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';

Future<(int, Uint8List)> get(String url) async {
  final c = HttpClient()..userAgent = 'WalkieTalkie test';
  try {
    final res = await (await c.getUrl(Uri.parse(url))).close();
    final b = BytesBuilder();
    await for (final x in res) {
      b.add(x);
    }
    return (res.statusCode, b.takeBytes());
  } finally {
    c.close(force: true);
  }
}

void main() {
  final live = Platform.environment['LIVE_MAPS'] == '1';
  // Silver Star Mountain, WA.
  const lat = 45.7486, lng = -122.2400;
  test(
    'all sources return images',
    () async {
      for (final s in [
        ...MapSource.bases,
        ...MapSource.overlays.where((o) => o.urlTemplate.startsWith('http')),
        MapSource.terrarium,
      ]) {
        final z = s.maxZoom.clamp(0, 14);
        final url = s.urlFor(z, tileX(lng, z), tileY(lat, z));
        final (code, bytes) = await get(url);
        final im = img.decodeImage(bytes);
        // ignore: avoid_print
        print(
          '${s.id} z$z: HTTP $code ${bytes.length} B ${im?.width}x${im?.height}',
        );
        expect(code, 200, reason: url);
        expect(im, isNotNull, reason: url);
        expect(im!.width, 256, reason: url);
      }
      final (_, dem) = await get(
        MapSource.terrarium.urlFor(14, tileX(lng, 14), tileY(lat, 14)),
      );
      expect(slopeTilePng(dem, 14, tileY(lat, 14)), isNotNull);
      final fires = await FireService().inArea(
        const GeoBounds(32, -125, 49, -102),
      );
      // ignore: avoid_print
      print('fires in the West now: ${fires.length}');
      expect(fires, isA<List<FirePerimeter>>());
    },
    skip: live ? false : 'set LIVE_MAPS=1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
