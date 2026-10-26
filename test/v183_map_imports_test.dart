import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:walkie_talkie/trip/geo.dart';
import 'package:walkie_talkie/trip/imports/geo_import.dart';
import 'package:walkie_talkie/trip/imports/georef.dart';
import 'package:walkie_talkie/trip/imports/map_layers.dart';
import 'package:walkie_talkie/trip/imports/mbtiles.dart';
import 'package:walkie_talkie/trip/imports/route_share.dart';
import 'package:walkie_talkie/trip/track.dart';
import 'package:walkie_talkie/trip/trip_packet.dart';

import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/lora/lora_transport.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';

import 'fake_transport.dart';
import 'messaging_fakes.dart';

import 'package:flutter/material.dart';
import 'package:walkie_talkie/ui/map_layers_page.dart';

import 'support/host_sqlite.dart';
import 'trip_integration_test.dart'
    show FakeHost, FakeRadio, flush, hello, trip;

// AllTrails-style GPX 1.1 export: metadata name, one track, waypoints.
const allTrailsGpx = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1" creator="AllTrails.com" version="1.1">
  <metadata><name><![CDATA[Mount Si Trail]]></name></metadata>
  <wpt lat="47.4880" lon="-121.7230"><name>Trailhead</name><desc>Parking</desc></wpt>
  <wpt lat="47.5059" lon="-121.7305"><name>Haystack</name></wpt>
  <wpt lat="bad" lon="-121"><name>Broken</name></wpt>
  <trk>
    <name>Mount Si Trail</name>
    <trkseg>
      <trkpt lat="47.4880" lon="-121.7230"><ele>200</ele></trkpt>
      <trkpt lat="47.4920" lon="-121.7250"><ele>320</ele></trkpt>
      <trkpt lat="47.4990" lon="-121.7280"><ele>700</ele></trkpt>
      <trkpt lat="47.5059" lon="-121.7305"><ele>1200</ele></trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="47.5059" lon="-121.7305"/>
      <trkpt lat="47.5070" lon="-121.7310"/>
    </trkseg>
  </trk>
</gpx>''';

// Gaia / Garmin GPX 1.0 with a planned route and a colour extension.
const gaiaGpx = '''<?xml version="1.0"?>
<gpx version="1.0" creator="GaiaGPS" xmlns="http://www.topografix.com/GPX/1/0">
  <name>Enchantments</name>
  <rte><name>Planned</name>
    <rtept lat="47.52" lon="-120.82"/><rtept lat="47.48" lon="-120.80"/>
    <rtept lat="47.46" lon="-120.78"/>
  </rte>
  <trk><name>Day 1</name>
    <extensions><gpxx:TrackExtension xmlns:gpxx="x"><color>FF8800</color></gpxx:TrackExtension></extensions>
    <trkseg><trkpt lat="47.52" lon="-120.82"/><trkpt lat="47.50" lon="-120.81"/></trkseg>
  </trk>
</gpx>''';

// Google My Maps KML: styles via StyleMap, folders, line, points, polygon.
const myMapsKml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <name>Camping weekend</name>
    <Style id="line-0288D1-1200-normal"><LineStyle><color>ffd18802</color><width>4</width></LineStyle></Style>
    <StyleMap id="line-0288D1-1200">
      <Pair><key>normal</key><styleUrl>#line-0288D1-1200-normal</styleUrl></Pair>
    </StyleMap>
    <Folder><name>Trails</name>
      <Placemark><name>Loop</name><styleUrl>#line-0288D1-1200</styleUrl>
        <LineString><tessellate>1</tessellate><coordinates>
          -122.0,37.0,0 -122.01,37.01,0
          -122.02,37.0,0
        </coordinates></LineString>
      </Placemark>
      <Placemark><name>Lake outline</name>
        <Polygon><outerBoundaryIs><LinearRing><coordinates>-122.1,37.1 -122.11,37.1 -122.11,37.11 -122.1,37.1</coordinates></LinearRing></outerBoundaryIs></Polygon>
      </Placemark>
    </Folder>
    <Folder><name>Spots</name>
      <Placemark><name>Camp</name><description>Site 12</description><Point><coordinates>-122.005,37.004,0</coordinates></Point></Placemark>
      <Placemark><name>Water</name><Point><coordinates>-122.015,37.006</coordinates></Point></Placemark>
    </Folder>
    <Placemark><name>Recorded</name>
      <gx:Track><when>2026-01-01T00:00:00Z</when><gx:coord>-122.2 37.2 10</gx:coord><when>2026-01-01T00:01:00Z</when><gx:coord>-122.21 37.21 12</gx:coord></gx:Track>
    </Placemark>
  </Document>
</kml>''';

Uint8List kmz(String kml, {String name = 'doc.kml'}) {
  final a = Archive()
    ..addFile(ArchiveFile.bytes('files/icon.png', [1, 2, 3]))
    ..addFile(ArchiveFile.bytes(name, utf8.encode(kml)));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

/// A wiggly trail: [n] points heading north-east with small noise.
List<GeoPoint> wiggle(int n, {double noiseM = 3, int seed = 1}) {
  final r = Random(seed);
  return [
    for (var i = 0; i < n; i++)
      GeoPoint(
        47.0 + i * 0.0001 + (r.nextDouble() - 0.5) * noiseM / 111000,
        -121.0 + i * 0.0001 + (r.nextDouble() - 0.5) * noiseM / 75000,
      ),
  ];
}

/// Minimal valid PNG header (IHDR) for a w x h image.
Uint8List pngHeader(int w, int h) {
  final b = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add([0, 0, 0, 13])
    ..add(ascii.encode('IHDR'));
  final d = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  b
    ..add(d.buffer.asUint8List())
    ..add([0, 0, 0, 0]);
  return b.takeBytes();
}

void main() {
  group('GPX', () {
    test('AllTrails: name, track segments, waypoints, bad points skipped', () {
      final d = parseGpx(allTrailsGpx);
      expect(d.name, 'Mount Si Trail');
      expect(d.lines, hasLength(2));
      expect(d.lines.first.points, hasLength(4));
      expect(d.lines.first.points.first, const GeoPoint(47.488, -121.723));
      expect(d.lines.first.isRoute, isFalse);
      expect(d.waypoints.map((w) => w.name), ['Trailhead', 'Haystack']);
      expect(d.waypoints.first.description, 'Parking');
      expect(d.pointCount, 8);
    });

    test('Gaia GPX 1.0: route + track, colour extension', () {
      final d = parseGpx(gaiaGpx);
      expect(d.name, 'Enchantments');
      expect(d.lines.where((l) => l.isRoute).single.points, hasLength(3));
      expect(d.lines.where((l) => !l.isRoute).single.name, 'Day 1');
      expect(d.color, 0xFFFF8800);
    });

    test('file name is the fallback name; empty and broken files fail', () {
      final d = parseTrailFile(
        '/sdcard/Download/My Hike.gpx',
        utf8.encode(
          '<gpx><trk><trkseg><trkpt lat="1" lon="2"/><trkpt lat="1.1" lon="2"/></trkseg></trk></gpx>',
        ),
      );
      expect(d.name, 'My Hike');
      expect(
        () => parseTrailFile('x.gpx', utf8.encode('<gpx></gpx>')),
        throwsA(isA<ImportFormatException>()),
      );
      expect(
        () => parseTrailFile('x.gpx', utf8.encode('<gpx><trk>')),
        throwsA(isA<ImportFormatException>()),
      );
      expect(
        () => parseTrailFile('x.txt', utf8.encode('hello')),
        throwsA(isA<ImportFormatException>()),
      );
    });
  });

  group('KML / KMZ', () {
    test(
      'Google My Maps: lines, polygon outline, gx:Track, points, colour',
      () {
        final d = parseKml(myMapsKml);
        expect(d.name, 'Camping weekend');
        expect(d.lines.map((l) => l.name), [
          'Loop',
          'Lake outline',
          'Recorded',
        ]);
        expect(d.lines[0].points, hasLength(3));
        expect(d.lines[0].points[1], const GeoPoint(37.01, -122.01));
        expect(d.lines[1].points, hasLength(4));
        expect(d.lines[2].points.last, const GeoPoint(37.21, -122.21));
        expect(d.waypoints.map((w) => w.name), ['Camp', 'Water']);
        expect(d.waypoints.first.description, 'Site 12');
        // KML aabbggrr ffd18802 -> ARGB ff0288d1.
        expect(d.color, 0xFF0288D1);
      },
    );

    test('KMZ: doc.kml inside a zip (with other files)', () {
      final bytes = kmz(myMapsKml);
      expect(sniffImport('trip.kmz', bytes.take(64).toList()), ImportKind.kmz);
      final d = parseTrailFile('trip.kmz', bytes);
      expect(d.lines, hasLength(3));
      expect(d.waypoints, hasLength(2));
      // Any .kml when there is no doc.kml.
      expect(parseKmz(kmz(myMapsKml, name: 'other.kml')).lines, hasLength(3));
      expect(
        () => parseKmz(Uint8List.fromList([0x50, 0x4B, 3, 4, 0, 0])),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('sniffing by content beats the file name', () {
      List<int> h(String s) => utf8.encode(s);
      expect(sniffImport('a.xml', h('<?xml?><gpx>')), ImportKind.gpx);
      expect(sniffImport('download', h('<?xml?><kml>')), ImportKind.kml);
      expect(sniffImport('x', h('SQLite format 3\u0000')), ImportKind.mbtiles);
      expect(sniffImport('x', h('%PDF-1.7')), ImportKind.pdf);
      expect(sniffImport('x', pngHeader(4, 4)), ImportKind.image);
      expect(
        sniffImport('map.JPG', [0xFF, 0xD8, 0xFF, 0xE0]),
        ImportKind.image,
      );
      expect(sniffImport('x.mbtiles', const []), ImportKind.mbtiles);
      expect(sniffImport('notes.txt', h('hi')), isNull);
    });
  });

  group('simplification', () {
    test('tidyImport drops GPS jitter (2 m) and caps total points', () {
      final d = ImportedData(
        name: 't',
        lines: [ImportedLine('a', wiggle(3000, noiseM: 1))],
      );
      final before = pathLengthM(d.lines.first.points);
      tidyImport(d);
      expect(d.lines.first.points.length, lessThan(3000));
      expect(pathLengthM(d.lines.first.points), closeTo(before, before * 0.05));
      final big = ImportedData(
        lines: [
          for (var i = 0; i < 3; i++)
            ImportedLine('$i', wiggle(10000, noiseM: 40, seed: i)),
        ],
      );
      tidyImport(big);
      expect(
        big.lines.fold<int>(0, (s, l) => s + l.points.length),
        lessThanOrEqualTo(maxImportPoints),
      );
    });

    test('Douglas-Peucker keeps corners and ends, thinTo caps', () {
      final l = [
        const GeoPoint(0, 0),
        const GeoPoint(0, 0.001),
        const GeoPoint(0, 0.002),
        const GeoPoint(0.002, 0.002), // corner
        const GeoPoint(0.004, 0.002),
      ];
      final s = simplify<GeoPoint>(l, (p) => p, 5);
      expect(s, [l[0], l[2], l[4]]);
      final t = thinTo<GeoPoint>(wiggle(500, noiseM: 30), (p) => p, 16);
      expect(t.length, lessThanOrEqualTo(16));
    });

    test('max deviation of a thinned line', () {
      final line = [
        const GeoPoint(0, 0),
        const GeoPoint(0.001, 0.0005), // ~55 m off the straight line
        const GeoPoint(0.002, 0),
      ];
      final thin = [line.first, line.last];
      expect(maxDeviationM(line, thin), closeTo(55.6, 1));
      expect(maxDeviationM(line, line), 0);
    });

    test(
      'LoRa: a simple route goes as <= 16 points, a twisty one not at all',
      () {
        final simple = ImportedData(
          lines: [
            ImportedLine('short', wiggle(80, noiseM: 4)),
            ImportedLine('main', wiggle(400, noiseM: 6)),
          ],
        );
        final m = routeRadioSummary(simple, 77, 5)!;
        expect(m.summary, isTrue);
        expect(m.trackId, 77);
        expect(m.points.length, lessThanOrEqualTo(radioRoutePoints));
        expect(m.points.length, greaterThanOrEqualTo(2));
        expect(m.encode().length, lessThan(100));
        // Longest line chosen: ends match "main".
        expect(m.points.last.pos.latE5, simple.lines[1].points.last.latE5);

        // A switchback trail: 60 hairpins 400 m wide.
        final twisty = [
          for (var i = 0; i < 120; i++)
            GeoPoint(47 + i * 0.0003, -121 + (i.isEven ? 0 : 0.005)),
        ];
        expect(
          routeRadioSummary(
            ImportedData(lines: [ImportedLine('z', twisty)]),
            1,
            1,
          ),
          isNull,
        );
        expect(routeRadioSummary(ImportedData(), 1, 1), isNull);
      },
    );
  });

  group('sharing a route (fast links, compressed)', () {
    test('round trip, compressed well under raw size, parts fit a frame', () {
      final d = ImportedData(
        name: 'Loop trail',
        lines: [
          ImportedLine('Main', wiggle(2000, noiseM: 8)),
          ImportedLine('Spur', wiggle(50, seed: 3), isRoute: true),
        ],
        waypoints: [
          ImportedWaypoint('Camp', const GeoPoint(47.01, -121.01)),
          ImportedWaypoint('Water ünïcode', const GeoPoint(47.02, -121.02)),
        ],
      );
      var id = 100;
      final parts = routeMessages(d, 0x1234, () => id++, color: 0xFFE53935)!;
      expect(parts, isNotEmpty);
      final raw = d.lines.fold<int>(0, (s, l) => s + l.points.length) * 8;
      final sent = parts.fold<int>(0, (s, m) => s + m.data.length);
      expect(sent, lessThan(raw ~/ 2), reason: 'delta + zlib');
      for (final m in parts) {
        expect(m.encode().length, lessThanOrEqualTo(RouteMsg.partBytes + 8));
        final back = TripMsg.tryDecode(m.encode()) as RouteMsg;
        expect(back.routeId, 0x1234);
        expect(back.count, parts.length);
      }
      // Arrive out of order, with a duplicate.
      final a = RouteAssembler();
      final order = [...parts.reversed, parts.first];
      ({ImportedData data, int color})? got;
      for (final m in order) {
        got ??= a.add(9, TripMsg.tryDecode(m.encode()) as RouteMsg);
      }
      expect(got, isNotNull);
      expect(got!.color, 0xFFE53935);
      expect(got.data.name, 'Loop trail');
      expect(got.data.lines.map((l) => l.name), ['Main', 'Spur']);
      expect(got.data.lines[1].isRoute, isTrue);
      expect(got.data.waypoints.map((w) => w.name), ['Camp', 'Water ünïcode']);
      // Shape kept within a few metres (3 m simplification, 1e-5 grid).
      expect(
        maxDeviationM(d.lines[0].points, got.data.lines[0].points),
        lessThan(5),
      );
      expect(a.pending, 0);
    });

    test('damaged data is rejected; huge shares are thinned to fit', () {
      expect(decodeRouteBlob([1, 2, 3]), isNull);
      final big = ImportedData(
        lines: [
          for (var i = 0; i < 4; i++)
            ImportedLine('$i', wiggle(20000, noiseM: 60, seed: i)),
        ],
      );
      final parts = routeMessages(big, 1, () => 1)!;
      expect(parts.length, lessThanOrEqualTo(255));
      final a = RouteAssembler();
      ({ImportedData data, int color})? got;
      for (final m in parts) {
        got ??= a.add(1, m);
      }
      expect(
        got!.data.lines.fold<int>(0, (s, l) => s + l.points.length),
        lessThanOrEqualTo(maxSharePoints + 8),
      );
    });

    test('route parts never go over the radio', () {
      final m = RouteMsg(
        1,
        routeId: 2,
        index: 0,
        count: 1,
        data: Uint8List(10),
      );
      expect(m.encode()[0] & 0xF, 9);
      expect(TripKind.route.code, 9);
    });
  });

  group('georeference', () {
    const center = GeoPoint(37.7459, -119.5332); // Yosemite Valley

    test('Mercator round trip', () {
      for (final p in [
        center,
        const GeoPoint(0, 0),
        const GeoPoint(-33.9, 151.2),
        const GeoPoint(64.1, -21.9),
      ]) {
        final (x, y) = toMercator(p);
        final q = fromMercator(x, y);
        expect(q.lat, closeTo(p.lat, 1e-9));
        expect(q.lng, closeTo(p.lng, 1e-9));
      }
    });

    test('corner fit: centre, size, rotation, corners', () {
      final g = Georef.fit(
        center: center,
        widthM: 2000,
        rotationDeg: 0,
        w: 1000,
        h: 500,
      );
      final c = g.toMap((u: 500, v: 250));
      expect(distanceM(c, center), lessThan(0.01));
      final k = g.corners(1000, 500);
      // Exact across the middle; edges differ by the map scale change
      // over 500 m (about 0.1 %).
      expect(
        distanceM(g.toMap((u: 0, v: 250)), g.toMap((u: 1000, v: 250))),
        closeTo(2000, 0.5),
      );
      expect(distanceM(k.topLeft, k.topRight), closeTo(2000, 4));
      expect(distanceM(k.topLeft, k.bottomLeft), closeTo(1000, 1));
      expect(k.topLeft.lat, greaterThan(k.bottomLeft.lat), reason: 'north up');
      expect(k.topRight.lng, greaterThan(k.topLeft.lng));
      expect(g.metresPerPixel(center), closeTo(2, 0.01));
      expect(g.rotationDeg, closeTo(0, 1e-9));

      final r = Georef.fit(
        center: center,
        widthM: 2000,
        rotationDeg: 90,
        w: 1000,
        h: 500,
      );
      final rk = r.corners(1000, 500);
      // Turned 90° clockwise: the image's top edge now runs north-south on
      // the east side, top-left corner is the north-east one.
      expect(bearingDeg(rk.topLeft, rk.topRight), closeTo(180, 0.5));
      expect(r.rotationDeg, closeTo(90, 1e-6));
      expect(distanceM(r.toMap((u: 500, v: 250)), center), lessThan(0.01));
    });

    test('2 control points: exact at both, shape kept', () {
      // Make "truth" with a rotated, scaled fit, then recover it.
      final truth = Georef.fit(
        center: center,
        widthM: 3500,
        rotationDeg: 17,
        w: 2400,
        h: 1800,
      );
      const a = (u: 300.0, v: 200.0), b = (u: 2100.0, v: 1500.0);
      final g = Georef.fromTwo(
        ControlPoint(a, truth.toMap(a)),
        ControlPoint(b, truth.toMap(b)),
      )!;
      for (final p in [a, b, (u: 0.0, v: 0.0), (u: 2400.0, v: 1800.0)]) {
        expect(distanceM(g.toMap(p), truth.toMap(p)), lessThan(0.05));
      }
      expect(g.rotationDeg, closeTo(17, 1e-6));
      // Inverse.
      final back = g.toImage(truth.toMap((u: 1234, v: 567)))!;
      expect(back.u, closeTo(1234, 1e-3));
      expect(back.v, closeTo(567, 1e-3));
      // Same pixel twice is not a fit.
      expect(
        Georef.fromTwo(
          ControlPoint(a, center),
          ControlPoint(a, const GeoPoint(37.75, -119.53)),
        ),
        isNull,
      );
    });

    test('3 control points: affine fits a stretched scan exactly', () {
      // Map drawn 1.5x stretched east-west, slightly skewed.
      const tl = GeoPoint(37.76, -119.56);
      GeoPoint at(double u, double v) =>
          GeoPoint(tl.lat - v * 0.00001, tl.lng + u * 0.000015 + v * 0.000002);
      const p1 = (u: 100.0, v: 100.0);
      const p2 = (u: 1800.0, v: 150.0);
      const p3 = (u: 900.0, v: 1300.0);
      final g = Georef.fromControlPoints([
        ControlPoint(p1, at(p1.u, p1.v)),
        ControlPoint(p2, at(p2.u, p2.v)),
        ControlPoint(p3, at(p3.u, p3.v)),
      ])!;
      for (final p in [p1, p2, p3]) {
        expect(distanceM(g.toMap(p), at(p.u, p.v)), lessThan(0.01));
      }
      // Elsewhere close too (Mercator is near-linear over a few km).
      expect(
        distanceM(g.toMap((u: 1500, v: 1000)), at(1500, 1000)),
        lessThan(2),
      );
      final k = g.corners(2000, 1400);
      expect(distanceM(k.bottomRight, at(2000, 1400)), lessThan(2));
      // In a line: no fit.
      expect(
        Georef.fromThree(
          ControlPoint((u: 0, v: 0), at(0, 0)),
          ControlPoint((u: 10, v: 10), at(10, 10)),
          ControlPoint((u: 20, v: 20), at(20, 20)),
        ),
        isNull,
      );
      expect(Georef.fromControlPoints([ControlPoint(p1, tl)]), isNull);
    });

    test('saved and loaded', () {
      final g = Georef.fit(
        center: center,
        widthM: 900,
        rotationDeg: -30,
        w: 800,
        h: 600,
      );
      final h = Georef.fromJson(jsonDecode(jsonEncode(g.toJson())))!;
      expect(distanceM(h.toMap((u: 10, v: 20)), g.toMap((u: 10, v: 20))), 0);
      expect(
        Georef.fromJson({
          'm': [0, 0, 0, 0, 0, 0],
        }),
        isNull,
      );
      expect(Georef.fromJson('x'), isNull);
    });
  });

  group('image headers', () {
    test('PNG, JPEG and WebP sizes without decoding', () {
      expect(imageSize(pngHeader(1234, 567)), (w: 1234, h: 567));
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xE0, 0, 4, 0, 0, // APP0 (len 4)
        0xFF, 0xC0, 0, 11, 8, 0x01, 0xF4, 0x03, 0x20, 3, 0, 0, 0, // SOF0
      ]);
      expect(imageSize(jpeg), (w: 800, h: 500));
      final webp = BytesBuilder()
        ..add(ascii.encode('RIFF'))
        ..add([0, 0, 0, 0])
        ..add(ascii.encode('WEBPVP8X'))
        ..add([10, 0, 0, 0, 0, 0, 0, 0])
        ..add([0xFF, 0x03, 0x00, 0x7F, 0x02, 0x00]) // 1024 x 640
        ..add(List.filled(8, 0));
      expect(imageSize(webp.takeBytes()), (w: 1024, h: 640));
      expect(imageSize(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('MBTiles reader', () {
    final haveSqlite = useHostSqlite();
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('mbt'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String make({String format = 'png', bool meta = true}) {
      final path = '${tmp.path}/t.mbtiles';
      final db = sqlite3.open(path);
      db.execute(
        'CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, '
        'tile_row INTEGER, tile_data BLOB)',
      );
      db.execute('CREATE TABLE metadata (name TEXT, value TEXT)');
      if (meta) {
        for (final kv in {
          'name': 'Yosemite topo',
          'format': format,
          'minzoom': '10',
          'maxzoom': '12',
          'bounds': '-119.7,37.6,-119.4,37.9',
          'center': '-119.55,37.75,11',
          'attribution': '© USGS',
        }.entries) {
          db.execute('INSERT INTO metadata VALUES (?, ?)', [kv.key, kv.value]);
        }
      }
      // XYZ tile z=12 x=683 y=1580 -> TMS row 4095-1580 = 2515.
      db.execute('INSERT INTO tiles VALUES (12, 683, 2515, ?)', [
        Uint8List.fromList([1, 2, 3]),
      ]);
      db.execute('INSERT INTO tiles VALUES (10, 170, 628, ?)', [
        Uint8List.fromList([9]),
      ]);
      db.dispose();
      return path;
    }

    test('metadata, TMS row flip, missing tiles', () {
      final mb = MbTiles.open(make());
      expect(mb.name, 'Yosemite topo');
      expect(mb.format, 'png');
      expect(mb.minZoom, 10);
      expect(mb.maxZoom, 12);
      expect(mb.attribution, '© USGS');
      expect(mb.bounds!.west, -119.7);
      expect(mb.bounds!.north, 37.9);
      expect(mb.center, (37.75, -119.55, 11));
      expect(mb.tileCount, 2);
      expect(mb.tile(12, 683, 1580), [1, 2, 3]);
      expect(mb.tile(10, 170, 1023 - 628), [9]);
      expect(mb.tile(12, 683, 2515), isNull, reason: 'XYZ, not TMS, asked');
      expect(mb.tile(5, 0, 0), isNull);
      mb.close();
      expect(mb.tile(12, 683, 1580), isNull);
    }, skip: haveSqlite ? false : 'no SQLite library on this machine');

    test('zoom range from tiles when metadata lacks it; vector refused', () {
      final p = make(meta: false);
      final mb = MbTiles.open(p);
      expect((mb.minZoom, mb.maxZoom), (10, 12));
      mb.close();
      File(p).deleteSync();
      expect(() => MbTiles.open(make(format: 'pbf')), throwsFormatException);
      final junk = File('${tmp.path}/junk.mbtiles')..writeAsStringSync('no');
      expect(() => MbTiles.open(junk.path), throwsA(anything));
    }, skip: haveSqlite ? false : 'no SQLite library on this machine');

    test('layer store: import, base map lookup, sizes, delete', () async {
      final layers = MapLayers(Directory('${tmp.path}/layers'));
      final l = await layers.importMbtiles(File(make()));
      expect(l.kind, MapLayerKind.tiles);
      expect(l.name, 'Yosemite topo');
      expect(l.summary, contains('2 tiles'));
      expect(layers.usedBytes, l.bytes);
      expect(layers.tilesOf(l.id)!.tile(12, 683, 1580), [1, 2, 3]);
      final again = MapLayers(Directory('${tmp.path}/layers'));
      await again.load();
      expect(again.tileSets.single.id, l.id);
      expect(again.tilesOf(l.id)!.tileCount, 2);
      again.close();
      await layers.delete(l);
      expect(layers.all, isEmpty);
      expect(File('${tmp.path}/layers/${l.file}').existsSync(), isFalse);
      layers.close();
    }, skip: haveSqlite ? false : 'no SQLite library on this machine');
  });

  group('layer store', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('layers'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('trail import: toggle, rename, recolour, persist, delete', () async {
      final layers = MapLayers(Directory('${tmp.path}/l'));
      final l = await layers.importTrail('si.gpx', utf8.encode(allTrailsGpx));
      expect(l.name, 'Mount Si Trail');
      expect(l.summary, startsWith('2 tracks · 2 waypoints · '));
      expect(l.data!.lines, hasLength(2));
      await layers.setVisible(l, false);
      await layers.rename(l, '  Si  ');
      await layers.rename(l, '   '); // ignored
      await layers.recolor(l, layerColors[2]);
      final k = await layers.importTrail('trip.kmz', kmz(myMapsKml));
      expect(k.color, 0xFF0288D1, reason: 'colour from the file');

      final again = MapLayers(Directory('${tmp.path}/l'));
      await again.load();
      final a = again.byId(l.id)!;
      expect(a.name, 'Si');
      expect(a.visible, isFalse);
      expect(a.color, layerColors[2]);
      expect(
        a.data!.lines.first.points.first,
        const GeoPoint(47.488, -121.723),
      );
      expect(a.data!.waypoints.first.description, 'Parking');
      expect(again.trails.map((x) => x.id), [
        k.id,
        l.id,
      ], reason: 'newest first');
      expect(again.usedBytes, l.bytes + k.bytes);
      await again.delete(a);
      expect(again.trails.single.id, k.id);
      expect(Directory('${tmp.path}/l').listSync().length, 2);
    });

    test('storage limit and size caps', () async {
      final layers = MapLayers(Directory('${tmp.path}/l'), limitBytes: 2000);
      await layers.importTrail('si.gpx', utf8.encode(allTrailsGpx));
      final big = ImportedData(lines: [ImportedLine('x', wiggle(500))]);
      expect(() => layers.addTrail(big), throwsA(isA<StorageLimitException>()));
      expect(
        () => layers.importTrail('huge.gpx', Uint8List(maxTrailFileBytes + 1)),
        throwsA(isA<ImportFormatException>()),
      );
      expect(formatBytes(1536), '2 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(layers.freeBytes, 2000 - layers.usedBytes);
    });

    test('overlay: size from header, place, opacity, persist', () async {
      final layers = MapLayers(Directory('${tmp.path}/l'));
      final o = await layers.importOverlay('Park map', pngHeader(1600, 1200));
      expect((o.imageW, o.imageH), (1600, 1200));
      expect(o.placed, isFalse);
      await layers.setVisible(o, false);
      final g = Georef.fit(
        center: const GeoPoint(37.74, -119.57),
        widthM: 4000,
        rotationDeg: 10,
        w: 1600,
        h: 1200,
      );
      await layers.setGeoref(o, g);
      expect(o.visible, isTrue, reason: 'placing shows it');
      await layers.setOpacity(o, 5);
      expect(o.opacity, 1.0);
      await layers.setOpacity(o, 0.4);
      final again = MapLayers(Directory('${tmp.path}/l'));
      await again.load();
      final a = again.overlays.single;
      expect(a.opacity, 0.4);
      expect(
        distanceM(a.georef!.toMap((u: 0, v: 0)), g.toMap((u: 0, v: 0))),
        lessThan(0.001),
      );
      expect(
        () => layers.importOverlay('x', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<ImportFormatException>()),
      );
    });

    test('a corrupt index or a missing file is skipped', () async {
      final d = Directory('${tmp.path}/l')..createSync();
      File('${d.path}/layers.json').writeAsStringSync(
        jsonEncode([
          {'id': 'a', 'k': 'trail', 'f': 'gone.json'},
          {'id': 'b', 'k': 'trail', 'f': '../escape.json'},
          'junk',
        ]),
      );
      final layers = MapLayers(d);
      await layers.load();
      expect(layers.all, isEmpty);
    });
  });

  group('sharing an imported route between phones', () {
    late Directory tmp;
    late FakeClock clock;
    late FakeHost ha, hb;
    late TripController a, b;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('share');
      clock = FakeClock();
      TripController make(FakeHost h, String n) => TripController(
        host: h,
        settings: TripSettings(),
        dir: Directory('${tmp.path}/$n'),
        userAgent: 'test',
        clock: clock.call,
      )..tiles.online = false;
      ha = FakeHost(0xA);
      hb = FakeHost(0xB);
      a = make(ha, 'a');
      b = make(hb, 'b');
      await a.start();
      await b.start();
    });
    tearDown(() async {
      a.dispose();
      b.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('fast phones get the whole route as a layer; radio gets 16 points', () async {
      final l = await a.layers.importTrail(
        'loop.gpx',
        utf8.encode(
          '<gpx><metadata><name>Loop</name></metadata>'
          '<wpt lat="47.0005" lon="-121.0005"><name>Camp</name></wpt>'
          '<trk><trkseg>${[for (final p in wiggle(600)) '<trkpt lat="${p.lat}" lon="${p.lng}"/>'].join()}</trkseg></trk></gpx>',
        ),
      );
      await a.layers.recolor(l, layerColors[3]);
      final r = a.shareLayer(l);
      expect(r.parts, greaterThan(0));
      expect(r.radio, isTrue);
      final fast = ha.sent.where((s) => s.msg is RouteMsg).toList();
      expect(fast, hasLength(r.parts));
      expect(fast.every((s) => s.route.fast && !s.route.radio), isTrue);
      final radio = ha.sent.where((s) => s.route.radio).single;
      expect(radio.route.fast, isFalse);
      expect((radio.msg as TrackMsg).summary, isTrue);
      expect((radio.msg as TrackMsg).points.length, lessThanOrEqualTo(16));
      expect(radio.msg.encode().length, lessThan(100));

      // Radio copy first (it's what a far phone sees), then the full one.
      b.onTrip(trip(0xA, radio.msg, via: TransportKind.lora));
      final key = '${0xA}:${(radio.msg as TrackMsg).trackId}';
      expect(b.sharedTracks[key]!.summary, isTrue);
      for (final s in fast) {
        b.onTrip(trip(0xA, s.msg));
      }
      final got = await b.lastSharedRoute!;
      expect(got.name, 'Loop');
      expect(got.from, 0xA);
      expect(got.color, layerColors[3]);
      expect(got.data!.waypoints.single.name, 'Camp');
      expect(b.layers.trails.single.id, got.id);
      expect(b.sharedTracks.containsKey(key), isFalse, reason: 'replaced');
      await flush();
      expect(b.feed.first.text, contains('shared a route: Loop'));
    });

    test('a twisty route is not sent over the radio at all', () async {
      final l = await a.layers.addTrail(
        ImportedData(
          name: 'Switchbacks',
          lines: [
            ImportedLine('z', [
              for (var i = 0; i < 120; i++)
                GeoPoint(47 + i * 0.0003, -121 + (i.isEven ? 0 : 0.005)),
            ]),
          ],
        ),
      );
      final r = a.shareLayer(l);
      expect(r.radio, isFalse);
      expect(ha.sent.where((s) => s.route.radio), isEmpty);
      expect(ha.sent.length, r.parts);
    });

    test('the manager never puts a route part on LoRa', () async {
      final radio = FakeRadio();
      final ble = FakeTransport(TransportKind.ble);
      final lora = LoraTransport(
        radio: radio,
        clock: clock.call,
        limiter: LoraRateLimiter(burst: 100, clock: clock.call),
        pumpInterval: const Duration(hours: 1),
      );
      final m = TransportManager(
        transports: [ble, lora],
        localNodeId: 0xA,
        localName: 'A',
        clock: clock.call,
        helloInterval: const Duration(hours: 1),
      );
      await m.start();
      ble.deliver(hello(0xB, 1));
      radio.hear(hello(0xC, 1).encode(), 0xC0C0);
      await flush();
      radio.sent.clear();
      final part = RouteMsg(
        1,
        routeId: 1,
        index: 0,
        count: 1,
        data: Uint8List(300),
      );
      await m.sendTrip(part.encode(), radio: true, flood: true);
      await m.sendTrip(part.encode(), to: 0xC, radio: true);
      await flush();
      expect(radio.trips, isEmpty);
      expect(ble.sent, isNotEmpty);
      await m.dispose();
    });
  });

  testWidgets('layers page lists layers with sizes, toggles and storage', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('ui');
    final t = TripController(
      host: FakeHost(1),
      settings: TripSettings(),
      dir: tmp,
      userAgent: 'test',
    )..tiles.online = false;
    late MapLayer l;
    await tester.runAsync(() async {
      await t.layers.load();
      l = await t.layers.importTrail('si.gpx', utf8.encode(allTrailsGpx));
      await t.layers.importOverlay('Valley map', pngHeader(800, 600));
    });
    await tester.pumpWidget(MaterialApp(home: MapLayersPage(trip: t)));
    expect(find.text('Mount Si Trail'), findsOneWidget);
    expect(find.text('Valley map'), findsOneWidget);
    expect(find.textContaining('not placed yet'), findsOneWidget);
    expect(find.textContaining('of 2.00 GB'), findsOneWidget);
    expect(find.text('Trails, routes and waypoints'), findsOneWidget);
    expect(find.text('Park map overlays'), findsOneWidget);
    expect(l.visible, isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.byType(Switch).first);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(l.visible, isFalse);
    t.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('track summaries still decode next to route parts', () {
    final t = Track(5, points: [for (final p in wiggle(100)) TrackPt(p, 1000)]);
    final s = trackSummary(t, 1);
    expect((TripMsg.tryDecode(s.encode()) as TrackMsg).summary, isTrue);
  });
}
