import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/setup.dart';
import 'platform/platform_caps.dart';
import 'app/walkie_controller.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (PlatformCaps.desktop) _keepErrorLog();
  final controller = await WalkieController.load();
  runApp(WalkieApp(controller: controller));
  // Normally the home screen starts the controller. When Android starts the
  // app with no screen (after a reboot, or after it was killed while
  // "stay reachable" is on) nothing is drawn, so start it here.
  // First run: the setup wizard starts it (v1.8.7).
  Future.delayed(const Duration(seconds: 3), () {
    if (controller.setupEntry != SetupEntry.wizard) controller.start();
  });
}

class WalkieApp extends StatelessWidget {
  const WalkieApp({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.offlineUi,
      builder: (context, offline, home) => MaterialApp(
        title: 'Stalkie Talkie',
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

/// Desktop app (v1.9.6): uncaught errors also go to logs/errors.txt in the
/// app's data folder (%APPDATA%\Walkie Talkie\Walkie Talkie on Windows),
/// since a desktop release build has no console to show them.
void _keepErrorLog() {
  Future<void> write(String text) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/logs/errors.txt');
      await f.parent.create(recursive: true);
      if (await f.exists() && await f.length() > 512 * 1024) await f.delete();
      await f.writeAsString(
        '${DateTime.now().toIso8601String()} $text\n\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    previous?.call(d);
    write('${d.exceptionAsString()}\n${d.stack ?? ''}');
  };
  PlatformDispatcher.instance.onError = (e, s) {
    write('$e\n$s');
    return false;
  };
}
