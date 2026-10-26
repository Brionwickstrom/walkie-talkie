import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// Where PCM goes (FlutterPcmSound.feed in the app, a fake in tests).
typedef PcmFeed = void Function(PcmArrayInt16 pcm);

/// A [PcmArrayInt16] holding exactly the samples of [pcm].
///
/// v1.5.3 root cause of "saved messages never stop looping":
/// `FlutterPcmSound.feed` sends `buffer.bytes.buffer.asUint8List()`, the
/// WHOLE backing buffer, ignoring the view's offset and length. Since
/// v1.4.0 a saved clip was fed in 20 ms views of one big buffer
/// (`Int16List.sublistView(samples, i, end)` in AudioEngine.playClip), so
/// every 20 ms feed queued the entire clip again: a 10 s message was queued
/// 500 times (almost 1.5 hours of audio), and Stop could only stop feeding,
/// not the copies already queued in the native player. Always copy.
PcmArrayInt16 exactPcm(Int16List pcm) {
  final out = Uint8List(pcm.lengthInBytes)
    ..setAll(0, pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
  return PcmArrayInt16(bytes: out.buffer.asByteData());
}

/// Feeds a decoded clip to the speaker in real time (at most [lead] ahead,
/// so pause / stop are quick), reports the position, and ends exactly once:
/// after the last sample plus [tail], or at the latest [hardCap] after the
/// clip's length, whatever happens.
class ClipPump {
  ClipPump({
    required this.samples,
    required this.feed,
    this.sampleRate = 16000,
    this.frameSamples = 320,
    this.speed = 1.0,
    this.startMs = 0,
    this.onPosition,
    this.lead = const Duration(milliseconds: 200),
    this.tail = const Duration(milliseconds: 300),
    this.hardCap = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Int16List samples;
  final PcmFeed feed;
  final int sampleRate;
  final int frameSamples;
  final double speed;
  final int startMs;
  final void Function(int ms)? onPosition;
  final Duration lead;
  final Duration tail;
  final Duration hardCap;
  final DateTime Function() _clock;

  final _done = Completer<bool>();
  DateTime? _start;
  int _i = 0;
  Timer? _timer;

  int get totalMs => samples.length * 1000 ~/ sampleRate;

  /// Samples handed to [feed] so far.
  int get fed => _i;
  bool get isDone => _done.isCompleted;

  /// Starts pumping with a 40 ms timer. Completes with true if it played to
  /// the end, false if [stop]ped.
  Future<bool> run({bool timer = true}) {
    _start = _clock();
    tick();
    if (timer && !isDone) {
      _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => tick());
    }
    return _done.future;
  }

  /// One pump step (the timer calls this; tests call it directly).
  void tick() {
    if (isDone) return;
    final start = _start ??= _clock();
    final elapsed = _clock().difference(start).inMilliseconds;
    while (_i < samples.length &&
        _i * 1000 ~/ sampleRate < elapsed + lead.inMilliseconds) {
      final end = (_i + frameSamples).clamp(0, samples.length);
      try {
        feed(exactPcm(Int16List.sublistView(samples, _i, end)));
      } catch (_) {}
      _i = end;
    }
    onPosition?.call(startMs + (elapsed.clamp(0, totalMs) * speed).round());
    if (_i >= samples.length && elapsed >= totalMs + tail.inMilliseconds) {
      _finish(true);
    } else if (elapsed >= totalMs + hardCap.inMilliseconds) {
      _finish(true); // safety net: never longer than the clip + 1 s
    }
  }

  void stop() => _finish(false);

  void _finish(bool finished) {
    _timer?.cancel();
    _timer = null;
    if (!_done.isCompleted) _done.complete(finished);
  }
}
