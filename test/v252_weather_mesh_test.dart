// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/lora/meshtastic_proto.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/ui/home_view.dart';
import 'package:walkie_talkie/ui/person_sheet.dart';
import 'package:walkie_talkie/ui/weather_alerts_page.dart';
import 'package:walkie_talkie/weather/alert_store.dart';
import 'package:walkie_talkie/weather/nws_client.dart';
import 'package:walkie_talkie/weather/weather_alerts.dart';
import 'package:walkie_talkie/weather/wx_alert.dart';
import 'package:walkie_talkie/weather/wx_codec.dart';
import 'package:walkie_talkie/weather/wx_keys.dart';
import 'package:walkie_talkie/weather/wx_mesh.dart';
import 'package:walkie_talkie/weather/wx_notice.dart';

import 'fake_transport.dart';
import 'v231_helpers.dart';
import 'v250_weather_test.dart' show FakeNws, alertOf, collection, feat, t0;

// v2.5.2, stage 2: signed weather alerts over the relay rooms and the LoRa
// radio, per-device Ed25519 keys, trust, and one notification across paths.

const pt = GeoPoint(45.5231, -122.6765);

class FakeTimer implements Timer {
  FakeTimer(this.delay, this.cb);
  final Duration delay;
  final void Function() cb;
  bool cancelled = false, fired = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => 0;
}

/// One phone or PC: its store, NWS service, key and mesh, with fake rooms
/// and a fake radio.
class Dev {
  Dev._(this.id, this.name);
  final int id;
  final String name;
  DateTime now = t0;
  final nws = FakeNws();
  late AlertStore store;
  late WeatherAlerts service;
  late WxDeviceKey key;
  late WxMesh mesh;
  late WxRooms rooms;
  final roomsUp = <String, FakeTransport>{};
  final timers = <FakeTimer>[];
  final notified = <WxAlert>[];
  final cleared = <WxAlert>[];
  final radioOut = <Frame>[];
  bool radioUp = true;
  int budget = 188;
  bool share = true;
  final trusted = <String>{};
  final names = <String, String>{};
  List<WxWatchPoint> pts = const [WxWatchPoint('Fix', pt, isFix: true)];

  static Future<Dev> make(
    int id,
    String name, {
    bool rooms = true,
    bool radio = true,
    List<String>? zones,
  }) async {
    final d = Dev._(id, name);
    d.key = await WxDeviceKey.generate();
    d.store = AlertStore(clock: () => d.now);
    d.service = WeatherAlerts(
      store: d.store,
      client: NwsClient(userAgent: 'test', fetch: d.nws.call),
      points: () => d.pts,
      onNotify: (a) async => d.notified.add(a),
      onCleared: d.cleared.add,
      onRead: (g, z) async => d.mesh.onNwsRead(g, z),
      clock: () => d.now,
    );
    d.rooms = WxRooms(
      factory: (room) =>
          d.roomsUp[room] = FakeTransport(TransportKind.internet),
      onFrame: (f) => d.mesh.onRelayFrame(f),
    );
    d.mesh = WxMesh(
      key: d.key,
      weather: d.service,
      nodeId: () => id,
      shareOn: () => d.share,
      isTrusted: d.trusted.contains,
      deviceName: (n, k) => d.names[k] ?? '',
      rooms: rooms ? d.rooms : null,
      radioReady: () => d.radioUp,
      radioBudget: () => d.budget,
      sendRadio: radio
          ? (f) {
              if (!d.radioUp) return false;
              d.radioOut.add(f);
              return true;
            }
          : null,
      radioChannel: () => 1,
      clock: () => d.now,
      timer: (dur, f) {
        final t = FakeTimer(dur, f);
        d.timers.add(t);
        return t;
      },
    );
    if (zones != null) {
      d.store.zones['${pt.lat.toStringAsFixed(2)},${pt.lng.toStringAsFixed(2)}'] =
          WxZones(zones: zones, at: t0, place: 'Portland, OR');
    }
    if (rooms) await d.rooms.sync({'OR'}, localNodeId: id);
    return d;
  }

  /// Run every timer that is waiting.
  Future<void> fireTimers() async {
    for (final t in List.of(timers)) {
      if (t.cancelled || t.fired) continue;
      t.fired = true;
      t.cb();
    }
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<FakeTimer> get waiting => [
    for (final t in timers)
      if (t.isActive) t,
  ];

  /// Frames this device put into its relay room for [state].
  List<Frame> relaySent([String state = 'OR']) => [
    for (final s in roomsUp[WxRooms.roomFor(state)]?.sent ?? <SentFrame>[])
      s.frame,
  ];

  /// This phone reads [alerts] from the NWS (a poll).
  Future<void> poll(List<Map<String, Object?>> alerts) async {
    nws.alerts = collection(alerts);
    await service.poll(force: true);
  }
}

Map<String, Object?> tornado({
  String vtec = '/O.NEW.KPQR.TO.W.0012.261030T1855Z-261030T1945Z/',
  DateTime? sent,
  List<String>? ugc,
  String area = 'Multnomah, OR',
}) => feat(vtec: vtec, sent: sent, ugc: ugc ?? const ['ORC051'], area: area);

void main() {
  group('device keys and signatures', () {
    test(
      'each device makes its own Ed25519 key; id is 20 hex; sign/verify',
      () async {
        final a = await WxDeviceKey.generate();
        final b = await WxDeviceKey.generate();
        expect(a.id, matches(RegExp(r'^[0-9a-f]{20}$')));
        expect(a.id, isNot(b.id));
        expect(a.publicKey, hasLength(32));
        final sig = await a.sign(utf8.encode('hello'));
        expect(sig, hasLength(64));
        expect(
          await WxDeviceKey.verify(utf8.encode('hello'), sig, a.publicKey),
          isTrue,
        );
        expect(
          await WxDeviceKey.verify(utf8.encode('hellO'), sig, a.publicKey),
          isFalse,
        );
        expect(
          await WxDeviceKey.verify(utf8.encode('hello'), sig, b.publicKey),
          isFalse,
        );
        expect(
          wxKeyShow(a.id),
          matches(RegExp(r'^[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}$')),
        );
      },
    );

    test('the key is kept in a private file and survives a restart; a damaged file makes a new key', () async {
      final dir = Directory.systemTemp.createTempSync('wxk');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/wx_key.json');
      final a = await WxDeviceKey.loadOrCreate(f);
      final again = await WxDeviceKey.loadOrCreate(f);
      expect(again.id, a.id);
      expect(again.publicKey, a.publicKey);
      f.writeAsStringSync('{"seed":"AAAA","pk":"AAAA"}');
      final fresh = await WxDeviceKey.loadOrCreate(f);
      expect(fresh.id, isNot(a.id), reason: 'reinstall / damage: new key');
    });

    test(
      'a bad signature is rejected, and so is a changed sender or key',
      () async {
        final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
        final rx = await Dev.make(0xB2, 'rx', zones: ['ORZ006', 'ORC051']);
        final a = alertOf(tornado());
        final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
        Frame frame(Uint8List p, {int from = 0xA1}) => Frame(
          type: FrameType.alert,
          senderId: from,
          channel: 1,
          seq: 1,
          payload: p,
        );
        // Good.
        expect(await rx.mesh.onRadioFrame(frame(c.packets.first)), WxRx.stored);
        final rx2 = await Dev.make(0xB3, 'rx2', zones: ['ORZ006', 'ORC051']);
        // One flipped bit in the text.
        final bad = Uint8List.fromList(c.packets.first)..[30] ^= 1;
        expect(await rx2.mesh.onRadioFrame(frame(bad)), WxRx.badSignature);
        // Passed off as another phone.
        expect(
          await rx2.mesh.onRadioFrame(frame(c.packets.first, from: 0xEE)),
          WxRx.badSignature,
        );
        // Signature of someone else's key.
        final other = await WxDeviceKey.generate();
        final forged = Uint8List.fromList(c.packets.first);
        forged.setRange(
          forged.length - 96,
          forged.length - 64,
          other.publicKey,
        );
        expect(await rx2.mesh.onRadioFrame(frame(forged)), WxRx.badSignature);
        expect(rx2.store.active(), isEmpty);
        expect(rx2.notified, isEmpty);
        expect(rx2.mesh.rejected, 3);
        // Relay form too.
        final full = await wxEncodeFull(a, key: tx.key, nodeId: 0xA1);
        final badFull = Uint8List.fromList(full)..[20] ^= 1;
        expect(
          await rx2.mesh.onRelayFrame(frame(badFull)),
          anyOf(WxRx.badSignature, WxRx.ignored),
        );
        expect(rx2.store.active(), isEmpty);
      },
    );
  });

  group('compact radio packet', () {
    test('event table: unique codes, warnings only, names match the VTEC', () {
      final codes = {for (final e in wxEvents) e.code};
      expect(codes.length, wxEvents.length);
      for (final e in wxEvents) {
        expect(e.name.endsWith('Warning'), isTrue, reason: e.name);
        expect(e.sig, 'W');
        expect(e.code, inInclusiveRange(1, 255));
      }
      expect(wxEventByVtec('TO', 'W')!.name, 'Tornado Warning');
      expect(wxEventByVtec('TO', 'A'), isNull);
    });

    test('zone and office packing round trip', () {
      for (final z in ['ORZ006', 'ORC051', 'WAZ999', 'AKZ000', 'FLC127']) {
        expect(wxUnpackZone(wxPackZone(z)!), z);
        expect(wxPackZone(z)!, lessThan(1 << 24));
      }
      expect(wxPackZone('PZZ530'), isNotNull);
      expect(wxPackZone('bad'), isNull);
      expect(
        WxVtec.parse('vtec:KPQR.TO.W.0012.2026')!.key,
        'vtec:KPQR.TO.W.0012.2026',
      );
      expect(WxVtec.parse('nws:urn:x'), isNull);
    });

    test('a Tornado Warning: one packet, round trip, byte count and airtime', () async {
      final key = await WxDeviceKey.generate();
      final a = alertOf(
        tornado(
          ugc: const ['ORC051', 'ORC005', 'ORC067'],
          area: 'Multnomah, OR; Clackamas, OR; Washington, OR',
        ),
      );
      final c = (await wxEncodeCompact(a, key: key, nodeId: 0xA1))!;
      expect(c.packets, hasLength(1));
      final bytes = c.frameSizes.single;
      final air = wxAirtimeMs(bytes);
      print(
        'TORNADO compact: ${c.zonesSent} zones, text "${c.text}" (${utf8.encode(c.text).length} B), frame $bytes B, LongFast ~${air.round()} ms',
      );
      expect(bytes, lessThanOrEqualTo(loraPayloadBudget));
      final d = wxDecode(c.packets.first)!;
      expect(d.packet, WxPacket.compact);
      expect(await d.verify(0xA1), isTrue);
      final b = d.alert!;
      expect(b.key, a.key);
      expect(b.event, 'Tornado Warning');
      expect(b.severity, a.severity);
      expect(b.urgency, 'Immediate');
      expect(b.ugc, ['ORC051', 'ORC005', 'ORC067']);
      expect(b.issued, a.issued);
      expect(b.rev, a.rev);
      expect(b.expiresAt, a.expiresAt, reason: 'to the minute');
      expect(b.isExtreme, isTrue);
      expect(d.moreZones, isFalse);
      expect(d.keyId, key.id);
    });

    test('a Winter Storm Warning over 9 zones: byte count and airtime', () async {
      final key = await WxDeviceKey.generate();
      final zones = [
        for (var i = 0; i < 9; i++) 'ORZ${(40 + i).toString().padLeft(3, '0')}',
      ];
      final a = alertOf(
        feat(
          event: 'Winter Storm Warning',
          vtec: '/O.NEW.KPQR.WS.W.0005.261031T0100Z-261101T0300Z/',
          ugc: zones,
          lasts: const Duration(hours: 24),
          area: 'Central Columbia River Gorge; Hood River Valley; Upper Hood River Valley; Northern Oregon Cascades; Mt. Hood area',
        ),
      );
      final c = (await wxEncodeCompact(a, key: key, nodeId: 0xA1))!;
      final sizes = c.frameSizes;
      print(
        'WINTER STORM 9 zones: ${c.packets.length} packet(s), frames $sizes B, text "${c.text}" (${utf8.encode(c.text).length} B), LongFast ~${sizes.map((x) => wxAirtimeMs(x).round()).toList()} ms',
      );
      expect(c.zonesSent, 9);
      for (final x in sizes) {
        expect(x, lessThanOrEqualTo(loraPayloadBudget));
      }
      final d = wxDecode(c.packets.first)!;
      expect(await d.verify(0xA1), isTrue);
      expect(d.alert!.event, 'Winter Storm Warning');
    });

    test('a Winter Storm Warning with many zones: a second zones-only packet', () async {
      final key = await WxDeviceKey.generate();
      final zones = [
        for (var i = 0; i < 20; i++)
          'ORZ${(40 + i).toString().padLeft(3, '0')}',
      ];
      final a = alertOf(
        feat(
          event: 'Winter Storm Warning',
          vtec: '/O.NEW.KPQR.WS.W.0005.261031T0100Z-261101T0300Z/',
          ugc: zones,
          severity: 'Severe',
          lasts: const Duration(hours: 24),
          area: 'Central Columbia River Gorge; Hood River Valley; Upper Hood River Valley; Northern Oregon Cascades; Mt. Hood area; Cascades; Foothills',
        ),
      );
      final c = (await wxEncodeCompact(a, key: key, nodeId: 0xA1))!;
      expect(c.packets, hasLength(2));
      expect(c.zonesSent, 20);
      final sizes = c.frameSizes;
      final air = [for (final s in sizes) wxAirtimeMs(s)];
      print(
        'WINTER STORM compact: frames $sizes B, text "${c.text}", LongFast ~${air.map((x) => x.round()).toList()} ms',
      );
      for (final s in sizes) {
        expect(s, lessThanOrEqualTo(loraPayloadBudget));
      }
      final d1 = wxDecode(c.packets[0])!, d2 = wxDecode(c.packets[1])!;
      expect(d1.moreZones, isTrue);
      expect(d1.alert!.event, 'Winter Storm Warning');
      expect(d2.packet, WxPacket.zones);
      expect(d2.alertKey, a.key);
      expect([...d1.alert!.ugc, ...d2.zoneList], zones);
      expect(await d1.verify(0xA1), isTrue);
      expect(await d2.verify(0xA1, key: d1.keyBytes), isTrue);
      expect(await d2.verify(0xA2, key: d1.keyBytes), isFalse);
    });

    test(
      'on a private group (29 B of sealing) it still fits: shorter text',
      () async {
        final key = await WxDeviceKey.generate();
        final a = alertOf(
          tornado(
            area: 'Multnomah, OR; Clackamas, OR; Washington, OR; Columbia, OR',
          ),
        );
        final budget =
            loraPayloadBudget - ChannelKey.overhead - Frame.headerSize;
        final c = (await wxEncodeCompact(
          a,
          key: key,
          nodeId: 0xA1,
          budget: budget,
        ))!;
        expect(
          c.frameSizes.single + ChannelKey.overhead,
          lessThanOrEqualTo(loraPayloadBudget),
        );
        expect(c.text.isNotEmpty, isTrue);
      },
    );

    test('without VTEC or outside the table it stays off the radio', () async {
      final key = await WxDeviceKey.generate();
      final a = alertOf(
        feat(vtec: null, id: 'urn:x', event: 'Flash Flood Warning'),
      );
      expect(a.key, startsWith('nws:'));
      expect(wxRadioReady(a), isFalse);
      expect(await wxEncodeCompact(a, key: key, nodeId: 1), isNull);
      expect(wxRadioReady(alertOf(tornado())), isTrue);
    });

    test(
      'relay form: whole alert, and the sender cannot set our local flags',
      () async {
        final key = await WxDeviceKey.generate();
        final a = alertOf(tornado());
        final full = await wxEncodeFull(a, key: key, nodeId: 0xA1);
        expect(full.length, lessThan(4096));
        final d = wxDecode(full)!;
        expect(d.packet, WxPacket.full);
        expect(await d.verify(0xA1), isTrue);
        final b = d.alert!;
        expect(b.headline, a.headline);
        expect(b.instruction, a.instruction);
        expect(b.ugc, a.ugc);
        expect(b.trust, WxTrust.unconfirmed);
        expect(b.source, WxSource.relay);
        expect(b.notified, isFalse);
        // A hostile sender adds flags to the JSON: they are dropped.
        final j =
            jsonDecode(utf8.decode(full.sublist(1, full.length - 96))) as Map;
        j['nt'] = true;
        j['mt'] = 'cancel';
        j['tr'] = 'nws';
        final body = BytesBuilder()
          ..addByte(full[0])
          ..add(utf8.encode(jsonEncode(j)))
          ..add(key.publicKey);
        final sig = await key.sign(wxSignedBytes(0xA1, body.toBytes()));
        final evil = wxDecode((body..add(sig)).toBytes())!;
        expect(await evil.verify(0xA1), isTrue);
        expect(evil.alert!.notified, isFalse);
        expect(evil.alert!.isCancel, isFalse);
        expect(evil.alert!.trust, WxTrust.unconfirmed);
      },
    );

    test('airtime estimate is in the right range for LongFast', () {
      final ms = wxAirtimeMs(200);
      expect(ms, inInclusiveRange(1200, 2200));
      expect(wxAirtimeMs(50), lessThan(ms));
    });
  });

  group('trust labels', () {
    test('unknown device on a relay or Open channel: unconfirmed, from <device>; trusted or group: confirmed', () async {
      final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
      final rx = await Dev.make(0xB2, 'rx', zones: ['ORZ006', 'ORC051']);
      rx.names[tx.key.id] = 'Ridge phone';
      final a = alertOf(tornado());
      final full = await wxEncodeFull(a, key: tx.key, nodeId: 0xA1);
      Frame fr(Uint8List p) => Frame(
        type: FrameType.alert,
        senderId: 0xA1,
        channel: 0,
        seq: 1,
        payload: p,
      );
      expect(await rx.mesh.onRelayFrame(fr(full)), WxRx.stored);
      var got = rx.store.byKey(a.key)!;
      expect(got.trust, WxTrust.unconfirmed);
      expect(got.trustLine, 'Unconfirmed, from Ridge phone');
      expect(
        got.sourceLine,
        'National Weather Service, via Ridge phone over relay',
      );
      // Trusted device: confirmed on the radio and the relay.
      final rx2 = await Dev.make(0xB3, 'rx2', zones: ['ORZ006', 'ORC051']);
      rx2.trusted.add(tx.key.id);
      rx2.names[tx.key.id] = 'Ridge phone';
      final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
      expect(await rx2.mesh.onRadioFrame(fr(c.packets.first)), WxRx.stored);
      got = rx2.store.byKey(a.key)!;
      expect(got.trust, WxTrust.confirmed);
      expect(got.source, WxSource.lora);
      expect(
        got.sourceLine,
        'National Weather Service, via Ridge phone over radio',
      );
      expect(got.trustLine, startsWith('Confirmed'));
      // Sealed in our private group: confirmed even from an unknown key.
      final rx3 = await Dev.make(0xB4, 'rx3', zones: ['ORZ006', 'ORC051']);
      expect(
        await rx3.mesh.onRadioFrame(fr(c.packets.first), group: true),
        WxRx.stored,
      );
      expect(rx3.store.byKey(a.key)!.trust, WxTrust.confirmed);
      // A device with no name known: "device <id>".
      final rx4 = await Dev.make(0xB5, 'rx4', zones: ['ORZ006', 'ORC051']);
      await rx4.mesh.onRadioFrame(fr(c.packets.first));
      expect(
        rx4.store.byKey(a.key)!.trustLine,
        'Unconfirmed, from device ${tx.key.id.substring(0, 8)}',
      );
    });

    test('an unconfirmed Tornado Warning notifies on the warning channel and never sounds the extreme alarm', () async {
      final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
      final rx = await Dev.make(0xB2, 'rx', zones: ['ORZ006', 'ORC051']);
      final a = alertOf(tornado());
      final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
      await rx.mesh.onRadioFrame(
        Frame(
          type: FrameType.alert,
          senderId: 0xA1,
          channel: 1,
          seq: 1,
          payload: c.packets.first,
        ),
      );
      expect(rx.notified, hasLength(1));
      final n = rx.notified.single;
      expect(n.isExtreme, isTrue);
      expect(n.alarms, isFalse);
      final plan = planWxNotice(n, silenced: false, extremeSwitch: true);
      expect(
        (plan.extreme, plan.sound, plan.bypass),
        (false, true, false),
        reason: 'even with the switch on',
      );
      expect(wxNoticeText(n).short, startsWith('Unconfirmed, from'));
      // The same alert from a trusted device does alarm.
      final plan2 = planWxNotice(
        n.copyWith(trust: WxTrust.confirmed),
        silenced: true,
        extremeSwitch: true,
      );
      expect((plan2.extreme, plan2.bypass), (true, true));
    });

    test('unconfirmed alerts are limited, and a weaker copy never replaces a trusted one', () async {
      final s = AlertStore(clock: () => t0);
      for (var i = 0; i < 12; i++) {
        s.ingest([
          alertOf(
            feat(
              vtec: '/O.NEW.KPQR.SV.W.00${10 + i}.261030T1855Z-261030T1945Z/',
              event: 'Severe Thunderstorm Warning',
              id: 'u$i',
            ),
          ).copyWith(source: WxSource.relay, trust: WxTrust.unconfirmed),
        ]);
      }
      expect(s.active(), hasLength(AlertStore.maxUnconfirmed));
      final good = alertOf(tornado());
      s.ingest([good]);
      final liar = WxAlert(
        key: good.key,
        event: 'Tornado Warning',
        issued: good.issued.add(const Duration(minutes: 1)),
        rev: good.rev + 60000,
        headline: 'All clear (fake)',
        expires: good.expiresAt,
        source: WxSource.relay,
        trust: WxTrust.unconfirmed,
      );
      s.ingest([liar]);
      expect(s.byKey(good.key)!.headline, good.headline);
      expect(s.byKey(good.key)!.trust, WxTrust.nws);
    });
  });

  group('NWS upgrades and the drop rule', () {
    test('our own NWS read upgrades a radio copy; a flood warning stays silent, a tornado alarms once now it is confirmed', () async {
      final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
      final rx = await Dev.make(0xB2, 'rx', zones: ['ORZ006', 'ORC051']);
      final torn = alertOf(tornado());
      final flood = alertOf(
        feat(
          event: 'Flash Flood Warning',
          vtec: '/O.NEW.KPQR.FF.W.0003.261030T1855Z-261030T1945Z/',
          severity: 'Severe',
        ),
      );
      for (final a in [torn, flood]) {
        final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
        await rx.mesh.onRadioFrame(
          Frame(
            type: FrameType.alert,
            senderId: 0xA1,
            channel: 1,
            seq: 1,
            payload: c.packets.first,
          ),
        );
      }
      expect(rx.notified.map((a) => a.event), [
        'Tornado Warning',
        'Flash Flood Warning',
      ]);
      rx.notified.clear();
      await rx.poll([
        tornado(),
        feat(
          event: 'Flash Flood Warning',
          vtec: '/O.NEW.KPQR.FF.W.0003.261030T1855Z-261030T1945Z/',
          severity: 'Severe',
        ),
      ]);
      expect(rx.store.byKey(torn.key)!.trust, WxTrust.nws);
      expect(rx.store.byKey(flood.key)!.source, WxSource.nws);
      expect(
        rx.notified.map((a) => a.event),
        ['Tornado Warning'],
        reason:
            'the flood row upgrades silently; the tornado may now sound once',
      );
      expect(rx.notified.single.alarms, isTrue);
      rx.notified.clear();
      await rx.poll([
        tornado(),
        feat(
          event: 'Flash Flood Warning',
          vtec: '/O.NEW.KPQR.FF.W.0003.261030T1855Z-261030T1945Z/',
          severity: 'Severe',
        ),
      ]);
      expect(rx.notified, isEmpty);
    });

    test('after a good NWS check, radio and relay alerts it does not list are dropped (after the first minutes)', () async {
      final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
      final rx = await Dev.make(0xB2, 'rx', zones: ['ORZ006', 'ORC051']);
      final a = alertOf(tornado());
      final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
      await rx.mesh.onRadioFrame(
        Frame(
          type: FrameType.alert,
          senderId: 0xA1,
          channel: 1,
          seq: 1,
          payload: c.packets.first,
        ),
      );
      expect(rx.store.active(), hasLength(1));
      // The NWS answers with nothing right away: it may just be behind.
      await rx.poll([]);
      expect(rx.store.active(), hasLength(1), reason: 'first minutes: kept');
      rx.now = rx.now.add(const Duration(minutes: 11));
      await rx.poll([]);
      expect(
        rx.store.active(),
        isEmpty,
        reason: 'the NWS does not list it for our zones',
      );
      expect(rx.cleared, hasLength(1));
      // A radio alert for zones we did not ask about is not touched.
      final far = alertOf(
        feat(
          vtec: '/O.NEW.KPDT.TO.W.0002.261030T1855Z-261030T1945Z/',
          ugc: const ['WAZ028'],
          id: 'far',
        ),
      );
      final c2 = (await wxEncodeCompact(far, key: tx.key, nodeId: 0xA1))!;
      rx.store.zones.clear();
      await rx.mesh.onRadioFrame(
        Frame(
          type: FrameType.alert,
          senderId: 0xA1,
          channel: 1,
          seq: 2,
          payload: c2.packets.first,
        ),
      );
      expect(
        rx.store.active(),
        hasLength(1),
        reason: 'no zone known: accepted',
      );
    });

    test('a radio alert for a zone we do not cover is ignored once we know where we are', () async {
      final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
      final rx = await Dev.make(0xB2, 'rx', zones: ['ORZ006', 'ORC051']);
      final far = alertOf(
        feat(
          vtec: '/O.NEW.KPDT.TO.W.0002.261030T1855Z-261030T1945Z/',
          ugc: const ['WAZ028'],
          id: 'far',
        ),
      );
      final c = (await wxEncodeCompact(far, key: tx.key, nodeId: 0xA1))!;
      await rx.poll([]); // learn our zones
      final r = await rx.mesh.onRadioFrame(
        Frame(
          type: FrameType.alert,
          senderId: 0xA1,
          channel: 1,
          seq: 1,
          payload: c.packets.first,
        ),
      );
      expect(r, WxRx.notForUs);
      expect(rx.notified, isEmpty);
    });
  });

  group('sending rules', () {
    test('a new alert: relay after 2-12 s, radio after 5-30 s, once; a poll again changes nothing', () async {
      final d = await Dev.make(0xA1, 'phone');
      await d.poll([tornado()]);
      expect(d.notified, hasLength(1));
      final w = d.waiting;
      expect(w, hasLength(2));
      final delays = w.map((t) => t.delay.inMilliseconds).toList()..sort();
      expect(delays.first, inInclusiveRange(2000, 12000));
      expect(delays.last, inInclusiveRange(5000, 30000));
      expect(d.relaySent(), isEmpty);
      expect(d.radioOut, isEmpty);
      await d.fireTimers();
      expect(d.relaySent(), hasLength(1));
      expect(d.relaySent().single.type, FrameType.alert);
      expect(d.radioOut, hasLength(1));
      expect(d.radioOut.single.type, FrameType.alert);
      expect(
        d.radioOut.single.encode().length,
        lessThanOrEqualTo(loraPayloadBudget),
      );
      // The next poll (nothing changed): nothing more.
      d.now = d.now.add(const Duration(minutes: 5));
      await d.poll([tornado()]);
      expect(d.waiting, isEmpty);
      await d.fireTimers();
      expect(d.relaySent(), hasLength(1));
      expect(d.radioOut, hasLength(1));
    });

    test('a reminder every 20 minutes while it stays active', () async {
      final d = await Dev.make(0xA1, 'phone');
      await d.poll([tornado(sent: t0)]);
      await d.fireTimers();
      expect(d.radioOut, hasLength(1));
      d.now = d.now.add(const Duration(minutes: 19));
      await d.poll([tornado(sent: t0)]);
      expect(d.waiting, isEmpty);
      d.now = d.now.add(const Duration(minutes: 2));
      await d.poll([tornado(sent: t0)]);
      expect(d.waiting, hasLength(2));
      await d.fireTimers();
      expect(d.relaySent(), hasLength(2));
      expect(d.radioOut, hasLength(2));
      // The alert ended: no more reminders.
      d.now = d.now.add(const Duration(minutes: 30));
      await d.poll([]);
      expect(d.waiting, isEmpty);
    });

    test('a material change (worse severity, longer, more zones) sends again, after the cooldown', () async {
      final d = await Dev.make(0xA1, 'phone');
      await d.poll([tornado(sent: t0)]);
      await d.fireTimers();
      expect(d.radioOut, hasLength(1));
      // 1 minute later it is upgraded (Extreme) and extended: material, but
      // the per alert cooldown of 3 minutes holds it back.
      d.now = d.now.add(const Duration(minutes: 1));
      final up = feat(
        vtec: '/O.CON.KPQR.TO.W.0012.261030T1855Z-261030T2045Z/',
        severity: 'Extreme',
        lasts: const Duration(minutes: 105),
        sent: t0.add(const Duration(minutes: 1)),
      );
      await d.poll([up]);
      final w = d.waiting;
      expect(w, hasLength(2));
      expect(
        w.map((t) => t.delay.inSeconds),
        everyElement(greaterThanOrEqualTo(2 * 60)),
        reason: 'cooldown 3 min minus the 1 min since the first send',
      );
      await d.fireTimers();
      expect(d.radioOut, hasLength(2));
      expect(d.relaySent(), hasLength(2));
      final first = wxDecode(d.radioOut[0].payload)!.alert!;
      final second = wxDecode(d.radioOut[1].payload)!.alert!;
      expect(second.severity, WxSeverity.extreme);
      expect(second.rev, greaterThan(first.rev));
    });

    test(
      'skip if the same alert is heard on the air meanwhile, or just before',
      () async {
        final d = await Dev.make(0xA1, 'phone', zones: ['ORZ006', 'ORC051']);
        final other = await Dev.make(
          0xC3,
          'other',
          zones: ['ORZ006', 'ORC051'],
        );
        final a = alertOf(tornado(sent: t0));
        await d.poll([tornado(sent: t0)]);
        expect(d.waiting, hasLength(2));
        // Meanwhile another device airs it (and puts it on the relay).
        final c = (await wxEncodeCompact(a, key: other.key, nodeId: 0xC3))!;
        await d.mesh.onRadioFrame(
          Frame(
            type: FrameType.alert,
            senderId: 0xC3,
            channel: 1,
            seq: 1,
            payload: c.packets.first,
          ),
        );
        d.now = d.now.add(const Duration(seconds: 20));
        await d.fireTimers();
        expect(d.radioOut, isEmpty, reason: 'heard on air meanwhile: skipped');
        expect(
          d.relaySent(),
          hasLength(1),
          reason: 'only the radio was heard; the relay is separate',
        );
        expect(d.mesh.skippedHeard, greaterThan(0));
        // Heard just before our read: not even planned.
        final e = await Dev.make(0xA9, 'late', zones: ['ORZ006', 'ORC051']);
        await e.mesh.onRadioFrame(
          Frame(
            type: FrameType.alert,
            senderId: 0xC3,
            channel: 1,
            seq: 1,
            payload: c.packets.first,
          ),
        );
        await e.poll([tornado(sent: t0)]);
        expect(
          e.waiting.length,
          1,
          reason: 'the radio is covered, the relay is not',
        );
        await e.fireTimers();
        expect(e.radioOut, isEmpty);
        expect(e.relaySent(), hasLength(1));
      },
    );

    test('a bad signature never counts as "heard" (a fake cannot silence the real one)', () async {
      final d = await Dev.make(0xA1, 'phone', zones: ['ORZ006', 'ORC051']);
      final evil = await Dev.make(0xE1, 'evil');
      final a = alertOf(tornado(sent: t0));
      final c = (await wxEncodeCompact(a, key: evil.key, nodeId: 0xE1))!;
      final bad = Uint8List.fromList(c.packets.first)..[40] ^= 0xFF;
      await d.poll([tornado(sent: t0)]);
      await d.mesh.onRadioFrame(
        Frame(
          type: FrameType.alert,
          senderId: 0xE1,
          channel: 1,
          seq: 1,
          payload: bad,
        ),
      );
      await d.fireTimers();
      expect(d.radioOut, hasLength(1));
    });

    test(
      'radio-only phones never originate and never pass on what they heard',
      () async {
        final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
        final rx = await Dev.make(
          0xB2,
          'radio-only',
          rooms: false,
          zones: ['ORZ006', 'ORC051'],
        );
        final a = alertOf(tornado());
        final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
        await rx.mesh.onRadioFrame(
          Frame(
            type: FrameType.alert,
            senderId: 0xA1,
            channel: 1,
            seq: 1,
            payload: c.packets.first,
          ),
        );
        expect(rx.notified, hasLength(1));
        rx.now = rx.now.add(const Duration(minutes: 30));
        await rx.fireTimers();
        expect(rx.waiting, isEmpty);
        expect(rx.radioOut, isEmpty);
        expect(rx.relaySent(), isEmpty);
      },
    );

    test(
      'off with the share switch, no radio, no relay room: nothing is sent',
      () async {
        final off = await Dev.make(0xA1, 'off');
        off.share = false;
        await off.poll([tornado()]);
        expect(off.waiting, isEmpty);
        final noRadio = await Dev.make(0xA2, 'noradio');
        noRadio.radioUp = false;
        await noRadio.poll([tornado()]);
        await noRadio.fireTimers();
        expect(noRadio.radioOut, isEmpty);
        expect(
          noRadio.relaySent(),
          hasLength(1),
          reason: 'the relay still works',
        );
        final noRooms = await Dev.make(0xA3, 'norooms', rooms: false);
        await noRooms.poll([tornado()]);
        await noRooms.fireTimers();
        expect(noRooms.relaySent(), isEmpty);
        expect(noRooms.radioOut, hasLength(1));
        // Only warnings are shared: a watch is not even stored.
        final w = await Dev.make(0xA4, 'watch');
        await w.poll([
          feat(
            event: 'Tornado Watch',
            vtec: '/O.NEW.KPQR.TO.A.0001.261030T1855Z-261030T2045Z/',
          ),
        ]);
        expect(w.waiting, isEmpty);
      },
    );

    test('the radio zones are the ones this phone covers; relay rooms are the states of the alert', () async {
      final d = await Dev.make(0xA1, 'phone', zones: ['ORZ006', 'ORC051']);
      await d.poll([
        tornado(ugc: const ['ORC051', 'ORC005', 'WAC011']),
      ]);
      await d.fireTimers();
      final air = wxDecode(d.radioOut.single.payload)!.alert!;
      expect(air.ugc, ['ORC051'], reason: 'only what this phone covers');
      final relay = wxDecode(d.relaySent().single.payload)!.alert!;
      expect(relay.ugc, [
        'ORC051',
        'ORC005',
        'WAC011',
      ], reason: 'the relay carries all of them');
      expect(d.roomsUp.keys, ['wx-or']);
      expect(wxStates(['ORC051', 'WAC011', 'PZZ530', 'x']), {'OR', 'WA', 'PZ'});
    });
  });

  group('cross-path dedupe', () {
    test(
      'NWS, relay and radio for the same alert notify once and keep one row',
      () async {
        final tx = await Dev.make(0xA1, 'tx', zones: ['ORZ006', 'ORC051']);
        final rx = await Dev.make(0xB2, 'rx', zones: ['ORZ006', 'ORC051']);
        rx.trusted.add(tx.key.id);
        final a = alertOf(tornado());
        final full = await wxEncodeFull(a, key: tx.key, nodeId: 0xA1);
        final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
        Frame fr(Uint8List p) => Frame(
          type: FrameType.alert,
          senderId: 0xA1,
          channel: 1,
          seq: 1,
          payload: p,
        );
        await rx.mesh.onRelayFrame(fr(full));
        expect(await rx.mesh.onRadioFrame(fr(c.packets.first)), WxRx.stored);
        expect(await rx.mesh.onRelayFrame(fr(full)), WxRx.duplicate);
        await rx.poll([tornado()]);
        await rx.poll([tornado()]);
        expect(rx.store.active(), hasLength(1));
        expect(
          rx.notified,
          hasLength(1),
          reason:
              'once across all paths (the relay copy was trusted: it alarmed)',
        );
        expect(rx.store.byKey(a.key)!.trust, WxTrust.nws);
      },
    );

    test('end to end: A reads the NWS and shares; B (relay) and C (radio) get it; D (also reads the NWS) skips', () async {
      final a = await Dev.make(0xA1, 'A', zones: ['ORZ006', 'ORC051']);
      final b = await Dev.make(
        0xB2,
        'B-relay',
        radio: false,
        zones: ['ORZ006', 'ORC051'],
      );
      final c = await Dev.make(
        0xC3,
        'C-radio',
        rooms: false,
        zones: ['ORZ006', 'ORC051'],
      );
      await a.poll([tornado()]);
      await a.fireTimers();
      for (final f in a.relaySent()) {
        await b.mesh.onRelayFrame(f);
      }
      for (final f in a.radioOut) {
        await c.mesh.onRadioFrame(f);
      }
      expect(b.notified.single.sourceLine, contains('over relay'));
      expect(c.notified.single.sourceLine, contains('over radio'));
      expect(b.notified.single.trust, WxTrust.unconfirmed);
      expect(c.notified.single.areaDesc, 'Multnomah, OR');
      // B reads the NWS later: upgraded, still one row.
      await b.poll([tornado()]);
      expect(b.store.active().single.trust, WxTrust.nws);
      expect(b.store.active(), hasLength(1));
    });
  });

  group('zones follow-up packet', () {
    Future<(Dev, Dev, List<Uint8List>)> setUp9() async {
      final tx = await Dev.make(0xA1, 'tx');
      final rx = await Dev.make(0xB2, 'rx');
      final zones = [
        for (var i = 0; i < 20; i++)
          'ORZ${(40 + i).toString().padLeft(3, '0')}',
      ];
      final a = alertOf(
        feat(
          event: 'Winter Storm Warning',
          vtec: '/O.NEW.KPQR.WS.W.0005.261031T0100Z-261101T0300Z/',
          ugc: zones,
          lasts: const Duration(hours: 24),
          area: 'Gorge; Hood River Valley',
        ),
      );
      final c = (await wxEncodeCompact(a, key: tx.key, nodeId: 0xA1))!;
      return (tx, rx, c.packets);
    }

    test('in order: waits for the zones packet, then stores one alert with all zones', () async {
      final (_, rx, p) = await setUp9();
      Frame fr(Uint8List b, int s) => Frame(
        type: FrameType.alert,
        senderId: 0xA1,
        channel: 1,
        seq: s,
        payload: b,
      );
      expect(await rx.mesh.onRadioFrame(fr(p[0], 1)), WxRx.waiting);
      expect(rx.store.active(), isEmpty);
      expect(await rx.mesh.onRadioFrame(fr(p[1], 2)), WxRx.stored);
      expect(rx.store.active().single.ugc, hasLength(20));
      expect(rx.mesh.pending, 0);
    });

    test('a zones packet before its first packet is dropped (no key to check it); a lost zones packet stores the first zones after a short wait', () async {
      final (_, rx, p) = await setUp9();
      Frame fr(Uint8List b, int s) => Frame(
        type: FrameType.alert,
        senderId: 0xA1,
        channel: 1,
        seq: s,
        payload: b,
      );
      expect(await rx.mesh.onRadioFrame(fr(p[1], 2)), WxRx.unknownKey);
      expect(await rx.mesh.onRadioFrame(fr(p[0], 1)), WxRx.waiting);
      expect(rx.store.active(), isEmpty);
      final (_, rx2, p2) = await setUp9();
      expect(await rx2.mesh.onRadioFrame(fr(p2[0], 1)), WxRx.waiting);
      await rx2.fireTimers();
      expect(
        rx2.store.active().single.ugc,
        hasLength(greaterThan(0)),
        reason: 'what the first packet carried',
      );
    });
  });

  group('LoRa priority, hop limit, queue', () {
    test('Meshtastic constants: HIGH 100, ALERT 110 (the old comment mixed them up)', () {
      expect(MeshPacketPb.priorityHigh, 100);
      expect(MeshPacketPb.priorityAlert, 110);
      expect(MeshPacketPb.priorityReliable, 70);
      expect(MeshPacketPb.priorityDefault, 64);
    });

    test('an alert goes out as ALERT 110, hop limit 3, broadcast, no ack, ahead of everything but SOS', () async {
      final radio = AirRadio();
      var now = DateTime(2026, 10, 30, 12);
      final lora = LoraTransport(
        radio: radio,
        clock: () => now,
        limiter: LoraRateLimiter(burst: 1, clock: () => now),
        pumpInterval: const Duration(hours: 1),
      );
      await lora.start(localNodeId: 1, channel: 1);
      Uint8List f(int n) => Frame(
        type: FrameType.data,
        senderId: 1,
        channel: 1,
        seq: n,
        payload: Uint8List.fromList([n]),
      ).encode();
      // No token left: everything queues.
      lora.limiter.tryTake();
      lora.sendRadio(f(1), priority: LoraPriority.normal);
      lora.sendRadio(f(2), priority: LoraPriority.urgent);
      lora.sendRadio(f(3), priority: LoraPriority.alert);
      lora.sendRadio(f(4), priority: LoraPriority.sos);
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(seconds: 9));
        await lora.pump();
      }
      final order = [
        for (final s in radio.sent) Frame.tryDecode(s.payload)!.seq,
      ];
      expect(order, [4, 3, 2, 1], reason: 'SOS, alert, urgent, normal');
      RadioSent of(int n) =>
          radio.sent.firstWhere((s) => Frame.tryDecode(s.payload)!.seq == n);
      final alert = of(3);
      expect(alert.priority, 110);
      expect(alert.hopLimit, 3);
      expect(alert.to, meshBroadcast);
      expect(alert.wantAck, isFalse);
      // Everything else is unchanged.
      expect(of(2).priority, MeshPacketPb.priorityHigh);
      expect(of(4).priority, MeshPacketPb.priorityHigh);
      expect(of(1).priority, MeshPacketPb.priorityReliable);
      expect(of(1).hopLimit, 0);
      await lora.dispose();
    });

    test(
      'the gateway protocol numbers of the older priorities did not move',
      () {
        expect(LoraPriority.sos.index, 0);
        expect(LoraPriority.urgent.index, 1);
        expect(LoraPriority.normal.index, 2);
        expect(LoraPriority.bulk.index, 3);
        expect(LoraPriority.presence.index, 4);
        expect(LoraPriority.alert.index, 5);
        expect(alertHopLimit, 3);
      },
    );
  });

  group('transport manager', () {
    test('a plain alert frame is handed to the weather layer from any channel; it never makes a person', () async {
      final radio = AirRadio();
      final lora = LoraTransport(
        radio: radio,
        pumpInterval: const Duration(hours: 1),
      );
      final m = TransportManager(
        transports: [lora],
        localNodeId: 0x11,
        localName: 'Me',
        channel: 1,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      final got = <InboundAlert>[];
      m.alerts.listen(got.add);
      final key = await WxDeviceKey.generate();
      final c = (await wxEncodeCompact(
        alertOf(tornado()),
        key: key,
        nodeId: 0x22,
      ))!;
      final f = Frame(
        type: FrameType.alert,
        senderId: 0x22,
        channel: 7,
        seq: 1,
        payload: c.packets.first,
      );
      radio.hear(f.encode(), node: 0x2222);
      await Future<void>.delayed(Duration.zero);
      expect(got, hasLength(1));
      expect(got.single.group, isFalse);
      expect(got.single.frame.payload, c.packets.first);
      expect(m.peers, isEmpty);
      await m.dispose();
    });

    test('on a private group: sent sealed (only members read it), received as group = confirmed', () async {
      final key = await ChannelKey.deriveInline(3, 'summit', iterations: 1000);
      final radio = AirRadio();
      final lora = LoraTransport(
        radio: radio,
        pumpInterval: const Duration(milliseconds: 20),
      );
      final m = TransportManager(
        transports: [lora],
        localNodeId: 0x11,
        localName: 'Me',
        channel: key.channel,
        channelKey: key,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      expect(m.alertRadioReady, isTrue);
      expect(
        m.alertRadioBudget,
        loraPayloadBudget - ChannelKey.overhead - Frame.headerSize,
      );
      final wk = await WxDeviceKey.generate();
      final c = (await wxEncodeCompact(
        alertOf(tornado()),
        key: wk,
        nodeId: 0x11,
        budget: m.alertRadioBudget,
      ))!;
      final f = Frame(
        type: FrameType.alert,
        senderId: 0x11,
        channel: key.channel,
        seq: 1,
        payload: c.packets.first,
      );
      expect(m.sendAlertRadio(f), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final out = radio.sent.single;
      expect(
        Frame.tryDecode(out.payload)!.type,
        FrameType.sealed,
        reason: 'ciphertext on the air',
      );
      expect(out.priority, 110);
      expect(out.hopLimit, 3);
      expect(out.payload.length, lessThanOrEqualTo(loraPayloadBudget));
      // Another member hears a sealed alert: group = true.
      final got = <InboundAlert>[];
      m.alerts.listen(got.add);
      final other = Frame(
        type: FrameType.alert,
        senderId: 0x33,
        channel: key.channel,
        seq: 9,
        payload: c.packets.first,
      );
      radio.hear(key.seal(other), node: 0x3333);
      await Future<void>.delayed(Duration.zero);
      expect(got.single.group, isTrue);
      // A plain alert from a stranger while private still reaches the weather
      // layer (it will be "unconfirmed"), not the people list.
      radio.hear(other.encode(), node: 0x4444);
      await Future<void>.delayed(Duration.zero);
      expect(got.last.group, isFalse);
      expect(m.peers, isEmpty);
      await m.dispose();
    });

    test('on an open channel it goes out plain', () async {
      final radio = AirRadio();
      final lora = LoraTransport(
        radio: radio,
        pumpInterval: const Duration(milliseconds: 20),
      );
      final m = TransportManager(
        transports: [lora],
        localNodeId: 0x11,
        localName: 'Me',
        channel: 1,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      final wk = await WxDeviceKey.generate();
      final c = (await wxEncodeCompact(
        alertOf(tornado()),
        key: wk,
        nodeId: 0x11,
        budget: m.alertRadioBudget,
      ))!;
      expect(
        m.sendAlertRadio(
          Frame(
            type: FrameType.alert,
            senderId: 0x11,
            channel: 1,
            seq: 1,
            payload: c.packets.first,
          ),
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(Frame.tryDecode(radio.sent.single.payload)!.type, FrameType.alert);
      await m.dispose();
    });

    test('older apps drop the unknown frame type', () {
      final f = Frame(
        type: FrameType.alert,
        senderId: 1,
        channel: 1,
        seq: 1,
        payload: Uint8List(3),
      ).encode();
      final old = Uint8List.fromList(f)..[3] = 200;
      expect(Frame.tryDecode(old), isNull);
      expect(FrameType.alert.code, 9);
    });
  });

  group('relay rooms', () {
    test('one room per state, wx-<state>, closed again when not wanted; rooms come from the covered zones', () async {
      final made = <String, FakeTransport>{};
      final rooms = WxRooms(
        factory: (r) => made[r] = FakeTransport(TransportKind.internet),
        onFrame: (_) {},
      );
      await rooms.sync({'OR', 'WA'}, localNodeId: 1);
      expect(made.keys.toSet(), {'wx-or', 'wx-wa'});
      expect(rooms.isUp('OR'), isTrue);
      await rooms.sync({'OR'}, localNodeId: 1);
      expect(rooms.states, {'OR'});
      expect(made['wx-wa']!.status, TransportStatus.stopped);
      await rooms.sync({'AA', 'BB', 'CC', 'DD', 'EE', 'FF'}, localNodeId: 1);
      expect(rooms.states.length, WxRooms.maxStates);
      await rooms.closeAll();
      expect(rooms.states, isEmpty);
      expect(
        RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(WxRooms.roomFor('OR')),
        isTrue,
        reason: 'accepted by the unchanged relay',
      );
    });

    test('frames of other types in a weather room are ignored', () async {
      var got = 0;
      late FakeTransport t;
      final rooms = WxRooms(
        factory: (r) => t = FakeTransport(TransportKind.internet),
        onFrame: (_) => got++,
      );
      await rooms.sync({'OR'}, localNodeId: 1);
      t.deliver(
        Frame(
          type: FrameType.control,
          senderId: 2,
          channel: 0,
          seq: 1,
          payload: Uint8List(2),
        ),
      );
      t.deliver(
        Frame(
          type: FrameType.alert,
          senderId: 2,
          channel: 0,
          seq: 2,
          payload: Uint8List(2),
        ),
      );
      expect(got, 1);
    });
  });

  group('friend card and settings', () {
    PersonView? person;
    Widget sheet({String? key, bool trusted = false, ValueChanged<bool>? on}) {
      return MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PersonSheetView(
              person: person!,
              volume: 1,
              alwaysAllow: false,
              isFriend: true,
              muted: false,
              canRemove: false,
              onVolume: (_) {},
              onAlwaysAllow: (_) {},
              onRing: () {},
              onBeep: () {},
              onUrgent: () {},
              onVoiceMessage: () {},
              onPrivateChat: () {},
              onAddFriend: () {},
              onMute: () {},
              onBlock: () {},
              onRemove: () {},
              onWxTrust: on,
              wxKeyId: key,
              wxTrusted: trusted,
            ),
          ),
        ),
      );
    }

    testWidgets(
      'the friend card shows the toggle with the key id, off until their key is known',
      (t) async {
        phone(t, ts: 1.0);
        person = const PersonView(id: 0x2222, name: 'Ann');
        final got = <bool>[];
        await t.pumpWidget(sheet(on: got.add));
        expect(
          find.text('Trust weather alerts from this device'),
          findsOneWidget,
        );
        expect(find.textContaining('Their key shows here'), findsOneWidget);
        expect(
          t.widget<SwitchListTile>(find.byKey(const Key('wx-trust'))).onChanged,
          isNull,
        );
        await t.pumpWidget(sheet(key: '0123456789abcdef0123', on: got.add));
        expect(find.textContaining('Key 0123 4567 89AB'), findsOneWidget);
        await t.ensureVisible(find.byKey(const Key('wx-trust')));
        await t.tap(find.byKey(const Key('wx-trust')));
        expect(got, [true]);
        await t.pumpWidget(
          sheet(key: '0123456789abcdef0123', trusted: true, on: got.add),
        );
        expect(
          t.widget<SwitchListTile>(find.byKey(const Key('wx-trust'))).value,
          isTrue,
        );
      },
    );

    testWidgets(
      'their key arrives sealed in the friend hello; trust is kept per key; a changed key drops the trust',
      (t) async {
        phone(t, ts: 1.0);
        final c = await makeController(t, friends: [testFriend(0x2222, 'Ann')]);
        expect(c.friendWxKeyId(0x2222), isNull);
        await t.runAsync(() => c.setFriendWxTrust(0x2222, true));
        expect(
          c.settings.wxTrusted,
          isEmpty,
          reason: 'no key yet: nothing to trust',
        );
        c.friendLinks.onWxKey!(0x2222, 'aaaaaaaaaaaaaaaaaaaa');
        expect(c.friendWxKeyId(0x2222), 'aaaaaaaaaaaaaaaaaaaa');
        await t.runAsync(() => c.setFriendWxTrust(0x2222, true));
        expect(c.isFriendWxTrusted(0x2222), isTrue);
        expect(c.settings.wxTrusted, {'aaaaaaaaaaaaaaaaaaaa': 'Ann'});
        // They reinstalled: new key, old trust gone.
        c.friendLinks.onWxKey!(0x2222, 'bbbbbbbbbbbbbbbbbbbb');
        expect(c.isFriendWxTrusted(0x2222), isFalse);
        expect(c.settings.wxTrusted, isEmpty);
        await t.runAsync(() => c.setFriendWxTrust(0x2222, true));
        await t.runAsync(() => c.removeWxTrust('bbbbbbbbbbbbbbbbbbbb'));
        expect(c.settings.wxTrusted, isEmpty);
      },
    );

    testWidgets('Settings: share switch, and trusted devices can be removed', (
      t,
    ) async {
      phone(t, h: 900, ts: 1.0);
      final c = await makeController(t);
      c.settings.wxAlerts = true;
      c.settings.wxTrusted['aaaaaaaaaaaaaaaaaaaa'] = 'Ann';
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WeatherAlertsSettings(controller: c),
            ),
          ),
        ),
      );
      await t.pump();
      expect(find.text('Share alerts with other phones'), findsOneWidget);
      expect(find.text('Trusted: Ann'), findsOneWidget);
      final before = c.settings.wxShare;
      await t.ensureVisible(find.byKey(const Key('wx-share')));
      await t.tap(find.byKey(const Key('wx-share')));
      await t.pump();
      expect(c.settings.wxShare, !before);
      await t.tap(find.byTooltip('Stop trusting'));
      await t.pump();
      expect(find.text('Trusted: Ann'), findsNothing);
      expect(c.settings.wxTrusted, isEmpty);
    });
  });
}

typedef RadioSent = ({
  Uint8List payload,
  int to,
  bool wantAck,
  int priority,
  int hopLimit,
});

/// A radio that records what was sent, with hop limit.
class AirRadio implements RadioLink {
  final sent =
      <
        ({Uint8List payload, int to, bool wantAck, int priority, int hopLimit})
      >[];
  final _packets = StreamController<MeshPacketPb>.broadcast(sync: true);
  @override
  bool get ready => true;
  @override
  Stream<bool> get readyChanges => const Stream.empty();
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;
  @override
  int? get queueFree => null;
  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
    int hopLimit = 0,
  }) async => sent.add((
    payload: payload,
    to: to,
    wantAck: wantAck,
    priority: priority,
    hopLimit: hopLimit,
  ));

  void hear(Uint8List frame, {required int node}) => _packets.add(
    MeshPacketPb(
      from: node,
      to: meshBroadcast,
      rxSnr: 4,
      rxRssi: -100,
      hopLimit: 2,
      hopStart: 3,
      decoded: MeshData(portnum: PortNum.privateApp, payload: frame),
    ),
  );
}
