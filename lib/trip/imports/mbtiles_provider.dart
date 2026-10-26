import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import 'mbtiles.dart';

/// flutter_map tiles straight from an MBTiles file on the device.
class MbTilesProvider extends TileProvider {
  MbTilesProvider(this.mb);
  final MbTiles mb;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MbTileImage(mb, coordinates.z, coordinates.x, coordinates.y);
}

@immutable
class MbTileImage extends ImageProvider<MbTileImage> {
  const MbTileImage(this.mb, this.z, this.x, this.y);
  final MbTiles mb;
  final int z, x, y;

  @override
  Future<MbTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    MbTileImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: '${mb.path}/$z/$x/$y',
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = mb.tile(z, x, y);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('tile not in the MBTiles file');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is MbTileImage &&
      other.mb.path == mb.path &&
      other.z == z &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(mb.path, z, x, y);
}
