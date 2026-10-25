import 'dart:async';
import 'dart:typed_data';

import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';

class SentFrame {
  SentFrame(this.frame, this.peerIds);
  final Frame frame;
  final Set<int>? peerIds;
}

class FakeTransport extends Transport {
  FakeTransport(this.kind);

  @override
  final TransportKind kind;
  TransportStatus _status = TransportStatus.stopped;
  final _frames = StreamController<InboundFrame>.broadcast(sync: true);
  final _status$ = StreamController<TransportStatus>.broadcast(sync: true);
  final sent = <SentFrame>[];

  @override
  TransportStatus get status => _status;
  set status(TransportStatus s) {
    _status = s;
    _status$.add(s);
  }

  @override
  Stream<InboundFrame> get frames => _frames.stream;
  @override
  Stream<TransportStatus> get statusChanges => _status$.stream;

  @override
  Future<void> start({required int localNodeId, required int channel}) async =>
      status = TransportStatus.running;

  @override
  Future<void> stop() async => status = TransportStatus.stopped;

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async =>
      sent.add(SentFrame(Frame.tryDecode(frame)!, peerIds));

  void deliver(Frame f) => _frames.add(InboundFrame(f, kind));
}
