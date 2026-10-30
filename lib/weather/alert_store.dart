import 'dart:convert';
import 'dart:io';

import '../trip/geo.dart';
import 'wx_alert.dart';

/// What an NWS `/points` lookup said about a place: its zones.
class WxZones {
  const WxZones({
    required this.zones,
    required this.at,
    this.place = '',
    this.supported = true,
  });

  /// Forecast zone and county zone (`ORZ006`, `ORC051`), the ones alerts
  /// are addressed to.
  final List<String> zones;
  final DateTime at;

  /// "Portland, OR".
  final String place;

  /// False for places the NWS does not cover (outside the US).
  final bool supported;

  Map<String, Object?> toJson() => {
    'z': zones,
    't': at.millisecondsSinceEpoch,
    if (place.isNotEmpty) 'p': place,
    if (!supported) 'u': true,
  };

  static WxZones? fromJson(Object? j) {
    if (j is! Map || j['t'] is! num) return null;
    return WxZones(
      zones: [
        if (j['z'] is List)
          for (final z in j['z'] as List)
            if (z is String) z,
      ],
      at: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
      place: (j['p'] as String?) ?? '',
      supported: j['u'] != true,
    );
  }
}

/// What one ingest changed.
class WxIngest {
  final List<WxAlert> added = [];
  final List<WxAlert> updated = [];
  final List<WxAlert> removed = [];

  /// Alerts the phone must notify for now (new, or escalated), in order of
  /// importance.
  final List<WxAlert> toNotify = [];

  bool get changed =>
      added.isNotEmpty || updated.isNotEmpty || removed.isNotEmpty;
}

/// The alerts the phone knows about, kept in `alerts.json` so they survive
/// a restart and are never notified twice. It is the one place every source
/// (internet now; relay and radio in the next stages) feeds: it dedupes by
/// [WxAlert.key], keeps the newest revision, honours cancels and expiry.
class AlertStore {
  AlertStore({this.file, DateTime Function()? clock, Set<WxKind>? kinds})
    : _clock = clock ?? DateTime.now,
      kinds = kinds ?? kDefaultWxKinds;

  /// Null = memory only (tests).
  final File? file;
  final DateTime Function() _clock;

  /// Kinds kept and notified.
  Set<WxKind> kinds;

  final Map<String, WxAlert> _alerts = {};

  /// Cancelled events: key -> rev of the cancel, so an older copy arriving
  /// late (relay, radio) does not bring it back. Dropped once expired.
  final Map<String, ({int rev, int until})> _cancelled = {};

  /// Rounded place -> its zones.
  final Map<String, WxZones> zones = {};

  /// Last place we knew where the phone was (so a restart can still check).
  GeoPoint? lastFix;
  DateTime? lastFixAt;

  /// When the internet check last worked.
  DateTime? lastChecked;

  /// Every alert still in force, most important first.
  List<WxAlert> active([DateTime? now]) {
    final t = now ?? _clock();
    final l = [
      for (final a in _alerts.values)
        if (a.activeAt(t)) a,
    ];
    l.sort((a, b) {
      if (a.isExtreme != b.isExtreme) return a.isExtreme ? -1 : 1;
      final s = b.severity.index.compareTo(a.severity.index);
      if (s != 0) return s;
      return b.issued.compareTo(a.issued);
    });
    return l;
  }

  WxAlert? byKey(String key) => _alerts[key];

  int get length => _alerts.length;

  /// Take [incoming] (all from [source]). When [authoritative] is a set of
  /// zones, [incoming] is the complete list of what is active there: our
  /// internet alerts for those zones that are missing from it were
  /// cancelled or withdrawn, and internet alerts for no zone we watch any
  /// more are dropped.
  WxIngest ingest(Iterable<WxAlert> incoming, {Set<String>? authoritative}) {
    final now = _clock();
    final r = WxIngest();
    final seen = <String>{};
    for (final a in incoming) {
      if (a.isCancel) {
        _cancel(a, r);
        continue;
      }
      if (!kinds.contains(a.kind)) continue;
      if (!a.activeAt(now)) continue;
      final dead = _cancelled[a.key];
      if (dead != null && a.rev <= dead.rev) continue;
      seen.add(a.key);
      // A message replacing older ones with other ids (alerts without
      // VTEC): drop those, keep "already notified".
      var inherited = false;
      for (final k in [
        for (final e in _alerts.entries)
          if (e.key != a.key &&
              e.value.nwsId != null &&
              a.refs.contains(e.value.nwsId))
            e.key,
      ]) {
        final old = _alerts.remove(k)!;
        inherited = inherited || old.notified;
        r.removed.add(old);
      }
      final old = _alerts[a.key];
      if (old == null) {
        final n = inherited ? a.copyWith(notified: true) : a;
        _alerts[a.key] = n;
        r.added.add(n);
        if (!n.notified) r.toNotify.add(n);
        continue;
      }
      if (a.rev < old.rev) continue;
      if (a.rev == old.rev && a.trust.index <= old.trust.index) continue;
      // Same event, newer text. Notify again only if it got worse.
      final worse =
          (a.isExtreme && !old.isExtreme) ||
          a.severity.index > old.severity.index;
      final n = a.copyWith(
        notified: old.notified && !worse,
        firstSeen: old.firstSeen,
        // The most trusted copy wins: our own NWS read beats a relay or
        // radio copy, which beats an unconfirmed one (a radio alert is
        // upgraded when this phone checks the NWS itself).
        source: a.trust.index >= old.trust.index ? a.source : old.source,
        trust: a.trust.index >= old.trust.index ? a.trust : old.trust,
      );
      _alerts[a.key] = n;
      r.updated.add(n);
      if (!n.notified) r.toNotify.add(n);
    }
    if (authoritative != null) {
      for (final e in _alerts.entries.toList()) {
        final a = e.value;
        if (a.source != WxSource.nws || seen.contains(e.key)) continue;
        // Not in the answer for the zones we asked about (cancelled early,
        // or for a place we no longer watch): gone. With no zone listed we
        // cannot tell, so it stays until it expires.
        if (a.ugc.isEmpty) continue;
        _alerts.remove(e.key);
        r.removed.add(a);
      }
    }
    _prune(now, r);
    r.toNotify.sort((a, b) {
      if (a.isExtreme != b.isExtreme) return a.isExtreme ? -1 : 1;
      return b.severity.index.compareTo(a.severity.index);
    });
    return r;
  }

  void _cancel(WxAlert c, WxIngest r) {
    _cancelled[c.key] = (rev: c.rev, until: c.expiresAt.millisecondsSinceEpoch);
    final old = _alerts[c.key];
    if (old != null && c.rev >= old.rev) {
      _alerts.remove(c.key);
      r.removed.add(old);
    }
    for (final id in c.refs) {
      for (final k in [
        for (final e in _alerts.entries)
          if (e.value.nwsId == id) e.key,
      ]) {
        r.removed.add(_alerts.remove(k)!);
      }
    }
  }

  void _prune(DateTime now, WxIngest? r) {
    for (final k in [
      for (final e in _alerts.entries)
        if (!e.value.activeAt(now)) e.key,
    ]) {
      final a = _alerts.remove(k)!;
      r?.removed.add(a);
    }
    _cancelled.removeWhere((_, v) => v.until < now.millisecondsSinceEpoch);
  }

  /// Drop what expired (also called when the clock passes an expiry).
  List<WxAlert> expire() {
    final r = WxIngest();
    _prune(_clock(), r);
    return r.removed;
  }

  void markNotified(String key) {
    final a = _alerts[key];
    if (a != null) a.notified = true;
  }

  // ------------------------------------------------------------ persistence

  Future<void> load() async {
    final f = file;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      _alerts.clear();
      for (final x in (j['alerts'] as List?) ?? const []) {
        final a = WxAlert.fromJson(x);
        if (a != null) _alerts[a.key] = a;
      }
      final c = j['cancelled'];
      if (c is Map) {
        for (final e in c.entries) {
          final v = e.value;
          if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
            _cancelled['${e.key}'] = (
              rev: (v[0] as num).toInt(),
              until: (v[1] as num).toInt(),
            );
          }
        }
      }
      final z = j['zones'];
      if (z is Map) {
        for (final e in z.entries) {
          final w = WxZones.fromJson(e.value);
          if (w != null) zones['${e.key}'] = w;
        }
      }
      final fx = j['fix'];
      if (fx is Map && fx['lat'] is num && fx['lng'] is num) {
        lastFix = GeoPoint(
          (fx['lat'] as num).toDouble(),
          (fx['lng'] as num).toDouble(),
        );
        lastFixAt = fx['t'] is num
            ? DateTime.fromMillisecondsSinceEpoch((fx['t'] as num).toInt())
            : null;
      }
      if (j['checked'] is num) {
        lastChecked = DateTime.fromMillisecondsSinceEpoch(
          (j['checked'] as num).toInt(),
        );
      }
      _prune(_clock(), null);
    } catch (_) {}
  }

  Future<void> save() async {
    final f = file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'v': 1,
          'alerts': [for (final a in _alerts.values) a.toJson()],
          'cancelled': {
            for (final e in _cancelled.entries)
              e.key: [e.value.rev, e.value.until],
          },
          'zones': {for (final e in zones.entries) e.key: e.value.toJson()},
          if (lastFix != null)
            'fix': {
              'lat': lastFix!.lat,
              'lng': lastFix!.lng,
              't': lastFixAt?.millisecondsSinceEpoch,
            },
          if (lastChecked != null)
            'checked': lastChecked!.millisecondsSinceEpoch,
        }),
      );
      await tmp.rename(f.path);
    } catch (_) {}
  }
}
