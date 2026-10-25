// Run with: dart run bin/server.dart [port]   (or set $PORT)
import 'dart:io';

import 'package:walkie_relay/relay_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty
      ? int.parse(args.first)
      : int.parse(Platform.environment['PORT'] ?? '8080');
  final relay = await RelayServer.bind(port: port);
  stdout.writeln(
    'Walkie-talkie relay on :${relay.port}  (ws path /ws, health /healthz)',
  );
}
