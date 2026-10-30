import 'dart:convert' show Utf8Codec;
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import '../geo.dart';
import '../tile_cache.dart' show GeoBounds;

/// Offline roads (v1.9.2): the drivable OpenStreetMap roads of an area as
/// a compact routing graph (a `.wtr` file: gzip of the arrays below).
///
/// Nodes are road junctions (and gates / fords); edges are the road
/// pieces between them with their shape, length, class, speed, one-way,
/// roughness (tracktype / smoothness / 4wd_only / surface) and seasonal
/// closures. Nodes keep their OpenStreetMap id so several saved areas join
/// up into one network ([RoadData.merge]).

/// Road classes (index = code).
const roadClasses = [
  'motorway',
  'trunk',
  'primary',
  'secondary',
  'tertiary',
  'unclassified',
  'residential',
  'living_street',
  'service',
  'track',
  'road',
];

/// Default speeds (km/h) by class.
const List<int> classSpeedKmh = [105, 88, 72, 64, 56, 45, 35, 15, 20, 25, 35];

/// Edge flags.
abstract final class EdgeFlag {
  /// One way, along the stored direction (a -> b) only.
  static const oneway = 1;

  /// One way, against the stored direction (b -> a) only.
  static const onewayBack = 2;
  static const roundabout = 4;
  static const link = 8;

  /// access=destination (or private allowed for destination traffic).
  static const destination = 16;

  /// seasonal=yes (no dates).
  static const seasonal = 32;
  static const ford = 64;
  static const toll = 128;
}

/// Node flags.
abstract final class NodeFlag {
  /// Locked / no-access gate, bollard, block...: cannot drive through.
  static const blocked = 1;

  /// A gate that may be closed.
  static const gate = 2;
  static const ford = 4;
}

/// Roughness: 0 normal, 1 gravel / unpaved, 2 rough, 3 high clearance / 4WD.
const roughLabels = ['', 'gravel / unpaved', 'rough', 'high clearance / 4WD'];

/// What the road rules make of a way's tags (null = not drivable).
class RoadAttr {
  const RoadAttr({
    required this.cls,
    required this.speedKmh,
    this.flags = 0,
    this.rough = 0,
    this.closeFrom = 0,
    this.closeTo = 0,
    this.name = '',
  });
  final int cls, speedKmh, flags, rough;

  /// Seasonal closure, day of year 1..366 (0 = none).
  final int closeFrom, closeTo;
  final String name;
}

const _months = {
  'jan': 0,
  'feb': 31,
  'mar': 59,
  'apr': 90,
  'may': 120,
  'jun': 151,
  'jul': 181,
  'aug': 212,
  'sep': 243,
  'oct': 273,
  'nov': 304,
  'dec': 334,
};
const _monthEnd = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/// Day of year (1..365, Feb 29 counts as Feb 28).
int dayOfYear(DateTime d) {
  final m = _months.values.elementAt(d.month - 1);
  return m + min(d.day, _monthEnd[d.month - 1]);
}

/// "Nov 15" for a day of year.
String dayLabel(int doy) {
  final names = _months.keys.toList();
  var m = 11;
  final starts = _months.values.toList();
  while (m > 0 && starts[m] >= doy) {
    m--;
  }
  final n = names[m];
  return '${n[0].toUpperCase()}${n.substring(1)} ${doy - starts[m]}';
}

/// Inside a closure from [from] to [to] (wraps over New Year)?
bool closedOn(int doy, int from, int to) {
  if (from == 0 || to == 0) return false;
  return from <= to ? doy >= from && doy <= to : doy >= from || doy <= to;
}

/// The drivable-road rules (car profile).
abstract final class RoadRules {
  static const _drivable = {
    'motorway': 0,
    'trunk': 1,
    'primary': 2,
    'secondary': 3,
    'tertiary': 4,
    'unclassified': 5,
    'residential': 6,
    'living_street': 7,
    'service': 8,
    'track': 9,
    'road': 10,
  };
  static const _no = {'no', 'private', 'agricultural', 'forestry', 'delivery'};
  static const _yes = {'yes', 'permissive', 'designated', 'official'};

  /// Overpass regex of the highway values used.
  static const overpassHighways =
      '^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|'
      'living_street|service|track|road|motorway_link|trunk_link|'
      'primary_link|secondary_link|tertiary_link)\$';

  static RoadAttr? classify(Map<String, String> t) {
    var hw = t['highway'];
    if (hw == null) return null;
    var flags = 0;
    if (hw.endsWith('_link')) {
      hw = hw.substring(0, hw.length - 5);
      flags |= EdgeFlag.link;
    }
    final cls = _drivable[hw];
    if (cls == null) return null;
    if (t['area'] == 'yes') return null;
    const skipService = {
      'driveway',
      'parking_aisle',
      'drive-through',
      'emergency_access',
    };
    if (hw == 'service' && skipService.contains(t['service'])) return null;
    if (t['smoothness'] == 'impassable') return null;
    // Access: the most specific tag wins (motorcar > motor_vehicle >
    // vehicle > access).
    String? acc;
    for (final k in ['motorcar', 'motor_vehicle', 'vehicle', 'access']) {
      final v = t[k];
      if (v != null) {
        acc = v;
        break;
      }
    }
    if (acc != null && _no.contains(acc)) return null;
    if (acc == 'destination' || acc == 'customers') {
      flags |= EdgeFlag.destination;
    }
    if (hw == 'track' &&
        acc != null &&
        !_yes.contains(acc) &&
        acc != 'destination') {
      // e.g. access=permit: keep, but as destination-only.
      flags |= EdgeFlag.destination;
    }
    // One way.
    final ow = t['oneway'];
    final roundabout =
        t['junction'] == 'roundabout' || t['junction'] == 'circular';
    if (roundabout) flags |= EdgeFlag.roundabout;
    if (ow == '-1' || ow == 'reverse') {
      flags |= EdgeFlag.onewayBack;
    } else if (ow == 'yes' ||
        ow == 'true' ||
        ow == '1' ||
        (ow == null && (roundabout || (hw == 'motorway')))) {
      flags |= EdgeFlag.oneway;
    }
    if (t['ford'] == 'yes') flags |= EdgeFlag.ford;
    if (t['toll'] == 'yes') flags |= EdgeFlag.toll;
    final seasonal = t['seasonal'];
    if (seasonal != null && seasonal != 'no') flags |= EdgeFlag.seasonal;
    // Roughness.
    final rough = roughness(t, hw);
    // Speed.
    var speed = classSpeedKmh[cls];
    if (flags & EdgeFlag.link != 0) speed = (speed * 0.6).round();
    final ms = parseMaxspeed(t['maxspeed']);
    if (ms != null && ms > 0) speed = ms;
    speed = min(speed, const [200, 50, 25, 12][rough]);
    final (cf, ct) = closure(t);
    return RoadAttr(
      cls: cls,
      speedKmh: max(5, speed),
      flags: flags,
      rough: rough,
      closeFrom: cf,
      closeTo: ct,
      name: nameOf(t, cls, flags & EdgeFlag.link != 0),
    );
  }

  /// 0 normal .. 3 high clearance / 4WD.
  static int roughness(Map<String, String> t, String hw) {
    if (t['4wd_only'] == 'yes' || t['4wd_only'] == 'recommended') return 3;
    switch (t['smoothness']) {
      case 'horrible' || 'very_horrible':
        return 3;
      case 'bad' || 'very_bad':
        return 2;
    }
    switch (t['tracktype']) {
      case 'grade5':
        return 3;
      case 'grade3' || 'grade4':
        return 2;
      case 'grade2':
        return 1;
      case 'grade1':
        return 0;
    }
    const unpaved = {
      'unpaved',
      'gravel',
      'fine_gravel',
      'compacted',
      'pebblestone',
      'rock',
    };
    const soft = {'dirt', 'ground', 'earth', 'mud', 'sand', 'grass'};
    final s = t['surface'];
    if (s != null && soft.contains(s)) return 2;
    if (s != null && unpaved.contains(s)) return 1;
    if (hw == 'track') return 1;
    return 0;
  }

  /// km/h from "35 mph", "50", "50 km/h" (null = none / unusable).
  static int? parseMaxspeed(String? v) {
    if (v == null) return null;
    final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(mph|km/h|kmh)?').firstMatch(v);
    if (m == null) return null;
    final n = double.parse(m.group(1)!);
    return (m.group(2) == 'mph' ? n * 1.609344 : n).round();
  }

  /// Seasonal closure from `*:conditional = no @ (Nov 15-Apr 30)` (dated
  /// one-off closures with a year are ignored: they are usually over).
  static (int, int) closure(Map<String, String> t) {
    for (final k in const [
      'motorcar:conditional',
      'motor_vehicle:conditional',
      'vehicle:conditional',
      'access:conditional',
    ]) {
      final v = t[k];
      if (v == null) continue;
      for (final m in RegExp(r'(no|private)\s*@\s*\(([^)]*)\)').allMatches(v)) {
        final r = parseSeason(m.group(2)!);
        if (r != null) return r;
      }
    }
    return (0, 0);
  }

  /// "Nov 15-Apr 30" / "Dec-Mar" -> day-of-year range.
  static (int, int)? parseSeason(String s) {
    if (RegExp(r'\d{4}').hasMatch(s)) return null; // dated, one-off
    final m = RegExp(
      r'^\s*([A-Za-z]{3})[a-z]*\s*(\d{1,2})?\s*-\s*([A-Za-z]{3})[a-z]*\s*(\d{1,2})?\s*$',
    ).firstMatch(s);
    if (m == null) return null;
    final a = _months[m.group(1)!.toLowerCase()];
    final b = _months[m.group(3)!.toLowerCase()];
    if (a == null || b == null) return null;
    final ai = _months.values.toList().indexOf(a);
    final bi = _months.values.toList().indexOf(b);
    final from = a + (int.tryParse(m.group(2) ?? '') ?? 1);
    final to = b + (int.tryParse(m.group(4) ?? '') ?? _monthEnd[bi]);
    if (ai < 0) return null;
    return (from, to);
  }

  /// "NF 4109" / "FS 4109" -> "FR 4109"; "I 84" -> "I-84".
  static String normRef(String ref) {
    var r = ref.split(';').first.trim();
    r = r.replaceFirstMapped(
      RegExp(r'^(NF|FS|FR|USFS|NFSR)[\s-]*(\d)'),
      (m) => 'FR ${m.group(2)}',
    );
    r = r.replaceFirstMapped(RegExp(r'^I\s+(\d)'), (m) => 'I-${m.group(1)}');
    return r;
  }

  /// Name shown in directions: "Silverstar Road (FR 4109)", "I-84",
  /// a ramp's destination.
  static String nameOf(Map<String, String> t, int cls, bool link) {
    if (link) {
      final refs = (t['destination:ref'] ?? '')
          .split(';')
          .map((r) => normRef(r.trim()))
          .where((r) => r.isNotEmpty)
          .join(' / ');
      final dest = (t['destination'] ?? '').split(';').join(', ').trim();
      if (refs.isEmpty) return dest;
      return dest.isEmpty ? refs : '$refs ($dest)';
    }
    final name = (t['name'] ?? '').trim();
    final ref = t['ref'] == null ? '' : normRef(t['ref']!);
    if (name.isEmpty) return ref;
    if (ref.isEmpty) return name;
    if (cls <= 1) return ref; // motorway / trunk: "I-84", "US 26"
    final digits = RegExp(r'\d+').firstMatch(ref)?.group(0);
    if (digits != null && name.contains(digits)) return name;
    return '$name ($ref)';
  }

  /// Node tags -> [NodeFlag]s.
  static int nodeFlags(Map<String, String>? t) {
    if (t == null) return 0;
    var f = 0;
    if (t['ford'] == 'yes') f |= NodeFlag.ford;
    final b = t['barrier'];
    if (b == null || b == 'no' || b == 'kerb') return f;
    String? acc;
    for (final k in ['motorcar', 'motor_vehicle', 'vehicle', 'access']) {
      if (t[k] != null) {
        acc = t[k];
        break;
      }
    }
    if (acc != null && _yes.contains(acc)) return f | NodeFlag.gate;
    const closedKinds = {
      'bollard',
      'block',
      'jersey_barrier',
      'log',
      'chain',
      'barrier_board',
      'bar',
      'rope',
      'wall',
      'fence',
      'debris',
      'height_restrictor',
      'kissing_gate',
      'stile',
      'turnstile',
      'cycle_barrier',
    };
    if ((acc != null && _no.contains(acc)) ||
        t['locked'] == 'yes' ||
        closedKinds.contains(b)) {
      return f | NodeFlag.blocked;
    }
    if (b == 'gate' || b == 'lift_gate' || b == 'swing_gate') {
      return f | NodeFlag.gate;
    }
    return f;
  }
}

/// A way as read from OpenStreetMap.
class OsmWay {
  OsmWay(this.id, this.nodes, this.tags);
  final int id;
  final List<int> nodes;
  final Map<String, String> tags;
}

/// The road graph of one area (or several merged).
class RoadData {
  RoadData({
    required this.bounds,
    required this.builtAt,
    required this.nodeOsm,
    required this.nodeLat,
    required this.nodeLng,
    required this.nodeFlags,
    required this.edgeA,
    required this.edgeB,
    required this.edgeLen,
    required this.edgeName,
    required this.edgeCls,
    required this.edgeFlags,
    required this.edgeRough,
    required this.edgeSpeed,
    required this.edgeClose,
    required this.edgeShape,
    required this.shapeLat,
    required this.shapeLng,
    required this.names,
  });

  final GeoBounds bounds;

  /// When the OpenStreetMap data was read.
  final DateTime builtAt;

  final Int64List nodeOsm;

  /// Degrees x 1e6.
  final Int32List nodeLat, nodeLng;
  final Uint8List nodeFlags;
  final Int32List edgeA, edgeB;

  /// Metres.
  final Float32List edgeLen;
  final Int32List edgeName;
  final Uint8List edgeCls, edgeFlags, edgeRough, edgeSpeed;

  /// Two per edge: closure from / to (day of year, 0 = none).
  final Uint16List edgeClose;

  /// Shape points of edge i: edgeShape[i] .. edgeShape[i + 1].
  final Int32List edgeShape;
  final Int32List shapeLat, shapeLng;
  final List<String> names;

  int get nodeCount => nodeLat.length;
  int get edgeCount => edgeA.length;

  GeoPoint nodePos(int n) => GeoPoint(nodeLat[n] / 1e6, nodeLng[n] / 1e6);

  /// The full line of edge [e] from a to b.
  List<GeoPoint> edgePoints(int e) => [
    nodePos(edgeA[e]),
    for (var i = edgeShape[e]; i < edgeShape[e + 1]; i++)
      GeoPoint(shapeLat[i] / 1e6, shapeLng[i] / 1e6),
    nodePos(edgeB[e]),
  ];

  // ------------------------------------------------------------ build

  /// Build from OpenStreetMap ways and their nodes (lat, lng) with node
  /// tags for barriers ([nodeTags], may be partial).
  static RoadData build(
    Iterable<OsmWay> ways,
    Map<int, (double, double)> coords, {
    Map<int, Map<String, String>> nodeTags = const {},
    GeoBounds? bounds,
    DateTime? builtAt,
  }) {
    final kept = <(OsmWay, RoadAttr)>[];
    final use = <int, int>{};
    for (final w in ways) {
      final a = RoadRules.classify(w.tags);
      if (a == null) continue;
      final ns = [
        for (final n in w.nodes)
          if (coords.containsKey(n)) n,
      ];
      if (ns.length < 2) continue;
      final ww = OsmWay(w.id, ns, w.tags);
      kept.add((ww, a));
      for (var i = 0; i < ns.length; i++) {
        final end = i == 0 || i == ns.length - 1;
        use[ns[i]] = (use[ns[i]] ?? 0) + (end ? 2 : 1);
      }
    }
    final nflag = <int, int>{
      for (final e in nodeTags.entries)
        if (RoadRules.nodeFlags(e.value) != 0)
          e.key: RoadRules.nodeFlags(e.value),
    };
    final idx = <int, int>{};
    final nOsm = <int>[], nLat = <int>[], nLng = <int>[], nF = <int>[];
    int nodeIndex(int osm) => idx.putIfAbsent(osm, () {
      final c = coords[osm]!;
      nOsm.add(osm);
      nLat.add((c.$1 * 1e6).round());
      nLng.add((c.$2 * 1e6).round());
      nF.add(nflag[osm] ?? 0);
      return nOsm.length - 1;
    });
    final names = <String>[''];
    final nameIdx = <String, int>{'': 0};
    final eA = <int>[], eB = <int>[], eName = <int>[];
    final eLen = <double>[];
    final eCls = <int>[], eFl = <int>[], eR = <int>[], eSp = <int>[];
    final eClose = <int>[], eShape = <int>[0];
    final sLat = <int>[], sLng = <int>[];
    for (final (w, a) in kept) {
      final ns = w.nodes;
      final name = nameIdx.putIfAbsent(a.name, () {
        names.add(a.name);
        return names.length - 1;
      });
      var start = 0;
      for (var i = 1; i < ns.length; i++) {
        final junction =
            i == ns.length - 1 ||
            (use[ns[i]] ?? 0) >= 2 ||
            nflag.containsKey(ns[i]);
        if (!junction) continue;
        // Edge ns[start] .. ns[i].
        var len = 0.0;
        for (var k = start; k < i; k++) {
          final p = coords[ns[k]]!, q = coords[ns[k + 1]]!;
          len += distanceM(GeoPoint(p.$1, p.$2), GeoPoint(q.$1, q.$2));
        }
        if (ns[start] != ns[i] || i - start > 1) {
          var fl = a.flags;
          // Fords tagged on nodes inside the piece.
          for (var k = start + 1; k < i; k++) {
            if ((nflag[ns[k]] ?? 0) & NodeFlag.ford != 0) fl |= EdgeFlag.ford;
          }
          eA.add(nodeIndex(ns[start]));
          eB.add(nodeIndex(ns[i]));
          eLen.add(len);
          eName.add(name);
          eCls.add(a.cls);
          eFl.add(fl);
          eR.add(a.rough);
          eSp.add(a.speedKmh.clamp(1, 255));
          eClose
            ..add(a.closeFrom)
            ..add(a.closeTo);
          for (var k = start + 1; k < i; k++) {
            final c = coords[ns[k]]!;
            sLat.add((c.$1 * 1e6).round());
            sLng.add((c.$2 * 1e6).round());
          }
          eShape.add(sLat.length);
        }
        start = i;
      }
    }
    var b = bounds;
    if (b == null) {
      var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
      for (var i = 0; i < nLat.length; i++) {
        s = min(s, nLat[i] / 1e6);
        n = max(n, nLat[i] / 1e6);
        w = min(w, nLng[i] / 1e6);
        e = max(e, nLng[i] / 1e6);
      }
      b = nLat.isEmpty ? const GeoBounds(0, 0, 0, 0) : GeoBounds(s, w, n, e);
    }
    return RoadData(
      bounds: b,
      builtAt: builtAt ?? DateTime.now(),
      nodeOsm: Int64List.fromList(nOsm),
      nodeLat: Int32List.fromList(nLat),
      nodeLng: Int32List.fromList(nLng),
      nodeFlags: Uint8List.fromList(nF),
      edgeA: Int32List.fromList(eA),
      edgeB: Int32List.fromList(eB),
      edgeLen: Float32List.fromList(eLen),
      edgeName: Int32List.fromList(eName),
      edgeCls: Uint8List.fromList(eCls),
      edgeFlags: Uint8List.fromList(eFl),
      edgeRough: Uint8List.fromList(eR),
      edgeSpeed: Uint8List.fromList(eSp),
      edgeClose: Uint16List.fromList(eClose),
      edgeShape: Int32List.fromList(eShape),
      shapeLat: Int32List.fromList(sLat),
      shapeLng: Int32List.fromList(sLng),
      names: names,
    );
  }

  // ------------------------------------------------------------ merge

  /// Join several areas into one network: the same OpenStreetMap junction
  /// in two areas becomes one node, roads saved twice are kept once.
  static RoadData merge(List<RoadData> parts) {
    if (parts.length == 1) return parts.first;
    final idx = <int, int>{};
    final nOsm = <int>[], nLat = <int>[], nLng = <int>[], nF = <int>[];
    // Junctions of every area by position: a road that is one piece in
    // one area can be cut there by a junction from another area.
    final at = <int, int>{};
    int key(int lat, int lng) => lat * 400000000 + lng;
    for (final p in parts) {
      for (var i = 0; i < p.nodeCount; i++) {
        final osm = p.nodeOsm[i];
        final have = idx[osm];
        if (have != null) {
          nF[have] |= p.nodeFlags[i];
          continue;
        }
        nOsm.add(osm);
        nLat.add(p.nodeLat[i]);
        nLng.add(p.nodeLng[i]);
        nF.add(p.nodeFlags[i]);
        idx[osm] = nOsm.length - 1;
        at.putIfAbsent(key(p.nodeLat[i], p.nodeLng[i]), () => nOsm.length - 1);
      }
    }
    final names = <String>[''];
    final nameIdx = <String, int>{'': 0};
    // Edge key -> area it came from (only repeats across areas are dropped).
    final seen = <(int, int, int, int), int>{};
    final eA = <int>[], eB = <int>[], eName = <int>[];
    final eLen = <double>[];
    final eCls = <int>[], eFl = <int>[], eR = <int>[], eSp = <int>[];
    final eClose = <int>[], eShape = <int>[0];
    final sLat = <int>[], sLng = <int>[];
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    var built = parts.first.builtAt;
    double dist(int la0, int ln0, int la1, int ln1) => distanceM(
      GeoPoint(la0 / 1e6, ln0 / 1e6),
      GeoPoint(la1 / 1e6, ln1 / 1e6),
    );
    for (var pi = 0; pi < parts.length; pi++) {
      final p = parts[pi];
      s = min(s, p.bounds.south);
      w = min(w, p.bounds.west);
      n = max(n, p.bounds.north);
      e = max(e, p.bounds.east);
      if (p.builtAt.isBefore(built)) built = p.builtAt;
      for (var k = 0; k < p.edgeCount; k++) {
        final nm = p.names[p.edgeName[k]];
        final name = nameIdx.putIfAbsent(nm, () {
          names.add(nm);
          return names.length - 1;
        });
        // The edge's points, cut at junctions.
        final la = <int>[p.nodeLat[p.edgeA[k]]],
            ln = <int>[p.nodeLng[p.edgeA[k]]];
        for (var i = p.edgeShape[k]; i < p.edgeShape[k + 1]; i++) {
          la.add(p.shapeLat[i]);
          ln.add(p.shapeLng[i]);
        }
        la.add(p.nodeLat[p.edgeB[k]]);
        ln.add(p.nodeLng[p.edgeB[k]]);
        final ends = idx[p.nodeOsm[p.edgeB[k]]]!;
        var raw = 0.0;
        for (var i = 0; i + 1 < la.length; i++) {
          raw += dist(la[i], ln[i], la[i + 1], ln[i + 1]);
        }
        final scale = raw <= 0 ? 1.0 : p.edgeLen[k] / raw;
        var from = idx[p.nodeOsm[p.edgeA[k]]]!;
        var i0 = 0;
        for (var i = 1; i < la.length; i++) {
          final last = i == la.length - 1;
          final cut = last ? ends : at[key(la[i], ln[i])];
          if (cut == null) continue;
          var len = 0.0;
          for (var j = i0; j < i; j++) {
            len += dist(la[j], ln[j], la[j + 1], ln[j + 1]);
          }
          final kk = (min(from, cut), max(from, cut), i - i0, len.round());
          if ((seen[kk] ??= pi) == pi) {
            eA.add(from);
            eB.add(cut);
            eLen.add(len * scale);
            eName.add(name);
            eCls.add(p.edgeCls[k]);
            eFl.add(p.edgeFlags[k]);
            eR.add(p.edgeRough[k]);
            eSp.add(p.edgeSpeed[k]);
            eClose
              ..add(p.edgeClose[2 * k])
              ..add(p.edgeClose[2 * k + 1]);
            for (var j = i0 + 1; j < i; j++) {
              sLat.add(la[j]);
              sLng.add(ln[j]);
            }
            eShape.add(sLat.length);
          }
          from = cut;
          i0 = i;
        }
      }
    }
    return RoadData(
      bounds: GeoBounds(s, w, n, e),
      builtAt: built,
      nodeOsm: Int64List.fromList(nOsm),
      nodeLat: Int32List.fromList(nLat),
      nodeLng: Int32List.fromList(nLng),
      nodeFlags: Uint8List.fromList(nF),
      edgeA: Int32List.fromList(eA),
      edgeB: Int32List.fromList(eB),
      edgeLen: Float32List.fromList(eLen),
      edgeName: Int32List.fromList(eName),
      edgeCls: Uint8List.fromList(eCls),
      edgeFlags: Uint8List.fromList(eFl),
      edgeRough: Uint8List.fromList(eR),
      edgeSpeed: Uint8List.fromList(eSp),
      edgeClose: Uint16List.fromList(eClose),
      edgeShape: Int32List.fromList(eShape),
      shapeLat: Int32List.fromList(sLat),
      shapeLng: Int32List.fromList(sLng),
      names: names,
    );
  }

  /// The same roads, labelled as covering [b].
  RoadData withBounds(GeoBounds b) => RoadData(
    bounds: b,
    builtAt: builtAt,
    nodeOsm: nodeOsm,
    nodeLat: nodeLat,
    nodeLng: nodeLng,
    nodeFlags: nodeFlags,
    edgeA: edgeA,
    edgeB: edgeB,
    edgeLen: edgeLen,
    edgeName: edgeName,
    edgeCls: edgeCls,
    edgeFlags: edgeFlags,
    edgeRough: edgeRough,
    edgeSpeed: edgeSpeed,
    edgeClose: edgeClose,
    edgeShape: edgeShape,
    shapeLat: shapeLat,
    shapeLng: shapeLng,
    names: names,
  );

  // ------------------------------------------------------------ file

  static const _magic = 0x31525457; // "WTR1"

  /// The `.wtr` file (gzip).
  Uint8List encode() {
    final b = BytesBuilder(copy: false);
    final h = ByteData(64);
    h.setUint32(0, _magic, Endian.little);
    h.setUint32(4, 1, Endian.little);
    h.setFloat64(8, bounds.south, Endian.little);
    h.setFloat64(16, bounds.west, Endian.little);
    h.setFloat64(24, bounds.north, Endian.little);
    h.setFloat64(32, bounds.east, Endian.little);
    h.setInt64(40, builtAt.millisecondsSinceEpoch, Endian.little);
    h.setUint32(48, nodeCount, Endian.little);
    h.setUint32(52, edgeCount, Endian.little);
    h.setUint32(56, shapeLat.length, Endian.little);
    h.setUint32(60, names.length, Endian.little);
    b.add(h.buffer.asUint8List());
    void add(TypedData d) {
      b.add(d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes));
      final pad = (8 - d.lengthInBytes % 8) % 8;
      if (pad > 0) b.add(Uint8List(pad));
    }

    // Shapes and nodes delta-coded (compress far better).
    Int32List delta(Int32List v) {
      final o = Int32List(v.length);
      var prev = 0;
      for (var i = 0; i < v.length; i++) {
        o[i] = v[i] - prev;
        prev = v[i];
      }
      return o;
    }

    add(nodeOsm);
    add(delta(nodeLat));
    add(delta(nodeLng));
    add(nodeFlags);
    add(edgeA);
    add(edgeB);
    add(edgeLen);
    add(edgeName);
    add(edgeCls);
    add(edgeFlags);
    add(edgeRough);
    add(edgeSpeed);
    add(edgeClose);
    add(edgeShape);
    add(delta(shapeLat));
    add(delta(shapeLng));
    final nb = BytesBuilder();
    for (final s in names) {
      final u = Uint8List.fromList(
        s.codeUnits.any((c) => c > 127) ? _utf8(s) : s.codeUnits,
      );
      nb.add([u.length & 0xFF, u.length >> 8]);
      nb.add(u);
    }
    b.add(nb.takeBytes());
    return Uint8List.fromList(gzip.encode(b.takeBytes()));
  }

  static List<int> _utf8(String s) => const Utf8Codec().encode(s);

  static RoadData decode(Uint8List file) {
    var raw = gzip.decode(file);
    var bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
    if (bytes.offsetInBytes % 8 != 0) bytes = Uint8List.fromList(bytes);
    final bd = ByteData.sublistView(bytes);
    if (bytes.length < 64 || bd.getUint32(0, Endian.little) != _magic) {
      throw const FormatException('Not a Stalkie Talkie roads file');
    }
    final nN = bd.getUint32(48, Endian.little);
    final nE = bd.getUint32(52, Endian.little);
    final nS = bd.getUint32(56, Endian.little);
    final nNames = bd.getUint32(60, Endian.little);
    var off = 64;
    final buf = bytes.buffer, base = bytes.offsetInBytes;
    T take<T>(int count, int size, T Function(int o, int n) view) {
      final v = view(base + off, count);
      off += count * size;
      off += (8 - (count * size) % 8) % 8;
      if (off > bytes.length) throw const FormatException('Roads file cut off');
      return v;
    }

    Int32List undelta(Int32List v) {
      final o = Int32List(v.length);
      var prev = 0;
      for (var i = 0; i < v.length; i++) {
        prev += v[i];
        o[i] = prev;
      }
      return o;
    }

    final osm = Int64List.fromList(take(nN, 8, buf.asInt64List));
    final lat = undelta(take(nN, 4, buf.asInt32List));
    final lng = undelta(take(nN, 4, buf.asInt32List));
    final nf = Uint8List.fromList(take(nN, 1, buf.asUint8List));
    final ea = Int32List.fromList(take(nE, 4, buf.asInt32List));
    final eb = Int32List.fromList(take(nE, 4, buf.asInt32List));
    final el = Float32List.fromList(take(nE, 4, buf.asFloat32List));
    final en = Int32List.fromList(take(nE, 4, buf.asInt32List));
    final ec = Uint8List.fromList(take(nE, 1, buf.asUint8List));
    final ef = Uint8List.fromList(take(nE, 1, buf.asUint8List));
    final er = Uint8List.fromList(take(nE, 1, buf.asUint8List));
    final es = Uint8List.fromList(take(nE, 1, buf.asUint8List));
    final ecl = Uint16List.fromList(take(nE * 2, 2, buf.asUint16List));
    final esh = Int32List.fromList(take(nE + 1, 4, buf.asInt32List));
    final sla = undelta(take(nS, 4, buf.asInt32List));
    final sln = undelta(take(nS, 4, buf.asInt32List));
    final names = <String>[];
    for (var i = 0; i < nNames; i++) {
      final len = bytes[off] | bytes[off + 1] << 8;
      off += 2;
      names.add(const Utf8Codec().decode(bytes.sublist(off, off + len)));
      off += len;
    }
    return RoadData(
      bounds: GeoBounds(
        bd.getFloat64(8, Endian.little),
        bd.getFloat64(16, Endian.little),
        bd.getFloat64(24, Endian.little),
        bd.getFloat64(32, Endian.little),
      ),
      builtAt: DateTime.fromMillisecondsSinceEpoch(
        bd.getInt64(40, Endian.little),
      ),
      nodeOsm: osm,
      nodeLat: lat,
      nodeLng: lng,
      nodeFlags: nf,
      edgeA: ea,
      edgeB: eb,
      edgeLen: el,
      edgeName: en,
      edgeCls: ec,
      edgeFlags: ef,
      edgeRough: er,
      edgeSpeed: es,
      edgeClose: ecl,
      edgeShape: esh,
      shapeLat: sla,
      shapeLng: sln,
      names: names,
    );
  }

  /// Kilometres of road in the data.
  double get roadKm {
    var s = 0.0;
    for (var i = 0; i < edgeCount; i++) {
      s += edgeLen[i];
    }
    return s / 1000;
  }
}
