// v1.8.7: setup wizard, connection test, background reliability guide,
// invite links / QR, debug log.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_relay/relay_server.dart';
import 'package:walkie_talkie/app/battery_guide.dart';
import 'package:walkie_talkie/app/conn_probes.dart';
import 'package:walkie_talkie/app/connection_test.dart';
import 'package:walkie_talkie/app/debug_log.dart';
import 'package:walkie_talkie/app/invite.dart';
import 'package:walkie_talkie/app/link_settings.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/app/setup.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/transports/relay_socket.dart';
import 'package:walkie_talkie/ui/battery_help.dart';
import 'package:walkie_talkie/ui/connection_test_page.dart';
import 'package:walkie_talkie/ui/invite_sheet.dart';
import 'package:walkie_talkie/ui/setup_wizard.dart';

String friendCode() => PairKey.qrText(
  ownerId: 0x1234abcd,
  ownerName: 'Bandit',
  code: PairKey.randomSecret(),
);

CheckRow row(List<CheckRow> rows, String id) =>
    rows.firstWhere((r) => r.id == id);

void main() {
  group('setup entry', () {
    test('fresh install: wizard; updated: one-time prompt; done: none', () {
      expect(
        setupEntryFor(newInstall: true, setupDone: false, promptShown: false),
        SetupEntry.wizard,
      );
      expect(
        setupEntryFor(newInstall: false, setupDone: false, promptShown: false),
        SetupEntry.prompt,
      );
      expect(
        setupEntryFor(newInstall: false, setupDone: false, promptShown: true),
        SetupEntry.none,
      );
      expect(
        setupEntryFor(newInstall: true, setupDone: true, promptShown: false),
        SetupEntry.none,
      );
    });

    test('settings: new install detected from the missing phone id; flags '
        'survive a save', () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsSettingsStore();
      final fresh = await store.load(defaultChannel: 1);
      expect(fresh.newInstall, isTrue);
      expect(fresh.setupDone, isFalse);
      fresh.setupDone = true;
      await store.save(fresh);
      final again = await store.load(defaultChannel: 1);
      expect(again.newInstall, isFalse);
      expect(again.setupDone, isTrue);

      // Existing user from an older version: id saved, no setup flags.
      SharedPreferences.setMockInitialValues({'node_id': 42, 'channel': 3});
      final old = await store.load(defaultChannel: 1);
      expect(old.newInstall, isFalse);
      expect(old.setupDone, isFalse);
      expect(
        setupEntryFor(
          newInstall: old.newInstall,
          setupDone: old.setupDone,
          promptShown: old.setupPromptShown,
        ),
        SetupEntry.prompt,
      );
      old.setupPromptShown = true;
      await store.save(old);
      expect((await store.load(defaultChannel: 1)).setupPromptShown, isTrue);
    });
  });

  group('battery guide', () {
    test('maker detection and steps', () {
      expect(brandOf('samsung'), PhoneBrand.samsung);
      expect(brandOf('Xiaomi'), PhoneBrand.xiaomi);
      expect(brandOf('Redmi'), PhoneBrand.xiaomi);
      expect(brandOf('OnePlus'), PhoneBrand.oneplus);
      expect(brandOf('OPPO'), PhoneBrand.oppo);
      expect(brandOf('realme'), PhoneBrand.oppo);
      expect(brandOf('HUAWEI'), PhoneBrand.huawei);
      expect(brandOf('HONOR'), PhoneBrand.huawei);
      expect(brandOf('Google'), PhoneBrand.pixel);
      expect(brandOf('Motorola'), PhoneBrand.other);
      final s = batteryGuideFor('samsung');
      expect(s.steps.join(), contains('Never sleeping apps'));
      expect(s.steps.join(), contains('Unrestricted'));
      expect(batteryGuideFor('Xiaomi').steps.join(), contains('Autostart'));
      for (final m in [
        'samsung',
        'xiaomi',
        'oneplus',
        'oppo',
        'huawei',
        'google',
        'x',
      ]) {
        expect(batteryGuideFor(m).steps, isNotEmpty);
      }
    });
  });

  group('connection test rows', () {
    const good = ConnSnapshot(
      phoneNet: 'cell',
      lan: TransportStatus.unavailable,
      wifiDirect: TransportStatus.running,
      ble: TransportStatus.running,
      bluetoothOn: true,
      cell: CellState.active,
      cellInfo: CellInfo(
        dataUp: true,
        validated: true,
        sim: true,
        service: true,
        level: 3,
        type: 'LTE',
      ),
      internet: NetProbe(ok: true, ms: 120),
      relayLink: TransportStatus.running,
      relay: RelayProbe(
        ok: true,
        connectMs: 300,
        rttMs: 85,
        room: '1',
        host: 'relay.example',
      ),
      permissions: {
        AppPermission.microphone: PermState.granted,
        AppPermission.nearby: PermState.granted,
        AppPermission.location: PermState.granted,
        AppPermission.notifications: PermState.granted,
      },
      batteryExempt: true,
      serviceRunning: true,
      manufacturer: 'Google',
    );

    test('all good: green rows, relay shows ping and room', () {
      final rows = evaluateConnection(good);
      expect(rows.map((r) => r.id), [
        'wifi',
        'wifiDirect',
        'bluetooth',
        'cell',
        'internet',
        'relay',
        'radio',
        'permissions',
        'battery',
      ]);
      expect(row(rows, 'relay').level, CheckLevel.ok);
      expect(row(rows, 'relay').detail, contains('ping 85 ms'));
      expect(row(rows, 'relay').detail, contains('room 1'));
      expect(row(rows, 'cell').level, CheckLevel.ok);
      expect(row(rows, 'internet').detail, contains('mobile data'));
      expect(row(rows, 'battery').level, CheckLevel.ok);
      expect(row(rows, 'radio').level, CheckLevel.off);
      expect(row(rows, 'wifi').level, CheckLevel.warn);
      expect(overallLevel(rows), CheckLevel.warn);
    });

    test(
      'Offline power save: internet, relay and cell are intentionally off',
      () {
        final rows = evaluateConnection(
          const ConnSnapshot(
            offlineSaver: true,
            cell: CellState.saver,
            ble: TransportStatus.running,
            bluetoothOn: true,
          ),
        );
        for (final id in ['internet', 'relay', 'cell']) {
          expect(row(rows, id).level, CheckLevel.off, reason: id);
          expect(row(rows, id).detail, contains('intentionally'));
        }
      },
    );

    test('relay unreachable with working internet vs. no internet', () {
      final a = evaluateConnection(
        const ConnSnapshot(
          internet: NetProbe(ok: true, ms: 50),
          relay: RelayProbe(ok: false, error: 'timed out after 45s'),
        ),
      );
      expect(row(a, 'relay').level, CheckLevel.fail);
      expect(row(a, 'relay').detail, contains('waking up'));
      final b = evaluateConnection(
        const ConnSnapshot(
          cell: CellState.blocked,
          cellInfo: CellInfo(
            dataUp: true,
            sim: true,
            service: true,
            dataSaver: true,
          ),
          internet: NetProbe(ok: false, error: 'no connection'),
          relay: RelayProbe(ok: false, error: 'failed'),
        ),
      );
      expect(row(b, 'relay').fix, CheckFix.appInfo);
      expect(row(b, 'cell').level, CheckLevel.fail);
      expect(row(b, 'cell').detail, contains('Data Saver'));
      expect(row(b, 'internet').level, CheckLevel.fail);
      expect(overallLevel(b), CheckLevel.fail);
    });

    test('relay off in Settings is grey with a settings fix', () {
      final r = evaluateConnection(const ConnSnapshot(relayConfigured: false));
      expect(row(r, 'relay').level, CheckLevel.off);
      expect(row(r, 'relay').fix, CheckFix.relaySettings);
    });

    test('Bluetooth: permission missing is red, adapter off is yellow', () {
      expect(
        row(
          evaluateConnection(
            const ConnSnapshot(bluetoothPermissionMissing: true),
          ),
          'bluetooth',
        ).fix,
        CheckFix.bluetoothPermission,
      );
      final off = row(
        evaluateConnection(const ConnSnapshot(bluetoothOn: false)),
        'bluetooth',
      );
      expect(off.level, CheckLevel.warn);
      expect(off.fix, CheckFix.bluetoothSettings);
    });

    test(
      'permissions: denied mic is red; "don\'t ask again" opens App info',
      () {
        final r = row(
          evaluateConnection(
            const ConnSnapshot(
              permissions: {
                AppPermission.microphone: PermState.permanentlyDenied,
                AppPermission.notifications: PermState.granted,
              },
            ),
          ),
          'permissions',
        );
        expect(r.level, CheckLevel.fail);
        expect(r.detail, contains('Microphone'));
        expect(r.fix, CheckFix.appInfo);
        final n = row(
          evaluateConnection(
            const ConnSnapshot(
              permissions: {AppPermission.notifications: PermState.denied},
            ),
          ),
          'permissions',
        );
        expect(n.level, CheckLevel.warn);
        expect(n.fix, CheckFix.permissions);
      },
    );

    test('battery: not exempt is red; Samsung adds maker steps; stay '
        'reachable off is grey', () {
      final r = row(
        evaluateConnection(
          const ConnSnapshot(batteryExempt: false, manufacturer: 'samsung'),
        ),
        'battery',
      );
      expect(r.level, CheckLevel.fail);
      expect(r.fix, CheckFix.batteryExemption);
      expect(r.detail, contains('Samsung'));
      final ok = row(
        evaluateConnection(
          const ConnSnapshot(
            batteryExempt: true,
            serviceRunning: true,
            manufacturer: 'samsung',
          ),
        ),
        'battery',
      );
      expect(ok.level, CheckLevel.warn);
      expect(ok.fix, CheckFix.batteryGuide);
      expect(
        row(
          evaluateConnection(
            const ConnSnapshot(batteryExempt: false, stayReachable: false),
          ),
          'battery',
        ).level,
        CheckLevel.off,
      );
    });

    test('radio: paired but not connected is yellow', () {
      final r = row(
        evaluateConnection(
          const ConnSnapshot(radioPaired: true, radioDetail: 'out of range'),
        ),
        'radio',
      );
      expect(r.level, CheckLevel.warn);
      expect(r.fix, CheckFix.radioPairing);
      expect(
        row(
          evaluateConnection(
            const ConnSnapshot(radioPaired: true, radioReady: true),
          ),
          'radio',
        ).level,
        CheckLevel.ok,
      );
    });
  });

  group('probes', () {
    test('relay probe: connect + ping round trip in the right room', () async {
      final server = await RelayServer.bind(address: '127.0.0.1', port: 0);
      try {
        final uri = Uri.parse('ws://127.0.0.1:${server.port}/ws');
        final p = await probeRelay(
          server: uri,
          channelScope: 3,
          connector: IoRelayConnector(),
        );
        expect(p.ok, isTrue, reason: p.error);
        expect(p.rttMs, isNotNull);
        expect(p.room, '3');
        expect(p.host, '127.0.0.1');
        final priv = await probeRelay(
          server: uri,
          channelScope: 0x1a2b0000 | 0xbeef,
          connector: IoRelayConnector(),
        );
        expect(priv.ok, isTrue);
        expect(priv.room, startsWith('p'));
      } finally {
        await server.close();
      }
    });

    test('relay probe: nothing listening -> error', () async {
      final s = await ServerSocket.bind('127.0.0.1', 0);
      final port = s.port;
      await s.close();
      final p = await probeRelay(
        server: Uri.parse('ws://127.0.0.1:$port/ws'),
        channelScope: 1,
        connector: IoRelayConnector(),
        connectTimeout: const Duration(seconds: 3),
      );
      expect(p.ok, isFalse);
      expect(p.error, isNotEmpty);
    });

    test('internet probe: local HTTP 204 ok, closed port fails', () async {
      await HttpOverrides.runWithHttpOverrides(_internetProbe, _RealHttp());
    });
  });

  group('invite', () {
    test('public channel link round trip (app link and web link)', () {
      const inv = Invite(channel: 3, name: 'Bandit');
      expect(inv.appLink, startsWith('walkietalkie://join?'));
      for (final link in [inv.appLink, inv.webLink, inv.shareText()]) {
        final p = Invite.parse(link)!;
        expect(p.channel, 3);
        expect(p.isPrivate, isFalse);
        expect(p.name, 'Bandit');
        expect(p.hasFriend, isFalse);
      }
    });

    test('private channel: passcode inside, but only in the URL fragment for '
        'the web link; never a radio key', () {
      const inv = Invite(channel: 7, passcode: 'blue fox 42&x', name: 'A');
      final web = Uri.parse(inv.webLink);
      expect(web.host, 'github.com');
      expect(web.query, isEmpty);
      expect(web.fragment, startsWith('wt-join?'));
      final p = Invite.parse(inv.webLink)!;
      expect(p.passcode, 'blue fox 42&x');
      expect(Invite.parse(inv.appLink)!.passcode, 'blue fox 42&x');
      expect(inv.appLink.toLowerCase(), isNot(contains('psk')));
    });

    test('friend add rides along and is validated', () {
      final code = friendCode();
      final inv = Invite(channel: 2, friendCode: code);
      final p = Invite.parse(inv.appLink)!;
      expect(p.friendCode, code);
      expect(Invite.parse('walkietalkie://join?v=1&f=nonsense'), isNull);
      final onlyFriend = Invite.parse(Invite(friendCode: code).webLink)!;
      expect(onlyFriend.hasChannel, isFalse);
      expect(onlyFriend.hasFriend, isTrue);
    });

    test('bad channels and junk are rejected; old private QR text is read', () {
      expect(Invite.parse('walkietalkie://join?ch=99'), isNull);
      expect(Invite.parse('walkietalkie://join?ch=0'), isNull);
      expect(Invite.parse('hello'), isNull);
      expect(Invite.parse(''), isNull);
      final old = Invite.parse(
        'Walkie Talkie private channel\nCH 5\nPasscode: secret99',
      )!;
      expect(old.channel, 5);
      expect(old.passcode, 'secret99');
      final copied = Invite.parse(
        'Walkie Talkie private channel: CH 4, passcode: abc123',
      )!;
      expect(copied.channel, 4);
      expect(copied.passcode, 'abc123');
    });
  });

  group('debug log', () {
    test('redaction: passcodes, friend codes, keys, rooms, URL params, '
        'precise locations', () {
      final code = friendCode();
      String r(String s) => redactLog(s, secrets: ['hunter22']);
      expect(r('passcode hunter22 set'), isNot(contains('hunter22')));
      expect(r('scan $code'), 'scan walkie-friend:[redacted]');
      expect(
        r('join walkietalkie://join?v=1&ch=3&p=hunter&n=x'),
        contains('p=[redacted]'),
      );
      expect(r('key: abc'), 'key: [redacted]');
      expect(r('token ${'A' * 44}'), 'token [key]');
      expect(r('id 0123456789abcdef0123'), 'id [hex]');
      expect(r('room p1a2b up'), 'room p**** up');
      expect(r('wss://x/ws?ch=f0123456789abcdef&id=12'), contains('ch=f****'));
      expect(r('at 37.774929, -122.419416 now'), 'at 37.8~, -122.4~ now');
      expect(r('lat=45.12345 lng=-122.98765'), 'lat=45.1~ lng=-123.0~');
      // Ordinary lines survive.
      expect(
        r('internet: running (connected via mobile data)'),
        'internet: running (connected via mobile data)',
      );
      expect(r('v1.8.7 ping 85 ms'), 'v1.8.7 ping 85 ms');
    });

    test('ring buffer keeps the newest lines; file rotates; report has the '
        'header and redacts again', () async {
      final dir = await Directory.systemTemp.createTemp('wtlog');
      try {
        final log = DebugLog(capacity: 5, maxFileBytes: 400);
        await log.attach(dir);
        for (var i = 0; i < 20; i++) {
          log.add('t', 'line $i ${'x' * 20}');
        }
        expect(log.lines.length, 5);
        expect(log.lines.last, contains('line 19'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        log.add('t', 'later passcode-ish sesame99');
        log.secrets = () => ['sesame99'];
        final rep = await log.report(['App version: 1.8.7+25', 'Device: test']);
        expect(rep, startsWith('App version: 1.8.7+25\nDevice: test'));
        expect(rep, contains('line 19'));
        expect(rep, isNot(contains('sesame99')));
        expect(File('${dir.path}/debug.log.1').existsSync(), isTrue);
        await log.close();
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('widgets', () {
    testWidgets('connection test view: rows, colours, fix buttons', (t) async {
      CheckRow? fixed;
      var reran = 0;
      final rows = evaluateConnection(
        const ConnSnapshot(
          bluetoothPermissionMissing: true,
          offlineSaver: true,
          cell: CellState.saver,
        ),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionTestView(
              rows: rows,
              running: false,
              onFix: (r) => fixed = r,
              onRun: () => reran++,
              onSendLog: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('conn-overall')), findsOneWidget);
      expect(find.text('Something needs fixing'), findsOneWidget);
      // Offline rows have no fix button.
      expect(find.byKey(const Key('conn-fix-relay')), findsNothing);
      await t.tap(find.byKey(const Key('conn-fix-bluetooth')));
      expect(fixed?.fix, CheckFix.bluetoothPermission);
      await t.scrollUntilVisible(find.byKey(const Key('conn-run')), 200);
      await t.tap(find.byKey(const Key('conn-run')));
      expect(reran, 1);
      await t.scrollUntilVisible(find.byKey(const Key('conn-send-log')), 200);
      expect(find.byKey(const Key('conn-send-log')), findsOneWidget);
    });

    testWidgets('invite view: private channel QR only after the warning', (
      t,
    ) async {
      var revealed = false;
      Widget view() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: InviteView(
              channelLabel: 'CH 7 (private)',
              withChannel: true,
              withFriend: false,
              isPrivate: true,
              revealed: revealed,
              invite: revealed
                  ? const Invite(channel: 7, passcode: 'secret99')
                  : null,
              onChannel: (_) {},
              onFriend: (_) {},
              onReveal: () => revealed = true,
              onShare: () {},
              onCopy: () {},
              onScan: () {},
            ),
          ),
        ),
      );
      await t.pumpWidget(view());
      expect(find.byKey(const Key('invite-private-warning')), findsOneWidget);
      expect(find.byKey(const Key('invite-qr')), findsNothing);
      await t.tap(find.byKey(const Key('invite-reveal')));
      await t.pumpWidget(view());
      expect(find.byKey(const Key('invite-qr')), findsOneWidget);
      expect(find.text('Contains the passcode.'), findsOneWidget);
    });

    testWidgets('invite confirm dialog returns the choice', (t) async {
      ({bool join, bool friend})? got;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                got = await showDialog(
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
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Invite from Bandit'), findsOneWidget);
      expect(find.text('Join CH 4 (private)'), findsOneWidget);
      await t.tap(find.byKey(const Key('invite-add-friend')));
      await t.pump();
      await t.tap(find.byKey(const Key('invite-accept')));
      await t.pumpAndSettle();
      expect(got, (join: true, friend: false));
    });

    testWidgets('battery guide view: Samsung steps and Allow', (t) async {
      var allowed = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BatteryGuideView(
                guide: batteryGuideFor('samsung'),
                exempt: false,
                onAllow: () => allowed++,
                onVendor: () {},
                onAppInfo: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Never sleeping apps'), findsOneWidget);
      expect(find.text('Open Samsung screen'), findsOneWidget);
      await t.tap(find.byKey(const Key('battery-allow')));
      expect(allowed, 1);
    });

    testWidgets('setup wizard: steps, private passcode check, finish', (
      t,
    ) async {
      final h = FakeHost();
      await t.pumpWidget(MaterialApp(home: SetupWizardPage(host: h)));
      await t.pumpAndSettle();
      expect(find.text('Your call sign'), findsWidgets);
      await t.enterText(find.byKey(const Key('setup-name')), 'Maverick');
      await t.tap(find.byKey(const Key('setup-next')));
      await t.pumpAndSettle();
      expect(find.text('Permissions'), findsWidgets);
      expect(find.byKey(const Key('setup-perm-microphone')), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(const Key('setup-allow-all')), 200);
      await t.tap(find.byKey(const Key('setup-allow-all')));
      await t.pumpAndSettle();
      expect(h.askedAll, isTrue);
      await t.tap(find.byKey(const Key('setup-next')));
      await t.pumpAndSettle();
      expect(h.started, isTrue);
      expect(find.byKey(const Key('setup-net')), findsOneWidget);
      await t.tap(find.byKey(const Key('setup-next')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('battery-allow')), findsOneWidget);
      await t.tap(find.byKey(const Key('setup-next')));
      await t.pumpAndSettle();
      // Channel: private with a too-short passcode is refused.
      await t.tap(find.text('Private'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('setup-passcode')), 'abc');
      await t.tap(find.byKey(const Key('setup-next')));
      await t.pumpAndSettle();
      expect(find.text('Use at least 6 characters'), findsOneWidget);
      await t.enterText(find.byKey(const Key('setup-passcode')), 'abcdef12');
      await t.tap(find.byKey(const Key('setup-next')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('setup-radio')), findsOneWidget);
      await t.tap(find.byKey(const Key('setup-next')));
      await t.pumpAndSettle();
      expect(h.finished, (
        name: 'Maverick',
        channel: 1,
        private: true,
        passcode: 'abcdef12',
      ));
      expect(h.skipped, isFalse);
    });

    testWidgets('setup wizard: skip', (t) async {
      final h = FakeHost();
      await t.pumpWidget(MaterialApp(home: SetupWizardPage(host: h)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('setup-skip')));
      await t.pumpAndSettle();
      expect(h.skipped, isTrue);
      expect(h.finished, isNull);
    });
  });
}

class FakeHost implements SetupHost {
  bool askedAll = false;
  bool started = false;
  bool skipped = false;
  ({String name, int channel, bool private, String? passcode})? finished;
  final perms = {
    AppPermission.microphone: PermState.denied,
    AppPermission.nearby: PermState.denied,
    AppPermission.location: PermState.granted,
    AppPermission.notifications: PermState.permanentlyDenied,
  };

  @override
  String get callSign => 'Professor Mumbles';
  @override
  String get customName => '';
  @override
  void rerollCallSign() {}
  @override
  Future<Map<AppPermission, PermState>> permissionStates() async =>
      Map.of(perms);
  @override
  Future<bool> requestPermission(AppPermission p) async {
    perms[p] = PermState.granted;
    return true;
  }

  @override
  Future<void> requestAllPermissions() async {
    askedAll = true;
    perms.updateAll((k, v) => PermState.granted);
  }

  @override
  Future<void> startLinks() async => started = true;
  @override
  String get internetText => 'Internet: connected via mobile data';
  @override
  CellState get cell => CellState.active;
  @override
  Future<void> refreshNet() async {}
  @override
  Future<void> openSetting(PhoneSetting s) async {}
  @override
  Future<bool?> batteryExempt() async => false;
  @override
  Future<String> manufacturer() async => 'samsung';
  @override
  Future<void> requestBattery() async {}
  @override
  Future<void> openVendorBattery() async {}
  @override
  int get channel => 1;
  @override
  bool isPrivate(int channel) => false;
  @override
  Future<void> finish({
    required String name,
    required int channel,
    required bool private,
    String? passcode,
  }) async {
    finished = (
      name: name,
      channel: channel,
      private: private,
      passcode: passcode,
    );
  }

  @override
  Future<void> skip() async => skipped = true;
  @override
  Future<void> pairRadio(BuildContext context) async {}
  @override
  Future<void> scanInvite(BuildContext context) async {}
}

Future<void> _internetProbe() async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  http.listen((r) {
    r.response.statusCode = 204;
    r.response.close();
  });
  final ok = await probeInternet(
    url: Uri.parse('http://127.0.0.1:${http.port}/generate_204'),
  );
  expect(ok.ok, isTrue);
  expect(ok.ms, isNotNull);
  final port = http.port;
  await http.close(force: true);
  final bad = await probeInternet(
    url: Uri.parse('http://127.0.0.1:$port/x'),
    timeout: const Duration(seconds: 3),
  );
  expect(bad.ok, isFalse);
}

class _RealHttp extends HttpOverrides {}
