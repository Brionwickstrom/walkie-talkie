/// Build-time configuration. Override with e.g.
/// `flutter run --dart-define=RELAY_URL=wss://relay.example.com/`.
class AppConfig {
  /// WebSocket relay used by the internet transport. Empty = internet link
  /// disabled until set in the app's settings sheet.
  static const String relayUrl = String.fromEnvironment('RELAY_URL');

  static const int defaultChannel = 1;
}
