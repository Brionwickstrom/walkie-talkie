// v2.3.3: choppy live audio. The speaker stays open (10 s, never in a talk
// burst) and opens on the talk signal; the playout buffer has an adaptive
// 80-120 ms cushion and a 300 ms cap; concealment uses Opus FEC and elapsed
// time; identical silence-like packets inside a burst are no longer dropped;
// a talk burst keeps its route (smoothed round trip, hysteresis, switch only
// on 2 misses or link loss); the Talk screen has Voice messages and History
// shortcuts and the Chat badge counts missed live talk.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/codec.dart';
import 'package:walkie_talkie/audio/live_gate.dart';
import 'package:walkie_talkie/audio/playout_buffer.dart';
import 'package:walkie_talkie/audio/speaker_gate.dart';
import 'package:walkie_talkie/audio/voice_pipeline.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/link_policy.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/history/talk_history.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/ui/status_line.dart';
import 'package:walkie_talkie/ui/who_can_hear.dart';

import 'home_layout_test.dart' show loadFonts;
import 'messaging_fakes.dart';
import 'v198_failover_test.dart' show LatencyLink, bob, hello, me;
import 'v220_battery_test.dart'
    show FakeSpeaker, silentSamples, voice, voiceSamples;
import 'v231_helpers.dart';

/// A decoder that can rebuild a lost frame from the next packet (like Opus).
class FecDecoder implements VoiceDecoder, FecVoiceDecoder {
  final calls = <String>[];
  @override
  Int16List decode(Uint8List? packet) {
    calls.add(packet == null ? 'plc' : 'pkt');
    return Int16List(320);
  }

  @override
  Int16List decodeFec(Uint8List next) {
    calls.add('fec');
    return Int16List(320);
  }

  @override
  void dispose() {}
}

class PlainDecoder implements VoiceDecoder {
  final calls = <String>[];
  @override
  Int16List decode(Uint8List? packet) {
    calls.add(packet == null ? 'plc' : 'pkt');
    return Int16List(320);
  }

  @override
  void dispose() {}
}

class NoEncoder implements VoiceEncoder {
  @override
  Uint8List encode(Int16List pcm) => Uint8List(1);
  @override
  void dispose() {}
}

Uint8List pkt(int i, {int len = 30}) =>
    Uint8List.fromList([i & 0xFF, (i >> 8) & 0xFF, ...List.filled(len - 2, 7)]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. speaker', () {
    test('stays open 10 s after the last audio (was 1.5 s)', () {
      final g = SpeakerGate(FakeSpeaker(), sampleRate: 16000, channels: 1);
      expect(g.idle, const Duration(seconds: 10));
      final src = File('lib/audio/speaker_gate.dart').readAsStringSync();
      expect(src.contains('Timer.periodic'), isFalse);
    });

    test('never closes while a talker is active, but not forever', () async {
      final s = FakeSpeaker();
      var talker = true;
      final g = SpeakerGate(
        s,
        sampleRate: 16000,
        channels: 1,
        idle: const Duration(milliseconds: 40),
        holdCap: const Duration(milliseconds: 400),
        holdOpen: () => talker,
      );
      g.feed(voice(320));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(s.open, isTrue, reason: 'a pause inside the burst');
      expect(s.releases, 0);
      talker = false;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(s.open, isFalse, reason: 'burst over: closes after the quiet');
      // A lost "talk end" cannot keep it open past the cap.
      talker = true;
      g.feed(voice(320));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(s.open, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(s.open, isFalse, reason: 'holdCap reached');
      await g.dispose();
    });

    test('warmUp opens on the talk signal, before any audio', () async {
      final s = FakeSpeaker(openTime: const Duration(milliseconds: 30));
      final g = SpeakerGate(
        s,
        sampleRate: 16000,
        channels: 1,
        idle: const Duration(milliseconds: 150),
      );
      g.warmUp();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(s.open, isTrue);
      expect(s.setups, 1);
      expect(s.fed, isEmpty, reason: 'warming up feeds nothing');
      // The audio then needs no opening of its own.
      g.feedSilence(1280);
      g.feed(voice(320));
      expect(s.setups, 1);
      expect(s.fed.length, 2);
      expect(silentSamples(s.fed), 1280, reason: 'cushion not trimmed');
      await g.dispose();

      // Talk signal but no audio: it closes again by itself.
      final s2 = FakeSpeaker();
      final g2 = SpeakerGate(
        s2,
        sampleRate: 16000,
        channels: 1,
        idle: const Duration(milliseconds: 60),
      );
      g2.warmUp();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(s2.open, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(s2.open, isFalse);
      expect(g2.timerRunning, isFalse);
      await g2.dispose();
    });

    test(
      'a slow opening keeps a real cushion and tells the playout buffer',
      () async {
        // Opening takes 100 ms: longer than the whole 80 ms cushion.
        final s = FakeSpeaker(openTime: const Duration(milliseconds: 100));
        DateTime? at;
        int? fed;
        final g = SpeakerGate(
          s,
          sampleRate: 16000,
          channels: 1,
          onOpened: (a, f) {
            at = a;
            fed = f;
          },
        );
        g.feedSilence(1280); // 80 ms
        for (var i = 0; i < 3; i++) {
          g.feed(voice(320, value: 50 + i));
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(voiceSamples(s.fed), 3 * 320);
        // At least the 20 ms floor of the cushion is kept (was: all cut).
        expect(silentSamples(s.fed), greaterThanOrEqualTo(320));
        expect(silentSamples(s.fed), lessThan(1280));
        expect(at, isNotNull);
        expect(fed, s.fed.fold<int>(0, (n, p) => n + p.count));
        // The playout clock starts when the speaker really did: its estimate
        // then counts what was handed over, not the full planned cushion.
        var now = DateTime(2026);
        final pb = PlayoutBuffer(sampleRate: 16000, clock: () => now);
        expect(pb.admit(320), 1280);
        now = now.add(const Duration(milliseconds: 100));
        pb.reanchor(now, fed!);
        expect(pb.queuedMs, closeTo(fed! * 1000 ~/ 16000, 1));
        pb.reanchor(now, 0);
        expect(pb.queuedMs, 0);
        await g.dispose();
      },
    );
  });

  group('2. jitter buffer and concealment', () {
    test('cushion is 80 ms when calm, grows with jitter up to 120 ms', () {
      var now = DateTime(2026);
      final pb = PlayoutBuffer(sampleRate: 16000, clock: () => now);
      expect(pb.cushionMs, 80);
      expect(pb.admit(320), 1280);
      // Calm, on-time arrivals: stays at the minimum.
      for (var i = 0; i < 50; i++) {
        pb.noteArrival(1, i);
        now = now.add(const Duration(milliseconds: 20));
      }
      expect(pb.cushionMs, 80);
      expect(pb.jitterMs, lessThan(1));
      // Uneven arrivals (0 / 60 / 0 / 60 ms late): the cushion grows.
      for (var i = 50; i < 120; i++) {
        now = now.add(Duration(milliseconds: i.isEven ? 0 : 40));
        pb.noteArrival(1, i);
        now = now.add(const Duration(milliseconds: 20));
      }
      expect(pb.cushionMs, greaterThan(80));
      expect(pb.cushionMs, lessThanOrEqualTo(120));
      // Wild jitter is capped at 120 ms.
      for (var i = 120; i < 200; i++) {
        now = now.add(Duration(milliseconds: i.isEven ? 0 : 300));
        pb.noteArrival(1, i);
      }
      expect(pb.cushionMs, 120);
      // Calm again: it comes back down slowly.
      for (var i = 200; i < 700; i++) {
        pb.noteArrival(1, i);
        now = now.add(const Duration(milliseconds: 20));
      }
      expect(pb.cushionMs, lessThan(120));
      // The next burst gets the current cushion.
      now = now.add(const Duration(seconds: 2));
      expect(pb.admit(320), pb.cushionMs * 16);
    });

    test('a late burst plays late instead of being dropped (cap 300 ms)', () {
      var now = DateTime(2026);
      final pb = PlayoutBuffer(sampleRate: 16000, clock: () => now);
      expect(pb.admit(320), 1280);
      // 10 frames (200 ms) arrive at once after a stall: all played.
      var dropped = 0;
      for (var i = 0; i < 10; i++) {
        if (pb.admit(320) == null) dropped++;
      }
      expect(dropped, 0, reason: 'was cut at 200 ms before');
      expect(pb.queuedMs, lessThanOrEqualTo(300));
      // A backlog beyond the cap still snaps back.
      for (var i = 0; i < 30; i++) {
        pb.admit(320);
      }
      expect(pb.dropped, greaterThan(0));
      expect(pb.queuedMs, lessThanOrEqualTo(330));
      // Steady real-time audio is never dropped.
      now = now.add(const Duration(seconds: 2));
      final pb2 = PlayoutBuffer(sampleRate: 16000, clock: () => now);
      for (var i = 0; i < 500; i++) {
        expect(pb2.admit(320), isNotNull);
        now = now.add(const Duration(milliseconds: 20));
      }
    });

    test('one lost packet is rebuilt from the next one (FEC)', () {
      final d = FecDecoder();
      final p = VoicePipeline(
        encoderFactory: NoEncoder.new,
        decoderFactory: () => d,
      );
      expect(p.decode(1, 10, pkt(10)), hasLength(1));
      final out = p.decode(1, 12, pkt(12)); // 11 lost
      expect(out, hasLength(2));
      expect(d.calls, ['pkt', 'fec', 'pkt']);
      expect(p.fecFrames, 1);
      expect(p.concealedFrames, 0);
      // Two lost: one concealed, the one right before the packet from FEC.
      d.calls.clear();
      expect(p.decode(1, 15, pkt(15)), hasLength(3)); // 13, 14 lost
      expect(d.calls, ['plc', 'fec', 'pkt']);
    });

    test('a decoder without FEC is concealed as before', () {
      final d = PlainDecoder();
      final p = VoicePipeline(
        encoderFactory: NoEncoder.new,
        decoderFactory: () => d,
      );
      p.decode(1, 10, pkt(10));
      expect(p.decode(1, 12, pkt(12)), hasLength(2));
      expect(d.calls, ['pkt', 'plc', 'pkt']);
      expect(p.fecFrames, 0);
    });

    test('a long gap is concealed by elapsed time, not dropped', () {
      final clock = FakeClock();
      final d = FecDecoder();
      final p = VoicePipeline(
        encoderFactory: NoEncoder.new,
        decoderFactory: () => d,
        clock: clock.call,
      );
      p.decode(1, 100, pkt(100));
      // 8 lost and the next packet comes right away (a path switch): the
      // whole gap is still to be played: 7 concealed + 1 FEC + the packet.
      clock.advance(const Duration(milliseconds: 20));
      d.calls.clear();
      expect(p.decode(1, 109, pkt(109)), hasLength(9));
      expect(d.calls.where((c) => c == 'plc'), hasLength(7));
      expect(d.calls.where((c) => c == 'fec'), hasLength(1));
      // 8 lost and 180 ms really went by in silence already: only the FEC
      // frame (a stall that already played needs nothing more).
      clock.advance(const Duration(milliseconds: 180));
      d.calls.clear();
      expect(p.decode(1, 118, pkt(118)), hasLength(2));
      expect(d.calls, ['fec', 'pkt']);
      // A huge gap is capped at 200 ms of concealment.
      d.calls.clear();
      clock.advance(const Duration(milliseconds: 20));
      final out = p.decode(1, 600, pkt(600));
      expect(out, hasLength(VoicePipeline.maxTimedConceal + 1));
      // Late and duplicate packets are still dropped.
      expect(p.decode(1, 118, pkt(118)), isEmpty);
    });

    test('silence-like identical packets inside a burst are not dropped', () {
      final clock = FakeClock();
      final g = LiveAudioGate(clock: clock.call);
      g.talkChanged(1, true);
      final quiet = Uint8List.fromList([0xF8, 0xFF, 0xFE]);
      String? admit(Uint8List b) {
        final r = g.admit(1, b, talking: true);
        clock.advance(const Duration(milliseconds: 20));
        return r;
      }

      expect(admit(pkt(1)), isNull); // speech starts the burst
      for (var i = 0; i < 30; i++) {
        expect(admit(quiet), isNull, reason: 'pause $i');
      }
      // A speech packet repeated is still a repeat (a delayed copy).
      expect(admit(pkt(2)), isNull);
      expect(admit(pkt(2)), LiveAudioGate.reasonRepeat);
    });

    test('a re-sent burst is still blocked, tiny packets included', () {
      final clock = FakeClock();
      final g = LiveAudioGate(clock: clock.call);
      g.talkChanged(1, true);
      final quiet = Uint8List.fromList([0xF8, 0xFF, 0xFE]);
      for (var i = 0; i < 10; i++) {
        expect(g.admit(1, i == 0 ? pkt(1) : quiet, talking: true), isNull);
        clock.advance(const Duration(milliseconds: 20));
      }
      clock.advance(const Duration(seconds: 3));
      // The same burst again: its first packet is a repeat, so all of it is.
      expect(g.admit(1, pkt(1), talking: true), LiveAudioGate.reasonRepeat);
      for (var i = 0; i < 10; i++) {
        clock.advance(const Duration(milliseconds: 20));
        expect(g.admit(1, quiet, talking: true), LiveAudioGate.reasonRepeat);
      }
    });

    test('the engine and controller are wired to it', () {
      final eng = File('lib/audio/audio_engine.dart').readAsStringSync();
      expect(eng.contains('holdOpen: () => talkerActive'), isTrue);
      expect(eng.contains('_playout.noteArrival'), isTrue);
      expect(eng.contains('reanchor'), isTrue);
      final ctl = File('lib/app/walkie_controller.dart').readAsStringSync();
      expect(ctl.contains('_audio.prepare()'), isTrue);
      expect(ctl.contains('_audio.talkerActive ='), isTrue);
    });
  });

  group('3. routing', () {
    test('smoothed round trip (EWMA)', () {
      const a = Duration(milliseconds: 100);
      expect(LinkPolicy.smoothRtt(null, a), a);
      final s = LinkPolicy.smoothRtt(a, const Duration(milliseconds: 40));
      expect(s.inMilliseconds, closeTo(82, 1)); // 0.7 * 100 + 0.3 * 40
    });

    test('hysteresis: the override is taken strictly, kept loosely', () {
      Duration? rtt(TransportKind k) => switch (k) {
        TransportKind.internet => const Duration(milliseconds: 100),
        TransportKind.lan => const Duration(milliseconds: 60),
        _ => null,
      };
      // 40 ms faster but 60% of the round trip: not clearly faster...
      expect(
        LinkPolicy.rank([TransportKind.internet, TransportKind.lan], rtt: rtt),
        [TransportKind.internet, TransportKind.lan],
      );
      // ... but once it holds the front it keeps it.
      expect(
        LinkPolicy.rank(
          [TransportKind.internet, TransportKind.lan],
          rtt: rtt,
          incumbent: TransportKind.lan,
        ),
        [TransportKind.lan, TransportKind.internet],
      );
      // It loses it when it is no longer meaningfully faster.
      expect(
        LinkPolicy.rank(
          [TransportKind.internet, TransportKind.lan],
          rtt: (k) => k == TransportKind.lan
              ? const Duration(milliseconds: 95)
              : const Duration(milliseconds: 100),
          incumbent: TransportKind.lan,
        ),
        [TransportKind.internet, TransportKind.lan],
      );
      // A failing incumbent never keeps it.
      expect(
        LinkPolicy.rank(
          [TransportKind.internet, TransportKind.lan],
          rtt: rtt,
          incumbent: TransportKind.lan,
          degraded: (k) => k == TransportKind.lan,
        ).first,
        TransportKind.internet,
      );
      // Clearly faster (strict rule) still takes over without an incumbent.
      expect(
        LinkPolicy.rank(
          [TransportKind.internet, TransportKind.lan],
          rtt: (k) => k == TransportKind.lan
              ? const Duration(milliseconds: 20)
              : const Duration(milliseconds: 100),
        ).first,
        TransportKind.lan,
      );
    });

    group('a talk burst keeps its route', () {
      late FakeClock clock;
      late LatencyLink net, lan;
      late TransportManager m;

      setUp(() async {
        clock = FakeClock();
        net = LatencyLink(
          TransportKind.internet,
          clock,
          latency: const Duration(milliseconds: 80),
        );
        lan = LatencyLink(
          TransportKind.lan,
          clock,
          latency: const Duration(milliseconds: 5),
        );
        m = TransportManager(
          transports: [net, lan],
          localNodeId: me,
          localName: 'me',
          clock: clock.call,
          helloInterval: const Duration(hours: 1),
        );
        await m.start();
        lan.deliver(hello(bob, 1));
        net.deliver(hello(bob, 2));
        await m.sendPings();
        lan.answerPings(bob, seq: 100);
        net.answerPings(bob, seq: 200);
        net.sent.clear();
        lan.sent.clear();
      });
      tearDown(() => m.dispose());

      List<int> counts() => [
        net.framesOf(FrameType.audio).length,
        lan.framesOf(FrameType.audio).length,
      ];

      test('pongs feed the smoothed round trip routing ranks on', () async {
        final p = m.peer(bob)!;
        expect(p.rtt[TransportKind.lan], const Duration(milliseconds: 5));
        expect(p.rttSmooth[TransportKind.lan], const Duration(milliseconds: 5));
        lan.latency = const Duration(milliseconds: 45);
        await m.sendPings();
        lan.answerPings(bob, seq: 300);
        expect(p.rtt[TransportKind.lan], const Duration(milliseconds: 45));
        expect(p.rttSmooth[TransportKind.lan]!.inMilliseconds, 17); // EWMA
      });

      test(
        'no switch for a wobbling round trip; the next burst re-chooses',
        () async {
          await m.setTalking(true);
          await m.sendAudio(Uint8List.fromList([1]));
          expect(counts(), [0, 1], reason: 'Wi-Fi is clearly faster');
          // Wi-Fi gets slow (as measured): during the burst nothing changes.
          lan.latency = const Duration(milliseconds: 200);
          for (var i = 0; i < 4; i++) {
            await m.sendPings();
            net.answerPings(bob, seq: 500 + i * 10);
            lan.answerPings(bob, seq: 400 + i * 10);
          }
          net.sent.clear();
          lan.sent.clear();
          await m.sendAudio(Uint8List.fromList([2]));
          expect(counts(), [0, 1], reason: 'held for the burst');
          expect(m.routeSwitches, 0);
          await m.setTalking(false);
          await m.setTalking(true);
          net.sent.clear();
          lan.sent.clear();
          await m.sendAudio(Uint8List.fromList([3]));
          expect(counts(), [1, 0], reason: 'a new burst chooses afresh');
          await m.setTalking(false);
        },
      );

      test('one missed ping adds the backup, two switch; recovery does not '
          'flap', () async {
        await m.setTalking(true);
        await m.sendAudio(Uint8List.fromList([1]));
        expect(counts(), [0, 1]);
        lan.dead = true;
        await m.sendPings();
        net.answerPings(bob, seq: 600); // the internet link is fine
        clock.advance(LinkPolicy.missDeadline(const Duration(milliseconds: 5)));
        clock.advance(const Duration(milliseconds: 1));
        m.checkMisses();
        expect(m.peer(bob)!.misses[TransportKind.lan], 1);
        net.sent.clear();
        lan.sent.clear();
        await m.sendAudio(Uint8List.fromList([2]));
        expect(counts(), [1, 1], reason: 'backup carries it too');
        expect(m.routeSwitches, 0, reason: 'one miss is not a switch');
        // The second miss in a row: the healthy link leads now.
        await m.sendPings();
        net.answerPings(bob, seq: 700);
        clock.advance(const Duration(milliseconds: 900));
        m.checkMisses();
        expect(m.peer(bob)!.misses[TransportKind.lan], 2);
        net.sent.clear();
        lan.sent.clear();
        await m.sendAudio(Uint8List.fromList([3]));
        expect(m.routeSwitches, 1);
        expect(net.framesOf(FrameType.audio), hasLength(1));
        await m.setTalking(false);
      });

      test('real link loss switches at once, even mid-burst', () async {
        await m.setTalking(true);
        await m.sendAudio(Uint8List.fromList([1]));
        expect(counts(), [0, 1]);
        await lan.stop(); // Wi-Fi gone
        net.sent.clear();
        lan.sent.clear();
        await m.sendAudio(Uint8List.fromList([2]));
        expect(counts(), [1, 0]);
        expect(m.routeSwitches, 1);
        await m.setTalking(false);
      });
    });
  });

  group('4. Talk screen shortcuts', () {
    testWidgets('status line shortcuts: small, with a dot only when new', (
      t,
    ) async {
      var voice = 0, history = 0;
      Widget line({required bool vNew, required bool hNew}) => MaterialApp(
        home: Scaffold(
          body: TalkStatusLine(
            audience: const AudienceInfo(Audience.open, channel: 1),
            here: 3,
            netStatus: TransportStatus.running,
            netText: 'Internet via Wi-Fi',
            onOpen: () {},
            onOpenVoice: () => voice++,
            onOpenHistory: () => history++,
            voiceNew: vNew,
            historyUnheard: hNew,
          ),
        ),
      );
      await t.pumpWidget(line(vNew: false, hNew: false));
      expect(find.byKey(const Key('talk-voice-shortcut')), findsOneWidget);
      expect(find.byKey(const Key('talk-history-shortcut')), findsOneWidget);
      expect(find.byKey(const Key('shortcut-dot')), findsNothing);
      expect(find.byTooltip('Voice messages'), findsOneWidget);
      expect(find.byTooltip('History'), findsOneWidget);
      await t.pumpWidget(line(vNew: true, hNew: false));
      expect(find.byKey(const Key('shortcut-dot')), findsOneWidget);
      await t.pumpWidget(line(vNew: true, hNew: true));
      expect(find.byKey(const Key('shortcut-dot')), findsNWidgets(2));
      await t.tap(find.byKey(const Key('talk-voice-shortcut')));
      await t.tap(find.byKey(const Key('talk-history-shortcut')));
      expect([voice, history], [1, 1]);
      // Small: icons of 20 dp in a 32 dp target; the text keeps the room.
      expect(
        t.getSize(find.byKey(const Key('talk-voice-shortcut'))).width,
        lessThanOrEqualTo(40),
      );
    });

    group('on the real Talk screen', () {
      setUpAll(loadFonts);

      testWidgets('shortcuts open Voice messages and History; 360 dp, 1.3x '
          'text, nothing overlaps', (t) async {
        phone(t);
        final c = await makeController(t, group: 'Ski patrol');
        await t.pumpWidget(homeApp(c));
        await settle(t);
        expect(t.takeException(), isNull);
        final voiceBtn = find.byKey(const Key('talk-voice-shortcut'));
        final histBtn = find.byKey(const Key('talk-history-shortcut'));
        expect(voiceBtn, findsOneWidget);
        expect(histBtn, findsOneWidget);
        // Still one status line, no banner, the people list and the four
        // action buttons are where they were.
        expect(find.byKey(const Key('status-line-text')), findsOneWidget);
        expect(find.byKey(const Key('ring-all')), findsOneWidget);
        expect(find.byKey(const Key('beep-all')), findsOneWidget);
        final text = t.getRect(find.byKey(const Key('status-line-text')));
        expect(text.right, lessThanOrEqualTo(t.getRect(voiceBtn).left + 0.5));
        expect(
          t.getRect(voiceBtn).right,
          lessThanOrEqualTo(t.getRect(histBtn).left + 0.5),
        );
        expect(
          t.getRect(histBtn).right,
          lessThanOrEqualTo(t.getSize(find.byType(MaterialApp)).width),
        );
        await t.tap(voiceBtn);
        await settle(t);
        expect(find.text('Voice messages'), findsWidgets);
        expect(t.takeException(), isNull);
        await t.pageBack();
        await settle(t);
        await t.tap(histBtn);
        await settle(t);
        expect(find.textContaining('History ·'), findsOneWidget);
        await t.pageBack();
        await settle(t);
        await finish(t);
      });

      testWidgets('the Chat badge counts missed live talk too', (t) async {
        phone(t);
        final c = await makeController(t);
        final h = TalkHistory(storage: MemoryMessageStorage());
        await t.runAsync(h.load);
        c.history = h;
        await t.pumpWidget(homeApp(c));
        await settle(t);
        final tabs = find.byKey(const Key('mainTabs'));
        expect(
          find.descendant(of: tabs, matching: find.byType(Badge)),
          findsWidgets,
        );
        bool chatBadge1() => find
            .descendant(of: tabs, matching: find.text('1'))
            .evaluate()
            .isNotEmpty;
        expect(chatBadge1(), isFalse);
        // 30 packets (600 ms) from someone else, not heard (app closed).
        for (var i = 0; i < 30; i++) {
          h.addPacket(scope: c.scope, sender: 7, name: 'Pat', opus: pkt(i));
        }
        h.endTake(7);
        expect(c.unheardTakes, 1);
        await finish(t);
        await t.pumpWidget(homeApp(c));
        await settle(t);
        expect(chatBadge1(), isTrue, reason: 'missed talk on the Chat tab');
        await finish(t);
      });
    });
  });
}
