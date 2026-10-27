import 'dart:convert';
import 'dart:io';

import 'geo.dart';
import 'tile_cache.dart';

/// One current wildfire perimeter (NIFC WFIGS).
class FirePerimeter {
  FirePerimeter({
    required this.name,
    required this.rings,
    this.acres,
    this.contained,
    this.updated,
  });
  final String name;
  final List<List<GeoPoint>> rings;
  final double? acres;
  final int? contained;
  final DateTime? updated;

  String get label => [
    name,
    if (acres != null) '${acres!.round()} ac',
    if (contained != null) '$contained% contained',
  ].join(' · ');
}

/// Current wildfire perimeters from the public NIFC WFIGS service. Online
/// only (fire lines change by the hour; never saved for offline).
class FireService {
  FireService({Future<String?> Function(Uri u)? get}) : _get = get ?? _http;

  final Future<String?> Function(Uri u) _get;

  static const base =
      'https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/'
      'WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query';

  static Uri queryUri(GeoBounds b, {double simplify = 0.0005}) =>
      Uri.parse(base).replace(
        queryParameters: {
          'where': '1=1',
          'outFields':
              'poly_IncidentName,attr_IncidentSize,attr_PercentContained,'
              'poly_DateCurrent',
          'geometry': '${b.west},${b.south},${b.east},${b.north}',
          'geometryType': 'esriGeometryEnvelope',
          'inSR': '4326',
          'outSR': '4326',
          'spatialRel': 'esriSpatialRelIntersects',
          'maxAllowableOffset': '$simplify',
          'resultRecordCount': '200',
          'f': 'geojson',
        },
      );

  /// Perimeters crossing [b]; empty when offline or the service fails.
  Future<List<FirePerimeter>> inArea(GeoBounds b, {double? zoom}) async {
    final simplify = zoom == null
        ? 0.0005
        : (360 / (256 * (1 << zoom.clamp(3, 16).round()))).toDouble();
    final s = await _get(queryUri(b, simplify: simplify));
    return s == null ? const [] : parse(s);
  }

  static List<FirePerimeter> parse(String json) {
    try {
      final j = jsonDecode(json);
      final out = <FirePerimeter>[];
      for (final f in (j['features'] as List? ?? const [])) {
        final g = f['geometry'];
        final p = (f['properties'] as Map?) ?? const {};
        if (g is! Map) continue;
        final rings = <List<GeoPoint>>[];
        void ring(List r) {
          final pts = [
            for (final c in r)
              if (c is List && c.length >= 2)
                GeoPoint((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          ];
          if (pts.length > 2) rings.add(pts);
        }

        switch (g['type']) {
          case 'Polygon':
            for (final r in g['coordinates'] as List) {
              ring(r as List);
            }
          case 'MultiPolygon':
            for (final poly in g['coordinates'] as List) {
              for (final r in poly as List) {
                ring(r as List);
              }
            }
        }
        if (rings.isEmpty) continue;
        final at = p['poly_DateCurrent'];
        out.add(
          FirePerimeter(
            name: '${p['poly_IncidentName'] ?? 'Fire'}'.trim(),
            rings: rings,
            acres: (p['attr_IncidentSize'] as num?)?.toDouble(),
            contained: (p['attr_PercentContained'] as num?)?.round(),
            updated: at is num
                ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
                : null,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<String?> _http(Uri u) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final res = await (await c.getUrl(u))
          .close()
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      return await res.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }
}
