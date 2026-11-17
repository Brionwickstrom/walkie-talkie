// Relay 1.4.1: every open, refusal and close is logged with a reason and
// the client's id, room, peer address, forwarded-for and user agent.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_relay/relay_server.dart';

Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late List<String> lines;
  late RelayServer s;

  Future<RelayServer> bind({int maxRoomSize = 64, int maxBytes = 4096}) async {
    lines = [];
    return s = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      maxRoomSize: maxRoomSize,
      maxMessageBytes: maxBytes,
      log: lines.add,
    );
  }

  Future<WebSocket> open(String q, {Map<String, dynamic>? headers}) =>
      WebSocket.connect('ws://127.0.0.1:${s.port}/ws?$q', headers: headers);

  tearDown(() => s.close());

  test('open and client close are logged with client info', () async {
    await bind();
    final ws = await open(
      'ch=7&id=abc1&v=2.6.15',
      headers: {
        'X-Forwarded-For': '203.0.113.9',
        'User-Agent': 'okhttp/4.12.0',
      },
    );
    await _until(() => lines.any((l) => l.startsWith('relay open')));
    final o = lines.firstWhere((l) => l.startsWith('relay open'));
    expect(o, contains('room="7"'));
    expect(o, contains('id="abc1"'));
    expect(o, contains('xff="203.0.113.9"'));
    expect(o, contains('okhttp/4.12.0'));
    expect(o, contains('app="2.6.15"'));
    expect(o, contains('remote=127.0.0.1:'));
    await ws.close(1000, 'bye');
    await _until(() => lines.any((l) => l.startsWith('relay close')));
    final c = lines.firstWhere((l) => l.startsWith('relay close'));
    expect(c, contains('by=client'));
    expect(c, contains('code=1000'));
    expect(c, contains('peer_reason="bye"'));
  });

  test('bad room, unknown path and full room are logged as refusals', () async {
    await bind(maxRoomSize: 1);
    await expectLater(open('ch=bad!room&id=1'), throwsA(anything));
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:${s.port}/nope?ch=1'),
      throwsA(anything),
    );
    final a = await open('ch=3&id=a');
    await expectLater(open('ch=3&id=b'), throwsA(anything));
    await _until(
      () => lines.where((l) => l.startsWith('relay refuse')).length >= 3,
    );
    final r = lines.where((l) => l.startsWith('relay refuse')).join('\n');
    expect(r, contains('reason="bad room name" status=400'));
    expect(r, contains('reason="unknown path" status=404'));
    expect(r, contains('reason="room full" status=503'));
    expect(r, contains('id="b"'));
    await a.close();
  });

  test('relay drop (message too big) logs reason and by=relay', () async {
    await bind(maxBytes: 10);
    final ws = await open('ch=4&id=d');
    ws.listen((_) {});
    ws.add('x' * 50);
    await _until(() => lines.any((l) => l.startsWith('relay close')));
    expect(
      lines.firstWhere((l) => l.startsWith('relay drop')),
      allOf(
        contains('reason="message too big"'),
        contains('code=1009'),
        contains('id="d"'),
      ),
    );
    expect(
      lines.firstWhere((l) => l.startsWith('relay close')),
      allOf(contains('by=relay'), contains('reason="message too big"')),
    );
  });

  test('healthz is not logged and still answers', () async {
    await bind();
    final c = HttpClient();
    final res = await (await c.getUrl(
      Uri.parse('http://127.0.0.1:${s.port}/healthz'),
    )).close();
    expect(res.statusCode, 200);
    await res.drain<void>();
    c.close();
    expect(lines, isEmpty);
  });
}
