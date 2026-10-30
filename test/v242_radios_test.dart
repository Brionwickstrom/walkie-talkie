import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/ui/radio_settings.dart';
import 'package:walkie_talkie/ui/radios_nearby_page.dart';
import 'package:walkie_talkie/ui/reach.dart';

import 'lora_proto_test.dart' show FakeRadioWire;
import 'v231_helpers.dart';

// v2.4.2: Radios nearby. Everything shown is read from what the radio
// already sent: no requests, no timers.

Uint8List float32(double v) {
  final d = ByteData(4)..setFloat32(0, v, Endian.little);
  return d.buffer.asUint8List();
}

/// A `NodeInfo` as the radio sends it.
Uint8List nodeInfoBytes(
  int num, {
  String? long,
  String short = '',
  int hw = 0,
  int role = 0,
  double? lat,
  double? lng,
  double snr = 0,
  int last = 0,
  int? battery,
  int? channel,
  int? hops,
}) {
  final w = PbWriter()..uint(1, num);
  if (long != null) {
    w.message(
      2,
      (PbWriter()
            ..string(1, radioNodeId(num))
            ..string(2, long)
            ..string(3, short)
            ..uint(5, hw)
            ..uint(7, role))
          .toBytes(),
    );
  }
  if (lat != null && lng != null) {
    w.message(
      3,
      (PbWriter()
            ..fixed32(1, (lat * 1e7).round())
            ..fixed32(2, (lng * 1e7).round()))
          .toBytes(),
    );
  }
  if (snr != 0) {
    // float, wire type 5, field 4
    final f = float32(snr);
    final bd = ByteData.sublistView(f);
    w.fixed32(4, bd.getUint32(0, Endian.little));
  }
  w.fixed32(5, last);
  if (battery != null) {
    w.message(6, (PbWriter()..uint(1, battery)).toBytes());
  }
  if (channel != null) w.uint(7, channel, always: true);
  if (hops != null) w.uint(9, hops, always: true);
  return w.toBytes();
}

FromRadio node(Uint8List ni) =>
    FromRadio.tryDecode((PbWriter()..message(4, ni)).toBytes())!;

const meNum = 0x1000;
final t0 = DateTime(2026, 10, 29, 12, 0);

MeshtasticSession newSession({DateTime? now}) {
  final s = MeshtasticSession(FakeRadioWire(), clock: () => now ?? t0);
  s.handle(FromRadio(myInfo: MyNodeInfoPb(meNum, 10)));
  return s;
}

void addChannel(
  MeshtasticSession s,
  int index,
  String name,
  List<int> psk, {
  int role = 2,
}) => s.handle(
  FromRadio(channel: ChannelPb(index, name, Uint8List.fromList(psk), role)),
);

MeshPacketPb decodedFrom(
  int from, {
  int channel = 0,
  int port = PortNum.privateApp,
  Uint8List? payload,
  double snr = 5,
  int rssi = -90,
}) => MeshPacketPb(
  from: from,
  to: meshBroadcast,
  channel: channel,
  rxSnr: snr,
  rxRssi: rssi,
  decoded: MeshData(portnum: port, payload: payload ?? Uint8List(1)),
);

MeshPacketPb encryptedFrom(int from, {double snr = -3, int rssi = -110}) =>
    MeshPacketPb(
      from: from,
      to: meshBroadcast,
      channel: 77, // a channel hash, not a slot
      encrypted: true,
      rxSnr: snr,
      rxRssi: rssi,
    );

Frame appFrame(int sender, int channel, {FrameType type = FrameType.control}) =>
    Frame(
      type: type,
      senderId: sender,
      channel: channel,
      seq: 1,
      payload: Uint8List.fromList([1, 2, 3]),
    );

MeshPacketPb walkiePacket(int from, Frame f, {int slot = 0}) =>
    decodedFrom(from, channel: slot, payload: f.encode());

RadiosNearby compute(
  MeshtasticSession? s, {
  Map<int, LoraPeerSignal> signals = const {},
  Map<int, String> walkie = const {},
  Map<MeshChannelRef, Reach> links = const {},
  Map<int, Reach> groups = const {},
  Map<int, Reach> open = const {},
  GeoPoint? phone,
}) => computeRadiosNearby(
  session: s,
  signals: signals,
  walkieName: (id) => walkie[id] ?? 'Phone $id',
  openByLink: (r) => links[r],
  groupByTag: (t) => groups[t],
  openByNumber: (n) => open[n],
  phone: phone,
);

void main() {
  group('decoding', () {
    test('NodeInfo: names, hardware, role, position, channel, signal', () {
      final m = node(
        nodeInfoBytes(
          0x2000,
          long: 'Summit Hiker',
          short: 'SH',
          hw: 71,
          role: 5,
          lat: 45.5231,
          lng: -122.6765,
          snr: 6.5,
          last: 1793000000,
          battery: 82,
          channel: 2,
          hops: 0,
        ),
      );
      final n = m.nodeInfo!;
      expect(n.num, 0x2000);
      expect(n.longName, 'Summit Hiker');
      expect(n.shortName, 'SH');
      expect(n.hasUser, isTrue);
      expect(n.hwModel, 71);
      expect(meshHardwareName(n.hwModel), 'SenseCAP T1000-E');
      expect(meshRoleName(n.role), 'Tracker');
      expect(n.position!.lat, closeTo(45.5231, 1e-6));
      expect(
        n.position!.lng,
        closeTo(-122.6765, 1e-6),
        reason: 'west is negative',
      );
      expect(n.snr, 6.5);
      expect(n.lastHeard, 1793000000);
      expect(n.metrics!.batteryLevel, 82);
      expect(n.channel, 2);
      expect(n.hopsAway, 0, reason: '0 hops is direct, not unknown');
    });

    test('no user and an empty position: nothing invented', () {
      final n = node(nodeInfoBytes(0x2100, lat: 0.0, lng: 0.0)).nodeInfo!;
      expect(n.hasUser, isFalse);
      expect(n.position, isNull);
      expect(n.hopsAway, isNull);
      expect(n.channel, isNull);
      expect(meshHardwareName(0), isNull);
      expect(meshHardwareName(9999), isNull);
      expect(meshRoleName(0), isNull, reason: 'a plain client says nothing');
    });

    test(
      'the session keeps the new fields, packets add position and signal',
      () {
        final s = newSession();
        s.handle(
          node(
            nodeInfoBytes(
              0x2000,
              long: 'Ann Radio',
              hw: 9,
              role: 2,
              lat: 45.0,
              lng: -122.0,
              snr: 4,
              last: 1793000000,
              channel: 1,
            ),
          ),
        );
        final n = s.nodes[0x2000]!;
        expect(n.hasInfo, isTrue);
        expect(n.hwModel, 9);
        expect(n.role, 2);
        expect(n.lat, 45.0);
        expect(n.channel, 1);
        // A position packet it sent moves it; its RSSI is kept.
        final pos =
            (PbWriter()
                  ..fixed32(1, (45.1 * 1e7).round())
                  ..fixed32(2, (-122.1 * 1e7).round()))
                .toBytes();
        s.handle(
          FromRadio(
            packet: decodedFrom(
              0x2000,
              channel: 2,
              port: PortNum.position,
              payload: pos,
              rssi: -97,
            ),
          ),
        );
        expect(n.lat, closeTo(45.1, 1e-6));
        expect(n.lng, closeTo(-122.1, 1e-6));
        expect(n.rssi, -97);
        expect(n.channel, 2, reason: 'heard on slot 2 now');
        expect(n.decodedHeard, isTrue);
        // The existing fields are unchanged.
        expect(s.nodeCount, 1);
      },
    );
  });

  group('the list', () {
    test('no radio session: not connected, nothing listed', () {
      final r = compute(null);
      expect(r.connected, isFalse);
      expect(r.radios, isEmpty);
    });

    test('sorted by last heard, newest first; our own node is the header', () {
      final s = newSession();
      s.handle(
        node(
          nodeInfoBytes(
            meNum,
            long: 'My Radio',
            battery: 101,
            last: 1793000900,
          ),
        ),
      );
      s.handle(node(nodeInfoBytes(0x2001, long: 'Old One', last: 1793000100)));
      s.handle(node(nodeInfoBytes(0x2002, long: 'Newest', last: 1793000800)));
      s.handle(node(nodeInfoBytes(0x2003, long: 'Middle', last: 1793000500)));
      s.handle(node(nodeInfoBytes(0x2004, long: 'Never heard')));
      final r = compute(s);
      expect(r.connected, isTrue);
      expect(r.mine!.name, 'My Radio');
      expect(r.mine!.battery, 101);
      expect(r.radios.map((x) => x.name), [
        'Newest',
        'Middle',
        'Old One',
        'Never heard',
      ]);
      expect(r.radios.any((x) => x.num == meNum), isFalse);
    });

    test('Walkie phones heard over the radio are matched by node number', () {
      final s = newSession();
      s.handle(
        node(
          nodeInfoBytes(
            0x2001,
            long: 'Ann T1000',
            short: 'AT',
            last: 1793000000,
          ),
        ),
      );
      s.handle(node(nodeInfoBytes(0x2002, long: 'Stranger', last: 1793000000)));
      final sig = {0x7777: LoraPeerSignal(0x2001, 6, -95, 1, t0)};
      final r = compute(s, signals: sig, walkie: {0x7777: 'Ann'});
      final ann = r.radios.firstWhere((x) => x.num == 0x2001);
      final other = r.radios.firstWhere((x) => x.num == 0x2002);
      expect(ann.walkieName, 'Ann');
      expect(ann.name, 'Ann T1000', reason: 'the radio name stays the title');
      expect(other.walkieName, isNull);
    });

    test('a Walkie phone with no NodeInfo is listed by its Walkie name', () {
      final s = newSession();
      // Heard a Walkie frame (readable), but its radio never sent a NodeInfo.
      final f = appFrame(0x7777, 3);
      s.handle(FromRadio(packet: walkiePacket(0x2005, f)));
      final sig = {
        0x7777: LoraPeerSignal(0x2005, 5, -90, 0, t0, frameChannel: 3),
      };
      final r = compute(s, signals: sig, walkie: {0x7777: 'Ben'});
      expect(r.radios.single.name, 'Ben');
      expect(r.radios.single.walkieName, 'Ben');
      expect(r.unreadable, 0);
      // With no Walkie match either, the node id stands in.
      final r2 = compute(s);
      expect(r2.radios.single.name, '!00002005');
    });

    test("nodes we can't read are one count, not rows", () {
      final s = newSession();
      s.handle(node(nodeInfoBytes(0x2001, long: 'Readable')));
      s.handle(FromRadio(packet: encryptedFrom(0x3001)));
      s.handle(FromRadio(packet: encryptedFrom(0x3002)));
      s.handle(FromRadio(packet: encryptedFrom(0x3002)));
      s.handle(FromRadio(packet: encryptedFrom(0x3003)));
      expect(s.unreadableCount, 3);
      final r = compute(s);
      expect(r.unreadable, 3);
      expect(r.radios.map((x) => x.name), ['Readable']);
      // The existing "nodes heard" count still counts everyone.
      expect(s.nodeCount, 4);
      expect(radioDetailLines(s), contains('Meshtastic nodes heard: 4'));
    });

    test(
      'a node first unreadable, then heard on a channel we know, is listed',
      () {
        final s = newSession();
        s.handle(FromRadio(packet: encryptedFrom(0x3001)));
        expect(compute(s).unreadable, 1);
        s.handle(FromRadio(packet: decodedFrom(0x3001, channel: 0)));
        final r = compute(s);
        expect(r.unreadable, 0);
        expect(r.radios, hasLength(1));
      },
    );
  });

  group('channel labels', () {
    test(
      'open Walkie channel, private group, default and custom radio channels',
      () {
        final s = newSession();
        addChannel(s, 0, '', [1]); // LongFast, default key
        addChannel(s, 1, 'Crew', List<int>.generate(16, (i) => i + 9));
        addChannel(s, 2, 'Walkie CH 5', List<int>.generate(16, (i) => i + 40));
        addChannel(s, 3, 'Open Net', [0]); // no encryption
        s.handle(
          node(
            nodeInfoBytes(
              0x2001,
              long: 'On default',
              channel: 0,
              last: 1793000005,
            ),
          ),
        );
        s.handle(
          node(
            nodeInfoBytes(
              0x2002,
              long: 'On crew',
              channel: 1,
              last: 1793000004,
            ),
          ),
        );
        s.handle(
          node(
            nodeInfoBytes(
              0x2003,
              long: 'On linked',
              channel: 2,
              last: 1793000003,
            ),
          ),
        );
        s.handle(
          node(
            nodeInfoBytes(
              0x2004,
              long: 'On open net',
              channel: 3,
              last: 1793000002,
            ),
          ),
        );
        s.handle(
          node(
            nodeInfoBytes(
              0x2005,
              long: 'Private pal',
              channel: 0,
              last: 1793000001,
            ),
          ),
        );
        s.handle(
          node(
            nodeInfoBytes(
              0x2006,
              long: 'Gone slot',
              channel: 6,
              last: 1793000000,
            ),
          ),
        );
        final linkRef = s.refOf(s.channels[2]!);
        final openReach = Reach.open(5, name: 'Hikers');
        final groupReach = Reach.group('privates club', color: 0xFF4DB6AC);
        final r = compute(
          s,
          links: {linkRef: openReach},
          groups: {0x4242: groupReach},
          signals: {
            0x8888: LoraPeerSignal(
              0x2005,
              5,
              -90,
              0,
              t0,
              frameChannel: 0x4242,
              sealed: true,
            ),
          },
        );
        NearbyRadio by(int n) => r.radios.firstWhere((x) => x.num == n);
        expect(by(0x2001).channel.text, 'LongFast (Meshtastic default)');
        expect(by(0x2001).channel.reach, isNull);
        expect(by(0x2002).channel.text, 'Crew');
        expect(by(0x2003).channel.reach, openReach);
        expect(by(0x2003).channel.reach!.tag, 'Open channel · CH 5');
        expect(by(0x2004).channel.text, 'Open Net (no encryption)');
        expect(by(0x2005).channel.reach, groupReach);
        expect(by(0x2005).channel.reach!.tag, 'Private group · privates club');
        expect(
          by(0x2006).channel.isEmpty,
          isTrue,
          reason: 'slot not on this radio',
        );
      },
    );

    test(
      'a Walkie phone on an open channel is labelled from its own frames',
      () {
        final s = newSession();
        addChannel(s, 0, '', [1]);
        s.handle(
          node(
            nodeInfoBytes(0x2001, long: 'Ann', channel: 0, last: 1793000000),
          ),
        );
        final open7 = Reach.open(7);
        final r = compute(
          s,
          open: {7: open7},
          signals: {
            0x7777: LoraPeerSignal(0x2001, 5, -90, 0, t0, frameChannel: 7),
          },
        );
        expect(r.radios.single.channel.reach, open7);
      },
    );
  });

  group('distance and numbers', () {
    test(
      'distance from our own radio, else from the phone, never invented',
      () {
        final s = newSession();
        s.handle(
          node(
            nodeInfoBytes(
              0x2001,
              long: 'Shares',
              lat: 45.1,
              lng: -122.0,
              last: 1793000003,
            ),
          ),
        );
        s.handle(node(nodeInfoBytes(0x2002, long: 'Hides', last: 1793000002)));
        // Phone only (our radio shares no position).
        final phone = const GeoPoint(45.0, -122.0);
        var r = compute(s, phone: phone);
        final d = r.radios.firstWhere((x) => x.num == 0x2001).distanceM!;
        expect(d, closeTo(11113, 60)); // 0.1 degree of latitude
        expect(r.radios.firstWhere((x) => x.num == 0x2002).distanceM, isNull);
        // No phone fix and no radio position: nothing is shown.
        r = compute(s);
        expect(r.radios.every((x) => x.distanceM == null), isTrue);
        // Our radio's own position wins over the phone's.
        s.handle(
          node(nodeInfoBytes(meNum, long: 'Me', lat: 45.2, lng: -122.0)),
        );
        r = compute(s, phone: phone);
        expect(
          r.radios.firstWhere((x) => x.num == 0x2001).distanceM,
          closeTo(11113, 60),
          reason: 'from 45.2, not from the phone at 45.0 (22 km)',
        );
      },
    );

    test('the line: heard, SNR, RSSI, direct or hops, battery, distance', () {
      final now = t0.add(const Duration(minutes: 5));
      final direct = NearbyRadio(
        num: 1,
        name: 'A',
        lastHeard: t0,
        snr: 6.5,
        rssi: -92,
        hops: 0,
        battery: 80,
        distanceM: 3200,
      );
      expect(
        nearbyRadioLine(direct, now: now, imperial: false),
        'heard 5 min ago · SNR 6.5 dB · RSSI -92 dBm · direct · battery 80% · 3.2 km',
      );
      final far = NearbyRadio(num: 2, name: 'B', hops: 3, battery: 101);
      expect(nearbyRadioLine(far, now: now), '3 hops · powered');
      expect(
        nearbyRadioLine(NearbyRadio(num: 3, name: 'C', hops: 1), now: now),
        '1 hop',
      );
      expect(nearbyRadioLine(NearbyRadio(num: 4, name: 'D'), now: now), '');
      expect(radioAgo(const Duration(seconds: 10)), 'just now');
      expect(radioAgo(const Duration(hours: 3)), '3 h ago');
      expect(radioAgo(const Duration(days: 4)), '4 d ago');
    });
  });

  group('screens', () {
    testWidgets(
      'Settings line opens the page; rows, tags, count, no leftovers',
      (t) async {
        phone(t, ts: 1.0);
        final c = await makeController(
          t,
          group: 'privates club',
          friends: [testFriend(0x2222, 'Ann')],
        );
        // A paired, connected radio that has heard a few things.
        c.radioDevice.deviceId = 'AA:BB';
        c.radioDevice.deviceName = 'T1000-E 4f2a';
        c.radioDevice.state = RadioState.ready;
        final s = newSession(now: DateTime.now());
        c.radioDevice.session = s;
        addChannel(s, 0, '', [1]);
        final now = DateTime.now();
        int ago(int min) =>
            now.subtract(Duration(minutes: min)).millisecondsSinceEpoch ~/ 1000;
        s.handle(node(nodeInfoBytes(meNum, long: 'T1000-E 4f2a', battery: 64)));
        s.handle(
          node(
            nodeInfoBytes(
              0x2001,
              long: 'Ann T1000',
              short: 'ANN',
              hw: 71,
              snr: 7.5,
              last: ago(2),
              battery: 91,
              hops: 0,
              lat: 45.01,
              lng: -122.0,
              channel: 0,
            ),
          ),
        );
        s.handle(
          node(
            nodeInfoBytes(
              0x2002,
              long: 'Ridge Repeater',
              short: 'RR',
              hw: 9,
              role: 4,
              snr: -4,
              last: ago(40),
              hops: 2,
              channel: 0,
            ),
          ),
        );
        s.handle(FromRadio(packet: encryptedFrom(0x3001)));
        s.handle(FromRadio(packet: encryptedFrom(0x3002)));
        // Ann's phone talked over the radio on our own private group.
        final tag = c.scope & 0xFFFF;
        c.loraTransport.onPacket(
          walkiePacket(0x2001, appFrame(0x2222, tag, type: FrameType.sealed)),
        );
        // The phone's last known fix (no GPS is started for this).
        expect(TransportManager.isPrivateScope(c.scope), isTrue);

        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: Scaffold(
              body: SingleChildScrollView(child: RadioSettings(controller: c)),
            ),
          ),
        );
        await t.pump();
        final line = find.byKey(const Key('radiosNearbyLine'));
        expect(line, findsOneWidget);
        expect(
          find.descendant(
            of: line,
            matching: find.text('Meshtastic nodes heard: 4'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: line, matching: find.byIcon(Icons.chevron_right)),
          findsOneWidget,
        );
        await t.ensureVisible(line);
        await t.tap(line);
        await settle(t);
        expect(find.text('Radios nearby'), findsOneWidget);
        expect(find.byKey(const Key('radios-this')), findsOneWidget);
        expect(
          find.textContaining('This radio · T1000-E 4f2a'),
          findsOneWidget,
        );
        // Ann: Walkie tag, signal, direct, battery, hardware, private group.
        expect(find.text('Ann T1000 (ANN)'), findsOneWidget);
        expect(find.byKey(const Key('radio-walkie-${0x2001}')), findsOneWidget);
        expect(find.text('Stalkie · Ann'), findsOneWidget);
        expect(find.textContaining('SNR 7.5 dB'), findsOneWidget);
        expect(find.textContaining('direct'), findsOneWidget);
        expect(find.textContaining('battery 91%'), findsOneWidget);
        expect(find.textContaining('SenseCAP T1000-E'), findsOneWidget);
        expect(find.text('Private group · privates club'), findsOneWidget);
        // Repeater: hops, role, the radio channel's name.
        expect(find.text('Ridge Repeater (RR)'), findsOneWidget);
        expect(find.textContaining('2 hops'), findsOneWidget);
        expect(find.textContaining('Repeater'), findsWidgets);
        expect(find.text('LongFast (Meshtastic default)'), findsOneWidget);
        // The ones we can't read: one line.
        expect(find.text("Other channel, can't read: 2"), findsOneWidget);
        // Newest first: Ann (2 min) above the repeater (40 min).
        expect(
          t.getTopLeft(find.text('Ann T1000 (ANN)')).dy,
          lessThan(t.getTopLeft(find.text('Ridge Repeater (RR)')).dy),
        );
        // No transmissions came from opening it.
        expect((s.wire as FakeRadioWire).written, isEmpty);
        // Live: a new radio shows up while open, without being asked.
        s.handle(
          node(
            nodeInfoBytes(
              0x2003,
              long: 'Late Arrival',
              last: now.millisecondsSinceEpoch ~/ 1000,
            ),
          ),
        );
        await t.pump();
        await t.pump();
        expect(find.text('Late Arrival'), findsOneWidget);
        await t.pageBack();
        await settle(t);
        await finish(t);
        expect((s.wire as FakeRadioWire).written, isEmpty);
      },
    );

    testWidgets('empty: one plain line', (t) async {
      phone(t, ts: 1.0);
      final c = await makeController(t);
      final s = newSession(now: DateTime.now());
      c.radioDevice.session = s;
      await t.pumpWidget(MaterialApp(home: RadiosNearbyPage(controller: c)));
      await t.pump();
      expect(find.byKey(const Key('radios-empty')), findsOneWidget);
      expect(find.text('No other radios heard yet.'), findsOneWidget);
      expect(find.byKey(const Key('radios-unreadable')), findsNothing);
      await finish(t);
    });

    testWidgets('no radio: says to connect', (t) async {
      phone(t, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(MaterialApp(home: RadiosNearbyPage(controller: c)));
      await t.pump();
      expect(
        find.text('Connect your radio to see radios nearby.'),
        findsOneWidget,
      );
      await finish(t);
    });

    testWidgets('wide screens get a dialog', (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = await makeController(t);
      c.radioDevice.session = newSession(now: DateTime.now());
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => openRadiosNearby(ctx, c),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
      expect(find.byKey(const Key('radios-dialog')), findsOneWidget);
      expect(find.text('Radios nearby'), findsOneWidget);
      await t.tap(find.byTooltip('Close'));
      await settle(t);
      expect(find.byKey(const Key('radios-dialog')), findsNothing);
      await finish(t);
    });
  });
}
