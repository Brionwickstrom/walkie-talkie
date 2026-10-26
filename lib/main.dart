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
    return ValueListenableBuilder<bool>(
      valueListenable: controller.offlineUi,
      builder: (context, offline, home) => MaterialApp(
        title: 'Walkie Talkie',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        // Offline power save: dark (OLED pixels off) and dimmed.
        themeMode: offline ? ThemeMode.dark : ThemeMode.system,
        builder: (context, child) => OfflineDim(on: offline, child: child!),
        home: home,
      ),
      child: HomePage(controller: controller),
    );
  }
}

/// Dims the whole app (offline power save). Touches pass through.
class OfflineDim extends StatelessWidget {
  const OfflineDim({super.key, required this.on, required this.child});
  final bool on;
  final Widget child;

  /// How much darker the app gets.
  static const dim = 0.35;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      child,
      if (on)
        const Positioned.fill(
          child: IgnorePointer(
            key: Key('offlineDim'),
            child: ColoredBox(color: Color.fromRGBO(0, 0, 0, dim)),
          ),
        ),
    ],
  );
}
