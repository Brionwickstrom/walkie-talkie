// v1.9.8: connection resilience. Every link at once, the fastest working
// one first, failing links detected within about a second and their
// traffic moved, urgent rings and SOS on every path, reconnects on network
// changes, and probe intervals per battery mode.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/link_policy.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/transports/relay_socket.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart';

const me = 0x1111, bob = 0x2222, carol = 0x3333;

/// A fake link with a controllable round trip and failure: it answers our
/// pings for [peer] after [latency] (on the manager's fake clock) unless
/// [dead].
class LatencyLink extends FakeTransport {
  LatencyLink(super.kind, this.clock, {this.latency = Duration.zero});
  final FakeClock clock;
  Duration latency;
  bool dead = false;
  int kicks = 0;
  final plans = <(Duration, Duration)>[];

  @override
  void kickDiscovery() => kicks++;

  @override
  void setProbePlan({
    required Duration probe,
    required Duration reconnectCap,
  }) => plans.add((probe, reconnectCap));

  /// Answer every ping in [sent] (our pings to [from]) as [from] would,
  /// [latency] later.
  void answerPings(int from, {int seq = 1000}) {
    if (dead) return;
    final pings = [
      for (final s in sent)
        if (s.frame.type == FrameType.control &&
            s.frame.control?.kind == ControlKind.ping &&
            s.frame.control?.to == from)
          s.frame.control!,
    ];
    sent.removeWhere(
      (s) =>
          s.frame.type == FrameType.control &&
          s.frame.control?.kind == ControlKind.ping,
    );
    clock.advance(latency);
    var i = 0;
    for (final p in pings) {
      deliver(
        Frame.control(
          senderId: from,
          channel: 1,
          seq: seq + i++,
          message: ControlMessage(ControlKind.pong, to: me, time: p.time),
        ),
      );
    }
  }

  List<Frame> framesOf(FrameType t) => [
    for (final s in sent)
      if (s.frame.type == t) s.frame,
  ];
}

class FakeRadio implements RadioLink {
  final sent = <Uint8List>[];
  @override
  int? queueFree;
  final _packets = StreamController<MeshPacketPb>.broadcast(sync: true);
  final _readyCtl = StreamController<bool>.broadcast(sync: true);
  @override
  bool get ready => true;
  @override
  Stream<bool> get readyChanges => _readyCtl.stream;
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;
  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
  }) async => sent.add(payload);
}

Frame hello(int from, int seq, {int channel = 1}) => Frame.control(
  senderId: from,
  channel: channel,
  seq: seq,
  message: const ControlMessage(ControlKind.hello),
);

Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> until(bool Function() ok, {int ms = 4000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// ------------------------------------------------------- relay fakes

class Sock implements RelaySocket {
  Sock(this.host, {this.answerPings = true});
  final String host;
  bool answerPings;
  final ctl = StreamController<Object>();
  final sent = <Uint8List>[];
  final pings = <DateTime>[];
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
  void sendText(String text) {
    if (text != 'ping') return;
    pings.add(DateTime.now());
    if (answerPings && !ctl.isClosed) {
      scheduleMicrotask(() {
        if (!ctl.isClosed) ctl.add('pong');
      });
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!ctl.isClosed) await ctl.close();
  }
}

/// Per-host connect delay; null delay = never connects (a sleeping relay).
class Net implements RelayConnector {
  final net = StreamController<String>.broadcast();
  final delay = <String, Duration?>{};
  final sockets = <Sock>[];
  bool answerPings = true;

  Sock? open(String host) {
    for (final s in sockets.reversed) {
      if (s.host == host && !s.closed) return s;
    }
    return null;
  }

  @override
  Stream<String> get networkChanges => net.stream;

  @override
  Future<RelaySocket> connect(Uri uri, {required Duration timeout}) async {
    final d = delay[uri.host] ?? Duration.zero;
    if (!delay.containsKey(uri.host) || d > Duration.zero) {
      await Future<void>.delayed(d);
    }
    if (delay.containsKey(uri.host) && delay[uri.host] == null) {
      await Completer<void>().future.timeout(timeout);
    }
    final s = Sock(uri.host, answerPings: answerPings);
    sockets.add(s);
    return s;
  }
}

final home = Uri.parse('wss://home.test/ws');
final backup = Uri.parse('wss://backup.test/ws');

void main() {
  group('ranking (LinkPolicy.rank)', () {
    Duration? none(TransportKind _) => null;

    test('tiers: internet, Wi-Fi, Bluetooth / Wi-Fi Direct, LoRa last', () {
      expect(
        LinkPolicy.rank([
          TransportKind.lora,
          TransportKind.ble,
          TransportKind.lan,
          TransportKind.internet,
          TransportKind.wifiDirect,
        ], rtt: none),
        [
          TransportKind.internet,
          TransportKind.lan,
          TransportKind.wifiDirect,
          TransportKind.ble,
          TransportKind.lora,
        ],
      );
    });

    test('inside a tier: by measured round trip', () {
      final r = {
        TransportKind.wifiDirect: const Duration(milliseconds: 90),
        TransportKind.ble: const Duration(milliseconds: 35),
      };
      expect(
        LinkPolicy.rank([
          TransportKind.wifiDirect,
          TransportKind.ble,
        ], rtt: (k) => r[k]),
        [TransportKind.ble, TransportKind.wifiDirect],
      );
    });

    test('a clearly faster lower tier link wins; a slightly faster one '
        'does not; LoRa never moves up', () {
      Map<TransportKind, Duration> ms(int net, int lan) => {
        TransportKind.internet: Duration(milliseconds: net),
        TransportKind.lan: Duration(milliseconds: lan),
        TransportKind.lora: const Duration(milliseconds: 1),
      };
      final kinds = [
        TransportKind.internet,
        TransportKind.lan,
        TransportKind.lora,
      ];
      // Same Wi-Fi: 8 ms vs 120 ms through a relay.
      var r = ms(120, 8);
      expect(LinkPolicy.rank(kinds, rtt: (k) => r[k]).first, TransportKind.lan);
      // 30 vs 50 ms: only 20 ms faster, the tier order stays.
      r = ms(50, 30);
      expect(
        LinkPolicy.rank(kinds, rtt: (k) => r[k]).first,
        TransportKind.internet,
      );
      expect(LinkPolicy.rank(kinds, rtt: (k) => r[k]).last, TransportKind.lora);
    });

    test('failing links go last', () {
      expect(
        LinkPolicy.rank(
          [TransportKind.internet, TransportKind.lan, TransportKind.ble],
          rtt: none,
          degraded: (k) => k == TransportKind.internet,
        ),
        [TransportKind.lan, TransportKind.ble, TransportKind.internet],
      );
    });
  });

  group('manager failover', () {
    late FakeClock clock;
    late LatencyLink net, lan, ble;
    late TransportManager m;

    setUp(() async {
      clock = FakeClock();
      net = LatencyLink(
        TransportKind.internet,
        clock,
        latency: const Duration(milliseconds: 80),
      );
      lan = LatencyLink(
        TransportKind.lan,
        clock,
        latency: const Duration(milliseconds: 60),
      );
      ble = LatencyLink(
        TransportKind.ble,
        clock,
        latency: const Duration(milliseconds: 70),
      );
      m = TransportManager(
        transports: [net, lan, ble],
        localNodeId: me,
        localName: 'me',
        clock: clock.call,
        helloInterval: const Duration(hours: 1), // driven by hand
      );
      await m.start();
      for (final t in [net, lan, ble]) {
        t.sent.clear();
      }
    });

    tearDown(() => m.dispose());

    /// Bob heard on [links], pings answered once on each.
    Future<void> bobOn(List<LatencyLink> links) async {
      var seq = 1;
      for (final l in links) {
        l.deliver(hello(bob, seq++));
      }
      await m.sendPings();
      for (final l in links) {
        l.answerPings(bob, seq: 100 * seq++);
      }
      for (final l in links) {
        l.sent.clear();
      }
    }

    test('a link that comes up is used at once (first success wins, no '
        'waiting for a timer)', () async {
      net.status = TransportStatus.stopped;
      ble.deliver(hello(bob, 1));
      expect(m.routeTo(bob), [TransportKind.ble]);
      // The relay connects: our hello goes out on it right away (the hello
      // timer is an hour in this test) ...
      net.status = TransportStatus.running;
      await flush();
      expect(
        net.framesOf(FrameType.control).map((f) => f.control!.kind),
        contains(ControlKind.hello),
      );
      // ... and the first frame Bob sends on it switches the route.
      net.deliver(hello(bob, 2));
      expect(m.routeTo(bob), [TransportKind.internet]);
      await m.sendAudio(Uint8List.fromList([1]));
      expect(net.framesOf(FrameType.audio), hasLength(1));
      expect(ble.framesOf(FrameType.audio), isEmpty);
    });

    test('miss thresholds', () {
      expect(LinkPolicy.missDeadline(null), const Duration(milliseconds: 1500));
      expect(
        LinkPolicy.missDeadline(const Duration(milliseconds: 40)),
        const Duration(milliseconds: 600),
      );
      expect(
        LinkPolicy.missDeadline(const Duration(milliseconds: 300)),
        const Duration(milliseconds: 1100),
      );
      expect(
        LinkPolicy.missDeadline(const Duration(seconds: 2)),
        const Duration(milliseconds: 1500),
      );
      expect(LinkPolicy.relayPongDeadline(null), const Duration(seconds: 3));
      expect(
        LinkPolicy.relayPongDeadline(const Duration(milliseconds: 100)),
        const Duration(milliseconds: 1500),
      );
      expect(
        LinkPolicy.relayPongDeadline(const Duration(milliseconds: 800)),
        const Duration(milliseconds: 3700),
      );
      expect(LinkPolicy.relayMissesForReconnect, 2);
    });

    test('one missed ping marks the link failing; traffic moves at once and '
        'comes back after the next answer', () async {
      await bobOn([net, lan]);
      expect(m.routeTo(bob), [TransportKind.internet]);
      final rtt = m.peer(bob)!.rtt[TransportKind.internet]!;
      expect(rtt, const Duration(milliseconds: 80));
      net.dead = true;
      await m.sendPings();
      // Just inside the deadline: still fine.
      clock.advance(LinkPolicy.missDeadline(rtt));
      m.checkMisses();
      expect(m.isDegraded(m.peer(bob)!, TransportKind.internet), isFalse);
      expect(m.routeTo(bob), [TransportKind.internet]);
      // 1 ms later: a miss. Wi-Fi carries it now (internet kept as a
      // second copy so it can recover).
      clock.advance(const Duration(milliseconds: 1));
      m.checkMisses();
      expect(m.isDegraded(m.peer(bob)!, TransportKind.internet), isTrue);
      expect(m.degradedEvents, 1);
      expect(m.routeTo(bob).first, TransportKind.lan);
      expect(m.routeTo(bob), contains(TransportKind.internet));
      // The internet answers again: back to it alone.
      net.dead = false;
      await m.sendPings();
      net.answerPings(bob, seq: 5000);
      lan.answerPings(bob, seq: 6000);
      expect(m.isDegraded(m.peer(bob)!, TransportKind.internet), isFalse);
      expect(m.routeTo(bob), [TransportKind.internet]);
    });

    test('chat sent on a link that then fails is sent again on the next '
        'best one (same frame, receivers drop the copy)', () async {
      await bobOn([net, lan]);
      net.dead = true;
      await m.sendData(bob, Uint8List.fromList([1, 2, 3]));
      final data = net.framesOf(FrameType.data).single;
      expect(lan.framesOf(FrameType.data), isEmpty);
      await m.sendPings();
      clock.advance(const Duration(milliseconds: 700));
      m.checkMisses();
      await flush();
      final again = lan.framesOf(FrameType.data).single;
      expect(again.seq, data.seq);
      expect(again.payload, data.payload);
      expect(m.resent, 1);
    });

    test(
      'live audio switches path mid-talk without a gap in the stream',
      () async {
        await bobOn([net, lan]);
        await m.setTalking(true);
        expect(m.activity, ProbeActivity.active);
        for (var i = 0; i < 3; i++) {
          await m.sendAudio(Uint8List.fromList([i]));
        }
        net.dead = true;
        await m.sendPings();
        clock.advance(const Duration(milliseconds: 700));
        m.checkMisses();
        for (var i = 3; i < 6; i++) {
          await m.sendAudio(Uint8List.fromList([i]));
        }
        final onNet = net.framesOf(FrameType.audio);
        final onLan = lan.framesOf(FrameType.audio);
        expect(onNet.length, 6); // still tried until it recovers or times out
        expect(onLan.map((f) => f.payload.single), [3, 4, 5]);
        // One continuous sequence: the receiver plays it without a gap and
        // drops the duplicates.
        final seqs = {...onNet.map((f) => f.seq), ...onLan.map((f) => f.seq)}
          ..toList();
        final sorted = seqs.toList()..sort();
        for (var i = 1; i < sorted.length; i++) {
          expect(sorted[i] - sorted[i - 1], 1);
        }
        expect(onLan.first.seq, onNet[3].seq);
        // Internet gone for good: its link times out, Wi-Fi alone.
        clock.advance(const Duration(seconds: 5));
        lan.deliver(hello(bob, 77));
        m.prune();
        lan.sent.clear();
        net.sent.clear();
        await m.sendAudio(Uint8List.fromList([9]));
        expect(lan.framesOf(FrameType.audio), hasLength(1));
        expect(net.framesOf(FrameType.audio), isEmpty);
        await m.setTalking(false);
      },
    );

    test('a faster link that appears mid-talk is used from the next burst '
        '(v2.3.3: the route is held for the burst)', () async {
      await bobOn([net]);
      await m.setTalking(true);
      await m.sendAudio(Uint8List.fromList([1]));
      expect(net.framesOf(FrameType.audio), hasLength(1));
      // Same Wi-Fi shows up and measures 5 ms against 80 ms.
      lan.latency = const Duration(milliseconds: 5);
      lan.deliver(hello(bob, 50));
      await m.sendPings();
      lan.answerPings(bob, seq: 900);
      net.answerPings(bob, seq: 950);
      net.sent.clear();
      await m.sendAudio(Uint8List.fromList([2]));
      expect(net.framesOf(FrameType.audio), hasLength(1), reason: 'held');
      expect(lan.framesOf(FrameType.audio), isEmpty);
      await m.setTalking(false);
      // Next burst: the fresh choice is the faster link.
      await m.setTalking(true);
      net.sent.clear();
      lan.sent.clear();
      await m.sendAudio(Uint8List.fromList([3]));
      expect(lan.framesOf(FrameType.audio), hasLength(1));
      expect(net.framesOf(FrameType.audio), isEmpty);
      await m.setTalking(false);
    });

    test('network change: presence and checks on every link right away, '
        'local links look again', () async {
      await bobOn([net, lan, ble]);
      await m.onNetworkChanged();
      expect(m.networkChanges, 1);
      for (final l in [net, lan, ble]) {
        final kinds = l
            .framesOf(FrameType.control)
            .map((f) => f.control!.kind)
            .toList();
        expect(kinds, contains(ControlKind.hello));
        expect(kinds, contains(ControlKind.ping));
      }
      expect(lan.kicks, 1);
      expect(ble.kicks, 0); // Bluetooth is not tied to a network
      expect(net.kicks, 0); // relays replace their sockets themselves
      // A link that died with the old network misses within a second.
      net.dead = true;
      clock.advance(const Duration(milliseconds: 700));
      m.checkMisses();
      expect(m.routeTo(bob).first, isNot(TransportKind.internet));
    });

    test('status line: best path, its round trip, backups ready', () async {
      await bobOn([net, lan, ble]);
      final s = m.connectionSummary();
      expect(s.best, 'Internet');
      expect(s.bestRtt, const Duration(milliseconds: 80));
      expect(s.backups, 2);
      expect(s.text, 'Internet 80 ms · 2 backups ready');
      expect(
        const ConnectionSummary(
          best: 'Direct',
          bestRtt: Duration(milliseconds: 42),
          backups: 3,
          checkEvery: Duration(seconds: 3),
        ).text,
        'Direct 42 ms · 3 backups ready',
      );
      expect(
        const ConnectionSummary(
          best: null,
          bestRtt: null,
          backups: 0,
          checkEvery: Duration(seconds: 3),
        ).text,
        'Looking for a connection · checking every 3 s',
      );
    });
  });

  group('urgent rings and SOS on every path', () {
    late FakeClock clock;
    late LatencyLink net, lan, ble;
    late FakeRadio radio;
    late LoraTransport lora;
    late TransportManager m;

    setUp(() async {
      clock = FakeClock();
      net = LatencyLink(TransportKind.internet, clock);
      lan = LatencyLink(TransportKind.lan, clock);
      ble = LatencyLink(TransportKind.ble, clock);
      radio = FakeRadio();
      lora = LoraTransport(
        radio: radio,
        clock: clock.call,
        limiter: LoraRateLimiter(burst: 100, clock: clock.call),
        pumpInterval: const Duration(hours: 1),
      );
      m = TransportManager(
        transports: [net, lan, ble, lora],
        localNodeId: me,
        localName: 'me',
        clock: clock.call,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      await flush();
      net.deliver(hello(bob, 1));
      lan.deliver(hello(carol, 2));
      for (final t in [net, lan, ble]) {
        t.sent.clear();
      }
      radio.sent.clear();
    });

    tearDown(() => m.dispose());

    bool hasRing(LatencyLink l) => l
        .framesOf(FrameType.control)
        .any((f) => f.control!.kind == ControlKind.ring);

    test('urgent ring to the channel: internet, Wi-Fi, Bluetooth and LoRa '
        'at once', () async {
      await m.sendControlToChannel(
        const ControlMessage(ControlKind.ring, id: 7, urgent: true),
      );
      await flush();
      expect(hasRing(net), isTrue);
      expect(hasRing(lan), isTrue);
      expect(hasRing(ble), isTrue);
      expect(
        radio.sent
            .map(Frame.tryDecode)
            .any((f) => f?.control?.kind == ControlKind.ring),
        isTrue,
      );
      expect(m.urgentSends, 1);
      expect(m.activity, ProbeActivity.active);
    });

    test('urgent ring to one phone still goes on every path', () async {
      await m.sendControlTo(
        bob,
        const ControlMessage(ControlKind.ring, id: 8, to: bob, urgent: true),
      );
      await flush();
      expect(hasRing(net), isTrue);
      expect(hasRing(lan), isTrue);
      expect(hasRing(ble), isTrue);
      expect(radio.sent, isNotEmpty);
    });

    test('a normal ring only takes the best path', () async {
      await m.sendControlTo(
        bob,
        const ControlMessage(ControlKind.ring, id: 9, to: bob),
      );
      await flush();
      expect(hasRing(net), isTrue);
      expect(hasRing(lan), isFalse);
      expect(hasRing(ble), isFalse);
      expect(radio.sent, isEmpty);
    });

    test(
      'an SOS answer to one phone goes on every fast path and LoRa',
      () async {
        // Trip kind 3 = SOS acknowledgement.
        await m.sendTrip(
          Uint8List.fromList([3, 1, 2, 3]),
          to: bob,
          radio: true,
        );
        await flush();
        for (final l in [net, lan, ble]) {
          expect(l.framesOf(FrameType.trip), hasLength(1));
        }
        expect(radio.sent, isNotEmpty);
      },
    );
  });

  group('probe intervals and battery modes', () {
    test('the table', () {
      Duration p(ConnectionSpeed s, ProbeActivity a) =>
          LinkPolicy.probeInterval(s, a);
      const max = ConnectionSpeed.maxSpeed, bal = ConnectionSpeed.balanced;
      expect(p(max, ProbeActivity.active), const Duration(seconds: 1));
      expect(p(max, ProbeActivity.foreground), const Duration(seconds: 3));
      expect(p(max, ProbeActivity.idle), const Duration(seconds: 15));
      expect(p(bal, ProbeActivity.active), const Duration(seconds: 2));
      expect(p(bal, ProbeActivity.foreground), const Duration(seconds: 5));
      expect(p(bal, ProbeActivity.idle), const Duration(seconds: 30));
      expect(
        LinkPolicy.reconnectCap(max, ProbeActivity.foreground),
        const Duration(seconds: 5),
      );
      expect(
        LinkPolicy.reconnectCap(bal, ProbeActivity.idle),
        const Duration(seconds: 30),
      );
      expect(
        LinkPolicy.peerPingInterval(max, ProbeActivity.foreground),
        const Duration(seconds: 1),
      );
      expect(
        LinkPolicy.peerPingInterval(bal, ProbeActivity.idle),
        const Duration(seconds: 15),
      );
    });

    test('the manager follows the app and talk, and tells the links', () async {
      final clock = FakeClock();
      final net = LatencyLink(TransportKind.internet, clock);
      final m = TransportManager(
        transports: [net],
        localNodeId: me,
        localName: 'me',
        clock: clock.call,
        helloInterval: const Duration(hours: 1),
      );
      expect(m.speed, ConnectionSpeed.maxSpeed); // default
      await m.start();
      expect(m.probeInterval, const Duration(seconds: 3));
      expect(net.plans.last, (
        const Duration(seconds: 3),
        const Duration(seconds: 5),
      ));
      m.setActivity(ProbeActivity.idle); // background, nothing going on
      expect(m.probeInterval, const Duration(seconds: 15));
      expect(net.plans.last.$1, const Duration(seconds: 15));
      await m.setTalking(true); // talking from the notification
      expect(m.probeInterval, const Duration(seconds: 1));
      await m.setTalking(false);
      // v2.0.0: a minute of quiet after talking before it relaxes again.
      expect(m.probeInterval, const Duration(seconds: 3));
      clock.advance(LinkPolicy.idleAfter + const Duration(seconds: 1));
      m.setSpeed(ConnectionSpeed.balanced);
      expect(m.probeInterval, const Duration(seconds: 30));
      expect(net.plans.last, (
        const Duration(seconds: 30),
        const Duration(seconds: 30),
      ));
      m.setActivity(ProbeActivity.foreground);
      expect(m.probeInterval, const Duration(seconds: 5));
      // A ring keeps it at full speed for a minute.
      net.deliver(hello(bob, 1));
      await m.sendControlTo(
        bob,
        const ControlMessage(ControlKind.ring, id: 1, to: bob),
      );
      expect(m.probeInterval, const Duration(seconds: 2));
      clock.advance(const Duration(seconds: 61));
      expect(m.probeInterval, const Duration(seconds: 5));
      await m.dispose();
    });
  });

  group('relays', () {
    MultiRelayTransport multi(Net n) => MultiRelayTransport(
      serverUris: [home, backup],
      factory: (u) => RelayTransport(serverUri: u, connector: n),
      networkChanges: n.net.stream,
    );

    test('connects race: a fast relay is used while a sleeping one is still '
        'waking (nobody waits for it)', () async {
      final n = Net()
        ..delay['home.test'] = const Duration(milliseconds: 40)
        ..delay['backup.test'] = null; // never answers
      final m = multi(n);
      final sw = Stopwatch()..start();
      await m.start(localNodeId: 1, channel: 1);
      expect(sw.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(m.status, TransportStatus.running);
      expect(m.relays.last.status, TransportStatus.starting);
      await m.send(Uint8List.fromList([1, 2, 3]));
      expect(n.open('home.test')!.sent, hasLength(1));
      await m.dispose();
    });

    test('home relay recovery is re-checked within seconds', () async {
      final n = Net();
      final m = multi(n);
      m.setProbePlan(
        probe: const Duration(seconds: 3),
        reconnectCap: const Duration(seconds: 5),
      );
      expect(m.homeRetryWhileOnBackup, const Duration(seconds: 10));
      expect(m.homeRetryAlone, const Duration(seconds: 5));
      m.setProbePlan(
        probe: const Duration(seconds: 30),
        reconnectCap: const Duration(seconds: 30),
      );
      expect(m.homeRetryWhileOnBackup, const Duration(seconds: 60));
      await m.dispose();
    });

    test('pings measure the round trip; two missed pongs replace the socket '
        'right away', () async {
      final n = Net();
      final r = RelayTransport(serverUri: home, connector: n);
      r.setProbePlan(
        probe: const Duration(milliseconds: 200),
        reconnectCap: const Duration(seconds: 5),
      );
      await r.start(localNodeId: 1, channel: 1);
      await until(() => r.probeRtt != null);
      expect(r.probeRtt, lessThan(const Duration(milliseconds: 500)));
      final first = n.open('home.test')!;
      first.answerPings = false; // the socket died silently
      n.answerPings = true;
      // Deadline 1.5 s (fast relay), two in a row, then a new socket.
      await until(() => r.pongReconnects == 1, ms: 6000);
      await until(() => r.status == TransportStatus.running);
      expect(first.closed, isTrue);
      expect(n.open('home.test'), isNot(same(first)));
      await r.dispose();
    });

    test('network change: make-before-break (old socket kept until the new '
        'one is open)', () async {
      final n = Net()..delay['home.test'] = const Duration(milliseconds: 10);
      final r = RelayTransport(serverUri: home, connector: n);
      await r.start(localNodeId: 1, channel: 1);
      await until(() => r.status == TransportStatus.running);
      final old = n.open('home.test')!;
      n.delay['home.test'] = const Duration(milliseconds: 150);
      n.net.add('mobile data');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Still up on the old socket while the new one connects.
      expect(r.status, TransportStatus.running);
      expect(old.closed, isFalse);
      await r.send(Uint8List.fromList([7]));
      expect(old.sent, hasLength(1));
      await until(() => old.closed);
      expect(r.status, TransportStatus.running);
      expect(r.networkReplacements, 1);
      await r.send(Uint8List.fromList([8]));
      expect(n.open('home.test')!.sent, hasLength(1));
      await r.dispose();
    });
  });
}
