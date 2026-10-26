import 'dart:async';

import 'package:flutter/foundation.dart';

/// What happened with the LoRa part of a refresh.
enum RadioProbe {
  /// Not asked for (plain pull-to-refresh).
  none,

  /// Asked over the radio; answers can take a minute or more.
  sent,

  /// Asked for, but the radio was asked less than [PeopleRefresh.radioEvery]
  /// ago.
  limited,

  /// Asked for, but no radio is connected.
  noRadio,
}

/// Result of one pull-to-refresh.
class RefreshResult {
  const RefreshResult({
    required this.found,
    required this.before,
    this.radio = RadioProbe.none,
    this.radioWait,
  });

  /// People listed when the spinner stopped (not counting this phone).
  final int found;

  /// People listed when the refresh started.
  final int before;
  final RadioProbe radio;

  /// [RadioProbe.limited]: how long until the radio may be asked again.
  final Duration? radioWait;

  int get added => found > before ? found - before : 0;

  /// "Found 3 people", plus a note about the radio.
  String get message {
    final who = found == 0
        ? 'No one found yet'
        : 'Found $found ${found == 1 ? 'person' : 'people'}';
    final extra = switch (radio) {
      RadioProbe.none => '',
      RadioProbe.sent => '. Asked over radio too, answers can take a minute.',
      RadioProbe.limited =>
        '. Radio was asked recently, try again in '
            '${_short(radioWait ?? Duration.zero)}.',
      RadioProbe.noRadio => '. No radio connected.',
    };
    return '$who$extra';
  }

  static String _short(Duration d) {
    final s = d.inSeconds < 1 ? 1 : d.inSeconds;
    if (s < 60) return '${s}s';
    final m = (s / 60).ceil();
    return '$m min';
  }
}

/// Pull-to-refresh for the people list and Who's where (v1.8.5).
///
/// [refresh] sends one "who's here?" probe on every fast path ([probe]:
/// LAN broadcast / multicast + subnet sweep, Wi-Fi Direct discovery,
/// a Bluetooth scan burst, the relay rooms and the phone mesh), and over
/// LoRa only when asked ([refresh] `radio: true`, at most once per
/// [radioEvery]). Then it waits for answers: the spinner stops once
/// nothing new arrived for [settle] (but not before [minWait], so the
/// replies' 0-500 ms jitter has a chance), or after [maxWait].
class PeopleRefresh {
  PeopleRefresh({
    required this.probe,
    this.probeRadio,
    this.changes,
    this.minWait = const Duration(milliseconds: 900),
    this.settle = const Duration(milliseconds: 700),
    this.maxWait = const Duration(seconds: 3),
    this.radioEvery = const Duration(minutes: 2),
    this.pollEvery = const Duration(milliseconds: 150),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Sends the probe on every non-radio path.
  final Future<void> Function() probe;

  /// Sends the probe over LoRa; false when no radio is connected. Null =
  /// no radio support.
  final bool Function()? probeRadio;

  /// Fires when someone shows up / changes (people list, lobby). The
  /// count is polled every [pollEvery] as well.
  final Listenable? changes;
  final Duration minWait;
  final Duration settle;
  final Duration maxWait;
  final Duration radioEvery;
  final Duration pollEvery;
  final DateTime Function() _clock;

  DateTime? _lastRadio;
  Future<RefreshResult>? _running;

  /// Counters (tests / Details).
  int probes = 0;
  int radioProbes = 0;

  bool get refreshing => _running != null;

  /// Time left before the radio may be asked again (zero = now).
  Duration get radioWait {
    final l = _lastRadio;
    if (l == null) return Duration.zero;
    final left = radioEvery - _clock().difference(l);
    return left.isNegative ? Duration.zero : left;
  }

  /// One refresh; a second call while one runs joins it ([radio] still
  /// adds the radio probe).
  Future<RefreshResult> refresh({
    required int Function() count,
    bool radio = false,
  }) {
    final r = _running;
    if (r != null) {
      if (!radio) return r;
      final rp = _radio();
      return r.then(
        (v) => RefreshResult(
          found: v.found,
          before: v.before,
          radio: rp.$1,
          radioWait: rp.$2,
        ),
      );
    }
    final f = _run(count, radio);
    _running = f;
    return f.whenComplete(() => _running = null);
  }

  (RadioProbe, Duration?) _radio() {
    final send = probeRadio;
    if (send == null) return (RadioProbe.noRadio, null);
    final wait = radioWait;
    if (wait > Duration.zero) return (RadioProbe.limited, wait);
    if (!send()) return (RadioProbe.noRadio, null);
    _lastRadio = _clock();
    radioProbes++;
    return (RadioProbe.sent, null);
  }

  Future<RefreshResult> _run(int Function() count, bool radio) async {
    final before = count();
    probes++;
    final done = Completer<void>();
    Timer? settleTimer;
    var minDone = false;
    var quiet = true;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    void arm() {
      settleTimer?.cancel();
      settleTimer = Timer(settle, () {
        quiet = true;
        if (minDone) finish();
      });
    }

    void onChange() {
      quiet = false;
      arm();
    }

    changes?.addListener(onChange);
    final minTimer = Timer(minWait, () {
      minDone = true;
      if (quiet) finish();
    });
    final maxTimer = Timer(maxWait, finish);
    // Also watch the count itself (the controller may notify for other
    // reasons, and not every path notifies).
    var last = before;
    final poll = Timer.periodic(pollEvery, (_) {
      final n = count();
      if (n != last) {
        last = n;
        onChange();
      }
    });
    try {
      await probe();
    } catch (_) {}
    final rp = radio ? _radio() : (RadioProbe.none, null);
    await done.future;
    changes?.removeListener(onChange);
    settleTimer?.cancel();
    minTimer.cancel();
    maxTimer.cancel();
    poll.cancel();
    return RefreshResult(
      found: count(),
      before: before,
      radio: rp.$1,
      radioWait: rp.$2,
    );
  }
}
