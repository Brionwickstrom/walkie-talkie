// v2.6.0: the connection chip on the Talk status line.
//   V260_SHOTS=/workspace flutter test test/v260_connection_chip_test.dart
// (screenshots only when V260_SHOTS is set)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart' show RadioState;
import 'package:walkie_talkie/trip/range_test.dart' show defaultRangeHomeNode;
import 'package:walkie_talkie/ui/connection_health.dart';
import 'package:walkie_talkie/ui/status_line.dart';
import 'package:walkie_talkie/ui/who_can_hear.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v242_radios_test.dart' show newSession, node, nodeInfoBytes, addChannel;

final now = DateTime(2026, 10, 30, 18, 0, 0);

RadioHealth radio({
  bool paired = true,
  RadioState state = RadioState.ready,
  RadioLinkKind link = RadioLinkKind.bluetooth,
  String? port,
  Duration? heardAgo = const Duration(minutes: 2),
  double snr = 5.5,
  int rssi = -88,
  int? hops = 0,
}) => RadioHealth(
  paired: paired,
  state: state,
  link: link,
  port: port,
  homeName: 'Skunk Ape',
  homeHeard: heardAgo == null ? null : now.subtract(heardAgo),
  homeSnr: snr,
  homeRssi: rssi,
  homeHops: hops,
);

ConnectionHealth health({
  TransportKind? best = TransportKind.internet,
  TransportStatus internet = TransportStatus.running,
  String? net = 'Internet via Wi-Fi (Home relay)',
  String? phoneNet = 'wifi',
  RadioHealth r = const RadioHealth(),
  Map<TransportKind, TransportStatus> links = const {},
  bool failing = false,
  Duration stale = const Duration(minutes: 30),
}) => ConnectionHealth.from(
  now: now,
  bestKind: best,
  internet: internet,
  internetText: net,
  phoneNet: phoneNet,
  radio: r,
  links: links,
  linkFailing: failing,
  homeStaleAfter: stale,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('ConnectionHealth logic', () {
    test('internet up, no radio: green, "Internet", no home part', () {
      final h = health();
      expect(h.level, HealthLevel.good);
      expect(h.text, 'Internet');
      expect(h.shortText, 'Internet');
      expect(h.homeLine, isNull);
      expect(h.reasons, isEmpty);
      expect(h.headline, startsWith('All good'));
    });

    test('radio connected, home heard 2 min ago, good signal: green', () {
      final h = health(r: radio());
      expect(h.level, HealthLevel.good);
      expect(h.text, 'Internet · Home 2m');
      expect(h.shortText, 'Internet · 2m');
      expect(h.homeLine, 'Skunk Ape: heard 2 min ago');
      expect(h.signalText, 'Good (SNR 5.5 dB, RSSI -88 dBm, direct)');
    });

    test('home not heard for 45 min: amber with the plain reason', () {
      final h = health(r: radio(heardAgo: const Duration(minutes: 45)));
      expect(h.level, HealthLevel.weak);
      expect(h.headline, 'Skunk Ape not heard for 45 min');
      expect(h.text, 'Internet · Home 45m');
      // Stale signal is not shown as if it were current.
      expect(h.signalText, isNull);
    });

    test('the stale limit is shorter while Range logging is on', () {
      const age = Duration(minutes: 12);
      expect(health(r: radio(heardAgo: age)).level, HealthLevel.good);
      final h = health(
        r: radio(heardAgo: age),
        stale: const Duration(minutes: 10),
      );
      expect(h.level, HealthLevel.weak);
      expect(h.headline, 'Skunk Ape not heard for 12 min');
    });

    test('never heard: amber, "Home —"', () {
      final h = health(r: radio(heardAgo: null));
      expect(h.level, HealthLevel.weak);
      expect(h.text, 'Internet · Home —');
      expect(h.headline, 'Skunk Ape not heard yet');
    });

    test('weak signal grades: Fair and Weak', () {
      final fair = health(r: radio(snr: -10));
      expect(fair.level, HealthLevel.good);
      expect(fair.signalText, startsWith('Fair (SNR -10 dB'));
      final weak = health(r: radio(snr: -17.5, hops: 2));
      expect(weak.level, HealthLevel.weak);
      expect(weak.signalText, 'Weak (SNR -17.5 dB, RSSI -88 dBm, 2 hops)');
      expect(weak.headline, 'Weak signal to Skunk Ape');
    });

    test('SNR 0 means not reported: no signal text, no weak signal', () {
      final h = health(r: radio(snr: 0, rssi: 0));
      expect(h.signalText, isNull);
      expect(h.level, HealthLevel.good);
    });

    test('Bluetooth radio not connected: amber with the Bluetooth reason', () {
      final h = health(
        r: radio(state: RadioState.reconnecting, heardAgo: null),
      );
      expect(h.level, HealthLevel.weak);
      expect(h.headline, startsWith('Radio not connected over Bluetooth'));
      expect(h.text, 'Internet · Radio off');
      expect(h.shortText, 'Internet · off');
      expect(h.homeLine, contains('radio is not connected'));
      final row = h.paths.firstWhere((p) => p.name == 'Radio (Bluetooth)');
      expect(row.level, HealthLevel.down);
    });

    test('Bluetooth off and a connecting radio get their own words', () {
      expect(
        health(r: radio(state: RadioState.bluetoothOff)).headline,
        contains('Bluetooth is off'),
      );
      final c = health(r: radio(state: RadioState.connecting));
      expect(c.headline, contains('Connecting to the radio over Bluetooth'));
      final p = health(r: radio(state: RadioState.pairing));
      expect(p.headline, contains('pairing PIN'));
    });

    test('USB radio on the desktop: named USB, COM port in the reason', () {
      final up = health(
        best: TransportKind.lora,
        internet: TransportStatus.stopped,
        net: null,
        r: radio(link: RadioLinkKind.usb, port: 'COM7'),
      );
      expect(up.level, HealthLevel.good);
      expect(up.pathName, 'Radio');
      expect(up.text, 'Radio · Home 2m');
      final row = up.paths.firstWhere((p) => p.name == 'Radio (USB)');
      expect(row.active, isTrue);
      expect(row.text, startsWith('Connected on COM7'));

      final down = health(
        r: radio(
          link: RadioLinkKind.usb,
          port: 'COM7',
          state: RadioState.reconnecting,
        ),
      );
      expect(down.headline, contains('over USB'));
      expect(down.headline, contains('COM7'));
    });

    test('nothing up: red, "No link", plain "No internet" reason', () {
      final h = health(
        best: null,
        internet: TransportStatus.error,
        net: 'Internet: relay error',
        phoneNet: 'none',
      );
      expect(h.level, HealthLevel.down);
      expect(h.text, 'No link');
      expect(h.headline, 'No internet: the phone has no network');
      final relay = health(
        best: null,
        internet: TransportStatus.error,
        net: 'timeout',
      );
      expect(relay.headline, startsWith('No internet: the relay can not'));
    });

    test('nothing up and radio also down: both reasons in one line', () {
      final h = health(
        best: null,
        internet: TransportStatus.error,
        phoneNet: 'none',
        r: radio(state: RadioState.reconnecting, heardAgo: null),
      );
      expect(h.level, HealthLevel.down);
      expect(h.headline, contains('No internet'));
      expect(h.headline, contains('Radio not connected over Bluetooth'));
    });

    test('still starting: grey "Connecting", not red', () {
      final h = health(
        best: null,
        internet: TransportStatus.starting,
        net: null,
      );
      expect(h.level, HealthLevel.idle);
      expect(h.pathName, 'Connecting');
    });

    test('Wi-Fi Direct and local paths name the chip', () {
      final wd = health(
        best: TransportKind.wifiDirect,
        internet: TransportStatus.error,
        net: null,
        links: {TransportKind.wifiDirect: TransportStatus.running},
      );
      expect(wd.pathName, 'Wi-Fi Direct');
      expect(wd.level, HealthLevel.good);
      expect(wd.paths.where((p) => p.active).single.name, 'Wi-Fi Direct');
      final lan = health(
        best: TransportKind.lan,
        links: {TransportKind.lan: TransportStatus.running},
      );
      expect(lan.pathName, 'Wi-Fi');
    });

    test('no best kind given: falls back to what is running', () {
      expect(health(best: null).pathName, 'Internet');
      final lora = health(
        best: null,
        internet: TransportStatus.stopped,
        net: null,
        r: radio(),
      );
      expect(lora.pathName, 'Radio');
    });

    test('a link that just missed a check turns it amber', () {
      final h = health(failing: true);
      expect(h.level, HealthLevel.weak);
      expect(h.headline, contains('backup is carrying it'));
    });

    test('a future last-heard time (clock skew) reads as just now', () {
      final h = health(
        r: RadioHealth(
          paired: true,
          state: RadioState.ready,
          homeName: 'Skunk Ape',
          homeHeard: now.add(const Duration(minutes: 3)),
        ),
      );
      expect(h.level, HealthLevel.good);
      expect(h.text, 'Internet · Home now');
      expect(h.homeLine, 'Skunk Ape: heard just now');
    });

    test('no radio paired: radio row says so, nothing about home', () {
      final h = health();
      expect(h.paths.last.name, 'Radio');
      expect(h.paths.last.text, 'No radio set up');
      expect(h.paths.last.level, HealthLevel.idle);
    });

    test('ConnectionSummary carries the kind of the best link', () {
      const s = ConnectionSummary(
        best: 'Wi-Fi',
        bestRtt: null,
        backups: 0,
        checkEvery: Duration(seconds: 5),
        bestKind: TransportKind.lan,
      );
      expect(s.bestKind, TransportKind.lan);
      expect(
        const ConnectionSummary(
          best: null,
          bestRtt: null,
          backups: 0,
          checkEvery: Duration(seconds: 5),
        ).bestKind,
        isNull,
      );
    });
  });

  group('chip and sheet widgets', () {
    Widget line(
      ConnectionHealth Function() src, {
      double w = 400,
      VoidCallback? onMore,
      List<Widget>? extra,
    }) => MediaQuery(
      data: MediaQueryData(size: Size(w, 700)),
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: w,
            child: TalkStatusLine(
              audience: const AudienceInfo(Audience.privateGroup),
              here: 3,
              netStatus: TransportStatus.running,
              netText: 'Internet via Wi-Fi',
              volumeLow: true,
              onVolumeLow: () {},
              mobileDataHint: true,
              onMobileData: () {},
              weather: 'Flood Watch',
              onOpenWeather: () {},
              onOpenMessages: () {},
              messagesNew: true,
              onOpen: () {},
              health: src,
              onOpenHealth: () {},
            ),
          ),
        ),
      ),
    );

    testWidgets('no chip unless asked for (existing screens unchanged)', (
      t,
    ) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TalkStatusLine(
              audience: AudienceInfo(Audience.open, channel: 1),
              here: 1,
              netStatus: TransportStatus.running,
              netText: 'Internet via Wi-Fi',
              onOpen: _noop,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('connection-chip')), findsNothing);
    });

    testWidgets(
      'fits beside every other shortcut at 360 dp, icon + short text',
      (t) async {
        final h = health(r: radio());
        await t.pumpWidget(line(() => h, w: 360));
        expect(t.takeException(), isNull);
        final txt = t.widget<Text>(
          find.byKey(const Key('connection-chip-text')),
        );
        expect(txt.data, 'Internet · 2m');
        for (final k in const [
          'connection-chip',
          'talk-weather-shortcut',
          'talk-messages-shortcut',
          'volume-low-chip',
          'allow-mobile-data',
          'status-line',
        ]) {
          expect(find.byKey(Key(k)), findsOneWidget, reason: k);
        }
        final chip = t.getRect(find.byKey(const Key('connection-chip')));
        expect(chip.right, lessThanOrEqualTo(360));
        expect(chip.width, lessThanOrEqualTo(108));
      },
    );

    testWidgets('wide enough: full text', (t) async {
      final h = health(r: radio());
      await t.pumpWidget(line(() => h, w: 700));
      final txt = t.widget<Text>(find.byKey(const Key('connection-chip-text')));
      expect(txt.data, 'Internet · Home 2m');
    });

    testWidgets('large text on a phone does not overflow', (t) async {
      final h = health(r: radio(heardAgo: const Duration(hours: 5)));
      t.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(t.platformDispatcher.clearAllTestValues);
      await t.pumpWidget(line(() => h, w: 360));
      expect(t.takeException(), isNull);
    });

    testWidgets('colour follows the level: green, amber, red', (t) async {
      Color? border(WidgetTester t) {
        final box = t.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('connection-chip')),
            matching: find.byType(DecoratedBox),
          ),
        );
        return ((box.decoration as BoxDecoration).border as Border).top.color;
      }

      var h = health(r: radio());
      await t.pumpWidget(line(() => h));
      expect(
        border(t)!.toARGB32(),
        Colors.green.withValues(alpha: .7).toARGB32(),
      );
      h = health(r: radio(heardAgo: const Duration(hours: 2)));
      await t.pumpWidget(line(() => h));
      expect(
        border(t)!.toARGB32(),
        Colors.amber.shade700.withValues(alpha: .7).toARGB32(),
      );
      h = health(best: null, internet: TransportStatus.error, net: null);
      await t.pumpWidget(line(() => h));
      expect(
        border(t)!.toARGB32(),
        Colors.redAccent.withValues(alpha: .7).toARGB32(),
      );
    });

    testWidgets('the age counts up by itself (30 s tick, no other source)', (
      t,
    ) async {
      var clock = now;
      ConnectionHealth src() => ConnectionHealth.from(
        now: clock,
        bestKind: TransportKind.internet,
        internet: TransportStatus.running,
        radio: radio(),
      );
      await t.pumpWidget(line(src, w: 700));
      expect(
        t.widget<Text>(find.byKey(const Key('connection-chip-text'))).data,
        'Internet · Home 2m',
      );
      clock = now.add(const Duration(minutes: 5));
      await t.pump(const Duration(seconds: 31));
      expect(
        t.widget<Text>(find.byKey(const Key('connection-chip-text'))).data,
        'Internet · Home 7m',
      );
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 61)); // timer cancelled: no error
    });

    testWidgets('tapping the chip calls onOpenHealth, not the status line', (
      t,
    ) async {
      var health0 = 0, line0 = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TalkStatusLine(
              audience: const AudienceInfo(Audience.open, channel: 1),
              here: 1,
              netStatus: TransportStatus.running,
              netText: 'Internet via Wi-Fi',
              onOpen: () => line0++,
              health: () => health(),
              onOpenHealth: () => health0++,
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('connection-chip')));
      expect(health0, 1);
      expect(line0, 0);
    });

    testWidgets('sheet: per-path rows, reason, home line, signal, more', (
      t,
    ) async {
      var more = 0;
      final h = health(
        r: radio(heardAgo: const Duration(minutes: 12)),
        stale: const Duration(minutes: 10),
        links: {TransportKind.lan: TransportStatus.running},
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConnectionHealthSheet(health: h, onMore: () => more++),
            ),
          ),
        ),
      );
      expect(
        t.widget<Text>(find.byKey(const Key('connection-headline'))).data,
        'Skunk Ape not heard for 12 min',
      );
      expect(find.text('Internet relay · in use'), findsOneWidget);
      expect(find.text('Wi-Fi / local network'), findsOneWidget);
      expect(find.text('Radio (Bluetooth)'), findsOneWidget);
      expect(find.text('Skunk Ape: heard 12 min ago'), findsOneWidget);
      expect(find.textContaining('nothing is sent'), findsOneWidget);
      await t.tap(find.byKey(const Key('connection-more')));
      expect(more, 1);
    });

    testWidgets('sheet when nothing is up says why in plain words', (t) async {
      final h = health(
        best: null,
        internet: TransportStatus.error,
        net: null,
        phoneNet: 'none',
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConnectionHealthSheet(health: h)),
        ),
      );
      expect(find.text('No internet: the phone has no network'), findsWidgets);
      expect(find.byKey(const Key('connection-more')), findsNothing);
    });
  });

  group('on the real Talk screen', () {
    testWidgets('chip shows, opens the sheet, More opens the old sheet', (
      t,
    ) async {
      phone(t, ts: 1.0);
      final c = await makeController(t, friends: [testFriend(0x2222, 'Ann')]);
      await t.pumpWidget(homeApp(c));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('connection-chip')), findsOneWidget);
      expect(find.byKey(const Key('status-line')), findsOneWidget);
      await t.tap(find.byKey(const Key('connection-chip')));
      await settle(t);
      expect(find.byKey(const Key('connection-sheet')), findsOneWidget);
      await t.tap(find.byKey(const Key('connection-more')));
      await settle(t);
      expect(find.byKey(const Key('connection-sheet')), findsNothing);
      expect(find.byKey(const Key('status-sheet')), findsOneWidget);
      await finish(t);
    });

    testWidgets('connectionHealthOf reads the radio session: home heard', (
      t,
    ) async {
      phone(t, ts: 1.0);
      final c = await makeController(t);
      // No radio: no home part, never any traffic asked for.
      var h = connectionHealthOf(c);
      expect(h.homeLine, isNull);
      expect(h.text, isNot(contains('Home')));

      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'T1000-E'
        ..state = RadioState.ready;
      final s = newSession(now: DateTime.now());
      c.radioDevice.session = s;
      addChannel(s, 0, '', [1]);
      final ago =
          DateTime.now()
              .subtract(const Duration(minutes: 3))
              .millisecondsSinceEpoch ~/
          1000;
      s.handle(
        node(
          nodeInfoBytes(
            defaultRangeHomeNode,
            long: 'Skunk Ape',
            short: 'SKNK',
            snr: -3,
            last: ago,
            hops: 0,
            channel: 0,
          ),
        ),
      );
      h = connectionHealthOf(c);
      expect(h.homeLine, 'Skunk Ape: heard 3 min ago');
      expect(h.signalText, startsWith('Good (SNR -3 dB'));
      expect(h.paths.any((p) => p.name == 'Radio (Bluetooth)'), isTrue);

      // USB (desktop) radio.
      c.radioDevice.deviceId = 'serial:COM7';
      h = connectionHealthOf(c);
      expect(h.paths.any((p) => p.name == 'Radio (USB)'), isTrue);

      // The radio drops: amber, Bluetooth words for a Bluetooth radio.
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..state = RadioState.reconnecting;
      h = connectionHealthOf(c);
      expect(h.reasons.join(), contains('Radio not connected over Bluetooth'));
      await t.runAsync(() async {});
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V260_SHOTS'];
    if (dir == null) return;
    // Dev tool: the PNGs are written before the end of the test; the
    // controller's start-up timers can still trip the final timer check.

    Future<void> shot(WidgetTester t, String name) async {
      for (var i = 0; i < 3; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v260_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    testWidgets('Talk screen with the chip, and the tapped sheet', (t) async {
      phone(t, w: 360, h: 640, ts: 1.0);
      final c = await makeController(
        t,
        group: 'Bigfoot crew',
        friends: [testFriend(0x2222, 'Ann'), testFriend(0x3333, 'Ben')],
      );
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'Yowie'
        ..state = RadioState.ready;
      final s = newSession(now: DateTime.now());
      c.radioDevice.session = s;
      addChannel(s, 0, '', [1]);
      final ago =
          DateTime.now()
              .subtract(const Duration(minutes: 3))
              .millisecondsSinceEpoch ~/
          1000;
      s.handle(
        node(
          nodeInfoBytes(
            defaultRangeHomeNode,
            long: 'Skunk Ape',
            short: 'SKNK',
            snr: 5.5,
            last: ago,
            hops: 0,
            channel: 0,
          ),
        ),
      );
      await t.pumpWidget(
        RepaintBoundary(key: const Key('shotroot'), child: homeApp(c)),
      );
      await t.pump(const Duration(milliseconds: 400));
      await shot(t, 'talk');
      await t.tap(find.byKey(const Key('connection-chip')));
      await settle(t);
      await shot(t, 'sheet');
      // Same radio, but the home radio went quiet 45 min ago: amber.
      await t.tapAt(const Offset(180, 40));
      await settle(t);
      s.nodes[defaultRangeHomeNode]!.lastHeard = DateTime.now().subtract(
        const Duration(minutes: 45),
      );
      c.notifyListeners();
      await t.pump(const Duration(milliseconds: 200));
      await shot(t, 'talk_amber');
      // Let the controller's start-up finish, then stop it.
      await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await t.pump(const Duration(minutes: 2));
    });
  });
}

void _noop() {}
