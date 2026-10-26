import 'dart:convert';
import 'dart:io';

import 'geo.dart';

/// One day of the cached forecast.
class WeatherDay {
  const WeatherDay({
    required this.date,
    required this.code,
    required this.tMax,
    required this.tMin,
    this.precipProb,
    this.windMax,
    this.sunrise,
    this.sunset,
  });
  final DateTime date;
  final int code;
  final double tMax;
  final double tMin;
  final int? precipProb;
  final double? windMax;
  final DateTime? sunrise;
  final DateTime? sunset;
}

class WeatherHour {
  const WeatherHour(
    this.time,
    this.temp,
    this.code,
    this.precipProb,
    this.wind,
  );
  final DateTime time;
  final double temp;
  final int code;
  final int? precipProb;
  final double? wind;
}

/// Forecast for the trip area from Open-Meteo (free, no key), kept on the
/// phone so it shows offline with its age.
class Forecast {
  Forecast({
    required this.at,
    required this.place,
    required this.days,
    required this.hours,
    required this.imperial,
  });

  /// When it was downloaded.
  final DateTime at;
  final GeoPoint place;
  final List<WeatherDay> days;
  final List<WeatherHour> hours;
  final bool imperial;

  String get tempUnit => imperial ? '°F' : '°C';
  String get windUnit => imperial ? 'mph' : 'km/h';

  /// Hours from [now] on (next [n]).
  List<WeatherHour> nextHours(DateTime now, int n) => [
    for (final h in hours)
      if (!h.time.isBefore(now.subtract(const Duration(minutes: 59)))) h,
  ].take(n).toList();

  static Uri url(
    GeoPoint p, {
    bool imperial = true,
    int days = 3,
  }) => Uri.https('api.open-meteo.com', '/v1/forecast', {
    'latitude': p.lat.toStringAsFixed(4),
    'longitude': p.lng.toStringAsFixed(4),
    'daily':
        'weather_code,temperature_2m_max,temperature_2m_min,'
        'precipitation_probability_max,wind_speed_10m_max,sunrise,sunset',
    'hourly':
        'temperature_2m,weather_code,precipitation_probability,wind_speed_10m',
    'timezone': 'auto',
    'timeformat': 'unixtime',
    'forecast_days': '$days',
    if (imperial) 'temperature_unit': 'fahrenheit',
    if (imperial) 'wind_speed_unit': 'mph',
  });

  /// Parse an Open-Meteo response (`timeformat=unixtime`). Null if broken.
  static Forecast? parse(
    String body, {
    required DateTime at,
    required GeoPoint place,
    required bool imperial,
  }) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      DateTime t(Object? v) => DateTime.fromMillisecondsSinceEpoch(
        (v as num).toInt() * 1000,
        isUtc: true,
      ).toLocal();
      List<Object?> l(Map<String, dynamic>? m, String k) =>
          (m?[k] as List?) ?? const [];
      final d = j['daily'] as Map<String, dynamic>?;
      final days = <WeatherDay>[];
      final dt = l(d, 'time');
      for (var i = 0; i < dt.length; i++) {
        Object? at(String k) {
          final x = l(d, k);
          return i < x.length ? x[i] : null;
        }

        days.add(
          WeatherDay(
            date: t(dt[i]),
            code: (at('weather_code') as num?)?.toInt() ?? -1,
            tMax: (at('temperature_2m_max') as num?)?.toDouble() ?? double.nan,
            tMin: (at('temperature_2m_min') as num?)?.toDouble() ?? double.nan,
            precipProb: (at('precipitation_probability_max') as num?)?.toInt(),
            windMax: (at('wind_speed_10m_max') as num?)?.toDouble(),
            sunrise: at('sunrise') == null ? null : t(at('sunrise')),
            sunset: at('sunset') == null ? null : t(at('sunset')),
          ),
        );
      }
      final h = j['hourly'] as Map<String, dynamic>?;
      final hours = <WeatherHour>[];
      final ht = l(h, 'time');
      for (var i = 0; i < ht.length; i++) {
        Object? at(String k) {
          final x = l(h, k);
          return i < x.length ? x[i] : null;
        }

        hours.add(
          WeatherHour(
            t(ht[i]),
            (at('temperature_2m') as num?)?.toDouble() ?? double.nan,
            (at('weather_code') as num?)?.toInt() ?? -1,
            (at('precipitation_probability') as num?)?.toInt(),
            (at('wind_speed_10m') as num?)?.toDouble(),
          ),
        );
      }
      if (days.isEmpty && hours.isEmpty) return null;
      return Forecast(
        at: at,
        place: place,
        days: days,
        hours: hours,
        imperial: imperial,
      );
    } catch (_) {
      return null;
    }
  }
}

/// WMO weather code -> short text and emoji.
(String, String) weatherText(int code) => switch (code) {
  0 => ('Clear', '☀️'),
  1 => ('Mostly clear', '🌤️'),
  2 => ('Partly cloudy', '⛅'),
  3 => ('Cloudy', '☁️'),
  45 || 48 => ('Fog', '🌫️'),
  51 || 53 || 55 || 56 || 57 => ('Drizzle', '🌦️'),
  61 || 63 || 66 => ('Rain', '🌧️'),
  65 || 67 => ('Heavy rain', '🌧️'),
  71 || 73 || 77 => ('Snow', '🌨️'),
  75 => ('Heavy snow', '❄️'),
  80 || 81 => ('Showers', '🌦️'),
  82 => ('Heavy showers', '⛈️'),
  85 || 86 => ('Snow showers', '🌨️'),
  95 => ('Thunderstorm', '⛈️'),
  96 || 99 => ('Thunderstorm, hail', '⛈️'),
  _ => ('Unknown', '❔'),
};

/// Downloads and keeps the forecast in [file].
class WeatherCache {
  WeatherCache(this.file, {this.userAgent = 'WalkieTalkie'});
  final File file;
  final String userAgent;
  Forecast? forecast;

  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      forecast = Forecast.parse(
        j['body'] as String,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
        place: GeoPoint(
          (j['lat'] as num).toDouble(),
          (j['lng'] as num).toDouble(),
        ),
        imperial: j['imp'] == true,
      );
    } catch (_) {}
  }

  /// Fetch for [p]; keeps the old forecast if offline. Returns true if
  /// updated.
  Future<bool> refresh(GeoPoint p, {bool imperial = true}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = userAgent;
    try {
      final req = await client.getUrl(Forecast.url(p, imperial: imperial));
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return false;
      }
      final body = await res.transform(utf8.decoder).join();
      final now = DateTime.now();
      final f = Forecast.parse(body, at: now, place: p, imperial: imperial);
      if (f == null) return false;
      forecast = f;
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(
          jsonEncode({
            'at': now.millisecondsSinceEpoch,
            'lat': p.lat,
            'lng': p.lng,
            'imp': imperial,
            'body': body,
          }),
        );
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
