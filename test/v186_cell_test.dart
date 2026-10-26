// v1.8.6: the Cell / mobile data icon: parsing, states, sheet, UI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/link_settings.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/link_sheet.dart';

const cellOk = CellInfo(
  dataUp: true,
  validated: true,
  sim: true,
  service: true,
  level: 3,
  type: 'LTE',
);

CellState st({
  CellInfo? info = cellOk,
  bool relayUp = false,
  String? relayNet,
  String? phoneNet = 'cell',
  bool hasRelay = true,
  bool offline = false,
}) => cellState(
  info: info,
  relayUp: relayUp,
  relayNet: relayNet,
  phoneNet: phoneNet,
  hasRelay: hasRelay,
  offlineSaver: offline,
);

void main() {
  group('cell info', () {
    test('parses the bridge map, rejects junk', () {
      final i = CellInfo.fromMap({
        'dataUp': true,
        'validated': true,
        'defaultCell': true,
        'sim': true,
        'service': true,
        'level': 4,
        'type': '5G',
        'airplane': false,
        'dataSaver': true,
      })!;
      expect(i.dataUp, isTrue);
      expect(i.defaultCell, isTrue);
      expect(i.level, 4);
      expect(i.type, '5G');
      expect(i.dataSaver, isTrue);
      expect(i.cellUp, isTrue);
      expect(CellInfo.fromMap(null), isNull);
      final bad = CellInfo.fromMap({'level': 9, 'type': '', 'dataUp': 'yes'})!;
      expect(bad.level, isNull);
      expect(bad.type, isNull);
      expect(bad.dataUp, isFalse);
      expect(CellInfo.fromMap({'level': 2}), CellInfo.fromMap({'level': 2}));
    });

    test('label: technology and bars', () {
      expect(cellLabel(cellOk), 'LTE, 3/4 bars');
      expect(cellLabel(const CellInfo(level: 0)), '0/4 bars');
      expect(cellLabel(const CellInfo()), '');
      expect(cellLabel(null), '');
    });
  });

  group('states', () {
    test('active: the relay is connected over mobile data', () {
      expect(st(relayUp: true, relayNet: 'mobile data'), CellState.active);
      // Even when the details are unknown.
      expect(
        st(info: null, relayUp: true, relayNet: 'mobile data'),
        CellState.active,
      );
    });

    test('available: cell up, app on Wi-Fi or no relay set', () {
      expect(st(relayUp: true, relayNet: 'Wi-Fi'), CellState.available);
      expect(st(hasRelay: false), CellState.available);
      // Relay down while on Wi-Fi: not the cell's fault.
      expect(st(phoneNet: 'wifi'), CellState.available);
    });

    test('off: no service, no SIM or airplane mode', () {
      expect(st(info: const CellInfo()), CellState.off);
      expect(
        st(info: const CellInfo(service: true, airplane: true)),
        CellState.off,
      );
      // Airplane mode but a cellular data network still up (it counts).
      expect(
        st(
          info: const CellInfo(dataUp: true, airplane: true),
          relayUp: true,
          relayNet: 'mobile data',
        ),
        CellState.active,
      );
    });

    test('blocked: cell up, no Wi-Fi, relay unreachable', () {
      expect(st(), CellState.blocked);
      expect(
        st(info: const CellInfo(service: true, sim: true), phoneNet: 'none'),
        CellState.blocked,
        reason: 'service but no data network: mobile data off',
      );
      expect(
        st(
          info: const CellInfo(
            dataUp: true,
            validated: true,
            defaultCell: true,
            service: true,
          ),
          phoneNet: 'wifi',
        ),
        CellState.blocked,
        reason: 'cell is the default network after all',
      );
    });

    test('Offline power save and unknown phones', () {
      expect(st(offline: true), CellState.saver);
      expect(
        st(offline: true, relayUp: true, relayNet: 'mobile data'),
        CellState.saver,
      );
      expect(st(info: null), CellState.unknown);
    });
  });

  group('sheet', () {
    test('every state opens App info, with mobile network settings too', () {
      for (final s in CellState.values) {
        final i = describeCell(s, cellOk);
        expect(i.setting, PhoneSetting.appInfo, reason: '$s');
        expect(i.button, 'Open phone settings');
        expect(i.secondSetting, PhoneSetting.mobileNetwork);
        expect(i.secondButton, 'Mobile network settings');
      }
      expect(PhoneSetting.mobileNetwork.wire, 'mobile');
    });

    test('texts per state', () {
      expect(
        describeCell(CellState.active, cellOk).state,
        'Using mobile data (LTE, 3/4 bars)',
      );
      expect(describeCell(CellState.active, cellOk).connected, isTrue);
      expect(
        describeCell(CellState.available, cellOk).state,
        startsWith('Available'),
      );
      expect(
        describeCell(CellState.off, const CellInfo(airplane: true)).state,
        'Off (airplane mode)',
      );
      expect(
        describeCell(CellState.off, const CellInfo()).state,
        'No SIM / no service',
      );
      final b = describeCell(
        CellState.blocked,
        const CellInfo(service: true, dataSaver: true),
      );
      expect(b.help, contains('Background data'));
      expect(b.help, contains('Data saver is on'));
      expect(
        describeCell(CellState.saver, null).state,
        'Off (Offline power save)',
      );
    });

    test('iOS: app settings only', () {
      final i = describeCell(CellState.unknown, null, ios: true);
      expect(i.button, 'Open app settings');
      expect(i.secondButton, isNull);
      expect(i.state, 'Not available on this phone');
    });
  });

  group('UI', () {
    test('icon and color per state', () {
      expect(cellIcon(CellState.off, null), Icons.signal_cellular_off);
      expect(cellIcon(CellState.saver, 4), Icons.signal_cellular_off);
      expect(
        cellIcon(CellState.blocked, 4),
        Icons.signal_cellular_connected_no_internet_4_bar,
      );
      expect(cellIcon(CellState.active, 1), Icons.signal_cellular_alt_1_bar);
      expect(cellIcon(CellState.available, 2), Icons.signal_cellular_alt_2_bar);
      expect(cellIcon(CellState.available, 0), Icons.signal_cellular_0_bar);
      expect(cellColor(CellState.active), Colors.green);
      expect(cellColor(CellState.blocked), Colors.orange);
      expect(cellColor(CellState.saver), Colors.grey);
    });

    Widget row({CellState? cell, VoidCallback? onCell, bool internet = true}) =>
        MaterialApp(
          home: Scaffold(
            body: StatusRow(
              links: [
                (TransportKind.lan, TransportStatus.running),
                if (internet) (TransportKind.internet, TransportStatus.running),
                (TransportKind.ble, TransportStatus.running),
              ],
              internet: (status: TransportStatus.running, text: 'Internet'),
              showDetails: false,
              onToggleDetails: (_) {},
              onLinkTap: (_) {},
              cell: cell,
              cellLevel: 3,
              onCellTap: onCell,
            ),
          ),
        );

    testWidgets('the Cell icon sits right after Internet and opens its sheet', (
      t,
    ) async {
      var taps = 0;
      await t.pumpWidget(row(cell: CellState.active, onCell: () => taps++));
      final cellX = t.getCenter(find.byKey(const Key('link-cell'))).dx;
      final netX = t.getCenter(find.byKey(const Key('link-internet'))).dx;
      final bleX = t.getCenter(find.byKey(const Key('link-ble'))).dx;
      expect(cellX, greaterThan(netX));
      expect(cellX, lessThan(bleX));
      await t.tap(find.byKey(const Key('link-cell')));
      expect(taps, 1);
      expect(find.byIcon(Icons.signal_cellular_alt), findsOneWidget);
    });

    testWidgets('no Internet icon: Cell still shown; null: hidden', (t) async {
      await t.pumpWidget(row(cell: CellState.off, internet: false));
      expect(find.byKey(const Key('link-cell')), findsOneWidget);
      await t.pumpWidget(row());
      expect(find.byKey(const Key('link-cell')), findsNothing);
    });

    testWidgets('sheet: App info and mobile network buttons', (t) async {
      var first = 0, second = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkSheetView(
              kind: TransportKind.internet,
              icon: Icons.signal_cellular_alt,
              info: describeCell(CellState.blocked, cellOk),
              onAction: () => first++,
              onSecond: () => second++,
            ),
          ),
        ),
      );
      expect(find.text('Mobile data'), findsOneWidget);
      expect(find.byIcon(Icons.signal_cellular_alt), findsWidgets);
      await t.tap(find.byKey(const Key('link-open-settings')));
      await t.tap(find.byKey(const Key('link-second-settings')));
      expect((first, second), (1, 1));
    });
  });
}
