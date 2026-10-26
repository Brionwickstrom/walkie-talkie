import 'dart:async';

/// Runs requests one at a time with at least [minInterval] between the
/// starts of two requests (Nominatim's usage policy: at most 1 per second;
/// Overpass is asked more gently still). [clock] and [sleep] are injectable
/// so tests do not wait.
class RateLimiter {
  RateLimiter(
    this.minInterval, {
    DateTime Function()? clock,
    Future<void> Function(Duration d)? sleep,
  }) : _clock = clock ?? DateTime.now,
       _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final Duration minInterval;
  final DateTime Function() _clock;
  final Future<void> Function(Duration d) _sleep;
  DateTime? _last;
  Future<void> _tail = Future<void>.value();

  /// When the last request started (null = none yet).
  DateTime? get lastStart => _last;

  /// How long a request made now would wait.
  Duration get waitNow {
    final l = _last;
    if (l == null) return Duration.zero;
    final w = l.add(minInterval).difference(_clock());
    return w.isNegative ? Duration.zero : w;
  }

  Future<T> run<T>(Future<T> Function() f) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return () async {
      try {
        await prev;
      } catch (_) {}
      try {
        final w = waitNow;
        if (w > Duration.zero) await _sleep(w);
        _last = _clock();
        return await f();
      } finally {
        done.complete();
      }
    }();
  }
}

/// Calls the latest action once things have been quiet for [delay]
/// (typing in the search box).
class Debouncer {
  Debouncer(this.delay);
  final Duration delay;
  Timer? _t;

  void call(void Function() f) {
    _t?.cancel();
    _t = Timer(delay, f);
  }

  bool get pending => _t?.isActive ?? false;

  void cancel() {
    _t?.cancel();
    _t = null;
  }
}
