/// What made the phone play (or refuse to play) audio, newest first, so a
/// screenshot of Details shows where a repeating sound comes from.
class PlaybackEvent {
  PlaybackEvent(this.at, this.kind, this.text);
  final DateTime at;

  /// 'live', 'live-blocked', 'voice-msg', 'voice-msg-quiet', 'history',
  /// 'private', 'private-blocked', 'stop', 'cleared'.
  final String kind;
  final String text;

  String get line {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)} '
        '$kind  $text';
  }
}

class PlaybackLog {
  PlaybackLog({this.max = 200, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final int max;
  final DateTime Function() _clock;
  final List<PlaybackEvent> events = [];

  void add(String kind, String text) {
    events.insert(0, PlaybackEvent(_clock(), kind, text));
    if (events.length > max) events.removeRange(max, events.length);
  }

  /// Last decision logged per live stream (sender), so each burst / change
  /// is logged once instead of 50 times a second.
  final Map<String, (String, DateTime)> _streams = {};

  /// Log a live frame decision only when it differs from the last one for
  /// [stream] or that stream was quiet for [gap].
  void stream(
    String stream,
    String kind,
    String text, {
    Duration gap = const Duration(milliseconds: 1500),
  }) {
    final now = _clock();
    final prev = _streams[stream];
    _streams[stream] = (kind + text, now);
    if (prev != null &&
        prev.$1 == kind + text &&
        now.difference(prev.$2) < gap) {
      return;
    }
    add(kind, text);
  }

  String get text => events.map((e) => e.line).join('\n');
}
