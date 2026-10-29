import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/chat/chat_store.dart';
import 'package:walkie_talkie/history/talk_history.dart';
import 'package:walkie_talkie/messaging/inbox.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/outbox.dart';
import 'package:walkie_talkie/messaging/sent_log.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';
import 'package:walkie_talkie/ui/chat_view.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/messages_page.dart';
import 'package:walkie_talkie/ui/reach.dart';
import 'package:walkie_talkie/ui/status_line.dart';
import 'package:walkie_talkie/ui/who_can_hear.dart';
import 'package:walkie_talkie/core/transport.dart';

import 'home_layout_test.dart' show loadFonts;
import 'messaging_fakes.dart';
import 'v231_helpers.dart';

Uint8List pkt(int i) => Uint8List.fromList([i & 0xFF, 1, 2, 3, 4, 5, 6, 7, 8]);

Uint8List clipBody([int packets = 50]) =>
    VoiceClip([for (var i = 0; i < packets; i++) pkt(i)]).encode();

InboxEntry entry(
  int sender,
  int id, {
  String name = 'Pat',
  int channel = 1,
  bool channelMessage = true,
  bool played = false,
  Duration ago = const Duration(minutes: 5),
}) => InboxEntry(
  sender: sender,
  msgId: id,
  senderName: name,
  channel: channel,
  channelMessage: channelMessage,
  receivedAt: DateTime.now().subtract(ago),
  durationMs: 7000,
  played: played,
);

/// A controller with a (not started) channel messenger and friend
/// messenger, so the inbox / sent lists can be filled directly.
Future<(Messenger, Messenger)> withMessengers(
  WidgetTester t,
  WalkieController c,
) async {
  final net = FakeNet();
  final a = Messenger(link: net.add(0x1234), storage: MemoryMessageStorage());
  final b = Messenger(link: net.add(0x1235), storage: MemoryMessageStorage());
  c.messenger = a;
  c.friendMessenger = b;
  addTearDown(() async {
    await a.dispose();
    await b.dispose();
  });
  return (a, b);
}

Future<TalkHistory> withHistory(WidgetTester t, WalkieController c) async {
  final h = TalkHistory(storage: MemoryMessageStorage());
  await t.runAsync(h.load);
  c.history = h;
  return h;
}

void take(TalkHistory h, int scope, int sender, String name) {
  for (var i = 0; i < 30; i++) {
    h.addPacket(scope: scope, sender: sender, name: name, opus: pkt(i));
  }
  h.endTake(sender);
}

TakeView tv(int id, {bool heard = true, String name = 'Pat'}) => TakeView(
  id: id,
  sender: 7,
  name: name,
  at: DateTime(2026, 10, 25, 14, id),
  durationMs: 3000,
  heard: heard,
);

Widget view({
  MessagesFilter filter = MessagesFilter.here,
  ValueChanged<MessagesFilter>? onFilter,
  Map<MessagesFilter, int> unheard = const {},
  List<WaitingRow> waiting = const [],
  List<SentRow> sent = const [],
  bool allSent = false,
  List<TakeRow> takes = const [],
  List<VoiceRow> voice = const [],
  int unheardTakes = 0,
  String? focusKey,
  ValueChanged<double>? onSpeed,
  VoidCallback? onPlayMissed,
  VoidCallback? onMarkAllHeard,
  VoidCallback? onClearTalk,
  VoidCallback? onAllSent,
}) => MaterialApp(
  home: MessagesView(
    filter: filter,
    onFilter: onFilter ?? (_) {},
    place: Reach.open(1),
    chips: const [
      (MessagesFilter.here, 'Here · CH 1', Icons.lock_open),
      (MessagesFilter.direct, 'Direct', Icons.person),
      (MessagesFilter.all, 'All', Icons.all_inbox),
    ],
    unheard: unheard,
    waiting: waiting,
    sent: sent,
    allSent: allSent,
    onAllSent: onAllSent,
    takes: takes,
    voice: voice,
    speed: 1,
    playingAll: false,
    unheardTakes: unheardTakes,
    onSpeed: onSpeed ?? (_) {},
    onPlayMissed: onPlayMissed ?? () {},
    onMarkAllHeard: onMarkAllHeard ?? () {},
    onClearTalk: onClearTalk ?? () {},
    focusKey: focusKey,
  ),
);

VoiceRow vrow(
  int i, {
  bool played = false,
  Reach? tag,
  VoidCallback? onPlay,
  VoidCallback? onDelete,
}) => VoiceRow(
  key: 'k$i',
  sender: 5,
  who: 'Ann',
  when: '5 min ago',
  durationMs: 7000,
  played: played,
  playing: false,
  tag: tag,
  onPlay: onPlay ?? () {},
  onDelete: onDelete ?? () {},
);

Future<void> openStatusLine(WidgetTester t, {required bool dot}) async {
  var taps = 0;
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TalkStatusLine(
          audience: const AudienceInfo(Audience.open, channel: 1),
          here: 3,
          netStatus: TransportStatus.running,
          netText: 'Internet via Wi-Fi',
          onOpen: () {},
          onOpenMessages: () => taps++,
          messagesNew: dot,
        ),
      ),
    ),
  );
  if (!dot) expect(taps, 0);
}

/// Badges on the bottom bar that actually show something.
int visibleBadges(WidgetTester t) => t
    .widgetList<Badge>(
      find.descendant(
        of: find.byKey(const Key('mainTabs')),
        matching: find.byType(Badge),
      ),
    )
    .where((b) => b.isLabelVisible)
    .length;

Finder nav(String label) => find.descendant(
  of: find.byKey(const Key('mainTabs')),
  matching: find.text(label),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);

  group('Talk status line: one Messages icon', () {
    testWidgets('one icon, one dot only when audio is unheard', (t) async {
      await openStatusLine(t, dot: false);
      expect(find.byKey(const Key('talk-messages-shortcut')), findsOneWidget);
      expect(find.byTooltip('Messages'), findsOneWidget);
      expect(find.byKey(const Key('shortcut-dot')), findsNothing);
      expect(find.byKey(const Key('talk-voice-shortcut')), findsNothing);
      expect(find.byKey(const Key('talk-history-shortcut')), findsNothing);
      await openStatusLine(t, dot: true);
      expect(find.byKey(const Key('shortcut-dot')), findsOneWidget);
      expect(find.byType(Badge), findsOneWidget);
      expect(
        t.getSize(find.byKey(const Key('talk-messages-shortcut'))).width,
        lessThanOrEqualTo(40),
      );
    });
  });

  group('Messages screen', () {
    testWidgets('empty: one line, no empty section headers', (t) async {
      phone(t);
      await t.pumpWidget(view());
      expect(find.byKey(const Key('messages-empty')), findsOneWidget);
      expect(find.text('Waiting to send'), findsNothing);
      expect(find.text('Voice messages'), findsNothing);
      expect(find.text('Live talk'), findsNothing);
      expect(find.text('Sent'), findsNothing);
      expect(find.textContaining('Hold: message'), findsNothing);
      expect(find.textContaining('Hold Message'), findsOneWidget);
      // Here has no direct-talk note; Direct and All do.
      expect(find.byKey(const Key('messages-direct-note')), findsNothing);
      await t.pumpWidget(view(filter: MessagesFilter.direct));
      expect(find.byKey(const Key('messages-direct-note')), findsOneWidget);
      expect(
        find.textContaining('Live talk in a direct chat is not recorded'),
        findsOneWidget,
      );
      expect(find.text('No voice messages from friends yet.'), findsOneWidget);
      await t.pumpWidget(view(filter: MessagesFilter.all));
      expect(find.byKey(const Key('messages-direct-note')), findsOneWidget);
    });

    testWidgets('filters, with the unheard count on the chip and the lock '
        'icon kept', (t) async {
      phone(t);
      MessagesFilter? picked;
      await t.pumpWidget(
        view(
          unheard: const {
            MessagesFilter.here: 0,
            MessagesFilter.direct: 2,
            MessagesFilter.all: 3,
          },
          onFilter: (f) => picked = f,
        ),
      );
      expect(find.text('Here · CH 1'), findsOneWidget);
      expect(find.text('Direct (2)'), findsOneWidget);
      expect(find.text('All (3)'), findsOneWidget);
      final here = find.byKey(const Key('messages-filter-here'));
      expect(t.widget<ChoiceChip>(here).selected, isTrue);
      expect(
        find.descendant(of: here, matching: find.byIcon(Icons.lock_open)),
        findsOneWidget,
        reason: 'the lock stays on the selected chip',
      );
      await t.tap(find.byKey(const Key('messages-filter-all')));
      expect(picked, MessagesFilter.all);
    });

    testWidgets('live talk: speed, Play all missed, mark all heard, clear, '
        'swipe to delete', (t) async {
      phone(t);
      final speeds = <double>[];
      var played = 0, heard = 0, cleared = 0, deleted = 0, tapped = 0;
      await t.pumpWidget(
        view(
          takes: [
            TakeRow(
              take: tv(1, heard: false),
              onPlay: () => tapped++,
              onDelete: () => deleted++,
            ),
            TakeRow(take: tv(2), onPlay: () {}, onDelete: () {}),
          ],
          unheardTakes: 1,
          onSpeed: speeds.add,
          onPlayMissed: () => played++,
          onMarkAllHeard: () => heard++,
          onClearTalk: () => cleared++,
        ),
      );
      expect(find.text('Live talk'), findsOneWidget);
      expect(find.text('1x'), findsOneWidget);
      await t.tap(find.text('2x'));
      expect(speeds, [2.0]);
      expect(find.text('Play all missed (1)'), findsOneWidget);
      await t.tap(find.byKey(const Key('messages-play-missed')));
      expect(played, 1);
      expect(find.textContaining('not heard'), findsOneWidget);
      await t.tap(find.text('Pat').first);
      expect(tapped, 1);
      await t.tap(find.byKey(const Key('messages-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Mark all as heard'));
      await t.pumpAndSettle();
      expect(heard, 1);
      await t.tap(find.byKey(const Key('messages-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Clear live talk history'));
      await t.pumpAndSettle();
      expect(cleared, 1);
      await t.fling(find.text('Pat').first, const Offset(-600, 0), 1500);
      await t.pumpAndSettle();
      expect(deleted, 1);
    });

    testWidgets('direct filter has no live talk section (not recorded)', (
      t,
    ) async {
      phone(t);
      await t.pumpWidget(view(filter: MessagesFilter.direct, voice: [vrow(1)]));
      expect(find.text('Live talk'), findsNothing);
      expect(find.text('Voice messages'), findsOneWidget);
      await t.tap(find.byKey(const Key('messages-menu')));
      await t.pumpAndSettle();
      expect(find.text('Clear live talk history'), findsNothing);
      expect(find.text('Mark all as heard'), findsOneWidget);
    });

    testWidgets('voice messages: play, delete, new marker; the place tag '
        'only where places are mixed (All)', (t) async {
      phone(t);
      var play = 0, del = 0;
      await t.pumpWidget(
        view(
          voice: [
            vrow(1, onPlay: () => play++, onDelete: () => del++),
            vrow(2, played: true),
          ],
        ),
      );
      expect(find.byType(ReachTag), findsNothing);
      expect(find.textContaining('new'), findsOneWidget);
      await t.tap(find.byTooltip('Play').first);
      expect(play, 1);
      await t.tap(find.byTooltip('Delete').first);
      expect(del, 1);
      await t.pumpWidget(
        view(
          filter: MessagesFilter.all,
          voice: [vrow(1, tag: Reach.open(4))],
        ),
      );
      expect(find.byType(ReachTag), findsOneWidget);
      expect(find.text('Open channel · CH 4'), findsOneWidget);
    });

    testWidgets('waiting to send and sent (small status)', (t) async {
      phone(t);
      var cancelled = 0, forgot = 0, all = 0;
      SentRow sentRow(int i, {bool heard = false}) => SentRow(
        id: '$i',
        title: 'To Ann · 0:07',
        status: heard ? 'Listened' : 'Delivered',
        when: 'just now',
        heard: heard,
        onForget: () => forgot++,
      );
      await t.pumpWidget(
        view(
          waiting: [
            WaitingRow(
              id: '1',
              icon: Icons.schedule,
              title: 'To Bob - 0:05',
              subtitle: 'Will send when they are in range',
              onCancel: () => cancelled++,
            ),
          ],
          sent: [for (var i = 0; i < 5; i++) sentRow(i, heard: i == 0)],
          onAllSent: () => all++,
        ),
      );
      expect(find.text('Waiting to send'), findsOneWidget);
      await t.tap(find.byTooltip('Cancel'));
      expect(cancelled, 1);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.textContaining('Listened'), findsOneWidget);
      expect(find.textContaining('Delivered'), findsNWidgets(2));
      expect(find.byKey(const Key('sent-show-all')), findsOneWidget);
      await t.tap(find.byKey(const Key('sent-show-all')));
      expect(all, 1);
      await t.pumpWidget(
        view(sent: [for (var i = 0; i < 5; i++) sentRow(i)], allSent: true),
      );
      expect(find.textContaining('Delivered'), findsNWidgets(5));
      await t.tap(find.byTooltip('Remove from Sent').first);
      expect(forgot, 1);
    });

    testWidgets('scrolls to and highlights the voice message it was opened '
        'for', (t) async {
      phone(t, h: 640, ts: 1.0);
      await t.pumpWidget(
        view(voice: [for (var i = 0; i < 40; i++) vrow(i)], focusKey: 'k33'),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final f = find.byKey(const Key('voice-k33'));
      expect(f, findsOneWidget);
      final r = t.getRect(f);
      final screen = t.getSize(find.byType(MaterialApp));
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.bottom, lessThanOrEqualTo(screen.height));
      // Without a focus key it stays at the top.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(view(voice: [for (var i = 0; i < 40; i++) vrow(i)]));
      await t.pump();
      expect(find.byKey(const Key('voice-k33')), findsNothing);
      expect(find.byKey(const Key('voice-k0')), findsOneWidget);
    });
  });

  group('SentLog', () {
    test(
      'records deliveries (one per message), listens, expires, caps',
      () async {
        final st = MemoryMessageStorage();
        final log = SentLog(st, maxEntries: 3);
        final now = DateTime(2026, 10, 29, 9);
        Future<void> d(int id, int peer, {DateTime? at}) => log.delivered(
          msgId: id,
          toPeer: null,
          channel: 1,
          createdAt: now,
          durationMs: 5000,
          peer: peer,
          now: at ?? now,
        );
        await d(1, 10);
        await d(1, 11);
        expect(log.entries, hasLength(1));
        expect(log.entries.single.peers, {10, 11});
        expect(await log.heard(1, 10), isTrue);
        expect(await log.heard(1, 10), isFalse);
        expect(log.entries.single.heard, isTrue);
        for (var i = 2; i <= 5; i++) {
          await d(i, 10);
        }
        expect(log.entries.map((e) => e.msgId), [5, 4, 3]);
        final back = SentLog(st);
        await back.load(now.add(const Duration(hours: 1)));
        expect(back.entries.map((e) => e.msgId), [5, 4, 3]);
        await back.load(now.add(const Duration(hours: 25)));
        expect(back.entries, isEmpty);
        await log.remove(5);
        expect(log.entries.map((e) => e.msgId), [4, 3]);
      },
    );

    test(
      'Messenger records a delivered voice message and its listen',
      () async {
        final net = FakeNet();
        final aNode = net.add(1);
        final bNode = net.add(2);
        final a = Messenger(link: aNode, storage: MemoryMessageStorage());
        final b = Messenger(link: bNode, storage: MemoryMessageStorage());
        await a.start();
        await b.start();
        await a.send(
          VoiceClip([for (var i = 0; i < 20; i++) pkt(i)]),
          toPeer: 2,
          channel: 1,
        );
        for (var i = 0; i < 200 && a.sent.entries.isEmpty; i++) {
          await a.tick();
          await b.tick();
          await net.settle();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(a.sent.entries, hasLength(1));
        expect(a.sent.entries.single.toPeer, 2);
        expect(a.sent.entries.single.heard, isFalse);
        final id = a.sent.entries.single.msgId;
        await a.sent.heard(id, 2);
        expect(a.sent.entries.single.heard, isTrue);
        await a.forgetSent(id);
        expect(a.sent.entries, isEmpty);
        await a.dispose();
        await b.dispose();
      },
    );
  });

  group('on the real screens', () {
    testWidgets('Talk: the Messages icon opens Messages on Here; the dot '
        'counts audio from every place', (t) async {
      phone(t);
      final c = await makeController(t, group: 'Ski patrol');
      final h = await withHistory(t, c);
      final (m, fm) = await withMessengers(t, c);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      expect(find.byKey(const Key('talk-voice-shortcut')), findsNothing);
      expect(find.byKey(const Key('talk-history-shortcut')), findsNothing);
      expect(find.byKey(const Key('shortcut-dot')), findsNothing);
      expect(c.unheardAudio, 0);
      // Missed talk on another channel + an unplayed message from a friend.
      take(h, 7, 9, 'Maverick');
      await t.runAsync(
        () => fm.inbox.add(
          entry(
            0x2222,
            1,
            name: 'Ann',
            channel: WalkieController.friendScope,
            channelMessage: false,
          ),
          clipBody(),
        ),
      );
      c.notifyListeners();
      await t.pump();
      expect(c.unheardAudio, 2);
      expect(find.byKey(const Key('shortcut-dot')), findsOneWidget);
      // Chat is text only: nothing lights up there.
      expect(c.unreadText, 0);
      expect(visibleBadges(t), 0);
      await t.tap(find.byKey(const Key('talk-messages-shortcut')));
      await settle(t);
      expect(find.text('Messages'), findsWidgets);
      expect(
        t
            .widget<ChoiceChip>(find.byKey(const Key('messages-filter-here')))
            .selected,
        isTrue,
        reason: 'defaults to Here',
      );
      // Here is empty, Direct and All say what is waiting.
      expect(find.byKey(const Key('messages-empty')), findsOneWidget);
      expect(find.text('Direct (1)'), findsOneWidget);
      expect(find.text('All (2)'), findsOneWidget);
      await t.tap(find.byKey(const Key('messages-filter-direct')));
      await t.pump();
      expect(find.text('Ann · 0:07'), findsOneWidget);
      await t.tap(find.byKey(const Key('messages-filter-all')));
      await t.pump();
      expect(find.text('Ann · 0:07'), findsOneWidget);
      expect(find.textContaining('Live talk ·'), findsOneWidget);
      expect(find.text('Direct · Ann · only you two'), findsOneWidget);
      expect(m.inbox.entries, isEmpty);
      await t.pageBack();
      await settle(t);
      await finish(t);
    });

    testWidgets('Chat badge counts unread text only', (t) async {
      phone(t);
      final c = await makeController(t);
      final h = await withHistory(t, c);
      final (_, fm) = await withMessengers(t, c);
      take(h, c.scope, 7, 'Pat');
      await t.runAsync(
        () => fm.inbox.add(
          entry(
            0x2222,
            2,
            channel: WalkieController.friendScope,
            channelMessage: false,
          ),
          clipBody(),
        ),
      );
      expect(c.unheardTakes, 1);
      expect(c.unplayedMessages, 1);
      expect(c.unreadText, 0);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      expect(visibleBadges(t), 0);
      expect(find.byKey(const Key('shortcut-dot')), findsOneWidget);
      await finish(t);
    });

    testWidgets('Chat badge: unread channel chat plus friend chats', (t) async {
      phone(t);
      final c = await makeController(t, friends: [testFriend(0x2222, 'Ann')]);
      final store = ChatStore(MemoryMessageStorage());
      c.chats = store;
      ChatMessage msg(int id, int sender) => ChatMessage(
        id: id,
        sender: sender,
        senderName: 'Them',
        mine: false,
        at: DateTime.now(),
        type: ChatType.text,
        text: 'hi $id',
      );
      await t.runAsync(() async {
        await store.add(c.channelChat, msg(1, 0x9999));
        await store.add(c.channelChat, msg(2, 0x9999));
        await store.add(friendConversation(0x2222), msg(3, 0x2222));
      });
      expect(c.unreadChannelChat, 2);
      expect(c.unreadFriendChats, 1);
      expect(c.unreadText, 3);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      expect(visibleBadges(t), 1);
      expect(
        find.descendant(of: nav('Chat'), matching: find.text('3')),
        findsNothing,
        reason: 'the label sits next to the icon, not inside the text',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('mainTabs')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      await finish(t);
    });

    testWidgets('the queued button opens Messages on the filter it belongs '
        'to', (t) async {
      phone(t);
      final c = await makeController(t);
      await withMessengers(t, c);
      // Nobody on the channel: a channel message waits for anyone.
      await t.runAsync(
        () => c.messenger!.outbox.add(
          OutboxEntry(
            msgId: 5,
            toPeer: null,
            channel: c.scope,
            createdAt: DateTime.now(),
            durationMs: 4000,
          ),
          clipBody(),
        ),
      );
      expect(queuedFilter(c), MessagesFilter.here);
      await t.runAsync(
        () => c.messenger!.outbox.add(
          OutboxEntry(
            msgId: 6,
            toPeer: null,
            channel: 9,
            createdAt: DateTime.now(),
            durationMs: 4000,
          ),
          clipBody(),
        ),
      );
      expect(queuedFilter(c), MessagesFilter.all);
    });

    testWidgets('a voice message notification opens Messages on the right '
        'list, scrolled to that message', (t) async {
      phone(t, ts: 1.0);
      final c = await makeController(t, group: 'Ski patrol');
      final (m, fm) = await withMessengers(t, c);
      await t.runAsync(() async {
        for (var i = 0; i < 25; i++) {
          await m.inbox.add(
            entry(
              5,
              100 + i,
              channel: c.scope,
              ago: Duration(minutes: i),
            ),
            clipBody(),
          );
        }
        await fm.inbox.add(
          entry(
            0x2222,
            7,
            name: 'Ann',
            channel: WalkieController.friendScope,
            channelMessage: false,
          ),
          clipBody(),
        );
      });
      await t.pumpWidget(homeApp(c));
      await settle(t);
      final requests = <String>[];
      final sub = c.uiRequests.listen(requests.add);
      addTearDown(sub.cancel);
      // The oldest channel message (far down the list).
      final oldest = m.inbox.entries.last;
      await t.runAsync(
        () => c.debugAction({'type': 'openInbox', 'key': oldest.key}),
      );
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(requests, ['messages:here:${oldest.key}']);
      await settle(t);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 150));
      }
      expect(
        t
            .widget<ChoiceChip>(find.byKey(const Key('messages-filter-here')))
            .selected,
        isTrue,
      );
      final f = find.byKey(Key('voice-${oldest.key}'));
      expect(f, findsOneWidget);
      expect(t.getRect(f).bottom, lessThanOrEqualTo(640));
      await t.pageBack();
      await settle(t);
      // A friend's message opens Direct.
      final fe = fm.inbox.entries.single;
      await t.runAsync(
        () => c.debugAction({'type': 'openInbox', 'key': fe.key}),
      );
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await settle(t);
      expect(requests.last, 'messages:direct:${fe.key}');
      expect(
        t
            .widget<ChoiceChip>(find.byKey(const Key('messages-filter-direct')))
            .selected,
        isTrue,
      );
      expect(find.byKey(Key('voice-${fe.key}')), findsOneWidget);
      await t.pageBack();
      await settle(t);
      await finish(t);
    });

    testWidgets('the notification Play button still plays that message', (
      t,
    ) async {
      phone(t);
      final c = await makeController(t);
      final (_, fm) = await withMessengers(t, c);
      final e = entry(
        0x2222,
        3,
        name: 'Ann',
        channel: WalkieController.friendScope,
        channelMessage: false,
      );
      await t.runAsync(() => fm.inbox.add(e, clipBody()));
      expect(e.played, isFalse);
      await t.runAsync(() => c.debugAction({'type': 'play', 'key': e.key}));
      expect(e.played, isTrue, reason: 'Play from the notification works');
      expect(
        c.playbackLog.events.any((l) => l.text.contains('play (notification)')),
        isTrue,
      );
    });

    testWidgets('Messages: mark all as heard clears the dot; clear history '
        'asks first', (t) async {
      phone(t);
      final c = await makeController(t);
      final h = await withHistory(t, c);
      final (m, fm) = await withMessengers(t, c);
      take(h, c.scope, 7, 'Pat');
      take(h, 8, 7, 'Other channel');
      await t.runAsync(() async {
        await m.inbox.add(entry(5, 1), clipBody());
        await fm.inbox.add(
          entry(
            0x2222,
            2,
            channel: WalkieController.friendScope,
            channelMessage: false,
          ),
          clipBody(),
        );
      });
      await t.pumpWidget(MaterialApp(home: MessagesPage(controller: c)));
      await settle(t);
      expect(c.unheardAudio, 4);
      await t.tap(find.byKey(const Key('messages-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Mark all as heard'));
      await t.pumpAndSettle();
      // Here only: the other channel's take and the friend's clip stay.
      expect(c.unheardTakes, 0);
      expect(m.inbox.unplayed, 0);
      expect(fm.inbox.unplayed, 1);
      expect(c.unheardTakesAll, 1);
      await t.tap(find.byKey(const Key('messages-filter-all')));
      await t.pump();
      await t.tap(find.byKey(const Key('messages-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Mark all as heard'));
      await t.pumpAndSettle();
      expect(c.unheardAudio, 0);
      await t.tap(find.byKey(const Key('messages-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Clear live talk history'));
      await t.pumpAndSettle();
      expect(find.text('Clear live talk history?'), findsOneWidget);
      await t.tap(find.text('Clear'));
      await t.pumpAndSettle();
      await t.runAsync(h.flush);
      expect(c.takesAll, isEmpty);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('wide layout: Messages opens as a dialog, not a page', (
      t,
    ) async {
      phone(t, w: 1100, h: 700, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(homeApp(c));
      await settle(t);
      expect(find.byKey(const Key('mainTabs')), findsNothing);
      await t.tap(find.byKey(const Key('talk-messages-shortcut')));
      await settle(t);
      expect(find.byKey(const Key('messages-dialog')), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      // The Talk screen is still there behind it.
      expect(find.byKey(const Key('status-line')), findsOneWidget);
      await t.tap(find.byTooltip('Close'));
      await settle(t);
      expect(find.byKey(const Key('messages-dialog')), findsNothing);
      await finish(t);
    });

    testWidgets('Chat tab: text only, banner once, tabs have no audio rows', (
      t,
    ) async {
      phone(t);
      final c = await makeController(t, group: 'Ski patrol');
      await t.pumpWidget(homeApp(c));
      await settle(t);
      await t.tap(nav('Chat'));
      await settle(t);
      expect(find.text('Ski patrol · private'), findsOneWidget);
      expect(find.text('Ski patrol chat'), findsOneWidget);
      expect(find.textContaining('Voice messages'), findsNothing);
      expect(find.textContaining('History'), findsNothing);
      expect(find.byType(ReachTag), findsNothing);
      expect(
        find.text('Ski patrol'),
        findsNWidgets(1),
        reason: 'only the top bar names it once more',
      );
      await finish(t);
    });

    testWidgets('a friend\'s thread: their voice messages are bubbles you '
        'can play; ours show delivered / listened; Messages > Direct is one '
        'tap away', (t) async {
      phone(t, ts: 1.0);
      final c = await makeController(t, friends: [testFriend(0x2222, 'Ann')]);
      final (_, fm) = await withMessengers(t, c);
      final e = entry(
        0x2222,
        4,
        name: 'Ann',
        channel: WalkieController.friendScope,
        channelMessage: false,
      );
      await t.runAsync(() async {
        await fm.inbox.add(e, clipBody());
        await fm.sent.delivered(
          msgId: 9,
          toPeer: 0x2222,
          channel: 1,
          createdAt: DateTime.now().subtract(const Duration(minutes: 9)),
          durationMs: 3000,
          peer: 0x2222,
          now: DateTime.now().subtract(const Duration(minutes: 8)),
        );
        await fm.sent.heard(9, 0x2222);
      });
      await t.pumpWidget(homeApp(c));
      await settle(t);
      await t.tap(nav('Chat'));
      await settle(t);
      await t.tap(find.byKey(Key('direct-chat-${0x2222}')));
      await settle(t);
      expect(find.byKey(Key('voice-bubble-in-${e.key}')), findsOneWidget);
      expect(find.byKey(const Key('voice-bubble-out-9')), findsOneWidget);
      expect(find.textContaining('Listened'), findsOneWidget);
      expect(find.textContaining('new'), findsOneWidget);
      expect(
        find.text('Voice message'),
        findsOneWidget,
        reason: 'the record button says Voice message, not Hold: voice msg',
      );
      await t.tap(find.byKey(Key('voice-bubble-in-${e.key}')));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
      expect(e.played, isTrue, reason: 'tapping the bubble plays it');
      c.stopPlayback();
      await t.tap(find.byKey(const Key('friend-messages')));
      await settle(t);
      expect(
        t
            .widget<ChoiceChip>(find.byKey(const Key('messages-filter-direct')))
            .selected,
        isTrue,
      );
      expect(find.byKey(Key('voice-${e.key}')), findsOneWidget);
      await t.pageBack();
      await settle(t);
      await t.pageBack();
      await settle(t);
      await finish(t);
    });
  });

  group('friend thread view', () {
    testWidgets('voice bubbles sit between the text by time', (t) async {
      phone(t, ts: 1.0);
      final now = DateTime(2026, 10, 29, 9, 30);
      ChatMessage text(String s, DateTime at, {bool mine = false}) =>
          ChatMessage(
            id: at.millisecondsSinceEpoch,
            sender: mine ? 1 : 2,
            senderName: mine ? 'Me' : 'Ann',
            at: at,
            type: ChatType.text,
            text: s,
            mine: mine,
          );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatView(
              messages: [
                text('first', now.subtract(const Duration(minutes: 10))),
                text('last', now),
              ],
              voice: [
                VoiceBubble(
                  id: 'a',
                  at: now.subtract(const Duration(minutes: 5)),
                  durationMs: 4000,
                  mine: false,
                  played: false,
                  onPlay: () {},
                ),
              ],
              loadPhoto: (_) async => null,
              onSend: (_) {},
              onAttach: () {},
              onOpenMap: (_) {},
              showNames: false,
              now: now,
            ),
          ),
        ),
      );
      final first = t.getRect(find.text('first')).top;
      final voice = t.getRect(find.byKey(const Key('voice-bubble-a'))).top;
      final last = t.getRect(find.text('last')).top;
      expect(first, lessThan(voice));
      expect(voice, lessThan(last));
    });
  });
}
