// v2.6.5: Public-node names on the Show public nodes list.
// Fake radio; nothing here has run on a real radio.
//   V265_SHOTS=/workspace flutter test test/v265_public_names_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/ui/public_nodes.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';
import 'package:walkie_talkie/ui/radios_nearby_page.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v264_public_nodes_test.dart' show addExamplePublic, heard, radioOn, up;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('sanitize', () {
    test('strips control characters and length-limits', () {
      expect(sanitizePublicName('  Camp Gate  '), 'Camp Gate');
      expect(sanitizePublicName('bad\nname\t!'), 'badname!');
      expect(sanitizePublicName('\x00\x1f\x7f'), '');
      expect(sanitizePublicName('a' * 50).length, lessThanOrEqualTo(39));
      expect(
        utf8ByteLen(sanitizePublicName('a' * 50)),
        lessThanOrEqualTo(publicLongNameMaxBytes),
      );
      expect(
        sanitizePublicName('ABCDEx', maxBytes: publicShortNameMaxBytes),
        'ABCD',
      );
      expect(sanitizePublicName('é' * 30).isNotEmpty, isTrue);
      expect(
        utf8ByteLen(sanitizePublicName('é' * 30)),
        lessThanOrEqualTo(publicLongNameMaxBytes),
      );
    });
  });

  group('User on the public channel', () {
    test('NODEINFO_APP sets the name; packet stays out of the app', () async {
      final fw = radioOn(withPublic: true);
      final s = await up(fw);
      addTearDown(s.close);
      final got = <MeshPacketPb>[];
      final sub = s.packets.listen(got.add);
      addTearDown(sub.cancel);
      final before = List<String>.from(fw.log);
      final user = UserPb(
        id: '!e0a10099',
        longName: 'Public Example',
        shortName: 'PEX',
        hwModel: 9,
      );
      s.handle(
        heard(
          0xE0A10099,
          ch: 2,
          port: PortNum.nodeInfo,
          payload: user.encode(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty, reason: 'public traffic never reaches the app');
      expect(s.publicReceived, 1);
      final n = s.nodes[0xE0A10099]!;
      expect(s.isPublicNode(n), isTrue);
      expect(n.longName, 'Public Example');
      expect(n.shortName, 'PEX');
      expect(n.hasInfo, isTrue);
      expect(n.hwModel, 9);
      expect(fw.log, before, reason: 'no name request is sent to the radio');
      expect(fw.packets, isEmpty, reason: 'nothing queued on the radio');
    });

    test('list shows sanitized name with ID smaller; no locations', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      final now = DateTime(2026, 11, 6, 10);
      addExamplePublic(s, now: now);
      // Nasty name from the air: controls + over-long.
      s.handle(
        heard(
          0xE0A10006,
          ch: 2,
          port: PortNum.nodeInfo,
          payload: UserPb(
            longName: 'Evil\nName\x00${'X' * 60}',
            shortName: 'TOOLONG',
          ).encode(),
        ),
      );
      final p = computePublicNodes(
        session: s,
        onPublicSlot: true,
        phone: const GeoPoint(45.52, -122.68),
      );
      final named = p.nodes.firstWhere((n) => n.num == 0xE0A10001);
      expect(named.label, 'Example Name One (EX1)');
      expect(named.idLabel, '!e0a10001');
      expect(named.hasName, isTrue);
      final evil = p.nodes.firstWhere((n) => n.num == 0xE0A10006);
      expect(evil.longName, isNot(contains('\n')));
      expect(evil.longName, isNot(contains('\x00')));
      expect(utf8ByteLen(evil.longName), lessThanOrEqualTo(39));
      expect(utf8ByteLen(evil.shortName), lessThanOrEqualTo(4));
      expect(evil.label, isNot(startsWith('Public radio')));
      final unnamed = p.nodes.firstWhere((n) => n.num == 0xE0A10003);
      expect(unnamed.label, 'Public radio !e0a10003');
      for (final n in p.nodes) {
        final text = '${n.label} ${n.idLabel} ${publicNodeLine(n, now: now)}';
        expect(text, isNot(contains('45.')));
        expect(text, isNot(contains('-122')));
      }
    });

    test('no request is sent when the list is built or the page opens',
        () async {
      final fw = radioOn(withPublic: true);
      final s = await up(fw);
      addTearDown(s.close);
      addExamplePublic(s);
      final before = fw.log.length;
      computePublicNodes(session: s, onPublicSlot: true);
      expect(fw.log.length, before, reason: 'compute sends nothing');
    });
  });

  group('kept apart', () {
    test('Radios nearby still leaves public nodes out', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      addExamplePublic(s);
      final r = computeRadiosNearby(
        session: s,
        signals: const {},
        walkieName: (_) => '',
        openByLink: (_) => null,
        groupByTag: (_) => null,
        openByNumber: (_) => null,
      );
      expect(r.public, 4);
      expect(r.radios.where((x) => x.name.contains('Example')), isEmpty);
    });
  });

  group('settings search', () {
    test('names / callsign / long name find Show public nodes', () {
      for (final q in ['names', 'callsign', 'long name', 'short name']) {
        expect(
          searchSettings(q).map((e) => e.id),
          contains('radio-public-nodes'),
          reason: q,
        );
      }
      final e = settingsIndex.firstWhere((e) => e.id == 'radio-public-nodes');
      expect(e.about, contains('name'));
    });
  });

  group('the page', () {
    Future<(WalkieController, MeshtasticSession)> world(
      WidgetTester t,
    ) async {
      phone(t, w: 400, h: 4200, ts: 1.0);
      final c = await makeController(t);
      final s = MeshtasticSession(radioOn(withPublic: true));
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      return (c, s);
    }

    testWidgets('named row shows name and smaller ID; unnamed keeps ID title',
        (t) async {
      final (c, s) = await world(t);
      addExamplePublic(s);
      await t.pumpWidget(MaterialApp(home: RadioSettingsPage(controller: c)));
      await t.pump();
      expect(find.text('Example Name One (EX1)'), findsOneWidget);
      expect(find.textContaining('!e0a10001'), findsWidgets);
      expect(find.text('Public radio !e0a10003'), findsOneWidget);
      expect(find.text(radioPublicNote), findsOneWidget);
      expect(radioPublicNote, contains('name'));
      expect(radioPublicNote, isNot(contains('no names')));
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V265_SHOTS'];
    if (dir == null) return;

    Future<void> save(WidgetTester t, String name) async {
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v265_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    testWidgets('list with names', (t) async {
      phone(t, w: 400, h: 1350, ts: 1.0);
      final c = await makeController(t);
      final fw = radioOn(withPublic: true);
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      s.nodes[0x0B4F84FB] = RadioNode(0x0B4F84FB)
        ..lat = 45.52
        ..lng = -122.68;
      // Fw.myNode may differ; set our own position via myNodeNum.
      final me = s.myNodeNum;
      if (me != null) {
        s.nodes[me]!
          ..lat = 45.52
          ..lng = -122.68;
      }
      addExamplePublic(s);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.amber,
                  padding: const EdgeInsets.fromLTRB(8, 30, 8, 6),
                  child: const Text(
                    'EXAMPLE DATA: made-up radios, not real nodes',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black,
                      fontFamily: 'Roboto',
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                Expanded(child: RadioSettingsPage(controller: c)),
              ],
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      await t.ensureVisible(find.byKey(const Key('rs-relay')));
      await t.pump(const Duration(milliseconds: 300));
      await t.drag(find.byType(Scrollable).first, const Offset(0, 60));
      await t.pump(const Duration(milliseconds: 300));
      await save(t, 'list');
    });
  });
}

int utf8ByteLen(String s) => utf8.encode(s).length;