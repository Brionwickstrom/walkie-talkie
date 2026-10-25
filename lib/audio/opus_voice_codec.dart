import 'dart:typed_data';

import 'package:opus_codec/opus_codec.dart' as opus_flutter;
import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:opus_codec_dart/wrappers/opus_defines.dart' as defines;

import 'codec.dart';

/// Loads the native libopus shipped by `opus_codec` (Android .so /
/// iOS xcframework) once per process.
class OpusRuntime {
  static Future<void>? _loading;

  static Future<void> ensureLoaded() =>
      _loading ??= opus_flutter.load().then(initOpus);
}

class OpusVoiceEncoder implements VoiceEncoder {
  OpusVoiceEncoder({int bitrate = VoiceFormat.bitrate})
      : _enc = BufferedOpusEncoder(
          sampleRate: VoiceFormat.sampleRate,
          channels: VoiceFormat.channels,
          application: Application.voip,
          maxInputBufferSizeBytes: 2 * VoiceFormat.samplesPerFrame * 6,
        ) {
    _enc.encoderCtl(request: defines.OPUS_SET_BITRATE_REQUEST, value: bitrate);
    // In-band FEC lets the receiver rebuild a lost packet from the next one.
    _enc.encoderCtl(request: defines.OPUS_SET_INBAND_FEC_REQUEST, value: 1);
    _enc.encoderCtl(
        request: defines.OPUS_SET_PACKET_LOSS_PERC_REQUEST, value: 10);
  }

  final BufferedOpusEncoder _enc;

  @override
  Uint8List encode(Int16List pcm) {
    final bytes = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
    _enc.inputBuffer.setAll(0, bytes);
    _enc.inputBufferIndex = bytes.length;
    return _enc.encode();
  }

  @override
  void dispose() => _enc.destroy();
}

class OpusVoiceDecoder implements VoiceDecoder {
  final _dec = SimpleOpusDecoder(
      sampleRate: VoiceFormat.sampleRate, channels: VoiceFormat.channels);

  @override
  Int16List decode(Uint8List? packet) => _dec.decode(input: packet);

  @override
  void dispose() => _dec.destroy();
}
