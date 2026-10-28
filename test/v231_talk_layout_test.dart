// v2.3.1: the declutter, as pure views on small phones and with large text:
// one status line (with chips only when they apply), one row of four equal
// action buttons, the people list keeps its room, the Chat and People tabs,
// "Who can hear this?" with Add people in a private group, and the Channels
// list's Add people / Group settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart'
    show ConnectionSummary;
import 'package:walkie_talkie/ui/channels_sheet.dart';
import 'package:walkie_talkie/ui/home_page.dart' show talkButtonSize;
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/quiet_widgets.dart';
import 'package:walkie_talkie/ui/status_line.dart';
import 'package:walkie_talkie/ui/who_can_hear.dart';

import 'home_layout_test.dart' show loadFonts, people;
import 'v231_helpers.dart' show phone, settle;

class Calls {
  int ringAll = 0, beepAll = 0, record = 0, settings = 0, status = 0;
  int muted = 0, unmuted = 0, talk = 0, volume = 0, addPeople = 0;
}

const _summary = ConnectionSummary(
  best: 'Home relay',
  bestRtt: Duration(milliseconds: 42),
  backups: 1,
  checkEvery: Duration(seconds: 5),
);

Widget talkScreen(
  Calls k, {
  List<PersonView> peers = people,
  bool quiet = true,
  bool muted = false,
  bool volumeLow = true,
  bool mobileData = false,
  bool private = false,
  AudienceInfo? audience,
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
          titleSpacing: 4,
          title: const Text('CH 1'),
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.settings)),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          height: 60,
          selectedIndex: 0,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.mic), label: 'Talk'),
            NavigationDestination(icon: Icon(Icons.chat), label: 'Chat'),
            NavigationDestination(icon: Icon(Icons.people), label: 'People'),
            NavigationDestination(icon: Icon(Icons.terrain), label: 'Trip'),
          ],
        ),
        body: HomeBody(
          status: TalkStatusLine(
            audience:
                audience ??
                (private
                    ? const AudienceInfo(Audience.privateGroup)
                    : const AudienceInfo(Audience.open, channel: 1)),
            here: peers.length + 1,
            netStatus: TransportStatus.running,
            netText: 'Internet: connected via Wi-Fi (Home relay)',
            summary: _summary,
            volumeLow: volumeLow,
            onVolumeLow: () => k.volume++,
            mobileDataHint: mobileData,
            onMobileData: () {},
            quiet: quiet
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
            onOpen: () => k.status++,
          ),
          channelLabel: 'CH 1',
          isPrivate: private,
          onAddPeople: private ? () => k.addPeople++ : null,
          onShareInvite: private ? () {} : null,
          me: const PersonView(id: 0x1234, name: 'Lord of the Pings', me: true),
          people: peers,
          onRing: (_) {},
          onBeep: (_) {},
          onMessage: (_) {},
          onEditMe: () {},
          actions: ChannelActions(
            onRingAll: () => k.ringAll++,
            onBeepAll: () => k.beepAll++,
            record: ActionTile(
              key: const Key('record'),
              icon: Icons.keyboard_voice,
              label: 'Message',
              onPressed: () => k.record++,
            ),
            mute: MuteButton(
              tile: true,
              muted: muted,
              onMute: () => k.muted++,
              onUnmute: () => k.unmuted++,
            ),
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
    'Ring all': find.byKey(const Key('ring-all')),
    'Beep': find.byKey(const Key('beep-all')),
    'Message': find.byKey(const Key('record')),
    'Mute': find.byKey(const Key('muteButton')),
    'Talk': find.byKey(const Key('ptt')),
    'quiet chip': find.byKey(const Key('quiet-chip')),
    'status line': find.byKey(const Key('status-line')),
    'volume chip': find.byKey(const Key('volume-low-chip')),
  };

  for (final (label, w, h, ts) in [
    ('360x640 at 1.3x text', 360.0, 640.0, 1.3),
    ('360x640 at 1.0x text', 360.0, 640.0, 1.0),
    ('320x568 at 1.3x text', 320.0, 568.0, 1.3),
    ('411x891 at 1.0x text', 411.0, 891.0, 1.0),
  ]) {
    testWidgets('$label: the people list keeps its room, every control is '
        'reachable, the four buttons share one row', (t) async {
      phone(t, w: w, h: h, ts: ts);
      await t.pumpWidget(talkScreen(Calls()));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);

      final list = t.getSize(peopleList.first);
      // ignore: avoid_print
      print('$label: people list ${list.width} x ${list.height}');
      expect(
        list.height,
        greaterThanOrEqualTo(h < 600 ? 90 : h * 0.28),
        reason: label,
      );
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
      expect(
        t.getSize(controls['Talk']!).shortestSide,
        greaterThanOrEqualTo(96),
      );
      // The four buttons: equal, one row, never wrapped.
      final four = [
        for (final n in ['Ring all', 'Beep', 'Message', 'Mute'])
          t.getRect(controls[n]!),
      ];
      for (final r in four) {
        expect(r.top, four.first.top, reason: 'one row');
        expect(r.width, closeTo(four.first.width, 1));
        expect(r.height, lessThan(80));
      }
      // The status line is at most two lines.
      expect(t.getSize(controls['status line']!).height, lessThan(60));
      if (h >= 600) {
        final name = find.text('Rubber Duck');
        expect(name, findsOneWidget);
        expect(t.getSize(name).height, lessThan(70));
      }
    });
  }

  testWidgets('the buttons still do their jobs; the line opens the sheet', (
    t,
  ) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(controls['Ring all']!);
    await t.tap(controls['Beep']!);
    await t.tap(controls['Message']!);
    await t.tap(controls['status line']!);
    await t.tap(controls['volume chip']!);
    expect(
      (k.ringAll, k.beepAll, k.record, k.status, k.volume),
      (1, 1, 1, 1, 1),
    );
  });

  testWidgets('one line: audience, people, network, backup; chips only when '
      'they apply', (t) async {
    phone(t, ts: 1.0);
    await t.pumpWidget(talkScreen(Calls()));
    await t.pump(const Duration(milliseconds: 300));
    String line() => t
        .widget<Text>(find.byKey(const Key('status-line-text')))
        .textSpan!
        .toPlainText();
    expect(line(), 'Open channel CH 1 · 6 people · Wi-Fi · backup ready');
    expect(controls['quiet chip']!, findsOneWidget);
    expect(controls['volume chip']!, findsOneWidget);
    expect(find.byKey(const Key('allow-mobile-data')), findsNothing);
    await t.pumpWidget(
      talkScreen(Calls(), quiet: false, volumeLow: false, mobileData: true),
    );
    await t.pump(const Duration(milliseconds: 300));
    expect(controls['quiet chip']!, findsNothing);
    expect(controls['volume chip']!, findsNothing);
    expect(find.byKey(const Key('allow-mobile-data')), findsOneWidget);
    await t.pumpWidget(talkScreen(Calls(), private: true));
    await t.pump(const Duration(milliseconds: 300));
    expect(line(), startsWith('Private group · 6 people · Wi-Fi'));
  });

  testWidgets('low volume chip: amber speaker, takes no extra row', (t) async {
    phone(t);
    await t.pumpWidget(talkScreen(Calls()));
    await t.pump(const Duration(milliseconds: 300));
    final icon = t.widget<Icon>(
      find.descendant(
        of: controls['volume chip']!,
        matching: find.byType(Icon),
      ),
    );
    expect(icon.icon, Icons.volume_down);
    expect(icon.color, Colors.amber);
    final withIt = t.getSize(peopleList.first).height;
    await t.pumpWidget(talkScreen(Calls(), volumeLow: false));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getSize(peopleList.first).height, withIt);
  });

  testWidgets('quiet hours chip opens Change; the line still opens its own '
      'sheet', (t) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k));
    expect(find.byKey(const Key('quietBanner')), findsNothing);
    await t.tap(controls['quiet chip']!);
    await settle(t);
    expect(find.text('Quiet hours until 7:00 AM'), findsOneWidget);
    await t.tap(find.text('Change'));
    await settle(t);
    expect(k.settings, 1);
    expect(k.status, 0, reason: 'the chip is its own target');
  });

  testWidgets('muted: the chip opens Unmute, which keeps the 2.5 s hold and '
      'the confirm', (t) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k, muted: true));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(controls['quiet chip']!);
    await settle(t);
    final unmute = find.byKey(const Key('bannerUnmute'));
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

  testWidgets('empty private group: a big Add people on a small phone', (
    t,
  ) async {
    phone(t, w: 320, h: 568);
    final k = Calls();
    await t.pumpWidget(talkScreen(k, peers: const [], private: true));
    await t.pump(const Duration(milliseconds: 300));
    final add = find.byKey(const Key('empty-add-people'));
    expect(add.hitTestable(), findsOneWidget);
    expect(find.textContaining('Nobody on'), findsNothing);
    expect(t.getSize(add).height, greaterThanOrEqualTo(56));
    await t.tap(add);
    expect(k.addPeople, 1);
    expect(find.byKey(const Key('empty-share-invite')), findsOneWidget);
  });

  testWidgets('empty open channel: a simple note, no Add people', (t) async {
    phone(t);
    await t.pumpWidget(talkScreen(Calls(), peers: const []));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Nobody on CH 1 yet'), findsOneWidget);
    expect(find.byKey(const Key('empty-add-people')), findsNothing);
  });

  testWidgets('private group with people: a small Add people under the list', (
    t,
  ) async {
    phone(t);
    final k = Calls();
    await t.pumpWidget(talkScreen(k, private: true));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('empty-add-people')), findsNothing);
    final f = find.byKey(const Key('list-add-people'));
    await t.scrollUntilVisible(
      f,
      150,
      scrollable: find
          .descendant(of: peopleList.first, matching: find.byType(Scrollable))
          .first,
    );
    await t.tap(f);
    expect(k.addPeople, 1);
  });

  group('Who can hear this?', () {
    Future<void> sheet(WidgetTester t, AudienceInfo a, Calls k) async {
      phone(t, w: 320, h: 568);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => TextButton(
                onPressed: () => showWhoCanHearSheet(
                  c,
                  a,
                  onAddPeople: a.kind == Audience.privateGroup
                      ? () => k.addPeople++
                      : null,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
    }

    testWidgets('private group: an Add people button that closes the sheet '
        'and runs', (t) async {
      final k = Calls();
      await sheet(t, const AudienceInfo(Audience.privateGroup), k);
      final b = find.byKey(const Key('who-add-people'));
      expect(b.hitTestable(), findsOneWidget);
      await t.tap(b);
      await settle(t);
      expect(k.addPeople, 1);
      expect(find.byKey(const Key('who-can-hear-sheet')), findsNothing);
    });

    testWidgets('open channel and direct chat: no Add people', (t) async {
      await sheet(t, const AudienceInfo(Audience.open, channel: 1), Calls());
      expect(find.byKey(const Key('who-add-people')), findsNothing);
    });
  });

  group('status sheet', () {
    testWidgets('has the explanation, the connection and the technical '
        'switch; Add people only in a private group', (t) async {
      phone(t, w: 320, h: 568);
      var tech = false;
      var added = 0;
      Widget body(AudienceInfo a) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (c, set) => StatusSheetBody(
                audience: a,
                onAddPeople: a.kind == Audience.privateGroup
                    ? () => added++
                    : null,
                connection: const SizedBox(key: Key('conn')),
                lines: const ['Home relay 42 ms · 1 backup ready'],
                technical: tech,
                onTechnical: (v) => set(() => tech = v),
              ),
            ),
          ),
        ),
      );
      await t.pumpWidget(body(const AudienceInfo(Audience.privateGroup)));
      expect(find.byKey(const Key('who-can-hear-sheet')), findsOneWidget);
      expect(find.byKey(const Key('conn')), findsOneWidget);
      expect(find.textContaining('Home relay 42 ms'), findsOneWidget);
      expect(find.byKey(const Key('who-add-people')), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('status-technical')));
      await t.tap(find.byKey(const Key('status-technical')));
      await t.pump();
      expect(tech, isTrue);
      await t.pumpWidget(body(const AudienceInfo(Audience.open, channel: 1)));
      expect(find.byKey(const Key('who-add-people')), findsNothing);
    });
  });

  group('Channels list', () {
    ChannelsView view({
      String? current = 'g1',
      Calls? k,
      bool settings = true,
      bool adds = true,
    }) => ChannelsView(
      current: 1,
      currentGroup: current,
      groupRows: const [
        GroupRow('g1', name: 'Family', emoji: '🏕', color: 0xFF2E7D32),
        GroupRow('g2', name: 'Ski club', emoji: '', color: 0xFF1565C0),
      ],
      openRows: const [ChannelRow(1)],
      onPick: (_) {},
      onPickGroup: (_) {},
      onNewGroup: () {},
      onJoinGroup: () {},
      onAddPeople: adds ? (id) => k?.addPeople++ : null,
      onGroupSettings: settings ? () => k?.settings++ : null,
    );

    testWidgets('in a group: Add people and Group settings on top, a '
        'person-add icon per group', (t) async {
      phone(t, w: 320, h: 568);
      final k = Calls();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: view(k: k)),
          ),
        ),
      );
      final add = find.byKey(const Key('channels-add-people'));
      expect(add.hitTestable(), findsOneWidget);
      expect(
        t.getRect(add).top,
        lessThan(t.getRect(find.byKey(const Key('group-row-g1'))).top),
      );
      await t.tap(add);
      await t.tap(find.byKey(const Key('channels-group-settings')));
      await t.tap(find.byKey(const Key('group-add-g2')));
      expect((k.addPeople, k.settings), (2, 1));
      expect(find.byKey(const Key('group-add-g1')), findsOneWidget);
    });

    testWidgets('on an open channel: no group header', (t) async {
      phone(t);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: view(current: null, k: Calls())),
          ),
        ),
      );
      expect(find.byKey(const Key('channels-add-people')), findsNothing);
      expect(find.byKey(const Key('group-add-g2')), findsOneWidget);
    });

    testWidgets('without the new callbacks the sheet looks as before', (
      t,
    ) async {
      phone(t);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: view(settings: false, adds: false),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('channels-add-people')), findsNothing);
      expect(find.byKey(const Key('group-add-g2')), findsNothing);
    });
  });

  test('status line wording', () {
    expect(
      shortNetText(
        'Internet: connected via Wi-Fi (Home relay)',
        TransportStatus.running,
      ),
      'Wi-Fi',
    );
    expect(
      shortNetText(
        'Internet: connected via mobile data',
        TransportStatus.running,
      ),
      'mobile data',
    );
    expect(
      shortNetText('Internet: not connected', TransportStatus.error),
      'no internet',
    );
    expect(
      shortNetText('Internet: connecting…', TransportStatus.starting),
      'connecting…',
    );
    expect(backupText(null), isNull);
    expect(backupText(_summary), 'backup ready');
    expect(
      backupText(
        const ConnectionSummary(
          best: 'Wi-Fi',
          bestRtt: null,
          backups: 0,
          checkEvery: Duration(seconds: 5),
        ),
      ),
      'no backup',
    );
    expect(
      backupText(
        const ConnectionSummary(
          best: 'Wi-Fi',
          bestRtt: null,
          backups: 2,
          checkEvery: Duration(seconds: 5),
        ),
      ),
      '2 backups ready',
    );
    expect(
      backupText(
        const ConnectionSummary(
          best: null,
          bestRtt: null,
          backups: 0,
          checkEvery: Duration(seconds: 5),
        ),
      ),
      'looking for a connection',
    );
    expect(
      compactInternetText('Internet: connected via mobile data (Home relay)'),
      'Internet via mobile data',
    );
  });

  test('talkButtonSize: shrinks on short screens and with large text', () {
    const normal = TextScaler.noScaling;
    final big = TextScaler.linear(1.3);
    expect(talkButtonSize(891, normal), closeTo(151.5, 0.1));
    expect(talkButtonSize(2000, normal), 160);
    expect(talkButtonSize(640, big), lessThan(talkButtonSize(640, normal)));
    expect(talkButtonSize(480, TextScaler.linear(2)), 96);
  });
}
