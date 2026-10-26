import 'dart:collection';
import 'dart:convert';

import '../geo.dart';
import '../tile_cache.dart';
import 'fetch.dart';
import 'rate_limiter.dart';

/// A place found by name (Nominatim).
class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.displayName,
    required this.center,
    this.bounds,
    this.osmType = '',
    this.osmId = 0,
    this.category = '',
    this.type = '',
  });

  final String name;
  final String displayName;
  final GeoPoint center;
  final GeoBounds? bounds;

  /// 'node', 'way' or 'relation'.
  final String osmType;
  final int osmId;

  /// e.g. 'boundary' / 'protected_area', 'natural' / 'peak'.
  final String category;
  final String type;

  /// Overpass area id for the place's outline (ways and relations only).
  int? get overpassAreaId => switch (osmType) {
    'relation' when osmId > 0 => 3600000000 + osmId,
    'way' when osmId > 0 => 2400000000 + osmId,
    _ => null,
  };

  /// "Protected area", "Peak" ...
  String get kindLabel {
    final t = type.isEmpty ? category : type;
    if (t.isEmpty) return '';
    final s = t.replaceAll('_', ' ');
    return s[0].toUpperCase() + s.substring(1);
  }
}

/// Place search with OpenStreetMap's Nominatim, following its usage
/// policy (https://operations.osmfoundation.org/policies/nominatim/): an
/// identifying User-Agent, at most one request per second (shared by the
/// whole app), results cached, no search-as-you-type (only when the user
/// presses search), and attribution shown with the results.
class NominatimClient {
  NominatimClient({
    required this.fetch,
    RateLimiter? limiter,
    this.endpoint = 'https://nominatim.openstreetmap.org/search',
    this.acceptLanguage = 'en',
    DateTime Function()? clock,
  }) : limiter = limiter ?? shared,
       _clock = clock ?? DateTime.now;

  /// One request per second across the app (a little over, to be safe).
  static final RateLimiter shared = RateLimiter(
    const Duration(milliseconds: 1100),
  );

  static const String attribution =
      'Search by Nominatim · Data © OpenStreetMap contributors, ODbL';

  final Fetch fetch;
  final RateLimiter limiter;
  final String endpoint;
  final String acceptLanguage;
  final DateTime Function() _clock;

  final LinkedHashMap<String, ({DateTime at, List<PlaceResult> r})> _cache =
      LinkedHashMap();
  static const int _cacheSize = 40;
  static const Duration _cacheFor = Duration(hours: 6);

  /// Requests actually sent (not served from the cache).
  int requests = 0;

  static String normQuery(String q) =>
      q.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  static Uri searchUri(
    String query, {
    String endpoint = 'https://nominatim.openstreetmap.org/search',
    int limit = 8,
    String acceptLanguage = 'en',
  }) {
    final u = Uri.parse(endpoint);
    return u.replace(
      queryParameters: {
        'q': query.trim().replaceAll(RegExp(r'\s+'), ' '),
        'format': 'jsonv2',
        'limit': '$limit',
        'addressdetails': '0',
        'accept-language': acceptLanguage,
      },
    );
  }

  Future<List<PlaceResult>> search(String query) async {
    final key = normQuery(query);
    if (key.length < 2) return const [];
    final hit = _cache[key];
    if (hit != null && _clock().difference(hit.at) < _cacheFor) {
      _cache.remove(key);
      _cache[key] = hit;
      return hit.r;
    }
    final body = await limiter.run(() {
      requests++;
      return fetch(
        FetchRequest(
          searchUri(query, endpoint: endpoint, acceptLanguage: acceptLanguage),
          headers: const {'Accept': 'application/json'},
          timeout: const Duration(seconds: 15),
          maxBytes: 1024 * 1024,
        ),
      );
    });
    final r = parse(body);
    _cache[key] = (at: _clock(), r: r);
    while (_cache.length > _cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return r;
  }

  /// Parse a `format=jsonv2` answer (bad entries are skipped).
  static List<PlaceResult> parse(String body) {
    final Object? j;
    try {
      j = jsonDecode(body);
    } catch (_) {
      throw FetchException('Map search sent an answer the app cannot read.');
    }
    if (j is! List) return const [];
    final out = <PlaceResult>[];
    double? d(Object? v) =>
        v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    for (final e in j) {
      if (e is! Map) continue;
      final lat = d(e['lat']), lon = d(e['lon']);
      if (lat == null || lon == null) continue;
      final c = GeoPoint(lat, lon);
      if (!c.valid) continue;
      GeoBounds? b;
      final bb = e['boundingbox'];
      if (bb is List && bb.length == 4) {
        final s = d(bb[0]), n = d(bb[1]), w = d(bb[2]), ea = d(bb[3]);
        if (s != null && n != null && w != null && ea != null && n >= s) {
          b = GeoBounds(s, w, n, ea);
        }
      }
      final display = '${e['display_name'] ?? ''}';
      var name = '${e['name'] ?? ''}'.trim();
      if (name.isEmpty) name = display.split(',').first.trim();
      out.add(
        PlaceResult(
          name: name,
          displayName: display,
          center: c,
          bounds: b,
          osmType: '${e['osm_type'] ?? ''}',
          osmId: (e['osm_id'] is num)
              ? (e['osm_id'] as num).toInt()
              : int.tryParse('${e['osm_id']}') ?? 0,
          category: '${e['category'] ?? e['class'] ?? ''}',
          type: '${e['type'] ?? ''}',
        ),
      );
    }
    return out;
  }
}
