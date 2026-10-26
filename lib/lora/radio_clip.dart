import 'dart:typed_data';

/// Codec used for radio clips (Codec 2 in the app, a fake in tests).
abstract class FrameCodec {
  int get mode;

  /// 8 kHz samples per frame (320 = 40 ms for 700C / 1200).
  int get samplesPerFrame;
  int get bitsPerFrame;
  Uint8List encode(Int16List pcm8k);
  Int16List decode(Uint8List bits);
  void dispose();
}

/// A short voice clip for LoRa radios: Codec 2 frames, bit-packed with no
/// padding between frames (700C: 28 bits per 40 ms = 3.5 bytes, so 8 s is
/// 700 bytes + header, about 5 radio packets).
///
/// ```
/// 'W' 'C' ver(1) mode u8 bitsPerFrame u8 frameMs u8 frames u16
/// sentAt ms u64 | packed bits
/// ```
class RadioClip {
  RadioClip({
    required this.mode,
    required this.bitsPerFrame,
    required this.frameMs,
    required this.frames,
    required this.bits,
    this.sentAt,
  });

  static const int headerSize = 16;

  /// Longest clip sent over the radio.
  static const int maxDurationMs = 8000;

  final int mode;
  final int bitsPerFrame;
  final int frameMs;
  final int frames;
  final Uint8List bits;
  final DateTime? sentAt;

  int get durationMs => frames * frameMs;

  static bool looksLike(Uint8List b) =>
      b.length >= headerSize && b[0] == 0x57 && b[1] == 0x43 && b[2] == 1;

  Uint8List encode() {
    final out = Uint8List(headerSize + bits.length);
    ByteData.sublistView(out)
      ..setUint8(0, 0x57)
      ..setUint8(1, 0x43)
      ..setUint8(2, 1)
      ..setUint8(3, mode)
      ..setUint8(4, bitsPerFrame)
      ..setUint8(5, frameMs)
      ..setUint16(6, frames)
      ..setUint64(8, sentAt?.millisecondsSinceEpoch ?? 0);
    out.setRange(headerSize, out.length, bits);
    return out;
  }

  static RadioClip? tryDecode(Uint8List b) {
    if (!looksLike(b)) return null;
    final bd = ByteData.sublistView(b);
    final bpf = b[4];
    final frames = bd.getUint16(6);
    if (bpf == 0 || b[5] == 0) return null;
    final need = (frames * bpf + 7) ~/ 8;
    if (b.length < headerSize + need) return null;
    final ms = bd.getUint64(8);
    return RadioClip(
      mode: b[3],
      bitsPerFrame: bpf,
      frameMs: b[5],
      frames: frames,
      bits: Uint8List.fromList(b.sublist(headerSize, headerSize + need)),
      sentAt: ms > 0 && ms < 8640000000000000
          ? DateTime.fromMillisecondsSinceEpoch(ms)
          : null,
    );
  }

  /// The frames, each [bitsPerFrame] bits left-aligned in whole bytes (the
  /// layout codec2_decode expects).
  List<Uint8List> unpackFrames() => unpackBits(bits, frames, bitsPerFrame);
}

/// Concatenate the first [bitsPerFrame] bits (MSB first) of every frame.
Uint8List packBits(List<Uint8List> frames, int bitsPerFrame) {
  final out = Uint8List((frames.length * bitsPerFrame + 7) ~/ 8);
  var pos = 0;
  for (final f in frames) {
    for (var i = 0; i < bitsPerFrame; i++) {
      final bit = (f[i >> 3] >> (7 - (i & 7))) & 1;
      if (bit == 1) out[pos >> 3] |= 1 << (7 - (pos & 7));
      pos++;
    }
  }
  return out;
}

List<Uint8List> unpackBits(Uint8List packed, int frames, int bitsPerFrame) {
  final bytesPer = (bitsPerFrame + 7) ~/ 8;
  final out = <Uint8List>[];
  var pos = 0;
  for (var n = 0; n < frames; n++) {
    final f = Uint8List(bytesPer);
    for (var i = 0; i < bitsPerFrame; i++) {
      final byte = pos >> 3;
      final bit = byte < packed.length
          ? (packed[byte] >> (7 - (pos & 7))) & 1
          : 0;
      if (bit == 1) f[i >> 3] |= 1 << (7 - (i & 7));
      pos++;
    }
    out.add(f);
  }
  return out;
}

/// 16 kHz -> 8 kHz with a small low-pass (1/4, 1/2, 1/4) before dropping
/// every other sample.
Int16List downsample16to8(Int16List x) {
  final out = Int16List(x.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final c = 2 * i;
    final a = c > 0 ? x[c - 1] : x[c];
    final b = x[c];
    final d = c + 1 < x.length ? x[c + 1] : x[c];
    out[i] = ((a + 2 * b + d) ~/ 4).clamp(-32768, 32767);
  }
  return out;
}

/// 8 kHz -> 16 kHz by linear interpolation.
Int16List upsample8to16(Int16List x) {
  final out = Int16List(x.length * 2);
  for (var i = 0; i < x.length; i++) {
    final a = x[i];
    final b = i + 1 < x.length ? x[i + 1] : a;
    out[2 * i] = a;
    out[2 * i + 1] = (a + b) ~/ 2;
  }
  return out;
}

/// Drop quiet audio at both ends (keeps [padMs]): no airtime for silence.
Int16List trimSilence(
  Int16List pcm, {
  int sampleRate = 16000,
  int threshold = 600,
  int padMs = 120,
}) {
  final win = sampleRate ~/ 50; // 20 ms
  int loud(int start) {
    var peak = 0;
    for (var i = start; i < start + win && i < pcm.length; i++) {
      final v = pcm[i].abs();
      if (v > peak) peak = v;
    }
    return peak;
  }

  var first = -1, last = -1;
  for (var s = 0; s < pcm.length; s += win) {
    if (loud(s) >= threshold) {
      if (first < 0) first = s;
      last = s + win;
    }
  }
  if (first < 0) return Int16List(0);
  final pad = sampleRate * padMs ~/ 1000;
  final a = (first - pad).clamp(0, pcm.length);
  final b = (last + pad).clamp(0, pcm.length);
  return Int16List.fromList(pcm.sublist(a, b));
}

/// PCM (16 kHz) <-> [RadioClip].
class RadioClipCodec {
  RadioClipCodec(this._newCodec);
  final FrameCodec Function() _newCodec;

  /// Encode [pcm16k] (silence trimmed at both ends). Null when nothing
  /// audible is left, or when it is longer than [maxMs] (half a second of
  /// slack) unless [truncate].
  RadioClip? encode(
    Int16List pcm16k, {
    DateTime? sentAt,
    int maxMs = RadioClip.maxDurationMs,
    bool truncate = false,
  }) {
    final trimmed = trimSilence(pcm16k);
    if (trimmed.isEmpty) return null;
    final maxSamples = 16 * maxMs;
    if (!truncate && trimmed.length > maxSamples + 16 * 500) return null;
    final use = trimmed.length > maxSamples
        ? Int16List.sublistView(trimmed, 0, maxSamples)
        : trimmed;
    final pcm8 = downsample16to8(use);
    final c = _newCodec();
    try {
      final spf = c.samplesPerFrame;
      final frames = <Uint8List>[];
      for (var o = 0; o < pcm8.length; o += spf) {
        final f = Int16List(spf);
        final end = o + spf > pcm8.length ? pcm8.length : o + spf;
        f.setRange(0, end - o, pcm8, o);
        frames.add(c.encode(f));
      }
      return RadioClip(
        mode: c.mode,
        bitsPerFrame: c.bitsPerFrame,
        frameMs: spf ~/ 8,
        frames: frames.length,
        bits: packBits(frames, c.bitsPerFrame),
        sentAt: sentAt,
      );
    } finally {
      c.dispose();
    }
  }

  /// 16 kHz PCM of [clip].
  Int16List decode(RadioClip clip) {
    final c = _newCodec();
    try {
      final b = BytesBuilder(copy: false);
      for (final f in clip.unpackFrames()) {
        final pcm = c.decode(f);
        b.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
      }
      final bytes = b.takeBytes();
      return upsample8to16(Int16List.view(bytes.buffer, 0, bytes.length ~/ 2));
    } finally {
      c.dispose();
    }
  }
}
