import 'dart:convert';

/// One programmable quiet-hours span (v1.9.5), e.g. 22:00-07:00 every day.
///
/// [start] / [end] are minutes after midnight. When [end] <= [start] the
/// span runs overnight into the next day ([start] == [end] = 24 hours).
/// [days] are the days it *starts* on (DateTime.monday = 1 ...
/// DateTime.sunday = 7), so "Fri 22:00-07:00" keeps Saturday morning
/// quiet too.
class QuietSchedule {
  QuietSchedule({
    required this.start,
    required this.end,
    Set<int>? days,
    this.enabled = true,
  }) : days = days ?? {1, 2, 3, 4, 5, 6, 7};

  int start;
  int end;
  Set<int> days;
  bool enabled;

  bool get overnight => end <= start;

  static int _prevDay(int weekday) => weekday == 1 ? 7 : weekday - 1;

  static DateTime _at(DateTime day, int minutes) =>
      DateTime(day.year, day.month, day.day).add(Duration(minutes: minutes));

  /// When the span covering [t] began, or null if [t] is not inside one.
  DateTime? _startOf(DateTime t) {
    if (!enabled || days.isEmpty) return null;
    final m = t.hour * 60 + t.minute;
    final today = DateTime(t.year, t.month, t.day);
    if (!overnight) {
      if (days.contains(t.weekday) && m >= start && m < end) {
        return _at(today, start);
      }
      return null;
    }
    if (days.contains(t.weekday) && m >= start) return _at(today, start);
    final yesterday = DateTime(t.year, t.month, t.day - 1);
    final endToday = start == end ? start : end;
    if (days.contains(_prevDay(t.weekday)) && m < endToday) {
      return _at(yesterday, start);
    }
    return null;
  }

  bool covers(DateTime t) => _startOf(t) != null;

  /// End of the span covering [t] (null if none).
  DateTime? endAfter(DateTime t) {
    final s = _startOf(t);
    if (s == null) return null;
    final len = overnight ? (24 * 60 - start + end) : end - start;
    // DST-safe enough: rebuild from the calendar day.
    return DateTime(s.year, s.month, s.day).add(Duration(minutes: start + len));
  }

  Map<String, Object?> toJson() => {
    's': start,
    'e': end,
    'd': (days.toList()..sort()),
    'on': enabled,
  };

  static QuietSchedule? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = j['s'], e = j['e'], d = j['d'];
    if (s is! num || e is! num) return null;
    final start = s.toInt(), end = e.toInt();
    if (start < 0 || start >= 1440 || end < 0 || end >= 1440) return null;
    return QuietSchedule(
      start: start,
      end: end,
      days: d is List
          ? {
              for (final x in d)
                if (x is num && x >= 1 && x <= 7) x.toInt(),
            }
          : null,
      enabled: j['on'] != false,
    );
  }

  static String hhmm(int minutes) =>
      '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

  static const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// "10:00 PM-7:00 AM · Every day" style summary (24 h clock).
  String get label {
    final d = days.length == 7
        ? 'Every day'
        : days.isEmpty
        ? 'No days'
        : (days.toList()..sort()).map((x) => dayNames[x - 1]).join(', ');
    return '${hhmm(start)}–${hhmm(end)} · $d';
  }
}

/// Why a sound was let through while silenced.
enum QuietBypass { none, urgent, repeated, alwaysAllow }

/// Mute and quiet hours (v1.9.5): one place that says whether the phone
/// should stay silent right now and which rings still get through.
///
/// Silenced = live audio is not played (kept in Missed), rings, beeps,
/// join tones and notification sounds stay quiet. Rings, voice messages
/// and chat are kept as usual. With [letUrgentThrough] (default on) an
/// urgent ring or an SOS, a second ring from the same person within
/// [repeatWindow], or a ring from an "Always allow" person still sounds.
class QuietHours {
  QuietHours({
    this.muted = false,
    List<QuietSchedule>? schedules,
    this.letUrgentThrough = true,
    Set<int>? alwaysAllow,
    DateTime Function()? clock,
  }) : schedules = schedules ?? [],
       alwaysAllow = alwaysAllow ?? {},
       _clock = clock ?? DateTime.now;

  /// Hold this long on the mute button to turn mute on or off (v1.9.7:
  /// both ways, a quick tap only shows a hint).
  static const holdToMute = Duration(milliseconds: 1000);

  /// A second ring from the same person within this gets through.
  static const repeatWindow = Duration(minutes: 2);

  /// Manual mute (v1.9.7: a plain on/off switch, no time limit; stays on
  /// until turned off, also across restarts).
  bool muted;
  final List<QuietSchedule> schedules;
  bool letUrgentThrough;

  /// People whose rings always get through (node ids).
  final Set<int> alwaysAllow;
  final DateTime Function() _clock;

  /// Distinct rings heard per person while silenced (id, time).
  final Map<int, List<(int, DateTime)>> _rings = {};

  DateTime get now => _clock();

  /// A quiet-hours schedule covers now.
  bool get inQuietHours => schedules.any((s) => s.covers(now));

  /// Mute or quiet hours: stay silent.
  bool get silenced => muted || inQuietHours;

  /// When the current quiet hours end (latest end of the spans covering
  /// now, following spans that run into each other), or null.
  DateTime? get quietUntil {
    var t = now;
    DateTime? until;
    for (var guard = 0; guard < 8; guard++) {
      DateTime? best;
      for (final s in schedules) {
        final e = s.endAfter(t);
        if (e != null && (best == null || e.isAfter(best))) best = e;
      }
      if (best == null) break;
      until = best;
      t = best; // a schedule starting exactly then continues the quiet
    }
    return until;
  }

  /// Mute until turned off.
  void mute() => muted = true;

  void unmute() => muted = false;

  /// 24 h clock ("7:00", "15:30") for [statusText].
  static String clockFor24(DateTime t) =>
      '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

  /// Short status for the banner / notification, null when not silenced.
  /// [fmt] formats a time ("7:00", "3:45 PM").
  String? statusText(String Function(DateTime) fmt) {
    if (muted) return 'Muted';
    if (inQuietHours) {
      final u = quietUntil;
      return u == null ? 'Quiet hours' : 'Quiet hours until ${fmt(u)}';
    }
    return null;
  }

  /// Should a ring / beep / SOS from [from] make sound now? Records the
  /// ring so a second one (another [ringId]) within [repeatWindow] gets
  /// through. Repeats of the same ring id (rings are re-sent every second
  /// until answered) do not count as a second ring.
  QuietBypass allowRing({required int from, int? ringId, bool urgent = false}) {
    if (!silenced) return QuietBypass.none;
    if (!letUrgentThrough) return QuietBypass.none;
    if (urgent) return QuietBypass.urgent;
    if (alwaysAllow.contains(from)) return QuietBypass.alwaysAllow;
    final t = now;
    final list = _rings.putIfAbsent(from, () => []);
    list.removeWhere((e) => t.difference(e.$2) > repeatWindow);
    final id = ringId ?? t.millisecondsSinceEpoch;
    final other = list.any((e) => e.$1 != id);
    if (!list.any((e) => e.$1 == id)) list.add((id, t));
    if (_rings.length > 200) _rings.remove(_rings.keys.first);
    return other ? QuietBypass.repeated : QuietBypass.none;
  }

  /// True when a ring may sound: not silenced, or let through.
  bool ringSounds({required int from, int? ringId, bool urgent = false}) =>
      !silenced ||
      allowRing(from: from, ringId: ringId, urgent: urgent) != QuietBypass.none;

  // ------------------------------------------------------------ storage

  String encode() => jsonEncode({
    if (muted) 'mf': 1,
    'sc': [for (final s in schedules) s.toJson()],
    'ut': letUrgentThrough,
    'aa': alwaysAllow.toList(),
  });

  static QuietHours decode(String? text, {DateTime Function()? clock}) {
    if (text == null || text.isEmpty) return QuietHours(clock: clock);
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      // v1.9.5/1.9.6 timed mute ("mu": end time): still running -> plain
      // mute (on until turned off); already over -> not muted.
      final mu = j['mu'];
      final now = (clock ?? DateTime.now)();
      final timed =
          mu is num &&
          now.isBefore(DateTime.fromMillisecondsSinceEpoch(mu.toInt()));
      return QuietHours(
        muted: j['mf'] == 1 || timed,
        schedules: [
          for (final s in (j['sc'] as List? ?? const []))
            ?QuietSchedule.fromJson(s),
        ],
        letUrgentThrough: j['ut'] != false,
        alwaysAllow: {
          for (final x in (j['aa'] as List? ?? const []))
            if (x is num) x.toInt(),
        },
        clock: clock,
      );
    } catch (_) {
      return QuietHours(clock: clock);
    }
  }
}
