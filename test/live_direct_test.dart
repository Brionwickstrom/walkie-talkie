// ignore_for_file: avoid_print
// Real direct-link check over the internet (v1.8.9). Skipped unless
// LIVE_RELAY is set.
//
// One machine, two phones (they meet through the real relay and connect
// directly):
//   LIVE_RELAY=wss://walkie-relay.tail1700cf.ts.net/ws flutter test test/live_direct_test.dart
//
// Two machines on different networks (run both at the same time):
//   LIVE_RELAY=... LIVE_DIRECT_ROLE=a flutter test test/live_direct_test.dart
//   LIVE_RELAY=... LIVE_DIRECT_ROLE=b flutter test test/live_direct_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/direct_links.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

final live = Platform.environment['LIVE_RELAY'];
final role = Platform.environment['LIVE_DIRECT_ROLE'];
final room = int.tryParse(Platform.environment['LIVE_DIRECT_CH'] ?? '') ?? 4747;

Future<bool> until(bool Function() ok, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return true;
}

void main() {
  test(
    'live direct link',
    () async {
      final uris = MultiRelayTransport.parseList(live!);
      final ids = switch (role) {
        'a' => [0x0D1A0001],
        'b' => [0x0D1A0002],
        _ => [0x0D1A0001 + pid * 4, 0x0D1A0002 + pid * 4],
      };
      final events = <String>[];
      final ms = <TransportManager>[];
      final ts = <MultiRelayTransport>[];
      for (final id in ids) {
        final d = DirectLinks()
          ..onEvent = (l) {
            events.add(l);
            print('  [${id.toRadixString(16)}] $l');
          };
        final t = MultiRelayTransport(serverUris: uris, direct: d);
        final m = TransportManager(
          transports: [t],
          localNodeId: id,
          localName: 'live-$id',
          channel: room,
        );
        m.helloExtras = () => {'v': featureLevel};
        d.attach(m);
        ms.add(m);
        ts.add(t);
      }
      final sw = Stopwatch()..start();
      for (final m in ms) {
        await m.start();
      }
      final peerUp = await until(
        () => ms.every((m) => m.peers.isNotEmpty),
        seconds: 120,
      );
      print('relay: peers seen=$peerUp after ${sw.elapsedMilliseconds} ms');
      expect(peerUp, isTrue);
      final nat = await ts.first.direct!.probeNat();
      print(
        'nat: public4=${nat?.public4 != null ? 'yes' : 'no'} '
        'symmetric=${nat?.symmetric} ipv6=${nat?.ipv6} '
        'outlook=${nat?.outlook}',
      );
      final directUp = await until(
        () => ts.every((t) => t.direct!.upPeers.isNotEmpty),
        seconds: 40,
      );
      print(
        'direct: up=$directUp after ${sw.elapsedMilliseconds} ms '
        'path=${ts.first.direct!.upPeers.map(ts.first.direct!.pathOf).toList()}',
      );
      if (directUp) {
        // Count audio frames that arrive over the direct link.
        final got = <InboundFrame>[];
        final subs = [for (final t in ts) t.direct!.frames.listen(got.add)];
        for (var i = 0; i < 20; i++) {
          for (final m in ms) {
            await m.sendAudio(Uint8List.fromList([i, 1, 2, 3]));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        final audio = got.where((f) => f.frame.type == FrameType.audio).length;
        print('direct audio frames received: $audio');
        for (final s in subs) {
          await s.cancel();
        }
      }
      // Keep the other machine company for a bit.
      if (role != null) await Future<void>.delayed(const Duration(seconds: 8));
      for (final m in ms) {
        await m.dispose();
      }
      if (role == null) expect(directUp, isTrue);
    },
    skip: live == null ? 'set LIVE_RELAY' : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
