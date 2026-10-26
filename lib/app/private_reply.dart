/// Where the big talk button on the home screen goes.
///
/// v1.5.4: private talk from a friend plays on the home screen. The friend
/// then answered with the big HOLD TO TALK button, which always went to the
/// whole channel ("only the person can hear me, but everyone hears them").
/// Now, for [window] after private audio / a voice message from a friend,
/// the big button (and talk keys) reply privately to that friend instead,
/// until the user taps "Talk to channel instead".
class PrivateReply {
  PrivateReply({
    DateTime Function()? clock,
    this.window = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration window;
  int? _id;
  DateTime? _at;

  /// Private audio / a voice message from friend [id] just arrived.
  void heard(int id) {
    _id = id;
    _at = _clock();
  }

  /// Friend last heard privately (even after the window ran out).
  int? get lastId => _id;

  /// "Talk to channel instead".
  void dismiss() {
    _id = null;
    _at = null;
  }

  /// The friend the big button replies to right now, or null (channel).
  int? get target {
    final at = _at;
    if (_id == null || at == null) return null;
    if (_clock().difference(at) > window) return null;
    return _id;
  }

  /// Seconds left in reply mode (for the label), 0 when off.
  int get secondsLeft {
    final at = _at;
    if (target == null || at == null) return 0;
    return (window - _clock().difference(at)).inSeconds.clamp(0, 9999);
  }
}

/// Routes the big talk button: privately to [PrivateReply.target] while in
/// reply mode, else to the channel. Never falls back to the channel when
/// private talk is refused (not connected, friend's app too old).
class MainTalkRouter {
  MainTalkRouter({
    required this.reply,
    required this.talkPrivate,
    required this.talkChannel,
    required this.privateTalkTo,
  });

  final PrivateReply reply;

  /// Start / stop private talk; returns false if it was refused.
  final Future<bool> Function(int friend, bool down) talkPrivate;
  final Future<void> Function(bool down) talkChannel;

  /// Friend currently being talked to privately (null = none).
  final int? Function() privateTalkTo;

  /// The last press went to a friend (even if refused).
  bool _pressPrivate = false;

  Future<void> talk(bool down) async {
    if (!down) {
      final p = privateTalkTo();
      if (p != null) {
        await talkPrivate(p, false);
        // Keep replying to them for another window after our reply.
        if (p == reply.lastId) reply.heard(p);
      } else if (!_pressPrivate) {
        await talkChannel(false);
      }
      _pressPrivate = false;
      return;
    }
    final t = reply.target;
    if (t != null) {
      _pressPrivate = true;
      await talkPrivate(t, true); // refused = nothing sent, never channel
      return;
    }
    _pressPrivate = false;
    await talkChannel(true);
  }
}
