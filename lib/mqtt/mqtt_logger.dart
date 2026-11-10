// NAS logger: subscribe to the private broker and append the node log and
// range lines (v2.6.15). Run by the walkie-mqtt-log container, not by the
// phone. Reconnects after a drop. The password is read from a file and is
// only placed in the MQTT connect packet.
import 'dart:async';
import 'dart:io';

import '../app/debug_log.dart' show redactLog;
import 'mesh_log.dart';
import 'mqtt_client.dart';

/// One line on stdout. [redactLog] is a second pass; [meshLogLine] already
/// has no payload.
void mqttLoggerLine(String line) {
  stdout.writeln(redactLog(line));
}

/// Reads a secret file and trims the trailing newline. Does not print it.
String? readSecretFile(String? path) {
  if (path == null || path.isEmpty) return null;
  final f = File(path);
  if (!f.existsSync()) return null;
  final t = f.readAsStringSync().trim();
  return t.isEmpty ? null : t;
}

/// Subscribe until the pipe closes, writing whatever publishes arrive.
/// Returns when the connection ends. Throws [MqttSignInException] when the
/// broker refuses the sign-in.
Future<void> consumeBroker(
  MqttPipe pipe, {
  required String username,
  required String password,
  required String root,
  required MqttLogFiles files,
  DateTime Function()? clock,
}) async {
  final now = clock ?? DateTime.now;
  files.markConnected(true);
  await mqttSubscribe(
    pipe,
    username: username,
    password: password,
    root: root,
    onPublish: (pub) {
      final take = meshRecordFromPublish(
        pub.body,
        topic: pub.topic,
        root: root,
        at: now(),
      );
      final rec = take.record;
      files.addTake(take);
      if (rec != null) mqttLoggerLine(meshLogLine(rec));
    },
  );
}

/// The container's main loop. [once] runs a single connection (tests).
/// The phone never calls this.
Future<void> runMqttLogger({
  String host = '127.0.0.1',
  int port = 1883,
  String? username,
  String? password,
  String root = 'msh/stalkie',
  Directory? logDir,
  MqttOpener? open,
  bool once = false,
  Duration retry = const Duration(seconds: 5),
  DateTime Function()? clock,
}) async {
  final dir = logDir ?? Directory(_env('LOG_DIR') ?? '/data');
  final user = username ?? readSecretFile(_env('MQTT_USER_FILE')) ?? 'logger';
  final pass = password ?? readSecretFile(_env('MQTT_PASS_FILE')) ?? '';
  final files = MqttLogFiles(dir);
  final opener = open ?? openMqttSocket;
  if (pass.isEmpty) {
    mqttLoggerLine('broker password file is missing');
    files.markConnected(false);
    return;
  }
  while (true) {
    MqttPipe? pipe;
    try {
      pipe = await opener(
        host: host,
        port: port,
        tls: false,
        timeout: const Duration(seconds: 10),
      );
      await consumeBroker(
        pipe,
        username: user,
        password: pass,
        root: root,
        files: files,
        clock: clock,
      );
      files.markConnected(false);
    } on MqttSignInException catch (e) {
      files.markConnected(false);
      mqttLoggerLine(e.toString());
    } catch (e) {
      files.markConnected(false);
      mqttLoggerLine('broker not reachable');
    } finally {
      try {
        await pipe?.close();
      } catch (_) {}
    }
    if (once) return;
    await Future<void>.delayed(retry);
  }
}

String? _env(String k) {
  final v = Platform.environment[k];
  if (v == null || v.isEmpty) return null;
  return v;
}
