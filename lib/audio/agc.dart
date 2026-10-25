import 'dart:math' as math;
import 'dart:typed_data';

/// Automatic gain control + soft limiter for 16-bit voice frames.
///
/// Used on both ends:
/// * sender: before Opus encoding, so a quiet mic / a far-away mouth and a
///   shouting user come out at about the same level;
/// * receiver: per sender, so phones on older builds (no sender AGC) are
///   evened out too, and the per-person volume (0..2) is applied before the
///   limiter so turning someone up can never clip.
///
/// Level is measured per frame (RMS), the gain follows it slowly in dB
/// (attack when it must go down, release when it may go up), stays within
/// [minGainDb]..[maxGainDb], and is frozen while the input is near-silent
/// ([gateDbfs]) so background hiss between words is not pumped up. Gain
/// changes are ramped across the frame (no zipper noise) and the output
/// passes a soft clipper above [limitDbfs].
class Agc {
  Agc({
    this.targetDbfs = -18,
    this.maxGainDb = 20,
    this.minGainDb = -20,
    this.gateDbfs = -48,
    this.attackMs = 120,
    this.releaseMs = 900,
    this.limitDbfs = -1.5,
    double initialGainDb = 0,
  }) : _gainDb = initialGainDb;

  final double targetDbfs;
  final double maxGainDb;
  final double minGainDb;
  final double gateDbfs;
  final double attackMs;
  final double releaseMs;
  final double limitDbfs;

  double _gainDb;
  double _lastLinear = 1;
  bool _primed = false;

  /// Current gain in dB (for tests / debug).
  double get gainDb => _gainDb;

  static double dbfs(Int16List pcm) {
    if (pcm.isEmpty) return -120;
    var sum = 0.0;
    for (final s in pcm) {
      sum += s * s;
    }
    final rms = math.sqrt(sum / pcm.length) / 32768.0;
    return rms <= 1e-9 ? -120 : 20 * math.log(rms) / math.ln10;
  }

  /// Process [frame] in place and return it. [volume] (linear, e.g. 0..2)
  /// is applied on top of the AGC gain, before the limiter.
  Int16List process(Int16List frame, {double volume = 1, bool agc = true}) {
    if (frame.isEmpty) return frame;
    final frameMs = frame.length / 16.0; // 16 kHz
    if (agc) {
      final level = dbfs(frame);
      if (level > gateDbfs) {
        final want = (targetDbfs - level).clamp(minGainDb, maxGainDb);
        if (!_primed) {
          // First speech frame: start close to the right gain instead of
          // ramping up from 0 dB over a second (first word inaudible) -
          // but never above +6 dB on the first frame.
          _gainDb = math.min(want, 6.0);
          _primed = true;
        } else {
          final tau = want < _gainDb ? attackMs : releaseMs;
          final a = 1 - math.exp(-frameMs / tau);
          _gainDb += (want - _gainDb) * a;
        }
      }
    }
    final target =
        (agc ? math.pow(10, _gainDb / 20).toDouble() : 1.0) *
        volume.clamp(0.0, 4.0);
    final start = _lastLinear;
    _lastLinear = target;
    final limit = 32767 * math.pow(10, limitDbfs / 20).toDouble();
    final knee = 32767 - limit;
    final n = frame.length;
    for (var i = 0; i < n; i++) {
      final g = start + (target - start) * (i + 1) / n;
      var x = frame[i] * g;
      final ax = x.abs();
      if (ax > limit) {
        // Soft clip: smoothly approach full scale, never exceed it.
        final over = (ax - limit) / knee;
        final y = limit + knee * (over / (1 + over));
        x = x.isNegative ? -y : y;
      }
      frame[i] = x.round().clamp(-32767, 32767);
    }
    return frame;
  }

  void reset() {
    _primed = false;
    _gainDb = 0;
    _lastLinear = 1;
  }
}
