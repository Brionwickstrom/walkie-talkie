// v2.6.13: Guided radio setup. Fake radios only; nothing here has run on
// a real radio.
//   GUIDED_SHOTS=/opt/cursor/artifacts flutter test test/v2613_guided_setup_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/lora/guided_setup.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/lora/radio_match.dart';
import 'package:walkie_talkie/lora/saved_radios.dart';
import 'package:walkie_talkie/ui/guided_setup_page.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v253_radio_settings_test.dart'
    show Fw, loraRaw, ownerRaw, positionRaw, writer;
import 'v257_precision_test.dart' show bigKey, chan, hikeKey;
import 'v264_public_nodes_test.dart' show chWriter;

final t0 = DateTime.utc(2026, 11, 8, 12);

GuidedNow yetiNow({
  int slot = 0,
  int hop = 3,
  int? bigfoot = 13,
  bool sharing = false,
  bool listen = false,
  bool shares = false,
}) => GuidedNow(
  connected: true,
  radioId: 'AA:BB',
  radioTitle: 'Yeti',
  longName: 'Yeti',
  shortName: 'YETI',
  region: 1,
  slot: slot,
  hop: hop,
  bigfootIndex: bigfoot == null ? null : 0,
  bigfootPrecision: bigfoot,
  sharing: sharing,
  publicListen: listen,
  publicShares: shares,
);

GuidedChoice choice({
  int slot = 20,
  int hop = 4,
  bool share = false,
  bool listen = false,
  String long = 'Yeti',
  String short = 'YETI',
}) => GuidedChoice(
  longName: long,
  shortName: short,
  region: 1,
  slot: slot,
  hop: hop,
  shareLocation: share,
  listenPublic: listen,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the plan', () {
    test('no other radios yet: hop 4 and the US public slot', () {
      final want = suggestGuided(yetiNow(), const []);
      expect(want.hop, guidedDefaultHop);
      expect(want.slot, 20);
      expect(radioPublicSlot(1), 20);
      expect(want.region, 1);
      expect(want.longName, 'Yeti');
      expect(want.listenPublic, isFalse);
      expect(want.shareLocation, isFalse);
    });

    test('other radios win, and a tie goes to hop 4', () {
      final others = [
        RadioReading(at: t0, slot: 9, hop: 3),
        RadioReading(at: t0, slot: 20, hop: 4),
      ];
      final want = suggestGuided(yetiNow(), others);
      expect(want.hop, 4);
      expect(want.slot, 20);
    });

    test('a clear majority is used, hop and slot', () {
      final others = [
        RadioReading(at: t0, slot: 20, hop: 4),
        RadioReading(at: t0, slot: 20, hop: 4),
        RadioReading(at: t0, slot: 9, hop: 7),
      ];
      final want = suggestGuided(yetiNow(hop: 7, slot: 9), others);
      expect(want.hop, 4);
      expect(want.slot, 20);
    });

    test('review names only the settings that change, never a key', () {
      final plan = buildGuidedPlan(yetiNow(), choice());
      expect(plan.writes, isTrue);
      expect(plan.missingChannel, isFalse);
      expect(plan.change.lora[8], 4);
      expect(plan.change.lora[11], 20);
      expect(plan.change.lora.containsKey(7), isFalse, reason: 'region stays');
      expect(plan.change.channelPrecision, {0: 32});
      expect(plan.change.longName, isNull);
      final text = plan.lines.map((l) => l.sentence).join('\n');
      expect(text, contains('Frequency slot: 0 (automatic) to 20'));
      expect(text, contains('Hop limit: 3 to 4'));
      expect(text, contains('~2.9 km (13) to Full (exact)'));
      expect(text, contains('Long name: Yeti (no change)'));
      expect(text.toLowerCase(), isNot(contains('psk')));
      expect(text, isNot(contains('http')));
      expect(text, isNot(contains(base64Encode(bigKey))));
    });

    test('BigfootNet missing: nothing is written for its precision', () {
      final plan = buildGuidedPlan(yetiNow(bigfoot: null), choice());
      expect(plan.missingChannel, isTrue);
      expect(plan.change.channelPrecision, isEmpty);
      expect(
        plan.lines.firstWhere((l) => l.label.startsWith('BigfootNet')).before,
        'not on this radio',
      );
    });

    test('a public channel that shares is made listen-only, not left', () {
      final now = yetiNow(
        listen: true,
        shares: true,
        hop: 4,
        slot: 20,
        bigfoot: 32,
      );
      final want = suggestGuided(now, const []);
      expect(want.listenPublic, isTrue, reason: 'the switch stays as it was');
      final plan = buildGuidedPlan(now, want);
      expect(plan.publicReset, isTrue);
      expect(plan.publicListen, isNull);
      expect(plan.change.isEmpty, isTrue);
    });

    test('read-back says which setting did not stick', () {
      final checks = checkGuided(yetiNow(), choice());
      final hop = checks.firstWhere((c) => c.id == 'hop');
      expect(hop.ok, isFalse);
      expect(hop.sentence, 'Hop limit is still 3, not 4.');
      final prec = checks.firstWhere((c) => c.id == 'precision');
      expect(prec.ok, isFalse);
      expect(prec.sentence, contains('Full (exact)'));
      expect(checks.firstWhere((c) => c.id == 'long').ok, isTrue);
      final msg = guidedMismatchMessage(checks);
      expect(msg, contains('did not keep:'));
      expect(msg, contains('hop limit'));
      expect(msg.toLowerCase(), isNot(contains('psk')));
      expect(msg, isNot(contains(base64Encode(bigKey))));
    });

    test('a matching radio reads back clean', () {
      final now = yetiNow(
        slot: 20,
        hop: 4,
        bigfoot: 32,
        sharing: true,
        listen: true,
      );
      final checks = checkGuided(now, choice(share: true, listen: true));
      expect(checks.every((c) => c.ok), isTrue);
      expect(checks.map((c) => c.sentence).join('\n'), isNot(contains('http')));
    });

    test('slot and region validation stay in plain words', () {
      expect(validateFrequencySlot(20, 1), isNull);
      expect(validateFrequencySlot(0, 1), isNull);
      expect(validateFrequencySlot(-1, 1), isNotNull);
      expect(validateFrequencySlot(200, 1), contains('frequency slots 1 to'));
      expect(validateGuidedRegion(1), isNull);
      expect(validateGuidedRegion(0), 'Pick a region.');
    });

    test('the backup remembers whether public listening was on', () {
      final snap = RadioSnapshot(node: 1, at: t0, lora: loraRaw());
      final again = RadioBackup.tryDecode(
        RadioBackup(previous: snap, publicListen: false).encode(),
      )!;
      expect(again.publicListen, isFalse);
      expect(again.previous.hopLimit, 3);
      final older = RadioBackup.tryDecode(
        RadioBackup(previous: snap).encode(),
      )!;
      expect(older.publicListen, isNull);
    });

    test('version 2.6.13+73 or later is described in the changelog', () {
      final p = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'\nversion: 2\.6\.(\d+)\+(\d+)\n').firstMatch(p)!;
      final patch = int.parse(m.group(1)!);
      final build = int.parse(m.group(2)!);
      expect(
        patch > 13 || (patch == 13 && build >= 73),
        isTrue,
        reason: 'pubspec is ${m.group(0)}',
      );
      final readme = File('README.md').readAsStringSync();
      final start = readme.indexOf('## v2.6.13:');
      expect(start, greaterThanOrEqualTo(0));
      final next = readme.indexOf('\n## ', start + 4);
      final section = readme.substring(start, next < 0 ? readme.length : next);
      expect(section, contains('Guided radio setup'));
      expect(section, contains('Listen to public radios'));
      expect(section.toLowerCase(), isNot(contains('psk')));
      expect(section, isNot(contains('http')));
    });

    test('settings search finds the wizard', () {
      final hits = searchSettings('guided');
      expect(hits.first.id, 'radio-guided-setup');
      expect(searchSettings('guided setup').first.id, 'radio-guided-setup');
      expect(
        searchSettings('wizard').map((e) => e.id),
        contains('radio-guided-setup'),
      );
      expect(
        searchSettings('new radio').map((e) => e.id),
        contains('radio-guided-setup'),
      );
      final page = File('lib/ui/radio_settings_page.dart').readAsStringSync();
      expect(page, contains("id: 'radio-guided-setup'"));
      expect(page, contains("head('Guided radio setup')"));
      final entry = settingsIndex.firstWhere(
        (e) => e.id == 'radio-guided-setup',
      );
      expect(entry.home, SettingsHome.radio);
      expect(entry.label, 'Guided radio setup');
    });
  });

  group('on screen', () {
    setUpAll(loadFonts);

    Future<(WalkieController, Fw, MeshtasticSession)> world(
      WidgetTester t, {
      Fw? fw0,
      bool connected = true,
      bool withOthers = true,
    }) async {
      phone(t, w: 400, h: 900, ts: 1.0);
      final c = await makeController(t);
      final fw =
          fw0 ??
          (Fw()
            ..lora = patchVarints(loraRaw(hop: 3), {11: 0})
            ..position = positionRaw(secs: posNever, smart: false)
            ..owner = ownerRaw(long: 'Yeti', short: 'YETI')
            ..channels[0] = chan(0, 1, 'BigfootNet', bigKey, prec: 13)
            ..channels[1] = chan(1, 2, 'Hikers', hikeKey, prec: 13));
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      if (connected) {
        c.radioDevice
          ..deviceId = 'AA:BB'
          ..deviceName = 'Yeti'
          ..state = RadioState.ready
          ..session = s;
      }
      c.radioSettingsWriterFactory = () => writer(s);
      c.meshWriterFactory = () => chWriter(s);
      if (withOthers) {
        c.settings.savedRadios.add(
          SavedRadio(
            id: 'serial:COM7',
            name: 'Skunk Ape',
            nodeId: 0x0b4f84fb,
            reading: RadioReading(
              at: t0,
              slot: 20,
              hop: 4,
              precisions: const {'BigfootNet': 32},
            ),
          ),
        );
      }
      return (c, fw, s);
    }

    Future<void> open(WidgetTester t, WalkieController c) async {
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: Colors.teal,
            brightness: Brightness.dark,
            useMaterial3: true,
          ),
          home: GuidedSetupPage(controller: c),
        ),
      );
      await t.pump();
    }

    Future<void> next(WidgetTester t) async {
      final f = find.byKey(const Key('gs-next'));
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pump();
    }

    Future<void> waitDone(WidgetTester t) async {
      for (var i = 0; i < 250; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
        final done =
            find.byKey(const Key('gs-checks')).evaluate().isNotEmpty ||
            find.byKey(const Key('fe-message')).evaluate().isNotEmpty ||
            find.byKey(const Key('gs-restored')).evaluate().isNotEmpty ||
            find.byKey(const Key('gs-ping-sent')).evaluate().isNotEmpty;
        if (done) return;
      }
      fail('the wizard step never finished');
    }

    String visibleText(WidgetTester t) => t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
        .join('\n');

    void noSecrets(String text) {
      expect(text.toLowerCase(), isNot(contains('psk')));
      expect(text, isNot(contains('http')));
      expect(text, isNot(contains('meshtastic.org')));
      expect(text, isNot(contains(base64Encode(bigKey))));
      expect(text, isNot(contains(base64Encode(hikeKey))));
    }

    testWidgets('connect, review, apply, read-back, ping, saved radio', (
      t,
    ) async {
      final (c, fw, s) = await world(t);
      await open(t, c);
      expect(find.byKey(const Key('gs-connected')), findsOneWidget);
      expect(find.text('Skunk Ape'), findsOneWidget);
      expect(find.text('Connected'), findsWidgets);
      noSecrets(visibleText(t));

      await next(t);
      expect(find.text('Name'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byKey(const Key('gs-long'))).controller!.text,
        'Yeti',
      );
      expect(
        t.widget<TextField>(find.byKey(const Key('gs-short'))).controller!.text,
        'YETI',
      );

      await next(t);
      expect(find.text('Region and hops'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byKey(const Key('gs-slot'))).controller!.text,
        '20',
      );
      expect(find.byKey(const Key('gs-hop-value')), findsOneWidget);
      expect(find.text('4'), findsWidgets);

      await next(t);
      expect(find.byKey(const Key('gs-precision')), findsOneWidget);
      expect(find.textContaining('Full (exact)'), findsWidgets);
      noSecrets(visibleText(t));

      await next(t);
      await t.tap(find.byKey(const Key('gs-location')));
      await t.pump();
      expect(
        t.widget<SwitchListTile>(find.byKey(const Key('gs-location'))).value,
        isTrue,
      );

      await next(t);
      expect(find.byKey(const Key('gs-public-note')), findsOneWidget);
      expect(find.textContaining('slot 20'), findsOneWidget);
      await t.tap(find.byKey(const Key('gs-public')));
      await t.pump();

      await next(t);
      expect(find.byKey(const Key('gs-review')), findsOneWidget);
      expect(find.byKey(const Key('gs-backup-note')), findsOneWidget);
      expect(
        find.textContaining('Frequency slot: 0 (automatic) to 20'),
        findsOneWidget,
      );
      expect(find.textContaining('Hop limit: 3 to 4'), findsOneWidget);
      expect(
        find.textContaining('~2.9 km (13) to Full (exact)'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Location sharing: off to on'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Listen to public radios: off to on, listen-only'),
        findsOneWidget,
      );
      noSecrets(visibleText(t));

      await next(t);
      await waitDone(t);
      expect(find.byKey(const Key('gs-checks')), findsOneWidget);
      expect(find.byKey(const Key('fe-message')), findsNothing);
      for (final id in [
        'long',
        'short',
        'region',
        'slot',
        'hop',
        'precision',
        'location',
        'public',
      ]) {
        expect(find.byKey(Key('gs-check-$id')), findsOneWidget, reason: id);
      }
      expect(find.text('Hop limit is 4.'), findsOneWidget);
      expect(find.text('Frequency slot is 20.'), findsOneWidget);
      expect(
        find.textContaining('BigfootNet location precision is Full (exact)'),
        findsOneWidget,
      );
      noSecrets(visibleText(t));

      expect(s.hopLimit, 4);
      expect(s.channelNum, 20);
      expect(s.channels[0]!.name, 'BigfootNet');
      expect(s.channels[0]!.positionPrecision, 32);
      expect(s.channels[1]!.name, 'Hikers');
      expect(s.channels[1]!.positionPrecision, 13);
      expect(locationSharingOn(s.positionSecs, s.positionSmart), isTrue);
      expect(s.publicListenIndex, isNotNull);
      final pub = s.channels[s.publicListenIndex!]!;
      expect(pub.uplinkEnabled, isFalse);
      expect(pub.positionPrecision, 0);

      final backup = RadioBackup.tryDecode(c.settings.radioBackup)!;
      expect(backup.previous.hopLimit, 3);
      expect(backup.previous.channelNum, 0);
      expect(backup.publicListen, isFalse);
      expect(backup.previous.channelPrecisions[0], 13);

      final saved = c.savedRadios.firstWhere((r) => r.id == 'AA:BB');
      expect(saved.name, 'Yeti');
      expect(saved.shortName, 'YETI');
      expect(saved.reading!.hop, 4);
      expect(saved.reading!.slot, 20);
      expect(saved.reading!.precisions['BigfootNet'], 32);
      expect(saved.reading!.precisions.containsKey('LongFast'), isFalse);

      await t.tap(find.byKey(const Key('gs-to-done')));
      await t.pump();
      expect(find.byKey(const Key('gs-saved-radio')), findsOneWidget);
      expect(find.text('Yeti is in your saved radios.'), findsOneWidget);
      await t.tap(find.byKey(const Key('gs-ping')));
      await waitDone(t);
      expect(find.byKey(const Key('gs-ping-sent')), findsOneWidget);
      final pings = fw.packets
          .where((p) => p.decoded?.portnum == PortNum.privateApp)
          .toList();
      expect(pings, hasLength(1));
      expect(pings.single.hopLimit, 1);
      expect(pings.single.channel, 0);
      expect(pings.single.decoded!.payload.toList(), [0x50]);
      noSecrets(c.debugLog.lines.join('\n'));
      noSecrets(visibleText(t));

      // Restore puts the backup back, including the public channel.
      await t.tap(find.byKey(const Key('gs-back')));
      await t.pump();
      await t.ensureVisible(find.byKey(const Key('gs-restore')));
      await t.tap(find.byKey(const Key('gs-restore')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('gs-restore-dialog')), findsOneWidget);
      await t.tap(find.byKey(const Key('gs-restore-cancel')));
      await t.pumpAndSettle();
      expect(s.hopLimit, 4, reason: 'cancel leaves the new settings');

      await t.tap(find.byKey(const Key('gs-restore')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('gs-restore-confirm')));
      await t.pump();
      await waitDone(t);
      expect(find.byKey(const Key('gs-restored')), findsOneWidget);
      expect(s.hopLimit, 3);
      expect(s.channelNum, 0);
      expect(s.channels[0]!.positionPrecision, 13);
      expect(s.channels[1]!.positionPrecision, 13);
      expect(locationSharingOn(s.positionSecs, s.positionSmart), isFalse);
      expect(s.publicListenIndex, isNull);
      final restored = c.savedRadios.firstWhere((r) => r.id == 'AA:BB');
      expect(restored.reading!.hop, 3);
      expect(restored.reading!.slot, 0);
      expect(restored.reading!.precisions['BigfootNet'], 13);
      noSecrets(visibleText(t));
    });

    testWidgets('a read-back mismatch offers Restore and does not stick', (
      t,
    ) async {
      final fw = Fw(applySets: false)
        ..lora = patchVarints(loraRaw(hop: 3), {11: 0})
        ..position = positionRaw(secs: posNever, smart: false)
        ..owner = ownerRaw(long: 'Yeti', short: 'YETI')
        ..channels[0] = chan(0, 1, 'BigfootNet', bigKey, prec: 13);
      final (c, _, s) = await world(t, fw0: fw, withOthers: true);
      await open(t, c);
      await next(t);
      await next(t);
      await next(t);
      await next(t);
      await next(t);
      await next(t);
      expect(find.textContaining('Hop limit: 3 to 4'), findsOneWidget);
      await next(t);
      await waitDone(t);
      expect(find.byKey(const Key('fe-message')), findsOneWidget);
      expect(find.textContaining('did not keep'), findsOneWidget);
      expect(
        find.textContaining('Hop limit is still 3, not 4.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('gs-restore')), findsOneWidget);
      expect(s.hopLimit, 3);
      expect(s.channelNum, 0);
      expect(s.channels[0]!.positionPrecision, 13);
      final backup = RadioBackup.tryDecode(c.settings.radioBackup)!;
      expect(backup.previous.hopLimit, 3);
      expect(backup.previous.channelPrecisions[0], 13);
      expect(
        fw.writes.first,
        isNot('set_lora'),
        reason: 'a read happens first',
      );
      expect(fw.writes, contains('set_lora'));
      noSecrets(visibleText(t));
      noSecrets(c.debugLog.lines.join('\n'));

      fw.applySets = true;
      await t.tap(find.byKey(const Key('gs-restore')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('gs-restore-confirm')));
      await t.pump();
      await waitDone(t);
      expect(find.byKey(const Key('gs-restored')), findsOneWidget);
      expect(s.hopLimit, 3);
      expect(s.channels[0]!.positionPrecision, 13);
      expect(s.publicListenIndex, isNull);
    });

    testWidgets('no BigfootNet channel: a plain error and Try again', (
      t,
    ) async {
      final fw = Fw()
        ..owner = ownerRaw(long: 'Sasquatch', short: 'SQCH')
        ..channels[0] = chan(0, 1, 'LongFast', const [1], prec: 13);
      final (c, _, _) = await world(t, fw0: fw, withOthers: false);
      await open(t, c);
      await next(t);
      await next(t);
      await next(t);
      expect(
        find.textContaining('does not have the BigfootNet channel'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('fe-fix-retry')), findsOneWidget);
      expect(
        t.widget<FilledButton>(find.byKey(const Key('gs-next'))).onPressed,
        isNull,
      );
      await t.tap(find.byKey(const Key('fe-fix-retry')));
      await t.pump();
      expect(find.text('Location sharing'), findsNothing);
      noSecrets(visibleText(t));
    });

    testWidgets(
      'not connected: Connect radio, and the page opens from Radio settings',
      (t) async {
        final (c, _, _) = await world(t, connected: false, withOthers: false);
        await open(t, c);
        expect(find.textContaining('Connect your radio first'), findsOneWidget);
        expect(find.byKey(const Key('fe-fix-connectRadio')), findsOneWidget);
        expect(
          t.widget<FilledButton>(find.byKey(const Key('gs-next'))).onPressed,
          isNull,
        );

        await t.pumpWidget(const SizedBox());
        await t.pumpWidget(MaterialApp(home: RadioSettingsPage(controller: c)));
        await t.pump();
        await t.ensureVisible(find.byKey(const Key('rs-guided')));
        expect(find.text('Guided radio setup'), findsWidgets);
        await t.tap(find.byKey(const Key('rs-guided')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 400));
        expect(find.byType(GuidedSetupPage), findsOneWidget);
        expect(find.byKey(const Key('gs-title')), findsOneWidget);
      },
    );

    testWidgets('the radio page search lists the wizard', (t) async {
      final (c, _, _) = await world(t);
      await t.pumpWidget(MaterialApp(home: RadioSettingsPage(controller: c)));
      await t.pump();
      await t.enterText(find.byKey(const Key('settings-search')), 'wizard');
      await t.pump();
      expect(
        find.byKey(const Key('search-result-radio-guided-setup')),
        findsOneWidget,
      );
      noSecrets(visibleText(t));
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['GUIDED_SHOTS'];
    if (dir == null) return;
    setUpAll(loadFonts);

    testWidgets('wizard with an out-of-sync Yeti', (t) async {
      phone(t, w: 400, h: 820, ts: 1.0);
      final c = await makeController(t);
      final fw = Fw()
        ..lora = patchVarints(loraRaw(hop: 3), {11: 0})
        ..position = positionRaw(secs: posNever, smart: false)
        ..owner = ownerRaw(long: 'Yeti', short: 'YETI')
        ..channels[0] = chan(0, 1, 'BigfootNet', bigKey, prec: 13)
        ..channels[1] = chan(1, 2, 'Hikers', hikeKey, prec: 13);
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yeti'
        ..state = RadioState.ready
        ..session = s;
      c.radioSettingsWriterFactory = () => writer(s);
      c.meshWriterFactory = () => chWriter(s);
      c.settings.savedRadios.addAll([
        SavedRadio(
          id: 'serial:COM7',
          name: 'Skunk Ape',
          reading: RadioReading(
            at: t0,
            slot: 20,
            hop: 4,
            precisions: const {'BigfootNet': 32},
          ),
        ),
        SavedRadio(
          id: 'CC:DD',
          name: 'Sasquatch',
          reading: RadioReading(
            at: t0,
            slot: 20,
            hop: 4,
            precisions: const {'BigfootNet': 32},
          ),
        ),
      ]);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: ThemeData(
              colorSchemeSeed: Colors.teal,
              brightness: Brightness.dark,
              useMaterial3: true,
            ),
            home: GuidedSetupPage(controller: c),
          ),
        ),
      );
      await t.pump();

      Future<void> shot(String name) async {
        final b = t.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('shotroot')),
        );
        await t.runAsync(() async {
          final img = await b.toImage(pixelRatio: 2);
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          File('$dir/guided_$name.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
        });
      }

      Future<void> next() async {
        await t.tap(find.byKey(const Key('gs-next')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
      }

      await shot('1_connect');
      await next();
      await next();
      await shot('2_region');
      await next();
      await next();
      await t.tap(find.byKey(const Key('gs-location')));
      await t.pump();
      await next();
      await t.tap(find.byKey(const Key('gs-public')));
      await t.pump();
      await next();
      await shot('3_review');
    });
  });
}
