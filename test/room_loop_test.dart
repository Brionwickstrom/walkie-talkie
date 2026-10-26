// Three phones in one room, end to end through the real TransportManager:
// A and B (1.5.1 / 1.5.2) and C with a mic that stayed on (1.5.0 or older,
// or any phone whose talk got stuck). C's mic hears whatever A and B play
// out loud, so a message A sent goes A -> B's speaker / C's mic -> A and B
// -> C's mic -> ... forever. That is the loop the user hears even with only
// new phones playing: they play C's stream. 1.5.2 refuses that stream.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/live_gate.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';

import 'fake_transport.dart';

class Phone {
  Phone(this.id, DateTime Function() clock, {bool gated = true})
    : gate = gated ? LiveAudioGate(clock: clock) : null {
    m = TransportManager(
      transports: [lan],
      localNodeId: id,
      localName: 'P$id',
      clock: clock,
      helloInterval: const Duration(hours: 1),
    );
    // As WalkieController._onPeers: talk start / end as they arrive.
    m.peerChanges.listen((list) {
      for (final p in list) {
        gate?.talkChanged(p.id, p.talking);
      }
    });
    m.audio.listen((a) {
      // Same decision as WalkieController's live audio listener.
      final talking = m.peer(a.peerId)?.talking ?? false;
      if (gate?.admit(a.peerId, a.opus, talking: talking) != null) return;
      playedThisTick.add(a.opus);
      if (a.peerId == 3) fromStuck++;
      played++;
    });
  }

  final int id;
  final LiveAudioGate? gate;
  final lan = FakeTransport(TransportKind.lan);
  late final TransportManager m;
  final playedThisTick = <Uint8List>[];
  int played = 0, fromStuck = 0;
  int seq = 0, aseq = 0;
}

Future<void> simulate(
  List<Phone> phones,
  void Function(Duration) advance, {
  required Duration length,
}) async {
  Future<void> send(Phone from, Frame f) async {
    for (final p in phones) {
      if (p != from) p.lan.deliver(f);
    }
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> control(Phone from, ControlKind k) => send(
    from,
    Frame.control(
      senderId: from.id,
      channel: 1,
      seq: from.seq++ & 0xFFFF,
      message: ControlMessage(k),
    ),
  );

  Future<void> audio(Phone from, Uint8List payload) => send(
    from,
    Frame(
      type: FrameType.audio,
      senderId: from.id,
      channel: 1,
      seq: from.aseq++ & 0xFFFF,
      payload: payload,
    ),
  );

  final a = phones[0], c = phones[2];
  for (final p in phones) {
    await p.m.start();
    await control(p, ControlKind.hello);
  }
  // Earlier, C's owner tapped talk quickly and the mic stayed on.
  await control(c, ControlKind.talkStart);
  await control(c, ControlKind.talkEnd);

  var heardInRoom = <Uint8List>[];
  final ticks = length.inMilliseconds ~/ 20;
  for (var t = 0; t < ticks; t++) {
    // A sends a new 2 s message at 1 s.
    if (t == 50) await control(a, ControlKind.talkStart);
    if (t >= 50 && t < 150) await audio(a, Uint8List.fromList([1, t & 0xFF]));
    if (t == 150) await control(a, ControlKind.talkEnd);
    // C's mic: whatever the room heard last tick, re-encoded (new bytes).
    final loud = heardInRoom.isNotEmpty;
    await audio(
      c,
      Uint8List.fromList([loud ? 2 : 0, t & 0xFF, (t >> 8) & 0xFF]),
    );
    heardInRoom = [for (final p in phones) ...p.playedThisTick];
    for (final p in phones) {
      p.playedThisTick.clear();
    }
    advance(const Duration(milliseconds: 20));
  }
  for (final p in phones) {
    await p.m.dispose();
  }
}

void main() {
  test(
    '1.5.1 behaviour: the stuck phone loops forever on new phones',
    () async {
      var now = DateTime(2026, 10, 25, 18);
      final phones = [
        for (final id in [1, 2, 3]) Phone(id, () => now, gated: false),
      ];
      await simulate(
        phones,
        (d) => now = now.add(d),
        length: const Duration(minutes: 2),
      );
      // Nearly every 20 ms of two minutes, on both new phones.
      expect(phones[0].fromStuck, greaterThan(5500));
      expect(phones[1].fromStuck, greaterThan(5500));
    },
  );

  test(
    '1.5.2: the stuck stream is refused, the new message plays once',
    () async {
      var now = DateTime(2026, 10, 25, 18);
      final phones = [
        for (final id in [1, 2, 3]) Phone(id, () => now),
      ];
      await simulate(
        phones,
        (d) => now = now.add(d),
        length: const Duration(minutes: 10),
      );
      final b = phones[1];
      expect(b.played - b.fromStuck, 100, reason: "A's 2 s message, once");
      // C streamed non-stop for 10 min: at most its first 60 s (no talk
      // signal since; talkStart/End came long before) and nothing after.
      expect(phones[0].fromStuck, lessThanOrEqualTo(3000));
      expect(b.fromStuck, lessThanOrEqualTo(3000));
    },
  );
}
