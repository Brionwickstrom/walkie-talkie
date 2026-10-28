import 'dart:io';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart' show PcmArrayInt16;
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/pcm_speaker.dart';
import 'package:walkie_talkie/audio/speaker_gate.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';

import 'trip_integration_test.dart' show FakeHost;

/// A speaker that records what happens to it; opening takes [openTime].
class FakeSpeaker implements PcmSpeaker {
  FakeSpeaker({this.openTime = Duration.zero});
  final Duration openTime;
  bool open = false;
  int setups = 0, releases = 0;
  final fed = <PcmArrayInt16>[];

  @override
  Future<void> setup({required int sampleRate, required int channels}) async {
    if (openTime > Duration.zero) await Future<void>.delayed(openTime);
    open = true;
    setups++;
  }

  @override
  void feed(PcmArrayInt16 pcm) {
    expect(open, isTrue, reason: 'never fed while closed');
    fed.add(pcm);
  }

  @override
  Future<void> release() async {
    open = false;
    releases++;
  }
}

PcmArrayInt16 voice(int samples, {int value = 1000}) =>
    PcmArrayInt16.fromList(List.filled(samples, value));

int silentSamples(Iterable<PcmArrayInt16> l) =>
    l.where((p) => p.count > 0 && p[0] == 0).fold(0, (s, p) => s + p.count);
int voiceSamples(Iterable<PcmArrayInt16> l) =>
    l.where((p) => p.count > 0 && p[0] != 0).fold(0, (s, p) => s + p.count);

void main() {
  group('speaker closes when nothing plays', () {
    test('closed until audio, closed again after the quiet period', () async {
      final s = FakeSpeaker();
      final g = SpeakerGate(
        s,
        sampleRate: 16000,
        channels: 1,
        idle: const Duration(milliseconds: 80),
      );
      expect(g.isOpen, isFalse);
      expect(g.timerRunning, isFalse, reason: 'no timer while idle');
      expect(s.setups, 0);
      // 20 ms of voice arrives: opens and plays.
      g.feed(voice(320));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s.open, isTrue);
      expect(s.fed.length, 1);
      // Stays open while frames keep coming.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        g.feed(voice(320));
      }
      expect(s.open, isTrue);
      expect(s.releases, 0);
      // Quiet: closes by itself, timer gone, no silence was ever fed.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(s.open, isFalse);
      expect(s.releases, 1);
      expect(g.timerRunning, isFalse);
      expect(silentSamples(s.fed), 0, reason: 'no idle silence feed');
      // And instantly again with the next audio.
      g.feed(voice(320));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(s.open, isTrue);
      expect(s.setups, 2);
      await g.dispose();
    });

    test('queued audio is allowed to finish before it closes', () async {
      final s = FakeSpeaker();
      final g = SpeakerGate(
        s,
        sampleRate: 16000,
        channels: 1,
        idle: const Duration(milliseconds: 30),
      );
      // 400 ms of audio queued at once (a clip): must not close early.
      for (var i = 0; i < 20; i++) {
        g.feed(voice(320));
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(s.open, isTrue, reason: 'still playing the queue');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(s.open, isFalse);
      await g.dispose();
    });

    test(
      'first syllable is not clipped or delayed while the speaker opens',
      () async {
        final s = FakeSpeaker(openTime: const Duration(milliseconds: 40));
        final g = SpeakerGate(s, sampleRate: 16000, channels: 1);
        final t0 = DateTime.now();
        // What the engine does for a new burst: 60 ms cushion, then frames.
        g.feedSilence(960);
        for (var i = 0; i < 5; i++) {
          g.feed(voice(320, value: 100 + i));
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(s.setups, 1);
        // Every voice sample arrived, in order, none dropped.
        expect(voiceSamples(s.fed), 5 * 320);
        final firstVoice = s.fed.indexWhere((p) => p[0] != 0);
        expect(
          [for (final p in s.fed.skip(firstVoice)) p[0]],
          [100, 101, 102, 103, 104],
        );
        // The cushion was shortened by the opening time (40 ms of the
        // 60 ms), so the voice starts when it would have anyway.
        final silence = silentSamples(s.fed);
        expect(silence, lessThan(960));
        expect(
          silence,
          lessThanOrEqualTo(960 - 16000 * 30 ~/ 1000),
          reason: 'at least ~30 ms of the 60 ms cushion used up opening',
        );
        expect(DateTime.now().difference(t0).inMilliseconds, lessThan(400));
        await g.dispose();
      },
    );

    test(
      'a release while opening leaves it closed, later audio opens',
      () async {
        final s = FakeSpeaker(openTime: const Duration(milliseconds: 30));
        final g = SpeakerGate(s, sampleRate: 16000, channels: 1);
        g.feed(voice(320));
        final r = g.release(); // flush while it is still opening
        g.feed(voice(320, value: 7)); // audio of the next burst
        await r;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(s.open, isTrue);
        expect(voiceSamples(s.fed), 320, reason: 'only the new burst played');
        expect(s.fed.single[0], 7);
        await g.dispose();
        expect(s.open, isFalse);
      },
    );

    test('the engine never feeds silence by itself', () {
      // Source check: the only silence feed is the 60 ms cushion in play().
      final src = File('lib/audio/audio_engine.dart').readAsStringSync();
      expect(RegExp('feedSilence').allMatches(src).length, 1);
      expect(src.contains('Timer.periodic'), isFalse);
      final gate = File('lib/audio/speaker_gate.dart').readAsStringSync();
      expect(gate.contains('Timer.periodic'), isFalse);
    });
  });

  group('location while idle in the background', () {
    late Directory dir;
    late FakeHost host;
    late TripController t;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trip220');
      host = FakeHost(1);
      t = TripController(
        host: host,
        settings: TripSettings()..tripMode = true,
        dir: dir,
        userAgent: 'test',
      );
      t.tiles.online = false;
      await t.start();
    });
    tearDown(() async {
      t.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test(
      'idle with Trip mode: balanced accuracy, longer interval; busy: high',
      () async {
        // App on screen with the Trip tab visible: high accuracy, 5 s.
        t.setAppForeground(true);
        t.setVisible(true);
        await settle();
        expect(host.locationStarts.last.highAccuracy, isTrue);
        expect(host.locationStarts.last.interval, const Duration(seconds: 5));
        // Background / idle: balanced and slower, but still running.
        t.setAppForeground(false);
        await settle();
        expect(host.locationStarts.last.highAccuracy, isFalse);
        expect(host.locationStarts.last.interval, const Duration(seconds: 45));
        expect(t.locationInterval, isNotNull, reason: 'friends still update');
        // Friends still get positions: a fix goes out.
        final before = host.sent.length;
        t.onFix(Fix(const GeoPoint(45.5, -122.6), DateTime.now()));
        expect(host.sent.length, greaterThan(before));
        // Recording a track needs high accuracy again.
        t.startTrack();
        await settle();
        expect(host.locationStarts.last.highAccuracy, isTrue);
        await t.stopTrack();
        await settle();
        expect(host.locationStarts.last.highAccuracy, isFalse);
        // Navigating: high accuracy.
        await t.navigateTo(
          const GeoPoint(45.51, -122.6),
          name: 'X',
          compass: true,
        );
        await settle();
        expect(host.locationStarts.last.highAccuracy, isTrue);
        await t.stopNav();
        await settle();
        expect(host.locationStarts.last.highAccuracy, isFalse);
        // SOS: high accuracy, 5 s.
        t.onFix(Fix(const GeoPoint(45.5, -122.6), DateTime.now()));
        await t.startSos();
        await settle();
        expect(host.locationStarts.last.highAccuracy, isTrue);
        expect(host.locationStarts.last.interval, const Duration(seconds: 5));
      },
    );

    test('Android bridge passes the accuracy to the phone', () {
      final dart = File('lib/platform/background_bridge.dart')
          .readAsStringSync();
      expect(dart.contains("'accurate': highAccuracy"), isTrue);
      final kt = File(
        'android/app/src/main/kotlin/com/walkie/walkie_talkie/BgBridge.kt',
      ).readAsStringSync();
      expect(kt.contains('accurate: Boolean'), isTrue);
      expect(kt.contains('!accurate &&'), isTrue);
    });
  });
}
