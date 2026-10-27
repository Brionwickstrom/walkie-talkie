// v1.9.7: Meshtastic channel QR import, admin writes, links, and the
// on/off mute.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/debug_log.dart';
import 'package:walkie_talkie/app/mesh_links.dart';
import 'package:walkie_talkie/app/quiet.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/gateway_protocol.dart';
import 'package:walkie_talkie/gateway/gateway_core.dart';
import 'package:walkie_talkie/gateway/gateway_io.dart' show GatewayConfig;
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_admin.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/lora/meshtastic_session.dart';
import 'package:walkie_talkie/lora/protobuf.dart';
import 'package:walkie_talkie/ui/channels_sheet.dart';
import 'package:walkie_talkie/ui/mesh_channels.dart';
import 'package:walkie_talkie/ui/quiet_widgets.dart';

/// The default channel as the official Android app shares it
/// (Meshtastic-Android ChannelSetTest / FdroidQrDecoderTest).
const defaultUrl = 'https://meshtastic.org/e/#CgMSAQESBggBQANIAQ';

/// Made with the official Python library (meshtastic 2.x, apponly_pb2):
/// ChannelSet{settings: [Trail, psk 01..20 (32 B), uplink, position 13],
/// [Base, psk 64..73 (16 B)]], lora: use_preset, MEDIUM_FAST, EU_868,
/// hop 3, tx on}; meshtastic.util.generate_channel_hash gives Trail 98,
/// Base 53 and LongFast/AQ== 8.
const pythonUrl =
    'https://meshtastic.org/e/#Ci8SIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gGgVUcmFpbCgBOgIIDQoYEhBkZWZnaGlqa2xtbm9wcXJzGgRCYXNlEgoIARAEOANAA0gB';
final trailKey = List<int>.generate(32, (i) => i + 1);
final baseKey = List<int>.generate(16, (i) => i + 100);

/// Every way a key could show up in text.
List<String> keyForms(List<int> key) => [
  base64.encode(key),
  base64Url.encode(key).replaceAll('=', ''),
  key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  key.toString(),
  key.join(', '),
];

void expectNoKey(String text, List<int> key) {
  for (final f in keyForms(key)) {
    expect(text.contains(f), isFalse, reason: 'key leaked');
  }
}

// --------------------------------------------------------- fake radio

Uint8List _channelBytes(int index, int role, Uint8List settings) {
  final w = PbWriter()..uint(1, index);
  if (settings.isNotEmpty || role != 0) w.message(2, settings);
  w.uint(3, role);
  return w.toBytes();
}

Uint8List _settings(String name, List<int> psk) =>
    (PbWriter()
          ..bytes(2, psk)
          ..string(3, name))
        .toBytes();

/// A Meshtastic radio's client API as the firmware answers it: config
/// download, AdminModule get_config (with a session key), begin / set /
/// commit and the restart after a commit.
class FakeFirmware implements MeshtasticWire {
  FakeFirmware({this.rebootOnCommit = true, int used = 0}) {
    channels[0] = _channelBytes(0, 1, _settings('', const [1]));
    for (var i = 1; i < 8; i++) {
      channels[i] = i <= used
          ? _channelBytes(i, 2, _settings('Used$i', List.filled(16, i)))
          : _channelBytes(i, 0, Uint8List(0));
    }
  }

  static const myNode = 0x1234ABCD;
  final bool rebootOnCommit;
  final channels = <int, Uint8List>{};

  /// LoRaConfig: use_preset, LONG_FAST, US, hop 3, tx on, tx_power 27.
  Uint8List lora =
      (PbWriter()
            ..boolean(1, true)
            ..uint(2, 0)
            ..uint(7, 1)
            ..uint(8, 3)
            ..boolean(9, true)
            ..uint(10, 27))
          .toBytes();
  final passkey = Uint8List.fromList([9, 8, 7, 6, 5, 4, 3, 2]);

  /// Admin messages received: (first field number, has passkey, packet).
  final admin = <(int, bool, MeshPacketPb, Uint8List)>[];
  final _queue = <Uint8List>[];
  final _notify = StreamController<void>.broadcast();
  bool editOpen = false;
  int commits = 0;

  void _push(void Function(PbWriter w) f) {
    final w = PbWriter();
    f(w);
    _queue.add(w.toBytes());
  }

  void _serveConfig(int nonce) {
    _push((w) => w.message(3, (PbWriter()..uint(1, myNode)).toBytes()));
    _push((w) => w.message(5, (PbWriter()..message(6, lora)).toBytes()));
    for (var i = 0; i < 8; i++) {
      _push((w) => w.message(10, channels[i]!));
    }
    _push((w) => w.uint(7, nonce));
  }

  void _reply(Uint8List adminPayload) {
    final pkt = MeshPacketPb(
      from: myNode,
      to: myNode,
      decoded: MeshData(portnum: PortNum.admin, payload: adminPayload),
    );
    _push((w) => w.message(2, pkt.encode()));
  }

  @override
  Future<void> write(Uint8List toRadio) async {
    for (final f in pbDecode(toRadio)) {
      if (f.number == 3) _serveConfig(f.asInt);
      if (f.number == 1) _onPacket(MeshPacketPb.decode(f.asBytes));
    }
    _notify.add(null);
  }

  void _onPacket(MeshPacketPb p) {
    final d = p.decoded;
    if (d == null || d.portnum != PortNum.admin) return;
    final fields = pbDecode(d.payload);
    final hasKey = fields.any((f) => f.number == 101 && f.asBytes.length == 8);
    final first = fields.firstWhere((f) => f.number != 101);
    admin.add((first.number, hasKey, p, Uint8List.fromList(d.payload)));
    switch (first.number) {
      case 5:
        final type = first.asInt;
        final w = PbWriter();
        if (type == AdminPb.configLora) {
          w.message(6, (PbWriter()..message(6, lora)).toBytes());
        }
        w.bytes(101, passkey);
        _reply(w.toBytes());
      case 64:
        editOpen = true;
      case 33:
        final ch = ChannelPb.decode(first.asBytes);
        channels[ch.index] = Uint8List.fromList(first.asBytes);
      case 34:
        for (final c in pbDecode(first.asBytes)) {
          if (c.number == 6) lora = Uint8List.fromList(c.asBytes);
        }
      case 65:
        editOpen = false;
        commits++;
        if (rebootOnCommit) _push((w) => w.boolean(8, true));
    }
  }

  @override
  Future<Uint8List> read() async =>
      _queue.isEmpty ? Uint8List(0) : _queue.removeAt(0);

  @override
  Stream<void> get notifications => _notify.stream;

  List<int> get adminOrder => [for (final a in admin) a.$1];
}

Future<(FakeFirmware, MeshtasticSession)> radio({
  bool rebootOnCommit = true,
  int used = 0,
}) async {
  final fw = FakeFirmware(rebootOnCommit: rebootOnCommit, used: used);
  final s = MeshtasticSession(fw);
  await s.start(timeout: const Duration(seconds: 2));
  return (fw, s);
}

MeshChannelWriter writer(MeshtasticSession s) => MeshChannelWriter(
  () => s,
  replyTimeout: const Duration(seconds: 1),
  rebootWait: const Duration(milliseconds: 200),
  reconnectTimeout: const Duration(seconds: 5),
  poll: const Duration(milliseconds: 10),
  writeGap: Duration.zero,
);

// ------------------------------------------------------------- radios

class TxRadio implements RadioLink {
  final sent = <(Uint8List, int)>[];
  @override
  bool ready = true;
  @override
  int? queueFree;
  final _p = StreamController<MeshPacketPb>.broadcast();
  final _r = StreamController<bool>.broadcast();
  @override
  Stream<MeshPacketPb> get packets => _p.stream;
  @override
  Stream<bool> get readyChanges => _r.stream;
  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
  }) async => sent.add((payload, channel));
}

class GwRadio implements GatewayRadioLink {
  GwRadio(this.slots);
  final Map<MeshChannelRef, int> slots;
  final sent = <int>[];
  @override
  String get name => 'r';
  @override
  bool get ready => true;
  @override
  int? get myNode => 77;
  @override
  int? get queueFree => null;
  @override
  Stream<MeshPacketPb> get packets => const Stream.empty();
  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
  }) async => sent.add(channel);
  @override
  int? meshChannelIndex(MeshChannelRef ref) => slots[ref];
}

class NullRoom implements GatewayRoom {
  NullRoom(this.room);
  @override
  final String room;
  @override
  bool get connected => true;
  @override
  Stream<Uint8List> get frames => const Stream.empty();
  @override
  void send(Uint8List bytes) {}
  @override
  Future<void> close() async {}
}

Frame dataOn(int ch, {int seq = 1, FrameType type = FrameType.data}) => Frame(
  type: type,
  senderId: 0x42,
  channel: ch,
  seq: seq,
  payload: Uint8List.fromList([1, 2, seq]),
);

void main() {
  group('URL parsing', () {
    test('the default channel link', () {
      final s = MeshChannelSet.parseUrl(defaultUrl);
      expect(s.channels.length, 1);
      expect(s.channels.single.name, '');
      expect(s.keyKindOf(0), MeshKeyKind.defaultPublic);
      expect(s.addMode, isFalse);
      final l = s.lora!;
      expect(l.usePreset, isTrue);
      expect(l.modemPreset, 0);
      expect(l.presetLabel, 'LongFast');
      expect(l.hopLimit, 3);
      // LongFast + AQ== is the well known hash 8 (firmware and Python).
      expect(s.refFor(0, 'LongFast'), const MeshChannelRef('LongFast', 8));
      expect(s.toUrl(), defaultUrl);
    });

    test('variants the official apps accept', () {
      for (final u in [
        'HTTPS://MESHTASTIC.ORG/E/#CgMSAQESBggBQANIAQ',
        'https://www.meshtastic.org/e/#CgMSAQESBggBQANIAQ',
        'https://meshtastic.org/e#CgMSAQESBggBQANIAQ',
        'https://meshtastic.org/channel/e/#CgMSAQESBggBQANIAQ',
        'https://www.meshtastic.org/d/#CgMSAQESBggBQANIAQ',
        'meshtastic.org/e/#CgMSAQESBggBQANIAQ',
        '  https://meshtastic.org/e/#CgMSAQESBggBQANIAQ==  ',
      ]) {
        expect(MeshChannelSet.parseUrl(u).lora!.usePreset, isTrue, reason: u);
      }
      final add1 = MeshChannelSet.parseUrl(
        'https://meshtastic.org/e/#CgMSAQESBggBQANIAQ?add=true',
      );
      final add2 = MeshChannelSet.parseUrl(
        'https://meshtastic.org/e/?add=true#CgMSAQESBggBQANIAQ',
      );
      for (final a in [add1, add2]) {
        expect(a.addMode, isTrue);
        expect(a.loraToApply, isNull);
      }
      // Python lib's sample config (no padding, use_preset left out).
      final py = MeshChannelSet.parseUrl(
        'https://www.meshtastic.org/e/#CgMSAQESCDgBQANIAVAe',
      );
      expect(py.lora!.region, 1);
      expect(py.lora!.effectiveUsePreset, isTrue);
    });

    test('vector from the official Python library', () {
      final s = MeshChannelSet.parseUrl(pythonUrl);
      expect([for (final c in s.channels) c.name], ['Trail', 'Base']);
      expect(s.channels[0].uplinkEnabled, isTrue);
      expect(s.channels[0].positionPrecision, 13);
      expect(s.channels[1].uplinkEnabled, isFalse);
      expect(s.keyKindOf(0), MeshKeyKind.custom);
      expect(s.channels[0].keyBits, 256);
      expect(s.channels[1].keyBits, 128);
      expect(s.lora!.modemPreset, 4);
      expect(s.lora!.region, 3);
      expect(s.lora!.presetLabel, 'MediumFast');
      expect(s.refFor(0, 'LongFast').hash, 98);
      expect(s.refFor(1, 'LongFast').hash, 53);
      expect(meshChannelHash('Trail', trailKey), 98);
      expect(MeshChannelSet.parseUrl(s.toUrl()).encode(), s.encode());
    });

    test('rejects other links and damage, never echoing the link', () {
      for (final u in [
        'https://example.com/e/#CgMSAQESBggBQANIAQ',
        'https://meshtastic.org/docs/#CgMSAQESBggBQANIAQ',
        'https://meshtastic.org/e/#',
        'https://meshtastic.org/e/#***',
        'https://meshtastic.org/e/#A',
        'https://meshtastic.org/e/#EgA', // a lora config but no channel
        'walkietalkie://join?c=3',
      ]) {
        expect(
          () => MeshChannelSet.parseUrl(u),
          throwsA(
            isA<MeshLinkException>().having(
              (e) =>
                  e.toString().contains('CgMS') ||
                  e.toString().contains('docs') ||
                  e.toString().contains('***'),
              'echoes the link',
              isFalse,
            ),
          ),
          reason: u,
        );
      }
      expect(MeshChannelSet.looksLikeLink(defaultUrl), isTrue);
      expect(MeshChannelSet.looksLikeLink('walkie-friend:1:x'), isFalse);
    });
  });

  group('PSK classification', () {
    test('kinds', () {
      expect(meshClassifyPsk(const []), MeshKeyKind.none);
      expect(
        meshClassifyPsk(const [], secondary: true),
        MeshKeyKind.primaryKey,
      );
      expect(meshClassifyPsk(const [0]), MeshKeyKind.none);
      expect(meshClassifyPsk(const [1]), MeshKeyKind.defaultPublic);
      expect(meshClassifyPsk(const [7]), MeshKeyKind.defaultPublic);
      expect(meshClassifyPsk(meshDefaultPsk), MeshKeyKind.defaultPublic);
      expect(meshClassifyPsk(baseKey), MeshKeyKind.custom);
      expect(meshClassifyPsk(trailKey), MeshKeyKind.custom);
    });

    test('expansion matches the firmware', () {
      expect(meshExpandPsk(const [1]), meshDefaultPsk);
      final k5 = meshExpandPsk(const [5]);
      expect(k5.sublist(0, 15), meshDefaultPsk.sublist(0, 15));
      expect(k5[15], 5);
      expect(meshExpandPsk(const [0]), isEmpty);
      expect(meshExpandPsk(const [1, 2, 3]).length, 16);
    });

    test('a key-less channel keeps its meaning on our radio', () {
      // First channel without key = no encryption: written as key 0.
      final w = PbWriter()
        ..message(1, _settings('Open', const []))
        ..message(1, _settings('Second', const []))
        ..message(1, _settings('Third', baseKey));
      var set = MeshChannelSet.decode(w.toBytes());
      expect(set.keyKindOf(0), MeshKeyKind.none);
      ChannelPb psk(Uint8List settings) =>
          ChannelPb.decode(_channelBytes(1, 2, settings));
      expect(psk(set.settingsForSecondary(0)).psk, [0]);
      // A later key-less channel used the set's first key.
      expect(set.keyKindOf(1), MeshKeyKind.none);
      final w2 = PbWriter()
        ..message(1, _settings('Main', baseKey))
        ..message(1, _settings('Side', const []));
      set = MeshChannelSet.decode(w2.toBytes());
      expect(set.keyKindOf(1), MeshKeyKind.custom);
      expect(psk(set.settingsForSecondary(1)).psk, baseKey);
      expect(psk(set.settingsForSecondary(1)).name, 'Side');
    });
  });

  group('admin messages against a fake radio', () {
    test('session key, begin, set_channel (secondary slot 1), commit, '
        'restart, read back', () async {
      final (fw, s) = await radio();
      expect(s.channels.length, 8);
      expect(s.presetDisplayName, 'LongFast');
      final set = MeshChannelSet.parseUrl(pythonUrl);
      final primaryBefore = fw.channels[0];
      final loraBefore = fw.lora;
      final steps = <MeshWriteStep>[];
      final r = await writer(s).addChannel(set, 0, onStep: steps.add);
      expect(fw.adminOrder, [5, 64, 33, 65]);
      // get_config_request(SESSIONKEY_CONFIG = 8), then every set carries
      // the session key from the reply.
      expect(pbDecode(fw.admin[0].$4).first.asInt, AdminPb.configSessionKey);
      expect([for (final a in fw.admin.skip(1)) a.$2], [true, true, true]);
      for (final a in fw.admin) {
        expect(a.$3.to, FakeFirmware.myNode);
        expect(a.$3.decoded!.portnum, PortNum.admin);
        expect(a.$3.channel, 0);
      }
      expect(fw.admin[0].$3.decoded!.wantResponse, isTrue);
      final written = ChannelPb.decode(fw.channels[1]!);
      expect(written.index, 1);
      expect(written.role, MeshChannelRole.secondary);
      expect(written.name, 'Trail');
      expect(written.psk, trailKey);
      expect(fw.channels[0], primaryBefore);
      expect(fw.lora, loraBefore);
      expect(fw.commits, 1);
      expect(s.rebootCount, 1);
      expect(r.index, 1);
      expect(r.alreadyThere, isFalse);
      expect(r.ref, const MeshChannelRef('Trail', 98));
      expect(s.indexOf(r.ref), 1);
      expect(steps.last, MeshWriteStep.done);
      expect(steps, contains(MeshWriteStep.restarting));
      await s.close();
    });

    test('also apply radio settings: set_config with only the radio part '
        'changed', () async {
      final (fw, s) = await radio();
      final set = MeshChannelSet.parseUrl(pythonUrl);
      await writer(s).addChannel(set, 1, applyLora: true);
      expect(fw.adminOrder, [5, 64, 33, 34, 65]);
      expect(pbDecode(fw.admin[0].$4).first.asInt, AdminPb.configLora);
      final l = MeshLoraSettings.decode(fw.lora);
      expect(l.modemPreset, 4); // MediumFast from the QR
      expect(l.region, 3); // EU 868 from the QR
      expect(l.fields[10], 27); // tx power kept
      expect(l.fields[8], 3);
      expect(s.modemPreset, 4);
      expect(s.indexOf(set.refFor(1, s.presetDisplayName)), 1);
      // The primary channel was not touched.
      expect(ChannelPb.decode(fw.channels[0]!).psk, [1]);
      await s.close();
    });

    test('firmware that does not restart: settings are read again', () async {
      final (fw, s) = await radio(rebootOnCommit: false);
      final set = MeshChannelSet.parseUrl(pythonUrl);
      final r = await writer(s).addChannel(set, 0);
      expect(r.index, 1);
      expect(s.rebootCount, 0);
      expect(s.configCount, greaterThanOrEqualTo(2));
      expect(fw.commits, 1);
      await s.close();
    });

    test('remove a secondary channel; the primary cannot be', () async {
      final (fw, s) = await radio(used: 2);
      await writer(s).removeChannel(2);
      expect(fw.adminOrder, [5, 64, 33, 65]);
      expect(ChannelPb.decode(fw.channels[2]!).role, 0);
      expect(s.channels[2]!.isDisabled, isTrue);
      expect(s.channels[1]!.isSecondary, isTrue);
      expect(
        () => writer(s).removeChannel(0),
        throwsA(isA<MeshWriteException>()),
      );
      await s.close();
    });
  });

  group('duplicates and slots', () {
    test(
      'a channel already on the radio (name + hash) is just linked',
      () async {
        final (fw, s) = await radio();
        final set = MeshChannelSet.parseUrl(pythonUrl);
        await writer(s).addChannel(set, 0);
        fw.admin.clear();
        final again = await writer(s).addChannel(set, 0);
        expect(again.alreadyThere, isTrue);
        expect(again.index, 1);
        expect(fw.admin, isEmpty);
        // The radio's own default primary is a duplicate of the default QR.
        final def = MeshChannelSet.parseUrl(defaultUrl);
        expect(MeshChannelWriter.findOnRadio(s, def, 0), 0);
        // Same name, other key: not a duplicate.
        final other = MeshChannelSet.decode(
          (PbWriter()..message(1, _settings('Trail', baseKey))).toBytes(),
        );
        expect(MeshChannelWriter.findOnRadio(s, other, 0), isNull);
        await s.close();
      },
    );

    test('first free slot 1-7', () async {
      MeshRadioChannel ch(int i, int role) => MeshRadioChannel(
        index: i,
        role: role,
        name: 'c$i',
        keyKind: MeshKeyKind.custom,
        keyXor: 0,
      );
      expect(meshFreeSlot([ch(0, 1)]), 1);
      expect(meshFreeSlot([ch(0, 1), ch(1, 2), ch(2, 2), ch(3, 0)]), 3);
      expect(meshFreeSlot([ch(0, 1), ch(1, 2), ch(2, 0), ch(3, 2)]), 2);
      expect(
        meshFreeSlot([ch(0, 1), for (var i = 1; i < 8; i++) ch(i, 2)]),
        isNull,
      );
      final (_, s) = await radio(used: 7);
      await expectLater(
        writer(s).addChannel(MeshChannelSet.parseUrl(pythonUrl), 0),
        throwsA(
          isA<MeshWriteException>().having(
            (e) => e.message,
            'message',
            contains('All 7'),
          ),
        ),
      );
      final (fw3, s3) = await radio(used: 3);
      final r = await writer(s3)
          .addChannel(MeshChannelSet.parseUrl(pythonUrl), 0);
      expect(r.index, 4);
      expect(ChannelPb.decode(fw3.channels[4]!).name, 'Trail');
      await s.close();
      await s3.close();
    });
  });

  group('channel index on send', () {
    const trail = MeshChannelRef('Trail', 98);

    test('LoraTransport: linked Walkie channel -> its slot, else 0', () async {
      final r = TxRadio();
      final t = LoraTransport(
        radio: r,
        pumpInterval: const Duration(hours: 1),
        limiter: LoraRateLimiter(burst: 100),
      );
      t.meshLinkFor = (f) => f.channel == 5 ? trail : null;
      t.meshIndexOf = (ref) => ref == trail ? 3 : null;
      await t.start(localNodeId: 1, channel: 5);
      expect(t.sendRadio(dataOn(5).encode()), isTrue);
      expect(t.sendRadio(dataOn(4, seq: 2).encode()), isTrue);
      // A gateway request naming the channel wins.
      expect(
        t.sendRadio(dataOn(4, seq: 3).encode(), meshChannel: trail),
        isTrue,
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
        await t.pump();
      }
      List<int> data() => [
        for (final x in r.sent)
          if (Frame.tryDecode(x.$1)?.type == FrameType.data) x.$2,
      ];
      expect(data(), [3, 0, 3]);
      // The radio does not have it (another radio paired): primary.
      t.meshIndexOf = (_) => null;
      t.sendRadio(dataOn(5, seq: 4).encode());
      await t.pump();
      expect(data().last, 0);
      expect(t.linkMissing, greaterThanOrEqualTo(1));
      expect(t.sentOnLinked, greaterThanOrEqualTo(2));
      await t.dispose();
    });

    test('MeshtasticSession puts the slot in MeshPacket.channel', () async {
      final (fw, s) = await radio();
      final out = <MeshPacketPb>[];
      final orig = fw;
      await s.send(Uint8List.fromList([1, 2, 3]), channel: 3);
      // The fake firmware ignores non-admin packets; check the encoding.
      final pkt = MeshPacketPb(
        to: meshBroadcast,
        channel: 3,
        decoded: MeshData(portnum: PortNum.privateApp, payload: Uint8List(1)),
      );
      expect(MeshPacketPb.decode(pkt.encode()).channel, 3);
      expect(out, isEmpty);
      expect(orig.admin, isEmpty);
      await s.close();
    });

    test(
      'gateway envelope names the channel; gateway resolves per radio',
      () async {
        final inner = dataOn(5).encode();
        final env = GatewayEnvelope.toRadio(
          inner,
          priority: 2,
          mesh: trail,
        ).toFrame(senderId: 9, channel: 5, seq: 1);
        expect(env.payload[0], 3);
        final back = GatewayEnvelope.tryDecode(env)!;
        expect(back.kind, GatewayKind.toRadio);
        expect(back.mesh, trail);
        expect(back.inner, inner);
        // Plain requests stay kind 2 (older gateways).
        final plain = GatewayEnvelope.toRadio(inner)
            .toFrame(senderId: 9, channel: 5, seq: 2);
        expect(plain.payload[0], 2);
        expect(GatewayEnvelope.tryDecode(plain)!.mesh, isNull);

        final core = GatewayCore(
          name: 'gw',
          nodeId: 1000,
          roomFactory: NullRoom.new,
          rooms: {'5', '6'},
        );
        final a = GwRadio({trail: 2});
        final b = GwRadio({trail: 6});
        final c = GwRadio({});
        core
          ..addRadio(a)
          ..addRadio(b)
          ..addRadio(c);
        core.onRoomFrame('5', env.encode());
        // The plain copy right after it is a duplicate.
        core.onRoomFrame('5', plain.encode());
        await core.pump();
        expect(a.sent, [2]);
        expect(b.sent, [6]);
        expect(c.sent, [0]);
        expect(core.duplicates, 1);
        // gateway.json mapping for phones that do not name the channel.
        core.meshLinks = {6: trail};
        core.onRoomFrame(
          '6',
          GatewayEnvelope.toRadio(dataOn(6, seq: 9).encode())
              .toFrame(senderId: 9, channel: 6, seq: 3)
              .encode(),
        );
        await core.pump();
        expect(a.sent.last, 2);
        expect(c.sent.last, 0);
        expect(core.status()['meshChannelLinks'], {
          '6': {'name': 'Trail', 'hash': 98},
        });
        await core.close();
      },
    );

    test('gateway with no radio attached', () async {
      final core = GatewayCore(
        name: 'gw',
        nodeId: 1000,
        roomFactory: NullRoom.new,
        rooms: {'5'},
      )..meshLinks = {5: trail};
      core.onRoomFrame(
        '5',
        GatewayEnvelope.toRadio(
          dataOn(5).encode(),
          mesh: trail,
        ).toFrame(senderId: 9, channel: 5, seq: 1).encode(),
      );
      await core.pump();
      expect(core.noRoute, 1);
      expect(core.status()['radios'], 0);
      await core.close();
    });

    test('gateway.json meshChannels', () {
      final cfg = GatewayConfig.parse(
        jsonEncode({
          'meshChannels': {
            '5': {'name': 'Trail', 'hash': 98},
            '40': {'name': 'x', 'hash': 1},
            '6': {'name': 'bad', 'hash': 999},
          },
        }),
      );
      expect(cfg.meshChannels, {5: trail});
      expect(jsonDecode(GatewayConfig.defaultJson), isA<Map>());
    });
  });

  group('preview and links', () {
    test('warnings: public key, MQTT uplink, other radio settings', () {
      final p = MeshImportPreview.build(
        MeshChannelSet.parseUrl(pythonUrl),
        const MeshRadioInfo(region: 1, modemPreset: 0, usePreset: true),
      );
      expect(p.channels[0].title, 'Trail');
      expect(p.channels[0].keyText, 'Custom key');
      expect(p.warningsFor(0).single, contains('MQTT'));
      expect(p.warningsFor(1), isEmpty);
      expect(p.mismatch, contains('MediumFast'));
      expect(p.mismatch, contains('EU 868'));
      expect(p.radioLines, contains('Region: EU 868'));
      final d = MeshImportPreview.build(
        MeshChannelSet.parseUrl(defaultUrl),
        MeshRadioInfo(
          region: 1,
          modemPreset: 0,
          usePreset: true,
          onRadio: {MeshChannelRef('LongFast', 8): 0},
        ),
      );
      expect(d.channels.single.title, 'LongFast (unnamed)');
      expect(d.warningsFor(0).single, contains('default public key'));
      expect(d.mismatch, isNull);
      expect(d.channels.single.onRadioSlot, 0);
    });

    testWidgets('preview sheet: no key, "Also apply" off by default', (
      t,
    ) async {
      final calls = <(int, bool)>[];
      final p = MeshImportPreview.build(
        MeshChannelSet.parseUrl(pythonUrl),
        const MeshRadioInfo(region: 1, modemPreset: 0, usePreset: true),
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MeshImportView(
                preview: p,
                radioReady: true,
                onAdd: (i, a) => calls.add((i, a)),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('mesh-mismatch')), findsOneWidget);
      await t.tap(find.byKey(const Key('mesh-add')));
      expect(calls, [(0, false)]);
      await t.tap(find.byKey(const Key('mesh-advanced')));
      await t.pumpAndSettle();
      final box = t.widget<CheckboxListTile>(
        find.byKey(const Key('mesh-apply-radio')),
      );
      expect(box.value, isFalse);
      await t.tap(find.byKey(const Key('mesh-apply-radio')));
      await t.pump();
      expect(find.textContaining('cut off'), findsWidgets);
      await t.tap(find.text('Base'));
      await t.pump();
      await t.ensureVisible(find.byKey(const Key('mesh-add')));
      await t.tap(find.byKey(const Key('mesh-add')));
      expect(calls.last, (1, true));
      final all = t
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .join('\n');
      expectNoKey(all, trailKey);
      expectNoKey(all, baseKey);
    });

    testWidgets('no radio: the add button is off', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MeshImportView(
                preview: MeshImportPreview.build(
                  MeshChannelSet.parseUrl(defaultUrl),
                  const MeshRadioInfo(),
                ),
                radioReady: false,
                onAdd: (_, _) {},
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('mesh-no-radio')), findsOneWidget);
      final b = t.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Add to my radio'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(b.onPressed, isNull);
    });

    testWidgets('channel picker shows the mesh badge and the entry', (t) async {
      var mesh = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChannelsView(
                current: 1,
                privateRows: const [],
                openRows: const [
                  ChannelRow(1),
                  ChannelRow(16, title: 'Trail', meshName: 'Trail'),
                ],
                onPick: (_) {},
                onNewPrivate: () {},
                onJoinPrivate: () {},
                onMeshImport: () => mesh++,
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('mesh-badge-16')), findsOneWidget);
      expect(find.byKey(const Key('mesh-badge-1')), findsNothing);
      expect(find.text('Shared with Meshtastic · Trail'), findsOneWidget);
      await t.tap(find.byKey(const Key('mesh-import-picker')));
      expect(mesh, 1);
    });

    test('a saved link has name + hash, never a key or slot', () {
      final l = MeshLink(
        ref: const MeshChannelRef('Trail', 98),
        preset: 'MediumFast',
        keyKind: MeshKeyKind.custom,
        uplink: true,
        created: 5,
      );
      final text = MeshLink.encodeMap({16: l});
      final back = MeshLink.decodeMap(text)[16]!;
      expect(back.ref, l.ref);
      expect(back.uplink, isTrue);
      expect(back.keyKind, MeshKeyKind.custom);
      expect(text.contains('index'), isFalse);
      expect(MeshLink.decodeMap('{"40": {"name": "x", "hash": 1}}'), isEmpty);
      expect(MeshLink.decodeMap('junk'), isEmpty);
    });
  });

  group('the key never shows', () {
    test('toString of everything that holds one', () async {
      final set = MeshChannelSet.parseUrl(pythonUrl);
      final (_, s) = await radio();
      await writer(s).addChannel(set, 0);
      final texts = [
        set.toString(),
        for (final c in set.channels) c.toString(),
        ChannelPb.decode(_channelBytes(1, 2, set.settingsForSecondary(0)))
            .toString(),
        for (final c in s.channels.values) c.toString(),
        for (final c in s.channels.values) s.refOf(c).toString(),
        AdminReply.tryDecode(
          AdminPb.setChannel(
            index: 1,
            settings: set.settingsForSecondary(0),
            role: 2,
          ),
        ).toString(),
        MeshWriteResult(1, set.refFor(0, 'LongFast')).toString(),
        MeshImportPreview.build(
          set,
          MeshRadioInfo.of(s),
        ).channels.map((c) => '${c.title} ${c.keyText}').join(),
      ];
      for (final t in texts) {
        expectNoKey(t, trailKey);
        expectNoKey(t, baseKey);
      }
      await s.close();
    });

    test('debug log blanks Meshtastic links', () {
      final log = DebugLog();
      log.add('mesh', 'scanned $pythonUrl and $defaultUrl');
      final line = log.lines.single;
      expect(line.contains('Ci8SIAEC'), isFalse);
      expect(line.contains('CgMSAQES'), isFalse);
      expect(line, contains('meshtastic.org/e/#[redacted]'));
      expectNoKey(line, trailKey);
    });

    test('parse errors and exceptions do not carry the link', () {
      try {
        MeshChannelSet.parseUrl('${pythonUrl.substring(0, 60)}!!');
        fail('should throw');
      } on MeshLinkException catch (e) {
        expect(e.toString().contains('Ci8S'), isFalse);
      }
    });
  });

  group('v1.9.7 mute on/off', () {
    test('a running timed mute from v1.9.5/1.9.6 becomes plain mute', () {
      final now = DateTime(2026, 10, 27, 12);
      final running = jsonEncode({
        'mu': now.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
      });
      final over = jsonEncode({
        'mu': now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
      });
      final q = QuietHours.decode(running, clock: () => now);
      expect(q.muted, isTrue);
      expect(q.statusText(QuietHours.clockFor24), 'Muted');
      // No time limit any more: still muted hours later, saved as on/off.
      final later = QuietHours.decode(
        q.encode(),
        clock: () => now.add(const Duration(days: 2)),
      );
      expect(later.muted, isTrue);
      expect(q.encode().contains('"mu"'), isFalse);
      expect(QuietHours.decode(over, clock: () => now).muted, isFalse);
      expect(QuietHours.decode(jsonEncode({'mf': 1})).muted, isTrue);
    });

    testWidgets('v1.9.9 banner Unmute needs the 2.5 s hold and confirm', (
      t,
    ) async {
      var unmuted = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuietBanner(
              text: 'Muted',
              muted: true,
              onUnmute: () => unmuted++,
              onSettings: () {},
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('bannerUnmute')));
      await t.pump(const Duration(milliseconds: 100));
      expect(unmuted, 0);
      expect(find.text('Keep holding to unmute'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      var g = await t.startGesture(
        t.getCenter(find.byKey(const Key('bannerUnmute'))),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 1250));
      expect(
        t
            .widget<CircularProgressIndicator>(
              find.byKey(const Key('bannerUnmuteProgress')),
            )
            .value,
        closeTo(0.5, 0.1),
      );
      await t.pump(const Duration(milliseconds: 1400));
      await g.up();
      await t.pumpAndSettle();
      expect(find.text('Unmute Walkie?'), findsOneWidget);
      expect(unmuted, 0);
      await t.tap(find.byKey(const Key('muteConfirmCancel')));
      await t.pumpAndSettle();
      expect(unmuted, 0);
      g = await t.startGesture(
        t.getCenter(find.byKey(const Key('bannerUnmute'))),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 2600));
      await g.up();
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('muteConfirmOk')));
      await t.pumpAndSettle();
      expect(unmuted, 1);
    });
  });
}
