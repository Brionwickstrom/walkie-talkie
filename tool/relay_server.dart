// Run with: dart run tool/relay_server.dart [port]
import 'dart:io';

import 'package:walkie_talkie/relay/relay_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty
      ? int.parse(args.first)
      : int.parse(Platform.environment['PORT'] ?? '8080');
  final relay = await RelayServer.bind(port: port);
  stdout.writeln('Walkie-talkie relay listening on ws://0.0.0.0:${relay.port}/');
}
