import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../drive/road_download.dart' show RoadDownloader;
import '../geo.dart';
import 'fetch.dart';
import 'rate_limiter.dart';

/// A place to park and start walking.
class TrailheadCandidate {
  const TrailheadCandidate({
    required this.name,
    required this.pos,
    required this.kind,
    required this.source,
    required this.distToTargetM,
  });
  final String name;
  final GeoPoint pos;

  /// 'trailhead' or 'parking'.
  final String kind;

  /// 'overpass', 'photon', 'nominatim', 'saved'.
  final String source;

  /// Straight line from here to the place being walked to.
  final double distToTargetM;
}

/// What a trailhead search found.
class TrailheadSearch {
  const TrailheadSearch(
    this.found, {
    this.overpassFailed = false,
    this.noSignal = false,
    this.note = '',
  });

  /// Best first.
  final List<TrailheadCandidate> found;

  /// Every Overpass server failed (the backups were tried).
  final bool overpassFailed;
  final bool noSignal;
  final String note;
}

/// Finds trailheads and signed parking near a trail destination (v2.1.0),
/// online: OpenStreetMap trailhead points and public parking from Overpass
/// (several servers, each tried briefly), then Photon and Nominatim as
/// backups. Never throws; a failure is reported in [TrailheadSearch].
class TrailheadFinder {
  TrailheadFinder({
    required this.fetch,
    RateLimiter? limiter,
    List<String>? overpassEndpoints,
    this.photon = 'https://photon.komoot.io/api/',
    this.nominatim = 'https://nominatim.openstreetmap.org/search',
    this.perTry = const Duration(seconds: 6),
  }) : limiter = limiter ?? RateLimiter(const Duration(milliseconds: 1100)),
       endpoints = overpassEndpoints ?? RoadDownloader.defaultEndpoints;

  final Fetch fetch;
  final RateLimiter limiter;
  final List<String> endpoints;
  final String photon, nominatim;
  final Duration perTry;

  /// Share of the whole wait Overpass may use before the backups.
  static const double overpassShare = 0.55;

  static final RegExp hint = RegExp(
    r'trail ?head|\bTH\b|trail|hike|hiking|wilderness|forest|lookout|summit|falls|lake|picnic|campground',
    caseSensitive: false,
  );

  static String query(GeoPoint to, double radiusM) {
    final r = radiusM.round();
    final at = '${to.lat.toStringAsFixed(5)},${to.lng.toStringAsFixed(5)}';
    return '[out:json][timeout:10];'
        '(node["highway"="trailhead"](around:$r,$at);'
        'nwr["amenity"="parking"]["access"!~"^(private|no|customers|permit)\$"](around:$r,$at););'
        'out center tags 80;';
  }

  /// Candidates from an Overpass answer, best first.
  static List<TrailheadCandidate> parseOverpass(String body, GeoPoint to) {
    final out = <TrailheadCandidate>[];
    try {
      final j = jsonDecode(body) as Map;
      for (final e in (j['elements'] as List? ?? const [])) {
        final m = e as Map;
        final tags = (m['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
        double? lat, lon;
        if (m['lat'] is num) {
          lat = (m['lat'] as num).toDouble();
          lon = (m['lon'] as num).toDouble();
        } else if (m['center'] is Map) {
          lat = ((m['center'] as Map)['lat'] as num?)?.toDouble();
          lon = ((m['center'] as Map)['lon'] as num?)?.toDouble();
        }
        if (lat == null || lon == null) continue;
        final trailhead = tags['highway'] == 'trailhead';
        final name = '${tags['name'] ?? ''}'.trim();
        final pos = GeoPoint(lat, lon);
        out.add(
          TrailheadCandidate(
            name: name.isEmpty
                ? (trailhead ? 'Trailhead' : 'Parking area')
                : name,
            pos: pos,
            kind: trailhead ? 'trailhead' : 'parking',
            source: 'overpass',
            distToTargetM: distanceM(pos, to),
          ),
        );
      }
    } catch (_) {}
    return rank(out);
  }

  /// Trailheads first, then signed parking, nearest to the destination.
  /// Plain parking lots (no trail-like name) rank well behind.
  static List<TrailheadCandidate> rank(List<TrailheadCandidate> c) {
    double score(TrailheadCandidate t) {
      final named = hint.hasMatch(t.name);
      return t.distToTargetM *
          (t.kind == 'trailhead' ? 1.0 : (named ? 1.3 : 3.0));
    }

    final seen = <String>{};
    final l = [
      for (final t in c)
        if (seen.add(
          '${t.pos.lat.toStringAsFixed(4)},${t.pos.lng.toStringAsFixed(4)}',
        ))
          t,
    ]..sort((a, b) => score(a).compareTo(score(b)));
    return l.take(6).toList();
  }

  static List<TrailheadCandidate> parsePhoton(String body, GeoPoint to) {
    final out = <TrailheadCandidate>[];
    try {
      final j = jsonDecode(body) as Map;
      for (final f in (j['features'] as List? ?? const [])) {
        final m = f as Map;
        final c = (m['geometry'] as Map)['coordinates'] as List;
        final props = (m['properties'] as Map?) ?? const {};
        final pos = GeoPoint(
          (c[1] as num).toDouble(),
          (c[0] as num).toDouble(),
        );
        final name = '${props['name'] ?? ''}'.trim();
        out.add(
          TrailheadCandidate(
            name: name.isEmpty ? 'Trailhead' : name,
            pos: pos,
            kind: props['osm_value'] == 'parking' ? 'parking' : 'trailhead',
            source: 'photon',
            distToTargetM: distanceM(pos, to),
          ),
        );
      }
    } catch (_) {}
    return out;
  }

  static List<TrailheadCandidate> parseNominatim(String body, GeoPoint to) {
    final out = <TrailheadCandidate>[];
    try {
      for (final r in (jsonDecode(body) as List)) {
        final m = r as Map;
        final pos = GeoPoint(
          double.parse('${m['lat']}'),
          double.parse('${m['lon']}'),
        );
        final type = '${m['type'] ?? ''}';
        if (type != 'trailhead' && type != 'parking') continue;
        final dn = '${m['display_name'] ?? ''}'.split(',').first.trim();
        out.add(
          TrailheadCandidate(
            name: dn.isEmpty ? 'Trailhead' : dn,
            pos: pos,
            kind: type,
            source: 'nominatim',
            distToTargetM: distanceM(pos, to),
          ),
        );
      }
    } catch (_) {}
    return out;
  }

  /// Search around [to] within [radiusM].
  Future<TrailheadSearch> find(
    GeoPoint to, {
    double radiusM = 12000,
    Duration? budget,
  }) async {
    final start = DateTime.now();
    final total = budget ?? const Duration(seconds: 14);
    Duration left() => total - DateTime.now().difference(start);
    var anyAnswer = false;
    // 1. Overpass, server by server.
    var overpassFailed = true;
    // Overpass gets at most [overpassShare] of the time: a server that
    // does not answer must not use up the time for Photon / Nominatim.
    final overpassEnd = start.add(
      Duration(milliseconds: (total.inMilliseconds * overpassShare).round()),
    );
    for (final url in endpoints) {
      final l = left();
      final lo = overpassEnd.difference(DateTime.now());
      if (l <= const Duration(milliseconds: 800) ||
          lo <= const Duration(milliseconds: 800)) {
        break;
      }
      final t = [l, lo, perTry].reduce((a, b) => a < b ? a : b);
      try {
        final body = await limiter
            .run(
              () => fetch(
                FetchRequest(
                  Uri.parse(url),
                  method: 'POST',
                  headers: const {
                    'Content-Type':
                        'application/x-www-form-urlencoded; charset=utf-8',
                    'Accept': 'application/json',
                  },
                  body: 'data=${Uri.encodeQueryComponent(query(to, radiusM))}',
                  timeout: t,
                  maxBytes: 2 * 1024 * 1024,
                ),
              ),
            )
            .timeout(t);
        anyAnswer = true;
        final c = parseOverpass(body, to);
        overpassFailed = false;
        if (c.isNotEmpty) return TrailheadSearch(c);
        break; // answered, nothing near: the backups will not know more
      } on NoSignalException {
        break; // unreachable: the backups are other servers
      } on TimeoutException {
        continue;
      } catch (_) {
        continue;
      }
    }
    // 2. Photon, 3. Nominatim. (An unreachable Overpass server is not "no
    // signal": the backups are other servers and may still answer.)
    final dLat = radiusM / 111320,
        dLng = radiusM / (111320 * max(0.2, cos(to.lat * pi / 180)));
    final west = to.lng - dLng, east = to.lng + dLng;
    final south = to.lat - dLat, north = to.lat + dLat;
    final backups =
        <
          ({
            String name,
            Uri uri,
            List<TrailheadCandidate> Function(String) parse,
          })
        >[
          (
            name: 'photon',
            uri: Uri.parse(photon).replace(
              queryParameters: {
                'q': 'trailhead',
                'lat': to.lat.toStringAsFixed(5),
                'lon': to.lng.toStringAsFixed(5),
                'bbox': '$west,$south,$east,$north',
                'osm_tag': 'highway:trailhead',
                'limit': '15',
              },
            ),
            parse: (b) => parsePhoton(b, to),
          ),
          (
            name: 'nominatim',
            uri: Uri.parse(nominatim).replace(
              queryParameters: {
                'q': 'trailhead',
                'format': 'jsonv2',
                'limit': '15',
                'viewbox': '$west,$north,$east,$south',
                'bounded': '1',
              },
            ),
            parse: (b) => parseNominatim(b, to),
          ),
        ];
    for (final b in backups) {
      final l = left();
      if (l <= const Duration(milliseconds: 800)) break;
      final t = l < perTry ? l : perTry;
      try {
        final body = await limiter
            .run(
              () => fetch(
                FetchRequest(
                  b.uri,
                  headers: const {'Accept': 'application/json'},
                  timeout: t,
                  maxBytes: 1024 * 1024,
                ),
              ),
            )
            .timeout(t);
        anyAnswer = true;
        final c = rank([
          for (final x in b.parse(body))
            if (x.distToTargetM <= radiusM * 1.1) x,
        ]);
        if (c.isNotEmpty) {
          return TrailheadSearch(
            c,
            overpassFailed: overpassFailed,
            note: overpassFailed
                ? 'The main map-data server did not answer, so these come '
                      'from ${b.name}.'
                : '',
          );
        }
      } on NoSignalException {
        return const TrailheadSearch([], noSignal: true, overpassFailed: true);
      } catch (_) {
        continue;
      }
    }
    return TrailheadSearch(
      const [],
      overpassFailed: overpassFailed,
      noSignal: !anyAnswer,
    );
  }
}
