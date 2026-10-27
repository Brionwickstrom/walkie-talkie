import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_relay/relay_server.dart';
import 'package:walkie_talkie/app/connection_test.dart';
import 'package:walkie_talkie/app/link_settings.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/direct_links.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';
import 'package:walkie_talkie/transports/stun.dart';

Future<void> _until(bool Function() ok, {int ms = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<List<InternetAddress>> _loop() async => [InternetAddress.loopbackIPv4];

DirectLinks _dl({
  Future<List<InternetAddress>> Function()? hosts,
  Duration punchFor = const Duration(seconds: 2),
  Duration deadAfter = const Duration(seconds: 40),
}) => DirectLinks(
  stunServers: const [],
  hostAddresses: hosts ?? _loop,
  enableV6: false,
  checkEvery: const Duration(milliseconds: 50),
  punchInterval: const Duration(milliseconds: 20),
  punchFor: punchFor,
  deadAfter: deadAfter,
  offerTimeout: const Duration(seconds: 3),
);

/// Wire two DirectLinks to each other's signaling directly.
void _pair(DirectLinks a, int ida, DirectLinks b, int idb) {
  a.signal = (to, x) =>
      Timer(const Duration(milliseconds: 5), () => b.onSignal(ida, Map.of(x)));
  b.signal = (to, x) =>
      Timer(const Duration(milliseconds: 5), () => a.onSignal(idb, Map.of(x)));
  a.wantedPeers = () => [idb];
  b.wantedPeers = () => [ida];
}

Uint8List _frame(int from, int seq) => Frame(
  type: FrameType.audio,
  senderId: from,
  channel: 1,
  seq: seq,
  payload: Uint8List.fromList([9, 9, 9]),
).encode();

void main() {
  group('STUN', () {
    test('builds a Binding request and parses XOR-MAPPED-ADDRESS', () {
      final tx = Stun.newTxId();
      final req = Stun.request(tx);
      expect(req.length, 20);
      expect(Stun.isStun(req), isTrue);
      final resp = Stun.successFor(req, InternetAddress('203.0.113.7'), 54321);
      final m = Stun.parseMapped(resp)!;
      expect(m.address.address, '203.0.113.7');
      expect(m.port, 54321);
      expect(Stun.txKey(resp), Stun.txKey(req));
      final r6 = Stun.successFor(req, InternetAddress('2001:db8::42'), 4000);
      final m6 = Stun.parseMapped(r6)!;
      expect(m6.address.address, '2001:db8::42');
      expect(m6.port, 4000);
    });

    test('ignores non-STUN and failure packets', () {
      expect(Stun.parseMapped(Uint8List(10)), isNull);
      final b = Uint8List.fromList([0x57, 0x44, ...List.filled(30, 0)]);
      expect(Stun.isStun(b), isFalse);
    });

    test('gather learns the public address from a STUN server', () async {
      // A tiny local STUN server that reports a made-up public address.
      final srv = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((e) {
        final d = srv.receive();
        if (d == null) return;
        srv.send(
          Stun.successFor(d.data, InternetAddress('198.51.100.9'), 40000),
          d.address,
          d.port,
        );
      });
      final a = DirectLinks(
        stunServers: [('127.0.0.1', srv.port)],
        hostAddresses: () async => const [],
        enableV6: false,
      );
      final b = DirectLinks(stunServers: const [], enableV6: false);
      String? offer;
      a.signal = (to, x) => offer = (x['c'] as List).join(',');
      a.wantedPeers = () => [2];
      _pair(a, 1, b, 2);
      a.signal = (to, x) => offer = (x['c'] as List).join(',');
      await a.start(localNodeId: 1);
      await _until(() => offer != null);
      expect(offer, contains('198.51.100.9#40000'));
      expect(a.nat!.public4, '198.51.100.9:40000');
      expect(a.nat!.symmetric, isFalse);
      await a.dispose();
      await b.dispose();
      srv.close();
    });
  });

  group('direct links', () {
    test('two phones punch through and swap frames directly', () async {
      final a = _dl(), b = _dl();
      _pair(a, 1, b, 2);
      final atB = <InboundFrame>[];
      b.frames.listen(atB.add);
      final events = <String>[];
      a.onEvent = events.add;
      await a.start(localNodeId: 1);
      await b.start(localNodeId: 2);
      await _until(() => a.isUp(2) && b.isUp(1));
      expect(a.pathOf(2), 'IPv4');
      expect(events.single, contains('direct link up to 2'));
      expect(a.send(2, _frame(1, 7)), isTrue);
      await _until(() => atB.isNotEmpty);
      expect(atB.single.frame.seq, 7);
      expect(atB.single.transport, TransportKind.internet);
      await a.dispose();
      await b.dispose();
    });

    test('only the lower id offers (no double offers)', () async {
      final a = _dl(), b = _dl();
      var offersFromB = 0;
      _pair(a, 1, b, 2);
      final orig = b.signal!;
      b.signal = (to, x) {
        if (x['op'] == 'o') offersFromB++;
        orig(to, x);
      };
      await a.start(localNodeId: 1);
      await b.start(localNodeId: 2);
      await _until(() => a.isUp(2));
      expect(offersFromB, 0);
      await a.dispose();
      await b.dispose();
    });

    test('packets with a wrong token are ignored', () async {
      final a = _dl(), b = _dl();
      _pair(a, 1, b, 2);
      int? bPort;
      final orig = b.signal!;
      b.signal = (to, x) {
        final c = (x['c'] as List?)?.cast<String>() ?? const [];
        if (c.isNotEmpty) bPort = int.parse(c.first.split('#')[1]);
        orig(to, x);
      };
      final atB = <InboundFrame>[];
      b.frames.listen(atB.add);
      await a.start(localNodeId: 1);
      await b.start(localNodeId: 2);
      await _until(() => a.isUp(2) && b.isUp(1) && bPort != null);
      // Someone who never saw the signaling sends a data packet claiming
      // to be phone 1, with a guessed token.
      final evil = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final pkt = Uint8List.fromList([
        0x57, 0x44, 1, 3, // magic, version, data
        1, 2, 3, 4, 5, 6, 7, 8, // wrong token
        0, 0, 0, 1, // "from phone 1"
        ..._frame(1, 99),
      ]);
      evil.send(pkt, InternetAddress.loopbackIPv4, bPort!);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(atB, isEmpty);
      // The real phone still gets through.
      a.send(2, _frame(1, 5));
      await _until(() => atB.isNotEmpty);
      expect(atB.single.frame.seq, 5);
      evil.close();
      await a.dispose();
      await b.dispose();
    });

    test('no route (unreachable candidates) -> fails, retries later, '
        'never blocks anything', () async {
      Future<List<InternetAddress>> none() async => [
        InternetAddress('192.0.2.1'), // TEST-NET, never answers
      ];
      final a = _dl(hosts: none, punchFor: const Duration(milliseconds: 300));
      final b = _dl(hosts: none, punchFor: const Duration(milliseconds: 300));
      _pair(a, 1, b, 2);
      final events = <String>[];
      a.onEvent = events.add;
      await a.start(localNodeId: 1);
      await b.start(localNodeId: 2);
      await _until(() => events.any((e) => e.contains('failed')));
      expect(a.isUp(2), isFalse);
      expect(a.send(2, _frame(1, 1)), isFalse);
      expect(a.attemptsFailed, greaterThanOrEqualTo(1));
      expect(events.first, contains('relay keeps working'));
      expect(events.first, contains('retry in 30s'));
      await a.dispose();
      await b.dispose();
    });

    test(
      'link dies when the other phone goes silent, then comes back',
      () async {
        final a = _dl(deadAfter: const Duration(milliseconds: 400));
        final b = _dl(deadAfter: const Duration(milliseconds: 400));
        a.keepAlive = const Duration(seconds: 30);
        b.keepAlive = const Duration(seconds: 30);
        _pair(a, 1, b, 2);
        await a.start(localNodeId: 1);
        await b.start(localNodeId: 2);
        await _until(() => a.isUp(2) && b.isUp(1));
        await b.stop(); // b vanishes (says bye) ...
        await _until(() => !a.isUp(2), ms: 2000);
        await b.start(localNodeId: 2); // ... and is back
        await _until(() => a.isUp(2) && b.isUp(1), ms: 3000);
        await a.dispose();
        await b.dispose();
      },
    );

    test('keepalive pings keep an idle link up', () async {
      final a = _dl(deadAfter: const Duration(milliseconds: 600));
      final b = _dl(deadAfter: const Duration(milliseconds: 600));
      a.keepAlive = const Duration(milliseconds: 100);
      b.keepAlive = const Duration(milliseconds: 100);
      _pair(a, 1, b, 2);
      await a.start(localNodeId: 1);
      await b.start(localNodeId: 2);
      await _until(() => a.isUp(2) && b.isUp(1));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(a.isUp(2), isTrue);
      expect(b.isUp(1), isTrue);
      await a.dispose();
      await b.dispose();
    });

    test('network change: both sides start over at once', () async {
      final a = _dl(), b = _dl();
      _pair(a, 1, b, 2);
      await a.start(localNodeId: 1);
      await b.start(localNodeId: 2);
      await _until(() => a.isUp(2) && b.isUp(1));
      b.networkChanged(); // higher id: asks a for a fresh offer
      expect(b.isUp(1), isFalse);
      await _until(() => a.isUp(2) && b.isUp(1), ms: 3000);
      await a.dispose();
      await b.dispose();
    });

    test('peers no longer wanted (now on the same Wi-Fi) are closed', () async {
      final a = DirectLinks(
        stunServers: const [],
        hostAddresses: _loop,
        enableV6: false,
        checkEvery: const Duration(milliseconds: 50),
        punchInterval: const Duration(milliseconds: 20),
        forgetAfter: const Duration(milliseconds: 200),
      );
      final b = _dl();
      _pair(a, 1, b, 2);
      await a.start(localNodeId: 1);
      await b.start(localNodeId: 2);
      await _until(() => a.isUp(2));
      a.wantedPeers = () => const [];
      b.wantedPeers = () => const [];
      // b keeps pinging only every 15 s, so a forgets it.
      await _until(() => !a.isUp(2), ms: 3000);
      await a.dispose();
      await b.dispose();
    });

    test('NAT outlook', () {
      expect(const NatInfo(ipv6: true).outlook, 'good');
      expect(
        const NatInfo(stunAnswered: true, public4: '1.2.3.4:5').outlook,
        'maybe',
      );
      expect(
        const NatInfo(stunAnswered: true, symmetric: true).outlook,
        'unlikely',
      );
    });
  });

  group('direct links through real relays + TransportManager', () {
    Future<
      ({
        RelayServer home,
        RelayServer backup,
        List<TransportManager> ms,
        List<MultiRelayTransport> ts,
      })
    >
    setup({ChannelKey? key, int bFeature = featureLevel}) async {
      final channel = key?.tag ?? 3;
      final home = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final backup = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final uris = [
        Uri.parse('ws://127.0.0.1:${home.port}/ws'),
        Uri.parse('ws://127.0.0.1:${backup.port}/ws'),
      ];
      final ts = <MultiRelayTransport>[];
      final ms = <TransportManager>[];
      for (final id in [0x11, 0x22]) {
        final d = _dl();
        final t = MultiRelayTransport(serverUris: uris, direct: d);
        final m = TransportManager(
          transports: [t],
          localNodeId: id,
          localName: 'p$id',
          channel: channel,
          channelKey: key,
          helloInterval: const Duration(milliseconds: 200),
        );
        final v = id == 0x22 ? bFeature : featureLevel;
        m.helloExtras = () => {'v': v};
        d.attach(m);
        ts.add(t);
        ms.add(m);
      }
      for (final m in ms) {
        await m.start();
      }
      return (home: home, backup: backup, ms: ms, ts: ts);
    }

    Future<void> run(ChannelKey? key) async {
      final s = await setup(key: key);
      final [a, b] = s.ms;
      final [ta, tb] = s.ts;
      // Relays first: people show up right away, no waiting for direct.
      await _until(() => a.peers.isNotEmpty && b.peers.isNotEmpty);
      // Then the direct link comes up on its own.
      await _until(
        () => ta.direct!.isUp(0x22) && tb.direct!.isUp(0x11),
        ms: 8000,
      );
      expect(ta.pathTo(0x22), 'Direct');
      expect(a.pathOf(a.peers.single), 'Direct');
      expect(ta.summary.text, contains('Direct to 1 phone'));
      // What arrives over the direct link is exactly what the relay gets:
      // sealed on a private channel.
      final rawDirect = <InboundFrame>[];
      final rsub = tb.direct!.frames.listen(rawDirect.add);
      // Audio goes direct (and through the relays); b plays one copy.
      final got = <ReceivedAudio>[];
      final sub = b.audio.listen(got.add);
      final before = ta.directSent;
      await a.sendAudio(Uint8List.fromList([1, 2, 3, 4]));
      await _until(() => got.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(ta.directSent, greaterThan(before));
      expect(got, hasLength(1), reason: 'deduplicated');
      expect(rawDirect, isNotEmpty);
      expect(
        rawDirect.every(
          (f) =>
              f.frame.type == (key != null ? FrameType.sealed : f.frame.type),
        ),
        isTrue,
      );
      if (key != null) {
        expect(rawDirect.map((f) => f.frame.type).toSet(), {FrameType.sealed});
      } else {
        expect(rawDirect.map((f) => f.frame.type), contains(FrameType.audio));
      }
      await rsub.cancel();
      // Relays die: the direct link alone keeps talk working.
      await s.home.close();
      await s.backup.close();
      await _until(
        () => ta.relays.every((r) => r.status != TransportStatus.running),
      );
      expect(ta.status, TransportStatus.running);
      got.clear();
      await a.sendAudio(Uint8List.fromList([5, 6, 7, 8]));
      await _until(() => got.isNotEmpty);
      await sub.cancel();
      for (final m in s.ms) {
        await m.dispose();
      }
    }

    test('public channel', () => run(null));

    test('private channel: signaling and direct frames stay sealed', () async {
      final key = await ChannelKey.deriveInline(
        5,
        'correct horse',
        iterations: 1000,
      );
      await run(key);
    });

    test('a phone on an older app version gets no direct attempt', () async {
      final s = await setup(bFeature: 19);
      final [a, b] = s.ms;
      final [ta, _] = s.ts;
      await _until(() => a.peers.isNotEmpty && b.peers.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(a.directCandidates(), isEmpty);
      expect(ta.direct!.upPeers, isEmpty);
      expect(ta.pathTo(0x22), isNull);
      for (final m in s.ms) {
        await m.dispose();
      }
      await s.home.close();
      await s.backup.close();
    });
  });

  group('v1.8.9 compatibility and UI', () {
    test('dx signaling is a new control kind older phones drop', () {
      final m = ControlMessage(ControlKind.dx, to: 7, x: const {'op': 'o'});
      final back = ControlMessage.tryDecode(m.encode())!;
      expect(back.kind, ControlKind.dx);
      expect(back.to, 7);
      expect(featureLevel, greaterThanOrEqualTo(directFeature));
      expect(DirectLinks.feature, directFeature);
      // What a 1.8.8 phone does with an unknown kind: decode fails -> null.
      expect(
        ControlMessage.tryDecode(Uint8List.fromList('{"k":"zz"}'.codeUnits)),
        isNull,
      );
    });

    test('Internet sheet says Direct', () {
      final i = describeLink(
        TransportKind.internet,
        TransportStatus.running,
        relayInUse: 'Home relay',
        directCount: 2,
      );
      expect(i.state, 'Connected · Home relay · Direct to 2');
      expect(i.help, contains('Direct to 2 phones'));
      expect(
        describeLink(
          TransportKind.internet,
          TransportStatus.running,
          relayInUse: 'Home relay',
        ).state,
        'Connected · Home relay',
      );
    });

    CheckRow? directRow(ConnSnapshot s) {
      for (final r in evaluateConnection(s)) {
        if (r.id == 'direct') return r;
      }
      return null;
    }

    test('connection test: direct row', () {
      expect(directRow(const ConnSnapshot()), isNull);
      final up = directRow(
        const ConnSnapshot(
          direct: DirectCheck(
            nat: NatInfo(stunAnswered: true, ipv6: true),
            up: 1,
            paths: ['IPv6'],
          ),
        ),
      )!;
      expect(up.level, CheckLevel.ok);
      expect(up.detail, contains('Direct to 1 phone now over IPv6'));
      final strict = directRow(
        const ConnSnapshot(
          direct: DirectCheck(
            nat: NatInfo(stunAnswered: true, symmetric: true),
          ),
        ),
      )!;
      expect(strict.level, CheckLevel.ok);
      expect(strict.detail, contains('strict (carrier) NAT'));
      expect(strict.detail, contains('relay too'));
      final off = directRow(
        const ConnSnapshot(offlineSaver: true, direct: DirectCheck()),
      )!;
      expect(off.level, CheckLevel.off);
    });

    test('Offline power save stops direct links with the relays', () async {
      final d = _dl();
      final t = MultiRelayTransport(
        serverUris: [Uri.parse('ws://127.0.0.1:1/ws')],
        direct: d,
      );
      await t.start(localNodeId: 1, channel: 1);
      expect(d.running, isTrue);
      await t.stop(); // what the manager does in Offline power save
      expect(d.running, isFalse);
      expect(d.send(2, _frame(1, 1)), isFalse);
      await t.dispose();
    });
  });
}
