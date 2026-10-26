import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/track.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';

const here = GeoPoint(45.52345, -122.67621);

T roundTrip<T extends TripMsg>(T m) {
  final d = TripMsg.tryDecode(m.encode());
  expect(d, isA<T>());
  expect(d!.id, m.id);
  return d as T;
}

void main() {
  group('Trip packet codec', () {
    test('location: 14 bytes, ~1 m precision, flags and fix age', () {
      const m = PosMsg(
        7,
        here,
        checkIn: true,
        accuracyM: 12.4,
        fixAge: Duration(seconds: 42),
      );
      expect(m.encode().length, 14);
      final d = roundTrip(m);
      expect(d.checkIn, isTrue);
      expect(d.accuracyM, 12);
      expect(d.fixAge, const Duration(seconds: 40));
      expect(distanceM(d.pos, here), lessThan(1.2));
      final live = roundTrip(const PosMsg(8, here));
      expect(live.checkIn, isFalse);
      expect(live.accuracyM, isNull);
    });

    test('SOS with and without a location, cancel flag, repeat count', () {
      const m = SosMsg(300, pos: here, repeat: 3, accuracyM: 8);
      expect(m.encode().length, 14);
      final d = roundTrip(m);
      expect(d.pos!.latE5, here.latE5);
      expect(d.repeat, 3);
      expect(d.cancel, isFalse);
      expect(d.accuracyM, 8);
      final c = roundTrip(const SosMsg(300, cancel: true));
      expect(c.cancel, isTrue);
      expect(c.pos, isNull);
      expect(const SosMsg(1).encode().length, 5);
    });

    test('SOS ack names the sender and its SOS id', () {
      final d = roundTrip(const SosAckMsg(9, origin: 0xDEADBEEF, sosId: 300));
      expect(d.origin, 0xDEADBEEF);
      expect(d.sosId, 300);
      expect(const SosAckMsg(9, origin: 1, sosId: 2).encode().length, 9);
    });

    test(
      'canned: built-ins are a code only (5 bytes), custom carries text',
      () {
        expect(const CannedMsg(1, 4).encode().length, 5);
        expect(roundTrip(const CannedMsg(1, 4)).display, 'At camp');
        expect(roundTrip(const CannedMsg(1, 3)).display, 'Need help');
        final c = roundTrip(const CannedMsg(2, 0, text: 'Lunch at the lake'));
        expect(c.display, 'Lunch at the lake');
        // Long / multi-byte text is cut on a character boundary.
        final long = roundTrip(CannedMsg(3, 0, text: '🏕️' * 30));
        expect(long.text.length, lessThan(30 * 3));
        expect(long.text.runes.every((r) => r != 0xFFFD), isTrue);
      },
    );

    test('pins and pin delete', () {
      final p = roundTrip(
        const PinMsg(
          5,
          pinId: 77,
          type: PinType.water,
          pos: here,
          label: 'Spring',
        ),
      );
      expect(p.pinId, 77);
      expect(p.type, PinType.water);
      expect(p.label, 'Spring');
      expect(distanceM(p.pos, here), lessThan(1.2));
      expect(roundTrip(const PinDeleteMsg(6, pinId: 77)).pinId, 77);
    });

    test('trail chunk: delta coded with times, summary without', () {
      final t0 = 1790000000;
      final pts = [
        for (var i = 0; i < 60; i++)
          TrackPt(
            GeoPoint(here.lat + i * 0.0001, here.lng - i * 0.00007),
            t0 + i * 7,
          ),
      ];
      final m = TrackMsg(1, trackId: 4, index: 0, count: 1, points: pts);
      final bytes = m.encode();
      expect(bytes.length, lessThanOrEqualTo(10 + 12 + 59 * 6));
      final d = roundTrip(m);
      expect(d.points.length, 60);
      for (var i = 0; i < 60; i++) {
        expect(d.points[i].pos.latE5, pts[i].pos.latE5);
        expect(d.points[i].pos.lngE5, pts[i].pos.lngE5);
        expect(d.points[i].t, pts[i].t);
      }
      final s = roundTrip(
        TrackMsg(
          2,
          trackId: 4,
          index: 0,
          count: 1,
          summary: true,
          points: pts.take(16).toList(),
        ),
      );
      expect(s.summary, isTrue);
      expect(s.points.first.t, isNull);
    });

    test('trail chunking splits on size and on big jumps', () {
      final pts = [
        for (var i = 0; i < 130; i++)
          TrackPt(GeoPoint(10 + i * 0.0001, 20), 1000 + i),
        const TrackPt(GeoPoint(11, 20), 2000), // 100 km jump
      ];
      final chunks = TrackMsg.chunk(pts);
      expect(chunks.map((c) => c.length), [60, 60, 10, 1]);
    });

    test('base camp wrapper keeps the original sender and age', () {
      final d = roundTrip(
        const HeldMsg(
          11,
          origin: 0x2222,
          age: Duration(minutes: 42),
          inner: CannedMsg(3, 2),
        ),
      );
      expect(d.origin, 0x2222);
      expect(d.age, const Duration(minutes: 42));
      expect((d.inner as CannedMsg).display, 'Stopping');
    });

    test('rejects garbage, other versions, truncation and nesting', () {
      expect(TripMsg.tryDecode([]), isNull);
      expect(TripMsg.tryDecode([0x21, 0, 1]), isNull); // version 2
      expect(TripMsg.tryDecode([0x1F, 0, 1]), isNull); // unknown kind
      final ok = const PosMsg(1, here).encode();
      expect(TripMsg.tryDecode(ok.sublist(0, ok.length - 3)), isNull);
      // Coordinates out of range.
      final bad = Uint8List.fromList(ok);
      ByteData.sublistView(bad).setInt32(4, 95 * 100000);
      expect(TripMsg.tryDecode(bad), isNull);
      // Held inside held is refused.
      final inner = const HeldMsg(
        1,
        origin: 2,
        age: Duration.zero,
        inner: CannedMsg(1, 1),
      );
      final outer = HeldMsg(2, origin: 3, age: Duration.zero, inner: inner);
      expect(TripMsg.tryDecode(outer.encode()), isNull);
    });

    test(
      'LoRa friendly: SOS, check-in, canned, pin fit a sealed radio packet',
      () async {
        final key = await ChannelKey.derive(3, 'secret');
        for (final m in <TripMsg>[
          const SosMsg(1, pos: here, accuracyM: 5),
          const PosMsg(2, here, checkIn: true, accuracyM: 5),
          const CannedMsg(
            3,
            0,
            text: 'Forty-eight characters of custom text here......',
          ),
          const PinMsg(
            4,
            pinId: 1,
            type: PinType.camp,
            pos: here,
            label: 'Thirty-two character pin label!!',
          ),
          trackSummary(
            Track(
              1,
              points: [
                for (var i = 0; i < 400; i++)
                  TrackPt(
                    GeoPoint(here.lat + i * 1e-4, here.lng + (i % 7) * 1e-4),
                    i,
                  ),
              ],
            ),
            9,
          ),
        ]) {
          final f = Frame(
            type: FrameType.trip,
            senderId: 1,
            channel: key.tag,
            seq: 1,
            payload: m.encode(),
          );
          expect(
            key.seal(f).length,
            lessThanOrEqualTo(loraPayloadBudget),
            reason: '$m',
          );
        }
      },
    );

    test('trip frames survive the frame codec and channel sealing', () async {
      final f = Frame(
        type: FrameType.trip,
        senderId: 0xABCD,
        channel: 1,
        seq: 9,
        payload: const CannedMsg(1, 5).encode(),
      );
      final d = Frame.tryDecode(f.encode())!;
      expect(d.type, FrameType.trip);
      final key = await ChannelKey.derive(2, 'pw');
      final opened = key.open(Frame.tryDecode(key.seal(f))!)!;
      expect(opened.type, FrameType.trip);
      expect((TripMsg.tryDecode(opened.payload) as CannedMsg).display, 'OK');
      expect(featureLevel, greaterThanOrEqualTo(tripFeature));
    });
  });
}
