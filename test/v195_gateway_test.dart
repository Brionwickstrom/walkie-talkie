// v1.9.5: LoRa gateway (Synology container + phones sharing their radio):
// stream framing, envelopes, dedupe, loop prevention, airtime limits and
// end-to-end bridging between an internet phone and a radio-only phone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_relay/relay_server.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/gateway_protocol.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/gateway/gateway_core.dart';
import 'package:walkie_talkie/gateway/gateway_io.dart';
import 'package:walkie_talkie/gateway/stream_wire.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/protobuf.dart';

import 'fake_transport.dart';

const alice = 0xA1A1, bob = 0xB0B0, carol = 0xC0C0, gwId = 0x6A7E;
const gwRadioNode = 0x11110001, gwRadio2Node = 0x11110002;
const bobRadioNode = 0x22220001;

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Everything transmitted on the air reaches every other radio.
class Air {
  final radios = <AirRadio>[];
  void transmit(AirRadio from, Uint8List payload, int to) {
    for (final r in radios) {
      if (identical(r, from) || !r.ready) continue;
      if (to != meshBroadcast && to != r.node) {
        // Meshtastic: other radios still hear (and repeat) it, the
        // firmware only hands packets for us / broadcast to the client.
        continue;
      }
      r.hear(payload, from: from.node, to: to);
    }
  }
}

class RadioTx {
  RadioTx(this.payload, this.to, this.wantAck);
  final Uint8List payload;
  final int to;
  final bool wantAck;
  Frame get frame => Frame.tryDecode(payload)!;
}

/// A radio for both the gateway ([GatewayRadioLink]) and phones
/// ([RadioLink]).
class AirRadio implements GatewayRadioLink, RadioLink {
  AirRadio(this.node, {this.air, this.name = 'radio'}) {
    air?.radios.add(this);
  }
  final int node;
  final Air? air;
  @override
  final String name;
  @override
  bool ready = true;
  final sent = <RadioTx>[];
  final _packets = StreamController<MeshPacketPb>.broadcast(sync: true);
  final _readyCtl = StreamController<bool>.broadcast(sync: true);

  @override
  int? get myNode => node;
  @override
  int? queueFree;
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;
  @override
  Stream<bool> get readyChanges => _readyCtl.stream;

  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
    int hopLimit = 0,
  }) async {
    sent.add(RadioTx(payload, to, wantAck));
    channels.add(channel);
    air?.transmit(this, payload, to);
  }

  /// Slots used by [send] (v1.9.7) and this radio's linked channels.
  final channels = <int>[];
  final meshSlots = <MeshChannelRef, int>{};
  @override
  int? meshChannelIndex(MeshChannelRef ref) => meshSlots[ref];

  void hear(Uint8List payload, {required int from, int to = meshBroadcast}) =>
      _packets.add(
        MeshPacketPb(
          from: from,
          to: to,
          rxSnr: 6.25,
          rxRssi: -95,
          decoded: MeshData(portnum: PortNum.privateApp, payload: payload),
        ),
      );
}

/// A relay room in memory: what one socket sends reaches the others.
class Hub {
  final rooms = <String, List<HubSocket>>{};
  void post(HubSocket from, Uint8List bytes) {
    for (final s in List.of(rooms[from.room] ?? const <HubSocket>[])) {
      if (!identical(s, from)) s.receive(bytes);
    }
  }
}

abstract class HubSocket {
  String get room;
  void receive(Uint8List bytes);
}

class FakeRoom implements GatewayRoom, HubSocket {
  FakeRoom(this.hub, this.room) {
    hub.rooms.putIfAbsent(room, () => []).add(this);
  }
  final Hub hub;
  @override
  final String room;
  @override
  bool connected = true;
  final sent = <Frame>[];
  final _frames = StreamController<Uint8List>.broadcast(sync: true);
  bool closed = false;

  @override
  Stream<Uint8List> get frames => _frames.stream;
  @override
  void send(Uint8List bytes) {
    sent.add(Frame.tryDecode(bytes)!);
    hub.post(this, bytes);
  }

  @override
  void receive(Uint8List bytes) => _frames.add(bytes);
  @override
  Future<void> close() async {
    closed = true;
    hub.rooms[room]?.remove(this);
  }

  List<GatewayEnvelope> envelopes(GatewayKind k) => [
    for (final f in sent)
      if (GatewayEnvelope.tryDecode(f) case final e? when e.kind == k) e,
  ];
}

/// A phone's internet transport sitting in one hub room.
class HubTransport extends FakeTransport implements HubSocket {
  HubTransport(this.hub, this.room) : super(TransportKind.internet) {
    hub.rooms.putIfAbsent(room, () => []).add(this);
  }
  final Hub hub;
  @override
  final String room;

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    await super.send(frame, peerIds: peerIds);
    if (status == TransportStatus.running) hub.post(this, frame);
  }

  @override
  void receive(Uint8List bytes) {
    final f = Frame.tryDecode(bytes);
    if (f != null && status == TransportStatus.running) deliver(f);
  }
}

Frame ctl(int from, ControlKind k, {int seq = 1, int ch = 3, int? to}) =>
    Frame.control(
      senderId: from,
      channel: ch,
      seq: seq,
      message: ControlMessage(k, to: to, id: 77),
    );

Frame data(int from, int seq, {int ch = 3, int len = 20}) => Frame(
  type: FrameType.data,
  senderId: from,
  channel: ch,
  seq: seq,
  payload: Uint8List.fromList(List.generate(len, (i) => i & 0xFF)),
);

Uint8List toRadio(Frame inner, {int to = 0, int from = alice, int seq = 9}) =>
    GatewayEnvelope.toRadio(
      inner.encode(),
      to: to,
      priority: LoraPriority.normal.index,
    ).toFrame(senderId: from, channel: inner.channel, seq: seq).encode();

void main() {
  group('stream framing (USB serial / TCP)', () {
    test('frames survive junk, split reads and back-to-back packets', () {
      final a = Uint8List.fromList([1, 2, 3]);
      final b = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
      final wire = [
        ...utf8.encode('DEBUG | ??:??:?? 3 [Main] boot\r\n'),
        ...StreamFramer.frame(a),
        0x94, // a stray start byte
        ...StreamFramer.frame(b),
      ];
      final fr = StreamFramer();
      final out = <Uint8List>[];
      for (var i = 0; i < wire.length; i += 7) {
        out.addAll(
          fr.add(wire.sublist(i, i + 7 > wire.length ? wire.length : i + 7)),
        );
      }
      expect(out.length, 2);
      expect(out[0], a);
      expect(out[1], b);
    });

    test('StreamWire hands frames to read() and notifies', () async {
      final ctl = StreamController<List<int>>();
      final written = <int>[];
      final w = StreamWire(ctl.stream, (b) async => written.addAll(b));
      var notes = 0;
      w.notifications.listen((_) => notes++);
      ctl.add(StreamFramer.frame(Uint8List.fromList([9, 8])));
      await flush();
      expect(notes, 1);
      expect(await w.read(), [9, 8]);
      expect(await w.read(), isEmpty);
      await w.write(Uint8List.fromList([5]));
      expect(written, [0x94, 0xC3, 0, 1, 5]);
      await ctl.close();
      await flush();
      expect(w.isClosed, isTrue);
    });
  });

  group('envelopes', () {
    test('fromRadio / toRadio / announce round trip', () {
      final inner = data(bob, 4).encode();
      final f1 = GatewayEnvelope.fromRadio(
        inner,
        radioNode: gwRadioNode,
        snr: -7.25,
      ).toFrame(senderId: gwId, channel: 3, seq: 1);
      final e1 = GatewayEnvelope.tryDecode(Frame.tryDecode(f1.encode())!)!;
      expect(e1.kind, GatewayKind.fromRadio);
      expect(e1.inner, inner);
      expect(e1.radioNode, gwRadioNode);
      expect(e1.snr, -7.25);
      expect(e1.packetId, gatewayPacketId(inner));

      final f2 = GatewayEnvelope.toRadio(
        inner,
        to: bob,
        priority: 1,
      ).toFrame(senderId: alice, channel: 3, seq: 2);
      final e2 = GatewayEnvelope.tryDecode(f2)!;
      expect((e2.kind, e2.to, e2.priority), (GatewayKind.toRadio, bob, 1));

      final f3 = GatewayEnvelope.announce(
        name: 'Home gateway',
        radiosUp: 2,
        radios: 3,
      ).toFrame(senderId: gwId, channel: 3, seq: 3);
      final e3 = GatewayEnvelope.tryDecode(f3)!;
      expect(
        (e3.name, e3.radiosUp, e3.radios, e3.isPhone),
        ('Home gateway', 2, 3, false),
      );
    });

    test('nested envelopes and phone-mesh frames are refused', () {
      final env = GatewayEnvelope.announce(name: 'x')
          .toFrame(senderId: gwId, channel: 1, seq: 1)
          .encode();
      final f = GatewayEnvelope.toRadio(env)
          .toFrame(senderId: alice, channel: 1, seq: 2);
      expect(GatewayEnvelope.tryDecode(f), isNull);
      expect(FrameType.fromCode(8), FrameType.gateway);
    });

    test('room of a frame: channel number, or p+tag when sealed', () async {
      expect(gatewayRoomOf(data(bob, 1, ch: 7)), '7');
      final key = await ChannelKey.derive(5, 'correct horse battery');
      final sealed = Frame.tryDecode(key.seal(data(bob, 1, ch: 5)))!;
      expect(
        gatewayRoomOf(sealed),
        'p${key.tag.toRadixString(16).padLeft(4, '0')}',
      );
    });
  });

  group('gateway core', () {
    late Hub hub;
    late DateTime now;
    late GatewayCore gw;
    late AirRadio home, van;
    late FakeRoom phoneSide; // what a phone in room 3 sees

    FakeRoom room(String r) =>
        hub.rooms[r]!.whereType<FakeRoom>().firstWhere((x) => x != phoneSide);

    setUp(() {
      hub = Hub();
      now = DateTime(2026, 10, 27, 9);
      gw = GatewayCore(
        name: 'Home gateway',
        nodeId: gwId,
        roomFactory: (r) => FakeRoom(hub, r),
        rooms: {'3'},
        clock: () => now,
      );
      home = AirRadio(gwRadioNode, name: 'Home RAK');
      van = AirRadio(gwRadio2Node, name: 'Van');
      gw.addRadio(home);
      gw.addRadio(van);
      phoneSide = FakeRoom(hub, '3');
    });

    test('LoRa -> internet: wrapped once, deduped across radios', () {
      final f = data(bob, 1).encode();
      home.hear(f, from: bobRadioNode);
      van.hear(f, from: bobRadioNode); // the van radio heard it too
      final got = [for (final b in phoneSide.sent) b];
      expect(got, isEmpty); // phoneSide only records its own sends
      final out = room('3').envelopes(GatewayKind.fromRadio);
      expect(out.length, 1);
      expect(out.single.inner, f);
      expect(gw.duplicates, 1);
      expect(gw.loraPeers[bob]!.node, bobRadioNode);
    });

    test('a sealed LoRa frame opens its private room (lease)', () async {
      final key = await ChannelKey.derive(5, 'correct horse battery');
      final sealed = key.seal(data(bob, 1, ch: 5));
      home.hear(sealed, from: bobRadioNode);
      final r = 'p${key.tag.toRadixString(16).padLeft(4, '0')}';
      expect(gw.inRoom(r), isTrue);
      final env = room(r).envelopes(GatewayKind.fromRadio).single;
      expect(env.inner, sealed); // ciphertext, untouched
      now = now.add(const Duration(minutes: 31));
      await gw.tick();
      expect(gw.inRoom(r), isFalse);
    });

    test(
      'internet -> LoRa: request transmitted once, never echoed back',
      () async {
        final inner = data(alice, 5);
        phoneSide.send(toRadio(inner));
        await gw.pump();
        expect(home.sent.length, 1);
        expect(van.sent.length, 1); // broadcast: every radio
        expect(home.sent.single.payload, inner.encode());
        expect(home.sent.single.to, meshBroadcast);
        // The same request again (a second relay / phone retry).
        phoneSide.send(toRadio(inner, seq: 10));
        await gw.pump();
        expect(home.sent.length, 1);
        // The van radio hears the home radio's packet on the air: not
        // forwarded back to the internet (loop prevention).
        van.hear(inner.encode(), from: gwRadioNode);
        // A phone's radio repeats it (Meshtastic rebroadcast): still not.
        home.hear(inner.encode(), from: bobRadioNode);
        expect(room('3').envelopes(GatewayKind.fromRadio), isEmpty);
      },
    );

    test('directed request goes out only where that phone was heard', () async {
      van.hear(ctl(bob, ControlKind.hello).encode(), from: bobRadioNode);
      final inner = data(alice, 6);
      phoneSide.send(toRadio(inner, to: bob));
      await gw.pump();
      expect(home.sent, isEmpty);
      expect(van.sent.single.to, bobRadioNode);
      expect(van.sent.single.wantAck, isTrue);
      // Unknown target: nothing on the air.
      phoneSide.send(toRadio(data(alice, 7), to: carol, seq: 11));
      await gw.pump();
      expect(van.sent.length, 1);
      expect(gw.noRoute, 1);
    });

    test('never live audio or talk start / pings over LoRa', () async {
      final audio = Frame(
        type: FrameType.audio,
        senderId: alice,
        channel: 3,
        seq: 1,
        payload: Uint8List(40),
      );
      phoneSide.send(toRadio(audio));
      phoneSide.send(toRadio(ctl(alice, ControlKind.talkStart), seq: 12));
      phoneSide.send(toRadio(ctl(alice, ControlKind.ping, seq: 2), seq: 13));
      phoneSide.send(toRadio(data(alice, 8, len: 220), seq: 14)); // too big
      await gw.pump();
      expect(home.sent, isEmpty);
      expect(gw.rejected, 4);
    });

    test('airtime: token bucket per radio, queue drains over time', () async {
      for (var i = 0; i < 8; i++) {
        phoneSide.send(toRadio(data(alice, 20 + i), seq: 30 + i));
      }
      await gw.pump();
      expect(home.sent.length, 4); // burst
      now = now.add(const Duration(seconds: 8));
      await gw.pump();
      expect(home.sent.length, 5);
      now = now.add(const Duration(seconds: 24));
      await gw.pump();
      expect(home.sent.length, 8);
    });

    test('per phone request limit and presence once per few minutes', () async {
      for (var i = 0; i < 20; i++) {
        phoneSide.send(toRadio(data(alice, 100 + i), seq: 200 + i));
      }
      expect(gw.rateLimited, 8); // 12 per minute
      final hello1 = GatewayEnvelope.toRadio(
        ctl(carol, ControlKind.hello, seq: 1).encode(),
        priority: LoraPriority.presence.index,
      ).toFrame(senderId: carol, channel: 3, seq: 1);
      final hello2 = GatewayEnvelope.toRadio(
        ctl(carol, ControlKind.hello, seq: 2).encode(),
        priority: LoraPriority.presence.index,
      ).toFrame(senderId: carol, channel: 3, seq: 2);
      phoneSide.send(hello1.encode());
      phoneSide.send(hello2.encode());
      expect(gw.rateLimited, 9);
    });

    test('another gateway brought it in first: we stay quiet', () {
      final f = data(bob, 9).encode();
      final other = GatewayEnvelope.fromRadio(f)
          .toFrame(senderId: 0x0BAD, channel: 3, seq: 1);
      phoneSide.send(other.encode());
      home.hear(f, from: bobRadioNode);
      expect(room('3').envelopes(GatewayKind.fromRadio), isEmpty);
    });

    test('a phone sent it straight to the room: its LoRa copy is not '
        'echoed', () {
      final f = data(alice, 3);
      phoneSide.send(f.encode());
      home.hear(f.encode(), from: 0x33330001);
      expect(room('3').envelopes(GatewayKind.fromRadio), isEmpty);
    });

    test('announces itself in every room, with radio count', () async {
      await gw.tick();
      final a = room('3').envelopes(GatewayKind.announce).single;
      expect((a.name, a.radiosUp, a.radios), ('Home gateway', 2, 2));
      home.ready = false;
      now = now.add(const Duration(seconds: 31));
      await gw.tick();
      expect(room('3').envelopes(GatewayKind.announce).last.radiosUp, 1);
    });

    test('radio removed from config: its phones are forgotten', () async {
      van.hear(ctl(bob, ControlKind.hello).encode(), from: bobRadioNode);
      await gw.removeRadio(van);
      expect(gw.loraPeers, isEmpty);
      expect(gw.radios.length, 1);
    });
  });

  group('phones and the gateway end to end', () {
    late Hub hub;
    late Air air;
    late GatewayCore gw;
    late TransportManager a, b;
    late HubTransport aNet;
    late AirRadio bRadio;
    late LoraTransport bLora;

    setUp(() async {
      hub = Hub();
      air = Air();
      gw = GatewayCore(
        name: 'Home gateway',
        nodeId: gwId,
        roomFactory: (r) => FakeRoom(hub, r),
        rooms: {'3'},
      );
      gw.addRadio(AirRadio(gwRadioNode, air: air));
      aNet = HubTransport(hub, '3');
      a = TransportManager(
        transports: [aNet],
        localNodeId: alice,
        localName: 'Alice',
        channel: 3,
      );
      bRadio = AirRadio(bobRadioNode, air: air);
      bLora = LoraTransport(radio: bRadio);
      b = TransportManager(
        transports: [bLora],
        localNodeId: bob,
        localName: 'Bob',
        channel: 3,
      );
      await a.start();
      await b.start();
      await gw.tick(); // announce
    });

    tearDown(() async {
      await a.dispose();
      await b.dispose();
      await gw.close();
    });

    test(
      'internet phone sees the gateway; radio phone shows up via it',
      () async {
        expect(a.gateways.single.name, 'Home gateway');
        expect(a.gatewayIds, {gwId});
        await b.sendRadioHello();
        await bLora.pump();
        await flush();
        final p = a.peer(bob)!;
        expect(p.name, 'Bob');
        expect(a.gatewayReachable(bob), isTrue);
        expect(a.isReachable(bob), isTrue);
        expect(a.bestLinkTo(bob), TransportKind.lora);
        expect(p.viaGateway, 'Home gateway');
      },
    );

    test('a message both ways, deduped, and no live audio', () async {
      await b.sendRadioHello();
      await bLora.pump();
      await flush();
      final bGot = <InboundData>[];
      b.data.listen(bGot.add);
      expect(await a.sendData(bob, Uint8List.fromList([1, 2, 3])), isTrue);
      await flush();
      await gw.pump();
      await flush();
      expect(bGot.single.payload, [1, 2, 3]);
      expect(bGot.single.peerId, alice);

      // Alice's presence over the radio, then Bob answers over LoRa.
      expect(a.sendGatewayHello(), isTrue);
      await flush();
      await gw.pump();
      await flush();
      expect(b.radioReachable(alice), isTrue);
      final aGot = <InboundData>[];
      a.data.listen(aGot.add);
      expect(await b.sendData(alice, Uint8List.fromList([4, 5])), isTrue);
      await bLora.pump();
      await flush();
      expect(aGot.single.payload, [4, 5]);
      // Directed at the gateway's radio (Meshtastic acks it).
      expect(bRadio.sent.last.to, gwRadioNode);

      // Live audio never asks the gateway for airtime.
      final before = gw.internetToRadio;
      await a.sendAudio(Uint8List(30));
      await flush();
      await gw.pump();
      expect(gw.internetToRadio, before);
      expect(
        aNet.sent.where(
          (s) =>
              s.frame.type == FrameType.gateway &&
              GatewayEnvelope.tryDecode(s.frame)?.kind == GatewayKind.toRadio &&
              GatewayEnvelope.tryDecode(s.frame)!.innerFrame!.type ==
                  FrameType.audio,
        ),
        isEmpty,
      );
    });

    test('a phone sharing its radio stays quiet when the Home gateway '
        'already forwarded the same frame', () async {
      // Carol: internet + radio, sharing it.
      final cNet = HubTransport(hub, '3');
      final cRadio = AirRadio(0x33330001, air: air);
      final cLora = LoraTransport(radio: cRadio);
      final c =
          TransportManager(
              transports: [cNet, cLora],
              localNodeId: carol,
              localName: 'Carol',
              channel: 3,
            )
            ..gatewayForwardDelayMin = const Duration(milliseconds: 30)
            ..gatewayForwardDelayMax = const Duration(milliseconds: 60);
      await c.start();
      expect(c.sharingRadio, isTrue);
      await b.sendRadioHello();
      await bLora.pump();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final mine = cNet.sent.where(
        (s) =>
            s.frame.type == FrameType.gateway &&
            GatewayEnvelope.tryDecode(s.frame)?.kind == GatewayKind.fromRadio,
      );
      expect(mine, isEmpty);
      expect(gw.radioToInternet, 1);
      await c.dispose();
    });

    test('a phone sharing its radio bridges when no gateway did', () async {
      await gw.close();
      final cNet = HubTransport(hub, '3');
      final cRadio = AirRadio(0x33330001, air: air);
      final cLora = LoraTransport(radio: cRadio);
      final c =
          TransportManager(
              transports: [cNet, cLora],
              localNodeId: carol,
              localName: 'Carol',
              channel: 3,
            )
            ..gatewayForwardDelayMin = Duration.zero
            ..gatewayForwardDelayMax = Duration.zero;
      await c.start();
      await b.sendRadioHello();
      await bLora.pump();
      await flush();
      expect(c.gatewayForwarded, 1);
      expect(a.peer(bob)?.viaGateway, isNotNull);
      // Alice asks for the radio: Carol transmits it.
      await a.sendData(bob, Uint8List.fromList([7]));
      await flush();
      await cLora.pump();
      expect(c.gatewayTransmitted, 1);
      await c.dispose();
    });
  });

  test('private channel: the gateway only ever carries ciphertext', () async {
    final key = await ChannelKey.derive(5, 'correct horse battery');
    final room = 'p${key.tag.toRadixString(16).padLeft(4, '0')}';
    final hub = Hub(), air = Air();
    final gw = GatewayCore(
      name: 'Home gateway',
      nodeId: gwId,
      roomFactory: (r) => FakeRoom(hub, r),
    );
    final gwRadio = AirRadio(gwRadioNode, air: air);
    gw.addRadio(gwRadio);
    final a = TransportManager(
      transports: [HubTransport(hub, room)],
      localNodeId: alice,
      localName: 'Alice',
      channel: 5,
      channelKey: key,
    );
    final bRadio = AirRadio(bobRadioNode, air: air);
    final bLora = LoraTransport(radio: bRadio);
    final b = TransportManager(
      transports: [bLora],
      localNodeId: bob,
      localName: 'Bob',
      channel: 5,
      channelKey: key,
    );
    await a.start();
    await b.start();
    await b.sendRadioHello();
    await bLora.pump();
    await flush();
    expect(gw.inRoom(room), isTrue);
    await gw.tick(); // announce in the private room
    expect(a.gateways, isNotEmpty);
    expect(a.peer(bob)?.name, 'Bob'); // opened with the passcode key
    final got = <InboundData>[];
    b.data.listen(got.add);
    await a.sendData(bob, Uint8List.fromList([42]));
    await flush();
    await gw.pump();
    await flush();
    expect(got.single.payload, [42]);
    // Everything that went over the air or through the gateway was sealed.
    for (final t in [...gwRadio.sent, ...bRadio.sent]) {
      expect(t.frame.type, FrameType.sealed);
    }
    await a.dispose();
    await b.dispose();
    await gw.close();
  });

  test('gateway service: waiting for a USB radio, healthz answers', () async {
    final relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    final dir = await Directory.systemTemp.createTemp('gw');
    final hp = await ServerSocket.bind('127.0.0.1', 0);
    final healthPort = hp.port;
    await hp.close();
    await File('${dir.path}/gateway.json').writeAsString(
      jsonEncode({
        'name': 'Home gateway',
        'relay': 'ws://127.0.0.1:${relay.port}/ws',
        'healthPort': healthPort,
        'rooms': ['3'],
        'radios': [
          {'name': 'Home RAK (USB)', 'serial': '${dir.path}/ttyACM9'},
        ],
      }),
    );
    final svc = GatewayService(
      '${dir.path}/gateway.json',
      '${dir.path}/state.json',
    );
    await svc.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final client = HttpClient();
    final req = await client.get('127.0.0.1', healthPort, '/healthz');
    final res = await req.close();
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
    expect(res.statusCode, 200);
    expect(body['state'], 'waiting for radio');
    final radio = (body['radioList'] as List).single as Map;
    expect(radio['state'], 'waiting');
    expect('${radio['detail']}', contains('not present'));
    expect(relay.clientCount('3'), 1); // in the room already
    client.close();
    await svc.stop();
    await relay.close();
  });

  test('gateway service: Wi-Fi radio over TCP, added without a restart, '
      'bridges to the real relay', () async {
    final relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    final dir = await Directory.systemTemp.createTemp('gw');
    // A pretend Meshtastic radio on TCP (stream API, port 4403 style).
    final radioSrv = await ServerSocket.bind('127.0.0.1', 0);
    Socket? radioSock;
    final radioIn = <Uint8List>[];
    radioSrv.listen((sock) {
      radioSock = sock;
      final fr = StreamFramer();
      sock.listen((bytes) {
        for (final m in fr.add(bytes)) {
          radioIn.add(m);
          for (final f in pbDecode(m)) {
            if (f.number == 3) {
              final my = PbWriter()
                ..message(3, (PbWriter()..uint(1, gwRadioNode)).toBytes());
              sock.add(StreamFramer.frame(my.toBytes()));
              sock.add(
                StreamFramer.frame((PbWriter()..uint(7, f.asInt)).toBytes()),
              );
            }
          }
        }
      });
    });
    final cfg = File('${dir.path}/gateway.json');
    Future<void> writeCfg(List<Map<String, Object?>> radios) =>
        cfg.writeAsString(
          jsonEncode({
            'name': 'Home gateway',
            'relay': 'ws://127.0.0.1:${relay.port}/ws',
            'healthPort': 0,
            'rooms': ['3'],
            'radios': radios,
          }),
        );
    await writeCfg([]);
    final svc = GatewayService(cfg.path, '${dir.path}/state.json')
      ..reloadEvery = const Duration(milliseconds: 200);
    await svc.start();
    expect(svc.status()['state'], 'no radios configured');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await writeCfg([
      {'name': 'Van radio', 'tcp': '127.0.0.1:${radioSrv.port}'},
    ]);
    for (var i = 0; i < 50 && svc.core.radiosUp == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(svc.core.radiosUp, 1);
    expect(svc.status()['state'], 'bridging');

    // A phone in room 3 on the real relay.
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${relay.port}/ws?ch=3&id=a1a1',
    );
    final got = <Frame>[];
    ws.listen((m) {
      if (m is List<int>) got.add(Frame.tryDecode(m)!);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Bob's radio packet arrives at the van radio.
    final inner = data(bob, 1).encode();
    final snrBits = (ByteData(
      4,
    )..setFloat32(0, 5, Endian.little)).getUint32(0, Endian.little);
    final pkt = PbWriter()
      ..message(
        2,
        (PbWriter()
              ..fixed32(1, bobRadioNode)
              ..fixed32(2, meshBroadcast)
              ..message(
                4,
                MeshData(portnum: PortNum.privateApp, payload: inner).encode(),
              )
              ..fixed32(6, 99)
              ..fixed32(8, snrBits))
            .toBytes(),
      );
    radioSock!.add(StreamFramer.frame(pkt.toBytes()));
    for (var i = 0; i < 30 && got.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final env = [
      for (final f in got)
        if (GatewayEnvelope.tryDecode(f) case final e?
            when e.kind == GatewayKind.fromRadio)
          e,
    ];
    expect(env.single.inner, inner);

    // The phone asks for a ring on the air: it reaches the radio socket.
    ws.add(toRadio(ctl(alice, ControlKind.ring, seq: 5)));
    for (var i = 0; i < 30 && radioIn.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final sentPkts = [
      for (final m in radioIn)
        for (final f in pbDecode(m))
          if (f.number == 1) f,
    ];
    expect(sentPkts, isNotEmpty);
    expect(svc.core.internetToRadio, 1);
    await ws.close();
    await svc.stop();
    await radioSrv.close();
    await relay.close();
  });
}
