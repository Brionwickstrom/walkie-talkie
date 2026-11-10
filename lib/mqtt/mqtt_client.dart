// A small MQTT 3.1.1 client: one sign-in check for the phone, and a
// subscribe loop for the NAS logger. The phone call connects, reads the
// acknowledgement, and disconnects. It does not subscribe and it has no
// timer. Passwords are only placed in the connect packet.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Result of one broker check. [line] is a fixed sentence. [details] is
/// scrubbed and never includes the password (the password is not put on
/// any exception this code throws).
class BrokerProbe {
  const BrokerProbe.up() : ok = true, line = 'Broker reachable', details = null;

  const BrokerProbe.down(this.line, {this.details}) : ok = false;

  final bool ok;
  final String line;
  final String? details;
}

class MqttPublish {
  const MqttPublish(this.topic, this.body);
  final String topic;
  final Uint8List body;
}

class MqttIncoming {
  MqttIncoming._({this.connackCode, this.publish, this.tooBig = false});

  factory MqttIncoming.connack(int code) => MqttIncoming._(connackCode: code);

  factory MqttIncoming.publish(String topic, Uint8List body) =>
      MqttIncoming._(publish: MqttPublish(topic, body));

  factory MqttIncoming.other() => MqttIncoming._();

  factory MqttIncoming.tooBig() => MqttIncoming._(tooBig: true);

  final int? connackCode;
  final MqttPublish? publish;
  final bool tooBig;

  bool get isConnack => connackCode != null;
}

/// Bytes of an MQTT connect with a username and password. Clean session.
Uint8List mqttConnectPacket({
  required String clientId,
  required String username,
  required String password,
  int keepAlive = 15,
}) {
  final body = BytesBuilder(copy: false);
  _utf8(body, 'MQTT');
  body.addByte(4);
  body.addByte(0xC2); // username, password, clean session
  body
    ..addByte((keepAlive >> 8) & 0xFF)
    ..addByte(keepAlive & 0xFF);
  _utf8(body, clientId);
  _utf8(body, username);
  _utf8(body, password);
  return _packet(0x10, body.toBytes());
}

Uint8List mqttSubscribePacket(String topic, {int packetId = 1}) {
  final body = BytesBuilder(copy: false)
    ..addByte((packetId >> 8) & 0xFF)
    ..addByte(packetId & 0xFF);
  _utf8(body, topic);
  body.addByte(0);
  return _packet(0x82, body.toBytes());
}

Uint8List mqttPublishPacket(String topic, List<int> payload) {
  final body = BytesBuilder(copy: false);
  _utf8(body, topic);
  body.add(payload);
  return _packet(0x30, body.toBytes());
}

Uint8List mqttDisconnectPacket() => Uint8List.fromList(const [0xE0, 0x00]);

Uint8List mqttPingPacket() => Uint8List.fromList(const [0xC0, 0x00]);

Uint8List _packet(int header, Uint8List body) {
  final out = BytesBuilder(copy: false)..addByte(header);
  _remaining(out, body.length);
  out.add(body);
  return out.toBytes();
}

void _remaining(BytesBuilder out, int len) {
  var x = len;
  do {
    var digit = x % 128;
    x ~/= 128;
    if (x > 0) digit |= 0x80;
    out.addByte(digit);
  } while (x > 0);
}

void _utf8(BytesBuilder out, String s) {
  final b = utf8.encode(s);
  out
    ..addByte((b.length >> 8) & 0xFF)
    ..addByte(b.length & 0xFF)
    ..add(b);
}

/// Incremental MQTT parser. Payloads larger than 8 KB are refused and the
/// bytes are dropped, not returned.
class MqttParser {
  final List<int> _buf = [];
  final List<MqttIncoming> pending = [];

  void add(List<int> chunk) {
    _buf.addAll(chunk);
    while (_buf.isNotEmpty) {
      final header = _buf[0];
      var i = 1;
      var mult = 1;
      var len = 0;
      var got = false;
      for (var k = 0; k < 4 && i < _buf.length; k++) {
        final digit = _buf[i++];
        len += (digit & 0x7F) * mult;
        mult *= 128;
        if (digit & 0x80 == 0) {
          got = true;
          break;
        }
      }
      if (!got) return;
      if (len < 0 || len > 8192) {
        pending.add(MqttIncoming.tooBig());
        _buf.clear();
        return;
      }
      if (_buf.length < i + len) return;
      final body = Uint8List.fromList(_buf.sublist(i, i + len));
      _buf.removeRange(0, i + len);
      pending.add(_one(header, body));
    }
  }

  MqttIncoming _one(int header, Uint8List body) {
    final type = header >> 4;
    if (type == 2 && body.length >= 2) {
      return MqttIncoming.connack(body[1]);
    }
    if (type == 3) return _publish(header & 0x0F, body);
    return MqttIncoming.other();
  }

  MqttIncoming _publish(int flags, Uint8List body) {
    if (body.length < 2) return MqttIncoming.other();
    final tlen = (body[0] << 8) | body[1];
    var i = 2 + tlen;
    if (tlen < 0 || i > body.length) return MqttIncoming.other();
    final topic = utf8.decode(body.sublist(2, 2 + tlen), allowMalformed: true);
    final qos = (flags >> 1) & 0x3;
    if (qos > 0) {
      if (i + 2 > body.length) return MqttIncoming.other();
      i += 2;
    }
    return MqttIncoming.publish(topic, Uint8List.sublistView(body, i));
  }
}

abstract class MqttPipe {
  void add(List<int> bytes);
  Stream<List<int>> get incoming;
  Future<void> close();
}

typedef MqttOpener = Future<MqttPipe> Function({
  required String host,
  required int port,
  required bool tls,
  required Duration timeout,
});

class SocketMqttPipe implements MqttPipe {
  SocketMqttPipe(this._socket);
  final Socket _socket;

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  Stream<List<int>> get incoming => _socket;

  @override
  Future<void> close() => _socket.close();
}

Future<MqttPipe> openMqttSocket({
  required String host,
  required int port,
  required bool tls,
  required Duration timeout,
}) async {
  final Socket socket;
  if (tls) {
    socket = await SecureSocket.connect(host, port, timeout: timeout);
  } else {
    socket = await Socket.connect(host, port, timeout: timeout);
  }
  return SocketMqttPipe(socket);
}

/// Connect, read the acknowledgement, disconnect. No subscribe and no timer.
Future<BrokerProbe> probeMqtt({
  required String host,
  required int port,
  required bool tls,
  required String username,
  required String password,
  MqttOpener? open,
  Duration timeout = const Duration(seconds: 4),
  String clientId = 'stalkie-check',
}) async {
  final opener = open ?? openMqttSocket;
  MqttPipe? pipe;
  StreamSubscription<List<int>>? sub;
  try {
    pipe = await opener(host: host, port: port, tls: tls, timeout: timeout);
    final parser = MqttParser();
    final ack = Completer<int>();
    sub = pipe.incoming.listen((chunk) {
      parser.add(chunk);
      for (final m in parser.pending) {
        final code = m.connackCode;
        if (code != null && !ack.isCompleted) ack.complete(code);
      }
      parser.pending.clear();
    });
    pipe.add(
      mqttConnectPacket(
        clientId: clientId,
        username: username,
        password: password,
      ),
    );
    final code = await ack.future.timeout(timeout);
    try {
      pipe.add(mqttDisconnectPacket());
    } catch (_) {}
    return _fromCode(code);
  } on TimeoutException {
    return const BrokerProbe.down('The broker did not answer.');
  } on SocketException catch (e) {
    return BrokerProbe.down(
      'Could not reach the broker. Check the address, and that the NAS broker is running.',
      details: scrubMqttError(e.message),
    );
  } on HandshakeException catch (e) {
    return BrokerProbe.down(
      'The broker certificate was not accepted.',
      details: scrubMqttError(e.message),
    );
  } on TlsException catch (e) {
    return BrokerProbe.down(
      'The broker certificate was not accepted.',
      details: scrubMqttError(e.message),
    );
  } catch (e) {
    return BrokerProbe.down(
      'Could not reach the broker.',
      details: scrubMqttError('$e'),
    );
  } finally {
    await sub?.cancel();
    try {
      await pipe?.close();
    } catch (_) {}
  }
}

/// Drop passwords, links and long tokens from a socket error. The MQTT
/// password is never put on the exception; this is a second pass.
String scrubMqttError(String raw) {
  var s = raw;
  s = s.replaceAllMapped(
    RegExp(r'mqtts?://[^:\s/@]+:[^@\s]+@', caseSensitive: false),
    (_) => 'mqtt://[redacted]@',
  );
  s = s.replaceAllMapped(
    RegExp(r'(password|mqtt[_\s-]?pass)(\s*[:=]\s*)\S+', caseSensitive: false),
    (m) => '${m[1]}${m[2]}[redacted]',
  );
  s = s.replaceAll(RegExp(r'[A-Za-z0-9_\-+/=]{24,}'), '[removed]');
  if (s.length > 300) s = '${s.substring(0, 300)}…';
  return s.trim();
}

BrokerProbe _fromCode(int code) => switch (code) {
  0 => const BrokerProbe.up(),
  4 ||
  5 => const BrokerProbe.down('The broker refused the username or password.'),
  _ => const BrokerProbe.down('The broker refused the connection.'),
};

/// Subscribe to [root]/# until [pipe] closes. Publishes are handed to
/// [onPublish]. A bad sign-in throws [MqttSignInException] with no password
/// in the message. Ping is the caller's job; this function does not start
/// a timer.
Future<void> mqttSubscribe(
  MqttPipe pipe, {
  required String username,
  required String password,
  required String root,
  required void Function(MqttPublish publish) onPublish,
  String clientId = 'stalkie-log',
  Duration ackTimeout = const Duration(seconds: 10),
}) async {
  final parser = MqttParser();
  final ack = Completer<int>();
  final done = Completer<void>();
  final sub = pipe.incoming.listen(
    (chunk) {
      parser.add(chunk);
      final batch = List<MqttIncoming>.of(parser.pending);
      parser.pending.clear();
      for (final m in batch) {
        if (m.tooBig) continue;
        final code = m.connackCode;
        if (code != null && !ack.isCompleted) {
          ack.complete(code);
          continue;
        }
        final pub = m.publish;
        if (pub != null) onPublish(pub);
      }
    },
    onError: (Object e, StackTrace st) {
      if (!done.isCompleted) done.completeError(e, st);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  try {
    pipe.add(
      mqttConnectPacket(
        clientId: clientId,
        username: username,
        password: password,
        keepAlive: 60,
      ),
    );
    final code = await ack.future.timeout(ackTimeout);
    if (code != 0) {
      throw MqttSignInException(code);
    }
    final topic = root.endsWith('/#') ? root : '$root/#';
    pipe.add(mqttSubscribePacket(topic));
    await done.future;
  } finally {
    await sub.cancel();
  }
}

class MqttSignInException implements Exception {
  MqttSignInException(this.code);
  final int code;
  @override
  String toString() => code == 4 || code == 5
      ? 'The broker refused the username or password.'
      : 'The broker refused the connection.';
}
