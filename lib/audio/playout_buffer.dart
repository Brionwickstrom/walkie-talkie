/// Keeps speaker latency bounded and smooths network jitter.
///
/// flutter_pcm_sound queues everything it is fed in an unbounded queue. This
/// tracks how much audio is queued (fed minus played, assuming real-time
/// playback) and:
///  * at the start of a burst or after an underrun (queue empty) asks for a
///    cushion of silence first. v2.3.3: the cushion is adaptive, between
///    [minTargetMs] and [maxTargetMs] (default 80-120 ms): it grows when
///    packets arrive unevenly ([noteArrival] measures the jitter as a
///    smoothed average of how far each packet is from its 20 ms slot) and
///    shrinks back when the network is calm;
///  * drops frames only while more than [maxMs] (default 300 ms, was 200) is
///    queued, so a late burst plays slightly late instead of losing words,
///    and a really long backlog still snaps back instead of accumulating;
///  * [reanchor]: when the speaker opened late, the played-audio clock starts
///    when it really started, so the estimate (and the next cushion) is real.
class PlayoutBuffer {
  PlayoutBuffer({
    required this.sampleRate,
    this.targetMs = 80,
    int? minTargetMs,
    int? maxTargetMs,
    this.maxMs = 300,
    this.frameMs = 20,
    DateTime Function()? clock,
  }) : minTargetMs = minTargetMs ?? targetMs,
       maxTargetMs = maxTargetMs ?? (targetMs > 120 ? targetMs : 120),
       _clock = clock ?? DateTime.now,
       _target = targetMs;

  final int sampleRate;

  /// The starting cushion (before any jitter was measured).
  final int targetMs;
  final int minTargetMs;
  final int maxTargetMs;

  /// Queued audio above this is dropped.
  final int maxMs;
  final int frameMs;
  final DateTime Function() _clock;

  DateTime? _start;
  int _fedSamples = 0;
  int dropped = 0;
  int _target;

  // Jitter estimate (smoothed mean deviation of the arrival times, ms).
  double _jitterMs = 0;
  bool _haveJitter = false;
  final Map<int, ({int seq, DateTime at})> _lastArrival = {};

  /// The cushion that the next burst / underrun gets, in ms.
  int get cushionMs => _target;

  /// Smoothed arrival jitter in ms (0 until measured).
  double get jitterMs => _jitterMs;

  /// Estimated ms of audio still waiting to be played.
  int get queuedMs {
    final s = _start;
    if (s == null) return 0;
    final playedSamples =
        _clock().difference(s).inMicroseconds * sampleRate ~/ 1000000;
    final q = _fedSamples - playedSamples;
    return q <= 0 ? 0 : q * 1000 ~/ sampleRate;
  }

  /// A packet from [peerId] with sequence [seq] arrived now. Feeds the
  /// jitter estimate: the gap since that sender's previous packet compared
  /// with the 20 ms per sequence step the sender used. Packets far apart in
  /// sequence (a new burst, lost runs) are not measured.
  void noteArrival(int peerId, int seq) {
    final now = _clock();
    final prev = _lastArrival[peerId];
    _lastArrival[peerId] = (seq: seq, at: now);
    if (prev == null) return;
    final steps = (seq - prev.seq) & 0xFFFF;
    if (steps < 1 || steps > 8) return;
    final actual = now.difference(prev.at).inMicroseconds / 1000.0;
    final dev = (actual - steps * frameMs).abs();
    // Spikes pull the estimate up quickly, calm pulls it down slowly.
    final k = dev > _jitterMs ? 0.25 : 1 / 16;
    _jitterMs = _haveJitter ? _jitterMs + (dev - _jitterMs) * k : dev;
    _haveJitter = true;
    final want = (minTargetMs + 1.5 * _jitterMs).round();
    _target = want.clamp(minTargetMs, maxTargetMs);
  }

  /// A peer's burst ended: forget its arrival clock.
  void endPeer(int peerId) => _lastArrival.remove(peerId);

  /// Decide what to do with a frame of [samples]. Returns null to drop it,
  /// otherwise the number of silence samples to feed before it (0 normally).
  int? admit(int samples) {
    final q = queuedMs;
    if (q <= 0) {
      // Underrun or new burst: restart the clock with a jitter cushion.
      _start = _clock();
      final pre = _target * sampleRate ~/ 1000;
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

  /// The speaker really started playing at [at], after [fedSamples] samples
  /// were handed to it (the cushion may have been shortened by the time the
  /// opening took). From now on the estimate counts from there.
  void reanchor(DateTime at, int fedSamples) {
    if (fedSamples <= 0) {
      reset();
      return;
    }
    _start = at;
    _fedSamples = fedSamples;
  }

  void reset() {
    _start = null;
    _fedSamples = 0;
  }
}
