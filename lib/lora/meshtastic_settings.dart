import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'meshtastic_admin.dart';
import 'meshtastic_channels.dart';
import 'meshtastic_proto.dart';
import 'meshtastic_session.dart';
import 'protobuf.dart';

/// Basic radio settings on the paired Meshtastic radio (v2.5.3): names, hop
/// limit, position broadcast on/off, region and speed preset. The same way
/// the channel writer and the official apps do it: read the current config,
/// copy it byte for byte, change only the chosen fields, `begin_edit_settings`
/// / `set_*` / `commit_edit_settings`, wait for the restart, read back and
/// compare. Nothing here runs on its own: only when the user saves.

/// PositionConfig.position_broadcast_secs "never" (the Meshtastic apps' own
/// "no broadcast" value; the firmware treats it as ~49 days).
const posNever = 0xFFFFFFFF;

/// One choice in a list.
class RadioChoice {
  const RadioChoice(this.code, this.label, [this.hint = '']);
  final int code;
  final String label;
  final String hint;
}

/// Every region the firmware knows (Config.LoRaConfig.RegionCode), by name.
/// Which one is legal depends on where you are.
const radioRegions = <RadioChoice>[
  RadioChoice(1, 'US (915 MHz)', 'United States, Canada, Mexico'),
  RadioChoice(3, 'EU 868', 'Europe, UK'),
  RadioChoice(2, 'EU 433', 'Europe, 433 MHz'),
  RadioChoice(6, 'ANZ (915 MHz)', 'Australia, New Zealand'),
  RadioChoice(22, 'ANZ 433', 'Australia, New Zealand, 433 MHz'),
  RadioChoice(11, 'NZ 865', 'New Zealand, 865 MHz'),
  RadioChoice(4, 'China'),
  RadioChoice(5, 'Japan'),
  RadioChoice(7, 'Korea'),
  RadioChoice(8, 'Taiwan'),
  RadioChoice(9, 'Russia'),
  RadioChoice(10, 'India'),
  RadioChoice(12, 'Thailand'),
  RadioChoice(14, 'Ukraine 433'),
  RadioChoice(15, 'Ukraine 868'),
  RadioChoice(16, 'Malaysia 433'),
  RadioChoice(17, 'Malaysia 919'),
  RadioChoice(18, 'Singapore 923'),
  RadioChoice(19, 'Philippines 433'),
  RadioChoice(20, 'Philippines 868'),
  RadioChoice(21, 'Philippines 915'),
  RadioChoice(23, 'Kazakhstan 433'),
  RadioChoice(24, 'Kazakhstan 863'),
  RadioChoice(25, 'Nepal 865'),
  RadioChoice(26, 'Brazil 902'),
  RadioChoice(13, '2.4 GHz', 'only radios with a 2.4 GHz chip'),
];

/// Speed presets (Config.LoRaConfig.ModemPreset). No custom speeds here.
const radioPresets = <RadioChoice>[
  RadioChoice(0, 'Long range, fast (LongFast)', 'the Meshtastic default'),
  RadioChoice(7, 'Long range, moderate (LongModerate)'),
  RadioChoice(1, 'Long range, slow (LongSlow)'),
  RadioChoice(9, 'Long range, turbo (LongTurbo)', 'newer firmware only'),
  RadioChoice(4, 'Medium range, fast (MediumFast)'),
  RadioChoice(3, 'Medium range, slow (MediumSlow)'),
  RadioChoice(6, 'Short range, fast (ShortFast)'),
  RadioChoice(5, 'Short range, slow (ShortSlow)'),
  RadioChoice(8, 'Short range, turbo (ShortTurbo)'),
];

String radioRegionText(int code) => code == 0
    ? 'Not set'
    : radioRegions
          .firstWhere(
            (r) => r.code == code,
            orElse: () => RadioChoice(code, meshRegionLabel(code)),
          )
          .label;

String radioPresetText(int code, {bool usePreset = true}) {
  if (!usePreset) return 'Custom speed';
  for (final p in radioPresets) {
    if (p.code == code) return p.label;
  }
  return meshPresetLabel(code);
}

/// The message the user confirms before the region or speed changes.
const radioConfirmText =
    'All radios in your group must use the same region and speed, or they '
    'can\'t hear each other. Region must match where you are by law.';

// ---------------------------------------------------------- validation

/// null when [s] is fine as the radio's long name.
String? validateLongName(String s) {
  final t = s.trim();
  if (t.isEmpty) return 'Type a name.';
  if (_hasControl(t)) return 'Letters, digits and spaces only.';
  if (utf8.encode(t).length > 39) return 'At most 39 characters.';
  return null;
}

/// null when [s] is fine as the radio's short name (up to 4 characters).
String? validateShortName(String s) {
  final t = s.trim();
  if (t.isEmpty) return 'Type 1 to 4 characters.';
  if (_hasControl(t)) return 'Letters and digits only.';
  if (t.runes.length > 4 || utf8.encode(t).length > 4) {
    return 'At most 4 characters.';
  }
  return null;
}

bool _hasControl(String s) =>
    s.runes.any((r) => r < 0x20 || r == 0x7F || (r >= 0x80 && r < 0xA0));

/// null when [h] is a hop limit the radio takes (0-7).
String? validateHopLimit(int h) => h < 0 || h > 7 ? 'Pick 0 to 7 hops.' : null;

// ------------------------------------------------------- raw protobuf

/// The varint of [field] in [raw] (0 when absent, like proto3), null when
/// [raw] is null.
int? rawInt(Uint8List? raw, int field) {
  if (raw == null) return null;
  var v = 0;
  for (final f in pbDecode(raw)) {
    if (f.number == field && f.wireType == 0) v = f.asInt;
  }
  return v;
}

String? rawString(Uint8List? raw, int field) {
  if (raw == null) return null;
  var v = '';
  for (final f in pbDecode(raw)) {
    if (f.number == field && f.wireType == 2) v = f.asString;
  }
  return v;
}

/// [raw] with the varint [set] fields changed (value 0 / null = removed,
/// which is how proto3 writes zero) and everything else copied as it was,
/// in the same order. New fields go at the end.
Uint8List patchVarints(Uint8List raw, Map<int, int?> set) {
  final fields = pbDecode(raw);
  final have = {
    for (final f in fields)
      if (f.wireType == 0) f.number,
  };
  // Fields it did not have yet go in field-number order (where the
  // firmware writes them), so setting a value back gives the same bytes.
  for (final k in (set.keys.toList()..sort())) {
    if (have.contains(k)) continue;
    final v = set[k];
    if (v == null || v == 0) continue;
    var at = fields.length;
    for (var i = 0; i < fields.length; i++) {
      if (fields[i].number > k) {
        at = i;
        break;
      }
    }
    fields.insert(at, PbField(k, 0, v, null));
  }
  final w = PbWriter();
  final done = <int>{};
  for (final f in fields) {
    if (set.containsKey(f.number) && f.wireType == 0) {
      if (done.add(f.number)) {
        final v = set[f.number];
        if (v != null && v != 0) w.uint(f.number, v);
      }
      continue;
    }
    w.raw(f);
  }
  return w.toBytes();
}

/// [raw] (a `User`) with the long / short name replaced.
Uint8List patchNames(Uint8List raw, {String? longName, String? shortName}) {
  final w = PbWriter();
  var l = false, s = false;
  for (final f in pbDecode(raw)) {
    if (f.number == 2 && f.wireType == 2 && longName != null) {
      if (!l) w.string(2, longName);
      l = true;
      continue;
    }
    if (f.number == 3 && f.wireType == 2 && shortName != null) {
      if (!s) w.string(3, shortName);
      s = true;
      continue;
    }
    w.raw(f);
  }
  if (!l) w.string(2, longName);
  if (!s) w.string(3, shortName);
  return w.toBytes();
}

/// Position sharing is off when the radio never broadcasts on a timer.
bool locationSharingOn(int? secs, bool? smart) =>
    !(secs == posNever && smart != true);

// ---------------------------------------------------------- snapshots

/// What the radio had: the raw LoRa config, position config and owner
/// (`User`), as the radio sent them.
class RadioSnapshot {
  RadioSnapshot({
    required this.node,
    required this.at,
    this.lora,
    this.position,
    this.owner,
  });

  final int node;
  final DateTime at;
  final Uint8List? lora;
  final Uint8List? position;
  final Uint8List? owner;

  int? get region => rawInt(lora, 7);
  int? get preset => rawInt(lora, 2);
  bool? get usePreset => lora == null ? null : rawInt(lora, 1) != 0;
  int? get hopLimit => rawInt(lora, 8);
  int? get positionSecs => rawInt(position, 1);
  bool? get positionSmart => position == null ? null : rawInt(position, 2) != 0;
  String? get longName => rawString(owner, 2);
  String? get shortName => rawString(owner, 3);
  bool? get sharing =>
      position == null ? null : locationSharingOn(positionSecs, positionSmart);

  Map<String, Object?> toJson() => {
    'node': node,
    'at': at.toUtc().toIso8601String(),
    if (lora != null) 'lora': base64.encode(lora!),
    if (position != null) 'position': base64.encode(position!),
    if (owner != null) 'owner': base64.encode(owner!),
  };

  static RadioSnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      Uint8List? b(String k) => j[k] is String
          ? Uint8List.fromList(base64.decode(j[k] as String))
          : null;
      return RadioSnapshot(
        node: (j['node'] as num).toInt(),
        at: DateTime.parse(j['at'] as String),
        lora: b('lora'),
        position: b('position'),
        owner: b('owner'),
      );
    } catch (_) {
      return null;
    }
  }

  /// A line for the page: "US 915, LongFast, hop limit 3".
  String get summary => [
    if (region != null) radioRegionText(region!),
    if (preset != null) radioPresetText(preset!, usePreset: usePreset ?? true),
    if (hopLimit != null) 'hop limit $hopLimit',
    if (longName != null && longName!.isNotEmpty)
      'name $longName${(shortName ?? '').isEmpty ? '' : ' ($shortName)'}',
    if (sharing != null) 'location sharing ${sharing! ? 'on' : 'off'}',
  ].join(', ');
}

/// What is kept in app storage before a change (and used by "Restore
/// previous settings"): the radio as it was, plus the last position
/// interval it had while sharing was on (so turning sharing on again puts
/// that back).
class RadioBackup {
  RadioBackup({required this.previous, this.sharingSecs, this.sharingSmart});
  final RadioSnapshot previous;
  final int? sharingSecs;
  final bool? sharingSmart;

  String encode() => jsonEncode({
    'v': 1,
    'previous': previous.toJson(),
    'sharingSecs': ?sharingSecs,
    'sharingSmart': ?sharingSmart,
  });

  static RadioBackup? tryDecode(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s) as Map;
      final p = RadioSnapshot.fromJson(j['previous']);
      if (p == null) return null;
      return RadioBackup(
        previous: p,
        sharingSecs: (j['sharingSecs'] as num?)?.toInt(),
        sharingSmart: j['sharingSmart'] as bool?,
      );
    } catch (_) {
      return null;
    }
  }
}

// ------------------------------------------------------------ changes

/// What to put on the radio: only these fields change.
class RadioChange {
  const RadioChange({
    this.longName,
    this.shortName,
    this.lora = const {},
    this.position = const {},
    this.what = 'settings',
  });

  final String? longName, shortName;

  /// LoRaConfig varint fields to set (0 / null = remove).
  final Map<int, int?> lora;

  /// PositionConfig varint fields to set.
  final Map<int, int?> position;

  /// "region", "speed", ... for the progress text.
  final String what;

  bool get touchesOwner => longName != null || shortName != null;
  bool get touchesLora => lora.isNotEmpty;
  bool get touchesPosition => position.isNotEmpty;
  bool get isEmpty => !touchesOwner && !touchesLora && !touchesPosition;

  /// The radio restarts for LoRa changes (and maybe others: the writer
  /// waits and asks again if it does not).
  bool get expectReboot => touchesLora;

  static RadioChange names({String? longName, String? shortName}) =>
      RadioChange(
        longName: longName?.trim(),
        shortName: shortName?.trim(),
        what: 'name',
      );
  static RadioChange hop(int h) => RadioChange(lora: {8: h}, what: 'hop limit');
  static RadioChange region(int code) =>
      RadioChange(lora: {7: code}, what: 'region');

  /// A preset: use_preset on, the chosen modem preset; bandwidth / spread
  /// factor / coding rate stay (the radio ignores them with a preset).
  static RadioChange preset(int code) =>
      RadioChange(lora: {1: 1, 2: code}, what: 'speed');

  /// Location sharing off: never on a timer, no smart broadcast. On: the
  /// interval it had (or the firmware default).
  static RadioChange sharingOff() =>
      const RadioChange(position: {1: posNever, 2: 0}, what: 'location');
  static RadioChange sharingOn({int? secs, bool? smart}) => RadioChange(
    position: {
      1: (secs == null || secs == posNever) ? 0 : secs,
      2: (smart ?? true) ? 1 : 0,
    },
    what: 'location',
  );

  /// Put back what [b] had (only the fields this page changes, on top of
  /// what the radio has now).
  static RadioChange restore(RadioSnapshot b) => RadioChange(
    longName: b.longName != null && b.longName!.isNotEmpty ? b.longName : null,
    shortName: b.shortName != null && b.shortName!.isNotEmpty
        ? b.shortName
        : null,
    lora: b.lora == null
        ? const {}
        : {
            1: rawInt(b.lora, 1),
            2: rawInt(b.lora, 2),
            7: rawInt(b.lora, 7),
            8: rawInt(b.lora, 8),
          },
    position: b.position == null
        ? const {}
        : {1: rawInt(b.position, 1), 2: rawInt(b.position, 2)},
    what: 'previous settings',
  );
}

class RadioWriteResult {
  RadioWriteResult(this.after, this.backup);
  final RadioSnapshot after;
  final RadioBackup backup;
}

/// Reads and writes the basic settings of the paired radio with admin
/// messages. [session] returns the radio's current session (a new one
/// after the reconnect).
class RadioSettingsWriter {
  RadioSettingsWriter(
    this.session, {
    this.replyTimeout = const Duration(seconds: 8),
    this.rebootWait = const Duration(seconds: 20),
    this.quickWait = const Duration(seconds: 6),
    this.reconnectTimeout = const Duration(seconds: 120),
    this.poll = const Duration(milliseconds: 250),
    this.writeGap = const Duration(milliseconds: 150),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MeshtasticSession? Function() session;
  final Duration replyTimeout;

  /// How long to wait for a restart after a LoRa change / any other
  /// change before asking the radio for its settings on the same link.
  final Duration rebootWait;
  final Duration quickWait;
  final Duration reconnectTimeout;
  final Duration poll;
  final Duration writeGap;
  final DateTime Function() _clock;

  MeshtasticSession _ready() {
    final s = session();
    if (s == null || s.myNodeNum == null || !s.configured) {
      throw MeshWriteException('Connect your radio first.');
    }
    return s;
  }

  Future<AdminReply?> _ask(
    MeshtasticSession s,
    Uint8List request,
    bool Function(AdminReply r) match,
  ) async {
    final reply = s.adminReplies
        .where((p) => p.decoded?.portnum == PortNum.admin)
        .map((p) => AdminReply.tryDecode(p.decoded!.payload))
        .where((r) => r != null && match(r))
        .first
        .timeout(replyTimeout, onTimeout: () => null);
    await s.sendAdmin(request);
    unawaited(s.drain());
    return reply;
  }

  Future<void> _gap() => writeGap == Duration.zero
      ? Future.value()
      : Future<void>.delayed(writeGap);

  /// The radio's LoRa config, position config and owner as raw bytes.
  Future<RadioSnapshot> read([MeshtasticSession? s0]) async {
    final s = s0 ?? _ready();
    final lora = await _ask(
      s,
      AdminPb.getConfig(AdminPb.configLora),
      (r) => r.loraConfig != null,
    );
    final pos = await _ask(
      s,
      AdminPb.getConfig(AdminPb.configPosition),
      (r) => r.positionConfig != null,
    );
    final owner = await _ask(s, AdminPb.getOwner(), (r) => r.owner != null);
    return RadioSnapshot(
      node: s.myNodeNum!,
      at: _clock(),
      lora: lora?.loraConfig,
      position: pos?.positionConfig,
      owner: owner?.owner,
    );
  }

  /// Apply [change]. [saveBackup] stores the settings as they were BEFORE
  /// anything is written (an error there stops everything). Throws
  /// [MeshWriteException] with a plain message; once the backup is saved
  /// the page offers "Restore previous settings".
  Future<RadioWriteResult> apply(
    RadioChange change, {
    required Future<void> Function(RadioBackup backup) saveBackup,
    RadioBackup? previousBackup,
    void Function(MeshWriteStep step)? onStep,
  }) async {
    if (change.isEmpty) {
      throw MeshWriteException('Nothing to change.');
    }
    onStep?.call(MeshWriteStep.preparing);
    final s = _ready();
    final before = await read(s);
    if (change.touchesLora && before.lora == null) {
      throw MeshWriteException(
        'Your radio did not send its radio settings, so nothing was '
        'changed.',
      );
    }
    if (change.touchesPosition && before.position == null) {
      throw MeshWriteException(
        'Your radio did not send its position settings, so nothing was '
        'changed.',
      );
    }
    if (change.touchesOwner && before.owner == null) {
      throw MeshWriteException(
        'Your radio did not send its name, so nothing was changed.',
      );
    }
    // The last interval it had while sharing was on.
    var onSecs = previousBackup?.sharingSecs;
    var onSmart = previousBackup?.sharingSmart;
    if (before.position != null && before.sharing == true) {
      onSecs = before.positionSecs;
      onSmart = before.positionSmart;
    }
    final backup = RadioBackup(
      previous: before,
      sharingSecs: onSecs,
      sharingSmart: onSmart,
    );
    await saveBackup(backup);
    final key = (await _ask(
      s,
      AdminPb.getConfig(AdminPb.configSessionKey),
      (r) => r.passkey != null,
    ))?.passkey;
    onStep?.call(MeshWriteStep.writing);
    final bootsBefore = (s.rebootCount, s.configCount);
    await s.sendAdmin(AdminPb.beginEdit(passkey: key), wantResponse: false);
    if (change.touchesOwner) {
      await _gap();
      await s.sendAdmin(
        AdminPb.setOwner(
          patchNames(
            before.owner!,
            longName: change.longName,
            shortName: change.shortName,
          ),
          passkey: key,
        ),
        wantResponse: false,
      );
    }
    if (change.touchesLora) {
      await _gap();
      await s.sendAdmin(
        AdminPb.setLoraConfig(
          patchVarints(before.lora!, change.lora),
          passkey: key,
        ),
        wantResponse: false,
      );
    }
    if (change.touchesPosition) {
      await _gap();
      await s.sendAdmin(
        AdminPb.setPositionConfig(
          patchVarints(before.position!, change.position),
          passkey: key,
        ),
        wantResponse: false,
      );
    }
    await _gap();
    await s.sendAdmin(AdminPb.commitEdit(passkey: key), wantResponse: false);
    onStep?.call(MeshWriteStep.restarting);
    final after = await _afterCommit(
      s,
      bootsBefore,
      change.expectReboot ? rebootWait : quickWait,
    );
    onStep?.call(MeshWriteStep.verifying);
    final now = await read(after);
    final bad = verify(change, now);
    if (bad.isNotEmpty) {
      throw MeshWriteException(
        'Your radio did not keep: ${bad.join(', ')}. Nothing else was '
        'touched. You can restore the previous settings.',
      );
    }
    onStep?.call(MeshWriteStep.done);
    return RadioWriteResult(now, backup);
  }

  /// What of [change] the radio does not show after the change.
  static List<String> verify(RadioChange c, RadioSnapshot now) {
    final bad = <String>[];
    if (c.touchesLora) {
      if (now.lora == null) {
        bad.add('radio settings (not readable)');
      } else {
        for (final e in c.lora.entries) {
          if (rawInt(now.lora, e.key) != (e.value ?? 0)) {
            bad.add(switch (e.key) {
              7 => 'the region',
              8 => 'the hop limit',
              _ => 'the speed',
            });
          }
        }
      }
    }
    if (c.touchesPosition) {
      if (now.position == null) {
        bad.add('position settings (not readable)');
      } else if (c.position.entries.any(
        (e) => rawInt(now.position, e.key) != (e.value ?? 0),
      )) {
        bad.add('location sharing');
      }
    }
    if (c.touchesOwner) {
      if (c.longName != null && now.longName != c.longName) {
        bad.add('the long name');
      }
      if (c.shortName != null && now.shortName != c.shortName) {
        bad.add('the short name');
      }
    }
    return bad;
  }

  /// Same wait as the channel writer: a new session or "rebooted" on the
  /// same one; when nothing happens within [wait], ask for the settings.
  Future<MeshtasticSession> _afterCommit(
    MeshtasticSession s0,
    (int, int) before,
    Duration wait,
  ) async {
    final start = DateTime.now();
    var asked = false;
    while (true) {
      final cur = session();
      final elapsed = DateTime.now().difference(start);
      if (cur != null && cur.configured && cur.myNodeNum != null) {
        final fresh = !identical(cur, s0);
        final restarted =
            identical(cur, s0) &&
            (cur.rebootCount > before.$1 || cur.configCount > before.$2);
        if (fresh || restarted) return cur;
      }
      if (!asked && elapsed >= wait && identical(cur, s0)) {
        asked = true;
        try {
          unawaited(s0.requestConfig());
        } catch (_) {}
      }
      if (elapsed >= reconnectTimeout) {
        throw MeshWriteException(
          'Your radio did not come back after saving. Check that it is on '
          'and connected, then open Radio settings again.',
        );
      }
      await Future<void>.delayed(poll);
    }
  }
}
