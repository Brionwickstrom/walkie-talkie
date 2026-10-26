import 'geo.dart';
import 'trip_route.dart';

class ContactState {
  ContactState(this.id, this.lastHeard);
  final int id;
  DateTime lastHeard;
  GeoPoint? lastPos;
  DateTime? lastPosAt;
  bool lost = false;
}

/// Lost-contact alerts (v1.8.0): warns once when someone on the trip has
/// not been heard from (any link, any message) for [threshold], with where
/// and when they were last seen. Only phones heard while it is watching
/// count; hearing them again clears the warning.
class LostContactMonitor {
  LostContactMonitor({
    this.threshold = const Duration(minutes: 20),
    Clock? clock,
  }) : _clock = clock ?? DateTime.now;

  Duration threshold;
  bool enabled = true;
  final Clock _clock;
  final Map<int, ContactState> _s = {};

  /// Fired once per lost person (until heard again).
  void Function(ContactState s)? onLost;
  void Function(ContactState s)? onFound;

  /// [id] was heard at [at] (default now), optionally with a location.
  void heard(int id, {DateTime? at, GeoPoint? pos, DateTime? posAt}) {
    final t = at ?? _clock();
    final s = _s.putIfAbsent(id, () => ContactState(id, t));
    if (t.isAfter(s.lastHeard)) s.lastHeard = t;
    if (pos != null) {
      final pt = posAt ?? t;
      if (s.lastPosAt == null || !pt.isBefore(s.lastPosAt!)) {
        s.lastPos = pos;
        s.lastPosAt = pt;
      }
    }
    if (s.lost && _clock().difference(s.lastHeard) < threshold) {
      s.lost = false;
      onFound?.call(s);
    }
  }

  ContactState? state(int id) => _s[id];

  /// Silent for this long (null if never heard).
  Duration? silentFor(int id) {
    final s = _s[id];
    return s == null ? null : _clock().difference(s.lastHeard);
  }

  /// Check everyone; returns the people who just became lost.
  List<ContactState> tick() {
    if (!enabled) return const [];
    final now = _clock();
    final out = <ContactState>[];
    for (final s in _s.values) {
      if (!s.lost && now.difference(s.lastHeard) >= threshold) {
        s.lost = true;
        out.add(s);
        onLost?.call(s);
      }
    }
    return out;
  }

  List<ContactState> get lost => [
    for (final s in _s.values)
      if (s.lost) s,
  ]..sort((a, b) => a.lastHeard.compareTo(b.lastHeard));

  void forget(int id) => _s.remove(id);
  void clear() => _s.clear();
}
