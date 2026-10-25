import 'dart:async';
import 'dart:io';

/// Minimal channel relay for [RelayTransport]. Pure dart:io, no packages.
///
/// Clients connect to `ws://host:port/?ch=<channel>&id=<hex node id>` and
/// every binary message is forwarded to every *other* client in the same
/// channel. No auth, no persistence: put it behind TLS (wss://) and add a
/// shared secret before exposing it publicly.
class RelayServer {
  RelayServer._(this._server);

  final HttpServer _server;
  final Map<String, Set<WebSocket>> _channels = {};

  int get port => _server.port;

  int clientCount(String channel) => _channels[channel]?.length ?? 0;

  static Future<RelayServer> bind({
    Object address = '0.0.0.0',
    int port = 8080,
  }) async {
    final http = await HttpServer.bind(address, port);
    final relay = RelayServer._(http);
    http.listen(relay._handle);
    return relay;
  }

  Future<void> _handle(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..statusCode = HttpStatus.ok
        ..write('walkie-talkie relay ok\n');
      await req.response.close();
      return;
    }
    final channel = req.uri.queryParameters['ch'] ?? '1';
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 15);
    final members = _channels.putIfAbsent(channel, () => <WebSocket>{});
    members.add(ws);
    ws.listen(
      (data) {
        if (data is! List<int>) return;
        for (final other in members) {
          if (!identical(other, ws)) other.add(data);
        }
      },
      onDone: () => _leave(channel, ws),
      onError: (_) => _leave(channel, ws),
      cancelOnError: true,
    );
  }

  void _leave(String channel, WebSocket ws) {
    final members = _channels[channel];
    members?.remove(ws);
    if (members != null && members.isEmpty) _channels.remove(channel);
  }

  Future<void> close() async {
    for (final members in _channels.values) {
      for (final ws in members.toList()) {
        await ws.close();
      }
    }
    _channels.clear();
    await _server.close(force: true);
  }
}
