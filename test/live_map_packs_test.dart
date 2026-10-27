// Live: adds the real packs from GitHub (set LIVE_PACKS=1).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/imports/map_packs.dart';

import 'support/host_sqlite.dart';

void main() {
  final live = Platform.environment['LIVE_PACKS'] == '1';
  final haveSqlite = useHostSqlite();
  test(
    'real packs download, verify and import',
    () async {
      final remote = await PackCatalog.httpFetch();
      final packs = MapPack.parseList(
        remote ?? File('map_packs.json').readAsStringSync(),
      );
      expect(packs, hasLength(2));
      final tmp = Directory.systemTemp.createTempSync('live');
      final layers = MapLayers(Directory('${tmp.path}/l'));
      final inst = PackInstaller(
        layers: layers,
        tempDir: Directory('${tmp.path}/t'),
      );
      for (final p in packs) {
        final out = await inst.add(p);
        expect(packAdded(p, layers), isTrue);
        // ignore: avoid_print
        print(
          '${p.id}: ${out.map((l) => '${l.kind.name} ${l.name} ${formatBytes(l.bytes)}').join(', ')}'
          ' bounds ${unionBounds([for (final l in out) layerBounds(layers, l)])}',
        );
      }
      layers.close();
      tmp.deleteSync(recursive: true);
    },
    skip: !live
        ? 'set LIVE_PACKS=1'
        : haveSqlite
        ? false
        : 'no SQLite',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // The real Silver Star files imported by hand (box only).
  final src = Directory('/workspace/silver_star');
  test(
    'hand-imported Silver Star files are found, not copied',
    () async {
      final tmp = Directory.systemTemp.createTempSync('real');
      final layers = MapLayers(Directory('${tmp.path}/l'));
      await layers.importTrail(
        'Silver_Star_Trails.kml',
        File('${src.path}/Silver_Star_Trails.kml').readAsBytesSync(),
      );
      File('${src.path}/Silver_Star_USGS_Topo.mbtiles')
          .copySync('${tmp.path}/x.mbtiles');
      await layers.importMbtiles(File('${tmp.path}/x.mbtiles'));
      final p = MapPack.parseList(File('map_packs.json').readAsStringSync())
          .first;
      final inst = PackInstaller(
        layers: layers,
        tempDir: Directory('${tmp.path}/t'),
        download: (_, _, _) async => fail('no download'),
      );
      final out = await inst.add(p);
      expect(inst.found, hasLength(2));
      expect(out.every((l) => l.packMatched), isTrue);
      expect(layers.all, hasLength(2));
      layers.close();
      tmp.deleteSync(recursive: true);
    },
    skip: !src.existsSync()
        ? 'no source files'
        : haveSqlite
        ? false
        : 'no SQLite',
  );
}
