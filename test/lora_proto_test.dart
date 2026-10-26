import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/ui/radio_settings.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);

/// FromRadio bytes built with the writer (field numbers from mesh.proto).
Uint8List fromRadio(void Function(PbWriter w) f) {
  final w = PbWriter();
  f(w);
  return w.toBytes();
}

Uint8List myInfo(int num) => fromRadio(
  (w) => w
    ..uint(1, 1)
    ..message(3, (PbWriter()..uint(1, num)).toBytes()),
);

Uint8List nodeInfo(int num, String long, String short, {int? battery}) =>
    fromRadio(
      (w) => w.message(
        4,
        (PbWriter()
              ..uint(1, num)
              ..message(
                2,
                (PbWriter()
                      ..string(1, '!${num.toRadixString(16)}')
                      ..string(2, long)
                      ..string(3, short))
                    .toBytes(),
              )
              ..message(6, (PbWriter()..uint(1, battery ?? 0)).toBytes()))
            .toBytes(),
      ),
    );

Uint8List loraConfig({int region = 1, int hop = 5}) => fromRadio(
  (w) => w.message(
    5,
    (PbWriter()..message(
          6,
          (PbWriter()
                ..boolean(1, true)
                ..uint(7, region)
                ..uint(8, hop)
                ..boolean(9, true))
              .toBytes(),
        ))
        .toBytes(),
  ),
);

Uint8List primaryChannel({List<int> psk = const [1], String name = ''}) =>
    fromRadio(
      (w) => w.message(
        10,
        (PbWriter()
              ..uint(1, 0)
              ..message(
                2,
                (PbWriter()
                      ..bytes(2, psk)
                      ..string(3, name))
                    .toBytes(),
              )
              ..uint(3, 1))
            .toBytes(),
      ),
    );

Uint8List configComplete(int nonce) => fromRadio((w) => w.uint(7, nonce));

Uint8List packetFrom(
  int from,
  List<int> payload, {
  int port = PortNum.privateApp,
  double snr = 6.25,
  int rssi = -97,
}) {
  final snrBits = (ByteData(
    4,
  )..setFloat32(0, snr, Endian.little)).getUint32(0, Endian.little);
  return fromRadio(
    (w) => w.message(
      2,
      (PbWriter()
            ..fixed32(1, from)
            ..fixed32(2, meshBroadcast)
            ..message(4, MeshData(portnum: port, payload: b(payload)).encode())
            ..fixed32(6, 77)
            ..fixed32(8, snrBits)
            ..uint(9, 1)
            ..uint(12, rssi)
            ..uint(15, 3))
          .toBytes(),
    ),
  );
}

/// A pretend Meshtastic radio behind the BLE characteristics.
class FakeRadioWire implements MeshtasticWire {
  final written = <Uint8List>[];
  final queue = <Uint8List>[];
  final _notify = StreamController<void>.broadcast(sync: true);
  List<Uint8List> Function(int nonce) onWantConfig = (_) => [];

  @override
  Future<void> write(Uint8List toRadio) async {
    written.add(toRadio);
    for (final f in pbDecode(toRadio)) {
      if (f.number == 3) queue.addAll(onWantConfig(f.asInt));
    }
  }

  @override
  Future<Uint8List> read() async =>
      queue.isEmpty ? Uint8List(0) : queue.removeAt(0);

  @override
  Stream<void> get notifications => _notify.stream;

  void push(Uint8List fr) {
    queue.add(fr);
    _notify.add(null);
  }
}

void main() {
  group('protobuf framing', () {
    test('varints, fixed32, negative int32, floats round trip', () {
      final w = PbWriter()
        ..uint(1, 300)
        ..uint(2, -97)
        ..fixed32(3, 0xFFFFFFFF)
        ..string(4, 'hé')
        ..boolean(5, true);
      final fields = pbDecode(w.toBytes());
      expect(fields[0].asInt, 300);
      expect(fields[1].asInt32, -97);
      // int32 negatives are 10 byte sign-extended varints.
      expect(w.toBytes().sublist(3, 14).length, 11);
      expect(fields[2].asFixed32, 0xFFFFFFFF);
      expect(fields[3].asString, 'hé');
      expect(fields[4].asBool, isTrue);
    });

    test('truncated input throws, FromRadio.tryDecode returns null', () {
      expect(
        () => pbDecode(b([0x12, 0x05, 1, 2])),
        throwsA(isA<PbFormatException>()),
      );
      expect(FromRadio.tryDecode(b([0x12, 0x05, 1, 2])), isNull);
    });

    test('ToRadio golden bytes (want_config_id, heartbeat, packet)', () {
      // field 3 varint 1234 = 0x18 0xD2 0x09
      expect(ToRadio.wantConfig(1234), b([0x18, 0xD2, 0x09]));
      // field 7 message { field 1 = 1 }
      expect(ToRadio.heartbeat(), b([0x3A, 0x02, 0x08, 0x01]));
      final pkt = ToRadio.packet(
        MeshPacketPb(
          to: meshBroadcast,
          id: 0x01020304,
          hopLimit: 3,
          decoded: MeshData(portnum: PortNum.privateApp, payload: b([0xAB])),
        ),
      );
      expect(
        pkt,
        b([
          0x0A, 20, // ToRadio.packet, len 20
          0x15, 0xFF, 0xFF, 0xFF, 0xFF, // to (fixed32 field 2)
          0x22, 0x06, 0x08, 0x80, 0x02, 0x12, 0x01, 0xAB, // decoded Data
          0x35, 0x04, 0x03, 0x02, 0x01, // id (fixed32 field 6)
          0x48, 0x03, // hop_limit 3
        ]),
      );
    });

    test('MeshPacket round trip keeps every field we use', () {
      final p = MeshPacketPb(
        from: 0x11223344,
        to: 0x55667788,
        channel: 1,
        id: 9,
        hopLimit: 4,
        wantAck: true,
        priority: MeshPacketPb.priorityReliable,
        decoded: MeshData(portnum: 256, payload: b([1, 2, 3])),
      );
      final d = MeshPacketPb.decode(p.encode());
      expect(d.from, 0x11223344);
      expect(d.to, 0x55667788);
      expect(d.channel, 1);
      expect(d.id, 9);
      expect(d.hopLimit, 4);
      expect(d.wantAck, isTrue);
      expect(d.priority, 70);
      expect(d.decoded!.portnum, 256);
      expect(d.decoded!.payload, b([1, 2, 3]));
    });

    test('FromRadio: packet with SNR float, negative RSSI and hops', () {
      final m = FromRadio.tryDecode(packetFrom(0xABCD, [7, 8]))!;
      final p = m.packet!;
      expect(p.from, 0xABCD);
      expect(p.rxSnr, 6.25);
      expect(p.rxRssi, -97);
      expect(p.hopsAway, 2); // hop_start 3, hop_limit 1
      expect(p.decoded!.payload, b([7, 8]));
    });

    test('decodes FromRadio bytes made by the official meshtastic python '
        'protobufs', () {
      // mesh_pb2.FromRadio(packet=MeshPacket(from=0xABCD, to=0xFFFFFFFF,
      // rx_snr=6.25, rx_rssi=-97, hop_limit=1, hop_start=3, id=77,
      // decoded=Data(portnum=PRIVATE_APP, payload=b'\x07\x08')))
      const hex =
          '122c0dcdab000015ffffffff220708800212020708354d000000450000c840'
          '4801609fffffffffffffffff017803';
      final bytes = Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
      final p = FromRadio.tryDecode(bytes)!.packet!;
      expect(p.from, 0xABCD);
      expect(p.to, meshBroadcast);
      expect(p.id, 77);
      expect(p.rxSnr, 6.25);
      expect(p.rxRssi, -97);
      expect(p.hopsAway, 2);
      expect(p.decoded!.portnum, PortNum.privateApp);
      expect(p.decoded!.payload, b([7, 8]));
    });

    test('unknown fields (newer firmware) are skipped', () {
      final w = PbWriter()
        ..uint(99, 5)
        ..bytes(98, [1, 2, 3])
        ..fixed32(97, 1)
        ..uint(7, 42);
      expect(FromRadio.tryDecode(w.toBytes())!.configCompleteId, 42);
    });

    test('BLE UUIDs match the Meshtastic client API docs', () {
      expect(MeshtasticUuids.service, '6ba1b218-15a8-461f-9fa8-5dcae273eafd');
      expect(MeshtasticUuids.toRadio, 'f75c76d2-129e-4dad-a1dd-7866124401e7');
      expect(MeshtasticUuids.fromRadio, '2c55e69e-4993-11ed-b878-0242ac120002');
      expect(MeshtasticUuids.fromNum, 'ed9da18c-a800-4f66-a670-aa7547e34453');
      expect(PortNum.privateApp, 256);
    });
  });

  group('MeshtasticSession', () {
    test(
      'want_config handshake, node DB, battery, settings, warnings',
      () async {
        final wire = FakeRadioWire()
          ..onWantConfig = (nonce) => [
            myInfo(0x1000),
            nodeInfo(0x1000, 'Base camp', 'BASE', battery: 87),
            nodeInfo(0x2000, 'Hiker 1', 'H1', battery: 55),
            nodeInfo(0x3000, 'Hiker 2', 'H2'),
            loraConfig(region: 0, hop: 5),
            primaryChannel(),
            configComplete(nonce),
          ];
        final s = MeshtasticSession(wire, random: Random(3));
        await s.start(timeout: const Duration(seconds: 1));
        expect(s.configured, isTrue);
        expect(s.myNodeNum, 0x1000);
        expect(s.nodeCount, 2);
        expect(s.battery, 87);
        expect(s.hopLimit, 5);
        expect(s.primaryUsesDefaultKey, isTrue);
        final warn = radioWarnings(s);
        expect(warn.any((w) => w.contains('Region is not set')), isTrue);
        expect(warn.any((w) => w.contains('public default channel')), isTrue);
        final lines = radioDetailLines(s, appPhones: 1);
        expect(lines, contains('Battery: 87%'));
        expect(lines, contains('Meshtastic nodes heard: 2'));
        await s.close();
      },
    );

    test('FromNum notify -> read until empty -> private app packets', () async {
      final wire = FakeRadioWire()
        ..onWantConfig = (n) => [myInfo(0x1000), configComplete(n)];
      final s = MeshtasticSession(wire, random: Random(4));
      await s.start(timeout: const Duration(seconds: 1));
      final got = <MeshPacketPb>[];
      s.packets.listen(got.add);
      wire.queue.add(packetFrom(0x2000, [1, 2, 3]));
      wire.push(packetFrom(0x3000, [4], snr: -3.5, rssi: -120));
      await Future<void>.delayed(Duration.zero);
      await s.drain();
      expect(got.map((p) => p.from), [0x2000, 0x3000]);
      expect(s.lastSignal!.snr, -3.5);
      expect(s.lastSignal!.rssi, -120);
      expect(wire.queue, isEmpty);
      await s.close();
    });

    test(
      'send writes a ToRadio packet on PRIVATE_APP with the hop limit',
      () async {
        final wire = FakeRadioWire()
          ..onWantConfig = (n) => [loraConfig(hop: 6), configComplete(n)];
        final s = MeshtasticSession(wire, random: Random(5));
        await s.start(timeout: const Duration(seconds: 1));
        await s.send(b([9, 9]), to: 0x2000, wantAck: true);
        final last = wire.written.last;
        final pkt = MeshPacketPb.decode(pbDecode(last).single.asBytes);
        expect(pkt.to, 0x2000);
        expect(pkt.hopLimit, 6);
        expect(pkt.wantAck, isTrue);
        expect(pkt.decoded!.portnum, PortNum.privateApp);
        expect(
          () => s.send(Uint8List(meshDataPayloadLen + 1)),
          throwsArgumentError,
        );
        await s.close();
      },
    );

    test('rebooted radio is asked for its configuration again', () async {
      final wire = FakeRadioWire()..onWantConfig = (n) => [configComplete(n)];
      final s = MeshtasticSession(wire, random: Random(6));
      await s.start(timeout: const Duration(seconds: 1));
      final before = wire.written.length;
      s.handle(FromRadio(rebooted: true));
      await Future<void>.delayed(Duration.zero);
      expect(wire.written.length, before + 1);
      expect(pbDecode(wire.written.last).single.number, 3);
      await s.close();
    });
  });
}
