// v1.8.7 (prepared): explain why nobody shows up over the internet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/link_settings.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/ui/home_view.dart';

AloneReason why({
  bool offline = false,
  bool relay = true,
  TransportStatus net = TransportStatus.running,
  String? detail,
  CellState cell = CellState.available,
  bool private = false,
}) => aloneReason(
  offlineSaver: offline,
  hasRelay: relay,
  internet: net,
  internetDetail: detail,
  cell: cell,
  channelLabel: 'CH 1',
  isPrivate: private,
);

void main() {
  test('Offline power save and relay off come first', () {
    expect(why(offline: true).text, contains('Offline power save is on'));
    expect(why(offline: true).fix, isNull);
    expect(why(relay: false).text, contains('turned off in Settings'));
  });

  test('relay not connected: says why and offers a fix', () {
    final b = why(
      net: TransportStatus.error,
      detail: 'Relay unreachable: timed out after 75s',
      cell: CellState.blocked,
    );
    expect(b.text, contains('over mobile data'));
    expect(b.text, contains('timed out'));
    expect(b.fix, PhoneSetting.appInfo);
    final off = why(net: TransportStatus.error, cell: CellState.off);
    expect(off.text, contains('no mobile service'));
    expect(off.fix, PhoneSetting.mobileNetwork);
    expect(why(net: TransportStatus.starting).text, contains('Connecting'));
  });

  test('relay connected: the other phone is the problem', () {
    final r = why(private: true);
    expect(r.text, contains('Connected to the internet relay on CH 1'));
    expect(r.text, contains('same code'));
    expect(r.fix, isNull);
    expect(why().text, isNot(contains('passcode')));
  });

  testWidgets('shown under an empty people list with a fix button', (t) async {
    PhoneSetting? opened;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeBody(
            channelLabel: 'CH 1',
            me: const PersonView(id: 1, name: 'Me', me: true),
            people: const [],
            onRing: (_) {},
            onBeep: (_) {},
            onMessage: (_) {},
            alone: why(net: TransportStatus.error, cell: CellState.blocked),
            onAloneFix: (s) => opened = s,
            actions: const SizedBox(),
            ptt: const SizedBox(height: 40),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('alone-reason')), findsOneWidget);
    await t.tap(find.byKey(const Key('alone-fix')));
    expect(opened, PhoneSetting.appInfo);
  });
}
