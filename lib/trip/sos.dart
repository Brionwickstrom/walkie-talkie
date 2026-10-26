import 'geo.dart';
import 'trip_packet.dart';
import 'trip_route.dart';

/// My own SOS while it is active.
class OutgoingSos {
  OutgoingSos(this.id, this.startedAt, this.pos, this.accuracyM);
  final int id;
  final DateTime startedAt;
  GeoPoint? pos;
  double? accuracyM;
  int repeats = 0;
  DateTime? lastFast;
  DateTime? lastRadio;
  int radioSends = 0;

  /// Who acknowledged, and when.
  final Map<int, DateTime> acks = {};
  bool get acknowledged => acks.isNotEmpty;
}

/// Someone else's SOS.
class IncomingSos {
  IncomingSos(this.origin, this.id, this.firstAt);
  final int origin;
  final int id;
  final DateTime firstAt;
  DateTime lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  GeoPoint? pos;
  double? accuracyM;
  DateTime? posAt;
  int repeat = 0;
  bool cancelled = false;

  /// I pressed Acknowledge.
  DateTime? ackedAt;
  DateTime? _lastAckSent;

  /// Everyone known to have acknowledged (me included).
  final Map<int, DateTime> ackers = {};

  /// Came from a base camp phone that held it.
  bool held = false;
  String get key => '$origin:$id';
}

/// SOS alerts (v1.8.0): sending, repeating until acknowledged, cancelling,
/// and the receiving side (de-dup, location updates, acks).
///
/// * Start: sent at once on every fast link to everyone in range (flood)
///   and over the LoRa radio (highest radio priority).
/// * Until someone acknowledges: again every [fastRepeat] on fast links
///   and every [radioRepeat] over the radio (the radio's own rate limiter
///   still applies, at most [maxRadioSends] radio copies).
/// * After the first acknowledgement: only every [ackedRepeat] on fast
///   links (so phones that come into range later still see it), no radio.
/// * Cancel: sent [cancelRepeats] times on fast links ([fastRepeat] apart)
///   and twice over the radio.
class SosManager {
  SosManager({
    required this.localId,
    required this.send,
    required this.nextId,
    Clock? clock,
    this.fastRepeat = const Duration(seconds: 10),
    this.radioRepeat = const Duration(seconds: 30),
    this.ackedRepeat = const Duration(seconds: 60),
    this.ackResend = const Duration(seconds: 15),
    this.maxRadioSends = 20,
    this.cancelRepeats = 3,
    this.forgetAfter = const Duration(hours: 2),
  }) : _clock = clock ?? DateTime.now;

  final int localId;
  final TripSend send;
  final int Function() nextId;
  final Clock _clock;
  final Duration fastRepeat;
  final Duration radioRepeat;
  final Duration ackedRepeat;
  final Duration ackResend;
  final int maxRadioSends;
  final int cancelRepeats;
  final Duration forgetAfter;

  OutgoingSos? _active;
  OutgoingSos? get active => _active;

  // Cancel in progress.
  int? _cancelId;
  int _cancelLeft = 0;
  int _cancelRadioLeft = 0;
  DateTime? _cancelLast;
  DateTime? _cancelRadioLast;
  GeoPoint? _cancelPos;

  final Map<String, IncomingSos> _incoming = {};

  /// Others' alerts, newest first.
  List<IncomingSos> get incoming =>
      _incoming.values.toList()..sort((a, b) => b.firstAt.compareTo(a.firstAt));

  /// Alerts still sounding (not cancelled, not acknowledged by me).
  List<IncomingSos> get unanswered => [
    for (final s in incoming)
      if (!s.cancelled && s.ackedAt == null) s,
  ];

  /// A new alert arrived (sound the alarm).
  void Function(IncomingSos s)? onAlert;

  /// An alert was cancelled by its sender, or answered by me.
  void Function(IncomingSos s)? onStop;

  /// Someone acknowledged my SOS.
  void Function(int from)? onAcked;
  void Function()? onChange;

  // ------------------------------------------------------------ sending

  OutgoingSos start(GeoPoint? pos, {double? accuracyM}) {
    final now = _clock();
    final s = OutgoingSos(nextId(), now, pos, accuracyM);
    _active = s;
    _cancelLeft = 0;
    _sendActive(s, now, radio: true);
    onChange?.call();
    return s;
  }

  void updatePosition(GeoPoint pos, {double? accuracyM}) {
    final s = _active;
    if (s == null) return;
    s.pos = pos;
    s.accuracyM = accuracyM;
  }

  void cancel() {
    final s = _active;
    if (s == null) return;
    _active = null;
    _cancelId = s.id;
    _cancelPos = s.pos;
    _cancelLeft = cancelRepeats;
    _cancelRadioLeft = 2;
    _cancelLast = null;
    _cancelRadioLast = null;
    _tickCancel(_clock());
    onChange?.call();
  }

  void _sendActive(OutgoingSos s, DateTime now, {required bool radio}) {
    final msg = SosMsg(
      s.id,
      pos: s.pos,
      repeat: s.repeats,
      accuracyM: s.accuracyM,
    );
    s.repeats++;
    s.lastFast = now;
    final useRadio = radio && s.radioSends < maxRadioSends;
    if (useRadio) {
      s.lastRadio = now;
      s.radioSends++;
    }
    send(msg, TripRoute(flood: true, radio: useRadio));
  }

  void _tickCancel(DateTime now) {
    final id = _cancelId;
    if (id == null) return;
    final fastDue =
        _cancelLeft > 0 &&
        (_cancelLast == null || now.difference(_cancelLast!) >= fastRepeat);
    final radioDue =
        _cancelRadioLeft > 0 &&
        (_cancelRadioLast == null ||
            now.difference(_cancelRadioLast!) >= radioRepeat);
    if (!fastDue && !radioDue) return;
    if (fastDue) {
      _cancelLeft--;
      _cancelLast = now;
    }
    if (radioDue) {
      _cancelRadioLeft--;
      _cancelRadioLast = now;
    }
    send(
      SosMsg(id, pos: _cancelPos, cancel: true),
      TripRoute(flood: true, fast: fastDue, radio: radioDue),
    );
    if (_cancelLeft <= 0 && _cancelRadioLeft <= 0) _cancelId = null;
  }

  /// Call about once a second.
  void tick() {
    final now = _clock();
    final s = _active;
    if (s != null) {
      final fastEvery = s.acknowledged ? ackedRepeat : fastRepeat;
      final fastDue =
          s.lastFast == null || now.difference(s.lastFast!) >= fastEvery;
      final radioDue =
          !s.acknowledged &&
          s.radioSends < maxRadioSends &&
          (s.lastRadio == null || now.difference(s.lastRadio!) >= radioRepeat);
      if (fastDue || radioDue) {
        if (fastDue) {
          _sendActive(s, now, radio: radioDue);
        } else {
          // Radio only (the fast copy went recently).
          s.lastRadio = now;
          s.radioSends++;
          send(
            SosMsg(
              s.id,
              pos: s.pos,
              repeat: s.repeats++,
              accuracyM: s.accuracyM,
            ),
            const TripRoute(flood: true, fast: false, radio: true),
          );
        }
      }
    }
    _tickCancel(now);
    final before = _incoming.length;
    _incoming.removeWhere((_, v) => now.difference(v.lastAt) > forgetAfter);
    if (_incoming.length != before) onChange?.call();
  }

  // ------------------------------------------------------------ receiving

  /// An SOS from [origin]. Returns the alert (new or updated).
  IncomingSos? onSos(
    int origin,
    SosMsg m, {
    bool held = false,
    Duration age = Duration.zero,
  }) {
    if (origin == localId) return null;
    final now = _clock();
    final key = '$origin:${m.id}';
    var s = _incoming[key];
    final isNew = s == null;
    if (s == null) {
      if (m.cancel) {
        // Cancel for an alert we never saw: remember it so a late copy
        // of the alert does not sound.
        s = IncomingSos(origin, m.id, now.subtract(age))..cancelled = true;
        s.lastAt = now;
        _incoming[key] = s;
        return null;
      }
      s = IncomingSos(origin, m.id, now.subtract(age))..held = held;
      _incoming[key] = s;
    }
    s.lastAt = now;
    if (m.pos != null) {
      s.pos = m.pos;
      s.accuracyM = m.accuracyM;
      s.posAt = now.subtract(age);
    }
    if (m.repeat > s.repeat) s.repeat = m.repeat;
    if (m.cancel) {
      if (!s.cancelled) {
        s.cancelled = true;
        onStop?.call(s);
      }
      onChange?.call();
      return s;
    }
    if (s.cancelled) return s;
    if (isNew) {
      onAlert?.call(s);
    } else if (s.ackedAt != null) {
      // They are still repeating: our ack may not have reached them.
      _sendAck(s, now);
    }
    onChange?.call();
    return s;
  }

  /// I acknowledge [s]: tell everyone (the sender stops the radio repeats).
  void acknowledge(IncomingSos s) {
    final now = _clock();
    s.ackedAt ??= now;
    s.ackers[localId] = now;
    s._lastAckSent = null;
    _sendAck(s, now);
    onStop?.call(s);
    onChange?.call();
  }

  void _sendAck(IncomingSos s, DateTime now) {
    final last = s._lastAckSent;
    if (last != null && now.difference(last) < ackResend) return;
    s._lastAckSent = now;
    send(
      SosAckMsg(nextId(), origin: s.origin, sosId: s.id),
      const TripRoute(flood: true, radio: true),
    );
  }

  void onAck(int from, SosAckMsg m) {
    final now = _clock();
    final a = _active;
    if (m.origin == localId && a != null && a.id == m.sosId) {
      final first = !a.acks.containsKey(from);
      a.acks[from] = now;
      if (first) onAcked?.call(from);
      onChange?.call();
      return;
    }
    final s = _incoming['${m.origin}:${m.sosId}'];
    if (s != null) {
      s.ackers[from] = now;
      onChange?.call();
    }
  }

  void dismiss(IncomingSos s) {
    _incoming.remove(s.key);
    onChange?.call();
  }
}
