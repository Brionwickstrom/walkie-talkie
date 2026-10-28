import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imports/geo_import.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/search/fetch.dart';
import 'package:walkie_talkie/trip/search/map_search.dart';
import 'package:walkie_talkie/trip/search/nominatim.dart';
import 'package:walkie_talkie/trip/search/offline_search.dart';
import 'package:walkie_talkie/trip/search/overpass.dart';
import 'package:walkie_talkie/trip/search/rate_limiter.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/track.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_search_page.dart';

import 'messaging_fakes.dart';
import 'trip_integration_test.dart' show FakeHost, trip;

const me = 0x1111, bob = 0x2222;

String fixture() =>
    File('test/fixtures/overpass_trapper_creek.json').readAsStringSync();

// Nominatim jsonv2 answer for "Trapper Creek Wilderness".
const nominatimAnswer = '''[
  {"place_id": 1, "osm_type": "relation", "osm_id": 5555, "lat": "45.8836",
   "lon": "-121.9793", "category": "boundary", "type": "protected_area",
   "name": "Trapper Creek Wilderness",
   "display_name": "Trapper Creek Wilderness, Skamania County, Washington, United States",
   "boundingbox": ["45.8500", "45.9200", "-122.0300", "-121.9300"]},
  {"place_id": 2, "osm_type": "node", "osm_id": 77, "lat": "45.87",
   "lon": "-121.99", "category": "highway", "type": "trailhead",
   "name": "Trapper Creek Trailhead",
   "display_name": "Trapper Creek Trailhead, Washington",
   "boundingbox": ["45.8699", "45.8701", "-121.9901", "-121.9899"]},
  {"place_id": 3, "lat": "bad", "lon": "x"}
]''';

/// Records requests and answers from a script.
class FakeFetch {
  FakeFetch(this.answer);
  final String Function(FetchRequest r) answer;
  final requests = <FetchRequest>[];
  Future<String> call(FetchRequest r) async {
    requests.add(r);
    return answer(r);
  }
}

class _RealHttp extends HttpOverrides {}

RateLimiter instantLimiter() => RateLimiter(Duration.zero, sleep: (_) async {});

void main() {
  group('Overpass to layer', () {
    test('fixture: named trails merged, route ways once, places typed', () {
      final r = overpassToData(fixture(), name: 'Trapper Creek trails');
      final d = r.data;
      expect(d.name, 'Trapper Creek trails');
      final names = d.lines.map((l) => l.name).toList();
      expect(names, [
        'Observation Trail #132',
        'Forest Road 5401',
        'Trapper Creek Trail #192',
        // v2.1.0: unnamed paths are kept (offline routing needs them).
        'Unnamed path',
      ]);
      // Two route members touching end to end (one reversed) -> one line.
      expect(d.lines[0].points, hasLength(3));
      expect(d.lines[0].points.first, const GeoPoint(45.88, -121.98));
      expect(d.lines[0].points.last, const GeoPoint(45.89, -121.97));
      // Two ways of the same trail -> one line of 4 points.
      expect(d.lines[2].points, hasLength(4));
      expect(r.trails, 4);
      // The unnamed path is now kept; a street is still left out.
      expect(d.lines[3].points.length, greaterThanOrEqualTo(2));
      expect(names.any((n) => n.contains('Main')), isFalse);

      final kinds = d.waypoints.map((w) => w.kind).toList();
      expect(kinds, [
        'trailhead',
        'water',
        'spring',
        'campsite',
        'shelter',
        'lake',
        'peak',
      ]);
      // Duplicate trailhead dropped, invalid point dropped.
      expect(d.waypoints.where((w) => w.kind == 'trailhead'), hasLength(1));
      expect(d.waypoints.any((w) => w.name == 'Broken'), isFalse);
      final peak = d.waypoints.last;
      expect(peak.name, 'Observation Peak');
      expect(peak.description, 'Peak · 1287 m');
      expect(d.waypoints[1].name, 'Drinking water');
      expect(d.waypoints[2].name, 'Spring');
      final lake = d.waypoints.firstWhere((w) => w.kind == 'lake');
      expect(lake.pos, const GeoPoint(45.895, -121.96));
      expect(r.partial, isFalse);
    });

    test('server remark marks the result partial', () {
      final r = overpassToData({
        'elements': <Object>[],
        'remark': 'runtime error: Query timed out in "query" at line 4',
      });
      expect(r.partial, isTrue);
      expect(r.data.isEmpty, isTrue);
      expect(
        () => overpassToData('<html>busy</html>'),
        throwsA(isA<FetchException>()),
      );
    });

    test('chainSegments joins in any direction and keeps gaps apart', () {
      const a = GeoPoint(1, 1), b = GeoPoint(1, 2), c = GeoPoint(1, 3);
      const x = GeoPoint(5, 5), y = GeoPoint(5, 6);
      final out = chainSegments([
        [b, c],
        [x, y],
        [b, a],
      ]);
      expect(out, hasLength(2));
      expect(out.first, [a, b, c]);
      expect(out.last, [x, y]);
    });

    test('kinds from OSM tags', () {
      expect(osmPlaceKind({'natural': 'volcano'})!.kind, 'peak');
      expect(osmPlaceKind({'tourism': 'wilderness_hut'})!.label, 'Hut');
      expect(
        osmPlaceKind({'natural': 'water', 'water': 'pond'})!.label,
        'Pond',
      );
      expect(osmPlaceKind({'highway': 'path'}), isNull);
    });
  });

  group('query building', () {
    const b = GeoBounds(45.85, -122.03, 45.92, -121.93);

    test('Overpass query: area + bbox, timeout, size cap, geometry', () {
      final q = buildTrailQuery(b, areaId: 3600005555);
      expect(q, startsWith('[out:json][timeout:30][maxsize:'));
      expect(q, contains('area(3600005555)->.a;'));
      expect(
        q,
        contains(
          'way["highway"~"^(path|footway|track|bridleway)\$"]["name"]'
          '(area.a)(45.85000,-122.03000,45.92000,-121.93000);',
        ),
      );
      expect(q, contains('relation["route"="hiking"](area.a)('));
      for (final tag in [
        '"highway"="trailhead"',
        'peak|volcano|spring',
        'drinking_water',
        'camp_site',
        '"amenity"="shelter"',
        '"natural"="water"',
      ]) {
        expect(q, contains(tag));
      }
      expect(q, contains('.t out geom qt;'));
      expect(q, contains('.p out center qt;'));
      final plain = buildTrailQuery(b, timeoutS: 10);
      expect(plain, isNot(contains('area')));
      expect(plain, contains('[timeout:10]'));
      expect(plain, contains('(45.85000,-122.03000,45.92000,-121.93000);'));
    });

    test('Nominatim URL follows the usage policy shape', () {
      final u = NominatimClient.searchUri('  Trapper   Creek Wilderness ');
      expect(u.host, 'nominatim.openstreetmap.org');
      expect(u.queryParameters['q'], 'Trapper Creek Wilderness');
      expect(u.queryParameters['format'], 'jsonv2');
      expect(u.queryParameters['limit'], '8');
      expect(u.toString(), contains('q=Trapper+Creek+Wilderness'));
    });

    test('Nominatim answers parse; area ids for ways and relations', () {
      final r = NominatimClient.parse(nominatimAnswer);
      expect(r, hasLength(2));
      expect(r.first.name, 'Trapper Creek Wilderness');
      expect(r.first.overpassAreaId, 3600005555);
      expect(r.first.kindLabel, 'Protected area');
      expect(r.first.bounds!.north, 45.92);
      expect(r.last.overpassAreaId, isNull);
      expect(
        const PlaceResult(
          name: 'x',
          displayName: 'x',
          center: GeoPoint(0, 0),
          osmType: 'way',
          osmId: 9,
        ).overpassAreaId,
        2400000009,
      );
    });

    test('area cap trims big places and grows tiny ones', () {
      final big = capBounds(const GeoBounds(44, -123, 47, -120));
      expect(big.trimmed, isTrue);
      final s = boundsSizeKm(big.bounds);
      expect(s.w, closeTo(maxTrailAreaKm, 0.5));
      expect(s.h, closeTo(maxTrailAreaKm, 0.5));
      final tiny = capBounds(const GeoBounds(45.87, -121.99, 45.87, -121.99));
      expect(tiny.trimmed, isFalse);
      expect(boundsSizeKm(tiny.bounds).h, closeTo(minTrailAreaKm, 0.1));
      final ok = capBounds(b);
      expect(ok.trimmed, isFalse);
      expect(ok.bounds.south, b.south);
      expect(ok.bounds.east, b.east);
      // Off-centre point near an edge still gets the full allowed box.
      final edge = capBounds(
        const GeoBounds(40, -125, 50, -115),
        center: const GeoPoint(40.01, -124.99),
      );
      expect(edge.bounds.south, closeTo(40, 1e-9));
      expect(edge.bounds.west, closeTo(-125, 1e-9));
      expect(boundsSizeKm(edge.bounds).h, closeTo(maxTrailAreaKm, 0.5));
    });
  });

  group('rate limiter', () {
    test(
      'spaces requests at least the interval apart, one at a time',
      () async {
        final clock = FakeClock();
        final slept = <Duration>[];
        final l = RateLimiter(
          const Duration(milliseconds: 1100),
          clock: clock.call,
          sleep: (d) async {
            slept.add(d);
            clock.advance(d);
          },
        );
        final starts = <DateTime>[];
        var running = 0, maxRunning = 0;
        Future<int> job(int i) => l.run(() async {
          running++;
          maxRunning = running > maxRunning ? running : maxRunning;
          starts.add(clock.now);
          await Future<void>.delayed(Duration.zero);
          clock.advance(const Duration(milliseconds: 200));
          running--;
          return i;
        });
        final r = await Future.wait([job(1), job(2), job(3)]);
        expect(r, [1, 2, 3]);
        expect(maxRunning, 1);
        for (var i = 1; i < starts.length; i++) {
          expect(
            starts[i].difference(starts[i - 1]),
            greaterThanOrEqualTo(const Duration(milliseconds: 1100)),
          );
        }
        expect(slept, [
          const Duration(milliseconds: 900),
          const Duration(milliseconds: 900),
        ]);
        // After a quiet second, no wait.
        clock.advance(const Duration(seconds: 2));
        expect(l.waitNow, Duration.zero);
      },
    );

    test('a failing request does not block the next', () async {
      final l = instantLimiter();
      await expectLater(
        l.run<int>(() async => throw FetchException('x')),
        throwsA(isA<FetchException>()),
      );
      expect(await l.run(() async => 5), 5);
    });

    test('Nominatim: cached repeats, shared limiter', () async {
      final clock = FakeClock();
      final slept = <Duration>[];
      final limiter = RateLimiter(
        const Duration(seconds: 1),
        clock: clock.call,
        sleep: (d) async {
          slept.add(d);
          clock.advance(d);
        },
      );
      final f = FakeFetch((_) => nominatimAnswer);
      final n = NominatimClient(
        fetch: f.call,
        limiter: limiter,
        clock: clock.call,
      );
      await n.search('Trapper Creek');
      await n.search('  trapper   creek ');
      expect(f.requests, hasLength(1));
      await n.search('Soda Peaks');
      expect(f.requests, hasLength(2));
      expect(slept, [const Duration(seconds: 1)]);
      expect(await n.search('a'), isEmpty);
      expect(f.requests, hasLength(2));
    });

    test('debouncer runs only the last call', () async {
      final d = Debouncer(const Duration(milliseconds: 30));
      final calls = <int>[];
      d(() => calls.add(1));
      d(() => calls.add(2));
      d(() => calls.add(3));
      expect(d.pending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, [3]);
      d(() => calls.add(4));
      d.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, [3]);
    });
  });

  group('offline search index', () {
    late Directory dir;
    late MapLayers layers;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('search184');
      layers = MapLayers(dir);
    });
    tearDown(() => dir.delete(recursive: true));

    test('normalize folds case, accents and punctuation', () {
      expect(
        normalizeSearch("  Café  Lake! (Mt. St. Helen's) "),
        'cafe lake mt st helens',
      );
    });

    test(
      'indexed on import, kept on reload, updated on rename/delete',
      () async {
        final r = overpassToData(fixture(), name: 'Trapper Creek trails');
        final l = await layers.addTrail(r.data, attribution: osmAttribution);
        expect(layers.index.hasLayer(l.id), isTrue);
        expect(layers.index.size, 4 + 7);

        var hits = layers.index.search('trapper');
        expect(hits.first.title, 'Trapper Creek Trail #192');
        expect(hits.first.kind, SearchKind.trail);
        expect(hits.first.doc.line, hasLength(4));
        expect(hits.first.doc.lengthM, greaterThan(500));
        expect(hits.map((h) => h.title), contains('Trapper Creek Trailhead'));

        // Exact match first; kind words match through the subtitle.
        hits = layers.index.search('observation peak');
        expect(hits.first.title, 'Observation Peak');
        expect(hits.first.kind, SearchKind.place);
        expect(hits.first.doc.placeKind, 'peak');
        expect(
          layers.index.search('lake').map((h) => h.title),
          containsAll(['Sister Rocks Lake', 'Lake Camp']),
        );
        expect(
          layers.index.search('obs tr').first.title,
          'Observation Trail #132',
        );
        expect(layers.index.search('zzz'), isEmpty);

        // Reload from disk: kinds and attribution survive, index rebuilt.
        final again = MapLayers(dir);
        await again.load();
        expect(again.trails.single.attribution, osmAttribution);
        expect(again.trails.single.data!.waypoints.last.kind, 'peak');
        expect(again.index.search('sister').single.doc.placeKind, 'lake');

        await again.rename(again.trails.single, 'Wilderness');
        expect(again.index.search('trapper').first.doc.subtitle, 'Wilderness');
        await again.delete(again.trails.single);
        expect(again.index.size, 0);
        expect(again.index.search('trapper'), isEmpty);
      },
    );

    test('ranking: prefix beats contains; closer wins ties; dupes merged', () {
      SearchDoc pin(String t, GeoPoint p) =>
          SearchDoc(kind: SearchKind.pin, title: t, pos: p, ref: t);
      const here = GeoPoint(45.88, -121.98);
      final docs = [
        pin('Old camp', const GeoPoint(45.0, -121.0)),
        pin('Camp', const GeoPoint(46.5, -121.0)),
        pin('Camp', const GeoPoint(45.881, -121.981)),
        pin('Base camp', const GeoPoint(45.881, -121.981)),
        pin('Campfire ring', const GeoPoint(45.9, -121.9)),
        SearchDoc(
          kind: SearchKind.place,
          title: 'Camp',
          pos: const GeoPoint(45.8811, -121.9811),
          placeKind: 'campsite',
        ),
      ];
      final hits = rank('camp', docs, near: here);
      expect(hits[0].title, 'Camp');
      expect(hits[0].doc.pos, const GeoPoint(45.881, -121.981));
      expect(hits[0].distanceM, lessThan(200));
      expect(hits[1].title, 'Camp');
      expect(hits[1].kind, SearchKind.place);
      expect(hits[2].title, 'Camp');
      expect(hits[2].doc.pos.lat, 46.5);
      expect(hits[3].title, 'Campfire ring');
      // Word prefix ("Base camp", "Old camp") after title prefix.
      expect(
        hits.sublist(4).map((h) => h.title),
        containsAll(['Base camp', 'Old camp']),
      );
      // Same kind, name and place: once.
      final dup = rank('camp', [docs[2], docs[2]]);
      expect(dup, hasLength(1));
      expect(rank('  ', docs), isEmpty);
    });
  });

  group('TripController search', () {
    late Directory dir;
    late FakeClock clock;
    late FakeHost host;
    late FakeFetch fetch;
    late TripController t;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('trip184');
      clock = FakeClock();
      host = FakeHost(me);
      fetch = FakeFetch((r) {
        if (r.uri.host.contains('nominatim')) return nominatimAnswer;
        final q = Uri.splitQueryString(r.body!)['data']!;
        // The outline gives nothing: the client retries with the box.
        if (q.contains('area(')) return '{"elements": []}';
        return fixture();
      });
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: dir,
        userAgent: 'WalkieTalkie/test',
        clock: clock.call,
        fetch: fetch.call,
        searchLimiter: instantLimiter(),
      );
      t.tiles.online = false;
      await t.start();
    });
    tearDown(() async {
      t.dispose();
      await dir.delete(recursive: true);
    });

    test('offline: pins, shared pins, people, trails and areas', () async {
      await t.addPin(
        PinType.water,
        const GeoPoint(45.87, -121.98),
        label: 'Creek water',
      );
      host.inbound.add(
        trip(
          bob,
          const PinMsg(
            1,
            pinId: 4,
            type: PinType.meetup,
            pos: GeoPoint(45.89, -121.97),
            label: 'Lunch rock',
          ),
        ),
      );
      final shared = t.searchOffline('lunch').single;
      expect(shared.kind, SearchKind.sharedPin);
      expect(shared.doc.subtitle, contains('from ${host.nameOf(bob)}'));
      t.people[bob] = PersonPos(
        bob,
        const GeoPoint(45.88, -121.97),
        clock.now,
        TransportKind.ble,
        1,
      );
      t.savedTracks.add(
        Track(
          7,
          name: 'Morning loop',
          points: [
            const TrackPt(GeoPoint(45.86, -121.99)),
            const TrackPt(GeoPoint(45.87, -121.98)),
          ],
        ),
      );
      t.tiles.regions.add(
        OfflineRegion(
          name: 'Trapper Creek topo',
          sourceId: 'topo',
          bounds: const GeoBounds(45.85, -122.03, 45.92, -121.93),
          minZoom: 10,
          maxZoom: 15,
          tiles: 100,
          bytes: 1000,
          at: clock.now,
        ),
      );
      // Title prefix (my pin) before a later word (the downloaded area).
      expect(t.searchOffline('creek').map((h) => h.kind), [
        SearchKind.pin,
        SearchKind.area,
      ]);
      expect(t.searchOffline('water').single.title, 'Creek water');
      // The person first; their shared pin ("from P2222") after.
      final who = t.searchOffline(host.nameOf(bob));
      expect(who.map((h) => h.kind), [SearchKind.person, SearchKind.sharedPin]);
      expect(who.first.doc.pos, const GeoPoint(45.88, -121.97));
      final loop = t.searchOffline('morning').single;
      expect(loop.kind, SearchKind.track);
      expect(loop.doc.line, hasLength(2));
      final area = t.searchOffline('topo').single;
      expect(area.kind, SearchKind.area);
      expect(area.doc.bounds!.north, 45.92);
    });

    test('no network: online search says so, offline still answers', () async {
      await t.addPin(
        PinType.camp,
        const GeoPoint(45.9, -121.96),
        label: 'Trapper camp',
      );
      final r = await t.findPlaces('Trapper Creek Wilderness');
      expect(r.status, OnlineStatus.noSignal);
      expect(r.message, noSignalMessage);
      expect(fetch.requests, isEmpty);
      expect(t.searchOffline('trapper').single.title, 'Trapper camp');
      await expectLater(
        t.importTrailsFor(visible: const GeoBounds(45.8, -122, 45.9, -121.9)),
        throwsA(isA<NoSignalException>()),
      );

      t.tiles.online = true;
      await t.setOfflineSaver(true);
      final saver = await t.findPlaces('Trapper Creek Wilderness');
      expect(saver.noSignal, isTrue);
      expect(saver.message, contains('Offline power save'));
      expect(fetch.requests, isEmpty);
    });

    test('unreachable network and server errors fail gracefully', () async {
      Future<OnlineSearchResult> withFetch(Fetch f) => MapSearch(
        fetch: f,
        canUseNetwork: () => null,
        nominatim: NominatimClient(fetch: f, limiter: instantLimiter()),
      ).findPlaces('Trapper');
      expect(
        (await withFetch((_) async => throw NoSignalException())).status,
        OnlineStatus.noSignal,
      );
      final busy = await withFetch(
        (_) async => throw FetchException('busy', status: 429),
      );
      expect(busy.status, OnlineStatus.failed);
      expect(busy.message, 'busy');
      expect((await withFetch((_) async => '[]')).status, OnlineStatus.empty);

      // A real socket to a closed port: no signal, not a crash.
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      // (flutter_test fakes HttpClient; use the real one here.)
      Object? err;
      await HttpOverrides.runWithHttpOverrides(() async {
        final io = ioFetch('WalkieTalkie/test');
        try {
          await io(FetchRequest(Uri.parse('http://127.0.0.1:$port/search')));
        } catch (e) {
          err = e;
        }
      }, _RealHttp());
      expect(err, isA<NoSignalException>());
    });

    test('online: find a place, get its trails as an offline layer', () async {
      t.tiles.online = true;
      final r = await t.findPlaces('Trapper Creek Wilderness');
      expect(r.status, OnlineStatus.ok);
      final place = r.places.first;
      final nom = fetch.requests.single;
      expect(nom.uri.queryParameters['q'], 'Trapper Creek Wilderness');

      final got = await t.importTrailsFor(place: place);
      // Outline first (empty here), then the box.
      final posts = fetch.requests.where((x) => x.method == 'POST').toList();
      expect(posts, hasLength(2));
      expect(
        posts.first.headers['Content-Type'],
        startsWith('application/x-www-form-urlencoded'),
      );
      expect(
        Uri.splitQueryString(posts.first.body!)['data'],
        contains('area(3600005555)'),
      );
      expect(
        Uri.splitQueryString(posts.last.body!)['data'],
        isNot(contains('area(')),
      );
      expect(posts.first.maxBytes, OverpassClient.maxAnswerBytes);

      expect(got.layer.name, 'Trapper Creek Wilderness trails');
      expect(got.layer.attribution, osmAttribution);
      expect(got.result.trails, 4);
      expect(got.trimmed, isFalse);
      expect(t.layers.trails.single.id, got.layer.id);
      // Indexed on import: found with no network.
      t.tiles.online = false;
      expect(t.searchOffline('observation peak').first.kind, SearchKind.place);
      expect(
        t.searchOffline('trapper creek trail').first.doc.layerId,
        got.layer.id,
      );
    });

    test('empty answer is an error, not an empty layer', () async {
      t.tiles.online = true;
      final empty = TripController(
        host: host,
        settings: TripSettings(),
        dir: Directory('${dir.path}/b'),
        userAgent: 'test',
        clock: clock.call,
        fetch: FakeFetch((_) => jsonEncode({'elements': []})).call,
        searchLimiter: instantLimiter(),
      );
      await empty.start();
      await expectLater(
        empty.importTrailsFor(
          visible: const GeoBounds(45.8, -122, 45.9, -121.9),
        ),
        throwsA(isA<FetchException>()),
      );
      expect(empty.layers.trails, isEmpty);
      empty.dispose();
    });
  });

  test('Overpass retries a busy server once, not a rate limit', () async {
    var n = 0;
    final c = OverpassClient(
      limiter: instantLimiter(),
      fetch: (r) async {
        n++;
        if (n == 1) throw FetchException('busy', status: 502);
        return fixture();
      },
    );
    final r = await c.trails(const GeoBounds(45.85, -122.03, 45.92, -121.93));
    expect(n, 2);
    expect(r.trails, 4);
    final limited = OverpassClient(
      limiter: instantLimiter(),
      fetch: (r) async => throw FetchException('slow down', status: 429),
    );
    await expectLater(
      limited.trails(const GeoBounds(45.85, -122.03, 45.92, -121.93)),
      throwsA(isA<FetchException>()),
    );
  });

  group('search page', () {
    late Directory dir;
    late TripController t;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('page184');
      t = TripController(
        host: FakeHost(me),
        settings: TripSettings(),
        dir: dir,
        userAgent: 'test',
        clock: FakeClock().call,
        fetch: (_) async => throw StateError('no network in tests'),
      );
      t.tiles.online = false;
      await t.start();
      await t.layers.addTrail(
        overpassToData(fixture(), name: 'Trapper Creek trails').data,
        attribution: osmAttribution,
      );
    });
    tearDown(() async {
      t.dispose();
      await dir.delete(recursive: true);
    });

    testWidgets('no signal message with offline results below; pick one', (
      tester,
    ) async {
      MapSearchPick? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await Navigator.push<MapSearchPick>(
                    ctx,
                    MaterialPageRoute(builder: (_) => MapSearchPage(trip: t)),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('mapSearchField')),
        'trapper',
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Trapper Creek Trail #192'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mapSearchOnline')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mapSearchNoSignal')), findsOneWidget);
      expect(find.text(noSignalMessage), findsOneWidget);
      expect(find.text('Trapper Creek Trailhead'), findsOneWidget);
      await tester.tap(find.text('Trapper Creek Trailhead'));
      await tester.pumpAndSettle();
      expect(picked, isA<OfflinePick>());
      expect((picked! as OfflinePick).hit.doc.placeKind, 'trailhead');
    });
  });

  test('waypoint kind round-trips through ImportedWaypoint', () {
    final w = ImportedWaypoint('A', const GeoPoint(1, 2), kind: 'peak');
    expect(w.kind, 'peak');
    expect(ImportedWaypoint('B', const GeoPoint(1, 2)).kind, '');
  });
}
