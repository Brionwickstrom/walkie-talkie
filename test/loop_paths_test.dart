// v1.5.2: every way one phone could play the same audio over and over,
// with older (1.5.0 and earlier) phones on the channel.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/playback_log.dart';
import 'package:walkie_talkie/audio/codec.dart';
import 'package:walkie_talkie/audio/live_gate.dart';
import 'package:walkie_talkie/audio/voice_pipeline.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/history/talk_history.dart';
import 'package:walkie_talkie/messaging/inbox.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';
import 'package:walkie_talkie/messaging/voice_transfer.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart';

/// A distinct 20 ms Opus-like packet (like a real encoder's output).
Uint8List pkt(int i) => Uint8List.fromList([i & 0xFF, (i >> 8) & 0xFF, 7, 9]);

class _Enc implements VoiceEncoder {
  @override
  Uint8List encode(Int16List pcm) => Uint8List(1);
  @override
  void dispose() {}
}

class _Dec implements VoiceDecoder {
  final calls = <Uint8List?>[];
  @override
  Int16List decode(Uint8List? packet) {
    calls.add(packet);
    return Int16List(VoiceFormat.samplesPerFrame);
  }

  @override
  void dispose() {}
}

void main() {
  group('LiveAudioGate: a mic left on by an older phone', () {
    late FakeClock clock;
    late LiveAudioGate gate;
    var n = 0;

    /// Feed [ms] of 20 ms frames from [peer]; returns how many may play.
    int feed(int peer, int ms, {required bool? talking}) {
      var played = 0;
      for (var t = 0; t < ms; t += 20) {
        if (gate.admit(peer, pkt(n++), talking: talking) == null) played++;
        clock.advance(const Duration(milliseconds: 20));
      }
      return played;
    }

    setUp(() {
      clock = FakeClock();
      gate = LiveAudioGate(clock: clock.call);
    });

    test('stream after talk end is cut after the 1 s tail, for good', () {
      expect(feed(1, 2000, talking: true), 100); // real talk plays
      gate.talkChanged(1, false); // talk end
      final after = feed(1, 10 * 60 * 1000, talking: false); // 10 min stuck
      expect(after, lessThanOrEqualTo(51), reason: 'only the 1 s tail');
      // They press talk again: heard again.
      gate.talkChanged(1, true);
      expect(feed(1, 1000, talking: true), 50);
    });

    test('mic opened after the button was released (the race) is cut', () {
      gate.talkChanged(1, true);
      gate.talkChanged(1, false); // quick tap: start + end, no audio yet
      clock.advance(const Duration(milliseconds: 300));
      final played = feed(1, 60 * 1000, talking: false);
      expect(played, lessThanOrEqualTo(40));
    });

    test('two older phones echoing each other: each heard at most ~1 s', () {
      for (final p in [1, 2]) {
        gate.talkChanged(p, true);
        gate.talkChanged(p, false);
      }
      var played = 0;
      for (var i = 0; i < 30000; i++) {
        // 10 minutes, both streaming the same "old message" back and forth
        final p = 1 + i % 2;
        if (gate.admit(p, pkt(i ~/ 2), talking: false) == null) played++;
        if (p == 2) clock.advance(const Duration(milliseconds: 20));
      }
      expect(played, lessThanOrEqualTo(2 * 51));
    });

    test('lost talk start: still plays (up to 30 s), then cut', () {
      expect(feed(1, 5000, talking: false), 250);
      expect(feed(1, 120 * 1000, talking: false), lessThanOrEqualTo(1251));
    });

    test('very long non-stop talk is capped at 3 minutes', () {
      gate.talkChanged(1, true);
      final played = feed(1, 5 * 60 * 1000, talking: true);
      expect(played, closeTo(9000, 2));
    });

    test('an identical packet within 30 s never plays twice', () {
      gate.talkChanged(1, true);
      final p = pkt(42);
      expect(gate.admit(1, p, talking: true), isNull);
      clock.advance(const Duration(seconds: 5));
      expect(gate.admit(1, p, talking: true), LiveAudioGate.reasonRepeat);
      clock.advance(const Duration(seconds: 31));
      expect(gate.admit(1, p, talking: true), isNull);
    });

    test('Stop silences everyone until they talk again', () {
      gate.talkChanged(1, true);
      expect(feed(1, 400, talking: true), 20);
      gate.silenceAll();
      expect(feed(1, 5000, talking: true), 0);
      gate.talkChanged(1, false);
      clock.advance(const Duration(seconds: 2));
      gate.talkChanged(1, true);
      expect(feed(1, 400, talking: true), 20);
    });

    test('1:1 talk (no talk signals): Stop holds until a new burst', () {
      expect(feed(-5, 400, talking: null), 20);
      gate.silenceAll();
      expect(feed(-5, 3000, talking: null), 0);
      clock.advance(const Duration(seconds: 2)); // they let go
      expect(feed(-5, 400, talking: null), 20);
    });
  });

  test('through the transport manager: older phone with a stuck mic', () async {
    var now = DateTime(2026);
    final lan = FakeTransport(TransportKind.lan);
    final m = TransportManager(
      transports: [lan],
      localNodeId: 1,
      localName: 'me',
      clock: () => now,
      helloInterval: const Duration(hours: 1),
    );
    await m.start();
    final gate = LiveAudioGate(clock: () => now);
    var played = 0;
    m.audio.listen((a) {
      final talking = m.peer(a.peerId)?.talking ?? false;
      if (gate.admit(a.peerId, a.opus, talking: talking) == null) played++;
    });
    var seq = 100, aseq = 0;
    Future<void> control(ControlKind k) async {
      lan.deliver(
        Frame.control(
          senderId: 9,
          channel: 1,
          seq: seq++,
          message: ControlMessage(k),
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    Future<void> audio(int count) async {
      for (var i = 0; i < count; i++) {
        lan.deliver(
          Frame(
            type: FrameType.audio,
            senderId: 9,
            channel: 1,
            seq: aseq++ & 0xFFFF,
            payload: pkt(aseq),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(milliseconds: 20));
      }
    }

    await control(ControlKind.hello);
    await control(ControlKind.talkStart);
    await audio(50);
    await control(ControlKind.talkEnd);
    await audio(50 * 120); // 2 minutes of the stuck mic
    expect(played, lessThanOrEqualTo(101));
    await m.dispose();
  });

  group('jitter / concealment never repeats a packet', () {
    test('a gap is concealed (no packet re-decoded), big gaps skipped', () {
      final dec = _Dec();
      final p = VoicePipeline(
        encoderFactory: _Enc.new,
        decoderFactory: () => dec,
      );
      p.decode(1, 10, pkt(10));
      p.decode(1, 12, pkt(12)); // 11 lost
      expect(dec.calls.whereType<Uint8List>(), hasLength(2));
      expect(dec.calls.where((c) => c == null), hasLength(1));
      p.decode(1, 40, pkt(40)); // 27 lost: skip, no concealment
      expect(dec.calls.where((c) => c == null), hasLength(1));
      // Late / duplicate packets are dropped.
      expect(p.decode(1, 12, pkt(12)), isEmpty);
      expect(p.decode(1, 40, pkt(40)), isEmpty);
    });

    test(
      'after talk end the decoder forgets; the gate catches late copies',
      () {
        final dec = _Dec();
        final p = VoicePipeline(
          encoderFactory: _Enc.new,
          decoderFactory: () => dec,
        );
        final clock = FakeClock();
        final gate = LiveAudioGate(clock: clock.call);
        gate.talkChanged(1, true);
        var played = 0;
        void rx(int seq) {
          if (gate.admit(1, pkt(seq), talking: true) != null) return;
          played += p.decode(1, seq, pkt(seq)).length;
          clock.advance(const Duration(milliseconds: 20));
        }

        for (var s = 0; s < 50; s++) {
          rx(s);
        }
        p.resetPeer(1); // talk end
        // A slow relay delivers the same burst again 3 s later.
        clock.advance(const Duration(seconds: 3));
        for (var s = 0; s < 50; s++) {
          rx(s);
        }
        expect(played, 50);
      },
    );
  });

  group('voice messages from older phones', () {
    late FakeNet net;
    late FakeClock clock;
    Messenger make(FakeNode n, MessageStorage st) =>
        Messenger(link: n, storage: st, clock: clock.call);
    Future<void> run(List<Messenger> ms, int ticks) async {
      for (var i = 0; i < ticks; i++) {
        clock.advance(const Duration(milliseconds: 50));
        for (final m in ms) {
          await m.tick();
        }
        await net.settle();
      }
    }

    Future<void> sendRaw(FakeNode from, int to, int id, Uint8List body) async {
      final s = TransferSender(
        msgId: id,
        to: to,
        body: body,
        durationMs: 1200,
        channelMessage: false,
        now: clock.now,
        chunkSize: 1000,
      );
      for (final p in s.due(clock.now, TransferPacing.fast)) {
        await from.sendData(to, p);
      }
    }

    VoiceClip clip() => VoiceClip([for (var i = 0; i < 60; i++) pkt(i)]);

    setUp(() {
      net = FakeNet();
      clock = FakeClock();
    });

    test('send time rides along; old apps read the clip unchanged', () {
      final t = DateTime(2026, 10, 25, 12, 1, 2);
      final bytes = clip().encode(sentAt: t);
      final back = VoiceClip.tryDecode(bytes)!;
      expect(back.sentAt, t);
      expect(back.packets, hasLength(60));
      // An old app's decoder reads exactly `count` packets: same bytes as
      // a clip without the trailer, plus 10 ignored bytes.
      final legacy = clip().encode();
      expect(bytes.sublist(0, legacy.length), legacy);
      expect(VoiceClip.tryDecode(legacy)!.sentAt, isNull);
    });

    test(
      'fresh message keeps its time; legacy has none; ancient dropped',
      () async {
        final a = net.add(1), b = net.add(2);
        final ma = make(a, MemoryMessageStorage());
        final mb = make(b, MemoryMessageStorage());
        await ma.start();
        await mb.start();
        final got = <InboxEntry>[];
        mb.received.listen(got.add);
        await ma.send(clip(), toPeer: 2, channel: 1);
        await run([ma, mb], 100);
        expect(got.single.sentAt, isNotNull);

        await sendRaw(a, 2, 777, clip().encode()); // 1.5.1-or-older sender
        await run([mb], 10);
        expect(got.last.msgId, 777);
        expect(got.last.sentAt, isNull);

        final old = clock.now.subtract(const Duration(days: 2));
        await sendRaw(a, 2, 888, clip().encode(sentAt: old));
        await run([mb], 10);
        expect(got.map((e) => e.msgId), isNot(contains(888)));
        expect(mb.hasSeen(1, 888), isTrue, reason: 'acked, never again');
      },
    );

    test('clearAll: nothing old is ever sent again or shown again', () async {
      final a = net.add(1), b = net.add(2);
      net.allConnected = false; // b out of range: message stays queued
      final sa = MemoryMessageStorage(), sb = MemoryMessageStorage();
      var ma = make(a, sa);
      final mb = make(b, sb);
      await ma.start();
      await mb.start();
      await ma.send(clip(), toPeer: 2, channel: 1);
      expect(ma.outbox.entries, hasLength(1));
      await ma.clearAll(); // the one-time 1.5.2 migration
      await ma.dispose();
      ma = make(a, sa); // app restarted
      await ma.start();
      expect(ma.outbox.entries, isEmpty);
      net.allConnected = true;
      final sent = net.sent;
      await run([ma, mb], 200);
      expect(net.sent, sent, reason: 'old outbox never re-sent');

      // Receiver side: a message it already has, then clearAll(delete).
      final got = <InboxEntry>[];
      mb.received.listen(got.add);
      await sendRaw(a, 2, 555, clip().encode());
      await run([mb], 10);
      expect(got, hasLength(1));
      await mb.clearAll(deleteInbox: true);
      expect(mb.inbox.entries, isEmpty);
      await sendRaw(a, 2, 555, clip().encode()); // older phone re-sends it
      await run([mb], 10);
      expect(got, hasLength(1));
      expect(mb.inbox.entries, isEmpty);
    });
  });

  group('history ("Missed") never re-queues', () {
    test('played takes stay heard; migration marks everything heard', () async {
      final clock = FakeClock();
      final h = TalkHistory(storage: MemoryMessageStorage(), clock: clock.call);
      for (final scope in [1, 2]) {
        for (var i = 0; i < 50; i++) {
          h.addPacket(scope: scope, sender: 9, name: 'Old', opus: pkt(i));
          clock.advance(const Duration(milliseconds: 20));
        }
        h.endTake(9);
      }
      expect(h.unheardIn(1), 1);
      h.markHeard(h.takesFor(1).single);
      expect(h.takesFor(1).where((t) => !t.heard), isEmpty);
      h.markEverythingHeard();
      expect(h.unheardIn(2), 0);
      await h.clearAll();
      expect(h.takesFor(1), isEmpty);
      expect(h.takesFor(2), isEmpty);
    });
  });

  test('playback log: one line per burst / change, not 50 per second', () {
    final clock = FakeClock();
    final log = PlaybackLog(clock: clock.call);
    for (var i = 0; i < 100; i++) {
      log.stream('ch1', 'live', 'Bob #1 via lan');
      clock.advance(const Duration(milliseconds: 20));
    }
    log.stream('ch1', 'live-blocked', 'Bob #1 via lan: not talking');
    clock.advance(const Duration(seconds: 3));
    log.stream('ch1', 'live', 'Bob #1 via lan');
    expect(log.events.map((e) => e.kind), ['live', 'live-blocked', 'live']);
  });
}
