import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/codec.dart';
import 'package:walkie_talkie/audio/pcm_chunker.dart';
import 'package:walkie_talkie/audio/voice_pipeline.dart';

class FakeEncoder implements VoiceEncoder {
  int frames = 0;
  @override
  Uint8List encode(Int16List pcm) {
    frames++;
    expect(pcm.length, VoiceFormat.samplesPerFrame);
    return Uint8List.fromList([pcm.first & 0xFF]);
  }

  @override
  void dispose() {}
}

class FakeDecoder implements VoiceDecoder {
  final calls = <Uint8List?>[];
  @override
  Int16List decode(Uint8List? packet) {
    calls.add(packet);
    return Int16List(VoiceFormat.samplesPerFrame);
  }

  @override
  void dispose() {}
}

Uint8List pcmBytes(int samples, {int value = 0}) {
  final l = Int16List(samples)..fillRange(0, samples, value);
  return l.buffer.asUint8List();
}

void main() {
  test('chunker produces exact 20 ms frames from ragged input', () {
    final c = PcmChunker(samplesPerFrame: 320);
    expect(c.add(pcmBytes(100)), isEmpty);
    final out = c.add(pcmBytes(600, value: 7));
    expect(out, hasLength(2));
    expect(out.every((f) => f.length == 320), isTrue);
    expect(out[1].first, 7);
    expect(c.flush()!.length, 320); // 60 leftover samples padded
    expect(c.flush(), isNull);
  });

  test('pipeline encodes mic audio into one packet per frame', () {
    final enc = FakeEncoder();
    final p = VoicePipeline(
      encoderFactory: () => enc,
      decoderFactory: FakeDecoder.new,
    );
    expect(p.encodeMic(pcmBytes(960)), hasLength(3));
    expect(p.encodeMic(pcmBytes(100)), isEmpty);
    expect(p.endTransmission(), hasLength(1));
  });

  test('small gaps are concealed, late packets dropped, per peer', () {
    final decoders = <FakeDecoder>[];
    final p = VoicePipeline(
      encoderFactory: FakeEncoder.new,
      decoderFactory: () => FakeDecoder()..let(decoders.add),
    );
    final pkt = Uint8List.fromList([1]);
    expect(p.decode(1, 10, pkt), hasLength(1));
    expect(p.decode(1, 13, pkt), hasLength(3)); // 11,12 concealed + 13
    expect(decoders.single.calls.where((c) => c == null), hasLength(2));
    expect(p.decode(1, 12, pkt), isEmpty); // late
    expect(p.decode(1, 30, pkt), hasLength(1)); // big gap: skip, no PLC
    expect(p.decode(2, 0, pkt), hasLength(1)); // separate decoder
    expect(decoders, hasLength(2));
  });
}

extension<T> on T {
  void let(void Function(T) f) => f(this);
}
