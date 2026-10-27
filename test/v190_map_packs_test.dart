import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:walkie_talkie/trip/imports/georef.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/imports/map_packs.dart';
import 'package:walkie_talkie/trip/tile_cache.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_layers_page.dart';
import 'package:walkie_talkie/ui/map_packs_page.dart';

import 'support/host_sqlite.dart';
import 'trip_integration_test.dart' show FakeHost;
import 'v183_map_imports_test.dart' show allTrailsGpx, pngHeader;

Future<String> sha(List<int> b) async {
  final h = await Sha256().hash(b);
  return h.bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

const url = 'https://github.com/Brionwickstrom/walkie-talkie/releases/download';

Map<String, Object?> file(
  String name,
  String kind,
  int size, {
  String? sha256,
  String? asset,
  String title = '',
  Map<String, Object?>? bounds,
}) => {
  'name': name,
  'kind': kind,
  'title': title,
  'url': '$url/maps-test/$name',
  'asset': ?asset,
  'size': size,
  'sha256': ?sha256,
  'bounds': ?bounds,
  'opacity': 0.85,
};

const box = {'s': 45.875, 'w': -122.08, 'n': 45.955, 'e': -121.955};

void main() {
  group('pack list', () {
    test('bundled map_packs.json: Silver Star + Trapper Creek', () {
      final packs = MapPack.parseList(
        File('map_packs.json').readAsStringSync(),
      );
      expect(packs.map((p) => p.id), [
        'silver-star',
        'trapper-creek',
        'gp-roads', // v1.9.2
      ]);
      final ss = packs.first;
      expect(ss.short, 'Silver Star');
      expect(ss.files.map((f) => f.name), [
        'Silver_Star_Trails.gpx',
        'Silver_Star_USGS_Topo.mbtiles',
      ]);
      expect(ss.files.map((f) => f.kind), [
        PackFileKind.trail,
        PackFileKind.tiles,
      ]);
      final tc = packs[1];
      expect(tc.files.last.kind, PackFileKind.overlay);
      expect(tc.files.last.bounds!.north, 45.955);
      for (final p in packs) {
        for (final f in p.files) {
          expect(f.url, startsWith('https://github.com/Brionwickstrom/'));
          expect(f.sha256, hasLength(64));
          expect(f.size, greaterThan(0));
          final a = f.asset;
          if (a != null) {
            // The bundled trail files are the very same files.
            final bytes = File(a).readAsBytesSync();
            expect(bytes.length, f.size, reason: a);
          }
        }
      }
      // GPX files ship in the APK, so only the big maps download.
      expect(ss.downloadSize, ss.files.last.size);
      final pub = File('pubspec.yaml').readAsStringSync();
      expect(pub, contains('- map_packs.json'));
      expect(pub, contains('- assets/map_packs/'));
    });

    test('bundled trail files match their checksums', () async {
      for (final p in MapPack.parseList(
        File('map_packs.json').readAsStringSync(),
      )) {
        for (final f in p.files.where((f) => f.asset != null)) {
          expect(await sha(File(f.asset!).readAsBytesSync()), f.sha256);
        }
      }
    });

    test('bad entries are skipped', () {
      final json = jsonEncode({
        'version': 1,
        'packs': [
          {
            'id': 'ok',
            'name': 'OK',
            'files': [
              file('a.gpx', 'trail', 10),
              {...file('b.gpx', 'trail', 10), 'url': 'http://x/b.gpx'},
              {...file('../c.gpx', 'trail', 10)},
              {...file('d.gpx', 'trail', 10), 'asset': '/etc/passwd'},
              {...file('e.bin', 'trail', 10), 'kind': 'weird'},
            ],
          },
          {'id': 'empty', 'name': 'No files', 'files': []},
          {
            'name': 'no id',
            'files': [file('a.gpx', 'trail', 1)],
          },
          'junk',
        ],
      });
      final packs = MapPack.parseList(json);
      expect(packs.single.id, 'ok');
      expect(packs.single.short, 'OK');
      expect(packs.single.files.map((f) => f.name), ['a.gpx', 'd.gpx']);
      expect(packs.single.files.last.asset, isNull, reason: 'bad asset path');
      expect(MapPack.parseList('not json'), isEmpty);
      expect(MapPack.parseList('{"packs": 3}'), isEmpty);
    });

    test('newer list wins, keeps bundled copies, keeps extra packs', () {
      final bundled = MapPack.parseList(
        jsonEncode({
          'packs': [
            {
              'id': 'a',
              'name': 'A',
              'files': [
                file(
                  'a.gpx',
                  'trail',
                  5,
                  sha256: 'x' * 64,
                  asset: 'assets/map_packs/a.gpx',
                ),
              ],
            },
            {
              'id': 'b',
              'name': 'B',
              'files': [file('b.gpx', 'trail', 5)],
            },
          ],
        }),
      );
      final remote = MapPack.parseList(
        jsonEncode({
          'packs': [
            {
              'id': 'c',
              'name': 'C (new)',
              'files': [file('c.gpx', 'trail', 5)],
            },
            {
              'id': 'a',
              'name': 'A v2',
              'files': [
                file('a.gpx', 'trail', 5, sha256: 'x' * 64),
                file('a2.gpx', 'trail', 5),
              ],
            },
          ],
        }),
      );
      final m = PackCatalog.merge(bundled, remote);
      expect(m.map((p) => p.id), ['c', 'a', 'b']);
      final a = m[1];
      expect(a.name, 'A v2');
      expect(a.files.first.asset, 'assets/map_packs/a.gpx');
      expect(a.files.last.asset, isNull);
    });

    test('catalog: bundled, then GitHub (cached for offline)', () async {
      final tmp = Directory.systemTemp.createTempSync('cat');
      final cache = File('${tmp.path}/c.json');
      final b = jsonEncode({
        'packs': [
          {
            'id': 'a',
            'name': 'A',
            'files': [file('a.gpx', 'trail', 1)],
          },
        ],
      });
      final r = jsonEncode({
        'packs': [
          {
            'id': 'n',
            'name': 'New',
            'files': [file('n.gpx', 'trail', 1)],
          },
        ],
      });
      var online = true;
      PackCatalog cat() => PackCatalog(
        bundled: () async => b,
        fetch: () async => online ? r : null,
        cacheFile: cache,
      );
      expect((await cat().load(refresh: false)).map((p) => p.id), ['a']);
      expect((await cat().load()).map((p) => p.id), ['n', 'a']);
      online = false;
      expect((await cat().load()).map((p) => p.id), ['n', 'a']);
      final broken = PackCatalog(
        bundled: () async => b,
        fetch: () async => throw const SocketException('down'),
      );
      expect((await broken.load()).map((p) => p.id), ['a']);
      expect(PackCatalog.remoteUrl.toString(), contains('main/map_packs.json'));
      tmp.deleteSync(recursive: true);
    });
  });

  test('georefForBounds puts the picture corners on the box', () {
    final b = GeoBounds.fromJson(box)!;
    final g = georefForBounds(b, 5565, 5120);
    final c = g.corners(5565, 5120);
    expect(c.topLeft.lat, closeTo(45.955, 1e-9));
    expect(c.topLeft.lng, closeTo(-122.08, 1e-9));
    expect(c.bottomRight.lat, closeTo(45.875, 1e-9));
    expect(c.bottomRight.lng, closeTo(-121.955, 1e-9));
    expect(c.topRight.lat, closeTo(45.955, 1e-9));
    expect(c.bottomLeft.lng, closeTo(-122.08, 1e-9));
    final mid = g.toMap((u: 5565 / 2, v: 5120 / 2));
    expect(mid.lng, closeTo((-122.08 + -121.955) / 2, 1e-9));
  });

  group('installer', () {
    late Directory tmp;
    late MapLayers layers;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('packs');
      layers = MapLayers(Directory('${tmp.path}/layers'));
    });
    tearDown(() {
      layers.close();
      tmp.deleteSync(recursive: true);
    });

    Future<(MapPack, Map<String, Uint8List>)> pack() async {
      final gpx = Uint8List.fromList(utf8.encode(allTrailsGpx));
      final png = pngHeader(400, 300);
      final pk = MapPack.fromJson({
        'id': 'tc',
        'name': 'Trapper Creek Wilderness',
        'short': 'Trapper Creek',
        'bounds': box,
        'files': [
          file(
            't.gpx',
            'trail',
            gpx.length,
            sha256: await sha(gpx),
            asset: 'assets/map_packs/t.gpx',
            title: 'Trapper trails',
          ),
          file(
            'topo.png',
            'overlay',
            png.length,
            sha256: await sha(png),
            title: 'Trapper topo',
            bounds: box,
          ),
        ],
      })!;
      return (pk, {'t.gpx': gpx, 'topo.png': png});
    }

    test('adds trails (bundled) and places the picture (downloaded)', () async {
      final (p, data) = await pack();
      final got = <Uri>[];
      final progress = <PackProgress>[];
      final inst = PackInstaller(
        layers: layers,
        tempDir: Directory('${tmp.path}/t'),
        readAsset: (k) async {
          expect(k, 'assets/map_packs/t.gpx');
          return data['t.gpx']!;
        },
        download: (u, to, on) async {
          got.add(u);
          final b = data[u.pathSegments.last]!;
          on(b.length ~/ 2, b.length);
          await to.writeAsBytes(b);
          on(b.length, b.length);
        },
      );
      expect(packAdded(p, layers), isFalse);
      final out = await inst.add(p, onProgress: progress.add);
      expect(out, hasLength(2));
      expect(got.map((u) => u.pathSegments.last), [
        'topo.png',
      ], reason: 'the trail came from the APK');
      expect(packAdded(p, layers), isTrue);
      final trail = out.first, pic = out.last;
      expect(trail.name, 'Trapper trails');
      expect(trail.kind, MapLayerKind.trail);
      expect((trail.pack, trail.packFile), ('tc', 't.gpx'));
      expect(pic.name, 'Trapper topo');
      expect(pic.placed, isTrue);
      expect(pic.opacity, closeTo(0.85, 1e-9));
      expect(
        progress.map((x) => x.step),
        containsAll(['Downloading', 'Checking', 'Adding', 'Added']),
      );
      expect(progress.last.fraction, 1.0);
      expect(
        Directory('${tmp.path}/t').listSync(),
        isEmpty,
        reason: 'temp cleaned',
      );

      // Bounds of what was added: the pack box.
      final pb = layerBounds(layers, pic)!;
      expect(pb.north, closeTo(45.955, 1e-6));
      expect(pb.west, closeTo(-122.08, 1e-6));
      final b = unionBounds([for (final l in out) layerBounds(layers, l)])!;
      expect(b.north, closeTo(47.507, 1e-6), reason: 'the test trail');
      expect(b.south, closeTo(45.875, 1e-6));

      // Survives a restart (pack tags persist), nothing added twice.
      final again = MapLayers(Directory('${tmp.path}/layers'));
      await again.load();
      expect(packAdded(p, again), isTrue);
      expect(again.overlays.single.georef, isA<Georef>());
      final inst2 = PackInstaller(
        layers: again,
        tempDir: Directory('${tmp.path}/t'),
        download: (_, _, _) async => fail('nothing to download'),
      );
      expect(await inst2.add(p), isEmpty);
      again.close();
    });

    test(
      'checksum mismatch, download error and cancel: nothing half-added',
      () async {
        final (p, data) = await pack();
        final inst = PackInstaller(
          layers: layers,
          tempDir: Directory('${tmp.path}/t'),
          download: (u, to, on) async => to.writeAsBytes(
            u.pathSegments.last == 'topo.png'
                ? (Uint8List.fromList(data['topo.png']!)..[20] ^= 1)
                : data[u.pathSegments.last]!,
          ),
        );
        await expectLater(
          inst.add(p),
          throwsA(
            isA<PackException>().having(
              (e) => e.message,
              'm',
              contains('checksum'),
            ),
          ),
        );
        // The trail (first file) stayed; adding again only needs the picture.
        expect(addedFiles(p, layers), {'t.gpx'});
        expect(layers.overlays, isEmpty);
        final down = PackInstaller(
          layers: layers,
          tempDir: Directory('${tmp.path}/t'),
          download: (_, _, _) async => throw const SocketException('no signal'),
        );
        await expectLater(
          down.add(p),
          throwsA(
            isA<PackException>().having(
              (e) => '$e',
              'm',
              contains('Could not download topo.png'),
            ),
          ),
        );
        await expectLater(
          down.add(p, cancelled: () => true),
          throwsA(isA<PackException>().having((e) => '$e', 'm', 'Cancelled')),
        );
        final ok = PackInstaller(
          layers: layers,
          tempDir: Directory('${tmp.path}/t'),
          download: (u, to, on) async =>
              to.writeAsBytes(data[u.pathSegments.last]!),
        );
        expect((await ok.add(p)).single.packFile, 'topo.png');
        expect(packAdded(p, layers), isTrue);
      },
    );

    test('storage limit is checked before downloading', () async {
      final (p, _) = await pack();
      final small = MapLayers(Directory('${tmp.path}/s'), limitBytes: 100);
      final inst = PackInstaller(
        layers: small,
        tempDir: Directory('${tmp.path}/t'),
        download: (_, _, _) async => fail('should not download'),
      );
      await expectLater(inst.add(p), throwsA(isA<StorageLimitException>()));
      small.close();
    });

    final haveSqlite = useHostSqlite();
    test('an MBTiles pack file becomes an offline base map', () async {
      final path = '${tmp.path}/src.mbtiles';
      final db = sqlite3.open(path);
      db.execute(
        'CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, '
        'tile_row INTEGER, tile_data BLOB)',
      );
      db.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
      for (final kv in {
        'name': 'x',
        'format': 'png',
        'minzoom': '12',
        'maxzoom': '12',
        'bounds': '-122.335,45.695,-122.115,45.805',
      }.entries) {
        db.execute('INSERT INTO metadata VALUES (?, ?)', [kv.key, kv.value]);
      }
      db.execute('INSERT INTO tiles VALUES (12, 656, 2650, ?)', [
        Uint8List.fromList([1]),
      ]);
      db.dispose();
      final bytes = File(path).readAsBytesSync();
      final p = MapPack.fromJson({
        'id': 'ss',
        'name': 'Silver Star',
        'files': [
          file(
            'topo.mbtiles',
            'tiles',
            bytes.length,
            sha256: await sha(bytes),
            title: 'Silver Star USGS topo',
          ),
        ],
      })!;
      final inst = PackInstaller(
        layers: layers,
        tempDir: Directory('${tmp.path}/t'),
        download: (u, to, on) async => to.writeAsBytes(bytes),
      );
      final l = (await inst.add(p)).single;
      expect(l.kind, MapLayerKind.tiles);
      expect(l.name, 'Silver Star USGS topo');
      expect(layers.tilesOf(l.id)!.tileCount, 1);
      final b = layerBounds(layers, l)!;
      expect(b.south, closeTo(45.695, 1e-9));
    }, skip: haveSqlite ? false : 'no SQLite library on this machine');
  });

  test('"maps are ready" banner answer is remembered', () {
    final s = TripSettings();
    expect(s.packsOffered, isFalse);
    s.packsOffered = true;
    expect(TripSettings.decode(s.encode()).packsOffered, isTrue);
    expect(TripSettings.decode('{}').packsOffered, isFalse);
  });

  group('screens', () {
    late Directory tmp;
    late TripController t;
    late Map<String, Uint8List> data;
    late MapPack p;

    Future<void> setUpTrip(WidgetTester tester) async {
      tmp = Directory.systemTemp.createTempSync('ui');
      t = TripController(
        host: FakeHost(1),
        settings: TripSettings(),
        dir: tmp,
        userAgent: 'test',
      )..tiles.online = false;
      await tester.runAsync(() async {
        await t.layers.load();
        final gpx = Uint8List.fromList(utf8.encode(allTrailsGpx));
        final png = pngHeader(400, 300);
        data = {'t.gpx': gpx, 'topo.png': png};
        p = MapPack.fromJson({
          'id': 'tc',
          'name': 'Trapper Creek Wilderness',
          'area': 'Gifford Pinchot NF',
          'files': [
            file('t.gpx', 'trail', gpx.length, sha256: await sha(gpx)),
            file(
              'topo.png',
              'overlay',
              png.length,
              sha256: await sha(png),
              bounds: box,
            ),
          ],
        })!;
      });
    }

    testWidgets('Ready-made maps: Add downloads, places and moves the map', (
      tester,
    ) async {
      await setUpTrip(tester);
      GeoBounds? fit;
      final page = MapPacksPage(
        trip: t,
        onFit: (b) => fit = b,
        catalog: PackCatalog(
          bundled: () async => jsonEncode({
            'packs': [jsonDecode(jsonEncode(_packJson(p)))],
          }),
        ),
        installer: PackInstaller(
          layers: t.layers,
          tempDir: Directory('${tmp.path}/t'),
          download: (u, to, on) async =>
              to.writeAsBytes(data[u.pathSegments.last]!),
        ),
      );
      await tester.pumpWidget(MaterialApp(home: page));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.text('Ready-made maps'), findsOneWidget);
      expect(find.text('Trapper Creek Wilderness'), findsOneWidget);
      expect(find.text('trails + topo map picture'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('addPack:tc')));
        for (var i = 0; i < 40 && fit == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      await tester.pump();
      expect(fit, isNotNull);
      expect(fit!.south, closeTo(45.875, 1e-3));
      expect(packAdded(p, t.layers), isTrue);
      expect(find.widgetWithText(Chip, 'Added'), findsOneWidget);
      expect(find.text('Added'), findsNWidgets(3), reason: 'chip + 2 files');
      expect(find.text('Show on map'), findsOneWidget);
      t.dispose();
      tmp.deleteSync(recursive: true);
    });

    testWidgets('Map layers page leads with Ready-made maps', (tester) async {
      await setUpTrip(tester);
      await tester.pumpWidget(MaterialApp(home: MapLayersPage(trip: t)));
      expect(find.byKey(const Key('readyMadeMaps')), findsOneWidget);
      expect(find.text('Ready-made maps'), findsOneWidget);
      t.dispose();
      tmp.deleteSync(recursive: true);
    });

    testWidgets('adding only trails leaves the base map alone', (tester) async {
      await setUpTrip(tester);
      final trail = await tester.runAsync(
        () => t.layers.importTrail('si.gpx', utf8.encode(allTrailsGpx)),
      );
      final b = await tester.runAsync(() => afterAdding(t, [trail!]));
      expect(b!.north, closeTo(47.507, 1e-3));
      expect(t.baseTiles, isNull);
      t.dispose();
      tmp.deleteSync(recursive: true);
    });
  });
}

Map<String, Object?> _packJson(MapPack p) => {
  'id': p.id,
  'name': p.name,
  'area': p.area,
  'files': [
    for (final f in p.files)
      {
        'name': f.name,
        'kind': f.kind.name,
        'url': f.url,
        'size': f.size,
        'sha256': ?f.sha256,
        if (f.bounds != null)
          'bounds': {
            's': f.bounds!.south,
            'w': f.bounds!.west,
            'n': f.bounds!.north,
            'e': f.bounds!.east,
          },
      },
  ],
};
