// Live: the online routers answer the way the app asks (LIVE_MAPS=1).
// Overpass may be blocked on some networks; the trailhead lookup then falls
// back to Photon / Nominatim, which is what this checks too.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/drive/online_router.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/nav/foot_router.dart';
import 'package:walkie_talkie/trip/nav/valhalla.dart';
import 'package:walkie_talkie/trip/search/fetch.dart';
import 'package:walkie_talkie/trip/search/rate_limiter.dart';
import 'package:walkie_talkie/trip/search/trailhead_finder.dart';

void main() {
  final live = Platform.environment['LIVE_MAPS'] == '1';
  const ua =
      'WalkieTalkie/2.1.0 (+https://github.com/Brionwickstrom/walkie-talkie)';
  const from = GeoPoint(45.52965, -122.71574); // Forest Park, Portland
  const to = GeoPoint(45.5420, -122.7290);
  final fetch = ioFetch(ua);
  final limiter = RateLimiter(const Duration(milliseconds: 1100));

  test('walking: Valhalla, BRouter and OSRM foot each answer', () async {
    final fr = FootRouter(fetch: fetch, limiter: limiter);
    final v = await fr.route(from, to);
    expect(fr.lastProvider, 'valhalla');
    expect(v.lengthM, greaterThan(1500));
    // BRouter and OSRM foot on their own.
    final b = FootRouter.parseBrouter(
      await fetch(
        FetchRequest(
          FootRouter.brouterUri(FootRouter.defaultBrouter, from, to),
        ),
      ),
      from: from,
      to: to,
    );
    expect(b.hasElevation, isTrue);
    final o = FootRouter.parseOsrmFoot(
      await limiter.run(
        () => fetch(
          FetchRequest(
            FootRouter.osrmFootUri(FootRouter.defaultOsrmFoot, from, to),
          ),
        ),
      ),
      from: from,
      to: to,
    );
    expect(o.lengthM, greaterThan(1500));
    // The walks are foot routes, not a car route (the demo OSRM server
    // would have answered a car route).
    expect((o.lengthM - v.lengthM).abs() / v.lengthM, lessThan(0.6));
  }, skip: !live);

  test('driving: OSRM car (FOSSGIS) and Valhalla auto', () async {
    final car = await OnlineRouter(
      fetch: fetch,
      limiter: limiter,
    ).route(from, to);
    expect(car.lengthM, greaterThan(1500));
    final body = await limiter.run(
      () => fetch(
        FetchRequest(
          Uri.parse(Valhalla.endpoint),
          method: 'POST',
          headers: const {'Content-Type': 'application/json'},
          body: Valhalla.autoBody(from, to),
        ),
      ),
    );
    final v = Valhalla.parseDrive(body, from: from, to: to);
    expect(v.steps, isNotEmpty);
  }, skip: !live);

  test('trailheads: Overpass, else Photon / Nominatim, never a crash', () async {
    final f = TrailheadFinder(fetch: fetch, limiter: limiter);
    final s = await f.find(const GeoPoint(45.5300, -122.7200), radiusM: 8000);
    // ignore: avoid_print
    print(
      'trailheads: ${s.found.length} found, overpassFailed '
      '${s.overpassFailed}, noSignal ${s.noSignal}, note "${s.note}"'
      '${s.found.isEmpty ? '' : ', first ${s.found.first.name} (${s.found.first.source})'}',
    );
    expect(s.noSignal, isFalse);
  }, skip: !live);
}
