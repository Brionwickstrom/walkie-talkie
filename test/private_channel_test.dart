import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_relay/relay_server.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/fragmenter.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/voice_transfer.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

/// Fast KDF for tests (the app uses [ChannelKey.iterations]).
Future<ChannelKey> key(int ch, String pass) =>
    ChannelKey.deriveInline(ch, pass, iterations: 1000);

/// A shared "air": every phone's transport hears every other phone.
class Air {
  final List<AirTransport> members = [];
}

class AirTransport extends Transport {
  AirTransport(this.air) {
    air.members.add(this);
  }
  final Air air;
  int id = 0;
  final _frames = StreamController<InboundFrame>.broadcast(sync: true);
  final _status = StreamController<TransportStatus>.broadcast(sync: true);
  TransportStatus _s = TransportStatus.stopped;
  final List<Uint8List> wire = [];

  @override
  TransportKind get kind => TransportKind.lan;
  @override
  TransportStatus get status => _s;
  @override
  Stream<TransportStatus> get statusChanges => _status.stream;
  @override
  Stream<InboundFrame> get frames => _frames.stream;
  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    id = localNodeId;
    _s = TransportStatus.running;
  }

  @override
  Future<void> stop() async => _s = TransportStatus.stopped;

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    wire.add(frame);
    for (final m in air.members) {
      if (identical(m, this) || m._s != TransportStatus.running) continue;
      final f = Frame.tryDecode(frame);
      if (f != null) m._frames.add(InboundFrame(f, TransportKind.lan));
    }
  }
}

Uint8List opus(int n) => Uint8List.fromList(List.generate(n, (i) => i));

void main() {
  group('ChannelKey', () {
    test('seal/open round trip for every frame type', () async {
      final k = await key(3, 'blue-falcon');
      final k2 = await key(3, '  blue-falcon '); // trimmed
      for (final type in [FrameType.audio, FrameType.control, FrameType.data]) {
        final inner = Frame(
          type: type,
          senderId: 0xABCDEF01,
          channel: k.tag,
          seq: 4242,
          payload: opus(37),
        );
        final wire = k.seal(inner);
        expect(wire.length, Frame.headerSize + 37 + ChannelKey.overhead);
        final outer = Frame.tryDecode(wire)!;
        expect(outer.type, FrameType.sealed);
        expect(outer.channel, k.tag);
        final back = k2.open(outer)!;
        expect(back.type, type);
        expect(back.senderId, 0xABCDEF01);
        expect(back.seq, 4242);
        expect(back.payload, opus(37));
      }
    });

    test('wrong passcode / other channel / tampering is rejected', () async {
      final good = await key(3, 'blue-falcon');
      final wrong = await key(3, 'blue-falcoN');
      final otherCh = await key(4, 'blue-falcon');
      expect(
        good.tag == otherCh.tag && good.fingerprint == otherCh.fingerprint,
        isFalse,
      );
      final wire = good.seal(
        Frame(
          type: FrameType.audio,
          senderId: 7,
          channel: good.tag,
          seq: 1,
          payload: opus(30),
        ),
      );
      final outer = Frame.tryDecode(wire)!;
      expect(wrong.open(outer), isNull);
      expect(otherCh.open(outer), isNull);
      // Same tag but a different key (forced) must still fail auth.
      final forged = Frame(
        type: FrameType.sealed,
        senderId: 7,
        channel: wrong.tag,
        seq: 1,
        payload: outer.payload,
      );
      expect(wrong.open(forged), isNull);
      // Flip one ciphertext bit / change the header (sender id).
      final flipped = Uint8List.fromList(wire)..[Frame.headerSize + 14] ^= 1;
      expect(good.open(Frame.tryDecode(flipped)!), isNull);
      final spoofed = Uint8List.fromList(wire)..[4] ^= 1;
      expect(good.open(Frame.tryDecode(spoofed)!), isNull);
      // Plain text is not visible on the wire.
      expect(
        utf8.decode(wire, allowMalformed: true).contains('hello'),
        isFalse,
      );
    });

    test('random nonce: same frame encrypts differently each time', () async {
      final k = await key(1, 'secret1');
      final f = Frame(
        type: FrameType.audio,
        senderId: 1,
        channel: k.tag,
        seq: 1,
        payload: opus(10),
      );
      expect(k.seal(f), isNot(equals(k.seal(f))));
    });

    test('real derivation (isolate, full iterations) is consistent', () async {
      final sw = Stopwatch()..start();
      final a = await ChannelKey.derive(5, 'pass-word');
      sw.stop();
      final b = await ChannelKey.deriveInline(5, 'pass-word');
      expect(a.tag, b.tag);
      expect(a.fingerprint, b.fingerprint);
      // ignore: avoid_print
      print(
        'PBKDF2 ${ChannelKey.iterations} rounds: ${sw.elapsedMilliseconds} ms',
      );
    });

    test('sealed voice chunk still fits one BLE packet (MTU 185)', () async {
      final k = await key(2, 'abcdef');
      final chunk = ChunkPacket(
        msgId: 1,
        to: 2,
        index: 0,
        total: 1,
        durationMs: 1000,
        channelMessage: false,
        data: Uint8List(bleChunkSize - ChannelKey.overhead),
      ).encode();
      final wire = k.seal(
        Frame(
          type: FrameType.data,
          senderId: 1,
          channel: k.tag,
          seq: 1,
          payload: chunk,
        ),
      );
      expect(wire.length, lessThanOrEqualTo(185 - 3));
      // And within the 15 fragment limit at the 23 byte default MTU.
      expect(Fragmenter(maxChunkSize: 20).split(wire).length, lessThan(16));
    });
  });

  group('TransportManager on a private channel', () {
    late Air air;
    final managers = <TransportManager>[];

    Future<TransportManager> phone(int id, int ch, [ChannelKey? k]) async {
      final m = TransportManager(
        transports: [AirTransport(air)],
        localNodeId: id,
        localName: 'phone$id',
        channel: ch,
        channelKey: k,
        helloInterval: const Duration(hours: 1),
      );
      managers.add(m);
      await m.start();
      return m;
    }

    setUp(() => air = Air());
    tearDown(() async {
      for (final m in managers) {
        await m.dispose();
      }
      managers.clear();
    });

    test('same passcode: see each other, hear audio, get rings', () async {
      final k = await key(3, 'blue-falcon');
      final a = await phone(1, 3, k);
      final b = await phone(2, 3, await key(3, 'blue-falcon'));
      final outsider = await phone(3, 3, await key(3, 'wrong-guess'));
      final public3 = await phone(4, 3); // v1.2-style public CH 3

      await a.sendHello();
      await b.sendHello();
      expect(b.peers.map((p) => p.id), [1]);
      expect(b.peers.single.name, 'phone1');
      expect(b.peers.single.channel, a.scope);
      expect(outsider.peers, isEmpty);
      expect(public3.peers, isEmpty);

      final heardB = <int>[], heardOut = <int>[], heardPub = <int>[];
      b.audio.listen((x) => heardB.add(x.opus.length));
      outsider.audio.listen((x) => heardOut.add(1));
      public3.audio.listen((x) => heardPub.add(1));
      final ringsOut = <InboundControl>[];
      outsider.controls.listen(ringsOut.add);
      final ringsB = <InboundControl>[];
      b.controls.listen(ringsB.add);

      await a.sendAudio(opus(30));
      await a.sendControlToChannel(
        const ControlMessage(ControlKind.ring, id: 9),
      );
      await Future<void>.delayed(Duration.zero);
      expect(heardB, [30]);
      expect(heardOut, isEmpty);
      expect(heardPub, isEmpty);
      expect(ringsB.single.message.kind, ControlKind.ring);
      expect(ringsOut, isEmpty);

      // Nothing on the wire carries the channel number or the name.
      final wire = (managers.first.transports.single as AirTransport).wire;
      for (final w in wire) {
        final f = Frame.tryDecode(w)!;
        if (f.type == FrameType.mesh) {
          // v1.6.0 mesh beacons: only node ids, no channel or name.
          expect(f.channel, 0);
          expect(latin1.decode(w).contains('phone1'), isFalse);
          if (f.payload.first == 1) {
            // A relayed copy: the sealed frame, unchanged.
            final inner = Frame.tryDecode(f.payload.sublist(7))!;
            expect(inner.type, FrameType.sealed);
            expect(inner.channel, k.tag);
          }
          continue;
        }
        expect(f.type, FrameType.sealed);
        expect(f.channel, k.tag);
        expect(latin1.decode(w).contains('phone1'), isFalse);
      }
    });

    test('public phones keep working and ignore private traffic', () async {
      final a = await phone(1, 3);
      final b = await phone(2, 3);
      final priv = await phone(3, 3, await key(3, 'blue-falcon'));
      await a.sendHello();
      await priv.sendHello();
      expect(b.peers.map((p) => p.id), [1]);
      expect(priv.peers, isEmpty); // private ignores plain frames
      final w = (managers.first.transports.single as AirTransport).wire.last;
      expect(Frame.tryDecode(w)!.type, FrameType.control);
      expect(Frame.tryDecode(w)!.channel, 3);
    });

    test('leaving a private channel forgets its members', () async {
      final k = await key(3, 'blue-falcon');
      final a = await phone(1, 3, k);
      final b = await phone(2, 3, k);
      await a.sendHello();
      expect(b.peers, isNotEmpty);
      await b.setChannel(3);
      expect(b.isPrivate, isFalse);
      expect(b.peers, isEmpty);
      expect(b.frameOverhead, 0);
      await b.setChannel(3, key: k);
      expect(b.frameOverhead, ChannelKey.overhead);
    });
  });

  test('private voice messages never go out on a public channel', () {
    expect(scopeMatches(1, 2), isTrue);
    expect(scopeMatches(0x10000 | 5, 3), isFalse);
    expect(scopeMatches(3, 0x10000 | 5), isFalse);
    expect(scopeMatches(0x10000 | 5, 0x10000 | 5), isTrue);
    expect(scopeMatches(0x10000 | 5, 0x10000 | 6), isFalse);
  });

  test('private channel passcodes survive save/load encoding', () {
    final m = {3: 'blue-falcon', 12: 'x"y,z'};
    expect(AppSettings.decodePrivate(AppSettings.encodePrivate(m)), m);
    expect(AppSettings.decodePrivate('garbage'), isEmpty);
  });

  group('relay', () {
    test('room for private channels is the tag, never the number', () {
      expect(RelayTransport.roomFor(3), '3');
      expect(RelayTransport.roomFor(0x10000 | 0x1a2b), 'p1a2b');
    });

    test('relay list parsing', () {
      expect(
        MultiRelayTransport.parseList(
          'wss://a.example/ws, wss://b.example/ws,wss://a.example/ws',
        ).map((u) => u.host),
        ['a.example', 'b.example'],
      );
      expect(MultiRelayTransport.parseList('off'), isEmpty);
      expect(MultiRelayTransport.parseList('http://x'), isEmpty);
    });

    test('server: /healthz, ping/pong, size limit, idle drop', () async {
      final server = await RelayServer.bind(
        address: '127.0.0.1',
        port: 0,
        maxMessageBytes: 100,
        idleTimeout: const Duration(milliseconds: 400),
      );
      final http = HttpClient();
      final req = await http.get('127.0.0.1', server.port, '/healthz');
      final res = await req.close();
      expect(res.statusCode, 200);
      await res.drain<void>();
      http.close();

      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws?ch=p1a2b&id=1',
      );
      final msgs = StreamIterator(ws);
      ws.add('ping');
      expect(await msgs.moveNext(), isTrue);
      expect(msgs.current, 'pong');
      expect(server.clientCount('p1a2b'), 1);
      ws.add(Uint8List(101)); // too big -> dropped
      expect(
        await msgs.moveNext().timeout(const Duration(seconds: 2)),
        isFalse,
      );
      expect(ws.closeCode, 1009);

      final idle = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/ws?ch=1&id=2',
      );
      final done = Completer<void>();
      idle.listen((_) {}, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 3));
      expect(idle.closeCode, 4000);
      await server.close();
    });

    test('two relays: both connected, frames arrive via each', () async {
      final s1 = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final s2 = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final uris = [
        Uri.parse('ws://127.0.0.1:${s1.port}/ws'),
        Uri.parse('ws://127.0.0.1:${s2.port}/ws'),
      ];
      final a = MultiRelayTransport(serverUris: uris);
      final b = MultiRelayTransport(serverUris: uris);
      await a.start(localNodeId: 1, channel: 0x10000 | 0x1a2b);
      await b.start(localNodeId: 2, channel: 0x10000 | 0x1a2b);
      expect(a.status, TransportStatus.running);
      expect(s1.clientCount('p1a2b'), 2);
      expect(s2.clientCount('p1a2b'), 2);
      final got = <int>[];
      b.frames.listen((f) => got.add(f.frame.seq));
      await a.send(
        Frame(
          type: FrameType.audio,
          senderId: 1,
          channel: 1,
          seq: 77,
          payload: opus(3),
        ).encode(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(got, [77, 77]); // the manager de-duplicates by (sender, seq)
      // One relay down: still connected through the other.
      await s1.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.status, TransportStatus.running);
      await a.dispose();
      await b.dispose();
      await s2.close();
    });
  });
}
