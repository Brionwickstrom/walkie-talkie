import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';

void main() {
  test('audio frame round-trips through encode/decode', () {
    final f = Frame(
      type: FrameType.audio,
      senderId: 0xDEADBEEF,
      channel: 7,
      seq: 65535,
      payload: Uint8List.fromList(List.generate(30, (i) => i)),
    );
    final bytes = f.encode();
    expect(bytes.length, Frame.headerSize + 30);
    final d = Frame.tryDecode(bytes)!;
    expect(d.type, FrameType.audio);
    expect(d.senderId, 0xDEADBEEF);
    expect(d.channel, 7);
    expect(d.seq, 65535);
    expect(d.payload, f.payload);
  });

  test('control frame carries hello name', () {
    final f = Frame.control(
      senderId: 1,
      channel: 2,
      seq: 3,
      message: const ControlMessage(ControlKind.hello, name: 'Ana'),
    );
    final msg = Frame.tryDecode(f.encode())!.control!;
    expect(msg.kind, ControlKind.hello);
    expect(msg.name, 'Ana');
  });

  test('rejects foreign, truncated and unknown-type packets', () {
    expect(Frame.tryDecode([1, 2, 3]), isNull);
    expect(Frame.tryDecode(List.filled(20, 0)), isNull);
    final good = Frame(
      type: FrameType.audio,
      senderId: 1,
      channel: 1,
      seq: 1,
      payload: Uint8List(0),
    ).encode();
    final badType = Uint8List.fromList(good)..[3] = 99;
    expect(Frame.tryDecode(badType), isNull);
    final badVersion = Uint8List.fromList(good)..[2] = 2;
    expect(Frame.tryDecode(badVersion), isNull);
  });

  test('sequence comparison handles 16-bit wrap', () {
    expect(seqNewer(1, 0), isTrue);
    expect(seqNewer(0, 65535), isTrue);
    expect(seqNewer(65535, 0), isFalse);
    expect(seqNewer(5, 5), isFalse);
  });
}
