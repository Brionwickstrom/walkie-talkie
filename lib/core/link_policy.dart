/// Connection resilience policy (v1.9.8): how links are ranked, how often
/// they are checked, and when one counts as failing.
///
/// Goal: the fastest connection that works right now, with no waiting.
/// Every link runs at once; frames go on the best one (plus backups while
/// it looks shaky), and the ranking is re-evaluated for every frame.
library;

import 'transport.dart';

/// Tiers in the order the user asked for: the internet first (direct
/// phone-to-phone UDP, then the home and backup relays, all kept open
/// together), then the local Wi-Fi network, then the nearby links
/// (Bluetooth and Wi-Fi Direct), and the LoRa radio last.
enum LinkTier { internet, wifi, nearby, radio }

LinkTier tierOf(TransportKind k) => switch (k) {
  TransportKind.internet => LinkTier.internet,
  TransportKind.lan => LinkTier.wifi,
  TransportKind.wifiDirect => LinkTier.nearby,
  TransportKind.ble => LinkTier.nearby,
  TransportKind.lora => LinkTier.radio,
};

/// "Max speed (more battery)" or "Balanced" (Settings, v1.9.8).
enum ConnectionSpeed { maxSpeed, balanced }

/// What the phone is doing, for how often links are checked.
enum ProbeActivity {
  /// Talking, hearing someone talk, or a ring / SOS is going on.
  active,

  /// The app is on screen.
  foreground,

  /// The app is in the background (screen off or another app) and nothing
  /// is going on.
  idle,
}

class LinkPolicy {
  const LinkPolicy._();

  // ------------------------------------------------------------ ranking

  /// A link in a lower tier takes the top spot only when it is measured
  /// clearly faster than the tier winner: at least this many ms faster...
  static const overrideMinGainMs = 30;

  /// ... and at most this fraction of the tier winner's round trip.
  static const overrideMaxRatio = 0.5;

  /// Sort [kinds] best first: by tier, then by measured round trip inside
  /// a tier (unmeasured after measured, ties by the old LAN > Wi-Fi
  /// Direct > Bluetooth > internet order), healthy links before failing
  /// ([degraded]) ones. Then, because speed beats the tier order, a
  /// healthy link measured clearly faster than the winner (see
  /// [overrideMinGainMs], [overrideMaxRatio]) moves to the front: two
  /// phones on the same Wi-Fi talk over it, not round the world through a
  /// relay. LoRa never moves up (it can not carry live audio).
  static List<TransportKind> rank(
    Iterable<TransportKind> kinds, {
    required Duration? Function(TransportKind) rtt,
    bool Function(TransportKind)? degraded,
  }) {
    final bad = degraded ?? (_) => false;
    final l = kinds.toList();
    int cmp(TransportKind a, TransportKind b) {
      final da = bad(a), db = bad(b);
      if (da != db) return da ? 1 : -1;
      final t = tierOf(a).index.compareTo(tierOf(b).index);
      if (t != 0) return t;
      final ra = rtt(a), rb = rtt(b);
      if (ra != null && rb != null && ra != rb) return ra.compareTo(rb);
      if (ra != null && rb == null) return -1;
      if (ra == null && rb != null) return 1;
      return b.defaultPriority.compareTo(a.defaultPriority);
    }

    l.sort(cmp);
    if (l.length < 2 || bad(l.first)) return l;
    final topRtt = rtt(l.first);
    if (topRtt == null) return l;
    TransportKind? fastest;
    var fastestMs = topRtt.inMilliseconds;
    for (final k in l.skip(1)) {
      if (bad(k) || tierOf(k) == LinkTier.radio) continue;
      final r = rtt(k);
      if (r == null) continue;
      final ms = r.inMilliseconds;
      if (ms < fastestMs &&
          topRtt.inMilliseconds - ms >= overrideMinGainMs &&
          ms <= topRtt.inMilliseconds * overrideMaxRatio) {
        fastest = k;
        fastestMs = ms;
      }
    }
    if (fastest != null) {
      l
        ..remove(fastest)
        ..insert(0, fastest);
    }
    return l;
  }

  // --------------------------------------------------- probe intervals

  /// How often idle links are checked (relay keep-alive pings, per-phone
  /// round-trip pings while backgrounded, relay reconnects).
  static Duration probeInterval(ConnectionSpeed speed, ProbeActivity a) =>
      switch ((speed, a)) {
        (ConnectionSpeed.maxSpeed, ProbeActivity.active) => const Duration(
          seconds: 1,
        ),
        (ConnectionSpeed.maxSpeed, ProbeActivity.foreground) => const Duration(
          seconds: 3,
        ),
        (ConnectionSpeed.maxSpeed, ProbeActivity.idle) => const Duration(
          seconds: 15,
        ),
        (ConnectionSpeed.balanced, ProbeActivity.active) => const Duration(
          seconds: 2,
        ),
        (ConnectionSpeed.balanced, ProbeActivity.foreground) => const Duration(
          seconds: 5,
        ),
        (ConnectionSpeed.balanced, ProbeActivity.idle) => const Duration(
          seconds: 30,
        ),
      };

  /// Per-phone round-trip pings ride on the presence hello (every second
  /// normally). They are skipped on hellos closer together than this.
  static Duration peerPingInterval(ConnectionSpeed speed, ProbeActivity a) =>
      switch ((speed, a)) {
        (ConnectionSpeed.maxSpeed, ProbeActivity.idle) => const Duration(
          seconds: 5,
        ),
        (ConnectionSpeed.maxSpeed, _) => const Duration(seconds: 1),
        (ConnectionSpeed.balanced, ProbeActivity.active) => const Duration(
          seconds: 1,
        ),
        (ConnectionSpeed.balanced, ProbeActivity.foreground) => const Duration(
          seconds: 2,
        ),
        (ConnectionSpeed.balanced, ProbeActivity.idle) => const Duration(
          seconds: 15,
        ),
      };

  /// Longest wait between relay reconnect attempts.
  static Duration reconnectCap(ConnectionSpeed speed, ProbeActivity a) =>
      switch ((speed, a)) {
        (ConnectionSpeed.maxSpeed, ProbeActivity.idle) => const Duration(
          seconds: 15,
        ),
        (ConnectionSpeed.maxSpeed, _) => const Duration(seconds: 5),
        (ConnectionSpeed.balanced, ProbeActivity.idle) => const Duration(
          seconds: 30,
        ),
        (ConnectionSpeed.balanced, _) => const Duration(seconds: 10),
      };

  /// First wait after a relay connect fails (doubles up to [reconnectCap]).
  static const reconnectMin = Duration(milliseconds: 500);

  // ----------------------------------------------------- miss detection

  /// A ping not answered within this counts as a miss (one miss = the
  /// link is failing and backups carry the traffic at once): three round
  /// trips plus 200 ms, at least 600 ms, at most 1.5 s; 1.5 s when the
  /// round trip is not known yet.
  static Duration missDeadline(Duration? rtt) {
    if (rtt == null) return const Duration(milliseconds: 1500);
    final ms = rtt.inMilliseconds * 3 + 200;
    return Duration(milliseconds: ms.clamp(600, 1500));
  }

  /// Misses in a row before a phone link is reported down in the status
  /// (routing already avoids it after the first).
  static const missesForDown = 3;

  /// Relay websocket: "pong" deadline after a "ping" (relays answer in
  /// well under a second when healthy; cell links can stall briefly):
  /// four round trips plus 500 ms, between 1.5 and 4 s.
  static Duration relayPongDeadline(Duration? rtt) {
    if (rtt == null) return const Duration(seconds: 3);
    final ms = rtt.inMilliseconds * 4 + 500;
    return Duration(milliseconds: ms.clamp(1500, 4000));
  }

  /// Relay pongs missed in a row before the socket is replaced.
  static const relayMissesForReconnect = 2;

  /// Frames sent on a link this recently are sent again on the next best
  /// link when that link misses (chat, voice clip chunks, rings; never
  /// live audio, which just continues on the new path).
  static const resendWindow = Duration(milliseconds: 2500);

  /// Rough battery use of each mode, for the Settings text. Presence
  /// hellos (every second on every link) cost the most and are the same in
  /// both modes; the modes change the checks on top of them.
  static String estimate(ConnectionSpeed s) => switch (s) {
    ConnectionSpeed.maxSpeed =>
      'Max speed: moves to a working connection within about a second. '
          'Checks every 1-3 s while the app is open or you talk, every '
          '15 s in the background. Uses a little more battery than '
          'Balanced (roughly 1-3% more per hour with the app open; '
          'estimate, varies by phone).',
    ConnectionSpeed.balanced =>
      'Balanced: checks about half as often (every 2-5 s open, 30 s in '
          'the background), so switching can take 2-3 s. Slightly less '
          'battery.',
  };
}
