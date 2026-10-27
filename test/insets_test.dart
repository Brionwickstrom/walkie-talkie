// Android 15+ draws apps edge to edge: status bar (top 24) and gesture /
// 3-button navigation bar (bottom 48) sit on top of the app. Nothing that
// matters may be under them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/sheets.dart';

import 'home_layout_test.dart' show app, chatApp, loadFonts;

const top = 24.0, bottom = 48.0, w = 360.0, h = 780.0;

Future<void> pumpEdgeToEdge(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(w, h) * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: top * 3, bottom: bottom * 3);
  tester.view.viewPadding = const FakeViewPadding(
    top: top * 3,
    bottom: bottom * 3,
  );
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pump(const Duration(milliseconds: 300));
}

void expectClear(WidgetTester tester, Finder f) {
  final r = tester.getRect(f);
  expect(r.top, greaterThanOrEqualTo(top), reason: '$f under status bar');
  expect(r.bottom, lessThanOrEqualTo(h - bottom), reason: '$f under nav bar');
}

void main() {
  setUpAll(loadFonts);

  testWidgets('talk button sits above the navigation bar', (tester) async {
    await pumpEdgeToEdge(tester, app());
    expect(tester.takeException(), isNull);
    // The whole round button (busy preview shows RECEIVING).
    expectClear(tester, find.byType(PttButton));
  });

  testWidgets('chat input sits above the navigation bar', (tester) async {
    await pumpEdgeToEdge(tester, chatApp());
    expect(tester.takeException(), isNull);
    expectClear(tester, find.byType(TextField));
  });

  testWidgets('Settings-style sheet: first and last item fully visible', (
    tester,
  ) async {
    // Same sheet setup as Settings (showAppSheet, scroll-controlled, long).
    await pumpEdgeToEdge(
      tester,
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAppSheet<void>(
                  context: context,
                  scrollable: false,
                  builder: (ctx) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Your call sign'),
                          for (var i = 0; i < 40; i++)
                            SwitchListTile(
                              title: Text('Setting $i'),
                              value: false,
                              onChanged: (_) {},
                            ),
                          Row(
                            children: [
                              const Expanded(
                                child: Text('Version 1.5.2 (2012)'),
                              ),
                              OutlinedButton(
                                onPressed: () {},
                                child: const Text('Check for updates'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expectClear(tester, find.text('Your call sign'));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -5000),
    );
    await tester.pumpAndSettle();
    expectClear(tester, find.text('Version 1.5.2 (2012)'));
    expectClear(tester, find.text('Check for updates'));
  });
}
