/// Active probes for the connection test (v1.8.7).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../transports/relay_socket.dart';
import '../transports/relay_transport.dart';
import 'connection_test.dart';

/// HTTPS GET of a "204" page; ok on any HTTP answer.
Future<NetProbe> probeInternet({
  Uri? url,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final u =
      url ?? Uri.parse('https://connectivitycheck.gstatic.com/generate_204');
  final sw = Stopwatch()..start();
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(u).timeout(timeout);
    final res = await req.close().timeout(timeout);
    await res.drain<void>().timeout(timeout);
    return NetProbe(ok: true, ms: sw.elapsedMilliseconds);
  } on TimeoutException {
    return NetProbe(ok: false, error: 'timed out after ${timeout.inSeconds}s');
  } on SocketException catch (e) {
    final m = e.osError?.message ?? e.message;
    return NetProbe(ok: false, error: m.isEmpty ? 'no connection' : m);
  } catch (e) {
    final s = '$e';
    return NetProbe(ok: false, error: s.length > 80 ? s.substring(0, 80) : s);
  } finally {
    client.close(force: true);
  }
}

/// Opens a separate connection to the relay room [channelScope] (the same
/// path the app uses: [connector]), sends a text "ping" and times the
/// "pong". Nothing is sent to the people in the room (the relay answers
/// "ping" itself and only forwards binary frames).
Future<RelayProbe> probeRelay({
  required Uri server,
  required int channelScope,
  required RelayConnector connector,
  Duration connectTimeout = const Duration(seconds: 45),
  Duration pongTimeout = const Duration(seconds: 8),
}) async {
  final room = RelayTransport.roomFor(channelScope);
  // A throwaway id, so the probe never looks like this phone.
  final id = Random().nextInt(0x7FFFFFFF) | 0x10000000;
  final uri = RelayTransport.channelUri(server, channelScope, id);
  final sw = Stopwatch()..start();
  RelaySocket? sock;
  try {
    sock = await connector.connect(uri, timeout: connectTimeout);
  } on RelayConnectException catch (e) {
    return RelayProbe(
      ok: false,
      room: room,
      host: server.host,
      error: e.reason,
    );
  } catch (e) {
    return RelayProbe(ok: false, room: room, host: server.host, error: '$e');
  }
  final connectMs = sw.elapsedMilliseconds;
  try {
    final pong = Completer<int>();
    final ping = Stopwatch();
    final sub = sock.messages.listen(
      (m) {
        if (m is String && m.trim() == 'pong' && !pong.isCompleted) {
          pong.complete(ping.elapsedMilliseconds);
        }
      },
      onDone: () {
        if (!pong.isCompleted) pong.completeError('closed by the relay');
      },
      onError: (Object e) {
        if (!pong.isCompleted) pong.completeError('$e');
      },
    );
    ping.start();
    sock.sendText('ping');
    try {
      final rtt = await pong.future.timeout(pongTimeout);
      return RelayProbe(
        ok: true,
        connectMs: connectMs,
        rttMs: rtt,
        room: room,
        host: server.host,
      );
    } on TimeoutException {
      return RelayProbe(
        ok: false,
        connectMs: connectMs,
        room: room,
        host: server.host,
        error: 'connected but no answer to ping in ${pongTimeout.inSeconds}s',
      );
    } catch (e) {
      return RelayProbe(
        ok: false,
        connectMs: connectMs,
        room: room,
        host: server.host,
        error: '$e',
      );
    } finally {
      await sub.cancel();
    }
  } finally {
    unawaited(sock.close().catchError((_) {}));
  }
}
