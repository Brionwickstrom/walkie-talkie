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
}
