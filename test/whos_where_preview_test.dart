// Who's where screen (v1.8.2): layout at 360x780 / 1.3x text, taps, and
// WHOS_PNG=path renders a preview.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/whos_where.dart';
import 'package:walkie_talkie/core/lobby.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/ui/whos_where_page.dart';

import 'home_layout_test.dart' show loadFonts;

List<WhoGroup> sampleGroups() {
  final now = DateTime(2026, 10, 26, 9);
  LobbyEntry e(int id, LobbyBeacon b, TransportKind via, {int? hops}) {
    final x = LobbyEntry(id, b);
    if (hops != null) {
      x
        ..meshAt = now.subtract(const Duration(seconds: 4))
        ..hops = hops;
    } else {
      x.heard[via] = now.subtract(const Duration(seconds: 6));
    }
    return x;
  }

  return buildWhosWhere(
    myId: 0x1234,
    myName: 'Lord of the Pings',
    myChannel: 1,
    myScope: 1,
    iAmPrivate: false,
    myChannelName: 'Base Camp',
    myChannelEmoji: '🏕️',
    seen: const [
      WhoSeen(
        id: 0x5A11E,
        name: 'Rubber Duck',
        scope: 1,
        talking: true,
        links: {TransportKind.lan, TransportKind.internet},
      ),
      WhoSeen(id: 0x77, name: 'Maverick', scope: 1, links: {TransportKind.ble}),
      WhoSeen(
        id: 0x9001,
        name: 'Night Owl',
        scope: 3,
        links: {TransportKind.wifiDirect},
        info: {'cn': 'Hunters', 'ce': '🦌'},
      ),
    ],
    lobby: [
      e(
        0x4242,
        LobbyBeacon.public(name: 'Ghost Pepper', channel: 3),
        TransportKind.ble,
        hops: 2,
      ),
      e(
        0x31337,
        LobbyBeacon.public(
          name: 'Taco Tuesday',
          channel: 7,
          channelName: 'Fishing',
          channelEmoji: '🎣',
        ),
        TransportKind.internet,
      ),
      e(
        0xBEEF,
        LobbyBeacon.public(name: 'Grandpa', channel: 7),
        TransportKind.internet,
      ),
      e(
        0xCAFE,
        LobbyBeacon.private(callSign: 'Iceberg'),
        TransportKind.internet,
      ),
      e(
        0xF00D,
        LobbyBeacon.private(callSign: 'Static Cling'),
        TransportKind.lan,
      ),
    ],
    friends: {0xBEEF: 'Grandpa', 0xCAFE: 'Mom'},
    now: now,
  );
}

Widget whoApp({
  void Function(WhoGroup)? onJump,
  void Function(WhoPerson)? onPerson,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    colorSchemeSeed: Colors.teal,
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['NotoColorEmoji'],
  ),
  home: WhosWhereView(
    groups: sampleGroups(),
    showMe: true,
    lobbyOnline: true,
    onJump: onJump ?? (_) {},
    onPerson: onPerson == null ? null : (_, p) => onPerson(p),
    onShowMe: (_) {},
  ),
);

void main() {
  setUpAll(loadFonts);

  Future<void> pumpPhone(
    WidgetTester tester,
    Widget w, {
    double scale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 16 * 3);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(RepaintBoundary(child: w));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('groups lay out at 1.3x text; private shows no channel', (
    tester,
  ) async {
    await pumpPhone(tester, whoApp(), scale: 1.3);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('whos-where-summary')), findsOneWidget);
    expect(find.text('8 people on 4 channels'), findsOneWidget);
    expect(find.text('🏕️ Base Camp · CH 1'), findsNothing);
    expect(find.text('Base Camp · CH 1'), findsOneWidget);
    expect(find.text('Hunters · CH 3'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Private group'), findsOneWidget);
    expect(find.text('Mom'), findsOneWidget, reason: 'friend name');
    expect(find.textContaining('CH 9'), findsNothing);
    expect(find.byKey(const Key('whosWhereShowMe')), findsOneWidget);
  });

  testWidgets('tap a channel jumps there, tap a person opens them', (
    tester,
  ) async {
    WhoGroup? jumped;
    WhoPerson? opened;
    await pumpPhone(
      tester,
      whoApp(onJump: (g) => jumped = g, onPerson: (p) => opened = p),
    );
    await tester.tap(find.byKey(const Key('who-jump-3')));
    expect(jumped?.channel, 3);
    await tester.tap(find.text('Night Owl'));
    expect(opened?.name, 'Night Owl');
    // No jump button on our own channel.
    expect(find.byKey(const Key('who-jump-1')), findsNothing);
  });

  testWidgets('preview PNG (WHOS_PNG=path)', (tester) async {
    final out = Platform.environment['WHOS_PNG'];
    if (out == null) return;
    await pumpPhone(tester, whoApp());
    final b = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final img = await b.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
