import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/history/talk_history.dart';
import 'package:walkie_talkie/transports/wifi_direct_transport.dart';

class FakeWifiDirect implements WifiDirectPlatform {
  final ctl = StreamController<Map<String, Object?>>.broadcast(sync: true);
  String? startResult;
  final connects = <(String, int)>[];
  int stops = 0;

  @override
  Stream<Map<String, Object?>> get events => ctl.stream;
  @override
  Future<String?> start(int nodeId) async => startResult;
  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> connect(String address, {int ownerIntent = 0}) async =>
      connects.add((address, ownerIntent));
  @override
  Future<void> setDiscoveryInterval(Duration every) async {}
}

void main() {
  group('WifiDirectPolicy', () {
    const p = WifiDirectPolicy();
    final t0 = DateTime(2026);
    WifiDirectPeer peer(int id) => WifiDirectPeer('aa:bb', id, t0);

    test('larger id asks; smaller id waits, then falls back', () {
      expect(
        p.shouldConnect(
          localId: 9,
          peer: peer(3),
          inGroup: false,
          sharedNetwork: false,
          now: t0,
        ),
        isTrue,
      );
      expect(
        p.shouldConnect(
          localId: 3,
          peer: peer(9),
          inGroup: false,
          sharedNetwork: false,
          now: t0,
        ),
        isFalse,
      );
      expect(
        p.shouldConnect(
          localId: 3,
          peer: peer(9),
          inGroup: false,
          sharedNetwork: false,
          now: t0.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );
    });

    test('never with a shared network or while already in a group', () {
      expect(
        p.shouldConnect(
          localId: 9,
          peer: peer(3),
          inGroup: false,
          sharedNetwork: true,
          now: t0,
        ),
        isFalse,
      );
      expect(
        p.shouldConnect(
          localId: 9,
          peer: peer(3),
          inGroup: true,
          sharedNetwork: false,
          now: t0,
        ),
        isFalse,
      );
    });

    test('one attempt per peer per minute', () {
      final x = peer(3)..lastAttempt = t0;
      expect(
        p.shouldConnect(
          localId: 9,
          peer: x,
          inGroup: false,
          sharedNetwork: false,
          now: t0.add(const Duration(seconds: 10)),
        ),
        isFalse,
      );
      expect(
        p.shouldConnect(
          localId: 9,
          peer: x,
          inGroup: false,
          sharedNetwork: false,
          now: t0.add(const Duration(seconds: 61)),
        ),
        isTrue,
      );
    });
  });

  group('WifiDirectTransport', () {
    test('iPhone: unavailable, cleanly', () async {
      final t = WifiDirectTransport(
        platform: FakeWifiDirect(),
        supported: false,
      );
      await t.start(localNodeId: 1, channel: 1);
      expect(t.status, TransportStatus.unavailable);
      expect(t.statusDetail, contains('Android only'));
      await t.send(Uint8List(12)); // no-op, no throw
      await t.dispose();
    });

    test('missing permission is reported, not thrown', () async {
      final fake = FakeWifiDirect()..startResult = 'permission';
      final t = WifiDirectTransport(platform: fake, supported: true);
      await t.start(localNodeId: 1, channel: 1);
      expect(t.status, TransportStatus.unavailable);
      expect(t.statusDetail, contains('Nearby devices'));
      await t.dispose();
    });

    test('connects to found phones it shares no network with', () async {
      final fake = FakeWifiDirect();
      final shared = <int>{5};
      final t = WifiDirectTransport(platform: fake, supported: true)
        ..sharedNetworkWith = shared.contains;
      await t.start(localNodeId: 9, channel: 1);
      expect(t.status, TransportStatus.running);
      fake.ctl.add({'t': 'found', 'addr': 'a', 'id': 5}); // same Wi-Fi
      fake.ctl.add({'t': 'found', 'addr': 'b', 'id': 3});
      fake.ctl.add({'t': 'found', 'addr': 'b', 'id': 3}); // again: no retry
      expect(fake.connects, [('b', 0)]);
      fake.ctl.add({'t': 'conn', 'formed': true, 'owner': false});
      expect(t.inGroup, isTrue);
      fake.ctl.add({'t': 'found', 'addr': 'c', 'id': 2});
      expect(fake.connects, hasLength(1)); // already in a group
      fake.ctl.add({'t': 'conn', 'formed': false});
      expect(t.inGroup, isFalse);
      await t.dispose();
    });

    test(
      'frames from the group are delivered and make peers reachable',
      () async {
        final t = WifiDirectTransport(
          platform: FakeWifiDirect(),
          supported: true,
        );
        await t.start(localNodeId: 9, channel: 1);
        final got = <InboundFrame>[];
        t.frames.listen(got.add);
        final f = Frame(
          type: FrameType.audio,
          senderId: 3,
          channel: 1,
          seq: 1,
          payload: Uint8List.fromList([1, 2]),
        );
        expect(t.canReach(3), isFalse);
        t.onDatagram(f.encode(), InternetAddress('192.168.49.1'), 47475);
        await Future<void>.delayed(Duration.zero);
        expect(got.single.transport, TransportKind.wifiDirect);
        expect(t.canReach(3), isTrue);
        await t.dispose();
      },
    );

    test('priority sits between Wi-Fi and Bluetooth', () {
      expect(
        TransportKind.lan.defaultPriority >
                TransportKind.wifiDirect.defaultPriority &&
            TransportKind.wifiDirect.defaultPriority >
                TransportKind.ble.defaultPriority &&
            TransportKind.ble.defaultPriority >
                TransportKind.internet.defaultPriority,
        isTrue,
      );
    });
  });

  test(
    'settings: relay for others and Wi-Fi Direct default on, saved',
    () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsSettingsStore();
      final s = await store.load(defaultChannel: 1);
      expect(s.relayForOthers, isTrue);
      expect(s.wifiDirect, isTrue);
      s
        ..relayForOthers = false
        ..wifiDirect = false;
      await store.save(s);
      final s2 = await store.load(defaultChannel: 1);
      expect(s2.relayForOthers, isFalse);
      expect(s2.wifiDirect, isFalse);
    },
  );

  test('replay history keeps the hop count', () {
    final t = TalkTake(
      id: 1,
      scope: 1,
      sender: 2,
      name: 'B',
      start: DateTime(2026),
      durationMs: 1000,
      bytes: 10,
      hops: 3,
    );
    expect(TalkTake.fromJson(t.toJson())!.hops, 3);
    expect(
      TalkTake.fromJson({'id': 1, 'sc': 1, 's': 2, 'at': 0, 'dur': 1})!.hops,
      1,
    );
  });
}
