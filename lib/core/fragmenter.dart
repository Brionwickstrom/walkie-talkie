import 'dart:typed_data';

/// Splits frames that do not fit a single BLE write/notification and puts
/// them back together on the other side.
///
/// Each chunk carries a 2 byte prefix:
/// ```
/// byte 0: message id (wraps at 256)
/// byte 1: high nibble = chunk index, low nibble = chunk count (1..15)
/// ```
/// With a typical negotiated MTU (185 -> 182 usable) audio frames always fit
/// in one chunk; fragmentation mainly matters on the 23 byte default MTU.
class Fragmenter {
  Fragmenter({required this.maxChunkSize})
    : assert(maxChunkSize > prefixSize, 'MTU too small');

  static const int prefixSize = 2;
  static const int maxChunks = 15;

  /// Usable bytes per BLE packet (ATT MTU - 3).
  int maxChunkSize;
  int _nextId = 0;

  List<Uint8List> split(Uint8List message) {
    final body = maxChunkSize - prefixSize;
    final count = message.isEmpty ? 1 : (message.length + body - 1) ~/ body;
    if (count > maxChunks) {
      throw ArgumentError(
        'Message of ${message.length}B needs $count chunks (> $maxChunks) '
        'at chunk size $maxChunkSize',
      );
    }
    final id = _nextId;
    _nextId = (_nextId + 1) & 0xFF;
    final chunks = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final start = i * body;
      final end = (start + body) > message.length
          ? message.length
          : start + body;
      final chunk = Uint8List(prefixSize + (end - start));
      chunk[0] = id;
      chunk[1] = (i << 4) | count;
      chunk.setRange(prefixSize, chunk.length, message, start);
      chunks.add(chunk);
    }
    return chunks;
  }
}

/// Reassembles chunks produced by [Fragmenter]. One instance per remote
/// sender (a BLE link), since message ids are per-sender.
class Reassembler {
  int? _id;
  int _count = 0;
  final Map<int, Uint8List> _parts = {};

  /// Returns the full message once all chunks arrived, otherwise null.
  /// Chunks of a newer message drop any incomplete older one (audio is
  /// real-time; waiting for a lost chunk is pointless).
  Uint8List? add(List<int> chunk) {
    if (chunk.length < Fragmenter.prefixSize) return null;
    final id = chunk[0];
    final index = chunk[1] >> 4;
    final count = chunk[1] & 0x0F;
    if (count == 0 || index >= count) return null;
    if (count == 1) {
      _reset();
      return Uint8List.fromList(chunk.sublist(Fragmenter.prefixSize));
    }
    if (_id != id || _count != count) {
      _reset();
      _id = id;
      _count = count;
    }
    _parts[index] = Uint8List.fromList(chunk.sublist(Fragmenter.prefixSize));
    if (_parts.length < _count) return null;
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < _count; i++) {
      builder.add(_parts[i]!);
    }
    _reset();
    return builder.takeBytes();
  }

  void _reset() {
    _id = null;
    _count = 0;
    _parts.clear();
  }
}
