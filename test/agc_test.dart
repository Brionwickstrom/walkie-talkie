import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/agc.dart';

/// 20 ms of a voice-like signal (two tones with a syllable envelope).
Int16List speech(int frame, double amplitude) {
  final out = Int16List(320);
  for (var i = 0; i < 320; i++) {
    final t = (frame * 320 + i) / 16000.0;
    final env = 0.6 + 0.4 * math.sin(2 * math.pi * 3 * t);
    final v =
        env *
        (0.7 * math.sin(2 * math.pi * 220 * t) +
            0.3 * math.sin(2 * math.pi * 660 * t));
    out[i] = (v * amplitude * 32767).round().clamp(-32768, 32767);
  }
  return out;
}

double settledLevel(Agc agc, double amplitude) {
  final tail = <int>[];
  for (var f = 0; f < 200; f++) {
    final out = agc.process(speech(f, amplitude));
    if (f >= 150) tail.addAll(out);
    for (final s in out) {
      expect(s.abs(), lessThanOrEqualTo(32767));
    }
  }
  return Agc.dbfs(Int16List.fromList(tail)); // RMS over the last second
}

void main() {
  test('quiet and loud speakers converge to about -18 dBFS', () {
    final quiet = settledLevel(Agc(), 0.05); // about -34 dBFS
    final loud = settledLevel(Agc(), 0.95); // about -4 dBFS, near clipping
    // ignore: avoid_print
    print('settled: quiet $quiet dBFS, loud $loud dBFS');
    expect(quiet, closeTo(-18, 2.5));
    expect(loud, closeTo(-18, 2.5));
    expect((quiet - loud).abs(), lessThan(3));
  });

  test('never clips, even with 200% volume on a hot signal', () {
    final agc = Agc();
    var maxAbs = 0;
    for (var f = 0; f < 100; f++) {
      final out = agc.process(speech(f, 1.0), volume: 2.0);
      for (final s in out) {
        maxAbs = math.max(maxAbs, s.abs());
      }
    }
    expect(maxAbs, lessThan(32767));
  });

  test('gain is capped at +20 dB and not raised on near-silence', () {
    final agc = Agc();
    for (var f = 0; f < 300; f++) {
      agc.process(speech(f, 0.001)); // about -66 dBFS: below the gate
    }
    expect(agc.gainDb, 0);
    for (var f = 0; f < 300; f++) {
      agc.process(speech(f, 0.008)); // speech-ish but very quiet
    }
    expect(agc.gainDb, lessThanOrEqualTo(20));
    expect(agc.gainDb, greaterThan(15));
  });

  test('volume 0 mutes, volume without agc is plain gain', () {
    final agc = Agc();
    agc.process(speech(0, 0.2), volume: 0); // ramps down over one frame
    final out = agc.process(speech(1, 0.2), volume: 0);
    expect(out.every((s) => s == 0), isTrue);
  });
}
