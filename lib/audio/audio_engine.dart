import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart' hide IosAudioCategory;

import 'agc.dart';
import 'clip_player.dart';
import 'codec.dart';
import 'mic_gate.dart';
import 'opus_voice_codec.dart';
import 'playout_buffer.dart';
import 'time_stretch.dart';
import 'voice_pipeline.dart';

/// Mic capture (record, raw PCM16 stream) and speaker playback
/// (flutter_pcm_sound), with Opus in between.
class AudioEngine {
  final _recorder = AudioRecorder();
  late final VoicePipeline _pipeline;
  late final MicGate _mic = MicGate(
    open: _openMic,
    close: () => _recorder.stop(),
  );
  bool _ready = false;
  final _playout = PlayoutBuffer(sampleRate: VoiceFormat.sampleRate);
  AudioSession? _session;
  bool _focused = false;
  ClipPump? _pump;
  VoiceDecoder? _clipDecoder;
  Completer<void>? _clipDone;

  /// False while the native player is being reset (feeds would fail).
  bool _speakerOk = false;

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

  bool get isTransmitting => _mic.active;

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
    await _setupSpeaker();
    _ready = true;
  }

  Future<void> _setupSpeaker() async {
    await FlutterPcmSound.setup(
      sampleRate: VoiceFormat.sampleRate,
      channelCount: VoiceFormat.channels,
      iosAudioCategory: IosAudioCategory.playAndRecord,
      iosAllowBackgroundAudio: true,
    );
    await FlutterPcmSound.setFeedThreshold(VoiceFormat.samplesPerFrame * 4);
    _speakerOk = true;
  }

  void _feed(PcmArrayInt16 pcm) {
    if (!_speakerOk) return;
    FlutterPcmSound.feed(pcm).catchError((_) {});
  }

  Future<void>? _flushing;

  /// Drop everything already queued in the native player (it has no flush
  /// call: release + setup empties its queue and stops the AudioTrack).
  Future<void> flushSpeaker() {
    if (!_ready) return Future.value();
    return _flushing ??= () async {
      _speakerOk = false;
      _playout.reset();
      try {
        await FlutterPcmSound.release();
      } catch (_) {}
      try {
        await _setupSpeaker();
      } catch (_) {}
      _flushing = null;
    }();
  }

  Future<bool> hasMicPermission() => _recorder.hasPermission();

  /// Start capturing; [onPacket] receives one Opus packet per 20 ms.
  /// Start / stop are serialized (see [MicGate]): a stop that comes while
  /// the mic is still opening really stops it.
  Future<void> startTransmit(void Function(Uint8List opus) onPacket) =>
      _mic.start((bytes) {
        for (final p in _pipeline.encodeMic(bytes)) {
          onPacket(p);
        }
      });

  Future<Stream<Uint8List>> _openMic() async {
    Object? lastError;
    while (_micBufferIndex < _micBufferBytes.length) {
      try {
        return await _recorder.startStream(
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
    _micBufferIndex = _micBufferBytes.length - 1;
    throw lastError ?? StateError('mic failed');
  }

  Future<void> stopTransmit(void Function(Uint8List opus) onPacket) async {
    if (!await _mic.stop()) return;
    for (final p in _pipeline.endTransmission()) {
      onPacket(p);
    }
  }

  /// Turn the mic off no matter who started it (safety net).
  Future<void> forceStopTransmit() async {
    if (await _mic.stop()) _pipeline.endTransmission();
  }

  void play(int peerId, int seq, Uint8List opus) {
    if (!_ready) return;
    for (final pcm in _pipeline.decode(peerId, seq, opus)) {
      final pre = _playout.admit(pcm.length);
      if (pre == null) continue; // too far behind: drop to catch up
      if (pre > 0) _feed(PcmArrayInt16.zeros(count: pre));
      _feed(exactPcm(pcm));
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

  /// Play a recorded clip (list of 20 ms Opus packets): a voice message or
  /// a replayed transmission. Starts at [startMs] of the clip, at [speed]
  /// (1, 1.5, 2: pitch kept, see [timeStretch]); [onPosition] gets the clip
  /// time in ms as it plays. Completes when it finished or [stopClip] was
  /// called; returns true if it played to the end.
  Future<bool> playClip(
    List<Uint8List> packets, {
    int? fromPeer,
    double speed = 1.0,
    int startMs = 0,
    void Function(int ms)? onPosition,
  }) async {
    if (!_ready) return false;
    stopClip();
    final done = Completer<void>();
    _clipDone = done;
    await setFocus(true);
    final dec = OpusVoiceDecoder();
    _clipDecoder = dec;
    final agc = Agc();
    final vol = fromPeer == null ? 1.0 : (_volumes[fromPeer] ?? 1.0);
    final first = (startMs ~/ VoiceFormat.frameMs).clamp(0, packets.length);
    final pcm = BytesBuilder(copy: false);
    for (var i = first; i < packets.length; i++) {
      try {
        final f = agc.process(dec.decode(packets[i]), volume: vol);
        pcm.add(f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes));
      } catch (_) {}
    }
    final raw = pcm.takeBytes();
    var samples = Int16List.view(
      Uint8List.fromList(raw).buffer,
      0,
      raw.length ~/ 2,
    );
    if ((speed - 1).abs() > 0.01) {
      final input = samples;
      samples = await Isolate.run(() => timeStretch(input, speed));
    }
    final flushing = _flushing;
    if (flushing != null) await flushing; // previous clip's leftovers gone
    if (!identical(_clipDone, done)) return false; // stopped meanwhile
    final pump = ClipPump(
      samples: samples,
      feed: _feed,
      sampleRate: VoiceFormat.sampleRate,
      frameSamples: VoiceFormat.samplesPerFrame,
      speed: speed,
      startMs: startMs,
      onPosition: onPosition,
    );
    _pump = pump;
    final finished = await pump.run();
    if (identical(_pump, pump)) {
      _pump = null;
      // Nothing of this clip may keep playing after it ended / was stopped.
      await flushSpeaker();
    }
    final d = _clipDone;
    if (identical(d, done)) {
      _clipDone = null;
      _clipDecoder?.dispose();
      _clipDecoder = null;
    }
    if (!done.isCompleted) done.complete();
    return finished;
  }

  /// Stop the clip now, including audio already handed to the player.
  void stopClip() {
    final hadClip = _clipDone != null || _pump != null;
    _pump?.stop();
    _pump = null;
    _clipDecoder?.dispose();
    _clipDecoder = null;
    final d = _clipDone;
    _clipDone = null;
    if (d != null && !d.isCompleted) d.complete();
    if (hadClip) unawaited(flushSpeaker());
  }

  void peerStopped(int peerId) {
    if (_ready) _pipeline.resetPeer(peerId);
  }

  Future<void> dispose() async {
    stopClip();
    await _mic.stop();
    await _recorder.dispose();
    if (_ready) {
      _pipeline.dispose();
      await FlutterPcmSound.release();
    }
  }
}
