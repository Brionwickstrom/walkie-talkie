// The connection test says why a relay socket ended before the pong
// (close code / reason), instead of always "closed by the relay".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/conn_probes.dart';
import 'package:walkie_talkie/transports/relay_socket.dart';

void main() {
  test(
    'socket closed right after the upgrade: code and reason shown',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((_) {});
        await ws.close(4001, 'test bye');
      });
      try {
        final p = await probeRelay(
          server: Uri.parse('ws://127.0.0.1:${server.port}/ws'),
          channelScope: 1,
          connector: IoRelayConnector(),
        );
        expect(p.ok, isFalse);
        expect(p.error, contains('closed before the ping answer'));
        expect(p.error, contains('4001'));
        expect(p.error, isNot(contains('closed by the relay')));
      } finally {
        await server.close(force: true);
      }
    },
  );

  test('message without a reason', () {
    expect(closedBeforePong(null, 120), contains('(no reason given)'));
    expect(closedBeforePong('closed 1006', 90), endsWith(': closed 1006'));
  });
}
