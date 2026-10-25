import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/ui/home_view.dart';

const people = [
  PersonView(
    id: 0x5A11E,
    name: 'Rubber Duck',
    talking: true,
    links: [TransportKind.lan, TransportKind.internet],
    active: TransportKind.lan,
    lastHeard: Duration(milliseconds: 300),
    volume: 1.5,
  ),
  PersonView(
    id: 0xBEEF01,
    name: 'Maverick the Extraordinarily Long Call Sign',
    links: [TransportKind.ble],
    active: TransportKind.ble,
    lastHeard: Duration(seconds: 1),
    ringStatus: 'Ringing...',
  ),
  PersonView(
    id: 0xC0FFEE,
    name: 'Goose',
    links: [TransportKind.internet],
    active: TransportKind.internet,
    lastHeard: Duration(seconds: 3),
  ),
  PersonView(
    id: 0x7777,
    name: 'Iceman',
    links: [TransportKind.lan],
    active: TransportKind.lan,
    lastHeard: Duration(seconds: 2),
    elsewhere: 'On CH 4',
  ),
  PersonView(
    id: 0x4242,
    name: 'Bandit',
    left: true,
    lastHeard: Duration(seconds: 12),
  ),
];

Widget app({List<PersonView> peers = people, bool details = false}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('CH 1  🔓'),
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.voicemail)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.settings)),
          ],
        ),
        body: HomeBody(
          links: const [
            (TransportKind.lan, TransportStatus.running),
            (TransportKind.ble, TransportStatus.unavailable),
            (TransportKind.internet, TransportStatus.running),
          ],
          internet: (
            status: TransportStatus.running,
            text: 'Internet: connected via Wi-Fi',
          ),
          showDetails: details,
          onToggleDetails: (_) {},
          details: const ['WiFi: running · IP 192.168.68.54/22'],
          channelLabel: 'CH 1',
          me: const PersonView(id: 0x1234, name: 'Lord of the Pings', me: true),
          people: peers,
          onRing: (_) {},
          onBeep: (_) {},
          onMessage: (_) {},
          onVolume: (_) {},
          onEditMe: () {},
          actions: ChannelActions(
            onRingAll: () {},
            onBeepAll: () {},
            record: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () {},
              icon: const Icon(Icons.keyboard_voice),
              label: const Text('Hold: message'),
            ),
          ),
          ptt: PttButton(
            transmitting: false,
            busy: true,
            onChanged: (_) {},
            size: 132,
          ),
        ),
      ),
    );

Future<void> loadFonts() async {
  final dir =
      '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
  if (!Directory(dir).existsSync()) return;
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final bytes = File('$dir/$f').readAsBytesSync();
      l.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await l.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Italic.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

void main() {
  setUpAll(loadFonts);

  Future<void> pumpAt(
    WidgetTester tester,
    Widget w, {
    double scale = 1.3,
  }) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(w);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('360x780, 5 peers, 1.3x text: no overflow, count includes you', (
    tester,
  ) async {
    await pumpAt(tester, app());
    expect(tester.takeException(), isNull);
    // You + 3 on our channel (Iceman elsewhere, Bandit left).
    expect(find.text('4 on CH 1'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Lord of the Pings'), findsOneWidget);
    expect(find.text('Rubber Duck'), findsOneWidget);
    // Scroll to the end: every card lays out without overflow.
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Bandit'), findsOneWidget);
    expect(find.textContaining('Left 12s ago'), findsOneWidget);
  });

  testWidgets('details open + 2x text still lays out', (tester) async {
    await pumpAt(tester, app(details: true), scale: 2.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state', (tester) async {
    await pumpAt(tester, app(peers: const []));
    expect(tester.takeException(), isNull);
    expect(find.text('1 on CH 1'), findsOneWidget);
    expect(find.textContaining('Nobody on CH 1 yet'), findsOneWidget);
  });

  testWidgets('preview PNG (PREVIEW_PNG=path)', (tester) async {
    final out = Platform.environment['PREVIEW_PNG'];
    if (out == null) return;
    await pumpAt(tester, RepaintBoundary(child: app()), scale: 1.0);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
