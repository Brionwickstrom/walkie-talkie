import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/app/power_plan.dart';
import 'package:walkie_talkie/trip/drive/drive_nav.dart';
import 'package:walkie_talkie/trip/drive/road_data.dart';
import 'package:walkie_talkie/trip/drive/road_download.dart';
import 'package:walkie_talkie/trip/drive/road_router.dart';
import 'package:walkie_talkie/trip/drive/road_service.dart';
import 'package:walkie_talkie/trip/drive/speech.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imports/geo_import.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/imports/map_packs.dart';
import 'package:walkie_talkie/trip/search/fetch.dart';
import 'package:walkie_talkie/trip/search/rate_limiter.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/drive_page.dart';
import 'package:walkie_talkie/ui/offline_areas_page.dart';

import 'trip_integration_test.dart' show FakeHost;

const lat0 = 45.75, lng0 = -122.25;

GeoPoint at(double e, double n) => GeoPoint(
  lat0 + n / 111132.954,
  lng0 + e / (111319.49 * cos(lat0 * pi / 180)),
);

/// A little OSM: nodes placed in metres, ways by node ids.
class Osm {
  final coords = <int, (double, double)>{};
  final nodeTags = <int, Map<String, String>>{};
  final ways = <OsmWay>[];
  int _way = 1;

  void node(int id, double e, double n, [Map<String, String>? tags]) {
    final p = at(e, n);
    coords[id] = (p.lat, p.lng);
    if (tags != null) nodeTags[id] = tags;
  }

  /// A straight road from node [a] to [b] with [mid] extra shape nodes.
  void road(List<int> ids, Map<String, String> tags) =>
      ways.add(OsmWay(_way++, ids, tags));

  RoadData build() => RoadData.build(
    ways,
    coords,
    nodeTags: nodeTags,
    builtAt: DateTime(2026, 10, 1),
  );

  /// Overpass-style JSON of everything.
  String overpassJson() => jsonEncode({
    'elements': [
      for (final e in coords.entries)
        {
          'type': 'node',
          'id': e.key,
          'lat': e.value.$1,
          'lon': e.value.$2,
          if (nodeTags[e.key] != null) 'tags': nodeTags[e.key],
        },
      for (final w in ways)
        {'type': 'way', 'id': w.id, 'nodes': w.nodes, 'tags': w.tags},
    ],
  });
}

/// Nodes every [step] m from (e0,n0) to (e1,n1), ids from [id0].
List<int> chain(
  Osm o,
  int id0,
  double e0,
  double n0,
  double e1,
  double n1, {
  int step = 250,
  Map<int, int> reuse = const {},
  int? first,
  int? last,
}) {
  final len = sqrt(pow(e1 - e0, 2) + pow(n1 - n0, 2));
  final n = max(1, (len / step).round());
  return [
    for (var i = 0; i <= n; i++)
      (i == 0 ? first : null) ??
          (i == n ? last : null) ??
          reuse[i] ??
          (() {
            o.node(id0 + i, e0 + (e1 - e0) * i / n, n0 + (n1 - n0) * i / n);
            return id0 + i;
          })(),
  ];
}

DateTime jan = DateTime(2027, 1, 10), jul = DateTime(2026, 7, 1);

/// Residential stubs before [a] and after [b] so the trip starts and ends
/// on its own street.
void stubs(Osm o, int a, double ea, int b, double eb) {
  o.road(chain(o, 900, ea - 300, 0, ea, 0, last: a), {
    'highway': 'residential',
    'name': 'Start Lane',
  });
  o.road(chain(o, 950, eb, 0, eb + 300, 0, first: b), {
    'highway': 'residential',
    'name': 'End Lane',
  });
}

void main() {
  group('road rules (OSM tags)', () {
    test('FR 4109: gravel, smoothness=bad = rough; name with ref', () {
      final a = RoadRules.classify({
        'highway': 'unclassified',
        'name': 'Silverstar Road',
        'ref': 'FS 4109',
        'surface': 'gravel',
        'smoothness': 'bad',
      })!;
      expect(a.rough, 2);
      expect(a.name, 'Silverstar Road (FR 4109)');
      expect(a.speedKmh, lessThanOrEqualTo(25));
      expect(
        RoadRules.classify({'highway': 'track', 'ref': 'NF 4109'})!.name,
        'FR 4109',
      );
      expect(
        RoadRules.classify({
          'highway': 'unclassified',
          'name': 'Forest Road 16',
          'ref': 'NF 16',
        })!.name,
        'Forest Road 16',
      );
      expect(
        RoadRules.classify({
          'highway': 'motorway',
          'name': 'Banfield Expressway',
          'ref': 'I 84;US 30',
        })!.name,
        'I-84',
      );
    });

    test('high clearance / 4WD, unpaved, normal', () {
      int r(Map<String, String> t) =>
          RoadRules.classify({'highway': 'track', ...t})!.rough;
      expect(r({'4wd_only': 'yes'}), 3);
      expect(r({'tracktype': 'grade5'}), 3);
      expect(r({'smoothness': 'very_horrible'}), 3);
      expect(r({'tracktype': 'grade3'}), 2);
      expect(r({'surface': 'dirt'}), 2);
      expect(r({'tracktype': 'grade2'}), 1);
      expect(r({}), 1); // unknown track: unpaved
      expect(RoadRules.classify({'highway': 'residential'})!.rough, 0);
      expect(
        RoadRules.classify({'highway': 'track', 'smoothness': 'impassable'}),
        isNull,
      );
    });

    test('access: private / no avoided unless cars are allowed', () {
      expect(
        RoadRules.classify({'highway': 'track', 'access': 'private'}),
        isNull,
      );
      expect(RoadRules.classify({'highway': 'track', 'access': 'no'}), isNull);
      expect(
        RoadRules.classify({'highway': 'track', 'motor_vehicle': 'no'}),
        isNull,
      );
      expect(
        RoadRules.classify({
          'highway': 'track',
          'access': 'private',
          'motor_vehicle': 'yes',
        }),
        isNotNull,
      );
      expect(
        RoadRules.classify({'highway': 'residential', 'access': 'destination'})!
                .flags &
            EdgeFlag.destination,
        isNot(0),
      );
      expect(RoadRules.classify({'highway': 'footway'}), isNull);
      expect(RoadRules.classify({'highway': 'path'}), isNull);
      expect(
        RoadRules.classify({'highway': 'service', 'service': 'driveway'}),
        isNull,
      );
    });

    test('one way, roundabouts, motorways, speeds', () {
      int f(Map<String, String> t) => RoadRules.classify(t)!.flags;
      expect(
        f({'highway': 'primary', 'oneway': 'yes'}) & EdgeFlag.oneway,
        isNot(0),
      );
      expect(
        f({'highway': 'primary', 'oneway': '-1'}) & EdgeFlag.onewayBack,
        isNot(0),
      );
      expect(f({'highway': 'motorway'}) & EdgeFlag.oneway, isNot(0));
      expect(
        f({'highway': 'tertiary', 'junction': 'roundabout'}) &
            (EdgeFlag.oneway | EdgeFlag.roundabout),
        EdgeFlag.oneway | EdgeFlag.roundabout,
      );
      expect(f({'highway': 'motorway_link'}) & EdgeFlag.link, isNot(0));
      expect(RoadRules.parseMaxspeed('35 mph'), 56);
      expect(RoadRules.parseMaxspeed('50'), 50);
      expect(
        RoadRules.classify({'highway': 'residential', 'maxspeed': '25 mph'})!
            .speedKmh,
        40,
      );
    });

    test('seasonal closures from :conditional tags', () {
      final (a, b) = RoadRules.closure({
        'motor_vehicle:conditional': 'no @ (Nov 15-Apr 30)',
      });
      expect(dayLabel(a), 'Nov 15');
      expect(dayLabel(b), 'Apr 30');
      expect(closedOn(dayOfYear(jan), a, b), isTrue);
      expect(closedOn(dayOfYear(jul), a, b), isFalse);
      final (c, d) = RoadRules.closure({
        'access:conditional': 'no @ (Dec-Mar)',
      });
      expect(dayLabel(c), 'Dec 1');
      expect(dayLabel(d), 'Mar 31');
      // Dated one-offs and time-of-day rules are ignored.
      expect(
        RoadRules.closure({
          'motor_vehicle:conditional': 'no @ (2023 Mar 15-2024 Mar 30)',
        }),
        (0, 0),
      );
      expect(
        RoadRules.closure({'access:conditional': 'no @ (Fr 20:00-24:00)'}),
        (0, 0),
      );
      expect(
        RoadRules.classify({'highway': 'track', 'seasonal': 'yes'})!.flags &
            EdgeFlag.seasonal,
        isNot(0),
      );
    });

    test('barriers on nodes', () {
      expect(
        RoadRules.nodeFlags({'barrier': 'gate', 'locked': 'yes'}),
        NodeFlag.blocked,
      );
      expect(
        RoadRules.nodeFlags({'barrier': 'gate', 'access': 'private'}),
        NodeFlag.blocked,
      );
      expect(RoadRules.nodeFlags({'barrier': 'gate'}), NodeFlag.gate);
      expect(
        RoadRules.nodeFlags({'barrier': 'gate', 'access': 'yes'}),
        NodeFlag.gate,
      );
      expect(RoadRules.nodeFlags({'barrier': 'bollard'}), NodeFlag.blocked);
      expect(RoadRules.nodeFlags({'barrier': 'lift_gate'}), NodeFlag.gate);
      expect(RoadRules.nodeFlags({'barrier': 'kerb'}), 0);
    });
  });

  group('routing', () {
    test(
      'a fast highway beats a short 4WD track; without it, the track (warned)',
      () {
        final o = Osm();
        final track = chain(o, 100, 0, 0, 3000, 0);
        o.road(track, {
          'highway': 'track',
          'name': 'Forest Road 99',
          'tracktype': 'grade5',
        });
        final hw = chain(o, 200, 0, 0, 1500, 1500, first: 100);
        final hw2 = chain(
          o,
          300,
          1500,
          1500,
          3000,
          0,
          first: hw.last,
          last: track.last,
        );
        o.road(hw, {'highway': 'primary', 'name': 'Highway 1'});
        o.road(hw2, {'highway': 'primary', 'name': 'Highway 1'});
        stubs(o, 100, 0, track.last, 3000);
        var g = RoadGraph(o.build());
        var r = g.route(at(-290, 0), at(3290, 0), now: jul)!;
        expect(r.lengthM, greaterThan(4500));
        expect(r.worstRough, 0);
        expect(r.warnings, isEmpty);
        o.ways.removeWhere((w) => w.tags['name'] == 'Highway 1');
        g = RoadGraph(o.build());
        r = g.route(at(-290, 0), at(3290, 0), now: jul)!;
        expect(r.lengthM, closeTo(3580, 20));
        expect(r.worstRough, 3);
        expect(r.warnings.first.kind, 'clearance');
        expect(r.warnings.first.text, contains('high clearance'));
        expect(r.duration.inMinutes, greaterThan(10)); // 12 km/h
      },
    );

    test('one-way streets', () {
      final o = Osm();
      // North street one way eastbound; south street both ways, longer.
      o.node(1, 0, 0);
      o.node(2, 1000, 0);
      final north = chain(o, 10, 0, 0, 1000, 0, first: 1, last: 2);
      o.road(north, {
        'highway': 'residential',
        'name': 'North St',
        'oneway': 'yes',
      });
      final s1 = chain(o, 20, 0, 0, 500, -600, first: 1);
      final s2 = chain(o, 40, 500, -600, 1000, 0, first: s1.last, last: 2);
      o.road(
        [...s1, ...s2.skip(1)],
        {'highway': 'residential', 'name': 'South St'},
      );
      final g = RoadGraph(o.build());
      final east = g.route(at(5, 0), at(995, 0))!;
      expect(east.lengthM, closeTo(990, 15));
      final west = g.route(at(995, 0), at(5, 0))!;
      expect(west.lengthM, greaterThan(1400));
      expect(west.segRoad.toSet(), contains('South St'));
    });

    test('locked gates are not driven through; open gates are warned', () {
      final o = Osm();
      final short = chain(o, 100, 0, 0, 2000, 0);
      o.node(short[4], 1000, 0, {'barrier': 'gate', 'locked': 'yes'});
      o.road(short, {'highway': 'unclassified', 'name': 'Gated Road'});
      final a = chain(o, 200, 0, 0, 1000, 1000, first: short.first);
      final b = chain(
        o,
        300,
        1000,
        1000,
        2000,
        0,
        first: a.last,
        last: short.last,
      );
      o.road(
        [...a, ...b.skip(1)],
        {'highway': 'unclassified', 'name': 'Long Way'},
      );
      stubs(o, short.first, 0, short.last, 2000);
      var r = RoadGraph(o.build()).route(at(-290, 0), at(2290, 0))!;
      expect(r.lengthM, greaterThan(3400));
      expect(r.warnings, isEmpty);
      // Just past the gate: around by the long way and back.
      final past = RoadGraph(o.build()).route(at(-290, 0), at(1100, 5))!;
      expect(past.lengthM, closeTo(290 + 2828 + 900, 30));
      // Behind a locked gate with no other way: through it, warned.
      final only = Osm()
        ..coords.addAll(o.coords)
        ..nodeTags.addAll(o.nodeTags)
        ..ways.addAll(o.ways.where((w) => w.tags['name'] != 'Long Way'));
      final inside = RoadGraph(only.build()).route(at(-290, 0), at(1100, 5))!;
      expect(inside.lengthM, closeTo(1390, 15));
      expect(
        inside.warnings.single.text,
        'Locked gate or barrier on Gated Road: no other way by road',
      );
      o.nodeTags[short[4]] = {'barrier': 'gate'};
      r = RoadGraph(o.build()).route(at(-290, 0), at(2290, 0))!;
      expect(r.lengthM, closeTo(2580, 15));
      expect(
        r.warnings.map((w) => w.text),
        contains('Gate on Gated Road (may be closed)'),
      );
    });

    test('closed for the season: avoided in winter, warned in summer', () {
      final o = Osm();
      final short = chain(o, 100, 0, 0, 2000, 0);
      o.road(short, {
        'highway': 'unclassified',
        'name': 'Pass Road',
        'motor_vehicle:conditional': 'no @ (Nov 15-Apr 30)',
      });
      final a = chain(o, 200, 0, 0, 1000, 1500, first: short.first);
      final b = chain(
        o,
        300,
        1000,
        1500,
        2000,
        0,
        first: a.last,
        last: short.last,
      );
      o.road(
        [...a, ...b.skip(1)],
        {'highway': 'unclassified', 'name': 'Valley Road'},
      );
      stubs(o, short.first, 0, short.last, 2000);
      final g = RoadGraph(o.build());
      final winter = g.route(at(-290, 0), at(2290, 0), now: jan)!;
      expect(winter.segRoad.toSet(), isNot(contains('Pass Road')));
      final summer = g.route(at(-290, 0), at(2290, 0), now: jul)!;
      expect(summer.lengthM, closeTo(2580, 15));
      expect(summer.warnings.single.text, 'Pass Road: closed Nov 15 to Apr 30');
    });

    test('turns, keep, roundabout exits and arrival in the steps', () {
      final o = Osm();
      // First Street east 1 km to a T junction: Second Street north (left),
      // Third Street south.
      final first = chain(o, 100, -1000, 0, 0, 0);
      o.road(first, {'highway': 'residential', 'name': 'First Street'});
      final second = chain(o, 200, 0, 0, 0, 1000, first: first.last);
      o.road(second, {'highway': 'residential', 'name': 'Second Street'});
      final third = chain(o, 300, 0, 0, 0, -800, first: first.last);
      o.road(third, {'highway': 'residential', 'name': 'Third Street'});
      // Roundabout at the top of Second Street (counter-clockwise ring).
      const c = 1030.0;
      o.node(400, 0, c - 30); // S (where Second Street arrives)
      o.node(401, 30, c); // E
      o.node(402, 0, c + 30); // N
      o.node(403, -30, c); // W
      o.road(
        [second.last, 400],
        {'highway': 'residential', 'name': 'Second Street'},
      );
      o.road(
        [400, 401, 402, 403, 400],
        {'highway': 'tertiary', 'junction': 'roundabout'},
      );
      final east = chain(o, 500, 30, c, 800, c, first: 401);
      o.road(east, {'highway': 'tertiary', 'name': 'East Road'});
      final north = chain(o, 600, 0, c + 30, 0, c + 800, first: 402);
      o.road(north, {'highway': 'tertiary', 'name': 'North Road'});
      final west = chain(o, 700, -30, c, -800, c, first: 403);
      o.road(west, {'highway': 'tertiary', 'name': 'West Road'});
      final g = RoadGraph(o.build());
      final r = g.route(at(-990, 0), at(-700, c), targetName: 'Camp')!;
      final texts = r.steps.map((s) => s.text).toList();
      expect(texts.first, 'Head E on First Street');
      expect(texts, contains('Turn left onto Second Street'));
      expect(
        texts,
        contains('At the roundabout, take the 3rd exit onto West Road'),
      );
      expect(texts.last, 'Arrive at Camp');
      expect(r.steps[1].maneuver, Maneuver.left);
      expect(r.steps.last.spoken, 'you have arrived at Camp');
      // Out the east side: 1st exit.
      final r2 = g.route(at(-990, 0), at(600, c))!;
      expect(
        r2.steps.map((s) => s.text),
        contains('At the roundabout, take the 1st exit onto East Road'),
      );
      // Right turn.
      final r3 = g.route(at(-990, 0), at(0, -700))!;
      expect(r3.steps[1].text, 'Turn right onto Third Street');
      expect(r3.steps[1].maneuver, Maneuver.right);
    });

    test('same road under two labels is not a step', () {
      expect(
        RoadGraph.sameRoad('SR 14', 'Lewis and Clark Trail Highway (SR 14)'),
        isTrue,
      );
      expect(
        RoadGraph.sameRoad('Forest Road 64', 'Dry Creek Road (FR 64)'),
        isTrue,
      );
      expect(
        RoadGraph.sameRoad('Wind River Road', 'Wind River Road (FR 30)'),
        isTrue,
      );
      expect(RoadGraph.sameRoad('First Street', 'Second Street'), isFalse);
    });

    test('no roads near / not connected', () {
      final o = Osm();
      o.road(chain(o, 100, 0, 0, 1000, 0), {'highway': 'residential'});
      o.road(chain(o, 200, 0, 50000, 1000, 50000), {'highway': 'residential'});
      final g = RoadGraph(o.build());
      expect(g.route(at(0, 0), at(0, 200000)), isNull); // nothing near
      expect(g.route(at(0, 0), at(500, 50000)), isNull); // not connected
      expect(g.snap(at(500, 40))!.distM, closeTo(40, 2));
    });
  });

  group('the roads file and several areas', () {
    Osm twoAreas() {
      final o = Osm();
      o.road(chain(o, 100, 0, 0, 4000, 0), {
        'highway': 'secondary',
        'name': 'Long Road',
      });
      return o;
    }

    test('encode / decode keeps everything', () {
      final o = Osm();
      final w = chain(o, 100, 0, 0, 1000, 0);
      o.node(w[2], 500, 0, {'barrier': 'gate'});
      o.road(w, {
        'highway': 'track',
        'name': 'Rd ü',
        'tracktype': 'grade4',
        'access:conditional': 'no @ (Dec-Mar)',
        'oneway': 'yes',
      });
      final d = o.build();
      final bytes = d.encode();
      expect(bytes.sublist(0, 2), [0x1f, 0x8b]);
      final e = RoadData.decode(bytes);
      expect(e.nodeCount, d.nodeCount);
      expect(e.edgeCount, d.edgeCount);
      expect(e.nodeOsm, d.nodeOsm);
      expect(e.nodeLat, d.nodeLat);
      expect(e.shapeLng, d.shapeLng);
      expect(e.names, d.names);
      expect(e.edgeRough, d.edgeRough);
      expect(e.edgeFlags, d.edgeFlags);
      expect(e.edgeClose, d.edgeClose);
      expect(e.nodeFlags, d.nodeFlags);
      expect(e.builtAt, d.builtAt);
      expect(e.bounds.south, d.bounds.south);
      expect(
        () => RoadData.decode(Uint8List.fromList(gzip.encode([1, 2, 3]))),
        throwsFormatException,
      );
    });

    test('two saved areas join into one network (a route crosses them)', () {
      final o = twoAreas();
      // Area A: first 2.5 km of the road; area B: from 1.5 km on.
      final w = o.ways.single;
      final a = OsmWay(1, w.nodes.sublist(0, 11), w.tags);
      final b = OsmWay(1, w.nodes.sublist(6), w.tags);
      final da = RoadData.build([a], o.coords);
      final db = RoadData.build([b], o.coords);
      expect(
        RoadGraph(da).route(at(100, 0), at(3900, 0))?.lengthM ?? 0,
        lessThan(2500),
      );
      final m = RoadData.merge([da, db]);
      // The shared 1 km is kept once.
      expect(m.roadKm, closeTo(4, 0.05));
      final r = RoadGraph(m).route(at(100, 0), at(3900, 0))!;
      expect(r.lengthM, closeTo(3800, 10));
    });
  });

  group('saving roads from OpenStreetMap (Overpass)', () {
    test('parse an Overpass answer', () {
      final o = Osm();
      final w = chain(o, 100, 0, 0, 1000, 0);
      o.node(w[1], 250, 0, {'barrier': 'gate', 'locked': 'yes'});
      o.road(w, {'highway': 'residential', 'name': 'A St'});
      o.road(chain(o, 200, 0, 100, 1000, 100), {'highway': 'footway'});
      final d = roadsFromOverpass(
        o.overpassJson(),
        const GeoBounds(45, -123, 46, -122),
        DateTime(2026, 10, 27),
      );
      expect(d.names, contains('A St'));
      expect(d.roadKm, closeTo(1, 0.01)); // the footway is not a road
      expect(d.nodeFlags.where((f) => f & NodeFlag.blocked != 0).length, 1);
    });

    test('size first, then pieces; a piece too big is split', () async {
      final o = Osm();
      o.road(chain(o, 100, 0, 0, 3000, 0), {
        'highway': 'residential',
        'name': 'A St',
      });
      final queries = <String>[];
      Future<String> fetch(FetchRequest r) async {
        final q = Uri.decodeQueryComponent(r.body!.substring(5));
        queries.add(q);
        if (q.contains('out count')) {
          return jsonEncode({
            'elements': [
              {
                'type': 'count',
                'tags': {'ways': '2500', 'total': '2500'},
              },
            ],
          });
        }
        final m = RegExp(r'\(([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)\)')
            .firstMatch(q)!;
        final h = double.parse(m.group(3)!) - double.parse(m.group(1)!);
        if (h > 0.1) {
          throw FetchException('Too much map data for one download. Zoom in.');
        }
        return o.overpassJson();
      }

      final dl = RoadDownloader(
        fetch: fetch,
        limiter: RateLimiter(Duration.zero),
        endpoints: const ['https://example.com/api'],
      );
      const b = GeoBounds(45.5, -122.5, 45.8, -122.0);
      final est = await dl.estimate(b);
      expect(est.ways, 2500);
      expect(est.bytes, 2500 * roadBytesPerWay);
      final prog = <RoadProgress>[];
      final d = await dl.download(b, onProgress: prog.add);
      expect(prog.last.done, prog.last.total);
      expect(prog.last.total, greaterThan(RoadDownloader.pieces(b).length));
      expect(d.roadKm, closeTo(3, 0.05)); // same road in every piece, once
      expect(d.bounds.north, b.north);
      expect(
        RoadDownloader.checkArea(const GeoBounds(45, -123, 46.5, -121)),
        contains('too big'),
      );
      expect(RoadDownloader.checkArea(b), isNull);
    });

    test('a busy server: the next one is tried', () async {
      final used = <String>[];
      final dl = RoadDownloader(
        fetch: (r) async {
          used.add(r.uri.host);
          if (r.uri.host == 'a.example') {
            throw FetchException('busy', status: 504);
          }
          return '{"elements":[{"type":"count","tags":{"ways":"7"}}]}';
        },
        limiter: RateLimiter(Duration.zero),
        endpoints: const ['https://a.example/i', 'https://b.example/i'],
      );
      expect(
        (await dl.estimate(const GeoBounds(45, -122, 45.1, -121.9))).ways,
        7,
      );
      expect(used, ['a.example', 'b.example']);
    });
  });

  group('following a drive', () {
    late DriveRoute r;
    setUp(() {
      final o = Osm();
      final first = chain(o, 100, 0, 0, 3000, 0);
      o.road(first, {'highway': 'primary', 'name': 'First Street'});
      final second = chain(o, 200, 3000, 0, 3000, 2000, first: first.last);
      o.road(second, {'highway': 'primary', 'name': 'Second Street'});
      o.road(chain(o, 300, 3000, 0, 3000, -500, first: first.last), {
        'highway': 'residential',
        'name': 'Spur',
      });
      r = RoadGraph(o.build())
          .route(at(0, 0), at(3000, 2000), targetName: 'Lake', imperial: true)!;
    });

    test('progress, next turn, off route, arrival', () {
      final f = DriveFollower(r);
      var s = f.update(at(1000, 0));
      expect(s.alongM, closeTo(1000, 5));
      expect(s.nextInM, closeTo(2000, 5));
      expect(r.steps[s.nextStep].text, 'Turn left onto Second Street');
      expect(s.road, 'First Street');
      expect(s.timeLeft.inSeconds, greaterThan(100));
      f.update(at(1500, 300));
      s = f.update(at(1500, 300));
      expect(s.offRoute, isTrue);
      expect(f.offEvents, 1);
      expect(cardinal(s.bearingToRoute), 'S');
      s = f.update(at(3000, 1990));
      expect(s.arrived, isTrue);
    });

    test('voice: early, just before, then arrival', () {
      final f = DriveFollower(r);
      final v = VoicePrompter(imperial: true);
      final said = <String>[];
      for (var e = 0.0; e <= 3000; e += 50) {
        final t = v.next(r, f.update(at(e, 0)), speedMps: 25);
        if (t != null) said.add(t);
      }
      for (var n = 50.0; n <= 2000; n += 50) {
        final t = v.next(r, f.update(at(3000, n)), speedMps: 15);
        if (t != null) said.add(t);
      }
      expect(said.first, startsWith('Head east on First Street'));
      expect(said, contains('In 1 mile, turn left onto Second Street.'));
      expect(said, contains('Turn left onto Second Street.'));
      expect(said.last, 'You have arrived at Lake.');
      expect(said.where((s) => s == 'Turn left onto Second Street.').length, 1);
    });

    test('spoken distances', () {
      expect(spokenDistance(150, imperial: true), '500 feet');
      expect(spokenDistance(400, imperial: true), 'a quarter mile');
      expect(spokenDistance(800, imperial: true), 'half a mile');
      expect(spokenDistance(1609, imperial: true), '1 mile');
      expect(spokenDistance(4000, imperial: true), '2.5 miles');
      expect(spokenDistance(300, imperial: false), '300 meters');
      expect(spokenDistance(1500, imperial: false), '1.5 kilometers');
    });

    test('GPS rate while driving respects the power modes', () {
      expect(const PowerPlan().driveInterval, const Duration(seconds: 1));
      expect(
        const PowerPlan(saver: true).driveInterval,
        const Duration(seconds: 2),
      );
      expect(
        const PowerPlan(offline: true).driveInterval,
        const Duration(seconds: 3),
      );
    });
  });

  group('trip: Drive here', () {
    late Directory tmp;
    late FakeHost host;
    late TripController t;
    late SilentSpeaker voice;
    late Osm o;

    Future<MapLayer> addRoads(RoadData d, String name) => t.layers.importRoads(
      name,
      d.encode(),
      area: d.bounds,
      summary: TripController.roadsSummary(d.roadKm, d.builtAt),
    );

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('drive');
      host = FakeHost(1);
      t = TripController(
        host: host,
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
      )..tiles.online = false;
      t.roads = RoadService.inline();
      t.speaker = voice = SilentSpeaker();
      await t.layers.load();
      await t.start();
      o = Osm();
      final first = chain(o, 100, 0, 0, 3000, 0);
      o.road(first, {'highway': 'primary', 'name': 'First Street'});
      final fr = chain(o, 200, 3000, 0, 3000, 2000, first: first.last);
      o.road(fr, {
        'highway': 'unclassified',
        'name': 'Silverstar Road',
        'ref': 'FS 4109',
        'surface': 'gravel',
        'smoothness': 'bad',
      });
      o.road(chain(o, 300, 3000, 0, 3000, -500, first: first.last), {
        'highway': 'residential',
        'name': 'Spur',
      });
    });
    tearDown(() {
      t.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('no roads saved: says where to get them', () async {
      final res = await t.driveTo(at(10, 10));
      expect(res.session, isNull);
      expect(res.message, contains('Ready-made maps'));
      expect(res.message, contains('Save this area offline'));
    });

    test(
      'route, rough road warning, spoken turns, reroute, mute, stop',
      () async {
        await addRoads(o.build(), 'Test roads');
        var res = await t.driveTo(at(3000, 2000), name: 'Trailhead');
        expect(res.message, startsWith('Waiting for GPS'));
        t.onFix(Fix(at(0, 0), DateTime.now(), speedMps: 20));
        res = await t.driveTo(at(3000, 2000), name: 'Trailhead');
        final s = res.session!;
        expect(t.drive, same(s));
        expect(
          s.route.warnings.first.text,
          contains('Silverstar Road (FR 4109)'),
        );
        expect(s.route.warnings.first.text, contains('rough'));
        expect(t.locationInterval, const PowerPlan().driveInterval);
        expect(voice.said.first, startsWith('Head east on First Street'));
        var time = DateTime.now();
        for (var e = 100.0; e <= 3000; e += 100) {
          time = time.add(const Duration(seconds: 5));
          t.onFix(Fix(at(e, 0), time, speedMps: 20));
        }
        expect(
          voice.said,
          contains('Turn left onto Silverstar Road (FR 4109).'),
        );
        // Wrong turn down the spur: off route, rerouted.
        t.onFix(Fix(at(3000, -200), time, speedMps: 10));
        t.onFix(Fix(at(3000, -300), time, speedMps: 10));
        await pumpEventQueue();
        expect(voice.said, contains('Rerouting.'));
        expect(
          t.drive!.route.points.first.lat,
          closeTo(at(3000, -300).lat, 1e-4),
        );
        // Mute.
        await t.setDriveVoice(false);
        final n = voice.said.length;
        for (var nn = -200.0; nn <= 2000; nn += 100) {
          t.onFix(Fix(at(3000, nn), time, speedMps: 10));
        }
        expect(voice.said.length, n);
        expect(t.drive!.arrived, isTrue);
        expect(host.notes.last, 'Arrived: You reached Trailhead.');
        await t.stopDrive();
        expect(t.drive, isNull);
        expect(t.settings.driveVoice, isFalse);
      },
    );

    test('a route across two saved areas', () async {
      final w = o.ways.first; // First Street
      final a = RoadData.build([
        OsmWay(1, w.nodes.sublist(0, 9), w.tags),
      ], o.coords);
      final b = RoadData.build([
        OsmWay(1, w.nodes.sublist(6), w.tags),
        ...o.ways.skip(1),
      ], o.coords);
      await addRoads(a, 'West');
      await addRoads(b, 'East');
      t.onFix(Fix(at(0, 0), DateTime.now()));
      final res = await t.driveTo(at(3000, 1500), name: 'X');
      expect(res.session!.route.lengthM, closeTo(4500, 20));
    });

    test(
      'drive to the trailhead, then hike: trail navigation starts',
      () async {
        await addRoads(o.build(), 'Test roads');
        await t.layers.addTrail(
          ImportedData(
            name: 'Trails',
            lines: [
              ImportedLine('Lake Trail', [
                for (var n = 2000.0; n <= 3000; n += 50) at(3000, n),
              ]),
            ],
            waypoints: [
              ImportedWaypoint(
                'Lake Trailhead',
                at(3000, 2000),
                kind: 'trailhead',
              ),
              ImportedWaypoint(
                'Far Trailhead',
                at(9000, 9000),
                kind: 'trailhead',
              ),
            ],
          ),
        );
        t.onFix(Fix(at(0, 0), DateTime.now()));
        final th = await t.trailheadFor(at(3000, 3000));
        expect(th!.name, 'Lake Trailhead');
        final res = await t.driveThenHike(at(3000, 3000), name: 'Lake');
        final s = res.session!;
        expect(s.name, 'Lake Trailhead');
        expect(s.hikeName, 'Lake');
        for (var e = 0.0; e <= 3000; e += 200) {
          t.onFix(Fix(at(e, 0), DateTime.now()));
        }
        for (var n = 0.0; n <= 2000; n += 200) {
          t.onFix(Fix(at(3000, n), DateTime.now()));
        }
        await pumpEventQueue();
        expect(t.drive, isNull);
        expect(t.nav, isNotNull);
        expect(t.nav!.name, 'Lake');
        expect(t.nav!.route!.lengthM, closeTo(1000, 30));
        expect(t.locationInterval, const PowerPlan().navInterval);
        expect(voice.said, contains('Now walk to Lake.'));
      },
    );

    test('trail voice prompts (optional)', () async {
      await t.layers.addTrail(
        ImportedData(
          name: 'Cross',
          lines: [
            ImportedLine('East West', [
              for (var e = -500.0; e <= 500; e += 25) at(e, 0),
            ]),
            ImportedLine('North South', [
              for (var n = -500.0; n <= 500; n += 25) at(0, n),
            ]),
          ],
        ),
      );
      t.onFix(Fix(at(-500, 0), DateTime.now()));
      await t.navigateTo(at(0, 500), name: 'Lookout');
      for (var e = -450.0; e <= 0; e += 25) {
        t.onFix(Fix(at(e, 0), DateTime.now()));
      }
      expect(voice.said, isEmpty); // off by default
      await t.setTrailVoice(true);
      t.onFix(Fix(at(-500, 0), DateTime.now()));
      await t.navigateTo(at(0, 500), name: 'Lookout');
      expect(voice.said.first, contains('First: Turn left onto North South'));
      expect(voice.said.first, startsWith('Route to Lookout, '));
      for (var e = -450.0; e <= 0; e += 25) {
        t.onFix(Fix(at(e, 0), DateTime.now()));
      }
      expect(
        voice.said
            .where(
              (s) =>
                  s.startsWith('In ') &&
                  s.contains('turn left onto North South'),
            )
            .length,
        1,
      );
      t.onFix(Fix(at(-100, 200), DateTime.now()));
      t.onFix(Fix(at(-100, 200), DateTime.now()));
      expect(voice.said.last, startsWith('You are off the route. Head'));
    });

    test('save roads for an area; update keeps the name; delete', () async {
      Future<String> fetch(FetchRequest r) async => o.overpassJson();
      final dl = RoadDownloader(
        fetch: fetch,
        limiter: RateLimiter(Duration.zero),
        endpoints: const ['https://example.com/api'],
      );
      const area = GeoBounds(45.74, -122.26, 45.78, -122.20);
      final l = await t.saveRoads(area, downloader: dl);
      expect(l.kind, MapLayerKind.roads);
      expect(l.name, 'Roads near 45.76° N, 122.23° W');
      expect(l.summary, contains('km of road'));
      expect(l.area!.north, area.north);
      await t.layers.rename(l, 'Home roads');
      final u = await t.saveRoads(
        area,
        downloader: dl,
        replace: t.layers.roads.single,
      );
      expect(t.layers.roads.single, same(u));
      expect(u.name, 'Home roads');
      // Persisted.
      final again = MapLayers(t.layers.dir);
      await again.load();
      expect(again.roads.single.area!.west, area.west);
      await t.setOfflineSaver(true);
      expect(
        () => t.saveRoads(area, downloader: dl),
        throwsA(isA<RoadDownloadException>()),
      );
      await t.layers.delete(u);
      expect(t.layers.roads, isEmpty);
    });

    test('ready-made roads pack installs as a roads layer', () async {
      final bytes = o.build().encode();
      final sha = await PackInstaller.shaOf(bytes);
      final p = MapPack.parseList(
        jsonEncode({
          'packs': [
            {
              'id': 'roads-x',
              'name': 'X roads',
              'bounds': {'s': 45.7, 'w': -122.3, 'n': 45.8, 'e': -122.1},
              'files': [
                {
                  'name': 'X_Roads.wtr',
                  'kind': 'roads',
                  'title': 'X roads',
                  'url': 'https://example.com/X_Roads.wtr',
                  'size': bytes.length,
                  'sha256': sha,
                  'summary': '4 km of road',
                },
              ],
            },
          ],
        }),
      ).single;
      expect(p.files.single.kind, PackFileKind.roads);
      final inst = PackInstaller(
        layers: t.layers,
        tempDir: Directory('${tmp.path}/t'),
        download: (u, f, on) async => f.writeAsBytes(bytes),
      );
      final added = await inst.add(p);
      expect(added.single.kind, MapLayerKind.roads);
      expect(added.single.area!.south, 45.7);
      expect(added.single.sha, sha);
      expect(packAdded(p, t.layers), isTrue);
      t.onFix(Fix(at(0, 0), DateTime.now()));
      expect((await t.driveTo(at(3000, 1000))).session, isNotNull);
    });

    testWidgets('drive card, steps, follow screen, mute', (tester) async {
      await tester.runAsync(() async {
        await addRoads(o.build(), 'Test roads');
        t.onFix(Fix(at(0, 0), DateTime.now()));
        await t.driveTo(at(3000, 2000), name: 'Trailhead');
      });
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DriveCard(trip: t, session: t.drive!, onFollow: () {}),
          ),
        ),
      );
      expect(find.text('Drive to Trailhead'), findsOneWidget);
      expect(find.textContaining('FR 4109'), findsWidgets);
      expect(find.byKey(const Key('driveWarning')), findsWidgets);
      await tester.tap(find.byKey(const Key('driveSteps')));
      await tester.pumpAndSettle();
      expect(
        find.text('Turn left onto Silverstar Road (FR 4109)'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(home: DriveFollowPage(trip: t, showMap: false)),
      );
      expect(find.byKey(const Key('driveNextText')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('driveNextText'))).data,
        'Turn left onto Silverstar Road (FR 4109)',
      );
      expect(find.byIcon(Icons.turn_left), findsWidgets);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('driveMute')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(t.settings.driveVoice, isFalse);
      expect(find.byIcon(Icons.volume_off), findsOneWidget);
      expect(find.text('Re-route'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('driveStopFollow')));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(t.drive, isNull);
    });

    testWidgets(
      'offline areas list: rename, delete; save page shows the size and saves roads',
      (tester) async {
        final dl = RoadDownloader(
          fetch: (r) async {
            final q = Uri.decodeQueryComponent(r.body!.substring(5));
            if (q.contains('out count')) {
              return '{"elements":[{"type":"count","tags":{"ways":"4000"}}]}';
            }
            return o.overpassJson();
          },
          limiter: RateLimiter(Duration.zero),
          endpoints: const ['https://example.com/api'],
        );
        late MapLayer l;
        await tester.runAsync(() async {
          l = await addRoads(o.build(), 'Test roads');
          await t.areas.migrate();
        });
        final id = t.areas.entries.single.id;
        expect(l.offlineArea, id);
        await tester.binding.setSurfaceSize(const Size(800, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: OfflineAreasPage(
              trip: t,
              view: const GeoBounds(45.74, -122.26, 45.78, -122.20),
              downloader: dl,
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Test roads'), findsOneWidget);
        expect(find.textContaining('1 saved area'), findsOneWidget);
        await tester.tap(find.byKey(Key('areaMenu:$id')));
        await tester.pumpAndSettle();
        expect(find.text('Update'), findsOneWidget);
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Gifford');
        await tester.runAsync(() async {
          await tester.tap(find.text('OK'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(find.text('Gifford'), findsOneWidget);
        for (
          var i = 0;
          i < 20 && t.layers.roads.single.name != 'Gifford roads';
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
        expect(t.layers.roads.single.name, 'Gifford roads');
        // New area: roads only (map style, elevation and trails off).
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: SaveAreaPage(
              trip: t,
              initial: const GeoBounds(46.0, -122.26, 46.1, -122.10),
              downloader: dl,
              showTiles: false,
            ),
          ),
        );
        await tester.ensureVisible(find.byKey(const Key('style:topo')));
        await tester.tap(find.byKey(const Key('style:topo')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const Key('areaElev')));
        await tester.tap(find.byKey(const Key('areaElev')));
        await tester.pump();
        await tester.ensureVisible(find.byKey(const Key('areaTrails')));
        await tester.tap(find.byKey(const Key('areaTrails')));
        await tester.pump();
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump(const Duration(milliseconds: 950));
        }
        expect(
          tester.widget<Text>(find.byKey(const Key('areaEstimate'))).data,
          allOf(contains('+ roads '), isNot(contains('checking'))),
        );
        expect(find.textContaining('Save this area (~'), findsOneWidget);
        expect(find.byKey(const Key('areaUseView')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('areaName')),
          'Silver Star',
        );

        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('areaSave')));
        });
        for (var i = 0; i < 100 && t.layers.roads.length < 2; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }
        await tester.pump();
        expect(
          t.layers.roads.map((l) => l.name),
          contains('Silver Star roads'),
        );
        // Delete from the list.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MaterialApp(home: OfflineAreasPage(trip: t)));
        await tester.pump();
        await tester.tap(find.byKey(Key('areaMenu:$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('areaDeleteOk')));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(t.layers.roads.map((l) => l.name), ['Silver Star roads']);
      },
    );
  });

  test('the ready-made roads pack is listed', () {
    final p = MapPack.parseList(File('map_packs.json').readAsStringSync())
        .firstWhere((p) => p.id == 'gp-roads');
    expect(p.name, 'Portland to Gifford Pinchot roads');
    final f = p.files.single;
    expect(f.kind, PackFileKind.roads);
    expect(f.size, inInclusiveRange(5000000, 200000000));
    expect(f.summary, contains('km of road'));
    expect(p.bounds!.contains(const GeoPoint(45.5190, -122.6795)), isTrue);
    expect(p.bounds!.contains(const GeoPoint(45.881607, -121.980238)), isTrue);
  });

  test(
    'real Portland - Gifford Pinchot pack (ROADS_PACK=path)',
    () async {
      final d = RoadData.decode(
        File(Platform.environment['ROADS_PACK']!).readAsBytesSync(),
      );
      final g = RoadGraph(d);
      // Downtown Portland to Silver Star Mountain Trailhead (end of FR 4109).
      final r = g.route(
        const GeoPoint(45.5190, -122.6795),
        const GeoPoint(45.772598, -122.244409),
        targetName: 'Silver Star Mountain Trailhead',
        now: DateTime(2026, 10, 27),
      )!;
      expect(r.lengthM / 1609.344, inInclusiveRange(40, 60));
      expect(r.warnings.map((w) => w.text).join('\n'), contains('FR 4109'));
      expect(
        r.steps.map((s) => s.text),
        contains(contains('Silverstar Road (FR 4109)')),
      );
      // Gresham to Trapper Creek Trailhead.
      final r2 = g.route(
        const GeoPoint(45.4980, -122.4310),
        const GeoPoint(45.881607, -121.980238),
      )!;
      expect(
        r2.steps.map((s) => s.text),
        contains(contains('Wind River Road')),
      );
      // Worker isolate.
      final svc = RoadService();
      await svc.load([Platform.environment['ROADS_PACK']!]);
      final r3 = await svc.route(
        const GeoPoint(45.5826, -122.3535),
        const GeoPoint(45.721747, -122.269525),
        name: 'Grouse Vista Trailhead',
      );
      expect(r3!.lengthM, greaterThan(20000));
      svc.dispose();
    },
    skip: Platform.environment['ROADS_PACK'] == null ? 'set ROADS_PACK' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
