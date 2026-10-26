// v1.8.1: Offline power save (which subsystems go off and come back) and
// the Trip tab's full-screen map and guarded SOS button.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/power_plan.dart';
import 'package:walkie_talkie/core/mesh.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/friends/friend_links.dart';
import 'package:walkie_talkie/main.dart' show OfflineDim;
import 'package:walkie_talkie/transports/wifi_direct_transport.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/trip_widgets.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart' show FakeClock;
import 'trip_integration_test.dart' show FakeHost, me, here;

class RecordingWifiDirect implements WifiDirectPlatform {
  final ctl = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final intervals = <Duration>[];
  @override
  Stream<Map<String, Object?>> get events => ctl.stream;
  @override
  Future<String?> start(int nodeId) async => null;
  @override
  Future<void> stop() async {}
  @override
  Future<void> connect(String address, {int ownerIntent = 0}) async {}
  @override
  Future<void> setDiscoveryInterval(Duration every) async =>
      intervals.add(every);
}

void main() {
  group('PowerPlan', () {
    test('normal: everything on', () {
      const p = PowerPlan();
      expect(p.internetRelay, isTrue);
      expect(p.networkChangeReconnects, isTrue);
      expect(p.lanSweeps, isTrue);
      expect(p.wifiDirectAutoDiscovery, isTrue);
      expect(p.liveLocation, isTrue);
      expect(p.mapTileDownloads, isTrue);
      expect(p.darkDimUi, isFalse);
      expect(p.bleScan, isNull, reason: 'continuous scanning');
      expect(p.helloInterval(const Duration(seconds: 1)).inSeconds, 1);
    });

    test('offline: network things off, the essentials stay on', () {
      const p = PowerPlan(offline: true);
      expect(p.internetRelay, isFalse);
      expect(p.networkChangeReconnects, isFalse);
      expect(p.lanSweeps, isFalse);
      expect(p.wifiDirectAutoDiscovery, isFalse);
      expect(p.liveLocation, isFalse);
      expect(p.mapTileDownloads, isFalse);
      expect(p.weatherAutoRefresh, isFalse);
      expect(p.rttPings, isFalse);
      expect(p.darkDimUi, isTrue);
      expect(p.keepScreenOn, isFalse);
      expect(p.transportSaver, isTrue, reason: 'stacks on battery saver');
      // Still working.
      expect(p.pushToTalk && p.receive && p.meshRelay, isTrue);
      expect(p.loraRadio && p.sos && p.quickMessages, isTrue);
      // Slower, but inside the Bluetooth (8 s) and mesh windows.
      expect(
        p.helloInterval(const Duration(seconds: 1)),
        PowerPlan.offlineHello,
      );
      expect(PowerPlan.offlineHello < const Duration(seconds: 5), isTrue);
      expect(p.bleScan!.on, const Duration(seconds: 5));
      expect(
        p.bleScan!.idle > const PowerPlan(saver: true).bleScan!.idle,
        isTrue,
      );
      expect(p.wifiDirectDiscovery, const Duration(minutes: 15));
      // GPS slower, SOS still full speed.
      expect(p.gpsInterval(visible: false, sosActive: false).inSeconds, 90);
      expect(p.gpsInterval(visible: true, sosActive: false).inSeconds, 15);
      expect(p.gpsInterval(visible: false, sosActive: true).inSeconds, 5);
      // Check-ins doubled, capped under the 20 min lost-contact alert.
      expect(p.checkInMinutes(5), 10);
      expect(p.checkInMinutes(10), 15);
      expect(p.checkInMinutes(30), 30);
      expect(p.checkInMinutes(0), 0);
      expect(p.estimate, contains('estimate'));
    });

    test('saver alone keeps the internet relay', () {
      const p = PowerPlan(saver: true);
      expect(p.internetRelay, isTrue);
      expect(p.transportSaver, isTrue);
      expect(p.liveLocation, isTrue);
      expect(p.checkInMinutes(5), 5);
    });
  });

  group('TransportManager offline power save', () {
    late FakeTransport lan, ble, net;
    late TransportManager m;
    setUp(() async {
      lan = FakeTransport(TransportKind.lan);
      ble = FakeTransport(TransportKind.ble);
      net = FakeTransport(TransportKind.internet);
      m = TransportManager(
        transports: [lan, ble, net],
        localNodeId: me,
        localName: 'Me',
      );
    });
    tearDown(() => m.dispose());

    test('stops the internet relay, keeps nearby links, restores', () async {
      await m.start();
      expect(net.status, TransportStatus.running);
      await m.setOfflineSaver(true);
      expect(m.offlineSaver, isTrue);
      expect(net.status, TransportStatus.stopped);
      expect(lan.status, TransportStatus.running);
      expect(ble.status, TransportStatus.running);
      expect(lan.saver && ble.saver, isTrue, reason: 'implies saver');
      expect(m.currentHelloInterval, PowerPlan.offlineHello);
      expect(m.mesh.timeoutScale, 2);

      await m.setOfflineSaver(false);
      expect(net.status, TransportStatus.running);
      expect(lan.saver, isFalse);
      expect(m.mesh.timeoutScale, 1);
      expect(m.currentHelloInterval, m.helloInterval);
    });

    test('stacks with battery saver', () async {
      await m.setPowerSaver(true);
      await m.setOfflineSaver(true);
      await m.setOfflineSaver(false);
      expect(lan.saver, isTrue, reason: 'back to the saver setting');
      expect(m.currentHelloInterval, TransportManager.saverHelloInterval);
    });

    test('starting while offline leaves the relay off', () async {
      await m.setOfflineSaver(true);
      await m.start();
      expect(net.status, TransportStatus.stopped);
      expect(lan.status, TransportStatus.running);
    });

    test('mesh timeout scale is settable (offline trusts neighbours 2x)', () {
      var now = DateTime(2026);
      final r = MeshRouter(localId: 1, clock: () => now)..timeoutScale = 2;
      expect(r.neighbourTimeout, const Duration(seconds: 5));
      // The scale is applied inside; just make sure it is settable.
      now = now.add(const Duration(seconds: 1));
      expect(r.directNeighbours(), isEmpty);
    });
  });

  test('friend relay rooms close offline and reopen after', () async {
    final opened = <String>[];
    final links = FriendLinks(
      localId: 7,
      radio: ManagerFriendRadio(
        TransportManager(
          transports: [FakeTransport(TransportKind.lan)],
          localNodeId: 7,
          localName: 'x',
        ),
      ),
      localName: () => 'x',
      relayFactory: (room) {
        opened.add(room);
        return FakeTransport(TransportKind.internet);
      },
    );
    final k = PairKey(List.filled(32, 1));
    links.start();
    links.addPending(k);
    expect(links.openRelays, 1);
    links.setOfflineSaver(true);
    expect(links.openRelays, 0);
    expect(links.currentPresenceInterval, FriendLinks.offlinePresenceInterval);
    links.addPending(PairKey(List.filled(32, 2)));
    expect(links.openRelays, 0, reason: 'no new internet sockets offline');
    links.setOfflineSaver(false);
    expect(links.openRelays, 2);
    expect(links.currentPresenceInterval, FriendLinks.presenceInterval);
    await links.dispose();
  });

  test('Wi-Fi Direct discovery only on demand offline', () async {
    final fake = RecordingWifiDirect();
    final t = WifiDirectTransport(platform: fake, supported: true);
    await t.start(localNodeId: 3, channel: 1);
    expect(t.discoveryInterval, const Duration(seconds: 30));
    t.setOfflineSaver(true);
    expect(t.discoveryInterval, const Duration(minutes: 15));
    t.discoverNow(forTime: const Duration(milliseconds: 50));
    expect(t.discoveryInterval, const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(t.discoveryInterval, const Duration(minutes: 15));
    expect(fake.intervals.last, const Duration(minutes: 15));
    t.setOfflineSaver(false);
    expect(
      t.discoveryInterval,
      const Duration(seconds: 90),
      reason: 'saver stays on until the manager turns it off',
    );
    await t.dispose();
  });

  group('TripController offline', () {
    late Directory dir;
    late FakeClock clock;
    late FakeHost host;
    late TripController t;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trip181');
      clock = FakeClock();
      host = FakeHost(me);
      t = TripController(
        host: host,
        settings: TripSettings()
          ..tripMode = true
          ..checkInMinutes = 5,
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

    int posSent({bool? checkIn}) => host.sent
        .where(
          (s) =>
              s.msg is PosMsg &&
              (checkIn == null || (s.msg as PosMsg).checkIn == checkIn),
        )
        .length;

    test(
      'no live positions, slower GPS and check-ins, no map downloads',
      () async {
        await t.setOfflineSaver(true);
        expect(t.tiles.online, isFalse);
        expect(t.locationInterval, const Duration(seconds: 90));
        t.onFix(Fix(here, clock.now));
        for (var i = 0; i < 10 * 60 + 5; i++) {
          clock.advance(const Duration(seconds: 1));
          t.tick();
        }
        expect(posSent(checkIn: false), 0, reason: 'live location off');
        // One check-in at the start, then every 10 min (5 doubled).
        expect(posSent(checkIn: true), 2);
        expect(t.checkInMinutesNow, 10);

        await t.setOfflineSaver(false);
        expect(t.tiles.online, isTrue);
        expect(t.locationInterval, const Duration(seconds: 20));
        t.onFix(Fix(here, clock.now));
        expect(posSent(checkIn: false), 1, reason: 'live again');
      },
    );

    test('SOS still goes out at full speed offline', () async {
      await t.setOfflineSaver(true);
      t.onFix(Fix(here, clock.now));
      await t.startSos();
      expect(host.sent.where((s) => s.msg is SosMsg), isNotEmpty);
      expect(host.sent.lastWhere((s) => s.msg is SosMsg).route.flood, isTrue);
    });
  });

  group('SOS slide-and-hold button', () {
    Future<int Function()> pump(WidgetTester tester) async {
      var sent = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 40),
                child: SosSlideButton(onSend: () => sent++),
              ),
            ),
          ),
        ),
      );
      return () => sent;
    }

    testWidgets('a tap only shows the hint', (tester) async {
      final sent = await pump(tester);
      await tester.tap(find.byKey(const Key('sosButton')));
      await tester.pump();
      expect(find.text(SosSlideButton.hint), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(sent(), 0);
      expect(find.text(SosSlideButton.hint), findsNothing);
    });

    testWidgets('holding without sliding (pocket) does nothing', (
      tester,
    ) async {
      final sent = await pump(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('sosButton'))),
      );
      await tester.pump(const Duration(seconds: 5));
      await g.up();
      await tester.pump();
      expect(sent(), 0);
    });

    testWidgets('slide then hold 3 s sends; letting go early does not', (
      tester,
    ) async {
      final sent = await pump(tester);
      // Slide all the way, let go after 1 s: cancelled.
      var g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('sosButton'))),
      );
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const Key('sosRing')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await g.up();
      await tester.pump(const Duration(seconds: 3));
      expect(sent(), 0);
      expect(find.byKey(const Key('sosRing')), findsNothing);

      // Slide only half way and hold: not armed.
      g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('sosButton'))),
      );
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(seconds: 4));
      expect(sent(), 0);
      await g.up();
      await tester.pump();

      // Slide and hold 3 s: sent once.
      g = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('sosButton'))),
      );
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.textContaining('Keep holding'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(sent(), 0);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(sent(), 1);
      await g.up();
      await tester.pump();
      expect(sent(), 1);
    });
  });

  group('Trip layout', () {
    Widget app({required bool full, required ValueChanged<bool> onFull}) =>
        MaterialApp(
          home: Scaffold(
            body: TripLayout(
              full: full,
              onFull: onFull,
              map: const ColoredBox(key: Key('fakeMap'), color: Colors.green),
              panel: ListView(
                children: const [ListTile(title: Text('People (3)'))],
              ),
              sos: SosSlideButton(onSend: () {}),
              fullControls: [
                RoundMapButton(icon: Icons.add, tip: 'Zoom in', onTap: () {}),
              ],
              controls: [
                RoundMapButton(
                  icon: Icons.layers,
                  tip: 'Map style',
                  onTap: () {},
                ),
              ],
              topLeft: [OfflineSaverChip(on: true, onTap: () {})],
            ),
          ),
        );

    testWidgets('bigger map by default; full-screen toggle hides the panel', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      var full = false;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, set) =>
              app(full: full, onFull: (v) => set(() => full = v)),
        ),
      );
      final h = tester.getSize(find.byKey(const Key('tripMap'))).height;
      final body = tester.getSize(find.byType(Scaffold)).height;
      expect(h / body, closeTo(TripLayout.mapShare, 0.01));
      expect(find.text('People (3)'), findsOneWidget);
      expect(find.byKey(const Key('sosButton')), findsOneWidget);
      expect(find.text('Power save on'), findsOneWidget);
      expect(find.byTooltip('Zoom in'), findsNothing, reason: 'full only');

      await tester.tap(find.byKey(const Key('mapFullScreen')));
      await tester.pumpAndSettle();
      expect(full, isTrue);
      expect(find.text('People (3)'), findsNothing);
      expect(tester.getSize(find.byKey(const Key('tripMap'))).height, body);
      // Controls and the guarded SOS stay usable.
      expect(find.byTooltip('Zoom in'), findsOneWidget);
      expect(find.byTooltip('Exit full screen'), findsOneWidget);
      expect(find.byKey(const Key('sosButton')), findsOneWidget);
      expect(find.byKey(const Key('fakeMap')), findsOneWidget);

      // Back gesture leaves full screen instead of closing the app.
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(full, isFalse);
      expect(find.text('People (3)'), findsOneWidget);
    });

    testWidgets('exit button leaves full screen', (tester) async {
      var full = true;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, set) =>
              app(full: full, onFull: (v) => set(() => full = v)),
        ),
      );
      await tester.tap(find.byTooltip('Exit full screen'));
      await tester.pumpAndSettle();
      expect(full, isFalse);
    });

    testWidgets('dim overlay lets touches through', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => OfflineDim(on: true, child: child!),
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('Tap'),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('offlineDim')), findsOneWidget);
      await tester.tap(find.text('Tap'), warnIfMissed: false);
      expect(taps, 1);
    });
  });
}
