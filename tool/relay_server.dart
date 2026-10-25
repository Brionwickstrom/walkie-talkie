// Run with: dart run tool/relay_server.dart [port]
// (Same server as relay/bin/server.dart, which is what Docker / Render run.)
import 'dart:io';

import 'package:walkie_relay/relay_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty
      ? int.parse(args.first)
      : int.parse(Platform.environment['PORT'] ?? '8080');
  final relay = await RelayServer.bind(port: port);
  stdout.writeln('Walkie-talkie relay on :${relay.port} (ws /ws, health /healthz)');
}
