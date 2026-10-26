import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/mic_gate.dart';
import 'package:walkie_talkie/messaging/inbox.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';
import 'package:walkie_talkie/messaging/voice_transfer.dart';

import 'messaging_fakes.dart';

VoiceClip clip([int packets = 60]) =>
    VoiceClip([for (var i = 0; i < packets; i++) Uint8List(70)..[0] = i]);

void main() {
  group('MicGate (v1.5.0 endless replay root cause)', () {
    test('a stop during start really turns the mic off', () async {
      final opening = Completer<Stream<Uint8List>>();
      final mic = StreamController<Uint8List>();
      var closed = 0;
      final gate = MicGate(
        open: () => opening.future,
        close: () async => closed++,
      );
      final got = <Uint8List>[];
      final start = gate.start(got.add); // finger down
      final stop = gate.stop(); // finger up before the mic opened
      opening.complete(mic.stream);
      await start;
      expect(await stop, isTrue);
      expect(gate.active, isFalse);
      expect(closed, 1);
      mic.add(Uint8List(10)); // late audio from the mic
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      await mic.close();
    });

    test('rapid taps never leave the mic on', () async {
      var opens = 0, closes = 0;
      final gate = MicGate(
        open: () async {
          opens++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return const Stream<Uint8List>.empty();
        },
        close: () async => closes++,
      );
      final ops = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        ops
          ..add(gate.start((_) {}))
          ..add(gate.stop());
      }
      await Future.wait(ops);
      expect(gate.active, isFalse);
      expect(opens, closes);
    });
  });

  group('voice message delivery', () {
    late FakeNet net;
    late FakeClock clock;

    Messenger make(FakeNode n, MessageStorage st, {int maxAttempts = 30}) =>
        Messenger(
          link: n,
          storage: st,
          clock: clock.call,
          maxAttempts: maxAttempts,
        );

    Future<void> run(List<Messenger> ms, int ticks) async {
      for (var i = 0; i < ticks; i++) {
        clock.advance(const Duration(milliseconds: 50));
        for (final m in ms) {
          await m.tick();
        }
        await net.settle();
      }
    }

    setUp(() {
      net = FakeNet();
      clock = FakeClock();
    });

    test('3 transports + lost acks: received exactly once', () async {
      final a = net.add(1), b = net.add(2);
      net.copies = 3; // Wi-Fi + Bluetooth + relay
      var acksDropped = 0;
      net.drop = (from, to, p) {
        // Lose the first 6 acks from the receiver.
        if (from == 2 && DataPacket.tryDecode(p) is AckPacket) {
          return acksDropped++ < 6;
        }
        return false;
      };
      final sa = MemoryMessageStorage(), sb = MemoryMessageStorage();
      final ma = make(a, sa), mb = make(b, sb);
      await ma.start();
      await mb.start();
      final got = <InboxEntry>[];
      mb.received.listen(got.add);
      await ma.send(clip(), toPeer: 2, channel: 1);
      await run([ma, mb], 600);
      expect(got, hasLength(1));
      expect(mb.inbox.entries, hasLength(1));
      expect(ma.outbox.entries, isEmpty, reason: 'sender stopped resending');

      // Deleted on the receiver, then the sender's re-send arrives (from a
      // backup / an ack lost before a restart): not shown again, even
      // after the receiver restarts.
      await mb.deleteReceived(mb.inbox.entries.single);
      await mb.dispose();
      final mb2 = make(b, sb);
      await mb2.start();
      final again = <InboxEntry>[];
      mb2.received.listen(again.add);
      final id = got.single.msgId;
      // Replay the whole message by hand with the same id.
      final s = TransferSender(
        msgId: id,
        to: 2,
        body: clip().encode(),
        durationMs: clip().durationMs,
        channelMessage: false,
        now: clock.now,
        chunkSize: 1000,
      );
      for (final pkt in s.due(clock.now, TransferPacing.fast)) {
        await a.sendData(2, pkt);
      }
      await run([mb2], 20);
      expect(again, isEmpty);
      expect(mb2.inbox.entries, isEmpty);
      await ma.dispose();
      await mb2.dispose();
    });

    test(
      'no acks at all: the sender gives up, receiver shows it once',
      () async {
        final a = net.add(1), b = net.add(2);
        net.copies = 3;
        net.drop = (from, to, p) => from == 2; // every ack lost
        final ma = make(a, MemoryMessageStorage(), maxAttempts: 4);
        final mb = make(b, MemoryMessageStorage());
        await ma.start();
        await mb.start();
        final got = <InboxEntry>[];
        mb.received.listen(got.add);
        await ma.send(clip(), toPeer: 2, channel: 1);
        // 4 attempts x (8 s stall + 3 s retry) is well under 2000 ticks.
        await run([ma, mb], 2000);
        expect(got, hasLength(1));
        expect(ma.outbox.entries, isEmpty);
        final sentBefore = net.sent;
        await run([ma, mb], 200);
        expect(net.sent, sentBefore, reason: 'nothing is re-sent any more');
      },
    );
  });
}
