// Trip tab previews (v1.8.1): TRIP_PNG=path / TRIP_FULL_PNG=path render the
// tab and the full-screen map. Without them this only checks layout.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/ui/trip_widgets.dart';

import 'home_layout_test.dart' show loadFonts;

/// Stand-in for the topo map (no tiles in tests).
class _FakeTopo extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFFE8EFD8));
    final contour = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFB9A27A);
    for (var k = 0; k < 14; k++) {
      final path = Path();
      for (var x = 0.0; x <= s.width; x += 6) {
        final y =
            k * s.height / 12 +
            18 * math.sin(x / 47 + k * 0.7) +
            9 * math.cos(x / 23 + k);
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      c.drawPath(path, contour);
    }
    final water = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF7FB2E5);
    c.drawPath(
      Path()
        ..moveTo(0, s.height * 0.7)
        ..quadraticBezierTo(
          s.width * 0.4,
          s.height * 0.55,
          s.width,
          s.height * 0.8,
        ),
      water,
    );
    final trail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.red;
    c.drawPath(
      Path()
        ..moveTo(s.width * 0.15, s.height * 0.9)
        ..cubicTo(
          s.width * 0.3,
          s.height * 0.6,
          s.width * 0.35,
          s.height * 0.45,
          s.width * 0.5,
          s.height * 0.42,
        ),
      trail,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Widget _dot(String initials, Color color, String label) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    CircleAvatar(
      radius: 14,
      backgroundColor: color,
      child: Text(
        initials,
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    ),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Colors.black87,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  ],
);

Widget _map() => LayoutBuilder(
  builder: (context, box) => Stack(
    children: [
      Positioned.fill(child: CustomPaint(painter: _FakeTopo())),
      Positioned(
        left: box.maxWidth * 0.5 - 10,
        top: box.maxHeight * 0.42 - 10,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      ),
      Positioned(
        left: box.maxWidth * 0.22,
        top: box.maxHeight * 0.25,
        child: _dot('RD', Colors.deepOrange, 'Rubber Duck · 1 min'),
      ),
      Positioned(
        left: box.maxWidth * 0.58,
        top: box.maxHeight * 0.62,
        child: _dot('GO', Colors.indigo, 'Goose · 4 min'),
      ),
      Positioned(
        left: box.maxWidth * 0.35,
        top: box.maxHeight * 0.12,
        child: const Icon(Icons.cabin, color: Colors.brown, size: 28),
      ),
      const Positioned(
        right: 4,
        bottom: 4,
        child: Text(
          '© OpenStreetMap, OpenTopoMap',
          style: TextStyle(fontSize: 10, color: Colors.black54),
        ),
      ),
    ],
  ),
);

Widget _panel() => Builder(
  builder: (context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Share my location with the group'),
          subtitle: const Text('Check-in every 10 min (offline power save).'),
          value: true,
          onChanged: (_) {},
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.energy_savings_leaf, color: Colors.green),
          title: const Text('Offline power save'),
          subtitle: const Text(
            'On: internet relay, live location and map downloads off. '
            'Talk, relay, radio, SOS and quick messages still work.',
          ),
          value: true,
          onChanged: (_) {},
        ),
        Text('Quick messages', style: theme.textTheme.titleSmall),
        Wrap(
          spacing: 6,
          children: [
            for (final t in ['On my way', 'Stopping', 'Need help', 'At camp'])
              ActionChip(label: Text(t), onPressed: () {}),
          ],
        ),
        const Divider(),
        Text('People (3)', style: theme.textTheme.titleSmall),
        const ListTile(
          leading: CircleAvatar(backgroundColor: Colors.deepOrange),
          title: Text('Rubber Duck'),
          subtitle: Text('0.3 mi NW · via Bluetooth'),
        ),
        const ListTile(
          leading: CircleAvatar(backgroundColor: Colors.indigo),
          title: Text('Goose'),
          subtitle: Text('0.8 mi SE · via radio'),
        ),
      ],
    );
  },
);

Widget tripApp({required bool full, ValueChanged<bool>? onFull}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    colorSchemeSeed: Colors.teal,
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Roboto',
  ),
  home: Scaffold(
    appBar: full ? null : AppBar(title: const Text('CH 1')),
    bottomNavigationBar: full
        ? null
        : NavigationBar(
            height: 60,
            selectedIndex: 1,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.record_voice_over_outlined),
                label: 'Talk',
              ),
              NavigationDestination(icon: Icon(Icons.terrain), label: 'Trip'),
            ],
          ),
    body: SafeArea(
      child: TripLayout(
        full: full,
        onFull: onFull ?? (_) {},
        map: _map(),
        panel: _panel(),
        sos: SosSlideButton(onSend: () {}),
        controls: [
          for (final (i, t) in [
            (Icons.my_location, 'Following you'),
            (Icons.layers, 'Map style'),
            (Icons.download_for_offline, 'Offline maps'),
            (Icons.add_location_alt, 'Drop a pin here'),
          ])
            RoundMapButton(icon: i, tip: t, onTap: () {}),
        ],
        fullControls: [
          RoundMapButton(icon: Icons.add, tip: 'Zoom in', onTap: () {}),
          RoundMapButton(icon: Icons.remove, tip: 'Zoom out', onTap: () {}),
        ],
        topLeft: [OfflineSaverChip(on: true, onTap: () {})],
      ),
    ),
  ),
);

void main() {
  setUpAll(loadFonts);

  Future<void> pumpPhone(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    // Status bar and gesture bar: controls must stay clear of them.
    tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 16 * 3);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(child: w));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> snap(WidgetTester tester, String out) async {
    final b = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final img = await b.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  testWidgets('trip tab + full screen lay out with system insets', (
    tester,
  ) async {
    await pumpPhone(tester, tripApp(full: false));
    expect(tester.takeException(), isNull);
    final sos = tester.getRect(find.byKey(const Key('sosButton')));
    final mapBox = tester.getRect(find.byKey(const Key('tripMap')));
    expect(mapBox.contains(sos.center), isTrue, reason: 'SOS on the map');
    expect(sos.width, lessThan(50), reason: 'small SOS');
    await pumpPhone(tester, tripApp(full: true));
    expect(tester.takeException(), isNull);
    final full = tester.getRect(find.byKey(const Key('tripMap')));
    expect(full.top, 24, reason: 'below the status bar');
    expect(full.bottom, 780 - 16, reason: 'above the gesture bar');
    expect(find.byTooltip('Exit full screen'), findsOneWidget);
    expect(find.byKey(const Key('sosButton')), findsOneWidget);
  });

  testWidgets('trip preview PNG (TRIP_PNG=path)', (tester) async {
    final out = Platform.environment['TRIP_PNG'];
    if (out == null) return;
    await pumpPhone(tester, tripApp(full: false));
    await snap(tester, out);
  });

  testWidgets('trip full-screen preview PNG (TRIP_FULL_PNG=path)', (
    tester,
  ) async {
    final out = Platform.environment['TRIP_FULL_PNG'];
    if (out == null) return;
    await pumpPhone(tester, tripApp(full: true));
    await snap(tester, out);
  });
}
