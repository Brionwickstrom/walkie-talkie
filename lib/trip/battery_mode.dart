// v2.6.12: Battery modes. One picker (Settings > Battery > Battery mode, and
// the Talk connection sheet) switches everything that costs battery at once:
//
//  * Saver: Share my location off (so no live updates, check-ins or radio
//    trail summaries), Range logging and its pings off, Keep home area
//    ready (background map precaching) off. The radio link stays up:
//    messages, voice and rings still come in. A location goes out only with
//    SOS (always works), "Check in now" or a dropped pin.
//  * Normal: today's behaviour with your own settings, exactly.
//  * Tracking: Share my location on, Range logging on (a ping to the home
//    radio every 30 s while charging, otherwise every 60-120 s, default 90)
//    and high-accuracy GPS every 10 s.
//
// Rules:
//  * Leaving Normal saves the settings the modes control ([BatterySnapshot]);
//    back to Normal puts exactly those back.
//  * While Saver or Tracking is on, a setting the mode controls is locked
//    (its switch is disabled with "Controlled by Battery mode"); pick Normal
//    to change it. The mode is never dropped behind your back.
//  * Location source (v2.6.7) is not touched: in Saver, Auto still uses the
//    radio's own GPS when it is good, which costs the phone nothing.
//  * One-tap range test (v2.6.10): it needs pings, so it cannot start in
//    Saver (the start sheet offers "Switch to Tracking"), and Saver cannot
//    be picked while a test runs (stop it first). Normal and Tracking work
//    with a test running; Normal during a test keeps Range logging on until
//    the test ends, then puts your own Range logging setting back.
//  * Tracking on battery (not charging) for over 3 hours: a gentle
//    suggestion to switch back to Normal (once per stretch on battery).
import 'dart:convert';

enum BatteryMode {
  saver('saver', 'Saver'),
  normal('normal', 'Normal'),
  tracking('tracking', 'Tracking');

  const BatteryMode(this.id, this.label);
  final String id;
  final String label;

  static BatteryMode fromId(Object? id) => switch (id) {
    'saver' => BatteryMode.saver,
    'tracking' => BatteryMode.tracking,
    _ => BatteryMode.normal,
  };

  /// What it does, one line (Settings and the connection sheet).
  String get summary => switch (this) {
    BatteryMode.saver =>
      'Least battery. Location sharing, Range logging pings and map '
          'precaching are off. Messages and voice still come in; SOS always '
          'works and sends your location.',
    BatteryMode.normal => 'Your own settings, as you set them.',
    BatteryMode.tracking =>
      'Most battery. Location shared with GPS every 10 s (high accuracy), '
          'Range logging pings the home radio every 30 s while charging, '
          'otherwise every 60-120 s.',
  };

  /// How it affects the battery, one line.
  String get battery => switch (this) {
    BatteryMode.saver =>
      'Phone GPS only while the Trip map is open, navigating, recording or '
          'in SOS; no radio pings from this phone (estimate: the biggest '
          'saving when you were sharing your location).',
    BatteryMode.normal => 'Battery use depends on your own settings.',
    BatteryMode.tracking =>
      'GPS every 10 s and a radio transmit every 30-120 s: keep the phone '
          'plugged in if you can.',
  };
}

/// The settings a mode controls.
enum BatterySetting { shareLocation, rangeLogging, warmHome }

const controlledNote = 'Controlled by Battery mode';

/// Tracking for this long on battery shows the suggestion.
const trackingNudgeAfter = Duration(hours: 3);

/// The value [mode] forces on [s], null = not controlled (your own).
bool? forcedBy(BatteryMode mode, BatterySetting s) => switch (mode) {
  BatteryMode.normal => null,
  BatteryMode.saver => false,
  BatteryMode.tracking => switch (s) {
    BatterySetting.shareLocation => true,
    BatterySetting.rangeLogging => true,
    BatterySetting.warmHome => null,
  },
};

bool controls(BatteryMode mode, BatterySetting s) => forcedBy(mode, s) != null;

/// The user's own values of the controlled settings, saved when leaving
/// Normal and put back on the way back.
class BatterySnapshot {
  const BatterySnapshot({
    required this.shareLocation,
    required this.rangeLogging,
    required this.warmHome,
  });
  final bool shareLocation;
  final bool rangeLogging;
  final bool warmHome;

  bool valueOf(BatterySetting s) => switch (s) {
    BatterySetting.shareLocation => shareLocation,
    BatterySetting.rangeLogging => rangeLogging,
    BatterySetting.warmHome => warmHome,
  };

  Map<String, Object?> toJson() => {
    'tm': shareLocation,
    'rl': rangeLogging,
    'wh': warmHome,
  };

  static BatterySnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    final tm = j['tm'], rl = j['rl'], wh = j['wh'];
    if (tm is! bool || rl is! bool || wh is! bool) return null;
    return BatterySnapshot(shareLocation: tm, rangeLogging: rl, warmHome: wh);
  }

  @override
  bool operator ==(Object other) =>
      other is BatterySnapshot &&
      other.shareLocation == shareLocation &&
      other.rangeLogging == rangeLogging &&
      other.warmHome == warmHome;

  @override
  int get hashCode => Object.hash(shareLocation, rangeLogging, warmHome);

  @override
  String toString() => jsonEncode(toJson());
}
