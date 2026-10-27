// Builds an offline roads pack (.wtr) from an OpenStreetMap OPL file, e.g.:
//   osmium tags-filter state.osm.pbf w/highway=... -o hw.pbf
//   osmium extract -b W,S,E,N --strategy complete_ways hw.pbf -o area.pbf
//   osmium cat -f opl area.pbf -o area.opl
//   dart run tool/build_roads.dart area.opl out.wtr S W N E
import 'dart:convert';
import 'dart:io';

import 'package:walkie_talkie/trip/drive/road_data.dart';
import 'package:walkie_talkie/trip/tile_cache.dart' show GeoBounds;

String _unescape(String s) => s.replaceAllMapped(
  RegExp(r'%([0-9a-fA-F]+)%'),
  (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
);

Map<String, String> _tags(String f) {
  final out = <String, String>{};
  if (f.length <= 1) return out;
  for (final kv in f.substring(1).split(',')) {
    final i = kv.indexOf('=');
    if (i <= 0) continue;
    out[_unescape(kv.substring(0, i))] = _unescape(kv.substring(i + 1));
  }
  return out;
}

Future<void> main(List<String> a) async {
  final coords = <int, (double, double)>{};
  final nodeTags = <int, Map<String, String>>{};
  final ways = <OsmWay>[];
  DateTime? newest;
  await for (final line in File(a[0])
      .openRead()
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final f = line.split(' ');
    final id = int.parse(f[0].substring(1));
    String? field(String p) => f.where((x) => x.startsWith(p)).firstOrNull;
    final t = field('t');
    if (t != null && t.length > 1) {
      final d = DateTime.tryParse(t.substring(1));
      if (d != null && (newest == null || d.isAfter(newest))) newest = d;
    }
    if (line[0] == 'n') {
      final x = field('x'), y = field('y');
      if (x == null || y == null || x.length < 2) continue;
      coords[id] = (double.parse(y.substring(1)), double.parse(x.substring(1)));
      final tg = field('T');
      if (tg != null && tg.contains('barrier') || (tg ?? '').contains('ford')) {
        nodeTags[id] = _tags(tg!);
      }
    } else if (line[0] == 'w') {
      final n = field('N');
      if (n == null || n.length < 2) continue;
      ways.add(
        OsmWay(id, [
          for (final r in n.substring(1).split(','))
            if (r.length > 1) int.parse(r.substring(1)),
        ], _tags(field('T') ?? 'T')),
      );
    }
  }
  final b = a.length >= 6
      ? GeoBounds(
          double.parse(a[2]),
          double.parse(a[3]),
          double.parse(a[4]),
          double.parse(a[5]),
        )
      : null;
  final d = RoadData.build(
    ways,
    coords,
    nodeTags: nodeTags,
    bounds: b,
    builtAt: newest,
  );
  final bytes = d.encode();
  await File(a[1]).writeAsBytes(bytes);
  stdout.writeln(
    '${ways.length} ways -> ${d.nodeCount} junctions, ${d.edgeCount} road '
    'pieces, ${d.shapeLat.length} shape points, ${d.names.length} names, '
    '${d.roadKm.round()} km; ${bytes.length} bytes',
  );
}
