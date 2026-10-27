import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// Where decoded voice goes: Android / iOS use flutter_pcm_sound, Windows
/// (v1.9.6 desktop app) uses the system waveOut API directly, since
/// flutter_pcm_sound has no Windows version.
abstract class PcmSpeaker {
  Future<void> setup({required int sampleRate, required int channels});

  /// Queue [pcm] (16-bit samples) behind what is already playing.
  void feed(PcmArrayInt16 pcm);

  /// Stop now and drop everything queued.
  Future<void> release();

  static PcmSpeaker platform() =>
      Platform.isWindows ? WaveOutSpeaker() : FlutterPcmSpeaker();
}

class FlutterPcmSpeaker implements PcmSpeaker {
  bool _quiet = false;

  @override
  Future<void> setup({required int sampleRate, required int channels}) async {
    if (!_quiet) {
      // The plugin logs every feed() call by default (50 per second).
      await FlutterPcmSound.setLogLevel(LogLevel.error);
      _quiet = true;
    }
    await FlutterPcmSound.setup(
      sampleRate: sampleRate,
      channelCount: channels,
      iosAudioCategory: IosAudioCategory.playAndRecord,
      iosAllowBackgroundAudio: true,
    );
    await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 50 * 4);
  }

  @override
  void feed(PcmArrayInt16 pcm) {
    FlutterPcmSound.feed(pcm).catchError((_) {});
  }

  @override
  Future<void> release() => FlutterPcmSound.release();
}

// ---------------------------------------------------------------- Windows

@Packed(1)
final class _WaveFormatEx extends Struct {
  @Uint16()
  external int wFormatTag;
  @Uint16()
  external int nChannels;
  @Uint32()
  external int nSamplesPerSec;
  @Uint32()
  external int nAvgBytesPerSec;
  @Uint16()
  external int nBlockAlign;
  @Uint16()
  external int wBitsPerSample;
  @Uint16()
  external int cbSize;
}

final class _WaveHdr extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @UintPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwLoops;
  external Pointer<_WaveHdr> lpNext;
  @UintPtr()
  external int reserved;
}

typedef _OpenC = Uint32 Function(
  Pointer<IntPtr>,
  Uint32,
  Pointer<_WaveFormatEx>,
  UintPtr,
  UintPtr,
  Uint32,
);
typedef _OpenD = int Function(
  Pointer<IntPtr>,
  int,
  Pointer<_WaveFormatEx>,
  int,
  int,
  int,
);
typedef _HdrC = Uint32 Function(IntPtr, Pointer<_WaveHdr>, Uint32);
typedef _HdrD = int Function(int, Pointer<_WaveHdr>, int);
typedef _HC = Uint32 Function(IntPtr);
typedef _HD = int Function(int);

class _WinMm {
  _WinMm(DynamicLibrary l)
    : open = l.lookupFunction<_OpenC, _OpenD>('waveOutOpen'),
      prepare = l.lookupFunction<_HdrC, _HdrD>('waveOutPrepareHeader'),
      unprepare = l.lookupFunction<_HdrC, _HdrD>('waveOutUnprepareHeader'),
      write = l.lookupFunction<_HdrC, _HdrD>('waveOutWrite'),
      reset = l.lookupFunction<_HC, _HD>('waveOutReset'),
      close = l.lookupFunction<_HC, _HD>('waveOutClose');

  final _OpenD open;
  final _HdrD prepare;
  final _HdrD unprepare;
  final _HdrD write;
  final _HD reset;
  final _HD close;

  static _WinMm? _i;
  static _WinMm get instance => _i ??= _WinMm(DynamicLibrary.open('winmm.dll'));
}

/// Streaming 16-bit PCM out of the default Windows playback device with
/// waveOut: every feed becomes one queued buffer, finished buffers are
/// freed on the next feed / release.
class WaveOutSpeaker implements PcmSpeaker {
  static const int _waveMapper = 0xFFFFFFFF;
  static const int _whdrDone = 0x00000001;

  int _handle = 0;
  final List<Pointer<_WaveHdr>> _queued = [];

  bool get isOpen => _handle != 0;

  @override
  Future<void> setup({required int sampleRate, required int channels}) async {
    if (_handle != 0) await release();
    final mm = _WinMm.instance;
    final fmt = calloc<_WaveFormatEx>();
    final h = calloc<IntPtr>();
    try {
      fmt.ref
        ..wFormatTag =
            1 // WAVE_FORMAT_PCM
        ..nChannels = channels
        ..nSamplesPerSec = sampleRate
        ..wBitsPerSample = 16
        ..nBlockAlign = channels * 2
        ..nAvgBytesPerSec = sampleRate * channels * 2
        ..cbSize = 0;
      final r = mm.open(h, _waveMapper, fmt, 0, 0, 0);
      if (r != 0) throw StateError('waveOutOpen failed ($r)');
      _handle = h.value;
    } finally {
      calloc.free(fmt);
      calloc.free(h);
    }
  }

  void _reclaim({bool all = false}) {
    final mm = _WinMm.instance;
    _queued.removeWhere((p) {
      if (!all && (p.ref.dwFlags & _whdrDone) == 0) return false;
      if (_handle != 0) mm.unprepare(_handle, p, sizeOf<_WaveHdr>());
      calloc.free(p.ref.lpData);
      calloc.free(p);
      return true;
    });
  }

  @override
  void feed(PcmArrayInt16 pcm) {
    if (_handle == 0) return;
    _reclaim();
    final bytes = pcm.bytes.buffer.asUint8List(
      pcm.bytes.offsetInBytes,
      pcm.bytes.lengthInBytes,
    );
    if (bytes.isEmpty) return;
    final mm = _WinMm.instance;
    final data = calloc<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final hdr = calloc<_WaveHdr>();
    hdr.ref
      ..lpData = data
      ..dwBufferLength = bytes.length;
    if (mm.prepare(_handle, hdr, sizeOf<_WaveHdr>()) != 0) {
      calloc.free(data);
      calloc.free(hdr);
      return;
    }
    if (mm.write(_handle, hdr, sizeOf<_WaveHdr>()) != 0) {
      mm.unprepare(_handle, hdr, sizeOf<_WaveHdr>());
      calloc.free(data);
      calloc.free(hdr);
      return;
    }
    _queued.add(hdr);
  }

  @override
  Future<void> release() async {
    if (_handle == 0) return;
    final mm = _WinMm.instance;
    mm.reset(_handle); // marks every queued buffer done
    _reclaim(all: true);
    mm.close(_handle);
    _handle = 0;
  }
}
