import 'dart:io' show Platform;

/// What this device can do (v1.9.6): the same app runs on Android phones
/// and tablets and, from v1.9.6, as a Windows desktop app. Desktop has no
/// Bluetooth phone links, Wi-Fi Direct, camera QR scan, GPS, compass,
/// listening service or APK updater; it talks over the internet relays,
/// direct UDP links and the local network, and reaches a Meshtastic radio
/// over USB serial or Wi-Fi (TCP 4403) instead of Bluetooth.
///
/// Tests run on Linux and Windows hosts; they see the phone feature set
/// unless they set [debugDesktop].
class PlatformCaps {
  PlatformCaps._();

  /// Tests: force the desktop (true) or phone (false) feature set.
  static bool? debugDesktop;

  static bool get _underTest =>
      Platform.environment.containsKey('FLUTTER_TEST');

  /// Running as the desktop app (Windows, also macOS / Linux builds).
  static bool get desktop {
    final d = debugDesktop;
    if (d != null) return d;
    if (_underTest) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  static bool get windows =>
      desktop && (debugDesktop != null || Platform.isWindows);

  /// Bluetooth LE phone-to-phone links and the Meshtastic Bluetooth pairing.
  static bool get bluetooth => !desktop;

  /// Camera for scanning invite / friend QR codes and taking photos.
  static bool get camera => !desktop;

  /// Phone sensors (compass) and GPS.
  static bool get sensors => !desktop;

  /// Meshtastic radios over USB serial / TCP instead of Bluetooth.
  static bool get streamRadios => desktop;
}
