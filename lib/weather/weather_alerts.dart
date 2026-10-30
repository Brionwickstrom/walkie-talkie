import 'dart:async';

import 'package:flutter/foundation.dart';

import '../trip/geo.dart';
import 'alert_store.dart';
import 'nws_client.dart';
import 'wx_alert.dart';

/// A place the phone keeps an eye on.
class WxWatchPoint {
  const WxWatchPoint(this.label, this.point, {this.isFix = false});

  /// "Your last known location", "Camp Hollow" (a saved area).
  final String label;
  final GeoPoint point;

  /// The phone's own last position (remembered for the next start).
  final bool isFix;
}

/// One place we cover, for the Settings list.
class WxArea {
  const WxArea(this.label, this.place, this.supported, this.known);
  final String label;

  /// "Portland, OR" once the NWS told us.
  final String place;

  /// False outside the US.
  final bool supported;

  /// The NWS has answered for this place.
  final bool known;

  String get text => !supported
      ? '$label (not covered by the NWS)'
      : place.isEmpty
      ? label
      : '$label · $place';
}

/// Weather alerts straight from the National Weather Service (stage 1).
///
/// Cost: a place is looked up once (cached 30 days); then ONE small request
/// every 10 minutes (5 while a warning is active) for all places together,
/// only while the app runs (on screen, or kept alive by background
/// listening). No GPS is started, no timers beyond the one poll timer.
/// Stages 2 and 3 feed [AlertStore.ingest] from the relay and the radio and
/// call [handle] to notify.
class WeatherAlerts extends ChangeNotifier {
  WeatherAlerts({
    required this.store,
    required this.client,
    required this.points,
    this.enabled = _yes,
    this.networkOk = _yes,
    this.slow = _no,
    this.onNotify,
    this.onCleared,
    this.onRead,
    DateTime Function()? clock,
    this.initialDelay = const Duration(seconds: 20),
  }) : _clock = clock ?? DateTime.now;

  static bool _yes() => true;
  static bool _no() => false;

  final AlertStore store;
  final NwsClient client;

  /// Places to watch (last fix, saved areas).
  final List<WxWatchPoint> Function() points;
  final bool Function() enabled;

  /// False when the connection is not allowed now (Wi-Fi only on mobile).
  final bool Function() networkOk;

  /// Offline saver: check every 30 minutes only.
  final bool Function() slow;
  final Future<void> Function(WxAlert a)? onNotify;

  /// An alert ended: take its notification down.
  final void Function(WxAlert a)? onCleared;

  /// This device just read these alerts from the NWS itself for [zones]
  /// (v2.5.2: the hook that shares them over the relay and the radio, and
  /// that decides which states' relay rooms to join).
  final Future<void> Function(List<WxAlert> got, Set<String> zones)? onRead;
  final DateTime Function() _clock;
  final Duration initialDelay;

  static const maxPoints = 6;
  static const zonesTtl = Duration(days: 30);
  static const unsupportedTtl = Duration(days: 7);
  static const fixMaxAge = Duration(days: 7);

  Timer? _timer;
  bool _polling = false;
  bool _stopped = true;
  int _failures = 0;
  int polls = 0;
  String? lastError;
  List<WxWatchPoint> _watched = const [];
  bool _noArea = false;

  /// Alerts in force now, most important first.
  List<WxAlert> get active => store.active(_clock());
  bool get hasActive => active.isNotEmpty;
  DateTime? get lastChecked => store.lastChecked;
  bool get isOn => enabled();

  /// The most important alert in force, or null.
  WxAlert? get top => active.isEmpty ? null : active.first;

  /// Time until the next check.
  Duration get interval {
    final base = slow()
        ? const Duration(minutes: 30)
        : hasActive
        ? const Duration(minutes: 5)
        : const Duration(minutes: 10);
    if (_failures == 0) return base;
    final backed = base * (1 << (_failures > 3 ? 3 : _failures));
    return backed > const Duration(minutes: 30)
        ? const Duration(minutes: 30)
        : backed;
  }

  Future<void> load() async {
    await store.load();
    notifyListeners();
  }

  /// Start the schedule (first check after [initialDelay]).
  void start() {
    _stopped = false;
    _schedule(initialDelay);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration d) {
    _timer?.cancel();
    if (_stopped) return;
    _timer = Timer(d, () => unawaited(poll()));
  }

  /// The app came to the screen: check now if the last check is old.
  Future<void> resume() async {
    if (_stopped || !enabled()) return;
    final last = store.lastChecked;
    if (last != null &&
        _clock().difference(last) < const Duration(minutes: 2)) {
      return;
    }
    await poll();
  }

  /// Settings changed (switched on / Wi-Fi only off): look again soon.
  void settingsChanged() {
    if (_stopped) return;
    if (!enabled()) {
      _timer?.cancel();
      notifyListeners();
      return;
    }
    _schedule(const Duration(seconds: 2));
    notifyListeners();
  }

  /// The place list: the live ones, then the last remembered fix.
  List<WxWatchPoint> _gather({bool remember = false}) {
    final out = <String, WxWatchPoint>{};
    for (final p in points()) {
      if (!p.point.valid) continue;
      out.putIfAbsent(wxPlaceKey(p.point), () => p);
      if (p.isFix && remember) {
        store.lastFix = p.point;
        store.lastFixAt = _clock();
      }
    }
    final fix = store.lastFix;
    final at = store.lastFixAt;
    if (fix != null &&
        at != null &&
        _clock().difference(at) < fixMaxAge &&
        !out.containsKey(wxPlaceKey(fix))) {
      out[wxPlaceKey(fix)] = WxWatchPoint(
        'Your last known location',
        fix,
        isFix: true,
      );
    }
    return out.values.take(maxPoints).toList();
  }

  /// The places covered, with what the NWS said about each.
  List<WxArea> get areas {
    final pts = _watched.isEmpty ? _gather() : _watched;
    return [
      for (final p in pts)
        () {
          final z = store.zones[wxPlaceKey(p.point)];
          return WxArea(
            p.label,
            z?.place ?? '',
            z?.supported ?? true,
            z != null,
          );
        }(),
    ];
  }

  /// One check. [force]: ignore Wi-Fi only (the user tapped refresh).
  Future<bool> poll({bool force = false}) async {
    if (_polling) return false;
    if (!enabled()) return false;
    if (!force && !networkOk()) {
      _schedule(interval);
      return false;
    }
    _polling = true;
    var ok = false;
    try {
      ok = await _poll();
    } catch (e) {
      lastError = '$e';
    } finally {
      _polling = false;
    }
    _failures = ok ? 0 : _failures + 1;
    polls++;
    _schedule(interval);
    notifyListeners();
    return ok;
  }

  Future<bool> _poll() async {
    final now = _clock();
    _watched = _gather(remember: true);
    _noArea = false;
    final zones = <String>{};
    var lookupFailed = false;
    for (final p in _watched) {
      final key = wxPlaceKey(p.point);
      var z = store.zones[key];
      final ttl = z == null
          ? Duration.zero
          : z.supported
          ? zonesTtl
          : unsupportedTtl;
      if (z == null || now.difference(z.at) > ttl) {
        final fresh = await client.zonesFor(key, now: now);
        if (fresh != null) {
          store.zones[key] = fresh;
          z = fresh;
        } else {
          lookupFailed = true;
        }
      }
      if (z != null && z.supported) zones.addAll(z.zones);
    }
    if (zones.isEmpty) {
      // Nowhere to ask about (no position yet, outside the US, or the
      // lookup failed). What we hold stays until it expires.
      _noArea = !lookupFailed;
      lastError = lookupFailed
          ? 'Could not reach the National Weather Service'
          : null;
      await _expire();
      await store.save();
      return !lookupFailed;
    }
    final got = await client.activeFor(zones);
    if (got == null) {
      lastError = 'Could not reach the National Weather Service';
      await _expire();
      await store.save();
      return false;
    }
    lastError = null;
    store.lastChecked = now;
    await handle(got, authoritative: zones);
    try {
      await onRead?.call(got, zones);
    } catch (_) {}
    return !lookupFailed;
  }

  /// The zones of the places we cover (known from earlier lookups), also
  /// without internet.
  Set<String> get coveredZones {
    final pts = _watched.isEmpty ? _gather() : _watched;
    return {
      for (final p in pts)
        if (store.zones[wxPlaceKey(p.point)] case final z?)
          if (z.supported) ...z.zones,
    };
  }

  /// Take alerts from any source: store them, notify the new ones, take
  /// the notifications of ended ones down. Stages 2 and 3 call this with
  /// verified relay / radio alerts.
  Future<WxIngest> handle(
    Iterable<WxAlert> incoming, {
    Set<String>? authoritative,
  }) async {
    final r = store.ingest(incoming, authoritative: authoritative);
    for (final a in r.removed) {
      onCleared?.call(a);
    }
    for (final a in r.toNotify) {
      store.markNotified(a.key);
      try {
        await onNotify?.call(a);
      } catch (_) {}
    }
    await store.save();
    if (r.changed) notifyListeners();
    return r;
  }

  Future<void> _expire() async {
    for (final a in store.expire()) {
      onCleared?.call(a);
    }
  }

  /// One line for Settings and the Alerts page.
  String statusLine({DateTime? now}) {
    if (!enabled()) return 'Weather alerts are off';
    final t = now ?? _clock();
    final n = active.length;
    final ago = lastChecked == null ? null : _ago(t.difference(lastChecked!));
    if (n > 0) {
      return '$n ${n == 1 ? 'warning' : 'warnings'} for your area'
          '${ago == null ? '' : ' · checked $ago'}';
    }
    if (_noArea || (areas.isEmpty && lastChecked == null)) {
      return 'Waiting for a place to watch';
    }
    if (lastChecked == null) {
      return lastError == null ? 'Checking…' : "Couldn't check yet";
    }
    return 'No warnings for your area · checked $ago'
        '${lastError != null ? ' (last try failed)' : ''}';
  }

  static String _ago(Duration d) {
    if (d.inSeconds < 45) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} min ago';
    if (d.inHours < 48) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
