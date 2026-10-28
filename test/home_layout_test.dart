import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/chat/chat_store.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart'
    show ConnectionSummary;
import 'package:walkie_talkie/ui/status_line.dart';
import 'package:walkie_talkie/ui/who_can_hear.dart';
import 'package:walkie_talkie/ui/chat_page.dart';
import 'package:walkie_talkie/ui/chat_view.dart';
import 'package:walkie_talkie/ui/friends_page.dart';
import 'package:walkie_talkie/ui/history_page.dart';
import 'package:walkie_talkie/ui/home_view.dart';

const people = [
  PersonView(
    id: 0x5A11E,
    name: 'Rubber Duck',
    talking: true,
    links: [TransportKind.lan, TransportKind.internet],
    active: TransportKind.lan,
    lastHeard: Duration(milliseconds: 300),
    volume: 1.5,
  ),
  PersonView(
    id: 0xBEEF01,
    name: 'Maverick the Extraordinarily Long Call Sign',
    links: [TransportKind.ble],
    active: TransportKind.ble,
    lastHeard: Duration(seconds: 1),
    ringStatus: 'Ringing...',
  ),
  PersonView(
    id: 0xC0FFEE,
    name: 'Goose',
    links: [TransportKind.internet],
    active: TransportKind.internet,
    lastHeard: Duration(seconds: 3),
  ),
  PersonView(
    id: 0x7777,
    name: 'Iceman',
    links: [TransportKind.lan],
    active: TransportKind.lan,
    lastHeard: Duration(seconds: 2),
    elsewhere: 'On CH 4',
  ),
  PersonView(
    id: 0x4242,
    name: 'Bandit',
    left: true,
    lastHeard: Duration(seconds: 12),
  ),
];

final takes = [
  TakeView(
    id: 1,
    sender: 0xBEEF01,
    name: 'Maverick the Extraordinarily Long Call Sign',
    at: DateTime(2026, 10, 25, 14, 5),
    durationMs: 12400,
    heard: false,
  ),
  TakeView(
    id: 2,
    sender: 0x5A11E,
    name: 'Rubber Duck',
    at: DateTime(2026, 10, 25, 14, 3),
    durationMs: 4100,
    playing: true,
    positionMs: 1800,
  ),
  TakeView(
    id: 3,
    sender: 0x1234,
    name: 'Lord of the Pings',
    mine: true,
    at: DateTime(2026, 10, 25, 14, 1),
    durationMs: 2600,
  ),
  TakeView(
    id: 4,
    sender: 0xC0FFEE,
    name: 'Goose',
    at: DateTime(2026, 10, 24, 22, 40),
    durationMs: 61000,
    heard: false,
  ),
];

Widget historyApp() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    colorSchemeSeed: Colors.teal,
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Roboto',
  ),
  home: HistoryView(
    channelLabel: 'CH 1',
    takes: takes,
    unheard: 2,
    speed: 1.5,
    playingAll: false,
    onPlay: (_) {},
    onPlayMissed: () {},
    onSpeed: (_) {},
    onDelete: (_) {},
    onMarkAllHeard: () {},
    onClear: () {},
  ),
);

Widget app({
  List<PersonView> peers = people,
  bool details = false,
  String? replyFrom,
  ValueChanged<bool>? onReply,
  ValueChanged<bool>? onMain,
  VoidCallback? onChannelInstead,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    colorSchemeSeed: Colors.teal,
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['NotoColorEmoji'],
  ),
  home: Scaffold(
    appBar: AppBar(
      titleSpacing: 8,
      // Same shape as the real app bar (lock + channel picker, then
      // Settings; Chat and People are in the bottom bar).
      title: Row(
        children: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.lock_open)),
          Flexible(
            child: DropdownButton<int>(
              value: 16,
              underline: const SizedBox.shrink(),
              items: const [DropdownMenuItem(value: 16, child: Text('CH 16'))],
              onChanged: (_) {},
            ),
          ),
        ],
      ),
      actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.settings))],
    ),
    body: HomeBody(
      status: TalkStatusLine(
        audience: const AudienceInfo(Audience.open, channel: 1),
        here: 4,
        netStatus: TransportStatus.running,
        netText: 'Internet: connected via Wi-Fi',
        summary: const ConnectionSummary(
          best: 'Home relay',
          bestRtt: Duration(milliseconds: 42),
          backups: 1,
          checkEvery: Duration(seconds: 5),
        ),
        onOpen: () {},
      ),
      showDebug: details,
      channelLabel: 'CH 1',
      me: const PersonView(id: 0x1234, name: 'Lord of the Pings', me: true),
      people: peers,
      onRing: (_) {},
      onBeep: (_) {},
      onMessage: (_) {},
      onVolume: (_) {},
      onEditMe: () {},
      actions: ChannelActions(
        onRingAll: () {},
        onBeepAll: () {},
        record: const ActionTile(
          key: Key('record'),
          icon: Icons.keyboard_voice,
          label: 'Message',
        ),
        mute: const ActionTile(
          key: Key('muteButton'),
          icon: Icons.volume_up,
          label: 'Mute',
        ),
      ),
      ptt: MainTalkArea(
        replyName: replyFrom,
        onReplyTalk: onReply,
        onChannelInstead: onChannelInstead,
        onOpenChat: () {},
        button: PttButton(
          transmitting: false,
          busy: replyFrom == null,
          onChanged: onMain ?? (_) {},
          size: replyFrom == null ? 132 : 112,
          private: replyFrom != null,
          caption: replyFrom != null
              ? 'Reply privately to $replyFrom'
              : 'Talk to CH 1 (3 people)',
        ),
      ),
    ),
  ),
);

final _t0 = DateTime(2026, 10, 25, 16, 2);

Uint8List _demoPhoto() {
  final im = img.Image(width: 320, height: 220);
  for (final p in im) {
    p
      ..r = 40 + p.x ~/ 2
      ..g = 90 + p.y ~/ 3
      ..b = 160;
  }
  img.fillCircle(
    im,
    x: 230,
    y: 70,
    radius: 36,
    color: img.ColorRgb8(250, 220, 90),
  );
  return img.encodeJpg(im);
}

final _photo = _demoPhoto();

List<ChatMessage> chatMessages() => [
  ChatMessage.fromBody(
    ChatBody.text('Anyone at the trailhead yet?'),
    id: 1,
    sender: 0xBEEF0001,
    senderName: 'Rubber Duck',
    mine: false,
    at: _t0,
  ),
  ChatMessage.fromBody(
    ChatBody.text('Parking now, 5 min'),
    id: 2,
    sender: 0x1234,
    senderName: 'Me',
    mine: true,
    at: _t0.add(const Duration(minutes: 1)),
  )..deliveredTo.addAll({1, 2}),
  ChatMessage.fromBody(
    ChatBody(type: ChatType.photo, data: _photo, width: 320, height: 220),
    id: 3,
    sender: 0xBEEF0002,
    senderName: 'Maverick',
    mine: false,
    at: _t0.add(const Duration(minutes: 2)),
  ),
  ChatMessage.fromBody(
    ChatBody(
      type: ChatType.location,
      lat: 45.52345,
      lng: -122.67621,
      accuracy: 8,
      liveUntil: _t0.add(const Duration(minutes: 30)),
      liveId: 9,
    ),
    id: 4,
    sender: 0xBEEF0002,
    senderName: 'Maverick',
    mine: false,
    at: _t0.add(const Duration(minutes: 3)),
  ),
  ChatMessage.fromBody(
    ChatBody(type: ChatType.location, lat: 45.5199, lng: -122.6801),
    id: 5,
    sender: 0x1234,
    senderName: 'Me',
    mine: true,
    at: _t0.add(const Duration(minutes: 4)),
  ),
];

Widget _themed(Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    colorSchemeSeed: Colors.teal,
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Roboto',
  ),
  home: home,
);

Widget chatApp({bool friend = false}) => _themed(
  Scaffold(
    appBar: AppBar(
      title: Text(friend ? 'Maverick' : 'Chat · Trail crew (CH 3)'),
    ),
    body: ChatView(
      messages: chatMessages(),
      loadPhoto: (m) async => m.hasPhoto ? _photo : null,
      onSend: (_) {},
      onAttach: () {},
      onOpenMap: (_) {},
      showNames: !friend,
      now: _t0.add(const Duration(minutes: 5)),
      liveUntil: friend ? null : _t0.add(const Duration(minutes: 15)),
      notice: friend ? null : 'Iceman has an older app and cannot see chats.',
      header: friend
          ? FriendTalkBar(
              name: 'Maverick',
              online: true,
              via: 'Internet',
              talking: false,
              hearing: false,
              recording: false,
              onTalk: (_) {},
              onRecord: (_) {},
            )
          : null,
    ),
  ),
);

Widget friendsApp() => _themed(
  Scaffold(
    appBar: AppBar(title: const Text('Friends')),
    body: FriendsView(
      friends: const [
        FriendItem(
          id: 0xBEEF0002,
          name: 'Maverick',
          online: true,
          via: 'Internet',
          unread: 2,
          last: 'Live location',
        ),
        FriendItem(
          id: 0xBEEF0001,
          name: 'Rubber Duck',
          online: true,
          via: 'Wi-Fi',
          talking: true,
        ),
        FriendItem(
          id: 0xBEEF0005,
          name: 'A friend with a really long name here',
          online: false,
          last: 'You: See you tomorrow at the usual place!',
        ),
      ],
      requests: [('Goose', () {}, () {})],
      onOpen: (_) {},
      onShowCode: () {},
      onScan: () {},
    ),
  ),
);

Future<void> loadFonts() async {
  final dir =
      '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
  if (!Directory(dir).existsSync()) return;
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final bytes = File('$dir/$f').readAsBytesSync();
      l.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await l.load();
  }

  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Italic.ttf',
  ]);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  // Emoji in names / the private banner (previews only).
  const emoji = '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf';
  if (File(emoji).existsSync()) {
    final l = FontLoader('NotoColorEmoji')
      ..addFont(
        Future.value(ByteData.sublistView(File(emoji).readAsBytesSync())),
      );
    await l.load();
  }
}

void main() {
  setUpAll(loadFonts);

  Future<void> pumpAt(
    WidgetTester tester,
    Widget w, {
    double scale = 1.3,
  }) async {
    tester.view.physicalSize = const Size(360, 780) * 3;
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(w);
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('360x780, 5 peers, 1.3x text: no overflow, count includes you', (
    tester,
  ) async {
    await pumpAt(tester, app());
    expect(tester.takeException(), isNull);
    // The one status line (the "N on CH 1" row is gone; the count is in
    // the line and in the People tab).
    expect(find.byKey(const Key('people-count')), findsNothing);
    expect(find.textContaining('Open channel CH 1 · 4 people'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Lord of the Pings'), findsOneWidget);
    expect(find.text('Rubber Duck'), findsOneWidget);
    // Scroll to the end: every card lays out without overflow.
    await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Bandit'), findsOneWidget);
    expect(find.textContaining('Left 12s ago'), findsOneWidget);
  });

  testWidgets('details open + 2x text still lays out', (tester) async {
    await pumpAt(tester, app(details: true), scale: 2.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty state', (tester) async {
    await pumpAt(tester, app(peers: const []));
    expect(tester.takeException(), isNull);
    // An open channel keeps a simple note (no Add people: nothing to add).
    expect(find.textContaining('Nobody on CH 1 yet'), findsOneWidget);
    expect(find.byKey(const Key('empty-add-people')), findsNothing);
  });

  testWidgets('history at 360x780 with 1.3x text', (tester) async {
    await pumpAt(tester, historyApp());
    expect(tester.takeException(), isNull);
    expect(find.text('Play all missed (2)'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.textContaining('not heard'), findsWidgets);
  });

  Future<void> snapshot(WidgetTester tester, Widget w, String out) async {
    await pumpAt(tester, RepaintBoundary(child: w), scale: 1.0);
    // Let pictures decode.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 3);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out).writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  testWidgets('chat at 360x780 with 1.3x text', (tester) async {
    await pumpAt(tester, chatApp());
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('Parking now, 5 min'), findsOneWidget);
    expect(find.textContaining('Live location (until 16:32)'), findsOneWidget);
    expect(find.textContaining('older app'), findsOneWidget);
    await pumpAt(tester, chatApp(friend: true));
    expect(tester.takeException(), isNull);
    expect(find.text('Hold to talk'), findsOneWidget);
    expect(find.textContaining('only you two can read this'), findsOneWidget);
  });

  testWidgets('chat at 2x text still lays out', (tester) async {
    await pumpAt(tester, chatApp(friend: true), scale: 2.0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('friends at 360x780 with 1.3x text', (tester) async {
    await pumpAt(tester, friendsApp());
    expect(tester.takeException(), isNull);
    expect(find.text('2 of 3 online'), findsOneWidget);
    expect(find.text('Goose wants to be friends'), findsOneWidget);
    expect(find.text('Talking to you...'), findsOneWidget);
  });

  testWidgets('chat preview PNG (CHAT_PNG=path)', (tester) async {
    final out = Platform.environment['CHAT_PNG'];
    if (out == null) return;
    await snapshot(tester, chatApp(), out);
  });

  testWidgets('friend chat preview PNG (FRIEND_CHAT_PNG=path)', (tester) async {
    final out = Platform.environment['FRIEND_CHAT_PNG'];
    if (out == null) return;
    await snapshot(tester, chatApp(friend: true), out);
  });

  testWidgets('friends preview PNG (FRIENDS_PNG=path)', (tester) async {
    final out = Platform.environment['FRIENDS_PNG'];
    if (out == null) return;
    await snapshot(tester, friendsApp(), out);
  });

  testWidgets('preview PNG (PREVIEW_PNG=path)', (tester) async {
    final out = Platform.environment['PREVIEW_PNG'];
    if (out == null) return;
    await snapshot(tester, app(), out);
  });

  testWidgets('private reply banner: lays out, routes to the friend', (
    tester,
  ) async {
    final reply = <bool>[], main = <bool>[];
    var channelInstead = 0;
    for (final scale in [1.0, 1.3, 2.0]) {
      await pumpAt(
        tester,
        app(
          replyFrom: 'Ginger Snap Dragon 🐉',
          onReply: reply.add,
          onMain: main.add,
          onChannelInstead: () => channelInstead++,
        ),
        scale: scale,
      );
      expect(tester.takeException(), isNull, reason: 'scale $scale');
    }
    expect(
      find.text(
        '🔒 Direct chat from Ginger Snap Dragon 🐉: Hold here to reply privately',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Reply privately to Ginger Snap Dragon 🐉'),
      findsOneWidget,
    );
    expect(find.text('HOLD TO REPLY'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsWidgets);
    // Holding the banner talks privately (down, then up).
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('private-reply-hold'))),
    );
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(reply, [true, false]);
    expect(main, isEmpty);
    await tester.tap(find.byKey(const Key('talk-to-channel')));
    expect(channelInstead, 1);
  });

  testWidgets('main button says who hears it', (tester) async {
    await pumpAt(tester, app());
    expect(find.text('Talk to CH 1 (3 people)'), findsOneWidget);
    expect(find.textContaining('Private from'), findsNothing);
    expect(find.byKey(const Key('talk-to-channel')), findsNothing);
  });

  testWidgets('reply preview PNG (REPLY_PNG=path)', (tester) async {
    final out = Platform.environment['REPLY_PNG'];
    if (out == null) return;
    await snapshot(
      tester,
      app(replyFrom: 'Ginger Snap Dragon 🐉', onChannelInstead: () {}),
      out,
    );
  });

  testWidgets('history preview PNG (HISTORY_PNG=path)', (tester) async {
    final out = Platform.environment['HISTORY_PNG'];
    if (out == null) return;
    await snapshot(tester, historyApp(), out);
  });
}
