import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/time_stretch.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/history/talk_history.dart';
import 'package:walkie_talkie/messaging/ringer.dart';
import 'package:walkie_talkie/messaging/storage.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart';

Int16List sine(double hz, int n, {double amp = 8000}) => Int16List.fromList([
  for (var i = 0; i < n; i++)
    (amp * math.sin(2 * math.pi * hz * i / 16000)).round(),
]);

/// Zero crossings per second (a rough pitch measure).
double crossingsPerSec(Int16List x) {
  var c = 0;
  for (var i = 1; i < x.length; i++) {
    if ((x[i - 1] < 0) != (x[i] < 0)) c++;
  }
  return c / (x.length / 16000);
}

Uint8List pkt(int i) => Uint8List.fromList([i & 0xFF, 1, 2, 3]);

void main() {
  group('time stretch (1.5x / 2x replay)', () {
    test('speeds up without changing pitch', () {
      final x = sine(440, 16000 * 2);
      for (final speed in [1.5, 2.0]) {
        final y = timeStretch(x, speed);
        expect(y.length, closeTo(x.length / speed, 400));
        expect(crossingsPerSec(y), closeTo(crossingsPerSec(x), 30));
        // No clipping / blow-up.
        expect(y.reduce(math.max), lessThan(9000));
      }
    });

    test('1x is a no-op', () {
      final x = sine(300, 4000);
      expect(identical(timeStretch(x, 1), x), isTrue);
    });
  });

  group('talk history', () {
    late MemoryMessageStorage store;
    late DateTime now;
    late TalkHistory h;

    setUp(() async {
      store = MemoryMessageStorage();
      now = DateTime(2026, 10, 25, 12);
      h = TalkHistory(storage: store, clock: () => now);
      await h.load();
    });

    void talk(
      int sender,
      int packets, {
      int scope = 1,
      bool heard = false,
      bool mine = false,
    }) {
      for (var i = 0; i < packets; i++) {
        h.addPacket(
          scope: scope,
          sender: sender,
          name: 'P$sender',
          opus: pkt(i),
          heard: heard,
          mine: mine,
        );
        now = now.add(const Duration(milliseconds: 20));
      }
    }

    test(
      'records transmissions per sender, ends on talk-end or silence',
      () async {
        talk(7, 100); // 2 s, not heard (app closed)
        h.endTake(7);
        talk(8, 50, heard: true);
        now = now.add(const Duration(seconds: 2));
        h.tick(); // silence closes it
        talk(1, 30, mine: true);
        h.endTake(1);
        await h.flush();
        final list = h.takesFor(1);
        expect(list.map((t) => t.sender), [1, 8, 7]); // newest first
        expect(list.last.durationMs, 2000);
        expect(h.unheardIn(1), 1); // only 7: own is always heard
        expect(list.first.mine, isTrue);
        final packets = await h.packetsOf(list.last);
        expect(packets!.length, 100);
        expect(packets[5], pkt(5));
      },
    );

    test('a transmission partly missed counts as not heard', () async {
      h.addPacket(scope: 1, sender: 7, name: 'x', opus: pkt(0), heard: true);
      for (var i = 0; i < 40; i++) {
        h.addPacket(
          scope: 1,
          sender: 7,
          name: 'x',
          opus: pkt(i),
          heard: i < 10,
        );
      }
      h.endTake(7);
      expect(h.unheardIn(1), 1);
      h.markHeard(h.takesFor(1).single);
      expect(h.unheardIn(1), 0);
    });

    test('ignores blips, keeps channels (and private scopes) apart', () {
      talk(7, 5); // 100 ms
      h.endTake(7);
      expect(h.takesFor(1), isEmpty);
      talk(7, 40, scope: 0x10000 | 0xBEEF);
      h.endTake(7);
      expect(h.takesFor(1), isEmpty);
      expect(h.takesFor(0x10000 | 0xBEEF).length, 1);
    });

    test('keeps the last 50 per channel and nothing older than 24 h', () async {
      for (var i = 0; i < 55; i++) {
        talk(7, 25);
        h.endTake(7);
        now = now.add(const Duration(seconds: 5));
      }
      await h.flush();
      // Pruning happens on save.
      expect(h.takesFor(1).length, 50);
      now = now.add(const Duration(hours: 25));
      talk(9, 25);
      h.endTake(9);
      await h.flush();
      expect(h.takesFor(1).length, 1);
      expect(store.blobs.length, 1);
    });

    test('size cap drops the oldest', () async {
      h = TalkHistory(storage: store, clock: () => now, maxBytes: 1000);
      await h.load();
      for (var i = 0; i < 5; i++) {
        talk(7, 50); // ~305 bytes each
        h.endTake(7);
      }
      await h.flush();
      expect(h.takesFor(1).length, 3);
    });

    test('survives a restart', () async {
      talk(7, 30);
      h.endTake(7);
      await h.flush();
      final again = TalkHistory(storage: store, clock: () => now);
      await again.load();
      expect(again.takesFor(1).single.sender, 7);
      expect(again.takesFor(1).single.name, 'P7');
    });
  });

  group('wire compatibility', () {
    test('urgent ring and saver interval round-trip, default off', () {
      const m = ControlMessage(ControlKind.ring, id: 5, urgent: true);
      final back = ControlMessage.tryDecode(m.encode())!;
      expect(back.urgent, isTrue);
      const h = ControlMessage(ControlKind.hello, name: 'a', interval: 2500);
      expect(ControlMessage.tryDecode(h.encode())!.interval, 2500);
      // What 1.3.x sends:
      final old = ControlMessage.tryDecode('{"k":"ring","i":5}'.codeUnits)!;
      expect(old.urgent, isFalse);
      expect(old.interval, isNull);
    });

    test('urgent ring reaches the other phone and is retried longer', () async {
      final net = FakeNet();
      final clock = FakeClock();
      final a = Ringer(link: net.add(1), clock: clock.call)..start();
      final b = Ringer(link: net.add(2), clock: clock.call)..start();
      final got = <IncomingRing>[];
      b.incoming.listen(got.add);
      await a.ring(toPeer: 2, urgent: true);
      await net.settle();
      expect(got.single.urgent, isTrue);
      // Beeps are never urgent.
      await a.ring(toPeer: 2, beep: true, urgent: true);
      await net.settle();
      expect(got.last.urgent, isFalse);
    });
  });

  group('battery saver', () {
    late FakeTransport lan;
    late TransportManager m;
    late DateTime now;

    setUp(() async {
      lan = FakeTransport(TransportKind.lan);
      now = DateTime(2026);
      m = TransportManager(
        transports: [lan],
        localNodeId: 1,
        localName: 'me',
        clock: () => now,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
    });
    tearDown(() => m.dispose());

    Frame hello(int from, int seq, {int? iv}) => Frame.control(
      senderId: from,
      channel: 1,
      seq: seq,
      message: ControlMessage(ControlKind.hello, name: 'x', interval: iv),
    );

    test('a saver phone (slow hellos) is not dropped early', () {
      lan.deliver(hello(2, 0, iv: 2500));
      lan.deliver(hello(3, 0));
      now = now.add(const Duration(seconds: 5));
      m.prune();
      expect(m.peers.map((p) => p.id), [2]);
      now = now.add(const Duration(seconds: 2));
      m.prune();
      expect(m.peers, isEmpty);
    });

    test('saver hellos announce the interval', () async {
      lan.sent.clear();
      await m.setPowerSaver(true);
      final f = lan.sent.last.frame;
      expect(
        f.control!.interval,
        TransportManager.saverHelloInterval.inMilliseconds,
      );
      expect(lan.saver, isTrue);
      lan.sent.clear();
      await m.setPowerSaver(false);
      expect(lan.sent.last.frame.control!.interval, isNull);
    });
  });
}
