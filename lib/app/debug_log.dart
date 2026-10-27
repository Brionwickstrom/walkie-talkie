/// Rolling connection log for "Send debug log" (v1.8.7): an in-memory ring
/// buffer plus a small rotating file. Passcodes, keys and precise
/// locations are redacted by default ([redactLog]).
library;

import 'dart:io';

class DebugLog {
  DebugLog({this.capacity = 1500, this.maxFileBytes = 256 * 1024});

  final int capacity;
  final int maxFileBytes;
  final List<String> _lines = [];

  /// Secrets to blank out (passcodes); set by the controller.
  Iterable<String> Function() secrets = () => const [];
  File? _file;
  int _fileBytes = 0;
  DateTime Function() now = DateTime.now;

  List<String> get lines => List.unmodifiable(_lines);

  /// Keep the log in [dir]/debug.log (and debug.log.1 after rotation).
  /// Lines are appended synchronously (a few per minute at most), so
  /// nothing is lost when the app is killed.
  Future<void> attach(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final f = File('${dir.path}/debug.log');
      _fileBytes = await f.exists() ? await f.length() : 0;
      _file = f;
    } catch (_) {
      _file = null;
    }
  }

  void add(String tag, String message) {
    final t = now();
    final line =
        '${t.toIso8601String().substring(0, 23)} [$tag] '
        '${redactLog(message, secrets: secrets())}';
    _lines.add(line);
    if (_lines.length > capacity) {
      _lines.removeRange(0, _lines.length - capacity);
    }
    final f = _file;
    if (f == null) return;
    try {
      if (_fileBytes > maxFileBytes) {
        final prev = File('${f.path}.1');
        if (prev.existsSync()) prev.deleteSync();
        if (f.existsSync()) f.renameSync(prev.path);
        _fileBytes = 0;
      }
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
      _fileBytes += line.length + 1;
    } catch (_) {}
  }

  /// Older lines from the files (previous runs) + this run's buffer,
  /// newest last, at most [maxLines].
  Future<List<String>> history({int maxLines = 4000}) async {
    final out = <String>[];
    final f = _file;
    if (f != null) {
      try {
        final prev = File('${f.path}.1');
        if (await prev.exists()) out.addAll(await prev.readAsLines());
        if (await f.exists()) out.addAll(await f.readAsLines());
      } catch (_) {}
    }
    if (out.isEmpty) out.addAll(_lines);
    return out.length > maxLines ? out.sublist(out.length - maxLines) : out;
  }

  /// The report: [header] lines, then the log (redacted again, in case a
  /// secret was set after a line was written).
  Future<String> report(List<String> header) async {
    final body = await history();
    final s = secrets();
    return [
      ...header,
      '',
      '--- log (${body.length} lines, passcodes / keys / precise locations '
          'redacted) ---',
      for (final l in body) redactLog(l, secrets: s),
    ].join('\n');
  }

  Future<void> clear() async {
    _lines.clear();
    final f = _file;
    if (f == null) return;
    try {
      final prev = File('${f.path}.1');
      if (await prev.exists()) await prev.delete();
      if (await f.exists()) await f.delete();
      _fileBytes = 0;
    } catch (_) {}
  }

  Future<void> close() async {}
}

/// Remove secrets from a log line: the given [secrets] (passcodes),
/// friend codes, key-looking tokens (long base64 / hex), private relay
/// rooms, passcode / key URL parameters and precise coordinates (rounded
/// to 1 decimal, about 10 km).
String redactLog(String line, {Iterable<String> secrets = const []}) {
  var s = line;
  for (final x in secrets) {
    if (x.length >= 3) s = s.replaceAll(x, '[passcode]');
  }
  // v1.9.7: Meshtastic channel links carry the channel key.
  s = s.replaceAllMapped(
    RegExp(r'(meshtastic\.org/[^\s#]*#)\S+', caseSensitive: false),
    (m) => '${m[1]}[redacted]',
  );
  s = s.replaceAllMapped(
    RegExp(r'walkie-friend:[^\s]+'),
    (_) => 'walkie-friend:[redacted]',
  );
  s = s.replaceAllMapped(
    RegExp(r'([?&#](?:p|f|k|key|psk|pass|passcode|code)=)[^&\s]+'),
    (m) => '${m[1]}[redacted]',
  );
  s = s.replaceAllMapped(
    RegExp(r'(passcode|psk|key)(\s*[:=]\s*)\S+', caseSensitive: false),
    (m) => '${m[1]}${m[2]}[redacted]',
  );
  s = s.replaceAllMapped(
    RegExp(r'(ch=|room )([pf])[0-9a-fA-F]{4,}'),
    (m) => '${m[1]}${m[2]}****',
  );
  s = s.replaceAll(RegExp(r'[A-Za-z0-9+/_-]{32,}={0,2}'), '[key]');
  s = s.replaceAll(RegExp(r'\b[0-9a-fA-F]{16,}\b'), '[hex]');
  s = s.replaceAllMapped(
    RegExp(r'(-?\d{1,3}\.\d{3,})(\s*,\s*)(-?\d{1,3}\.\d{3,})'),
    (m) => '${_round(m[1]!)}${m[2]}${_round(m[3]!)}',
  );
  s = s.replaceAllMapped(
    RegExp(
      r'\b(lat|lng|lon|latitude|longitude)(\s*[:=]\s*)(-?\d{1,3}\.\d+)',
      caseSensitive: false,
    ),
    (m) => '${m[1]}${m[2]}${_round(m[3]!)}',
  );
  return s;
}

String _round(String v) {
  final d = double.tryParse(v);
  return d == null ? '[loc]' : '${d.toStringAsFixed(1)}~';
}
