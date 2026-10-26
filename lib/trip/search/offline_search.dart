import 'dart:math' as math;

import '../geo.dart';
import '../imports/geo_import.dart';
import '../imports/map_layers.dart';
import '../tile_cache.dart';

/// What a search result is.
enum SearchKind {
  /// A named line in an imported layer (GPX track, OSM trail).
  trail,

  /// A peak, lake, trailhead, spring, campsite ... from map search.
  place,

  /// A waypoint in an imported file.
  waypoint,

  /// A pin I dropped.
  pin,

  /// A pin someone shared.
  sharedPin,

  /// Someone on the map.
  person,

  /// A trail I recorded (or someone shared).
  track,

  /// A downloaded map area or imported map.
  area,
}

extension SearchKindLabel on SearchKind {
  String get label => switch (this) {
    SearchKind.trail => 'Trail',
    SearchKind.place => 'Place',
    SearchKind.waypoint => 'Waypoint',
    SearchKind.pin => 'My pin',
    SearchKind.sharedPin => 'Shared pin',
    SearchKind.person => 'Person',
    SearchKind.track => 'Recorded trail',
    SearchKind.area => 'Offline map',
  };

  /// Small tie-break so people and trails come before generic places.
  double get bonus => switch (this) {
    SearchKind.person => 4,
    SearchKind.trail => 3,
    SearchKind.pin || SearchKind.sharedPin => 3,
    SearchKind.track => 2,
    SearchKind.place => 2,
    SearchKind.waypoint => 1,
    SearchKind.area => 1,
  };
}

/// One thing that can be found with no network.
class SearchDoc {
  SearchDoc({
    required this.kind,
    required this.title,
    required this.pos,
    this.subtitle = '',
    this.line,
    this.bounds,
    this.ref = '',
    this.layerId,
    this.placeKind = '',
    this.lengthM,
  }) : norm = normalizeSearch(title),
       subNorm = normalizeSearch('$subtitle $placeKind');

  final SearchKind kind;
  final String title;
  final String subtitle;

  /// Where to center the map.
  final GeoPoint pos;

  /// The line to highlight (trails).
  final List<GeoPoint>? line;

  /// Area to fit (downloaded areas, long trails).
  final GeoBounds? bounds;

  /// Pin key, person id, track id, region name ...
  final String ref;
  final String? layerId;

  /// 'peak', 'lake' ... for places.
  final String placeKind;

  /// Length of a trail (shown in the user's units).
  final double? lengthM;
  final String norm;
  final String subNorm;
  late final List<String> words = norm.split(' ');
}

/// A ranked result.
class SearchHit {
  SearchHit(this.doc, this.score, {this.distanceM});
  final SearchDoc doc;
  final double score;
  final double? distanceM;
  SearchKind get kind => doc.kind;
  String get title => doc.title;
}

const Map<String, String> _fold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', //
  'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', 'ÿ': 'y',
};

/// Lower case, accents folded, punctuation to spaces, single spaces.
String normalizeSearch(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    b.write(_fold[ch] ?? ch);
  }
  return b
      .toString()
      .replaceAll("'", '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
}

/// How well [q] (normalized) matches [d]; 0 = not at all.
double matchScore(String q, List<String> qWords, SearchDoc d) {
  if (q.isEmpty) return 0;
  final t = d.norm;
  if (t == q) return 100;
  if (t.startsWith(q)) return 80 + 10 * q.length / math.max(1, t.length);
  if (d.words.any((w) => w.startsWith(q))) return 65;
  // Every word of the query starts some word of the title (any order).
  if (qWords.every((qw) => d.words.any((w) => w.startsWith(qw)))) return 55;
  if (t.contains(q)) return 40;
  // Title words plus kind / subtitle ("lake", "peak", "trailhead").
  final all = [...d.words, ...d.subNorm.split(' ')];
  if (qWords.every((qw) => all.any((w) => w.startsWith(qw)))) return 30;
  return 0;
}

/// Offline search over imported layers (indexed when a layer is imported
/// or loaded) plus whatever else is passed in at search time (pins,
/// people, recorded trails, downloaded areas).
class SearchIndex {
  final Map<String, List<SearchDoc>> _byLayer = {};

  int get size => _byLayer.values.fold(0, (s, l) => s + l.length);
  bool hasLayer(String id) => _byLayer.containsKey(id);

  /// Documents for one layer (trail lines grouped by name, waypoints and
  /// places; a placed overlay as an area).
  static List<SearchDoc> docsForLayer(MapLayer l) {
    final out = <SearchDoc>[];
    final d = l.data;
    if (l.kind == MapLayerKind.trail && d != null) {
      final byName = <String, List<ImportedLine>>{};
      for (final line in d.lines) {
        if (line.points.isEmpty) continue;
        final n = line.name.trim().isEmpty ? l.name : line.name.trim();
        (byName[n] ??= []).add(line);
      }
      for (final e in byName.entries) {
        final pts = [for (final x in e.value) ...x.points];
        final longest = e.value.reduce(
          (a, b) => a.points.length >= b.points.length ? a : b,
        );
        final km = e.value.fold<double>(0, (s, x) => s + pathLengthM(x.points));
        out.add(
          SearchDoc(
            kind: SearchKind.trail,
            title: e.key,
            subtitle: l.name,
            lengthM: km,
            pos: longest.points[longest.points.length ~/ 2],
            line: [for (final x in e.value) ...x.points],
            bounds: _boundsOf(pts),
            ref: e.key,
            layerId: l.id,
          ),
        );
      }
      for (final w in d.waypoints) {
        if (w.name.trim().isEmpty) continue;
        out.add(
          SearchDoc(
            kind: w.kind.isEmpty ? SearchKind.waypoint : SearchKind.place,
            title: w.name,
            subtitle: [
              if (w.description.isNotEmpty) w.description,
              l.name,
            ].join(' · '),
            pos: w.pos,
            ref: w.name,
            layerId: l.id,
            placeKind: w.kind,
          ),
        );
      }
    }
    return out;
  }

  void indexLayer(MapLayer l) {
    final docs = docsForLayer(l);
    if (docs.isEmpty) {
      _byLayer.remove(l.id);
    } else {
      _byLayer[l.id] = docs;
    }
  }

  void removeLayer(String id) => _byLayer.remove(id);
  void clear() => _byLayer.clear();

  Iterable<SearchDoc> get docs sync* {
    for (final l in _byLayer.values) {
      yield* l;
    }
  }

  /// Ranked matches for [query] among the indexed layers and [extra].
  /// [hidden] layer ids are skipped. Closer results (to [near]) win ties.
  List<SearchHit> search(
    String query, {
    Iterable<SearchDoc> extra = const [],
    GeoPoint? near,
    int limit = 40,
    Set<String> hidden = const {},
  }) => rank(
    query,
    [
      for (final e in _byLayer.entries)
        if (!hidden.contains(e.key)) ...e.value,
      ...extra,
    ],
    near: near,
    limit: limit,
  );
}

/// Score, sort and de-duplicate [docs] for [query].
List<SearchHit> rank(
  String query,
  Iterable<SearchDoc> docs, {
  GeoPoint? near,
  int limit = 40,
}) {
  final q = normalizeSearch(query);
  if (q.isEmpty) return const [];
  final qWords = q.split(' ');
  final hits = <SearchHit>[];
  for (final d in docs) {
    final m = matchScore(q, qWords, d);
    if (m <= 0) continue;
    double? dist;
    var s = m + d.kind.bonus;
    if (near != null) {
      dist = distanceM(near, d.pos);
      // Up to +6 for things close by, fading out by ~100 km.
      s += 6 * (1 - (math.log(1 + dist / 1000) / math.log(101)).clamp(0, 1));
    }
    hits.add(SearchHit(d, s, distanceM: dist));
  }
  hits.sort((a, b) {
    final c = b.score.compareTo(a.score);
    if (c != 0) return c;
    final l = a.title.length.compareTo(b.title.length);
    return l != 0 ? l : a.title.compareTo(b.title);
  });
  // Same name and kind within 200 m (a trail in two imported files) once.
  final out = <SearchHit>[];
  for (final h in hits) {
    final dup = out.any(
      (o) =>
          o.kind == h.kind &&
          o.doc.norm == h.doc.norm &&
          distanceM(o.doc.pos, h.doc.pos) < 200,
    );
    if (!dup) out.add(h);
    if (out.length >= limit) break;
  }
  return out;
}

GeoBounds? _boundsOf(Iterable<GeoPoint> pts) {
  double? s, w, n, e;
  for (final p in pts) {
    s = s == null ? p.lat : math.min(s, p.lat);
    n = n == null ? p.lat : math.max(n, p.lat);
    w = w == null ? p.lng : math.min(w, p.lng);
    e = e == null ? p.lng : math.max(e, p.lng);
  }
  return s == null ? null : GeoBounds(s, w!, n!, e!);
}

GeoBounds? boundsOfPoints(Iterable<GeoPoint> pts) => _boundsOf(pts);
