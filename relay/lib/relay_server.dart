import 'dart:async';
import 'dart:io';

/// Channel relay for the app's internet transport. Pure dart:io, no packages.
///
/// * `GET /healthz` -> 200 "ok" (Render health check).
/// * WebSocket upgrade on `/ws` (and `/` for older builds) with
///   `?ch=<room>&id=<hex node id>`. Every binary message is forwarded to
///   every *other* socket in the same room. Public channels use the
///   channel number as room, private channels a key-derived tag ("p1a2b"),
///   and their frames are end-to-end encrypted, so the relay never sees
///   passcodes or audio.
/// * Text message "ping" is answered with "pong" (app keep-alive, every
///   25 s, keeps NAT / proxies from closing idle sockets).
///
/// Hardening: max message size, per-connection rate limit (messages and
/// bytes per second, token bucket), sockets that stay silent for
/// [idleTimeout] are dropped, room name / count limits.
/// Bump with every relay change so `/healthz` shows which deploy is live.
const String relayVersion = '1.3.1';

/// e.g. "relay 1.3.1 commit 1a2b3c4 rooms 2 clients 3" (Render sets
/// RENDER_GIT_COMMIT for the running deploy).
String get _commit {
  final c = Platform.environment['RENDER_GIT_COMMIT'] ?? '';
  return c.length > 7 ? c.substring(0, 7) : c;
}

class RelayServer {
  RelayServer._(
    this._server, {
    required this.maxMessageBytes,
    required this.maxMessagesPerSecond,
    required this.maxBytesPerSecond,
    required this.idleTimeout,
    required this.maxRoomSize,
  });

  final HttpServer _server;
  final int maxMessageBytes;
  final int maxMessagesPerSecond;
  final int maxBytesPerSecond;
  final Duration idleTimeout;
  final int maxRoomSize;

  final Map<String, Set<_Client>> _rooms = {};
  Timer? _sweeper;

  int get port => _server.port;

  int clientCount(String room) => _rooms[room]?.length ?? 0;

  String get versionLabel {
    final clients = _rooms.values.fold<int>(0, (n, r) => n + r.length);
    return 'relay $relayVersion'
        '${_commit.isEmpty ? '' : ' commit $_commit'}'
        ' rooms ${_rooms.length} clients $clients';
  }

  static Future<RelayServer> bind({
    Object address = '0.0.0.0',
    int port = 8080,
    int maxMessageBytes = 4096,
    int maxMessagesPerSecond = 150,
    int maxBytesPerSecond = 64 * 1024,
    Duration idleTimeout = const Duration(minutes: 3),
    int maxRoomSize = 64,
  }) async {
    final http = await HttpServer.bind(address, port);
    final relay = RelayServer._(
      http,
      maxMessageBytes: maxMessageBytes,
      maxMessagesPerSecond: maxMessagesPerSecond,
      maxBytesPerSecond: maxBytesPerSecond,
      idleTimeout: idleTimeout,
      maxRoomSize: maxRoomSize,
    );
    http.listen(relay._handle, onError: (_) {});
    relay._sweeper = Timer.periodic(
      Duration(
        milliseconds: (idleTimeout.inMilliseconds ~/ 4).clamp(50, 30000),
      ),
      (_) => relay._sweep(),
    );
    return relay;
  }

  static final _roomRe = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        final ok = path == '/healthz' || path == '/';
        req.response
          ..statusCode = ok ? HttpStatus.ok : HttpStatus.notFound
          ..headers.contentType = ContentType.text
          ..headers.set('cache-control', 'no-store')
          ..write(ok ? 'ok $versionLabel\n' : 'not found\n');
        await req.response.close();
        return;
      }
      if (path != '/ws' && path != '/') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final room = req.uri.queryParameters['ch'] ?? '1';
      if (!_roomRe.hasMatch(room)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final members = _rooms[room];
      if (members != null && members.length >= maxRoomSize) {
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.pingInterval = const Duration(seconds: 20);
      final c = _Client(ws, room, this);
      _rooms.putIfAbsent(room, () => <_Client>{}).add(c);
      ws.listen(
        c.onMessage,
        onDone: () => _leave(c),
        onError: (_) => _leave(c),
        cancelOnError: true,
      );
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  void _forward(_Client from, List<int> data) {
    final members = _rooms[from.room];
    if (members == null) return;
    for (final other in members) {
      if (!identical(other, from)) {
        try {
          other.ws.add(data);
        } catch (_) {}
      }
    }
  }

  void _sweep() {
    final now = DateTime.now();
    for (final members in _rooms.values.toList()) {
      for (final c in members.toList()) {
        if (now.difference(c.lastHeard) > idleTimeout) c.drop(4000, 'idle');
      }
    }
  }

  void _leave(_Client c) {
    final members = _rooms[c.room];
    members?.remove(c);
    if (members != null && members.isEmpty) _rooms.remove(c.room);
  }

  Future<void> close() async {
    _sweeper?.cancel();
    for (final members in _rooms.values.toList()) {
      for (final c in members.toList()) {
        await c.ws.close();
      }
    }
    _rooms.clear();
    await _server.close(force: true);
  }
}

class _Client {
  _Client(this.ws, this.room, this.server)
      : _msgTokens = server.maxMessagesPerSecond.toDouble(),
        _byteTokens = server.maxBytesPerSecond.toDouble();

  final WebSocket ws;
  final String room;
  final RelayServer server;
  DateTime lastHeard = DateTime.now();
  DateTime _refill = DateTime.now();
  double _msgTokens;
  double _byteTokens;
  bool _dropped = false;

  void onMessage(dynamic data) {
    if (_dropped) return;
    final now = DateTime.now();
    lastHeard = now;
    final size = data is String ? data.length : (data as List<int>).length;
    if (size > server.maxMessageBytes) {
      drop(1009, 'message too big');
      return;
    }
    final dt = now.difference(_refill).inMicroseconds / 1e6;
    _refill = now;
    // Bucket holds up to 2 s worth of traffic (bursts after a stall).
    _msgTokens = (_msgTokens + dt * server.maxMessagesPerSecond).clamp(
      0,
      2.0 * server.maxMessagesPerSecond,
    );
    _byteTokens = (_byteTokens + dt * server.maxBytesPerSecond).clamp(
      0,
      2.0 * server.maxBytesPerSecond,
    );
    if (_msgTokens < 1 || _byteTokens < size) return; // over the limit: drop
    _msgTokens -= 1;
    _byteTokens -= size;
    if (data is String) {
      if (data == 'ping') {
        try {
          ws.add('pong');
        } catch (_) {}
      }
      return; // text is never forwarded
    }
    server._forward(this, data as List<int>);
  }

  void drop(int code, String reason) {
    if (_dropped) return;
    _dropped = true;
    server._leave(this);
    ws.close(code, reason).catchError((_) {});
  }
}
