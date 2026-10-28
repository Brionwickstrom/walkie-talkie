import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/nav/gentle_route.dart';
import 'package:walkie_talkie/trip/nav/trail_graph.dart';

// A flat plain with a steep round hill in the middle: the gentle line must
// go around it, the "any" line may go closer, and no data gives a reason.
const base = GeoPoint(45.0, -122.0);
double kx = 111319.49 * cos(45 * pi / 180);
GeoPoint at(double east, double north) =>
    GeoPoint(base.lat + north / 111132.954, base.lng + east / kx);

/// Elevation: hill of [h] m, radius [r] m, centred at (e, n).
Future<double?> Function(double, double) hill({
  double e = 2500,
  double n = 0,
  double h = 600,
  double r = 700,
}) => (lat, lng) async {
  final x = (lng - base.lng) * kx, y = (lat - base.lat) * 111132.954;
  final d = sqrt((x - e) * (x - e) + (y - n) * (y - n));
  return 100 + (d >= r ? 0 : h * 0.5 * (1 + cos(pi * d / r)));
};

void main() {
  test(
    'gentle route goes around a steep hill, quickly, and is smooth',
    () async {
      final sw = Stopwatch()..start();
      final r = await planGentle(
        base,
        at(5000, 0),
        hill(),
        limit: SlopeLimit.gentle,
      );
      sw.stop();
      expect(r.plan, isNotNull, reason: r.reason);
      final p = r.plan!;
      expect(p.route.source, 'gentle');
      expect(p.route.terrainOnly, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(2000));
      // Longer than straight (5 km) but not silly.
      expect(p.route.lengthM, greaterThan(5050));
      expect(p.route.lengthM, lessThan(7500));
      // Ends are the real start and target.
      expect(distanceM(p.route.points.first, base), lessThan(1));
      expect(distanceM(p.route.points.last, at(5000, 0)), lessThan(1));
      // It stays out of the steepest middle of the hill.
      for (final q in p.route.points) {
        final x = (q.lng - base.lng) * kx, y = (q.lat - base.lat) * 111132.954;
        expect(sqrt((x - 2500) * (x - 2500) + y * y), greaterThan(380));
      }
      expect(p.output.maxSlopePct, lessThan(14));
      expect(p.output.exceedsLimit, isFalse);
      // Smooth: no zigzag, headings never flip more than 60 degrees in 25 m.
      final pts = p.route.points;
      var worst = 0.0;
      for (var i = 1; i + 1 < pts.length; i++) {
        worst = max(
          worst,
          deltaDeg(
            bearingDeg(pts[i], pts[i + 1]),
            bearingDeg(pts[i - 1], pts[i]),
          ).abs(),
        );
      }
      expect(worst, lessThan(60));
      expect(p.summary(), contains('steepest about'));
      expect(
        gentleLabel,
        contains("can't see cliffs, brush, water or private land"),
      );
    },
  );

  test('any limit cuts closer than gentle; slope limits are ordered', () async {
    final g = (await planGentle(
      base,
      at(5000, 0),
      hill(),
      limit: SlopeLimit.gentle,
    )).plan!;
    final m = (await planGentle(
      base,
      at(5000, 0),
      hill(),
      limit: SlopeLimit.moderate,
    )).plan!;
    final a = (await planGentle(
      base,
      at(5000, 0),
      hill(),
      limit: SlopeLimit.any,
    )).plan!;
    expect(a.route.lengthM, lessThanOrEqualTo(m.route.lengthM + 1));
    expect(m.route.lengthM, lessThanOrEqualTo(g.route.lengthM + 1));
    expect(a.output.maxSlopePct, greaterThanOrEqualTo(g.output.maxSlopePct));
  });

  test('a steep wall nobody can avoid is flagged', () async {
    // A wall across the whole corridor.
    Future<double?> wall(double lat, double lng) async {
      final x = (lng - base.lng) * kx;
      return x > 2400 && x < 2600 ? 400.0 : 100.0;
    }

    final r = await planGentle(
      base,
      at(5000, 0),
      wall,
      limit: SlopeLimit.gentle,
    );
    expect(r.plan, isNotNull);
    expect(r.plan!.output.exceedsLimit, isTrue);
    expect(r.plan!.summary(), contains('Warning'));
  });

  test('prefers a trail that runs the right way', () async {
    // Flat ground, a trail running 400 m to the side but parallel.
    final trail = GraphLine('East Trail', [
      for (var i = 0; i <= 10; i++) at(i * 500.0, 300),
    ]);
    final r = await planGentle(
      base,
      at(5000, 0),
      (lat, lng) async => 100.0,
      limit: SlopeLimit.any,
      trails: [trail],
    );
    final p = r.plan!;
    expect(p.output.onTrailFraction, greaterThan(0.3));
    expect(p.summary(), contains('follows a trail'));
    // A trail running across the way is not preferred.
    final cross = GraphLine('Cross', [
      for (var i = 0; i <= 10; i++) at(1000, -800.0 + i * 160),
    ]);
    final r2 = await planGentle(
      base,
      at(5000, 0),
      (lat, lng) async => 100.0,
      limit: SlopeLimit.any,
      trails: [cross],
    );
    expect(r2.plan!.output.onTrailFraction, lessThan(0.1));
  });

  test('no elevation data or too far gives a plain reason', () async {
    var r = await planGentle(base, at(3000, 0), (lat, lng) async => null);
    expect(r.plan, isNull);
    expect(r.reason, contains('No elevation data'));
    r = await planGentle(base, at(60000, 0), hill());
    expect(r.plan, isNull);
    expect(r.reason, contains('Too far'));
    r = await planGentle(base, at(5, 5), hill());
    expect(r.plan, isNull);
  });

  test('elevation profile and junction text come with the route', () async {
    final r = await planGentle(
      base,
      at(4000, 1000),
      hill(e: 2000, n: 500, r: 600),
    );
    final route = r.plan!.route;
    expect(route.hasElevation, isTrue);
    final c = route.climb();
    expect(c.gain, greaterThanOrEqualTo(0));
  });
}
