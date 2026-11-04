// v2.6.3: plain error messages with one-tap fix buttons.
// Nothing here has run on a real phone or radio.
//   V263_SHOTS=/workspace flutter test test/v263_friendly_error_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/lora/meshtastic_ble.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/meshtastic_settings.dart';
import 'package:walkie_talkie/ui/connection_health.dart';
import 'package:walkie_talkie/ui/friendly_error.dart';
import 'package:walkie_talkie/ui/home_page.dart';
import 'package:walkie_talkie/ui/radio_settings_page.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';
import 'v253_radio_settings_test.dart' show Fw, positionRaw, writer;
import 'v257_precision_test.dart' show threeChannels;
import 'v260_connection_chip_test.dart' as v260;

const fakeKey = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEf';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('the messages', () {
    test('every known cause: one plain sentence, never raw exception text', () {
      final raw = StateError('PlatformException(code 13, nope, null)');
      for (final cause in ErrorCause.values) {
        final fe = friendlyCause(cause, error: raw);
        expect(fe.message, isNotEmpty, reason: '$cause');
        expect(fe.message.endsWith('.'), isTrue, reason: '$cause');
        expect(fe.message, isNot(contains('Exception')), reason: '$cause');
        expect(fe.message, isNot(contains('PlatformException')));
        expect(fe.details, contains('PlatformException'), reason: '$cause');
        expect(fe.fixes.length, lessThanOrEqualTo(2));
      }
    });

    test('each cause has the fix button that fits it', () {
      FixAction? fixOf(ErrorCause c) => friendlyCause(c).fix;
      expect(fixOf(ErrorCause.bluetoothOff), FixAction.turnOnBluetooth);
      expect(fixOf(ErrorCause.bluetoothDenied), FixAction.allowNearby);
      expect(fixOf(ErrorCause.locationDenied), FixAction.allowLocation);
      expect(fixOf(ErrorCause.locationOff), FixAction.turnOnLocation);
      expect(fixOf(ErrorCause.microphoneDenied), FixAction.allowMicrophone);
      expect(
        fixOf(ErrorCause.notificationsDenied),
        FixAction.allowNotifications,
      );
      expect(fixOf(ErrorCause.cameraDenied), FixAction.allowCamera);
      expect(fixOf(ErrorCause.noInternet), FixAction.retry);
      expect(friendlyCause(ErrorCause.noInternet).fix2, FixAction.wifiSettings);
      expect(fixOf(ErrorCause.mobileDataBlocked), FixAction.allowMobileData);
      expect(fixOf(ErrorCause.dndDenied), FixAction.allowDnd);
      expect(fixOf(ErrorCause.radioNotConnected), FixAction.connectRadio);
      expect(fixOf(ErrorCause.audioFailed), FixAction.retry);
      expect(fixOf(ErrorCause.installerFailed), FixAction.openAppSettings);
    });

    test('the button labels are the plain ones', () {
      expect(FixAction.turnOnBluetooth.label, 'Turn on Bluetooth');
      expect(FixAction.connectRadio.label, 'Connect radio');
      expect(FixAction.retry.label, 'Try again');
      expect(FixAction.restoreBackup.label, 'Restore backup');
      expect(FixAction.allowMobileData.label, 'Allow mobile data');
      expect(FixAction.turnOnLocationSharing.label, 'Turn it on');
    });

    test('no internet explains itself and offers to retry', () {
      final fe = friendlyCause(ErrorCause.noInternet);
      expect(fe.message, contains('no internet'));
    });

    test('details never keep links or key-like text', () {
      final d = scrubDetails(
        'failed https://example.com/join?k=1 and $fakeKey and '
        'meshtastic.org/e/#CgMSAQE',
      );
      expect(d, isNot(contains('https')));
      expect(d, isNot(contains('example.com')));
      expect(d, isNot(contains(fakeKey)));
      expect(d, isNot(contains('meshtastic.org')));
      expect(d, contains('[link removed]'));
      expect(scrubDetails('x' * 1000).length, lessThanOrEqualTo(401));
      expect(detailsOf(StateError('Bad $fakeKey')), isNot(contains(fakeKey)));
    });
  });

  group('working out the cause', () {
    test('no network', () {
      const e = SocketException('Failed host lookup: example.org');
      final fe = friendlyFromError(e, what: 'download the forecast');
      expect(fe.cause, ErrorCause.noInternet);
      expect(fe.fix, FixAction.retry);
      expect(fe.message, isNot(contains('SocketException')));
      expect(fe.details, contains('Failed host lookup'));
      expect(
        friendlyFromError(TimeoutException('x')).cause,
        ErrorCause.noInternet,
      );
    });

    test('mobile data blocked for this app', () {
      final e = SocketException(
        'Connection failed',
        osError: const OSError('Operation not permitted', 1),
      );
      final fe = friendlyFromError(e);
      expect(fe.cause, ErrorCause.mobileDataBlocked);
      expect(fe.fix, FixAction.allowMobileData);
    });

    test('Bluetooth off and denied', () {
      expect(
        friendlyFromError(StateError('Turn Bluetooth on first.')).cause,
        ErrorCause.bluetoothOff,
      );
      expect(
        friendlyFromError(Exception('bluetooth permission denied')).cause,
        ErrorCause.bluetoothDenied,
      );
    });

    test('something else: generic sentence, raw text under Details only', () {
      final fe = friendlyFromError(
        FormatException('boom ${'a1' * 5}'),
        what: 'read the file',
      );
      expect(fe.message, 'Could not read the file, so it did not finish.');
      expect(fe.fix, FixAction.retry);
      expect(fe.details, contains('boom'));
    });
  });

  group('radio "Not saved" messages', () {
    test('did not keep: plain, Restore backup first when a backup exists', () {
      const raw =
          'Your radio did not keep: the region. Nothing else was '
          'touched.';
      final a = radioWriteError(raw, hasBackup: true);
      expect(
        a.message,
        startsWith(
          'Not saved because your radio did not '
          'keep the region.',
        ),
      );
      expect(a.fixes, [FixAction.restoreBackup, FixAction.retry]);
      expect(a.details, raw);
      final b = radioWriteError(raw);
      expect(b.fixes, [FixAction.retry]);
    });

    test('radio not connected: Connect radio', () {
      final fe = radioWriteError('Connect your radio first.');
      expect(fe.message, 'Not saved because your radio is not connected.');
      expect(fe.fix, FixAction.connectRadio);
    });

    test('radio did not come back: Connect radio (+ Restore backup)', () {
      final fe = radioWriteError(
        'The radio did not come back after restarting.',
        hasBackup: true,
      );
      expect(
        fe.message,
        startsWith(
          'Not saved because your radio did not '
          'come back',
        ),
      );
      expect(fe.fixes, [FixAction.connectRadio, FixAction.restoreBackup]);
    });

    test('no answer: Try again; a talk going on: wait', () {
      final a = radioWriteError('The radio has not sent its settings yet.');
      expect(a.message, contains('did not answer'));
      expect(a.fix, FixAction.retry);
      final b = radioWriteError('A talk is going on.');
      expect(b.message, contains('a talk is going on'));
    });

    test('an unknown reason keeps its own sentence and a Try again', () {
      final fe = radioWriteError('Some new reason.');
      expect(fe.message, 'Not saved. Some new reason.');
      expect(fe.fix, FixAction.retry);
    });

    test('details never show a channel key', () {
      final fe = radioWriteError('Bad key $fakeKey did not keep: x.');
      expect(fe.details, isNotNull);
    });
  });

  group('FriendlyErrorView and the snack bar', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets('Details are hidden until opened; buttons call onFix', (
      t,
    ) async {
      final got = <FixAction>[];
      var closed = 0;
      await t.pumpWidget(
        host(
          FriendlyErrorView(
            error: const FriendlyError(
              'Not saved because your radio is not connected.',
              fix: FixAction.connectRadio,
              fix2: FixAction.restoreBackup,
              details: 'MeshWriteException: raw words',
            ),
            onFix: got.add,
            onDismiss: () => closed++,
          ),
        ),
      );
      expect(find.byKey(const Key('fe-message')), findsOneWidget);
      expect(
        find.text('Not saved because your radio is not connected.'),
        findsOneWidget,
      );
      expect(find.textContaining('MeshWriteException'), findsNothing);
      await t.tap(find.byKey(const Key('fe-details')));
      await t.pumpAndSettle();
      expect(find.textContaining('MeshWriteException'), findsOneWidget);
      await t.tap(find.byKey(const Key('fe-fix-connectRadio')));
      await t.tap(find.byKey(const Key('fe-fix-restoreBackup')));
      expect(got, [FixAction.connectRadio, FixAction.restoreBackup]);
      await t.tap(find.byKey(const Key('fe-dismiss')));
      expect(closed, 1);
    });

    testWidgets('no details, no fix: just the sentence', (t) async {
      await t.pumpWidget(
        host(
          FriendlyErrorView(
            error: const FriendlyError('A plain sentence.'),
            onFix: (_) {},
          ),
        ),
      );
      expect(find.text('A plain sentence.'), findsOneWidget);
      expect(find.byKey(const Key('fe-details')), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('snack bar: the first usable fix is its button', (t) async {
      var retried = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                key: const Key('go'),
                onPressed: () => showFriendlySnack(
                  ctx,
                  friendlyCause(ErrorCause.noInternet),
                  null,
                  callbacks: FixCallbacks(retry: () => retried++),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('go')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('no internet'), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pump();
      expect(retried, 1);
    });

    testWidgets('snack bar with only Details opens them', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                key: const Key('go'),
                onPressed: () => showFriendlySnack(
                  ctx,
                  const FriendlyError('Could not do it.', details: 'raw text'),
                  null,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('go')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('raw text'), findsNothing);
      await t.tap(find.text('Details'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('fe-details-dialog')), findsOneWidget);
      expect(find.text('raw text'), findsOneWidget);
    });
  });

  group('on the Talk screen', () {
    testWidgets('a sound problem banner has Try again and closes', (t) async {
      phone(t, w: 360, h: 800, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      c.showError(
        friendlyCause(ErrorCause.microphoneDenied, error: StateError('raw')),
      );
      await settle(t);
      expect(find.byKey(const Key('fe-view')), findsOneWidget);
      expect(find.textContaining('microphone'), findsWidgets);
      expect(find.byKey(const Key('fe-fix-allowMicrophone')), findsOneWidget);
      await t.tap(find.byKey(const Key('fe-dismiss')));
      await settle(t);
      expect(find.byKey(const Key('fe-view')), findsNothing);
      expect(c.error, isNull);
      expect(c.errorInfo, isNull);
      await finish(t);
    });

    testWidgets('a notice with a fix gets a button in the snack bar', (
      t,
    ) async {
      phone(t, w: 360, h: 800, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      c.noticeFriendly(friendlyCause(ErrorCause.bluetoothOff));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Bluetooth is off'), findsOneWidget);
      expect(find.text('Turn on Bluetooth'), findsOneWidget);
      await finish(t);
    });

    testWidgets('a plain notice is unchanged', (t) async {
      phone(t, w: 360, h: 800, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      expect(c.noticeError('Delivered to Bandit'), isNull);
      await finish(t);
    });

    test('Try again and Restore backup are not offered from a notice', () {
      // They need a screen; the notice keeps a phone fix or Details only.
      const fe = FriendlyError('Hmm.', fix: FixAction.retry, details: 'raw');
      expect(fe.fixes, [FixAction.retry]);
    });
  });

  group('connection sheet fixes', () {
    Future<List<FixAction>> pump(WidgetTester t, ConnectionHealth h) async {
      final got = <FixAction>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConnectionHealthSheet(health: h, onFix: got.add),
            ),
          ),
        ),
      );
      return got;
    }

    testWidgets('no internet: Try again, and Wi-Fi settings with no network', (
      t,
    ) async {
      final h = v260.health(
        best: null,
        internet: TransportStatus.error,
        net: null,
        phoneNet: 'none',
      );
      final got = await pump(t, h);
      await t.tap(find.byKey(const Key('fix-Internet relay-retry')));
      await t.tap(find.byKey(const Key('fix-Internet relay-wifiSettings')));
      expect(got, [FixAction.retry, FixAction.wifiSettings]);
    });

    testWidgets('relay unreachable on Wi-Fi: Try again only', (t) async {
      final h = v260.health(
        best: null,
        internet: TransportStatus.error,
        net: null,
        phoneNet: 'wifi',
      );
      await pump(t, h);
      expect(find.byKey(const Key('fix-Internet relay-retry')), findsOneWidget);
      expect(
        find.byKey(const Key('fix-Internet relay-wifiSettings')),
        findsNothing,
      );
    });

    testWidgets('Bluetooth off for the radio: Turn on Bluetooth + Connect', (
      t,
    ) async {
      final h = v260.health(
        r: v260.radio(state: RadioState.bluetoothOff),
        best: TransportKind.internet,
      );
      final got = await pump(t, h);
      await t.tap(
        find.byKey(const Key('fix-Radio (Bluetooth)-turnOnBluetooth')),
      );
      await t.tap(find.byKey(const Key('fix-Radio (Bluetooth)-connectRadio')));
      expect(got, [FixAction.turnOnBluetooth, FixAction.connectRadio]);
    });

    testWidgets('a working connection shows no fix buttons', (t) async {
      await pump(t, v260.health());
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('without onFix the sheet is as it was', (t) async {
      final h = v260.health(
        best: null,
        internet: TransportStatus.error,
        net: null,
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConnectionHealthSheet(health: h)),
        ),
      );
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('Radio settings page', () {
    Future<(dynamic, Fw)> world(
      WidgetTester t, {
      Fw? fw0,
      bool connected = true,
    }) async {
      phone(t, w: 400, h: 3200, ts: 1.0);
      final c = await makeController(t);
      final fw = fw0 ?? Fw();
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      if (connected) {
        c.radioDevice
          ..deviceId = 'AA:BB'
          ..deviceName = 'RAK WisMesh'
          ..state = RadioState.ready
          ..session = s;
      }
      c.radioSettingsWriterFactory = () => writer(s);
      return (c, fw);
    }

    Future<void> open(WidgetTester t, dynamic c) async {
      await t.pumpWidget(
        MaterialApp(home: RadioSettingsPage(controller: c as dynamic)),
      );
      await t.pump();
    }

    Future<void> settleWrite(WidgetTester t) async {
      for (var i = 0; i < 200; i++) {
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

    Future<void> changeRegion(WidgetTester t) async {
      t
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const Key('rs-region')),
          )
          .onChanged!(3);
      await t.pump();
      final change = find.byKey(const Key('rs-region-change'));
      await t.ensureVisible(change);
      await t.pump();
      await t.tap(change);
      await t.pump();
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      await settleWrite(t);
    }

    testWidgets('a write the radio refuses: plain words, Details, '
        'Restore backup and Try again (which works once the radio does)', (
      t,
    ) async {
      final (c, fw) = await world(t, fw0: Fw(applySets: false));
      await open(t, c);
      await changeRegion(t);
      expect(find.byKey(const Key('rs-failed')), findsOneWidget);
      expect(
        find.text(
          'Not saved because your radio did not keep the region. Nothing '
          'else was touched.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Not saved:'), findsNothing);
      expect(find.byKey(const Key('rs-restore-failed')), findsOneWidget);
      expect(find.byKey(const Key('fe-fix-retry')), findsOneWidget);
      // The raw text is behind Details.
      expect(find.byKey(const Key('fe-details-text')), findsNothing);
      // The radio is fine now: Try again repeats the same change.
      fw.applySets = true;
      final retry = find.byKey(const Key('fe-fix-retry'));
      await t.ensureVisible(retry);
      await t.pump();
      await t.tap(retry);
      await t.pump();
      await t.pump();
      for (var i = 0; i < 200; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('rs-saved')).evaluate().isNotEmpty) break;
      }
      expect(find.byKey(const Key('rs-saved')), findsOneWidget);
      expect(find.byKey(const Key('rs-failed')), findsNothing);
    });

    testWidgets('no radio: the blocked line gets Connect radio', (t) async {
      final (c, _) = await world(t, connected: false);
      await open(t, c);
      expect(find.byKey(const Key('rs-blocked')), findsOneWidget);
      expect(
        find.text('Connect your radio first (Settings > Long-range radio).'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('rs-connect-radio')), findsOneWidget);
      expect(find.text('Connect radio'), findsOneWidget);
    });

    testWidgets('a connected radio has no Connect radio button', (t) async {
      final (c, _) = await world(t);
      await open(t, c);
      expect(find.byKey(const Key('rs-connect-radio')), findsNothing);
    });

    testWidgets(
      'location sharing off: a note under precision with Turn it on',
      (t) async {
        final fw = threeChannels()
          ..position = positionRaw(secs: posNever, smart: false);
        final (c, _) = await world(t, fw0: fw);
        await open(t, c);
        expect(find.byKey(const Key('rs-prec-sharing-off')), findsOneWidget);
        expect(
          find.textContaining('Location sharing is off on this radio'),
          findsOneWidget,
        );
        final turnOn = find.byKey(const Key('fe-fix-turnOnLocationSharing'));
        await t.ensureVisible(turnOn);
        await t.pump();
        await t.tap(turnOn);
        await t.pump();
        await settleWrite(t);
        // No backup: the firmware default interval (field absent) and the
        // smart-position flag come back, the same as the toggle above it.
        expect(
          rawInt(fw.position, 1) ?? 0,
          isNot(posNever),
          reason: 'not "never" any more',
        );
        expect(rawInt(fw.position, 2), 1);
        expect(find.byKey(const Key('rs-prec-sharing-off')), findsNothing);
      },
    );

    testWidgets('location sharing on: no note', (t) async {
      final (c, _) = await world(t, fw0: threeChannels());
      await open(t, c);
      expect(find.byKey(const Key('rs-prec-sharing-off')), findsNothing);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['V263_SHOTS'];
    if (dir == null) return;

    Future<void> shot(WidgetTester t, String name) async {
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v263_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    ThemeData theme() =>
        ThemeData(useMaterial3: true, brightness: Brightness.dark);

    testWidgets('Talk screen: sound problem with Allow microphone', (t) async {
      phone(t, w: 360, h: 640, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: theme(),
            home: HomePage(controller: c),
          ),
        ),
      );
      await settle(t);
      c.showError(
        friendlyCause(
          ErrorCause.microphoneDenied,
          error: StateError('PlatformException(permission, record, null)'),
        ),
      );
      await settle(t);
      await shot(t, 'talk_banner');
      c.clearError();
      c.noticeFriendly(friendlyCause(ErrorCause.bluetoothOff));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      await shot(t, 'talk_snack');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 90));
    });

    testWidgets('Connection sheet with fix buttons', (t) async {
      phone(t, w: 360, h: 640, ts: 1.0);
      final h = v260.health(
        best: null,
        internet: TransportStatus.error,
        net: null,
        phoneNet: 'none',
        r: v260.radio(state: RadioState.bluetoothOff),
      );
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: theme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ConnectionHealthSheet(health: h, onFix: (_) {}),
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await shot(t, 'connection_sheet');
    });

    testWidgets('Radio settings: Not saved, with Details open', (t) async {
      phone(t, w: 400, h: 900, ts: 1.0);
      final c = await makeController(t);
      final fw = Fw(applySets: false);
      final s = MeshtasticSession(fw);
      await t.runAsync(() => s.start(timeout: const Duration(seconds: 2)));
      addTearDown(() => t.runAsync(s.close));
      c.radioDevice
        ..deviceId = 'AA:BB'
        ..deviceName = 'RAK WisMesh'
        ..state = RadioState.ready
        ..session = s;
      c.radioSettingsWriterFactory = () => writer(s);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: theme(),
            home: RadioSettingsPage(controller: c),
          ),
        ),
      );
      await t.pump();
      t
          .widget<DropdownButtonFormField<int>>(
            find.byKey(const Key('rs-region')),
          )
          .onChanged!(3);
      await t.pump();
      final change = find.byKey(const Key('rs-region-change'));
      await t.ensureVisible(change);
      await t.pump();
      await t.tap(change);
      await t.pump();
      await t.tap(find.byKey(const Key('rs-confirm')));
      await t.pump();
      for (var i = 0; i < 200; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
        if (find.byKey(const Key('rs-failed')).evaluate().isNotEmpty) break;
      }
      final failed = find.byKey(const Key('rs-failed'));
      await t.ensureVisible(failed);
      await t.pump();
      await t.tap(find.byKey(const Key('fe-details')));
      await t.pump(const Duration(milliseconds: 400));
      await t.runAsync(
        () => Scrollable.ensureVisible(
          t.element(failed),
          alignment: 0.05,
          duration: Duration.zero,
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, 'radio_not_saved');
    });

    testWidgets('Radio settings: no radio connected', (t) async {
      phone(t, w: 400, h: 500, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            theme: theme(),
            home: RadioSettingsPage(controller: c),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      await shot(t, 'radio_blocked');
    });
  });
}
