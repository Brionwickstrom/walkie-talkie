// v1.9.6: tablet / desktop two-pane layout, Space bar push-to-talk, the
// Windows release asset next to the APK, and Meshtastic radios over
// Wi-Fi (TCP 4403) / USB serial ids for the desktop app.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/gateway/stream_wire.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/lora/stream_radio.dart';
import 'package:walkie_talkie/platform/platform_caps.dart';
import 'package:walkie_talkie/ui/adaptive_layout.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/trip_widgets.dart';
import 'package:walkie_talkie/ui/whos_where_page.dart';
import 'package:walkie_talkie/update/updater.dart';

import 'home_layout_test.dart' show loadFonts, people;
import 'lora_proto_test.dart'
    show configComplete, loraConfig, myInfo, nodeInfo, packetFrom;

Widget _talk() => HomeBody(
  links: const [
    (TransportKind.lan, TransportStatus.running),
    (TransportKind.internet, TransportStatus.running),
  ],
  internet: (status: TransportStatus.running, text: 'Internet: connected'),
  showDetails: false,
  onToggleDetails: (_) {},
  details: const [],
  channelLabel: 'CH 1',
  me: const PersonView(id: 0x1234, name: 'Lord of the Pings', me: true),
  people: people,
  onRing: (_) {},
  onBeep: (_) {},
  onMessage: (_) {},
  onVolume: (_) {},
  onEditMe: () {},
  headerAction: WhosWhereButton(count: 2, onPressed: () {}),
  actions: ChannelActions(
    onRingAll: () {},
    onBeepAll: () {},
    record: OutlinedButton(onPressed: () {}, child: const Text('Message')),
    history: HistoryButton(unheard: 1, onOpen: () {}),
  ),
  ptt: MainTalkArea(
    button: PttButton(
      transmitting: false,
      busy: false,
      onChanged: (_) {},
      size: 132,
      caption: 'Talk to CH 1 (3 people) · or hold Space',
    ),
  ),
);

Widget _trip() => TripLayout(
  full: false,
  onFull: (_) {},
  map: const ColoredBox(key: Key('fakeMap'), color: Color(0xFFE8EFD8)),
  panel: ListView(
    children: const [
      ListTile(title: Text('Trip: 4 people')),
      ListTile(title: Text('Elevation 3,120 ft')),
    ],
  ),
  sos: SosSlideButton(onSend: () {}),
  controls: [
    RoundMapButton(icon: Icons.my_location, tip: 'Following you', onTap: () {}),
    RoundMapButton(icon: Icons.layers, tip: 'Map style', onTap: () {}),
  ],
  fullControls: const [],
  topLeft: const [],
);

Widget _tabletApp(double width) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(useMaterial3: true, fontFamily: 'Roboto'),
  home: Scaffold(
    appBar: AppBar(title: const Text('CH 1')),
    body: TwoPaneHome(width: width, talk: _talk(), trip: _trip()),
  ),
);

void main() {
  setUpAll(loadFonts);

  group('two-pane layout', () {
    test('phones keep the tabs, tablets and desktop windows get two panes', () {
      expect(isTwoPane(360, 780), isFalse, reason: 'phone portrait');
      expect(isTwoPane(780, 360), isFalse, reason: 'phone landscape');
      expect(isTwoPane(915, 412), isFalse, reason: 'big phone landscape');
      expect(isTwoPane(600, 960), isFalse, reason: 'small tablet portrait');
      expect(isTwoPane(960, 600), isTrue, reason: 'small tablet landscape');
      expect(isTwoPane(800, 1280), isTrue, reason: 'tablet portrait');
      expect(isTwoPane(1280, 800), isTrue, reason: 'tablet landscape');
      expect(isTwoPane(1280, 520), isTrue, reason: 'short desktop window');
      expect(isTwoPane(699, 1000), isFalse, reason: 'narrow window');
    });

    test('talk pane keeps a phone-like width', () {
      expect(talkPaneWidth(700), 340);
      expect(talkPaneWidth(1000), 400);
      expect(talkPaneWidth(1920), 460);
    });

    for (final (w, h, name) in [
      (1280.0, 800.0, 'tablet landscape'),
      (800.0, 1280.0, 'tablet portrait'),
      (1024.0, 768.0, 'iPad-size landscape'),
      (1920.0, 1080.0, 'desktop window'),
    ]) {
      testWidgets('$name ${w.toInt()}x${h.toInt()} at 1.3x text: both panes', (
        tester,
      ) async {
        tester.view.physicalSize = Size(w, h) * 2;
        tester.view.devicePixelRatio = 2;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(_tabletApp(w));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        final talk = tester.getRect(find.byKey(const Key('talkPane')));
        final trip = tester.getRect(find.byKey(const Key('tripPane')));
        expect(talk.width, talkPaneWidth(w));
        expect(talk.left, 0);
        expect(trip.left, greaterThan(talk.right - 1));
        expect(trip.right, w);
        expect(trip.width, greaterThan(talk.width * 0.7));
        // Push-to-talk and the people list in the Talk pane, the map and
        // its SOS in the Trip pane.
        final ptt = tester.getRect(find.byKey(const Key('ptt-caption')));
        expect(talk.contains(ptt.center), isTrue);
        expect(find.text('Rubber Duck'), findsWidgets);
        final map = tester.getRect(find.byKey(const Key('tripMap')));
        expect(trip.contains(map.center), isTrue);
        final sos = tester.getRect(find.byKey(const Key('sosButton')));
        expect(map.contains(sos.center), isTrue);
        // Every person card lays out when scrolled.
        await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('tablet preview PNG (TABLET_PNG=path, TABLET_SIZE=WxH)', (
    tester,
  ) async {
    final out = Platform.environment['TABLET_PNG'];
    if (out == null) return;
    final size = (Platform.environment['TABLET_SIZE'] ?? '1280x800')
        .split('x')
        .map(double.parse)
        .toList();
    tester.view.physicalSize = Size(size[0], size[1]) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(child: _tabletApp(size[0])));
    await tester.pump(const Duration(milliseconds: 300));
    final b = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final img = await b.toImage(pixelRatio: 1);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });

  group('Space bar push-to-talk', () {
    Future<List<bool>> pump(WidgetTester tester, {bool field = false}) async {
      final got = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PushToTalkKeys(
            onTalk: got.add,
            child: Scaffold(
              body: Column(
                children: [
                  if (field) const TextField(key: Key('field')),
                  Builder(
                    builder: (ctx) => TextButton(
                      key: const Key('dialog'),
                      onPressed: () => showDialog<void>(
                        context: ctx,
                        builder: (_) => const AlertDialog(content: Text('Hi')),
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return got;
    }

    testWidgets('hold = talk, release = stop, repeats ignored', (tester) async {
      final got = await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      expect(got, [true]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(got, [true, false]);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(got, [true, false]);
    });

    testWidgets('typing a space in a text field does not talk', (tester) async {
      final got = await pump(tester, field: true);
      await tester.tap(find.byKey(const Key('field')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(got, isEmpty);
    });

    testWidgets('not under a dialog', (tester) async {
      final got = await pump(tester);
      await tester.tap(find.byKey(const Key('dialog')));
      await tester.pumpAndSettle();
      expect(find.text('Hi'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(got, isEmpty);
    });

    testWidgets('leaving the screen while held stops talking', (tester) async {
      final got = await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pumpWidget(const SizedBox());
      expect(got, [true, false]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(got, [true, false]);
    });
  });

  group('release assets: APK for phones, zip for Windows', () {
    Map<String, dynamic> asset(String name, int size) => {
      'name': name,
      'size': size,
      'browser_download_url':
          'https://github.com/$kReleasesRepo/releases/download/v1.9.6/$name',
    };
    Map<String, dynamic> rel(List<Map<String, dynamic>> assets) => {
      'tag_name': 'v1.9.6',
      'name': 'Walkie Talkie 1.9.6',
      'body': 'Tablets and Windows.',
      'html_url': 'https://github.com/$kReleasesRepo/releases/tag/v1.9.6',
      'assets': assets,
    };

    test('phones always pick WalkieTalkie.apk, whatever the order', () {
      for (final list in [
        [asset(kWindowsAsset, 30000000), asset(kApkAsset, 40000000)],
        [asset(kApkAsset, 40000000), asset(kWindowsAsset, 30000000)],
      ]) {
        final r = ReleaseInfo.fromGitHubJson(rel(list))!;
        expect(r.apkUrl.path, endsWith('/WalkieTalkie.apk'));
        expect(r.apkSize, 40000000);
      }
    });

    test('a release with only the Windows zip is no phone update', () {
      expect(
        ReleaseInfo.fromGitHubJson(rel([asset(kWindowsAsset, 1)])),
        isNull,
      );
    });

    test('Windows picks the zip, never the APK', () {
      final r = ReleaseInfo.windowsFromGitHubJson(
        rel([
          asset(kApkAsset, 40000000),
          asset('maps.zip', 5),
          asset(kWindowsAsset, 30000000),
        ]),
      )!;
      expect(r.apkUrl.path, endsWith('/WalkieTalkie-Windows.zip'));
      expect(r.apkSize, 30000000);
      expect(r.version.toString(), '1.9.6');
      expect(
        ReleaseInfo.windowsFromGitHubJson(rel([asset(kApkAsset, 1)])),
        isNull,
      );
      expect(
        ReleaseInfo.windowsFromGitHubJson(rel([asset('maps.zip', 1)])),
        isNull,
      );
    });

    test('latest download links', () {
      expect(
        kWindowsLatestUrl,
        'https://github.com/Brionwickstrom/walkie-talkie/releases/latest/download/WalkieTalkie-Windows.zip',
      );
    });
  });

  group('desktop feature set', () {
    tearDown(() => PlatformCaps.debugDesktop = null);

    test('tests see the phone feature set unless asked', () {
      expect(PlatformCaps.desktop, isFalse);
      expect(PlatformCaps.bluetooth, isTrue);
      PlatformCaps.debugDesktop = true;
      expect(PlatformCaps.desktop, isTrue);
      expect(PlatformCaps.bluetooth, isFalse);
      expect(PlatformCaps.camera, isFalse);
      expect(PlatformCaps.sensors, isFalse);
      expect(PlatformCaps.streamRadios, isTrue);
    });

    test(
      'desktop "Find USB radio" lists COM ports, no Bluetooth scan',
      () async {
        PlatformCaps.debugDesktop = true;
        final r = MeshtasticRadio()
          ..usbRadios = () => ['serial:COM3', 'serial:COM7'];
        final found = await r.scan();
        expect(found.map((f) => f.id), ['serial:COM3', 'serial:COM7']);
        expect(found.first.name, 'USB radio on COM3');
        expect(found.first.isStream, isTrue);
      },
    );
  });

  group('USB / Wi-Fi radio ids', () {
    test('typed addresses', () {
      expect(StreamRadioId.fromTyped('192.168.1.40'), 'tcp:192.168.1.40:4403');
      expect(
        StreamRadioId.fromTyped(' meshtastic.local '),
        'tcp:meshtastic.local:4403',
      );
      expect(
        StreamRadioId.fromTyped('http://10.0.0.9:4404/'),
        'tcp:10.0.0.9:4404',
      );
      expect(StreamRadioId.fromTyped(''), isNull);
      expect(StreamRadioId.fromTyped('my radio'), isNull);
      expect(StreamRadioId.fromTyped('10.0.0.9:99999'), isNull);
    });

    test('parse and label', () {
      expect(StreamRadioId.isStream('serial:COM3'), isTrue);
      expect(StreamRadioId.isStream('tcp:10.0.0.9:4403'), isTrue);
      expect(StreamRadioId.isStream('E4:5F:01:AA:BB:CC'), isFalse);
      expect(StreamRadioId.isStream(null), isFalse);
      expect(StreamRadioId.serialPort('serial:COM12'), 'COM12');
      expect(StreamRadioId.tcpTarget('tcp:10.0.0.9:4404'), (
        host: '10.0.0.9',
        port: 4404,
      ));
      expect(StreamRadioId.label('serial:COM3'), 'USB radio on COM3');
      expect(StreamRadioId.label('tcp:10.0.0.9:4403'), 'Wi-Fi radio 10.0.0.9');
      expect(
        StreamRadioId.label('tcp:10.0.0.9:4404'),
        'Wi-Fi radio 10.0.0.9:4404',
      );
    });
  });

  group('Wi-Fi radio over TCP (stream API, like the gateway)', () {
    test(
      'connects, configures, receives packets, reconnects after a drop',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final clients = <Socket>[];
        server.listen((s) {
          clients.add(s);
          final framer = StreamFramer();
          s.listen((bytes) {
            for (final toRadio in framer.add(bytes)) {
              for (final f in pbDecode(toRadio)) {
                if (f.number != 3) continue; // want_config_id
                for (final fr in [
                  myInfo(0xA1B2C3),
                  nodeInfo(0xA1B2C3, 'Van radio', 'VAN', battery: 88),
                  loraConfig(),
                  configComplete(f.asInt),
                ]) {
                  s.add(StreamFramer.frame(fr));
                }
              }
            }
          }, onError: (_) {});
        });
        final radio = MeshtasticRadio()
          ..deviceId = StreamRadioId.tcp('127.0.0.1', server.port)
          ..deviceName = 'Wi-Fi radio';
        addTearDown(radio.dispose);
        expect(radio.isStream, isTrue);
        final ready = radio.readyChanges.firstWhere((r) => r);
        radio.start();
        await ready.timeout(const Duration(seconds: 10));
        expect(radio.state, RadioState.ready);
        expect(radio.deviceName, 'Van radio');
        expect(radio.session!.myNodeNum, 0xA1B2C3);

        final got = radio.packets.first;
        clients.single.add(StreamFramer.frame(packetFrom(0x1234, [1, 2, 3])));
        final p = await got.timeout(const Duration(seconds: 5));
        expect(p.from, 0x1234);
        expect(p.decoded!.payload, Uint8List.fromList([1, 2, 3]));

        // The radio drops off Wi-Fi: not ready, then back by itself.
        final down = radio.readyChanges.firstWhere((r) => !r);
        clients.single.destroy();
        await down.timeout(const Duration(seconds: 5));
        final back = radio.readyChanges.firstWhere((r) => r);
        await back.timeout(const Duration(seconds: 15));
        expect(clients.length, 2);
        await radio.stop();
      },
    );

    test('a wrong address says what to check', () async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      final radio = MeshtasticRadio()
        ..deviceId = StreamRadioId.tcp('127.0.0.1', port);
      addTearDown(radio.dispose);
      final changed = Completer<void>();
      final sub = radio.changes.listen((_) {
        if (radio.state == RadioState.reconnecting && !changed.isCompleted) {
          changed.complete();
        }
      });
      radio.start();
      await changed.future.timeout(const Duration(seconds: 10));
      await sub.cancel();
      expect(radio.detail, contains('Wi-Fi'));
      await radio.stop();
    });
  });
}
