// v2.6.2: search box on the Settings sheet and the Radio settings page.
// The index is checked against the real source so a new setting cannot be
// forgotten:  anchors <-> entries, section titles, labels that really exist.
//   V262_SHOTS=/workspace flutter test test/v262_settings_search_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/ui/home_page.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v253_radio_settings_test.dart' show Fw;

List<String> ids(String q, {SettingsEnv env = const SettingsEnv()}) => [
  for (final e in searchSettings(q, env: env)) e.id,
];

String libText() {
  final b = StringBuffer();
  for (final f in Directory('lib').listSync(recursive: true)) {
    if (f is File && f.path.endsWith('.dart')) {
      b.writeln(f.readAsStringSync());
    }
  }
  return b.toString();
}

/// The jump is a 300 ms scroll that starts one frame after the tap.
Future<void> afterJump(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 600));
}

Iterable<String> grab(String src, RegExp re) =>
    re.allMatches(src).map((m) => m.group(1)!);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('matching', () {
    test('relay: the phone relay, the radio relay and the relay server', () {
      final r = ids('relay');
      expect(r, containsAll(['relay-others', 'radio-relay', 'relay-url']));
    });

    test('weather finds Weather alerts first', () {
      expect(ids('weather').first, 'weather');
      expect(ids('weather'), containsAll(['wx-wifi', 'wx-share']));
      expect(ids('storm'), contains('weather'));
    });

    test('precision, blur and location find Location precision', () {
      for (final q in ['precision', 'blur', 'location', 'blurry', 'hide']) {
        expect(ids(q), contains('radio-precision'), reason: q);
      }
      expect(ids('precision').first, 'radio-precision');
    });

    test('frequency and slot find the relay slot and the match check', () {
      for (final q in ['frequency', 'slot', 'channel number']) {
        expect(ids(q), containsAll(['radio-relay', 'radio-match']), reason: q);
      }
    });

    test('range finds Range logging and Range test markers', () {
      expect(ids('range'), containsAll(['range-logging', 'range-markers']));
    });

    test('battery and power find the battery settings', () {
      for (final q in ['battery', 'power']) {
        expect(
          ids(q),
          containsAll([
            'stay-reachable',
            'battery-help',
            'offline-saver',
            'power-saver',
            'connection-speed',
          ]),
          reason: q,
        );
      }
    });

    test('plural, case, apostrophes and hyphens do not matter', () {
      expect(ids('RELAYS'), contains('radio-relay'));
      expect(ids("who's where"), contains('whos-where'));
      expect(ids('whos'), contains('whos-where'));
      expect(ids('wifi'), contains('wifi-direct'));
      expect(ids('Wi-Fi'), contains('wifi-direct'));
      expect(ids('  hop   limit '), contains('radio-hop'));
    });

    test('every typed word must match: two words narrow the list', () {
      final one = ids('relay');
      final two = ids('relay public');
      expect(two, contains('radio-relay'));
      expect(two.length, lessThan(one.length));
      expect(ids('weather tornado'), contains('wx-extreme'));
      expect(ids('relay tornado'), isEmpty);
    });

    test('a title match beats a synonym match', () {
      expect(ids('hop limit').first, 'radio-hop');
      expect(ids('quiet').first, 'quiet');
      expect(ids('urgent').take(2), containsAll(['quiet-urgent']));
    });

    test('nothing for blank or nonsense', () {
      expect(ids(''), isEmpty);
      expect(ids('   '), isEmpty);
      expect(ids('???'), isEmpty);
      expect(ids('zzqqxx'), isEmpty);
    });

    test('settings that are not on screen are not offered', () {
      const pc = SettingsEnv(phone: false, wifiDirect: false);
      expect(ids('stay reachable', env: pc), isEmpty);
      expect(ids('volume', env: pc), isEmpty);
      expect(ids('wifi direct', env: pc), isEmpty);
      expect(ids('stay reachable'), contains('stay-reachable'));
      expect(
        ids('wifi only', env: const SettingsEnv(weatherOn: false)),
        isEmpty,
      );
      expect(
        ids('blocked', env: const SettingsEnv(hasBlocked: false)),
        isEmpty,
      );
      expect(
        ids('range logging', env: const SettingsEnv(hasTrip: false)),
        isEmpty,
      );
      expect(
        ids('undo', env: const SettingsEnv(radioBackup: false)),
        isNot(contains('radio-undo')),
      );
    });

    test('the Radio settings page only searches itself', () {
      final r = searchSettings('relay', homes: {SettingsHome.radio});
      expect(r.first.id, 'radio-relay');
      expect(r.every((e) => e.home == SettingsHome.radio), isTrue);
      expect(searchSettings('battery', homes: {SettingsHome.radio}), isEmpty);
    });

    test('fast: every word of the index over the whole index', () {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        searchSettings('battery power relay');
        searchSettings('x');
      }
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('the index matches the real screens', () {
    final src = libText();
    final anchors = grab(
      src,
      RegExp(r"SettingAnchor\(\s*id:\s*'([^']+)'"),
    ).toList();

    test('ids are unique', () {
      final seen = <String>{};
      for (final e in settingsIndex) {
        expect(seen.add(e.id), isTrue, reason: 'duplicate id ${e.id}');
      }
    });

    test(
      'every SettingAnchor has an index entry (add it to settings_index)',
      () {
        final known = {for (final e in settingsIndex) e.id};
        for (final a in anchors) {
          expect(known, contains(a), reason: 'anchor "$a" has no entry');
        }
      },
    );

    test('every Settings / Radio settings entry has an anchor', () {
      for (final e in settingsIndex) {
        if (e.home == SettingsHome.trip) continue;
        expect(anchors, contains(e.id), reason: '"${e.id}" has no anchor');
      }
    });

    test('every section title on the Settings sheet has index entries', () {
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      final titles = grab(home, RegExp(r"_SectionTitle\(\s*'([^']+)'")).toSet();
      expect(titles, isNotEmpty);
      final sections = {
        for (final e in settingsIndex)
          if (e.home == SettingsHome.settings) e.section,
      };
      for (final t in titles) {
        expect(sections, contains(t), reason: 'section "$t" has no entry');
      }
    });

    test('every heading on the Radio settings page has an index entry', () {
      final page = File('lib/ui/radio_settings_page.dart').readAsStringSync();
      final heads = grab(page, RegExp(r"head\(\s*'([^']+)'\s*\)")).toSet();
      expect(heads, isNotEmpty);
      final labels = {
        for (final e in settingsIndex)
          if (e.home == SettingsHome.radio) e.label,
      };
      for (final h in heads) {
        expect(labels, contains(h), reason: 'heading "$h" has no entry');
      }
    });

    test('every label is text that really exists in the app', () {
      for (final e in settingsIndex) {
        expect(
          src.contains(e.label),
          isTrue,
          reason: '"${e.label}" (${e.id}) is not on any screen any more',
        );
      }
    });

    test('every Trip map entry points at the real Range test page', () {
      final range = File('lib/ui/range_test_ui.dart').readAsStringSync();
      final layers = File('lib/ui/map_layers_page.dart').readAsStringSync();
      expect(range, contains("Text('Range logging')"));
      expect(range + layers, contains("Text('Range test markers')"));
    });

    test('result paths read well', () {
      final byId = {for (final e in settingsIndex) e.id: e};
      expect(byId['relay-others']!.path, 'Settings › Off-grid (no internet)');
      expect(
        byId['radio-precision']!.path,
        'Settings › Long-range radio › Radio settings',
      );
      expect(byId['range-logging']!.path, 'Trip map › Range test');
    });
  });

  group('Settings sheet', () {
    Future<WalkieController> openSettings(
      WidgetTester t, {
      double w = 360,
      double h = 640,
      double ts = 1.3,
    }) async {
      phone(t, w: w, h: h, ts: ts);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await t.pump();
      await t.tap(find.byTooltip('Settings'));
      await settle(t);
      return c;
    }

    Future<void> type(WidgetTester t, String q) async {
      await t.enterText(find.byKey(const Key('settings-search')), q);
      await t.pump();
    }

    testWidgets('a search box sits on top and stays when the list scrolls', (
      t,
    ) async {
      await openSettings(t);
      final box = find.byKey(const Key('settings-search'));
      expect(box, findsOneWidget);
      final y0 = t.getTopLeft(box).dy;
      await t.drag(
        find.byKey(const Key('settings-scroll')),
        const Offset(0, -900),
      );
      await t.pump();
      expect(t.getTopLeft(box).dy, y0);
      expect(t.getRect(box).right, lessThanOrEqualTo(360));
      expect(t.takeException(), isNull);
      await finish(t);
    });

    testWidgets(
      'typing shows results in place of the list; clear brings it back',
      (t) async {
        await openSettings(t);
        expect(find.text('Your call sign'), findsOneWidget);
        await type(t, 'weather');
        expect(find.byKey(const Key('search-result-weather')), findsOneWidget);
        expect(find.text('Your call sign'), findsNothing);
        expect(find.byKey(const Key('settings-search-count')), findsOneWidget);
        await t.tap(find.byKey(const Key('settings-search-clear')));
        await t.pump();
        expect(find.byKey(const Key('search-result-weather')), findsNothing);
        expect(find.text('Your call sign'), findsOneWidget);
        await finish(t);
      },
    );

    testWidgets('tapping a result scrolls to the setting and highlights it', (
      t,
    ) async {
      await openSettings(t);
      expect(find.byKey(const Key('wx-on')).hitTestable(), findsNothing);
      await type(t, 'weather');
      await t.tap(find.byKey(const Key('search-result-weather')));
      await afterJump(t);
      // The search is over, the whole list is back, the setting is on screen.
      expect(find.byKey(const Key('search-result-weather')), findsNothing);
      final r = t.getRect(find.byKey(const Key('wx-on')));
      expect(r.top, greaterThan(0));
      expect(r.bottom, lessThan(640));
      expect(find.byKey(const Key('wx-on')).hitTestable(), findsOneWidget);
      // Highlighted for a moment, then back to normal.
      final hl = find.ancestor(
        of: find.byKey(const Key('wx-on')),
        matching: find.byKey(const Key('setting-highlight')),
      );
      expect(hl, findsOneWidget);
      double alpha() =>
          (t.widget<DecoratedBox>(hl).decoration as BoxDecoration).color!.a;
      expect(alpha(), greaterThan(0.05));
      await t.pump(const Duration(seconds: 3));
      expect(alpha(), 0);
      await finish(t);
    });

    testWidgets('a result far down the list: Check for updates', (t) async {
      await openSettings(t);
      await type(t, 'updates');
      await t.tap(find.byKey(const Key('search-result-updates')));
      await afterJump(t);
      expect(find.text('Check for updates').hitTestable(), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
      await finish(t);
    });

    testWidgets('the search box does not jump while the list gets shorter', (
      t,
    ) async {
      await openSettings(t);
      final box = find.byKey(const Key('settings-search'));
      await type(t, 'relay');
      final y = t.getTopLeft(box).dy;
      await type(t, 'relay tornado');
      expect(find.text('No matching settings'), findsOneWidget);
      expect(t.getTopLeft(box).dy, y);
      await type(t, 'wifi only');
      expect(t.getTopLeft(box).dy, y);
      await finish(t);
    });

    testWidgets('No matching settings, with a hint', (t) async {
      await openSettings(t);
      await type(t, 'zzzqq');
      expect(find.text('No matching settings'), findsOneWidget);
      expect(find.byKey(const Key('settings-search-hint')), findsOneWidget);
      expect(find.byKey(const Key('settings-search-count')), findsNothing);
      await t.tap(find.byKey(const Key('settings-search-clear')));
      await t.pump();
      expect(find.text('No matching settings'), findsNothing);
      await finish(t);
    });

    testWidgets(
      '360 dp and double-size text: results and the empty state fit',
      (t) async {
        await openSettings(t, ts: 2.0);
        for (final q in ['relay', 'battery', 'frequency', 'qqq']) {
          await type(t, q);
          expect(t.takeException(), isNull, reason: q);
          final box = t.getRect(find.byKey(const Key('settings-search')));
          expect(box.left, greaterThanOrEqualTo(0));
          expect(box.right, lessThanOrEqualTo(360));
        }
        await type(t, 'battery');
        await t.drag(
          find.byKey(const Key('settings-scroll')),
          const Offset(0, -2000),
        );
        await t.pump();
        expect(t.takeException(), isNull);
        await finish(t);
      },
    );

    testWidgets('radio results say the radio must be connected', (t) async {
      await openSettings(t);
      await type(t, 'precision');
      expect(
        find.byKey(const Key('search-result-radio-precision')),
        findsOneWidget,
      );
      expect(find.text('Connect your radio first to change it.'), findsWidgets);
      await finish(t);
    });

    testWidgets('a radio result opens Radio settings at that setting', (
      t,
    ) async {
      await openSettings(t, h: 700);
      await type(t, 'precision');
      await t.tap(find.byKey(const Key('search-result-radio-precision')));
      await settle(t);
      expect(find.byType(RadioSettingsPage), findsOneWidget);
      final head = find.text('Location precision');
      expect(head.hitTestable(), findsWidgets);
      await t.pump(const Duration(seconds: 3));
      await finish(t);
    });

    testWidgets('every switch on the sheet is in the index', (t) async {
      final c = await openSettings(t, h: 4000);
      c.settings.blocked[1] = 'Somebody';
      c.settings.volumeKeyPtt = true;
      await t.pump();
      final known = {for (final e in settingsIndex) e.id};
      final sheet = find.byKey(const Key('settings-scroll'));
      final switches = find.descendant(
        of: sheet,
        matching: find.byType(SwitchListTile),
        skipOffstage: false,
      );
      expect(switches, findsWidgets);
      for (final s in switches.evaluate()) {
        final a = find.ancestor(
          of: find.byWidget(s.widget),
          matching: find.byType(SettingAnchor),
        );
        expect(
          a,
          findsWidgets,
          reason:
              'a switch without SettingAnchor: '
              '${(s.widget as SwitchListTile).title}',
        );
        final id = t.widget<SettingAnchor>(a.first).id;
        expect(known, contains(id));
      }
      await finish(t);
    });
  });

  group('Radio settings page', () {
    Future<void> world(
      WidgetTester t, {
      double h = 640,
      double ts = 1.3,
    }) async {
      phone(t, w: 360, h: h, ts: ts);
    }

    Future<dynamic> openPage(WidgetTester t, {String? jumpTo}) async {
      final c = await makeController(t);
      final s = MeshtasticSession(Fw());
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'RAK WisMesh'
        ..state = RadioState.ready
        ..session = s;
      await t.pumpWidget(
        MaterialApp(
          home: RadioSettingsPage(controller: c, jumpTo: jumpTo),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      return c;
    }

    testWidgets('opened from a search: scrolled to the setting, highlighted', (
      t,
    ) async {
      await world(t);
      await openPage(t, jumpTo: 'radio-relay');
      final r = t.getRect(find.byKey(const Key('rs-relay')));
      expect(r.top, greaterThan(0));
      expect(r.bottom, lessThan(640));
      final hl = find.ancestor(
        of: find.byKey(const Key('rs-relay')),
        matching: find.byKey(const Key('setting-highlight')),
      );
      expect(hl, findsOneWidget);
      await t.pump(const Duration(seconds: 3));
      expect(t.takeException(), isNull);
    });

    testWidgets('its own search box: only radio settings, tap scrolls', (
      t,
    ) async {
      await world(t);
      await openPage(t);
      expect(find.byKey(const Key('settings-search')), findsOneWidget);
      await t.enterText(find.byKey(const Key('settings-search')), 'battery');
      await t.pump();
      expect(find.text('No matching settings'), findsOneWidget);
      await t.enterText(find.byKey(const Key('settings-search')), 'slot');
      await t.pump();
      expect(
        find.byKey(const Key('search-result-radio-relay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('search-result-radio-match')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('search-result-weather')), findsNothing);
      await t.tap(find.byKey(const Key('search-result-radio-relay')));
      await afterJump(t);
      expect(find.byKey(const Key('search-result-radio-relay')), findsNothing);
      final r = t.getRect(find.byKey(const Key('rs-relay')));
      expect(r.top, greaterThan(0));
      expect(r.bottom, lessThan(640));
      await t.pump(const Duration(seconds: 3));
      expect(t.takeException(), isNull);
    });

    testWidgets('large text: the page and the results still fit', (t) async {
      await world(t, ts: 2.0);
      await openPage(t);
      for (final q in ['precision', 'zzz', 'hop']) {
        await t.enterText(find.byKey(const Key('settings-search')), q);
        await t.pump();
        expect(t.takeException(), isNull, reason: q);
      }
    });

    testWidgets('the Fix and Save buttons still work with the search around', (
      t,
    ) async {
      await world(t, h: 3000, ts: 1.0);
      await openPage(t);
      expect(find.byKey(const Key('rs-hop-save')), findsOneWidget);
      expect(find.byKey(const Key('rs-match')), findsOneWidget);
      expect(find.byKey(const Key('rs-list')), findsOneWidget);
    });
  });

  group('Trip map results', () {
    testWidgets('a Trip map result calls the Trip action', (t) async {
      phone(t);
      String? opened;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsSearchLayout(
              actions: SettingsSearchActions(openTrip: (id) => opened = id),
              body: const Text('everything'),
            ),
          ),
        ),
      );
      await t.enterText(find.byKey(const Key('settings-search')), 'range');
      await t.pump();
      expect(
        find.byKey(const Key('search-result-range-logging')),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('search-result-range-logging')));
      await t.pump();
      expect(opened, 'range-logging');
    });

    testWidgets('from Settings: closes the sheet and opens Range test', (
      t,
    ) async {
      phone(t, h: 800);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await t.pump();
      await t.tap(find.byTooltip('Settings'));
      await settle(t);
      await t.enterText(
        find.byKey(const Key('settings-search')),
        'range logging',
      );
      await t.pump();
      if (c.trip == null) {
        // No Trip map on this build of the test: the entries are not offered.
        expect(
          find.byKey(const Key('search-result-range-logging')),
          findsNothing,
        );
      } else {
        await t.tap(find.byKey(const Key('search-result-range-logging')));
        await settle(t);
        expect(find.byKey(const Key('settings-search')), findsNothing);
        expect(find.text('Range test markers'), findsWidgets);
      }
      await finish(t);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V262_SHOTS'];
    if (dir == null) return;

    Future<void> shot(WidgetTester t, String name) async {
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v262_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    testWidgets('Settings search on a 360 dp phone', (t) async {
      phone(t, w: 360, h: 640, ts: 1.3);
      final c = await makeController(t);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: HomePage(controller: c),
          ),
        ),
      );
      await t.pump();
      await t.tap(find.byTooltip('Settings'));
      await settle(t);
      await shot(t, 'settings');
      await t.enterText(find.byKey(const Key('settings-search')), 'relay');
      await t.pump();
      await shot(t, 'relay');
      await t.enterText(find.byKey(const Key('settings-search')), 'xyzzy');
      await t.pump();
      await shot(t, 'empty');
      await t.enterText(find.byKey(const Key('settings-search')), 'weather');
      await t.pump();
      await t.tap(find.byKey(const Key('search-result-weather')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 500));
      await shot(t, 'highlight');
      await t.pump(const Duration(seconds: 3));
      await finish(t);
      await t.pump(const Duration(seconds: 20));
    });

    testWidgets('Radio settings page search', (t) async {
      phone(t, w: 360, h: 640, ts: 1.3);
      final c = await makeController(t);
      final s = MeshtasticSession(Fw());
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: RadioSettingsPage(controller: c),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      await t.enterText(find.byKey(const Key('settings-search')), 'slot');
      await t.pump();
      await shot(t, 'radio_page');
      await t.tap(find.byKey(const Key('search-result-radio-relay')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 500));
      await shot(t, 'radio_jump');
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('large text', (t) async {
      phone(t, w: 360, h: 640, ts: 2.0);
      final c = await makeController(t);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: HomePage(controller: c),
          ),
        ),
      );
      await t.pump();
      await t.tap(find.byTooltip('Settings'));
      await settle(t);
      await t.enterText(find.byKey(const Key('settings-search')), 'battery');
      await t.pump();
      await shot(t, 'large_text');
      await finish(t);
      await t.pump(const Duration(seconds: 20));
    });
  });
}
