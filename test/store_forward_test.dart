import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/outbox.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';

import 'messaging_fakes.dart';

VoiceClip clip(int n) => VoiceClip([
  for (var i = 0; i < n; i++) Uint8List.fromList([i, i, i]),
]);

Future<void> run(
  FakeNet net,
  FakeClock clock,
  List<Messenger> ms,
  int steps,
) async {
  for (var i = 0; i < steps; i++) {
    clock.advance(const Duration(milliseconds: 50));
    for (final m in ms) {
      await m.tick();
    }
    await net.settle();
  }
}

void main() {
  late FakeNet net;
  late FakeClock clock;

  setUp(() {
    net = FakeNet()..allConnected = false;
    clock = FakeClock();
  });

  Messenger make(int id, MessageStorage s, {int channel = 1}) {
    final node = net.nodes[id] ?? net.add(id, channel: channel);
    final m = Messenger(
      link: node,
      storage: s,
      clock: clock.call,
      random: Random(id),
    );
    node.data.listen(m.onData);
    return m;
  }

  test('queued while out of reach, delivered when the peer shows up', () async {
    final sa = MemoryMessageStorage();
    final a = make(1, sa);
    final b = make(2, MemoryMessageStorage());
    await a.outbox.load();
    await a.send(clip(50), toPeer: 2, channel: 1);
    await run(net, clock, [a, b], 100);
    expect(b.inbox.entries, isEmpty);
    expect(a.outbox.entries.length, 1);
    expect(a.outgoing.single.sending, isFalse);

    // Phone 2 comes into range an hour later.
    clock.advance(const Duration(hours: 1));
    net.links.add((1, 2));
    await run(net, clock, [a, b], 100);
    expect(b.inbox.entries.length, 1);
    expect(a.outbox.entries, isEmpty);
    expect(sa.blobs.keys.where((k) => k.startsWith('out_')), isEmpty);
  });

  test('queue survives an app restart', () async {
    final sa = MemoryMessageStorage();
    final a = make(1, sa);
    await a.outbox.load();
    await a.send(clip(10), toPeer: 2, channel: 1);

    final a2 = Messenger(link: net.nodes[1]!, storage: sa, clock: clock.call);
    await a2.outbox.load();
    expect(a2.outbox.entries.single.toPeer, 2);
    final b = make(2, MemoryMessageStorage());
    net.links.add((1, 2));
    net.nodes[1]!.data.listen(a2.onData);
    await run(net, clock, [a2, b], 100);
    expect(b.inbox.entries.length, 1);
  });

  test('expires after 24 h', () async {
    final sa = MemoryMessageStorage();
    final a = make(1, sa);
    await a.outbox.load();
    await a.send(clip(10), toPeer: 2, channel: 1);
    clock.advance(const Duration(hours: 23));
    await a.tick();
    expect(a.outbox.entries.length, 1);
    clock.advance(const Duration(hours: 2));
    await a.tick();
    expect(a.outbox.entries, isEmpty);
    expect(sa.blobs, isEmpty);
  });

  test(
    'channel message with nobody around waits for the first arrivals',
    () async {
      final a = make(1, MemoryMessageStorage());
      await a.outbox.load();
      final e = await a.send(clip(10), channel: 1);
      expect(e.recipients, isEmpty);
      expect(a.waitingForAnyone.length, 1);
      final b = make(2, MemoryMessageStorage());
      final c = make(3, MemoryMessageStorage(), channel: 2);
      net.links.addAll({(1, 2), (1, 3)});
      await run(net, clock, [a, b, c], 60);
      expect(b.inbox.entries.length, 1);
      expect(c.inbox.entries, isEmpty); // other channel
      expect(a.outbox.entries, isEmpty);
    },
  );

  test('outbox entry json round trip', () {
    final e = OutboxEntry(
      msgId: 42,
      toPeer: null,
      channel: 3,
      createdAt: DateTime(2026, 1, 2),
      durationMs: 1200,
      recipients: {5, 6},
      delivered: {5},
    );
    final back = OutboxEntry.fromJson(e.toJson())!;
    expect(back.isChannel, isTrue);
    expect(back.recipients, {5, 6});
    expect(back.pending.toList(), [6]);
    expect(back.done, isFalse);
  });
}
