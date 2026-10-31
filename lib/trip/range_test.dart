import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'geo.dart';

/// Range test markers (v2.5.9): where a radio connected to / dropped off the
/// home radio while driving. They come from the range test script on the PC
/// (`range_state.json`), from pasted text, or from a file; they live only on
/// this device (never sent over the air) and show on the Trip map as green
/// "connected" and red "dropped" markers.
enum RangeKind { connect, drop }

/// How far a blurred position (Meshtastic precision 13) can be off.
const double rangeBlurM = 3000;

class RangeEvent {
  RangeEvent({
    required this.kind,
    required this.at,
    required this.pos,
    this.snr,
    this.hops,
    this.distM,
    this.approximate = true,
  });

  final RangeKind kind;
  final DateTime at;
  final GeoPoint pos;
  final double? snr;

  /// 0 = heard directly.
  final int? hops;

  /// Metres from the home radio, as the test measured it.
  final double? distM;

  /// The position is a blurred one (about 3 km), not an exact fix.
  final bool approximate;

  /// Same kind at the same second = the same event (re-imports do not double).
  String get id => '${kind.name}:${at.millisecondsSinceEpoch ~/ 1000}';

  Map<String, Object?> toJson() => {
    'k': kind.name,
    'at': at.millisecondsSinceEpoch,
    'la': pos.lat,
    'lo': pos.lng,
    if (snr != null) 'snr': snr,
    if (hops != null) 'h': hops,
    if (distM != null) 'd': distM,
    'ap': approximate,
  };

  static RangeEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final kind = RangeKind.values.firstWhere((k) => k.name == j['k']);
      final p = GeoPoint(
        (j['la'] as num).toDouble(),
        (j['lo'] as num).toDouble(),
      );
      if (!p.valid) return null;
      return RangeEvent(
        kind: kind,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
        pos: p,
        snr: (j['snr'] as num?)?.toDouble(),
        hops: (j['h'] as num?)?.toInt(),
        distM: (j['d'] as num?)?.toDouble(),
        approximate: j['ap'] != false,
      );
    } catch (_) {
      return null;
    }
  }

  /// One line that can be pasted into Stalkie Talkie on another device.
  String toLine() =>
      '$rangeTextTag ${kind.name.toUpperCase()} '
      '${at.millisecondsSinceEpoch ~/ 1000} '
      'snr=${snr ?? '-'} hops=${hops ?? '-'} '
      'pos=${pos.lat.toStringAsFixed(7)},${pos.lng.toStringAsFixed(7)} '
      'dist=${distM == null ? '-' : distM!.round()} '
      'approx=${approximate ? 1 : 0}';

  static RangeEvent? fromLine(String line) {
    final t = line.trim().split(RegExp(r'\s+'));
    if (t.length < 4 || t[0] != rangeTextTag) return null;
    final kind = switch (t[1].toUpperCase()) {
      'CONNECT' => RangeKind.connect,
      'DROP' => RangeKind.drop,
      _ => null,
    };
    final secs = int.tryParse(t[2]);
    if (kind == null || secs == null) return null;
    final kv = <String, String>{};
    for (final x in t.skip(3)) {
      final i = x.indexOf('=');
      if (i > 0) kv[x.substring(0, i)] = x.substring(i + 1);
    }
    final ll = (kv['pos'] ?? '').split(',');
    if (ll.length != 2) return null;
    final lat = double.tryParse(ll[0]), lng = double.tryParse(ll[1]);
    if (lat == null || lng == null) return null;
    final p = GeoPoint(lat, lng);
    if (!p.valid) return null;
    return RangeEvent(
      kind: kind,
      at: DateTime.fromMillisecondsSinceEpoch(secs * 1000),
      pos: p,
      snr: double.tryParse(kv['snr'] ?? ''),
      hops: int.tryParse(kv['hops'] ?? ''),
      distM: double.tryParse(kv['dist'] ?? ''),
      approximate: kv['approx'] != '0',
    );
  }
}

const String rangeTextTag = 'STALKIE-RANGE-1';

/// One logged point from the phone's own range logging (v2.5.9).
enum SampleKind {
  /// A ping to the home radio was answered (two-way link).
  ok,

  /// A ping got no answer.
  fail,

  /// A packet from the home radio was heard (one way, no ping).
  heard,
}

class RangeSample {
  const RangeSample({
    required this.at,
    required this.pos,
    required this.kind,
    this.snr,
    this.rssi,
    this.hops,
    this.from,
  });
  final DateTime at;

  /// The phone's own GPS fix when the ping went out / the packet came in.
  final GeoPoint pos;
  final SampleKind kind;
  final double? snr;
  final int? rssi;
  final int? hops;

  /// Node number of the radio that was heard.
  final int? from;

  Map<String, Object?> toJson() => {
    't': at.millisecondsSinceEpoch,
    'la': double.parse(pos.lat.toStringAsFixed(6)),
    'lo': double.parse(pos.lng.toStringAsFixed(6)),
    'k': kind.name,
    if (snr != null) 's': snr,
    if (rssi != null) 'r': rssi,
    if (hops != null) 'h': hops,
    if (from != null) 'f': from,
  };

  static RangeSample? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final p = GeoPoint(
        (j['la'] as num).toDouble(),
        (j['lo'] as num).toDouble(),
      );
      if (!p.valid) return null;
      return RangeSample(
        at: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
        pos: p,
        kind: SampleKind.values.firstWhere((k) => k.name == j['k']),
        snr: (j['s'] as num?)?.toDouble(),
        rssi: (j['r'] as num?)?.toInt(),
        hops: (j['h'] as num?)?.toInt(),
        from: (j['f'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  String get csvLine =>
      '${at.toUtc().toIso8601String()},${at.millisecondsSinceEpoch ~/ 1000},'
      '${pos.lat.toStringAsFixed(6)},${pos.lng.toStringAsFixed(6)},'
      '${switch (kind) {
        SampleKind.ok => 'reply',
        SampleKind.fail => 'no_reply',
        SampleKind.heard => 'heard',
      }},'
      '${snr ?? ''},${rssi ?? ''},${hops ?? ''},'
      '${from == null ? '' : '!${from!.toRadixString(16).padLeft(8, '0')}'}';

  static const csvHeader =
      'time_utc,unix_s,lat,lon,result,snr_db,rssi_dbm,hops,from';
}

/// The home radio that range logging listens for and pings by default:
/// Skunk Ape.
const int defaultRangeHomeNode = 0x0b4f84fb;

/// Logged points kept (about 80 bytes each, so about 400 KB at most); the
/// oldest go first.
const int maxRangeSamples = 5000;

class RangeImport {
  const RangeImport({this.added = 0, this.updated = 0, this.noPlace = 0});

  /// New markers.
  final int added;

  /// Markers already there (same event).
  final int updated;

  /// Connects / drops the test could not place (no position).
  final int noPlace;

  int get found => added + updated;
}

/// "05:44:34 PM" or "17:44:34" as seconds into the day, null if unreadable.
int? _secondsOfDay(String s) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?\s*$')
      .firstMatch(s);
  if (m == null) return null;
  var h = int.parse(m[1]!);
  final min = int.parse(m[2]!), sec = int.parse(m[3] ?? '0');
  final ap = m[4]?.toLowerCase();
  if (ap != null) {
    if (h < 1 || h > 12) return null;
    h = h % 12 + (ap == 'pm' ? 12 : 0);
  }
  if (h > 23 || min > 59 || sec > 59) return null;
  return h * 3600 + min * 60 + sec;
}

/// Read the range test script's `range_state.json` (events with only a time
/// of day). Dates are worked out backwards from `end` (when the test stops),
/// or from [anchor] (file time / now): no event is later than that.
RangeImport parseRangeState(
  String text, {
  DateTime? anchor,
  required bool approximate,
  required List<RangeEvent> into,
}) {
  final j = jsonDecode(text);
  if (j is! Map || j['events'] is! List) {
    throw const FormatException('Not a range test file');
  }
  var top = anchor ?? DateTime.now();
  final end = j['end'];
  if (end is num) {
    final e = DateTime.fromMillisecondsSinceEpoch((end * 1000).round());
    if (e.isBefore(top)) top = e;
  }
  final events = (j['events'] as List).whereType<Map>().toList();
  var noPlace = 0;
  var cursor = top;
  final out = <RangeEvent>[];
  for (final e in events.reversed) {
    final kind = switch ('${e['kind']}'.toUpperCase()) {
      'CONNECT' => RangeKind.connect,
      'DROP' => RangeKind.drop,
      _ => null,
    };
    final secs = _secondsOfDay('${e['time']}');
    if (secs == null) continue;
    var at = DateTime(
      cursor.year,
      cursor.month,
      cursor.day,
      secs ~/ 3600,
      secs % 3600 ~/ 60,
      secs % 60,
    );
    if (at.isAfter(cursor)) {
      at = DateTime(
        cursor.year,
        cursor.month,
        cursor.day - 1,
        secs ~/ 3600,
        secs % 3600 ~/ 60,
        secs % 60,
      );
    }
    cursor = at;
    if (kind == null) continue; // START_NO_CONTACT and the like
    final lat = (e['lat'] as num?)?.toDouble();
    final lon = (e['lon'] as num?)?.toDouble();
    final p = lat == null || lon == null ? null : GeoPoint(lat, lon);
    if (p == null || !p.valid) {
      noPlace++;
      continue;
    }
    out.add(
      RangeEvent(
        kind: kind,
        at: at,
        pos: p,
        snr: (e['snr'] as num?)?.toDouble(),
        hops: (e['hops'] as num?)?.toInt(),
        distM: (e['dist_m'] as num?)?.toDouble(),
        approximate: approximate,
      ),
    );
  }
  into.addAll(out.reversed);
  return RangeImport(noPlace: noPlace);
}

/// The markers, saved in `range_test.json`. Local to this device.
class RangeTest extends ChangeNotifier {
  /// [file] null = keep in memory only (tests).
  RangeTest(this.file);
  final File? file;

  final Map<String, RangeEvent> _events = {};

  /// Show the markers on the Trip map.
  bool visible = true;

  /// Positions in new imports are exact (the radio shares full precision)
  /// instead of blurred. Applies to imports only.
  bool importExact = false;

  // ---- range logging on this phone (v2.5.9); off until switched on

  /// Log what the connected radio hears from [homeNode] and ping it.
  bool logging = false;

  /// The radio to listen for and ping (a node number).
  int homeNode = defaultRangeHomeNode;

  /// Seconds between pings on battery (60 to 120). Plugged in it is 30.
  int pingSecs = 90;

  final List<RangeSample> _samples = [];
  File? get _samplesFile =>
      file == null ? null : File('${file!.parent.path}/range_samples.jsonl');
  int _samplesOnDisk = 0;

  /// Oldest first.
  List<RangeSample> get samples => List.unmodifiable(_samples);

  /// Oldest first.
  List<RangeEvent> get events =>
      _events.values.toList()..sort((a, b) => a.at.compareTo(b.at));
  bool get isEmpty => _events.isEmpty;

  /// Markers or logged points exist, or logging is on.
  bool get hasAny => _events.isNotEmpty || _samples.isNotEmpty || logging;
  int get length => _events.length;

  Future<void> load() async {
    await _loadMain();
    await _loadSamples();
    notifyListeners();
  }

  Future<void> _loadSamples() async {
    final f = _samplesFile;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      _samples.clear();
      for (final line in const LineSplitter().convert(await f.readAsString())) {
        try {
          final x = RangeSample.fromJson(jsonDecode(line));
          if (x != null) _samples.add(x);
        } catch (_) {}
      }
      _samplesOnDisk = _samples.length;
      if (_samples.length > maxRangeSamples) {
        _samples.removeRange(0, _samples.length - maxRangeSamples);
        await _rewriteSamples();
      }
    } catch (_) {}
  }

  /// File work on the points runs one after the other (an append never
  /// races a clear).
  Future<void> _io = Future<void>.value();
  Future<void> _queue(Future<void> Function() job) =>
      _io = _io.then((_) => job()).catchError((_) {});

  /// Waits for every pending file write (tests, export).
  Future<void> flush() => file == null ? Future<void>.value() : _io;

  Future<void> _rewriteSamples() async {
    final f = _samplesFile;
    if (f == null) return;
    final lines = _samples.map((x) => '${jsonEncode(x.toJson())}\n').join();
    final n = _samples.length;
    await _queue(() async {
      await f.parent.create(recursive: true);
      await f.writeAsString(lines);
      _samplesOnDisk = n;
    });
  }

  /// One logged point: appended to the file (no rewrite), the oldest drop
  /// off at [maxRangeSamples].
  Future<void> addSample(RangeSample x) async {
    _samples.add(x);
    final over = _samples.length > maxRangeSamples;
    if (over) _samples.removeAt(0);
    notifyListeners();
    final f = _samplesFile;
    if (f == null) return;
    if (over && _samplesOnDisk >= maxRangeSamples + 250) {
      await _rewriteSamples(); // compact once per 250 points
      return;
    }
    _samplesOnDisk++;
    final line = '${jsonEncode(x.toJson())}\n';
    await _queue(() async {
      await f.parent.create(recursive: true);
      await f.writeAsString(line, mode: FileMode.append);
    });
  }

  Future<void> clearSamples() async {
    if (_samples.isEmpty) return;
    _samples.clear();
    _samplesOnDisk = 0;
    notifyListeners();
    final f = _samplesFile;
    if (f == null) return;
    await _queue(() async {
      if (await f.exists()) await f.delete();
    });
  }

  /// CSV of every logged point (and nothing about keys or channels).
  String samplesCsv() =>
      '${RangeSample.csvHeader}\n${_samples.map((x) => x.csvLine).join('\n')}\n';

  /// JSON with the logged points and the connect / drop markers.
  String exportJson() => const JsonEncoder.withIndent(' ').convert({
    'app': 'Stalkie Talkie range log',
    'home': '!${homeNode.toRadixString(16).padLeft(8, '0')}',
    'points': [for (final x in _samples) x.toJson()],
    'events': [for (final e in events) e.toJson()],
  });

  Future<void> setLogging(bool v) async {
    if (v == logging) return;
    logging = v;
    notifyListeners();
    await _save();
  }

  Future<void> setHomeNode(int n) async {
    if (n == homeNode) return;
    homeNode = n;
    notifyListeners();
    await _save();
  }

  Future<void> setPingSecs(int s) async {
    final v = s.clamp(60, 120);
    if (v == pingSecs) return;
    pingSecs = v;
    notifyListeners();
    await _save();
  }

  Future<void> _loadMain() async {
    final file = this.file;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString());
      if (j is! Map) return;
      visible = j['visible'] != false;
      importExact = j['exact'] == true;
      logging = j['log'] == true;
      homeNode = (j['home'] as num?)?.toInt() ?? defaultRangeHomeNode;
      pingSecs = ((j['ping'] as num?)?.toInt() ?? 90).clamp(60, 120);
      for (final x in (j['events'] as List?) ?? const []) {
        final e = RangeEvent.fromJson(x);
        if (e != null) _events[e.id] = e;
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'visible': visible,
          'exact': importExact,
          'log': logging,
          'home': homeNode,
          'ping': pingSecs,
          'events': [for (final e in events) e.toJson()],
        }),
      );
    } catch (_) {}
  }

  Future<RangeImport> add(List<RangeEvent> list, {int noPlace = 0}) async {
    var added = 0, updated = 0;
    for (final e in list) {
      if (_events.containsKey(e.id)) {
        updated++;
      } else {
        added++;
      }
      _events[e.id] = e;
    }
    if (list.isNotEmpty) {
      notifyListeners();
      await _save();
    }
    return RangeImport(added: added, updated: updated, noPlace: noPlace);
  }

  /// [text] is a `range_state.json` or lines copied from "Copy markers".
  /// Throws [FormatException] when it is neither.
  Future<RangeImport> importText(String text, {DateTime? anchor}) async {
    final t = text.trim().replaceFirst('\uFEFF', '');
    final list = <RangeEvent>[];
    var noPlace = 0;
    if (t.startsWith('{')) {
      noPlace = parseRangeState(
        t,
        anchor: anchor,
        approximate: !importExact,
        into: list,
      ).noPlace;
    } else {
      for (final line in const LineSplitter().convert(t)) {
        if (!line.contains(rangeTextTag)) continue;
        final e = RangeEvent.fromLine(
          line.substring(line.indexOf(rangeTextTag)),
        );
        if (e != null) list.add(e);
      }
      if (list.isEmpty) {
        throw const FormatException('No range test markers in that text');
      }
    }
    return add(list, noPlace: noPlace);
  }

  /// Import from the range test's file (`range_state.json`).
  Future<RangeImport> importFile(File f) async {
    final text = await f.readAsString();
    return importText(text, anchor: await f.lastModified());
  }

  Future<void> remove(RangeEvent e) async {
    if (_events.remove(e.id) == null) return;
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    if (_events.isEmpty) return;
    _events.clear();
    notifyListeners();
    await _save();
  }

  Future<void> setVisible(bool v) async {
    if (v == visible) return;
    visible = v;
    notifyListeners();
    await _save();
  }

  Future<void> setImportExact(bool v) async {
    if (v == importExact) return;
    importExact = v;
    notifyListeners();
    await _save();
  }

  /// All markers as lines to paste into the app on another device.
  String toText() => [for (final e in events) e.toLine()].join('\n');

  // ---------------------------------------------- the PC's range test file

  DateTime? _pcSeen;

  /// Windows: the range test script writes `%USERPROFILE%\meshtastic_watch\
  /// range_state.json`. Imported when it is new or changed; one file-time
  /// check, no polling of the radio. Null = nothing new.
  Future<RangeImport?> importFromPc({File? file}) async {
    final f = file ?? pcRangeFile();
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      final m = await f.lastModified();
      if (_pcSeen != null && !m.isAfter(_pcSeen!)) return null;
      final r = await importFile(f);
      _pcSeen = m;
      return r;
    } catch (_) {
      return null;
    }
  }

  static File? pcRangeFile() {
    if (!Platform.isWindows) return null;
    final home = Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return null;
    return File('$home\\meshtastic_watch\\range_state.json');
  }
}
