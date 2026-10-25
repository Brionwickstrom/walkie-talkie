import 'dart:typed_data';

/// Voice settings shared by both ends.
class VoiceFormat {
  static const int sampleRate = 16000; // wideband, plenty for voice
  static const int channels = 1;
  static const int frameMs = 20;
  static const int samplesPerFrame = sampleRate * frameMs ~/ 1000; // 320

  /// 12 kbps keeps a BLE link comfortable; LAN/internet could go higher.
  static const int bitrate = 12000;
}

/// Encoder/decoder abstraction so the pipeline can be unit-tested without
/// the native Opus library.
abstract class VoiceEncoder {
  Uint8List encode(Int16List pcm);
  void dispose();
}

abstract class VoiceDecoder {
  /// Decodes one packet. Pass null for a lost packet (packet loss
  /// concealment).
  Int16List decode(Uint8List? packet);
  void dispose();
}
