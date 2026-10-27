// ignore_for_file: avoid_print
// v1.9.8 live check against the real relays (home + backup) with the app's
// own MultiRelayTransport and TransportManager, on a throwaway private room
// (nobody's phone sees it). Skipped unless LIVE_RELAYS is set, e.g.
//   LIVE_RELAYS=default flutter test test/live_failover_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/config.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/link_policy.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

final live = Platform.environment['LIVE_RELAYS'];

Future<void> until(bool Function() ok, {int seconds = 90}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'live: both relays race, round trips, failover to backup mid-talk',
    () async {
      final uris = MultiRelayTransport.parseList(
        live == 'default' ? AppConfig.defaultRelayUrl : live!,
      );
      final rnd = Random.secure();
      final pass = List.generate(
        16,
        (_) => rnd.nextInt(36).toRadixString(36),
      ).join();
      final key = await ChannelKey.derive(16, 'v198-live-$pass');
      final ids = [
        0x1A000000 | rnd.nextInt(0xFFFFF),
        0x2B000000 | rnd.nextInt(0xFFFFF),
      ];
      final relays = [
        for (final _ in ids) MultiRelayTransport(serverUris: uris),
      ];
      final ms = [
        for (var i = 0; i < 2; i++)
          TransportManager(
            transports: [relays[i]],
            localNodeId: ids[i],
            localName: 'v198-live-$i',
            channel: 16,
            channelKey: key,
          ),
      ];
      final sw = Stopwatch()..start();
      await Future.wait(ms.map((m) => m.start()));
      print(
        'start() returned after ${sw.elapsedMilliseconds} ms '
        '(${relays[0].relaysUp} relay(s) up on A)',
      );
      await until(() => relays.every((r) => r.relaysUp == uris.length));
      print(
        'all ${uris.length} relays up on both after ${sw.elapsedMilliseconds} ms',
      );
      await until(() => ms[0].peers.isNotEmpty && ms[1].peers.isNotEmpty);
      print('presence both ways after ${sw.elapsedMilliseconds} ms');
      await until(
        () => relays[0].relays.every((r) => r.probeRtt != null),
        seconds: 20,
      );
      for (final r in relays[0].relays) {
        print(
          '  ${relays[0].labelOf(r)} ${r.serverUri!.host}: '
          'pong ${r.probeRtt!.inMilliseconds} ms',
        );
      }
      await until(
        () => ms[0].peer(ids[1])?.rtt[TransportKind.internet] != null,
        seconds: 20,
      );
      print(
        'A->B round trip ${ms[0].peer(ids[1])!.rtt[TransportKind.internet]!.inMilliseconds} ms',
      );
      print('status line on A: "${ms[0].connectionSummary().text}"');
      expect(ms[0].connectionSummary().best, isNotNull);

      // Talk; halfway through A loses its home relay (socket closed). The
      // backup carries the rest with no gap.
      final got = <int>{};
      final sub = ms[1].audio.listen((a) => got.add(a.opus.first));
      await ms[0].setTalking(true);
      expect(ms[0].activity, ProbeActivity.active);
      for (var i = 0; i < 100; i++) {
        if (i == 50 && uris.length > 1) {
          await relays[0].relays.first.stop();
          print('  A home relay stopped at packet 50');
        }
        await ms[0].sendAudio(Uint8List.fromList([i, 1, 2, 3]));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await ms[0].setTalking(false);
      await Future<void>.delayed(const Duration(seconds: 2));
      final missing = [
        for (var i = 0; i < 100; i++)
          if (!got.contains(i)) i,
      ];
      print('audio at B: ${got.length}/100, missing $missing');
      expect(got.length, greaterThanOrEqualTo(95));
      expect(
        [
          for (final i in missing)
            if (i >= 50) i,
        ].length,
        lessThan(5),
      );

      // Urgent ring to B goes out on every path and arrives.
      final rings = <int>[];
      final rs = ms[1].controls.listen((c) {
        if (c.message.kind == ControlKind.ring) rings.add(c.message.id ?? 0);
      });
      await ms[0].sendControlTo(
        ids[1],
        ControlMessage(ControlKind.ring, id: 4242, to: ids[1], urgent: true),
      );
      await until(() => rings.contains(4242), seconds: 10);
      print('urgent ring arrived; A urgent sends ${ms[0].urgentSends}');
      print(
        'status line on A after losing home: '
        '"${ms[0].connectionSummary().text}"',
      );
      await sub.cancel();
      await rs.cancel();
      for (final m in ms) {
        await m.dispose();
      }
    },
    skip: live == null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
