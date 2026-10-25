import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/frame.dart';
import '../core/transport.dart';

/// Internet transport: a WebSocket to a tiny relay server that fans each
/// binary frame out to every other phone joined to the same channel.
///
/// Works across any networks/NATs (mobile data on one phone, Wi-Fi on the
/// other) because both sides make outbound connections. The server is in
/// `lib/relay/relay_server.dart` (`dart run tool/relay_server.dart`).
///
/// A relay was chosen over WebRTC for v1: it needs no STUN/TURN, has one
/// moving part, and push-to-talk audio is ~2-3 KB/s per talker. WebRTC
/// (flutter_webrtc) peer-to-peer data channels are a drop-in replacement
/// behind this same [Transport] interface later; the relay would then just
/// carry signaling.
class RelayTransport extends Transport {
  RelayTransport({
    this._serverUri,
    this.reconnectDelay = const Duration(seconds: 3),
  });

  Uri? _serverUri;
  final Duration reconnectDelay;

  int _localNodeId = 0;
  int _channel = 1;
  bool _wanted = false;
  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
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

  /// Point at a different relay (from settings). Empty/null disables.
  Future<void> setServerUri(Uri? uri) async {
    _serverUri = uri;
    if (_wanted) {
      await _disconnect();
      await _connect();
    }
  }

  void _setStatus(TransportStatus s, [String? detail]) {
    _status = s;
    _detail = detail;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  static Uri channelUri(Uri base, int channel, int nodeId) => base.replace(
    queryParameters: {
      ...base.queryParameters,
      'ch': '$channel',
      'id': nodeId.toRadixString(16),
    },
  );

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    _localNodeId = localNodeId;
    _channel = channel;
    _wanted = true;
    await _connect();
  }

  Future<void> _connect() async {
    final base = _serverUri;
    if (base == null) {
      _setStatus(TransportStatus.unavailable, 'No relay server configured');
      return;
    }
    _setStatus(TransportStatus.starting);
    try {
      final ws = WebSocketChannel.connect(
        channelUri(base, _channel, _localNodeId),
      );
      await ws.ready.timeout(const Duration(seconds: 8));
      _ws = ws;
      _sub = ws.stream.listen(
        (data) {
          if (data is List<int>) {
            final f = Frame.tryDecode(data);
            if (f != null && !_framesCtl.isClosed) {
              _framesCtl.add(InboundFrame(f, TransportKind.internet));
            }
          }
        },
        onDone: _onLost,
        onError: (_) => _onLost(),
        cancelOnError: true,
      );
      _setStatus(TransportStatus.running);
    } catch (e) {
      _setStatus(TransportStatus.error, 'Relay unreachable');
      _scheduleRetry();
    }
  }

  void _onLost() {
    _ws = null;
    _sub = null;
    if (_wanted) {
      _setStatus(TransportStatus.error, 'Relay connection lost');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retry?.cancel();
    if (!_wanted) return;
    _retry = Timer(reconnectDelay, () {
      if (_wanted && _ws == null) _connect();
    });
  }

  Future<void> _disconnect() async {
    _retry?.cancel();
    final sub = _sub;
    _sub = null;
    final ws = _ws;
    _ws = null;
    await sub?.cancel();
    await ws?.sink.close();
  }

  @override
  Future<void> setChannel(int channel) async {
    if (channel == _channel) return;
    _channel = channel;
    if (_wanted) {
      await _disconnect();
      await _connect();
    }
  }

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    // The relay fans out to the whole channel; per-peer targeting is not
    // needed for push-to-talk.
    _ws?.sink.add(frame);
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
    await _statusCtl.close();
    await _framesCtl.close();
  }
}
