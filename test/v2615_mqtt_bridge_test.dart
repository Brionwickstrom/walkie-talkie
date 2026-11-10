// v2.6.15: MQTT bridge through the user's broker.
// Config bytes, the confirm-before-write step, secret redaction, and
// settings search. No real radio and no NAS.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/debug_log.dart';
import 'package:walkie_talkie/app/friendly_error.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/mqtt/mesh_log.dart';
import 'package:walkie_talkie/mqtt/mqtt_client.dart';
import 'package:walkie_talkie/mqtt/mqtt_config.dart';
import 'package:walkie_talkie/mqtt/mqtt_radio.dart';
import 'package:walkie_talkie/mqtt/mqtt_secret.dart';
import 'package:walkie_talkie/ui/mqtt_bridge_section.dart';
import 'package:walkie_talkie/ui/settings_index.dart';
import 'package:walkie_talkie/ui/settings_search.dart';
import 'package:walkie_talkie/weather/wx_sample.dart';

/// Not a string literal, so a failure of expect(contains, isFalse) does not
/// print it from the source line.
final secretUnits = [115, 51, 99, 114, 101, 116, 45, 109, 113, 116, 116];
String get secret => String.fromCharCodes(secretUnits);

final psk = List<int>.generate(16, (i) => 0xA0 + i);

void expectBytes(List<int> got, List<int> want) {
  if (got.length != want.length) {
    fail('byte length ${got.length} != ${want.length}');
  }
  for (var i = 0; i < got.length; i++) {
    if (got[i] != want[i]) fail('bytes differ at $i');
  }
}

void expectHidden(String text) {
  expect(text.contains(secret), isFalse);
}

List<String> ids(String q) => [for (final e in searchSettings(q)) e.id];

Uint8List float32Field(int field, double v) {
  final d = ByteData(4)..setFloat32(0, v, Endian.little);
  return (BytesBuilder(copy: false)
        ..addByte((field << 3) | 5)
        ..add(d.buffer.asUint8List()))
      .toBytes();
}

class QuietWire implements MeshtasticWire {
  @override
  Future<void> write(Uint8List toRadio) async {}

  @override
  Future<Uint8List> read() async => Uint8List(0);

  @override
  Stream<void> get notifications => const Stream.empty();
}

class _Pipe implements MqttPipe {
  final _in = StreamController<List<int>>(sync: true);
  final sent = <Uint8List>[];

  @override
  Stream<List<int>> get incoming => _in.stream;

  void script(void Function(List<int> bytes) onBytes) => _on = onBytes;
  void Function(List<int> bytes)? _on;

  @override
  void add(List<int> bytes) {
    final copy = Uint8List.fromList(bytes);
    sent.add(copy);
    _on?.call(copy);
  }

  void emit(List<int> bytes) => _in.add(bytes);

  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
  }
}

/// Firmware stand-in: session key, module config, channel uplink.
class MqttFw implements MeshtasticWire {
  static const myNode = 0x1234ABCD;
  final passkey = Uint8List.fromList([9, 8, 7, 6]);
  final log = <String>[];
  final channels = <int, Uint8List>{};
  Uint8List? module;
  final _queue = <Uint8List>[];
  final _notify = StreamController<void>.broadcast();

  void _push(void Function(PbWriter w) f) {
    final w = PbWriter();
    f(w);
    _queue.add(w.toBytes());
  }

  void _serve(int nonce) {
    _push((w) => w.message(3, (PbWriter()..uint(1, myNode)).toBytes()));
    for (final c in channels.values) {
      _push((w) => w.message(10, c));
    }
    _push((w) => w.uint(7, nonce));
  }

  void _reply(void Function(PbWriter w) f) {
    final w = PbWriter();
    f(w);
    w.bytes(101, passkey);
    final pkt = MeshPacketPb(
      from: myNode,
      to: myNode,
      decoded: MeshData(portnum: PortNum.admin, payload: w.toBytes()),
    );
    _push((x) => x.message(2, pkt.encode()));
  }

  @override
  Future<void> write(Uint8List toRadio) async {
    for (final f in pbDecode(toRadio)) {
      if (f.number == 3) _serve(f.asInt);
      if (f.number == 1) _onPacket(MeshPacketPb.decode(f.asBytes));
    }
    _notify.add(null);
  }

  void _onPacket(MeshPacketPb p) {
    final d = p.decoded;
    if (d == null || d.portnum != PortNum.admin) return;
    final fields = pbDecode(d.payload);
    final hasKey = fields.any(
      (f) => f.number == 101 && _same(f.asBytes, passkey),
    );
    final first = fields.firstWhere((f) => f.number != 101);
    final isSet = {33, 35, 64, 65}.contains(first.number);
    if (isSet && !hasKey) {
      log.add('REJECTED:${first.number}');
      return;
    }
    switch (first.number) {
      case 1:
        final slot = first.asInt - 1;
        log.add('get:channel$slot');
        _reply(
          (w) => w.message(
            2,
            channels[slot] ?? (PbWriter()..uint(1, slot)).toBytes(),
          ),
        );
      case 7:
        log.add('get:module');
        _reply((w) {
          final m = module;
          if (m != null) w.message(8, m);
        });
      case 64:
        log.add('begin');
      case 35:
        log.add('set_module');
        module = Uint8List.fromList(first.asBytes);
      case 33:
        final slot =
            pbDecode(first.asBytes)
                .where((f) => f.number == 1)
                .map((f) => f.asInt)
                .firstOrNull ??
            0;
        log.add('set_channel$slot');
        channels[slot] = Uint8List.fromList(first.asBytes);
      case 65:
        log.add('commit');
        _push((w) => w.boolean(8, true));
    }
  }

  bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<Uint8List> read() async =>
      _queue.isEmpty ? Uint8List(0) : _queue.removeAt(0);

  @override
  Stream<void> get notifications => _notify.stream;
}

Uint8List channelMsg({
  required int index,
  required int role,
  required Uint8List settings,
}) =>
    (PbWriter()
          ..uint(1, index)
          ..message(2, settings)
          ..uint(3, role))
        .toBytes();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('config generation', () {
    test(
      'encryption on, JSON off, TLS from the port, password only in bytes',
      () {
        final draft = MqttModuleDraft(
          enabled: true,
          address: 'walkie-relay.tail1700cf.ts.net:8443',
          username: 'phone',
          password: secret,
          tls: true,
          root: defaultMqttRoot,
        );
        expectHidden(draft.toString());
        final module = draft.toModuleBytes();
        final view = MqttModuleView.tryModule(module)!;
        expect(view.enabled, isTrue);
        expect(view.encryptionEnabled, isTrue);
        expect(view.jsonEnabled, isFalse);
        expect(view.tlsEnabled, isTrue);
        expect(view.address, 'walkie-relay.tail1700cf.ts.net:8443');
        expect(view.root, defaultMqttRoot);
        expect(view.username, 'phone');
        expectBytes(view.passwordBytes, secretUnits);
        expectHidden(view.toString());
        final mqtt = pbDecode(module).single.asBytes;
        final numbers = [for (final f in pbDecode(mqtt)) f.number];
        expect(numbers, isNot(contains(6))); // json
        expect(numbers, isNot(contains(9))); // phone proxy
        expect(numbers, isNot(contains(10))); // map reports
      },
    );

    test('1883 is plain, 8443 is TLS, public broker and embedded passwords are refused', () {
      expect(tryParseMqttAddress('192.168.68.64:1883')!.tls, isFalse);
      expect(
        tryParseMqttAddress('walkie-relay.tail1700cf.ts.net:8443')!.tls,
        isTrue,
      );
      expect(tryParseMqttAddress('mqtts://nas.example:1883')!.tls, isTrue);
      expect(tryParseMqttAddress('phone:$secret@192.168.68.64:1883'), isNull);

      final embedded = prepareMqttWrite(
        radioReady: true,
        hasChannels: true,
        enabled: true,
        addressRaw: 'mqtt://phone:$secret@mqtt.meshtastic.org:1883',
        username: 'phone',
        rootRaw: '',
        hasPassword: true,
        channels: const [
          MqttChannelSnap(index: 0, name: 'BigfootNet', listenOnly: false),
        ],
      );
      expect(embedded.plan, isNull);
      expectHidden(embedded.problem!.message);
      expect(embedded.problem!.message, contains('password box'));

      final pub = prepareMqttWrite(
        radioReady: true,
        hasChannels: true,
        enabled: true,
        addressRaw: 'mqtt.meshtastic.org:1883',
        username: 'phone',
        rootRaw: '',
        hasPassword: true,
        channels: const [
          MqttChannelSnap(index: 0, name: 'BigfootNet', listenOnly: false),
        ],
      );
      expect(pub.plan, isNull);
      expect(pub.problem!.message, contains('public Meshtastic'));
      expect(pub.problem!.message, isNot(contains('mqtt.meshtastic.org')));
    });

    test(
      'preview lists uplink per channel and leaves public LongFast alone',
      () {
        final prep = prepareMqttWrite(
          radioReady: true,
          hasChannels: true,
          enabled: true,
          addressRaw: 'walkie-relay.tail1700cf.ts.net:8443',
          username: 'phone',
          rootRaw: '',
          hasPassword: true,
          channels: const [
            MqttChannelSnap(index: 0, name: 'BigfootNet', listenOnly: false),
            MqttChannelSnap(index: 1, name: 'LongFast', listenOnly: true),
            MqttChannelSnap(index: 2, name: 'Camp', listenOnly: false),
          ],
        );
        final plan = prep.plan!;
        expect(plan.root, defaultMqttRoot);
        expect(plan.tls, isTrue);
        expect(plan.channels[1].selected, isFalse);
        final text = mqttPreviewText(plan);
        expect(text, contains('Encryption: on'));
        expect(text, contains('JSON: off'));
        expect(text, contains('Password: saved, not shown'));
        expect(text, contains('BigfootNet: uplink on, downlink on'));
        expect(text, contains('LongFast: left alone (listen-only)'));
        expectHidden(text);
        final off = plan.channels[0].copyWith(selected: false);
        final text2 = mqttPreviewText(
          plan.copyWith(channels: [off, ...plan.channels.skip(1)]),
        );
        expect(text2, contains('BigfootNet: left as it is'));
      },
    );

    test('a missing radio or password is a plain error and not a plan', () {
      final radio = prepareMqttWrite(
        radioReady: false,
        hasChannels: true,
        enabled: true,
        addressRaw: '192.168.68.64:1883',
        username: 'phone',
        rootRaw: 'msh/stalkie',
        hasPassword: true,
        channels: const [
          MqttChannelSnap(index: 0, name: 'A', listenOnly: false),
        ],
      );
      expect(radio.plan, isNull);
      expect(radio.problem!.fix, MqttFix.connectRadio);

      final pass = prepareMqttWrite(
        radioReady: true,
        hasChannels: true,
        enabled: true,
        addressRaw: '192.168.68.64:1883',
        username: 'phone',
        rootRaw: 'msh/stalkie',
        hasPassword: false,
        channels: const [
          MqttChannelSnap(index: 0, name: 'A', listenOnly: false),
        ],
      );
      expect(pass.plan, isNull);
      expect(pass.problem!.fix, MqttFix.enterPassword);
      expectHidden(pass.problem!.message);
    });

    test(
      'channel patch turns uplink and downlink on and keeps the key bytes',
      () {
        final raw =
            (PbWriter()
                  ..bytes(2, psk)
                  ..string(3, 'BigfootNet')
                  ..uint(9, 42))
                .toBytes();
        final next = patchChannelBridge(raw, uplink: true, downlink: true);
        final fields = pbDecode(next);
        Uint8List? key;
        var up = false, down = false, extra = 0;
        for (final f in fields) {
          if (f.number == 2) key = f.asBytes;
          if (f.number == 5) up = f.asBool;
          if (f.number == 6) down = f.asBool;
          if (f.number == 9) extra = f.asInt;
        }
        expectBytes(key!, psk);
        expect(up, isTrue);
        expect(down, isTrue);
        expect(extra, 42);
      },
    );
  });

  group('confirm before write', () {
    test('cancel does not write; confirm does', () async {
      final plan = prepareMqttWrite(
        radioReady: true,
        hasChannels: true,
        enabled: true,
        addressRaw: '192.168.68.64:1883',
        username: 'phone',
        rootRaw: 'msh/stalkie',
        hasPassword: true,
        channels: const [
          MqttChannelSnap(index: 0, name: 'BigfootNet', listenOnly: false),
        ],
      ).plan!;
      var writes = 0;
      final cancelled = await runMqttConfigure(
        plan: plan,
        confirm: (_) async => null,
        write: (_) async => writes++,
      );
      expect(cancelled, isNull);
      expect(writes, 0);

      final done = await runMqttConfigure(
        plan: plan,
        confirm: (p) async => p,
        write: (_) async => writes++,
      );
      expect(done, isNull);
      expect(writes, 1);
    });

    testWidgets('the dialog previews, and Cancel writes nothing', (t) async {
      final plan = prepareMqttWrite(
        radioReady: true,
        hasChannels: true,
        enabled: true,
        addressRaw: 'walkie-relay.tail1700cf.ts.net:8443',
        username: 'phone',
        rootRaw: '',
        hasPassword: true,
        channels: const [
          MqttChannelSnap(index: 0, name: 'BigfootNet', listenOnly: false),
          MqttChannelSnap(index: 1, name: 'LongFast', listenOnly: true),
        ],
      ).plan!;
      var writes = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  final err = await runMqttConfigure(
                    plan: plan,
                    confirm: (p) => showMqttWritePreview(ctx, p),
                    write: (_) async => writes++,
                  );
                  expect(err, isNull);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('mqtt-preview')), findsOneWidget);
      expect(find.textContaining('Encryption: on'), findsOneWidget);
      expect(find.textContaining('Password: saved, not shown'), findsOneWidget);
      expect(find.textContaining('left alone (listen-only)'), findsOneWidget);
      expect(find.textContaining(secret), findsNothing);
      await t.tap(find.byKey(const Key('mqtt-cancel')));
      await t.pumpAndSettle();
      expect(writes, 0);

      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('mqtt-ch-0')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('mqtt-confirm')));
      await t.pumpAndSettle();
      // The confirm callback's result is consumed inside runMqttConfigure.
      // Tapping confirm with the box unchecked still confirms, and write runs.
      expect(writes, 1);
    });

    test('the radio is written only with the confirmed channels', () async {
      final fw = MqttFw();
      fw.channels[0] = channelMsg(
        index: 0,
        role: MeshChannelRole.primary,
        settings:
            (PbWriter()
                  ..bytes(2, psk)
                  ..string(3, 'BigfootNet')
                  ..uint(9, 42))
                .toBytes(),
      );
      fw.channels[1] = channelMsg(
        index: 1,
        role: MeshChannelRole.secondary,
        settings: meshPublicListenSettings(),
      );
      fw.channels[2] = channelMsg(
        index: 2,
        role: MeshChannelRole.secondary,
        settings:
            (PbWriter()
                  ..bytes(2, const [3, 3, 3, 3])
                  ..string(3, 'Camp'))
                .toBytes(),
      );
      final s = MeshtasticSession(
        fw,
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(hours: 1),
      );
      addTearDown(s.close);
      await s.start(timeout: const Duration(seconds: 2));
      expect(s.publicListenIndex, 1);
      final snaps = mqttSnapsOf(s);
      expect(snaps.map((c) => c.name), ['BigfootNet', 'LongFast', 'Camp']);
      expect(snaps[1].listenOnly, isTrue);

      final plan =
          prepareMqttWrite(
            radioReady: true,
            hasChannels: true,
            enabled: true,
            addressRaw: 'walkie-relay.tail1700cf.ts.net:8443',
            username: 'phone',
            rootRaw: '',
            hasPassword: true,
            channels: snaps,
          ).plan!.copyWith(
            channels: [
              for (final c in snaps)
                MqttChannelPlan(
                  index: c.index,
                  name: c.name,
                  listenOnly: c.listenOnly,
                  selected: c.index == 0,
                ),
            ],
          );
      final writer = MqttRadioWriter(
        () => s,
        replyTimeout: const Duration(seconds: 2),
        rebootWait: const Duration(milliseconds: 30),
        reconnectTimeout: const Duration(seconds: 3),
        poll: const Duration(milliseconds: 5),
        writeGap: Duration.zero,
      );
      final result = await writer.apply(plan, password: secret);
      expect(result.address, contains('8443'));
      expectHidden(result.toString());
      expectHidden(fw.log.join(' '));
      expect(fw.log, contains('set_module'));
      expect(fw.log, contains('set_channel0'));
      expect(fw.log, isNot(contains('set_channel1')));
      expect(fw.log, isNot(contains('set_channel2')));

      final view = MqttModuleView.tryModule(fw.module!)!;
      expect(view.encryptionEnabled, isTrue);
      expect(view.jsonEnabled, isFalse);
      expect(view.tlsEnabled, isTrue);
      expectBytes(view.passwordBytes, secretUnits);
      expectHidden(view.toString());

      final written = fw.channels[0]!;
      Uint8List? key;
      var up = false, down = false, extra = 0;
      for (final f in pbDecode(written)) {
        if (f.number == 2) {
          for (final s in pbDecode(f.asBytes)) {
            if (s.number == 2) key = s.asBytes;
            if (s.number == 5) up = s.asBool;
            if (s.number == 6) down = s.asBool;
            if (s.number == 9) extra = s.asInt;
          }
        }
      }
      expectBytes(key!, psk);
      expect(up, isTrue);
      expect(down, isTrue);
      expect(extra, 42);

      final pub = ChannelPb.decode(fw.channels[1]!);
      expect(pub.uplink, isFalse);
      expect(pub.downlink, isFalse);
    });
  });

  group('secret redaction', () {
    test(
      'logs, details, and the sealed file do not show the password',
      () async {
        expectHidden(redactLog('password: $secret on the broker'));
        expect(
          redactLog('password: $secret on the broker'),
          contains('password: [redacted]'),
        );
        expectHidden(redactLog('mqtt://phone:$secret@192.168.68.64:1883'));
        expect(
          redactLog('https://meshtastic.org/e/#$secret'),
          isNot(contains('#$secret')),
        );
        expectHidden(scrubDetails('password=$secret'));
        expectHidden(scrubMqttError('Handshake failed password: $secret'));

        final dir = await Directory.systemTemp.createTemp('mqtt-secret');
        addTearDown(() => dir.delete(recursive: true));
        final store = SecureMqttSecretStore(dir);
        await store.save(secret);
        expectBytes(utf8.encode((await store.read())!), secretUnits);
        final dumped = [
          ...File('${dir.path}/key').readAsBytesSync(),
          ...File('${dir.path}/box').readAsBytesSync(),
        ];
        expect(_contains(dumped, secretUnits), isFalse);
        await store.clear();
        expect(await store.read(), isNull);

        final prefs = File('lib/app/settings.dart').readAsStringSync();
        expect(prefs.contains('mqtt_password'), isFalse);
        expect(prefs.contains('_kMqtt'), isTrue);
      },
    );

    test('the node log drops payloads, JSON, and duplicate packets', () async {
      final packet =
          (BytesBuilder(copy: false)
                ..add(
                  (PbWriter()
                        ..fixed32(1, 0xAB)
                        ..fixed32(2, 0xFFFFFFFF)
                        ..bytes(5, secretUnits)
                        ..fixed32(6, 42)
                        ..uint(9, 3)
                        ..uint(12, -90)
                        ..uint(15, 4))
                      .toBytes(),
                )
                ..add(float32Field(8, 6.5)))
              .toBytes();
      final body =
          (PbWriter()
                ..message(1, packet)
                ..string(2, 'BigfootNet')
                ..string(3, 'ab'))
              .toBytes();

      final take = meshRecordFromPublish(
        body,
        topic: 'msh/stalkie/2/e/BigfootNet/!000000ab',
        root: 'msh/stalkie',
        at: DateTime.utc(2026, 11, 10, 12),
      );
      final rec = take.record!;
      expect(rec.encrypted, isTrue);
      expect(rec.plaintext, isFalse);
      expect(rec.nodeId, '!000000ab');
      expect(rec.channelName, 'BigfootNet');
      expect(rec.gatewayId, '!000000ab');
      expect(rec.rssi, -90);
      expect(rec.snr, closeTo(6.5, 0.01));
      expect(rec.hops, 1);
      expectHidden(rec.rangeLine());
      expectHidden(meshLogLine(rec));
      expect(_contains(utf8.encode(rec.rangeLine()), secretUnits), isFalse);

      final store = MqttLogStore();
      expect(store.add(rec), isTrue);
      expect(store.add(rec), isFalse);
      expect(store.accepted, 1);
      final nodes = store.nodesJson();
      expect(nodes, contains('!000000ab'));
      expectHidden(nodes);
      expect(_contains(utf8.encode(nodes), secretUnits), isFalse);

      final jsonBody = utf8.encode('{"psk":"$secret","lat":45}');
      final ignored = meshRecordFromPublish(
        jsonBody,
        topic: 'msh/stalkie/2/json/BigfootNet/!000000ab',
        root: 'msh/stalkie',
        at: DateTime.utc(2026, 11, 10, 12),
      );
      expect(ignored.record, isNull);
      expect(ignored.ignore, MqttIgnore.json);

      final dir = await Directory.systemTemp.createTemp('mqtt-log');
      addTearDown(() => dir.delete(recursive: true));
      final files = MqttLogFiles(dir);
      files.addTake(take);
      files.addTake(ignored);
      final onDisk = File('${dir.path}/nodes.json').readAsStringSync();
      expectHidden(onDisk);
      expect(_contains(utf8.encode(onDisk), secretUnits), isFalse);
      expect(
        File('${dir.path}/range.jsonl').readAsStringSync(),
        contains('BigfootNet'),
      );
      expectHidden(File('${dir.path}/status.json').readAsStringSync());
    });

    test(
      'a sign-in check reports reachability and does not echo the password',
      () async {
        final pipe = _Pipe();
        pipe.script((bytes) {
          if (bytes.isNotEmpty && bytes[0] == 0x10) {
            pipe.emit(const [0x20, 0x02, 0x00, 0x00]);
          }
        });
        final probe = await probeMqtt(
          host: '127.0.0.1',
          port: 1883,
          tls: false,
          username: 'phone',
          password: secret,
          open: ({
            required host,
            required port,
            required tls,
            required timeout,
          }) async => pipe,
        );
        expect(probe.ok, isTrue);
        expect(probe.line, 'Broker reachable');
        expectHidden(probe.line);
        expect(pipe.sent, hasLength(2));
        expect(_contains(pipe.sent.first, secretUnits), isTrue);
        expect(_contains(pipe.sent.last, secretUnits), isFalse);
        expect(
          mqttStatusLine(reach: probe.line, lastBridged: null),
          contains('No bridged packet yet'),
        );

        final down = await probeSavedBroker(
          address: 'mqtt.meshtastic.org:1883',
          username: 'phone',
          password: secret,
        );
        expect(down.ok, isFalse);
        expectHidden(down.line);
        expect(down.line, contains('public Meshtastic'));
      },
    );
  });

  group('settings search and version', () {
    test('mqtt, bridge, broker, internet and uplink find it', () {
      for (final q in ['mqtt', 'bridge', 'broker', 'internet', 'uplink']) {
        expect(ids(q), contains('mqtt-bridge'), reason: q);
      }
      final entry = settingsIndex.firstWhere((e) => e.id == 'mqtt-bridge');
      expect(entry.section, 'MQTT bridge');
      expect(entry.label, 'MQTT bridge');
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      expect(home, contains("id: 'mqtt-bridge'"));
      expect(home, contains(entry.label));
    });

    test('version 2.6.15+75 is in the changelog and the broker files', () {
      final p = File('pubspec.yaml').readAsStringSync();
      expect(p, contains('version: 2.6.15+75'));
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains('## v2.6.15: MQTT bridge'));
      expect(readme, contains('sudo mqtt/deploy.sh'));
      expect(readme, contains('8443'));
      expect(readme, contains('1883'));
      expect(readme, contains('Battery mode Saver'));
      final change = File('CHANGELOG.md').readAsStringSync();
      expect(change, contains('2.6.15+75'));
      final conf = File('mqtt/mosquitto.conf').readAsStringSync();
      expect(conf, contains('allow_anonymous false'));
      expect(conf, contains('listener 1883'));
      expect(conf, isNot(contains('meshtastic.org')));
      final compose = File('mqtt/docker-compose.yml').readAsStringSync();
      expect(compose, contains('unless-stopped'));
      expect(compose, contains('walkie-mqtt'));
      final deploy = File('mqtt/deploy.sh').readAsStringSync();
      expect(deploy, contains('tailscale funnel --bg --tcp=8443'));
      expect(deploy, contains('umask 077'));
      expect(deploy.contains(secret), isFalse);
    });

    test('the sample weather hook is still debug-only', () {
      final src = File('lib/weather/wx_sample.dart').readAsStringSync();
      expect(src, contains('debug && enabled'));
      expect(sampleWeatherActive(debug: false, enabled: true), isFalse);
      expect(sampleWeatherActive(debug: true, enabled: false), isFalse);
      expect(sampleWeatherActive(debug: true, enabled: true), isTrue);
    });

    test('a via-MQTT packet is remembered without being asked for', () {
      final s = MeshtasticSession(
        QuietWire(),
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(hours: 1),
      );
      s.myNodeNum = 1;
      s.handle(
        FromRadio(packet: MeshPacketPb(from: 2, to: 1, viaMqtt: true, id: 5)),
      );
      expect(s.lastViaMqtt, isNotNull);
      final raw =
          (PbWriter()
                ..boolean(14, true)
                ..fixed32(1, 9))
              .toBytes();
      expect(MeshPacketPb.decode(raw).viaMqtt, isTrue);
      expect(
        MeshPacketPb.decode((PbWriter()..fixed32(1, 9)).toBytes()).viaMqtt,
        isFalse,
      );
    });
  });
}

bool _contains(List<int> hay, List<int> needle) {
  if (needle.isEmpty || hay.length < needle.length) return false;
  for (var i = 0; i <= hay.length - needle.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
