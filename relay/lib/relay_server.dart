import 'dart:async';
import 'dart:convert';
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
/// * v1.4.0 room roster (opt in, for the app's "Unknown listener"
///   warning): a socket that connects with `&r=1` gets a text message
///   `{"t":"roster","n":3,"s":[["a1b2",idle,age,sent],...]}` every
///   [rosterInterval] and shortly after someone joins or leaves. One entry
///   per socket in the room (including the receiver): the id it claimed,
///   seconds since it last sent anything, seconds since it connected, and
///   1 if it ever sent a binary frame. Older apps never ask for it (and
///   ignore text anyway), so nothing changes for them.
/// * v1.4.0 silent sockets in private rooms ("p" + 4 hex): a socket gets
///   the room's frames for its first [silentGrace] after connecting, and
///   after that only while it keeps sending binary frames (every app
///   version sends a presence hello every 1-4 s). A socket that only sends
///   text pings, or nothing at all, stops receiving after [silentGrace],
///   and again after [silentAfter] without a binary frame. Public rooms,
///   friend rooms and the lobby are unchanged.
///
/// Hardening: max message size, per-connection rate limit (messages and
/// bytes per second, token bucket), sockets that stay silent for
/// [idleTimeout] are dropped, room name / count limits.
///
/// v1.4.1 connection log (behaviour unchanged): one line on stdout (the
/// container log) for every WebSocket that opens, every refused upgrade,
/// every close (by the relay or by the client / proxy, with the close code
/// and reason) and rate-limited frames, with the client's claimed id, room,
/// socket peer address, X-Forwarded-For / X-Real-IP (set by Tailscale
/// Funnel and other proxies), User-Agent and app version (`&v=`) when sent.
/// Bump with every relay change so `/healthz` shows which deploy is live.
const String relayVersion = '1.4.1';

/// Who is connecting, for the connection log (v1.4.1).
class RelayPeer {
  RelayPeer({
    required this.remote,
    this.forwardedFor = '',
    this.realIp = '',
    this.userAgent = '',
    this.appVersion = '',
    this.id = '',
    this.room = '',
    this.path = '',
  });

  /// Peer address and port of the TCP socket ("-" if unknown).
  final String remote;
  final String forwardedFor;
  final String realIp;
  final String userAgent;
  final String appVersion;
  final String id;
  final String room;
  final String path;

  factory RelayPeer.of(HttpRequest req) {
    String h(String name) => _clean(req.headers.value(name) ?? '');
    final ci = req.connectionInfo;
    final q = req.uri.queryParameters;
    return RelayPeer(
      remote: ci == null ? '-' : '${ci.remoteAddress.address}:${ci.remotePort}',
      forwardedFor: h('x-forwarded-for'),
      realIp: h('x-real-ip'),
      userAgent: h('user-agent'),
      appVersion: _clean(q['v'] ?? q['app'] ?? ''),
      id: _clean(q['id'] ?? ''),
      room: _clean(q['ch'] ?? ''),
      path: _clean(req.uri.path),
    );
  }

  /// Log values are single line and bounded (headers are client input).
  static String _clean(String v) {
    final s = v.replaceAll(RegExp(r'[\x00-\x1f\x7f"]'), '?');
    return s.length > 120 ? '${s.substring(0, 120)}...' : s;
  }

  String describe() {
    final b = StringBuffer('remote=$remote');
    if (forwardedFor.isNotEmpty) b.write(' xff="$forwardedFor"');
    if (realIp.isNotEmpty) b.write(' xrealip="$realIp"');
    b.write(' id="$id" room="$room"');
    if (path.isNotEmpty && path != '/ws') b.write(' path="$path"');
    if (appVersion.isNotEmpty) b.write(' app="$appVersion"');
    b.write(' ua="$userAgent"');
    return b.toString();
  }
}

/// Default connection log sink: UTC timestamp + line on stdout.
void _stdoutLog(String line) {
  try {
    stdout.writeln('${DateTime.now().toUtc().toIso8601String()} $line');
  } catch (_) {}
}

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
    required this.rosterInterval,
    required this.silentGrace,
    required this.silentAfter,
    required this.log,
  });

  final HttpServer _server;

  /// Connection log sink (v1.4.1). Defaults to stdout.
  final void Function(String line) log;
  final int maxMessageBytes;
  final int maxMessagesPerSecond;
  final int maxBytesPerSecond;
  final Duration idleTimeout;
  final int maxRoomSize;

  /// How often opted-in sockets get the room roster (v1.4.0).
  final Duration rosterInterval;

  /// Private rooms: a new socket receives for this long before it has to
  /// send a binary frame (v1.4.0).
  final Duration silentGrace;

  /// Private rooms: a socket with no binary frame for this long stops
  /// receiving until it sends one again (v1.4.0).
  final Duration silentAfter;

  /// Private channel rooms ("p" + 16 bit tag in hex), see the app's
  /// RelayTransport.roomFor.
  static final privateRoom = RegExp(r'^p[0-9a-f]{4}$');

  final Map<String, Set<_Client>> _rooms = {};
  Timer? _sweeper;
  Timer? _rosterTimer;
  final Map<String, Timer> _rosterSoon = {};

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
    Duration rosterInterval = const Duration(seconds: 5),
    Duration silentGrace = const Duration(seconds: 10),
    Duration silentAfter = const Duration(seconds: 90),
    void Function(String line)? log,
  }) async {
    final http = await HttpServer.bind(address, port);
    final relay = RelayServer._(
      http,
      maxMessageBytes: maxMessageBytes,
      maxMessagesPerSecond: maxMessagesPerSecond,
      maxBytesPerSecond: maxBytesPerSecond,
      idleTimeout: idleTimeout,
      maxRoomSize: maxRoomSize,
      rosterInterval: rosterInterval,
      silentGrace: silentGrace,
      silentAfter: silentAfter,
      log: log ?? _stdoutLog,
    );
    http.listen(relay._handle, onError: (_) {});
    relay._sweeper = Timer.periodic(
      Duration(
        milliseconds: (idleTimeout.inMilliseconds ~/ 4).clamp(50, 30000),
      ),
      (_) => relay._sweep(),
    );
    relay._rosterTimer = Timer.periodic(
      rosterInterval,
      (_) => relay._sendRosters(),
    );
    return relay;
  }

  static final _roomRe = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

  Future<void> _handle(HttpRequest req) async {
    RelayPeer? peer;
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
      peer = RelayPeer.of(req);
      if (path != '/ws' && path != '/') {
        log('relay refuse reason="unknown path" status=404 ${peer.describe()}');
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final room = req.uri.queryParameters['ch'] ?? '1';
      if (!_roomRe.hasMatch(room)) {
        log('relay refuse reason="bad room name" status=400 ${peer.describe()}');
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final members = _rooms[room];
      if (members != null && members.length >= maxRoomSize) {
        log(
          'relay refuse reason="room full" status=503 '
          'members=${members.length} max=$maxRoomSize ${peer.describe()}',
        );
        req.response.statusCode = HttpStatus.serviceUnavailable;
        await req.response.close();
        return;
      }
      final WebSocket ws;
      try {
        ws = await WebSocketTransformer.upgrade(req);
      } catch (e) {
        log(
          'relay refuse reason="upgrade failed" '
          'error="${RelayPeer._clean('$e')}" ${peer.describe()}',
        );
        rethrow;
      }
      ws.pingInterval = const Duration(seconds: 20);
      final q = req.uri.queryParameters;
      final id = q['id'] ?? '';
      final c = _Client(
        ws,
        room,
        this,
        id: RegExp(r'^[0-9a-fA-F]{1,16}$').hasMatch(id) ? id.toLowerCase() : '',
        roster: q['r'] == '1',
        peer: peer,
      );
      _rooms.putIfAbsent(room, () => <_Client>{}).add(c);
      _rosterChanged(room);
      log(
        'relay open members=${_rooms[room]!.length} '
        'ext="${RelayPeer._clean(ws.extensions)}" ${peer.describe()}',
      );
      ws.listen(
        c.onMessage,
        onDone: () {
          c.logClosed(null);
          _leave(c);
        },
        onError: (Object e) {
          c.logClosed(e);
          _leave(c);
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (peer != null) {
        log(
          'relay refuse reason="error" error="${RelayPeer._clean('$e')}" '
          '${peer.describe()}',
        );
      }
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  void _forward(_Client from, List<int> data) {
    final members = _rooms[from.room];
    if (members == null) return;
    final gate = privateRoom.hasMatch(from.room);
    final now = DateTime.now();
    for (final other in members) {
      if (identical(other, from)) continue;
      if (gate && !other.mayReceive(now)) {
        other.withheld++;
        continue;
      }
      try {
        other.ws.add(data);
      } catch (_) {}
    }
  }

  /// Roster of [room] as sent to opted-in sockets (also for tests).
  Map<String, Object?> rosterOf(String room) {
    final now = DateTime.now();
    final members = _rooms[room] ?? const <_Client>{};
    return {
      't': 'roster',
      'n': members.length,
      's': [
        for (final c in members)
          [
            c.id,
            now.difference(c.lastHeard).inSeconds,
            now.difference(c.connectedAt).inSeconds,
            c.sentBinary == null ? 0 : 1,
          ],
      ],
    };
  }

  void _sendRoster(String room) {
    final members = _rooms[room];
    if (members == null || !members.any((c) => c.roster)) return;
    final text = jsonEncode(rosterOf(room));
    for (final c in members) {
      if (!c.roster) continue;
      try {
        c.ws.add(text);
      } catch (_) {}
    }
  }

  void _sendRosters() {
    for (final room in _rooms.keys.toList()) {
      _sendRoster(room);
    }
  }

  /// Someone joined or left: tell the room soon (batched).
  void _rosterChanged(String room) {
    if (_rosterSoon.containsKey(room)) return;
    _rosterSoon[room] = Timer(const Duration(milliseconds: 300), () {
      _rosterSoon.remove(room);
      _sendRoster(room);
    });
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
    final removed = members?.remove(c) ?? false;
    if (members != null && members.isEmpty) _rooms.remove(c.room);
    if (removed && members != null && members.isNotEmpty) {
      _rosterChanged(c.room);
    }
  }

  Future<void> close() async {
    _sweeper?.cancel();
    _rosterTimer?.cancel();
    for (final t in _rosterSoon.values) {
      t.cancel();
    }
    _rosterSoon.clear();
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
  _Client(
    this.ws,
    this.room,
    this.server, {
    this.id = '',
    this.roster = false,
    RelayPeer? peer,
  })  : peer = peer ?? RelayPeer(remote: '-'),
        _msgTokens = server.maxMessagesPerSecond.toDouble(),
        _byteTokens = server.maxBytesPerSecond.toDouble();

  final WebSocket ws;
  final String room;
  final RelayServer server;

  /// The node id the socket claimed (`&id=`, hex), '' if none. Not
  /// verified: the app only uses it next to who it actually hears.
  final String id;

  /// Asked for the room roster (`&r=1`, app 1.9.4+).
  final bool roster;

  /// For the connection log (v1.4.1).
  final RelayPeer peer;

  /// Frames dropped by the rate limit / sent before the close (log only).
  int limited = 0;
  int received = 0;

  /// Set when the relay itself closes the socket ([drop]).
  String? dropReason;
  bool _closeLogged = false;

  String get _age =>
      '${(DateTime.now().difference(connectedAt).inMilliseconds / 1000).toStringAsFixed(1)}s';

  /// The socket ended: log who closed it and why (v1.4.1).
  void logClosed(Object? error) {
    if (_closeLogged) return;
    _closeLogged = true;
    final by = dropReason != null ? 'relay' : 'client';
    final why = dropReason ??
        (error != null
            ? 'socket error'
            : ws.closeCode == null ||
                    ws.closeCode == 1005 ||
                    ws.closeCode == 1006
                ? 'connection dropped without a close frame'
                : 'closed by client');
    final b = StringBuffer(
      'relay close by=$by reason="${RelayPeer._clean(why)}" '
      'code=${ws.closeCode ?? '-'} '
      'peer_reason="${RelayPeer._clean(ws.closeReason ?? '')}"',
    );
    if (error != null) b.write(' error="${RelayPeer._clean('$error')}"');
    b.write(' after=$_age frames=$received limited=$limited');
    b.write(' ${peer.describe()}');
    server.log(b.toString());
  }

  final DateTime connectedAt = DateTime.now();

  /// Last binary frame from this socket (null: none yet).
  DateTime? sentBinary;

  /// Frames not forwarded to this silent socket (private rooms).
  int withheld = 0;

  /// Private rooms: new sockets get a grace period, then only sockets
  /// that keep sending binary frames receive.
  bool mayReceive(DateTime now) {
    if (now.difference(connectedAt) < server.silentGrace) return true;
    final b = sentBinary;
    return b != null && now.difference(b) < server.silentAfter;
  }

  DateTime lastHeard = DateTime.now();
  DateTime _refill = DateTime.now();
  double _msgTokens;
  double _byteTokens;
  bool _dropped = false;

  void onMessage(dynamic data) {
    if (_dropped) return;
    final now = DateTime.now();
    lastHeard = now;
    received++;
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
    if (_msgTokens < 1 || _byteTokens < size) {
      // Over the limit: the frame is dropped (socket stays open). Logged on
      // the first drop and then every 100th, so a flood cannot flood the log.
      limited++;
      if (limited == 1 || limited % 100 == 0) {
        server.log(
          'relay ratelimit dropped=$limited size=$size '
          'after=$_age ${peer.describe()}',
        );
      }
      return;
    }
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
    sentBinary = now;
    server._forward(this, data as List<int>);
  }

  void drop(int code, String reason) {
    if (_dropped) return;
    _dropped = true;
    dropReason = reason;
    server.log(
      'relay drop reason="$reason" code=$code after=$_age '
      'frames=$received limited=$limited ${peer.describe()}',
    );
    server._leave(this);
    ws.close(code, reason).catchError((_) {});
  }
}
