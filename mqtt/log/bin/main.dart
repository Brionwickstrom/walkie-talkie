import 'dart:io';

import 'package:walkie_mqtt_log/mqtt/mqtt_logger.dart';

/// walkie-mqtt-log. Password comes from MQTT_PASS_FILE, never from argv.
Future<void> main() async {
  final port = int.tryParse(Platform.environment['MQTT_PORT'] ?? '') ?? 1883;
  final root = Platform.environment['MQTT_ROOT'] ?? 'msh/stalkie';
  await runMqttLogger(
    host: Platform.environment['MQTT_HOST'] ?? '127.0.0.1',
    port: port,
    root: root,
  );
}
