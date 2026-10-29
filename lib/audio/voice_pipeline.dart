import 'dart:typed_data';

import '../core/frame.dart';
import 'agc.dart';
import 'codec.dart';
import 'pcm_chunker.dart';

/// Platform-independent part of the audio path: PCM bytes -> Opus packets
/// on the way out, Opus packets -> PCM (with loss concealment) on the way
/// in. The native mic/speaker plumbing lives in [AudioEngine].
class VoicePipeline {
  VoicePipeline({
    required this.encoderFactory,
    required this.decoderFactory,
    this.micAgc = false,
    this.playbackAgc = false,
    double Function(int peerId)? volumeOf,
    DateTime Function()? clock,
  }) : volumeOf = volumeOf ?? ((_) => 1.0),
       _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Even out the mic level before encoding (see [Agc]).
  final bool micAgc;

  /// Even out each sender's level on playback (helps with phones on older
  /// builds that send without AGC), then apply [volumeOf] and a limiter.
  final bool playbackAgc;

  /// Per-person playback volume, linear 0..2 (1 = normal).
  final double Function(int peerId) volumeOf;
  final Agc _micAgc = Agc();
  final Map<int, Agc> _rxAgc = {};

  final VoiceEncoder Function() encoderFactory;
  final VoiceDecoder Function() decoderFactory;

  final _chunker = PcmChunker(samplesPerFrame: VoiceFormat.samplesPerFrame);
  VoiceEncoder? _encoder;
  final Map<int, _RxState> _rx = {};

  /// Gaps up to this many lost packets are always concealed one for one.
  static const int maxConcealed = 3;

  /// v2.3.3: a longer gap is concealed by *time*: only for the part of it
  /// that has not already passed in real time (a stall that already played
  /// as silence needs nothing more), at most this many frames (200 ms), and
  /// at least the one frame that FEC can rebuild.
  static const int maxTimedConceal = 10;

  /// Frames rebuilt from Opus in-band FEC (debug / tests).
  int fecFrames = 0;

  /// Frames concealed without FEC (debug / tests).
  int concealedFrames = 0;

  List<Uint8List> encodeMic(Uint8List pcmBytes) {
    final enc = _encoder ??= encoderFactory();
    return [
      for (final f in _chunker.add(pcmBytes))
        enc.encode(micAgc ? _micAgc.process(f) : f),
    ];
  }

  List<Uint8List> endTransmission() {
    final rest = _chunker.flush();
    final out = <Uint8List>[];
    if (rest != null) out.add((_encoder ??= encoderFactory()).encode(rest));
    _chunker.reset();
    return out;
  }

  /// Decode a packet from [peerId] with sequence [seq]. Returns PCM to play,
  /// including concealment frames for any gap before it (v2.3.3): the frame
  /// right before this packet is rebuilt from the packet's own in-band FEC
  /// data when the decoder has it, the others are concealed; a gap longer
  /// than [maxConcealed] is concealed by elapsed time, not dropped.
  List<Int16List> decode(int peerId, int seq, Uint8List packet) {
    final st = _rx.putIfAbsent(peerId, () => _RxState(decoderFactory()));
    final out = <Int16List>[];
    final last = st.lastSeq;
    final now = _clock();
    if (last != null) {
      if (!seqNewer(seq, last)) return out; // late/out-of-order: drop
      final gap = ((seq - last) & 0xFFFF) - 1;
      if (gap > 0) {
        var n = gap;
        if (gap > maxConcealed) {
          final at = st.lastAt;
          final passed = at == null
              ? 0
              : now.difference(at).inMilliseconds ~/ VoiceFormat.frameMs - 1;
          n = (gap - (passed < 0 ? 0 : passed)).clamp(1, maxTimedConceal);
        }
        final dec = st.decoder;
        for (var i = 0; i < n - 1; i++) {
          out.add(dec.decode(null));
          concealedFrames++;
        }
        if (dec is FecVoiceDecoder) {
          out.add((dec as FecVoiceDecoder).decodeFec(packet));
          fecFrames++;
        } else {
          out.add(dec.decode(null));
          concealedFrames++;
        }
      }
    }
    st.lastAt = now;
    st.lastSeq = seq;
    out.add(st.decoder.decode(packet));
    final vol = volumeOf(peerId);
    if (playbackAgc || vol != 1.0) {
      final agc = _rxAgc.putIfAbsent(peerId, Agc.new);
      for (final f in out) {
        agc.process(f, volume: vol, agc: playbackAgc);
      }
    }
    return out;
  }

  /// Call when a peer stops talking so the next burst starts clean.
  void resetPeer(int peerId) => _rx.remove(peerId)?.decoder.dispose();

  void dispose() {
    _encoder?.dispose();
    for (final s in _rx.values) {
      s.decoder.dispose();
    }
    _rx.clear();
  }
}

class _RxState {
  _RxState(this.decoder);
  final VoiceDecoder decoder;
  int? lastSeq;

  /// When the last packet arrived (for timing-based concealment).
  DateTime? lastAt;
}
