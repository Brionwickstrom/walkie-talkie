import 'dart:convert';

import 'geo.dart';
import 'trip_packet.dart';

/// A recorded trail: points with unix-second timestamps.
class Track {
  Track(this.id, {List<TrackPt>? points, this.name = ''})
    : points = points ?? [];
  final int id;
  String name;
  final List<TrackPt> points;

  double get lengthM => pathLengthM([for (final p in points) p.pos]);

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    'p': [
      for (final p in points) [p.pos.latE5, p.pos.lngE5, p.t ?? 0],
    ],
  };

  static Track? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! num) return null;
    final pts = <TrackPt>[];
    for (final x in (j['p'] as List?) ?? const []) {
      if (x is List && x.length >= 3) {
        pts.add(
          TrackPt(
            GeoPoint.fromE5((x[0] as num).toInt(), (x[1] as num).toInt()),
            (x[2] as num).toInt() == 0 ? null : (x[2] as num).toInt(),
          ),
        );
      }
    }
    return Track(id.toInt(), points: pts, name: (j['n'] as String?) ?? '');
  }
}

/// Records GPS fixes into a [Track], battery-aware: ignores poor fixes
/// and tiny moves, and asks for fixes less often when standing still or in
/// battery saver.
class TrackRecorder {
  TrackRecorder({this.minMoveM = 8, this.maxAccuracyM = 50});

  final double minMoveM;
  final double maxAccuracyM;
  Track? track;
  bool get recording => track != null;
  DateTime? _lastMoveAt;

  void start(int id, {String name = ''}) {
    track = Track(id, name: name);
    _lastMoveAt = null;
  }

  Track? stop() {
    final t = track;
    track = null;
    return t;
  }

  /// Adds a fix; true if it became a track point.
  bool add(GeoPoint p, DateTime at, {double? accuracyM}) {
    final t = track;
    if (t == null || !p.valid) return false;
    if (accuracyM != null && accuracyM > maxAccuracyM) return false;
    final secs = at.millisecondsSinceEpoch ~/ 1000;
    if (t.points.isNotEmpty) {
      final last = t.points.last;
      if (distanceM(last.pos, p) < minMoveM) return false;
      if (last.t != null && secs <= last.t!) return false;
    }
    t.points.add(TrackPt(p, secs));
    _lastMoveAt = at;
    return true;
  }

  /// How often to ask for a GPS fix: 5 s moving, backing off to 60 s when
  /// nothing moved for a while; at least 20 s in battery saver.
  Duration interval(DateTime now, {bool saver = false}) {
    final still = _lastMoveAt == null
        ? Duration.zero
        : now.difference(_lastMoveAt!);
    var s = still.inSeconds < 60
        ? 5
        : still.inMinutes < 5
        ? 15
        : 60;
    if (saver && s < 20) s = 20;
    return Duration(seconds: s);
  }
}

/// Split a trail into Trip messages for fast links (about 380 bytes each).
List<TrackMsg> trackMessages(Track t, int Function() nextId) {
  final chunks = TrackMsg.chunk(t.points);
  final n = chunks.length.clamp(0, 255);
  return [
    for (var i = 0; i < n; i++)
      TrackMsg(nextId(), trackId: t.id, index: i, count: n, points: chunks[i]),
  ];
}

/// One thinned summary of a trail for LoRa (at most [maxPoints] points, no
/// timestamps, under 100 bytes).
TrackMsg trackSummary(Track t, int id, {int maxPoints = 16}) {
  final thin = thinTo<TrackPt>(t.points, (p) => p.pos, maxPoints);
  final pts = [for (final p in thin) TrackPt(p.pos)];
  final chunks = TrackMsg.chunk(pts, max: maxPoints);
  return TrackMsg(
    id,
    trackId: t.id,
    index: 0,
    count: 1,
    summary: true,
    points: chunks.isEmpty ? const [] : chunks.first,
  );
}

/// Rebuilds other people's shared trails from [TrackMsg] parts.
class TrackAssembler {
  final Map<String, Map<int, List<TrackPt>>> _parts = {};
  final Map<String, int> _counts = {};

  /// Returns the points known so far for that trail.
  List<TrackPt> add(int origin, TrackMsg m) {
    final key = '$origin:${m.trackId}';
    if (m.summary) {
      // A summary only fills in when no full parts arrived.
      if (_parts[key]?.isNotEmpty ?? false) {
        if (!_counts.containsKey(key)) {
          return points(origin, m.trackId);
        }
      }
      _parts[key] = {0: m.points};
      _counts.remove(key);
      return m.points;
    }
    if (!_counts.containsKey(key) || _counts[key] != m.count) {
      _parts[key] = {};
      _counts[key] = m.count;
    }
    _parts[key]![m.index] = m.points;
    return points(origin, m.trackId);
  }

  List<TrackPt> points(int origin, int trackId) {
    final parts = _parts['$origin:$trackId'];
    if (parts == null) return const [];
    final keys = parts.keys.toList()..sort();
    return [for (final k in keys) ...parts[k]!];
  }

  bool complete(int origin, int trackId) {
    final key = '$origin:$trackId';
    final c = _counts[key];
    return c != null && (_parts[key]?.length ?? 0) >= c;
  }
}

String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// GPX 1.1 with one track and optional waypoints (pins).
String toGpx(
  String name,
  List<TrackPt> points, {
  List<({GeoPoint pos, String name, String type})> waypoints = const [],
  String creator = 'Stalkie Talkie',
}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="${_xml(creator)}" '
      'xmlns="http://www.topografix.com/GPX/1/1">',
    )
    ..writeln('  <metadata><name>${_xml(name)}</name></metadata>');
  for (final w in waypoints) {
    b.writeln(
      '  <wpt lat="${w.pos.lat.toStringAsFixed(6)}" '
      'lon="${w.pos.lng.toStringAsFixed(6)}"><name>${_xml(w.name)}</name>'
      '<type>${_xml(w.type)}</type></wpt>',
    );
  }
  b.writeln('  <trk><name>${_xml(name)}</name><trkseg>');
  for (final p in points) {
    b.write(
      '    <trkpt lat="${p.pos.lat.toStringAsFixed(6)}" '
      'lon="${p.pos.lng.toStringAsFixed(6)}">',
    );
    if (p.t != null) {
      final t = DateTime.fromMillisecondsSinceEpoch(p.t! * 1000, isUtc: true);
      b.write('<time>${t.toIso8601String().split('.').first}Z</time>');
    }
    b.writeln('</trkpt>');
  }
  b
    ..writeln('  </trkseg></trk>')
    ..writeln('</gpx>');
  return b.toString();
}

/// Backtrack: the track point nearest to [me] and the distance back to the
/// start along the trail from there.
({int index, double toTrailM, double backM})? backtrack(
  List<TrackPt> pts,
  GeoPoint me,
) {
  if (pts.isEmpty) return null;
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < pts.length; i++) {
    final d = distanceM(me, pts[i].pos);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  final along = pathLengthM([for (final p in pts.take(best + 1)) p.pos]);
  return (index: best, toTrailM: bestD, backM: along + bestD);
}

String encodeTracks(List<Track> t) =>
    jsonEncode([for (final x in t) x.toJson()]);

List<Track> decodeTracks(String? s) {
  if (s == null || s.isEmpty) return [];
  try {
    return [
      for (final j in jsonDecode(s) as List)
        if (Track.fromJson(j) != null) Track.fromJson(j)!,
    ];
  } catch (_) {
    return [];
  }
}
