// v2.3.0: the private-group screens on a small phone with large text: the
// channel picker (Private groups above Open channels), invitations from
// friends, and the "Add people" sheet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/ui/channels_sheet.dart';
import 'package:walkie_talkie/ui/sheets.dart';

import 'home_layout_test.dart' show loadFonts;

void phone(WidgetTester t) {
  t.view.physicalSize = const Size(360, 640) * 3;
  t.view.devicePixelRatio = 3;
  t.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
  t.view.viewPadding = const FakeViewPadding(top: 24 * 3, bottom: 48 * 3);
  t.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
}

Widget sheetHost(Widget Function(BuildContext) body) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => showAppSheet<void>(
            context: context,
            builder: (ctx) =>
                Padding(padding: const EdgeInsets.all(16), child: body(ctx)),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(loadFonts);

  testWidgets('channel picker: groups first, an invitation can be joined or '
      'declined, old groups say older phones can join', (t) async {
    phone(t);
    final log = <String>[];
    await t.pumpWidget(
      sheetHost(
        (ctx) => ChannelsView(
          current: 1,
          currentGroup: 'ch3',
          groupRows: const [
            GroupRow('a1', name: 'Family', emoji: '🏕'),
            GroupRow('ch3', name: 'CH 3 group', legacy: true),
            GroupRow('b2', name: 'Hikers', invited: true, invitedBy: 'Bandit'),
          ],
          openRows: [for (var i = 1; i <= 16; i++) ChannelRow(i)],
          onPick: (c) => log.add('ch$c'),
          onPickGroup: (id) => log.add('g:$id'),
          onNewGroup: () => log.add('new'),
          onJoinGroup: () => log.add('join'),
          onAcceptInvite: (id) => log.add('accept:$id'),
          onDeclineInvite: (id) => log.add('decline:$id'),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(t.takeException(), isNull);
    expect(find.text('Private groups'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Older phones can join too'), findsOneWidget);
    expect(find.byKey(const Key('group-invited-b2')), findsOneWidget);
    expect(find.text('Invitation from Bandit'), findsOneWidget);
    // A group row never shows a channel number.
    expect(
      find.descendant(
        of: find.byKey(const Key('group-row-a1')),
        matching: find.textContaining('CH '),
      ),
      findsNothing,
    );
    await t.tap(find.byKey(const Key('group-accept-b2')));
    await t.tap(find.byKey(const Key('group-decline-b2')));
    await t.tap(find.byKey(const Key('group-row-a1')));
    await t.tap(find.byKey(const Key('new-private-group')));
    await t.tap(find.byKey(const Key('join-private-group')));
    expect(log, ['accept:b2', 'decline:b2', 'g:a1', 'new', 'join']);
    // Open channels are listed below the groups.
    final g = t.getTopLeft(find.byKey(const Key('group-row-a1'))).dy;
    await t.ensureVisible(find.byKey(const Key('channel-row-16')));
    expect(find.byKey(const Key('open-channels-title')), findsOneWidget);
    expect(
      g,
      lessThan(t.getTopLeft(find.byKey(const Key('channel-row-16'))).dy),
    );
  });

  testWidgets('add people: pick friends, Send needs a pick, QR/link is the '
      'way for non-friends', (t) async {
    phone(t);
    final picked = <int>{};
    var sent = 0, qr = 0;
    Widget view() => MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, set) => SingleChildScrollView(
            child: AddPeopleView(
              groupLabel: '🏕 Family',
              friends: const [
                (id: 1, name: 'Bandit', online: true),
                (
                  id: 2,
                  name: 'A friend with a really long call sign here',
                  online: false,
                ),
              ],
              picked: picked,
              onToggle: (id, on) => set(() {
                on ? picked.add(id) : picked.remove(id);
              }),
              onSend: () => sent++,
              onQr: () => qr++,
              theme: Theme.of(context),
            ),
          ),
        ),
      ),
    );
    await t.pumpWidget(view());
    expect(t.takeException(), isNull);
    expect(find.text('Add people to 🏕 Family'), findsOneWidget);
    expect(find.textContaining('2.3.0 or newer'), findsOneWidget);
    expect(find.text('In reach'), findsOneWidget);
    expect(find.text('Out of reach for now'), findsOneWidget);
    FilledButton send() =>
        t.widget<FilledButton>(find.byKey(const Key('add-people-send')));
    expect(send().onPressed, isNull, reason: 'nobody picked yet');
    await t.tap(find.byKey(const Key('add-people-1')));
    await t.pump();
    await t.tap(find.byKey(const Key('add-people-2')));
    await t.pump();
    expect(find.text('Send (2)'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('add-people-send')));
    await t.tap(find.byKey(const Key('add-people-send')));
    await t.ensureVisible(find.byKey(const Key('add-people-qr')));
    await t.tap(find.byKey(const Key('add-people-qr')));
    expect((sent, qr), (1, 1));
  });

  testWidgets('add people with no friends explains and offers QR / link', (
    t,
  ) async {
    phone(t);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Builder(
              builder: (context) => AddPeopleView(
                groupLabel: 'Family',
                friends: const [],
                picked: const {},
                onToggle: (_, _) {},
                onSend: () {},
                onQr: () {},
                theme: Theme.of(context),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('no friends added yet'), findsOneWidget);
    expect(find.byKey(const Key('add-people-qr')), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('colour picker: eight colours, one checked', (t) async {
    phone(t);
    var picked = -1;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupColorPicker(
            value: 0xFF43A047,
            onChanged: (c) => picked = c,
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      expect(find.byKey(Key('group-color-$i')), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
    await t.tap(find.byKey(const Key('group-color-3')));
    expect(picked, 0xFF8E24AA);
  });
}
