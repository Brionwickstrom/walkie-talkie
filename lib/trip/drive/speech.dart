import 'package:flutter_tts/flutter_tts.dart';

/// Spoken directions (v1.9.2). The phone's own text-to-speech engine
/// (Android: Google / Samsung TTS with their built-in offline voices), so
/// it works with no signal.
abstract class Speaker {
  Future<void> say(String text);
  Future<void> stop();
}

/// Says nothing (tests, or when speech is not available); keeps the lines.
class SilentSpeaker implements Speaker {
  final List<String> said = [];
  @override
  Future<void> say(String text) async => said.add(text);
  @override
  Future<void> stop() async {}
}

class TtsSpeaker implements Speaker {
  FlutterTts? _tts;
  bool _broken = false;

  Future<FlutterTts?> _get() async {
    if (_broken) return null;
    final t = _tts;
    if (t != null) return t;
    try {
      final n = FlutterTts();
      await n.setLanguage('en-US');
      await n.setSpeechRate(0.5);
      await n.setVolume(1.0);
      // Duck other audio (music) while speaking; queue lines.
      await n.setQueueMode(1);
      return _tts = n;
    } catch (_) {
      _broken = true;
      return null;
    }
  }

  @override
  Future<void> say(String text) async {
    try {
      await (await _get())?.speak(text);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}
