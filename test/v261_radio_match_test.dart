// v2.6.1: Radio match check on the Radio settings page.
// Fake radio of the v2.5.3 tests; nothing here has run on a real radio.
//   V261_SHOTS=/workspace flutter test test/v261_radio_match_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/lora/radio_match.dart';
import 'package:walkie_talkie/lora/saved_radios.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v253_radio_settings_test.dart' show Fw, fieldsExcept, loraRaw, writer;
import 'v257_precision_test.dart' show bigKey, chan, hikeKey, settingsOf;

final t0 = DateTime(2026, 10, 30, 20, 0);

RadioReading rd({
  int slot = 20,
  int hop = 4,
  int big = 32,
  int hike = 13,
  Duration ago = Duration.zero,
}) => RadioReading(
  at: t0.subtract(ago),
  slot: slot,
  hop: hop,
  precisions: {'BigfootNet': big, 'Hikers': hike},
);

MatchRadio mr(
  String name,
  RadioReading? r, {
  bool connected = false,
  bool home = false,
}) => MatchRadio(
  id: 'id-$name',
  name: name,
  connected: connected,
  reading: r,
  home: home,
);

/// A pretend Yowie: slot 0 (automatic), hop 4, BigfootNet precision 13.
Fw yowie({int slot = 0, int hop = 4, int big = 13}) => Fw()
  ..lora = patchVarints(loraRaw(hop: hop), {11: slot})
  ..channels[0] = chan(0, 1, 'BigfootNet', bigKey, prec: big)
  ..channels[1] = chan(1, 2, 'Hikers', hikeKey, prec: 13);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('comparing', () {
    final skunk = mr('Skunk Ape', rd(), home: true);

    test('the real case: Yowie on slot 0 and precision 13, the rest agree', () {
      final m = RadioMatch.compare([
        skunk,
        mr('Yowie', rd(slot: 0, big: 13), connected: true),
        mr('Yeti', rd(ago: const Duration(hours: 3))),
      ]);
      expect(m.target!.name, 'Skunk Ape', reason: 'home base is the default');
      expect(m.checked, 3);
      expect(m.allMatch, isFalse);
      expect(m.problems, [
        'Frequency slot: Yowie is on slot 0 (automatic), the others are on '
            'slot 20.',
        'Location precision of BigfootNet: Yowie is set to ~2.9 km (13), the '
            'others are set to Full (exact).',
      ]);
      final yowie = m.rows[1];
      expect(yowie.diffs.map((d) => d.field), ['slot', 'BigfootNet precision']);
      expect(yowie.diffs.first.have, '0 (automatic)');
      expect(yowie.diffs.first.want, '20');
      expect(m.rows[0].diffs, isEmpty);
      expect(m.rows[2].diffs, isEmpty);
    });

    test('everything matches: says what they share', () {
      final m = RadioMatch.compare([skunk, mr('Yowie', rd(), connected: true)]);
      expect(m.allMatch, isTrue);
      expect(m.problems, isEmpty);
      expect(
        m.targetSummary,
        'slot 20, hop limit 4, BigfootNet Full (exact), Hikers ~2.9 km (13)',
      );
    });

    test('hop limit differences are said in words', () {
      final m = RadioMatch.compare([
        skunk,
        mr('Yowie', rd(hop: 3)),
        mr('Yeti', rd(hop: 4)),
      ]);
      expect(m.problems, [
        'Hop limit: Yowie is set to 3, the others are set to 4.',
      ]);
    });

    test('two against two: each group is named', () {
      final m = RadioMatch.compare([
        mr('A', rd(slot: 20)),
        mr('B', rd(slot: 20)),
        mr('C', rd(slot: 0)),
        mr('D', rd(slot: 0)),
      ]);
      expect(m.problems.single, contains('A and B are on slot 20'));
      expect(m.problems.single, contains('C and D are on slot 0 (automatic)'));
    });

    test('a radio that was never read is "not checked", not a mismatch', () {
      final m = RadioMatch.compare([
        skunk,
        mr('Yowie', rd(), connected: true),
        mr('Yeti', null),
      ]);
      expect(m.checked, 2);
      expect(m.rows[2].checked, isFalse);
      expect(m.rows[2].diffs, isEmpty);
      expect(m.allMatch, isTrue);
    });

    test('fewer than two readings: nothing to compare', () {
      final m = RadioMatch.compare([mr('Yowie', rd(), connected: true)]);
      expect(m.allMatch, isFalse);
      expect(m.problems, isEmpty);
      expect(RadioMatch.compare([]).target, isNull);
    });

    test(
      'no home base read: the radio most others agree with is the target',
      () {
        final m = RadioMatch.compare([
          mr('A', rd(slot: 0)),
          mr('B', rd()),
          mr('C', rd()),
        ]);
        expect(m.target!.name, 'B', reason: 'B and C agree; B is first');
      },
    );

    test('a tie goes to the connected radio', () {
      final m = RadioMatch.compare([
        mr('A', rd(slot: 0)),
        mr('B', rd(), connected: true),
      ]);
      expect(m.target!.name, 'B');
    });

    test('the target can be picked', () {
      final m = RadioMatch.compare([
        skunk,
        mr('Yowie', rd(slot: 0, big: 13), connected: true),
      ], targetId: 'id-Yowie');
      expect(m.target!.name, 'Yowie');
      expect(m.rows[0].diffs, isNotEmpty);
      expect(m.rows[1].diffs, isEmpty);
    });

    test('channels only some radios have are not mismatches', () {
      final only = RadioReading(
        at: t0,
        slot: 20,
        hop: 4,
        precisions: const {'BigfootNet': 32},
      );
      final m = RadioMatch.compare([skunk, mr('Yeti', only)]);
      expect(m.problems, isEmpty);
    });

    test('unknown values (not read) are skipped', () {
      final partial = RadioReading(at: t0, precisions: const {});
      final m = RadioMatch.compare([skunk, mr('Yeti', partial)]);
      expect(m.problems, isEmpty);
      expect(m.rows[1].diffs, isEmpty);
    });
  });

  group('the fix', () {
    test('only what differs: slot, hop, one precision', () {
      final fix = matchFix(rd(slot: 0, hop: 3, big: 13), rd(), {
        'BigfootNet': 0,
        'Hikers': 1,
      })!;
      expect(fix.change.lora, {11: 20, 8: 4});
      expect(fix.change.channelPrecision, {0: 32});
      expect(fix.slot, isTrue);
      expect(fix.lines, [
        'Frequency slot: 0 (automatic) → 20',
        'Hop limit: 3 → 4',
        'Location precision of BigfootNet: ~2.9 km (13) → Full (exact)',
      ]);
    });

    test('precision only: no slot warning, no LoRa write', () {
      final fix = matchFix(rd(big: 13), rd(), {'BigfootNet': 0, 'Hikers': 1})!;
      expect(fix.slot, isFalse);
      expect(fix.change.touchesLora, isFalse);
      expect(fix.change.channelPrecision, {0: 32});
    });

    test('nothing differs, or a channel the radio lacks: no fix', () {
      expect(matchFix(rd(), rd(), {'BigfootNet': 0}), isNull);
      expect(matchFix(rd(big: 13), rd(), {'Hikers': 1}), isNull);
    });

    test('a slot of 0 is a valid target (automatic)', () {
      final fix = matchFix(rd(slot: 20), rd(slot: 0), {})!;
      expect(fix.change.lora, {11: 0});
    });
  });

  group('readings', () {
    test('json round trip keeps numbers and channel names only', () {
      final r = rd(ago: const Duration(hours: 2));
      final back = RadioReading.fromJson(r.toJson())!;
      expect(back.sameValues(r), isTrue);
      expect(back.at, r.at);
      final text = r.toJson().toString();
      expect(text, contains('BigfootNet'));
      expect(text.toLowerCase(), isNot(contains('psk')));
      expect(RadioReading.fromJson('x'), isNull);
      expect(RadioReading.fromJson({'slot': 1}), isNull);
    });

    test('a saved radio keeps its reading; old saves have none', () {
      final s = SavedRadio(id: 'AA', name: 'Yowie', reading: rd());
      final back = SavedRadio.decodeList(SavedRadio.encodeList([s])).single;
      expect(back.reading!.sameValues(rd()), isTrue);
      final old = SavedRadio.decodeList('[{"id":"AA","name":"Yowie"}]').single;
      expect(old.reading, isNull);
    });

    test('read from the session: slot, hop and the channels by name', () async {
      final fw = yowie(slot: 20, hop: 4, big: 32);
      final s = MeshtasticSession(fw);
      await s.start(timeout: const Duration(seconds: 2));
      addTearDown(s.close);
      final r = readingFromSession(s, t0)!;
      expect(r.slot, 20);
      expect(r.hop, 4);
      expect(r.precisions, {'BigfootNet': 32, 'Hikers': 13});
      expect(channelIndexByName(s), {'BigfootNet': 0, 'Hikers': 1});
    });
  });

  group('the page', () {
    Future<dynamic> world(
      WidgetTester t,
      Fw fw, {
      List<SavedRadio>? others,
      int h = 3600,
    }) async {
      phone(t, w: 400, h: h.toDouble(), ts: 1.0);
      final c = await makeController(t);
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      c.radioSettingsWriterFactory = () => writer(s);
      c.settings.savedRadios
        ..add(SavedRadio(id: 'AA:BB', name: 'Yowie', nodeId: Fw.myNode))
        ..addAll(
          others ??
              [
                SavedRadio(
                  id: 'serial:COM7',
                  name: 'Skunk Ape',
                  nodeId: 0x0b4f84fb,
                  reading: RadioReading(
                    at: DateTime.now().subtract(const Duration(hours: 5)),
                    slot: 20,
                    hop: 4,
                    precisions: const {'BigfootNet': 32, 'Hikers': 13},
                  ),
                ),
                SavedRadio(id: 'CC:DD', name: 'Yeti'),
                SavedRadio(
                  id: 'EE:FF',
                  name: 'Sasquatch',
                  reading: RadioReading(
                    at: DateTime.now().subtract(const Duration(hours: 3)),
                    slot: 20,
                    hop: 4,
                    precisions: const {'BigfootNet': 32, 'Hikers': 13},
                  ),
                ),
              ],
        );
      return c;
    }

    Future<void> openPage(WidgetTester t, dynamic c) async {
      await t.pumpWidget(
        MaterialApp(home: RadioSettingsPage(controller: c as dynamic)),
      );
      await t.pump();
    }

    Future<void> done(WidgetTester t) async {
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

    Finder inDialog(String s) => find.descendant(
      of: find.byKey(const Key('rs-confirm-dialog')),
      matching: find.text(s),
    );

    String text(WidgetTester t, String k) =>
        t.widget<Text>(find.byKey(Key(k))).data!;

    testWidgets('mismatches in plain words, rows with last-read times', (
      t,
    ) async {
      final c = await world(t, yowie());
      await openPage(t, c);
      expect(find.byKey(const Key('rs-match')), findsOneWidget);
      expect(text(t, 'rs-match-headline'), 'Your radios do not match.');
      final problems = [
        for (final w in t.widgetList<Text>(
          find.byKey(const Key('rs-match-problem')),
        ))
          w.data!,
      ];
      expect(problems, [
        '• Frequency slot: Yowie is on slot 0 (automatic), the others are on '
            'slot 20.',
        '• Location precision of BigfootNet: Yowie is set to ~2.9 km (13), '
            'the others are set to Full (exact).',
      ]);
      expect(find.text('Connected now, read just now'), findsOneWidget);
      expect(find.text('Skunk Ape · home base · reference'), findsOneWidget);
      expect(
        find.text('Not checked: not connected. Last read 5 h ago.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Never read: connect it once'),
        findsOneWidget,
      );
      expect(
        find.text('Different: slot is 0 (automatic), should be 20'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Slot 20 · Hop 4 · BigfootNet Full (exact) · Hikers ~2.9 km (13)',
        ),
        findsWidgets,
      );
      expect(
        find.textContaining('cannot read your other radios over the air'),
        findsOneWidget,
      );
      expect(find.text('Fix Yowie to match Skunk Ape'), findsOneWidget);
    });

    testWidgets('Fix: confirm with the all-radios warning, then writes', (
      t,
    ) async {
      final fw = yowie();
      final ch1 = Uint8List.fromList(fw.channels[1]!);
      final bigSettings = settingsOf(fw.channels[0]!);
      final c = await world(t, fw);
      await openPage(t, c);
      await tapKey(t, 'rs-match-fix');
      expect(find.byKey(const Key('rs-confirm-dialog')), findsOneWidget);
      expect(inDialog(radioRelayWarn), findsOneWidget);
      expect(find.text('Frequency slot: 0 (automatic) → 20'), findsOneWidget);
      expect(
        find.text(
          'Location precision of BigfootNet: ~2.9 km (13) → Full (exact)',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('must be switched to the same slot'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('rs-cancel')));
      await t.pumpAndSettle();
      expect(fw.log, isEmpty, reason: 'Cancel writes nothing');

      await tapKey(t, 'rs-match-fix');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await done(t);
      expect(find.byKey(const Key('rs-saved')), findsOneWidget);
      expect(fw.writes, ['begin', 'set_lora', 'set_channel0', 'commit']);
      expect(rawInt(fw.lora, 11), 20);
      expect(rawInt(fw.lora, 8), 4);
      expect(channelPrecisionOf(settingsOf(fw.channels[0]!)), 32);
      // Name and key of BigfootNet and the other channel are untouched.
      expect(
        fieldsExcept(settingsOf(fw.channels[0]!), {7}),
        fieldsExcept(bigSettings, {7}),
      );
      expect(fw.channels[1], ch1);
      expect(fw.log.where((l) => l.startsWith('REJECTED')), isEmpty);
      // The card now agrees.
      expect(
        text(t, 'rs-match-headline'),
        startsWith('All 3 checked radios match'),
      );
      expect(find.byKey(const Key('rs-match-fix')), findsNothing);
      // Restore previous settings is still offered (the backup was saved).
      expect(find.byKey(const Key('rs-restore')), findsOneWidget);
    });

    testWidgets('only a hop difference: no slot warning', (t) async {
      final fw = yowie(slot: 20, hop: 3, big: 32);
      final c = await world(t, fw);
      await openPage(t, c);
      await tapKey(t, 'rs-match-fix');
      expect(find.text('Hop limit: 3 → 4'), findsOneWidget);
      expect(inDialog(radioRelayWarn), findsNothing);
      expect(
        find.text(
          'Only this radio changes. Channel names and keys do not '
          'change.',
        ),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await done(t);
      expect(fw.writes, ['begin', 'set_lora', 'commit']);
      expect(rawInt(fw.lora, 8), 4);
      expect(rawInt(fw.lora, 11), 20);
    });

    testWidgets('a radio that does not keep it is reported with Restore', (
      t,
    ) async {
      final fw = yowie()..applySets = false;
      final c = await world(t, fw);
      await openPage(t, c);
      await tapKey(t, 'rs-match-fix');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await done(t);
      expect(find.byKey(const Key('rs-failed')), findsOneWidget);
      expect(find.byKey(const Key('rs-restore-failed')), findsOneWidget);
    });

    testWidgets(
      'the connected radio is the reference: says how to fix others',
      (t) async {
        final fw = yowie(slot: 20, hop: 4, big: 32);
        final c = await world(
          t,
          fw,
          others: [
            SavedRadio(
              id: 'serial:COM7',
              name: 'Skunk Ape',
              nodeId: 0x0b4f84fb,
              reading: rd(slot: 0, big: 13, ago: const Duration(hours: 1)),
            ),
          ],
        );
        c.settings.savedRadios.first.nodeId = 0x0b4f84fb; // Yowie is the home
        c.settings.savedRadios.last.nodeId = 7;
        await openPage(t, c);
        expect(find.byKey(const Key('rs-match-fix')), findsNothing);
        expect(
          find.textContaining('is the one the others should match'),
          findsOneWidget,
        );
      },
    );

    testWidgets('pick another reference radio', (t) async {
      final c = await world(t, yowie());
      await openPage(t, c);
      await t.ensureVisible(find.byKey(const Key('rs-match-target')));
      await t.tap(find.byKey(const Key('rs-match-target')));
      await t.pumpAndSettle();
      await t.tap(find.text('Sasquatch').last);
      await t.pumpAndSettle();
      expect(find.text('Fix Yowie to match Sasquatch'), findsOneWidget);
    });

    testWidgets('one radio only: asks to connect the others once', (t) async {
      final c = await world(t, yowie(), others: const []);
      await openPage(t, c);
      expect(text(t, 'rs-match-headline'), startsWith('Not enough to compare'));
      expect(find.byKey(const Key('rs-match-fix')), findsNothing);
    });

    testWidgets('Fix waits while a talk burst is going on', (t) async {
      final c = await world(t, yowie());
      c.transmitting = true;
      await openPage(t, c);
      final b = t.widget<FilledButton>(find.byKey(const Key('rs-match-fix')));
      expect(b.onPressed, isNull);
      c.transmitting = false;
    });

    testWidgets(
      'the connected radio\'s values are remembered when it connects',
      (t) async {
        final c = await world(
          t,
          yowie(slot: 20, hop: 4, big: 32),
          others: const [],
        );
        expect(c.settings.savedRadios.single.reading, isNull);
        c.noteRadioNow();
        final r = c.settings.savedRadios.single.reading as RadioReading;
        expect(r.slot, 20);
        expect(r.hop, 4);
        expect(r.precisions, {'BigfootNet': 32, 'Hikers': 13});
        // Same values again: the stored object is kept (no needless write).
        c.noteRadioNow();
        expect(c.settings.savedRadios.single.reading!.sameValues(r), isTrue);
      },
    );
  });

  group('screenshots', () {
    final dir = Platform.environment['V261_SHOTS'];
    if (dir == null) return;

    testWidgets('Radio settings with the match check', (t) async {
      phone(t, w: 400, h: 900, ts: 1.0);
      final c = await makeController(t);
      final s = MeshtasticSession(yowie());
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      final now = DateTime.now();
      RadioReading old(Duration ago, {int slot = 20, int big = 32}) =>
          RadioReading(
            at: now.subtract(ago),
            slot: slot,
            hop: 4,
            precisions: {'BigfootNet': big, 'Hikers': 13},
          );
      c.settings.savedRadios.addAll([
        SavedRadio(
          id: 'serial:COM7',
          name: 'Skunk Ape',
          nodeId: 0x0b4f84fb,
          reading: old(const Duration(hours: 5)),
        ),
        SavedRadio(id: 'AA:BB', name: 'Yowie', nodeId: Fw.myNode),
        SavedRadio(id: 'CC:DD', name: 'Yeti'),
        SavedRadio(
          id: 'EE:FF',
          name: 'Sasquatch',
          reading: old(const Duration(hours: 3)),
        ),
      ]);
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
      Future<void> shot(String name) async {
        final b = t.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('shotroot')),
        );
        await t.runAsync(() async {
          final img = await b.toImage(pixelRatio: 2);
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          File('$dir/v261_$name.png')
              .writeAsBytesSync(png!.buffer.asUint8List());
        });
      }

      await shot('card');
      await t.ensureVisible(find.byKey(const Key('rs-match-fix')));
      await t.tap(find.byKey(const Key('rs-match-fix')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await shot('confirm');
    });
  });
}
