// v2.6.9: Desktop USB sharing. The desktop app shares its radio link with
// other programs on this PC over a localhost Meshtastic TCP server
// (lib/lora/radio_share.dart). All radios, names and keys here are
// example data.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/friendly_error.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/gateway/stream_wire.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/lora/radio_share.dart';
import 'package:walkie_talkie/ui/radio_share_ui.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';

import 'home_layout_test.dart' show loadFonts;
import 'lora_proto_test.dart'
    show
        FakeRadioWire,
        configComplete,
        loraConfig,
        myInfo,
        nodeInfo,
        packetFrom,
        primaryChannel;

const myNode = 0x0B4F84FB;
const friend = 0x1A2B3C4D;

/// An example channel key (never a real one).
final examplePsk = List<int>.generate(32, (i) => 0xA0 + (i % 16));
final exampleWifi = 'example-wifi-pass'.codeUnits;
final exampleMqtt = 'example-mqtt-pass'.codeUnits;
final examplePrivate = List<int>.generate(32, (i) => 0x50 + (i % 7));

Uint8List configOf(int variant, Uint8List inner) =>
    (PbWriter()..message(5, (PbWriter()..message(variant, inner)).toBytes()))
        .toBytes();

Uint8List securityConfig() => configOf(
  8,
  (PbWriter()
        ..bytes(1, List.filled(32, 7))
        ..bytes(2, examplePrivate))
      .toBytes(),
);

Uint8List networkConfig() => configOf(
  4,
  (PbWriter()
        ..boolean(1, true)
        ..string(3, 'ExampleNet')
        ..bytes(4, exampleWifi))
      .toBytes(),
);

Uint8List bluetoothConfig() => configOf(
  7,
  (PbWriter()
        ..boolean(1, true)
        ..uint(2, 1)
        ..uint(3, 654321))
      .toBytes(),
);

Uint8List mqttModule() =>
    (PbWriter()..message(
          9,
          (PbWriter()..message(
                1,
                (PbWriter()
                      ..boolean(1, true)
                      ..string(2, 'mqtt.example.org')
                      ..string(3, 'exampleuser')
                      ..bytes(4, exampleMqtt))
                    .toBytes(),
              ))
              .toBytes(),
        ))
        .toBytes();

Uint8List rebooted() => (PbWriter()..boolean(8, true)).toBytes();

Uint8List queueStatus() =>
    (PbWriter()..message(
          11,
          (PbWriter()
                ..uint(2, 14)
                ..uint(3, 16))
              .toBytes(),
        ))
        .toBytes();

/// The app's download of the radio's settings and node list.
List<Uint8List> download() => [
  myInfo(myNode),
  nodeInfo(myNode, 'Skunk Ape', 'SKNK'),
  primaryChannel(psk: examplePsk, name: 'Example'),
  loraConfig(),
  securityConfig(),
  networkConfig(),
  bluetoothConfig(),
  mqttModule(),
  nodeInfo(friend, 'Yowie', 'YOWI'),
];

/// ToRadio{packet: MeshPacket{to, channel, decoded: Data}}.
Uint8List toRadioPacket({
  required int port,
  int to = meshBroadcast,
  int channel = 0,
  bool wantResponse = false,
  List<int> payload = const [1, 2, 3],
  bool encrypted = false,
}) {
  final pkt = PbWriter()
    ..fixed32(2, to)
    ..uint(3, channel);
  if (encrypted) {
    pkt.bytes(5, [9, 9, 9]);
  } else {
    pkt.message(
      4,
      MeshData(
        portnum: port,
        payload: Uint8List.fromList(payload),
        wantResponse: wantResponse,
      ).encode(),
    );
  }
  pkt.fixed32(6, 4242);
  return (PbWriter()..message(1, pkt.toBytes())).toBytes();
}

Uint8List wantConfig(int nonce) => ToRadio.wantConfig(nonce);

bool containsSeq(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// The app's radio link, faked: [refreshConfig] plays [frames] into the
/// hub like a real download.
class FakeLink implements RadioShareLink {
  FakeLink(this.hub, {List<Uint8List>? frames}) : frames = frames ?? download();
  final RadioShareHub hub;
  List<Uint8List> frames;
  final written = <Uint8List>[];
  int refreshes = 0;
  @override
  int? listenOnlySlot;

  @override
  Future<void> write(Uint8List toRadio) async => written.add(toRadio);

  @override
  Future<void> refreshConfig() async {
    refreshes++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    for (final f in frames) {
      hub.onFromRadio(f);
    }
    hub.onFromRadio(configComplete(555));
  }
}

/// A program on this PC speaking the Meshtastic stream protocol.
class Program {
  Program._(this.sock) {
    sock.listen(
      (b) => got.addAll(framer.add(b)),
      onDone: () => done = true,
      onError: (Object _) => done = true,
    );
    sock.done.catchError((Object _) => sock);
  }
  final Socket sock;
  final framer = StreamFramer();
  final got = <Uint8List>[];
  bool done = false;

  static Future<Program> connect(int port) async {
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final p = Program._(s);
    // Like the Python client: wake bytes first.
    s.add(StreamFramer.wake());
    return p;
  }

  void send(Uint8List toRadio) => sock.add(StreamFramer.frame(toRadio));

  Future<void> until(bool Function() ok, {int ms = 3000}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Top level field numbers of what it got (besides id).
  List<int> get kinds => [
    for (final g in got) pbDecode(g).firstWhere((f) => f.number != 1).number,
  ];

  int? get completeNonce {
    for (final g in got) {
      for (final f in pbDecode(g)) {
        if (f.number == 7) return f.asInt;
      }
    }
    return null;
  }

  Future<void> close() async => sock.destroy();
}

Future<void> settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late RadioShareHub hub;
  late FakeLink link;
  final programs = <Program>[];

  Future<Program> prog() async {
    final p = await Program.connect(hub.port!);
    programs.add(p);
    return p;
  }

  setUp(() async {
    hub = RadioShareHub();
    link = FakeLink(hub);
    expect(await hub.start(0), isTrue);
    hub.attach(link);
  });

  tearDown(() async {
    for (final p in programs) {
      await p.close();
    }
    programs.clear();
    await hub.dispose();
  });

  group('server', () {
    test('listens on 127.0.0.1 only and counts programs', () async {
      expect(hub.running, isTrue);
      expect(hub.port, greaterThan(0));
      expect(hub.clientCount, 0);
      final a = await prog();
      final b = await prog();
      await a.until(() => hub.clientCount == 2);
      await b.close();
      await a.until(() => hub.clientCount == 1);
      // Not reachable on another address of this PC.
      final others = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final i in others) {
        for (final addr in i.addresses) {
          if (addr.isLoopback) continue;
          await expectLater(
            Socket.connect(
              addr,
              hub.port!,
              timeout: const Duration(seconds: 1),
            ),
            throwsA(isA<SocketException>()),
          );
        }
      }
    });

    test('off: nothing runs, radio frames are ignored', () async {
      await hub.stop();
      expect(hub.running, isFalse);
      hub.onFromRadio(myInfo(myNode));
      hub.onFromRadio(configComplete(1));
      expect(hub.fromRadio, 0);
    });

    test('at most maxClients programs', () async {
      final small = RadioShareHub(maxClients: 1);
      await small.start(0);
      final a = await Program.connect(small.port!);
      await a.until(() => small.clientCount == 1);
      final b = await Program.connect(small.port!);
      await b.until(() => b.done);
      expect(small.clientCount, 1);
      await a.close();
      await small.dispose();
    });

    test('port in use: plain error with a free port fix', () async {
      final taken = hub.port!;
      final other = RadioShareHub();
      expect(await other.start(taken), isFalse);
      expect(other.problem, RadioShareProblem.portInUse);
      expect(other.running, isFalse);
      final s = AppSettings(nodeId: 1, channel: 1)
        ..radioShareLocal = true
        ..radioSharePort = taken;
      final fe = radioShareProblem(other, s)!;
      expect(fe.message, contains('Port $taken is already used'));
      expect(fe.fix, FixAction.useFreePort);
      expect(fe.fix2, FixAction.stopRadioShare);
      expect(FixAction.useFreePort.label, 'Use a free port');
      final free = await RadioShareHub.freePortAfter(taken);
      expect(free, isNotNull);
      expect(free, isNot(taken));
      expect(await other.start(free!), isTrue);
      expect(radioShareProblem(other, s), isNull);
      // Sharing off: never an error.
      s.radioShareLocal = false;
      expect(radioShareProblem(RadioShareHub(), s), isNull);
      await other.dispose();
    });

    test('address-in-use codes on Windows, Linux and macOS', () {
      for (final c in [10048, 98, 48]) {
        expect(
          RadioShareHub.isAddressInUse(
            SocketException('bind', osError: OSError('x', c)),
          ),
          isTrue,
        );
      }
      expect(
        RadioShareHub.isAddressInUse(
          SocketException('bind', osError: const OSError('denied', 13)),
        ),
        isFalse,
      );
    });
  });

  group('handshake (want_config per program)', () {
    test(
      'answered from the app\'s download, never sent to the radio',
      () async {
        final p = await prog();
        p.send(wantConfig(0x9ABCDEF1));
        await p.until(() => p.completeNonce != null);
        expect(p.completeNonce, 0x9ABCDEF1);
        expect(link.refreshes, 1);
        expect(link.written, isEmpty, reason: 'want_config stays local');
        // my_info, both node infos, channel, configs, module config, done.
        expect(p.kinds.first, 3);
        expect(p.kinds.where((k) => k == 4).length, 2);
        expect(p.kinds, contains(10));
        expect(p.kinds.last, 7);
      },
    );

    test('a second program within 2 min reuses the copy', () async {
      final a = await prog();
      a.send(wantConfig(11));
      await a.until(() => a.completeNonce == 11);
      final b = await prog();
      b.send(wantConfig(22));
      await b.until(() => b.completeNonce == 22);
      expect(link.refreshes, 1);
    });

    test('an old copy is downloaded again', () async {
      var now = DateTime(2026, 11, 6, 9);
      final h = RadioShareHub(clock: () => now);
      final l = FakeLink(h);
      await h.start(0);
      h.attach(l);
      final a = await Program.connect(h.port!);
      a.send(wantConfig(1));
      await a.until(() => a.completeNonce == 1);
      now = now.add(const Duration(minutes: 3));
      final b = await Program.connect(h.port!);
      b.send(wantConfig(2));
      await b.until(() => b.completeNonce == 2);
      expect(l.refreshes, 2);
      await a.close();
      await b.close();
      await h.dispose();
    });

    test('the app\'s own download fills the copy (no extra request)', () async {
      for (final f in download()) {
        hub.onFromRadio(f);
      }
      hub.onFromRadio(configComplete(777));
      final p = await prog();
      p.send(wantConfig(5));
      await p.until(() => p.completeNonce == 5);
      expect(link.refreshes, 0);
    });

    test('waits for the radio when the app is not connected yet', () async {
      hub.attach(null);
      final p = await prog();
      p.send(wantConfig(8));
      await settle(60);
      expect(p.completeNonce, isNull);
      hub.attach(link);
      await p.until(() => p.completeNonce == 8);
    });

    test('69420 (settings only) leaves out other nodes', () async {
      final p = await prog();
      p.send(wantConfig(wantConfigNoNodes));
      await p.until(() => p.completeNonce == wantConfigNoNodes);
      expect(p.kinds.where((k) => k == 4).length, 1);
      expect(p.kinds, contains(10));
    });

    test('69421 (node list only)', () async {
      final p = await prog();
      p.send(wantConfig(wantConfigOnlyNodes));
      await p.until(() => p.completeNonce == wantConfigOnlyNodes);
      expect(p.kinds.toSet(), {3, 4, 7});
    });
  });

  group('read-only (default) hides secrets', () {
    test('no channel key, private key, Wi-Fi / MQTT password or PIN', () async {
      expect(hub.access, RadioShareAccess.readOnly);
      final p = await prog();
      p.send(wantConfig(3));
      await p.until(() => p.completeNonce == 3);
      final all = [for (final g in p.got) ...g];
      expect(containsSeq(all, examplePsk), isFalse);
      expect(containsSeq(all, examplePrivate), isFalse);
      expect(containsSeq(all, exampleWifi), isFalse);
      expect(containsSeq(all, exampleMqtt), isFalse);
      // Still there: channel name, Wi-Fi name, MQTT server, LoRa config.
      expect(containsSeq(all, 'Example'.codeUnits), isTrue);
      expect(containsSeq(all, 'ExampleNet'.codeUnits), isTrue);
      expect(containsSeq(all, 'mqtt.example.org'.codeUnits), isTrue);
      final ch = p.got.firstWhere(
        (g) => pbDecode(g).any((f) => f.number == 10),
      );
      final pb = FromRadio.tryDecode(ch)!.channel!;
      expect(pb.name, 'Example');
      expect(pb.psk, isEmpty);
      // No security config at all.
      final cfgs = [
        for (final g in p.got)
          for (final f in pbDecode(g))
            if (f.number == 5) pbDecode(f.asBytes).first.number,
      ];
      expect(cfgs, isNot(contains(8)));
      expect(cfgs, containsAll([4, 6, 7]));
      // Bluetooth PIN gone.
      final bt = p.got.firstWhere(
        (g) => pbDecode(g)
            .any((f) => f.number == 5 && pbDecode(f.asBytes).first.number == 7),
      );
      final inner = pbDecode(
        pbDecode(pbDecode(bt).first.asBytes).first.asBytes,
      );
      expect(inner.map((f) => f.number), isNot(contains(3)));
    });

    test('redactForReadOnly leaves other frames byte for byte', () {
      for (final f in [myInfo(myNode), loraConfig(), nodeInfo(1, 'a', 'b')]) {
        expect(redactForReadOnly(f), f);
      }
      expect(redactForReadOnly(securityConfig()), isNull);
    });

    test('full access: frames go as the radio sent them', () async {
      hub.access = RadioShareAccess.full;
      final p = await prog();
      p.send(wantConfig(4));
      await p.until(() => p.completeNonce == 4);
      final all = [for (final g in p.got) ...g];
      expect(containsSeq(all, examplePsk), isTrue);
      expect(p.kinds.where((k) => k == 5).length, 4);
    });
  });

  group('radio -> programs', () {
    test('live packets go to every program after its handshake', () async {
      final a = await prog();
      final b = await prog();
      a.send(wantConfig(1));
      await a.until(() => a.completeNonce == 1);
      final before = a.got.length;
      hub.onFromRadio(
        packetFrom(friend, 'hello'.codeUnits, port: PortNum.text),
      );
      hub.onFromRadio(queueStatus());
      await a.until(() => a.got.length == before + 2);
      // b never asked for the config: nothing yet.
      await settle();
      expect(b.got, isEmpty);
      expect(a.kinds.sublist(before), [2, 11]);
    });

    test('settings answers stay out of read-only programs', () async {
      final p = await prog();
      p.send(wantConfig(1));
      await p.until(() => p.completeNonce == 1);
      final n = p.got.length;
      hub.onFromRadio(packetFrom(myNode, examplePsk, port: PortNum.admin));
      hub.onFromRadio(packetFrom(friend, [1], port: PortNum.position));
      await p.until(() => p.got.length == n + 1);
      await settle();
      expect(p.got.length, n + 1);
      expect(containsSeq([for (final g in p.got) ...g], examplePsk), isFalse);
    });

    test('a download the app asks for is not sent to programs', () async {
      final p = await prog();
      p.send(wantConfig(1));
      await p.until(() => p.completeNonce == 1);
      final n = p.got.length;
      for (final f in download()) {
        hub.onFromRadio(f);
      }
      hub.onFromRadio(configComplete(999));
      await settle();
      expect(p.got.length, n);
    });

    test('radio restarted: told, and the copy is fetched again', () async {
      final p = await prog();
      p.send(wantConfig(1));
      await p.until(() => p.completeNonce == 1);
      hub.onFromRadio(rebooted());
      await p.until(() => p.kinds.last == 8);
      final q = await prog();
      q.send(wantConfig(2));
      await q.until(() => q.completeNonce == 2);
      expect(link.refreshes, 2);
    });
  });

  group('programs -> radio', () {
    Future<Program> ready() async {
      final p = await prog();
      p.send(wantConfig(1));
      await p.until(() => p.completeNonce == 1);
      return p;
    }

    test('read-only: text and requests go, as sent', () async {
      final p = await ready();
      final text = toRadioPacket(port: PortNum.text, payload: 'hi'.codeUnits);
      final posReq = toRadioPacket(
        port: PortNum.position,
        to: friend,
        wantResponse: true,
      );
      final trace = toRadioPacket(
        port: RadioSharePorts.traceroute,
        to: friend,
        wantResponse: true,
      );
      final tele = toRadioPacket(
        port: PortNum.telemetry,
        to: friend,
        wantResponse: true,
      );
      final range = toRadioPacket(port: RadioSharePorts.rangeTest);
      for (final m in [text, posReq, trace, tele, range]) {
        p.send(m);
      }
      await p.until(() => link.written.length == 5);
      expect(link.written, [text, posReq, trace, tele, range]);
      expect(hub.blocked, 0);
    });

    test(
      'read-only: settings changes and the rest are blocked + logged',
      () async {
        final lines = <String>[];
        hub.log = lines.add;
        final p = await ready();
        final setConfig = (PbWriter()..message(34, Uint8List(2))).toBytes();
        p.send(
          toRadioPacket(port: PortNum.admin, to: myNode, payload: setConfig),
        );
        // A position broadcast (not a request), a Stalkie Talkie frame, an
        // encrypted packet.
        p.send(toRadioPacket(port: PortNum.position));
        p.send(toRadioPacket(port: PortNum.privateApp));
        p.send(toRadioPacket(port: PortNum.text, encrypted: true));
        await p.until(() => hub.blocked == 4);
        expect(link.written, isEmpty);
        final e = hub.events;
        expect(e.length, 4);
        expect(e.every((x) => !x.allowed), isTrue);
        expect(e.last.what, 'settings change (set config) (read-only)');
        expect(
          lines.where((l) => l.startsWith('Blocked settings change')),
          hasLength(1),
        );
        expect(lines.join('\n'), contains('127.0.0.1:'));
      },
    );

    test('full access: settings changes go and are logged', () async {
      hub.access = RadioShareAccess.full;
      final lines = <String>[];
      hub.log = lines.add;
      final p = await ready();
      final reboot = (PbWriter()..uint(97, 5)).toBytes();
      final m = toRadioPacket(port: PortNum.admin, to: myNode, payload: reboot);
      p.send(m);
      await p.until(() => link.written.length == 1);
      expect(link.written.single, m);
      expect(hub.settingsChanges, 1);
      expect(hub.events.first.allowed, isTrue);
      expect(hub.events.first.what, 'settings change (reboot)');
      expect(lines, contains(startsWith('Allowed settings change (reboot)')));
    });

    test('never on the listen-only public channel', () async {
      hub.access = RadioShareAccess.full;
      link.listenOnlySlot = 2;
      final p = await ready();
      p.send(toRadioPacket(port: PortNum.text, channel: 2));
      p.send(toRadioPacket(port: PortNum.text, channel: 0));
      await p.until(() => link.written.length == 1 && hub.blocked == 1);
      expect(hub.events.first.what, contains('listen-only public LongFast'));
    });

    test('heartbeat and disconnect stay local', () async {
      final p = await ready();
      p.send(ToRadio.heartbeat());
      await settle();
      expect(link.written, isEmpty);
      p.send(ToRadio.disconnect());
      await p.until(() => hub.clientCount == 0);
      expect(link.written, isEmpty);
    });

    test('too many at once are dropped (radio airtime)', () async {
      final p = await ready();
      for (var i = 0; i < 12; i++) {
        p.send(toRadioPacket(port: PortNum.text, payload: [i]));
      }
      await p.until(() => link.written.length + hub.blocked == 12);
      expect(link.written.length, 8);
      expect(hub.events.first.what, contains('too many at once'));
    });

    test('radio not connected: dropped', () async {
      final p = await ready();
      hub.attach(null);
      p.send(toRadioPacket(port: PortNum.text));
      await p.until(() => hub.blocked == 1);
      expect(link.written, isEmpty);
    });

    test('admin kinds', () {
      Uint8List a(int f) => (PbWriter()..uint(f, 1)).toBytes();
      expect(adminKind(a(34)), 'set config');
      expect(adminKind(a(33)), 'set channel');
      expect(adminKind(a(97)), 'reboot');
      expect(adminKind(a(99)), 'factory reset');
      final withKey =
          (PbWriter()
                ..bytes(101, [1, 2])
                ..uint(41, 1))
              .toBytes();
      expect(adminKind(withKey), 'set fixed position');
    });
  });

  group('the app\'s own link', () {
    test('session hands every frame to the hub, then handles it', () async {
      final wire = FakeRadioWire();
      final s = MeshtasticSession(wire);
      final h = RadioShareHub();
      await h.start(0);
      bindRadioShare(h, s);
      expect(h.radioAttached, isTrue);
      expect(s.rawTap, isNotNull);
      wire.queue.addAll([
        myInfo(myNode),
        nodeInfo(myNode, 'Skunk Ape', 'S'),
        configComplete(31),
      ]);
      await s.drain();
      expect(s.myNodeNum, myNode, reason: 'the app is unaffected');
      expect(s.nodes[myNode]!.longName, 'Skunk Ape');
      // The hub kept the app's download: a program is answered from it
      // without asking the radio again.
      final p = await Program.connect(h.port!);
      p.send(wantConfig(77));
      await p.until(() => p.completeNonce == 77);
      expect(p.kinds, [3, 4, 7]);
      expect(wire.written, isEmpty);
      await p.close();
      bindRadioShare(h, null);
      expect(h.radioAttached, isFalse);
      await s.close();
      await h.dispose();
    });

    test('a program\'s write goes through the session wire', () async {
      final wire = FakeRadioWire();
      final s = MeshtasticSession(wire);
      final l = SessionShareLink(s);
      final m = toRadioPacket(port: PortNum.text);
      await l.write(m);
      expect(wire.written.last, m);
      expect(l.listenOnlySlot, isNull);
      await s.close();
    });
  });

  group('settings', () {
    test('off by default, port 4403, read-only', () async {
      SharedPreferences.setMockInitialValues({});
      const store = SharedPrefsSettingsStore();
      final s = await store.load(defaultChannel: 1);
      expect(s.radioShareLocal, isFalse);
      expect(s.radioSharePort, 4403);
      expect(s.radioShareFull, isFalse);
      s
        ..radioShareLocal = true
        ..radioSharePort = 4410
        ..radioShareFull = true;
      await store.save(s);
      final again = await store.load(defaultChannel: 1);
      expect(again.radioShareLocal, isTrue);
      expect(again.radioSharePort, 4410);
      expect(again.radioShareFull, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('radio_share_local'), isTrue);
    });

    test('status text and how-to', () async {
      expect(radioShareStatusText(RadioShareHub()), 'Not running');
      expect(
        radioShareStatusText(hub),
        'On at 127.0.0.1:${hub.port} · no programs connected',
      );
      final p = await prog();
      await p.until(() => hub.clientCount == 1);
      expect(radioShareStatusText(hub), endsWith('1 program connected'));
      hub.attach(null);
      expect(radioShareStatusText(hub), endsWith('· radio not connected'));
      expect(radioShareHowTo(4403), contains("TCPInterface('127.0.0.1')"));
      expect(radioShareHowTo(4404), contains('portNumber=4404'));
      expect(radioShareHowTo(4404), contains('--host 127.0.0.1:4404'));
    });
  });

  group('Settings search', () {
    const pc = SettingsEnv(phone: false, wifiDirect: false);
    test('share radio / usb sharing / tcp / python / cli find it', () {
      for (final q in ['share radio', 'usb sharing', 'tcp', 'python', 'cli']) {
        final r = searchSettings(q, env: pc).map((e) => e.id);
        expect(r, contains('radio-share-local'), reason: q);
      }
      for (final q in ['usb sharing', 'python', 'cli']) {
        expect(searchSettings(q, env: pc).first.id, 'radio-share-local');
      }
      final e = settingsIndex.firstWhere((e) => e.id == 'radio-share-local');
      expect(e.path, 'Settings › Long-range radio (Meshtastic)');
      expect(e.needs, SettingNeeds.desktop);
    });

    test('not offered on phones', () {
      expect(
        searchSettings('usb sharing').map((e) => e.id),
        isNot(contains('radio-share-local')),
      );
    });

    test('anchor is on the Settings sheet radio section (desktop)', () {
      final src = File('lib/ui/radio_settings.dart').readAsStringSync();
      expect(
        RegExp(r"SettingAnchor\(\s*id:\s*'radio-share-local'").hasMatch(src),
        isTrue,
      );
      expect(src, contains('if (PlatformCaps.desktop)'));
      expect(
        File('lib/ui/radio_share_ui.dart').readAsStringSync(),
        contains("Text('Share radio with other programs on this PC')"),
      );
    });
  });

  group('README', () {
    test('documents sharing and range_test.py', () {
      final r = File('README.md').readAsStringSync();
      expect(r, contains('Share radio with other programs on this PC'));
      expect(r, contains("TCPInterface('127.0.0.1')"));
      expect(r, contains('range_test.py'));
      expect(r, contains('Read-only'));
    });
  });

  group('widgets (example data)', () {
    setUpAll(loadFonts);
    final dir = Platform.environment['V269_SHOTS'];

    Future<void> shot(WidgetTester t, String name, Widget body) async {
      t.view.physicalSize = const Size(420, 760) * 2;
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shotroot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
            home: Scaffold(
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.amber,
                    padding: const EdgeInsets.fromLTRB(8, 30, 8, 6),
                    child: const Text(
                      'EXAMPLE DATA: made-up programs and ports',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black, fontSize: 13),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: body,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      if (dir == null) return;
      final b = t.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shotroot')),
      );
      await t.runAsync(() async {
        final img = await b.toImage(pixelRatio: 2);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$dir/v269_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    final at = DateTime(2026, 11, 6, 10, 42);
    Widget section({
      bool on = true,
      bool full = false,
      FriendlyError? error,
      List<RadioShareEvent> events = const [],
      void Function(bool)? onToggle,
      void Function(bool)? onAccess,
    }) => RadioShareSection(
      on: on,
      status: 'On at 127.0.0.1:4403 · 1 program connected',
      port: 4403,
      full: full,
      error: error,
      events: events,
      onToggle: onToggle ?? (_) {},
      onPort: () {},
      onAccess: onAccess ?? (_) {},
      onFix: (_) {},
    );

    testWidgets('off: just the switch', (t) async {
      bool? toggled;
      await shot(t, 'off', section(on: false, onToggle: (v) => toggled = v));
      expect(
        find.text('Share radio with other programs on this PC'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('radioShareStatus')), findsNothing);
      await t.tap(find.byKey(const Key('radioShareLocal')));
      expect(toggled, isTrue);
    });

    testWidgets('on, read-only, a blocked change', (t) async {
      bool? access;
      await shot(
        t,
        'on_read_only',
        section(
          events: [
            RadioShareEvent(
              at,
              '127.0.0.1:53122',
              'settings change (set config) (read-only)',
              allowed: false,
            ),
          ],
          onAccess: (v) => access = v,
        ),
      );
      expect(
        find.text('On at 127.0.0.1:4403 · 1 program connected'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Read-only: programs can read'),
        findsOneWidget,
      );
      expect(
        find.text('10:42 AM  Blocked settings change (set config) (read-only)'),
        findsOneWidget,
      );
      await t.tap(find.text('Full access'));
      expect(access, isTrue);
    });

    testWidgets('full access, a logged change', (t) async {
      await shot(
        t,
        'full_access',
        section(
          full: true,
          events: [
            RadioShareEvent(
              at,
              '127.0.0.1:53122',
              'settings change (set owner)',
              allowed: true,
            ),
          ],
        ),
      );
      expect(find.textContaining('Every change is logged'), findsOneWidget);
    });

    testWidgets('port in use', (t) async {
      final s = AppSettings(nodeId: 1, channel: 1)..radioShareLocal = true;
      final h = RadioShareHub()..problem = RadioShareProblem.portInUse;
      await shot(t, 'port_in_use', section(error: radioShareProblem(h, s)));
      expect(find.textContaining('Port 4403 is already used'), findsOneWidget);
      expect(find.text('Use a free port'), findsOneWidget);
      expect(find.text('Turn off sharing'), findsOneWidget);
    });
  });
}
