import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_relay/relay_server.dart';
import 'package:walkie_talkie/app/passcodes.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/listeners.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/peer_box.dart';
import 'package:walkie_talkie/core/rekey.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';
import 'package:walkie_talkie/ui/channels_sheet.dart';

Future<void> _until(bool Function() ok, {int ms = 5000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List _hello(int id, {int ch = 1}) => Frame.control(
  senderId: id,
  channel: ch,
  seq: 1,
  message: ControlMessage(ControlKind.hello, name: 'p$id'),
).encode();

/// A raw relay socket, like an older app (or a hand-written listener).
class _Sock {
  _Sock(this.ws) {
    ws.listen((d) {
      if (d is String) {
        texts.add(d);
      } else {
        bins.add(d as List<int>);
      }
    });
  }
  final WebSocket ws;
  final texts = <String>[];
  final bins = <List<int>>[];
  static Future<_Sock> open(
    RelayServer s,
    String room,
    String id, {
    bool roster = false,
  }) async => _Sock(
    await WebSocket.connect(
      'ws://127.0.0.1:${s.port}/ws?ch=$room&id=$id${roster ? '&r=1' : ''}',
    ),
  );
  List<Map<String, dynamic>> get rosters => [
    for (final t in texts)
      if (t.startsWith('{')) jsonDecode(t) as Map<String, dynamic>,
  ];
}

Map<String, DateTime> _seen(String key, [DateTime? at]) => {
  key: at ?? DateTime.now(),
};

void main() {
  group('relay 1.4.0 stays compatible with older apps', () {
    test('healthz says 1.4.0', () async {
      final s = await RelayServer.bind(address: '127.0.0.1', port: 0);
      expect(relayVersion, '1.4.0');
      final sock = await Socket.connect('127.0.0.1', s.port);
      sock.write('GET /healthz HTTP/1.0\r\nHost: x\r\n\r\n');
      final body = await utf8.decodeStream(sock);
      expect(body, contains('200'));
      expect(body, contains('ok relay 1.4.0'));
      sock.destroy();
      await s.close();
    });

    test(
      'old clients (no &r=1) get only pong as text, frames as before',
      () async {
        final s = await RelayServer.bind(
          address: '127.0.0.1',
          port: 0,
          rosterInterval: const Duration(milliseconds: 50),
        );
        final a = await _Sock.open(s, '3', 'a');
        final b = await _Sock.open(s, '3', 'b');
        a.ws.add(_hello(0xa, ch: 3));
        a.ws.add('ping');
        await _until(() => b.bins.isNotEmpty && a.texts.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(a.texts, ['pong']);
        expect(b.texts, isEmpty);
        await a.ws.close();
        await b.ws.close();
        await s.close();
      },
    );

    test('private room: phones that send hellos keep receiving past the '
        'grace period (every app version does)', () async {
      final s = await RelayServer.bind(
        address: '127.0.0.1',
        port: 0,
        silentGrace: const Duration(milliseconds: 300),
        silentAfter: const Duration(milliseconds: 800),
      );
      final a = await _Sock.open(s, 'p1a2b', '1');
      final b = await _Sock.open(s, 'p1a2b', '2');
      final t = Timer.periodic(const Duration(milliseconds: 100), (_) {
        a.ws.add(_hello(1));
        b.ws.add(_hello(2));
      });
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final na = a.bins.length, nb = b.bins.length;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      t.cancel();
      expect(a.bins.length, greaterThan(na));
      expect(b.bins.length, greaterThan(nb));
      await a.ws.close();
      await b.ws.close();
      await s.close();
    });

    test('private room: a silent socket (pings only) stops receiving after '
        'the grace period; open rooms are unchanged', () async {
      final s = await RelayServer.bind(
        address: '127.0.0.1',
        port: 0,
        silentGrace: const Duration(milliseconds: 300),
      );
      final talker = await _Sock.open(s, 'p1a2b', '1');
      final silent = await _Sock.open(s, 'p1a2b', '9');
      final pubTalker = await _Sock.open(s, '5', '1');
      final pubSilent = await _Sock.open(s, '5', '9');
      talker.ws.add(_hello(1));
      pubTalker.ws.add(_hello(1, ch: 5));
      await _until(() => silent.bins.length == 1 && pubSilent.bins.length == 1);
      // Within the grace period a new phone hears the room right away.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      silent.ws.add('ping');
      pubSilent.ws.add('ping');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (var i = 0; i < 3; i++) {
        talker.ws.add(_hello(1));
        pubTalker.ws.add(_hello(1, ch: 5));
      }
      await _until(() => pubSilent.bins.length == 4);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(silent.bins.length, 1, reason: 'pings alone do not count');
      // Once it sends a frame (shows itself) it receives again.
      silent.ws.add(_hello(9));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      talker.ws.add(_hello(1));
      await _until(() => silent.bins.length == 2);
      for (final x in [talker, silent, pubTalker, pubSilent]) {
        await x.ws.close();
      }
      await s.close();
    });

    test(
      'roster only for sockets that ask, with id / idle / age / sent',
      () async {
        final s = await RelayServer.bind(
          address: '127.0.0.1',
          port: 0,
          rosterInterval: const Duration(milliseconds: 100),
        );
        final me = await _Sock.open(s, 'p00ff', 'aa', roster: true);
        final other = await _Sock.open(s, 'p00ff', 'bb');
        other.ws.add(_hello(0xbb));
        await _until(() => me.rosters.any((r) => r['n'] == 2));
        final r = RelayRoster.tryParse(jsonEncode(me.rosters.last))!;
        expect(r.entries.map((e) => e.id).toSet(), {'aa', 'bb'});
        expect(r.entries.firstWhere((e) => e.id == 'bb').sent, isTrue);
        expect(r.entries.firstWhere((e) => e.id == 'aa').sent, isFalse);
        expect(other.texts, isEmpty);
        await other.ws.close();
        await _until(() => me.rosters.last['n'] == 1);
        await me.ws.close();
        await s.close();
      },
    );
  });

  group('unknown listener', () {
    RelayRoster ro(List<RosterEntry> e) => RelayRoster(e, DateTime.now());

    test('counts sockets that never showed up', () {
      final heard = {'aa', 'bb'};
      // Everyone we hear: nothing to report.
      expect(
        unknownListeners(
          ro(const [RosterEntry('aa', 0, 60), RosterEntry('bb', 1, 60)]),
          heard,
        ),
        0,
      );
      // An extra socket with an id we never hear, active: a listener.
      expect(
        unknownListeners(
          ro(const [
            RosterEntry('aa', 0, 60),
            RosterEntry('bb', 1, 60),
            RosterEntry('cc', 3, 30),
          ]),
          heard,
        ),
        1,
      );
      // Just joined (hello on its way): not yet.
      expect(unknownListeners(ro(const [RosterEntry('cc', 0, 2)]), heard), 0);
      // Copying a phone's id does not hide it.
      expect(
        unknownListeners(
          ro(const [
            RosterEntry('aa', 0, 60),
            RosterEntry('bb', 1, 60),
            RosterEntry('bb', 2, 40),
          ]),
          heard,
        ),
        1,
      );
      // A phone that just lost signal (old socket, silent a little while)
      // is not a listener...
      expect(unknownListeners(ro(const [RosterEntry('bb', 30, 90)]), {}), 0);
      // ...but a socket silent longer than the relay keeps dead ones is.
      expect(unknownListeners(ro(const [RosterEntry('', 70, 90)]), {}), 1);
    });

    test('roster parsing ignores pong and junk', () {
      expect(RelayRoster.tryParse('pong'), isNull);
      expect(RelayRoster.tryParse('{"t":"other"}'), isNull);
      expect(RelayRoster.tryParse('{bad json'), isNull);
      final r = RelayRoster.tryParse(
        '{"t":"roster","n":1,"s":[["AB",1,2,1]]}',
      )!;
      expect(r.entries.single.id, 'ab');
      expect(r.entries.single.sent, isTrue);
    });

    test('watch: smoothed over two rosters, stale rosters drop out', () {
      final w = ListenerWatch(freshFor: const Duration(seconds: 15));
      final now = DateTime.now();
      final listener = RelayRoster(const [
        RosterEntry('aa', 0, 60),
        RosterEntry('zz', 2, 60),
      ], now);
      w.update('home', RelayRoster(const [RosterEntry('aa', 0, 60)], now), {
        'aa',
      });
      w.update('home', listener, {'aa'});
      expect(w.count(now), 0, reason: 'one roster is not enough');
      w.update('home', listener, {'aa'});
      expect(w.count(now), 1);
      expect(w.supported(now), isTrue);
      expect(w.count(now.add(const Duration(seconds: 30))), 0);
    });

    test(
      'end to end: two phones + a hidden socket on a private channel',
      () async {
        final s = await RelayServer.bind(
          address: '127.0.0.1',
          port: 0,
          rosterInterval: const Duration(milliseconds: 100),
        );
        final key = await ChannelKey.deriveInline(4, 'v194-e2e-passcode');
        final uri = Uri.parse('ws://127.0.0.1:${s.port}/ws');
        final ms = <TransportManager>[];
        final ts = <MultiRelayTransport>[];
        for (final id in [0x11, 0x22]) {
          final t = MultiRelayTransport(serverUris: [uri], roster: true);
          final m = TransportManager(
            transports: [t],
            localNodeId: id,
            localName: 'p$id',
            channel: 4,
            channelKey: key,
            helloInterval: const Duration(milliseconds: 100),
          );
          ts.add(t);
          ms.add(m);
          await m.start();
        }
        final watch = ListenerWatch(joinGrace: 0);
        final sub = ts[0].rosters.listen((e) {
          final heard = {
            '11',
            for (final p in ms[0].peers) p.id.toRadixString(16),
          };
          watch.update(e.$1, e.$2, heard);
        });
        await _until(() => ms[0].peers.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(watch.count(DateTime.now()), 0);
        final room = RelayTransport.roomFor(ms[0].scope);
        final hidden = await _Sock.open(s, room, 'dead');
        hidden.ws.add('ping');
        await _until(() => watch.count(DateTime.now()) == 1);
        await hidden.ws.close();
        await _until(() => watch.count(DateTime.now()) == 0);
        await sub.cancel();
        for (final m in ms) {
          await m.stop();
        }
        for (final t in ts) {
          await t.dispose();
        }
        await s.close();
      },
    );
  });

  group('real kick: the removed phone cannot read the new passcode', () {
    const admin = 0xA1, bob = 0xB2, kicked = 0xC3;
    late PeerBox adminBox, bobBox, kickedBox;
    setUpAll(() async {
      adminBox = await PeerBox.create();
      bobBox = await PeerBox.create();
      kickedBox = await PeerBox.create();
    });

    test('sealed per member; the kicked phone sees the frame but not the '
        'passcode', () async {
      final room = await ChannelKey.deriveInline(5, 'old-room-passcode');
      final r = Rekey.build(
        from: admin,
        to: bob,
        rid: 77,
        passcode: 'newpass2345xy',
        removed: kicked,
        toFeature: featureLevel,
        toKx: _seen(bobBox.publicKey),
        box: adminBox,
      );
      expect(r.how, 'key');
      expect(jsonEncode(r.x), isNot(contains('newpass2345xy')));
      // On the wire: sealed with the OLD room key, which the kicked phone
      // still has.
      final wire = room.seal(
        Frame.control(
          senderId: admin,
          channel: room.tag,
          seq: 9,
          message: ControlMessage(ControlKind.rekey, to: bob, id: 77, x: r.x!),
        ),
      );
      final seenByKicked = room.open(Frame.tryDecode(wire)!)!;
      final msg = seenByKicked.control!;
      expect(msg.x['pc'], isNull);
      // The kicked phone tries everything it has: its own key, pretending
      // to be Bob, the admin's public key.
      for (final me in [kicked, bob]) {
        expect(
          Rekey.open(
            from: admin,
            me: me,
            rid: 77,
            x: msg.x,
            fromKx: _seen(adminBox.publicKey),
            box: kickedBox,
          ),
          isNull,
        );
      }
      // Bob opens it.
      expect(
        Rekey.open(
          from: admin,
          me: bob,
          rid: 77,
          x: msg.x,
          fromKx: _seen(adminBox.publicKey),
          box: bobBox,
        ),
        'newpass2345xy',
      );
      // Not replayable to another round.
      expect(
        Rekey.open(
          from: admin,
          me: bob,
          rid: 78,
          x: msg.x,
          fromKx: _seen(adminBox.publicKey),
          box: bobBox,
        ),
        isNull,
      );
    });

    test('a forged rekey (kicked phone poses as the admin) is refused', () {
      final forged = Rekey.build(
        from: admin,
        to: bob,
        rid: 5,
        passcode: 'attacker-chosen',
        removed: 0,
        toFeature: featureLevel,
        toKx: _seen(bobBox.publicKey),
        box: kickedBox, // the attacker's own key, not the admin's
      );
      expect(
        Rekey.open(
          from: admin,
          me: bob,
          rid: 5,
          x: forged.x!,
          fromKx: _seen(adminBox.publicKey), // what the admin's hellos say
          box: bobBox,
        ),
        isNull,
      );
    });

    test('friends: sealed with the pair key', () {
      final pair = PairKey(PairKey.randomSecret());
      final r = Rekey.build(
        from: admin,
        to: bob,
        rid: 1,
        passcode: 'friendpass99',
        removed: kicked,
        toFeature: featureLevel,
        toKx: const {},
        friendSecret: pair.secret,
      );
      expect(r.how, 'friend');
      expect(
        Rekey.open(
          from: admin,
          me: bob,
          rid: 1,
          x: r.x!,
          fromKx: const {},
          friendSecret: pair.secret,
        ),
        'friendpass99',
      );
      expect(
        Rekey.open(
          from: admin,
          me: bob,
          rid: 1,
          x: r.x!,
          fromKx: const {},
          friendSecret: PairKey.randomSecret(),
        ),
        isNull,
      );
    });

    test('older phones: the same clear copy as before 1.9.4 (still works)', () {
      final r = Rekey.build(
        from: admin,
        to: bob,
        rid: 2,
        passcode: 'legacypass12',
        removed: kicked,
        toFeature: 20,
        toKx: const {},
        box: adminBox,
      );
      expect(r.how, 'legacy');
      expect(r.x, {
        'pc': 'legacypass12',
        'ex': [kicked],
      });
      // What a 1.9.3 phone does with it: x.pc, 6+ chars.
      expect(
        Rekey.open(from: admin, me: bob, rid: 2, x: r.x!, fromKx: const {}),
        'legacypass12',
      );
      // And a 1.9.3 phone given a new-style rekey ignores it (no x.pc).
      final v2 = Rekey.build(
        from: admin,
        to: bob,
        rid: 3,
        passcode: 'x' * 12,
        removed: kicked,
        toFeature: featureLevel,
        toKx: _seen(bobBox.publicKey),
        box: adminBox,
      );
      expect(v2.x!['pc'], isNull);
    });

    test('two keys claiming one phone: nothing is sent to it', () {
      final now = DateTime.now();
      final r = Rekey.build(
        from: admin,
        to: bob,
        rid: 4,
        passcode: 'conflictpass',
        removed: kicked,
        toFeature: featureLevel,
        toKx: {bobBox.publicKey: now, kickedBox.publicKey: now},
        box: adminBox,
        now: now,
      );
      expect(r.how, 'conflict');
      expect(r.x, isNull);
    });

    test('KxBook: a restarted phone (new key) is clear again later', () {
      final t0 = DateTime(2026, 1, 1);
      final seen = <String, DateTime>{};
      KxBook.record(seen, bobBox.publicKey, t0);
      KxBook.record(seen, 'not a key', t0);
      expect(KxBook.keyIn(seen, t0), bobBox.publicKey);
      KxBook.record(
        seen,
        kickedBox.publicKey,
        t0.add(const Duration(seconds: 1)),
      );
      expect(
        KxBook.conflictIn(seen, t0.add(const Duration(seconds: 2))),
        isTrue,
      );
      final later = t0.add(const Duration(seconds: 25));
      KxBook.record(seen, kickedBox.publicKey, later);
      expect(KxBook.keyIn(seen, later), kickedBox.publicKey);
    });
  });

  group('direct link setup sealed per phone', () {
    test(
      'sealed for the peer; others cannot open; older phones get plain',
      () async {
        final a = await PeerBox.create(), b = await PeerBox.create();
        final eve = await PeerBox.create();
        final x = {
          'op': 'o',
          's': 5,
          'tk': 'abcd',
          'c': ['1.2.3.4:5'],
        };
        final sealed = DirectSeal.seal(
          from: 1,
          to: 2,
          x: x,
          toFeature: featureLevel,
          toKx: _seen(b.publicKey),
          box: a,
        );
        expect(jsonEncode(sealed), isNot(contains('1.2.3.4')));
        expect(
          DirectSeal.open(
            from: 1,
            me: 2,
            x: sealed,
            fromKx: _seen(a.publicKey),
            box: b,
          ),
          x,
        );
        expect(
          DirectSeal.open(
            from: 1,
            me: 2,
            x: sealed,
            fromKx: _seen(a.publicKey),
            box: eve,
          ),
          isNull,
        );
        expect(
          DirectSeal.seal(
            from: 1,
            to: 2,
            x: x,
            toFeature: directFeature,
            toKx: const {},
            box: a,
          ),
          x,
        );
        // Plain messages from older phones still go through.
        expect(
          DirectSeal.open(from: 1, me: 2, x: x, fromKx: const {}, box: b),
          x,
        );
      },
    );

    test(
      'TransportManager keeps each phone\'s announced key from hellos',
      () async {
        final s = await RelayServer.bind(address: '127.0.0.1', port: 0);
        final uri = Uri.parse('ws://127.0.0.1:${s.port}/ws');
        final box = await PeerBox.create();
        final ms = <TransportManager>[];
        final ts = <MultiRelayTransport>[];
        for (final id in [0x31, 0x32]) {
          final t = MultiRelayTransport(serverUris: [uri]);
          final m = TransportManager(
            transports: [t],
            localNodeId: id,
            localName: 'p$id',
            channel: 7,
            helloInterval: const Duration(milliseconds: 100),
          );
          // 0x32 is new (kx), 0x31 an older phone (no kx).
          m.helloExtras = () => {
            'v': id == 0x32 ? featureLevel : 20,
            if (id == 0x32) 'kx': box.publicKey,
          };
          ms.add(m);
          ts.add(t);
          await m.start();
        }
        await _until(
          () =>
              ms[0].peer(0x32)?.kxSeen.isNotEmpty == true &&
              ms[1].peer(0x31) != null,
        );
        expect(
          KxBook.keyIn(ms[0].peer(0x32)!.kxSeen, DateTime.now()),
          box.publicKey,
        );
        expect(ms[1].peer(0x31)!.kxSeen, isEmpty);
        for (final m in ms) {
          await m.stop();
        }
        for (final t in ts) {
          await t.dispose();
        }
        await s.close();
      },
    );
  });

  group('strong passcodes for new private channels', () {
    test('rules', () {
      expect(Passcodes.problemForNew('abc123'), contains('at least 10'));
      expect(Passcodes.problemForNew('aaaaaaaaaaaa'), contains('easy'));
      expect(Passcodes.problemForNew('1234567890'), contains('easy'));
      expect(Passcodes.problemForNew('abcdefghij'), contains('easy'));
      expect(Passcodes.problemForNew('river-otter-42'), isNull);
      for (var i = 0; i < 50; i++) {
        final g = Passcodes.generate();
        expect(g.length, 12);
        expect(Passcodes.isStrong(g), isTrue, reason: g);
        expect(g, isNot(matches(RegExp('[01ilo]'))));
      }
      // Joining an existing channel (or one made by an older app) still
      // takes 6+ characters.
      expect(Passcodes.problemForJoin('abcdef'), isNull);
      expect(Passcodes.problemForJoin('abc'), isNotNull);
    });

    test(
      'key stretching unchanged: older phones derive the same key',
      () async {
        expect(ChannelKey.iterations, 120000);
        final a = await ChannelKey.deriveInline(3, 'abcdef');
        final b = await ChannelKey.deriveInline(3, ' abcdef ');
        expect(a.tag, b.tag);
        expect(a.fingerprint, b.fingerprint);
      },
    );
  });

  group('a clear home for private channels', () {
    testWidgets('Private channels section with lock, New and Join', (t) async {
      int? picked;
      var made = 0, joined = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChannelsView(
                current: 12,
                privateRows: const [
                  ChannelRow(12, title: 'Family', emoji: '🏕'),
                  ChannelRow(16),
                ],
                openRows: [
                  for (var i = 1; i <= 16; i++)
                    if (i != 12 && i != 16) ChannelRow(i),
                ],
                onPick: (c) => picked = c,
                onNewPrivate: () => made++,
                onJoinPrivate: () => joined++,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Private groups'), findsOneWidget);
      expect(find.text('Open channels'), findsOneWidget);
      expect(find.text('🏕 Family (CH 12)'), findsOneWidget);
      expect(find.byIcon(Icons.lock), findsNWidgets(3)); // title + 2 rows
      // Private ones are listed above the open ones, not mixed in.
      final privY = t.getTopLeft(find.byKey(const Key('channel-row-16'))).dy;
      final openY = t.getTopLeft(find.byKey(const Key('channel-row-1'))).dy;
      expect(privY, lessThan(openY));
      expect(find.byKey(const Key('channel-row-12')), findsOneWidget);
      await t.tap(find.byKey(const Key('new-private-channel')));
      await t.tap(find.byKey(const Key('join-private-channel')));
      await t.tap(find.byKey(const Key('channel-row-16')));
      expect((made, joined, picked), (1, 1, 16));
    });

    testWidgets('Unknown listener warning', (t) async {
      var tapped = false;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                UnknownListenerCard(
                  count: 2,
                  isPrivate: true,
                  onTap: () => tapped = true,
                ),
                const UnknownListenerCard(count: 1, isPrivate: false),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Unknown listener (2)'), findsOneWidget);
      expect(find.text('1 more connected without showing up'), findsOneWidget);
      await t.tap(find.byKey(const Key('unknown-listener')));
      expect(tapped, isTrue);
    });
  });
}
