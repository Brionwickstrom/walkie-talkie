import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One HTTP request for map search (GET or form POST).
class FetchRequest {
  const FetchRequest(
    this.uri, {
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 20),
    this.maxBytes = 8 * 1024 * 1024,
  });
  final Uri uri;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final Duration timeout;

  /// Responses bigger than this are refused (keeps a huge area from
  /// filling the phone).
  final int maxBytes;
}

/// Sends a request and returns the body. Throws [NoSignalException] when
/// the network is unreachable and [FetchException] for other failures.
typedef Fetch = Future<String> Function(FetchRequest r);

/// No internet right now (or the app is not allowed to use it).
class NoSignalException implements Exception {
  NoSignalException([this.message = noSignalMessage]);
  final String message;
  @override
  String toString() => message;
}

class FetchException implements Exception {
  FetchException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

const String noSignalMessage = 'Search needs signal; offline search below.';

/// [Fetch] over dart:io with a custom User-Agent.
Fetch ioFetch(String userAgent) {
  HttpClient? client;
  return (r) async {
    final c = client ??= (HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..maxConnectionsPerHost = 2
      ..userAgent = userAgent);
    try {
      final req = await c.openUrl(r.method, r.uri).timeout(r.timeout);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      r.headers.forEach(req.headers.set);
      if (r.body != null) {
        final b = utf8.encode(r.body!);
        req.contentLength = b.length;
        req.add(b);
      }
      final res = await req.close().timeout(r.timeout);
      if (res.statusCode == 429) {
        await res.drain<void>();
        throw FetchException(
          'The map search server is busy. Try again in a minute.',
          status: 429,
        );
      }
      if (res.statusCode == 502 ||
          res.statusCode == 503 ||
          res.statusCode == 504) {
        await res.drain<void>();
        throw FetchException(
          'The map search server timed out. Try a smaller area or try again '
          'later.',
          status: res.statusCode,
        );
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw FetchException(
          'Map search failed (HTTP ${res.statusCode}).',
          status: res.statusCode,
        );
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(r.timeout)) {
        out.add(chunk);
        if (out.length > r.maxBytes) {
          throw FetchException(
            'Too much map data for one download. Zoom in to a smaller area.',
          );
        }
      }
      return utf8.decode(out.takeBytes(), allowMalformed: true);
    } on SocketException {
      throw NoSignalException();
    } on HandshakeException {
      throw NoSignalException();
    } on TimeoutException {
      throw NoSignalException(
        'No answer from the map server (weak signal?). Offline search below.',
      );
    } on HttpException catch (e) {
      throw FetchException('Map search failed: ${e.message}');
    }
  };
}
