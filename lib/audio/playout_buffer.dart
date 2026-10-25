/// Keeps speaker latency bounded.
///
/// flutter_pcm_sound queues everything it is fed in an unbounded queue. If
/// packets arrive in bursts (Bluetooth does this) the queue grows after
/// every hiccup and never shrinks, so the delay creeps up the longer you
/// talk. This tracks how much audio is queued (fed minus played, assuming
/// real-time playback) and:
///  * at the start of a burst (queue empty) asks for [targetMs] of silence
///    first, a small cushion that absorbs network jitter;
///  * drops frames while more than [maxMs] is queued, so delay snaps back
///    instead of accumulating.
class PlayoutBuffer {
  PlayoutBuffer({
    required this.sampleRate,
    this.targetMs = 60,
    this.maxMs = 180,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int sampleRate;
  final int targetMs;
  final int maxMs;
  final DateTime Function() _clock;

  DateTime? _start;
  int _fedSamples = 0;
  int dropped = 0;

  /// Estimated ms of audio still waiting to be played.
  int get queuedMs {
    final s = _start;
    if (s == null) return 0;
    final playedSamples =
        _clock().difference(s).inMicroseconds * sampleRate ~/ 1000000;
    final q = _fedSamples - playedSamples;
    return q <= 0 ? 0 : q * 1000 ~/ sampleRate;
  }

  /// Decide what to do with a frame of [samples]. Returns null to drop it,
  /// otherwise the number of silence samples to feed before it (0 normally).
  int? admit(int samples) {
    final q = queuedMs;
    if (q <= 0) {
      // Underrun or new burst: restart the clock with a jitter cushion.
      _start = _clock();
      final pre = targetMs * sampleRate ~/ 1000;
      _fedSamples = pre + samples;
      return pre;
    }
    if (q > maxMs) {
      dropped++;
      return null;
    }
    _fedSamples += samples;
    return 0;
  }

  void reset() {
    _start = null;
    _fedSamples = 0;
  }
}
