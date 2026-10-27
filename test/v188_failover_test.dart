import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_relay/relay_server.dart';
import 'package:walkie_talkie/app/config.dart';
import 'package:walkie_talkie/app/connection_test.dart';
import 'package:walkie_talkie/app/link_settings.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/transports/relay_socket.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

class _Sock implements RelaySocket {
  _Sock(this.host);
  final String host;
  final ctl = StreamController<Object>();
  final sent = <Uint8List>[];
  final sentText = <String>[];
  bool closed = false;
  @override
  String? closeReason;
  @override
  String? network = 'Wi-Fi';
  @override
  Stream<Object> get messages => ctl.stream;
  @override
  void send(Uint8List data) => sent.add(data);
  @override
  void sendText(String text) => sentText.add(text);
  @override
  Future<void> close() async {
    closed = true;
    if (!ctl.isClosed) await ctl.close();
  }

  /// The relay drops the connection.
  void drop() {
    closeReason = 'dropped';
    if (!ctl.isClosed) ctl.close();
  }
}

/// Per-host fake: [down] hosts fail, [failNext] fails that many attempts.
class _Net implements RelayConnector {
  final net = StreamController<String>.broadcast();
  final down = <String>{};
  final failNext = <String, int>{};
  final attempts = <String, List<Duration>>{};
  final sockets = <_Sock>[];

  List<Duration> tries(String host) => attempts[host] ?? const [];
  _Sock? open(String host) {
    for (final s in sockets.reversed) {
      if (s.host == host && !s.closed && !s.ctl.isClosed) return s;
    }
    return null;
  }

  @override
  Stream<String> get networkChanges => net.stream;

  @override
  Future<RelaySocket> connect(Uri uri, {required Duration timeout}) async {
    (attempts[uri.host] ??= []).add(timeout);
    final n = failNext[uri.host] ?? 0;
    if (n > 0) {
      failNext[uri.host] = n - 1;
      throw RelayConnectException('handshake failed');
    }
    if (down.contains(uri.host)) {
      throw RelayConnectException('host unreachable');
    }
    final s = _Sock(uri.host);
    sockets.add(s);
    return s;
  }
}

final home = Uri.parse('wss://home.test/ws');
final backup = Uri.parse('wss://backup.test/ws');

MultiRelayTransport _multi(_Net n, {List<Uri>? uris}) => MultiRelayTransport(
  serverUris: uris ?? [home, backup],
  factory: (u) => RelayTransport(
    serverUri: u,
    connector: n,
    minBackoff: const Duration(milliseconds: 30),
    quickRetryDelay: const Duration(milliseconds: 20),
  ),
);

Future<void> _until(bool Function() ok, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List _frame(int from, int seq) => Frame(
  type: FrameType.audio,
  senderId: from,
  channel: 1,
  seq: seq,
  payload: Uint8List.fromList([1, 2, 3]),
).encode();

void main() {
  group('v1.8.8 default relays', () {
    test('home relay (Synology / Tailscale Funnel) first, Render backup', () {
      final l = MultiRelayTransport.parseList(AppConfig.defaultRelayUrl);
      expect(l.map((u) => u.toString()), [
        'wss://walkie-relay.tail1700cf.ts.net/ws',
        'wss://brion-walkie-relay.onrender.com/ws',
      ]);
    });

    test('empty / old Render-only setting -> default; custom kept', () {
      List<String> uris(String? saved) => [
        for (final u in WalkieController.relayUrisFor(
          AppSettings(nodeId: 1, channel: 1, relayUrl: saved),
        ))
          u.host,
      ];
      const both = [
        'walkie-relay.tail1700cf.ts.net',
        'brion-walkie-relay.onrender.com',
      ];
      expect(uris(null), both);
      expect(uris(''), both);
      expect(uris(' wss://brion-walkie-relay.onrender.com/ws '), both);
      expect(uris('wss://my.relay/ws'), ['my.relay']);
      expect(uris('wss://a.x/ws, wss://brion-walkie-relay.onrender.com/ws'), [
        'a.x',
        'brion-walkie-relay.onrender.com',
      ]);
      expect(uris('off'), isEmpty);
    });

    test('roles and labels', () {
      expect(MultiRelayTransport.roleAt(0, 2), RelayRole.home);
      expect(MultiRelayTransport.roleAt(1, 2), RelayRole.backup);
      expect(MultiRelayTransport.labelFor(RelayRole.home), 'Home relay');
      expect(MultiRelayTransport.labelFor(RelayRole.backup), 'Backup relay');
      expect(MultiRelayTransport.labelFor(RelayRole.home, count: 1), 'Relay');
    });
  });

  group('v1.8.8 failover', () {
    test('home: short timeout + quick retry; backup keeps the long one', () {
      final n = _Net();
      final m = _multi(n);
      expect(
        m.relays[0].connectTimeout,
        MultiRelayTransport.homeConnectTimeout,
      );
      expect(
        m.relays[0].connectTimeout.inMilliseconds,
        lessThanOrEqualTo(5000),
      );
      expect(m.relays[0].quickRetry, isTrue);
      expect(m.relays[1].connectTimeout, const Duration(seconds: 75));
      expect(m.relays[1].quickRetry, isFalse);
      // One relay: unchanged (it may be a sleeping Render one).
      final one = _multi(n, uris: [home]);
      expect(one.relays.single.connectTimeout, const Duration(seconds: 75));
      expect(one.relays.single.quickRetry, isFalse);
    });

    test(
      'home handshake fails once -> second try right away, no backoff',
      () async {
        final n = _Net()..failNext['home.test'] = 1;
        final m = _multi(n);
        await m.start(localNodeId: 1, channel: 1);
        await _until(() => m.activeRole == RelayRole.home);
        expect(n.tries('home.test').length, 2);
        expect(m.summary.text, contains('Home relay'));
        await m.dispose();
      },
    );

    test(
      'home down -> backup carries it, home retried with longer cap',
      () async {
        final n = _Net()..down.add('home.test');
        final m = _multi(n);
        final roles = <RelayRole?>[];
        m.onRoleChange = (_, to) => roles.add(to);
        await m.start(localNodeId: 1, channel: 1);
        await _until(() => m.activeRole == RelayRole.backup);
        expect(m.activeLabel, 'Backup relay');
        expect(m.summary.status, TransportStatus.running);
        expect(m.summary.text, contains('Backup relay; home relay'));
        expect(m.relays.first.maxBackoff, m.homeRetryWhileOnBackup);
        // v1.9.8: home recovery is re-checked within seconds (was 2.5 min).
        expect(
          m.homeRetryWhileOnBackup,
          allOf(
            greaterThanOrEqualTo(const Duration(seconds: 5)),
            lessThanOrEqualTo(const Duration(seconds: 30)),
          ),
        );
        // Quick retry happened (2 attempts), then normal backoff.
        await _until(() => n.tries('home.test').length >= 3);

        // Home is back: next retry gets it and it becomes the one in use.
        n.down.remove('home.test');
        await _until(() => m.activeRole == RelayRole.home);
        expect(m.summary.text, contains('Home relay + backup'));
        expect(roles, containsAllInOrder([RelayRole.backup, RelayRole.home]));
        await m.dispose();
      },
    );

    test('nothing up: home retry cap back to the normal (short) one', () async {
      final n = _Net()..down.addAll(['home.test', 'backup.test']);
      final m = _multi(n);
      await m.start(localNodeId: 1, channel: 1);
      await _until(() => m.status == TransportStatus.error);
      expect(m.relays.first.maxBackoff, m.homeRetryAlone);
      expect(m.activeRole, isNull);
      expect(m.summary.text, startsWith('Internet: offline'));
      await m.dispose();
    });

    test(
      'backup drops while home is waiting -> home retried right away',
      () async {
        final n = _Net()..down.add('home.test');
        // Home's next retry is far away (10 s backoff).
        final m = MultiRelayTransport(
          serverUris: [home, backup],
          factory: (u) => RelayTransport(
            serverUri: u,
            connector: n,
            minBackoff: u == home
                ? const Duration(seconds: 10)
                : const Duration(milliseconds: 30),
            quickRetryDelay: const Duration(milliseconds: 20),
          ),
        );
        await m.start(localNodeId: 1, channel: 1);
        await _until(() => m.activeRole == RelayRole.backup);
        await _until(() => n.tries('home.test').length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(m.relays.first.retryIn, const Duration(seconds: 10));
        n.down.remove('home.test');
        final before = n.tries('home.test').length;
        n.open('backup.test')!.drop();
        await _until(() => n.tries('home.test').length > before, ms: 1000);
        await _until(() => m.activeRole == RelayRole.home);
        await m.dispose();
      },
    );

    test('network change: home tried again at once', () async {
      final n = _Net()..down.add('home.test');
      final m = _multi(n);
      await m.start(localNodeId: 1, channel: 1);
      await _until(() => m.activeRole == RelayRole.backup);
      n.down.remove('home.test');
      n.net.add('mobile data');
      await _until(() => m.activeRole == RelayRole.home, ms: 1000);
      await m.dispose();
    });

    test(
      'wake (app on screen): reconnects home now, pings what is up',
      () async {
        final n = _Net()..down.add('home.test');
        final m = _multi(n);
        await m.start(localNodeId: 1, channel: 1);
        await _until(() => m.activeRole == RelayRole.backup);
        final b = n.open('backup.test')!;
        final pings = b.sentText.length;
        n.down.remove('home.test');
        await m.wake();
        await _until(() => m.activeRole == RelayRole.home, ms: 500);
        expect(b.sentText.length, pings + 1);
        expect(b.sentText.last, 'ping');
        await m.dispose();
      },
    );

    test(
      'frames go to every connected relay (keeps the room together)',
      () async {
        final n = _Net();
        final m = _multi(n);
        await m.start(localNodeId: 1, channel: 1);
        await _until(
          () => m.relays.every((r) => r.status == TransportStatus.running),
        );
        await m.send(_frame(1, 1));
        expect(n.open('home.test')!.sent, hasLength(1));
        expect(n.open('backup.test')!.sent, hasLength(1));
        expect(m.debugInfo, contains('home home:up'));
        expect(m.debugInfo, contains('backup backup:up'));
        await m.dispose();
      },
    );
  });

  test(
    'real relays: a phone that only reaches the backup still hears a phone '
    'on home + backup, and home-only phones hear it through the backup',
    () async {
      final homeSrv = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final backupSrv = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final h = Uri.parse('ws://127.0.0.1:${homeSrv.port}/ws');
      final b = Uri.parse('ws://127.0.0.1:${backupSrv.port}/ws');
      // Phone B cannot reach home (as if *.ts.net were blocked there).
      final dead = Uri.parse('ws://127.0.0.1:1/ws');
      final a = MultiRelayTransport(serverUris: [h, b]);
      final bb = MultiRelayTransport(serverUris: [dead, b]);
      await a.start(localNodeId: 0xA, channel: 7);
      await bb.start(localNodeId: 0xB, channel: 7);
      await _until(
        () =>
            a.relays.every((r) => r.status == TransportStatus.running) &&
            bb.activeRole == RelayRole.backup,
        ms: 8000,
      );
      expect(a.activeLabel, 'Home relay');
      expect(bb.activeLabel, 'Backup relay');
      final atB = <InboundFrame>[];
      final atA = <InboundFrame>[];
      final s1 = bb.frames.listen(atB.add);
      final s2 = a.frames.listen(atA.add);
      await a.send(_frame(0xA, 1));
      await bb.send(_frame(0xB, 1));
      await _until(() => atB.isNotEmpty && atA.isNotEmpty, ms: 3000);
      expect(atB.first.frame.senderId, 0xA);
      expect(atA.first.frame.senderId, 0xB);
      await s1.cancel();
      await s2.cancel();
      await a.dispose();
      await bb.dispose();
      await homeSrv.close();
      await backupSrv.close();
    },
  );

  group('v1.8.8 UI text', () {
    test('internet sheet names the relay in use', () {
      final i = describeLink(
        TransportKind.internet,
        TransportStatus.running,
        relayInUse: 'Home relay',
      );
      expect(i.state, 'Connected · Home relay');
      expect(i.help, contains('Synology'));
      final b = describeLink(
        TransportKind.internet,
        TransportStatus.running,
        relayInUse: 'Backup relay',
      );
      expect(b.state, 'Connected · Backup relay');
      expect(b.help, contains('keeps trying'));
      expect(
        describeLink(TransportKind.internet, TransportStatus.running).state,
        'Connected',
      );
    });

    RelayProbe p(bool ok, String label, String host) => RelayProbe(
      ok: ok,
      connectMs: ok ? 120 : null,
      rttMs: ok ? 40 : null,
      room: '1',
      host: host,
      error: ok ? null : 'timed out after 10s',
      label: label,
    );

    CheckRow row(List<RelayProbe> ps, String? inUse) => evaluateConnection(
      ConnSnapshot(
        relayLink: inUse == null
            ? TransportStatus.error
            : TransportStatus.running,
        relay: ps.first,
        relayProbes: ps,
        relayInUse: inUse,
        internet: const NetProbe(ok: true),
      ),
    ).firstWhere((r) => r.id == 'relay');

    test('connection test: both relays OK, shows the one in use', () {
      final r = row([
        p(true, 'Home relay', 'walkie-relay.tail1700cf.ts.net'),
        p(true, 'Backup relay', 'brion-walkie-relay.onrender.com'),
      ], 'Home relay');
      expect(r.level, CheckLevel.ok);
      expect(
        r.detail,
        contains('Home relay (walkie-relay.tail1700cf.ts.net): OK'),
      );
      expect(r.detail, contains('Backup relay'));
      expect(r.detail, contains('In use: Home relay.'));
    });

    test('connection test: home down, backup OK -> warning, still works', () {
      final r = row([
        p(false, 'Home relay', 'walkie-relay.tail1700cf.ts.net'),
        p(true, 'Backup relay', 'brion-walkie-relay.onrender.com'),
      ], 'Backup relay');
      expect(r.level, CheckLevel.warn);
      expect(r.detail, contains('Home relay'));
      expect(r.detail, contains('not reachable'));
      expect(r.detail, contains('In use: Backup relay.'));
    });

    test('connection test: neither relay -> fail', () {
      final r = row([
        p(false, 'Home relay', 'h'),
        p(false, 'Backup relay', 'b'),
      ], null);
      expect(r.level, CheckLevel.fail);
      expect(r.detail, startsWith('Cannot reach any relay'));
    });
  });
}
