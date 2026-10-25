import 'package:flutter/material.dart';

import 'app/walkie_controller.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(WalkieApp(controller: await WalkieController.load()));
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
