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
    this.quickRetry = false,
    this.quickRetryDelay = const Duration(milliseconds: 400),
  }) : connector = connector ?? IoRelayConnector() {
    _netSub = this.connector.networkChanges.listen(_onNetworkChanged);
  }

  Uri? _serverUri;
  final RelayConnector connector;

  /// Fixed relay room (friend links) instead of the channel's room.
  final String? room;
  final Duration minBackoff;

  /// Longest wait between retries. [MultiRelayTransport] raises it for the
  /// home relay while the backup relay carries the traffic (v1.8.8).
  Duration maxBackoff;

  /// Long on purpose: a sleeping free-tier server needs ~50 s to start.
  /// The always-on home relay uses a short one (v1.8.8).
  Duration connectTimeout;
  final Duration pingInterval;

  /// v1.8.8: after a failed connect, try once more right away (after
  /// [quickRetryDelay]) before backing off. Some TLS handshakes through
  /// Tailscale Funnel fail on the first try and work on the second.
  bool quickRetry;
  final Duration quickRetryDelay;
  bool _quickUsed = false;
  Duration? _retryDelay;

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
  Duration? get retryIn => _retry == null ? null : (_retryDelay ?? _backoff);

  /// When the open socket connected (null while down).
  DateTime? get connectedAt => _ws == null ? null : _connectedAt;

  /// Successful connects so far.
  int get connects => _connects;

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
    _quickUsed = false;
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
      _quickUsed = false;
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
        if (quickRetry && !_quickUsed && _wanted) {
          // One fast second try (flaky first TLS handshake), no backoff.
          _quickUsed = true;
          _setStatus(TransportStatus.starting, 'Retrying ($e)');
          _retry?.cancel();
          _retryDelay = quickRetryDelay;
          _retry = Timer(quickRetryDelay, () {
            _retry = null;
            _retryDelay = null;
            if (_wanted && _ws == null) _connect();
          });
        } else {
          _setStatus(TransportStatus.error, 'Relay unreachable: $e');
          _scheduleRetry();
        }
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
    _quickUsed = false;
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
      _quickUsed = false;
      await _connect();
    }());
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retryDelay = null;
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
    _retryDelay = null;
    _attempt++; // abandon an in-flight connect
    _connecting = false;
    final sub = _sub;
    _sub = null;
    final ws = _ws;
    _ws = null;
    await sub?.cancel();
    await ws?.close();
  }

  /// Pull-to-refresh (v1.8.5): reconnect right away when disconnected.
  @override
  void kickDiscovery() => unawaited(reconnectNow());

  /// Retry now (e.g. the phone just came back online).
  Future<void> reconnectNow() async {
    if (!_wanted || _ws != null) return;
    _backoff = Duration.zero;
    _quickUsed = false;
    await _connect();
  }

  /// App came back on screen (v1.8.8): reconnect now when down, else ping
  /// right away so a socket that died in the background is noticed (and
  /// replaced) before the next push-to-talk instead of up to a minute later.
  Future<void> wake() async {
    if (!_wanted) return;
    if (_ws == null) {
      await reconnectNow();
      return;
    }
    _keepAlive();
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

/// Which relay a phone uses (v1.8.8), for the UI and the debug log.
enum RelayRole {
  /// The first relay in the list (the user's Synology through Tailscale
  /// Funnel by default): always on, no cold start.
  home,

  /// Any later relay (Render by default): may sleep and take ~50 s to wake.
  backup,
}

/// Several relays at once, as one internet [Transport].
///
/// The list is ordered: first = the home relay (preferred), then backups.
///
/// Failover design (v1.8.8), "both doors open, home preferred":
/// * Every relay is connected in parallel and every frame is sent to every
///   connected relay; receivers drop the duplicate copies by (sender, seq)
///   and play whichever copy arrives first. So two phones always hear each
///   other as long as they share at least ONE working relay. This is what
///   keeps a room together: the relays do not talk to each other, and a
///   pure "switch over" design would split a room whenever one phone could
///   reach home and another could not (flaky TLS, a network that blocks
///   *.ts.net, ...). With both open, the phone stuck on the backup still
///   meets everyone, because they are on the backup too.
/// * The home relay gets a short connect timeout ([homeConnectTimeout])
///   plus one immediate second try (a first TLS handshake sometimes fails),
///   so it is up within seconds; the backup keeps the long timeout for its
///   cold start.
/// * While home is down and a backup carries the traffic, home is retried
///   with backoff up to [homeRetryWhileOnBackup] (2.5 min), right away on
///   a network change, and when the app comes back on screen ([wake]).
///   Home comes back by itself; nothing has to "switch back".
/// * The status line and the "which relay" label follow home first.
class MultiRelayTransport extends Transport {
  MultiRelayTransport({
    List<Uri> serverUris = const [],
    RelayTransport Function(Uri uri)? factory,
    RelayConnector? connector,
    this.failover = true,
  }) : _factory =
           factory ??
           ((u) => RelayTransport(serverUri: u, connector: connector)) {
    _build(serverUris);
  }

  /// Short: the home relay is always on (no cold start).
  static const homeConnectTimeout = Duration(milliseconds: 4500);

  /// Home retry cap while a backup relay is connected.
  static const homeRetryWhileOnBackup = Duration(seconds: 150);

  /// Home retry cap while nothing is connected (same as one relay).
  static const homeRetryAlone = Duration(seconds: 30);

  /// Tune the first relay as the fast home relay when there are several.
  final bool failover;

  /// The role of the relay at [index] in a list of [count].
  static RelayRole roleAt(int index, int count) =>
      index == 0 && count > 0 ? RelayRole.home : RelayRole.backup;

  /// "Home relay" / "Backup relay". A single custom relay is just "Relay".
  static String labelFor(RelayRole role, {int count = 2}) => count <= 1
      ? 'Relay'
      : switch (role) {
          RelayRole.home => 'Home relay',
          RelayRole.backup => 'Backup relay',
        };

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
      if (failover && uris.length > 1 && _relays.isEmpty) {
        r.connectTimeout = homeConnectTimeout;
        r.quickRetry = true;
      }
      _relays.add(r);
      _subs.add(
        r.frames.listen((f) {
          if (!_framesCtl.isClosed) _framesCtl.add(f);
        }),
      );
      _subs.add(
        r.statusChanges.listen((_) {
          _tuneHomeRetry();
          final role = activeRole;
          if (role != _lastRole) {
            final was = _lastRole;
            _lastRole = role;
            onRoleChange?.call(was, role);
          }
          if (!_statusCtl.isClosed) _statusCtl.add(status);
        }),
      );
    }
  }

  /// Called when the relay in use changes (home -> backup, ...), with null
  /// for "none connected". For the debug log.
  void Function(RelayRole? from, RelayRole? to)? onRoleChange;
  RelayRole? _lastRole;

  /// Home retries slowly (2.5 min) only while a backup carries the traffic.
  void _tuneHomeRetry() {
    if (!failover || _relays.length < 2) return;
    final backupUp = _relays
        .skip(1)
        .any((r) => r.status == TransportStatus.running);
    final home = _relays.first;
    home.maxBackoff = backupUp ? homeRetryWhileOnBackup : homeRetryAlone;
    if (_backupWasUp &&
        !backupUp &&
        _wanted &&
        home.status != TransportStatus.running) {
      // The backup just dropped while home is waiting out a long retry:
      // try home now instead of up to 2.5 min later.
      unawaited(home.reconnectNow());
    }
    _backupWasUp = backupUp;
  }

  bool _backupWasUp = false;

  /// The relay this phone talks through: home when it is connected, else
  /// the first connected backup, else null.
  RelayTransport? get active {
    for (final r in _relays) {
      if (r.status == TransportStatus.running) return r;
    }
    return null;
  }

  RelayRole? get activeRole {
    final a = active;
    if (a == null) return null;
    return roleAt(_relays.indexOf(a), _relays.length);
  }

  /// "Home relay" / "Backup relay" / "Relay", null when none is connected.
  String? get activeLabel {
    final role = activeRole;
    return role == null ? null : labelFor(role, count: _relays.length);
  }

  /// The label of [r] in this list.
  String labelOf(RelayTransport r) => labelFor(
    roleAt(_relays.indexOf(r), _relays.length),
    count: _relays.length,
  );

  /// One line for the UI: "Internet: connected via mobile data (Home
  /// relay)", "Internet: connected via Wi-Fi (Backup relay; home relay
  /// unreachable)", "Internet: connecting...", "Internet: offline (...)".
  ({TransportStatus status, String text}) get summary {
    final rs = _relays;
    if (rs.isEmpty) {
      return (
        status: TransportStatus.unavailable,
        text: 'Internet: off (no relay set in Settings)',
      );
    }
    String host(RelayTransport r) => r.serverUri?.host ?? '';
    final r = active;
    if (r != null) {
      final via = r.network != null ? ' via ${r.network}' : '';
      var which = '';
      if (rs.length > 1) {
        final role = roleAt(rs.indexOf(r), rs.length);
        final home = rs.first;
        if (role == RelayRole.home) {
          final backups = rs
              .skip(1)
              .where((b) => b.status == TransportStatus.running)
              .length;
          which = ' (Home relay${backups > 0 ? ' + backup' : ''})';
        } else {
          final homeWhy = home.status == TransportStatus.starting
              ? 'home relay connecting'
              : 'home relay unreachable'
                    '${home.retryIn != null ? ', retry in ${_short(home.retryIn!)}' : ''}';
          which = ' (Backup relay; $homeWhy)';
        }
      }
      return (
        status: TransportStatus.running,
        text: 'Internet: connected$via$which',
      );
    }
    final starting = rs.where((r) => r.status == TransportStatus.starting);
    if (starting.isNotEmpty) {
      final s = starting.first;
      return (
        status: TransportStatus.starting,
        text:
            'Internet: connecting... (${rs.length > 1 ? '${labelOf(s)}: ' : ''}${s.statusDetail ?? host(s)})',
      );
    }
    final f = rs.first;
    final why = f.lastError ?? f.statusDetail ?? 'not connected';
    final retry = f.retryIn;
    return (
      status: TransportStatus.error,
      text:
          'Internet: offline ($why)${retry != null ? ', retrying in ${retry.inSeconds}s' : ''}',
    );
  }

  static String _short(Duration d) => d.inSeconds >= 90
      ? '${(d.inSeconds / 60).round()} min'
      : '${d.inSeconds}s';

  /// App back on screen: reconnect what is down (home first), ping the rest.
  Future<void> wake() async {
    if (!_wanted) return;
    await Future.wait(_relays.map((r) => r.wake()));
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
        '${_relays.length > 1 ? '${labelOf(r).split(' ').first.toLowerCase()} ' : ''}'
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

  @override
  void kickDiscovery() => unawaited(reconnectNow());

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
