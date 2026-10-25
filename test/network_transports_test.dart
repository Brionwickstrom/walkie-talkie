import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_relay/relay_server.dart';
import 'package:walkie_talkie/transports/lan_transport.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

Uint8List frameBytes(int from, int seq, {int channel = 1}) => Frame(
  type: FrameType.audio,
  senderId: from,
  channel: channel,
  seq: seq,
  payload: Uint8List.fromList([1, 2, 3]),
).encode();

void main() {
  test(
    'LAN: discovery beacon then unicast audio over real UDP sockets',
    () async {
      final loop = InternetAddress.loopbackIPv4;
      final a = LanTransport(
        port: 0,
        enableBroadcast: false,
        bindAddress: loop,
      );
      await a.start(localNodeId: 1, channel: 1);
      final b = LanTransport(
        port: 0,
        enableBroadcast: false,
        bindAddress: loop,
        staticPeers: [LanEndpoint(loop, a.boundPort!)],
      );
      await b.start(localNodeId: 2, channel: 1);

      final atA = a.frames.first;
      await b.send(frameBytes(2, 0)); // "hello" to all candidates
      final f = (await atA.timeout(const Duration(seconds: 2))).frame;
      expect(f.senderId, 2);

      // A learned B's endpoint from that packet and can unicast back by id.
      final atB = b.frames.first;
      await a.send(frameBytes(1, 0), peerIds: {2});
      final back = await atB.timeout(const Duration(seconds: 2));
      expect(back.frame.senderId, 1);
      expect(back.transport, TransportKind.lan);

      await a.dispose();
      await b.dispose();
    },
  );

  test('Internet relay: fans out within a channel only', () async {
    final server = await RelayServer.bind(address: '127.0.0.1', port: 0);
    final uri = Uri.parse('ws://127.0.0.1:${server.port}/');
    final a = RelayTransport(serverUri: uri);
    final b = RelayTransport(serverUri: uri);
    final c = RelayTransport(serverUri: uri);
    await a.start(localNodeId: 1, channel: 1);
    await b.start(localNodeId: 2, channel: 1);
    await c.start(localNodeId: 3, channel: 2);
    expect(a.status, TransportStatus.running);

    final gotC = <Frame>[];
    c.frames.listen((f) => gotC.add(f.frame));
    final atB = b.frames.first;
    await a.send(frameBytes(1, 42));
    final f = await atB.timeout(const Duration(seconds: 2));
    expect(f.frame.seq, 42);
    expect(f.transport, TransportKind.internet);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(gotC, isEmpty);

    // Switching channel re-joins on the relay.
    await c.setChannel(1);
    final atC = c.frames.first;
    await a.send(frameBytes(1, 43));
    expect((await atC.timeout(const Duration(seconds: 2))).frame.seq, 43);

    await a.dispose();
    await b.dispose();
    await c.dispose();
    await server.close();
  });

  test('Internet relay: no server configured reports unavailable', () async {
    final t = RelayTransport();
    await t.start(localNodeId: 1, channel: 1);
    expect(t.status, TransportStatus.unavailable);
    await t.dispose();
  });
}
