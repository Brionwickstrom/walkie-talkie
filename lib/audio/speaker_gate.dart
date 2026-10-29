import 'dart:async';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart' show PcmArrayInt16;

import 'pcm_speaker.dart';

/// Opens the speaker only while there is something to play (v2.2.0).
///
/// An open Android AudioTrack / Windows waveOut device keeps the audio
/// hardware awake even when nothing is fed. The gate keeps the speaker
/// closed until the first audio arrives, then closes it again once the
/// queued audio has played and nothing came for [idle] (a single timer that
/// only exists while the speaker is open; no silence is ever fed, no
/// polling).
///
/// The first audio is never clipped and not delayed more than necessary:
/// frames that arrive while the speaker is opening are kept and fed in
/// order the moment it is ready, and the leading jitter-cushion silence
/// ([feedSilence]) is shortened by the time the opening took, so the voice
/// starts when it would have started with an already-open speaker. v2.3.3:
/// a little of the cushion ([minCushion]) is always kept, so a slow opening
/// can not leave the first frames with nothing in front of them, and
/// [onOpened] tells the playout buffer when the speaker really started and
/// how much it was given.
///
/// v2.3.3: the quiet time before closing is 10 s (was 1.5 s, which closed
/// the speaker in every pause of a conversation and paid the opening cost
/// again, clipping first syllables). It never closes while [holdOpen] says a
/// talker is active (capped at [holdCap] after the last audio, so a lost
/// "talk end" can not keep it open), and [warmUp] opens it on the talk-start
/// signal, before the first audio arrives.
class SpeakerGate {
  SpeakerGate(
    this.speaker, {
    required this.sampleRate,
    required this.channels,
    this.idle = const Duration(seconds: 10),
    this.holdOpen,
    this.holdCap = const Duration(seconds: 45),
    this.minCushion = const Duration(milliseconds: 20),
    this.onOpened,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PcmSpeaker speaker;
  final int sampleRate, channels;

  /// Quiet time (after the queued audio has played) before it closes.
  final Duration idle;

  /// True while someone is talking: the speaker stays open.
  final bool Function()? holdOpen;

  /// The longest [holdOpen] keeps it open after the last queued audio.
  final Duration holdCap;

  /// At least this much of a leading silence cushion is kept when the
  /// opening took longer than the cushion.
  final Duration minCushion;

  /// Called right after the speaker opened and its waiting frames were fed:
  /// when it started and how many samples (silence included) it was given.
  final void Function(DateTime at, int fedSamples)? onOpened;
  final DateTime Function() _clock;

  bool _open = false;
  Future<void>? _opening;
  int _epoch = 0;
  DateTime _openStarted = DateTime.fromMillisecondsSinceEpoch(0);
  final List<({PcmArrayInt16 pcm, bool silence})> _pending = [];
  DateTime _playUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _timer;
  bool _disposed = false;

  /// The speaker (AudioTrack / waveOut) is open right now.
  bool get isOpen => _open;
  bool get isOpening => _opening != null;

  /// An idle timer is running (only while open).
  bool get timerRunning => _timer != null;

  /// How many times the speaker was opened (tests / debug).
  int opens = 0;

  /// Queue [pcm] behind what is playing; opens the speaker if needed.
  void feed(PcmArrayInt16 pcm) => _feed(pcm, false);

  /// Open the speaker now, before any audio (v2.3.3: someone just signalled
  /// "talking"), so the first syllables do not wait for the opening. It
  /// closes again after [idle] if no audio comes.
  void warmUp() {
    if (_disposed) return;
    final now = _clock();
    if (!_playUntil.isAfter(now)) _playUntil = now;
    if (_open) {
      _arm();
      return;
    }
    _ensureOpening();
  }

  /// Queue [samples] of silence (the jitter cushion before a burst).
  void feedSilence(int samples) =>
      _feed(PcmArrayInt16.zeros(count: samples * channels), true);

  void _feed(PcmArrayInt16 pcm, bool silence) {
    if (_disposed) return;
    final n = pcm.bytes.lengthInBytes ~/ 2 ~/ channels;
    final now = _clock();
    final from = _playUntil.isAfter(now) ? _playUntil : now;
    _playUntil = from.add(Duration(microseconds: n * 1000000 ~/ sampleRate));
    if (_open) {
      speaker.feed(pcm);
      _arm();
      return;
    }
    _pending.add((pcm: pcm, silence: silence));
    _ensureOpening();
  }

  void _ensureOpening() {
    if (_opening != null || _disposed) return;
    final epoch = _epoch;
    _openStarted = _clock();
    _opening = () async {
      try {
        await speaker.setup(sampleRate: sampleRate, channels: channels);
      } catch (_) {
        _opening = null;
        if (epoch == _epoch) _pending.clear();
        return;
      }
      _opening = null;
      if (epoch != _epoch || _disposed) {
        // Closed while it was opening: close it again; frames that came
        // since belong to a new opening.
        try {
          await speaker.release();
        } catch (_) {}
        if (_pending.isNotEmpty && !_disposed) _ensureOpening();
        return;
      }
      _open = true;
      opens++;
      final openedAt = _clock();
      var skip =
          openedAt.difference(_openStarted).inMicroseconds *
          sampleRate ~/
          1000000;
      var keep = minCushion.inMicroseconds * sampleRate ~/ 1000000;
      var fed = 0;
      for (final f in _pending) {
        var pcm = f.pcm;
        final have = pcm.bytes.lengthInBytes ~/ 2 ~/ channels;
        if (f.silence && skip > 0) {
          // Shorten the cushion by the opening time, but keep a floor.
          final room = have > keep ? have - keep : 0;
          final cut = skip < room ? skip : room;
          skip -= cut;
          keep = keep > (have - cut) ? keep - (have - cut) : 0;
          if (cut == have) continue;
          pcm = PcmArrayInt16.zeros(count: (have - cut) * channels);
        }
        fed += pcm.bytes.lengthInBytes ~/ 2 ~/ channels;
        speaker.feed(pcm);
      }
      _pending.clear();
      try {
        onOpened?.call(openedAt, fed);
      } catch (_) {}
      _arm();
    }();
  }

  void _arm() {
    if (_timer != null || !_open) return;
    final wait = _playUntil.add(idle).difference(_clock());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _onTimer);
  }

  void _onTimer() {
    _timer = null;
    if (!_open) return;
    final now = _clock();
    if (now.isBefore(_playUntil.add(idle))) {
      _arm(); // more audio was queued meanwhile
    } else if ((holdOpen?.call() ?? false) &&
        now.isBefore(_playUntil.add(holdCap))) {
      // Someone is still talking (a long pause inside a burst): stay open.
      _timer = Timer(idle, _onTimer);
    } else {
      unawaited(release());
    }
  }

  /// Stop now and drop everything queued; the next [feed] opens again.
  Future<void> release() async {
    _timer?.cancel();
    _timer = null;
    _epoch++;
    _pending.clear();
    _playUntil = DateTime.fromMillisecondsSinceEpoch(0);
    final o = _opening;
    if (o != null) await o; // it closes itself (epoch changed)
    if (_open) {
      _open = false;
      try {
        await speaker.release();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await release();
  }
}
