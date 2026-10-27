// v2.0.0: adaptive probing. Idle (background, nothing for a minute) relaxes
// checks; anything real snaps them back at once; a link that actually
// drops still fails over in under 1.5 s, idle or not; urgent traffic goes
// on every path.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/config.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/link_policy.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

import 'messaging_fakes.dart';
import 'v198_failover_test.dart' show LatencyLink, hello, flush, me, bob;

class IdleLink extends LatencyLink {
  IdleLink(super.kind, super.clock, {super.latency});
  final idleCalls = <bool>[];
  bool failSend = false;

  @override
  void setIdle(bool idle) => idleCalls.add(idle);

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    if (failSend) throw StateError('socket closed');
    return super.send(frame, peerIds: peerIds);
  }
}

Frame data(int from, int seq) => Frame(
  type: FrameType.data,
  senderId: from,
  channel: 1,
  seq: seq,
  payload: Uint8List.fromList([1, 2, 3]),
);

Frame audio(int from, int seq) => Frame(
  type: FrameType.audio,
  senderId: from,
  channel: 1,
  seq: seq,
  payload: Uint8List.fromList([9]),
);

Frame control(int from, int seq, ControlMessage m) =>
    Frame.control(senderId: from, channel: 1, seq: seq, message: m);

void main() {
  late FakeClock clock;
  late IdleLink net, lan;
  late TransportManager m;

  Future<void> setUpManager({
    Duration helloEvery = const Duration(hours: 1),
  }) async {
    clock = FakeClock();
    net = IdleLink(
      TransportKind.internet,
      clock,
      latency: const Duration(milliseconds: 80),
    );
    lan = IdleLink(
      TransportKind.lan,
      clock,
      latency: const Duration(milliseconds: 20),
    );
    m = TransportManager(
      transports: [net, lan],
      localNodeId: me,
      localName: 'me',
      clock: clock.call,
      helloInterval: helloEvery,
    );
    await m.start();
    // Bob is on both links, pings answered once.
    net.deliver(hello(bob, 1));
    lan.deliver(hello(bob, 2));
    await m.sendPings();
    net.answerPings(bob, seq: 100);
    lan.answerPings(bob, seq: 200);
    net.sent.clear();
    lan.sent.clear();
  }

  tearDown(() => m.dispose());

  group('idle stretch', () {
    test('background with nothing going on: checks every 15 s (30 s '
        'Balanced), links told, hellos and beacons slow', () async {
      await setUpManager(helloEvery: const Duration(seconds: 1));
      expect(m.activity, ProbeActivity.foreground);
      expect(m.probeInterval, const Duration(seconds: 3));
      m.setActivity(ProbeActivity.idle);
      expect(m.activity, ProbeActivity.idle);
      expect(m.probeInterval, const Duration(seconds: 15));
      expect(net.plans.last.$1, const Duration(seconds: 15));
      expect(net.idleCalls.last, isTrue);
      expect(lan.idleCalls.last, isTrue);
      expect(m.currentHelloInterval, const Duration(seconds: 5));
      m.setSpeed(ConnectionSpeed.balanced);
      expect(m.probeInterval, const Duration(seconds: 30));
      expect(m.currentHelloInterval, const Duration(milliseconds: 7500));
      expect(
        LinkPolicy.peerPingInterval(
          ConnectionSpeed.maxSpeed,
          ProbeActivity.idle,
        ),
        const Duration(seconds: 10),
      );
      expect(
        LinkPolicy.peerPingInterval(
          ConnectionSpeed.balanced,
          ProbeActivity.idle,
        ),
        const Duration(seconds: 15),
      );
    });

    test('the hello tells others our slow interval so they do not call '
        'us gone', () async {
      await setUpManager(helloEvery: const Duration(seconds: 1));
      m.setActivity(ProbeActivity.idle);
      net.sent.clear();
      await m.sendHello();
      final h = net.framesOf(FrameType.control).last.control!;
      expect(h.kind, ControlKind.hello);
      expect(h.interval, 5000);
    });

    test('a background phone that just had a conversation keeps the '
        'screen-on rate until it has been quiet for 60 s', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      expect(m.activity, ProbeActivity.idle);
      net.deliver(data(bob, 10)); // a chat message arrives
      expect(m.activity, ProbeActivity.foreground);
      expect(m.probeInterval, const Duration(seconds: 3));
      clock.advance(const Duration(seconds: 59));
      expect(m.activity, ProbeActivity.foreground);
      clock.advance(const Duration(seconds: 2));
      expect(m.activity, ProbeActivity.idle);
      expect(m.probeInterval, const Duration(seconds: 15));
    });

    test('hellos, pings, pongs and beacons never count as activity (busy '
        'phones send them every second)', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      for (var i = 0; i < 5; i++) {
        net.deliver(hello(bob, 300 + i));
        net.deliver(
          control(
            bob,
            400 + i,
            ControlMessage(ControlKind.ping, to: me, time: i),
          ),
        );
      }
      clock.advance(const Duration(seconds: 70));
      expect(m.activity, ProbeActivity.idle);
    });

    test('a phone we have not heard yet gets our hello at once while '
        'idle', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      net.sent.clear();
      net.deliver(hello(carolId, 1));
      await flush();
      expect(
        net.framesOf(FrameType.control).map((f) => f.control!.kind),
        contains(ControlKind.hello),
      );
    });
  });

  group('instant snap-back', () {
    Future<void> expectSnapped(Future<void> Function() trigger) async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      expect(m.activity, ProbeActivity.idle);
      net.idleCalls.clear();
      await trigger();
      await flush();
      expect(m.activity, isNot(ProbeActivity.idle));
      expect(m.probeInterval, lessThanOrEqualTo(const Duration(seconds: 3)));
      expect(net.plans.last.$1, lessThanOrEqualTo(const Duration(seconds: 3)));
      expect(net.idleCalls, contains(false));
      expect(lan.idleCalls, contains(false));
    }

    test('screen on / app in front', () async {
      await expectSnapped(() async => m.setActivity(ProbeActivity.foreground));
    });

    test('push-to-talk', () async {
      await expectSnapped(() => m.setTalking(true));
      expect(m.activity, ProbeActivity.active);
      expect(m.probeInterval, const Duration(seconds: 1));
    });

    test('incoming audio', () async {
      await expectSnapped(() async => net.deliver(audio(bob, 5000)));
    });

    test('incoming talk start', () async {
      await expectSnapped(
        () async => net.deliver(
          control(bob, 50, const ControlMessage(ControlKind.talkStart)),
        ),
      );
      expect(m.activity, ProbeActivity.active);
    });

    test('incoming chat / voice clip data', () async {
      await expectSnapped(() async => net.deliver(data(bob, 60)));
    });

    test('incoming urgent ring', () async {
      await expectSnapped(
        () async => net.deliver(
          control(
            bob,
            70,
            const ControlMessage(ControlKind.ring, id: 7, to: me, urgent: true),
          ),
        ),
      );
      expect(m.activity, ProbeActivity.active);
    });

    test('a ring or SOS we send', () async {
      await expectSnapped(
        () => m.sendControlTo(
          bob,
          const ControlMessage(ControlKind.ring, id: 1, to: bob),
        ),
      );
      expect(m.activity, ProbeActivity.active);
    });

    test('a chat we send', () async {
      await expectSnapped(() => m.sendData(bob, Uint8List.fromList([1, 2])));
    });

    test('a network change', () async {
      await expectSnapped(() => m.onNetworkChanged());
      expect(m.activity, ProbeActivity.active);
      expect(m.bursts, 1);
    });

    test('friend talk reported by the app', () async {
      await expectSnapped(() async => m.noteTraffic());
    });

    test('going back to idle after the burst / quiet minute', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      await m.onNetworkChanged();
      expect(m.activity, ProbeActivity.active);
      clock.advance(LinkPolicy.burstFor + const Duration(seconds: 1));
      expect(m.activity, ProbeActivity.idle);
    });
  });

  group('failover stays fast while idle', () {
    test('PTT while idle pings every link now; a dead link is out in '
        'under 1.5 s and Wi-Fi carries the audio', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      expect(m.routeTo(bob), [TransportKind.internet]);
      net.dead = true;
      final t0 = clock.now;
      await m.setTalking(true);
      await flush();
      // Pings went out on both links the moment PTT was pressed.
      expect(
        net
            .framesOf(FrameType.control)
            .where((f) => f.control!.kind == ControlKind.ping),
        isNotEmpty,
      );
      lan.answerPings(bob, seq: 900);
      clock.advance(
        LinkPolicy.missDeadline(m.peer(bob)!.rtt[TransportKind.internet]) +
            const Duration(milliseconds: 1),
      );
      m.checkMisses();
      expect(
        clock.now.difference(t0),
        lessThan(const Duration(milliseconds: 1500)),
      );
      expect(m.isDegraded(m.peer(bob)!, TransportKind.internet), isTrue);
      expect(m.routeTo(bob).first, TransportKind.lan);
      await m.sendAudio(Uint8List.fromList([1]));
      expect(lan.framesOf(FrameType.audio), hasLength(1));
    });

    test('a ping missed while idle (no one touched the app) moves the '
        'traffic and starts a burst of fast probes', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      net.dead = true;
      await m.sendPings(); // the idle check
      clock.advance(const Duration(milliseconds: 1501));
      m.checkMisses();
      expect(m.degradedEvents, greaterThanOrEqualTo(1));
      expect(m.bursts, 1);
      expect(m.activity, ProbeActivity.active);
      expect(m.probeInterval, const Duration(seconds: 1));
      expect(net.plans.last.$1, const Duration(seconds: 1));
    });

    test('a send that fails while idle starts a burst and pings every '
        'link at once', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      net.failSend = true;
      lan.sent.clear();
      await m.sendData(bob, Uint8List.fromList([4]));
      await flush();
      expect(m.bursts, 1);
      expect(m.activity, ProbeActivity.active);
      expect(
        lan
            .framesOf(FrameType.control)
            .where((f) => f.control!.kind == ControlKind.ping),
        isNotEmpty,
      );
    });

    test('bursts are limited (a network that stays down does not keep the '
        'phone at full speed): one per cool-down', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      net.failSend = true;
      await m.sendHello(); // presence: not real traffic, but it failed
      expect(m.bursts, 1);
      clock.advance(LinkPolicy.burstFor + const Duration(seconds: 1));
      expect(m.activity, ProbeActivity.idle);
      await m.sendHello();
      expect(m.bursts, 1); // inside the cool-down
      expect(m.activity, ProbeActivity.idle);
      clock.advance(LinkPolicy.burstCooldown);
      await m.sendHello();
      expect(m.bursts, 2);
    });
  });

  group('urgent bypass', () {
    test('an urgent ring while idle goes on every path at once and holds '
        'full speed for a minute', () async {
      await setUpManager();
      m.setActivity(ProbeActivity.idle);
      await m.sendControlTo(
        bob,
        const ControlMessage(ControlKind.ring, id: 3, to: bob, urgent: true),
      );
      expect(m.urgentSends, 1);
      expect(
        net
            .framesOf(FrameType.control)
            .where((f) => f.control!.kind == ControlKind.ring),
        hasLength(1),
      );
      expect(
        lan
            .framesOf(FrameType.control)
            .where((f) => f.control!.kind == ControlKind.ring),
        hasLength(1),
      );
      expect(m.activity, ProbeActivity.active);
      clock.advance(const Duration(seconds: 61));
      // After the minute of full speed it relaxes again (no other traffic
      // after the ring's first 60 s).
      expect(m.activity, ProbeActivity.idle);
    });
  });

  group('more than one backup relay', () {
    test('labels: Home relay, Backup relay, Backup relay 2', () {
      expect(MultiRelayTransport.labelAt(0, 3), 'Home relay');
      expect(MultiRelayTransport.labelAt(1, 3), 'Backup relay');
      expect(MultiRelayTransport.labelAt(2, 3), 'Backup relay 2');
      expect(MultiRelayTransport.labelAt(1, 2), 'Backup relay');
      expect(MultiRelayTransport.labelAt(0, 1), 'Relay');
    });

    test('the default list is home + backup + backup 2, and old saved '
        'defaults get it', () {
      final uris = [
        for (final u in [
          AppConfig.homeRelayUrl,
          AppConfig.backupRelayUrl,
          AppConfig.backupRelay2Url,
        ])
          Uri.parse(u),
      ];
      expect(
        WalkieController.relayUrisFor(AppSettings(nodeId: 1, channel: 1)),
        uris,
      );
      for (final saved in [
        AppConfig.backupRelayUrl,
        '${AppConfig.homeRelayUrl}, ${AppConfig.backupRelayUrl}',
      ]) {
        expect(
          WalkieController.relayUrisFor(
            AppSettings(nodeId: 1, channel: 1, relayUrl: saved),
          ),
          uris,
        );
      }
      // A custom list is used as typed.
      expect(
        WalkieController.relayUrisFor(
          AppSettings(nodeId: 1, channel: 1, relayUrl: 'wss://x.example/ws'),
        ),
        [Uri.parse('wss://x.example/ws')],
      );
      expect(AppConfig.backupRelay2Url, contains('brion-walkie-relay-2'));
    });
  });
}

const carolId = 0x3333;
