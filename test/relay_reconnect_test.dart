import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/transports/relay_socket.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

class FakeSocket implements RelaySocket {
  final ctl = StreamController<Object>();
  final sentText = <String>[];
  bool closed = false;
  @override
  String? closeReason;
  @override
  String? network = 'mobile data';
  @override
  Stream<Object> get messages => ctl.stream;
  @override
  void send(Uint8List data) {}
  @override
  void sendText(String text) => sentText.add(text);
  @override
  Future<void> close() async {
    closed = true;
    if (!ctl.isClosed) await ctl.close();
  }
}

class FakeConnector implements RelayConnector {
  final net = StreamController<String>.broadcast();
  final sockets = <FakeSocket>[];
  Object? failWith;
  @override
  Stream<String> get networkChanges => net.stream;
  @override
  Future<RelaySocket> connect(Uri uri, {required Duration timeout}) async {
    if (failWith != null) throw RelayConnectException('$failWith');
    final s = FakeSocket();
    sockets.add(s);
    return s;
  }
}

void main() {
  final uri = Uri.parse('wss://relay.test/ws');

  test('network change replaces the socket right away', () async {
    final c = FakeConnector();
    final t = RelayTransport(serverUri: uri, connector: c);
    await t.start(localNodeId: 1, channel: 1);
    expect(t.status, TransportStatus.running);
    expect(t.network, 'mobile data');
    c.net.add('Wi-Fi');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.sockets.length, 2);
    expect(c.sockets.first.closed, isTrue);
    expect(t.status, TransportStatus.running);
    await t.dispose();
  });

  test('lost connection retries with backoff and reports why', () async {
    final c = FakeConnector();
    final t = RelayTransport(
      serverUri: uri,
      connector: c,
      minBackoff: const Duration(milliseconds: 50),
    );
    await t.start(localNodeId: 1, channel: 1);
    c.failWith = 'HTTP 503';
    c.sockets.single.closeReason = 'closed 1006';
    await c.sockets.single.ctl.close();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(t.status, TransportStatus.error);
    expect(t.lastError, contains('1006'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(t.lastError, contains('HTTP 503'));
    c.failWith = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(t.status, TransportStatus.running);
    await t.dispose();
  });

  test('app keep-alive ping', () async {
    final c = FakeConnector();
    final t = RelayTransport(
      serverUri: uri,
      connector: c,
      pingInterval: const Duration(milliseconds: 30),
    );
    await t.start(localNodeId: 1, channel: 1);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(c.sockets.first.sentText, contains('ping'));
    await t.dispose();
  });
}
