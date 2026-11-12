// v2.6.16: speed labels on the Trip map.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/speed_label.dart';
import 'package:walkie_talkie/trip/speed_sample.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/friend_marker.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';
import 'package:walkie_talkie/ui/trip_page.dart';
import 'package:walkie_talkie/ui/wx_map_layer.dart';
import 'package:walkie_talkie/weather/wx_alert.dart';
import 'package:walkie_talkie/weather/wx_areas.dart';

import 'home_layout_test.dart' show loadFonts;
import 'messaging_fakes.dart' show FakeClock;
import 'trip_integration_test.dart' show FakeHost;
import 'v2614_wx_map_test.dart' show box, sampleAlert;

List<String> ids(String q) => [for (final e in searchSettings(q)) e.id];

const _here = GeoPoint(45.52, -122.67);

/// 42 mph, the same factor the label uses.
const _mph42 = 42 / 2.23694;

Uint8List _position({int? kmh, int? time}) {
  final w = PbWriter()
    ..fixed32(1, (45.5 * 1e7).round())
    ..fixed32(2, (-122.6 * 1e7).round());
  if (time != null) w.fixed32(4, time);
  if (kmh != null) w.uint(15, kmh);
  return w.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('the label', () {
    final t0 = DateTime(2026, 11, 12, 12);

    String? label({
      double? speed = _mph42,
      DateTime? at,
      bool noTime = false,
      Duration? age,
      bool imperial = true,
      Duration fresh = speedLabelFreshLive,
      String name = 'Yeti',
    }) {
      return speedLabelText(
        name: name,
        speedMps: speed,
        at: noTime ? null : (at ?? (age == null ? t0 : t0.subtract(age))),
        now: t0,
        imperial: imperial,
        freshFor: fresh,
      );
    }

    test('shown when a speed is present and the fix is young', () {
      expect(label(), 'Yeti · 42 mph');
      expect(label(age: const Duration(seconds: 119)), 'Yeti · 42 mph');
    });

    test('hidden when the speed is missing or the fix is old', () {
      expect(label(speed: null), isNull);
      expect(label(noTime: true), isNull);
      expect(label(age: speedLabelFreshLive), isNull);
      expect(label(age: const Duration(minutes: 3)), isNull);
    });

    test('miles and kilometres follow the trip switch', () {
      expect(formatSpeed(_mph42, imperial: true), '42 mph');
      expect(formatSpeed(_mph42, imperial: false), '68 km/h');
      expect(label(imperial: false), 'Yeti · 68 km/h');
    });

    test('a radio or LoRa fix stays young for ten minutes', () {
      expect(speedFreshFor(TransportKind.ble), speedLabelFreshLive);
      expect(speedFreshFor(TransportKind.lora), speedLabelFreshRadio);
      expect(
        label(age: const Duration(minutes: 9), fresh: speedLabelFreshRadio),
        'Yeti · 42 mph',
      );
      expect(
        label(age: const Duration(minutes: 10), fresh: speedLabelFreshRadio),
        isNull,
      );
    });
  });

  group('Meshtastic ground_speed', () {
    test('field 15 is integer km/h and converts to m/s', () {
      final p = PositionPb.decode(_position(kmh: 68))!;
      expect(p.groundSpeedKmh, 68);
      expect(p.groundSpeedMps, closeTo(68 / 3.6, 1e-9));
      expect(formatSpeed(p.groundSpeedMps!, imperial: true), '42 mph');
      expect(formatSpeed(p.groundSpeedMps!, imperial: false), '68 km/h');
    });

    test('a position without the field has no speed', () {
      final p = PositionPb.decode(_position())!;
      expect(p.groundSpeedKmh, isNull);
      expect(p.groundSpeedMps, isNull);
      expect(p.lat, closeTo(45.5, 1e-6));
    });

    test('the fix time is the radio time, else when it was heard', () {
      final heard = DateTime(2026, 11, 12, 12);
      final ago = heard.subtract(const Duration(minutes: 4));
      expect(
        radioPositionAt(
          timeSeconds: ago.millisecondsSinceEpoch ~/ 1000,
          heard: heard,
        ),
        ago,
      );
      expect(radioPositionAt(timeSeconds: 0, heard: heard), heard);
    });
  });

  group('radios on the map', () {
    final now = DateTime.utc(2026, 11, 9, 18, 30);
    final areas = wxMapAreas(
      alerts: [
        sampleAlert(
          key: 'w',
          event: 'Tornado Warning',
          severity: WxSeverity.severe,
          polygons: box(45.4, -122.8, 45.6, -122.5),
        ),
      ],
      zones: const {},
      now: now,
    );

    WxNodeSpot spot(
      int id,
      GeoPoint pos, {
      bool public = false,
      bool self = false,
    }) {
      return WxNodeSpot(
        id: id,
        name: 'Yeti',
        pos: pos,
        public: public,
        self: self,
        speedMps: 68 / 3.6,
        posAt: now.subtract(const Duration(minutes: 3)),
      );
    }

    test('a positioned radio is drawn outside a weather area', () {
      expect(areas, isNotEmpty);
      final outside = spot(8, const GeoPoint(44.0, -122.6));
      final inside = spot(7, const GeoPoint(45.5, -122.6));
      expect(wxAreasAt(outside.pos, areas), isEmpty);
      expect(wxAreasAt(inside.pos, areas), isNotEmpty);
      final drawn = radioSpotsToDraw(
        nodes: [
          outside,
          inside,
          spot(9, const GeoPoint(45.5, -122.6), public: true),
          spot(1, const GeoPoint(45.5, -122.6), self: true),
          spot(4, const GeoPoint(44.2, -122.6)),
        ],
        skipIds: {4},
      );
      expect(drawn.map((n) => n.id), [8, 7]);
    });

    test('a radio with no position is not a map spot', () {
      expect(
        spotForRadio(
          id: 3,
          longName: 'Quiet',
          shortName: '',
          lat: null,
          lng: null,
          public: false,
          self: false,
        ),
        isNull,
      );
      expect(
        spotForRadio(
          id: 3,
          longName: '',
          shortName: '',
          lat: 0,
          lng: 0,
          public: false,
          self: false,
        ),
        isNull,
      );
      final s = spotForRadio(
        id: 3,
        longName: '',
        shortName: 'Rd',
        lat: 45.1,
        lng: -122.2,
        public: false,
        self: false,
        speedMps: 10,
        posAt: now,
      )!;
      expect(s.name, 'Rd');
      expect(radioSpotsToDraw(nodes: [s], skipIds: const {}), [s]);
    });
  });

  group('the session keeps a speed it was already sent', () {
    test('a position packet stores km/h as m/s and the time', () {
      final clock = FakeClock();
      final s = MeshtasticSession(_Wire(), clock: clock.call);
      final ago = clock.now.subtract(const Duration(minutes: 4));
      s.handle(
        FromRadio(
          packet: MeshPacketPb(
            from: 99,
            to: meshBroadcast,
            decoded: MeshData(
              portnum: PortNum.position,
              payload: _position(
                kmh: 68,
                time: ago.millisecondsSinceEpoch ~/ 1000,
              ),
            ),
          ),
        ),
      );
      final n = s.nodes[99]!;
      expect(n.lat, closeTo(45.5, 1e-6));
      expect(n.speedMps, closeTo(68 / 3.6, 1e-9));
      expect(n.posAt, ago);
      expect(s.received, 1);

      s.handle(
        FromRadio(
          packet: MeshPacketPb(
            from: 99,
            to: meshBroadcast,
            decoded: MeshData(portnum: PortNum.position, payload: _position()),
          ),
        ),
      );
      expect(s.nodes[99]!.speedMps, isNull);
      expect(s.nodes[99]!.posAt, clock.now);
    });
  });

  group('show my speed', () {
    test('defaults off and is saved when turned on', () {
      final fresh = TripSettings();
      expect(fresh.showMySpeed, isFalse);
      expect(TripSettings.decode(fresh.encode()).showMySpeed, isFalse);
      expect(fresh.encode().contains('sms'), isFalse);
      fresh.showMySpeed = true;
      final back = TripSettings.decode(fresh.encode());
      expect(back.showMySpeed, isTrue);
      expect(TripSettings.decode('{"tm":true}').showMySpeed, isFalse);
    });

    testWidgets('the switch starts off and the new value is saved', (t) async {
      final dir = Directory.systemTemp.createTempSync('v2616');
      final c = TripController(
        host: FakeHost(1),
        settings: TripSettings(),
        dir: dir,
        userAgent: 'test',
      );
      addTearDown(() {
        c.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: c,
              builder: (_, _) => ShowMySpeedTile(
                value: c.settings.showMySpeed,
                onChanged: (v) => c.update((s) => s.showMySpeed = v),
              ),
            ),
          ),
        ),
      );
      SwitchListTile tile() =>
          t.widget<SwitchListTile>(find.byKey(const Key('showMySpeed')));
      expect(tile().value, isFalse);
      expect(find.text('Show my speed on my dot'), findsOneWidget);
      await t.tap(find.byKey(const Key('showMySpeed')));
      await t.pump();
      expect(c.settings.showMySpeed, isTrue);
      expect(TripSettings.decode(c.settings.encode()).showMySpeed, isTrue);
      expect(tile().value, isTrue);
    });
  });

  group('markers', () {
    Future<TripController> trip() async {
      final dir = Directory.systemTemp.createTempSync('v2616m');
      final c = TripController(
        host: FakeHost(1),
        settings: TripSettings(),
        dir: dir,
        userAgent: 'test',
      );
      addTearDown(() {
        c.dispose();
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      return c;
    }

    Future<void> show(WidgetTester t, Marker m) {
      return t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: m.width, height: m.height, child: m.child),
            ),
          ),
        ),
      );
    }

    testWidgets('an app user shows a fresh speed and hides an old one', (
      t,
    ) async {
      final c = await trip();
      final clock = FakeClock();
      c.people[7] = PersonPos(7, _here, clock.now, TransportKind.ble, 1)
        ..speedMps = _mph42;
      await show(t, friendMarker(c, c.people[7]!, 'Yeti', now: clock.now));
      expect(find.text('Yeti · 42 mph'), findsOneWidget);
      expect(find.byKey(const Key('speed7')), findsOneWidget);

      clock.advance(const Duration(minutes: 3));
      c.people[7]!.at = clock.now.subtract(const Duration(minutes: 3));
      await show(t, friendMarker(c, c.people[7]!, 'Yeti', now: clock.now));
      expect(find.text('Yeti · 42 mph'), findsNothing);
      expect(find.textContaining('Yeti ·'), findsOneWidget);
    });

    testWidgets('kilometres when the trip is set that way', (t) async {
      final c = await trip();
      c.settings.imperial = false;
      final now = DateTime(2026, 11, 12, 12);
      c.people[7] = PersonPos(7, _here, now, TransportKind.lan, 1)
        ..speedMps = _mph42;
      await show(t, friendMarker(c, c.people[7]!, 'Yeti', now: now));
      expect(find.text('Yeti · 68 km/h'), findsOneWidget);
    });

    testWidgets('a LoRa fix is still labelled at nine minutes', (t) async {
      final c = await trip();
      final now = DateTime(2026, 11, 12, 12);
      c.people[7] = PersonPos(
        7,
        _here,
        now.subtract(const Duration(minutes: 9)),
        TransportKind.lora,
        2,
      )..speedMps = _mph42;
      await show(t, friendMarker(c, c.people[7]!, 'Yeti', now: now));
      expect(find.text('Yeti · 42 mph'), findsOneWidget);
    });

    testWidgets('a radio outside a weather area keeps its speed, no badge', (
      t,
    ) async {
      final now = DateTime.utc(2026, 11, 9, 18, 30);
      final areas = wxMapAreas(
        alerts: [
          sampleAlert(
            key: 'w',
            event: 'Tornado Warning',
            severity: WxSeverity.severe,
            polygons: box(45.4, -122.8, 45.6, -122.5),
          ),
        ],
        zones: const {},
        now: now,
      );
      final spot = WxNodeSpot(
        id: 8,
        name: 'Ridge',
        pos: const GeoPoint(44.0, -122.6),
        speedMps: 68 / 3.6,
        posAt: now.subtract(const Duration(minutes: 3)),
      );
      expect(wxAreasAt(spot.pos, areas), isEmpty);
      final label = speedLabelText(
        name: spot.name,
        speedMps: spot.speedMps,
        at: spot.posAt,
        now: now,
        imperial: true,
        freshFor: speedLabelFreshRadio,
      );
      expect(label, 'Ridge · 42 mph');
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 150,
                height: 72,
                child: WxNodeMarker(
                  name: spot.name,
                  alertLine: wxInAlertLine(wxAreasAt(spot.pos, areas)),
                  badgeKey: const Key('wx-badge-node-8'),
                  speedLabel: label,
                  speedKey: const Key('speed-radio-8'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Ridge · 42 mph'), findsOneWidget);
      expect(find.byKey(const Key('wx-badge-node-8')), findsNothing);
      expect(find.text('Ridge'), findsOneWidget);
    });
  });

  group('search and the version', () {
    test('settings search finds the own-dot switch', () {
      expect(ids('my speed'), contains('show-my-speed'));
      expect(ids('show my speed'), ['show-my-speed']);
      final entry = settingsIndex.firstWhere((e) => e.id == 'show-my-speed');
      expect(entry.home, SettingsHome.trip);
      expect(entry.label, 'Show my speed on my dot');
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      expect(home, contains("id == 'show-my-speed'"));
      expect(home, contains('revealMySpeedSetting'));
      final page = File('lib/ui/trip_page.dart').readAsStringSync();
      expect(page, contains(entry.label));
    });

    test('version 2.6.16+76 is in the changelog and the readme', () {
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('version: 2.6.16+76'),
      );
      expect(File('CHANGELOG.md').readAsStringSync(), contains('2.6.16+76'));
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains('## v2.6.16: Speed labels on the Trip map'));
      expect(readme, contains('ground_speed'));
      expect(readme, contains('SAMPLE_SPEED'));
    });

    test('sample speeds are debug-only', () {
      final src = File('lib/trip/speed_sample.dart').readAsStringSync();
      expect(src, contains('debug && enabled'));
      expect(sampleSpeedActive(debug: false, enabled: true), isFalse);
      expect(sampleSpeedActive(debug: true, enabled: false), isFalse);
      expect(sampleSpeedActive(debug: true, enabled: true), isTrue);
    });
  });
}

class _Wire implements MeshtasticWire {
  @override
  Stream<void> get notifications => const Stream.empty();
  @override
  Future<Uint8List> read() async => Uint8List(0);
  @override
  Future<void> write(Uint8List toRadio) async {}
}
