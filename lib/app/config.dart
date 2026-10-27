/// Build-time configuration. Override with e.g.
/// `flutter run --dart-define=RELAY_URL=wss://relay.example.com/ws`.
class AppConfig {
  /// WebSocket relay used by the internet transport (works on mobile data
  /// and Wi-Fi). Users can override it in Settings; "off" disables it.
  static const String relayUrl = String.fromEnvironment(
    'RELAY_URL',
    defaultValue: defaultRelayUrl,
  );

  /// v1.8.8: home relay first, backup second; v2.0.0: backup relay 2 third
  /// (see [MultiRelayTransport]; all are connected and raced at once).
  static const String defaultRelayUrl =
      '$homeRelayUrl, $backupRelayUrl, $backupRelay2Url';

  /// The home relay: the Synology NAS (tool/relay_server.dart in Docker),
  /// public through Tailscale Funnel. Always on, no cold start.
  static const String homeRelayUrl = 'wss://walkie-relay.tail1700cf.ts.net/ws';

  /// The backup relay: Render free web service from render.yaml (relay/ in
  /// this repo). Sleeps when idle and takes ~50 s to wake.
  static const String backupRelayUrl =
      'wss://brion-walkie-relay.onrender.com/ws';

  /// v2.0.0: the second Render backup relay (its own Render service, same
  /// relay/ code). The only place its URL is written down.
  static const String backupRelay2Url =
      'wss://brion-walkie-relay-2.onrender.com/ws';

  /// Saved relay settings that only repeat an old built-in default; they
  /// mean "the default" and get today's list (home + backups).
  static const List<String> legacyDefaults = [
    backupRelayUrl,
    '$homeRelayUrl, $backupRelayUrl',
  ];

  static const int defaultChannel = 1;
}
