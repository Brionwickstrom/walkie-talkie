import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lora/radio_clip.dart';

/// Codec 2 (LGPL-2.1, built from android/app/src/main/cpp) through
/// dart:ffi. Used only for short voice clips over LoRa radios, where every
/// byte costs seconds of airtime: 700C is 700 bit/s (28 bits per 40 ms).
///
/// Codec 2 runs at 8 kHz mono; [RadioClipCodec] converts from/to the app's
/// 16 kHz audio.
class Codec2Lib {
  Codec2Lib._(DynamicLibrary lib)
    : _create = lib
          .lookupFunction<
            Pointer<Void> Function(Int32),
            Pointer<Void> Function(int)
          >('codec2_create'),
      _destroy = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('codec2_destroy'),
      _encode = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int16>),
            void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int16>)
          >('codec2_encode'),
      _decode = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Pointer<Int16>, Pointer<Uint8>),
            void Function(Pointer<Void>, Pointer<Int16>, Pointer<Uint8>)
          >('codec2_decode'),
      _samples = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('codec2_samples_per_frame'),
      _bits = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('codec2_bits_per_frame');

  final Pointer<Void> Function(int) _create;
  final void Function(Pointer<Void>) _destroy;
  final void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int16>) _encode;
  final void Function(Pointer<Void>, Pointer<Int16>, Pointer<Uint8>) _decode;
  final int Function(Pointer<Void>) _samples;
  final int Function(Pointer<Void>) _bits;

  static Codec2Lib? _instance;
  static bool _tried = false;

  /// The bundled library, or null when it is missing (iPhone build, tests
  /// without `tool/build_codec2_host.sh`). [path] overrides the lookup.
  static Codec2Lib? load({String? path}) {
    if (path != null) {
      try {
        return Codec2Lib._(DynamicLibrary.open(path));
      } catch (_) {
        return null;
      }
    }
    if (_tried) return _instance;
    _tried = true;
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        _instance = Codec2Lib._(DynamicLibrary.open('libcodec2.so'));
      }
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }
}

/// Codec 2 modes (codec2.h).
class Codec2Mode {
  static const m3200 = 0;
  static const m2400 = 1;
  static const m1600 = 2;
  static const m1400 = 3;
  static const m1300 = 4;
  static const m1200 = 5;
  static const m700c = 8;
}

/// One Codec 2 encoder/decoder state.
class Codec2 {
  Codec2(this._lib, this.mode) : _st = _lib._create(mode) {
    if (_st == nullptr) throw StateError('codec2_create($mode) failed');
    samplesPerFrame = _lib._samples(_st);
    bitsPerFrame = _lib._bits(_st);
    _pcm = calloc<Int16>(samplesPerFrame);
    _buf = calloc<Uint8>(bytesPerFrame);
  }

  final Codec2Lib _lib;
  final int mode;
  final Pointer<Void> _st;
  late final int samplesPerFrame;
  late final int bitsPerFrame;
  int get bytesPerFrame => (bitsPerFrame + 7) ~/ 8;
  late final Pointer<Int16> _pcm;
  late final Pointer<Uint8> _buf;
  bool _disposed = false;

  /// [pcm] = [samplesPerFrame] samples at 8 kHz.
  Uint8List encode(Int16List pcm) {
    _pcm.asTypedList(samplesPerFrame).setAll(0, pcm);
    _lib._encode(_st, _buf, _pcm);
    return Uint8List.fromList(_buf.asTypedList(bytesPerFrame));
  }

  Int16List decode(Uint8List bits) {
    _buf.asTypedList(bytesPerFrame).setAll(0, bits.take(bytesPerFrame));
    _lib._decode(_st, _pcm, _buf);
    return Int16List.fromList(_pcm.asTypedList(samplesPerFrame));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lib._destroy(_st);
    calloc.free(_pcm);
    calloc.free(_buf);
  }
}

/// [Codec2] as a radio clip [FrameCodec].
class Codec2FrameCodec implements FrameCodec {
  Codec2FrameCodec(Codec2Lib lib, {int mode = Codec2Mode.m700c})
    : _c = Codec2(lib, mode);
  final Codec2 _c;
  @override
  int get mode => _c.mode;
  @override
  int get samplesPerFrame => _c.samplesPerFrame;
  @override
  int get bitsPerFrame => _c.bitsPerFrame;
  @override
  Uint8List encode(Int16List pcm8k) => _c.encode(pcm8k);
  @override
  Int16List decode(Uint8List bits) => _c.decode(bits);
  @override
  void dispose() => _c.dispose();
}
