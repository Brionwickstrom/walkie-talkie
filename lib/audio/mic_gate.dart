import 'dart:async';
import 'dart:typed_data';

/// Starts / stops the microphone strictly one after the other.
///
/// v1.5.0 bug: a quick tap (talk button, "Hold: voice msg", headset key)
/// called stop while start was still waiting for the mic to open. Stop saw
/// nothing to stop, then start finished and the mic stayed on for good,
/// sending everything it heard (including the speaker playing other
/// people's talk and voice messages) until the phone was restarted. Two
/// phones in that state echo each other's audio back and forth endlessly.
///
/// Here every start/stop waits for the previous one, and a stopped
/// session's packets are dropped even if one arrives late.
class MicGate {
  MicGate({required this.open, required this.close});

  /// Opens the mic stream (may throw).
  final Future<Stream<Uint8List>> Function() open;
  final Future<void> Function() close;

  Future<void> _chain = Future.value();
  int _gen = 0;
  bool _active = false;
  StreamSubscription<Uint8List>? _sub;

  /// Mic is (or is about to be) capturing.
  bool get active => _active;

  Future<T> _serial<T>(Future<T> Function() op) {
    final r = _chain.then((_) => op());
    _chain = r.then((_) {}, onError: (_) {});
    return r;
  }

  Future<void> start(void Function(Uint8List bytes) onData) =>
      _serial(() async {
        if (_active) return;
        final gen = ++_gen;
        _active = true;
        final Stream<Uint8List> s;
        try {
          s = await open();
        } catch (_) {
          _active = false;
          rethrow;
        }
        _sub = s.listen((b) {
          if (gen == _gen && _active) onData(b);
        });
      });

  /// Returns true if the mic was on.
  Future<bool> stop() => _serial(() async {
    if (!_active) return false;
    _active = false;
    _gen++;
    await _sub?.cancel();
    _sub = null;
    try {
      await close();
    } catch (_) {}
    return true;
  });
}
