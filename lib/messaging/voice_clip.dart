import 'dart:typed_data';

/// A recorded voice message: a list of 20 ms Opus packets.
///
/// Stored / sent as `'WV' | ver(1) | count u16 | (len u16 | packet)*`.
class VoiceClip {
  VoiceClip(this.packets);

  static const int frameMs = 20;
  static const int maxDurationMs = 30000;

  final List<Uint8List> packets;

  int get durationMs => packets.length * frameMs;

  Uint8List encode() {
    final b = BytesBuilder(copy: false);
    final head = ByteData(5)
      ..setUint8(0, 0x57)
      ..setUint8(1, 0x56)
      ..setUint8(2, 1)
      ..setUint16(3, packets.length);
    b.add(head.buffer.asUint8List());
    for (final p in packets) {
      final len = ByteData(2)..setUint16(0, p.length);
      b.add(len.buffer.asUint8List());
      b.add(p);
    }
    return b.takeBytes();
  }

  static VoiceClip? tryDecode(Uint8List bytes) {
    if (bytes.length < 5 || bytes[0] != 0x57 || bytes[1] != 0x56) return null;
    if (bytes[2] != 1) return null;
    final bd = ByteData.sublistView(bytes);
    final count = bd.getUint16(3);
    var o = 5;
    final out = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      if (o + 2 > bytes.length) return null;
      final len = bd.getUint16(o);
      o += 2;
      if (o + len > bytes.length) return null;
      out.add(Uint8List.fromList(bytes.sublist(o, o + len)));
      o += len;
    }
    return VoiceClip(out);
  }
}

/// "0:12"
String formatDuration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
