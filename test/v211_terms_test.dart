import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/friends/friend_links.dart';
import 'package:walkie_talkie/ui/who_can_hear.dart';

void main() {
  group('one word for each kind', () {
    test('no old wording is left in the app text', () {
      // Open channel / Private group / Direct chat everywhere. Allowed:
      // the QR / copied invite text old phones still read, and the
      // Meshtastic app's own "private channel".
      final bad = <RegExp>[
        RegExp(r'private channel', caseSensitive: false),
        RegExp(r'private chat', caseSensitive: false),
        RegExp(r'public channel', caseSensitive: false),
        RegExp(r"'Public'|'Private'"),
        RegExp(r'connected privately', caseSensitive: false),
        RegExp(r'''\(private\)['"]'''),
        RegExp(r'private \(friend\)'),
      ];
      const allowed = [
        'Walkie Talkie private channel', // QR + copied text (older apps parse it)
        'private (?:channel|group)', // the invite parser reads both
        'in the Meshtastic app', // Meshtastic's own channel
        'private-channel', // key salt (never changes)
      ];
      final hits = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.trimLeft().startsWith('//')) continue;
          if (allowed.any(l.contains)) continue;
          // Meshtastic app text spans two lines.
          if (f.path.endsWith('radio_settings.dart') &&
              l.contains('Make a private channel')) {
            continue;
          }
          for (final r in bad) {
            if (r.hasMatch(l)) hits.add('${f.path}:${i + 1}: ${l.trim()}');
          }
        }
      }
      expect(hits, isEmpty, reason: hits.join('\n'));
    });
  });

  group('direct chat status lines', () {
    final now = DateTime(2026, 10, 27, 12);
    const bt = FriendPath(FriendPathKind.direct, TransportKind.ble);
    const lora = FriendPath(FriendPathKind.radio, TransportKind.lora);
    String l(FriendLinkStatus s) => friendStatusLineFor(s, now, name: 'Sam');

    test('out of reach: never connected, and with last heard', () {
      expect(
        l(const FriendLinkStatus()),
        "Sam is out of reach · your messages will send when they're back "
        '(up to 24 h)',
      );
      expect(
        l(
          FriendLinkStatus(
            lastPath: bt,
            lastHeard: now.subtract(const Duration(hours: 3)),
          ),
        ),
        'Sam is out of reach (last heard 3 h ago) · your messages will send '
        "when they're back (up to 24 h)",
      );
    });

    test('connected, and over the radio', () {
      expect(
        l(const FriendLinkStatus(path: bt)),
        'Connected to Sam · only you two can read this',
      );
      expect(
        l(const FriendLinkStatus(path: lora)),
        'Connected to Sam · only you two can read this · via radio, slow',
      );
    });

    test('reconnecting within 2 minutes, then out of reach', () {
      expect(
        l(
          FriendLinkStatus(
            lastPath: bt,
            lastHeard: now.subtract(const Duration(seconds: 40)),
          ),
        ),
        'Reconnecting to Sam · only you two can read this',
      );
      expect(
        l(
          FriendLinkStatus(
            lastPath: bt,
            lastHeard: now.subtract(const Duration(minutes: 5)),
          ),
        ),
        startsWith('Sam is out of reach (last heard 5 min ago)'),
      );
    });
  });

  group('Who can hear this?', () {
    test('the three lines', () {
      expect(
        const AudienceInfo(Audience.open, channel: 3).line,
        'Open channel · anyone on CH 3 can hear',
      );
      expect(
        const AudienceInfo(Audience.privateGroup, channel: 3, members: 4).line,
        'Private group · only people with the code (4 members)',
      );
      expect(
        const AudienceInfo(Audience.privateGroup, channel: 3, members: 1).line,
        'Private group · only people with the code (1 member)',
      );
      expect(
        const AudienceInfo(Audience.privateGroup).line,
        'Private group · only people with the code',
      );
      expect(
        const AudienceInfo(Audience.direct, name: 'Sam').line,
        'Direct chat · just you and Sam',
      );
    });

    test('a channel chat says which kind it is', () {
      final priv = TransportManager.privateScopeBit | 5;
      final open = AudienceInfo.forScope(
        7,
        currentScope: priv,
        currentChannel: 5,
        listeners: 3,
      );
      expect(open.kind, Audience.open);
      expect(open.channel, 7);
      final mine = AudienceInfo.forScope(
        priv,
        currentScope: priv,
        currentChannel: 5,
        listeners: 3,
      );
      expect(mine.kind, Audience.privateGroup);
      expect(mine.members, 4, reason: 'you and 3 others');
      expect(
        mine.channel,
        isNull,
        reason: 'a private group has no channel number',
      );
    });

    // The top bar as the Talk screen builds it: title row, four action
    // buttons, then the line.
    Widget bar(AudienceInfo info) => MaterialApp(
      home: Builder(
        builder: (c) => Scaffold(
          appBar: AppBar(
            titleSpacing: 8,
            bottom: whoCanHearBottom(c, info),
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [Text('C'), Icon(Icons.arrow_drop_down)],
            ),
            actions: [
              for (final i in [
                Icons.chat_bubble_outline,
                Icons.people_outline,
                Icons.voicemail,
                Icons.settings,
              ])
                IconButton(onPressed: () {}, icon: Icon(i)),
            ],
          ),
          body: const SizedBox(),
        ),
      ),
    );

    for (final scale in [1.0, 1.3]) {
      testWidgets('fits a 360 dp phone at ${scale}x text; long text is cut '
          'with an ellipsis', (tester) async {
        tester.view.physicalSize = const Size(360, 640) * 3;
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final info in const [
          AudienceInfo(Audience.open, channel: 12),
          AudienceInfo(Audience.privateGroup, channel: 12, members: 24),
          AudienceInfo(
            Audience.direct,
            name: 'Ginger Snap Dragon the Third of Many Names',
          ),
        ]) {
          await tester.pumpWidget(bar(info));
          expect(tester.takeException(), isNull, reason: info.line);
          final t = tester.widget<Text>(
            find.byKey(const Key('who-can-hear-text')),
          );
          expect(t.maxLines, 1);
          expect(t.overflow, TextOverflow.ellipsis);
          expect(t.data, info.line);
          // Sits right under the title bar, inside the app bar.
          expect(
            tester.getRect(find.byKey(const Key('who-can-hear'))).bottom,
            lessThanOrEqualTo(kToolbarHeight + 13 * scale + 20),
          );
        }
      });
    }

    testWidgets('tap opens the sheet: three kinds, this one highlighted', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640) * 3;
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => Column(
                children: [
                  WhoCanHearLine(
                    info: const AudienceInfo(
                      Audience.privateGroup,
                      channel: 3,
                      members: 4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('who-can-hear')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Who can hear this?'), findsOneWidget);
      for (final k in Audience.values) {
        expect(find.byKey(Key('who-kind-${k.name}')), findsOneWidget);
      }
      expect(find.text('Private group (this one)'), findsOneWidget);
      expect(find.text('Open channel'), findsOneWidget);
      expect(find.text('Direct chat'), findsOneWidget);
      expect(find.textContaining('Only people you invited'), findsOneWidget);
      expect(
        find.textContaining('Anyone on the same channel number'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Only you two can read or hear it'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('who-can-hear-sheet')), findsNothing);
    });
  });
}
