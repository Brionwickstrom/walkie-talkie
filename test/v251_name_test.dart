import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/invite.dart';
import 'package:walkie_talkie/main.dart';
import 'package:walkie_talkie/ui/battery_help.dart';
import 'package:walkie_talkie/update/updater.dart';

import 'v231_helpers.dart';

// v2.5.1: the app is called "Stalkie Talkie" wherever people see it. What
// keeps updates and other phones working keeps its old name.

String read(String p) => File(p).readAsStringSync();

void main() {
  group('the visible name is Stalkie Talkie', () {
    testWidgets('MaterialApp title (task switcher, Windows title bar)', (
      t,
    ) async {
      phone(t, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(WalkieApp(controller: c));
      await t.pump();
      expect(
        t.widget<MaterialApp>(find.byType(MaterialApp)).title,
        'Stalkie Talkie',
      );
      await finish(t);
    });

    testWidgets('Help text names the app Stalkie Talkie', (t) async {
      phone(t, ts: 1.0);
      final c = await makeController(t);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showBatteryGuide(ctx, c),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.text('Let Stalkie Talkie run in the background'),
        findsOneWidget,
      );
      await finish(t);
    });

    test('Android: launcher label, accessibility service, notifications', () {
      final m = read('android/app/src/main/AndroidManifest.xml');
      expect(m, contains('android:label="Stalkie Talkie"'));
      final s = read('android/app/src/main/res/values/strings.xml');
      expect(s, contains('Stalkie Talkie volume-down talk button'));
      expect(s, contains('talk on Stalkie Talkie while'));
      expect(s, isNot(contains('Walkie Talkie')));
      final n = read(
        'android/app/src/main/kotlin/com/walkie/walkie_talkie/Notifier.kt',
      );
      expect(n, contains('Tap to open Stalkie Talkie'));
      expect(n, isNot(contains('Walkie Talkie')));
      final l = read(
        'android/app/src/main/kotlin/com/walkie/walkie_talkie/ListenService.kt',
      );
      expect(l, contains('"Stalkie Talkie is listening"'));
      final b = read(
        'android/app/src/main/kotlin/com/walkie/walkie_talkie/BootReceiver.kt',
      );
      expect(b, contains('"Stalkie Talkie is listening"'));
    });

    test('Windows window title and file description; iOS display name', () {
      expect(read('windows/runner/main.cpp'), contains('L"Stalkie Talkie"'));
      final rc = read('windows/runner/Runner.rc');
      expect(rc, contains('VALUE "FileDescription", "Stalkie Talkie"'));
      final ios = read('ios/Runner/Info.plist');
      expect(
        ios,
        contains(
          '<key>CFBundleDisplayName</key>\n\t<string>Stalkie Talkie</string>',
        ),
      );
      expect(ios, isNot(contains('Walkie Talkie')));
    });

    test('no visible "Walkie Talkie" is left in the app text', () {
      // Allowed: code comments, the old invite text old apps parse, and the
      // Windows storage folder name (see the next group).
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (l.trimLeft().startsWith('//')) continue;
          if (l.contains('Walkie Talkie')) {
            if (l.contains('(?:Walkie|Stalkie) Talkie private')) continue;
            bad.add('${f.path}:${i + 1}: $l');
          }
        }
      }
      expect(bad, isEmpty);
    });

    test('invite text uses the new name; old invites still parse', () {
      final inv = Invite(channel: 5);
      expect(
        inv.shareText(),
        startsWith('Stalkie Talkie: join open channel CH 5'),
      );
      expect(
        Invite.parse('Walkie Talkie private channel\nCH 5\nPasscode: secret99')!
            .channel,
        5,
      );
      expect(
        Invite.parse('Stalkie Talkie private channel: CH 4, passcode: abc123')!
            .channel,
        4,
      );
    });
  });

  group('what stays so updates and other phones keep working', () {
    test('package id, update assets, repo, link scheme', () {
      final g = read('android/app/build.gradle.kts');
      expect(g, contains('com.walkie.walkie_talkie'));
      expect(
        read('android/app/src/main/AndroidManifest.xml'),
        isNot(contains('com.stalkie')),
      );
      expect(kApkAsset, 'WalkieTalkie.apk');
      expect(kWindowsAsset, 'WalkieTalkie-Windows.zip');
      expect(kReleasesRepo, 'Brionwickstrom/walkie-talkie');
      expect(Invite.scheme, 'walkietalkie');
      expect(
        read('windows/CMakeLists.txt'),
        contains('set(BINARY_NAME "WalkieTalkie")'),
      );
      expect(
        read('windows/runner/Runner.rc'),
        contains('"OriginalFilename", "WalkieTalkie.exe"'),
      );
    });

    test('Windows data folder: company and product name unchanged', () {
      // path_provider builds %APPDATA%\<CompanyName>\<ProductName> from
      // these: renaming them would hide everyone's data after the update.
      final rc = read('windows/runner/Runner.rc');
      expect(rc, contains('VALUE "CompanyName", "Walkie Talkie"'));
      expect(rc, contains('VALUE "ProductName", "Walkie Talkie"'));
    });

    test('notification channel ids are unchanged (names only are visible)', () {
      final n = read(
        'android/app/src/main/kotlin/com/walkie/walkie_talkie/Notifier.kt',
      );
      for (final id in [
        'listen_v1',
        'ring_v1',
        'talk_v1',
        'msg_v1',
        'urgent_v1',
        'urgent_dnd_v1',
        'wx_warning_v1',
        'wx_extreme_v1',
      ]) {
        expect(n, contains('"$id"'));
      }
    });

    test('protocol strings and the NWS User-Agent keep the old identifier', () {
      expect(
        read('lib/core/channel_crypto.dart'),
        contains("'WalkieTalkie/private-channel/v1/ch='"),
      );
      expect(
        read('lib/app/walkie_controller.dart'),
        contains(
          "'WalkieTalkie/\$ver (+https://github.com/Brionwickstrom/walkie-talkie)'",
        ),
      );
    });
  });
}
