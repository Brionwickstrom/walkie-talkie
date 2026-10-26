import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import 'tile_cache.dart';

/// flutter_map tiles through the [TileCache] (offline first).
class CachedTileProvider extends TileProvider {
  CachedTileProvider(this.cache, this.source);
  final TileCache cache;
  final MapSource source;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      CachedTileImage(
        cache,
        source,
        coordinates.z,
        coordinates.x,
        coordinates.y,
      );
}

@immutable
class CachedTileImage extends ImageProvider<CachedTileImage> {
  const CachedTileImage(this.cache, this.source, this.z, this.x, this.y);
  final TileCache cache;
  final MapSource source;
  final int z, x, y;

  @override
  Future<CachedTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CachedTileImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: '${source.id}/$z/$x/$y',
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await cache.get(source, z, x, y);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('tile not available offline');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is CachedTileImage &&
      other.source.id == source.id &&
      other.source.urlTemplate == source.urlTemplate &&
      other.z == z &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(source.id, source.urlTemplate, z, x, y);
}
