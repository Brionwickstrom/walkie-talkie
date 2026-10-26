/// Lets a short foreground Bluetooth scan (looking for a LoRa radio to
/// pair) run without the app's background BLE peer scan restarting over
/// it: flutter_blue_plus has one scan per app.
class BleScanLock {
  static DateTime? _until;

  /// Hold the scanner for [d].
  static void hold(Duration d) => _until = DateTime.now().add(d);
  static void release() => _until = null;

  static bool get held {
    final u = _until;
    return u != null && DateTime.now().isBefore(u);
  }
}
