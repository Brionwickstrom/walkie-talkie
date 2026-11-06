// v2.6.7: Radio GPS as the location source. Fake radio and made-up
// positions (example data); nothing here has run on a real radio.
//   V267_SHOTS=/workspace flutter test test/v267_radio_gps_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/friendly_error.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart' show RadioState;
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/location_source.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/connection_health.dart';
import 'package:walkie_talkie/ui/location_source_ui.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'messaging_fakes.dart' show FakeClock;
import 'trip_integration_test.dart' show FakeHost;

const myNode = 0x0A0B0C0D;

/// Example position (made up, near Portland).
Uint8List positionBytes({
  double lat = 45.5231,
  double lng = -122.6765,
  int? time,
  int source = PositionPb.sourceInternal,
  int hdop = 120,
  int sats = 9,
  int prec = 32,
}) {
  final w = PbWriter()
    ..fixed32(1, (lat * 1e7).round())
    ..fixed32(2, (lng * 1e7).round())
    ..uint(3, 55);
  if (time != null) w.fixed32(4, time);
  w
    ..uint(5, source)
    ..uint(12, hdop)
    ..uint(19, sats)
    ..uint(23, prec);
  return w.toBytes();
}

class _Wire implements MeshtasticWire {
  final writes = <Uint8List>[];
  @override
  Stream<void> get notifications => const Stream.empty();
  @override
  Future<Uint8List> read() async => Uint8List(0);
  @override
  Future<void> write(Uint8List toRadio) async => writes.add(toRadio);
}

class _Host extends FakeHost {
  _Host() : super(0x1111);
  int stops = 0;
  int locates = 0;
  @override
  Future<void> stopLocation() async => stops++;
  @override
  Future<Fix?> locateOnce() async {
    locates++;
    return null;
  }
}

RadioGpsState good(DateTime at, {int prec = 32, int src = 2, int hdop = 120}) =>
    RadioGpsState(
      connected: true,
      pos: PositionPb.decode(
        positionBytes(prec: prec, source: src, hdop: hdop),
      ),
      at: at,
      broadcastSecs: 60,
      smart: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('Position extra fields', () {
    test('time, source, HDOP, satellites, precision are read', () {
      final p = PositionPb.decode(
        positionBytes(time: 1793900000, source: 2, hdop: 150, prec: 32),
      )!;
      expect(p.lat, closeTo(45.5231, 1e-6));
      expect(p.time, 1793900000);
      expect(p.source, PositionPb.sourceInternal);
      expect(p.hdop, 150);
      expect(p.sats, 9);
      expect(p.precisionBits, 32);
      expect(p.alt, 55);
    });

    test('old position without the new fields still decodes', () {
      final raw = PositionPb(45.5, -122.6, alt: 10).encode();
      final p = PositionPb.decode(raw)!;
      expect(p.time, 0);
      expect(p.source, 0);
      expect(p.precisionBits, 0);
    });
  });

  group('session: the radio\'s own position, no request', () {
    late FakeClock clock;
    late MeshtasticSession s;
    late _Wire wire;
    setUp(() {
      clock = FakeClock();
      wire = _Wire();
      s = MeshtasticSession(wire, clock: clock.call)
        ..handle(FromRadio(myInfo: MyNodeInfoPb(myNode, 1)));
    });

    MeshPacketPb own(Uint8List payload, {int from = myNode}) => MeshPacketPb(
      from: from,
      to: meshBroadcast,
      decoded: MeshData(portnum: PortNum.position, payload: payload),
    );

    test('a broadcast copy sets the live position, at the receive time', () {
      var other = 0;
      s.packets.listen((_) => other++);
      s.handle(FromRadio(packet: own(positionBytes())));
      final o = s.ownPosition!;
      expect(o.live, isTrue);
      expect(o.at, clock.now);
      expect(o.pos.lat, closeTo(45.5231, 1e-6));
      expect(s.received, 0, reason: 'our own packet is not "received"');
      expect(wire.writes, isEmpty, reason: 'nothing is asked for');
      expect(other, 0);
    });

    test('an older fix time in the packet is kept', () {
      final t = clock.now.subtract(const Duration(minutes: 5));
      s.handle(
        FromRadio(
          packet: own(positionBytes(time: t.millisecondsSinceEpoch ~/ 1000)),
        ),
      );
      expect(s.ownPosition!.at, t);
    });

    test('node list copy: age from its time; unknown age is not used', () {
      final t = clock.now.subtract(const Duration(minutes: 3));
      final withTime = NodeInfoPb(
        num: myNode,
        position: PositionPb.decode(
          positionBytes(time: t.millisecondsSinceEpoch ~/ 1000),
        ),
      );
      s.handle(FromRadio(nodeInfo: withTime));
      expect(s.ownPosition!.live, isFalse);
      expect(s.ownPosition!.at, t);
      s.handle(
        FromRadio(
          nodeInfo: NodeInfoPb(
            num: myNode,
            position: PositionPb.decode(positionBytes()),
          ),
        ),
      );
      expect(s.ownPosition!.at, isNull);
      // A live one is never replaced by the node list.
      s.handle(FromRadio(packet: own(positionBytes(lat: 45.6))));
      s.handle(FromRadio(nodeInfo: withTime));
      expect(s.ownPosition!.live, isTrue);
      expect(s.ownPosition!.pos.lat, closeTo(45.6, 1e-6));
    });

    test('other nodes\' positions do not touch it', () {
      s.handle(FromRadio(packet: own(positionBytes(), from: 0x55)));
      expect(s.ownPosition, isNull);
    });
  });

  group('choosing the GPS', () {
    final now = DateTime(2026, 11, 6, 9);

    test('max age: 2 min, longer with smart broadcast (up to 16 min)', () {
      expect(radioFixMaxAgeFor(), const Duration(minutes: 2));
      expect(
        radioFixMaxAgeFor(broadcastSecs: 900, smart: false),
        const Duration(minutes: 2),
      );
      expect(
        radioFixMaxAgeFor(broadcastSecs: 900, smart: true),
        const Duration(minutes: 16),
      );
      expect(
        radioFixMaxAgeFor(broadcastSecs: 300, smart: true),
        const Duration(minutes: 6),
      );
      expect(
        radioFixMaxAgeFor(broadcastSecs: 30, smart: true),
        const Duration(minutes: 2),
      );
      expect(
        radioFixMaxAgeFor(broadcastSecs: radioPositionNever, smart: true),
        const Duration(minutes: 2),
      );
    });

    test('Auto: radio while good, phone otherwise, with the reason', () {
      LocationChoice auto(RadioGpsState r, {bool fast = false}) =>
          chooseLocation(
            setting: LocationSource.auto,
            radio: r,
            now: now,
            needPhone: fast,
          );
      final ok = auto(good(now.subtract(const Duration(seconds: 40))));
      expect(ok.usingRadio, isTrue);
      expect(ok.phoneGpsAllowed, isFalse);
      expect(ok.title, 'Location: Radio GPS (Bluetooth)');
      expect(ok.subtitle, contains('battery'));

      final stale = auto(good(now.subtract(const Duration(minutes: 3))));
      expect(stale.active, ActiveLocation.phone);
      expect(stale.why, RadioGpsWhy.stale);
      expect(stale.reason, contains('3 min old'));

      expect(auto(RadioGpsState.none).why, RadioGpsWhy.notConnected);
      expect(
        auto(good(now, src: PositionPb.sourceManual)).why,
        RadioGpsWhy.fixedPosition,
      );
      expect(
        auto(good(now, src: PositionPb.sourceExternal)).why,
        RadioGpsWhy.fromPhone,
      );
      final blur = auto(good(now, prec: 13));
      expect(blur.why, RadioGpsWhy.blurred);
      expect(blur.reason, contains('2.8 km'));
      expect(auto(good(now, hdop: 5000)).why, RadioGpsWhy.weak);
      expect(
        auto(const RadioGpsState(connected: true, sharing: false)).why,
        RadioGpsWhy.notSharing,
      );
      expect(
        auto(const RadioGpsState(connected: true)).why,
        RadioGpsWhy.noPosition,
      );
      final fast = auto(good(now), fast: true);
      expect(fast.active, ActiveLocation.phone);
      expect(fast.why, RadioGpsWhy.needPhone);
    });

    test('Radio GPS only never allows the phone; Phone only ignores radio', () {
      final r = chooseLocation(
        setting: LocationSource.radio,
        radio: good(now.subtract(const Duration(minutes: 5))),
        now: now,
        needPhone: true,
      );
      expect(r.active, ActiveLocation.none);
      expect(r.phoneGpsAllowed, isFalse);
      expect(r.title, 'Location: waiting for radio GPS');
      final p = chooseLocation(
        setting: LocationSource.phone,
        radio: good(now),
        now: now,
      );
      expect(p.active, ActiveLocation.phone);
      expect(p.phoneGpsAllowed, isTrue);
      expect(p.reason, isNull);
    });

    test('USB link is named', () {
      final g = good(now);
      final c = chooseLocation(
        setting: LocationSource.auto,
        radio: RadioGpsState(connected: true, link: 'USB', pos: g.pos, at: now),
        now: now,
      );
      expect(c.title, 'Location: Radio GPS (USB)');
    });
  });

  group('plain errors (friendly_error)', () {
    final now = DateTime(2026, 11, 6, 9);
    test('not connected: Connect radio; Radio only adds Use Auto', () {
      final e = radioGpsError(
        chooseLocation(
          setting: LocationSource.radio,
          radio: RadioGpsState.none,
          now: now,
        ),
      )!;
      expect(e.message, startsWith('No location: Radio GPS only is on'));
      expect(e.fix, FixAction.connectRadio);
      expect(e.fix2, FixAction.usePhoneGps);
      expect(e.details, isNull);
    });
    test('blurred: Radio settings', () {
      final e = radioGpsError(
        chooseLocation(
          setting: LocationSource.auto,
          radio: good(now, prec: 13),
          now: now,
        ),
      )!;
      expect(e.message, startsWith("Using the phone's GPS: the radio sends"));
      expect(e.fix, FixAction.openRadioSettings);
    });
    test('no error while the radio is used, on purpose, or Phone only', () {
      expect(
        radioGpsError(
          chooseLocation(
            setting: LocationSource.auto,
            radio: good(now),
            now: now,
          ),
        ),
        isNull,
      );
      expect(
        radioGpsError(
          chooseLocation(
            setting: LocationSource.auto,
            radio: good(now),
            now: now,
            needPhone: true,
          ),
        ),
        isNull,
      );
      expect(
        radioGpsError(
          chooseLocation(
            setting: LocationSource.phone,
            radio: RadioGpsState.none,
            now: now,
          ),
        ),
        isNull,
      );
    });
  });

  group('setting is saved', () {
    test('ls round-trips; default Auto is not written', () {
      final s = TripSettings();
      expect(s.locationSource, 'auto');
      expect(s.encode(), isNot(contains('"ls"')));
      s.locationSource = 'radio';
      expect(TripSettings.decode(s.encode()).locationSource, 'radio');
      expect(TripSettings.decode('{"ls":"bogus"}').locationSource, 'auto');
      expect(LocationSource.fromId('phone'), LocationSource.phone);
      expect(LocationSource.fromId(null), LocationSource.auto);
    });
  });

  group('TripController', () {
    late Directory dir;
    late FakeClock clock;
    late _Host host;
    late TripController t;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v267');
      clock = FakeClock();
      host = _Host();
      t = TripController(
        host: host,
        settings: TripSettings(tripMode: true),
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

    Fix phone(double lat) =>
        Fix(GeoPoint(lat, -122.6), clock.now, accuracyM: 5);

    test('Auto: radio fix used, phone GPS stopped; back when stale', () async {
      expect(t.locationInterval, isNotNull, reason: 'phone GPS on at start');
      t.onFix(phone(45.40));
      expect(t.myFix!.pos.lat, 45.40);
      t.setRadioGps(good(clock.now));
      await pumpEventQueue();
      expect(t.location.usingRadio, isTrue);
      expect(t.myFix!.pos.lat, closeTo(45.5231, 1e-6));
      expect(t.locationInterval, isNull, reason: 'phone GPS off');
      expect(host.stops, greaterThan(0));
      // A late phone fix is kept aside, not used.
      t.onFix(phone(45.41));
      expect(t.phoneFix!.pos.lat, 45.41);
      expect(t.myFix!.pos.lat, closeTo(45.5231, 1e-6));
      // Range logging still pairs with the phone's own fix.
      expect(t.rangeFix!.pos.lat, 45.41);
      // 3 minutes with no new radio fix: phone again.
      final starts = host.locationStarts.length;
      clock.advance(const Duration(minutes: 3));
      t.tick();
      await pumpEventQueue();
      expect(t.location.active, ActiveLocation.phone);
      expect(t.location.why, RadioGpsWhy.stale);
      expect(host.locationStarts.length, greaterThan(starts));
      t.onFix(phone(45.42));
      expect(t.myFix!.pos.lat, 45.42);
    });

    test('radio disconnect falls back to the phone at once', () async {
      t.setRadioGps(good(clock.now));
      await pumpEventQueue();
      expect(t.location.usingRadio, isTrue);
      t.setRadioGps(RadioGpsState.none);
      await pumpEventQueue();
      expect(t.location.active, ActiveLocation.phone);
      expect(t.locationInterval, isNotNull);
    });

    test('Phone GPS only: the radio is never used', () async {
      await t.setLocationSource(LocationSource.phone);
      t.onFix(phone(45.40));
      t.setRadioGps(good(clock.now));
      await pumpEventQueue();
      expect(t.myFix!.pos.lat, 45.40);
      expect(t.locationInterval, isNotNull);
    });

    test(
      'Radio GPS only: phone GPS off, phone not asked, range uses radio',
      () async {
        await t.setLocationSource(LocationSource.radio);
        await pumpEventQueue();
        expect(t.locationInterval, isNull);
        t.setRadioGps(good(clock.now));
        await pumpEventQueue();
        expect(t.rangeFix!.pos.lat, closeTo(45.5231, 1e-6));
        clock.advance(const Duration(minutes: 10));
        t.tick();
        await pumpEventQueue();
        expect(t.location.active, ActiveLocation.none);
        expect(t.locationInterval, isNull, reason: 'phone GPS stays off');
        final before = host.locates;
        await t.startSos();
        // SOS is the one exception: one phone fix when none is fresh; the
        // phone's GPS still does not keep running.
        expect(host.locates, before + 1);
        await pumpEventQueue();
        expect(t.locationInterval, isNull);
      },
    );

    test('Auto: an SOS brings the phone GPS back', () async {
      t.setRadioGps(good(clock.now));
      await pumpEventQueue();
      expect(t.locationInterval, isNull);
      await t.startSos();
      await pumpEventQueue();
      expect(t.location.why, RadioGpsWhy.needPhone);
      expect(t.locationInterval, isNotNull);
    });
  });

  group('Settings search', () {
    test('gps / location source / radio gps find it', () {
      for (final q in ['radio gps', 'location source', 'gps']) {
        final r = searchSettings(q);
        expect(r.map((e) => e.id), contains('location-source'), reason: q);
      }
      expect(searchSettings('location source').first.id, 'location-source');
      expect(searchSettings('radio gps').first.id, 'location-source');
      final e = settingsIndex.firstWhere((e) => e.id == 'location-source');
      expect(e.home, SettingsHome.settings);
      expect(e.path, 'Settings › Long-range radio (Meshtastic)');
      expect(e.words, containsAll(['gps', 'location source', 'radio gps']));
    });

    test('anchor is on the Settings sheet radio section', () {
      final src = File('lib/ui/radio_settings.dart').readAsStringSync();
      expect(
        RegExp(r"SettingAnchor\(\s*id:\s*'location-source'").hasMatch(src),
        isTrue,
      );
      expect(
        File('lib/ui/location_source_ui.dart').readAsStringSync(),
        contains("Text('Location source')"),
      );
    });
  });

  group('widgets (example data)', () {
    final now = DateTime(2026, 11, 6, 9);

    testWidgets('picker shows the source in use and switches', (t) async {
      final picked = <LocationSource>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationSourceSection(
              choice: chooseLocation(
                setting: LocationSource.auto,
                radio: good(now.subtract(const Duration(seconds: 20))),
                now: now,
              ),
              onChanged: picked.add,
            ),
          ),
        ),
      );
      expect(find.text('Location source'), findsOneWidget);
      expect(find.text('In use: Radio GPS (Bluetooth)'), findsOneWidget);
      expect(find.byKey(const Key('location-source-battery')), findsOneWidget);
      expect(find.byKey(const Key('location-source-error')), findsNothing);
      await t.tap(find.byKey(const Key('location-source-radio')));
      expect(picked, [LocationSource.radio]);
    });

    testWidgets('Radio only without a radio: plain error with fixes', (
      t,
    ) async {
      final fixes = <FixAction>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationSourceSection(
              choice: chooseLocation(
                setting: LocationSource.radio,
                radio: RadioGpsState.none,
                now: now,
              ),
              onChanged: (_) {},
              onFix: fixes.add,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('location-source-error')), findsOneWidget);
      expect(find.text('Connect radio'), findsOneWidget);
      await t.tap(find.text('Use Auto'));
      expect(fixes, [FixAction.usePhoneGps]);
    });

    testWidgets('connection sheet names the source', (t) async {
      final h = ConnectionHealth.from(
        now: now,
        bestKind: TransportKind.internet,
        internet: TransportStatus.running,
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConnectionHealthSheet(
                health: h,
                location: chooseLocation(
                  setting: LocationSource.auto,
                  radio: good(now.subtract(const Duration(seconds: 30))),
                  now: now,
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Location: Radio GPS (Bluetooth)'), findsOneWidget);
      expect(find.textContaining('fix 30 s old'), findsOneWidget);
    });

    testWidgets('sheet without a location line is unchanged', (t) async {
      final h = ConnectionHealth.from(
        now: now,
        internet: TransportStatus.running,
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConnectionHealthSheet(health: h)),
        ),
      );
      expect(find.byKey(const Key('location-source-line')), findsNothing);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V267_SHOTS'];
    if (dir == null) return;
    final now = DateTime(2026, 11, 6, 9);

    Future<void> shot(WidgetTester t, String name, Widget body) async {
      t.view.physicalSize = const Size(400, 760) * 2;
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: Scaffold(
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.amber,
                    padding: const EdgeInsets.fromLTRB(8, 30, 8, 6),
                    child: const Text(
                      'EXAMPLE DATA: made-up radio and positions',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black, fontSize: 13),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: body,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v267_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    testWidgets('setting: Auto using radio', (t) async {
      await shot(
        t,
        'setting_auto_radio',
        LocationSourceSection(
          choice: chooseLocation(
            setting: LocationSource.auto,
            radio: good(now.subtract(const Duration(seconds: 25))),
            now: now,
          ),
          onChanged: (_) {},
        ),
      );
    });

    testWidgets('setting: Auto falling back (blurred)', (t) async {
      await shot(
        t,
        'setting_auto_blurred',
        LocationSourceSection(
          choice: chooseLocation(
            setting: LocationSource.auto,
            radio: good(now, prec: 13),
            now: now,
          ),
          onChanged: (_) {},
        ),
      );
    });

    testWidgets('setting: Radio only, no radio', (t) async {
      await shot(
        t,
        'setting_radio_only_error',
        LocationSourceSection(
          choice: chooseLocation(
            setting: LocationSource.radio,
            radio: RadioGpsState.none,
            now: now,
          ),
          onChanged: (_) {},
        ),
      );
    });

    testWidgets('connection sheet', (t) async {
      await shot(
        t,
        'connection_sheet',
        ConnectionHealthSheet(
          health: ConnectionHealth.from(
            now: now,
            bestKind: TransportKind.internet,
            internet: TransportStatus.running,
            internetText: 'Internet via Wi-Fi',
            phoneNet: 'wifi',
            radio: const RadioHealth(
              paired: true,
              state: RadioState.ready,
              link: RadioLinkKind.bluetooth,
            ),
          ),
          location: chooseLocation(
            setting: LocationSource.auto,
            radio: good(now.subtract(const Duration(seconds: 25))),
            now: now,
          ),
        ),
      );
    });
  });
}
