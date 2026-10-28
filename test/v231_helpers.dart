// Shared helpers for the v2.3.1 widget tests (a real HomePage on a phone).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/ui/home_page.dart';

void quietPlugins() {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final ch in [
    'com.llfbandit.record/messages',
    'com.llfbandit.record/events',
    'com.llfbandit.record/eventsRecord',
  ]) {
    m.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
  }
}

Future<WalkieController> makeController(WidgetTester t, {String? group}) async {
  quietPlugins();
  SharedPreferences.setMockInitialValues({});
  final c = (await t.runAsync(() async {
    final c = await WalkieController.load(
      store: MemorySettingsStore(AppSettings(nodeId: 0x1234, channel: 1)),
    );
    if (group != null) {
      await c.createGroup(passcode: 'correct-horse-staple', name: group);
    }
    return c;
  }))!;
  addTearDown(c.dispose);
  return c;
}

Widget homeApp(WalkieController c) => MaterialApp(
  theme: ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Roboto',
  ),
  home: HomePage(controller: c),
);

void phone(WidgetTester t, {double w = 360, double h = 640, double ts = 1.3}) {
  t.view.physicalSize = Size(w, h) * 3;
  t.view.devicePixelRatio = 3;
  t.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
  t.view.viewPadding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
  t.platformDispatcher.textScaleFactorTestValue = ts;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
}

/// Routes and sheets finish animating (the Talk screen never "settles":
/// the talk button and the clock keep animating).
Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

/// Tear the screen down and let HomePage's start-up timers run out.
Future<void> finish(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 6));
}
