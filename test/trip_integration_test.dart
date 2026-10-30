import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/sos.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/track.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_route.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/trip/weather.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart';

const me = 0x1111, bob = 0x2222, carol = 0x3333;
const here = GeoPoint(45.5, -122.6);

class FakeRadio implements RadioLink {
  final sent = <({Uint8List payload, int to, int priority})>[];
  final _packets = StreamController<MeshPacketPb>.broadcast(sync: true);
  final _ready = StreamController<bool>.broadcast(sync: true);
  @override
  bool get ready => true;
  @override
  Stream<bool> get readyChanges => _ready.stream;
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;
  @override
  int? queueFree;
  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
    int hopLimit = 0,
  }) async => sent.add((payload: payload, to: to, priority: priority));
  void hear(Uint8List frame, int node) => _packets.add(
    MeshPacketPb(
      from: node,
      to: meshBroadcast,
      rxSnr: 3,
      rxRssi: -110,
      hopLimit: 3,
      hopStart: 3,
      decoded: MeshData(portnum: PortNum.privateApp, payload: frame),
    ),
  );
  List<Frame> get trips => [
    for (final s in sent)
      if (Frame.tryDecode(s.payload)?.type == FrameType.trip)
        Frame.tryDecode(s.payload)!,
  ];
}

Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Frame hello(int from, int seq) => Frame.control(
  senderId: from,
  channel: 1,
  seq: seq,
  message: const ControlMessage(ControlKind.hello, name: 'x'),
);

class FakeHost implements TripHost {
  FakeHost(this.localId);
  @override
  final int localId;
  @override
  int scope = 1;
  @override
  bool privateScope = false;
  final sent = <({TripMsg msg, TripRoute route})>[];
  final inbound = StreamController<InboundTrip>.broadcast(sync: true);
  List<TripPeer> peers = [];
  final alarms = <IncomingSos>[];
  final notes = <String>[];
  @override
  String nameOf(int id) => 'P${id.toRadixString(16)}';
  @override
  bool get powerSaver => false;
  @override
  Future<Set<int>> sendTrip(Uint8List payload, TripRoute route) async {
    sent.add((msg: TripMsg.tryDecode(payload)!, route: route));
    return {};
  }

  @override
  Stream<InboundTrip> get trips => inbound.stream;
  @override
  List<TripPeer> channelPeers() => peers;
  @override
  Future<void> saveTripSettings() async {}
  @override
  Future<bool> startLocation(
    Duration interval, {
    bool highAccuracy = true,
  }) async {
    locationStarts.add((interval: interval, highAccuracy: highAccuracy));
    return true;
  }

  final locationStarts = <({Duration interval, bool highAccuracy})>[];
  @override
  Future<void> stopLocation() async {}
  @override
  Future<Fix?> locateOnce() async => null;
  @override
  Future<void> backgroundLocation(bool on) async {}
  @override
  void showSosAlarm(IncomingSos s, String text) => alarms.add(s);
  @override
  void stopSosAlarm(IncomingSos s) {}
  @override
  void notify(String title, String text) => notes.add('$title: $text');
  @override
  void notice(String text) => notes.add(text);
  @override
  Future<bool> shareFile(String path, String mime, String title) async => true;
}

InboundTrip trip(
  int from,
  TripMsg m, {
  int packetId = 0,
  TransportKind via = TransportKind.ble,
  int channel = 1,
}) => InboundTrip(from, channel, m.encode(), via, packetId: packetId);

void main() {
  group('TransportManager.sendTrip routing', () {
    late FakeTransport lan, ble;
    late FakeRadio radio;
    late TransportManager m;
    late FakeClock clock;

    setUp(() async {
      clock = FakeClock();
      lan = FakeTransport(TransportKind.lan);
      ble = FakeTransport(TransportKind.ble);
      radio = FakeRadio();
      final lora = LoraTransport(
        radio: radio,
        clock: clock.call,
        limiter: LoraRateLimiter(burst: 100, clock: clock.call),
        pumpInterval: const Duration(hours: 1),
      );
      m = TransportManager(
        transports: [lan, ble, lora],
        localNodeId: me,
        localName: 'Me',
        clock: clock.call,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      lan.sent.clear();
      ble.sent.clear();
      radio.sent.clear();
    });
    tearDown(() => m.dispose());

    test('fast peers get it directly; LoRa only for radio-only phones, and only if allowed', () async {
      ble.deliver(hello(bob, 1));
      radio.hear(hello(carol, 1).encode(), 0xC0C0);
      await flush();
      final live = const PosMsg(1, here).encode();
      await m.sendTrip(live);
      await flush();
      expect(ble.sent.single.frame.type, FrameType.trip);
      expect(ble.sent.single.peerIds, {bob});
      expect(radio.trips, isEmpty, reason: 'live positions never use LoRa');
      await m.sendTrip(
        const PosMsg(2, here, checkIn: true).encode(),
        radio: true,
      );
      await flush();
      expect(radio.trips.length, 1);
      expect(radio.trips.single.senderId, me);
    });

    test('SOS flood: every fast transport to everyone + radio broadcast at top priority', () async {
      await m.sendTrip(
        const SosMsg(5, pos: here).encode(),
        flood: true,
        radio: true,
      );
      await flush();
      expect(lan.sent.single.peerIds, isNull);
      expect(ble.sent.single.peerIds, isNull);
      expect(radio.trips.length, 1);
      expect(radio.sent.single.to, meshBroadcast);
      expect(radio.sent.single.priority, MeshPacketPb.priorityHigh);
      expect(
        TransportManager.tripRadioPriority(const SosMsg(5).encode()),
        LoraPriority.sos,
      );
      expect(
        TransportManager.tripRadioPriority(const CannedMsg(1, 1).encode()),
        LoraPriority.normal,
      );
      expect(
        TransportManager.tripRadioPriority(const PosMsg(1, here).encode()),
        LoraPriority.bulk,
      );
      expect(
        TransportManager.tripRadioPriority(
          const HeldMsg(
            1,
            origin: 2,
            age: Duration.zero,
            inner: SosMsg(3),
          ).encode(),
        ),
        LoraPriority.sos,
      );
    });

    test('SOS jumps the radio queue ahead of a waiting voice clip', () async {
      final lora = m.radio!;
      final q = LoraTransport(
        radio: radio,
        clock: clock.call,
        limiter: LoraRateLimiter(burst: 1, clock: clock.call),
        pumpInterval: const Duration(hours: 1),
      );
      await q.start(localNodeId: me, channel: 1);
      radio.sent.clear();
      q.sendRadio(
        Uint8List.fromList(List.filled(150, 1)),
        priority: LoraPriority.bulk,
      );
      q.sendRadio(
        Uint8List.fromList(List.filled(20, 2)),
        priority: LoraPriority.bulk,
      );
      q.sendRadio(
        Uint8List.fromList(List.filled(20, 3)),
        priority: LoraPriority.sos,
      );
      await flush();
      expect(radio.sent.length, 1, reason: 'limiter still applies');
      clock.advance(const Duration(seconds: 8));
      await q.pump();
      expect(radio.sent[1].payload.first, 3);
      await q.dispose();
      expect(lora, isNotNull);
    });

    test('received trip frames come out of the trips stream with hops and packet id', () async {
      final got = <InboundTrip>[];
      m.trips.listen(got.add);
      final f = Frame(
        type: FrameType.trip,
        senderId: bob,
        channel: 1,
        seq: 3,
        payload: const CannedMsg(1, 2).encode(),
      );
      ble.deliver(f);
      ble.deliver(f); // duplicate copy
      await flush();
      expect(got.length, 1);
      expect(got.single.peerId, bob);
      expect(got.single.transport, TransportKind.ble);
      expect(got.single.packetId, isNot(0));
      expect(
        (TripMsg.tryDecode(got.single.payload) as CannedMsg).display,
        'Stopping',
      );
    });
  });

  group('TripController', () {
    late Directory dir;
    late FakeClock clock;
    late FakeHost host;
    late TripController t;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trip');
      clock = FakeClock();
      host = FakeHost(me);
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: dir,
        userAgent: 'test',
        clock: clock.call,
      );
      t.tiles.online = false;
      await t.start();
    });
    tearDown(() async {
      t.dispose();
      await dir.delete(recursive: true);
    });

    void seconds(int n) {
      for (var i = 0; i < n; i++) {
        clock.advance(const Duration(seconds: 1));
        t.tick();
      }
    }

    test(
      'base camp holds for the absent and hands over when they return',
      () async {
        await t.update((s) => s.baseCamp = true);
        host.peers = [
          TripPeer(bob, lastHeard: clock.now, reachable: true),
          TripPeer(carol, lastHeard: clock.now, reachable: true),
        ];
        seconds(5);
        // Carol walks out of range.
        host.peers = [
          TripPeer(bob, lastHeard: clock.now, reachable: true),
          TripPeer(
            carol,
            lastHeard: clock.now.subtract(const Duration(minutes: 1)),
          ),
        ];
        seconds(5);
        host.inbound.add(trip(bob, const CannedMsg(9, 4), packetId: 77));
        host.inbound.add(
          trip(bob, const CannedMsg(9, 4), packetId: 78),
        ); // copy
        expect(t.store.items.length, 1);
        host.sent.clear();
        clock.advance(const Duration(minutes: 40));
        host.peers = [TripPeer(carol, lastHeard: clock.now, reachable: true)];
        t.onPeersChanged();
        final h = host.sent.single;
        expect(h.route.to, carol);
        expect(
          h.route.radio,
          isTrue,
          reason: 'may go by LoRa if that is all that reaches',
        );
        final held = h.msg as HeldMsg;
        expect(held.origin, bob);
        expect(held.age.inMinutes, greaterThanOrEqualTo(40));
        expect(t.store.items, isEmpty);
      },
    );

    test('a returning hiker unwraps base camp deliveries (once)', () async {
      host.inbound.add(
        trip(
          carol,
          const HeldMsg(
            1,
            origin: bob,
            age: Duration(minutes: 30),
            inner: CannedMsg(4, 3),
          ),
        ),
      );
      host.inbound.add(
        trip(
          carol,
          const HeldMsg(
            2,
            origin: bob,
            age: Duration(minutes: 30),
            inner: CannedMsg(4, 3),
          ),
        ),
      );
      final msgs = t.feed.where((e) => e.kind == 'canned').toList();
      expect(msgs.length, 1);
      expect(msgs.single.origin, bob);
      expect(msgs.single.text, contains('Need help'));
      expect(msgs.single.text, contains('base camp'));
    });

    test('SOS in: alarm once, ack sent over every path', () async {
      host.inbound.add(trip(bob, const SosMsg(3, pos: here)));
      host.inbound.add(trip(bob, const SosMsg(3, pos: here, repeat: 1)));
      expect(host.alarms.length, 1);
      t.acknowledgeSos(t.sos.incoming.single);
      final ack = host.sent.last;
      expect(ack.msg, isA<SosAckMsg>());
      expect(ack.route.flood && ack.route.radio, isTrue);
      expect(t.people[bob]!.pos, here);
    });

    test(
      'SOS from another public channel still alarms; other traffic does not',
      () async {
        host.inbound.add(trip(bob, const SosMsg(4, pos: here), channel: 5));
        host.inbound.add(trip(bob, const CannedMsg(5, 1), channel: 5));
        expect(host.alarms.length, 1);
        expect(t.feed.where((e) => e.kind == 'canned'), isEmpty);
        // From a private channel we are not on: ignored.
        host.inbound.add(trip(carol, const SosMsg(4), channel: 0x10005));
        expect(host.alarms.length, 1);
      },
    );

    test('my SOS: sent flooded with radio, acks show up, cancel', () async {
      t.onFix(Fix(here, clock.now, accuracyM: 5));
      await t.startSos();
      final first = host.sent.last;
      expect(first.msg, isA<SosMsg>());
      expect((first.msg as SosMsg).pos, here);
      expect(first.route.flood && first.route.radio, isTrue);
      host.inbound.add(
        trip(bob, SosAckMsg(1, origin: me, sosId: first.msg.id)),
      );
      expect(t.sos.active!.acks.keys, [bob]);
      t.cancelSos();
      expect((host.sent.last.msg as SosMsg).cancel, isTrue);
    });

    test(
      'trip mode: live positions on fast links, check-ins also by radio',
      () async {
        await t.update((s) {
          s.tripMode = true;
          s.checkInMinutes = 5;
        });
        t.onFix(Fix(here, clock.now));
        seconds(1);
        final pos = host.sent.map((s) => s.msg).whereType<PosMsg>().toList();
        expect(pos.where((p) => !p.checkIn), isNotEmpty);
        expect(pos.where((p) => p.checkIn).length, 1);
        for (final s in host.sent.where((s) => s.msg is PosMsg)) {
          expect(s.route.radio, (s.msg as PosMsg).checkIn);
        }
        host.sent.clear();
        seconds(299);
        expect(
          host.sent
              .map((s) => s.msg)
              .whereType<PosMsg>()
              .where((p) => p.checkIn),
          isEmpty,
        );
        seconds(1);
        expect(
          host.sent
              .map((s) => s.msg)
              .whereType<PosMsg>()
              .where((p) => p.checkIn)
              .length,
          1,
        );
      },
    );

    test('lost contact through the controller', () async {
      await t.update((s) {
        s.tripMode = true;
        s.lostContactMinutes = 20;
      });
      host.inbound.add(trip(bob, const PosMsg(1, here, checkIn: true)));
      seconds(20 * 60);
      expect(t.lost.lost.single.id, bob);
      expect(t.lost.lost.single.lastPos, here);
      expect(host.notes.any((n) => n.startsWith('Lost contact with')), isTrue);
    });

    test('pins and shared trails from others', () async {
      host.inbound.add(
        trip(
          bob,
          const PinMsg(
            1,
            pinId: 4,
            type: PinType.camp,
            pos: here,
            label: 'Camp 1',
          ),
        ),
      );
      expect(t.pins.single.title, 'Camp 1');
      host.inbound.add(trip(bob, const PinDeleteMsg(2, pinId: 4)));
      expect(t.pins, isEmpty);
      final tr = Track(
        7,
        points: [
          for (var i = 0; i < 90; i++)
            TrackPt(GeoPoint(45 + i * 1e-4, -122), 1000 + i),
        ],
      );
      final parts = trackMessages(tr, () => 50);
      expect(parts.length, 2);
      var id = 10;
      for (final p in parts) {
        host.inbound.add(
          trip(
            bob,
            TrackMsg(
              id++,
              trackId: p.trackId,
              index: p.index,
              count: p.count,
              points: p.points,
            ),
          ),
        );
      }
      expect(t.sharedTracks['$bob:7']!.points.length, 90);
    });

    test(
      'sharing a trail: full parts on fast links, one thin summary by radio',
      () async {
        t.startTrack();
        for (var i = 0; i < 200; i++) {
          clock.advance(const Duration(seconds: 5));
          t.onFix(
            Fix(GeoPoint(45 + i * 2e-4, -122 + (i % 5) * 1e-4), clock.now),
          );
        }
        final track = (await t.stopTrack())!;
        expect(track.points.length, 200);
        host.sent.clear();
        t.shareTrack(track);
        final fast = host.sent
            .where((s) => s.route.fast && !s.route.radio)
            .toList();
        final radio = host.sent.where((s) => s.route.radio).toList();
        expect(fast.length, 4);
        expect(radio.single.route.fast, isFalse);
        final sum = radio.single.msg as TrackMsg;
        expect(sum.summary, isTrue);
        expect(sum.points.length, lessThanOrEqualTo(16));
        expect(sum.encode().length, lessThan(100));
      },
    );
  });

  group('trails and GPX', () {
    test('recorder skips bad fixes and tiny moves, backs off when still', () {
      final r = TrackRecorder()..start(1);
      final t0 = DateTime(2026, 10, 26, 9);
      expect(r.add(here, t0), isTrue);
      expect(
        r.add(
          const GeoPoint(45.50003, -122.6),
          t0.add(const Duration(seconds: 5)),
        ),
        isFalse,
      );
      expect(
        r.add(
          const GeoPoint(45.501, -122.6),
          t0.add(const Duration(seconds: 10)),
          accuracyM: 80,
        ),
        isFalse,
      );
      expect(
        r.add(
          const GeoPoint(45.501, -122.6),
          t0.add(const Duration(seconds: 15)),
        ),
        isTrue,
      );
      expect(
        r.interval(t0.add(const Duration(seconds: 20))),
        const Duration(seconds: 5),
      );
      expect(
        r.interval(t0.add(const Duration(minutes: 3))),
        const Duration(seconds: 15),
      );
      expect(
        r.interval(t0.add(const Duration(minutes: 30))),
        const Duration(seconds: 60),
      );
      expect(
        r.interval(t0.add(const Duration(seconds: 20)), saver: true),
        const Duration(seconds: 20),
      );
    });

    test('GPX 1.1 with track points, times, waypoints and escaping', () {
      final gpx = toGpx(
        'Ridge <loop> & back',
        [
          const TrackPt(here, 1790000000),
          const TrackPt(GeoPoint(45.501, -122.601), 1790000060),
        ],
        waypoints: [(pos: here, name: 'Camp "A"', type: 'Camp')],
      );
      expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(gpx, contains('<gpx version="1.1"'));
      expect(gpx, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect(gpx, contains('<name>Ridge &lt;loop&gt; &amp; back</name>'));
      expect(RegExp('<trkpt ').allMatches(gpx).length, 2);
      expect(
        gpx,
        contains('<trkpt lat="45.500000" lon="-122.600000"><time>2026-09-21T'),
      );
      expect(gpx, contains('Z</time>'));
      expect(
        gpx,
        contains(
          '<wpt lat="45.500000" lon="-122.600000"><name>Camp &quot;A&quot;</name>',
        ),
      );
      expect(gpx.trim(), endsWith('</gpx>'));
      expect(
        RegExp('<trkseg>').allMatches(gpx).length,
        RegExp('</trkseg>').allMatches(gpx).length,
      );
    });

    test('backtrack: nearest trail point and distance back along it', () {
      final pts = [
        for (var i = 0; i <= 10; i++) TrackPt(GeoPoint(45 + i * 0.001, -122)),
      ];
      final b = backtrack(pts, const GeoPoint(45.0051, -121.999))!;
      expect(b.index, 5);
      expect(b.backM, closeTo(5 * 111.2 + b.toTrailM, 2));
      expect(backtrack(const [], here), isNull);
    });

    test('tracks survive save/load', () {
      final t = Track(
        3,
        name: 'A',
        points: [const TrackPt(here, 5), const TrackPt(GeoPoint(1, 2))],
      );
      final back = decodeTracks(encodeTracks([t])).single;
      expect(back.name, 'A');
      expect(back.points.length, 2);
      expect(back.points.last.t, isNull);
    });
  });

  group('weather and map tiles', () {
    test('Open-Meteo forecast parses and keeps its age', () {
      const body =
          '''{"daily":{"time":[1792998000,1793084400],"weather_code":[61,0],
        "temperature_2m_max":[58.1,61.0],"temperature_2m_min":[44.2,40.0],
        "precipitation_probability_max":[80,5],"wind_speed_10m_max":[12.3,4.0],
        "sunrise":[1793025600,1793112060],"sunset":[1793063400,1793149740]},
        "hourly":{"time":[1792998000,1793001600],"temperature_2m":[50.0,49.5],
        "weather_code":[3,61],"precipitation_probability":[20,60],"wind_speed_10m":[5,6]}}''';
      final f = Forecast.parse(
        body,
        at: DateTime(2026, 10, 26, 8),
        place: here,
        imperial: true,
      )!;
      expect(f.days.length, 2);
      expect(f.days.first.tMax, 58.1);
      expect(f.days.first.precipProb, 80);
      expect(weatherText(f.days.first.code).$1, 'Rain');
      expect(f.days.first.sunset!.isAfter(f.days.first.sunrise!), isTrue);
      expect(f.hours.length, 2);
      expect(f.tempUnit, '°F');
      expect(
        Forecast.parse('nope', at: DateTime(2026), place: here, imperial: true),
        isNull,
      );
      final u = Forecast.url(here);
      expect(u.host, 'api.open-meteo.com');
      expect(u.queryParameters['temperature_unit'], 'fahrenheit');
    });

    test('tile maths and download size limits', () {
      expect(tileX(-180, 3), 0);
      expect(tileX(179.9, 3), 7);
      expect(tileY(0, 1), 1);
      expect(tileY(85, 2), 0);
      // Portland at z13.
      expect(tileX(-122.6765, 13), 1304);
      expect(tileY(45.5231, 13), 2929);
      const b = GeoBounds(45.50, -122.70, 45.55, -122.60);
      final n = countTiles(b, 12, 15);
      expect(n, tilesIn(b, 12, 15).length);
      final cache = TileCache(
        Directory.systemTemp,
        userAgent: 'test',
        maxDownloadTiles: 10,
      );
      expect(
        cache.estimate(MapSource.topo, b, 12, 15).bytes,
        n * MapSource.topo.avgTileBytes,
      );
      expect(
        () => cache.download(MapSource.osm, b, 12, 13, name: 'x'),
        throwsA(isA<StateError>()),
        reason: 'OSM forbids offline downloads',
      );
      expect(
        () => cache.download(MapSource.topo, b, 12, 15, name: 'x'),
        throwsA(isA<StateError>()),
        reason: 'over the tile limit',
      );
      expect(
        MapSource.topo.urlFor(13, 1304, 2929),
        'https://a.tile.opentopomap.org/13/1304/2929.png',
      );
      final r = OfflineRegion(
        name: 'a',
        sourceId: 'topo',
        bounds: b,
        minZoom: 12,
        maxZoom: 15,
        tiles: n,
        bytes: 1,
        at: DateTime(2026),
      );
      expect(r.covers('topo', 13, 1304, 2929), isTrue);
      expect(r.covers('osm', 13, 1304, 2929), isFalse);
      expect(r.covers('topo', 16, 1304, 2929), isFalse);
      expect(OfflineRegion.fromJson(r.toJson())!.maxZoom, 15);
    });

    test(
      'offline: cached tiles are served, missing ones are not fetched',
      () async {
        final dir = await Directory.systemTemp.createTemp('tiles');
        final cache = TileCache(dir, userAgent: 'test')..online = false;
        final f = File('${dir.path}/topo/13/1/2.png');
        await f.parent.create(recursive: true);
        await f.writeAsBytes([1, 2, 3]);
        expect(await cache.get(MapSource.topo, 13, 1, 2), [1, 2, 3]);
        expect(await cache.get(MapSource.topo, 13, 1, 3), isNull);
        expect(await cache.sizeOnDisk(), 3);
        await dir.delete(recursive: true);
      },
    );

    test('trip settings round trip', () {
      final s = TripSettings(
        tripMode: true,
        checkInMinutes: 10,
        canned: ['Hi'],
        baseCamp: true,
        imperial: false,
      );
      final d = TripSettings.decode(s.encode());
      expect(d.tripMode, isTrue);
      expect(d.checkInMinutes, 10);
      expect(d.canned, ['Hi']);
      expect(d.baseCamp, isTrue);
      expect(d.imperial, isFalse);
      expect(TripSettings.decode('garbage').lostContactMinutes, 20);
    });
  });
}
