// v1.8.5: tappable connection icons -> status sheet -> matching settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/link_settings.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/link_sheet.dart';

void main() {
  group('which settings', () {
    test('each connection maps to its settings screen', () {
      expect(settingFor(TransportKind.internet), PhoneSetting.appInfo);
      expect(settingFor(TransportKind.lan), PhoneSetting.wifi);
      expect(settingFor(TransportKind.wifiDirect), PhoneSetting.wifi);
      expect(settingFor(TransportKind.ble), PhoneSetting.bluetooth);
      expect(settingFor(TransportKind.lora), PhoneSetting.radioPairing);
      expect(PhoneSetting.appInfo.wire, 'app');
      expect(PhoneSetting.location.wire, 'location');
    });

    test('internet on mobile data, relay down: tells how to allow data', () {
      final i = describeLink(
        TransportKind.internet,
        TransportStatus.error,
        detail: 'Relay connection lost: timeout',
        netKind: 'cell',
      );
      expect(i.state, startsWith('Not working: Relay connection lost'));
      expect(i.help, contains('Mobile data and Background data'));
      expect(i.button, 'Open phone settings');
      expect(i.connected, isFalse);
      final up = describeLink(TransportKind.internet, TransportStatus.running);
      expect(up.state, 'Connected');
      expect(up.connected, isTrue);
      final off = describeLink(
        TransportKind.internet,
        TransportStatus.stopped,
        offlineSaver: true,
      );
      expect(off.state, 'Off (Offline power save)');
    });

    test('Bluetooth permission missing asks for it first', () {
      final i = describeLink(
        TransportKind.ble,
        TransportStatus.error,
        permissionMissing: true,
      );
      expect(i.state, 'Bluetooth permission missing');
      expect(i.button, 'Allow Bluetooth');
      expect(i.permissionMissing, isTrue);
      final ok = describeLink(TransportKind.ble, TransportStatus.running);
      expect(ok.button, 'Open Bluetooth settings');
    });

    test('Wi-Fi, Wi-Fi Direct, radio and iOS labels', () {
      expect(
        describeLink(TransportKind.lan, TransportStatus.stopped).button,
        'Open Wi-Fi settings',
      );
      expect(
        describeLink(TransportKind.wifiDirect, TransportStatus.running).title,
        'Wi-Fi Direct',
      );
      expect(
        describeLink(TransportKind.lora, TransportStatus.stopped).button,
        'Radio pairing',
      );
      expect(
        describeLink(
          TransportKind.lan,
          TransportStatus.stopped,
          ios: true,
        ).button,
        'Open app settings',
      );
    });

    test('"Allow mobile data" only on mobile data with the relay down', () {
      bool hint({
        TransportStatus s = TransportStatus.error,
        String? net = 'cell',
        bool relay = true,
        bool offline = false,
      }) => showMobileDataHint(
        internet: s,
        netKind: net,
        hasRelay: relay,
        offlineSaver: offline,
      );
      expect(hint(), isTrue);
      expect(hint(s: TransportStatus.running), isFalse);
      expect(hint(s: TransportStatus.starting), isFalse);
      expect(hint(net: 'wifi'), isFalse);
      expect(hint(net: null), isFalse);
      expect(hint(relay: false), isFalse);
      expect(hint(offline: true), isFalse);
    });
  });

  group('UI', () {
    Widget row({
      required ValueChanged<TransportKind> onTap,
      bool hint = false,
    }) => MaterialApp(
      home: Scaffold(
        body: StatusRow(
          links: const [
            (TransportKind.lan, TransportStatus.running),
            (TransportKind.ble, TransportStatus.error),
            (TransportKind.internet, TransportStatus.error),
          ],
          internet: (status: TransportStatus.error, text: 'Internet: offline'),
          showDetails: false,
          onToggleDetails: (_) {},
          onLinkTap: onTap,
          mobileDataHint: hint,
        ),
      ),
    );

    testWidgets('each icon and the internet line are tappable', (t) async {
      final taps = <TransportKind>[];
      await t.pumpWidget(row(onTap: taps.add));
      await t.tap(find.byKey(const Key('link-lan')));
      await t.tap(find.byKey(const Key('link-ble')));
      await t.tap(find.byKey(const Key('link-internet')));
      await t.tap(find.byKey(const Key('internet-status')));
      expect(taps, [
        TransportKind.lan,
        TransportKind.ble,
        TransportKind.internet,
        TransportKind.internet,
      ]);
      expect(find.byKey(const Key('allow-mobile-data')), findsNothing);
    });

    testWidgets('"Allow mobile data" opens the internet sheet', (t) async {
      final taps = <TransportKind>[];
      await t.pumpWidget(row(onTap: taps.add, hint: true));
      await t.tap(find.byKey(const Key('allow-mobile-data')));
      expect(taps, [TransportKind.internet]);
    });

    testWidgets('the sheet shows the status and one settings button', (
      t,
    ) async {
      var opened = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkSheetView(
              kind: TransportKind.ble,
              info: describeLink(
                TransportKind.ble,
                TransportStatus.error,
                permissionMissing: true,
              ),
              onAction: () => opened++,
            ),
          ),
        ),
      );
      expect(find.text('Bluetooth permission missing'), findsOneWidget);
      expect(opened, 0, reason: 'nothing opens until the button is tapped');
      await t.tap(find.byKey(const Key('link-open-settings')));
      expect(opened, 1);
    });
  });
}
