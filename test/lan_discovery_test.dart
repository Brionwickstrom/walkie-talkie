import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/lan_transport.dart';

import 'fake_transport.dart';

Uint8List helloBytes(int from, [int seq = 0]) => Frame.control(
  senderId: from,
  channel: 1,
  seq: seq,
  message: const ControlMessage(ControlKind.hello),
).encode();

/// Reports one fake "Wi-Fi" interface (a loopback alias in tests).
class FakePlatform extends LanPlatform {
  const FakePlatform(this.ip, this.prefix);
  final String ip;
  final int prefix;
  @override
  Future<List<LanInterface>> interfaces() async => [
    LanInterface(
      name: 'wlan0',
      address: InternetAddress(ip),
      prefixLength: prefix,
    ),
  ];
}

Future<int> freePort() async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  s.close();
  return p;
}

Future<void> until(bool Function() cond, {int ms = 2000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('subnet sweep targets', () {
    LanInterface iface(String ip, int? prefix) => LanInterface(
      name: 'wlan0',
      address: InternetAddress(ip),
      prefixLength: prefix,
    );

    test('/24 excludes self, network and broadcast', () {
      final t = LanTransport.sweepTargets(iface('192.168.1.10', 24));
      expect(t.length, 253);
      expect(t.map((a) => a.address), isNot(contains('192.168.1.10')));
      expect(t.map((a) => a.address), isNot(contains('192.168.1.0')));
      expect(t.map((a) => a.address), isNot(contains('192.168.1.255')));
    });

    test('Deco-style /22 covers all 4 blocks, own /24 first', () {
      final t = LanTransport.sweepTargets(iface('192.168.68.54', 22));
      expect(t.length, 1021);
      expect(
        t.take(253).every((a) => a.address.startsWith('192.168.68.')),
        isTrue,
      );
      expect(t.map((a) => a.address), contains('192.168.71.254'));
      expect(t.map((a) => a.address), isNot(contains('192.168.71.255')));
    });

    test('huge subnets fall back to own /24; unknown prefix = /24', () {
      expect(LanTransport.sweepTargets(iface('10.1.2.3', 8)).length, 253);
      expect(LanTransport.sweepTargets(iface('10.1.2.3', null)).length, 253);
      expect(LanTransport.sweepTargets(iface('10.1.2.3', 31)), isEmpty);
    });
  });

  group('LAN peer memory', () {
    test('heard peers are saved, reloaded and re-probed by unicast', () async {
      final loop = InternetAddress.loopbackIPv4;
      final storeA = MemoryLanPeerStore();
      final a = LanTransport(
        port: 0,
        enableBroadcast: false,
        enableSweep: false,
        bindAddress: loop,
        store: storeA,
      );
      final b = LanTransport(
        port: 0,
        enableBroadcast: false,
        enableSweep: false,
        bindAddress: loop,
      );
      await a.start(localNodeId: 1, channel: 1);
      await b.start(localNodeId: 2, channel: 1);
      await a.send(helloBytes(1)); // a has a hello ready to answer with

      // b knows a's address (e.g. from Bluetooth) and says hello.
      b.learnPeerAddresses(1, ['127.0.0.1:${a.boundPort}']);
      await b.send(helloBytes(2));
      await until(() => a.canReach(2));
      // a answered immediately with its own hello, so b found a too.
      await until(() => b.canReach(1));
      expect(a.rxFromPeers, greaterThan(0));
      await until(() => storeA.saved.isNotEmpty);
      expect(storeA.saved.single.endpoint, '127.0.0.1:${b.boundPort}');
      await a.dispose();

      // App restart: no Bluetooth, no broadcast. The saved address is
      // probed by unicast and b answers.
      final a2 = LanTransport(
        port: 0,
        enableBroadcast: false,
        enableSweep: false,
        bindAddress: loop,
        store: storeA,
      );
      await a2.start(localNodeId: 1, channel: 1);
      expect(a2.candidates, contains(LanEndpoint(loop, b.boundPort!)));
      final atA2 = a2.frames.first;
      await a2.send(helloBytes(1, 5));
      final f = await atA2.timeout(const Duration(seconds: 2));
      expect(f.frame.senderId, 2);
      expect(a2.canReach(2), isTrue);
      await a2.dispose();
      await b.dispose();
    });

    test(
      'known addresses kept for 10 min after last heard/hint, then dropped',
      () async {
        var now = DateTime(2026, 1, 1, 12);
        final ep = LanEndpoint(InternetAddress('10.9.9.9'), 47474);
        final store = MemoryLanPeerStore()
          ..saved = [
            KnownLanPeer('$ep', now.subtract(const Duration(hours: 1))),
          ];
        final t = LanTransport(
          port: 0,
          enableBroadcast: false,
          enableSweep: false,
          bindAddress: InternetAddress.loopbackIPv4,
          store: store,
          clock: () => now,
        );
        await t.start(localNodeId: 1, channel: 1);
        expect(t.candidates, contains(ep));
        now = now.add(const Duration(minutes: 9));
        await t.send(helloBytes(1));
        expect(t.candidates, contains(ep));
        // A fresh hint (e.g. Bluetooth hello) restarts the 10 minutes.
        t.learnPeerAddresses(9, ['$ep']);
        now = now.add(const Duration(minutes: 9));
        await t.send(helloBytes(1, 1));
        expect(t.candidates, contains(ep));
        now = now.add(const Duration(minutes: 2));
        await t.send(helloBytes(1, 2));
        expect(t.candidates, isNot(contains(ep)));
        await t.dispose();
      },
    );

    test('entries older than a week are not reloaded', () async {
      final now = DateTime(2026, 1, 10);
      final store = MemoryLanPeerStore()
        ..saved = [KnownLanPeer('10.1.1.1:47474', DateTime(2026, 1, 1))];
      final t = LanTransport(
        port: 0,
        enableBroadcast: false,
        enableSweep: false,
        bindAddress: InternetAddress.loopbackIPv4,
        store: store,
        clock: () => now,
      );
      await t.start(localNodeId: 1, channel: 1);
      expect(t.candidates, isEmpty);
      await t.dispose();
    });

    test(
      'own looped-back packets are counted separately, never a peer',
      () async {
        final loop = InternetAddress.loopbackIPv4;
        final a = LanTransport(
          port: 0,
          enableBroadcast: false,
          enableSweep: false,
          bindAddress: loop,
        );
        await a.start(localNodeId: 1, channel: 1);
        final s = await RawDatagramSocket.bind(loop, 0);
        s.send(helloBytes(1), loop, a.boundPort!); // looks like our own echo
        await until(() => a.rxOwn == 1);
        expect(a.rxFromPeers, 0);
        expect(a.canReach(1), isFalse);
        s.send(helloBytes(7), loop, a.boundPort!);
        await until(() => a.rxFromPeers == 1);
        expect(a.debugInfo, contains('rx peers 1 · own echo 1'));
        s.close();
        await a.dispose();
      },
    );
  });

  test('subnet sweep finds a phone with no broadcast, mDNS or hints', () async {
    final p = await freePort();
    final a = LanTransport(
      port: p,
      enableBroadcast: false,
      enableSweep: false,
      bindAddress: InternetAddress('127.0.0.2'),
      platform: const FakePlatform('127.0.0.2', 29),
      allowLoopbackInterfaces: true,
    );
    final b = LanTransport(
      port: p,
      enableBroadcast: false,
      bindAddress: InternetAddress('127.0.0.5'),
      platform: const FakePlatform('127.0.0.5', 29),
      allowLoopbackInterfaces: true,
      sweepBatch: 2,
      sweepBatchDelay: const Duration(milliseconds: 1),
    );
    await a.start(localNodeId: 1, channel: 1);
    await b.start(localNodeId: 2, channel: 1);
    await a.send(helloBytes(1));
    await b.send(helloBytes(2));
    expect(b.candidates, isEmpty);
    await b.runSweep();
    await until(() => a.canReach(2));
    await until(() => b.canReach(1));
    expect(b.sweepsDone, 1);
    await a.dispose();
    await b.dispose();
  });

  test(
    'audio has its own sequence: beacons do not look like lost audio',
    () async {
      final lan = FakeTransport(TransportKind.lan);
      final m = TransportManager(
        transports: [lan],
        localNodeId: 1,
        localName: 'me',
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      lan.deliver(
        Frame.control(
          senderId: 2,
          channel: 1,
          seq: 0,
          message: const ControlMessage(ControlKind.hello),
        ),
      );
      lan.sent.clear();
      await m.sendAudio(Uint8List(1));
      await m.sendHello();
      await m.sendPings();
      await m.sendAudio(Uint8List(1));
      final audio = [
        for (final s in lan.sent)
          if (s.frame.type == FrameType.audio) s.frame.seq,
      ];
      expect(audio, hasLength(2));
      expect((audio[1] - audio[0]) & 0xFFFF, 1);

      // Receiver: control and audio with the same seq are both delivered.
      final got = <int>[];
      m.audio.listen((a) => got.add(a.seq));
      lan.deliver(
        Frame(
          type: FrameType.audio,
          senderId: 2,
          channel: 1,
          seq: 0,
          payload: Uint8List(1),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(got, [0]);
      await m.dispose();
    },
  );

  group('settings', () {
    test('stable id and name across launches (shared_preferences)', () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsSettingsStore();
      final s1 = await store.load(defaultChannel: 1);
      final s2 = await store.load(defaultChannel: 1);
      expect(s2.nodeId, s1.nodeId);
      expect(s2.name, s1.name);
      expect(s1.name, AppSettings.defaultNameFor(s1.nodeId));
      s1
        ..customName = 'Brion'
        ..channel = 3
        ..relayUrl = 'wss://x/';
      await store.save(s1);
      final s3 = await store.load(defaultChannel: 1);
      expect(s3.nodeId, s1.nodeId);
      expect(s3.name, 'Brion');
      expect(s3.channel, 3);
      expect(s3.relayUrl, 'wss://x/');
    });
  });
}
