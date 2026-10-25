import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart' hide IosAudioCategory;

import 'agc.dart';
import 'codec.dart';
import 'opus_voice_codec.dart';
import 'playout_buffer.dart';
import 'voice_pipeline.dart';

/// Mic capture (record, raw PCM16 stream) and speaker playback
/// (flutter_pcm_sound), with Opus in between.
class AudioEngine {
  final _recorder = AudioRecorder();
  late final VoicePipeline _pipeline;
  StreamSubscription<Uint8List>? _micSub;
  bool _ready = false;
  bool _transmitting = false;
  final _playout = PlayoutBuffer(sampleRate: VoiceFormat.sampleRate);
  AudioSession? _session;
  bool _focused = false;
  Timer? _clipTimer;
  VoiceDecoder? _clipDecoder;
  Completer<void>? _clipDone;

  /// Mic read sizes to try, smallest (lowest latency) first. The record
  /// plugin's default is 2x the OS minimum, often 80-240 ms per chunk, which
  /// both delays audio and makes it bursty. Some phones reject buffers
  /// below their minimum, so fall back until one works (null = default).
  static const List<int?> _micBufferBytes = [
    VoiceFormat.samplesPerFrame * 2, // 20 ms
    VoiceFormat.samplesPerFrame * 4, // 40 ms
    null,
  ];
  int _micBufferIndex = 0;

  /// Per-person playback volume (linear 0..2), set from the person card.
  final Map<int, double> _volumes = {};
  void setVolumes(Map<int, double> v) {
    _volumes
      ..clear()
      ..addAll(v);
  }

  /// Frames dropped on playback to keep latency bounded (debug).
  int get playbackDropped => _playout.dropped;

  bool get isTransmitting => _transmitting;

  Future<void> init() async {
    if (_ready) return;
    await OpusRuntime.ensureLoaded();
    _pipeline = VoicePipeline(
      encoderFactory: OpusVoiceEncoder.new,
      decoderFactory: OpusVoiceDecoder.new,
      micAgc: true,
      playbackAgc: true,
      volumeOf: (id) => _volumes[id] ?? 1.0,
    );
    final session = await AudioSession.instance;
    _session = session;
    await session.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
      ),
    );
    // The plugin logs every feed() call by default (50 per second).
    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(
      sampleRate: VoiceFormat.sampleRate,
      channelCount: VoiceFormat.channels,
      iosAudioCategory: IosAudioCategory.playAndRecord,
      iosAllowBackgroundAudio: true,
    );
    await FlutterPcmSound.setFeedThreshold(VoiceFormat.samplesPerFrame * 4);
    _ready = true;
  }

  Future<bool> hasMicPermission() => _recorder.hasPermission();

  /// Start capturing; [onPacket] receives one Opus packet per 20 ms.
  Future<void> startTransmit(void Function(Uint8List opus) onPacket) async {
    if (_transmitting) return;
    _transmitting = true;
    Stream<Uint8List>? stream;
    Object? lastError;
    while (stream == null && _micBufferIndex < _micBufferBytes.length) {
      try {
        stream = await _recorder.startStream(
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: VoiceFormat.sampleRate,
            numChannels: VoiceFormat.channels,
            echoCancel: true,
            noiseSuppress: true,
            autoGain: true,
            streamBufferSize: _micBufferBytes[_micBufferIndex],
            // Do not start a Bluetooth SCO (phone-call) link for the mic:
            // it re-routes and quietens playback on phones with a headset
            // / car kit paired. Mode stays NORMAL, speaker stays media.
            androidConfig: const AndroidRecordConfig(manageBluetooth: false),
          ),
        );
      } catch (e) {
        lastError = e;
        try {
          await _recorder.stop();
        } catch (_) {}
        _micBufferIndex++;
      }
    }
    if (stream == null) {
      _transmitting = false;
      _micBufferIndex = _micBufferBytes.length - 1;
      throw lastError ?? StateError('mic failed');
    }
    _micSub = stream.listen((bytes) {
      for (final p in _pipeline.encodeMic(bytes)) {
        onPacket(p);
      }
    });
  }

  Future<void> stopTransmit(void Function(Uint8List opus) onPacket) async {
    if (!_transmitting) return;
    _transmitting = false;
    await _recorder.stop();
    await _micSub?.cancel();
    _micSub = null;
    for (final p in _pipeline.endTransmission()) {
      onPacket(p);
    }
  }

  void play(int peerId, int seq, Uint8List opus) {
    if (!_ready) return;
    for (final pcm in _pipeline.decode(peerId, seq, opus)) {
      final pre = _playout.admit(pcm.length);
      if (pre == null) continue; // too far behind: drop to catch up
      if (pre > 0) {
        FlutterPcmSound.feed(PcmArrayInt16.zeros(count: pre));
      }
      FlutterPcmSound.feed(
        PcmArrayInt16(
          bytes: pcm.buffer.asByteData(pcm.offsetInBytes, pcm.lengthInBytes),
        ),
      );
    }
  }

  /// Ask Android for audio focus while someone talks / a clip plays (so
  /// it plays, ducking music, even with the app in the background).
  Future<void> setFocus(bool on) async {
    if (on == _focused) return;
    _focused = on;
    try {
      await _session?.setActive(on);
    } catch (_) {}
  }

  bool get playingClip => _clipDone != null;

  /// Play a recorded voice message (list of Opus packets). Completes when
  /// it finished or [stopClip] was called.
  Future<void> playClip(List<Uint8List> packets, {int? fromPeer}) async {
    if (!_ready) return;
    stopClip();
    await setFocus(true);
    final dec = OpusVoiceDecoder();
    _clipDecoder = dec;
    final agc = Agc();
    final vol = fromPeer == null ? 1.0 : (_volumes[fromPeer] ?? 1.0);
    final done = Completer<void>();
    _clipDone = done;
    var i = 0;
    final start = DateTime.now();
    final totalMs = packets.length * VoiceFormat.frameMs;
    void pump() {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      // Stay at most ~200 ms ahead of real time so stopClip is quick.
      while (i < packets.length && i * VoiceFormat.frameMs < elapsed + 200) {
        try {
          final pcm = agc.process(dec.decode(packets[i]), volume: vol);
          FlutterPcmSound.feed(
            PcmArrayInt16(
              bytes: pcm.buffer.asByteData(
                pcm.offsetInBytes,
                pcm.lengthInBytes,
              ),
            ),
          );
        } catch (_) {}
        i++;
      }
      if (i >= packets.length && elapsed > totalMs + 250) stopClip();
    }

    pump();
    _clipTimer = Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => pump(),
    );
    return done.future;
  }

  void stopClip() {
    _clipTimer?.cancel();
    _clipTimer = null;
    _clipDecoder?.dispose();
    _clipDecoder = null;
    final d = _clipDone;
    _clipDone = null;
    if (d != null && !d.isCompleted) d.complete();
  }

  void peerStopped(int peerId) {
    if (_ready) _pipeline.resetPeer(peerId);
  }

  Future<void> dispose() async {
    stopClip();
    await _micSub?.cancel();
    await _recorder.dispose();
    if (_ready) {
      _pipeline.dispose();
      await FlutterPcmSound.release();
    }
  }
}
