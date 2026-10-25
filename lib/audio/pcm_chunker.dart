import 'dart:typed_data';

/// Turns an arbitrary-sized stream of little-endian 16-bit PCM byte chunks
/// (what the `record` plugin delivers) into fixed-size frames that Opus can
/// encode (Opus only accepts 2.5/5/10/20/40/60 ms frames).
class PcmChunker {
  PcmChunker({required this.samplesPerFrame});

  final int samplesPerFrame;
  final BytesBuilder _pending = BytesBuilder(copy: true);

  int get _frameBytes => samplesPerFrame * 2;

  /// Feed raw bytes; returns zero or more complete frames.
  List<Int16List> add(Uint8List bytes) {
    _pending.add(bytes);
    if (_pending.length < _frameBytes) return const [];
    final all = _pending.takeBytes();
    final frames = <Int16List>[];
    var offset = 0;
    final bd = ByteData.sublistView(all);
    while (all.length - offset >= _frameBytes) {
      final frame = Int16List(samplesPerFrame);
      for (var i = 0; i < samplesPerFrame; i++) {
        frame[i] = bd.getInt16(offset + i * 2, Endian.little);
      }
      frames.add(frame);
      offset += _frameBytes;
    }
    if (offset < all.length) _pending.add(all.sublist(offset));
    return frames;
  }

  /// Pads the remainder with silence and flushes it (end of a transmission).
  Int16List? flush() {
    if (_pending.isEmpty) return null;
    final rest = _pending.takeBytes();
    final padded = Uint8List(_frameBytes)..setRange(0, rest.length, rest);
    return add(padded).firstOrNull;
  }

  void reset() => _pending.clear();
}
