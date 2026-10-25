import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/fragmenter.dart';

Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (i) => i & 0xFF));

void main() {
  test('small message is one chunk at BLE default MTU', () {
    final f = Fragmenter(maxChunkSize: 20);
    final chunks = f.split(bytes(18));
    expect(chunks, hasLength(1));
    expect(Reassembler().add(chunks.single), bytes(18));
  });

  test('typical audio frame (12B header + 30B opus) splits at MTU 23', () {
    final f = Fragmenter(maxChunkSize: 20);
    final msg = bytes(42);
    final chunks = f.split(msg);
    expect(chunks, hasLength(3));
    expect(chunks.every((c) => c.length <= 20), isTrue);
    final r = Reassembler();
    expect(r.add(chunks[0]), isNull);
    expect(r.add(chunks[1]), isNull);
    expect(r.add(chunks[2]), msg);
  });

  test('fits in one chunk after MTU negotiation', () {
    expect(Fragmenter(maxChunkSize: 182).split(bytes(42)), hasLength(1));
  });

  test('out-of-order chunks still reassemble', () {
    final chunks = Fragmenter(maxChunkSize: 10).split(bytes(30));
    final r = Reassembler();
    expect(r.add(chunks[3]), isNull);
    expect(r.add(chunks[0]), isNull);
    expect(r.add(chunks[2]), isNull);
    expect(r.add(chunks[1]), bytes(30));
  });

  test('a lost chunk is abandoned when the next message starts', () {
    final f = Fragmenter(maxChunkSize: 10);
    final first = f.split(bytes(20));
    final second = f.split(bytes(20));
    final r = Reassembler();
    expect(r.add(first[0]), isNull); // first[1] and first[2] lost
    expect(r.add(second[0]), isNull);
    expect(r.add(second[1]), isNull);
    expect(r.add(second[2]), bytes(20));
  });

  test('refuses messages needing more than 15 chunks', () {
    expect(() => Fragmenter(maxChunkSize: 10).split(bytes(200)),
        throwsArgumentError);
  });
}
