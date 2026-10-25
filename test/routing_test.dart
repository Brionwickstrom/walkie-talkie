import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/playout_buffer.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/lan_transport.dart';

import 'fake_transport.dart';

const me = 0x1111;
const bob = 0x2222;

Frame hello(int from, int seq, {List<String> addrs = const []}) =>
    Frame.control(
      senderId: from,
      channel: 1,
      seq: seq,
      message: ControlMessage(ControlKind.hello, name: 'B', lanAddrs: addrs),
    );

void main() {
  group('manager routing', () {
    late FakeTransport lan, ble, net;
    late TransportManager m;
    late DateTime now;

    setUp(() async {
      lan = FakeTransport(TransportKind.lan);
      ble = FakeTransport(TransportKind.ble);
      net = FakeTransport(TransportKind.internet);
      now = DateTime(2026);
      m = TransportManager(
        transports: [ble, net, lan],
        localNodeId: me,
        localName: 'me',
        clock: () => now,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      for (final t in [lan, ble, net]) {
        t.sent.clear();
      }
    });
    tearDown(() => m.dispose());

    test('route is re-evaluated per frame: LAN takes over mid-talk', () async {
      ble.deliver(hello(bob, 0));
      await m.sendAudio(Uint8List(1));
      expect(ble.sent.single.peerIds, {bob});
      lan.deliver(hello(bob, 1));
      ble.sent.clear();
      await m.sendAudio(Uint8List(1));
      expect(lan.sent.single.peerIds, {bob});
      expect(ble.sent, isEmpty);
    });

    test(
      'stale best link also sends on the runner-up (make-before-break)',
      () async {
        lan.deliver(hello(bob, 0));
        ble.deliver(hello(bob, 1));
        now = now.add(const Duration(seconds: 2)); // LAN quiet 2s
        ble.deliver(hello(bob, 2));
        await m.sendAudio(Uint8List(1));
        expect(lan.sent.single.peerIds, {bob});
        expect(ble.sent.single.peerIds, {bob});
      },
    );

    test('link reported gone by the radio is skipped immediately', () async {
      lan.deliver(hello(bob, 0));
      ble.deliver(hello(bob, 1));
      ble.unreachable.add(bob);
      lan.unreachable.add(bob);
      net.deliver(hello(bob, 2));
      await m.sendAudio(Uint8List(1));
      expect(lan.sent, isEmpty);
      expect(ble.sent, isEmpty);
      expect(net.sent.single.peerIds, {bob});
      m.prune();
      expect(m.peers.single.activeLink, TransportKind.internet);
    });

    test('BLE drop fails over to LAN within the liveness timeout', () async {
      ble.deliver(hello(bob, 0));
      lan.deliver(hello(bob, 1));
      // LAN dies (walked away from Wi-Fi) while BLE keeps going.
      for (var i = 2; i < 8; i++) {
        now = now.add(const Duration(seconds: 1));
        ble.deliver(hello(bob, i));
      }
      m.prune();
      expect(m.peers.single.activeLink, TransportKind.ble);
      // Now the reverse: back on Wi-Fi, BLE out of range.
      lan.deliver(hello(bob, 9));
      now = now.add(const Duration(seconds: 5));
      lan.deliver(hello(bob, 10));
      m.prune();
      expect(m.peers.single.activeLink, TransportKind.lan);
      expect(m.peers.single.lastSeen.containsKey(TransportKind.ble), isFalse);
    });

    test(
      'hello carries our LAN addresses and peers hints reach transports',
      () async {
        lan.addresses = ['192.168.1.20:47474'];
        await m.sendHello();
        expect(ble.sent.single.frame.control!.lanAddrs, ['192.168.1.20:47474']);

        ble.deliver(hello(bob, 0, addrs: ['192.168.1.30:47474']));
        expect(lan.learned[bob], ['192.168.1.30:47474']);
        expect(m.peers.single.lanAddrs, ['192.168.1.30:47474']);
      },
    );

    test(
      'ping is answered with a pong on the same link; pong sets rtt',
      () async {
        ble.deliver(hello(bob, 0));
        ble.deliver(
          Frame.control(
            senderId: bob,
            channel: 1,
            seq: 1,
            message: const ControlMessage(ControlKind.ping, to: me, time: 123),
          ),
        );
        await pumpEventQueue();
        final pong = ble.sent.single;
        expect(pong.peerIds, {bob});
        expect(pong.frame.control!.kind, ControlKind.pong);
        expect(pong.frame.control!.time, 123);

        // Ping addressed to someone else is ignored.
        ble.sent.clear();
        ble.deliver(
          Frame.control(
            senderId: bob,
            channel: 1,
            seq: 2,
            message: const ControlMessage(
              ControlKind.ping,
              to: 0x9999,
              time: 1,
            ),
          ),
        );
        await pumpEventQueue();
        expect(ble.sent, isEmpty);

        await m.sendPings();
        final ping = ble.sent.single.frame.control!;
        expect(ping.kind, ControlKind.ping);
        now = now.add(const Duration(milliseconds: 42));
        ble.deliver(
          Frame.control(
            senderId: bob,
            channel: 1,
            seq: 3,
            message: ControlMessage(ControlKind.pong, to: me, time: ping.time),
          ),
        );
        expect(
          m.peers.single.rtt[TransportKind.ble],
          const Duration(milliseconds: 42),
        );
      },
    );
  });

  test('control message round-trips new fields and tolerates old ones', () {
    const msg = ControlMessage(
      ControlKind.hello,
      name: 'x',
      lanAddrs: ['10.0.0.2:1'],
      to: 5,
      time: 99,
    );
    final back = ControlMessage.tryDecode(msg.encode())!;
    expect(back.lanAddrs, ['10.0.0.2:1']);
    expect(back.to, 5);
    expect(back.time, 99);
    final old = ControlMessage.tryDecode('{"k":"hello","n":"y"}'.codeUnits)!;
    expect(old.lanAddrs, isEmpty);
    expect(ControlMessage.tryDecode('{"k":"future"}'.codeUnits), isNull);
  });

  group('LAN helpers', () {
    test('subnet broadcast from prefix', () {
      String bc(String ip, int p) =>
          LanInterface.computeBroadcast(InternetAddress(ip), p).address;
      expect(bc('192.168.1.37', 24), '192.168.1.255');
      expect(bc('172.20.10.3', 28), '172.20.10.15');
      expect(bc('10.12.200.9', 16), '10.12.255.255');
    });

    test('cellular/tunnel interfaces are not LAN', () {
      LanInterface i(String n) =>
          LanInterface(name: n, address: InternetAddress('10.1.2.3'));
      expect(i('wlan0').isLocalNetwork, isTrue);
      expect(i('swlan0').isLocalNetwork, isTrue);
      expect(i('rmnet_data0').isLocalNetwork, isFalse);
      expect(i('tun0').isLocalNetwork, isFalse);
    });

    test('endpoint parsing', () {
      expect(
        LanEndpoint.tryParse('192.168.0.5:47474'),
        LanEndpoint(InternetAddress('192.168.0.5'), 47474),
      );
      expect(LanEndpoint.tryParse('nope'), isNull);
      expect(LanEndpoint.tryParse('1.2.3.4:99999'), isNull);
    });

    test('hinted address alone (no broadcast, no mDNS) connects LAN', () async {
      final loop = InternetAddress.loopbackIPv4;
      final a = LanTransport(
        port: 0,
        enableBroadcast: false,
        bindAddress: loop,
      );
      final b = LanTransport(
        port: 0,
        enableBroadcast: false,
        bindAddress: loop,
      );
      await a.start(localNodeId: 1, channel: 1);
      await b.start(localNodeId: 2, channel: 1);
      expect(b.canReach(1), isFalse);

      // As if a's hello (with its LAN address) arrived at b over Bluetooth.
      b.learnPeerAddresses(1, ['127.0.0.1:${a.boundPort}']);
      final atA = a.frames.first;
      await b.send(
        Frame.control(
          senderId: 2,
          channel: 1,
          seq: 0,
          message: const ControlMessage(ControlKind.hello),
        ).encode(),
      );
      expect((await atA.timeout(const Duration(seconds: 2))).frame.senderId, 2);
      expect(a.canReach(2), isTrue);
      await a.dispose();
      await b.dispose();
    });
  });

  group('playout buffer', () {
    test('prefills at burst start and caps queued latency', () {
      var now = DateTime(2026);
      final pb = PlayoutBuffer(
        sampleRate: 16000,
        targetMs: 60,
        maxMs: 180,
        clock: () => now,
      );
      expect(pb.admit(320), 960); // 60 ms cushion
      // A burst of 20 frames arriving at once: only up to ~180 ms queued.
      var accepted = 0;
      for (var i = 0; i < 20; i++) {
        if (pb.admit(320) != null) accepted++;
      }
      expect(pb.queuedMs, lessThanOrEqualTo(200));
      expect(accepted, lessThan(20));
      expect(pb.dropped, 20 - accepted);
      // After it drains, the next frame starts a fresh cushion.
      now = now.add(const Duration(seconds: 1));
      expect(pb.queuedMs, 0);
      expect(pb.admit(320), 960);
    });

    test('steady real-time arrival is never dropped', () {
      var now = DateTime(2026);
      final pb = PlayoutBuffer(sampleRate: 16000, clock: () => now);
      for (var i = 0; i < 500; i++) {
        expect(pb.admit(320), isNotNull);
        now = now.add(const Duration(milliseconds: 20));
      }
      expect(pb.dropped, 0);
    });
  });
}
