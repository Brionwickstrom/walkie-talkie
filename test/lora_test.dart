import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/audio/codec2_ffi.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/mesh.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/radio_clip.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';
import 'package:walkie_talkie/messaging/voice_transfer.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart';

const me = 0x1111, bob = 0x2222, carol = 0x3333, dave = 0x4444;
const carolRadio = 0xC0C0, daveRadio = 0xD0D0;

class RadioSend {
  RadioSend(this.payload, this.to, this.wantAck, this.priority);
  final Uint8List payload;
  final int to;
  final bool wantAck;
  final int priority;
  Frame get frame => Frame.tryDecode(payload)!;
}

/// A paired Meshtastic radio that is always in range.
class FakeRadio implements RadioLink {
  bool _ready = true;
  final sent = <RadioSend>[];
  @override
  int? queueFree;
  final _packets = StreamController<MeshPacketPb>.broadcast(sync: true);
  final _readyCtl = StreamController<bool>.broadcast(sync: true);

  @override
  bool get ready => _ready;
  set ready(bool v) {
    _ready = v;
    _readyCtl.add(v);
  }

  @override
  Stream<bool> get readyChanges => _readyCtl.stream;
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;

  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
  }) async {
    sent.add(RadioSend(payload, to, wantAck, priority));
  }

  /// An app frame arrives over LoRa from radio [node].
  void hear(
    Uint8List frame, {
    required int node,
    int port = PortNum.privateApp,
  }) => _packets.add(
    MeshPacketPb(
      from: node,
      to: meshBroadcast,
      rxSnr: 4.5,
      rxRssi: -101,
      hopLimit: 2,
      hopStart: 3,
      decoded: MeshData(portnum: port, payload: frame),
    ),
  );

  /// Sent frames other than the radio presence hello.
  List<Frame> get traffic => [
    for (final s in sent)
      if (!(s.frame.type == FrameType.control &&
          s.frame.control?.kind == ControlKind.hello))
        s.frame,
  ];
}

Frame hello(int from, int seq, {String? name, int channel = 1}) =>
    Frame.control(
      senderId: from,
      channel: channel,
      seq: seq,
      message: ControlMessage(ControlKind.hello, name: name),
    );

Frame dataFrame(int from, int seq, List<int> payload) => Frame(
  type: FrameType.data,
  senderId: from,
  channel: 1,
  seq: seq,
  payload: Uint8List.fromList(payload),
);

Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

bool containsBytes(List<int> hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

/// 16 kHz test "speech": harmonics of 140 Hz with a syllable envelope.
Int16List speech(int ms, {int lead = 0}) {
  final n = 16 * ms;
  final out = Int16List(n);
  for (var i = 0; i < n; i++) {
    if (i < 16 * lead) continue;
    final t = i / 16000;
    final env = 0.5 + 0.5 * sin(2 * pi * 3 * t);
    var v = 0.0;
    for (var h = 1; h <= 8; h++) {
      v += sin(2 * pi * 140 * h * t) / h;
    }
    out[i] = (v * env * 6000).round().clamp(-32768, 32767);
  }
  return out;
}

/// Fake 2-byte-per-40-ms codec (bit layout like Codec 2: left aligned).
class FakeCodec implements FrameCodec {
  @override
  int get mode => 99;
  @override
  int get samplesPerFrame => 320;
  @override
  int get bitsPerFrame => 12;
  @override
  Uint8List encode(Int16List pcm8k) {
    var peak = 0;
    for (final v in pcm8k) {
      if (v.abs() > peak) peak = v.abs();
    }
    final q = (peak >> 3) & 0xFFF;
    return Uint8List.fromList([q >> 4, (q & 0xF) << 4]);
  }

  @override
  Int16List decode(Uint8List bits) {
    final q = (bits[0] << 4) | (bits[1] >> 4);
    return Int16List(320)..fillRange(0, 320, q << 3);
  }

  @override
  void dispose() {}
}

void main() {
  group('rate limit', () {
    test('burst of 4, then one packet every 8 s', () {
      final clock = FakeClock();
      final l = LoraRateLimiter(clock: clock.call);
      for (var i = 0; i < 4; i++) {
        expect(l.tryTake(), isTrue);
      }
      expect(l.tryTake(), isFalse);
      expect(l.wait, const Duration(seconds: 8));
      clock.advance(const Duration(seconds: 7));
      expect(l.tryTake(), isFalse);
      clock.advance(const Duration(seconds: 1));
      expect(l.tryTake(), isTrue);
      expect(l.tryTake(), isFalse);
      clock.advance(const Duration(minutes: 5));
      expect(l.tokens, 4); // never more than the burst
    });
  });

  group('LoraTransport', () {
    late FakeRadio radio;
    late FakeClock clock;
    late LoraTransport t;

    setUp(() async {
      radio = FakeRadio();
      clock = FakeClock();
      t = LoraTransport(
        radio: radio,
        clock: clock.call,
        pumpInterval: const Duration(hours: 1),
      );
      await t.start(localNodeId: me, channel: 1);
    });
    tearDown(() => t.dispose());

    test('plain send() is never allowed on the radio', () async {
      await t.send(hello(me, 1).encode());
      await t.send(hello(me, 2).encode(), peerIds: {carol});
      await flush();
      expect(radio.sent, isEmpty);
      expect(t.droppedGeneric, 2);
    });

    test('too big for a LoRa packet is refused', () {
      expect(t.sendRadio(Uint8List(loraPayloadBudget + 1)), isFalse);
      expect(t.sendRadio(Uint8List(loraPayloadBudget)), isTrue);
    });

    test('queue: urgent first, rate limited, expired after 3 min', () async {
      // Use up the burst.
      for (var i = 0; i < 4; i++) {
        t.sendRadio(dataFrame(me, i, [i]).encode());
      }
      await flush();
      expect(radio.sent.length, 4);
      t.sendRadio(
        dataFrame(me, 10, [10]).encode(),
        priority: LoraPriority.bulk,
      );
      t.sendRadio(dataFrame(me, 11, [11]).encode());
      t.sendRadio(hello(me, 12).encode(), priority: LoraPriority.presence);
      t.sendRadio(
        dataFrame(me, 13, [13]).encode(),
        priority: LoraPriority.urgent,
      );
      await flush();
      expect(radio.sent.length, 4);
      expect(t.queued, 4);
      clock.advance(const Duration(seconds: 8));
      await t.pump();
      expect(radio.sent.last.frame.seq, 13); // urgent first
      expect(radio.sent.last.priority, MeshPacketPb.priorityHigh);
      clock.advance(const Duration(seconds: 8));
      await t.pump();
      expect(radio.sent.last.frame.seq, 11); // then normal
      clock.advance(const Duration(minutes: 4));
      await t.pump(); // bulk and presence are stale now
      expect(t.queued, 0);
      expect(t.expired, 2);
    });

    test('radio queue full: hold packets', () async {
      radio.queueFree = 0;
      t.sendRadio(dataFrame(me, 1, [1]).encode());
      await flush();
      expect(radio.sent, isEmpty);
      radio.queueFree = 3;
      await t.pump();
      expect(radio.sent.length, 1);
    });

    test('directed to a known radio with want_ack, else broadcast', () async {
      radio.hear(hello(carol, 1).encode(), node: carolRadio);
      t.sendRadio(dataFrame(me, 1, [1]).encode(), peerIds: {carol});
      t.sendRadio(dataFrame(me, 2, [2]).encode(), peerIds: {carol, dave});
      t.sendRadio(dataFrame(me, 3, [3]).encode());
      await flush();
      expect(radio.sent[0].to, carolRadio);
      expect(radio.sent[0].wantAck, isTrue);
      expect(radio.sent[1].to, meshBroadcast);
      expect(radio.sent[2].to, meshBroadcast);
      expect(t.peerSignals[carol]!.rssi, -101);
      expect(t.peerSignals[carol]!.hopsAway, 1);
    });

    test('ignores other ports and non-app payloads', () async {
      final got = <InboundFrame>[];
      t.frames.listen(got.add);
      radio.hear(
        hello(carol, 1).encode(),
        node: carolRadio,
        port: PortNum.text,
      );
      radio.hear(Uint8List.fromList('hello'.codeUnits), node: carolRadio);
      radio.hear(hello(carol, 2).encode(), node: carolRadio);
      await flush();
      expect(got.length, 1);
      expect(got.single.transport, TransportKind.lora);
    });

    test('not ready: unavailable, nothing queued', () {
      radio.ready = false;
      expect(t.status, TransportStatus.unavailable);
      expect(t.sendRadio(dataFrame(me, 1, [1]).encode()), isFalse);
    });
  });

  group('routing: LoRa only when nothing else reaches', () {
    late FakeTransport lan, ble;
    late FakeRadio radio;
    late LoraTransport lora;
    late TransportManager m;
    late FakeClock clock;

    Future<void> setUpManager({ChannelKey? key}) async {
      clock = FakeClock();
      lan = FakeTransport(TransportKind.lan);
      ble = FakeTransport(TransportKind.ble);
      radio = FakeRadio();
      lora = LoraTransport(
        radio: radio,
        clock: clock.call,
        // Generous limit so routing, not the limiter, is under test.
        limiter: LoraRateLimiter(burst: 100, clock: clock.call),
        pumpInterval: const Duration(hours: 1),
      );
      m = TransportManager(
        transports: [lan, ble, lora],
        localNodeId: me,
        localName: 'Me',
        channel: key?.channel ?? 1,
        channelKey: key,
        clock: clock.call,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      lan.sent.clear();
      ble.sent.clear();
      radio.sent.clear();
    }

    tearDown(() => m.dispose());

    test('peer on Bluetooth and LoRa: everything goes on Bluetooth', () async {
      await setUpManager();
      ble.deliver(hello(bob, 1, name: 'Bob'));
      radio.hear(hello(bob, 2).encode(), node: 0xB0B0);
      await flush();
      expect(m.peer(bob)!.activeLink, TransportKind.ble);
      expect(m.bestLinkTo(bob), TransportKind.ble);
      await m.sendAudio(Uint8List.fromList([1, 2, 3]));
      await m.sendData(bob, Uint8List.fromList([9]));
      await m.sendControlTo(bob, const ControlMessage(ControlKind.ring, id: 5));
      await m.sendHello();
      await m.sendPings();
      await flush();
      expect(radio.traffic, isEmpty);
      expect(radio.sent, isEmpty);
      expect(ble.sent.map((s) => s.frame.type), contains(FrameType.audio));
      // The Bluetooth link going stale never adds LoRa as a backup copy.
      clock.advance(const Duration(seconds: 2));
      await m.sendData(bob, Uint8List.fromList([10]));
      await flush();
      expect(radio.sent, isEmpty);
    });

    test(
      'peer only on LoRa: data and rings yes, audio/talk/hello/ping no',
      () async {
        await setUpManager();
        radio.hear(hello(carol, 1, name: 'Carol').encode(), node: carolRadio);
        await flush();
        final p = m.peer(carol)!;
        expect(p.name, 'Carol');
        expect(p.activeLink, TransportKind.lora);
        expect(m.bestLinkTo(carol), TransportKind.lora);
        expect(m.isReachable(carol), isTrue);
        expect(m.reachablePeersOn(1), {carol});

        await m.setTalking(true);
        await m.sendAudio(Uint8List.fromList([1, 2, 3]));
        await m.setTalking(false);
        await m.sendHello();
        await m.sendPings();
        await m.sendBeacon();
        await flush();
        expect(radio.traffic, isEmpty);

        expect(await m.sendData(carol, Uint8List.fromList([7])), isTrue);
        await flush();
        expect(radio.traffic.single.type, FrameType.data);
        expect(radio.sent.last.to, carolRadio);

        // A ring the ringer repeats every second goes once per 20 s.
        const ring = ControlMessage(ControlKind.ring, id: 42, to: carol);
        await m.sendControlTo(carol, ring);
        await m.sendControlTo(carol, ring);
        await flush();
        expect(radio.traffic.length, 2);
        clock.advance(const Duration(seconds: 21));
        await m.sendControlTo(carol, ring);
        await flush();
        expect(radio.traffic.length, 3);
        expect(radio.sent.last.priority, MeshPacketPb.priorityHigh);

        // Channel-wide control: one radio packet for every far phone.
        radio.hear(hello(dave, 1).encode(), node: daveRadio);
        await flush();
        await m.sendControlToChannel(
          const ControlMessage(ControlKind.beep, id: 7),
        );
        await flush();
        expect(radio.traffic.last.control!.kind, ControlKind.beep);
        expect(radio.sent.last.to, meshBroadcast);
      },
    );

    test('LoRa peers stay reachable for minutes, then time out', () async {
      await setUpManager();
      radio.hear(hello(carol, 1).encode(), node: carolRadio);
      await flush();
      clock.advance(const Duration(minutes: 10));
      m.prune();
      expect(m.isReachable(carol), isTrue);
      expect(m.liveLinksOf(m.peer(carol)!, clock.now), [TransportKind.lora]);
      clock.advance(const Duration(minutes: 7));
      m.prune();
      expect(m.peer(carol), isNull);
    });

    test('a Wi-Fi link appearing takes over from LoRa at once', () async {
      await setUpManager();
      radio.hear(hello(carol, 1).encode(), node: carolRadio);
      await flush();
      lan.deliver(hello(carol, 2));
      await m.sendData(carol, Uint8List.fromList([1]));
      await flush();
      expect(m.peer(carol)!.activeLink, TransportKind.lan);
      expect(radio.traffic, isEmpty);
      expect(lan.sent.where((s) => s.frame.type == FrameType.data).length, 1);
    });

    test(
      'the phone mesh beats LoRa; LoRa frames are never mesh-relayed',
      () async {
        await setUpManager();
        // Bob is a mesh neighbour on Bluetooth.
        ble.deliver(hello(bob, 1));
        ble.deliver(Frame.tryDecode(MeshBeacon.encode(bob, 1, {me}))!);
        // Dave is heard both relayed by Bob and over LoRa.
        final inner = hello(dave, 1).encode();
        ble.deliver(
          Frame.tryDecode(
            MeshPacket.encode(
              relayer: bob,
              seq: 2,
              hops: 2,
              maxHops: 4,
              to: 0,
              inner: inner,
            ),
          )!,
        );
        radio.hear(hello(dave, 2).encode(), node: daveRadio);
        await flush();
        expect(m.meshReachable(dave), isTrue);
        expect(m.bestLinkTo(dave), TransportKind.ble);
        ble.sent.clear();
        await m.sendData(dave, Uint8List.fromList([5]));
        await flush();
        expect(radio.traffic, isEmpty);
        expect(ble.sent.single.frame.type, FrameType.mesh);

        // Carol (radio only) talks: Bob does not get a relayed copy.
        ble.sent.clear();
        radio.hear(dataFrame(carol, 9, [1, 2]).encode(), node: carolRadio);
        await flush();
        expect(ble.sent.where((s) => s.frame.type == FrameType.mesh), isEmpty);
        // And the app mesh never puts mesh frames on the radio.
        expect(
          radio.sent.where((s) => s.frame.type == FrameType.mesh),
          isEmpty,
        );
      },
    );

    test('same frame over LoRa and Bluetooth is delivered once', () async {
      await setUpManager();
      final got = <InboundData>[];
      m.data.listen(got.add);
      final f = dataFrame(carol, 77, [1, 2, 3]);
      radio.hear(f.encode(), node: carolRadio);
      await flush();
      ble.deliver(f);
      // A relayed copy of it via the phone mesh is dropped too.
      ble.deliver(hello(bob, 1));
      ble.deliver(Frame.tryDecode(MeshBeacon.encode(bob, 1, {me}))!);
      ble.deliver(
        Frame.tryDecode(
          MeshPacket.encode(
            relayer: bob,
            seq: 3,
            hops: 2,
            maxHops: 4,
            to: 0,
            inner: f.encode(),
          ),
        )!,
      );
      await flush();
      expect(got.length, 1);
      expect(got.single.transport, TransportKind.lora);
      expect(m.mesh.duplicates, greaterThanOrEqualTo(1));
    });

    test(
      'radio presence hello is small and only sent on its own timer',
      () async {
        await setUpManager();
        m.helloExtras = () => {'v': 18, 'cn': 'A long channel name', 'adm': 1};
        await m.sendHello();
        await flush();
        expect(radio.sent, isEmpty);
        await m.sendRadioHello();
        await flush();
        final h = radio.sent.single;
        expect(h.to, meshBroadcast);
        expect(h.payload.length, lessThan(80));
        expect(h.frame.control!.kind, ControlKind.hello);
        expect(h.frame.control!.x, {'v': 18, 'lr': 1});
        expect(h.frame.control!.name, 'Me');
      },
    );

    test('radio hello does not overwrite what fast links told us', () async {
      await setUpManager();
      lan.deliver(
        Frame.control(
          senderId: bob,
          channel: 1,
          seq: 1,
          message: const ControlMessage(
            ControlKind.hello,
            name: 'Bob',
            interval: 2500,
            x: {'v': 18, 'cn': 'Trail'},
          ),
        ),
      );
      radio.hear(
        Frame.control(
          senderId: bob,
          channel: 1,
          seq: 2,
          message: const ControlMessage(
            ControlKind.hello,
            name: 'Bob',
            x: {'v': 18, 'lr': 1},
          ),
        ).encode(),
        node: 0xB0B0,
      );
      await flush();
      final p = m.peer(bob)!;
      expect(p.info['cn'], 'Trail');
      expect(p.helloInterval, const Duration(milliseconds: 2500));
    });

    test('private channel: the radio only ever carries ciphertext', () async {
      final key = await ChannelKey.deriveInline(3, 'summit', iterations: 1000);
      await setUpManager(key: key);
      final carolHello = key.seal(
        Frame.control(
          senderId: carol,
          channel: key.tag,
          seq: 1,
          message: const ControlMessage(ControlKind.hello, name: 'Carol'),
        ),
      );
      radio.hear(carolHello, node: carolRadio);
      await flush();
      expect(m.isReachable(carol), isTrue);
      final secret = Uint8List.fromList('meet at the lake'.codeUnits);
      await m.sendData(carol, secret);
      await m.sendRadioHello();
      await flush();
      expect(radio.sent.length, 2);
      for (final s in radio.sent) {
        expect(s.frame.type, FrameType.sealed);
        expect(containsBytes(s.payload, secret), isFalse);
        expect(containsBytes(s.payload, 'Me'.codeUnits), isFalse);
        expect(s.payload.length, lessThanOrEqualTo(loraPayloadBudget));
      }
      // A phone without the passcode heard over LoRa is ignored.
      radio.hear(hello(dave, 1).encode(), node: daveRadio);
      await flush();
      expect(m.peer(dave), isNull);
    });
  });

  group('radio clips', () {
    test('bit packing round trip (28 bit frames)', () {
      final rnd = Random(1);
      final frames = [
        for (var i = 0; i < 25; i++)
          Uint8List.fromList([
            rnd.nextInt(256),
            rnd.nextInt(256),
            rnd.nextInt(256),
            rnd.nextInt(256) & 0xF0, // 28 bits used
          ]),
      ];
      final packed = packBits(frames, 28);
      expect(packed.length, (25 * 28 + 7) ~/ 8); // 88 instead of 100
      expect(unpackBits(packed, 25, 28), frames);
    });

    test('header round trip and corrupt input', () {
      final c = RadioClip(
        mode: Codec2Mode.m700c,
        bitsPerFrame: 28,
        frameMs: 40,
        frames: 2,
        bits: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
        sentAt: DateTime(2026, 10, 25, 12),
      );
      final d = RadioClip.tryDecode(c.encode())!;
      expect(d.durationMs, 80);
      expect(d.sentAt, DateTime(2026, 10, 25, 12));
      expect(d.bits, c.bits);
      expect(RadioClip.tryDecode(c.encode().sublist(0, 18)), isNull);
      expect(VoiceClip.tryDecode(c.encode()), isNull);
      expect(RadioClip.looksLike(VoiceClip([Uint8List(3)]).encode()), isFalse);
    });

    test('silence trimmed, too long refused, resampling keeps length', () {
      final codec = RadioClipCodec(FakeCodec.new);
      final pcm = speech(2000, lead: 1000); // 1 s silence + 1 s speech
      final clip = codec.encode(pcm)!;
      expect(clip.durationMs, inInclusiveRange(1000, 1200));
      expect(codec.decode(clip).length, clip.frames * 640);
      expect(codec.encode(Int16List(16000)), isNull); // all silence
      expect(codec.encode(speech(9000)), isNull); // > 8 s
      expect(codec.encode(speech(9000), truncate: true)!.durationMs, 8000);
      expect(downsample16to8(Int16List(320)).length, 160);
      expect(upsample8to16(Int16List(160)).length, 320);
    });

    final lib = File('build/host/libcodec2.so').existsSync()
        ? Codec2Lib.load(path: 'build/host/libcodec2.so')
        : null;
    test(
      'real Codec 2 700C: 28 bits / 40 ms, 8 s fits in 5 radio chunks',
      () {
        final codec = RadioClipCodec(() => Codec2FrameCodec(lib!));
        final c = Codec2FrameCodec(lib!);
        expect(c.bitsPerFrame, 28);
        expect(c.samplesPerFrame, 320);
        c.dispose();
        final clip = codec.encode(speech(8000))!;
        expect(clip.frames, 200);
        final body = clip.encode();
        expect(body.length, RadioClip.headerSize + 700);
        expect(splitBody(body, chunkSize: loraChunkSize).length, 6);
        final pcm = codec.decode(clip);
        expect(pcm.length, 200 * 640);
        var energy = 0.0;
        for (final v in pcm) {
          energy += v * v;
        }
        expect(energy / pcm.length, greaterThan(1e4)); // not silence
      },
      skip: lib == null
          ? 'run tool/build_codec2_host.sh to test the native codec'
          : false,
    );
  });

  group('messenger over the radio', () {
    late FakeNet net;
    late FakeClock clock;

    setUp(() {
      net = FakeNet()..linkKind = TransportKind.lora;
      clock = FakeClock();
    });

    Messenger make(int id) {
      final node = net.add(id);
      final m = Messenger(
        link: node,
        storage: MemoryMessageStorage(),
        clock: clock.call,
        random: Random(id),
      );
      node.data.listen(m.onData);
      return m;
    }

    Future<void> run(List<Messenger> ms, Duration total) async {
      final steps = total.inMilliseconds ~/ 500;
      for (var i = 0; i < steps; i++) {
        clock.advance(const Duration(milliseconds: 500));
        for (final m in ms) {
          await m.tick();
        }
        await net.settle();
      }
    }

    VoiceClip opusClip(int n) => VoiceClip([
      for (var i = 0; i < n; i++) Uint8List.fromList(List.filled(30, i)),
    ]);

    test(
      'voice: the Codec 2 copy goes in small chunks, never the Opus one',
      () async {
        final a = make(1), b = make(2);
        final sizes = <int>[];
        final ids = <int>{};
        net.drop = (from, to, p) {
          final pkt = DataPacket.tryDecode(p);
          if (pkt is ChunkPacket) {
            sizes.add(pkt.data.length);
            ids.add(pkt.msgId);
          }
          return false;
        };
        Uint8List? transcoded;
        b.radioClipToVoice = (body) async {
          transcoded = body;
          return VoiceClip([Uint8List(5)], sentAt: clock.now).encode();
        };
        await a.outbox.load();
        await b.outbox.load();
        // No radio copy (too long / no codec): waits for a faster link.
        final long = await a.send(opusClip(500), toPeer: 2, channel: 1);
        await run([a, b], const Duration(seconds: 30));
        expect(sizes, isEmpty);
        expect(a.outgoing.single.viaRadio, isTrue);
        await a.cancel(long.msgId);

        final radio = RadioClipCodec(FakeCodec.new).encode(speech(3000))!;
        final e = await a.send(
          opusClip(150),
          toPeer: 2,
          channel: 1,
          radioClip: radio,
        );
        await run([a, b], const Duration(minutes: 2));
        expect(sizes, isNotEmpty);
        expect(sizes.every((s) => s <= loraChunkSize), isTrue);
        expect(ids.single, e.msgId | radioTransferBit);
        expect(RadioClip.looksLike(transcoded!), isTrue);
        final got = b.inbox.entries.single;
        expect(got.msgId, e.msgId); // real id, not the transfer id
        expect(got.viaRadio, isTrue);
        expect(a.outbox.entries, isEmpty); // delivered (ack over the radio)
      },
    );

    test('chat: text and location yes, photos wait', () async {
      final a = make(1), b = make(2);
      final arrivals = <ChatArrival>[];
      b.chats.listen(arrivals.add);
      await a.outbox.load();
      await b.outbox.load();
      await a.sendChat(
        ChatBody(
          type: ChatType.photo,
          data: Uint8List(5000),
          width: 10,
          height: 10,
        ),
        toPeer: 2,
        channel: 1,
      );
      await a.sendChat(
        ChatBody.text('Camp at the ridge'),
        toPeer: 2,
        channel: 1,
      );
      await a.sendChat(
        ChatBody(type: ChatType.location, lat: 45.5, lng: -122.6),
        toPeer: 2,
        channel: 1,
      );
      await run([a, b], const Duration(minutes: 2));
      expect(arrivals.map((x) => x.body.type), [
        ChatType.text,
        ChatType.location,
      ]);
      expect(arrivals.every((x) => x.viaRadio), isTrue);
      expect(a.outbox.entries.single.isChat, isTrue); // the photo waits
      // Once a fast link shows up the photo goes too.
      net.linkKind = TransportKind.lan;
      await run([a, b], const Duration(seconds: 10));
      expect(arrivals.length, 3);
    });

    test(
      'live location updates go over the radio at most every 5 min',
      () async {
        final a = make(1), b = make(2);
        final arrivals = <ChatArrival>[];
        b.chats.listen(arrivals.add);
        await a.outbox.load();
        await b.outbox.load();
        for (var i = 0; i < 4; i++) {
          await a.sendChat(
            ChatBody(
              type: ChatType.location,
              lat: 45.0 + i,
              lng: -122,
              liveId: 9,
              liveUntil: clock.now.add(const Duration(hours: 1)),
            ),
            toPeer: 2,
            channel: 1,
          );
          await run([a, b], const Duration(seconds: 30));
        }
        expect(arrivals.length, 1);
      },
    );
  });
}
