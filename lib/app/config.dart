/// Build-time configuration. Override with e.g.
/// `flutter run --dart-define=RELAY_URL=wss://relay.example.com/ws`.
class AppConfig {
  /// WebSocket relay used by the internet transport (works on mobile data
  /// and Wi-Fi). Users can override it in Settings; "off" disables it.
  static const String relayUrl = String.fromEnvironment(
    'RELAY_URL',
    defaultValue: defaultRelayUrl,
  );

  /// v1.8.8: home relay first, backup second (see [MultiRelayTransport]).
  static const String defaultRelayUrl = '$homeRelayUrl, $backupRelayUrl';

  /// The home relay: the Synology NAS (tool/relay_server.dart in Docker),
  /// public through Tailscale Funnel. Always on, no cold start.
  static const String homeRelayUrl = 'wss://walkie-relay.tail1700cf.ts.net/ws';

  /// The backup relay: Render free web service from render.yaml (relay/ in
  /// this repo). Sleeps when idle and takes ~50 s to wake.
  static const String backupRelayUrl =
      'wss://brion-walkie-relay.onrender.com/ws';

  /// Saved relay settings that only repeat an old built-in default; they
  /// mean "the default" and get today's list (home + backup).
  static const List<String> legacyDefaults = [backupRelayUrl];

  static const int defaultChannel = 1;
}
