// v2.3.2: the Chat and People tabs say who each thing reaches: an open
// channel (anyone on the number), a private group (only its people) or a
// direct chat (only you two), with the same icon, colour and words everywhere.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/ui/chat_hub.dart';
import 'package:walkie_talkie/ui/friends_page.dart';
import 'package:walkie_talkie/ui/home_view.dart' show PersonView;
import 'package:walkie_talkie/ui/messages_page.dart';
import 'package:walkie_talkie/ui/people_tab.dart';
import 'package:walkie_talkie/ui/reach.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v231_helpers.dart';

Finder nav(String label) => find.descendant(
  of: find.byKey(const Key('mainTabs')),
  matching: find.text(label),
);

Future<void> goTab(WidgetTester t, String label) async {
  await t.tap(nav(label));
  await settle(t);
}

/// Scroll the tab's list until [f] is built, then fully on screen.
Future<void> reveal(WidgetTester t, Finder f, {bool first = false}) async {
  final sc = find.byType(Scrollable);
  await t.scrollUntilVisible(
    f,
    80,
    scrollable: first ? sc.first : sc.last,
    maxScrolls: 200,
  );
  await t.ensureVisible(f);
  await t.pump();
}

/// Every [ReachTag] text on screen.
List<String> tags(WidgetTester t) => [
  for (final r in t.widgetList<ReachTag>(find.byType(ReachTag)))
    r.text ?? r.reach.tag,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('Reach wording', () {
    test('open channel', () {
      final r = Reach.open(1);
      expect(r.tag, 'Open channel · CH 1');
      expect(r.header, 'CH 1 · open');
      expect(r.reads, 'Anyone on CH 1 can read this');
      expect(r.icon, Icons.lock_open);
      expect(
        Reach.open(1, name: 'General Room').header,
        'General Room · CH 1 · open',
      );
    });
    test('private group', () {
      final r = Reach.group('privates club', color: 0xFF2E7D32);
      expect(r.tag, 'Private group · privates club');
      expect(r.header, 'privates club · private');
      expect(r.reads, 'Only people in privates club');
      expect(r.icon, Icons.lock);
      expect(r.color, const Color(0xFF2E7D32));
    });
    test('direct', () {
      final r = Reach.direct('Ann');
      expect(r.tag, 'Direct · Ann · only you two');
      expect(r.reads, 'Only you two');
      expect(r.icon, Icons.person);
    });
    test('the three look different', () {
      final all = [Reach.open(1), Reach.group('g'), Reach.direct('a')];
      expect({for (final r in all) r.icon}.length, 3);
      expect({for (final r in all) r.color}.length, 3);
    });
  });

  group('Chat tab (real screen)', () {
    for (final (label, w, h, ts) in [
      ('360x640 at 1.3x', 360.0, 640.0, 1.3),
      ('320x568 at 1.3x', 320.0, 568.0, 1.3),
    ]) {
      testWidgets('$label, open channel: banner once, "CH 1 chat" first, '
          'Friends below, text only', (t) async {
        phone(t, w: w, h: h, ts: ts);
        final c = await makeController(
          t,
          friends: [testFriend(0x2222, 'Ann'), testFriend(0x3333, 'Bob')],
        );
        await t.pumpWidget(homeApp(c));
        await settle(t);
        await goTab(t, 'Chat');
        expect(t.takeException(), isNull);
        expect(
          t.widget<Text>(find.byKey(const Key('place-header-text'))).data,
          'CH 1 · open',
        );
        expect(find.text('Here (CH 1)'), findsNothing);
        expect(find.text('Anyone on CH 1 can read this'), findsNothing);
        expect(tags(t), isEmpty, reason: 'no per-row tags on the Chat tab');
        // The channel chat is the first row, Friends come after it.
        final chat = t.getRect(find.byKey(const Key('chat-hub-chat')));
        expect(find.text('CH 1 chat'), findsOneWidget);
        await reveal(t, find.byKey(const Key('direct-chat-${0x3333}')));
        expect(find.text('Friends'), findsOneWidget);
        expect(find.text('Direct chats'), findsNothing);
        expect(find.text('Direct · Ann · only you two'), findsNothing);
        expect(find.text('No messages yet'), findsNWidgets(3));
        expect(chat.top, lessThan(t.getRect(find.text('Friends')).top));
        // Audio is not on this tab any more.
        for (final k in [
          'chat-hub-voice',
          'chat-hub-history',
          'chat-hub-direct-voice',
        ]) {
          expect(find.byKey(Key(k)), findsNothing, reason: k);
        }
        expect(find.text('Voice messages from friends'), findsNothing);
        await finish(t);
      });
    }

    testWidgets('no friends: an empty state that leads to People', (t) async {
      phone(t);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      await goTab(t, 'Chat');
      await reveal(t, find.byKey(const Key('direct-add-friends')));
      expect(find.textContaining('No friends yet'), findsOneWidget);
      await t.tap(find.byKey(const Key('direct-add-friends')));
      await settle(t);
      expect(find.byKey(const Key('people-section-friends')), findsOneWidget);
      await finish(t);
    });
  });

  group('People tab (real screen)', () {
    for (final (label, w, h, ts) in [
      ('360x640 at 1.3x', 360.0, 640.0, 1.3),
      ('320x568 at 1.3x', 320.0, 568.0, 1.3),
    ]) {
      testWidgets('$label: "On CH 1 now" is the channel, "Friends (direct '
          'chats)" is separate; no friend list under a channel count', (
        t,
      ) async {
        phone(t, w: w, h: h, ts: ts);
        final c = await makeController(
          t,
          friends: [testFriend(0x2222, 'Ann'), testFriend(0x3333, 'Bob')],
        );
        await t.pumpWidget(homeApp(c));
        await settle(t);
        await goTab(t, 'People');
        expect(t.takeException(), isNull);
        expect(
          t.widget<Text>(find.byKey(const Key('place-header-text'))).data,
          'CH 1 · open',
        );
        // Section 1: who is on the channel (just you), with the tools.
        expect(find.text('On CH 1 now (1)'), findsOneWidget);
        expect(find.byKey(const Key('people-here-${0x1234}')), findsOneWidget);
        expect(find.byKey(const Key('people-here-empty')), findsOneWidget);
        expect(find.byKey(const Key('people-refresh')), findsOneWidget);
        expect(find.text('Scan for people'), findsOneWidget);
        // The friends are not in the channel section.
        expect(find.byKey(const Key('people-here-${0x2222}')), findsNothing);
        // Section 2 comes after, with the friends.
        final count = t.getRect(find.byKey(const Key('people-count')));
        final friendsTitle = t.getRect(
          find.byKey(const Key('people-section-friends')),
        );
        expect(friendsTitle.top, greaterThan(count.bottom));
        expect(find.text('Friends (direct chats)'), findsOneWidget);
        // Everything between the channel count and the friends title is
        // the channel's own people, never a friend.
        for (final id in [0x2222, 0x3333]) {
          final row = find.widgetWithText(
            ListTile,
            id == 0x2222 ? 'Ann' : 'Bob',
          );
          await t.scrollUntilVisible(
            row,
            100,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            t.getRect(row).top,
            greaterThan(
              t
                      .getRect(find.byKey(const Key('people-section-friends')))
                      .bottom -
                  1,
            ),
            reason: 'friend $id is listed under the friends title',
          );
        }
        expect(find.text('Direct · Ann · only you two'), findsOneWidget);
        expect(find.text('Add friends'), findsOneWidget);
        expect(find.text('Show my code'), findsOneWidget);
        expect(find.text('Scan a code'), findsOneWidget);
        await finish(t);
      });
    }

    testWidgets('private group: "On privates club now", Add people', (t) async {
      phone(t);
      final c = await makeController(t, group: 'privates club');
      await t.pumpWidget(homeApp(c));
      await settle(t);
      await goTab(t, 'People');
      expect(find.text('On privates club now (1)'), findsOneWidget);
      expect(find.text('privates club · private'), findsOneWidget);
      expect(
        tags(t).where((x) => x == 'Private group · privates club').length,
        1,
      );
      await t.tap(find.byKey(const Key('people-add-people')));
      await settle(t);
      expect(find.text('Add people'), findsWidgets);
      await finish(t);
    });
  });

  testWidgets('wide layout: Chat and People icons open the same sections', (
    t,
  ) async {
    phone(t, w: 1100, h: 700, ts: 1.0);
    final c = await makeController(t, friends: [testFriend(0x2222, 'Ann')]);
    await t.pumpWidget(homeApp(c));
    await settle(t);
    expect(find.byKey(const Key('mainTabs')), findsNothing);
    await t.tap(find.byTooltip('Chat'));
    await settle(t);
    expect(find.text('CH 1 chat'), findsOneWidget);
    expect(find.text('Friends'), findsOneWidget);
    await t.pageBack();
    await settle(t);
    await t.tap(find.byTooltip('People'));
    await settle(t);
    expect(find.text('On CH 1 now (1)'), findsOneWidget);
    expect(find.text('Friends (direct chats)'), findsOneWidget);
    await t.pageBack();
    await settle(t);
    await finish(t);
  });

  testWidgets('Messages: filter chips say Here / Direct / All, the lock '
      'stays when Here is selected', (t) async {
    phone(t);
    final c = await makeController(t, group: 'privates club');
    await t.pumpWidget(
      MaterialApp(
        home: MessagesPage(controller: c, initial: MessagesFilter.here),
      ),
    );
    await settle(t);
    expect(find.text('Here · privates club'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    final here = find.byKey(const Key('messages-filter-here'));
    expect(t.widget<ChoiceChip>(here).selected, isTrue);
    expect(t.widget<ChoiceChip>(here).showCheckmark, isFalse);
    expect(
      find.descendant(of: here, matching: find.byIcon(Icons.lock)),
      findsOneWidget,
    );
    await t.tap(find.byKey(const Key('messages-filter-direct')));
    await t.pump();
    expect(
      t
          .widget<ChoiceChip>(find.byKey(const Key('messages-filter-direct')))
          .selected,
      isTrue,
    );
    await finish(t);
  });

  group('pure views', () {
    testWidgets('Chat tab data: previews, unread badges, direct rows', (
      t,
    ) async {
      phone(t, w: 320, h: 568);
      var chat = 0;
      DirectChatItem? opened;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatHubView(
              place: Reach.open(1, name: 'General Room'),
              chatPreview: 'Yo yo yo',
              chatUnread: 3,
              onOpenChat: () => chat++,
              direct: const [
                DirectChatItem(
                  id: 1,
                  name: 'Ann',
                  online: true,
                  last: 'see you at 5',
                  unread: 2,
                ),
                DirectChatItem(id: 2, name: 'Bob', online: false),
              ],
              onOpenDirect: (d) => opened = d,
              onAddFriends: () {},
            ),
          ),
        ),
      );
      expect(find.text('General Room · CH 1 · open'), findsOneWidget);
      expect(find.text('Yo yo yo'), findsOneWidget);
      expect(find.text('CH 1 chat'), findsOneWidget);
      await t.tap(find.byKey(const Key('chat-hub-chat')));
      expect(chat, 1);
      await reveal(t, find.text('see you at 5'), first: true);
      expect(find.text('see you at 5'), findsOneWidget);
      expect(find.byKey(const Key('direct-empty')), findsNothing);
      await reveal(t, find.byKey(const Key('direct-chat-1')), first: true);
      await t.tap(find.byKey(const Key('direct-chat-1')));
      expect(opened?.name, 'Ann');
      await reveal(t, find.text('No messages yet'), first: true);
      expect(find.text('No messages yet'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('direct-chat-1')),
          matching: find.byType(Badge),
        ),
        findsOneWidget,
      );
    });

    testWidgets('People tab data: present people vs friends', (t) async {
      phone(t);
      PersonView? tapped;
      FriendItem? opened;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PeopleTabView(
              place: Reach.group('privates club'),
              here: const [
                PersonView(id: 1, name: 'Me', me: true),
                PersonView(
                  id: 2,
                  name: 'Pat',
                  lastHeard: Duration(seconds: 30),
                ),
                PersonView(id: 3, name: 'Quinn', talking: true),
              ],
              whosWhereCount: 2,
              onWhosWhere: () {},
              friends: const [
                FriendItem(id: 7, name: 'Ann', online: true),
                FriendItem(id: 8, name: 'Bob', online: false),
              ],
              onOpenFriend: (f) => opened = f,
              onOpenPerson: (p) => tapped = p,
              onShowCode: () {},
              onScan: () {},
            ),
          ),
        ),
      );
      expect(find.text('On privates club now (3)'), findsOneWidget);
      expect(find.text('Me (you)'), findsOneWidget);
      expect(find.text('Heard 30s ago'), findsOneWidget);
      expect(find.text('Talking now'), findsOneWidget);
      expect(find.byKey(const Key('people-here-empty')), findsNothing);
      await t.tap(find.byKey(const Key('people-here-2')));
      expect(tapped?.name, 'Pat');
      await reveal(t, find.text('Ann'), first: true);
      await t.tap(find.text('Ann'));
      expect(opened?.name, 'Ann');
      // Group people are tagged with the group, friends as direct.
      expect(tags(t), contains('Private group · privates club'));
      expect(tags(t), contains('Direct · Ann · only you two'));
    });
  });
}
