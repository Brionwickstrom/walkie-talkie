import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/messaging/ringer.dart';

import 'messaging_fakes.dart';

void main() {
  test('ring / beep / ringAck encode and decode', () {
    for (final m in [
      const ControlMessage(ControlKind.ring, to: 0xFFFFFFF0, id: 123456),
      const ControlMessage(ControlKind.beep, id: 7),
      const ControlMessage(
        ControlKind.ringAck,
        to: 9,
        id: 7,
        status: 'answered',
      ),
    ]) {
      final f = Frame.control(senderId: 1, channel: 4, seq: 2, message: m);
      final back = Frame.tryDecode(f.encode())!.control!;
      expect(back.kind, m.kind);
      expect(back.to, m.to);
      expect(back.id, m.id);
      expect(back.status, m.status);
    }
  });

  test('old phones ignore unknown control kinds', () {
    expect(ControlMessage.tryDecode('{"k":"teleport"}'.codeUnits), isNull);
  });

  late FakeNet net;
  late FakeClock clock;
  setUp(() {
    net = FakeNet();
    clock = FakeClock();
  });

  Ringer make(int id, {int channel = 1}) => Ringer(
    link: net.add(id, channel: channel),
    clock: clock.call,
  )..start();

  test('ring -> delivered -> answered', () async {
    final a = make(1);
    final b = make(2);
    final incoming = <IncomingRing>[];
    b.incoming.listen(incoming.add);
    await a.ring(toPeer: 2);
    expect(a.statusFor(2)!.$1, RingStatus.sending);
    await net.settle();
    expect(incoming.single.from, 1);
    expect(incoming.single.beep, isFalse);
    expect(a.statusFor(2)!.$1, RingStatus.delivered);
    await b.respond(incoming.single, RingStatus.answered);
    await net.settle();
    expect(a.statusFor(2)!.$1, RingStatus.answered);
  });

  test('lost ring is retried, duplicates ring only once', () async {
    final a = make(1);
    final b = make(2);
    final incoming = <IncomingRing>[];
    b.incoming.listen(incoming.add);
    var drops = 2;
    net.drop = (from, _, _) => from == 1 && drops-- > 0;
    await a.ring(toPeer: 2);
    await net.settle();
    expect(incoming, isEmpty);
    for (var i = 0; i < 4; i++) {
      clock.advance(const Duration(seconds: 1));
      await a.tick();
      await net.settle();
    }
    expect(incoming.length, 1);
    expect(a.statusFor(2)!.$1, RingStatus.delivered);
  });

  test(
    'lost ack: the repeat gets acked, final status not downgraded',
    () async {
      final a = make(1);
      final b = make(2);
      final incoming = <IncomingRing>[];
      b.incoming.listen(incoming.add);
      var dropAcks = true;
      net.drop = (from, _, _) => from == 2 && dropAcks;
      await a.ring(toPeer: 2);
      await net.settle();
      await b.respond(incoming.single, RingStatus.dismissed);
      dropAcks = false;
      clock.advance(const Duration(seconds: 1));
      await a.tick();
      await net.settle();
      expect(incoming.length, 1);
      expect(a.statusFor(2)!.$1, RingStatus.dismissed);
    },
  );

  test('ring all reaches only my channel; unreachable after retries', () async {
    final a = make(1);
    final b = make(2);
    final c = make(3);
    final d = make(4, channel: 2);
    final got = <int>[];
    for (final (id, r) in [(2, b), (3, c), (4, d)]) {
      r.incoming.listen((_) => got.add(id));
    }
    final out = await a.ring();
    await net.settle();
    expect(got..sort(), [2, 3]);
    expect(out.status.keys.toSet(), {2, 3});

    // Phone 5 is "reachable" but never answers: unreachable after retries.
    net.add(5);
    final r = await a.ring(toPeer: 5, beep: true);
    for (var i = 0; i < 8; i++) {
      clock.advance(const Duration(seconds: 1));
      await a.tick();
    }
    expect(r.status[5], RingStatus.unreachable);
  });

  test('channel-wide ring from another channel is ignored', () async {
    final b = make(2, channel: 3);
    final got = <IncomingRing>[];
    b.incoming.listen(got.add);
    final a = net.add(1);
    await a.sendControlTo(2, const ControlMessage(ControlKind.ring, id: 5));
    await net.settle();
    expect(got, isEmpty);
  });
}
