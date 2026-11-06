import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'geo.dart';
import 'range_logger.dart';
import 'range_test.dart';
import 'track.dart' show toGpx;
import 'trip_packet.dart' show TrackPt;

/// One-tap range test (v2.6.10). A thin layer on the v2.5.9 range logging:
/// Start turns Range logging on (pings to the home radio, passive packets,
/// no-reply points, connect / drop markers, phone exact GPS per point) and
/// remembers when it started; Stop turns logging back to how it was and
/// works out a summary of just this run. Nothing new is sent over the air
/// and the battery use is exactly Range logging's. It stops by itself after
/// [maxMinutes] (default 3 h) and says so with a notification.
class RangeRun extends ChangeNotifier {
  RangeRun({
    required this.store,
    required this.logger,
    this.file,
    DateTime Function()? clock,
    this.onAutoStop,
    GeoPoint? Function(int node)? homePos,
  }) : _clock = clock ?? DateTime.now,
       _homePosOf = homePos {
    store.addListener(_onStore);
  }

  final RangeTest store;
  final RangeLogger logger;

  /// `range_run.json` (null = memory only, tests).
  final File? file;
  final DateTime Function() _clock;
  final GeoPoint? Function(int node)? _homePosOf;

  /// Called once when the run stops by itself (the app shows a
  /// notification).
  void Function(RangeRunSummary s)? onAutoStop;

  static const int defaultMaxMinutes = 180;

  /// The choices for "Stop by itself after".
  static const List<int> maxChoices = [30, 60, 120, 180, 240, 360, 480];

  DateTime? _startedAt;
  bool _prevLogging = false;
  int maxMinutes = defaultMaxMinutes;
  Timer? _auto;
  bool _disposed = false;

  /// The home radio's position, kept from the last time it was known (the
  /// radio's node list or the v2.6.6 home location), so the summary still
  /// has distances after the radio disconnects.
  GeoPoint? _homePos;

  /// The summary of the last finished run (shown again from the strip).
  RangeRunSummary? last;

  bool get running => _startedAt != null;
  DateTime? get startedAt => _startedAt;
  Duration get maxDuration => Duration(minutes: maxMinutes);

  Duration get elapsed =>
      _startedAt == null ? Duration.zero : _clock().difference(_startedAt!);

  /// When it will stop by itself.
  DateTime? get stopsAt => _startedAt?.add(maxDuration);

  GeoPoint? get homePos {
    final p = _homePosOf?.call(store.homeNode);
    if (p != null && p.valid) _homePos = p;
    return _homePos;
  }

  /// Points logged in this run (oldest first).
  List<RangeSample> get samples => _window(_startedAt, null);

  List<RangeSample> _window(DateTime? from, DateTime? to) {
    if (from == null) return const [];
    return [
      for (final x in store.samples)
        if (!x.at.isBefore(from) && (to == null || !x.at.isAfter(to))) x,
    ];
  }

  List<RangeEvent> _events(DateTime from, DateTime? to) => [
    for (final e in store.events)
      if (!e.approximate &&
          !e.at.isBefore(from) &&
          (to == null || !e.at.isAfter(to)))
        e,
  ];

  /// What the live strip shows.
  RangeRunLive get live => RangeRunLive.of(samples, homePos, elapsed);

  Future<void> load() async {
    final f = file;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      maxMinutes = _clampMax((j['max'] as num?)?.toInt());
      _prevLogging = j['prev'] == true;
      final s = (j['start'] as num?)?.toInt();
      _startedAt = s == null ? null : DateTime.fromMillisecondsSinceEpoch(s);
      final la = (j['hla'] as num?)?.toDouble();
      final lo = (j['hlo'] as num?)?.toDouble();
      if (la != null && lo != null) _homePos = GeoPoint(la, lo);
      last = RangeRunSummary.fromJson(j['last']);
    } catch (_) {}
    if (_startedAt != null) {
      // The app was closed during a run: carry on, or stop it now when its
      // time is up.
      if (!store.logging) await store.setLogging(true);
      _arm();
    }
    notifyListeners();
  }

  static int _clampMax(int? m) => (m ?? defaultMaxMinutes).clamp(15, 720);

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    final h = _homePos;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          'max': maxMinutes,
          'prev': _prevLogging,
          if (_startedAt != null) 'start': _startedAt!.millisecondsSinceEpoch,
          if (h != null) 'hla': h.lat,
          if (h != null) 'hlo': h.lng,
          if (last != null) 'last': last!.toJson(),
        }),
      );
    } catch (_) {}
  }

  Future<void> setMaxMinutes(int m) async {
    final v = _clampMax(m);
    if (v == maxMinutes) return;
    maxMinutes = v;
    if (running) _arm();
    notifyListeners();
    await _save();
  }

  /// Starts a run against [home] (null = the Range logging home radio,
  /// Skunk Ape by default). Turns Range logging on.
  Future<void> start({int? home}) async {
    if (running) return;
    if (home != null) await store.setHomeNode(home);
    _prevLogging = store.logging;
    _startedAt = _clock();
    homePos;
    await store.setLogging(true);
    _arm();
    notifyListeners();
    await _save();
  }

  void _arm() {
    _auto?.cancel();
    final until = stopsAt;
    if (until == null || _disposed) return;
    var wait = until.difference(_clock());
    if (wait.isNegative) wait = Duration.zero;
    _auto = Timer(wait, () => unawaited(_autoStop()));
  }

  Future<void> _autoStop() async {
    if (!running || _disposed) return;
    final s = await stop(auto: true);
    if (s != null) onAutoStop?.call(s);
  }

  /// Tests: the auto-stop timer fired.
  @visibleForTesting
  Future<void> autoStopNow() => _autoStop();

  /// Ends the run: Range logging goes back to how it was before Start, and
  /// the summary of this run is kept in [last].
  Future<RangeRunSummary?> stop({bool auto = false}) async {
    final from = _startedAt;
    if (from == null) return null;
    _auto?.cancel();
    _auto = null;
    final end = _clock();
    final capped = auto && end.isAfter(stopsAt!) ? stopsAt! : end;
    _startedAt = null;
    final s = RangeRunSummary.of(
      startedAt: from,
      endedAt: capped,
      home: store.homeNode,
      homeName:
          logger.radio?.nameOf(store.homeNode) ??
          last?.homeName ??
          radioNodeLabel(store.homeNode),
      samples: _window(from, end),
      events: _events(from, end),
      homePos: homePos,
      autoStopped: auto,
    );
    last = s;
    if (!_prevLogging) await store.setLogging(false);
    notifyListeners();
    await _save();
    return s;
  }

  /// Points of [s]'s run, for the exports.
  List<RangeSample> samplesOf(RangeRunSummary s) =>
      _window(s.startedAt, s.endedAt);

  /// CSV of the run: the Range logging columns plus distance from home.
  String csvOf(RangeRunSummary s) {
    final h = s.homePos;
    final b = StringBuffer('${RangeSample.csvHeader},dist_m\n');
    for (final x in samplesOf(s)) {
      final d = h == null ? '' : distanceM(h, x.pos).round();
      b.writeln('${x.csvLine},$d');
    }
    return b.toString();
  }

  /// GPX of the run: the drive as a track, connect / drop markers and the
  /// furthest reply as waypoints. No keys, channels or messages.
  String gpxOf(RangeRunSummary s, {bool imperial = true}) {
    final pts = samplesOf(s);
    return toGpx(
      'Stalkie Talkie range test ${s.startedAt.toIso8601String().substring(0, 16)}',
      [
        for (final x in pts)
          TrackPt(x.pos, x.at.millisecondsSinceEpoch ~/ 1000),
      ],
      waypoints: [
        for (final e in _events(s.startedAt, s.endedAt))
          (
            pos: e.pos,
            name:
                '${e.kind == RangeKind.connect ? 'Connected' : 'Dropped'}'
                '${e.snr == null ? '' : ' SNR ${e.snr}'}',
            type: e.kind.name,
          ),
        for (final x in pts)
          if (x.kind == SampleKind.fail)
            (pos: x.pos, name: 'No reply', type: 'no_reply'),
        if (s.furthestAt != null)
          (
            pos: s.furthestAt!,
            name:
                'Furthest reply ${formatDistance(s.furthestReplyM!, imperial: imperial)}',
            type: 'furthest',
          ),
      ],
    );
  }

  void _onStore() {
    // Range logging switched off on its page during a run: the run ends.
    if (running && !store.logging) unawaited(stop());
  }

  @override
  void dispose() {
    _disposed = true;
    _auto?.cancel();
    store.removeListener(_onStore);
    super.dispose();
  }
}

/// The live numbers of a running test.
class RangeRunLive {
  const RangeRunLive({
    required this.elapsed,
    this.lastReplyAt,
    this.snr,
    this.hops,
    this.distM,
    this.replies = 0,
    this.noReplies = 0,
    this.heard = 0,
  });

  factory RangeRunLive.of(
    List<RangeSample> xs,
    GeoPoint? home,
    Duration elapsed,
  ) {
    RangeSample? lastOk;
    var ok = 0, fail = 0, heard = 0;
    for (final x in xs) {
      switch (x.kind) {
        case SampleKind.ok:
          ok++;
          lastOk = x;
        case SampleKind.fail:
          fail++;
        case SampleKind.heard:
          heard++;
      }
    }
    return RangeRunLive(
      elapsed: elapsed,
      lastReplyAt: lastOk?.at,
      snr: lastOk?.snr,
      hops: lastOk?.hops,
      distM: lastOk == null || home == null
          ? null
          : distanceM(home, lastOk.pos),
      replies: ok,
      noReplies: fail,
      heard: heard,
    );
  }

  final Duration elapsed;
  final DateTime? lastReplyAt;
  final double? snr;
  final int? hops;

  /// Distance from home at the last reply.
  final double? distM;
  final int replies;
  final int noReplies;
  final int heard;
}

/// What a finished run found.
class RangeRunSummary {
  const RangeRunSummary({
    required this.startedAt,
    required this.endedAt,
    required this.home,
    required this.homeName,
    this.homePos,
    this.replies = 0,
    this.noReplies = 0,
    this.heard = 0,
    this.connects = 0,
    this.drops = 0,
    this.furthestReplyM,
    this.furthestAt,
    this.bestSnr,
    this.worstSnr,
    this.autoStopped = false,
  });

  factory RangeRunSummary.of({
    required DateTime startedAt,
    required DateTime endedAt,
    required int home,
    required String homeName,
    required List<RangeSample> samples,
    required List<RangeEvent> events,
    GeoPoint? homePos,
    bool autoStopped = false,
  }) {
    var ok = 0, fail = 0, heard = 0;
    double? best, worst, far;
    GeoPoint? farAt;
    for (final x in samples) {
      switch (x.kind) {
        case SampleKind.ok:
          ok++;
          if (homePos != null) {
            final d = distanceM(homePos, x.pos);
            if (far == null || d > far) {
              far = d;
              farAt = x.pos;
            }
          }
        case SampleKind.fail:
          fail++;
        case SampleKind.heard:
          heard++;
      }
      final s = x.snr;
      if (x.kind != SampleKind.fail && s != null) {
        if (best == null || s > best) best = s;
        if (worst == null || s < worst) worst = s;
      }
    }
    return RangeRunSummary(
      startedAt: startedAt,
      endedAt: endedAt,
      home: home,
      homeName: homeName,
      homePos: homePos,
      replies: ok,
      noReplies: fail,
      heard: heard,
      connects: events.where((e) => e.kind == RangeKind.connect).length,
      drops: events.where((e) => e.kind == RangeKind.drop).length,
      furthestReplyM: far,
      furthestAt: farAt,
      bestSnr: best,
      worstSnr: worst,
      autoStopped: autoStopped,
    );
  }

  final DateTime startedAt;
  final DateTime endedAt;
  final int home;
  final String homeName;
  final GeoPoint? homePos;
  final int replies;
  final int noReplies;
  final int heard;
  final int connects;
  final int drops;
  final double? furthestReplyM;
  final GeoPoint? furthestAt;
  final double? bestSnr;
  final double? worstSnr;
  final bool autoStopped;

  Duration get duration => endedAt.difference(startedAt);
  int get pings => replies + noReplies;

  /// Answered pings out of all pings, 0 to 100; null = no pings.
  int? get connectedPct => pings == 0 ? null : (replies * 100 / pings).round();

  Map<String, Object?> toJson() => {
    's': startedAt.millisecondsSinceEpoch,
    'e': endedAt.millisecondsSinceEpoch,
    'h': home,
    'n': homeName,
    if (homePos != null) 'hla': homePos!.lat,
    if (homePos != null) 'hlo': homePos!.lng,
    'ok': replies,
    'no': noReplies,
    'he': heard,
    'c': connects,
    'd': drops,
    if (furthestReplyM != null) 'f': furthestReplyM,
    if (furthestAt != null) 'fla': furthestAt!.lat,
    if (furthestAt != null) 'flo': furthestAt!.lng,
    if (bestSnr != null) 'b': bestSnr,
    if (worstSnr != null) 'w': worstSnr,
    'a': autoStopped,
  };

  static RangeRunSummary? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      GeoPoint? p(String a, String b) {
        final la = (j[a] as num?)?.toDouble(), lo = (j[b] as num?)?.toDouble();
        return la == null || lo == null ? null : GeoPoint(la, lo);
      }

      return RangeRunSummary(
        startedAt: DateTime.fromMillisecondsSinceEpoch((j['s'] as num).toInt()),
        endedAt: DateTime.fromMillisecondsSinceEpoch((j['e'] as num).toInt()),
        home: (j['h'] as num).toInt(),
        homeName: '${j['n'] ?? ''}',
        homePos: p('hla', 'hlo'),
        replies: (j['ok'] as num?)?.toInt() ?? 0,
        noReplies: (j['no'] as num?)?.toInt() ?? 0,
        heard: (j['he'] as num?)?.toInt() ?? 0,
        connects: (j['c'] as num?)?.toInt() ?? 0,
        drops: (j['d'] as num?)?.toInt() ?? 0,
        furthestReplyM: (j['f'] as num?)?.toDouble(),
        furthestAt: p('fla', 'flo'),
        bestSnr: (j['b'] as num?)?.toDouble(),
        worstSnr: (j['w'] as num?)?.toDouble(),
        autoStopped: j['a'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Plain text for "Copy summary". No keys, channels or exact home spot.
  String toText({bool imperial = true}) {
    String snr(double? v) => v == null ? 'none' : '$v dB';
    final pct = connectedPct;
    return [
      'Stalkie Talkie range test to $homeName',
      '${formatRunDuration(duration)}'
          '${autoStopped ? ' (stopped by itself at the time limit)' : ''}',
      'Furthest reply: ${furthestReplyM == null ? 'none' : formatDistance(furthestReplyM!, imperial: imperial)}',
      'Best SNR: ${snr(bestSnr)} · Worst SNR: ${snr(worstSnr)}',
      'Connected: ${pct == null ? 'no pings sent' : '$pct% ($replies of $pings pings answered)'}',
      'Replies $replies · No reply $noReplies · Heard $heard packets',
      'Connects $connects · Drops $drops',
    ].join('\n');
  }
}

/// "1 h 05 min", "12 min", "45 s".
String formatRunDuration(Duration d) {
  if (d.isNegative) d = Duration.zero;
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
}
