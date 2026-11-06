/// v2.6.6: typed home / base coordinates for a fixed-position radio
/// (Skunk Ape). Pure parsing and formatting; the write path lives in
/// [meshtastic_settings.dart].
library;

import 'dart:typed_data';

import '../trip/geo.dart';
import 'protobuf.dart';

/// Latitude, longitude and optional altitude (metres above sea level).
class HomeCoords {
  const HomeCoords(this.lat, this.lng, {this.alt});

  final double lat;
  final double lng;

  /// Metres; null when the user did not type one.
  final int? alt;

  GeoPoint get point => GeoPoint(lat, lng);

  /// "45.586800, -122.290100" (6 decimals ≈ 0.1 m). Altitude is not in
  /// the one-line form so paste-back stays a single lat,long pair.
  String get pasteLine =>
      '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';

  String get summary {
    final a = alt == null ? '' : ', ${alt}m';
    return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}$a';
  }

  @override
  bool operator ==(Object other) =>
      other is HomeCoords &&
      other.lat == lat &&
      other.lng == lng &&
      other.alt == alt;

  @override
  int get hashCode => Object.hash(lat, lng, alt);
}

/// Why a typed value is not a usable latitude / longitude / altitude, or
/// null when it is fine.
String? validateLatitude(double? lat) {
  if (lat == null || lat.isNaN || lat.isInfinite) {
    return 'Type a latitude between -90 and 90.';
  }
  if (lat < -90 || lat > 90) return 'Latitude must be between -90 and 90.';
  return null;
}

String? validateLongitude(double? lng) {
  if (lng == null || lng.isNaN || lng.isInfinite) {
    return 'Type a longitude between -180 and 180.';
  }
  if (lng < -180 || lng > 180) {
    return 'Longitude must be between -180 and 180.';
  }
  return null;
}

String? validateAltitude(int? alt) {
  if (alt == null) return null;
  if (alt < -500 || alt > 10000) {
    return 'Altitude must be between -500 and 10,000 metres.';
  }
  return null;
}

String? validateHomeCoords(HomeCoords? c) {
  if (c == null) return 'Type a latitude and longitude.';
  return validateLatitude(c.lat) ??
      validateLongitude(c.lng) ??
      validateAltitude(c.alt);
}

/// Parse one typed box. Accepts:
///   "45.5868, -122.2901"
///   "45.5868 -122.2901"
///   "45.5868, -122.2901, 120" (optional altitude metres)
///   "lat: 45.5868 lon: -122.2901"
/// Empty input is an empty-field error (the Save button checks that).
class HomeParse {
  const HomeParse._(this.coords, this.error);
  const HomeParse.ok(HomeCoords c) : this._(c, null);
  const HomeParse.fail(String e) : this._(null, e);

  final HomeCoords? coords;
  final String? error;

  bool get ok => coords != null && error == null;
}

HomeParse parseHomeLocation(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return const HomeParse.fail('Type a latitude and longitude.');
  // Drop common labels (longest first) and punctuation separators.
  for (final label in [
    'latitude',
    'longitude',
    'altitude',
    'long',
    'lat',
    'lon',
    'alt',
  ]) {
    s = s.replaceAll(RegExp(label, caseSensitive: false), ' ');
  }
  s = s.replaceAll(RegExp(r'[=:;|/]+'), ' ').trim();

  // Split on comma or whitespace; keep a leading minus with its number.
  final parts = s
      .split(RegExp(r'[\s,]+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length < 2) {
    return const HomeParse.fail(
      'Type latitude and longitude, for example 45.5868, -122.2901.',
    );
  }
  if (parts.length > 3) {
    return const HomeParse.fail(
      'Type latitude, longitude and optionally altitude in metres.',
    );
  }
  final lat = double.tryParse(parts[0]);
  final lng = double.tryParse(parts[1]);
  final latErr = validateLatitude(lat);
  if (latErr != null) return HomeParse.fail(latErr);
  final lngErr = validateLongitude(lng);
  if (lngErr != null) return HomeParse.fail(lngErr);
  int? alt;
  if (parts.length == 3) {
    final a = double.tryParse(parts[2]);
    if (a == null) {
      return const HomeParse.fail(
        'Altitude must be a whole number of metres.',
      );
    }
    alt = a.round();
    final altErr = validateAltitude(alt);
    if (altErr != null) return HomeParse.fail(altErr);
  }
  // (0, 0) is "no position" on Meshtastic, so refuse the Gulf of Guinea.
  if (lat == 0 && lng == 0) {
    return const HomeParse.fail(
      '0, 0 is not a real place on the radio. Type the base coordinates.',
    );
  }
  return HomeParse.ok(HomeCoords(lat!, lng!, alt: alt));
}

/// Degrees → Meshtastic Position.latitude_i / longitude_i (degrees × 1e7).
int latToI(double deg) => (deg * 1e7).round();
int lngToI(double deg) => (deg * 1e7).round();

double latFromI(int i) => i / 1e7;
double lngFromI(int i) => i / 1e7;

/// PositionConfig.fixed_position (field 3) of the raw config bytes.
bool positionConfigIsFixed(Uint8List? position) {
  if (position == null) return false;
  for (final f in pbDecode(position)) {
    if (f.number == 3) return f.asBool;
  }
  return false;
}
