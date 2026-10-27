import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../gateway/stream_wire.dart';
import 'win_serial.dart';

/// Meshtastic radios over USB serial or Wi-Fi / TCP (port 4403) for the
/// desktop app (v1.9.6), with the same stream framing as the Synology
/// gateway ([StreamWire]). Saved as a radio id next to Bluetooth ids:
/// "serial:COM3" or "tcp:192.168.1.40:4403".
class StreamRadioId {
  StreamRadioId._();

  static const int defaultTcpPort = 4403;

  static bool isStream(String? id) =>
      id != null && (id.startsWith('serial:') || id.startsWith('tcp:'));

  static String serial(String port) => 'serial:$port';

  static String tcp(String host, [int port = defaultTcpPort]) =>
      'tcp:$host:$port';

  static String? serialPort(String id) =>
      id.startsWith('serial:') ? id.substring(7) : null;

  static ({String host, int port})? tcpTarget(String id) {
    if (!id.startsWith('tcp:')) return null;
    final rest = id.substring(4);
    final i = rest.lastIndexOf(':');
    if (i <= 0) return (host: rest, port: defaultTcpPort);
    final port = int.tryParse(rest.substring(i + 1));
    if (port == null) return (host: rest, port: defaultTcpPort);
    return (host: rest.substring(0, i), port: port);
  }

  /// "192.168.1.40", "radio.local:4403" or "meshtastic.local" typed by
  /// the user -> a tcp id, or null when it is not a host name / address.
  static String? fromTyped(String text) {
    var t = text.trim();
    if (t.startsWith('http://')) t = t.substring(7);
    if (t.startsWith('https://')) t = t.substring(8);
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    if (t.isEmpty || t.contains(' ') || t.contains('/')) return null;
    var host = t;
    var port = defaultTcpPort;
    final i = t.lastIndexOf(':');
    if (i > 0 && !t.contains('::')) {
      final p = int.tryParse(t.substring(i + 1));
      if (p == null || p <= 0 || p > 65535) return null;
      host = t.substring(0, i);
      port = p;
    }
    if (!RegExp(r'^[A-Za-z0-9.\-_]+$').hasMatch(host)) return null;
    return tcp(host, port);
  }

  /// "USB radio on COM3", "Wi-Fi radio 192.168.1.40".
  static String label(String id) {
    final s = serialPort(id);
    if (s != null) return 'USB radio on $s';
    final t = tcpTarget(id);
    if (t != null) {
      return 'Wi-Fi radio ${t.host}'
          '${t.port == defaultTcpPort ? '' : ':${t.port}'}';
    }
    return id;
  }
}

/// An open stream link: the wire for [MeshtasticSession] and its closer.
class StreamRadioConnection {
  StreamRadioConnection(this.wire, this._close);
  final StreamWire wire;
  final Future<void> Function() _close;
  Future<void> close() => _close();
}

/// Opens [id] ("serial:COM3" / "tcp:host:port"). Serial is Windows only.
Future<StreamRadioConnection> openStreamRadio(String id) async {
  final port = StreamRadioId.serialPort(id);
  if (port != null) {
    if (!Platform.isWindows) {
      throw UnsupportedError('USB radios need the Windows app');
    }
    final p = await WinSerialPort.open(port);
    final wire = StreamWire(p.input, p.write);
    // Switch a sleeping serial console to protobuf mode (official client).
    await p.write(StreamFramer.wake());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return StreamRadioConnection(wire, () async {
      await wire.close();
      await p.close();
    });
  }
  final t = StreamRadioId.tcpTarget(id);
  if (t == null) throw ArgumentError('not a USB / Wi-Fi radio: $id');
  final sock = await Socket.connect(
    t.host,
    t.port,
    timeout: const Duration(seconds: 10),
  );
  sock.setOption(SocketOption.tcpNoDelay, true);
  final wire = StreamWire(sock, (Uint8List b) async {
    sock.add(b);
    await sock.flush();
  });
  return StreamRadioConnection(wire, () async {
    await wire.close();
    sock.destroy();
  });
}

/// COM ports that may be a USB radio (Windows), as radio ids.
List<String> usbRadioIds() => Platform.isWindows
    ? [for (final p in WinSerialPort.ports()) StreamRadioId.serial(p)]
    : const [];
