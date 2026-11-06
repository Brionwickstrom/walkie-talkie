// v2.6.11: faster map start. The map opens where it was last left instead
// of the whole country while GPS warms up; the home area is kept ready on
// the phone only on Wi-Fi or while charging, only from map services that
// allow saving ahead, politely, once a week.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/map_start.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';

import 'trip_integration_test.dart' show FakeHost;

const home = GeoPoint(45.5868, -122.2901); // example data

class Server {
  late HttpServer _s;
  int hits = 0;
  bool fail = false;
  Future<void> start() async {
    _s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _s.listen((r) async {
      hits++;
      if (fail) {
        r.response.statusCode = 500;
      } else {
        r.response.add(Uint8List.fromList(List.filled(300, 3)));
      }
      await r.response.close();
    });
  }

  String get url => 'http://127.0.0.1:${_s.port}/{z}/{x}/{y}.png';
  Future<void> close() => _s.close(force: true);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('v2611s'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('where the map opens', () {
    final saved = SavedCamera(home, 13.5, DateTime(2026, 11, 6));
    const fix = GeoPoint(45.6, -122.3);
    const friend = GeoPoint(45.7, -122.4);

    test('no GPS yet: where it was last left, not the whole country', () {
      final v = mapStartView(saved: saved, friend: friend);
      expect(v.from, MapStartFrom.lastView);
      expect(v.center, home);
      expect(v.zoom, 13.5);
    });

    test('a GPS fix already: there, street level', () {
      final v = mapStartView(fix: fix, saved: saved);
      expect(v.from, MapStartFrom.gps);
      expect(v.center, fix);
      expect(v.zoom, 15);
    });

    test('asked to show a point (an SOS): that point first', () {
      final v = mapStartView(focus: friend, fix: fix, saved: saved);
      expect(v.from, MapStartFrom.focus);
      expect(v.center, friend);
    });

    test('first ever start: a friend, a pin, else the country', () {
      expect(mapStartView(friend: friend).from, MapStartFrom.friend);
      expect(mapStartView(pin: friend).from, MapStartFrom.pin);
      final c = mapStartView();
      expect(c.from, MapStartFrom.country);
      expect(c.zoom, 4);
    });
  });

  group('camera memory', () {
    test(
      'written a moment after moving, read back on the next start',
      () async {
        final f = File('${tmp.path}/cam.json');
        final m = CameraMemory(f, debounce: const Duration(milliseconds: 50));
        m.remember(home, 14);
        m.remember(const GeoPoint(45.59, -122.29), 14.5);
        expect(await f.exists(), isFalse, reason: 'not on every move');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final back = CameraMemory(f);
        await back.load();
        expect(back.camera!.center.lat, closeTo(45.59, 1e-9));
        expect(back.camera!.zoom, 14.5);
      },
    );

    test('a broken or silly file is ignored', () async {
      final f = File('${tmp.path}/cam.json');
      await f.writeAsString('{"la": 999, "lo": 0, "z": 3, "at": 0}');
      final m = CameraMemory(f);
      await m.load();
      expect(m.camera, isNull);
      await f.writeAsString('not json');
      await m.load();
      expect(m.camera, isNull);
    });

    test('the Trip controller keeps it across restarts', () async {
      final dir = Directory('${tmp.path}/trip');
      TripController make() =>
          TripController(
              host: FakeHost(1),
              settings: TripSettings(),
              dir: dir,
              userAgent: 't',
            )
            ..trimDelay = const Duration(hours: 1)
            ..warmDelay = const Duration(hours: 1);
      final a = make();
      a.tiles.online = false;
      await a.start();
      expect(a.camera.camera, isNull);
      a.rememberCamera(home, 12);
      a.dispose(); // writes it
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final b = make();
      b.tiles.online = false;
      await b.start();
      expect(b.camera.camera!.center.lat, closeTo(home.lat, 1e-9));
      expect(b.camera.camera!.zoom, 12);
      expect(b.warmHomePoint!.lat, closeTo(home.lat, 1e-9));
      b.dispose();
    });
  });

  group('keep home area ready', () {
    String? why({
      bool enabled = true,
      bool wifi = false,
      bool charging = false,
      bool saver = false,
      bool online = true,
      GeoPoint? at = home,
      MapSource source = MapSource.usgsTopo,
    }) => HomeWarmer.blocker(
      enabled: enabled,
      wifi: wifi,
      charging: charging,
      offlineSaver: saver,
      online: online,
      home: at,
      source: source,
    );

    test('only on Wi-Fi or while charging', () {
      expect(why(), 'Waiting for Wi-Fi or a charger.');
      expect(why(wifi: true), isNull);
      expect(why(charging: true), isNull);
    });

    test('never with it off, Offline power save, no internet, no home', () {
      expect(why(wifi: true, enabled: false), contains('off'));
      expect(why(wifi: true, saver: true), contains('Offline power save'));
      expect(why(wifi: true, online: false), 'No internet.');
      expect(why(wifi: true, at: null), 'No home location yet.');
    });

    test('never from OpenStreetMap (its rules forbid saving ahead)', () {
      expect(
        why(wifi: true, source: MapSource.osm),
        contains('does not allow saving maps ahead'),
      );
    });

    test('small: about 1.5 km around home, zoom 12 to 15, at most 120', () {
      final list = HomeWarmer.tilesAround(home);
      expect(list.length, lessThanOrEqualTo(HomeWarmer.maxTiles));
      expect(list.length, greaterThan(10));
      expect(list.map((t) => t.z).toSet(), {12, 13, 14, 15});
      // About 100 tiles of a typical 20 KB = about 2 MB.
      expect(list.length * MapSource.usgsTopo.avgTileBytes, lessThan(3e6));
    });

    test('fetches only what is missing, then not again for a week', () async {
      final srv = Server();
      await srv.start();
      final src = MapSource.custom(srv.url);
      final tiles = TileCache(Directory('${tmp.path}/tiles'), userAgent: 't');
      var now = DateTime(2026, 11, 6, 9);
      final w = HomeWarmer(
        tiles: tiles,
        stamp: File('${tmp.path}/warm.json'),
        clock: () => now,
        pause: Duration.zero,
      );
      final n = HomeWarmer.tilesAround(home).length;
      expect(await w.due(home, src), isTrue);
      expect(await w.run(src, home), n);
      expect(srv.hits, n);
      expect(await w.due(home, src), isFalse);
      // Second run: everything is there, nothing asked.
      expect(await w.run(src, home), 0);
      expect(srv.hits, n);
      now = now.add(const Duration(days: 8));
      expect(await w.due(home, src), isTrue);
      now = DateTime(2026, 11, 6, 10);
      expect(await w.due(const GeoPoint(45.7, -122.29), src), isTrue);
      tiles.close();
      await srv.close();
    });

    test('stops when Wi-Fi / the charger goes, and on no signal', () async {
      final srv = Server()..fail = true;
      await srv.start();
      final src = MapSource.custom(srv.url);
      final tiles = TileCache(Directory('${tmp.path}/tiles'), userAgent: 't');
      final w = HomeWarmer(
        tiles: tiles,
        stamp: File('${tmp.path}/warm.json'),
        pause: Duration.zero,
      );
      expect(await w.run(src, home), 0);
      expect(srv.hits, 6, reason: 'gives up after 6 failures in a row');
      expect(await w.due(home, src), isTrue, reason: 'tries another day');
      srv.fail = false;
      var left = 3;
      expect(await w.run(src, home, stillOk: () async => left-- > 0), 3);
      tiles.close();
      await srv.close();
    });

    test('the controller: on battery, off Wi-Fi = nothing at all', () async {
      final srv = Server();
      await srv.start();
      final dir = Directory('${tmp.path}/trip');
      final t =
          TripController(
              host: FakeHost(1),
              settings: TripSettings(
                mapSource: 'custom',
                customTileUrl: srv.url,
              ),
              dir: dir,
              userAgent: 't',
            )
            ..trimDelay = const Duration(hours: 1)
            ..warmDelay = const Duration(hours: 1)
            ..onWifi = () async => false;
      await t.start();
      t.homeFencePos = home;
      expect(await t.maybeWarmHome(), 0);
      expect(t.warmStatus, 'Waiting for Wi-Fi or a charger.');
      expect(srv.hits, 0);
      // Plugged in: it runs (politely, one a second; cut short here).
      t.warmer.cancel();
      await t.setPluggedIn(true);
      final f = t.maybeWarmHome();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      t.warmer.cancel();
      expect(await f, greaterThan(0));
      expect(t.warmStatus, isNull);
      // Switched off in Settings: nothing.
      await t.update((s) => s.warmHome = false);
      expect(await t.maybeWarmHome(), 0);
      expect(t.warmStatus, contains('off'));
      t.dispose();
      await srv.close();
    });
  });
}
