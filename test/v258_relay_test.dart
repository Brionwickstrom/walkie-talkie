// v2.5.8: "Relay through public radios" on the Radio settings page.
// Fake radio of the v2.5.3 tests; nothing here has run on a real radio.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';

import 'v231_helpers.dart';
import 'v253_radio_settings_test.dart'
    show Fw, Saved, fieldsExcept, loraRaw, writer;
import 'v257_precision_test.dart' show chan, bigKey;

/// loraRaw with its channel_num (field 11) set to [slot] (0 = absent).
Uint8List loraAt(int slot, {int region = 1, int preset = 0, bool use = true}) =>
    patchVarints(loraRaw(region: region, preset: preset), {
      11: slot,
      if (!use) 1: 0,
    });

Fw radioWith(Uint8List lora) => Fw()
  ..lora = lora
  ..channels[0] = chan(0, 1, 'BigfootNet', bigKey, prec: 13)
  ..channels[1] = chan(1, 2, 'Hikers', [1, 2, 3, 4], prec: 13);

void main() {
  group('the firmware\'s slot arithmetic', () {
    test('djb2 of LongFast and the public slot of the regions', () {
      expect(meshHashName('LongFast'), 130429955);
      expect(radioSlotCount(1), 104);
      expect(radioPublicSlot(1), 20, reason: 'US');
      final expected = {
        6: 20, // ANZ
        3: 1, // EU 868
        2: 4, // EU 433
        4: 36, // CN
        5: 12, // JP
        7: 12, // KR
        8: 16, // TW
        12: 16, // TH
        9: 2, // RU
        10: 4, // IN
        11: 4, // NZ 865
        13: 6, // 2.4 GHz (wide)
      };
      expected.forEach((region, slot) {
        expect(radioPublicSlot(region), slot, reason: 'region $region');
      });
    });

    test('every region of the list is known; others are not offered', () {
      for (final r in radioRegions) {
        final n = radioSlotCount(r.code);
        expect(n, isNotNull, reason: r.label);
        expect(radioPublicSlot(r.code), inInclusiveRange(1, n!));
      }
      expect(radioPublicSlot(0), isNull);
      expect(radioPublicSlot(99), isNull);
      expect(radioSlotMhz(99, 1), isNull);
    });

    test('frequencies', () {
      expect(radioSlotMhz(1, 20), closeTo(906.875, 0.0005));
      expect(radioSlotMhz(1, 1), closeTo(902.125, 0.0005));
      expect(radioMhzText(radioSlotMhz(1, 20)!), '906.875 MHz');
      expect(radioMhzText(902.125), '902.125 MHz');
      expect(radioMhzText(869.525), '869.525 MHz');
    });

    test('the switch state comes from channel_num', () {
      RadioRelayInfo info({
        int? region = 1,
        int? preset = 0,
        bool? use = true,
        int? ch = 0,
      }) => radioRelayInfo(
        region: region,
        preset: preset,
        usePreset: use,
        channelNum: ch,
      );
      expect(info().on, isFalse);
      expect(info().canTurnOn, isTrue);
      expect(info().canTurnOff, isFalse);
      expect(info(ch: 20).on, isTrue);
      expect(info(ch: 20).canTurnOff, isTrue);
      expect(info(ch: 7).on, isFalse);
      expect(info(ch: 7).custom, isTrue);
      expect(info(ch: 7).canTurnOn, isTrue);
      expect(info(ch: 7).stateText, contains('frequency slot 7'));
      expect(info(preset: 4).canTurnOn, isFalse);
      expect(info(preset: 4).problem, contains('LongFast'));
      expect(info(use: false).canTurnOn, isFalse);
      expect(info(region: 0).problem, contains('region'));
      expect(info(region: 99).problem, contains('not known'));
      expect(info(region: null).canTurnOn, isFalse);
      expect(info(ch: 20).stateText, contains('906.875 MHz'));
    });

    test('the change touches only channel_num; the old bytes are kept', () {
      final before = loraRaw();
      final on = patchVarints(before, RadioChange.relay(true, 20).lora);
      final off = patchVarints(on, RadioChange.relay(false, 20).lora);
      expect(RadioChange.relay(true, 20).lora, {11: 20});
      expect(RadioChange.relay(false, 20).lora, {11: 0});
      expect(rawInt(on, 11), 20);
      expect(fieldsExcept(on, {11}), fieldsExcept(before, {11}));
      expect(rawInt(off, 11) ?? 0, 0);
      expect(fieldsExcept(off, {11}), fieldsExcept(before, {11}));
      expect(RadioChange.relay(true, 20).what, 'public relay');
    });
  });

  group('writing', () {
    Future<(Fw, MeshtasticSession)> up(Fw fw) async {
      final s = MeshtasticSession(fw);
      await s.start(timeout: const Duration(seconds: 2));
      addTearDown(s.close);
      return (fw, s);
    }

    test('ON writes channel_num 20 only, channels untouched', () async {
      final (fw, s) = await up(radioWith(loraAt(0)));
      final lora0 = Uint8List.fromList(fw.lora);
      final ch0 = Uint8List.fromList(fw.channels[0]!);
      final saved = Saved();
      final r = await writer(s).apply(
        RadioChange.relay(true, radioPublicSlot(1)!),
        saveBackup: saved.save,
      );
      expect(fw.writes, ['begin', 'set_lora', 'commit']);
      expect(rawInt(fw.lora, 11), 20);
      expect(fieldsExcept(fw.lora, {11}), fieldsExcept(lora0, {11}));
      expect(rawInt(fw.lora, 1), 1, reason: 'use_preset kept');
      expect(rawInt(fw.lora, 2) ?? 0, 0, reason: 'LongFast kept');
      expect(fw.channels[0], ch0, reason: 'BigfootNet name and key untouched');
      expect(fw.log.where((l) => l.startsWith('set_channel')), isEmpty);
      expect(r.after.channelNum, 20);
      expect(saved.backup!.previous.channelNum, 0);
      expect(fw.log.where((l) => l.startsWith('REJECTED')), isEmpty);
    });

    test('OFF writes channel_num 0', () async {
      final (fw, s) = await up(radioWith(loraAt(20)));
      final lora0 = Uint8List.fromList(fw.lora);
      final saved = Saved();
      await writer(s)
          .apply(RadioChange.relay(false, 20), saveBackup: saved.save);
      expect(rawInt(fw.lora, 11) ?? 0, 0);
      expect(fieldsExcept(fw.lora, {11}), fieldsExcept(lora0, {11}));
      expect(saved.backup!.previous.channelNum, 20);
      expect(saved.backup!.previous.summary, contains('frequency slot 20'));
    });

    test(
      'Restore puts the old slot back; the backup survives as text',
      () async {
        final (fw, s) = await up(radioWith(loraAt(0)));
        final saved = Saved();
        await writer(s)
            .apply(RadioChange.relay(true, 20), saveBackup: saved.save);
        final round = RadioBackup.tryDecode(saved.backup!.encode())!;
        expect(round.previous.channelNum, 0);
        await writer(
          s,
        ).apply(RadioChange.restore(round.previous), saveBackup: Saved().save);
        expect(rawInt(fw.lora, 11) ?? 0, 0);
      },
    );

    test('a radio that keeps the old slot is reported', () async {
      final fw = radioWith(loraAt(0))..applySets = false;
      final (_, s) = await up(fw);
      final saved = Saved();
      await expectLater(
        writer(s).apply(RadioChange.relay(true, 20), saveBackup: saved.save),
        throwsA(predicate((e) => e.toString().contains('frequency slot'))),
      );
      expect(saved.backup, isNotNull);
    });
  });

  group('the page', () {
    Future<(dynamic, Fw, MeshtasticSession)> world(
      WidgetTester t,
      Fw fw,
    ) async {
      phone(t, w: 400, h: 3600, ts: 1.0);
      final c = await makeController(t);
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'RAK WisMesh'
        ..state = RadioState.ready
        ..session = s;
      c.radioSettingsWriterFactory = () => writer(s);
      return (c, fw, s);
    }

    Future<void> openPage(WidgetTester t, dynamic c) async {
      await t.pumpWidget(
        MaterialApp(home: RadioSettingsPage(controller: c as dynamic)),
      );
      await t.pump();
    }

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 200; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('rs-saved')).evaluate().isNotEmpty ||
            find.byKey(const Key('rs-failed')).evaluate().isNotEmpty) {
          return;
        }
      }
      fail('the write never finished');
    }

    Future<void> tapKey(WidgetTester t, String k) async {
      final f = find.byKey(Key(k));
      await t.ensureVisible(f);
      await t.pump();
      await t.tap(f);
      await t.pump();
    }

    bool switchOn(WidgetTester t) =>
        t.widget<SwitchListTile>(find.byKey(const Key('rs-relay'))).value;
    bool switchEnabled(WidgetTester t) =>
        t.widget<SwitchListTile>(find.byKey(const Key('rs-relay'))).onChanged !=
        null;

    testWidgets('the section: off by default, explanation, warning, no chat', (
      t,
    ) async {
      final (c, _, _) = await world(t, radioWith(loraAt(0)));
      await openPage(t, c);
      expect(find.text('Relay through public radios'), findsOneWidget);
      expect(switchOn(t), isFalse);
      expect(switchEnabled(t), isTrue);
      expect(
        find.textContaining(
          'strangers can\'t read your messages, names or locations',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('There is no public chat channel'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Skunk Ape, Yowie, Yeti, Sasquatch'),
        findsOneWidget,
      );
      expect(
        t.widget<Text>(find.byKey(const Key('rs-relay-state'))).data,
        startsWith('Off: the frequency slot comes from the main channel'),
      );
      expect(find.byKey(const Key('rs-relay-why')), findsNothing);
    });

    testWidgets('turning it on: confirm with the warning, then slot 20', (
      t,
    ) async {
      final (c, fw, _) = await world(t, radioWith(loraAt(0)));
      await openPage(t, c);
      await tapKey(t, 'rs-relay');
      expect(find.byKey(const Key('rs-confirm-dialog')), findsOneWidget);
      expect(find.text(radioRelayWarn), findsWidgets);
      expect(find.textContaining('restarts'), findsOneWidget);
      expect(
        find.text(
          'Frequency slot: automatic → 20 (public LongFast, 906.875 MHz)',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Channel names and keys do not change.'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('rs-cancel')));
      await t.pumpAndSettle();
      expect(fw.log, isEmpty, reason: 'Cancel writes nothing');
      await tapKey(t, 'rs-relay');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(fw.writes, ['begin', 'set_lora', 'commit']);
      expect(rawInt(fw.lora, 11), 20);
      expect(find.byKey(const Key('rs-saved')), findsOneWidget);
      expect(switchOn(t), isTrue);
      expect(
        t.widget<Text>(find.byKey(const Key('rs-relay-state'))).data,
        'On: frequency slot 20, the public LongFast slot (906.875 MHz).',
      );
      // Off again goes back to the automatic slot.
      await tapKey(t, 'rs-relay');
      expect(
        find.text(
          'Frequency slot: 20 → automatic (from the main channel\'s name)',
        ),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(rawInt(fw.lora, 11) ?? 0, 0);
      expect(switchOn(t), isFalse);
    });

    testWidgets('Restore says the slot goes back too', (t) async {
      final (c, fw, _) = await world(t, radioWith(loraAt(0)));
      await openPage(t, c);
      await tapKey(t, 'rs-relay');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      await tapKey(t, 'rs-restore');
      expect(find.text('Frequency slot: 20 → automatic'), findsOneWidget);
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(rawInt(fw.lora, 11) ?? 0, 0);
    });

    testWidgets('another region: its own public slot', (t) async {
      final (c, fw, _) = await world(t, radioWith(loraAt(0, region: 3)));
      await openPage(t, c);
      await tapKey(t, 'rs-relay');
      expect(
        find.textContaining('automatic → 1 (public LongFast, 869.525 MHz)'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(rawInt(fw.lora, 11), 1);
    });

    testWidgets('not LongFast: not offered, says why', (t) async {
      final (c, fw, _) = await world(t, radioWith(loraAt(0, preset: 4)));
      await openPage(t, c);
      expect(switchEnabled(t), isFalse);
      expect(find.byKey(const Key('rs-relay-why')), findsOneWidget);
      expect(
        find.textContaining('Needs the Long range, fast (LongFast) speed'),
        findsOneWidget,
      );
      expect(fw.log, isEmpty);
    });

    testWidgets('region not set: not offered', (t) async {
      final (c, _, _) = await world(t, radioWith(loraAt(0, region: 0)));
      await openPage(t, c);
      expect(switchEnabled(t), isFalse);
      expect(find.text('Set the region first.'), findsOneWidget);
    });

    testWidgets('a slot from another app: shown, can go back to automatic', (
      t,
    ) async {
      final (c, fw, _) = await world(t, radioWith(loraAt(7)));
      await openPage(t, c);
      expect(switchOn(t), isFalse);
      expect(find.textContaining('Off: frequency slot 7'), findsOneWidget);
      await tapKey(t, 'rs-relay-off');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(rawInt(fw.lora, 11) ?? 0, 0);
    });

    testWidgets('on with another speed can still be switched off', (t) async {
      final (c, fw, _) = await world(t, radioWith(loraAt(20, preset: 4)));
      await openPage(t, c);
      expect(find.byKey(const Key('rs-relay-state')), findsOneWidget);
      expect(find.textContaining('frequency slot 20'), findsWidgets);
      expect(
        switchEnabled(t),
        isTrue,
        reason: 'turning off is always possible',
      );
      await tapKey(t, 'rs-relay');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(rawInt(fw.lora, 11) ?? 0, 0);
      expect(rawInt(fw.lora, 2), 4, reason: 'speed untouched');
    });

    testWidgets('region and speed confirms mention a custom slot', (t) async {
      final (c, _, _) = await world(t, radioWith(loraAt(20)));
      await openPage(t, c);
      t
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const Key('rs-region')),
          )
          .onChanged!(6);
      await t.pump();
      await tapKey(t, 'rs-region-change');
      expect(find.textContaining('Frequency slot 20 stays'), findsOneWidget);
      await t.tap(find.byKey(const Key('rs-cancel')));
      await t.pumpAndSettle();
    });

    testWidgets('edits wait while a talk burst is going on', (t) async {
      final (c, fw, _) = await world(t, radioWith(loraAt(0)));
      c.transmitting = true;
      await openPage(t, c);
      expect(switchEnabled(t), isFalse);
      expect(fw.log, isEmpty);
      c.transmitting = false;
    });

    testWidgets('a failed write shows why and offers Restore', (t) async {
      final fw = radioWith(loraAt(0))..applySets = false;
      final (c, _, _) = await world(t, fw);
      await openPage(t, c);
      await tapKey(t, 'rs-relay');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(find.byKey(const Key('rs-failed')), findsOneWidget);
      expect(find.textContaining('frequency slot'), findsWidgets);
      expect(find.byKey(const Key('rs-restore-failed')), findsOneWidget);
    });
  });
}
