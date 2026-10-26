import 'dart:collection';
import 'dart:typed_data';

/// Decides, frame by frame, whether live audio from a phone may play.
///
/// Why (v1.5.2): phones on 1.5.0 or older can leave their mic on after a
/// quick tap (see MicGate). Such a phone keeps streaming everything its
/// speaker plays, AGC on both ends keeps it loud, and two of them echo an
/// old voice message or talk back and forth forever. Every phone that
/// listens used to play that stream, even after the sender had said
/// "talk end". This gate only lets a stream through while the sender
/// says it is talking, so a newer phone stays quiet no matter what the
/// older phones do:
///  * talking (talkStart seen): plays, for at most [maxStream];
///  * talkEnd seen during this burst: plays only the [tail] right after
///    it; the rest is a mic left on: dropped;
///  * no talk signal at all for this burst (talkStart lost or late): plays
///    for at most [unsignalled], then dropped;
///  * an Opus packet identical to one from the same sender in the last
///    [repeatWindow] is dropped (a delayed copy over another transport,
///    or a re-sent burst);
///  * after Stop ([silenceAll]) a sender stays silent until its next
///    talkStart (or, for 1:1 talk without talk signals, its next burst).
class LiveAudioGate {
  LiveAudioGate({
    DateTime Function()? clock,
    this.tail = const Duration(milliseconds: 1000),
    this.unsignalled = const Duration(seconds: 60),
    this.burstGap = const Duration(milliseconds: 1500),
    this.maxStream = const Duration(minutes: 3),
    this.repeatWindow = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration tail;
  final Duration unsignalled;
  final Duration burstGap;
  final Duration maxStream;
  final Duration repeatWindow;

  final Map<int, _PeerGate> _peers = {};

  static const reasonStopped = 'stopped by you';
  static const reasonNotTalking = 'not talking (mic left on?)';
  static const reasonTooLong = 'over 3 min non-stop';
  static const reasonRepeat = 'repeat of audio already played';

  /// Returns null if the frame may play, else why not. [talking] is the
  /// sender's talk state (talkStart / talkEnd), or null when the link has
  /// no talk signals (1:1 friend talk: bursts count instead).
  String? admit(int peer, Uint8List opus, {required bool? talking}) {
    final now = _clock();
    final g = _peers.putIfAbsent(peer, _PeerGate.new);
    final last = g.lastFrame;
    final newBurst = last == null || now.difference(last) > burstGap;
    g.lastFrame = now;
    if (newBurst) {
      g.burstStart = now;
      if (talking == null) g.silenced = false;
    }
    if (talking != null) {
      if (talking && !g.wasTalking) {
        g.talkStart = now;
        g.silenced = false;
      } else if (!talking && g.wasTalking) {
        g.lastEnd = now;
      }
      g.wasTalking = talking;
    }

    final repeat = g.seenRecently(_hash(opus), now, repeatWindow);
    if (g.silenced) return reasonStopped;
    if (talking == null) {
      if (now.difference(g.burstStart!) > maxStream) return reasonTooLong;
    } else if (talking) {
      if (now.difference(g.talkStart ?? g.burstStart!) > maxStream) {
        return reasonTooLong;
      }
    } else {
      final end = g.lastEnd;
      // A talkEnd just before the burst started counts too (the mic opened
      // after the button was already released: the v1.5.0 race).
      final endedThisBurst =
          end != null && end.isAfter(g.burstStart!.subtract(burstGap));
      if (endedThisBurst) {
        if (now.difference(end) > tail) return reasonNotTalking;
      } else if (now.difference(g.burstStart!) > unsignalled) {
        return reasonNotTalking;
      }
    }
    if (repeat) return reasonRepeat;
    return null;
  }

  /// Tell the gate about a talk signal as it happens (so a sender that was
  /// stopped can be heard again from its next talkStart).
  void talkChanged(int peer, bool talking) {
    final now = _clock();
    final g = _peers.putIfAbsent(peer, _PeerGate.new);
    if (talking && !g.wasTalking) {
      g.talkStart = now;
      g.silenced = false;
    } else if (!talking && g.wasTalking) {
      g.lastEnd = now;
    }
    g.wasTalking = talking;
  }

  /// Stop: silence everyone currently streaming until they talk again.
  void silenceAll() {
    for (final g in _peers.values) {
      g.silenced = true;
    }
  }

  bool isSilenced(int peer) => _peers[peer]?.silenced ?? false;

  void forget(int peer) => _peers.remove(peer);

  static int _hash(Uint8List b) {
    // FNV-1a, 32 bit, plus the length.
    var h = 0x811c9dc5;
    for (final x in b) {
      h = ((h ^ x) * 0x01000193) & 0xFFFFFFFF;
    }
    return h ^ (b.length << 1);
  }
}

class _PeerGate {
  bool wasTalking = false;
  bool silenced = false;
  DateTime? talkStart;
  DateTime? lastEnd;
  DateTime? lastFrame;
  DateTime? burstStart;
  final _hashes = HashMap<int, DateTime>();
  final _order = Queue<(int, DateTime)>();

  bool seenRecently(int h, DateTime now, Duration window) {
    while (_order.isNotEmpty && now.difference(_order.first.$2) > window) {
      final (oh, ot) = _order.removeFirst();
      if (_hashes[oh] == ot) _hashes.remove(oh);
    }
    final prev = _hashes[h];
    _hashes[h] = now;
    _order.addLast((h, now));
    while (_order.length > 4000) {
      final (oh, ot) = _order.removeFirst();
      if (_hashes[oh] == ot) _hashes.remove(oh);
    }
    return prev != null && now.difference(prev) <= window;
  }
}
