/// Speed under a Trip-map marker (v2.6.16).
///
/// The words only. No timers, no GPS, no network: the caller already has
/// the latest fix. A label is shown when that fix included a speed and the
/// fix is still young. Live app updates stay young for two minutes. A
/// radio or a position that arrived over LoRa stays young for ten minutes.
library;

import '../core/transport.dart';

/// A phone-to-phone live update (BLE, LAN, Wi-Fi Direct, internet).
const Duration speedLabelFreshLive = Duration(minutes: 2);

/// A Meshtastic position, or an app position that came over LoRa.
const Duration speedLabelFreshRadio = Duration(minutes: 10);

/// Which freshness window applies. LoRa is the slow path.
Duration speedFreshFor(TransportKind via) =>
    via == TransportKind.lora ? speedLabelFreshRadio : speedLabelFreshLive;

/// "42 mph" or "68 km/h". Same miles factor as the person sheet.
String formatSpeed(double speedMps, {required bool imperial}) {
  if (imperial) return '${(speedMps * 2.23694).round()} mph';
  return '${(speedMps * 3.6).round()} km/h';
}

/// "Yeti · 42 mph", or null when there is no speed or the fix is not young.
///
/// [freshFor] is [speedLabelFreshLive] or [speedLabelFreshRadio]. A fix
/// exactly that old is not younger, so it is hidden. A missing speed or a
/// missing time is hidden. No other cutoff.
String? speedLabelText({
  required String name,
  required double? speedMps,
  required DateTime? at,
  required DateTime now,
  required bool imperial,
  required Duration freshFor,
}) {
  final v = speedMps;
  if (v == null || !v.isFinite || v < 0 || at == null) return null;
  if (now.difference(at) >= freshFor) return null;
  final who = name.trim().isEmpty ? 'Radio' : name.trim();
  return '$who · ${formatSpeed(v, imperial: imperial)}';
}

/// When a radio position was taken. [timeSeconds] is Position.time
/// (seconds since 1970), 0 when the radio did not send one: then the
/// moment we heard it.
DateTime radioPositionAt({required int timeSeconds, required DateTime heard}) {
  if (timeSeconds <= 0) return heard;
  return DateTime.fromMillisecondsSinceEpoch(timeSeconds * 1000);
}
