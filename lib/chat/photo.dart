import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A photo ready to send: the JPEG (at most [maxBytes]) and a small
/// thumbnail for Bluetooth.
class PreparedPhoto {
  PreparedPhoto(this.jpeg, this.thumbnail, this.width, this.height);
  final Uint8List jpeg;
  final Uint8List thumbnail;
  final int width;
  final int height;
}

const int maxPhotoBytes = 150 * 1024;

/// Shrink and recompress until it fits in [maxBytes] (runs off the UI
/// thread). Returns null if the file is not a readable image.
Future<PreparedPhoto?> preparePhoto(
  Uint8List input, {
  int maxBytes = maxPhotoBytes,
}) => Isolate.run(() => preparePhotoSync(input, maxBytes: maxBytes));

PreparedPhoto? preparePhotoSync(
  Uint8List input, {
  int maxBytes = maxPhotoBytes,
}) {
  var image = img.decodeImage(input);
  if (image == null) return null;
  image = img.bakeOrientation(image);
  Uint8List? best;
  var w = image.width, h = image.height;
  outer:
  for (final side in const [1280, 1024, 800, 640, 480, 360]) {
    final scaled = _fit(image, side);
    for (final q in const [75, 60, 45]) {
      final out = img.encodeJpg(scaled, quality: q);
      best = out;
      w = scaled.width;
      h = scaled.height;
      if (out.length <= maxBytes) break outer;
    }
  }
  if (best == null || best.length > maxBytes) return null;
  final thumb = img.encodeJpg(_fit(image, 160), quality: 50);
  return PreparedPhoto(best, thumb, w, h);
}

img.Image _fit(img.Image i, int side) {
  if (i.width <= side && i.height <= side) return i;
  return i.width >= i.height
      ? img.copyResize(i, width: side, interpolation: img.Interpolation.average)
      : img.copyResize(
          i,
          height: side,
          interpolation: img.Interpolation.average,
        );
}
