// v2.5.3: a basic Radio settings page for the paired Meshtastic radio.
// Everything runs against a fake radio that answers admin messages like the
// firmware does (session key, begin / set / commit, restart); nothing here
// has run on a real radio.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/lora/meshtastic_admin.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/ui/radio_settings.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';

import 'v231_helpers.dart';

// ------------------------------------------------------------ the radio

Uint8List loraRaw({int region = 1, int preset = 0, int hop = 3}) =>
    (PbWriter()
          ..boolean(1, true)
          ..uint(2, preset)
          ..uint(7, region)
          ..uint(8, hop)
          ..boolean(9, true)
          ..uint(10, 27)
          ..uint(11, 20)
          ..boolean(13, true)
          ..fixed32(14, 0x4C6A5400)
          ..bytes(103, const [1, 2, 3]))
        .toBytes();

Uint8List positionRaw({int secs = 900, bool smart = true}) =>
    (PbWriter()
          ..uint(1, secs)
          ..boolean(2, smart)
          ..boolean(3, true)
          ..uint(7, 811)
          ..uint(10, 100)
          ..uint(13, 1))
        .toBytes();

final ownerKey = List<int>.generate(32, (i) => 200 - i);

Uint8List ownerRaw({String long = 'Ridge phone', String short = 'RDG'}) =>
    (PbWriter()
          ..string(1, '!1234abcd')
          ..string(2, long)
          ..string(3, short)
          ..uint(5, 9)
          ..bytes(8, ownerKey))
        .toBytes();

/// A Meshtastic radio's client API as the firmware answers it: config
/// download, AdminModule get_config / get_owner (with a session key),
/// begin / set_owner / set_config / commit, and the restart after a commit.
class Fw implements MeshtasticWire {
  Fw({
    this.rebootOnCommit = true,
    this.applySets = true,
    this.requireKey = true,
  });

  static const myNode = 0x1234ABCD;
  final bool rebootOnCommit;

  /// false: the radio quietly keeps what it had (to test the read back).
  bool applySets;
  final bool requireKey;

  Uint8List lora = loraRaw();
  Uint8List position = positionRaw();
  Uint8List owner = ownerRaw();
  final passkey = Uint8List.fromList([9, 8, 7, 6, 5, 4, 3, 2]);

  /// What the app sent, in order: 'get:lora', 'begin', 'set_lora', ...
  final log = <String>[];

  /// The raw bytes of what was sent per set.
  Uint8List? sentOwner, sentLora, sentPosition;
  final packets = <MeshPacketPb>[];
  int commits = 0;
  bool _open = false;
  Uint8List? _pLora, _pPos, _pOwner;
  final _queue = <Uint8List>[];
  final _notify = StreamController<void>.broadcast();

  void _push(void Function(PbWriter w) f) {
    final w = PbWriter();
    f(w);
    _queue.add(w.toBytes());
  }

  void _serveConfig(int nonce) {
    _push((w) => w.message(3, (PbWriter()..uint(1, myNode)).toBytes()));
    _push(
      (w) => w.message(
        4,
        (PbWriter()
              ..uint(1, myNode)
              ..message(2, owner))
            .toBytes(),
      ),
    );
    _push((w) => w.message(5, (PbWriter()..message(6, lora)).toBytes()));
    _push((w) => w.message(5, (PbWriter()..message(2, position)).toBytes()));
    _push((w) => w.uint(7, nonce));
  }

  void _reply(void Function(PbWriter w) f, {bool key = true}) {
    final w = PbWriter();
    f(w);
    if (key) w.bytes(101, passkey);
    final pkt = MeshPacketPb(
      from: myNode,
      to: myNode,
      decoded: MeshData(portnum: PortNum.admin, payload: w.toBytes()),
    );
    _push((x) => x.message(2, pkt.encode()));
  }

  @override
  Future<void> write(Uint8List toRadio) async {
    for (final f in pbDecode(toRadio)) {
      if (f.number == 3) _serveConfig(f.asInt);
      if (f.number == 1) {
        final p = MeshPacketPb.decode(f.asBytes);
        packets.add(p);
        _onPacket(p);
      }
    }
    _notify.add(null);
  }

  void _onPacket(MeshPacketPb p) {
    final d = p.decoded;
    if (d == null || d.portnum != PortNum.admin) return;
    final fields = pbDecode(d.payload);
    final hasKey = fields.any(
      (f) => f.number == 101 && f.asBytes.length == passkey.length,
    );
    final first = fields.firstWhere((f) => f.number != 101);
    final isSet = {32, 34, 64, 65}.contains(first.number);
    if (isSet && requireKey && !hasKey) {
      log.add('REJECTED:${first.number}');
      return;
    }
    switch (first.number) {
      case 3:
        log.add('get:owner');
        _reply((w) => w.message(4, owner));
      case 5:
        final t = first.asInt;
        if (t == AdminPb.configLora) {
          log.add('get:lora');
          _reply((w) => w.message(6, (PbWriter()..message(6, lora)).toBytes()));
        } else if (t == AdminPb.configPosition) {
          log.add('get:position');
          _reply(
            (w) => w.message(6, (PbWriter()..message(2, position)).toBytes()),
          );
        } else {
          log.add('get:key');
          _reply((w) {});
        }
      case 64:
        log.add('begin');
        _open = true;
        _pLora = _pPos = _pOwner = null;
      case 32:
        log.add('set_owner');
        sentOwner = Uint8List.fromList(first.asBytes);
        // The firmware takes the names (when not empty), nothing else.
        var next = owner;
        String? l, s;
        for (final u in pbDecode(first.asBytes)) {
          if (u.number == 2 && u.asString.isNotEmpty) l = u.asString;
          if (u.number == 3 && u.asString.isNotEmpty) s = u.asString;
        }
        next = patchNames(next, longName: l, shortName: s);
        _pOwner = next;
      case 34:
        for (final c in pbDecode(first.asBytes)) {
          if (c.number == 6) {
            log.add('set_lora');
            sentLora = Uint8List.fromList(c.asBytes);
            _pLora = sentLora;
          }
          if (c.number == 2) {
            log.add('set_position');
            sentPosition = Uint8List.fromList(c.asBytes);
            _pPos = sentPosition;
          }
        }
      case 65:
        log.add('commit');
        _open = false;
        commits++;
        if (applySets) {
          if (_pLora != null) lora = _pLora!;
          if (_pPos != null) position = _pPos!;
          if (_pOwner != null) owner = _pOwner!;
        }
        if (rebootOnCommit && _pLora != null) {
          _push((w) => w.boolean(8, true));
        }
    }
  }

  bool get editOpen => _open;

  @override
  Future<Uint8List> read() async =>
      _queue.isEmpty ? Uint8List(0) : _queue.removeAt(0);

  @override
  Stream<void> get notifications => _notify.stream;

  /// Everything sent that changes something.
  List<String> get writes => log.where((l) => !l.startsWith('get:')).toList();
}

Future<(Fw, MeshtasticSession)> radio({
  bool rebootOnCommit = true,
  bool applySets = true,
}) async {
  final fw = Fw(rebootOnCommit: rebootOnCommit, applySets: applySets);
  final s = MeshtasticSession(fw);
  await s.start(timeout: const Duration(seconds: 2));
  return (fw, s);
}

RadioSettingsWriter writer(MeshtasticSession s) => RadioSettingsWriter(
  () => s,
  replyTimeout: const Duration(seconds: 1),
  rebootWait: const Duration(milliseconds: 200),
  quickWait: const Duration(milliseconds: 200),
  reconnectTimeout: const Duration(seconds: 5),
  poll: const Duration(milliseconds: 10),
  writeGap: Duration.zero,
);

/// Fields of [raw] as number -> raw field values.
Map<int, List<Object>> fieldsOf(Uint8List raw) {
  final m = <int, List<Object>>{};
  for (final f in pbDecode(raw)) {
    (m[f.number] ??= []).add(f.wireType == 2 ? f.asBytes.toList() : f.asInt);
  }
  return m;
}

/// [raw] with the [skip] fields dropped, for "everything else is the same".
Map<int, List<Object>> fieldsExcept(Uint8List raw, Set<int> skip) =>
    fieldsOf(raw)..removeWhere((k, v) => skip.contains(k));

class Saved {
  RadioBackup? backup;
  Future<void> save(RadioBackup b) async => backup = b;
}

// ----------------------------------------------------------------- tests

void main() {
  group('validation and lists', () {
    test('long name: 1-39 bytes, no control characters', () {
      expect(validateLongName('Ridge phone'), isNull);
      expect(validateLongName('  '), isNotNull);
      expect(validateLongName('a' * 39), isNull);
      expect(validateLongName('a' * 40), isNotNull);
      expect(validateLongName('é' * 20), isNotNull, reason: '40 bytes');
      expect(validateLongName('bad\nname'), isNotNull);
    });

    test('short name: 1-4 characters', () {
      expect(validateShortName('RDG'), isNull);
      expect(validateShortName('R2D2'), isNull);
      expect(validateShortName(''), isNotNull);
      expect(validateShortName('ABCDE'), isNotNull);
      expect(validateShortName('A\tB'), isNotNull);
    });

    test('hop limit 0-7', () {
      for (var h = 0; h <= 7; h++) {
        expect(validateHopLimit(h), isNull);
      }
      expect(validateHopLimit(-1), isNotNull);
      expect(validateHopLimit(8), isNotNull);
    });

    test('the region list is complete and both name tables agree', () {
      final codes = {for (final r in radioRegions) r.code};
      expect(codes, {for (var i = 1; i <= 26; i++) i});
      for (var i = 1; i <= 26; i++) {
        expect(regionName(i), isNot(startsWith('region')), reason: '$i');
        expect(meshRegionLabel(i), isNot(startsWith('Region ')), reason: '$i');
        expect(radioRegionText(i), isNotEmpty);
      }
      // What was there before is unchanged.
      expect(regionName(0), 'not set');
      expect(regionName(1), 'US 915');
      expect(regionName(3), 'EU 868');
      expect(regionName(6), 'ANZ');
      expect(regionName(99), 'region 99');
      expect(radioRegionText(0), 'Not set');
    });

    test('speed presets: no custom speed, names match the firmware', () {
      expect(
        {for (final p in radioPresets) p.code},
        {0, 1, 3, 4, 5, 6, 7, 8, 9},
      );
      expect(radioPresetText(0), contains('LongFast'));
      expect(radioPresetText(0, usePreset: false), 'Custom speed');
    });

    test('the confirm text is the one asked for', () {
      expect(
        radioConfirmText,
        'All radios in your group must use the same region and speed, or '
        'they can\'t hear each other. Region must match where you are by '
        'law.',
      );
    });
  });

  group('copying a config byte for byte', () {
    test('only the chosen field changes; the rest is copied as it was', () {
      final raw = loraRaw();
      final out = patchVarints(raw, {7: 3});
      expect(rawInt(out, 7), 3);
      expect(fieldsExcept(out, {7}), fieldsExcept(raw, {7}));
      // Order kept (region is still where it was).
      expect(
        [for (final f in pbDecode(out)) f.number],
        [for (final f in pbDecode(raw)) f.number],
      );
    });

    test('setting the values it already has gives the same bytes', () {
      final raw = loraRaw();
      expect(patchVarints(raw, {7: 1, 8: 3, 2: 0, 1: 1}), raw);
      final pos = positionRaw();
      expect(patchVarints(pos, {1: 900, 2: 1}), pos);
    });

    test('zero removes the field (proto3), a missing field is added', () {
      final out = patchVarints(loraRaw(), {8: 0, 12: 1});
      expect(rawInt(out, 8), 0);
      expect(fieldsOf(out).containsKey(8), isFalse);
      expect(rawInt(out, 12), 1);
    });

    test('names: id, hardware and the public key come back as read', () {
      final raw = ownerRaw();
      final out = patchNames(raw, longName: 'Camp', shortName: 'CMP');
      expect(rawString(out, 2), 'Camp');
      expect(rawString(out, 3), 'CMP');
      expect(fieldsExcept(out, {2, 3}), fieldsExcept(raw, {2, 3}));
      expect(patchNames(raw, longName: 'Ridge phone'), raw);
    });

    test('admin messages: set_owner 32, set_config position, get_owner', () {
      final key = [1, 2, 3, 4, 5, 6, 7, 8];
      final so = pbDecode(AdminPb.setOwner(ownerRaw(), passkey: key));
      expect([for (final f in so) f.number], [32, 101]);
      final sp = pbDecode(
        AdminPb.setPositionConfig(positionRaw(), passkey: key),
      );
      expect(sp.first.number, 34);
      expect(pbDecode(sp.first.asBytes).single.number, 2);
      expect(pbDecode(AdminPb.getOwner()).single.number, 3);
      final r = AdminReply.tryDecode(
        (PbWriter()
              ..message(4, ownerRaw())
              ..bytes(101, key))
            .toBytes(),
      )!;
      expect(r.owner, ownerRaw());
      expect(r.passkey, key);
    });

    test('the config download now also tells the position interval', () async {
      final (fw, s) = await radio();
      addTearDown(s.close);
      expect(s.positionSecs, 900);
      expect(s.positionSmart, isTrue);
      expect(s.hopLimit, 3);
      expect(s.nodes[Fw.myNode]!.longName, 'Ridge phone');
      expect(fw.log, isEmpty, reason: 'nothing was asked for');
    });
  });

  group('writing settings (mocked admin round trips)', () {
    test(
      'hop limit: reads, saves the backup, then begin / set / commit',
      () async {
        final (fw, s) = await radio();
        addTearDown(s.close);
        final saved = Saved();
        final before = Uint8List.fromList(fw.lora);
        final steps = <MeshWriteStep>[];
        final r = await writer(s).apply(
          RadioChange.hop(5),
          saveBackup: (b) async {
            // Nothing written yet when the backup is stored.
            expect(fw.writes, isEmpty);
            expect(fw.commits, 0);
            await saved.save(b);
          },
          onStep: steps.add,
        );
        expect(fw.writes, ['begin', 'set_lora', 'commit']);
        expect(fw.log.first, startsWith('get:'));
        expect(
          fw.log.where((l) => l.startsWith('REJECTED')),
          isEmpty,
          reason: 'every set carried the session key',
        );
        expect(fw.commits, 1);
        expect(rawInt(fw.lora, 8), 5);
        expect(fieldsExcept(fw.lora, {8}), fieldsExcept(before, {8}));
        expect(saved.backup!.previous.lora, before);
        expect(saved.backup!.previous.hopLimit, 3);
        expect(r.after.hopLimit, 5);
        expect(s.hopLimit, 5, reason: 'the session read the new config');
        expect(
          steps,
          containsAllInOrder([
            MeshWriteStep.preparing,
            MeshWriteStep.writing,
            MeshWriteStep.restarting,
            MeshWriteStep.verifying,
            MeshWriteStep.done,
          ]),
        );
      },
    );

    test(
      'names go with set_owner; id, hardware and key are sent back as read',
      () async {
        final (fw, s) = await radio(rebootOnCommit: false);
        addTearDown(s.close);
        final owner0 = Uint8List.fromList(fw.owner);
        await writer(s).apply(
          RadioChange.names(longName: ' Camp radio ', shortName: 'CMP'),
          saveBackup: Saved().save,
        );
        expect(fw.writes, ['begin', 'set_owner', 'commit']);
        expect(rawString(fw.owner, 2), 'Camp radio');
        expect(rawString(fw.owner, 3), 'CMP');
        expect(
          fieldsExcept(fw.sentOwner!, {2, 3}),
          fieldsExcept(owner0, {2, 3}),
        );
        expect(fieldsExcept(fw.owner, {2, 3}), fieldsExcept(owner0, {2, 3}));
        expect(fw.lora, loraRaw(), reason: 'LoRa untouched');
        expect(fw.position, positionRaw());
      },
    );

    test('region: only the region field changes, the radio restarts', () async {
      final (fw, s) = await radio();
      addTearDown(s.close);
      await writer(s).apply(RadioChange.region(3), saveBackup: Saved().save);
      expect(fw.writes, ['begin', 'set_lora', 'commit']);
      expect(rawInt(fw.lora, 7), 3);
      expect(fieldsExcept(fw.lora, {7}), fieldsExcept(loraRaw(), {7}));
      expect(fw.sentLora, fw.lora);
      expect(s.region, 3);
      expect(s.rebootCount, greaterThan(0));
    });

    test(
      'speed: use_preset on and the preset; the other fields stay',
      () async {
        final (fw, s) = await radio();
        addTearDown(s.close);
        await writer(s).apply(RadioChange.preset(4), saveBackup: Saved().save);
        expect(rawInt(fw.lora, 2), 4);
        expect(rawInt(fw.lora, 1), 1);
        expect(fieldsExcept(fw.lora, {1, 2}), fieldsExcept(loraRaw(), {1, 2}));
        expect(s.modemPreset, 4);
      },
    );

    test('location sharing off: never on a timer, nothing else in the position config moves', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      addTearDown(s.close);
      final saved = Saved();
      await writer(s).apply(RadioChange.sharingOff(), saveBackup: saved.save);
      expect(fw.writes, ['begin', 'set_position', 'commit']);
      expect(rawInt(fw.position, 1), posNever);
      expect(rawInt(fw.position, 2), 0);
      expect(
        fieldsExcept(fw.position, {1, 2}),
        fieldsExcept(positionRaw(), {1, 2}),
        reason: 'flags, GPS mode, distances stay',
      );
      expect(locationSharingOn(s.positionSecs, s.positionSmart), isFalse);
      expect(saved.backup!.sharingSecs, 900);
      expect(saved.backup!.sharingSmart, isTrue);
    });

    test('location sharing on again puts the previous interval and flags back, even after other edits', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      addTearDown(s.close);
      final saved = Saved();
      final w = writer(s);
      await w.apply(RadioChange.sharingOff(), saveBackup: saved.save);
      // An unrelated edit in between: the "on" interval is remembered.
      await w.apply(
        RadioChange.names(longName: 'Later'),
        previousBackup: saved.backup,
        saveBackup: saved.save,
      );
      expect(saved.backup!.sharingSecs, 900);
      await w.apply(
        RadioChange.sharingOn(
          secs: saved.backup!.sharingSecs,
          smart: saved.backup!.sharingSmart,
        ),
        previousBackup: saved.backup,
        saveBackup: saved.save,
      );
      expect(fw.position, positionRaw());
      expect(locationSharingOn(s.positionSecs, s.positionSmart), isTrue);
    });

    test('turning sharing on with nothing remembered: the firmware default interval', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      addTearDown(s.close);
      fw.position = positionRaw(secs: posNever, smart: false);
      await s.requestConfig();
      await writer(s).apply(RadioChange.sharingOn(), saveBackup: Saved().save);
      expect(rawInt(fw.position, 1), 0, reason: '0 = the radio\'s default');
      expect(rawInt(fw.position, 2), 1);
      expect(locationSharingOn(rawInt(fw.position, 1), true), isTrue);
    });

    test('several fields in one commit', () async {
      final (fw, s) = await radio();
      addTearDown(s.close);
      await writer(s).apply(
        const RadioChange(
          longName: 'Both',
          lora: {8: 2, 7: 3},
          position: {1: posNever, 2: 0},
        ),
        saveBackup: Saved().save,
      );
      expect(fw.writes, [
        'begin',
        'set_owner',
        'set_lora',
        'set_position',
        'commit',
      ]);
      expect(fw.commits, 1);
    });

    test('nothing is written when the backup cannot be saved', () async {
      final (fw, s) = await radio();
      addTearDown(s.close);
      await expectLater(
        writer(s).apply(
          RadioChange.hop(1),
          saveBackup: (_) async => throw StateError('disk full'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(fw.writes, isEmpty);
      expect(fw.lora, loraRaw());
    });

    test('a radio that does not answer: nothing is written', () async {
      final fw = Fw();
      final silent = _SilentSession(fw);
      await silent.start(timeout: const Duration(seconds: 2));
      addTearDown(silent.close);
      await expectLater(
        RadioSettingsWriter(
          () => silent,
          replyTimeout: const Duration(milliseconds: 100),
          writeGap: Duration.zero,
        ).apply(RadioChange.hop(1), saveBackup: Saved().save),
        throwsA(isA<MeshWriteException>()),
      );
      expect(fw.writes, isEmpty);
    });

    test('read back does not match: a clear failure, backup kept', () async {
      final (fw, s) = await radio(applySets: false);
      addTearDown(s.close);
      final saved = Saved();
      await expectLater(
        writer(s).apply(RadioChange.region(3), saveBackup: saved.save),
        throwsA(
          isA<MeshWriteException>().having(
            (e) => e.message,
            'message',
            allOf(contains('did not keep'), contains('region')),
          ),
        ),
      );
      expect(saved.backup, isNotNull);
      expect(saved.backup!.previous.region, 1);
    });

    test('verify names each field the radio did not keep', () {
      final now = RadioSnapshot(
        node: 1,
        at: DateTime(2026),
        lora: loraRaw(),
        position: positionRaw(),
        owner: ownerRaw(),
      );
      expect(RadioSettingsWriter.verify(RadioChange.region(1), now), isEmpty);
      expect(RadioSettingsWriter.verify(RadioChange.region(3), now), [
        'the region',
      ]);
      expect(RadioSettingsWriter.verify(RadioChange.hop(4), now), [
        'the hop limit',
      ]);
      expect(RadioSettingsWriter.verify(RadioChange.preset(5), now), [
        'the speed',
      ]);
      expect(RadioSettingsWriter.verify(RadioChange.sharingOff(), now), [
        'location sharing',
      ]);
      expect(
        RadioSettingsWriter.verify(
          RadioChange.names(longName: 'x', shortName: 'RDG'),
          now,
        ),
        ['the long name'],
      );
    });
  });

  group('restore previous settings', () {
    test(
      'writes back region, speed, hop, names and position as they were',
      () async {
        final (fw, s) = await radio();
        addTearDown(s.close);
        final saved = Saved();
        final w = writer(s);
        await w.apply(RadioChange.region(3), saveBackup: saved.save);
        await w.apply(
          RadioChange.hop(6),
          previousBackup: saved.backup,
          saveBackup: saved.save,
        );
        // The backup is of the state before the LAST change; take the first.
        final first = Saved();
        final (fw2, s2) = await radio();
        addTearDown(s2.close);
        final w2 = writer(s2);
        await w2.apply(
          const RadioChange(
            longName: 'Changed',
            shortName: 'CHG',
            lora: {7: 3, 8: 6, 1: 1, 2: 4},
            position: {1: posNever, 2: 0},
          ),
          saveBackup: first.save,
        );
        expect(fw2.lora, isNot(loraRaw()));
        await w2.apply(
          RadioChange.restore(first.backup!.previous),
          saveBackup: (_) async {},
        );
        expect(fw2.lora, loraRaw(), reason: 'back, byte for byte');
        expect(fw2.position, positionRaw());
        expect(fw2.owner, ownerRaw());
        expect(fw, isNotNull);
      },
    );

    test(
      'keeps what the user changed elsewhere (Meshtastic app) in the meantime',
      () async {
        final (fw, s) = await radio();
        addTearDown(s.close);
        final saved = Saved();
        await writer(s).apply(RadioChange.region(3), saveBackup: saved.save);
        // Transmit power changed in the Meshtastic app afterwards.
        fw.lora = patchVarints(fw.lora, {10: 14});
        await s.requestConfig();
        await writer(s).apply(
          RadioChange.restore(saved.backup!.previous),
          saveBackup: (_) async {},
        );
        expect(rawInt(fw.lora, 7), 1);
        expect(rawInt(fw.lora, 10), 14);
      },
    );

    test('a backup survives storage (JSON) and ignores junk', () async {
      final (_, s) = await radio();
      addTearDown(s.close);
      final saved = Saved();
      await writer(s).apply(RadioChange.hop(2), saveBackup: saved.save);
      final again = RadioBackup.tryDecode(saved.backup!.encode())!;
      expect(again.previous.lora, loraRaw());
      expect(again.previous.position, positionRaw());
      expect(again.previous.owner, ownerRaw());
      expect(again.previous.node, Fw.myNode);
      expect(again.sharingSecs, 900);
      expect(RadioBackup.tryDecode('nope'), isNull);
      expect(RadioBackup.tryDecode(null), isNull);
      expect(RadioBackup.tryDecode('{"previous":{}}'), isNull);
      expect(again.previous.summary, contains('hop limit 3'));
    });
  });

  group('hop limit 0 is honoured', () {
    test(
      'packets from the app use the radio\'s hop limit; 3 until it told us',
      () async {
        final fw = Fw();
        final s = MeshtasticSession(fw);
        // Before the config download the default is 3.
        await s.send(Uint8List.fromList([1]));
        expect(fw.packets.last.hopLimit, 3);
        await s.start(timeout: const Duration(seconds: 2));
        addTearDown(s.close);
        await s.send(Uint8List.fromList([1]));
        expect(fw.packets.last.hopLimit, 3);
        fw.lora = loraRaw(hop: 0);
        await s.requestConfig();
        expect(s.hopLimit, 0);
        await s.send(Uint8List.fromList([1]));
        expect(fw.packets.last.hopLimit, 0, reason: 'direct only, as set');
        await s.send(Uint8List.fromList([1]), hopLimitOverride: 3);
        expect(fw.packets.last.hopLimit, 3, reason: 'alerts still use 3');
      },
    );
  });

  group('the page', () {
    Future<(dynamic, Fw, MeshtasticSession)> world(
      WidgetTester t, {
      bool connected = true,
      Fw? fw0,
    }) async {
      phone(t, w: 400, h: 3200, ts: 1.0);
      final c = await makeController(t);
      final fw = fw0 ?? Fw();
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      if (connected) {
        c.radioDevice
          ..deviceId = 'AA:BB'
          ..deviceName = 'RAK WisMesh'
          ..state = RadioState.ready
          ..session = s;
      }
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

    testWidgets('summary on top, controls below, the "not here" line', (
      t,
    ) async {
      final (c, fw, _) = await world(t);
      await openPage(t, c);
      expect(find.byKey(const Key('rs-summary')), findsOneWidget);
      expect(find.text('Name: Ridge phone (RDG)'), findsOneWidget);
      expect(find.text('Region: US (915 MHz)'), findsOneWidget);
      expect(find.textContaining('Speed: Long range, fast'), findsOneWidget);
      expect(find.text('Hop limit: 3'), findsOneWidget);
      expect(find.text('Location sharing: on'), findsOneWidget);
      expect(find.byKey(const Key('rs-blocked')), findsNothing);
      await t.ensureVisible(find.byKey(const Key('rs-not-here')));
      expect(
        find.textContaining('Not here (use the Meshtastic app): factory reset'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('rs-restore')),
        findsNothing,
        reason: 'no backup yet',
      );
      expect(
        fw.log,
        isEmpty,
        reason: 'opening the page asks the radio nothing',
      );
      expect(fw.packets, isEmpty);
    });

    testWidgets(
      'no radio: the page and the row are disabled with a plain line',
      (t) async {
        final (c, _, _) = await world(t, connected: false);
        await openPage(t, c);
        expect(
          find.text('Connect your radio first (Settings > Long-range radio).'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('rs-summary')), findsNothing);
        for (final k in [
          'rs-name-save',
          'rs-hop-save',
          'rs-region-change',
          'rs-preset-change',
        ]) {
          await t.ensureVisible(find.byKey(Key(k)));
          expect(
            t.widget<TextButton>(find.byKey(Key(k))).onPressed,
            isNull,
            reason: k,
          );
        }
        expect(
          t.widget<TextField>(find.byKey(const Key('rs-long'))).enabled,
          isFalse,
        );
        expect(
          t.widget<Slider>(find.byKey(const Key('rs-hop'))).onChanged,
          isNull,
        );
        expect(
          t
              .widget<SwitchListTile>(find.byKey(const Key('rs-location')))
              .onChanged,
          isNull,
        );
      },
    );

    testWidgets(
      'Settings row: chevron above Meshtastic channels; disabled without a radio, opens the page with one',
      (t) async {
        final (c, _, _) = await world(t, connected: false);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: RadioSettings(controller: c)),
            ),
          ),
        );
        await t.pump();
        var row = t.widget<ListTile>(find.byKey(const Key('radioSettingsRow')));
        expect(row.enabled, isFalse);
        expect(find.text('Connect your radio first.'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right), findsWidgets);
        final rowY = t.getTopLeft(find.byKey(const Key('radioSettingsRow'))).dy;
        expect(
          rowY,
          lessThan(t.getTopLeft(find.text('Meshtastic channels')).dy),
        );
        await t.pumpWidget(const SizedBox());

        final (c2, _, _) = await world(t);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: RadioSettings(controller: c2)),
            ),
          ),
        );
        await t.pump();
        row = t.widget<ListTile>(find.byKey(const Key('radioSettingsRow')));
        expect(row.enabled, isTrue);
        await t.ensureVisible(find.byKey(const Key('radioSettingsRow')));
        await t.tap(find.byKey(const Key('radioSettingsRow')));
        await t.pumpAndSettle();
        expect(find.byType(RadioSettingsPage), findsOneWidget);
        expect(find.text('Radio settings'), findsWidgets);
      },
    );

    testWidgets('wide screens get a dialog', (t) async {
      final (c, _, _) = await world(t);
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => openRadioSettings(ctx, c),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('radio-settings-dialog')), findsOneWidget);
    });

    testWidgets('names are validated before anything is sent', (t) async {
      final (c, fw, _) = await world(t);
      await openPage(t, c);
      await t.enterText(find.byKey(const Key('rs-short')), '');
      await tapKey(t, 'rs-name-save');
      expect(find.text('Type 1 to 4 characters.'), findsOneWidget);
      await t.enterText(find.byKey(const Key('rs-short')), 'ABCD');
      await t.enterText(find.byKey(const Key('rs-long')), '   ');
      await tapKey(t, 'rs-name-save');
      expect(find.text('Type a name.'), findsOneWidget);
      expect(fw.log, isEmpty);
      expect(fw.commits, 0);
    });

    testWidgets(
      'saving a name: Saved, new summary, no confirm needed, backup stored',
      (t) async {
        final (c, fw, _) = await world(t);
        await openPage(t, c);
        await t.enterText(find.byKey(const Key('rs-long')), 'Camp radio');
        await t.enterText(find.byKey(const Key('rs-short')), 'CMP');
        await tapKey(t, 'rs-name-save');
        await settle(t);
        expect(find.byKey(const Key('rs-saved')), findsOneWidget);
        expect(find.text('Saved. Name saved.'), findsOneWidget);
        expect(rawString(fw.owner, 2), 'Camp radio');
        expect(find.text('Name: Camp radio (CMP)'), findsOneWidget);
        expect(c.radioBackup, isNotNull);
        expect(find.byKey(const Key('rs-restore')), findsOneWidget);
      },
    );

    testWidgets('hop limit slider and note; Save writes it', (t) async {
      final (c, fw, _) = await world(t);
      await openPage(t, c);
      expect(
        find.textContaining(
          'More hops reach farther but use more airtime for everyone',
        ),
        findsOneWidget,
      );
      expect(
        t.widget<TextButton>(find.byKey(const Key('rs-hop-save'))).onPressed,
        isNull,
        reason: 'unchanged',
      );
      t.widget<Slider>(find.byKey(const Key('rs-hop'))).onChanged!(6);
      await t.pump();
      expect(find.text('6'), findsWidgets);
      await tapKey(t, 'rs-hop-save');
      await settle(t);
      expect(rawInt(fw.lora, 8), 6);
      expect(find.text('Hop limit: 6'), findsOneWidget);
    });

    testWidgets('location switch turns the broadcast off and on', (t) async {
      final (c, fw, _) = await world(t);
      await openPage(t, c);
      await tapKey(t, 'rs-location');
      await settle(t);
      expect(rawInt(fw.position, 1), posNever);
      expect(find.text('Location sharing: off'), findsOneWidget);
      expect(
        find.textContaining('does not send this phone\'s GPS'),
        findsOneWidget,
      );
      await t.pump();
      await tapKey(t, 'rs-location');
      await settle(t);
      expect(fw.position, positionRaw(), reason: 'interval and flags back');
      expect(find.text('Location sharing: on'), findsOneWidget);
    });

    testWidgets(
      'region: a confirm screen first; Cancel writes nothing; Change writes',
      (t) async {
        final (c, fw, _) = await world(t);
        await openPage(t, c);
        t
            .widget<DropdownButtonFormField<int>>(
              find.byKey(const Key('rs-region')),
            )
            .onChanged!(3);
        await t.pump();
        await tapKey(t, 'rs-region-change');
        expect(find.byKey(const Key('rs-confirm-dialog')), findsOneWidget);
        expect(
          find.text(
            'All radios in your group must use the same region and speed, or '
            'they can\'t hear each other. Region must match where you are by law.',
          ),
          findsOneWidget,
        );
        expect(find.text('Region: US (915 MHz) → EU 868'), findsOneWidget);
        await t.tap(find.byKey(const Key('rs-cancel')));
        await t.pumpAndSettle();
        expect(fw.log, isEmpty);
        expect(fw.commits, 0);
        await tapKey(t, 'rs-region-change');
        await t.tap(find.byKey(const Key('rs-confirm')));
        await t.pump();
        await settle(t);
        expect(rawInt(fw.lora, 7), 3);
        expect(find.text('Region: EU 868'), findsOneWidget);
      },
    );

    testWidgets('speed: same confirm, then written', (t) async {
      final (c, fw, _) = await world(t);
      await openPage(t, c);
      t
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const Key('rs-preset')),
          )
          .onChanged!(4);
      await t.pump();
      await tapKey(t, 'rs-preset-change');
      expect(find.byKey(const Key('rs-confirm-text')), findsOneWidget);
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(rawInt(fw.lora, 2), 4);
      expect(find.textContaining('Speed: Medium range, fast'), findsOneWidget);
    });

    testWidgets(
      'Restore previous settings: its own confirm, then the old values are back',
      (t) async {
        final (c, fw, _) = await world(t);
        await openPage(t, c);
        t
            .widget<DropdownButtonFormField<int>>(
              find.byKey(const Key('rs-region')),
            )
            .onChanged!(3);
        await t.pump();
        await tapKey(t, 'rs-region-change');
        await t.tap(find.byKey(const Key('rs-confirm')));
        await t.pump();
        await settle(t);
        expect(rawInt(fw.lora, 7), 3);
        await t.ensureVisible(find.byKey(const Key('rs-backup-line')));
        expect(
          find.textContaining(
            'Before the last change your radio had: US (915 MHz)',
          ),
          findsOneWidget,
        );
        await tapKey(t, 'rs-restore');
        expect(find.text('Restore previous settings?'), findsOneWidget);
        expect(
          find.byKey(const Key('rs-confirm-text')),
          findsOneWidget,
          reason: 'the same warning',
        );
        await t.tap(find.byKey(const Key('rs-cancel')));
        await t.pumpAndSettle();
        expect(rawInt(fw.lora, 7), 3);
        await tapKey(t, 'rs-restore');
        await t.tap(find.byKey(const Key('rs-confirm')));
        await t.pump();
        await settle(t);
        expect(fw.lora, loraRaw(), reason: 'byte for byte');
        expect(find.text('Saved. Previous settings restored.'), findsOneWidget);
      },
    );

    testWidgets('a failed write shows why and offers Restore', (t) async {
      final (c, fw, _) = await world(t, fw0: Fw(applySets: false));
      await openPage(t, c);
      t
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const Key('rs-region')),
          )
          .onChanged!(3);
      await t.pump();
      await tapKey(t, 'rs-region-change');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settle(t);
      expect(find.byKey(const Key('rs-failed')), findsOneWidget);
      expect(
        find.textContaining('Not saved: Your radio did not keep: the region'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('rs-restore-failed')), findsOneWidget);
      expect(find.byKey(const Key('rs-saved')), findsNothing);
      expect(fw.commits, 1);
      // Restore with the same confirm (the radio still refuses: it fails
      // clearly again, nothing hangs).
      await t.tap(find.byKey(const Key('rs-restore-failed')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rs-confirm-text')), findsOneWidget);
      await t.tap(find.byKey(const Key('rs-cancel')));
      await t.pumpAndSettle();
    });

    testWidgets('edits wait while a talk burst is going on', (t) async {
      final (c, fw, _) = await world(t);
      c.transmitting = true;
      await openPage(t, c);
      expect(find.byKey(const Key('rs-blocked')), findsOneWidget);
      expect(find.textContaining('A talk is going on'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byKey(const Key('rs-long'))).enabled,
        isFalse,
      );
      expect(
        t.widget<Slider>(find.byKey(const Key('rs-hop'))).onChanged,
        isNull,
      );
      expect(
        t
            .widget<SwitchListTile>(find.byKey(const Key('rs-location')))
            .onChanged,
        isNull,
      );
      final err = await t.runAsync(
        () => c.changeRadioSettings(RadioChange.hop(2)),
      );
      expect(err, contains('A talk is going on'));
      expect(fw.log, isEmpty);
      c.transmitting = false;
    });

    testWidgets('the region-not-set warning links to this page', (t) async {
      final fw = Fw()..lora = loraRaw(region: 0);
      final (c, _, _) = await world(t, fw0: fw);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: RadioSettings(controller: c)),
          ),
        ),
      );
      await t.pump();
      expect(find.textContaining('Region is not set'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('radioFixRegion')));
      await t.tap(find.byKey(const Key('radioFixRegion')));
      await t.pumpAndSettle();
      expect(find.byType(RadioSettingsPage), findsOneWidget);
      expect(find.text('Region: Not set'), findsOneWidget);
      expect(
        find.text('Not set: the radio will not transmit.'),
        findsOneWidget,
      );
      // Region is chosen from the full list.
      expect(
        t
            .widget<DropdownButton<int>>(
              find.descendant(
                of: find.byKey(const Key('rs-region')),
                matching: find.byType(DropdownButton<int>),
              ),
            )
            .items!
            .length,
        26,
      );
    });

    testWidgets('nothing runs in the background: no admin traffic while idle', (
      t,
    ) async {
      final (c, fw, _) = await world(t);
      await openPage(t, c);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await t.pump(const Duration(minutes: 5));
      expect(fw.log, isEmpty);
      expect(fw.packets, isEmpty);
    });

    testWidgets('summary lines without names or position are still sensible', (
      t,
    ) async {
      final s = MeshtasticSession(Fw());
      expect(radioSummaryLines(s).first, startsWith('Region: unknown'));
      expect(radioSummaryLines(s).last, 'Location sharing: unknown');
    });
  });
}

/// A session whose radio never answers admin messages.
class _SilentSession extends MeshtasticSession {
  _SilentSession(Fw fw) : super(_Mute(fw));
}

class _Mute implements MeshtasticWire {
  _Mute(this.fw);
  final Fw fw;
  @override
  Future<void> write(Uint8List toRadio) async {
    for (final f in pbDecode(toRadio)) {
      // Only the config download is answered.
      if (f.number == 3) await fw.write(toRadio);
    }
  }

  @override
  Future<Uint8List> read() => fw.read();
  @override
  Stream<void> get notifications => fw.notifications;
}
