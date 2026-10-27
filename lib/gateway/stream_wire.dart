import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../lora/meshtastic_session.dart';

/// Meshtastic "stream API" framing used over USB serial and TCP (port
/// 4403): `0x94 0xC3 len_hi len_lo` + a ToRadio / FromRadio protobuf.
/// Anything between frames (the radio's debug log text on serial) is
/// skipped.
class StreamFramer {
  static const int start1 = 0x94;
  static const int start2 = 0xC3;
  static const int maxLen = 512;

  final _buf = <int>[];

  /// Frame [payload] for the wire.
  static Uint8List frame(Uint8List payload) {
    final out = Uint8List(4 + payload.length);
    out[0] = start1;
    out[1] = start2;
    out[2] = (payload.length >> 8) & 0xFF;
    out[3] = payload.length & 0xFF;
    out.setRange(4, out.length, payload);
    return out;
  }

  /// Bytes the client sends first so a sleeping serial console switches to
  /// protobuf mode (as the official Python client does).
  static Uint8List wake() => Uint8List.fromList(List.filled(32, start2));

  /// Feed received bytes; returns complete payloads.
  List<Uint8List> add(List<int> bytes) {
    _buf.addAll(bytes);
    final out = <Uint8List>[];
    while (true) {
      // Find the start marker.
      var i = 0;
      while (i < _buf.length) {
        if (_buf[i] == start1 &&
            (i + 1 >= _buf.length || _buf[i + 1] == start2)) {
          break;
        }
        i++;
      }
      if (i > 0) _buf.removeRange(0, i);
      if (_buf.length < 4) return out;
      final len = (_buf[2] << 8) | _buf[3];
      if (len > maxLen) {
        // Corrupt header: skip this marker and look again.
        _buf.removeAt(0);
        continue;
      }
      if (_buf.length < 4 + len) return out;
      out.add(Uint8List.fromList(_buf.sublist(4, 4 + len)));
      _buf.removeRange(0, 4 + len);
    }
  }
}

/// [MeshtasticWire] over a byte stream (serial port or TCP socket): every
/// framed FromRadio is queued and handed out by [read], with a
/// notification per frame, so [MeshtasticSession] works unchanged.
class StreamWire implements MeshtasticWire {
  StreamWire(Stream<List<int>> input, this._write) {
    _sub = input.listen(
      (b) {
        for (final p in _framer.add(b)) {
          _queue.add(p);
          if (!_notify.isClosed) _notify.add(null);
        }
      },
      onError: (Object e) => _close(e),
      onDone: () => _close('closed'),
      cancelOnError: true,
    );
  }

  final Future<void> Function(Uint8List bytes) _write;
  final _framer = StreamFramer();
  final _queue = Queue<Uint8List>();
  final _notify = StreamController<void>.broadcast();
  final _done = Completer<Object>();
  late final StreamSubscription<List<int>> _sub;

  /// Completes (with the reason) when the stream ends or fails.
  Future<Object> get done => _done.future;
  bool get isClosed => _done.isCompleted;

  void _close(Object why) {
    if (!_done.isCompleted) _done.complete(why);
    if (!_notify.isClosed) _notify.close();
  }

  @override
  Future<void> write(Uint8List toRadio) async {
    if (isClosed) throw StateError('radio link closed');
    await _write(StreamFramer.frame(toRadio));
  }

  @override
  Future<Uint8List> read() async =>
      _queue.isEmpty ? Uint8List(0) : _queue.removeFirst();

  @override
  Stream<void> get notifications => _notify.stream;

  Future<void> close() async {
    await _sub.cancel();
    _close('closed');
  }
}
