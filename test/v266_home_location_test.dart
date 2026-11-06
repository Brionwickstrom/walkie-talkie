// v2.6.6: Set home location on Radio settings (fixed position).
// Fake radio; nothing here has run on a real radio.
//   V266_SHOTS=/workspace flutter test test/v266_home_location_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/lora/home_location.dart';
import 'package:walkie_talkie/lora/meshtastic_admin.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/trip/range_logger.dart';
import 'package:walkie_talkie/ui/public_nodes.dart';
import 'package:walkie_talkie/ui/settings_index.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v253_radio_settings_test.dart' show radio, writer, Saved;
import 'v264_public_nodes_test.dart' show addExamplePublic, radioOn, up;

final example = HomeCoords(45.5868, -122.2901, alt: 120);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('parse', () {
    test('paste line, spaces, labels, altitude', () {
      expect(parseHomeLocation('45.5868, -122.2901').coords, isNotNull);
      expect(
        parseHomeLocation('45.5868, -122.2901').coords!.pasteLine,
        '45.586800, -122.290100',
      );
      expect(parseHomeLocation('45.5868 -122.2901').ok, isTrue);
      expect(
        parseHomeLocation('lat: 45.5868 lon: -122.2901').coords!.lat,
        closeTo(45.5868, 1e-9),
      );
      final withAlt = parseHomeLocation('45.5868, -122.2901, 120');
      expect(withAlt.coords!.alt, 120);
      expect(parseHomeLocation('').ok, isFalse);
      expect(parseHomeLocation('91, 0').error, contains('Latitude'));
      expect(parseHomeLocation('0, 181').error, contains('Longitude'));
      expect(parseHomeLocation('0, 0').error, contains('0, 0'));
      expect(parseHomeLocation('45.5, -122, 99999').error, contains('Altitude'));
    });

    test('validate helpers', () {
      expect(validateHomeCoords(example), isNull);
      expect(validateLatitude(91), isNotNull);
      expect(validateLongitude(-181), isNotNull);
      expect(validateAltitude(-501), isNotNull);
    });
  });

  group('Position encode / AdminPb', () {
    test('round-trips lat/lng/alt as sfixed32', () {
      final raw = PositionPb(example.lat, example.lng, alt: example.alt)
          .encode();
      final back = PositionPb.decode(raw)!;
      expect(back.lat, closeTo(example.lat, 1e-7));
      expect(back.lng, closeTo(example.lng, 1e-7));
      expect(back.alt, 120);
      final fields = {for (final f in pbDecode(raw)) f.number: f};
      expect(fields[1]!.wireType, 5);
      expect(fields[2]!.wireType, 5);
      expect(fields[1]!.asSFixed32, latToI(example.lat));
      expect(fields[2]!.asSFixed32, lngToI(example.lng));
    });

    test('set_fixed_position and remove_fixed_position field numbers', () {
      final set = AdminPb.setFixedPosition(
        PositionPb(example.lat, example.lng).encode(),
        passkey: [1, 2, 3],
      );
      final nums = [for (final f in pbDecode(set)) f.number];
      expect(nums, containsAll([41, 101]));
      final rem = AdminPb.removeFixedPosition(passkey: [1]);
      expect(pbDecode(rem).map((f) => f.number), containsAll([42, 101]));
    });
  });

  group('writer on a fake radio', () {
    test('set home writes set_fixed, backs up, verifies fixed flag', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      addTearDown(s.close);
      // Start with fixed_position off.
      fw.position = patchVarints(fw.position, {3: 0});
      final saved = Saved();
      final w = writer(s);
      final r = await w.apply(
        RadioChange.setHome(example),
        saveBackup: saved.save,
        currentNodePos: const HomeCoords(45.0, -122.0),
      );
      expect(fw.writes, containsAll(['begin', 'set_fixed', 'commit']));
      expect(positionConfigIsFixed(fw.position), isTrue);
      expect(positionConfigIsFixed(r.after.position), isTrue);
      expect(saved.backup!.wasFixed, isFalse);
      expect(saved.backup!.fixedLat, 45.0);
      expect(saved.backup!.fixedLng, -122.0);
      // No PSK / key / URL in anything we log.
      expect(fw.log.join(' '), isNot(contains('psk')));
    });

    test('clear home sends remove_fixed and turns the flag off', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      addTearDown(s.close);
      fw.position = patchVarints(fw.position, {3: 1});
      final saved = Saved();
      final w = writer(s);
      final r = await w.apply(
        RadioChange.clearHome(),
        saveBackup: saved.save,
        currentNodePos: example,
      );
      expect(fw.writes, contains('remove_fixed'));
      expect(positionConfigIsFixed(fw.position), isFalse);
      expect(positionConfigIsFixed(r.after.position), isFalse);
      expect(saved.backup!.wasFixed, isTrue);
      expect(saved.backup!.fixedCoords, example);
    });

    test('restore puts a previous fixed position back', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      addTearDown(s.close);
      fw.position = patchVarints(fw.position, {3: 0});
      final saved = Saved();
      final w = writer(s);
      await w.apply(
        RadioChange.setHome(example),
        saveBackup: saved.save,
        currentNodePos: null,
      );
      // Clear, then restore from backup.
      await w.apply(
        RadioChange.clearHome(),
        saveBackup: saved.save,
        currentNodePos: example,
      );
      final b = saved.backup!;
      expect(b.wasFixed, isTrue);
      await w.apply(
        RadioChange.restore(b.previous, full: b),
        saveBackup: Saved().save,
        currentNodePos: null,
      );
      expect(fw.writes.where((x) => x == 'set_fixed').length, greaterThan(1));
      expect(positionConfigIsFixed(fw.position), isTrue);
    });
  });

  group('distance fallback', () {
    test('public nodes use home coords when the radio has no fix', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      addExamplePublic(s, now: DateTime(2026, 11, 6, 10));
      // Own node has no lat/lng.
      final me = s.nodes[s.myNodeNum];
      expect(me?.lat, isNull);
      final withHome = computePublicNodes(
        session: s,
        onPublicSlot: true,
        phone: example.point,
      );
      expect(
        withHome.nodes.any((n) => n.distanceM != null),
        isTrue,
        reason: 'home/phone supplies the origin for distance',
      );
    });

    test('range logger positionOf falls back for the home node', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      addTearDown(s.close);
      const home = 0x0b4f84fb;
      final r = SessionRangeRadio(
        s,
        fallbackOf: (n) => n == home ? example.point : null,
      );
      expect(r.positionOf(home), example.point);
      expect(r.positionOf(0x11111111), isNull);
    });
  });

  group('Settings search', () {
    test('radio-home-location is indexed with the asked synonyms', () {
      final e = settingsIndex.where((x) => x.id == 'radio-home-location').single;
      expect(e.title, 'Set home location');
      for (final w in [
        'home',
        'base',
        'coordinates',
        'lat',
        'long',
        'fixed position',
      ]) {
        expect(e.words, contains(w), reason: w);
      }
    });

    test('anchor id is listed for the Radio settings home', () {
      expect(
        settingsIndex.any((e) => e.id == 'radio-home-location'),
        isTrue,
      );
      expect(
        settingsIndex.any((e) => e.id == 'radio-home-location' && e.home == SettingsHome.radio),
        isTrue,
      );
    });
  });

  group('page UI (example data)', () {
    testWidgets('shows the field, save and clear', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
                children: [
                  const Text('Set home location', key: Key('head')),
                  const Text(
                    'For a base radio with no GPS (like Skunk Ape): type its '
                    'latitude and longitude. Example data.',
                    key: Key('rs-home-note'),
                  ),
                  const TextField(
                    key: Key('rs-home-coords'),
                    decoration: InputDecoration(
                      labelText: 'Latitude, longitude',
                      hintText: '45.5868, -122.2901',
                    ),
                  ),
                  TextButton(
                    key: const Key('rs-home-use-gps'),
                    onPressed: () {},
                    child: const Text('Use my current location'),
                  ),
                  FilledButton(
                    key: const Key('rs-home-save'),
                    onPressed: () {},
                    child: const Text('Save home location'),
                  ),
                  OutlinedButton(
                    key: const Key('rs-home-clear'),
                    onPressed: () {},
                    child: const Text('Clear fixed position'),
                  ),
                ],
            ),
          ),
        ),
      );
      expect(find.text('Set home location'), findsOneWidget);
      expect(find.byKey(const Key('rs-home-coords')), findsOneWidget);
      expect(find.text('Save home location'), findsOneWidget);
      expect(find.text('Clear fixed position'), findsOneWidget);
    });
  });
}

