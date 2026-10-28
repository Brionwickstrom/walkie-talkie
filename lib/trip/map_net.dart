import 'dart:async';

import 'package:flutter/foundation.dart';

/// How the phone's internet looks to the map features (v2.1.0).
enum MapNetState {
  /// Requests are working.
  online,

  /// One request failed or timed out: try online, but only wait briefly.
  weak,

  /// Several failed in a row: use the saved maps and data at once; keep
  /// checking and switch back as soon as a check works.
  offline,
}

/// Tells tiles, search, routing and rerouting whether the internet works
/// right now, without waiting for slow timeouts.
///
/// Fed by real request outcomes ([ok] / [fail]) and by a cheap connection
/// check ([probe], the same kind of page the connection test uses). It
/// only checks while something needs it: on screen, or while a route is
/// active, so an idle phone in a pocket stays quiet (v2.0.0 battery rules).
class MapNet extends ChangeNotifier {
  MapNet({this.probe, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    // The first connection check comes after one interval, not at once.
    _lastProbe = _clock();
  }

  /// The cheap connection check (true = got an answer in time).
  Future<bool> Function(Duration timeout)? probe;
  final DateTime Function() _clock;

  MapNetState _state = MapNetState.online;
  MapNetState get state => _state;

  int _fails = 0;
  DateTime? _lastProbe;
  DateTime? _lastAttempt;
  bool _probing = false;

  /// Waiting time for a routing request while online.
  static const Duration onlineTimeout = Duration(seconds: 7);

  /// Waiting time when the connection is weak or down.
  static const Duration weakTimeout = Duration(milliseconds: 2500);

  /// Failures in a row that mean "offline".
  static const int offlineAfter = 2;

  /// While offline, one online try is still allowed this often, in case
  /// the check page is blocked but the map servers work.
  static const Duration retryEvery = Duration(seconds: 10);

  Duration get routingTimeout =>
      _state == MapNetState.online ? onlineTimeout : weakTimeout;

  /// What to pass a router as its wait: null (its own, longer wait) while
  /// online, the short one while the connection is weak or down.
  Duration? get routingTimeoutOverride =>
      _state == MapNetState.online ? null : weakTimeout;

  bool get isOnline => _state == MapNetState.online;
  bool get isOffline => _state == MapNetState.offline;

  /// Online services may be tried now. Offline: only once in a while, so a
  /// route request never sits waiting when there is plainly no signal.
  bool get allowOnline {
    if (_state != MapNetState.offline) return true;
    final l = _lastAttempt;
    return l == null || _clock().difference(l) >= retryEvery;
  }

  /// An online request is about to start.
  void attempt() => _lastAttempt = _clock();

  void ok() {
    _fails = 0;
    _set(MapNetState.online);
  }

  /// A request failed for lack of signal (not "no route there").
  void fail({bool hard = false}) {
    _fails++;
    _set(
      hard || _fails >= offlineAfter ? MapNetState.offline : MapNetState.weak,
    );
  }

  void _set(MapNetState s) {
    if (s == _state) return;
    _state = s;
    notifyListeners();
  }

  /// Run the connection check now. Returns true when it worked.
  Future<bool> probeNow() async {
    final p = probe;
    if (p == null || _probing) return _state == MapNetState.online;
    _probing = true;
    _lastProbe = _clock();
    try {
      final good = await p(weakTimeout);
      if (good) {
        ok();
      } else {
        fail(hard: true);
      }
      return good;
    } catch (_) {
      fail(hard: true);
      return false;
    } finally {
      _probing = false;
    }
  }

  /// How long to wait between connection checks (null = do not check).
  /// [onScreen]: the app is showing. [routing]: a route is being followed.
  Duration? probeEvery({required bool onScreen, required bool routing}) {
    if (!onScreen && !routing) return null;
    if (_state == MapNetState.online) {
      return onScreen
          ? Duration(seconds: routing ? 8 : 20)
          : Duration(seconds: 30);
    }
    // Weak or offline: look again soon so the switch back is quick.
    return onScreen ? Duration(seconds: 4) : Duration(seconds: 12);
  }

  /// Called about once a second by the Trip tab.
  void tick({required bool onScreen, required bool routing}) {
    final every = probeEvery(onScreen: onScreen, routing: routing);
    if (every == null || probe == null) return;
    final l = _lastProbe;
    if (l == null || _clock().difference(l) >= every) {
      unawaited(probeNow());
    }
  }
}
