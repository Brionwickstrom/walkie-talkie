// v2.5.7: location precision per channel on the Radio settings page.
// Runs against the fake radio of the v2.5.3 tests, now with channels.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/lora/meshtastic_admin.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';

import 'v231_helpers.dart';
import 'v253_radio_settings_test.dart' show Fw, Saved, writer;

final bigKey = List<int>.generate(32, (i) => 100 + i);
final hikeKey = List<int>.generate(16, (i) => 50 + i);

/// A raw `Channel`: [prec] null = no module_settings at all.
Uint8List chan(
  int index,
  int role,
  String name,
  List<int> psk, {
  int? prec,
  bool muted = false,
}) {
  final settings = PbWriter()
    ..uint(1, 0)
    ..bytes(2, psk)
    ..string(3, name)
    ..fixed32(4, 0xCAFE)
    ..boolean(5, true);
  if (prec != null || muted) {
    final m = PbWriter();
    if (prec != null && prec != 0) m.uint(1, prec);
    if (muted) m.boolean(2, true);
    settings.message(7, m.toBytes());
  }
  return (PbWriter()
        ..uint(1, index)
        ..message(2, settings.toBytes())
        ..uint(3, role))
      .toBytes();
}

Fw threeChannels({int p0 = 13, int p1 = 13, int p2 = 0}) => Fw()
  ..channels[0] = chan(0, 1, 'BigfootNet', bigKey, prec: p0, muted: true)
  ..channels[1] = chan(1, 2, 'Hikers', hikeKey, prec: p1)
  ..channels[2] = chan(2, 2, 'Yowie', [1], prec: p2);

Uint8List settingsOf(Uint8List channel) => Uint8List.fromList(
  pbDecode(channel).firstWhere((f) => f.number == 2).asBytes,
);

int roleOf(Uint8List channel) =>
    pbDecode(channel).firstWhere((f) => f.number == 3).asInt;

void main() {
  group('levels and encode / decode', () {
    test('the Meshtastic levels, each with a plain line', () {
      expect(radioPrecisionLevels.map((l) => l.code), [
        0,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        32,
      ]);
      expect(radioPrecisionLevels.map((l) => l.label), [
        'Off',
        '~23 km',
        '~12 km',
        '~5.8 km',
        '~2.9 km',
        '~1.5 km',
        '~700 m',
        '~350 m',
        '~180 m',
        '~90 m',
        '~45 m',
        'Full (exact)',
      ]);
      for (final l in radioPrecisionLevels) {
        expect(l.hint, isNotEmpty);
      }
      expect(radioPrecisionText(13), '~2.9 km (13)');
      expect(radioPrecisionText(0), 'Off');
      expect(radioPrecisionText(32), 'Full (exact)');
      expect(radioPrecisionText(24), 'Custom (24 bits)');
      expect(validatePrecision(33), isNotNull);
      expect(validatePrecision(-1), isNotNull);
      expect(validatePrecision(32), isNull);
      expect(radioPrecisionNote, contains('Full shows your exact spot'));
    });

    test('ChannelPb reads role, name and precision; its text has no key', () {
      final c = ChannelPb.decode(chan(0, 1, 'BigfootNet', bigKey, prec: 13));
      expect(c.positionPrecision, 13);
      expect(c.isPrimary, isTrue);
      expect(c.name, 'BigfootNet');
      expect(c.toString(), isNot(contains('100')));
      expect(ChannelPb.decode(chan(1, 2, 'x', hikeKey)).positionPrecision, 0);
    });

    test('patching changes only the precision, everything else stays', () {
      final raw = settingsOf(
        chan(0, 1, 'BigfootNet', bigKey, prec: 13, muted: true),
      );
      expect(channelPrecisionOf(raw), 13);
      final out = patchChannelPrecision(raw, 32);
      expect(channelPrecisionOf(out), 32);
      Map<int, List<int>> rest(Uint8List b) => {
        for (final f in pbDecode(b))
          if (f.number != 7) f.number: f.wireType == 2 ? f.asBytes : [f.asInt],
      };
      expect(rest(out), rest(raw));
      // module_settings keeps its other field (is_client_muted = 2).
      final mod = pbDecode(out).firstWhere((f) => f.number == 7).asBytes;
      expect(pbDecode(mod).map((f) => f.number), containsAll([1, 2]));
      expect(patchChannelPrecision(out, 13), raw);
    });

    test(
      'a channel without module_settings gets one; Off on none is a no-op',
      () {
        final raw = settingsOf(chan(1, 2, 'Hikers', hikeKey));
        expect(channelPrecisionOf(raw), 0);
        expect(patchChannelPrecision(raw, 0), raw);
        final out = patchChannelPrecision(raw, 19);
        expect(channelPrecisionOf(out), 19);
        expect(pbDecode(out).map((f) => f.number), [2, 3, 4, 5, 7]);
        expect(channelPrecisionOf(patchChannelPrecision(out, 0)), 0);
      },
    );

    test('the session keeps each channel\'s precision', () async {
      final fw = threeChannels();
      final s = MeshtasticSession(fw);
      await s.start(timeout: const Duration(seconds: 2));
      addTearDown(s.close);
      expect(s.channels[0]!.positionPrecision, 13);
      expect(s.channels[1]!.positionPrecision, 13);
      expect(s.channels[2]!.positionPrecision, 0);
    });
  });

  group('writing', () {
    Future<(Fw, MeshtasticSession)> up(Fw fw) async {
      final s = MeshtasticSession(fw);
      await s.start(timeout: const Duration(seconds: 2));
      addTearDown(s.close);
      return (fw, s);
    }

    Map<int, List<int>> rest(Uint8List c) => {
      for (final f in pbDecode(settingsOf(c)))
        if (f.number != 7) f.number: f.wireType == 2 ? f.asBytes : [f.asInt],
    };

    test(
      'one secondary channel: one set_channel, role and key untouched',
      () async {
        final (fw, s) = await up(threeChannels());
        final before0 = fw.channels[0]!;
        final saved = Saved();
        final r = await writer(s)
            .apply(RadioChange.precisionOf(1, 32), saveBackup: saved.save);
        expect(r.after.channelPrecisions, {1: 32});
        expect(fw.writes, ['begin', 'set_channel1', 'commit']);
        expect(fw.commits, 1);
        expect(
          fw.log.where((l) => l.startsWith('REJECTED')),
          isEmpty,
          reason: 'the set carried the session key',
        );
        expect(channelPrecisionOf(settingsOf(fw.channels[1]!)), 32);
        expect(roleOf(fw.channels[1]!), 2);
        expect(
          fw.channels[0],
          before0,
          reason: 'other channels are not written',
        );
        expect(
          rest(fw.channels[1]!),
          rest(chan(1, 2, 'Hikers', hikeKey, prec: 13)),
        );
        expect(saved.backup!.previous.channelPrecisions, {1: 13});
      },
    );

    test('the main channel keeps its role and unknown module fields', () async {
      final (fw, s) = await up(threeChannels());
      await writer(s)
          .apply(RadioChange.precisionOf(0, 10), saveBackup: Saved().save);
      expect(roleOf(fw.channels[0]!), 1);
      final mod = pbDecode(settingsOf(fw.channels[0]!))
          .firstWhere((f) => f.number == 7)
          .asBytes;
      expect(pbDecode(mod).map((f) => f.number), containsAll([1, 2]));
      expect(channelPrecisionOf(settingsOf(fw.channels[0]!)), 10);
    });

    test('all channels in one edit, one commit', () async {
      final (fw, s) = await up(threeChannels());
      final r = await writer(s).apply(
        RadioChange.precisionAll([0, 1, 2], 32),
        saveBackup: Saved().save,
      );
      expect(r.after.channelPrecisions, {0: 32, 1: 32, 2: 32});
      expect(fw.writes, [
        'begin',
        'set_channel0',
        'set_channel1',
        'set_channel2',
        'commit',
      ]);
      for (final i in [0, 1, 2]) {
        expect(channelPrecisionOf(settingsOf(fw.channels[i]!)), 32);
      }
      expect(fw.commits, 1);
    });

    test('the backup keeps the old numbers; Restore puts them back', () async {
      final (fw, s) = await up(threeChannels());
      final saved = Saved();
      await writer(
        s,
      ).apply(RadioChange.precisionAll([0, 1, 2], 32), saveBackup: saved.save);
      final b = saved.backup!;
      expect(b.previous.channelPrecisions, {0: 13, 1: 13, 2: 0});
      expect(b.previous.summary, contains('location precision'));
      expect(b.previous.summary, contains('~2.9 km (13)'));
      await writer(s)
          .apply(RadioChange.restore(b.previous), saveBackup: Saved().save);
      expect(
        [
          for (final i in [0, 1, 2])
            channelPrecisionOf(settingsOf(fw.channels[i]!)),
        ],
        [13, 13, 0],
      );
      // The backup survives being stored as text.
      final round = RadioBackup.tryDecode(b.encode())!;
      expect(round.previous.channelPrecisions, {0: 13, 1: 13, 2: 0});
    });

    test('nothing about the key is stored or shown', () async {
      final (fw, s) = await up(threeChannels());
      final saved = Saved();
      final r = await writer(s)
          .apply(RadioChange.precisionAll([0, 1], 32), saveBackup: saved.save);
      final text =
          saved.backup!.encode() +
          saved.backup!.previous.summary +
          jsonEncode(r.after.toJson());
      for (final k in [bigKey, hikeKey]) {
        expect(text, isNot(contains(base64.encode(k))));
        expect(text, isNot(contains(k.join(','))));
      }
      expect(fw.writes, isNotEmpty);
    });

    test(
      'a value over 32 or a channel the radio does not have: nothing is sent',
      () async {
        final (fw, s) = await up(threeChannels());
        await expectLater(
          writer(s)
              .apply(RadioChange.precisionOf(1, 40), saveBackup: Saved().save),
          throwsA(isA<MeshWriteException>()),
        );
        await expectLater(
          writer(s)
              .apply(RadioChange.precisionOf(5, 32), saveBackup: Saved().save),
          throwsA(
            isA<MeshWriteException>().having(
              (e) => e.message,
              'message',
              contains('channel 6'),
            ),
          ),
        );
        expect(fw.writes, isEmpty);
        expect(fw.commits, 0);
      },
    );

    test('a radio that keeps the old value is reported', () async {
      final fw = threeChannels()..applySets = false;
      final (_, s) = await up(fw);
      final saved = Saved();
      await expectLater(
        writer(s).apply(RadioChange.precisionOf(1, 32), saveBackup: saved.save),
        throwsA(
          isA<MeshWriteException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('did not keep'),
              contains('location precision of channel 2'),
            ),
          ),
        ),
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

    testWidgets(
      'every channel is listed with its value, the note and the levels',
      (t) async {
        final (c, _, _) = await world(t, threeChannels());
        await openPage(t, c);
        expect(find.text('Location precision'), findsOneWidget);
        expect(find.byKey(const Key('rs-prec-note')), findsOneWidget);
        expect(
          find.textContaining(
            'Full shows your exact spot to everyone on the channel',
          ),
          findsOneWidget,
        );
        for (final i in [0, 1, 2]) {
          expect(find.byKey(Key('rs-prec-card-$i')), findsOneWidget);
        }
        expect(find.text('BigfootNet · main channel'), findsOneWidget);
        expect(find.text('Hikers · channel 2'), findsOneWidget);
        expect(find.text('Now: ~2.9 km (13)'), findsNWidgets(2));
        expect(find.text('Now: Off'), findsOneWidget);
        expect(find.text('Roughly which part of town.'), findsNWidgets(2));
        expect(
          find.text('Your position is not shared on this channel.'),
          findsOneWidget,
        );
        // The dropdown offers every level.
        await t.ensureVisible(find.byKey(const Key('rs-prec-0')));
        await t.tap(find.byKey(const Key('rs-prec-0')));
        await t.pumpAndSettle();
        for (final l in radioPrecisionLevels) {
          final text = l.code == 0 || l.code == 32
              ? l.label
              : '${l.label} (${l.code})';
          expect(find.text(text), findsWidgets, reason: l.label);
        }
        // No key anywhere on the page.
        expect(find.textContaining(base64.encode(bigKey)), findsNothing);
      },
    );

    testWidgets('the "not here" line no longer lists position precision', (
      t,
    ) async {
      final (c, _, _) = await world(t, threeChannels());
      await openPage(t, c);
      expect(radioNotHereText, isNot(contains('position precision')));
      expect(radioNotHereText, contains('position intervals'));
      expect(find.text(radioNotHereText), findsOneWidget);
    });

    testWidgets('Full (exact) is one tap: no question, only that channel', (
      t,
    ) async {
      final (c, fw, _) = await world(t, threeChannels());
      await openPage(t, c);
      await tapKey(t, 'rs-prec-full-2');
      expect(find.byKey(const Key('rs-confirm-dialog')), findsNothing);
      await settle(t);
      expect(fw.writes, ['begin', 'set_channel2', 'commit']);
      expect(channelPrecisionOf(settingsOf(fw.channels[2]!)), 32);
      expect(find.byKey(const Key('rs-saved')), findsOneWidget);
      expect(find.text('Now: Full (exact)'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('rs-prec-full-2')))
            .onPressed,
        isNull,
        reason: 'already full',
      );
    });

    testWidgets('a level from the list, then Save, writes that channel', (
      t,
    ) async {
      final (c, fw, _) = await world(t, threeChannels());
      await openPage(t, c);
      expect(
        t.widget<TextButton>(find.byKey(const Key('rs-prec-save-1'))).onPressed,
        isNull,
      );
      t
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const Key('rs-prec-1')),
          )
          .onChanged!(15);
      await t.pump();
      expect(find.text('A few streets around you.'), findsOneWidget);
      await tapKey(t, 'rs-prec-save-1');
      await settle(t);
      expect(fw.writes, ['begin', 'set_channel1', 'commit']);
      expect(channelPrecisionOf(settingsOf(fw.channels[1]!)), 15);
      expect(find.text('Now: ~700 m (15)'), findsOneWidget);
      expect(
        find.text('Now: ~2.9 km (13)'),
        findsOneWidget,
        reason: 'main untouched',
      );
    });

    testWidgets('Set all channels to Full: asks first, Cancel writes nothing', (
      t,
    ) async {
      final (c, fw, _) = await world(t, threeChannels(p1: 32));
      await openPage(t, c);
      await tapKey(t, 'rs-prec-all');
      expect(find.byKey(const Key('rs-confirm-dialog')), findsOneWidget);
      expect(find.text(radioPrecisionNote), findsWidgets);
      expect(
        find.text('BigfootNet: Full (exact), now ~2.9 km (13)'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Hikers: Full'),
        findsNothing,
        reason: 'already full',
      );
      expect(find.text('Yowie: Full (exact), now Off'), findsOneWidget);
      await t.tap(find.byKey(const Key('rs-cancel')));
      await t.pumpAndSettle();
      expect(fw.log, isEmpty);
      await tapKey(t, 'rs-prec-all');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(fw.writes, ['begin', 'set_channel0', 'set_channel2', 'commit']);
      for (final i in [0, 1, 2]) {
        expect(channelPrecisionOf(settingsOf(fw.channels[i]!)), 32);
      }
      expect(find.text('Now: Full (exact)'), findsNWidgets(3));
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('rs-prec-all')))
            .onPressed,
        isNull,
      );
      // Undo is offered and brings the old values back.
      expect(find.byKey(const Key('rs-restore')), findsOneWidget);
      await tapKey(t, 'rs-restore');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(
        [
          for (final i in [0, 1, 2])
            channelPrecisionOf(settingsOf(fw.channels[i]!)),
        ],
        [13, 32, 0],
      );
    });

    testWidgets(
      'a precision from another app is shown as custom and can be changed',
      (t) async {
        final (c, fw, _) = await world(t, threeChannels(p2: 24));
        await openPage(t, c);
        expect(find.text('Now: Custom (24 bits)'), findsOneWidget);
        await tapKey(t, 'rs-prec-full-2');
        await settle(t);
        expect(channelPrecisionOf(settingsOf(fw.channels[2]!)), 32);
      },
    );

    testWidgets('edits wait while a talk burst is going on', (t) async {
      final (c, fw, _) = await world(t, threeChannels());
      c.transmitting = true;
      await openPage(t, c);
      for (final k in ['rs-prec-full-0', 'rs-prec-save-0']) {
        final w = t.widget(find.byKey(Key(k)));
        expect(
          w is FilledButton ? w.onPressed : (w as TextButton).onPressed,
          isNull,
        );
      }
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('rs-prec-all')))
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<DropdownButtonFormField<int>>(
              find.byKey(const Key('rs-prec-0')),
            )
            .onChanged,
        isNull,
      );
      expect(fw.log, isEmpty);
      c.transmitting = false;
    });

    testWidgets('a failed write shows why and the channel keeps its value', (
      t,
    ) async {
      final fw = threeChannels()..applySets = false;
      final (c, _, _) = await world(t, fw);
      await openPage(t, c);
      await tapKey(t, 'rs-prec-full-1');
      await settle(t);
      expect(find.byKey(const Key('rs-failed')), findsOneWidget);
      expect(
        find.textContaining('location precision of channel 2'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('rs-restore-failed')), findsOneWidget);
    });

    testWidgets('no channels read yet: a plain line, no buttons', (t) async {
      final (c, _, _) = await world(t, Fw());
      await openPage(t, c);
      expect(find.byKey(const Key('rs-prec-none')), findsOneWidget);
      expect(find.byKey(const Key('rs-prec-all')), findsNothing);
    });
  });
}
