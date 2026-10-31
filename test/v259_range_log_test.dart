// v2.5.9: range logging on the phone (passive log of the home radio, pings,
// no-reply points, connect / drop markers, export, storage cap, GPS).
// RANGE_LOG_PNG=path renders a screenshot; RANGE_TILES=dir real tiles.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/range_logger.dart';
import 'package:walkie_talkie/trip/range_test.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/range_test_ui.dart';

import 'home_layout_test.dart' show loadFonts;
import 'trip_integration_test.dart' as ti;

final at0 = RangeSample(
  at: DateTime.fromMillisecondsSinceEpoch(1793407474000),
  pos: const GeoPoint(45.5868416, -122.290176),
  kind: SampleKind.ok,
  snr: -7.0,
  rssi: -104,
  hops: 0,
  from: 0x0b4f84fb,
);
const home = defaultRangeHomeNode; // Skunk Ape !0b4f84fb
const homePos = GeoPoint(45.5790, -122.3000);

class FakeRadio implements RangeRadio {
  final heardC = StreamController<RadioHeard>.broadcast(sync: true);
  final repliesC = StreamController<MeshPacketPb>.broadcast(sync: true);
  final pings = <int>[];
  var _id = 100;
  @override
  bool canPing = true;
  @override
  Stream<RadioHeard> get heard => heardC.stream;
  @override
  Stream<MeshPacketPb> get replies => repliesC.stream;
  @override
  Future<int> ping(int node) async {
    pings.add(node);
    return ++_id;
  }

  int get lastId => _id;
  @override
  GeoPoint? positionOf(int node) => node == home ? homePos : null;
  @override
  String nameOf(int node) => node == home ? 'Skunk Ape' : 'Radio $node';

  void ack(
    int id, {
    int from = home,
    double snr = 5.5,
    int rssi = -80,
    int hops = 0,
  }) => heardC.add(
    RadioHeard(
      from: from,
      at: DateTime.now(),
      snr: snr,
      rssi: rssi,
      hops: hops,
      port: PortNum.routing,
      requestId: id,
    ),
  );

  void packet({
    int from = home,
    double snr = 3,
    int rssi = -90,
    int? hops = 0,
    int? port = PortNum.text,
  }) => heardC.add(
    RadioHeard(
      from: from,
      at: DateTime.now(),
      snr: snr,
      rssi: rssi,
      hops: hops,
      port: port,
    ),
  );
}

class Clock {
  DateTime now = DateTime(2026, 10, 30, 18, 0, 0);
  DateTime call() => now;
  void add(Duration d) => now = now.add(d);
}

Directory tmp(String n) {
  final d = Directory.systemTemp.createTempSync(n);
  addTearDown(() {
    try {
      d.deleteSync(recursive: true);
    } catch (_) {}
  });
  return d;
}

typedef Rig = ({
  RangeTest store,
  RangeLogger log,
  FakeRadio radio,
  Clock clock,
  List<Fix?> fixes,
});

/// A logger with a fake radio; [fix] moves with each call to [move].
Rig rig({bool plugged = false, bool on = true, Directory? dir}) {
  final clock = Clock();
  final store = RangeTest(dir == null ? null : File('${dir.path}/r.json'));
  Fix? cur = Fix(const GeoPoint(45.58, -122.29), clock.now);
  final fixes = <Fix?>[cur];
  final log = RangeLogger(
    store: store,
    fix: () => fixes.last,
    plugged: () => plugged,
    clock: clock.call,
    ackTimeout: const Duration(milliseconds: 40),
    firstPing: const Duration(hours: 1),
  );
  final radio = FakeRadio();
  addTearDown(log.dispose);
  if (on) store.logging = true;
  log.bind(radio);
  return (store: store, log: log, radio: radio, clock: clock, fixes: fixes);
}

void moveTo(Rig r, double lat, double lon) =>
    r.fixes.add(Fix(GeoPoint(lat, lon), r.clock.now));

/// One ping; [answer] true = the home radio acks it.
Future<void> ping(
  Rig r, {
  required bool answer,
  double snr = 5.5,
  int hops = 0,
}) async {
  r.clock.add(const Duration(seconds: 30));
  r.fixes.add(Fix(r.fixes.last!.pos, r.clock.now)); // keep the fix fresh
  final f = r.log.pingNow();
  if (answer) {
    await Future<void>.delayed(Duration.zero);
    r.radio.ack(r.radio.lastId, snr: snr, hops: hops);
  }
  await f;
}

void main() {
  setUpAll(loadFonts);

  group('off by default', () {
    test('nothing runs, nothing is sent, no listener', () async {
      final r = rig(on: false);
      expect(r.store.logging, isFalse);
      expect(r.radio.heardC.hasListener, isFalse);
      expect(r.radio.repliesC.hasListener, isFalse);
      expect(r.log.status, 'Off');
      await r.log.pingNow();
      expect(r.radio.pings, isEmpty);
      r.radio.packet();
      expect(r.store.samples, isEmpty);
    });

    test('switching on starts listening; off stops again', () async {
      final r = rig(on: false);
      await r.store.setLogging(true);
      expect(r.radio.heardC.hasListener, isTrue);
      r.radio.packet();
      await Future<void>.delayed(Duration.zero);
      expect(r.store.samples.length, 1);
      await r.store.setLogging(false);
      expect(r.radio.heardC.hasListener, isFalse);
      expect(r.log.status, 'Off');
    });

    test('the setting survives a restart; default home is Skunk Ape', () async {
      final d = tmp('rl');
      final a = RangeTest(File('${d.path}/r.json'));
      expect(a.homeNode, 0x0b4f84fb);
      expect(a.pingSecs, 90);
      await a.setLogging(true);
      await a.setHomeNode(0x1234abcd);
      await a.setPingSecs(75);
      final b = RangeTest(File('${d.path}/r.json'));
      await b.load();
      expect(b.logging, isTrue);
      expect(b.homeNode, 0x1234abcd);
      expect(b.pingSecs, 75);
    });
  });

  group('ping pace', () {
    test(
      '30 s plugged in; 60 to 120 s (default 90) on battery; never under 30 s',
      () async {
        var plugged = true;
        final store = RangeTest(null);
        final log = RangeLogger(
          store: store,
          fix: () => null,
          plugged: () => plugged,
        );
        addTearDown(log.dispose);
        expect(log.interval, const Duration(seconds: 30));
        plugged = false;
        expect(log.interval, const Duration(seconds: 90));
        await store.setPingSecs(60);
        expect(log.interval, const Duration(seconds: 60));
        await store.setPingSecs(120);
        expect(log.interval, const Duration(seconds: 120));
        await store.setPingSecs(5);
        expect(store.pingSecs, 60);
        await store.setPingSecs(9999);
        expect(store.pingSecs, 120);
        expect(RangeLogger.minPingGap, const Duration(seconds: 30));
        expect(log.interval >= RangeLogger.minPingGap, isTrue);
      },
    );
  });

  group('pings', () {
    test(
      'an answered ping: reply point at the phone GPS + CONNECT marker',
      () async {
        final r = rig();
        moveTo(r, 45.5868, -122.2902);
        await ping(r, answer: true, snr: 5.5, hops: 0);
        expect(r.radio.pings, [home]);
        final s = r.store.samples.single;
        expect(s.kind, SampleKind.ok);
        expect(s.pos, const GeoPoint(45.5868, -122.2902));
        expect(s.snr, 5.5);
        expect(s.rssi, -80);
        expect(s.hops, 0);
        expect(s.from, home);
        final e = r.store.events.single;
        expect(e.kind, RangeKind.connect);
        expect(e.approximate, isFalse, reason: 'phone GPS is exact');
        expect(e.pos, const GeoPoint(45.5868, -122.2902));
        expect(e.snr, 5.5);
        expect(e.distM, closeTo(distanceM(homePos, e.pos), 0.01));
        expect(r.log.status, 'Reply from Skunk Ape, SNR 5.5');
        // A second answer is not a second connect.
        await ping(r, answer: true);
        expect(r.store.events.length, 1);
        expect(r.store.samples.length, 2);
      },
    );

    test(
      'no reply: a no-reply point; a drop after a connect needs two in a row',
      () async {
        final r = rig();
        await ping(r, answer: true);
        moveTo(r, 45.60, -122.20);
        await ping(r, answer: false);
        expect(r.store.samples.last.kind, SampleKind.fail);
        expect(r.store.samples.last.pos, const GeoPoint(45.60, -122.20));
        expect(r.store.events.length, 1, reason: 'one lost ping is not a drop');
        moveTo(r, 45.61, -122.19);
        await ping(r, answer: false);
        final drop = r.store.events.last;
        expect(drop.kind, RangeKind.drop);
        expect(
          drop.pos,
          const GeoPoint(45.60, -122.20),
          reason: 'at the first miss',
        );
        expect(drop.approximate, isFalse);
        await ping(r, answer: false);
        expect(r.store.events.where((e) => e.kind == RangeKind.drop).length, 1);
        // Back in range: a new connect.
        await ping(r, answer: true);
        expect(r.store.events.last.kind, RangeKind.connect);
        expect(r.store.events.length, 3);
      },
    );

    test(
      'one miss between replies makes no markers; never connected = no drop',
      () async {
        final r = rig();
        await ping(r, answer: false);
        await ping(r, answer: false);
        await ping(r, answer: false);
        expect(r.store.events, isEmpty);
        expect(r.store.samples.every((x) => x.kind == SampleKind.fail), isTrue);
        final q = rig();
        await ping(q, answer: true);
        await ping(q, answer: false);
        await ping(q, answer: true);
        expect(q.store.events.length, 1);
      },
    );

    test('our radio reporting a failed send ends the wait at once', () async {
      final r = rig();
      final slow = RangeLogger(
        store: r.store,
        fix: () => r.fixes.last,
        plugged: () => false,
        clock: r.clock.call,
        ackTimeout: const Duration(seconds: 30),
        firstPing: const Duration(hours: 1),
      );
      addTearDown(slow.dispose);
      slow.bind(r.radio);
      r.log.bind(null);
      final sw = Stopwatch()..start();
      final f = slow.pingNow();
      await Future<void>.delayed(Duration.zero);
      final err = PbWriter()..uint(3, 5, always: true); // MAX_RETRANSMIT
      r.radio.repliesC.add(
        MeshPacketPb(
          from: 0,
          to: 0,
          decoded: MeshData(
            portnum: PortNum.routing,
            payload: err.toBytes(),
            requestId: r.radio.lastId,
          ),
        ),
      );
      await f;
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(r.store.samples.single.kind, SampleKind.fail);
    });

    test(
      'an ack from another radio or for another packet does not count',
      () async {
        final r = rig();
        r.clock.add(const Duration(seconds: 30));
        r.fixes.add(Fix(r.fixes.last!.pos, r.clock.now));
        final f = r.log.pingNow();
        await Future<void>.delayed(Duration.zero);
        r.radio.ack(r.radio.lastId, from: 0x7777);
        r.radio.ack(r.radio.lastId + 5);
        await f;
        expect(r.store.samples.where((x) => x.kind == SampleKind.ok), isEmpty);
        expect(
          r.store.samples.where((x) => x.kind == SampleKind.fail).length,
          1,
        );
      },
    );

    test(
      'no fresh GPS fix: no ping is sent (no transmit for nothing)',
      () async {
        final r = rig();
        r.clock.add(const Duration(minutes: 5)); // the fix is 5 min old
        await r.log.pingNow();
        expect(r.radio.pings, isEmpty);
        expect(r.store.samples, isEmpty);
        expect(r.log.skippedNoGps, 1);
        expect(r.log.status, contains('GPS'));
      },
    );

    test('radio busy or not ready: no ping', () async {
      final r = rig();
      r.radio.canPing = false;
      await r.log.pingNow();
      expect(r.radio.pings, isEmpty);
    });

    test(
      'changing the home radio pings the new one and starts fresh',
      () async {
        final r = rig();
        await ping(r, answer: true);
        await r.store.setHomeNode(0x1234abcd);
        r.clock.add(const Duration(seconds: 30));
        r.fixes.add(Fix(r.fixes.last!.pos, r.clock.now));
        final f = r.log.pingNow();
        await Future<void>.delayed(Duration.zero);
        r.radio.ack(r.radio.lastId, from: 0x1234abcd);
        await f;
        expect(r.radio.pings, [home, 0x1234abcd]);
        expect(r.store.events.length, 2, reason: 'a new home connects again');
      },
    );

    test('radio disconnects: stops; reconnects: listens again', () async {
      final r = rig();
      r.log.bind(null);
      expect(r.radio.heardC.hasListener, isFalse);
      expect(r.log.status, 'No radio connected');
      r.log.bind(r.radio);
      expect(r.radio.heardC.hasListener, isTrue);
    });
  });

  group('passive log', () {
    test(
      'every packet from the home radio, with the phone GPS and signal',
      () async {
        final r = rig();
        moveTo(r, 45.59, -122.28);
        r.radio.packet(snr: -3.25, rssi: -101, hops: 0, port: PortNum.position);
        final s = r.store.samples.single;
        expect(s.kind, SampleKind.heard);
        expect(s.pos, const GeoPoint(45.59, -122.28));
        expect(s.snr, -3.25);
        expect(s.rssi, -101);
        expect(s.hops, 0);
        expect(s.from, home);
      },
    );

    test(
      'other radios are ignored; at most one per 2 s; needs a fresh fix',
      () async {
        final r = rig();
        r.radio.packet(from: 0x999);
        expect(r.store.samples, isEmpty);
        r.radio.packet();
        r.radio.packet();
        expect(r.store.samples.length, 1);
        r.clock.add(const Duration(seconds: 3));
        r.fixes.add(Fix(r.fixes.last!.pos, r.clock.now));
        r.radio.packet();
        expect(r.store.samples.length, 2);
        r.clock.add(const Duration(minutes: 3)); // GPS went stale
        r.radio.packet();
        expect(r.store.samples.length, 2);
      },
    );

    test(
      'an unreadable packet (other channel) from home is still a point',
      () async {
        final r = rig();
        r.radio.packet(port: null);
        expect(r.store.samples.single.kind, SampleKind.heard);
      },
    );
  });

  group('storage, export', () {
    test('rotates at the cap, oldest first, and reloads trimmed', () async {
      final d = tmp('rl');
      const cap = 100; // the app keeps 5000 with the same rules
      final s = RangeTest(File('${d.path}/r.json'), maxSamples: cap);
      RangeSample at(int i) => RangeSample(
        at: DateTime.fromMillisecondsSinceEpoch(1793400000000 + i * 1000),
        pos: GeoPoint(45.5 + i * 1e-6, -122.2),
        kind: SampleKind.heard,
        snr: 1,
        rssi: -90,
        hops: 0,
        from: home,
      );
      for (var i = 0; i < cap + 30; i++) {
        await s.addSample(at(i));
      }
      expect(s.samples.length, cap);
      expect(
        s.samples.first.at.millisecondsSinceEpoch,
        1793400000000 + 30 * 1000,
      );
      final lines = File('${d.path}/range_samples.jsonl').readAsLinesSync();
      expect(
        lines.length,
        lessThanOrEqualTo(cap + 5),
        reason: 'bounded on disk',
      );
      final t = RangeTest(File('${d.path}/r.json'), maxSamples: cap);
      await t.load();
      expect(t.samples.length, cap);
      expect(t.samples.last.at, s.samples.last.at);
      expect(t.samples.first.at, s.samples.first.at);
      // A shorter cap on the next start trims what is on disk.
      final u = RangeTest(File('${d.path}/r.json'), maxSamples: 40);
      await u.load();
      expect(u.samples.length, 40);
      expect(
        File('${d.path}/range_samples.jsonl').readAsLinesSync().length,
        40,
      );
    });

    test('the real cap is 5000 points of about 80 bytes (about 400 KB)', () {
      expect(maxRangeSamples, 5000);
      final line = '${jsonEncode(at0.toJson())}\n';
      expect(line.length, inInclusiveRange(60, 120));
      expect(line.length * maxRangeSamples, lessThan(600 * 1024));
    });

    test('clear points keeps markers; clear markers keeps points', () async {
      final r = rig(dir: tmp('rl'));
      await ping(r, answer: true);
      await ping(r, answer: false);
      expect(r.store.samples.length, 2);
      await r.store.clearSamples();
      await r.store.flush();
      expect(r.store.samples, isEmpty);
      expect(r.store.events.length, 1);
      final t = RangeTest(File('${r.store.file!.parent.path}/r.json'));
      await t.load();
      expect(t.samples, isEmpty);
      expect(t.events.length, 1);
    });

    test('CSV and JSON export: points, markers, no keys', () async {
      final r = rig();
      moveTo(r, 45.5868416, -122.290176);
      await ping(r, answer: true, snr: -7.0);
      await ping(r, answer: false);
      final csv = r.store.samplesCsv().trim().split('\n');
      expect(
        csv.first,
        'time_utc,unix_s,lat,lon,result,snr_db,rssi_dbm,hops,from',
      );
      expect(csv.length, 3);
      expect(
        csv[1],
        contains(',45.586842,-122.290176,reply,-7.0,-80,0,!0b4f84fb'),
      );
      expect(csv[2], contains(',no_reply,,,,!0b4f84fb'));
      final j = r.store.exportJson();
      expect(j, contains('"points"'));
      expect(j, contains('"events"'));
      expect(j, contains('!0b4f84fb'));
      for (final t in [r.store.samplesCsv(), j]) {
        expect(t.toLowerCase(), isNot(contains('psk')));
        expect(t.toLowerCase(), isNot(contains('key')));
      }
    });
  });

  group('the radio session', () {
    test(
      'a ping is one reliable byte to the home radio, one relay at most',
      () async {
        final w = _MiniWire();
        final s = MeshtasticSession(w);
        await s.start(timeout: const Duration(seconds: 2));
        addTearDown(s.close);
        final radio = SessionRangeRadio(s);
        expect(radio.canPing, isTrue);
        final id = await radio.ping(home);
        final p = w.sent.single;
        expect(p.to, home);
        expect(p.wantAck, isTrue);
        expect(p.hopLimit, 1);
        expect(p.id, id);
        expect(p.decoded!.portnum, PortNum.privateApp);
        expect(p.decoded!.payload.length, 1);
        expect(p.priority, MeshPacketPb.priorityReliable);
      },
    );

    test(
      'heard: every packet from another node, signal and hops, acks included',
      () async {
        final w = _MiniWire();
        final s = MeshtasticSession(w);
        await s.start(timeout: const Duration(seconds: 2));
        addTearDown(s.close);
        final got = <RadioHeard>[];
        final sub = s.heard.listen(got.add);
        addTearDown(sub.cancel);
        w.deliver(
          from: home,
          to: _MiniWire.me,
          port: PortNum.routing,
          requestId: 4242,
          snr: -7.0,
          rssi: -104,
          hopStart: 3,
          hopLimit: 3,
        );
        // Not decodable (no Data): still heard.
        w.deliver(
          from: home,
          to: meshBroadcast,
          snr: 2.5,
          rssi: -90,
          hopStart: 3,
          hopLimit: 2,
        );
        // Our own radio's packets are not "heard".
        w.deliver(from: _MiniWire.me, to: _MiniWire.me, port: PortNum.text);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(got.length, 2);
        expect(got[0].from, home);
        expect(got[0].port, PortNum.routing);
        expect(got[0].requestId, 4242);
        expect(got[0].snr, -7.0);
        expect(got[0].rssi, -104);
        expect(got[0].hops, 0);
        expect(got[1].port, isNull);
        expect(got[1].hops, 1);
      },
    );
  });

  group('trip controller and GPS', () {
    Future<(TripController, ti.FakeHost)> make() async {
      final d = tmp('trip');
      final host = ti.FakeHost(1);
      final c = TripController(
        host: host,
        settings: TripSettings(),
        dir: d,
        userAgent: 'test',
      );
      addTearDown(c.dispose);
      await c.start();
      return (c, host);
    }

    test('off: no GPS asked for by range logging', () async {
      final (c, host) = await make();
      expect(c.range.logging, isFalse);
      expect(host.locationStarts, isEmpty);
      expect(c.locationInterval, isNull);
    });

    test('on: one high-accuracy fix every 10 s, only while it is on', () async {
      final (c, host) = await make();
      await c.range.setLogging(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.locationInterval, const Duration(seconds: 10));
      expect(c.locationHighAccuracy, isTrue);
      expect(host.locationStarts.last.interval, const Duration(seconds: 10));
      await c.range.setLogging(false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.locationInterval, isNull);
    });

    test(
      'the logger uses the phone fix and the charging state of Driving mode',
      () async {
        final (c, _) = await make();
        expect(c.rangeLog.interval, const Duration(seconds: 90));
        await c.setPluggedIn(true);
        expect(c.rangeLog.interval, const Duration(seconds: 30));
        await c.setPluggedIn(false);
        expect(c.rangeLog.interval, const Duration(seconds: 90));
        final radio = FakeRadio();
        await c.range.setLogging(true);
        c.rangeLog.bind(radio);
        c.onFix(Fix(const GeoPoint(45.6, -122.3), DateTime.now()));
        radio.packet();
        expect(c.range.samples.single.pos, const GeoPoint(45.6, -122.3));
      },
    );
  });

  group('map layer and page', () {
    test(
      'points are graded by SNR; no-reply is grey with a red ring',
      () async {
        expect(HSVColor.fromColor(snrColor(5)).hue, closeTo(120, 1));
        expect(HSVColor.fromColor(snrColor(-15)).hue, closeTo(0, 1));
        final mid = HSVColor.fromColor(snrColor(-7.5)).hue;
        expect(mid, inInclusiveRange(40, 80));
        final store = RangeTest(null);
        DateTime t(int i) => DateTime(2026, 10, 30, 18, i);
        const p = GeoPoint(45.5, -122.2);
        await store.addSample(
          RangeSample(at: t(1), pos: p, kind: SampleKind.ok, snr: 5),
        );
        await store.addSample(
          RangeSample(at: t(2), pos: p, kind: SampleKind.ok, snr: -14),
        );
        await store.addSample(
          RangeSample(at: t(3), pos: p, kind: SampleKind.fail),
        );
        await store.addSample(
          RangeSample(at: t(4), pos: p, kind: SampleKind.heard, snr: -2),
        );
        final c = rangeSampleCircles(store);
        expect(c.length, 4);
        expect(c[0].color.a, closeTo(0.95, 0.01));
        expect(
          HSVColor.fromColor(c[0].color).hue,
          greaterThan(HSVColor.fromColor(c[1].color).hue),
        );
        expect(c[2].borderColor, rangeRed);
        expect(c[2].color.r, closeTo(noReplyFill.r, 0.02));
        expect(c[3].radius, lessThan(c[0].radius));
        await store.setVisible(false);
        expect(rangeSampleCircles(store), isEmpty);
        await store.setVisible(true);
        for (var i = 0; i < 20; i++) {
          await store.addSample(
            RangeSample(at: t(10), pos: p, kind: SampleKind.heard),
          );
        }
        expect(rangeSampleCircles(store, max: 5).length, 5);
      },
    );

    test('home radio ids typed by hand', () {
      expect(parseNodeId('!0b4f84fb'), 0x0b4f84fb);
      expect(parseNodeId(' 0B4F84FB '), 0x0b4f84fb);
      expect(parseNodeId('zzz'), isNull);
      expect(parseNodeId('!ffffffff'), isNull);
      expect(parseNodeId(''), isNull);
    });

    Future<(RangeTest, RangeLogger)> pageRig(WidgetTester t) async {
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final store = RangeTest(null);
      final log = RangeLogger(
        store: store,
        fix: () => null,
        plugged: () => false,
      );
      addTearDown(log.dispose);
      return (store, log);
    }

    testWidgets(
      'Range logging switch is off, turns on with one tap; settings appear',
      (t) async {
        final (store, log) = await pageRig(t);
        final shared = <String>[];
        final dir = tmp('exp');
        await t.pumpWidget(
          MaterialApp(
            home: RangeTestPage(
              range: store,
              logger: log,
              exportDir: dir,
              homeChoices: () => [(num: 0x1234abcd, name: 'Yeti')],
              share: (path, mime, title) async {
                shared.add('$mime ${path.split('/').last}');
                return true;
              },
            ),
          ),
        );
        expect(
          t.widget<SwitchListTile>(find.byKey(const Key('rangeLogging'))).value,
          isFalse,
        );
        expect(find.byKey(const Key('rangeHome')), findsNothing);
        expect(find.byKey(const Key('rangeBatteryNote')), findsNothing);
        await t.tap(find.byKey(const Key('rangeLogging')));
        await t.pumpAndSettle();
        expect(store.logging, isTrue);
        expect(find.text('Skunk Ape (!0b4f84fb)'), findsOneWidget);
        expect(find.text('Ping every 90 s (on battery)'), findsOneWidget);
        expect(
          t.widget<Text>(find.byKey(const Key('rangeBatteryNote'))).data,
          allOf(
            contains('radio transmit'),
            contains('GPS every 10 s'),
            contains('every 30 s'),
          ),
        );
        // The slider is 60..120.
        final sl = t.widget<Slider>(find.byKey(const Key('rangePing')));
        expect((sl.min, sl.max, sl.value), (60.0, 120.0, 90.0));
        // Pick another home radio.
        await t.tap(find.byKey(const Key('rangeHome')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('rangeHome-${0x1234abcd}')));
        await t.pumpAndSettle();
        expect(store.homeNode, 0x1234abcd);
        expect(find.text('Yeti (!1234abcd)'), findsOneWidget);
        // Or type one.
        await t.tap(find.byKey(const Key('rangeHome')));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const Key('rangeHomeId')), '!0b4f84fb');
        await t.tap(find.byKey(const Key('rangeHomeUse')));
        await t.pumpAndSettle();
        expect(store.homeNode, 0x0b4f84fb);

        // Export needs points.
        expect(
          t.widget<ListTile>(find.byKey(const Key('rangeExportCsv'))).enabled,
          isFalse,
        );
        await store.addSample(
          RangeSample(
            at: DateTime(2026, 10, 30, 18),
            pos: const GeoPoint(45.5, -122.2),
            kind: SampleKind.ok,
            snr: 4,
            rssi: -88,
            hops: 0,
            from: home,
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.textContaining(
            '1 points logged: 1 replies, 0 no reply, 0 heard.',
          ),
          findsOneWidget,
        );
        await t.runAsync(() async {
          await t.tap(find.byKey(const Key('rangeExportCsv')));
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await t.tap(find.byKey(const Key('rangeExportJson')));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        expect(shared.length, 2);
        expect(shared[0], startsWith('text/csv range-log-'));
        expect(shared[0], endsWith('.csv'));
        expect(shared[1], startsWith('application/json range-log-'));
        final files = dir.listSync().map((f) => f.path).toList()..sort();
        expect(
          File(files.firstWhere((f) => f.endsWith('.csv'))).readAsStringSync(),
          contains('reply,4.0,-88,0,!0b4f84fb'),
        );

        // Clear the points (with a confirm); the markers stay.
        await store.add([
          RangeEvent(
            kind: RangeKind.connect,
            at: DateTime(2026, 10, 30, 18),
            pos: const GeoPoint(45.5, -122.2),
            approximate: false,
          ),
        ]);
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('rangeClearPoints')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('rangeClearPointsYes')));
        await t.pumpAndSettle();
        expect(store.samples, isEmpty);
        expect(store.events.length, 1);
        // Off again: the settings fold away.
        await t.tap(find.byKey(const Key('rangeLogging')));
        await t.pumpAndSettle();
        expect(store.logging, isFalse);
        expect(find.byKey(const Key('rangeHome')), findsNothing);
      },
    );

    testWidgets(
      'plugged in: the page says every 30 s; slider moves the battery pace',
      (t) async {
        final store = RangeTest(null);
        await store.setLogging(true);
        t.view.physicalSize = const Size(800, 3000);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final log = RangeLogger(
          store: store,
          fix: () => null,
          plugged: () => true,
        );
        addTearDown(log.dispose);
        await t.pumpWidget(
          MaterialApp(
            home: RangeTestPage(range: store, logger: log),
          ),
        );
        expect(find.text('Ping every 30 s (plugged in)'), findsOneWidget);
        await store.setPingSecs(110);
        await t.pump();
        expect(store.pingSecs, 110);
        expect(find.byKey(const Key('rangeLegend')), findsOneWidget);
      },
    );
  });

  testWidgets('screenshot (RANGE_LOG_PNG=path)', (t) async {
    final out = Platform.environment['RANGE_LOG_PNG'];
    if (out == null) return;
    final tiles = Platform.environment['RANGE_TILES'];
    final store = RangeTest(null);
    // A drive away from home and back: replies strong -> weak, misses at
    // the edge, a few heard packets; the 5:44 PM marker from the PC test.
    final start = DateTime(2026, 10, 30, 18, 20);
    const path = [
      (45.5790, -122.3000, 8.0),
      (45.5800, -122.2960, 7.0),
      (45.5815, -122.2915, 5.5),
      (45.5834, -122.2872, 3.0),
      (45.5855, -122.2830, 0.5),
      (45.5880, -122.2790, -2.5),
      (45.5906, -122.2752, -5.0),
      (45.5934, -122.2715, -8.0),
      (45.5960, -122.2680, -11.0),
      (45.5985, -122.2645, -14.0),
      (45.6012, -122.2610, double.nan),
      (45.6040, -122.2575, double.nan),
      (45.6068, -122.2540, double.nan),
    ];
    for (var i = 0; i < path.length; i++) {
      final p = path[i];
      final at = start.add(Duration(seconds: 90 * i));
      final ok = !p.$3.isNaN;
      await store.addSample(
        RangeSample(
          at: at,
          pos: GeoPoint(p.$1, p.$2),
          kind: ok ? SampleKind.ok : SampleKind.fail,
          snr: ok ? p.$3 : null,
          rssi: ok ? (p.$3 * 3 - 80).round() : null,
          hops: ok ? 0 : null,
          from: home,
        ),
      );
      if (ok && i.isEven) {
        await store.addSample(
          RangeSample(
            at: at.add(const Duration(seconds: 40)),
            pos: GeoPoint(p.$1 + 0.0007, p.$2 + 0.0012),
            kind: SampleKind.heard,
            snr: p.$3 - 1,
            rssi: -95,
            hops: 0,
            from: home,
          ),
        );
      }
    }
    await store.add([
      RangeEvent(
        kind: RangeKind.connect,
        at: start,
        pos: const GeoPoint(45.5790, -122.3000),
        snr: 8,
        hops: 0,
        distM: 40,
        approximate: false,
      ),
      RangeEvent(
        kind: RangeKind.drop,
        at: start.add(const Duration(seconds: 90 * 10)),
        pos: const GeoPoint(45.6012, -122.2610),
        distM: 3900,
        approximate: false,
      ),
    ]);
    t.view.physicalSize = const Size(360, 780) * 3;
    t.view.devicePixelRatio = 3;
    t.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 16 * 3);
    addTearDown(t.view.reset);
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await t.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Stack(
              children: [
                FlutterMap(
                  options: const MapOptions(
                    initialCenter: LatLng(45.5910, -122.2780),
                    initialZoom: 13,
                  ),
                  children: [
                    if (tiles != null)
                      TileLayer(
                        tileProvider: _LocalTiles(tiles),
                        urlTemplate: 'x/{z}/{x}/{y}',
                      ),
                    CircleLayer(circles: rangeSampleCircles(store)),
                    MarkerLayer(markers: rangeMarkers(store)),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: const LatLng(45.5790, -122.3000),
                          width: 40,
                          height: 40,
                          child: const Icon(
                            Icons.home,
                            color: Colors.blue,
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 32,
                  left: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cell_tower, size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            'Range logging · No reply from Skunk Ape',
                            style: TextStyle(color: Colors.white, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  left: 8,
                  right: 8,
                  bottom: 24,
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: RangeLegend(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle();
    await t.pumpAndSettle();
    final b = t.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await t.runAsync(() async {
      final img = await b.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });

  testWidgets('settings page screenshot (RANGE_LOG_PAGE_PNG=path)', (t) async {
    final out = Platform.environment['RANGE_LOG_PAGE_PNG'];
    if (out == null) return;
    final store = RangeTest(null);
    await store.setLogging(true);
    await store.setPingSecs(90);
    final log = RangeLogger(
      store: store,
      fix: () => null,
      plugged: () => false,
    );
    addTearDown(log.dispose);
    for (var i = 0; i < 9; i++) {
      await store.addSample(
        RangeSample(
          at: DateTime(2026, 10, 30, 18, i),
          pos: const GeoPoint(45.5, -122.2),
          kind: i == 7
              ? SampleKind.fail
              : (i.isEven ? SampleKind.ok : SampleKind.heard),
          snr: 3,
        ),
      );
    }
    t.view.physicalSize = const Size(360, 1500) * 3;
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: RangeTestPage(range: store, logger: log),
        ),
      ),
    );
    await t.pumpAndSettle();
    final b = t.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await t.runAsync(() async {
      final img = await b.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}

class _LocalTiles extends TileProvider {
  _LocalTiles(this.dir);
  final String dir;
  @override
  ImageProvider getImage(TileCoordinates c, TileLayer o) {
    final f = File('$dir/${c.z}_${c.x}_${c.y}.png');
    return f.existsSync() ? FileImage(f) : MemoryImage(Uint8List(0));
  }
}

/// A radio that answers the config download and records / injects packets.
class _MiniWire implements MeshtasticWire {
  static const me = 0x1234ABCD;
  final sent = <MeshPacketPb>[];
  final _queue = <Uint8List>[];
  final _notify = StreamController<void>.broadcast();

  @override
  Future<void> write(Uint8List toRadio) async {
    for (final f in pbDecode(toRadio)) {
      if (f.number == 3) {
        _queue.add(
          (PbWriter()..message(3, (PbWriter()..uint(1, me)).toBytes()))
              .toBytes(),
        );
        _queue.add((PbWriter()..uint(7, f.asInt)).toBytes());
        _notify.add(null);
      }
      if (f.number == 1) sent.add(MeshPacketPb.decode(f.asBytes));
    }
  }

  void deliver({
    required int from,
    required int to,
    int? port,
    int requestId = 0,
    double snr = 0,
    int rssi = 0,
    int hopStart = 0,
    int hopLimit = 0,
  }) {
    final w = PbWriter()
      ..fixed32(1, from)
      ..fixed32(2, to);
    if (port != null) {
      w.message(
        4,
        MeshData(
          portnum: port,
          payload: Uint8List(0),
          requestId: requestId,
        ).encode(),
      );
    }
    final bits = ByteData(4)..setFloat32(0, snr, Endian.little);
    w
      ..fixed32(6, 77)
      ..fixed32(8, bits.getUint32(0, Endian.little))
      ..uint(9, hopLimit)
      ..uint(12, rssi)
      ..uint(15, hopStart);
    _queue.add((PbWriter()..message(2, w.toBytes())).toBytes());
    _notify.add(null);
  }

  @override
  Future<Uint8List> read() async =>
      _queue.isEmpty ? Uint8List(0) : _queue.removeAt(0);

  @override
  Stream<void> get notifications => _notify.stream;
}
