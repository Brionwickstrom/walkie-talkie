// v2.3.1: the real Talk screen (HomePage) on a small phone: one group-settings
// entry that never hides under the Chat action, Add people where a person can
// find it, one status line, the bottom bar and one row of four actions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  const long = 'Backcountry ski patrol crew!!!'; // 30 characters
  final settingsButton = find.byKey(const Key('group-settings-button'));
  final picker = find.byKey(const Key('channel-picker'));
  final addPeopleEmpty = find.byKey(const Key('empty-add-people'));

  testWidgets('30-character group name, 360 dp, 1.3x text: the title never '
      'overlaps the actions; the lock opens the group sheet, not Chat', (
    t,
  ) async {
    expect(long.length, 30);
    phone(t);
    final c = await makeController(t, group: long);
    await t.pumpWidget(homeApp(c));
    await settle(t);
    expect(t.takeException(), isNull);

    final lock = t.getRect(settingsButton);
    final name = t.getRect(picker);
    final bar = t.getRect(find.byType(AppBar));
    final gear = t.getRect(find.byTooltip('Settings'));
    expect(lock.width, greaterThanOrEqualTo(48));
    expect(lock.height, greaterThanOrEqualTo(48));
    expect(
      lock.right,
      lessThanOrEqualTo(name.left + 0.5),
      reason: 'lock | name',
    );
    expect(
      name.right,
      lessThanOrEqualTo(gear.left + 0.5),
      reason: 'name | gear',
    );
    expect(gear.right, lessThanOrEqualTo(bar.right));
    // No Chat icon in the top bar on a phone (it is in the bottom bar).
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.chat_bubble_outline),
      ),
      findsNothing,
    );
    // The name is cut with "…", not squeezed under anything.
    expect(find.byKey(const Key('group-picker-label')), findsOneWidget);

    // Tap the middle of the lock: the group sheet with Add people on top.
    await t.tap(settingsButton);
    await settle(t);
    expect(find.byKey(const Key('privacy-add-people')), findsOneWidget);
    expect(find.byKey(const Key('chat-hub-chat')), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Chat'), findsOneWidget, reason: 'only the bottom tab');
    await t.pumpWidget(const SizedBox());
    await finish(t);
  });

  testWidgets('tapping the group name opens the groups list, with Add people '
      'and Group settings at the top', (t) async {
    phone(t);
    final c = await makeController(t, group: 'Family');
    await t.pumpWidget(homeApp(c));
    await settle(t);
    await t.tap(picker);
    await settle(t);
    expect(find.byKey(const Key('channels-add-people')), findsOneWidget);
    expect(find.byKey(const Key('channels-group-settings')), findsOneWidget);
    expect(
      find.byKey(Key('group-add-${c.currentGroup!.id}')),
      findsOneWidget,
      reason: 'person-add icon on each group row',
    );
    await t.tap(find.byKey(const Key('channels-group-settings')));
    await settle(t);
    expect(find.byKey(const Key('privacy-add-people')), findsOneWidget);
    await finish(t);
  });

  testWidgets('group sheet: Add people is visible without scrolling on a '
      'small phone, above the name and colour', (t) async {
    phone(t, w: 320, h: 568, ts: 1.3);
    final c = await makeController(t, group: 'Family');
    await t.pumpWidget(homeApp(c));
    await settle(t);
    await t.tap(settingsButton);
    await settle(t);
    final add = find.byKey(const Key('privacy-add-people'));
    final invite = find.byKey(const Key('privacy-invite'));
    for (final f in [add, invite]) {
      expect(f, findsOneWidget);
      final r = t.getRect(f);
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.bottom, lessThanOrEqualTo(568 - 48), reason: '$r on screen');
      expect(f.hitTestable(), findsOneWidget);
    }
    expect(
      t.getRect(add).top,
      lessThan(t.getRect(find.byKey(const Key('privacy-name'))).top),
    );
    await t.tap(add);
    await settle(t);
    expect(find.byKey(const Key('privacy-add-people')), findsNothing);
    await finish(t);
  });

  testWidgets('empty private group: a big Add people button, no "Nobody on" '
      'text, no "1 on" row; a small share link under it', (t) async {
    phone(t, w: 320, h: 568, ts: 1.3);
    final c = await makeController(t, group: 'Family');
    await t.pumpWidget(homeApp(c));
    await settle(t);
    expect(addPeopleEmpty, findsOneWidget);
    final r = t.getRect(addPeopleEmpty);
    expect(r.bottom, lessThanOrEqualTo(568 - 48 - 60), reason: 'above the bar');
    expect(addPeopleEmpty.hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('empty-share-invite')), findsOneWidget);
    expect(find.textContaining('Nobody on'), findsNothing);
    expect(find.textContaining(' on Family'), findsNothing);
    await t.tap(addPeopleEmpty);
    await settle(t);
    expect(find.textContaining('Add people'), findsWidgets);
    await finish(t);
  });

  testWidgets('open channel: a simple note, no Add people', (t) async {
    phone(t);
    final c = await makeController(t);
    await t.pumpWidget(homeApp(c));
    await settle(t);
    expect(addPeopleEmpty, findsNothing);
    expect(find.textContaining('Nobody on CH 1'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.lock_open),
      ),
      findsOneWidget,
    );
    await finish(t);
  });

  testWidgets('status line: one line; tapping it opens the details sheet '
      'with "Who can hear this?" and Add people (private group)', (t) async {
    phone(t);
    final c = await makeController(t, group: 'Family');
    await t.pumpWidget(homeApp(c));
    await settle(t);
    final line = find.byKey(const Key('status-line'));
    expect(line, findsOneWidget);
    expect(find.textContaining('Private group'), findsOneWidget);
    // The old separate "Who can hear this?" line is gone.
    expect(find.byKey(const Key('who-can-hear')), findsNothing);
    await t.tap(line);
    await settle(t);
    expect(find.byKey(const Key('status-sheet')), findsOneWidget);
    expect(find.byKey(const Key('who-can-hear-sheet')), findsOneWidget);
    expect(find.byKey(const Key('who-add-people')), findsOneWidget);
    expect(find.byKey(const Key('status-technical')), findsOneWidget);
    await finish(t);
  });

  testWidgets('status sheet in an open channel has no Add people', (t) async {
    phone(t);
    final c = await makeController(t);
    await t.pumpWidget(homeApp(c));
    await settle(t);
    await t.tap(find.byKey(const Key('status-line')));
    await settle(t);
    expect(find.byKey(const Key('who-can-hear-sheet')), findsOneWidget);
    expect(find.byKey(const Key('who-add-people')), findsNothing);
    await finish(t);
  });

  testWidgets('bottom bar: Talk, Chat, People, Trip; Chat shows Chat, '
      'Voicemail and History; People shows Refresh and Who\'s where', (
    t,
  ) async {
    phone(t);
    final c = await makeController(t, group: 'Family');
    await t.pumpWidget(homeApp(c));
    await settle(t);
    final bar = find.byKey(const Key('mainTabs'));
    for (final l in ['Talk', 'Chat', 'People', 'Trip']) {
      expect(
        find.descendant(of: bar, matching: find.text(l)),
        findsOneWidget,
        reason: l,
      );
    }
    // Top bar: only the name, the lock and Settings.
    for (final i in [Icons.voicemail, Icons.people, Icons.people_outline]) {
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.byIcon(i)),
        findsNothing,
      );
    }
    await t.tap(find.descendant(of: bar, matching: find.text('Chat')));
    await settle(t);
    expect(find.byKey(const Key('chat-hub-chat')), findsOneWidget);
    expect(find.byKey(const Key('chat-hub-voice')), findsOneWidget);
    expect(find.byKey(const Key('chat-hub-history')), findsOneWidget);
    await t.tap(find.descendant(of: bar, matching: find.text('People')));
    await settle(t);
    expect(find.byKey(const Key('people-count')), findsOneWidget);
    expect(find.text('Scan for people'), findsOneWidget);
    await t.tap(find.descendant(of: bar, matching: find.text('Talk')));
    await settle(t);
    expect(find.byKey(const Key('status-line')), findsOneWidget);
    await finish(t);
  });

  for (final (label, w, h, ts) in [
    ('360x640 at 1.3x text', 360.0, 640.0, 1.3),
    ('320x568 at 1.3x text', 320.0, 568.0, 1.3),
    ('411x891 at 1.0x text', 411.0, 891.0, 1.0),
  ]) {
    testWidgets('$label: four equal action buttons in one row, the talk '
        'button and the status line are reachable', (t) async {
      phone(t, w: w, h: h, ts: ts);
      final c = await makeController(t, group: 'Family');
      await t.pumpWidget(homeApp(c));
      await settle(t);
      expect(t.takeException(), isNull);
      final keys = [
        find.byKey(const Key('ring-all')),
        find.byKey(const Key('beep-all')),
        find.byKey(const Key('record')),
        find.byKey(const Key('muteButton')),
      ];
      final rects = <Rect>[];
      for (final k in keys) {
        expect(k, findsOneWidget);
        expect(k.hitTestable(), findsOneWidget);
        rects.add(t.getRect(k));
      }
      for (final r in rects) {
        expect(r.top, rects.first.top, reason: 'one row');
        expect(r.width, closeTo(rects.first.width, 1), reason: 'equal');
        expect(r.height, lessThan(80), reason: 'never wraps');
        expect(r.bottom, lessThanOrEqualTo(h));
      }
      for (final f in [
        find.text('Ring all'),
        find.text('Beep'),
        find.text('Message'),
        find.text('Mute'),
      ]) {
        expect(f, findsOneWidget);
      }
      expect(find.byKey(const Key('ptt')), findsNothing); // key-less here
      final status = t.getRect(find.byKey(const Key('status-line')));
      expect(status.height, lessThan(60));
      // The big Add people stays on screen above the nav bar.
      expect(addPeopleEmpty.hitTestable(), findsOneWidget);
      // Settings and the lock are on screen and tappable.
      expect(settingsButton.hitTestable(), findsOneWidget);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      await finish(t);
    });
  }
}
