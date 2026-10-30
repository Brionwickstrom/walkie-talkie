import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../trip/geo.dart';
import 'alert_store.dart';
import 'wx_alert.dart';

/// An HTTP answer (status 0 = no connection).
class WxResponse {
  const WxResponse(this.status, this.body);
  final int status;
  final String body;
}

typedef WxFetch = Future<WxResponse> Function(
  Uri url,
  Map<String, String> headers,
);

/// The real thing: one GET, gzip handled by dart:io.
Future<WxResponse> realWxFetch(Uri url, Map<String, String> headers) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..autoUncompress = true;
  try {
    final req = await client.getUrl(url);
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 20));
    return WxResponse(res.statusCode, body);
  } catch (_) {
    return const WxResponse(0, '');
  } finally {
    client.close(force: true);
  }
}

/// Rounds a place to about 1 km (two decimals) for the `/points` lookup:
/// the zones do not change within that, and the NWS gets one request per
/// neighbourhood, not one per GPS fix.
String wxPlaceKey(GeoPoint p) =>
    '${p.lat.toStringAsFixed(2)},${p.lng.toStringAsFixed(2)}';

/// api.weather.gov: place -> zones, zones -> active alerts. No key; the
/// NWS asks for a User-Agent that says who is calling.
class NwsClient {
  NwsClient({required this.userAgent, WxFetch? fetch})
    : _fetch = fetch ?? realWxFetch;

  final String userAgent;
  final WxFetch _fetch;

  static const host = 'api.weather.gov';

  Map<String, String> get _headers => {
    'User-Agent': userAgent,
    'Accept': 'application/geo+json',
  };

  static Uri pointUrl(String key) => Uri.https(host, '/points/$key');

  static Uri alertsUrl(Iterable<String> zones) => Uri.https(
    host,
    '/alerts/active',
    {'zone': (zones.toList()..sort()).join(','), 'status': 'actual'},
  );

  /// Zones of [key] ("45.52,-122.68"); null when the NWS could not be
  /// reached (try again later). A place the NWS does not cover comes back
  /// as unsupported (cached for a while).
  Future<WxZones?> zonesFor(String key, {DateTime? now}) async {
    final r = await _fetch(pointUrl(key), _headers);
    final at = now ?? DateTime.now();
    if (r.status == 404) {
      return WxZones(zones: const [], at: at, supported: false);
    }
    if (r.status != 200) return null;
    return parseWxPoint(r.body, at);
  }

  /// Active alerts for [zones]; null on any error (keep what we have).
  Future<List<WxAlert>?> activeFor(Iterable<String> zones) async {
    if (zones.isEmpty) return const [];
    final r = await _fetch(alertsUrl(zones), _headers);
    if (r.status != 200) return null;
    return parseNwsAlerts(r.body);
  }
}

/// Zones and place name out of a `/points` answer.
WxZones? parseWxPoint(String body, DateTime at) {
  try {
    final j = jsonDecode(body);
    final p = (j as Map)['properties'] as Map;
    String? zone(Object? url) {
      if (url is! String) return null;
      final z = url.split('/').last;
      return z.isEmpty ? null : z;
    }

    final zones = <String>[?zone(p['forecastZone']), ?zone(p['county'])];
    if (zones.isEmpty) return null;
    var place = '';
    final rl = p['relativeLocation'];
    if (rl is Map && rl['properties'] is Map) {
      final rp = rl['properties'] as Map;
      place = [
        rp['city'],
        rp['state'],
      ].whereType<String>().where((s) => s.isNotEmpty).join(', ');
    }
    return WxZones(zones: zones, at: at, place: place);
  } catch (_) {
    return null;
  }
}
