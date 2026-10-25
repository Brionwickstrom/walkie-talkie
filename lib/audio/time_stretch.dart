import 'dart:math' as math;
import 'dart:typed_data';

/// Speeds speech up (or slows it down) without changing its pitch, using
/// WSOLA (waveform-similarity overlap-add): 30 ms Hann windows with 50 %
/// overlap, each one taken from near where it "should" come from at the new
/// speed, nudged by up to [searchMs] to line up with the previous one so
/// voices do not sound robotic.
///
/// Returns [input] unchanged for speed 1. Output length is about
/// `input.length / speed`.
Int16List timeStretch(
  Int16List input,
  double speed, {
  int sampleRate = 16000,
  int windowMs = 30,
  int searchMs = 5,
}) {
  if ((speed - 1).abs() < 0.01 || input.isEmpty) return input;
  final win = (sampleRate * windowMs / 1000).round() & ~1;
  final hs = win ~/ 2; // synthesis hop
  final ha = hs * speed; // analysis hop
  final delta = (sampleRate * searchMs / 1000).round();
  if (input.length < win * 2) {
    // Too short to stretch nicely: plain resample by dropping samples.
    final n = (input.length / speed).floor();
    return Int16List.fromList([
      for (var i = 0; i < n; i++)
        input[math.min(input.length - 1, (i * speed).floor())],
    ]);
  }
  final window = Float64List(win);
  for (var i = 0; i < win; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / win); // periodic Hann
  }
  final outLen = (input.length / speed).ceil() + win;
  final out = Float64List(outLen);
  final norm = Float64List(outLen);

  var prev = 0; // input start of the previous chosen segment
  var k = 0;
  while (true) {
    final nominal = (k * ha).round();
    var start = nominal;
    if (k > 0) {
      // Find the segment near [nominal] that best continues the previous
      // one: compare with what naturally followed it in the input.
      final natural = prev + hs;
      var best = -double.infinity;
      final lo = math.max(0, nominal - delta);
      final hi = math.min(input.length - win, nominal + delta);
      if (hi < lo) break;
      for (var s = lo; s <= hi; s++) {
        var c = 0.0;
        for (var i = 0; i < hs; i += 2) {
          final a = natural + i;
          if (a >= input.length) break;
          c += input[s + i] * input[a];
        }
        if (c > best) {
          best = c;
          start = s;
        }
      }
    }
    if (start + win > input.length) break;
    final o = k * hs;
    if (o + win > outLen) break;
    for (var i = 0; i < win; i++) {
      out[o + i] += input[start + i] * window[i];
      norm[o + i] += window[i];
    }
    prev = start;
    k++;
  }
  final n = math.min(outLen, (input.length / speed).round());
  final res = Int16List(n);
  for (var i = 0; i < n; i++) {
    final w = norm[i];
    final v = w > 1e-3 ? out[i] / w : 0.0;
    res[i] = v.round().clamp(-32768, 32767);
  }
  return res;
}
