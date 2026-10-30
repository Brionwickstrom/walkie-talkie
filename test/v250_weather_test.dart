import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/ui/weather_alerts_page.dart';
import 'package:walkie_talkie/weather/alert_store.dart';
import 'package:walkie_talkie/weather/nws_client.dart';
import 'package:walkie_talkie/weather/weather_alerts.dart';
import 'package:walkie_talkie/weather/wx_alert.dart';
import 'package:walkie_talkie/weather/wx_notice.dart';

import 'v231_helpers.dart';

// v2.5.0, stage 1: weather alerts straight from the National Weather
// Service. Mocked NWS JSON only: no live calls.

final t0 = DateTime.utc(2026, 10, 30, 19, 0); // 12:00 PDT

String iso(DateTime t) => t.toUtc().toIso8601String();

Map<String, Object?> feat({
  String id = 'urn:oid:2.49.0.1.840.0.aaa.001.1',
  String event = 'Tornado Warning',
  String severity = 'Severe',
  String? vtec = '/O.NEW.KPQR.TO.W.0012.261030T1855Z-261030T1945Z/',
  DateTime? sent,
  Duration lasts = const Duration(minutes: 45),
  String messageType = 'Alert',
  String status = 'Actual',
  List<String> ugc = const ['ORC051'],
  String headline = 'Tornado Warning issued October 30 at 11:55AM PDT',
  String instruction =
      'TAKE COVER NOW!\nMove to a basement or an interior room.',
  String description = 'At 1155 AM PDT, a severe thunderstorm\ncapable of producing a tornado was located near Gresham.',
  List<String> references = const [],
  String area = 'Multnomah, OR',
}) {
  final s = sent ?? t0.subtract(const Duration(minutes: 5));
  return {
    'id': id,
    'type': 'Feature',
    'properties': {
      'id': id,
      'areaDesc': area,
      'geocode': {
        'UGC': ugc,
        'SAME': ['041051'],
      },
      'sent': iso(s),
      'effective': iso(s),
      'onset': iso(s),
      'expires': iso(s.add(lasts)),
      'ends': null,
      'status': status,
      'messageType': messageType,
      'severity': severity,
      'urgency': 'Immediate',
      'event': event,
      'senderName': 'NWS Portland OR',
      'headline': headline,
      'description': description,
      'instruction': instruction,
      'references': [
        for (final r in references)
          {
            '@id': 'x',
            'identifier': r,
            'sender': 'w-nws.webmaster@noaa.gov',
            'sent': iso(s),
          },
      ],
      'parameters': {
        'VTEC': [?vtec],
      },
    },
  };
}

String collection(List<Map<String, Object?>> f) =>
    jsonEncode({'type': 'FeatureCollection', 'features': f});

String pointJson({String zone = 'ORZ006', String county = 'ORC051'}) =>
    jsonEncode({
      'properties': {
        'forecastZone': 'https://api.weather.gov/zones/forecast/$zone',
        'county': 'https://api.weather.gov/zones/county/$county',
        'relativeLocation': {
          'properties': {'city': 'Portland', 'state': 'OR'},
        },
      },
    });

WxAlert alertOf(Map<String, Object?> f) => WxAlert.fromNws(f)!;

class FakeNws {
  final calls = <Uri>[];
  final headers = <Map<String, String>>[];
  String alerts = collection([]);
  int alertsStatus = 200;
  int pointStatus = 200;
  String point = pointJson();

  Future<WxResponse> call(Uri u, Map<String, String> h) async {
    calls.add(u);
    headers.add(h);
    if (u.path.startsWith('/points/')) {
      return WxResponse(pointStatus, pointStatus == 200 ? point : '');
    }
    return WxResponse(alertsStatus, alertsStatus == 200 ? alerts : '');
  }

  int get pointCalls =>
      calls.where((u) => u.path.startsWith('/points/')).length;
  int get alertCalls =>
      calls.where((u) => u.path.startsWith('/alerts/')).length;
}

class Rig {
  Rig({this.file, List<WxWatchPoint>? pts})
    : pts =
          pts ??
          [
            const WxWatchPoint(
              'Your last known location',
              GeoPoint(45.5231, -122.6765),
              isFix: true,
            ),
          ] {
    store = AlertStore(file: file, clock: () => now);
    service = WeatherAlerts(
      store: store,
      client: NwsClient(
        userAgent: 'WalkieTalkie/2.5.0 (+https://example.test)',
        fetch: nws.call,
      ),
      points: () => this.pts,
      enabled: () => enabled,
      networkOk: () => networkOk,
      slow: () => slow,
      onNotify: (a) async => notified.add(a),
      onCleared: cleared.add,
      clock: () => now,
    );
  }
  final File? file;
  final nws = FakeNws();
  List<WxWatchPoint> pts;
  DateTime now = t0;
  bool enabled = true, networkOk = true, slow = false;
  final notified = <WxAlert>[];
  final cleared = <WxAlert>[];
  late AlertStore store;
  late WeatherAlerts service;
}

void main() {
  group('NWS JSON', () {
    test('a Tornado Warning: VTEC key, extreme, warning, text', () {
      final a = alertOf(feat());
      expect(a.key, 'vtec:KPQR.TO.W.0012.2026');
      expect(a.event, 'Tornado Warning');
      expect(a.kind, WxKind.warning);
      expect(a.isExtreme, isTrue, reason: 'Tornado Warning is always extreme');
      expect(a.severity, WxSeverity.severe);
      expect(a.ugc, ['ORC051']);
      expect(a.areaDesc, 'Multnomah, OR');
      expect(a.expiresAt, t0.add(const Duration(minutes: 40)));
      expect(a.isCancel, isFalse);
      expect(a.source, WxSource.nws);
      expect(a.trust, WxTrust.nws);
      expect(
        WxAlert.unwrap(a.description),
        'At 1155 AM PDT, a severe thunderstorm capable of producing a tornado was located near Gresham.',
      );
      expect(a.notificationId, inInclusiveRange(8000000, 8000000 + 0xFFFFF));
    });

    test('no VTEC: the NWS id is the key; tests and exercises are dropped', () {
      final a = alertOf(
        feat(vtec: null, event: 'Special Weather Statement', id: 'urn:oid:1'),
      );
      expect(a.key, 'nws:urn:oid:1');
      expect(a.kind, WxKind.statement);
      expect(WxAlert.fromNws(feat(status: 'Test')), isNull);
      expect(WxAlert.fromNws(feat(status: 'Exercise')), isNull);
      expect(WxAlert.fromNws({'properties': {}}), isNull);
      expect(WxAlert.fromNws('x'), isNull);
    });

    test('kinds: warning / watch / advisory / marine / statement', () {
      WxKind k(String e) => wxKindOf(e);
      expect(k('Flash Flood Warning'), WxKind.warning);
      expect(k('Winter Storm Warning'), WxKind.warning);
      expect(k('Red Flag Warning'), WxKind.warning);
      expect(k('Evacuation - Immediate'), WxKind.warning);
      expect(k('Tornado Watch'), WxKind.watch);
      expect(k('Wind Advisory'), WxKind.advisory);
      expect(k('Special Marine Warning'), WxKind.marine);
      expect(k('Gale Warning'), WxKind.marine);
      expect(k('Storm Warning'), WxKind.marine);
      expect(k('Small Craft Advisory'), WxKind.advisory);
      expect(k('Special Weather Statement'), WxKind.statement);
      expect(k('Shelter In Place Warning'), WxKind.warning);
    });

    test('extreme: severity Extreme, Tornado, Extreme Wind, Tsunami', () {
      expect(
        alertOf(
          feat(event: 'Flash Flood Warning', severity: 'Extreme', vtec: null),
        ).isExtreme,
        isTrue,
      );
      expect(
        alertOf(feat(event: 'Extreme Wind Warning', vtec: null)).isExtreme,
        isTrue,
      );
      expect(
        alertOf(feat(event: 'Tsunami Warning', vtec: null)).isExtreme,
        isTrue,
      );
      expect(
        alertOf(feat(event: 'Flash Flood Warning', vtec: null)).isExtreme,
        isFalse,
      );
      expect(
        alertOf(feat(event: 'Winter Storm Warning', vtec: null)).isExtreme,
        isFalse,
      );
    });

    test('cancel: message type Cancel, or VTEC CAN / EXP', () {
      expect(alertOf(feat(messageType: 'Cancel')).isCancel, isTrue);
      expect(
        alertOf(feat(vtec: '/O.CAN.KPQR.TO.W.0012.261030T1855Z-261030T1945Z/'))
            .isCancel,
        isTrue,
      );
      expect(
        alertOf(feat(vtec: '/O.EXP.KPQR.TO.W.0012.261030T1855Z-261030T1945Z/'))
            .isCancel,
        isTrue,
      );
      expect(
        alertOf(feat(vtec: '/O.CON.KPQR.TO.W.0012.261030T1855Z-261030T1945Z/'))
            .isCancel,
        isFalse,
      );
    });

    test('a collection: junk is null, nothing is an empty list', () {
      expect(parseNwsAlerts('<html>503</html>'), isNull);
      expect(parseNwsAlerts('{"x":1}'), isNull);
      expect(parseNwsAlerts(collection([])), isEmpty);
      expect(
        parseNwsAlerts(
          collection([
            feat(),
            feat(status: 'Test'),
            feat(event: 'Flood Watch', vtec: null, id: 'b'),
          ]),
        ),
        hasLength(2),
      );
    });

    test('JSON round trip keeps everything incl. device and trust', () {
      final a = WxAlert(
        key: 'vtec:KPQR.TO.W.0012.2026',
        event: 'Tornado Warning',
        issued: t0,
        rev: 5,
        severity: WxSeverity.severe,
        source: WxSource.lora,
        trust: WxTrust.unconfirmed,
        fromDevice: 'ab12cd',
        fromName: 'Ridge phone',
        ugc: const ['ORC051'],
        notified: true,
        headline: 'h',
        instruction: 'i',
        expires: t0.add(const Duration(hours: 1)),
      );
      final b = WxAlert.fromJson(jsonDecode(jsonEncode(a.toJson())))!;
      expect(b.key, a.key);
      expect(b.source, WxSource.lora);
      expect(b.trust, WxTrust.unconfirmed);
      expect(b.fromDevice, 'ab12cd');
      expect(b.fromName, 'Ridge phone');
      expect(b.notified, isTrue);
      expect(b.rev, 5);
      expect(b.expires, a.expires);
      expect(WxAlert.fromJson('nope'), isNull);
    });
  });

  group('the store', () {
    AlertStore newStore({File? f}) => AlertStore(file: f, clock: () => t0);

    test('the same alert twice: one alert, one notification', () {
      final s = newStore();
      final r1 = s.ingest([alertOf(feat())]);
      expect(r1.added, hasLength(1));
      expect(r1.toNotify, hasLength(1));
      s.markNotified(r1.toNotify.single.key);
      final r2 = s.ingest([alertOf(feat())]);
      expect(r2.added, isEmpty);
      expect(r2.toNotify, isEmpty);
      expect(s.active(), hasLength(1));
    });

    test('an update with new text does not notify again; a worse one does', () {
      final s = newStore();
      s.ingest([
        alertOf(
          feat(
            event: 'Flash Flood Warning',
            vtec: '/O.NEW.KPQR.FF.W.0003.261030T1855Z-261030T2300Z/',
            severity: 'Moderate',
          ),
        ),
      ]);
      s.markNotified('vtec:KPQR.FF.W.0003.2026');
      final later = t0.subtract(const Duration(minutes: 1));
      final r = s.ingest([
        alertOf(
          feat(
            event: 'Flash Flood Warning',
            vtec: '/O.CON.KPQR.FF.W.0003.261030T1855Z-261030T2300Z/',
            severity: 'Moderate',
            sent: later,
            headline: 'newer words',
            messageType: 'Update',
          ),
        ),
      ]);
      expect(r.updated, hasLength(1));
      expect(r.toNotify, isEmpty);
      expect(s.byKey('vtec:KPQR.FF.W.0003.2026')!.headline, 'newer words');
      final worse = s.ingest([
        alertOf(
          feat(
            event: 'Flash Flood Warning',
            vtec: '/O.CON.KPQR.FF.W.0003.261030T1855Z-261030T2300Z/',
            severity: 'Extreme',
            sent: later.add(const Duration(minutes: 1)),
            messageType: 'Update',
          ),
        ),
      ]);
      expect(worse.toNotify, hasLength(1), reason: 'escalated to Extreme');
    });

    test('an older revision never replaces a newer one', () {
      final s = newStore();
      s.ingest([
        alertOf(
          feat(headline: 'new', sent: t0.subtract(const Duration(minutes: 1))),
        ),
      ]);
      final r = s.ingest([
        alertOf(
          feat(headline: 'old', sent: t0.subtract(const Duration(minutes: 9))),
        ),
      ]);
      expect(r.updated, isEmpty);
      expect(s.byKey('vtec:KPQR.TO.W.0012.2026')!.headline, 'new');
    });

    test('cancel removes it, and a late older copy does not bring it back', () {
      final s = newStore();
      s.ingest([alertOf(feat())]);
      final r = s.ingest([
        alertOf(
          feat(
            vtec: '/O.CAN.KPQR.TO.W.0012.261030T1855Z-261030T1945Z/',
            messageType: 'Cancel',
            sent: t0,
          ),
        ),
      ]);
      expect(r.removed, hasLength(1));
      expect(s.active(), isEmpty);
      final back = s.ingest([alertOf(feat())]);
      expect(back.added, isEmpty, reason: 'older than the cancel');
      expect(s.active(), isEmpty);
    });

    test(
      'expiry: gone from active, pruned, not accepted when already over',
      () {
        var now = t0;
        final s = AlertStore(clock: () => now);
        s.ingest([alertOf(feat(lasts: const Duration(minutes: 10)))]);
        expect(s.active(), hasLength(1));
        now = t0.add(const Duration(minutes: 6));
        expect(s.active(), isEmpty, reason: 'expired 5 minutes after t0');
        expect(s.expire(), hasLength(1));
        expect(s.length, 0);
        final r = s.ingest([
          alertOf(
            feat(
              sent: t0.subtract(const Duration(hours: 3)),
              lasts: const Duration(hours: 1),
            ),
          ),
        ]);
        expect(r.added, isEmpty);
      },
    );

    test('only warnings by default; other kinds when asked', () {
      final s = newStore();
      final r = s.ingest([
        alertOf(feat()),
        alertOf(
          feat(
            event: 'Tornado Watch',
            vtec: '/O.NEW.KPQR.TO.A.0200.261030T1855Z-261031T0100Z/',
          ),
        ),
        alertOf(
          feat(
            event: 'Wind Advisory',
            vtec: '/O.NEW.KPQR.WI.Y.0010.261030T1855Z-261031T0100Z/',
          ),
        ),
        alertOf(
          feat(
            event: 'Special Marine Warning',
            vtec: '/O.NEW.KPQR.MA.W.0010.261030T1855Z-261031T0100Z/',
          ),
        ),
      ]);
      expect(r.added.map((a) => a.event), ['Tornado Warning']);
      s.kinds = {WxKind.warning, WxKind.watch};
      expect(
        s.ingest([
          alertOf(
            feat(
              event: 'Tornado Watch',
              vtec: '/O.NEW.KPQR.TO.A.0200.261030T1855Z-261031T0100Z/',
            ),
          ),
        ]).added,
        hasLength(1),
      );
    });

    test('extreme first when several are active', () {
      final s = newStore();
      s.ingest([
        alertOf(
          feat(
            event: 'Flood Warning',
            vtec: '/O.NEW.KPQR.FL.W.0001.261030T1855Z-261031T0100Z/',
            severity: 'Moderate',
          ),
        ),
        alertOf(feat()),
      ]);
      expect(s.active().first.event, 'Tornado Warning');
    });

    test(
      'authoritative: missing from the NWS answer = gone; other places too',
      () {
        final s = newStore();
        s.ingest([
          alertOf(feat()),
          alertOf(
            feat(
              event: 'Flash Flood Warning',
              vtec: '/O.NEW.KPQR.FF.W.0003.261030T1855Z-261030T2300Z/',
              ugc: ['WAC011'],
            ),
          ),
        ]);
        // Now asking about ORZ006 / ORC051 only; the tornado warning is no
        // longer listed (cancelled early) and the flood warning is for a place
        // we no longer watch.
        final r = s.ingest(const [], authoritative: {'ORZ006', 'ORC051'});
        expect(r.removed, hasLength(2));
        expect(s.active(), isEmpty);
      },
    );

    test('a message replacing another id inherits "already notified"', () {
      final s = newStore();
      s.ingest([
        alertOf(
          feat(vtec: null, event: 'Civil Emergency Message', id: 'urn:a'),
        ),
      ]);
      s.markNotified('nws:urn:a');
      final r = s.ingest([
        alertOf(
          feat(
            vtec: null,
            event: 'Civil Emergency Message',
            id: 'urn:b',
            references: ['urn:a'],
            sent: t0.subtract(const Duration(minutes: 1)),
          ),
        ),
      ]);
      expect(r.removed.map((a) => a.nwsId), ['urn:a']);
      expect(r.added, hasLength(1));
      expect(r.toNotify, isEmpty);
      expect(s.active().single.nwsId, 'urn:b');
    });

    test('later sources: a relay copy is unconfirmed until our own NWS read upgrades it', () {
      final s = newStore();
      final relay = alertOf(feat())
          .copyWith(source: WxSource.lora, trust: WxTrust.unconfirmed);
      expect(s.ingest([relay]).toNotify, hasLength(1));
      s.markNotified(relay.key);
      expect(s.active().single.trust, WxTrust.unconfirmed);
      final own = alertOf(feat());
      final r = s.ingest([own]);
      final a = s.active().single;
      expect(a.trust, WxTrust.nws);
      expect(a.source, WxSource.nws);
      expect(r.toNotify, isEmpty, reason: 'already notified once');
      // And the other way: a weaker copy never downgrades it.
      s.ingest([relay]);
      expect(s.active().single.trust, WxTrust.nws);
    });

    test('alerts.json: survives a restart, no double notify', () async {
      final dir = Directory.systemTemp.createTempSync('wx');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/alerts.json');
      final s = newStore(f: f);
      final r = s.ingest([
        alertOf(feat()),
        alertOf(
          feat(
            vtec: '/O.NEW.KPQR.TO.W.0001.261030T1855Z-261030T1945Z/',
            id: 'x',
            event: 'Tornado Warning',
          ),
        ),
      ]);
      for (final a in r.toNotify) {
        s.markNotified(a.key);
      }
      s.zones['45.52,-122.68'] = WxZones(
        zones: const ['ORZ006'],
        at: t0,
        place: 'Portland, OR',
      );
      s.lastFix = const GeoPoint(45.5, -122.6);
      s.lastFixAt = t0;
      s.lastChecked = t0;
      await s.save();
      expect(jsonDecode(f.readAsStringSync())['alerts'], hasLength(2));
      final s2 = newStore(f: f);
      await s2.load();
      expect(s2.active(), hasLength(2));
      expect(s2.active().every((a) => a.notified), isTrue);
      expect(s2.zones['45.52,-122.68']!.place, 'Portland, OR');
      expect(s2.lastFix!.lat, 45.5);
      expect(s2.lastChecked, isNotNull);
      final again = s2.ingest([alertOf(feat())]);
      expect(again.toNotify, isEmpty);
      // A broken file is ignored, not fatal.
      f.writeAsStringSync('{not json');
      final s3 = newStore(f: f);
      await s3.load();
      expect(s3.active(), isEmpty);
    });
  });

  group('NWS client', () {
    test(
      'URLs: point rounded to 2 decimals, zones sorted, User-Agent',
      () async {
        expect(
          wxPlaceKey(const GeoPoint(45.52314, -122.67651)),
          '45.52,-122.68',
        );
        expect(
          NwsClient.pointUrl('45.52,-122.68').toString(),
          'https://api.weather.gov/points/45.52,-122.68',
        );
        expect(
          NwsClient.alertsUrl(['ORZ006', 'ORC051']).toString(),
          'https://api.weather.gov/alerts/active?zone=ORC051%2CORZ006&status=actual',
        );
        final f = FakeNws();
        final c = NwsClient(
          userAgent: 'WalkieTalkie/2.5.0 (+https://example.test)',
          fetch: f.call,
        );
        final z = await c.zonesFor('45.52,-122.68');
        expect(z!.zones, ['ORZ006', 'ORC051']);
        expect(z.place, 'Portland, OR');
        expect(f.headers.single['User-Agent'], contains('WalkieTalkie/2.5.0'));
        expect(f.headers.single['Accept'], 'application/geo+json');
      },
    );

    test(
      '404 = not covered; other errors = try later; junk alerts = null',
      () async {
        final f = FakeNws()..pointStatus = 404;
        final c = NwsClient(userAgent: 'x', fetch: f.call);
        expect((await c.zonesFor('48.85,2.35'))!.supported, isFalse);
        f.pointStatus = 503;
        expect(await c.zonesFor('45.52,-122.68'), isNull);
        f.alertsStatus = 500;
        expect(await c.activeFor(['ORZ006']), isNull);
        f.alertsStatus = 200;
        f.alerts = 'oops';
        expect(await c.activeFor(['ORZ006']), isNull);
        expect(await c.activeFor(const []), isEmpty);
      },
    );
  });

  group('the service', () {
    test(
      'first check: place lookup, one alerts request, one notification',
      () async {
        final r = Rig();
        r.nws.alerts = collection([feat()]);
        expect(await r.service.poll(), isTrue);
        expect(r.nws.pointCalls, 1);
        expect(r.nws.alertCalls, 1);
        expect(r.nws.calls.first.path, '/points/45.52,-122.68');
        expect(r.nws.calls.last.queryParameters['zone'], 'ORC051,ORZ006');
        expect(r.notified.map((a) => a.event), ['Tornado Warning']);
        expect(r.service.hasActive, isTrue);
        expect(r.service.top!.event, 'Tornado Warning');
        expect(
          r.service.statusLine(now: t0),
          '1 warning for your area · checked just now',
        );
        expect(
          r.service.areas.single.text,
          'Your last known location · Portland, OR',
        );
      },
    );

    test(
      'later checks: the place is cached, nobody is notified twice',
      () async {
        final r = Rig();
        r.nws.alerts = collection([feat()]);
        await r.service.poll();
        r.now = r.now.add(const Duration(minutes: 5));
        await r.service.poll();
        await r.service.poll();
        expect(r.nws.pointCalls, 1, reason: 'zones cached for 30 days');
        expect(r.nws.alertCalls, 3);
        expect(r.notified, hasLength(1));
      },
    );

    test('cadence: 10 minutes, 5 with an alert, 30 offline saver, backoff on errors', () async {
      final r = Rig();
      expect(r.service.interval, const Duration(minutes: 10));
      r.nws.alerts = collection([feat()]);
      await r.service.poll();
      expect(r.service.interval, const Duration(minutes: 5));
      r.slow = true;
      expect(r.service.interval, const Duration(minutes: 30));
      r.slow = false;
      final e = Rig();
      e.nws.alertsStatus = 503;
      await e.service.poll();
      expect(e.service.interval, const Duration(minutes: 20));
      await e.service.poll();
      expect(e.service.interval, const Duration(minutes: 30), reason: 'capped');
      e.nws.alertsStatus = 200;
      await e.service.poll();
      expect(e.service.interval, const Duration(minutes: 10));
    });

    test('an error keeps what we have; the status says so', () async {
      final r = Rig();
      r.nws.alerts = collection([feat()]);
      await r.service.poll();
      r.nws.alertsStatus = 500;
      expect(await r.service.poll(), isFalse);
      expect(r.service.active, hasLength(1));
      expect(r.service.lastError, isNotNull);
      expect(r.cleared, isEmpty);
    });

    test('cancelled / expired: the notification is taken down', () async {
      final r = Rig();
      r.nws.alerts = collection([feat()]);
      await r.service.poll();
      r.nws.alerts = collection([]); // no longer active
      await r.service.poll();
      expect(r.service.active, isEmpty);
      expect(r.cleared.single.event, 'Tornado Warning');
      expect(
        r.service.statusLine(now: t0),
        startsWith('No warnings for your area'),
      );
    });

    test(
      'Wi-Fi only skips the check on mobile data; "Check now" does not',
      () async {
        final r = Rig()..networkOk = false;
        expect(await r.service.poll(), isFalse);
        expect(r.nws.calls, isEmpty);
        expect(await r.service.poll(force: true), isTrue);
        expect(r.nws.calls, isNotEmpty);
      },
    );

    test('off: no request at all', () async {
      final r = Rig()..enabled = false;
      expect(await r.service.poll(), isFalse);
      await r.service.resume();
      expect(r.nws.calls, isEmpty);
      expect(r.service.statusLine(), 'Weather alerts are off');
    });

    test('no place yet: no request, says so; GPS is never asked for', () async {
      final r = Rig(pts: const []);
      await r.service.poll();
      expect(r.nws.calls, isEmpty);
      expect(r.service.statusLine(now: t0), 'Waiting for a place to watch');
      expect(r.service.areas, isEmpty);
    });

    test(
      'the last fix is remembered across a restart (no Trip fix this time)',
      () async {
        final dir = Directory.systemTemp.createTempSync('wx');
        addTearDown(() => dir.deleteSync(recursive: true));
        final f = File('${dir.path}/alerts.json');
        final a = Rig(file: f);
        a.nws.alerts = collection([feat()]);
        await a.service.poll();
        final b = Rig(file: f, pts: const []);
        await b.service.load();
        b.nws.alerts = collection([feat()]);
        expect(b.service.hasActive, isTrue, reason: 'alerts.json');
        await b.service.poll();
        expect(b.nws.pointCalls, 0, reason: 'zones were saved too');
        expect(b.nws.alertCalls, 1);
        expect(b.notified, isEmpty, reason: 'notified before the restart');
        // A fix older than a week is not used.
        final c = Rig(file: f, pts: const []);
        await c.service.load();
        c.now = t0.add(const Duration(days: 9));
        await c.service.poll();
        expect(c.nws.alertCalls, 0);
      },
    );

    test('places: duplicates within ~1 km count once, at most six', () async {
      final pts = [
        const WxWatchPoint('Fix', GeoPoint(45.5231, -122.6765), isFix: true),
        const WxWatchPoint('Camp', GeoPoint(45.5249, -122.6781)),
        for (var i = 0; i < 8; i++)
          WxWatchPoint('Area $i', GeoPoint(40.0 + i, -100.0)),
      ];
      final r = Rig(pts: pts);
      await r.service.poll();
      expect(r.nws.pointCalls, 6);
      expect(r.service.areas.first.label, 'Fix');
    });

    test('outside the US: not covered, no alerts request', () async {
      final r = Rig(
        pts: const [WxWatchPoint('Paris', GeoPoint(48.8566, 2.3522))],
      );
      r.nws.pointStatus = 404;
      await r.service.poll();
      expect(r.nws.alertCalls, 0);
      expect(r.service.areas.single.text, 'Paris (not covered by the NWS)');
    });

    test(
      'handle(): later sources feed the same store and notify once',
      () async {
        final r = Rig();
        final relay = alertOf(feat())
            .copyWith(source: WxSource.relay, trust: WxTrust.confirmed);
        await r.service.handle([relay]);
        await r.service.handle([relay]);
        expect(r.notified, hasLength(1));
        expect(r.service.top!.trust, WxTrust.confirmed);
      },
    );
  });

  group('how it is announced', () {
    test('quiet hours only silence sound; the extreme switch lifts it for extreme only', () {
      final tornado = alertOf(feat());
      final flood = alertOf(
        feat(event: 'Flash Flood Warning', vtec: null, id: 'f'),
      );
      // Switch off (default): quiet hours and DND are followed.
      var p = planWxNotice(tornado, silenced: true, extremeSwitch: false);
      expect((p.extreme, p.sound, p.bypass), (true, false, false));
      p = planWxNotice(tornado, silenced: false, extremeSwitch: false);
      expect((p.extreme, p.sound, p.bypass), (true, true, false));
      // Switch on: a tornado warning sounds anyway and may pass DND.
      p = planWxNotice(tornado, silenced: true, extremeSwitch: true);
      expect((p.extreme, p.sound, p.bypass), (true, true, true));
      // Other warnings never break quiet hours.
      p = planWxNotice(flood, silenced: true, extremeSwitch: true);
      expect((p.extreme, p.sound, p.bypass), (false, false, false));
      p = planWxNotice(flood, silenced: false, extremeSwitch: true);
      expect((p.extreme, p.sound, p.bypass), (false, true, false));
    });

    test('notification text and clock', () {
      final a = alertOf(feat());
      final local = DateTime(2026, 10, 30, 13, 5);
      expect(wxClock(local, now: DateTime(2026, 10, 30, 8)), '1:05 PM');
      expect(wxClock(local, now: DateTime(2026, 10, 31, 8)), 'Fri 1:05 PM');
      expect(
        wxClock(DateTime(2026, 10, 30, 0, 7), now: DateTime(2026, 10, 30)),
        '12:07 AM',
      );
      final t = wxNoticeText(a, now: DateTime(2026, 10, 30));
      expect(t.title, 'Tornado Warning');
      expect(t.short, contains('Multnomah, OR'));
      expect(t.short, startsWith('Until '));
      expect(t.big, contains('Move to a basement'));
    });
  });

  group('settings', () {
    test(
      'defaults: on, Wi-Fi only off, extreme sound off; they are saved',
      () async {
        SharedPreferences.setMockInitialValues({});
        const store = SharedPrefsSettingsStore();
        final s = await store.load(defaultChannel: 1);
        expect(s.wxAlerts, isTrue);
        expect(s.wxWifiOnly, isFalse);
        expect(s.wxExtremeSound, isFalse);
        s
          ..wxAlerts = false
          ..wxWifiOnly = true
          ..wxExtremeSound = true;
        await store.save(s);
        final s2 = await store.load(defaultChannel: 1);
        expect(s2.wxAlerts, isFalse);
        expect(s2.wxWifiOnly, isTrue);
        expect(s2.wxExtremeSound, isTrue);
      },
    );
  });

  group('screens', () {
    Future<(dynamic, Rig)> world(WidgetTester t, {bool alerts = true}) async {
      phone(t, ts: 1.0);
      final c = await makeController(t);
      final r = Rig();
      r.now = DateTime.now().toUtc();
      if (alerts) {
        final sent = r.now.subtract(const Duration(minutes: 5));
        r.nws.alerts = collection([
          feat(sent: sent),
          feat(
            event: 'Flood Warning',
            severity: 'Moderate',
            vtec: '/O.NEW.KPQR.FL.W.0001.261030T1855Z-261031T0100Z/',
            id: 'u2',
            sent: sent,
            lasts: const Duration(hours: 6),
            headline: 'Flood Warning for the Sandy River',
            instruction: '',
            area: 'Clackamas, OR',
          ),
        ]);
      }
      await t.runAsync(() => r.service.poll());
      c.weatherAlerts = r.service;
      return (c, r);
    }

    testWidgets(
      'the Alerts page: event, area, times, headline, what to do, source',
      (t) async {
        final (c, _) = await world(t);
        await t.pumpWidget(MaterialApp(home: WeatherAlertsPage(controller: c)));
        await t.pump();
        expect(find.text('Weather alerts'), findsOneWidget);
        expect(find.text('Tornado Warning'), findsOneWidget);
        expect(find.text('Flood Warning'), findsOneWidget);
        expect(find.text('Multnomah, OR'), findsOneWidget);
        expect(find.textContaining('Issued '), findsNWidgets(2));
        expect(find.textContaining('Expires '), findsNWidgets(2));
        expect(
          find.textContaining('What to do: TAKE COVER NOW!'),
          findsOneWidget,
        );
        expect(find.text('Flood Warning for the Sandy River'), findsOneWidget);
        expect(find.byKey(const Key('wx-source')), findsNWidgets(2));
        expect(
          find.text('National Weather Service, via internet'),
          findsNWidgets(2),
        );
        expect(find.text('Details'), findsNWidgets(2));
        expect(find.byKey(const Key('alerts-empty')), findsNothing);
        // Tornado (extreme) first.
        expect(
          t.getTopLeft(find.text('Tornado Warning')).dy,
          lessThan(t.getTopLeft(find.text('Flood Warning')).dy),
        );
        expect(
          find.text(
            'Your last known location · Portland, OR',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        await t.pumpWidget(const SizedBox());
      },
    );

    testWidgets('empty: one plain line', (t) async {
      final (c, _) = await world(t, alerts: false);
      await t.pumpWidget(MaterialApp(home: WeatherAlertsPage(controller: c)));
      await t.pump();
      expect(find.text('No warnings for your area.'), findsOneWidget);
      expect(find.byKey(const Key('wx-alert-0')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('an unconfirmed radio alert says so', (t) async {
      final (c, r) = await world(t, alerts: false);
      final a = WxAlert(
        key: 'vtec:K.TO.W.1.2026',
        event: 'Tornado Warning',
        issued: DateTime.now().toUtc(),
        rev: 1,
        expires: DateTime.now().toUtc().add(const Duration(minutes: 30)),
        source: WxSource.lora,
        trust: WxTrust.unconfirmed,
        fromName: 'Ridge phone',
        areaDesc: 'Hood River, OR',
      );
      await t.runAsync(() => r.service.handle([a]));
      await t.pumpWidget(MaterialApp(home: WeatherAlertsPage(controller: c)));
      await t.pump();
      expect(find.text('Unconfirmed, from Ridge phone'), findsOneWidget);
      expect(find.text('National Weather Service, via radio'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('wide screens get a dialog', (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final (c, _) = await world(t);
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => openWeatherAlerts(ctx, c),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
      expect(find.byKey(const Key('alerts-dialog')), findsOneWidget);
      expect(find.text('Tornado Warning'), findsOneWidget);
      await t.tap(find.byTooltip('Close'));
      await settle(t);
      expect(find.byKey(const Key('alerts-dialog')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets(
      'Settings: on/off, Wi-Fi only, extreme switch, areas, open the page',
      (t) async {
        final (c, _) = await world(t);
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
        expect(find.text('Weather alerts'), findsOneWidget);
        expect(c.settings.wxAlerts, isTrue);
        expect(c.settings.wxWifiOnly, isFalse);
        expect(c.settings.wxExtremeSound, isFalse, reason: 'default off');
        expect(find.text('Areas covered'), findsOneWidget);
        expect(
          find.text('Your last known location · Portland, OR'),
          findsOneWidget,
        );
        await t.tap(find.byKey(const Key('wx-wifi')));
        await t.pump();
        expect(c.settings.wxWifiOnly, isTrue);
        await t.tap(find.byKey(const Key('wx-extreme')));
        await t.pump();
        expect(c.settings.wxExtremeSound, isTrue);
        await t.ensureVisible(find.byKey(const Key('wx-open')));
        await t.tap(find.byKey(const Key('wx-open')));
        await settle(t);
        expect(find.byKey(const Key('alerts-list')), findsOneWidget);
        await t.pageBack();
        await settle(t);
        // Off hides the rest and stops the checks.
        await t.ensureVisible(find.byKey(const Key('wx-on')));
        await t.tap(find.byKey(const Key('wx-on')));
        await t.pump();
        expect(c.settings.wxAlerts, isFalse);
        expect(find.byKey(const Key('wx-wifi')), findsNothing);
        await t.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'Talk status line: a small icon only while a warning is in force',
      (t) async {
        final (c, r) = await world(t);
        await t.pumpWidget(homeApp(c));
        await settle(t);
        final chip = find.byKey(const Key('talk-weather-shortcut'));
        expect(chip, findsOneWidget);
        expect(
          find.byTooltip('Weather alert: Tornado Warning'),
          findsOneWidget,
        );
        await t.tap(chip);
        await settle(t);
        expect(find.byKey(const Key('alerts-list')), findsOneWidget);
        await t.pageBack();
        await settle(t);
        // Alerts off: no icon.
        await t.runAsync(() => c.setWxAlerts(false));
        await t.pump();
        expect(find.byKey(const Key('talk-weather-shortcut')), findsNothing);
        await t.runAsync(() => c.setWxAlerts(true));
        // The warnings end: no icon.
        r.nws.alerts = collection([]);
        await t.runAsync(() => r.service.poll());
        await t.pump();
        expect(find.byKey(const Key('talk-weather-shortcut')), findsNothing);
        await finish(t);
      },
    );
  });
}
