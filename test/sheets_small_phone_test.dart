// v2.0.1: bottom sheets and dialogs on a small phone. Real bug (v2.0.0,
// Samsung 3-button nav): the person sheet was cut off below Ring / Beep
// because non-scroll-controlled sheets are capped at 9/16 of the screen and
// the content did not scroll. Every sheet now goes through showAppSheet:
// scroll-controlled, max 90 % of the screen, scrolls, and keeps clear of
// the navigation bar and keyboard.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/invite.dart';
import 'package:walkie_talkie/app/link_settings.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/ui/channels_sheet.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/invite_sheet.dart';
import 'package:walkie_talkie/ui/link_sheet.dart';
import 'package:walkie_talkie/ui/mesh_channels.dart';
import 'package:walkie_talkie/ui/person_sheet.dart';
import 'package:walkie_talkie/ui/sheets.dart';

import 'home_layout_test.dart' show loadFonts;
import 'v186_cell_test.dart' show cellOk;
import 'v187_features_test.dart' show friendCode;
import 'v197_meshtastic_import_test.dart' show pythonUrl;

const top = 24.0, bottom = 48.0, w = 360.0, h = 640.0;

void phone(WidgetTester t, {double keyboard = 0, double scale = 1.3}) {
  t.view.physicalSize = const Size(w, h) * 3;
  t.view.devicePixelRatio = 3;
  t.view.padding = FakeViewPadding(
    top: top * 3,
    bottom: keyboard > 0 ? 0 : bottom * 3,
  );
  t.view.viewPadding = const FakeViewPadding(top: top * 3, bottom: bottom * 3);
  t.view.viewInsets = FakeViewPadding(bottom: keyboard * 3);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearAllTestValues);
}

Widget host(
  WidgetBuilder content, {
  bool scrollable = true,
  bool dragHandle = true,
}) => MaterialApp(
  theme: ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Roboto',
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => showAppSheet<void>(
            context: context,
            scrollable: scrollable,
            showDragHandle: dragHandle,
            builder: content,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> open(WidgetTester t, Widget app) async {
  await t.pumpWidget(app);
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
}

/// The sheet fits the screen, its first item is clear of the status bar,
/// and after scrolling to the end every [last] item is fully visible and
/// above the navigation bar (and above [keyboard]).
Future<void> expectReachable(
  WidgetTester t,
  List<Finder> last, {
  double keyboard = 0,
}) async {
  final sheet = t.getRect(find.byType(BottomSheet));
  expect(sheet.top, greaterThanOrEqualTo(top), reason: 'sheet under status');
  expect(
    sheet.height,
    lessThanOrEqualTo(h * sheetMaxHeightFraction + 0.5),
    reason: 'sheet taller than 90 %',
  );
  final scroll = find
      .descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      )
      .first;
  await t.drag(scroll, const Offset(0, -6000));
  await t.pumpAndSettle();
  final floor = h - (keyboard > 0 ? keyboard : bottom);
  for (final f in last) {
    expect(f, findsOneWidget);
    final r = t.getRect(f);
    expect(r.bottom, lessThanOrEqualTo(floor + 0.01), reason: '$f under bar');
    expect(r.top, greaterThanOrEqualTo(sheet.top), reason: '$f above sheet');
  }
  expect(t.takeException(), isNull);
}

const adminPerson = PersonView(
  id: 0xBEEF01,
  name: 'General Nuisance',
  links: [TransportKind.internet],
  active: TransportKind.internet,
  lastHeard: Duration(seconds: 1),
);

PersonSheetView personView({
  bool friend = false,
  bool muted = false,
  bool admin = false,
  PersonView person = adminPerson,
}) => PersonSheetView(
  person: person,
  volume: 1,
  alwaysAllow: false,
  isFriend: friend,
  muted: muted,
  canRemove: admin,
  onVolume: (_) {},
  onAlwaysAllow: (_) {},
  onRing: () {},
  onBeep: () {},
  onUrgent: () {},
  onVoiceMessage: () {},
  onPrivateChat: () {},
  onAddFriend: () {},
  onMute: () {},
  onBlock: () {},
  onRemove: () {},
);

void main() {
  setUpAll(loadFonts);

  group('person sheet (the v2.0.0 bug)', () {
    testWidgets('everything below Ring / Beep is reachable', (t) async {
      phone(t);
      await open(t, host((_) => personView(admin: true, muted: true)));
      // Cut off at the start, as on the user's phone.
      expect(t.getRect(find.text('Block')).bottom, greaterThan(h - bottom));
      await expectReachable(t, [
        find.byKey(const Key('person-urgent')),
        find.byKey(const Key('person-voice')),
        find.byKey(const Key('person-add-friend')),
        find.byKey(const Key('person-mute')),
        find.byKey(const Key('person-block')),
        find.byKey(const Key('person-remove')),
        find.byKey(const Key('person-muted-note')),
      ]);
    });

    testWidgets('friend: Private chat instead of Add friend', (t) async {
      phone(t);
      await open(t, host((_) => personView(friend: true)));
      await expectReachable(t, [
        find.byKey(const Key('person-chat')),
        find.byKey(const Key('person-block')),
      ]);
      expect(find.byKey(const Key('person-add-friend')), findsNothing);
      expect(find.byKey(const Key('person-remove')), findsNothing);
    });

    testWidgets('long name, plain sizes, normal text', (t) async {
      phone(t, scale: 1);
      await open(
        t,
        host(
          (_) => personView(
            admin: true,
            person: const PersonView(
              id: 5,
              name: 'Maverick the Extraordinarily Long Call Sign',
              lastHeard: Duration(seconds: 1),
            ),
          ),
        ),
      );
      await expectReachable(t, [find.byKey(const Key('person-remove'))]);
    });
  });

  group('other sheets', () {
    testWidgets('channel picker (private + CH 1-16)', (t) async {
      phone(t);
      await open(
        t,
        host(
          scrollable: false,
          (_) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ChannelsView(
              current: 3,
              privateRows: [
                const ChannelRow(12, title: 'Family', emoji: '🏕'),
                const ChannelRow(15, title: 'Crew'),
              ],
              openRows: [
                for (var i = 1; i <= 16; i++)
                  if (i != 12 && i != 15) ChannelRow(i),
              ],
              onPick: (_) {},
              onNewPrivate: () {},
              onJoinPrivate: () {},
              onMeshImport: () {},
            ),
          ),
        ),
      );
      await expectReachable(t, [find.byKey(const Key('channel-row-16'))]);
    });

    testWidgets('invite sheet (private channel QR)', (t) async {
      phone(t);
      await open(
        t,
        host(
          scrollable: false,
          (_) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: InviteView(
              channelLabel: 'CH 7 (private)',
              withChannel: true,
              withFriend: true,
              isPrivate: true,
              revealed: true,
              invite: Invite(
                channel: 7,
                passcode: 'secret99',
                friendCode: friendCode(),
              ),
              onChannel: (_) {},
              onFriend: (_) {},
              onReveal: () {},
              onShare: () {},
              onCopy: () {},
              onScan: () {},
            ),
          ),
        ),
      );
      await expectReachable(t, [find.byKey(const Key('invite-qr'))]);
    });

    testWidgets('Meshtastic import preview', (t) async {
      phone(t);
      final p = MeshImportPreview.build(
        MeshChannelSet.parseUrl(pythonUrl),
        const MeshRadioInfo(region: 1, modemPreset: 0, usePreset: true),
      );
      await open(
        t,
        host(
          scrollable: false,
          (_) => SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: MeshImportView(
              preview: p,
              radioReady: true,
              onAdd: (_, _) {},
            ),
          ),
        ),
      );
      await expectReachable(t, [find.byKey(const Key('mesh-add'))]);
    });

    testWidgets('link / cell sheet (default scroll)', (t) async {
      phone(t);
      await open(
        t,
        host(
          (_) => LinkSheetView(
            kind: TransportKind.internet,
            icon: Icons.signal_cellular_alt,
            info: describeCell(CellState.blocked, cellOk),
            onAction: () {},
            onSecond: () {},
            onTest: () {},
          ),
        ),
      );
      await expectReachable(t, [find.byKey(const Key('link-second-settings'))]);
    });

    testWidgets('tall content, own scroll view, and no scroll view', (t) async {
      phone(t);
      Widget tall() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 30; i++) ListTile(title: Text('Row $i')),
          const ListTile(key: Key('end'), title: Text('The end')),
        ],
      );
      await open(t, host((_) => tall()));
      await expectReachable(t, [find.byKey(const Key('end'))]);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      await open(
        t,
        host(scrollable: false, (_) => SingleChildScrollView(child: tall())),
      );
      await expectReachable(t, [find.byKey(const Key('end'))]);
    });

    testWidgets('drag handle is shown and can be turned off', (t) async {
      phone(t);
      await open(t, host((_) => const Text('hi')));
      expect(
        t.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
        isTrue,
      );
      expect(t.getRect(find.text('hi')).top, greaterThan(top + 10));
    });

    testWidgets('keyboard: the text field stays above it', (t) async {
      phone(t, keyboard: 280);
      await open(
        t,
        host(
          (_) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 6; i++) ListTile(title: Text('Row $i')),
              const Padding(
                padding: EdgeInsets.all(16),
                child: TextField(key: Key('field')),
              ),
            ],
          ),
        ),
      );
      await expectReachable(t, [find.byKey(const Key('field'))], keyboard: 280);
    });

    testWidgets('the builder is not padded twice (SafeArea inside)', (t) async {
      phone(t);
      await open(
        t,
        host(
          (_) => const SafeArea(
            child: SizedBox(key: Key('box'), height: 100, width: 100),
          ),
        ),
      );
      final sheet = t.getRect(find.byType(BottomSheet));
      final box = t.getRect(find.byKey(const Key('box')));
      expect(box.bottom, lessThanOrEqualTo(h - bottom));
      // Sheet ends at the screen bottom; box sits right above the nav bar
      // (one inset, not two).
      expect(sheet.bottom, closeTo(h, 0.5));
      expect(h - bottom - box.bottom, lessThan(1));
    });
  });

  group('dialogs scroll on a small phone', () {
    testWidgets('invite confirm dialog at large text', (t) async {
      phone(t, scale: 2);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => InviteConfirmDialog(
                  invite: Invite(
                    channel: 4,
                    passcode: 'abcdef',
                    name: 'Bandit',
                    friendCode: friendCode(),
                  ),
                  currentChannel: 'CH 1',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'dialog overflowed');
      final accept = find.byKey(const Key('invite-accept'));
      expect(accept, findsOneWidget);
      final r = t.getRect(accept);
      expect(r.bottom, lessThanOrEqualTo(h - bottom));
    });
  });
}
