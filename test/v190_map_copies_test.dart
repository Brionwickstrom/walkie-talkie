import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:walkie_talkie/trip/imports/geo_import.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/imports/map_packs.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_layers_page.dart';
import 'package:walkie_talkie/ui/map_packs_page.dart';

import 'support/host_sqlite.dart';
import 'trip_integration_test.dart' show FakeHost;
import 'v183_map_imports_test.dart' show allTrailsGpx, gaiaGpx, pngHeader;
import 'v190_map_packs_test.dart' show box, file, sha;

// The Mount Si test trail's extent (tracks + waypoints).
const siBox = {'s': 47.488, 'w': -121.731, 'n': 47.507, 'e': -121.723};
const ssBox = {'s': 45.695, 'w': -122.335, 'n': 45.805, 'e': -122.115};

String makeMbtiles(String path, {String name = 'Silver Star Mountain'}) {
  final db = sqlite3.open(path);
  db.execute(
    'CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, '
    'tile_row INTEGER, tile_data BLOB)',
  );
  db.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
  for (final kv in {
    'name': name,
    'format': 'png',
    'minzoom': '12',
    'maxzoom': '12',
    'bounds': '-122.335,45.695,-122.115,45.805',
  }.entries) {
    db.execute('INSERT INTO metadata VALUES (?, ?)', [kv.key, kv.value]);
  }
  db.execute('INSERT INTO tiles VALUES (12, 656, 2650, ?)', [
    Uint8List.fromList([1, 2, 3]),
  ]);
  db.dispose();
  return path;
}

void main() {
  final haveSqlite = useHostSqlite();
  late Directory tmp;
  late MapLayers layers;
  late Uint8List gpx, png;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('copies');
    layers = MapLayers(Directory('${tmp.path}/l'));
    gpx = Uint8List.fromList(utf8.encode(allTrailsGpx));
    png = pngHeader(400, 300);
  });
  tearDown(() {
    layers.close();
    tmp.deleteSync(recursive: true);
  });

  Future<MapPack> pack({List<Map<String, Object?>> extra = const []}) async =>
      MapPack.fromJson({
        'id': 'p',
        'name': 'Test pack',
        'bounds': box,
        'files': [
          file(
            'Si_Trails.gpx',
            'trail',
            gpx.length,
            sha256: await sha(gpx),
            title: 'Si trails',
            bounds: siBox,
          ),
          file(
            'topo.png',
            'overlay',
            png.length,
            sha256: await sha(png),
            bounds: box,
          ),
          ...extra,
        ],
      })!;

  PackInstaller installer({List<String>? downloads}) => PackInstaller(
    layers: layers,
    tempDir: Directory('${tmp.path}/t'),
    download: (u, to, on) async {
      downloads?.add(u.pathSegments.last);
      await to.writeAsBytes(
        {'Si_Trails.gpx': gpx, 'topo.png': png}[u.pathSegments.last]!,
      );
    },
  );

  group('pack files already imported by hand', () {
    test('same GPX and picture: no copy, marked Already added', () async {
      final mine = await layers.importTrail('my download.gpx', gpx);
      final pic = await layers.importOverlay('my topo', png);
      await layers.setVisible(mine, false);
      final p = await pack();
      final downloads = <String>[];
      final inst = installer(downloads: downloads);
      final out = await inst.add(p);
      expect(downloads, isEmpty, reason: 'nothing downloaded');
      expect(layers.all, hasLength(2), reason: 'no duplicate layers');
      expect(out.map((l) => l.id).toSet(), {mine.id, pic.id});
      expect(inst.found, hasLength(2));
      expect(mine.packMatched && pic.packMatched, isTrue);
      expect((mine.pack, mine.packFile), ('p', 'Si_Trails.gpx'));
      expect(mine.name, 'Mount Si Trail', reason: 'user name kept');
      expect(packAdded(p, layers), isTrue);
      expect(
        addedMessage(out, null),
        'Already added: 2 were already on '
        'this phone (not copied again).',
      );
      // Persisted.
      final again = MapLayers(Directory('${tmp.path}/l'));
      await again.load();
      expect(again.all.every((l) => l.packMatched), isTrue);
      expect(again.byId(pic.id)!.sha, await sha(png));
      again.close();
    });

    test(
      'same trails in another file (other name and size): by extent',
      () async {
        final other = allTrailsGpx
            .replaceAll('Mount Si Trail', 'Si from KML')
            .replaceAll('<ele>', '<!-- x --><ele>');
        final mine = await layers.importTrail('si.kml.gpx', utf8.encode(other));
        expect(mine.sourceBytes, isNot(gpx.length));
        final p = await pack();
        final downloads = <String>[];
        final out = await installer(downloads: downloads).add(p);
        expect(downloads, ['topo.png']);
        expect(out.first.id, mine.id);
        expect(mine.packMatched, isTrue);
        expect(layers.trails, hasLength(1));
        expect(layers.overlays.single.packMatched, isFalse);
      },
    );

    test(
      'a different trail or picture is not taken for the pack one',
      () async {
        await layers.importTrail('gaia.gpx', utf8.encode(gaiaGpx));
        await layers.importOverlay('other', pngHeader(401, 300));
        final downloads = <String>[];
        final out = await installer(downloads: downloads).add(await pack());
        expect(downloads, ['Si_Trails.gpx', 'topo.png']);
        expect(out.every((l) => !l.packMatched), isTrue);
        expect(layers.all, hasLength(4));
      },
    );

    test('a trail with the same name somewhere else is not matched', () async {
      // Same name as the pack title, but far away.
      final far = gaiaGpx.replaceAll('Enchantments', 'Si trails');
      await layers.importTrail('x.gpx', utf8.encode(far));
      final c = await findCopy(
        await pack(),
        (await pack()).files.first,
        layers,
      );
      expect(c, isNull);
    });

    test('a pack layer is never taken for another pack file', () async {
      final p = await pack();
      await installer().add(p);
      final again = await pack(
        extra: [file('copy.gpx', 'trail', gpx.length, bounds: siBox)],
      );
      expect(await findCopy(again, again.files.last, layers), isNull);
    });

    test('names compare loosely', () {
      expect(normName('Silver_Star_Trails.gpx'), 'silverstartrails');
      expect(normName('Silver Star trails'), 'silverstartrails');
      expect(normName('v1.2 map'), 'v12map');
    });

    test('MBTiles imported by hand: same file, or same size + area', () async {
      final src = makeMbtiles('${tmp.path}/ss.mbtiles');
      final bytes = File(src).readAsBytesSync();
      final mine = await layers.importMbtiles(File(src));
      final tiles = file(
        'Silver_Star_USGS_Topo.mbtiles',
        'tiles',
        bytes.length,
        sha256: await sha(bytes),
        title: 'Silver Star USGS topo',
      );
      final p = MapPack.fromJson({
        'id': 'ss',
        'name': 'Silver Star',
        'bounds': ssBox,
        'files': [tiles],
      })!;
      final downloads = <String>[];
      final out = await installer(downloads: downloads).add(p);
      expect(downloads, isEmpty);
      expect(out.single.id, mine.id);
      expect(layers.tileSets, hasLength(1));
      // Changed bytes (e.g. SQLite touched it) but same size and area.
      final p2 = MapPack.fromJson({
        'id': 'ss2',
        'name': 'Silver Star',
        'bounds': ssBox,
        'files': [
          {...tiles, 'sha256': 'f' * 64},
        ],
      })!;
      await layers.tagPack(mine, null, null);
      expect((await findCopy(p2, p2.files.single, layers))?.id, mine.id);
      // Same name, same area, other size.
      final p3 = MapPack.fromJson({
        'id': 'ss3',
        'name': 'Silver Star',
        'bounds': ssBox,
        'files': [
          {
            ...tiles,
            'sha256': 'f' * 64,
            'size': 5,
            'title': 'Silver Star Mountain',
          },
        ],
      })!;
      expect((await findCopy(p3, p3.files.single, layers))?.id, mine.id);
      // Other area: no.
      final p4 = MapPack.fromJson({
        'id': 'ss4',
        'name': 'Elsewhere',
        'bounds': box,
        'files': [
          {...tiles, 'sha256': 'f' * 64, 'size': 5},
        ],
      })!;
      expect(await findCopy(p4, p4.files.single, layers), isNull);
    }, skip: haveSqlite ? false : 'no SQLite library on this machine');
  });

  group('duplicate cleanup', () {
    test('finds identical copies, keeps one of each', () async {
      final a = await layers.importTrail('si.gpx', gpx);
      final b = await layers.importTrail('si (1).gpx', gpx);
      final c = await layers.importTrail('si (2).gpx', gpx);
      await layers.importTrail('gaia.gpx', utf8.encode(gaiaGpx));
      final o1 = await layers.importOverlay('map', png);
      final o2 = await layers.importOverlay('map copy', png);
      await layers.importOverlay('other', pngHeader(500, 300));
      await layers.tagPack(c, 'p', 'Si_Trails.gpx');
      await layers.setVisible(o1, false);
      final d = await findDuplicates(layers);
      expect(d, hasLength(2));
      final r = await removeDuplicates(layers);
      expect(r.removed, 3);
      expect(r.freedBytes, a.bytes + b.bytes + o1.bytes);
      expect(
        layers.trails.map((l) => l.id).toSet(),
        contains(c.id),
        reason: 'the pack copy is kept',
      );
      expect(layers.trails, hasLength(2));
      expect(
        layers.overlays.map((l) => l.id),
        contains(o2.id),
        reason: 'the visible copy is kept',
      );
      expect(layers.overlays, hasLength(2));
      expect(r.kept[a.id]!.id, c.id);
      expect(await findDuplicates(layers), isEmpty);
      expect((await removeDuplicates(layers)).removed, 0);
    });

    test('pack tag moves to the copy that is kept', () async {
      final a = await layers.importOverlay('map', png);
      final b = await layers.importOverlay('map 2', png);
      await layers.tagPack(b, 'p', 'topo.png');
      final r = await removeDuplicates(layers, prefer: a.id);
      expect(r.removed, 1);
      // Pack copy wins over "prefer".
      expect(layers.overlays.single.id, b.id);
    });

    test('shared routes from others are left alone', () async {
      final d = tidyImport(parseTrailFile('si.gpx', gpx));
      await layers.addTrail(d, from: 7);
      await layers.addTrail(d, from: 7);
      expect(await findDuplicates(layers), isEmpty);
    });
  });

  testWidgets('Remove duplicate maps card; base map follows the kept copy', (
    tester,
  ) async {
    if (!haveSqlite) return;
    final dir = Directory.systemTemp.createTempSync('dupui');
    final t = TripController(
      host: FakeHost(1),
      settings: TripSettings(),
      dir: dir,
      userAgent: 'test',
    )..tiles.online = false;
    late MapLayer second;
    await tester.runAsync(() async {
      await t.layers.load();
      await t.layers.importMbtiles(File(makeMbtiles('${dir.path}/a.mbtiles')));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // A byte-identical second import (copy of the same file).
      File('${dir.path}/a.mbtiles').copySync('${dir.path}/b.mbtiles');
      second = await t.layers.importMbtiles(File('${dir.path}/b.mbtiles'));
      await t.update((s) => s.mapSource = 'mbtiles:${second.id}');
      await t.layers.setVisible(t.layers.tileSets.last, false);
      expect(await findDuplicates(t.layers), hasLength(1));
    });
    await tester.pumpWidget(MaterialApp(home: MapLayersPage(trip: t)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byKey(const Key('duplicateMaps')), findsOneWidget);
    expect(find.text('Remove duplicate maps'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('removeDuplicates')));
      for (var i = 0; i < 40 && t.layers.tileSets.length > 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.textContaining('Removed 1 duplicate copy'), findsOneWidget);
    expect(t.layers.tileSets, hasLength(1));
    expect(t.layers.tileSets.single.id, second.id, reason: 'base map kept');
    expect(t.baseTiles?.id, second.id);
    expect(find.byKey(const Key('duplicateMaps')), findsNothing);
    t.dispose();
    dir.deleteSync(recursive: true);
  });

  testWidgets('Ready-made maps shows Already added for a matched file', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ui2');
    final t = TripController(
      host: FakeHost(1),
      settings: TripSettings(),
      dir: dir,
      userAgent: 'test',
    )..tiles.online = false;
    late MapPack p;
    await tester.runAsync(() async {
      await t.layers.load();
      await t.layers.importTrail('mine.gpx', gpx);
      p = await pack();
    });
    var fitted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: MapPacksPage(
          trip: t,
          onFit: (_) => fitted = true,
          catalog: PackCatalog(
            bundled: () async => jsonEncode({
              'packs': [
                {
                  'id': p.id,
                  'name': p.name,
                  'files': [
                    file(
                      'Si_Trails.gpx',
                      'trail',
                      gpx.length,
                      title: 'Si trails',
                      bounds: siBox,
                    ),
                  ],
                },
              ],
            }),
          ),
          installer: PackInstaller(
            layers: t.layers,
            tempDir: Directory('${dir.path}/t'),
            download: (_, _, _) async => fail('no download'),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('addPack:p')));
      for (var i = 0; i < 40 && !fitted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pump();
    expect(fitted, isTrue, reason: 'map moves to the existing layer');
    expect(find.text('Already added'), findsOneWidget);
    expect(t.layers.all, hasLength(1));
    t.dispose();
    dir.deleteSync(recursive: true);
  });
}
