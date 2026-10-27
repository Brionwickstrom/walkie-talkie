import 'dart:io';

import 'package:walkie_gateway/gateway/gateway_io.dart';

Future<void> main() async {
  final dir = Platform.environment['GATEWAY_DATA'] ?? '/data';
  final svc = GatewayService('$dir/gateway.json', '$dir/state.json');
  await svc.start();
}
