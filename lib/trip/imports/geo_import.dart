import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../geo.dart';

/// A line from an imported file (GPX track / route, KML LineString,
/// gx:Track or polygon outline).
class ImportedLine {
  ImportedLine(this.name, this.points, {this.isRoute = false});
  String name;
  final List<GeoPoint> points;

  /// Planned route (GPX rte) rather than a recorded track.
  final bool isRoute;
}

/// A waypoint (GPX wpt, KML Point placemark).
class ImportedWaypoint {
  ImportedWaypoint(
    this.name,
    this.pos, {
    this.description = '',
    this.kind = '',
  });
  String name;
  final GeoPoint pos;
  final String description;

  /// Place kind from map search (v1.8.4): 'peak', 'lake', 'trailhead',
  /// 'spring', 'water', 'campsite', 'shelter'; '' for a plain waypoint.
  final String kind;
}

/// What came out of a GPX / KML / KMZ file.
class ImportedData {
  ImportedData({
    this.name = '',
    List<ImportedLine>? lines,
    List<ImportedWaypoint>? waypoints,
    this.color,
  }) : lines = lines ?? [],
       waypoints = waypoints ?? [];
  String name;
  final List<ImportedLine> lines;
  final List<ImportedWaypoint> waypoints;

  /// First line colour in the file (KML LineStyle / GPX extension), ARGB.
  int? color;

  bool get isEmpty => lines.isEmpty && waypoints.isEmpty;
  int get pointCount =>
      lines.fold(0, (s, l) => s + l.points.length) + waypoints.length;

  /// All coordinates (for fitting the map).
  Iterable<GeoPoint> get allPoints sync* {
    for (final l in lines) {
      yield* l.points;
    }
    for (final w in waypoints) {
      yield w.pos;
    }
  }
}

class ImportFormatException implements Exception {
  ImportFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Kinds of files the Trip tab can import.
enum ImportKind { gpx, kml, kmz, mbtiles, image, pdf }

/// Guess the kind from a file name and the first bytes.
ImportKind? sniffImport(String name, List<int> head) {
  final n = name.toLowerCase();
  bool starts(List<int> sig) {
    if (head.length < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (head[i] != sig[i]) return false;
    }
    return true;
  }

  if (starts(ascii.encode('SQLite format 3'))) return ImportKind.mbtiles;
  if (starts(ascii.encode('%PDF'))) return ImportKind.pdf;
  if (starts(const [0x89, 0x50, 0x4E, 0x47]) ||
      starts(const [0xFF, 0xD8, 0xFF]) ||
      (starts(ascii.encode('RIFF')) &&
          head.length >= 12 &&
          ascii.decode(head.sublist(8, 12), allowInvalid: true) == 'WEBP')) {
    return ImportKind.image;
  }
  if (starts(const [0x50, 0x4B, 0x03, 0x04])) return ImportKind.kmz; // zip
  final text = utf8
      .decode(head.take(1024).toList(), allowMalformed: true)
      .toLowerCase();
  if (text.contains('<gpx')) return ImportKind.gpx;
  if (text.contains('<kml')) return ImportKind.kml;
  if (n.endsWith('.gpx')) return ImportKind.gpx;
  if (n.endsWith('.kml')) return ImportKind.kml;
  if (n.endsWith('.kmz')) return ImportKind.kmz;
  if (n.endsWith('.mbtiles')) return ImportKind.mbtiles;
  if (n.endsWith('.pdf')) return ImportKind.pdf;
  if (RegExp(r'\.(png|jpe?g|webp)$').hasMatch(n)) return ImportKind.image;
  return null;
}

String _baseName(String file) {
  final s = file.split(RegExp(r'[/\\]')).last;
  final dot = s.lastIndexOf('.');
  return dot > 0 ? s.substring(0, dot) : s;
}

/// Parse GPX, KML or KMZ bytes.
ImportedData parseTrailFile(String fileName, Uint8List bytes) {
  final kind = sniffImport(fileName, bytes.take(1024).toList());
  final ImportedData d;
  switch (kind) {
    case ImportKind.gpx:
      d = parseGpx(utf8.decode(bytes, allowMalformed: true));
    case ImportKind.kml:
      d = parseKml(utf8.decode(bytes, allowMalformed: true));
    case ImportKind.kmz:
      d = parseKmz(bytes);
    default:
      throw ImportFormatException('Not a GPX, KML or KMZ file');
  }
  if (d.name.trim().isEmpty) d.name = _baseName(fileName);
  if (d.isEmpty) throw ImportFormatException('No tracks or waypoints found');
  return d;
}

XmlDocument _xml(String s) {
  try {
    return XmlDocument.parse(s.trim().replaceFirst('\uFEFF', ''));
  } on XmlException catch (e) {
    throw ImportFormatException('Unreadable file: ${e.message}');
  }
}

Iterable<XmlElement> _all(XmlNode n, String local) =>
    n.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

XmlElement? _child(XmlElement e, String local) {
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

String _text(XmlElement? e) => e?.innerText.trim() ?? '';

GeoPoint? _pt(String? lat, String? lng) {
  final a = double.tryParse(lat?.trim() ?? '');
  final b = double.tryParse(lng?.trim() ?? '');
  if (a == null || b == null) return null;
  final p = GeoPoint(a, b);
  return p.valid ? p : null;
}

/// GPX 1.0 / 1.1 (AllTrails, Gaia, CalTopo, Garmin).
ImportedData parseGpx(String s) {
  final doc = _xml(s);
  final root = doc.rootElement;
  if (root.name.local != 'gpx') throw ImportFormatException('Not a GPX file');
  final meta = _child(root, 'metadata');
  final d = ImportedData(
    name: _text(meta == null ? _child(root, 'name') : _child(meta, 'name')),
  );
  for (final w in root.childElements.where((e) => e.name.local == 'wpt')) {
    final p = _pt(w.getAttribute('lat'), w.getAttribute('lon'));
    if (p == null) continue;
    d.waypoints.add(
      ImportedWaypoint(
        _text(_child(w, 'name')),
        p,
        description: _text(_child(w, 'desc')),
      ),
    );
  }
  for (final t in root.childElements.where((e) => e.name.local == 'trk')) {
    final name = _text(_child(t, 'name'));
    d.color ??= _gpxColor(t);
    for (final seg in t.childElements.where((e) => e.name.local == 'trkseg')) {
      final pts = [
        for (final p in seg.childElements.where((e) => e.name.local == 'trkpt'))
          ?_pt(p.getAttribute('lat'), p.getAttribute('lon')),
      ];
      if (pts.length > 1) d.lines.add(ImportedLine(name, pts));
    }
  }
  for (final r in root.childElements.where((e) => e.name.local == 'rte')) {
    final pts = [
      for (final p in r.childElements.where((e) => e.name.local == 'rtept'))
        ?_pt(p.getAttribute('lat'), p.getAttribute('lon')),
    ];
    if (pts.length > 1) {
      d.lines.add(ImportedLine(_text(_child(r, 'name')), pts, isRoute: true));
    }
  }
  if (d.name.isEmpty && d.lines.isNotEmpty) d.name = d.lines.first.name;
  return d;
}

/// Garmin / Gaia `<extensions><...:DisplayColor>` or `<color>RRGGBB`.
int? _gpxColor(XmlElement trk) {
  for (final e in _all(trk, 'color')) {
    final v = int.tryParse(_text(e).replaceFirst('#', ''), radix: 16);
    if (v != null) return 0xFF000000 | v;
  }
  return null;
}

/// KML 2.2 (Google My Maps, Google Earth, CalTopo, Gaia).
ImportedData parseKml(String s) {
  final doc = _xml(s);
  if (doc.rootElement.name.local != 'kml') {
    throw ImportFormatException('Not a KML file');
  }
  final docEl = _all(doc, 'Document').firstOrNull;
  final d = ImportedData(
    name: docEl == null ? '' : _text(_child(docEl, 'name')),
  );
  final styles = <String, int>{};
  for (final st in _all(doc, 'Style')) {
    final id = st.getAttribute('id');
    final ls = _all(st, 'LineStyle').firstOrNull;
    final c = ls == null ? null : _kmlColor(_text(_child(ls, 'color')));
    if (id != null && c != null) styles['#$id'] = c;
  }
  // StyleMap -> normal style.
  for (final sm in _all(doc, 'StyleMap')) {
    final id = sm.getAttribute('id');
    for (final pair in _all(sm, 'Pair')) {
      if (_text(_child(pair, 'key')) == 'normal') {
        final c = styles[_text(_child(pair, 'styleUrl'))];
        if (id != null && c != null) styles['#$id'] = c;
      }
    }
  }
  for (final pm in _all(doc, 'Placemark')) {
    final name = _text(_child(pm, 'name'));
    final desc = _text(_child(pm, 'description'));
    final c = styles[_text(_child(pm, 'styleUrl'))];
    var hasLine = false;
    for (final ls in _all(pm, 'LineString')) {
      final pts = _coords(_text(_all(ls, 'coordinates').firstOrNull));
      if (pts.length > 1) {
        d.lines.add(ImportedLine(name, pts));
        hasLine = true;
      }
    }
    for (final ring in _all(pm, 'outerBoundaryIs')) {
      final pts = _coords(_text(_all(ring, 'coordinates').firstOrNull));
      if (pts.length > 1) {
        d.lines.add(ImportedLine(name, pts));
        hasLine = true;
      }
    }
    for (final tr in _all(pm, 'Track')) {
      // gx:Track: <gx:coord>lng lat alt</gx:coord>
      final pts = <GeoPoint>[];
      for (final co in _all(tr, 'coord')) {
        final v = _text(co).split(RegExp(r'\s+'));
        if (v.length >= 2) {
          final p = _pt(v[1], v[0]);
          if (p != null) pts.add(p);
        }
      }
      if (pts.length > 1) {
        d.lines.add(ImportedLine(name, pts));
        hasLine = true;
      }
    }
    if (hasLine) d.color ??= c;
    for (final p in _all(pm, 'Point')) {
      final pts = _coords(_text(_all(p, 'coordinates').firstOrNull));
      if (pts.isNotEmpty) {
        d.waypoints.add(ImportedWaypoint(name, pts.first, description: desc));
      }
    }
  }
  return d;
}

/// KML colour is aabbggrr.
int? _kmlColor(String s) {
  final v = int.tryParse(s.trim(), radix: 16);
  if (v == null || s.trim().length != 8) return null;
  final a = (v >> 24) & 0xFF, b = (v >> 16) & 0xFF;
  final g = (v >> 8) & 0xFF, r = v & 0xFF;
  return (a << 24) | (r << 16) | (g << 8) | b;
}

/// "lng,lat[,alt] lng,lat[,alt] ..."
List<GeoPoint> _coords(String s) {
  final out = <GeoPoint>[];
  for (final tuple in s.split(RegExp(r'\s+'))) {
    final v = tuple.split(',');
    if (v.length < 2) continue;
    final p = _pt(v[1], v[0]);
    if (p != null) out.add(p);
  }
  return out;
}

/// KMZ = zip with doc.kml (or the first .kml).
ImportedData parseKmz(Uint8List bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw ImportFormatException('Unreadable KMZ file');
  }
  final kmls = zip.files
      .where((f) => f.isFile && f.name.toLowerCase().endsWith('.kml'))
      .toList();
  if (kmls.isEmpty) throw ImportFormatException('No KML inside the KMZ');
  kmls.sort((a, b) {
    int rank(ArchiveFile f) => f.name.toLowerCase() == 'doc.kml' ? 0 : 1;
    return rank(a).compareTo(rank(b));
  });
  final f = kmls.first;
  if (f.size > maxTrailFileBytes) {
    throw ImportFormatException('KML inside the KMZ is too big');
  }
  return parseKml(utf8.decode(f.content, allowMalformed: true));
}

/// Largest GPX / KML (or KML inside a KMZ) we read: 20 MB.
const int maxTrailFileBytes = 20 * 1024 * 1024;

/// Total points kept per imported file (simplified at 2 m first).
const int maxImportPoints = 20000;

/// Drop near-duplicate points (2 m Douglas-Peucker) so huge recordings stay
/// light to draw and store; then cap the total.
ImportedData tidyImport(ImportedData d) {
  for (var i = 0; i < d.lines.length; i++) {
    final l = d.lines[i];
    if (l.points.length > 500) {
      final s = simplify<GeoPoint>(l.points, (p) => p, 2);
      d.lines[i] = ImportedLine(l.name, s, isRoute: l.isRoute);
    }
  }
  var total = d.lines.fold<int>(0, (s, l) => s + l.points.length);
  if (total > maxImportPoints) {
    final share = maxImportPoints / total;
    for (var i = 0; i < d.lines.length; i++) {
      final l = d.lines[i];
      final n = (l.points.length * share).floor().clamp(2, l.points.length);
      d.lines[i] = ImportedLine(
        l.name,
        thinTo<GeoPoint>(l.points, (p) => p, n),
        isRoute: l.isRoute,
      );
    }
  }
  if (d.waypoints.length > 2000) {
    d.waypoints.removeRange(2000, d.waypoints.length);
  }
  return d;
}
