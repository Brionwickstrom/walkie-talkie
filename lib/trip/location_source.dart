// v2.6.7: Radio GPS as the location source. When the connected Meshtastic
// radio has its own GPS, the app can use the position the radio already
// broadcasts (a copy comes to the phone over Bluetooth or USB, nothing is
// asked for) as "where I am", and fall back to the phone's GPS when the
// radio has no fix, is not connected, or its position is too old.
import 'dart:math' as math;

import '../lora/meshtastic_proto.dart';
import 'geo.dart';
import 'trip_controller.dart' show Fix;

/// The "Location source" setting.
enum LocationSource {
  /// Radio GPS while it is good, else the phone's GPS (the default).
  auto('auto', 'Auto'),

  /// Only the phone's GPS (the app before v2.6.7).
  phone('phone', 'Phone GPS only'),

  /// Only the radio's GPS: the phone's GPS is never used.
  radio('radio', 'Radio GPS only');

  const LocationSource(this.id, this.label);
  final String id;
  final String label;

  static LocationSource fromId(String? id) =>
      values.where((v) => v.id == id).firstOrNull ?? LocationSource.auto;

  String get about => switch (this) {
    LocationSource.auto =>
      "Uses the radio's GPS while it has a good, recent fix, else the "
          "phone's GPS.",
    LocationSource.phone => "Always uses the phone's GPS.",
    LocationSource.radio =>
      "Only uses the radio's GPS. The phone's GPS stays off, even when the "
          'radio has no fix.',
  };
}

/// Which GPS is "where I am" right now.
enum ActiveLocation { phone, radio, none }

/// Why the radio's GPS is not used (null = it is).
enum RadioGpsWhy {
  notConnected,
  noPosition,
  notSharing,
  fixedPosition,
  fromPhone,
  blurred,
  weak,
  stale,
  needPhone,
}

/// What the connected radio says about its own position (plain values, so
/// the choice can be tested without a radio).
class RadioGpsState {
  const RadioGpsState({
    this.connected = false,
    this.link = 'Bluetooth',
    this.pos,
    this.at,
    this.broadcastSecs,
    this.smart,
    this.sharing = true,
  });

  /// No radio, or it is not connected.
  static const none = RadioGpsState();

  final bool connected;

  /// "Bluetooth", "USB" or "Wi-Fi".
  final String link;

  /// The radio's newest own position, and when its fix was taken.
  final PositionPb? pos;
  final DateTime? at;

  /// PositionConfig: how often it broadcasts its position (seconds,
  /// 0xFFFFFFFF = never) and whether smart broadcast is on.
  final int? broadcastSecs;
  final bool? smart;

  /// The radio's main channel shares a location (precision > 0). With 0 it
  /// sends no position at all, so there is nothing to use.
  final bool sharing;
}

/// Radio broadcast interval meaning "never".
const radioPositionNever = 0xFFFFFFFF;

/// A radio fix counts as current this long by default.
const radioFixMaxAge = Duration(minutes: 2);

/// With smart broadcast the radio sends again as soon as it moves (about
/// 100 m), so a quiet radio has not moved: its fix stays current up to its
/// broadcast interval plus a minute, at most this long.
const radioFixMaxAgeSmart = Duration(minutes: 16);

/// Worst accuracy (metres) still good enough to stand in for the phone.
const radioFixMaxErrorM = 100.0;

/// How old the radio's fix may be before it no longer counts.
Duration radioFixMaxAgeFor({int? broadcastSecs, bool? smart}) {
  final secs = broadcastSecs;
  if (smart != true ||
      secs == null ||
      secs <= 0 ||
      secs == radioPositionNever) {
    return radioFixMaxAge;
  }
  final d = Duration(seconds: secs + 60);
  if (d < radioFixMaxAge) return radioFixMaxAge;
  return d > radioFixMaxAgeSmart ? radioFixMaxAgeSmart : d;
}

/// Size of the circle a blurred position is snapped to (metres), 0 =
/// exact or not blurred.
double blurMetres(int precisionBits) {
  if (precisionBits <= 0 || precisionBits >= 32) return 0;
  // Meshtastic's table: 13 bits is about 2.9 km, each bit halves it.
  return 2.33e7 / math.pow(2, precisionBits);
}

/// Rough accuracy of a radio fix (metres): HDOP x 5 m, at least the blur.
double radioFixErrorM(PositionPb p) {
  final h = p.hdop > 0 ? p.hdop / 100 * 5 : 10.0;
  return math.max(h, blurMetres(p.precisionBits));
}

/// The radio's position as a [Fix] (no speed: the radio's unit differs by
/// firmware, so the app works it out between fixes like on a phone).
Fix radioFixOf(PositionPb p, DateTime at) => Fix(
  GeoPoint(p.lat, p.lng),
  at,
  accuracyM: radioFixErrorM(p),
  altM: p.alt?.toDouble(),
);

/// The answer: which GPS, the line for the connection sheet, and why the
/// radio is not used.
class LocationChoice {
  const LocationChoice({
    required this.active,
    required this.setting,
    this.why,
    this.radioAge,
    this.link = 'Bluetooth',
    this.blurM = 0,
    this.errorM = 0,
  });
  final ActiveLocation active;
  final LocationSource setting;
  final RadioGpsWhy? why;
  final Duration? radioAge;
  final String link;
  final double blurM;
  final double errorM;

  bool get usingRadio => active == ActiveLocation.radio;

  /// The phone's GPS may run (it is off while the radio's is used, and
  /// never on with Radio GPS only).
  bool get phoneGpsAllowed =>
      setting != LocationSource.radio && active != ActiveLocation.radio;

  /// "Location: Radio GPS (Bluetooth)".
  String get title => switch (active) {
    ActiveLocation.radio => 'Location: Radio GPS ($link)',
    ActiveLocation.phone => 'Location: Phone GPS',
    ActiveLocation.none => 'Location: waiting for radio GPS',
  };

  /// One plain line under it.
  String get subtitle {
    final age = radioAge == null ? '' : ', fix ${_ago(radioAge!)}';
    switch (active) {
      case ActiveLocation.radio:
        return "${setting.label}$age. The phone's GPS is off to save "
            'battery.';
      case ActiveLocation.phone:
      case ActiveLocation.none:
        final r = reason;
        return r == null ? setting.label : '${setting.label}. $r';
    }
  }

  /// Why the radio's GPS is not in use, in plain words (null = it is, or
  /// the setting is Phone GPS only).
  String? get reason {
    if (setting == LocationSource.phone) return null;
    return switch (why) {
      null => null,
      RadioGpsWhy.notConnected => 'No radio is connected.',
      RadioGpsWhy.noPosition => 'The radio has not sent a GPS position yet.',
      RadioGpsWhy.notSharing =>
        'The radio is not set to send its position. Turn on Location '
            'sharing in Radio settings.',
      RadioGpsWhy.fixedPosition =>
        "The radio's position is a fixed home location, not GPS.",
      RadioGpsWhy.fromPhone =>
        "The radio's position came from a phone, not its own GPS.",
      RadioGpsWhy.blurred =>
        'The radio sends a blurred position (about ${_dist(blurM)}). Set '
            'its Location precision to Full in Radio settings.',
      RadioGpsWhy.weak =>
        "The radio's GPS fix is weak (about ${_dist(errorM)}).",
      RadioGpsWhy.stale =>
        "The radio's last GPS fix is ${_ago(radioAge ?? Duration.zero)}, "
            'too old to use.',
      RadioGpsWhy.needPhone =>
        "Navigation, Drive, SOS, a recorded trail or range logging is on, so "
            "the phone's faster GPS is used.",
    };
  }
}

String _ago(Duration d) {
  if (d.inSeconds < 60) return '${math.max(0, d.inSeconds)} s old';
  if (d.inMinutes < 60) return '${d.inMinutes} min old';
  return '${d.inHours} h old';
}

String _dist(double m) =>
    m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

/// Picks the GPS. [needPhone]: something wants fast phone fixes (navigation,
/// Drive, SOS, recording, range logging); in Auto that keeps the phone.
LocationChoice chooseLocation({
  required LocationSource setting,
  required RadioGpsState radio,
  required DateTime now,
  bool needPhone = false,
}) {
  final (why, age, blur, err) = _radioUsable(radio, now);
  switch (setting) {
    case LocationSource.phone:
      return LocationChoice(
        active: ActiveLocation.phone,
        setting: setting,
        why: why,
        radioAge: age,
        link: radio.link,
        blurM: blur,
        errorM: err,
      );
    case LocationSource.radio:
      return LocationChoice(
        active: why == null ? ActiveLocation.radio : ActiveLocation.none,
        setting: setting,
        why: why,
        radioAge: age,
        link: radio.link,
        blurM: blur,
        errorM: err,
      );
    case LocationSource.auto:
      final w = why ?? (needPhone ? RadioGpsWhy.needPhone : null);
      return LocationChoice(
        active: w == null ? ActiveLocation.radio : ActiveLocation.phone,
        setting: setting,
        why: w,
        radioAge: age,
        link: radio.link,
        blurM: blur,
        errorM: err,
      );
  }
}

(RadioGpsWhy?, Duration?, double, double) _radioUsable(
  RadioGpsState r,
  DateTime now,
) {
  if (!r.connected) return (RadioGpsWhy.notConnected, null, 0, 0);
  final notSharing = !r.sharing || r.broadcastSecs == radioPositionNever;
  final p = r.pos;
  final at = r.at;
  final age = at == null
      ? null
      : (now.isBefore(at) ? Duration.zero : now.difference(at));
  if (p == null) {
    return (
      notSharing ? RadioGpsWhy.notSharing : RadioGpsWhy.noPosition,
      null,
      0,
      0,
    );
  }
  if (p.source == PositionPb.sourceManual) {
    return (RadioGpsWhy.fixedPosition, age, 0, 0);
  }
  if (p.source == PositionPb.sourceExternal) {
    return (RadioGpsWhy.fromPhone, age, 0, 0);
  }
  final blur = blurMetres(p.precisionBits);
  final err = radioFixErrorM(p);
  if (blur > radioFixMaxErrorM) return (RadioGpsWhy.blurred, age, blur, err);
  if (err > radioFixMaxErrorM) return (RadioGpsWhy.weak, age, blur, err);
  final max = radioFixMaxAgeFor(broadcastSecs: r.broadcastSecs, smart: r.smart);
  if (age == null || age > max) {
    return (
      notSharing ? RadioGpsWhy.notSharing : RadioGpsWhy.stale,
      age,
      blur,
      err,
    );
  }
  return (null, age, blur, err);
}
