// ignore_for_file: avoid_print
// End-to-end check against the deployed relay. Skipped unless LIVE_RELAY is
// set, e.g.  LIVE_RELAY=wss://brion-walkie-relay.onrender.com/ws flutter test test/live_relay_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

final live = Platform.environment['LIVE_RELAY'];

Future<void> until(bool Function() ok, {int seconds = 90}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<void> run(int channel, ChannelKey? Function() key) async {
    final uri = Uri.parse(live!);
    final ids = [
      0x10000000 + pid * 7 + channel,
      0x20000000 + pid * 7 + channel,
    ];
    final ms = [
      for (final id in ids)
        TransportManager(
          transports: [
            MultiRelayTransport(serverUris: [uri]),
          ],
          localNodeId: id,
          localName: 'live-$id',
          channel: channel,
          channelKey: key(),
        ),
    ];
    final sw = Stopwatch()..start();
    for (final m in ms) {
      await m.start();
    }
    await until(
      () => ms.every(
        (m) => m.transports.single.status == TransportStatus.running,
      ),
    );
    print(
      'ch $channel private=${key() != null}: relay connected after ${sw.elapsedMilliseconds} ms',
    );
    await until(() => ms[0].peers.isNotEmpty && ms[1].peers.isNotEmpty);
    print(
      '  presence both ways after ${sw.elapsedMilliseconds} ms: '
      '${ms[0].peers.single.name} <-> ${ms[1].peers.single.name} '
      'via ${ms[0].peers.single.activeLink}',
    );
    final got = <int>[];
    ms[1].audio.listen((a) => got.add(a.opus.length));
    for (var i = 0; i < 50; i++) {
      await ms[0].sendAudio(Uint8List(30 + (i % 5)));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await until(() => got.length >= 45, seconds: 10);
    await Future<void>.delayed(const Duration(seconds: 1));
    print('  audio: ${got.length}/50 frames arrived at B');
    expect(ms[1].peers.single.channel, ms[1].scope);
    for (final m in ms) {
      await m.dispose();
    }
  }

  test(
    'live relay: public channel presence + audio',
    () async {
      await run(9, () => null);
    },
    skip: live == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'live relay: private channel presence + audio',
    () async {
      final k = await ChannelKey.derive(9, 'live-test-pass');
      await run(9, () => k);
    },
    skip: live == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
