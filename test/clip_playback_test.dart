// v1.5.3: saved voice messages / replays looped "forever".
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/clip_player.dart';
import 'package:walkie_talkie/audio/time_stretch.dart';

import 'messaging_fakes.dart' show FakeClock;

/// Behaves exactly like FlutterPcmSound.feed + its native queue: the Dart
/// side sends `buffer.bytes.buffer.asUint8List()` (the WHOLE backing
/// buffer of the view) and the player plays everything it was sent.
class FakeSpeaker {
  int queuedSamples = 0;
  int feeds = 0;
  void feed(PcmArrayInt16 p) {
    feeds++;
    queuedSamples += p.bytes.buffer.asUint8List().length ~/ 2;
  }
}

Int16List speech(int ms) => Int16List.fromList([
  for (var i = 0; i < ms * 16; i++)
    (8000 * math.sin(i * 2 * math.pi * 220 / 16000)).round(),
]);

void main() {
  test('root cause: 20 ms views of one buffer queue the whole clip each '
      'time (the v1.4.0 - v1.5.2 feed code)', () {
    final samples = speech(10000); // a 10 s message
    final sink = FakeSpeaker();
    for (var i = 0; i < samples.length; i += 320) {
      final end = math.min(i + 320, samples.length);
      final chunk = Int16List.sublistView(samples, i, end);
      sink.feed(
        PcmArrayInt16(
          bytes: chunk.buffer.asByteData(
            chunk.offsetInBytes,
            chunk.lengthInBytes,
          ),
        ),
      );
    }
    // 500 feeds x the whole 10 s clip = 83 minutes of the same message.
    expect(sink.queuedSamples, samples.length * 500);
  });

  test('exactPcm hands over exactly the view', () {
    final big = speech(1000);
    final v = Int16List.sublistView(big, 320, 640);
    final p = exactPcm(v);
    expect(p.bytes.buffer.asUint8List().length, 640);
    expect(p[0], big[320]);
  });

  for (final speed in [1.0, 1.5, 2.0]) {
    test('plays once with the right sample count at ${speed}x', () async {
      final clock = FakeClock();
      final sink = FakeSpeaker();
      final samples = timeStretch(speech(10000), speed);
      final positions = <int>[];
      final pump = ClipPump(
        samples: samples,
        feed: sink.feed,
        speed: speed,
        onPosition: positions.add,
        clock: clock.call,
      );
      var ends = 0;
      bool? result;
      final done = pump.run(timer: false).then((r) {
        ends++;
        result = r;
      });
      // 30 s of 40 ms ticks: far past the end.
      for (var t = 0; t < 750; t++) {
        clock.advance(const Duration(milliseconds: 40));
        pump.tick();
        await Future<void>.delayed(Duration.zero);
      }
      await done;
      expect(ends, 1);
      expect(result, isTrue);
      expect(sink.queuedSamples, samples.length, reason: 'each sample once');
      expect(samples.length, closeTo(160000 / speed, 160000 * 0.05));
      expect(positions.last, lessThanOrEqualTo(10000 + 50));
      final fedAfter = sink.feeds;
      for (var t = 0; t < 100; t++) {
        clock.advance(const Duration(milliseconds: 40));
        pump.tick();
      }
      expect(sink.feeds, fedAfter, reason: 'nothing after the end');
    });
  }

  test('"play all" over 3 saved items: 3 ends, each played once', () async {
    final clock = FakeClock();
    final sink = FakeSpeaker();
    final items = [speech(3000), speech(1200), speech(7400)];
    var ends = 0;
    for (final s in items) {
      final pump = ClipPump(samples: s, feed: sink.feed, clock: clock.call);
      final f = pump.run(timer: false).then((r) {
        expect(r, isTrue);
        ends++;
      });
      while (!pump.isDone) {
        clock.advance(const Duration(milliseconds: 40));
        pump.tick();
      }
      await f;
    }
    expect(ends, 3);
    expect(sink.queuedSamples, items.fold<int>(0, (a, s) => a + s.length));
  });

  test('Stop: ends at once, nothing more is fed', () async {
    final clock = FakeClock();
    final sink = FakeSpeaker();
    final pump = ClipPump(
      samples: speech(10000),
      feed: sink.feed,
      clock: clock.call,
    );
    final f = pump.run(timer: false);
    for (var t = 0; t < 50; t++) {
      clock.advance(const Duration(milliseconds: 40));
      pump.tick();
    }
    pump.stop();
    final fed = sink.queuedSamples;
    for (var t = 0; t < 500; t++) {
      clock.advance(const Duration(milliseconds: 40));
      pump.tick();
    }
    expect(await f, isFalse);
    expect(sink.queuedSamples, fed);
    expect(fed, lessThan(16 * 2300)); // ~2 s played + 200 ms lead
  });

  test('hard cap: never longer than the clip + 1 s', () async {
    final clock = FakeClock();
    final pump = ClipPump(
      samples: speech(2000),
      feed: (_) {},
      tail: const Duration(minutes: 5), // even with a broken end condition
      clock: clock.call,
    );
    final f = pump.run(timer: false);
    var ms = 0;
    while (!pump.isDone && ms < 60000) {
      clock.advance(const Duration(milliseconds: 40));
      ms += 40;
      pump.tick();
    }
    expect(await f, isTrue);
    expect(ms, lessThanOrEqualTo(2000 + 1000 + 40));
  });
}
