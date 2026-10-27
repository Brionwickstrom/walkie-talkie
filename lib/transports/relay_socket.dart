import 'dart:async';
import 'dart:io' show NetworkInterface, Platform;

import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// One WebSocket to a relay, independent of how it is implemented.
abstract class RelaySocket {
  /// Binary frames ([Uint8List]) and text ("pong"). Closes when the socket
  /// closes; [closeReason] says why.
  Stream<Object> get messages;
  String? get closeReason;

  /// Which network carries it ("Wi-Fi", "mobile data", ...), when known.
  String? get network;
  void send(Uint8List data);
  void sendText(String text);
  Future<void> close();
}

class RelayConnectException implements Exception {
  RelayConnectException(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

abstract class RelayConnector {
  Future<RelaySocket> connect(Uri uri, {required Duration timeout});

  /// Fires (with a label) when the network the relay should use changed,
  /// so open sockets are replaced right away. Never fires off Android.
  Stream<String> get networkChanges;

  /// The platform default: native sockets on Android (they bypass the
  /// Wi-Fi-without-internet process binding), dart:io elsewhere.
  static RelayConnector platform() => Platform.isAndroid
      ? AndroidRelayConnector.instance
      : IoRelayConnector(
          watchNetwork:
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
              !Platform.environment.containsKey('FLUTTER_TEST'),
        );
}

/// Desktop (v1.9.8): no network callbacks, so the addresses of the PC's
/// network adapters are checked every [every]; a change (Wi-Fi joined or
/// lost, cable in / out, VPN up) fires like Android's network callback.
/// One shared poll for every relay socket, only while someone listens.
class DesktopNetWatch {
  DesktopNetWatch._();
  static final instance = DesktopNetWatch._();
  static const every = Duration(seconds: 3);

  late final _ctl = StreamController<String>.broadcast(
    onListen: _start,
    onCancel: _stop,
  );
  Timer? _timer;
  String? _last;

  Stream<String> get changes => _ctl.stream;

  void _start() {
    _timer ??= Timer.periodic(every, (_) => _check());
    unawaited(_check());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _last = null;
  }

  Future<void> _check() async {
    try {
      final list = await NetworkInterface.list();
      final sig = [
        for (final i in list)
          for (final a in i.addresses) '${i.name}=${a.address}',
      ]..sort();
      final now = sig.join(',');
      final was = _last;
      _last = now;
      if (was != null && was != now && !_ctl.isClosed) _ctl.add('network');
    } catch (_) {}
  }
}

/// dart:io WebSocket (tests, iOS, desktop).
class IoRelayConnector implements RelayConnector {
  IoRelayConnector({this.watchNetwork = false});

  /// Desktop: fire [networkChanges] from [DesktopNetWatch] (v1.9.8).
  final bool watchNetwork;

  @override
  Stream<String> get networkChanges =>
      watchNetwork ? DesktopNetWatch.instance.changes : const Stream.empty();

  @override
  Future<RelaySocket> connect(Uri uri, {required Duration timeout}) async {
    final ws = WebSocketChannel.connect(uri);
    try {
      await ws.ready.timeout(timeout);
    } on TimeoutException {
      unawaited(ws.sink.close().catchError((_) {}));
      throw RelayConnectException('timed out after ${timeout.inSeconds}s');
    } catch (e) {
      throw RelayConnectException(_short(e));
    }
    return _IoSocket(ws);
  }
}

String _short(Object e) {
  final s = e.toString();
  return s.length > 120 ? s.substring(0, 120) : s;
}

class _IoSocket implements RelaySocket {
  _IoSocket(this._ws) {
    _sub = _ws.stream.listen(
      (d) {
        if (d is String) {
          _ctl.add(d);
        } else if (d is List<int>) {
          _ctl.add(d is Uint8List ? d : Uint8List.fromList(d));
        }
      },
      onDone: () {
        closeReason ??= 'closed ${_ws.closeCode ?? ''}'.trim();
        _ctl.close();
      },
      onError: (Object e) {
        closeReason = _short(e);
        _ctl.close();
      },
      cancelOnError: true,
    );
  }
  final WebSocketChannel _ws;
  late final StreamSubscription<dynamic> _sub;
  final _ctl = StreamController<Object>();

  @override
  Stream<Object> get messages => _ctl.stream;
  @override
  String? closeReason;
  @override
  String? get network => null;
  @override
  void send(Uint8List data) => _ws.sink.add(data);
  @override
  void sendText(String text) => _ws.sink.add(text);
  @override
  Future<void> close() async {
    closeReason ??= 'closed by app';
    try {
      await _ws.sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    await _sub.cancel();
    if (!_ctl.isClosed) await _ctl.close();
  }
}

/// Android: OkHttp sockets in RelayBridge.kt, created on a network that has
/// internet even while the process is bound to an offline Wi-Fi.
class AndroidRelayConnector implements RelayConnector {
  AndroidRelayConnector._() {
    _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
  }
  static final instance = AndroidRelayConnector._();

  static const _ch = MethodChannel('walkie/relay');
  static const _events = EventChannel('walkie/relay/events');
  final Map<int, _NativeSocket> _sockets = {};
  final _net = StreamController<String>.broadcast();
  int _nextId = 1;

  @override
  Stream<String> get networkChanges => _net.stream;

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final t = e['t'];
    if (t == 'net') {
      _net.add('${e['net']}');
      return;
    }
    final s = _sockets[(e['id'] as num?)?.toInt() ?? 0];
    if (s == null) return;
    switch (t) {
      case 'open':
        s.network = e['net'] as String?;
        if (!s.opened.isCompleted) s.opened.complete();
      case 'bin':
        final d = e['data'];
        if (d is Uint8List) s.ctl.add(d);
      case 'text':
        s.ctl.add('${e['data']}');
      case 'closed':
      case 'fail':
        s.closeReason ??= '${e['reason'] ?? t}';
        if (!s.opened.isCompleted) {
          s.opened.completeError(RelayConnectException(s.closeReason!));
        }
        s.finish();
    }
  }

  @override
  Future<RelaySocket> connect(Uri uri, {required Duration timeout}) async {
    final id = _nextId++;
    final s = _NativeSocket(this, id);
    s.opened.future.ignore(); // errors are handled below / after timeout
    _sockets[id] = s;
    try {
      s.network = await _ch.invokeMethod<String>('open', {
        'id': id,
        'url': uri.toString(),
      });
      await s.opened.future.timeout(timeout);
      return s;
    } on TimeoutException {
      await s.close();
      throw RelayConnectException('timed out after ${timeout.inSeconds}s');
    } on RelayConnectException {
      _sockets.remove(id);
      rethrow;
    } catch (e) {
      await s.close();
      throw RelayConnectException(_short(e));
    }
  }
}

class _NativeSocket implements RelaySocket {
  _NativeSocket(this.owner, this.id);
  final AndroidRelayConnector owner;
  final int id;
  final opened = Completer<void>();
  final ctl = StreamController<Object>();

  @override
  String? network;
  @override
  String? closeReason;
  @override
  Stream<Object> get messages => ctl.stream;

  void finish() {
    owner._sockets.remove(id);
    if (!ctl.isClosed) ctl.close();
  }

  @override
  void send(Uint8List data) {
    AndroidRelayConnector._ch
        .invokeMethod<bool>('send', {'id': id, 'data': data})
        .catchError((_) => false);
  }

  @override
  void sendText(String text) {
    AndroidRelayConnector._ch
        .invokeMethod<bool>('text', {'id': id, 'text': text})
        .catchError((_) => false);
  }

  @override
  Future<void> close() async {
    closeReason ??= 'closed by app';
    try {
      await AndroidRelayConnector._ch.invokeMethod<void>('close', {'id': id});
    } catch (_) {}
    finish();
  }
}
