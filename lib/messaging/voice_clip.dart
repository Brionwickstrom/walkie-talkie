import 'dart:typed_data';

/// A recorded voice message: a list of 20 ms Opus packets.
///
/// Stored / sent as `'WV' | ver(1) | count u16 | (len u16 | packet)*`,
/// optionally followed (1.5.2+) by `'WT' | sentAt ms u64`. Older apps read
/// exactly `count` packets and ignore the rest, so the trailer is safe.
class VoiceClip {
  VoiceClip(this.packets, {this.sentAt});

  static const int frameMs = 20;
  static const int maxDurationMs = 30000;

  final List<Uint8List> packets;

  /// When it was recorded / sent (null: from an app older than 1.5.2).
  final DateTime? sentAt;

  int get durationMs => packets.length * frameMs;

  Uint8List encode({DateTime? sentAt}) {
    sentAt ??= this.sentAt;
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
    if (sentAt != null) {
      final t = ByteData(10)
        ..setUint8(0, 0x57)
        ..setUint8(1, 0x54)
        ..setUint64(2, sentAt.millisecondsSinceEpoch);
      b.add(t.buffer.asUint8List());
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
    DateTime? sentAt;
    if (o + 10 <= bytes.length && bytes[o] == 0x57 && bytes[o + 1] == 0x54) {
      final ms = bd.getUint64(o + 2);
      if (ms > 0 && ms < 8640000000000000) {
        sentAt = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    }
    return VoiceClip(out, sentAt: sentAt);
  }
}

/// "0:12"
String formatDuration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
