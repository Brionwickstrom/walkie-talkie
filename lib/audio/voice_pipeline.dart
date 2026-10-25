import 'dart:typed_data';

import '../core/frame.dart';
import 'codec.dart';
import 'pcm_chunker.dart';

/// Platform-independent part of the audio path: PCM bytes -> Opus packets
/// on the way out, Opus packets -> PCM (with loss concealment) on the way
/// in. The native mic/speaker plumbing lives in [AudioEngine].
class VoicePipeline {
  VoicePipeline({
    required this.encoderFactory,
    required this.decoderFactory,
  });

  final VoiceEncoder Function() encoderFactory;
  final VoiceDecoder Function() decoderFactory;

  final _chunker = PcmChunker(samplesPerFrame: VoiceFormat.samplesPerFrame);
  VoiceEncoder? _encoder;
  final Map<int, _RxState> _rx = {};

  /// Max consecutive lost packets we conceal before just skipping ahead.
  static const int maxConcealed = 3;

  List<Uint8List> encodeMic(Uint8List pcmBytes) {
    final enc = _encoder ??= encoderFactory();
    return [for (final f in _chunker.add(pcmBytes)) enc.encode(f)];
  }

  List<Uint8List> endTransmission() {
    final rest = _chunker.flush();
    final out = <Uint8List>[];
    if (rest != null) out.add((_encoder ??= encoderFactory()).encode(rest));
    _chunker.reset();
    return out;
  }

  /// Decode a packet from [peerId] with sequence [seq]. Returns PCM to play,
  /// including concealment frames for any small gap before it.
  List<Int16List> decode(int peerId, int seq, Uint8List packet) {
    final st = _rx.putIfAbsent(peerId, () => _RxState(decoderFactory()));
    final out = <Int16List>[];
    final last = st.lastSeq;
    if (last != null) {
      if (!seqNewer(seq, last)) return out; // late/out-of-order: drop
      final gap = ((seq - last) & 0xFFFF) - 1;
      if (gap > 0 && gap <= maxConcealed) {
        for (var i = 0; i < gap; i++) {
          out.add(st.decoder.decode(null));
        }
      }
    }
    st.lastSeq = seq;
    out.add(st.decoder.decode(packet));
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
}
