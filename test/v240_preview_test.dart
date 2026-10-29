// Screenshots for v2.4.0 (only when V240_SHOTS=<dir> is set):
//   V240_SHOTS=/workspace flutter test test/v240_preview_test.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/chat/chat_store.dart';
import 'package:walkie_talkie/history/talk_history.dart';
import 'package:walkie_talkie/messaging/inbox.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/outbox.dart';
import 'package:walkie_talkie/messaging/storage.dart';
import 'package:walkie_talkie/messaging/voice_clip.dart';
import 'package:walkie_talkie/ui/chat_page.dart';
import 'package:walkie_talkie/ui/messages_page.dart';

import 'home_layout_test.dart' show loadFonts;
import 'messaging_fakes.dart';
import 'v231_helpers.dart';

Uint8List pkt(int i) => Uint8List.fromList([i & 0xFF, 1, 2, 3, 4, 5, 6, 7, 8]);
Uint8List body() => VoiceClip([for (var i = 0; i < 150; i++) pkt(i)]).encode();

InboxEntry entry(
  int sender,
  int id,
  String name, {
  required int channel,
  required bool channelMessage,
  bool played = false,
  int minutes = 5,
}) => InboxEntry(
  sender: sender,
  msgId: id,
  senderName: name,
  channel: channel,
  channelMessage: channelMessage,
  receivedAt: DateTime.now().subtract(Duration(minutes: minutes)),
  durationMs: 7000 + id * 1300,
  played: played,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Platform.environment['V240_SHOTS'];
  if (dir == null) {
    test('v2.4.0 previews skipped (set V240_SHOTS)', () {});
    return;
  }
  setUpAll(loadFonts);

  Future<void> shot(WidgetTester t, String name, {bool wait = true}) async {
    for (var i = 0; i < 3; i++) {
      if (wait) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
      }
      await t.pump(const Duration(milliseconds: 100));
    }
    final b = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('shotroot')),
    );
    await t.runAsync(() async {
      final img = await b.toImage(pixelRatio: 2);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/v240_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Widget root(Widget w) =>
      RepaintBoundary(key: const Key('shotroot'), child: w);

  Future<WalkieController> world(
    WidgetTester t, {
    String? group,
    double height = 640,
  }) async {
    phone(t, w: 360, h: height, ts: 1.0);
    final c = await makeController(
      t,
      group: group,
      friends: [
        testFriend(0x2222, 'Ann'),
        testFriend(0x3333, 'Ben the Long Named Friend'),
      ],
    );
    final h = TalkHistory(storage: MemoryMessageStorage());
    await t.runAsync(h.load);
    c.history = h;
    void take(
      int scope,
      int sender,
      String name,
      int packets, {
      bool heard = false,
    }) {
      for (var i = 0; i < packets; i++) {
        h.addPacket(
          scope: scope,
          sender: sender,
          name: name,
          opus: pkt(i),
          heard: heard,
        );
      }
      h.endTake(sender);
    }

    take(c.scope, 7, 'Pat', 200);
    take(c.scope, 8, 'Goose', 120, heard: true);
    take(c.scope == 4 ? 5 : 4, 9, 'Maverick', 90);
    final net = FakeNet();
    final m = Messenger(link: net.add(0x1234), storage: MemoryMessageStorage());
    final fm = Messenger(
      link: net.add(0x1235),
      storage: MemoryMessageStorage(),
    );
    c.messenger = m;
    c.friendMessenger = fm;
    addTearDown(m.dispose);
    addTearDown(fm.dispose);
    await t.runAsync(() async {
      await m.inbox.add(
        entry(5, 1, 'Iceman', channel: c.scope, channelMessage: true),
        body(),
      );
      await m.inbox.add(
        entry(
          6,
          2,
          'Goose',
          channel: c.scope,
          channelMessage: true,
          played: true,
          minutes: 95,
        ),
        body(),
      );
      await m.inbox.add(
        entry(
          0x4444,
          3,
          'Slider',
          channel: 9,
          channelMessage: true,
          minutes: 40,
        ),
        body(),
      );
      await fm.inbox.add(
        entry(
          0x2222,
          4,
          'Ann',
          channel: WalkieController.friendScope,
          channelMessage: false,
          minutes: 2,
        ),
        body(),
      );
      await fm.inbox.add(
        entry(
          0x2222,
          5,
          'Ann',
          channel: WalkieController.friendScope,
          channelMessage: false,
          played: true,
          minutes: 120,
        ),
        body(),
      );
      await m.outbox.add(
        OutboxEntry(
          msgId: 20,
          toPeer: null,
          channel: c.scope,
          createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
          durationMs: 4000,
        ),
        body(),
      );
      await m.sent.delivered(
        msgId: 30,
        toPeer: 5,
        channel: c.scope,
        createdAt: DateTime.now().subtract(const Duration(minutes: 12)),
        durationMs: 5000,
        peer: 5,
        now: DateTime.now().subtract(const Duration(minutes: 11)),
      );
      await m.sent.heard(30, 5);
      await fm.sent.delivered(
        msgId: 31,
        toPeer: 0x2222,
        channel: 1,
        createdAt: DateTime.now().subtract(const Duration(minutes: 30)),
        durationMs: 3000,
        peer: 0x2222,
        now: DateTime.now().subtract(const Duration(minutes: 29)),
      );
    });
    // A couple of text messages for the Chat tab and the friend thread.
    final store = ChatStore(MemoryMessageStorage());
    c.chats = store;
    ChatMessage text(
      int id,
      int sender,
      String name,
      String s,
      bool mine,
      int ago,
    ) => ChatMessage(
      id: id,
      sender: sender,
      senderName: name,
      mine: mine,
      at: DateTime.now().subtract(Duration(minutes: ago)),
      type: ChatType.text,
      text: s,
    );
    await t.runAsync(() async {
      await store.add(
        c.channelChat,
        text(1, 0x9999, 'Iceman', 'Parking now, 5 min', false, 4),
      );
      await store.add(
        friendConversation(0x2222),
        text(2, 0x2222, 'Ann', 'see you at 5', false, 20),
      );
      await store.add(
        friendConversation(0x2222),
        text(3, 0x1234, 'Me', 'ok, bringing the radios', true, 15),
      );
    });
    return c;
  }

  for (final group in ['Ski patrol', null]) {
    final tag = group == null ? 'open' : 'group';
    testWidgets('chat $tag', (t) async {
      final c = await world(t, group: group);
      await t.pumpWidget(root(homeApp(c)));
      await settle(t);
      await t.tap(
        find.descendant(
          of: find.byKey(const Key('mainTabs')),
          matching: find.text('Chat'),
        ),
      );
      await settle(t);
      await shot(t, 'chat_$tag', wait: false);
      await finish(t);
    });
  }

  testWidgets('talk', (t) async {
    final c = await world(t);
    await t.pumpWidget(root(homeApp(c)));
    await settle(t);
    await shot(t, 'talk', wait: false);
    await finish(t);
    await t.pump(const Duration(minutes: 2));
  });

  for (final f in MessagesFilter.values) {
    testWidgets('messages ${f.name}', (t) async {
      final c = await world(t, height: 1000);
      await t.pumpWidget(
        root(
          MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              brightness: Brightness.dark,
              fontFamily: 'Roboto',
            ),
            home: MessagesPage(
              controller: c,
              initial: f,
              focusKey: f == MessagesFilter.direct ? '${0x2222}_4' : null,
            ),
          ),
        ),
      );
      await settle(t);
      await shot(t, 'messages_${f.name}');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('friend thread with a voice bubble', (t) async {
    final c = await world(t);
    await t.pumpWidget(
      root(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            fontFamily: 'Roboto',
          ),
          home: ChatPage(controller: c, conv: friendConversation(0x2222)),
        ),
      ),
    );
    await settle(t);
    await shot(t, 'friend_thread');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
