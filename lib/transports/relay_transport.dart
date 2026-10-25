import 'dart:async';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/transport.dart';
import 'relay_socket.dart';

/// Internet transport: a WebSocket to a tiny relay server that fans each
/// binary frame out to every other phone joined to the same channel.
///
/// Works across any networks/NATs (mobile data on one phone, Wi-Fi on the
/// other) because both sides make outbound connections. The server is in
/// `relay/` (deployed on Render, see render.yaml).
///
/// The connection is kept up whenever the phone is online (also from the
/// background service): reconnects with exponential backoff, a generous
/// first-connect timeout (Render's free tier sleeps and takes ~50 s to
/// wake), and a text "ping" every [pingInterval] (server answers "pong")
/// that also detects silently dead sockets after a network change.
///
/// A relay was chosen over WebRTC for v1: it needs no STUN/TURN, has one
/// moving part, and push-to-talk audio is ~2-3 KB/s per talker. WebRTC
/// (flutter_webrtc) peer-to-peer data channels are a drop-in replacement
/// behind this same [Transport] interface later; the relay would then just
/// carry signaling.
class RelayTransport extends Transport {
  RelayTransport({
    this._serverUri,
    RelayConnector? connector,
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 75),
    this.pingInterval = const Duration(seconds: 25),
    this.room,
  }) : connector = connector ?? IoRelayConnector() {
    _netSub = this.connector.networkChanges.listen(_onNetworkChanged);
  }

  Uri? _serverUri;
  final RelayConnector connector;

  /// Fixed relay room (friend links) instead of the channel's room.
  final String? room;
  final Duration minBackoff;
  final Duration maxBackoff;

  /// Long on purpose: a sleeping free-tier server needs ~50 s to start.
  final Duration connectTimeout;
  final Duration pingInterval;

  int _localNodeId = 0;
  int _channel = 1;
  bool _wanted = false;
  bool _connecting = false;
  RelaySocket? _ws;
  StreamSubscription<Object>? _sub;
  StreamSubscription<String>? _netSub;
  Timer? _retry;
  Timer? _ping;
  Duration _backoff = Duration.zero;
  DateTime _lastRx = DateTime.now();
  DateTime? _connectedAt;
  int _connects = 0;
  int _attempt = 0;
  String? _lastError;
  TransportStatus _status = TransportStatus.stopped;
  String? _detail;
  final _statusCtl = StreamController<TransportStatus>.broadcast();
  final _framesCtl = StreamController<InboundFrame>.broadcast();

  @override
  TransportKind get kind => TransportKind.internet;
  @override
  TransportStatus get status => _status;
  @override
  String? get statusDetail => _detail;
  @override
  Stream<TransportStatus> get statusChanges => _statusCtl.stream;
  @override
  Stream<InboundFrame> get frames => _framesCtl.stream;

  Uri? get serverUri => _serverUri;

  /// Network the open socket uses ("Wi-Fi", "mobile data"), when known.
  String? get network => _ws?.network;

  /// Why the last connection attempt / connection failed.
  String? get lastError => _lastError;

  /// When the next retry happens, while waiting.
  Duration? get retryIn => _retry == null ? null : _backoff;

  @override
  String? get debugInfo {
    final host = _serverUri?.host;
    if (host == null) return null;
    return '$host room ${room ?? roomFor(_channel)}'
        '${network != null ? ' via $network' : ''}'
        '${_connects > 1 ? ' · reconnects ${_connects - 1}' : ''}'
        '${_status != TransportStatus.running && _retry != null ? ' · retry in ${_backoff.inSeconds}s' : ''}';
  }

  /// Point at a different relay (from settings). Empty/null disables.
  Future<void> setServerUri(Uri? uri) async {
    _serverUri = uri;
    if (_wanted) {
      await _disconnect();
      _backoff = Duration.zero;
      await _connectAndWait();
    }
  }

  /// Relay room for a channel / scope: the channel number, or for a
  /// private channel ("scope" > 0xFFFF) "p" + its key-derived tag, so the
  /// relay never learns the channel number or anything about the passcode.
  static String roomFor(int channel) => channel > 0xFFFF
      ? 'p${(channel & 0xFFFF).toRadixString(16).padLeft(4, '0')}'
      : '$channel';

  static Uri channelUri(Uri base, int channel, int nodeId) => base.replace(
    queryParameters: {
      ...base.queryParameters,
      'ch': roomFor(channel),
      'id': nodeId.toRadixString(16),
    },
  );

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    _localNodeId = localNodeId;
    _channel = channel;
    _wanted = true;
    _backoff = Duration.zero;
    await _connectAndWait();
  }

  /// Start connecting without blocking the caller on a cold relay: waits at
  /// most a few seconds (enough for a warm server), then keeps trying in
  /// the background.
  Future<void> _connectAndWait() async {
    unawaited(_connect());
    if (_serverUri == null) return;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_connecting && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> _connect() async {
    if (_connecting || !_wanted) return;
    final base = _serverUri;
    if (base == null) {
      _setStatus(TransportStatus.unavailable, 'No relay server configured');
      return;
    }
    _connecting = true;
    _retry?.cancel();
    _retry = null;
    final attempt = ++_attempt;
    _setStatus(
      TransportStatus.starting,
      _connects == 0
          ? 'Connecting (a sleeping relay can take up to a minute to wake)'
          : 'Reconnecting',
    );
    try {
      final ws = await connector.connect(
        room != null
            ? base.replace(
                queryParameters: {
                  ...base.queryParameters,
                  'ch': room!,
                  'id': _localNodeId.toRadixString(16),
                },
              )
            : channelUri(base, _channel, _localNodeId),
        timeout: connectTimeout,
      );
      if (attempt != _attempt || !_wanted) {
        await ws.close();
        return;
      }
      _ws = ws;
      _connects++;
      _connectedAt = DateTime.now();
      _lastRx = DateTime.now();
      _lastError = null;
      _sub = ws.messages.listen((data) {
        _lastRx = DateTime.now();
        if (data is Uint8List) {
          final f = Frame.tryDecode(data);
          if (f != null && !_framesCtl.isClosed) {
            _framesCtl.add(InboundFrame(f, TransportKind.internet));
          }
        }
        // Text ("pong") only refreshes liveness.
      }, onDone: () => _onLost(ws, ws.closeReason ?? 'connection closed'));
      _startPing();
      _setStatus(TransportStatus.running);
    } catch (e) {
      if (attempt == _attempt) {
        _lastError = '$e';
        _setStatus(TransportStatus.error, 'Relay unreachable: $e');
        _scheduleRetry();
      }
    } finally {
      if (attempt == _attempt) _connecting = false;
    }
  }

  bool _saver = false;

  /// Battery saver pings half as often (our hellos still keep the server
  /// side busy; a dead socket is noticed a bit later).
  Duration get currentPingInterval => _saver ? pingInterval * 2 : pingInterval;

  @override
  void setPowerSaver(bool on) {
    if (on == _saver) return;
    _saver = on;
    if (_ping != null) _startPing();
  }

  void _startPing() {
    _ping?.cancel();
    _ping = Timer.periodic(currentPingInterval, (_) => _keepAlive());
  }

  void _keepAlive() {
    final ws = _ws;
    if (ws == null) return;
    // No pong (or anything) for 2.5 ping periods: the socket is dead
    // (network switched, NAT timed out). Reconnect.
    if (DateTime.now().difference(_lastRx) > currentPingInterval * 2.5) {
      _onLost(ws, 'no answer from relay');
      return;
    }
    try {
      ws.sendText('ping');
    } catch (e) {
      _onLost(ws, '$e');
    }
  }

  void _onLost(RelaySocket which, String why) {
    if (!identical(which, _ws)) return;
    _ping?.cancel();
    _ping = null;
    final sub = _sub;
    _sub = null;
    _ws = null;
    unawaited(sub?.cancel());
    unawaited(which.close());
    // A connection that lived a while was fine: retry fast.
    final lived =
        _connectedAt != null &&
        DateTime.now().difference(_connectedAt!) > const Duration(seconds: 30);
    if (lived) _backoff = Duration.zero;
    _lastError = why;
    if (_wanted) {
      _setStatus(TransportStatus.error, 'Relay connection lost: $why');
      _scheduleRetry();
    }
  }

  void _onNetworkChanged(String net) {
    if (!_wanted) return;
    // The phone switched networks (left Wi-Fi, mobile data back, ...). The
    // old socket is probably dead or on the wrong network: replace it now
    // instead of waiting for pings to time out.
    unawaited(() async {
      await _disconnect();
      _backoff = Duration.zero;
      await _connect();
    }());
  }

  void _scheduleRetry() {
    _retry?.cancel();
    if (!_wanted) return;
    _backoff = _backoff == Duration.zero
        ? minBackoff
        : (_backoff * 2 > maxBackoff ? maxBackoff : _backoff * 2);
    _retry = Timer(_backoff, () {
      _retry = null;
      if (_wanted && _ws == null) _connect();
    });
  }

  Future<void> _disconnect() async {
    _retry?.cancel();
    _retry = null;
    _ping?.cancel();
    _ping = null;
    _attempt++; // abandon an in-flight connect
    _connecting = false;
    final sub = _sub;
    _sub = null;
    final ws = _ws;
    _ws = null;
    await sub?.cancel();
    await ws?.close();
  }

  /// Retry now (e.g. the phone just came back online).
  Future<void> reconnectNow() async {
    if (!_wanted || _ws != null) return;
    _backoff = Duration.zero;
    await _connect();
  }

  @override
  Future<void> setChannel(int channel) async {
    if (channel == _channel) return;
    _channel = channel;
    if (_wanted) {
      await _disconnect();
      _backoff = Duration.zero;
      await _connectAndWait();
    }
  }

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    // The relay fans out to the whole room; the receiver filters.
    try {
      _ws?.send(frame);
    } catch (_) {}
  }

  void _setStatus(TransportStatus s, [String? detail]) {
    _status = s;
    _detail = detail;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  @override
  Future<void> stop() async {
    _wanted = false;
    await _disconnect();
    _setStatus(TransportStatus.stopped);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _netSub?.cancel();
    await _statusCtl.close();
    await _framesCtl.close();
  }
}

/// Several relays at once, as one internet [Transport].
///
/// The list is ordered (first = preferred, e.g. a home Synology relay, then
/// the public Render one). Every relay that can be reached is connected in
/// parallel and every frame is sent to all connected relays, so two phones
/// meet as long as they share at least one working relay; the
/// [TransportManager] drops the duplicate copies by (sender, seq). The
/// status / debug line follows the first connected relay.
class MultiRelayTransport extends Transport {
  MultiRelayTransport({
    List<Uri> serverUris = const [],
    RelayTransport Function(Uri uri)? factory,
    RelayConnector? connector,
  }) : _factory =
           factory ??
           ((u) => RelayTransport(serverUri: u, connector: connector)) {
    _build(serverUris);
  }

  /// Parse a comma / whitespace separated list ("wss://a/ws, wss://b/ws").
  /// "off" (or empty) gives an empty list.
  static List<Uri> parseList(String text) {
    final out = <Uri>[];
    for (final part in text.split(RegExp(r'[,\s]+'))) {
      final p = part.trim();
      if (p.isEmpty || p.toLowerCase() == 'off') continue;
      final u = Uri.tryParse(p);
      if (u == null || !(u.scheme == 'ws' || u.scheme == 'wss')) continue;
      if (!out.contains(u)) out.add(u);
    }
    return out;
  }

  final RelayTransport Function(Uri uri) _factory;
  final List<RelayTransport> _relays = [];
  final List<StreamSubscription<dynamic>> _subs = [];
  final _statusCtl = StreamController<TransportStatus>.broadcast();
  final _framesCtl = StreamController<InboundFrame>.broadcast();
  bool _wanted = false;
  int _localNodeId = 0;
  int _channel = 1;

  List<Uri> get serverUris => [for (final r in _relays) r.serverUri!];
  List<RelayTransport> get relays => List.unmodifiable(_relays);

  bool _saver = false;

  @override
  void setPowerSaver(bool on) {
    _saver = on;
    for (final r in _relays) {
      r.setPowerSaver(on);
    }
  }

  void _build(List<Uri> uris) {
    for (final u in uris) {
      final r = _factory(u)..setPowerSaver(_saver);
      _relays.add(r);
      _subs.add(
        r.frames.listen((f) {
          if (!_framesCtl.isClosed) _framesCtl.add(f);
        }),
      );
      _subs.add(
        r.statusChanges.listen((_) {
          if (!_statusCtl.isClosed) _statusCtl.add(status);
        }),
      );
    }
  }

  Future<void> _teardown() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final old = List.of(_relays);
    _relays.clear();
    await Future.wait(old.map((r) => r.dispose()));
  }

  /// Replace the relay list (from settings). Empty disables the link.
  Future<void> setServerUris(List<Uri> uris) async {
    await _teardown();
    _build(uris);
    if (_wanted) {
      await Future.wait(
        _relays.map(
          (r) => r.start(localNodeId: _localNodeId, channel: _channel),
        ),
      );
    }
    if (!_statusCtl.isClosed) _statusCtl.add(status);
  }

  @override
  TransportKind get kind => TransportKind.internet;

  @override
  TransportStatus get status {
    if (!_wanted) return TransportStatus.stopped;
    if (_relays.isEmpty) return TransportStatus.unavailable;
    final all = _relays.map((r) => r.status).toSet();
    if (all.contains(TransportStatus.running)) return TransportStatus.running;
    if (all.contains(TransportStatus.starting)) return TransportStatus.starting;
    return TransportStatus.error;
  }

  @override
  String? get statusDetail {
    if (_relays.isEmpty) return 'No relay server configured';
    for (final r in _relays) {
      if (r.statusDetail != null) return r.statusDetail;
    }
    return null;
  }

  @override
  String? get debugInfo {
    if (_relays.isEmpty) return null;
    final parts = [
      for (final r in _relays)
        '${r.serverUri!.host.split('.').first}:${switch (r.status) {
          TransportStatus.running => 'up',
          TransportStatus.starting => 'connecting',
          _ => 'down',
        }}',
    ];
    return '${parts.join(' ')} · room ${RelayTransport.roomFor(_channel)}';
  }

  @override
  Stream<TransportStatus> get statusChanges => _statusCtl.stream;

  @override
  Stream<InboundFrame> get frames => _framesCtl.stream;

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    _localNodeId = localNodeId;
    _channel = channel;
    _wanted = true;
    await Future.wait(
      _relays.map((r) => r.start(localNodeId: localNodeId, channel: channel)),
    );
    if (!_statusCtl.isClosed) _statusCtl.add(status);
  }

  @override
  Future<void> setChannel(int channel) async {
    _channel = channel;
    await Future.wait(_relays.map((r) => r.setChannel(channel)));
  }

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    for (final r in _relays) {
      if (r.status == TransportStatus.running) {
        await r.send(frame, peerIds: peerIds);
      }
    }
  }

  /// Retry every disconnected relay right away.
  Future<void> reconnectNow() async {
    await Future.wait(_relays.map((r) => r.reconnectNow()));
  }

  @override
  Future<void> stop() async {
    _wanted = false;
    await Future.wait(_relays.map((r) => r.stop()));
    if (!_statusCtl.isClosed) _statusCtl.add(status);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _teardown();
    await _statusCtl.close();
    await _framesCtl.close();
  }
}
