// v2.6.4: Show public nodes (listen-only public LongFast channel).
// Fake radio of the v2.5.3 tests; nothing here has run on a real radio.
//   V264_SHOTS=/workspace flutter test test/v264_public_nodes_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/lora/meshtastic_admin.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/lora/radio_match.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/ui/public_nodes.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';
import 'package:walkie_talkie/ui/radios_nearby_page.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v253_radio_settings_test.dart' show Fw, loraRaw, writer;
import 'v257_precision_test.dart' show bigKey, chan, hikeKey;

/// loraRaw on frequency slot [slot] (20 = the US public LongFast slot).
Uint8List loraAt(int slot) => patchVarints(loraRaw(), {11: slot});

/// Bigfoot-style radio: private main channel + Hikers, on [slot].
Fw radioOn({int slot = 20, bool withPublic = false}) {
  final fw = Fw()
    ..lora = loraAt(slot)
    ..channels[0] = chan(0, 1, 'BigfootNet', bigKey, prec: 32)
    ..channels[1] = chan(1, 2, 'Hikers', hikeKey, prec: 13);
  if (withPublic) fw.channels[2] = publicChannelRaw(2);
  return fw;
}

/// The listen-only public channel as a raw `Channel` in slot [i].
Uint8List publicChannelRaw(int i) =>
    (PbWriter()
          ..uint(1, i)
          ..message(2, meshPublicListenSettings())
          ..uint(3, 2))
        .toBytes();

MeshChannelWriter chWriter(MeshtasticSession s) => MeshChannelWriter(
  () => s,
  replyTimeout: const Duration(seconds: 1),
  rebootWait: const Duration(milliseconds: 100),
  reconnectTimeout: const Duration(seconds: 5),
  poll: const Duration(milliseconds: 10),
  writeGap: Duration.zero,
);

Future<MeshtasticSession> up(Fw fw) async {
  final s = MeshtasticSession(fw);
  await s.start(timeout: const Duration(seconds: 2));
  return s;
}

/// A packet heard on air from [from] on channel slot [ch].
FromRadio heard(
  int from, {
  required int ch,
  int port = PortNum.text,
  double snr = 4.5,
  int rssi = -101,
  int hopStart = 3,
  int hopLimit = 1,
  List<int> payload = const [1, 2, 3],
}) => FromRadio(
  packet: MeshPacketPb(
    from: from,
    to: meshBroadcast,
    channel: ch,
    rxSnr: snr,
    rxRssi: rssi,
    hopStart: hopStart,
    hopLimit: hopLimit,
    decoded: MeshData(portnum: port, payload: Uint8List.fromList(payload)),
  ),
);

/// Example public nodes, clearly made up (for tests and screenshots).
void addExamplePublic(MeshtasticSession s, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final pub = s.publicListenIndex!;
  void add(
    int num, {
    required Duration ago,
    double snr = 0,
    int rssi = 0,
    int? hops,
    double? lat,
    double? lng,
    String name = '',
    String short = '',
  }) {
    s.nodes[num] = RadioNode(num)
      ..channel = pub
      ..decodedHeard = true
      ..lastHeard = t.subtract(ago)
      ..snr = snr
      ..rssi = rssi
      ..hopsAway = hops
      ..lat = lat
      ..lng = lng
      ..longName = name
      ..shortName = short;
  }

  add(
    0xE0A10001,
    ago: const Duration(minutes: 2),
    snr: 6.25,
    rssi: -94,
    hops: 0,
    lat: 45.56,
    lng: -122.60,
    name: 'Example Name One',
    short: 'EX1',
  );
  add(
    0xE0A10002,
    ago: const Duration(minutes: 14),
    snr: -7.5,
    rssi: -118,
    hops: 2,
    lat: 45.62,
    lng: -122.40,
    name: 'Example Name Two',
    short: 'EX2',
  );
  add(0xE0A10003, ago: const Duration(hours: 1), snr: -12, rssi: -124, hops: 3);
  add(0xE0A10004, ago: const Duration(hours: 3));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('the channel', () {
    test('LongFast, default key, uplink/downlink off, precision 0', () {
      final cs = MeshChannelSettings.decode(meshPublicListenSettings());
      expect(cs.name, 'LongFast');
      expect(cs.keyKind(), MeshKeyKind.defaultPublic);
      expect(cs.uplinkEnabled, isFalse);
      expect(cs.downlinkEnabled, isFalse);
      expect(cs.positionPrecision, 0);
      final raw = pbDecode(meshPublicListenSettings());
      expect(
        raw.where((f) => f.number == 7),
        hasLength(1),
        reason: 'module settings written, so precision 0 is explicit',
      );
      expect(raw.where((f) => f.number == 5 || f.number == 6), isEmpty);
    });

    test('same name and hash as a stock radio\'s public primary', () {
      final stock = MeshRadioChannel.fromChannel(
        index: 0,
        role: MeshChannelRole.primary,
        name: '',
        psk: const [1],
      );
      expect(stock.ref('LongFast'), meshPublicRef);
      final set = meshPublicListenSet();
      expect(set.addMode, isTrue, reason: 'never changes the LoRa settings');
      expect(set.loraToApply, isNull);
      expect(set.refFor(0, 'MediumFast'), meshPublicRef);
      expect(set.toString(), isNot(contains('AQ')));
    });

    test('found only as a secondary channel in slots 1-7', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      expect(s.publicListenIndex, 2);
      final s2 = await up(radioOn());
      addTearDown(s2.close);
      expect(s2.publicListenIndex, isNull);
      // A stock radio (public primary): its own group is public, nothing
      // is listen-only.
      final stock = Fw()
        ..channels[0] =
            (PbWriter()
                  ..uint(1, 0)
                  ..message(2, (PbWriter()..bytes(2, [1])).toBytes())
                  ..uint(3, 1))
                .toBytes();
      final s3 = await up(stock);
      addTearDown(s3.close);
      expect(s3.publicListenIndex, isNull);
    });
  });

  group('writing it', () {
    test('adds one secondary channel, nothing else changes', () async {
      final fw = radioOn();
      final s = await up(fw);
      addTearDown(s.close);
      final loraBefore = fw.lora;
      final primaryBefore = fw.channels[0];
      final r = await chWriter(s).addChannel(meshPublicListenSet(), 0);
      expect(r.index, 2, reason: 'first free slot');
      expect(fw.writes, ['begin', 'set_channel2', 'commit']);
      expect(fw.sentLora, isNull);
      expect(fw.lora, loraBefore);
      expect(fw.channels[0], primaryBefore);
      expect(s.publicListenIndex, 2);
      final ch = s.channels[2]!;
      expect(ch.isSecondary, isTrue);
      expect(ch.uplinkEnabled, isFalse);
      expect(ch.positionPrecision, 0);
    });
  });

  group('the session', () {
    test(
      'public packets never reach the app; signal and hops are kept',
      () async {
        final s = await up(radioOn(withPublic: true));
        addTearDown(s.close);
        final got = <MeshPacketPb>[];
        final sub = s.packets.listen(got.add);
        addTearDown(sub.cancel);
        s.handle(heard(0xE0A10001, ch: 2, port: PortNum.privateApp));
        s.handle(heard(0xE0A10002, ch: 2));
        s.handle(heard(0x00C0FFEE, ch: 0, port: PortNum.privateApp));
        await Future<void>.delayed(Duration.zero);
        expect(got.map((p) => p.from), [0x00C0FFEE]);
        expect(s.publicReceived, 2);
        expect(s.received, 1);
        final n = s.nodes[0xE0A10001]!;
        expect(s.isPublicNode(n), isTrue);
        expect(s.isPublicNode(s.nodes[0x00C0FFEE]!), isFalse);
        expect(n.snr, 4.5);
        expect(n.rssi, -101);
        expect(n.hopsAway, 2);
        expect(n.publicPackets, 1);
      },
    );

    test(
      'nothing can be sent on it; admin and other channels still can',
      () async {
        final fw = radioOn(withPublic: true);
        final s = await up(fw);
        addTearDown(s.close);
        expect(
          () => s.send(Uint8List.fromList([1]), channel: 2),
          throwsStateError,
        );
        await s.send(Uint8List.fromList([1]), channel: 1);
        await s.send(Uint8List.fromList([1]));
        expect(fw.packets.map((p) => p.channel), [1, 0]);
      },
    );
  });

  group('the list', () {
    test('name, ID, signal, hops and distance; no locations, newest first',
        () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      final now = DateTime(2026, 11, 6, 9);
      addExamplePublic(s, now: now);
      final p = computePublicNodes(
        session: s,
        onPublicSlot: true,
        phone: const GeoPoint(45.52, -122.68),
      );
      expect(p.listening, isTrue);
      expect(p.nodes.map((n) => n.num), [
        0xE0A10001,
        0xE0A10002,
        0xE0A10003,
        0xE0A10004,
      ]);
      expect(p.nodes.first.label, 'Example Name One (EX1)');
      expect(p.nodes.first.idLabel, '!e0a10001');
      expect(p.nodes[2].label, 'Public radio !e0a10003');
      final l1 = publicNodeLine(p.nodes[0], now: now, imperial: false);
      expect(l1, startsWith('heard 2 min ago · SNR 6.3 dB · RSSI -94 dBm'));
      expect(l1, contains('direct'));
      expect(l1, contains('km'));
      final l2 = publicNodeLine(p.nodes[1], now: now);
      expect(l2, contains('2 hops'));
      expect(l2, contains('mi'));
      final l4 = publicNodeLine(p.nodes[3], now: now);
      expect(l4, contains('signal unknown'));
      expect(l4, contains('hops unknown'));
      expect(l4, contains('distance unknown'));
      for (final n in p.nodes) {
        final text = '${n.label} ${n.idLabel} ${publicNodeLine(n, now: now)}';
        expect(text, isNot(contains('45.')));
        expect(text, isNot(contains('122')));
      }
      expect(publicNodesStateText(p), 'Public radios heard: 4');
    });

    test('distance from our own radio first, else the phone', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      addExamplePublic(s);
      s.nodes[Fw.myNode]!
        ..lat = 45.56
        ..lng = -122.60;
      final p = computePublicNodes(
        session: s,
        onPublicSlot: true,
        phone: const GeoPoint(10, 10),
      );
      expect(p.nodes.first.distanceM, closeTo(0, 1));
    });

    test('capped list says how many more', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      final t = DateTime.now();
      for (var i = 0; i < 40; i++) {
        s.nodes[0xE0B00000 + i] = RadioNode(0xE0B00000 + i)
          ..channel = 2
          ..lastHeard = t.subtract(Duration(minutes: i));
      }
      final p = computePublicNodes(session: s, onPublicSlot: true);
      expect(p.nodes, hasLength(publicNodesShown));
      expect(p.more, 40 - publicNodesShown);
      expect(p.total, 40);
    });

    test('state lines: off, not on the public slot, nothing yet', () async {
      final s = await up(radioOn());
      addTearDown(s.close);
      expect(
        publicNodesStateText(
          computePublicNodes(session: null, onPublicSlot: true),
        ),
        startsWith('Connect your radio'),
      );
      expect(
        publicNodesStateText(
          computePublicNodes(session: s, onPublicSlot: true),
        ),
        startsWith('Off.'),
      );
      final s2 = await up(radioOn(slot: 0, withPublic: true));
      addTearDown(s2.close);
      expect(
        publicNodesStateText(
          computePublicNodes(session: s2, onPublicSlot: false),
        ),
        contains('not on the public frequency'),
      );
      expect(
        publicNodesStateText(
          computePublicNodes(session: s2, onPublicSlot: true),
        ),
        contains('No public radios heard yet'),
      );
    });

    test('Radios nearby leaves them out (no names there either)', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      addExamplePublic(s);
      final r = computeRadiosNearby(
        session: s,
        signals: const {},
        walkieName: (_) => '',
        openByLink: (_) => null,
        groupByTag: (_) => null,
        openByNumber: (_) => null,
      );
      expect(r.public, 4);
      expect(r.radios.where((x) => x.name.contains('Example')), isEmpty);
    });

    test('the radio match check ignores the public channel', () async {
      final s = await up(radioOn(withPublic: true));
      addTearDown(s.close);
      final r = readingFromSession(s, DateTime.now())!;
      expect(r.precisions.keys, ['BigfootNet', 'Hikers']);
    });
  });

  group('settings search', () {
    test('public nodes / strangers / snr find it', () {
      for (final q in [
        'public nodes',
        'strangers',
        'longfast listen',
        'rssi',
      ]) {
        expect(
          searchSettings(q).map((e) => e.id),
          contains('radio-public-nodes'),
          reason: q,
        );
      }
      final e = settingsIndex.firstWhere((e) => e.id == 'radio-public-nodes');
      expect(e.home, SettingsHome.radio);
      expect(e.label, 'Show public nodes');
    });
  });

  group('the page', () {
    Future<(WalkieController, Fw, MeshtasticSession)> world(
      WidgetTester t,
      Fw fw,
    ) async {
      phone(t, w: 400, h: 4200, ts: 1.0);
      final c = await makeController(t);
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      c.radioSettingsWriterFactory = () => writer(s);
      c.meshWriterFactory = () => chWriter(s);
      return (c, fw, s);
    }

    Future<void> openPage(WidgetTester t, WalkieController c) async {
      await t.pumpWidget(MaterialApp(home: RadioSettingsPage(controller: c)));
      await t.pump();
    }

    Future<void> settleWrite(WidgetTester t) async {
      for (var i = 0; i < 300; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('rs-saved')).evaluate().isNotEmpty ||
            find.byKey(const Key('rs-failed')).evaluate().isNotEmpty) {
          return;
        }
      }
      fail('the write never finished');
    }

    Future<void> tapKey(WidgetTester t, String k) async {
      final f = find.byKey(Key(k));
      await t.ensureVisible(f);
      await t.pump();
      await t.tap(f);
      await t.pump();
    }

    bool switchOn(WidgetTester t) =>
        t.widget<SwitchListTile>(find.byKey(const Key('rs-public'))).value;

    String state(WidgetTester t) =>
        t.widget<Text>(find.byKey(const Key('rs-public-state'))).data!;

    testWidgets('off by default, below the relay switch, explained', (t) async {
      final (c, fw, _) = await world(t, radioOn());
      await openPage(t, c);
      expect(find.text('Show public nodes'), findsOneWidget);
      expect(switchOn(t), isFalse);
      expect(state(t), startsWith('Off.'));
      expect(find.text(radioPublicExplain), findsOneWidget);
      expect(find.text(radioPublicNote), findsOneWidget);
      final relayY = t.getTopLeft(find.byKey(const Key('rs-relay'))).dy;
      final pubY = t.getTopLeft(find.byKey(const Key('rs-public'))).dy;
      expect(pubY, greaterThan(relayY));
      expect(fw.log, isEmpty, reason: 'opening the page sends nothing');
    });

    testWidgets('on: confirm, one channel written, then listed; off again', (
      t,
    ) async {
      final (c, fw, s) = await world(t, radioOn());
      await openPage(t, c);
      await tapKey(t, 'rs-public');
      expect(find.byKey(const Key('rs-confirm-dialog')), findsOneWidget);
      expect(find.text(radioPublicConfirmOn), findsOneWidget);
      expect(find.textContaining('radio\'s ID'), findsOneWidget);
      await t.tap(find.byKey(const Key('rs-cancel')));
      await t.pumpAndSettle();
      expect(fw.log, isEmpty, reason: 'Cancel writes nothing');
      await tapKey(t, 'rs-public');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settleWrite(t);
      expect(find.byKey(const Key('rs-saved')), findsOneWidget);
      expect(fw.writes, ['begin', 'set_channel2', 'commit']);
      expect(fw.sentLora, isNull, reason: 'LoRa settings untouched');
      expect(switchOn(t), isTrue);
      expect(c.publicListenOn, isTrue);
      expect(c.publicListenShares, isFalse);
      // Not offered for linking, precision or sending.
      expect(c.radioChannels.map((x) => x.index), [0, 1]);
      expect(find.byKey(const Key('rs-prec-card-2')), findsNothing);
      expect(c.loraTransport.meshIndexOf!(meshPublicRef), isNull);
      expect(state(t), contains('No public radios heard yet'));
      // Heard: shown after the next redraw, with names when known.
      addExamplePublic(s);
      s.handle(heard(0xE0A10005, ch: 2));
      await t.pump(const Duration(seconds: 6));
      expect(state(t), 'Public radios heard: 5');
      expect(find.text('Example Name One (EX1)'), findsOneWidget);
      expect(find.textContaining('!e0a10001'), findsWidgets);
      expect(find.text('Public radio !e0a10003'), findsOneWidget);
      // Off: the channel is taken off.
      await tapKey(t, 'rs-public');
      expect(find.text(radioPublicConfirmOff), findsOneWidget);
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settleWrite(t);
      expect(fw.writes.last, 'commit');
      expect(fw.writes, contains('set_channel2'));
      expect(c.publicListenOn, isFalse);
      expect(switchOn(t), isFalse);
    });

    testWidgets('relay off: says it hears nothing until relay is on', (
      t,
    ) async {
      final (c, _, _) = await world(t, radioOn(slot: 0, withPublic: true));
      await openPage(t, c);
      expect(switchOn(t), isTrue);
      expect(state(t), contains('Turn on "Use the public frequency"'));
    });

    testWidgets('a failed write: plain sentence with Try again', (t) async {
      final fw = radioOn();
      for (var i = 2; i < meshMaxChannels; i++) {
        fw.channels[i] = chan(i, 2, 'Full $i', [i, 1, 2, 3]);
      }
      final (c, _, _) = await world(t, fw);
      await openPage(t, c);
      await tapKey(t, 'rs-public');
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settleWrite(t);
      expect(find.byKey(const Key('rs-failed')), findsOneWidget);
      expect(
        find.textContaining('Not saved because all 7 extra channel slots'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(c.publicListenOn, isFalse);
    });

    testWidgets('a public channel set up elsewhere that uploads is flagged', (
      t,
    ) async {
      final fw = radioOn();
      final settings = PbWriter()
        ..bytes(2, [1])
        ..string(3, 'LongFast')
        ..boolean(5, true);
      fw.channels[3] =
          (PbWriter()
                ..uint(1, 3)
                ..message(2, settings.toBytes())
                ..uint(3, 2))
              .toBytes();
      final (c, _, _) = await world(t, fw);
      await openPage(t, c);
      expect(switchOn(t), isTrue);
      expect(find.byKey(const Key('rs-public-shares')), findsOneWidget);
    });

    testWidgets('no radio: the section is not shown', (t) async {
      phone(t, w: 400, h: 2400, ts: 1.0);
      final c = await makeController(t);
      await openPage(t, c);
      expect(find.byKey(const Key('rs-public')), findsNothing);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V264_SHOTS'];
    if (dir == null) return;

    Future<void> save(WidgetTester t, String name) async {
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v264_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Future<void> shoot(
      WidgetTester t,
      String name,
      Fw fw, {
      bool examples = true,
    }) async {
      phone(t, w: 400, h: 1350, ts: 1.0);
      final c = await makeController(t);
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      s.nodes[Fw.myNode]!
        ..lat = 45.52
        ..lng = -122.68;
      if (examples && s.publicListenIndex != null) addExamplePublic(s);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.amber,
                  padding: const EdgeInsets.fromLTRB(8, 30, 8, 6),
                  child: const Text(
                    'EXAMPLE DATA: made-up radios, not real nodes',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.black,
                      fontFamily: 'Roboto',
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                Expanded(child: RadioSettingsPage(controller: c)),
              ],
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      // The relay switch at the top of the screen, the list below it.
      await t.ensureVisible(find.byKey(const Key('rs-relay')));
      await t.pump(const Duration(milliseconds: 300));
      await t.drag(find.byType(Scrollable).first, const Offset(0, 60));
      await t.pump(const Duration(milliseconds: 300));
      await save(t, name);
    }

    testWidgets('list', (t) async {
      await shoot(t, 'list', radioOn(withPublic: true));
    });
    testWidgets('relay off', (t) async {
      await shoot(t, 'relay_off', radioOn(slot: 0, withPublic: true));
    });
    testWidgets('off', (t) async {
      await shoot(t, 'off', radioOn(), examples: false);
    });
    testWidgets('confirm', (t) async {
      phone(t, w: 400, h: 900, ts: 1.0);
      final c = await makeController(t);
      final s = MeshtasticSession(radioOn());
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready
        ..session = s;
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: RadioSettingsPage(controller: c),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      final f = find.byKey(const Key('rs-public'));
      await t.ensureVisible(f);
      await t.pump();
      await t.tap(f);
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await save(t, 'confirm');
    });
  });
}
