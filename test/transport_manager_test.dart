import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';

import 'fake_transport.dart';

const me = 0x1111;
const bob = 0x2222;
const carol = 0x3333;

Frame hello(int from, int seq, {int channel = 1, String? name}) =>
    Frame.control(
      senderId: from,
      channel: channel,
      seq: seq,
      message: ControlMessage(ControlKind.hello, name: name),
    );

Frame audio(int from, int seq, {int channel = 1}) => Frame(
  type: FrameType.audio,
  senderId: from,
  channel: channel,
  seq: seq,
  payload: Uint8List.fromList([seq]),
);

void main() {
  late FakeTransport lan, ble, net;
  late TransportManager m;
  late DateTime now;

  setUp(() async {
    lan = FakeTransport(TransportKind.lan);
    ble = FakeTransport(TransportKind.ble);
    net = FakeTransport(TransportKind.internet);
    now = DateTime(2026);
    m = TransportManager(
      transports: [net, ble, lan],
      localNodeId: me,
      localName: 'me',
      clock: () => now,
      helloInterval: const Duration(hours: 1), // drive manually
    );
    await m.start();
    for (final t in [lan, ble, net]) {
      t.sent.clear();
    }
  });

  tearDown(() => m.dispose());

  test('learns peers and their names from hello frames', () {
    ble.deliver(hello(bob, 0, name: 'Bob'));
    expect(m.peers.single.id, bob);
    expect(m.peers.single.name, 'Bob');
    expect(m.peers.single.activeLink, TransportKind.ble);
  });

  test('prefers LAN over BLE over internet for the same peer', () async {
    net.deliver(hello(bob, 0));
    expect(m.peers.single.activeLink, TransportKind.internet);
    ble.deliver(hello(bob, 1));
    expect(m.peers.single.activeLink, TransportKind.ble);
    lan.deliver(hello(bob, 2));
    expect(m.peers.single.activeLink, TransportKind.lan);

    await m.sendAudio(Uint8List.fromList([9]));
    expect(lan.sent.single.peerIds, {bob});
    expect(ble.sent, isEmpty);
    expect(net.sent, isEmpty);
  });

  test(
    'fails over when the best link goes quiet, and drops dead peers',
    () async {
      lan.deliver(hello(bob, 0));
      ble.deliver(hello(bob, 1));
      now = now.add(const Duration(seconds: 4));
      ble.deliver(hello(bob, 2)); // BLE keeps hearing bob, LAN does not
      now = now.add(const Duration(seconds: 3)); // LAN now 7s stale
      m.prune();
      expect(m.peers.single.activeLink, TransportKind.ble);
      await m.sendAudio(Uint8List(1));
      expect(ble.sent.single.peerIds, {bob});
      expect(lan.sent, isEmpty);

      now = now.add(const Duration(seconds: 10));
      m.prune();
      expect(m.peers, isEmpty);
    },
  );

  test('a transport that stops is skipped even if recently heard', () async {
    lan.deliver(hello(bob, 0));
    ble.deliver(hello(bob, 1));
    lan.status = TransportStatus.error;
    await m.sendAudio(Uint8List(1));
    expect(lan.sent, isEmpty);
    expect(ble.sent.single.peerIds, {bob});
  });

  test('routes each peer on its own best link', () async {
    lan.deliver(hello(bob, 0));
    net.deliver(hello(carol, 0));
    await m.sendAudio(Uint8List(1));
    expect(lan.sent.single.peerIds, {bob});
    expect(net.sent.single.peerIds, {carol});
  });

  test('de-duplicates frames that arrive over several transports', () async {
    final got = <int>[];
    m.audio.listen((a) => got.add(a.seq));
    lan.deliver(audio(bob, 5));
    ble.deliver(audio(bob, 5));
    net.deliver(audio(bob, 5));
    ble.deliver(audio(bob, 6));
    await pumpEventQueue();
    expect(got, [5, 6]);
  });

  test('ignores own echoes and audio from other channels', () async {
    final got = <int>[];
    m.audio.listen((a) => got.add(a.peerId));
    lan.deliver(audio(me, 1));
    lan.deliver(audio(bob, 1, channel: 2));
    await pumpEventQueue();
    expect(got, isEmpty);
    expect(m.peers.map((p) => p.id), [bob]); // still listed, other channel
    await m.sendAudio(Uint8List(1));
    expect(lan.sent, isEmpty); // not routed to other-channel peer
  });

  test('hello is broadcast on every running transport', () async {
    ble.status = TransportStatus.unavailable;
    await m.sendHello();
    expect(lan.sent.single.peerIds, isNull);
    expect(net.sent.single.peerIds, isNull);
    expect(ble.sent, isEmpty);
    expect(lan.sent.single.frame.control!.name, 'me');
  });

  test('talk start/end toggles the peer talking flag', () {
    lan.deliver(hello(bob, 0));
    lan.deliver(
      Frame.control(
        senderId: bob,
        channel: 1,
        seq: 1,
        message: const ControlMessage(ControlKind.talkStart),
      ),
    );
    expect(m.peers.single.talking, isTrue);
    lan.deliver(
      Frame.control(
        senderId: bob,
        channel: 1,
        seq: 2,
        message: const ControlMessage(ControlKind.talkEnd),
      ),
    );
    expect(m.peers.single.talking, isFalse);
  });
}
