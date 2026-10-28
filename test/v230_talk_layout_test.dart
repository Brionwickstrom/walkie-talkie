// v2.3.0: the Talk screen clean-up. The people list had been squeezed into
// a thin strip by a stack of cards and rows. Now: quiet hours is a moon chip
// on the "Who can hear this?" line, the connection icons and the backup line
// are one line, the recent clips are one History button with a dot, Ring all /
// Beep / Hold: message / Mute / History share one wrapping row, and the talk
// button shrinks on short screens and with large text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/ui/home_page.dart' show talkButtonSize;
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/quiet_widgets.dart';
import 'package:walkie_talkie/ui/who_can_hear.dart';

import 'home_layout_test.dart' show loadFonts, people;

void phone(WidgetTester t, {double w = 360, double h = 640, double ts = 1.3}) {
  t.view.physicalSize = Size(w, h) * 3;
  t.view.devicePixelRatio = 3;
  t.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
  t.view.viewPadding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
  t.platformDispatcher.textScaleFactorTestValue = ts;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
}

/// Routes and sheets finish animating (the Talk screen never "settles":
/// the talk button and the clock keep animating).
Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

class Calls {
  int ringAll = 0, beepAll = 0, record = 0, history = 0, settings = 0;
  int muted = 0, unmuted = 0, details = 0, talk = 0;
}

/// The Talk screen as home_page.dart assembles it.
Widget talkScreen(
  Calls k, {
  List<PersonView> peers = people,
  bool quiet = true,
  bool muted = false,
  bool details = false,
  int unheard = 2,
  bool hasTakes = true,
  String internetText = 'Internet: connected via Wi-Fi (Home relay)',
}) => MaterialApp(
  theme: ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Roboto',
  ),
  home: Builder(
    builder: (context) {
      final mq = MediaQuery.of(context);
      final pttSize = talkButtonSize(mq.size.height, mq.textScaler);
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 8,
          title: const Text('CH 1'),
          bottom: whoCanHearBottom(
            context,
            const AudienceInfo(Audience.open, channel: 1),
            trailing: quiet
                ? QuietChip(
                    text: muted ? 'Muted' : 'Quiet hours until 7:00 AM',
                    muted: muted,
                    onTap: () => showQuietSheet(
                      context,
                      text: muted ? 'Muted' : 'Quiet hours until 7:00 AM',
                      muted: muted,
                      onUnmute: () => k.unmuted++,
                      onSettings: () => k.settings++,
                    ),
                  )
                : null,
          ),
          actions: [
            IconButton(
              onPressed: () {},
              icon: const Icon(Icons.chat_bubble_outline),
            ),
            IconButton(onPressed: () {}, icon: const Icon(Icons.people)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.voicemail)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.settings)),
          ],
        ),
        body: HomeBody(
          links: const [
            (TransportKind.lan, TransportStatus.running),
            (TransportKind.ble, TransportStatus.unavailable),
            (TransportKind.internet, TransportStatus.running),
          ],
          internet: (status: TransportStatus.running, text: internetText),
          bestPath: 'Home relay 42 ms · 1 backup ready',
          showDetails: details,
          onToggleDetails: (_) => k.details++,
          details: const ['WiFi: running · IP 192.168.68.54/22'],
          channelLabel: 'CH 1',
          me: const PersonView(id: 0x1234, name: 'Lord of the Pings', me: true),
          people: peers,
          onRing: (_) {},
          onBeep: (_) {},
          onMessage: (_) {},
          onEditMe: () {},
          actions: ChannelActions(
            onRingAll: () => k.ringAll++,
            onBeepAll: () => k.beepAll++,
            record: OutlinedButton.icon(
              key: const Key('record'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => k.record++,
              icon: const Icon(Icons.keyboard_voice),
              label: const Text('Hold: message'),
            ),
            mute: MuteButton(
              muted: muted,
              onMute: () => k.muted++,
              onUnmute: () => k.unmuted++,
            ),
            history: hasTakes
                ? HistoryButton(unheard: unheard, onOpen: () => k.history++)
                : null,
          ),
          ptt: MainTalkArea(
            button: PttButton(
              key: const Key('ptt'),
              transmitting: false,
              busy: false,
              onChanged: (v) => k.talk++,
              size: pttSize,
              caption: 'Talk to CH 1 (3 people)',
            ),
          ),
        ),
      );
    },
  ),
);

Finder get peopleList =>
    find.descendant(of: find.byType(HomeBody), matching: find.byType(ListView));

void main() {
  setUpAll(loadFonts);

  final controls = <String, Finder>{
    'Ring all': find.text('Ring all'),
    'Beep': find.text('Beep'),
    'Hold: message': find.byKey(const Key('record')),
    'Mute': find.byKey(const Key('muteButton')),
    'History': find.byKey(const Key('open-history')),
    'Talk': find.byKey(const Key('ptt')),
    'quiet chip': find.byKey(const Key('quiet-chip')),
    'Who can hear': find.byKey(const Key('who-can-hear')),
    'connections': find.byKey(const Key('link-internet')),
    'Details': find.byKey(const Key('toggle-details')),
  };

  for (final (label, w, h, ts) in [
    ('360x640 at 1.3x text', 360.0, 640.0, 1.3),
    ('360x640 at 1.0x text', 360.0, 640.0, 1.0),
    ('320x568 at 1.3x text', 320.0, 568.0, 1.3),
    ('411x891 at 1.0x text', 411.0, 891.0, 1.0),
  ]) {
    testWidgets('$label: the people list keeps its room, every control is '
        'reachable', (t) async {
      phone(t, w: w, h: h, ts: ts);
      final k = Calls();
      await t.pumpWidget(talkScreen(k));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);

      // The list is a real share of the screen (the old stack left a thin
      // strip, about 90 dp on this phone).
      final list = t.getSize(peopleList.first);
      // ignore: avoid_print
      print('$label: people list ${list.width} x ${list.height}');
      // A very short phone (568 dp) with large text cannot give the list
      // as much; it still gets a card and a half.
      expect(
        list.height,
        greaterThanOrEqualTo(h < 600 ? 80 : h * 0.28),
        reason: label,
      );

      // Every control is on screen and not covered.
      for (final e in controls.entries) {
        expect(e.value, findsOneWidget, reason: '${e.key} exists');
        final r = t.getRect(e.value);
        expect(
          r.top >= 0 && r.bottom <= h && r.left >= 0 && r.right <= w,
          isTrue,
          reason: '${e.key} $r is inside the $w x $h screen',
        );
        expect(e.value.hitTestable(), findsOneWidget, reason: e.key);
      }

      // The talk button is still big.
      expect(
        t.getSize(controls['Talk']!).shortestSide,
        greaterThanOrEqualTo(96),
      );

      // The row is at most two lines (wraps, never scrolls away).
      final ring = t.getRect(controls['Ring all']!);
      final hist = t.getRect(controls['History']!);
      // Two lines on a normal phone, three on a 320 dp one at large text.
      expect(
        hist.bottom - ring.top,
        lessThan(w < 340 ? 130 : 100),
        reason: 'the row wraps, it never scrolls away',
      );

      // The first person's name is shown whole (not on the 568 dp phone:
      // its list shows the header and "you" and scrolls for the rest).
      if (h >= 600) {
        final name = find.text('Rubber Duck');
        expect(name, findsOneWidget);
        expect(t.getSize(name).height, lessThan(70), reason: 'at most 2 lines');
      }
    });
  }

  testWidgets('the controls still do their jobs', (t) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(controls['Ring all']!);
    await t.tap(controls['Beep']!);
    await t.tap(controls['Hold: message']!);
    await t.tap(controls['History']!);
    await t.tap(controls['Details']!);
    expect(
      (k.ringAll, k.beepAll, k.record, k.history, k.details),
      (1, 1, 1, 1, 1),
    );
  });

  testWidgets('History: a dot only while something is unheard, none lost', (
    t,
  ) async {
    phone(t);
    await t.pumpWidget(talkScreen(Calls(), unheard: 3));
    Badge badge() => t.widget<Badge>(
      find.descendant(of: controls['History']!, matching: find.byType(Badge)),
    );
    expect(badge().isLabelVisible, isTrue);
    expect(badge().label, isNull, reason: 'a dot, not a number');
    await t.pumpWidget(talkScreen(Calls(), unheard: 0));
    expect(badge().isLabelVisible, isFalse);
    await t.pumpWidget(talkScreen(Calls(), hasTakes: false));
    expect(controls['History']!, findsNothing, reason: 'nothing to open yet');
  });

  testWidgets('quiet hours: no card on the Talk screen, a moon chip opens '
      'Change', (t) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k));
    expect(find.byKey(const Key('quietBanner')), findsNothing);
    expect(find.byIcon(Icons.bedtime), findsOneWidget);
    await t.tap(controls['quiet chip']!);
    await settle(t);
    expect(find.byKey(const Key('quietBanner')), findsOneWidget);
    expect(find.text('Quiet hours until 7:00 AM'), findsOneWidget);
    expect(
      find.text('Missed talk, rings and voice messages are kept.'),
      findsOneWidget,
    );
    await t.tap(find.text('Change'));
    await settle(t);
    expect(k.settings, 1);
    expect(find.byKey(const Key('quietBanner')), findsNothing);
    // The "Who can hear this?" line still opens its own sheet.
    await t.tap(controls['Who can hear']!);
    await settle(t);
    expect(find.byKey(const Key('who-can-hear-sheet')), findsOneWidget);
  });

  testWidgets('no quiet hours: no chip', (t) async {
    phone(t);
    await t.pumpWidget(talkScreen(Calls(), quiet: false));
    expect(controls['quiet chip']!, findsNothing);
  });

  testWidgets('muted: the chip opens Unmute, which still needs the 2.5 s hold '
      'and the confirm', (t) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k, muted: true));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.volume_off), findsWidgets);
    await t.tap(controls['quiet chip']!);
    await settle(t);
    final unmute = find.byKey(const Key('bannerUnmute'));
    expect(unmute, findsOneWidget);
    // A tap alone does nothing.
    await t.tap(unmute);
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Keep holding to unmute'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(k.unmuted, 0);
    final g = await t.startGesture(t.getCenter(unmute));
    await t.pump();
    await t.pump(const Duration(milliseconds: 2600));
    await g.up();
    await settle(t);
    expect(find.text('Unmute Walkie?'), findsOneWidget);
    expect(k.unmuted, 0);
    await t.tap(find.byKey(const Key('muteConfirmOk')));
    await settle(t);
    expect(k.unmuted, 1);
  });

  testWidgets('Mute in the row keeps the 2.5 s hold and the confirm', (
    t,
  ) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k));
    await t.pump(const Duration(milliseconds: 300));
    final mute = controls['Mute']!;
    await t.tap(mute);
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Keep holding to mute'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(k.muted, 0);
    final g = await t.startGesture(t.getCenter(mute));
    await t.pump();
    await t.pump(const Duration(milliseconds: 1000));
    await g.up();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Mute Walkie?'), findsNothing, reason: 'let go early');
    await t.pump(const Duration(seconds: 2));
    final g2 = await t.startGesture(t.getCenter(mute));
    await t.pump();
    await t.pump(const Duration(milliseconds: 2600));
    await g2.up();
    await settle(t);
    expect(find.text('Mute Walkie?'), findsOneWidget);
    await t.tap(find.byKey(const Key('muteConfirmCancel')));
    await settle(t);
    expect(k.muted, 0, reason: 'Cancel changes nothing');
  });

  testWidgets('one connection line: "Internet via Wi-Fi · Home relay 42 ms · '
      '1 backup ready"; Details has the full text', (t) async {
    phone(t, ts: 1.0);
    await t.pumpWidget(talkScreen(Calls()));
    await t.pump(const Duration(milliseconds: 300));
    final line = t.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('internet-status')),
        matching: find.byType(Text),
      ),
    );
    expect(
      line.textSpan!.toPlainText(),
      'Internet via Wi-Fi · Home relay 42 ms · 1 backup ready',
    );
    // The old second line is gone while Details is closed.
    expect(find.byKey(const Key('best-path')), findsNothing);
    await t.pumpWidget(talkScreen(Calls(), details: true));
    await t.pump(const Duration(milliseconds: 300));
    final full = t.widget<SelectableText>(find.byKey(const Key('best-path')));
    final text = full.data ?? full.textSpan!.toPlainText();
    expect(text, contains('Internet: connected via Wi-Fi (Home relay)'));
    expect(text, contains('Home relay 42 ms · 1 backup ready'));
    expect(text, contains('WiFi: running'));
  });

  test('compactInternetText', () {
    expect(
      compactInternetText('Internet: connected via mobile data (Home relay)'),
      'Internet via mobile data',
    );
    expect(
      compactInternetText('Internet: not connected'),
      'Internet: not connected',
    );
    expect(
      compactInternetText('Internet: connecting…'),
      'Internet: connecting…',
    );
  });

  test('talkButtonSize: shrinks on short screens and with large text, stays '
      'big', () {
    const normal = TextScaler.noScaling;
    final big = TextScaler.linear(1.3);
    expect(talkButtonSize(891, normal), closeTo(151.5, 0.1));
    expect(talkButtonSize(2000, normal), 160);
    expect(talkButtonSize(640, normal), closeTo(108.8, 0.1));
    expect(talkButtonSize(640, big), lessThan(talkButtonSize(640, normal)));
    expect(talkButtonSize(640, big), greaterThanOrEqualTo(96));
    expect(talkButtonSize(480, TextScaler.linear(2)), 96);
    expect(talkButtonSize(900, big), lessThan(talkButtonSize(900, normal)));
  });
}
