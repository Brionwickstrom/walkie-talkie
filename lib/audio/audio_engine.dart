import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart' hide IosAudioCategory;

import 'codec.dart';
import 'opus_voice_codec.dart';
import 'voice_pipeline.dart';

/// Mic capture (record, raw PCM16 stream) and speaker playback
/// (flutter_pcm_sound), with Opus in between.
class AudioEngine {
  final _recorder = AudioRecorder();
  late final VoicePipeline _pipeline;
  StreamSubscription<Uint8List>? _micSub;
  bool _ready = false;
  bool _transmitting = false;

  bool get isTransmitting => _transmitting;

  Future<void> init() async {
    if (_ready) return;
    await OpusRuntime.ensureLoaded();
    _pipeline = VoicePipeline(
      encoderFactory: OpusVoiceEncoder.new,
      decoderFactory: OpusVoiceDecoder.new,
    );
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
              AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    ));
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
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: VoiceFormat.sampleRate,
      numChannels: VoiceFormat.channels,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
    ));
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
      FlutterPcmSound.feed(PcmArrayInt16(
          bytes: pcm.buffer.asByteData(pcm.offsetInBytes, pcm.lengthInBytes)));
    }
  }

  void peerStopped(int peerId) {
    if (_ready) _pipeline.resetPeer(peerId);
  }

  Future<void> dispose() async {
    await _micSub?.cancel();
    await _recorder.dispose();
    if (_ready) {
      _pipeline.dispose();
      await FlutterPcmSound.release();
    }
  }
}
