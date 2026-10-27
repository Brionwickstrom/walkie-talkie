import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// USB serial (COM port) for a Meshtastic radio on Windows (v1.9.6 desktop
/// app), straight on kernel32: no plugin and no native build step. The
/// port is opened and read in its own isolate (ReadFile blocks), which
/// also does the writes in between reads.
class WinSerialPort {
  WinSerialPort._(this.name, this._toIsolate, this._input, this._isolate);

  final String name;
  final SendPort _toIsolate;
  final Stream<List<int>> _input;
  final Isolate _isolate;
  bool _closed = false;

  /// Bytes from the radio; ends (or errors) when the port goes away.
  Stream<List<int>> get input => _input;

  Future<void> write(Uint8List bytes) async {
    if (_closed) throw StateError('port closed');
    _toIsolate.send(bytes);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _toIsolate.send(null);
    // The isolate exits after its current read (<= 50 ms).
    Future<void>.delayed(
      const Duration(seconds: 2),
      () => _isolate.kill(priority: Isolate.immediate),
    );
  }

  /// COM ports on this PC ("COM3", ...), from the DOS device list.
  static List<String> ports() {
    final out = <String>[];
    try {
      final k = DynamicLibrary.open('kernel32.dll');
      final query = k
          .lookupFunction<
            Uint32 Function(Pointer<Utf16>, Pointer<Uint16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Uint16>, int)
          >('QueryDosDeviceW');
      const size = 1 << 18;
      final buf = calloc<Uint16>(size);
      try {
        final n = query(nullptr, buf, size);
        if (n == 0) return out;
        final chars = buf.asTypedList(n);
        var start = 0;
        for (var i = 0; i < n; i++) {
          if (chars[i] != 0) continue;
          if (i > start) {
            final s = String.fromCharCodes(chars.sublist(start, i));
            if (RegExp(r'^COM\d+$').hasMatch(s)) out.add(s);
          }
          start = i + 1;
        }
      } finally {
        calloc.free(buf);
      }
    } catch (_) {}
    int num(String s) => int.tryParse(s.substring(3)) ?? 0;
    out.sort((a, b) => num(a).compareTo(num(b)));
    return out;
  }

  /// Open [port] ("COM3") at [baud] 8N1 (Meshtastic uses 115200).
  static Future<WinSerialPort> open(String port, {int baud = 115200}) async {
    final fromIsolate = ReceivePort();
    final input = StreamController<List<int>>();
    final ready = Completer<SendPort>();
    fromIsolate.listen((m) {
      if (m is SendPort) {
        if (!ready.isCompleted) ready.complete(m);
      } else if (m is Uint8List) {
        if (!input.isClosed) input.add(m);
      } else if (m is String) {
        if (!ready.isCompleted) {
          ready.completeError(StateError(m));
        } else if (!input.isClosed) {
          input.addError(StateError(m));
        }
        fromIsolate.close();
        if (!input.isClosed) input.close();
      } else if (m == null) {
        fromIsolate.close();
        if (!input.isClosed) input.close();
      }
    });
    final iso = await Isolate.spawn(_serialMain, [
      fromIsolate.sendPort,
      port,
      baud,
    ]);
    try {
      final to = await ready.future.timeout(const Duration(seconds: 5));
      return WinSerialPort._(port, to, input.stream, iso);
    } catch (_) {
      iso.kill(priority: Isolate.immediate);
      fromIsolate.close();
      rethrow;
    }
  }
}

typedef _CreateFileC = IntPtr Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  IntPtr,
);
typedef _CreateFileD = int Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  int,
);
typedef _RwC = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _RwD = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _HBufC = Int32 Function(IntPtr, Pointer<Uint8>);
typedef _HBufD = int Function(int, Pointer<Uint8>);
typedef _BuildDcbC = Int32 Function(Pointer<Utf16>, Pointer<Uint8>);
typedef _BuildDcbD = int Function(Pointer<Utf16>, Pointer<Uint8>);
typedef _CloseC = Int32 Function(IntPtr);
typedef _CloseD = int Function(int);
typedef _EscC = Int32 Function(IntPtr, Uint32);
typedef _EscD = int Function(int, int);
typedef _ErrC = Uint32 Function();
typedef _ErrD = int Function();

Future<void> _serialMain(List<Object> args) async {
  final out = args[0] as SendPort;
  final port = args[1] as String;
  final baud = args[2] as int;
  final k = DynamicLibrary.open('kernel32.dll');
  final createFile = k.lookupFunction<_CreateFileC, _CreateFileD>(
    'CreateFileW',
  );
  final readFile = k.lookupFunction<_RwC, _RwD>('ReadFile');
  final writeFile = k.lookupFunction<_RwC, _RwD>('WriteFile');
  final getState = k.lookupFunction<_HBufC, _HBufD>('GetCommState');
  final setState = k.lookupFunction<_HBufC, _HBufD>('SetCommState');
  final setTimeouts = k.lookupFunction<_HBufC, _HBufD>('SetCommTimeouts');
  final buildDcb = k.lookupFunction<_BuildDcbC, _BuildDcbD>('BuildCommDCBW');
  final escape = k.lookupFunction<_EscC, _EscD>('EscapeCommFunction');
  final closeHandle = k.lookupFunction<_CloseC, _CloseD>('CloseHandle');
  final lastError = k.lookupFunction<_ErrC, _ErrD>('GetLastError');

  const genericRead = 0x80000000;
  const genericWrite = 0x40000000;
  const openExisting = 3;
  const invalid = -1;

  final full = '${r'\\.\'}$port'.toNativeUtf16();
  final h = createFile(
    full,
    genericRead | genericWrite,
    0,
    nullptr,
    openExisting,
    0,
    0,
  );
  calloc.free(full);
  if (h == invalid || h == 0) {
    final e = lastError();
    out.send(
      e == 5
          ? '$port is in use by another program (close the Meshtastic app or other serial tools)'
          : e == 2
          ? '$port not found (radio unplugged?)'
          : 'could not open $port (error $e)',
    );
    return;
  }
  // DCB (28 bytes, first DWORD = its size): current settings, then
  // "baud=115200 parity=N data=8 stop=1 dtr=on rts=on" (like pyserial).
  final dcb = calloc<Uint8>(28);
  dcb.cast<Uint32>().value = 28;
  getState(h, dcb);
  final spec = 'baud=$baud parity=N data=8 stop=1 dtr=on rts=on'
      .toNativeUtf16();
  final okDcb = buildDcb(spec, dcb) != 0 && setState(h, dcb) != 0;
  calloc.free(spec);
  calloc.free(dcb);
  if (!okDcb) {
    closeHandle(h);
    out.send('could not set up $port (error ${lastError()})');
    return;
  }
  // COMMTIMEOUTS: return at once with what is there, or after 50 ms.
  final to = calloc<Uint32>(5);
  to[0] = 0xFFFFFFFF;
  to[1] = 0xFFFFFFFF;
  to[2] = 50;
  to[3] = 0;
  to[4] = 2000;
  setTimeouts(h, to.cast());
  calloc.free(to);
  escape(h, 5); // SETDTR

  final inbox = ReceivePort();
  final writes = <Uint8List>[];
  var stop = false;
  inbox.listen((m) {
    if (m == null) {
      stop = true;
    } else if (m is Uint8List) {
      writes.add(m);
    }
  });
  out.send(inbox.sendPort);

  const cap = 4096;
  final buf = calloc<Uint8>(cap);
  final n = calloc<Uint32>();
  String? failure;
  try {
    while (!stop) {
      while (writes.isNotEmpty) {
        final w = writes.removeAt(0);
        final p = calloc<Uint8>(w.length);
        p.asTypedList(w.length).setAll(0, w);
        final ok = writeFile(h, p, w.length, n, nullptr);
        calloc.free(p);
        if (ok == 0) {
          failure = 'write failed on $port (error ${lastError()})';
          break;
        }
      }
      if (failure != null) break;
      if (readFile(h, buf, cap, n, nullptr) == 0) {
        failure = 'radio on $port disconnected (error ${lastError()})';
        break;
      }
      final got = n.value;
      if (got > 0) {
        out.send(Uint8List.fromList(buf.asTypedList(got)));
      }
      // Let the write / stop messages in.
      await Future<void>.delayed(Duration.zero);
    }
  } finally {
    calloc.free(buf);
    calloc.free(n);
    closeHandle(h);
    inbox.close();
    out.send(failure);
  }
}
