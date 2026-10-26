/// What runs, and how often, for the two battery modes (v1.8.1).
///
/// * Battery saver (`saver`): slower beacons / scans / keep-alives.
/// * Offline power save (`offline`): for when you know there is no
///   internet (a hike) and want the longest battery life. Stacks on top of
///   the saver: internet relays and network-change reconnects are off,
///   network sweeps off, Wi-Fi Direct discovery only on demand, Bluetooth
///   scans in short low-power bursts, slow GPS / check-ins / presence /
///   mesh announcements, no live location, no map downloads, dim dark UI
///   and no screen-on lock. Push-to-talk, receiving, the mesh relay
///   (rate limited), the LoRa radio, SOS (always full priority) and quick
///   messages keep working.
///
/// Pure data so tests can check which subsystems are on.
class PowerPlan {
  const PowerPlan({this.saver = false, this.offline = false});
  final bool saver;
  final bool offline;

  /// Transports run their battery saver (offline implies it).
  bool get transportSaver => saver || offline;

  // ------------------------------------------------ turned off offline
  bool get internetRelay => !offline;
  bool get networkChangeReconnects => !offline;
  bool get lanSweeps => !offline;
  bool get wifiDirectAutoDiscovery => !offline;
  bool get liveLocation => !offline;
  bool get mapTileDownloads => !offline;
  bool get weatherAutoRefresh => !offline;
  bool get rttPings => !transportSaver;
  bool get darkDimUi => offline;

  /// The app never holds a screen-on lock (the screen sleeps as usual).
  bool get keepScreenOn => false;

  // ------------------------------------------------ always on
  bool get pushToTalk => true;
  bool get receive => true;
  bool get meshRelay => true;
  bool get loraRadio => true;
  bool get sos => true;
  bool get quickMessages => true;

  // ------------------------------------------------ intervals
  static const normalHello = Duration(seconds: 1);
  static const saverHello = Duration(milliseconds: 2500);

  /// Hellos + mesh beacons: slow, but inside the Bluetooth silent-link
  /// drop (8 s) and the mesh neighbour window so relaying keeps working.
  static const offlineHello = Duration(seconds: 4);

  Duration helloInterval(Duration normal) =>
      offline ? offlineHello : (saver ? saverHello : normal);

  /// Friend presence ("fhello").
  Duration get presenceInterval =>
      offline ? const Duration(seconds: 7) : Duration(seconds: saver ? 6 : 3);

  /// Bluetooth scanning: null = continuous (normal), else
  /// (burst length, cycle when nobody linked, cycle when linked).
  ({Duration on, Duration idle, Duration linked})? get bleScan => offline
      ? (
          on: const Duration(seconds: 5),
          idle: const Duration(seconds: 45),
          linked: const Duration(seconds: 120),
        )
      : saver
      ? (
          on: const Duration(seconds: 8),
          idle: const Duration(seconds: 30),
          linked: const Duration(seconds: 90),
        )
      : null;

  /// Wi-Fi Direct service discovery period while not in a group (offline:
  /// effectively only when asked for with "Look for phones now").
  Duration get wifiDirectDiscovery => offline
      ? const Duration(minutes: 15)
      : Duration(seconds: saver ? 90 : 30);

  /// GPS fix interval for the Trip tab.
  Duration gpsInterval({required bool visible, required bool sosActive}) {
    if (sosActive) return const Duration(seconds: 5); // SOS: full speed
    if (offline) return Duration(seconds: visible ? 15 : 90);
    if (visible) return const Duration(seconds: 5);
    return Duration(seconds: saver ? 60 : 20);
  }

  /// Check-in period: offline doubles it, capped at 15 min so phones that
  /// only hear us by radio do not raise a lost-contact alert (20 min).
  int checkInMinutes(int every) {
    if (!offline || every <= 0) return every;
    final slow = every * 2;
    if (every >= 15) return every;
    return slow > 15 ? 15 : slow;
  }

  /// Rough extra battery life while waiting (varies a lot by phone).
  String get estimate {
    if (offline) {
      return 'About 1.5-2x the standby time of Normal (estimate, '
          'varies by phone). Talk, receive, phone relay, the radio, SOS and '
          'quick messages still work; new phones nearby can take up to a '
          'minute to show up.';
    }
    if (saver) return 'Roughly 20-35% less battery while waiting (estimate).';
    return 'Normal: fastest.';
  }
}
