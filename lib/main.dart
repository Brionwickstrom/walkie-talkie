import 'package:flutter/material.dart';

import 'app/walkie_controller.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await WalkieController.load();
  runApp(WalkieApp(controller: controller));
  // Normally the home screen starts the controller. When Android starts the
  // app with no screen (after a reboot, or after it was killed while
  // "stay reachable" is on) nothing is drawn, so start it here.
  Future.delayed(const Duration(seconds: 3), controller.start);
}

class WalkieApp extends StatelessWidget {
  const WalkieApp({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walkie Talkie',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: HomePage(controller: controller),
    );
  }
}
