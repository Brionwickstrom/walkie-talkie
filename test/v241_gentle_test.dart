import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imports/geo_import.dart';
import 'package:walkie_talkie/trip/nav/gentle_route.dart';
import 'package:walkie_talkie/trip/nav/nav_session.dart';
import 'package:walkie_talkie/trip/nav/trail_graph.dart';
import 'package:walkie_talkie/trip/search/fetch.dart';
import 'package:walkie_talkie/trip/search/rate_limiter.dart';
import 'package:walkie_talkie/trip/tile_cache.dart' show tileX, tileY;
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';

import 'trip_integration_test.dart' show FakeHost;
import 'v191_maps_nav_test.dart' show terrariumTile;
import 'v192_drive_test.dart' as drive;
import 'v210_gentle_test.dart' as g;

// v2.4.1: gentle routes follow trails whichever way they bend, stay on them,
// measure steepness over about one cell, never cross a wall when there is
// another way, and say so when there is not.

GeoPoint at(double e, double n) => g.at(e, n);

/// East / north (m) of a point, in the frame the test terrain is written in.
({double x, double y}) xy(double lat, double lng) =>
    (x: (lng - g.base.lng) * g.kx, y: (lat - g.base.lat) * 111132.954);

Future<double?> Function(double, double) terrain(
  double Function(double, double) f,
) => (lat, lng) async {
  final p = xy(lat, lng);
  return f(p.x, p.y);
};

double smooth(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Distance (m) from [p] to the polyline [line] (east/north pairs).
double toLine(List<(double, double)> line, double x, double y) {
  var best = double.infinity;
  for (var i = 0; i + 1 < line.length; i++) {
    final (ax, ay) = line[i];
    final (bx, by) = line[i + 1];
    final dx = bx - ax, dy = by - ay;
    final t = ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy);
    final c = t.clamp(0.0, 1.0);
    best = min(best, sqrt(pow(x - ax - c * dx, 2) + pow(y - ay - c * dy, 2)));
  }
  return best;
}

GraphLine lineOf(String name, List<(double, double)> pts) =>
    GraphLine(name, [for (final (e, n) in pts) at(e, n)]);

Future<GentlePlan> plan(
  double Function(double, double) f, {
  SlopeLimit limit = SlopeLimit.gentle,
  List<GraphLine> trails = const [],
  double to = 3000,
}) async {
  final r = await planGentle(
    g.base,
    at(to, 0),
    terrain(f),
    limit: limit,
    trails: trails,
    useIsolate: false,
  );
  expect(r.plan, isNotNull, reason: r.reason);
  return r.plan!;
}

List<({double x, double y})> pointsOf(GentlePlan p) => [
  for (final q in p.route.points) xy(q.lat, q.lng),
];

// A 30% hillside right across the corridor, with a switchback trail up it.
double ramp(double x, double y) =>
    100 + 150 * ((x - 1000) / 500).clamp(0.0, 1.0);
final switchback = <(double, double)>[
  (1000, -300),
  (1100, 300),
  (1200, -300),
  (1300, 300),
  (1400, -300),
  (1500, 300),
];

void main() {
  test('Tobler time factor: flat 1, best going down a little, dear uphill', () {
    expect(toblerFactor(0), closeTo(1, 1e-9));
    expect(toblerFactor(-0.05), closeTo(0.84, 0.005));
    expect(gentleToblerBest, closeTo(toblerFactor(-0.05), 1e-3));
    expect(toblerFactor(0.10), closeTo(1.42, 0.02));
    expect(toblerFactor(0.20), closeTo(2.01, 0.03));
    expect(toblerFactor(0.20), greaterThan(toblerFactor(-0.20)));
    // The search heuristic never beats the cheapest possible step.
    for (var s = -0.6; s <= 0.6; s += 0.01) {
      expect(
        toblerFactor(s) * gentleTrailFactor,
        greaterThanOrEqualTo(gentleToblerBest * gentleTrailFactor - 1e-9),
      );
    }
    expect(gentleCutoffFor(10), 20);
    expect(gentleCutoffFor(20), 40);
    expect(gentleCutoffFor(null), 45);
  });

  group('trails', () {
    test('a switchback trail up a steep hillside is followed', () async {
      final trail = lineOf('Switchbacks', switchback);
      final p = await plan(ramp, trails: [trail]);
      final o = p.output;
      expect(o.relaxedCutoff, isFalse);
      // The hill is 30%; the trail is about 5%, so is the walk, give or
      // take the tight turns (a cell is 30 m, the switchbacks 100 m apart).
      expect(o.maxSlopePct, lessThan(21), reason: p.summary());
      expect(o.onTrailFraction, greaterThan(0.45));
      expect(p.summary(), contains('follows a trail'));
      // Up the hill it is on the trail, not straight up.
      for (final q in pointsOf(p)) {
        if (q.x > 1050 && q.x < 1450) {
          expect(toLine(switchback, q.x, q.y), lessThan(45));
        }
      }
      expect(p.route.lengthM, greaterThan(4500));
      // Same hill, no trail: it works its own way up, over the limit
      // (the hill is 30%, and Gentle is 10%), and says so.
      final bare = await plan(ramp);
      expect(bare.output.onTrailFraction, lessThan(0.05));
      expect(bare.output.exceedsLimit, isTrue);
      expect(bare.output.maxSlopePct, lessThan(21));
    });

    test('the line stays on the trail, not beside it', () async {
      final path = <(double, double)>[
        (60, 0),
        (1000, 250),
        (2000, -250),
        (2940, 0),
      ];
      final p = await plan(
        (x, y) => 100.0,
        limit: SlopeLimit.any,
        trails: [lineOf('Dog-leg', path)],
      );
      expect(p.output.onTrailFraction, greaterThan(0.75));
      var near = 0;
      final pts = pointsOf(p);
      for (final q in pts) {
        if (toLine(path, q.x, q.y) <= 30) near++;
      }
      expect(near / pts.length, greaterThan(0.9));
    });

    test('a trail is preferred whichever way it bends', () async {
      // A contour trail running across the way (about 90 degrees to the
      // line) with a small dog-leg: the old 60 degree gate would not use it.
      final path = <(double, double)>[
        (400, -500),
        (400, 0),
        (1400, 0),
        (1400, 500),
        (2400, 500),
        (2400, 0),
        (2950, 0),
      ];
      final p = await plan(
        (x, y) => 100.0,
        limit: SlopeLimit.any,
        trails: [lineOf('Contour', path)],
      );
      // 400 m of it is the way we are going and the rest bends: the route
      // takes the bends too where they pay (here: all of the east-going part).
      expect(p.output.onTrailFraction, greaterThan(0.3));
    });

    test(
      'only trail-to-trail steps are cheaper: crossing a trail is not',
      () async {
        final across = <(double, double)>[(1500, -700), (1500, 700)];
        final p = await plan(
          (x, y) => 100.0,
          limit: SlopeLimit.any,
          trails: [lineOf('Across', across)],
        );
        expect(p.output.onTrailFraction, lessThan(0.1));
        expect(p.route.lengthM, lessThan(3050), reason: 'no detour');
      },
    );
  });

  group('steepness', () {
    // A ridge across the corridor, 60% on both faces, with a low pass.
    double ridge(double x, double y) {
      final pass = 1 - smooth(150, 300, (y - 500).abs());
      final h = 20 + (120 - 20) * (1 - pass);
      final up = smooth(1300, 1500, x), down = 1 - smooth(1700, 1900, x);
      return 100 + h * up * down;
    }

    test(
      'the hard cutoff keeps the line off the wall, using the pass',
      () async {
        for (final limit in SlopeLimit.values) {
          final p = await plan(ridge, limit: limit);
          expect(p.output.relaxedCutoff, isFalse, reason: limit.label);
          final cut = gentleCutoffFor(limit.percent);
          expect(p.output.maxSlopePct, lessThan(cut), reason: limit.label);
          // It crosses the ridge in the pass (north), not straight over it.
          final cross = pointsOf(p).where((q) => q.x > 1350 && q.x < 1850);
          expect(cross, isNotEmpty);
          for (final q in cross) {
            expect(q.y, greaterThan(150), reason: limit.label);
          }
        }
      },
    );

    test('no way round: the cutoff is relaxed, and it says so', () async {
      // A 35% wall right across the corridor (no pass).
      double wall(double x, double y) => 100 + 100 * smooth(2400, 2686, x);
      final gentle = await plan(wall);
      expect(gentle.output.relaxedCutoff, isTrue);
      expect(gentle.output.exceedsLimit, isTrue);
      expect(gentle.summary(), contains('has to cross ground steeper than'));
      expect(gentle.summary(), contains('Gentle'));
      expect(gentle.output.maxSlopePct, closeTo(35, 7));
      // "Any" can do 35% without relaxing anything: nothing to warn about.
      final any = await plan(wall, limit: SlopeLimit.any);
      expect(any.output.relaxedCutoff, isFalse);
      expect(any.summary(), isNot(contains('Warning')));
      // A cliff-like wall (about 100%) is beyond every cutoff.
      double cliff(double x, double y) => 100 + 100 * smooth(2400, 2500, x);
      final c = await plan(cliff, limit: SlopeLimit.any);
      expect(c.output.relaxedCutoff, isTrue);
      expect(c.summary(), contains('no way round very steep ground'));
      expect(c.route.points.last.lat, at(3000, 0).lat);
    });

    test('the steepest figure is honest (about one cell of walking)', () async {
      // A steady 25% slope across the whole way.
      final p = await plan(
        (x, y) => 100 + 0.25 * x,
        limit: SlopeLimit.any,
        to: 2000,
      );
      expect(p.output.maxSlopePct, closeTo(25, 3));
      // Flat ground says flat.
      final flat = await plan((x, y) => 100.0, limit: SlopeLimit.any);
      expect(flat.output.maxSlopePct, lessThan(1));
      // A short steep step shows at its true slope, not averaged flat: a
      // 40 m long 30% rise in otherwise flat ground, crossed by the line.
      double step(double x, double y) => 100 + 12 * smooth(1480, 1520, x);
      final s = await plan(step, limit: SlopeLimit.any);
      expect(s.output.maxSlopePct, greaterThan(15));
    });
  });

  group('time', () {
    test('planning time stays small on big grids', () async {
      final rows = <String>[];
      for (final km in [3.0, 10.0, 24.0]) {
        final sw = Stopwatch()..start();
        final r = await planGentle(
          g.base,
          at(km * 1000, 0),
          terrain(
            (x, y) =>
                100 +
                60 * sin(x / 700) * cos(y / 500) +
                30 * sin(x / 230 + y / 310),
          ),
          limit: SlopeLimit.gentle,
          useIsolate: false,
          trails: [
            lineOf('T', [
              for (var i = 0; i <= 20; i++) (i * km * 50, 200 * sin(i / 2.0)),
            ]),
          ],
        );
        sw.stop();
        expect(r.plan, isNotNull, reason: r.reason);
        rows.add('${km.round()} km: ${sw.elapsedMilliseconds} ms');
        expect(sw.elapsedMilliseconds, lessThan(8000));
      }
      // ignore: avoid_print
      print('gentle planning: ${rows.join(', ')}');
    });
  });

  group('hidden trail layer', () {
    late Directory tmp;
    late TripController t;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('v241g');
      // Flat ground (100 m) saved for the tiles around the start.
      final png = terrariumTile((x, y) => 100.0, n: 16);
      final tx = tileX(drive.lng0, 12), ty = tileY(drive.lat0, 12);
      for (var dx = -2; dx <= 2; dx++) {
        for (var dy = -2; dy <= 2; dy++) {
          final f = File(
            '${tmp.path}/tiles/terrarium/12/${tx + dx}/${ty + dy}.png',
          );
          f.parent.createSync(recursive: true);
          f.writeAsBytesSync(png);
        }
      }
      t = TripController(
        host: FakeHost(1),
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
        fetch: (r) async => throw NoSignalException(),
        searchLimiter: RateLimiter(Duration.zero),
      );
      t.tiles.online = false;
      await t.start();
      t.onFix(Fix(drive.at(0, 0), DateTime.now()));
    });
    tearDown(() {
      t.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    });

    Future<void> addDogLeg({required bool visible}) async {
      final path = <(double, double)>[
        (60, 0),
        (1000, 250),
        (2000, -250),
        (2940, 0),
      ];
      final layer = await t.layers.addTrail(
        ImportedData(
          name: 'Saved trail',
          lines: [
            ImportedLine('Dog-leg', [
              for (final (e, n) in path) drive.at(e, n),
            ]),
          ],
        ),
      );
      if (!visible) await t.layers.setVisible(layer, false);
    }

    test(
      'hidden layers still count for gentle routes, not for the graph',
      () async {
        await addDogLeg(visible: false);
        expect(graphLinesOf(t.layers), isEmpty);
        expect(graphLinesOf(t.layers, includeHidden: true), hasLength(1));
        final r = await t.gentleTo(
          drive.at(3000, 0),
          name: 'Peak',
          limit: SlopeLimit.any,
        );
        expect(r.session, isNotNull, reason: r.message);
        expect(r.session!.compass, isFalse);
        expect(r.message, contains('follows a trail'));
      },
    );

    test('shown layer gives the same; no layer at all, no trail', () async {
      final none = await t.gentleTo(
        drive.at(3000, 0),
        name: 'Peak',
        limit: SlopeLimit.any,
      );
      expect(none.message, isNot(contains('follows a trail')));
      await addDogLeg(visible: true);
      final shown = await t.gentleTo(
        drive.at(3000, 0),
        name: 'Peak',
        limit: SlopeLimit.any,
      );
      expect(shown.message, contains('follows a trail'));
    });
  });
}
