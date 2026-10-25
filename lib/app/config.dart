/// Build-time configuration. Override with e.g.
/// `flutter run --dart-define=RELAY_URL=wss://relay.example.com/ws`.
class AppConfig {
  /// WebSocket relay used by the internet transport (works on mobile data
  /// and Wi-Fi). Users can override it in Settings; "off" disables it.
  static const String relayUrl = String.fromEnvironment(
    'RELAY_URL',
    defaultValue: defaultRelayUrl,
  );

  /// Render free web service from render.yaml (relay/ in this repo).
  static const String defaultRelayUrl =
      'wss://brion-walkie-relay.onrender.com/ws';

  static const int defaultChannel = 1;
}
