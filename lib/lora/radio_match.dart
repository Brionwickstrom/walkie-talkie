import 'meshtastic_channels.dart' show MeshRadioChannel, meshPresetDisplayName;
import 'meshtastic_session.dart';
import 'meshtastic_settings.dart';

/// Radio match check (v2.6.1): do your radios agree on the settings that
/// make them hear each other? Only three things are compared: the LoRa
/// frequency slot (`channel_num`), the hop limit, and the location
/// precision of each channel (by channel name). Only numbers and channel
/// names are kept, never a key.

/// The settings of one radio as they were read from it.
class RadioReading {
  RadioReading({
    required this.at,
    this.slot,
    this.hop,
    this.precisions = const {},
  });

  /// When the radio was read (the radio was connected then).
  final DateTime at;

  /// LoRaConfig.channel_num: 0 = automatic (from the main channel's name).
  final int? slot;
  final int? hop;

  /// Channel name (as the Meshtastic apps show it) -> location precision.
  final Map<String, int> precisions;

  bool sameValues(RadioReading? o) =>
      o != null &&
      slot == o.slot &&
      hop == o.hop &&
      precisions.length == o.precisions.length &&
      precisions.entries.every((e) => o.precisions[e.key] == e.value);

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'slot': ?slot,
    'hop': ?hop,
    if (precisions.isNotEmpty) 'prec': precisions,
  };

  static RadioReading? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['at'];
    if (at is! int) return null;
    final p = <String, int>{};
    final pj = j['prec'];
    if (pj is Map) {
      for (final e in pj.entries) {
        if (e.key is String && e.value is int) {
          p[e.key as String] = e.value as int;
        }
      }
    }
    return RadioReading(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      slot: j['slot'] is int ? j['slot'] as int : null,
      hop: j['hop'] is int ? j['hop'] as int : null,
      precisions: p,
    );
  }
}

/// The radio's channels with the name the Meshtastic apps show for each
/// (a repeated name gets "#2" added).
List<({String name, MeshRadioChannel channel})> _namedChannels(
  MeshtasticSession s,
) {
  final preset = meshPresetDisplayName(
    s.modemPreset ?? 0,
    usePreset: s.usePreset ?? true,
  );
  final list = s.channels.values.where((c) => !c.isDisabled).toList()
    ..sort((a, b) => a.index.compareTo(b.index));
  final seen = <String>{};
  final out = <({String name, MeshRadioChannel channel})>[];
  for (final c in list) {
    var n = c.effectiveName(preset);
    if (!seen.add(n)) n = '$n #${c.index + 1}';
    out.add((name: n, channel: c));
  }
  return out;
}

/// Channel name -> channel index on the connected radio.
Map<String, int> channelIndexByName(MeshtasticSession s) => {
  for (final e in _namedChannels(s)) e.name: e.channel.index,
};

/// What the connected radio sent when it connected (no traffic: this is the
/// settings download the app already does). Null until it is configured.
RadioReading? readingFromSession(MeshtasticSession s, DateTime now) {
  if (!s.configured || s.myNodeNum == null) return null;
  final prec = <String, int>{};
  for (final e in _namedChannels(s)) {
    prec[e.name] = e.channel.positionPrecision;
  }
  return RadioReading(
    at: now,
    slot: s.channelNum,
    hop: s.hopLimit,
    precisions: prec,
  );
}

/// A radio in the check.
class MatchRadio {
  const MatchRadio({
    required this.id,
    required this.name,
    this.connected = false,
    this.reading,
    this.home = false,
  });
  final String id;
  final String name;

  /// Connected now: [reading] was just read from it.
  final bool connected;

  /// What it had when it was last read (null = never).
  final RadioReading? reading;

  /// The home base (default Skunk Ape).
  final bool home;
}

/// What a Fix would write on the connected radio.
class MatchFix {
  MatchFix({required this.change, required this.lines, required this.slot});
  final RadioChange change;

  /// "Frequency slot: 0 (automatic) → 20" ...
  final List<String> lines;

  /// The slot changes (so the all-radios-together warning applies).
  final bool slot;
}

String slotText(int? n) =>
    n == null ? 'unknown' : (n == 0 ? '0 (automatic)' : '$n');

/// The changes that make [now] match [target]. [indexByName] maps channel
/// names of the radio to its channel index. Null when nothing differs.
MatchFix? matchFix(
  RadioReading now,
  RadioReading target,
  Map<String, int> indexByName,
) {
  final lora = <int, int?>{};
  final prec = <int, int>{};
  final lines = <String>[];
  var slot = false;
  if (target.slot != null && now.slot != null && target.slot != now.slot) {
    lora[11] = target.slot;
    slot = true;
    lines.add(
      'Frequency slot: ${slotText(now.slot)} → ${slotText(target.slot)}',
    );
  }
  if (target.hop != null && now.hop != null && target.hop != now.hop) {
    lora[8] = target.hop;
    lines.add('Hop limit: ${now.hop} → ${target.hop}');
  }
  for (final e in target.precisions.entries) {
    final have = now.precisions[e.key];
    final idx = indexByName[e.key];
    if (have == null || idx == null || have == e.value) continue;
    prec[idx] = e.value;
    lines.add(
      'Location precision of ${e.key}: ${radioPrecisionText(have)} → '
      '${radioPrecisionText(e.value)}',
    );
  }
  if (lora.isEmpty && prec.isEmpty) return null;
  return MatchFix(
    change: RadioChange(
      lora: lora,
      channelPrecision: prec,
      what: 'matching settings',
    ),
    lines: lines,
    slot: slot,
  );
}

/// One setting that differs from the target.
class MatchDiff {
  const MatchDiff(this.field, this.have, this.want);

  /// "slot", "hop limit" or "[channel] precision".
  final String field;
  final String have;
  final String want;
}

class MatchRow {
  MatchRow(this.radio, this.diffs);
  final MatchRadio radio;

  /// Different from the target; empty = matches (or nothing to compare).
  final List<MatchDiff> diffs;

  bool get checked => radio.reading != null;
}

/// The result of comparing the saved radios.
class RadioMatch {
  RadioMatch._({
    required this.rows,
    required this.target,
    required this.problems,
    required this.checked,
  });

  final List<MatchRow> rows;

  /// The radio whose values the others are compared with (null if nothing
  /// was read yet).
  final MatchRadio? target;

  /// Plain sentences, one per setting that differs ("Yowie is on slot 0,
  /// the others are on 20.").
  final List<String> problems;

  /// How many radios have a reading.
  final int checked;

  bool get allMatch => checked >= 2 && problems.isEmpty;

  /// "slot 20, hop limit 4, BigfootNet Full (exact)" of the target.
  String get targetSummary {
    final r = target?.reading;
    if (r == null) return '';
    return [
      if (r.slot != null) 'slot ${slotText(r.slot)}',
      if (r.hop != null) 'hop limit ${r.hop}',
      for (final e in r.precisions.entries)
        '${e.key} ${radioPrecisionText(e.value)}',
    ].join(', ');
  }

  /// Compare [radios]. [targetId] picks the reference radio; the default is
  /// the home base when it was read, else the radio that agrees with the
  /// most others (a tie goes to the connected one, then the newest).
  static RadioMatch compare(List<MatchRadio> radios, {String? targetId}) {
    final read = [
      for (final r in radios)
        if (r.reading != null) r,
    ];
    MatchRadio? target;
    if (targetId != null) {
      target = read.where((r) => r.id == targetId).firstOrNull;
    }
    target ??= read.where((r) => r.home).firstOrNull;
    if (target == null && read.isNotEmpty) {
      int agree(MatchRadio a) => read
          .where((b) => b.id != a.id && _sameAll(a.reading!, b.reading!))
          .length;
      final sorted = [...read]
        ..sort((a, b) {
          final c = agree(b).compareTo(agree(a));
          if (c != 0) return c;
          if (a.connected != b.connected) return a.connected ? -1 : 1;
          return b.reading!.at.compareTo(a.reading!.at);
        });
      target = sorted.first;
    }
    final rows = <MatchRow>[];
    for (final r in radios) {
      final diffs = <MatchDiff>[];
      final t = target?.reading;
      final x = r.reading;
      if (t != null && x != null && r.id != target!.id) {
        if (t.slot != null && x.slot != null && t.slot != x.slot) {
          diffs.add(MatchDiff('slot', slotText(x.slot), slotText(t.slot)));
        }
        if (t.hop != null && x.hop != null && t.hop != x.hop) {
          diffs.add(MatchDiff('hop limit', '${x.hop}', '${t.hop}'));
        }
        for (final e in t.precisions.entries) {
          final h = x.precisions[e.key];
          if (h != null && h != e.value) {
            diffs.add(
              MatchDiff(
                '${e.key} precision',
                radioPrecisionText(h),
                radioPrecisionText(e.value),
              ),
            );
          }
        }
      }
      rows.add(MatchRow(r, diffs));
    }
    return RadioMatch._(
      rows: rows,
      target: target,
      problems: _problems(read),
      checked: read.length,
    );
  }

  static bool _sameAll(RadioReading a, RadioReading b) {
    if (a.slot != b.slot || a.hop != b.hop) return false;
    for (final e in a.precisions.entries) {
      final o = b.precisions[e.key];
      if (o != null && o != e.value) return false;
    }
    return true;
  }

  /// Group the radios by value for each setting and say it in words.
  static List<String> _problems(List<MatchRadio> read) {
    final out = <String>[];
    void field(
      String label,
      Map<String, String> byRadio,
      String Function(String value) say,
    ) {
      if (byRadio.length < 2) return;
      final groups = <String, List<String>>{};
      for (final e in byRadio.entries) {
        groups.putIfAbsent(e.value, () => []).add(e.key);
      }
      if (groups.length < 2) return;
      final order = groups.entries.toList()
        ..sort((a, b) => b.value.length.compareTo(a.value.length));
      final parts = <String>[];
      if (order.length == 2 &&
          order[1].value.length == 1 &&
          order[0].value.length > 1) {
        parts.add('${order[1].value.single} is ${say(order[1].key)}');
        parts.add('the others are ${say(order[0].key)}');
      } else {
        for (final g in order) {
          parts.add(
            '${_names(g.value)} ${g.value.length == 1 ? 'is' : 'are'} '
            '${say(g.key)}',
          );
        }
      }
      out.add('$label: ${parts.join(', ')}.');
    }

    field('Frequency slot', {
      for (final r in read)
        if (r.reading!.slot != null) r.name: slotText(r.reading!.slot),
    }, (v) => 'on slot $v');
    field('Hop limit', {
      for (final r in read)
        if (r.reading!.hop != null) r.name: '${r.reading!.hop}',
    }, (v) => 'set to $v');
    final names = <String>{for (final r in read) ...r.reading!.precisions.keys};
    for (final n in names) {
      field('Location precision of $n', {
        for (final r in read)
          if (r.reading!.precisions[n] != null)
            r.name: radioPrecisionText(r.reading!.precisions[n]!),
      }, (v) => 'set to $v');
    }
    return out;
  }

  static String _names(List<String> n) => n.length <= 2
      ? n.join(' and ')
      : '${n.sublist(0, n.length - 1).join(', ')} and ${n.last}';
}
