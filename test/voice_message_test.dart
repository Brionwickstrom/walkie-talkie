import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/messaging/inbox.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';
import 'package:walkie_talkie/messaging/voice_transfer.dart';

import 'messaging_fakes.dart';

VoiceClip fakeClip(int packets, {int seed = 1}) {
  final r = Random(seed);
  return VoiceClip([
    for (var i = 0; i < packets; i++)
      Uint8List.fromList(
        List.generate(20 + r.nextInt(30), (_) => r.nextInt(256)),
      ),
  ]);
}

Future<void> run(
  FakeNet net,
  FakeClock clock,
  List<Messenger> ms, {
  int steps = 200,
}) async {
  for (var i = 0; i < steps; i++) {
    clock.advance(const Duration(milliseconds: 50));
    for (final m in ms) {
      await m.tick();
    }
    await net.settle();
  }
}

const _wide = TransferPacing(
  window: 100,
  burst: 100,
  rto: Duration(seconds: 1),
);

void main() {
  group('VoiceClip', () {
    test('encode/decode round trip and duration', () {
      final c = fakeClip(50);
      final back = VoiceClip.tryDecode(c.encode())!;
      expect(back.packets.length, 50);
      for (var i = 0; i < 50; i++) {
        expect(back.packets[i], c.packets[i]);
      }
      expect(back.durationMs, 1000);
      expect(formatDuration(12400), '0:12');
      expect(VoiceClip.tryDecode(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('chunk / ack packets', () {
    test('chunk round trip', () {
      final c = ChunkPacket(
        msgId: 0xDEADBEEF,
        to: 0xFFFFFFFE,
        index: 7,
        total: 9,
        durationMs: 12000,
        channelMessage: true,
        data: Uint8List.fromList([1, 2, 3]),
      );
      final d = DataPacket.tryDecode(c.encode()) as ChunkPacket;
      expect(d.msgId, 0xDEADBEEF);
      expect(d.to, 0xFFFFFFFE);
      expect(d.index, 7);
      expect(d.total, 9);
      expect(d.durationMs, 12000);
      expect(d.channelMessage, isTrue);
      expect(d.data, [1, 2, 3]);
    });

    test('ack round trip and acked indexes', () {
      final a = AckPacket(
        msgId: 5,
        to: 6,
        total: 40,
        nextMissing: 3,
        bitmap: 0x5,
      );
      final d = DataPacket.tryDecode(a.encode()) as AckPacket;
      expect(d.ackedIndexes.toList(), [0, 1, 2, 4, 6]);
      expect(d.complete, isFalse);
      expect(
        AckPacket(
          msgId: 1,
          to: 1,
          total: 4,
          nextMissing: 4,
          bitmap: 0,
        ).complete,
        isTrue,
      );
    });

    test('garbage is rejected', () {
      expect(DataPacket.tryDecode(Uint8List(0)), isNull);
      expect(DataPacket.tryDecode(Uint8List.fromList([1, 0, 0])), isNull);
      expect(DataPacket.tryDecode(Uint8List.fromList([9, 0, 0])), isNull);
    });

    test('a Bluetooth chunk fits one BLE packet / the fragment limit', () {
      final frame = Frame.headerSize + ChunkPacket.headerSize + bleChunkSize;
      // One packet at MTU 185 (182 usable - 2 byte fragment prefix).
      expect(frame, lessThanOrEqualTo(180));
      // 15 fragments x 18 bytes at the 23 byte default MTU.
      expect(frame, lessThanOrEqualTo(270));
    });
  });

  group('sender / receiver', () {
    test('split + reassemble out of order with duplicates', () {
      final body = Uint8List.fromList(List.generate(1234, (i) => i & 0xFF));
      final now = DateTime(2026);
      final s = TransferSender(
        msgId: 1,
        to: 2,
        body: body,
        durationMs: 1000,
        channelMessage: false,
        now: now,
        chunkSize: 100,
      );
      expect(s.total, 13);
      final pkts = s
          .due(now, _wide)
          .map((b) => DataPacket.tryDecode(b) as ChunkPacket)
          .toList();
      expect(pkts.length, 13);
      final r = TransferReceiver(
        sender: 1,
        msgId: 1,
        total: 13,
        durationMs: 1000,
        channelMessage: false,
        now: now,
      );
      for (final p in pkts.reversed) {
        r.add(p, now);
      }
      expect(r.add(pkts[3], now), isFalse); // duplicate
      expect(r.complete, isTrue);
      expect(r.assemble(), body);
      final ack = r.ack();
      expect(ack.complete, isTrue);
      s.onAck(ack, now);
      expect(s.complete, isTrue);
    });

    test('window limits in-flight chunks and timeouts resend', () {
      final now = DateTime(2026);
      final s = TransferSender(
        msgId: 1,
        to: 2,
        body: Uint8List(2000),
        durationMs: 1000,
        channelMessage: false,
        now: now,
        chunkSize: 100,
      );
      const pacing = TransferPacing(
        window: 5,
        burst: 3,
        rto: Duration(milliseconds: 500),
      );
      expect(s.due(now, pacing).length, 3);
      expect(s.due(now, pacing).length, 2); // window of 5 reached
      expect(s.due(now, pacing), isEmpty);
      // Acking 0..1 frees two slots.
      s.onAck(
        AckPacket(msgId: 1, to: 1, total: 20, nextMissing: 2, bitmap: 0),
        now,
      );
      expect(s.due(now, pacing).length, 2);
      // After the timeout the unacked ones go out again, oldest first.
      final later = now.add(const Duration(milliseconds: 600));
      final again = s
          .due(later, pacing)
          .map((b) => (DataPacket.tryDecode(b) as ChunkPacket).index)
          .toList();
      expect(again, [2, 3, 4]);
    });

    test('receiver ack reports gaps', () {
      final now = DateTime(2026);
      final r = TransferReceiver(
        sender: 1,
        msgId: 9,
        total: 10,
        durationMs: 0,
        channelMessage: false,
        now: now,
      );
      for (final i in [0, 1, 3, 5]) {
        r.add(
          ChunkPacket(
            msgId: 9,
            to: 2,
            index: i,
            total: 10,
            durationMs: 0,
            channelMessage: false,
            data: Uint8List(1),
          ),
          now,
        );
      }
      final a = r.ack();
      expect(a.nextMissing, 2);
      expect(a.ackedIndexes.toList(), [0, 1, 3, 5]);
    });
  });

  group('Messenger end to end', () {
    late FakeNet net;
    late FakeClock clock;

    Messenger make(int id, {int channel = 1}) {
      final node = net.add(id, channel: channel);
      final m = Messenger(
        link: node,
        storage: MemoryMessageStorage(),
        clock: clock.call,
        random: Random(id),
      );
      node.data.listen(m.onData);
      return m;
    }

    setUp(() {
      net = FakeNet();
      clock = FakeClock();
    });

    test('delivers a 30 s message over a clean link', () async {
      final a = make(1);
      final b = make(2);
      final received = <InboxEntry>[];
      b.received.listen(received.add);
      final delivered = <int>[];
      a.delivered.listen((d) => delivered.add(d.$2));
      await a.send(fakeClip(1500), toPeer: 2, channel: 1); // 30 s
      await run(net, clock, [a, b], steps: 100);
      await net.settle();
      expect(received.length, 1);
      expect(received.single.durationMs, 30000);
      expect(received.single.senderName, 'Node 1');
      final body = await b.bodyOf(received.single);
      expect(VoiceClip.tryDecode(body!)!.packets.length, 1500);
      expect(delivered, [2]);
      expect(a.outbox.entries, isEmpty);
    });

    test('survives 30% loss in both directions', () async {
      final a = make(1);
      final b = make(2);
      final r = Random(7);
      net.drop = (_, _, _) => r.nextDouble() < 0.3;
      final received = <InboxEntry>[];
      b.received.listen(received.add);
      await a.send(fakeClip(400), toPeer: 2, channel: 1);
      await run(net, clock, [a, b], steps: 400);
      expect(received.length, 1);
      expect(
        VoiceClip.tryDecode((await b.bodyOf(received.single))!)!.packets.length,
        400,
      );
      expect(a.outbox.entries, isEmpty);
    });

    test('over Bluetooth: small chunks, slower pacing, 10% loss', () async {
      net.linkKind = TransportKind.ble;
      final a = make(1);
      final b = make(2);
      final r = Random(3);
      var maxLen = 0;
      net.drop = (_, _, p) {
        if (p.length > maxLen) maxLen = p.length;
        return r.nextDouble() < 0.1;
      };
      await a.send(fakeClip(250), toPeer: 2, channel: 1); // 5 s
      await run(net, clock, [a, b], steps: 600);
      expect(b.inbox.entries.length, 1);
      expect(maxLen, ChunkPacket.headerSize + bleChunkSize);
      expect(a.outbox.entries, isEmpty);
    });

    test('a lost final ack does not duplicate the message', () async {
      final a = make(1);
      final b = make(2);
      var dropAcks = true;
      net.drop = (from, _, p) =>
          dropAcks && from == 2 && p[0] == DataPacket.ackType;
      final received = <InboxEntry>[];
      b.received.listen(received.add);
      await a.send(fakeClip(20), toPeer: 2, channel: 1);
      await run(net, clock, [a, b], steps: 40);
      expect(received.length, 1);
      expect(a.outbox.entries.length, 1); // sender never heard the ack
      dropAcks = false;
      await run(net, clock, [a, b], steps: 300);
      expect(received.length, 1);
      expect(b.inbox.entries.length, 1);
      expect(a.outbox.entries, isEmpty);
    });

    test('channel message goes to everyone on the channel', () async {
      final a = make(1);
      final b = make(2);
      final c = make(3);
      final other = make(4, channel: 2);
      await a.send(fakeClip(30), channel: 1);
      await run(net, clock, [a, b, c, other], steps: 60);
      expect(b.inbox.entries.single.channelMessage, isTrue);
      expect(c.inbox.entries.length, 1);
      expect(other.inbox.entries, isEmpty);
      expect(a.outbox.entries, isEmpty);
    });

    test('file storage round trip', () async {
      final dir = await Directory.systemTemp.createTemp('wt_msgs');
      try {
        final s = FileMessageStorage(Directory('${dir.path}/voice'));
        await s.writeJson('x.json', [1, 2]);
        expect(await s.readJson('x.json'), [1, 2]);
        await s.putBlob('b.wtv', Uint8List.fromList([9, 8]));
        expect(await s.getBlob('b.wtv'), [9, 8]);
        await s.deleteBlob('b.wtv');
        expect(await s.getBlob('b.wtv'), isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
