import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math';
import 'dart:typed_data';

import '../geo.dart';
import '../trip_packet.dart';
import 'geo_import.dart';

/// Sharing an imported route / trail file with the group (v1.8.3).
///
/// Fast links: the lines and waypoints, delta + varint coded and zlib
/// compressed, split into [RouteMsg] parts. LoRa: one thinned
/// (Douglas-Peucker) [TrackMsg] summary of the longest line, only if a
/// handful of points still follow it closely; otherwise nothing.

/// Points kept for a share (after a 3 m simplification).
const int maxSharePoints = 6000;
const int maxShareWaypoints = 200;

/// LoRa summary: at most this many points, and only if the thinned line
/// stays within [radioMaxErrorM] of the real one.
const int radioRoutePoints = 16;
const double radioMaxErrorM = 150;

const int _blobVersion = 1;

/// Compressed blob for [d] (name, colour, lines, waypoints).
Uint8List encodeRouteBlob(ImportedData d, {int color = 0xFF1E88E5}) {
  final lines = [
    for (final l in d.lines)
      if (l.points.length > 1) (l, simplify<GeoPoint>(l.points, (p) => p, 3)),
  ];
  final total = lines.fold<int>(0, (s, e) => s + e.$2.length);
  final out = BytesBuilder(copy: false);
  void varint(int v) {
    var x = v;
    while (x >= 0x80) {
      out.addByte((x & 0x7F) | 0x80);
      x >>= 7;
    }
    out.addByte(x);
  }

  void zz(int v) => varint(v >= 0 ? v << 1 : ((-v) << 1) - 1);
  void str(String s, int max) {
    var b = utf8.encode(s);
    if (b.length > max) {
      var cut = max;
      while (cut > 0 && (b[cut] & 0xC0) == 0x80) {
        cut--;
      }
      b = b.sublist(0, cut);
    }
    varint(b.length);
    out.add(b);
  }

  out.addByte(_blobVersion);
  str(d.name, 60);
  varint(color & 0xFFFFFFFF);
  varint(lines.length.clamp(0, 255));
  for (final (l, pts0) in lines.take(255)) {
    final n = total > maxSharePoints
        ? (pts0.length * maxSharePoints / total).floor().clamp(2, pts0.length)
        : pts0.length;
    final pts = n < pts0.length ? thinTo<GeoPoint>(pts0, (p) => p, n) : pts0;
    str(l.name, 40);
    out.addByte(l.isRoute ? 1 : 0);
    varint(pts.length);
    var lat = 0, lng = 0;
    for (final p in pts) {
      zz(p.latE5 - lat);
      zz(p.lngE5 - lng);
      lat = p.latE5;
      lng = p.lngE5;
    }
  }
  final w = d.waypoints.take(maxShareWaypoints).toList();
  varint(w.length);
  for (final p in w) {
    str(p.name, 40);
    zz(p.pos.latE5);
    zz(p.pos.lngE5);
  }
  return Uint8List.fromList(zlib.encode(out.takeBytes()));
}

/// Decode a blob made by [encodeRouteBlob]; null if damaged.
({ImportedData data, int color})? decodeRouteBlob(List<int> blob) {
  try {
    final b = zlib.decode(blob);
    var o = 0;
    int u8() => b[o++];
    int varint() {
      var v = 0, shift = 0;
      while (true) {
        final x = b[o++];
        v |= (x & 0x7F) << shift;
        if (x & 0x80 == 0) return v;
        shift += 7;
        if (shift > 35) throw const FormatException('varint');
      }
    }

    int zz() {
      final v = varint();
      return v & 1 == 0 ? v >> 1 : -((v + 1) >> 1);
    }

    String str() {
      final n = varint();
      final s = utf8.decode(b.sublist(o, o + n), allowMalformed: true);
      o += n;
      return s;
    }

    if (u8() != _blobVersion) return null;
    final d = ImportedData(name: str());
    final color = varint();
    final nl = varint();
    for (var i = 0; i < nl; i++) {
      final name = str();
      final route = u8() == 1;
      final n = varint();
      if (n > maxSharePoints * 2) return null;
      var lat = 0, lng = 0;
      final pts = <GeoPoint>[];
      for (var k = 0; k < n; k++) {
        lat += zz();
        lng += zz();
        final p = GeoPoint.fromE5(lat, lng);
        if (!p.valid) return null;
        pts.add(p);
      }
      d.lines.add(ImportedLine(name, pts, isRoute: route));
    }
    final nw = varint();
    for (var i = 0; i < nw && i < maxShareWaypoints; i++) {
      final name = str();
      final p = GeoPoint.fromE5(zz(), zz());
      if (!p.valid) return null;
      d.waypoints.add(ImportedWaypoint(name, p));
    }
    return (data: d, color: color);
  } catch (_) {
    return null;
  }
}

/// Split [d] into fast-link messages (null if it would need over 255).
List<RouteMsg>? routeMessages(
  ImportedData d,
  int routeId,
  int Function() nextId, {
  int color = 0xFF1E88E5,
}) {
  final blob = encodeRouteBlob(d, color: color);
  final n = (blob.length + RouteMsg.partBytes - 1) ~/ RouteMsg.partBytes;
  if (n == 0 || n > 255) return null;
  return [
    for (var i = 0; i < n; i++)
      RouteMsg(
        nextId(),
        routeId: routeId & 0xFFFF,
        index: i,
        count: n,
        data: Uint8List.sublistView(
          blob,
          i * RouteMsg.partBytes,
          ((i + 1) * RouteMsg.partBytes).clamp(0, blob.length),
        ),
      ),
  ];
}

/// Largest distance (m) from any point of [line] to the polyline [thin].
double maxDeviationM(List<GeoPoint> line, List<GeoPoint> thin) {
  if (thin.length < 2) return double.infinity;
  var worst = 0.0;
  for (final p in line) {
    var best = double.infinity;
    for (var i = 1; i < thin.length; i++) {
      final d = _segDistM(p, thin[i - 1], thin[i]);
      if (d < best) best = d;
    }
    if (best > worst) worst = best;
  }
  return worst;
}

double _segDistM(GeoPoint p, GeoPoint a, GeoPoint b) {
  // Local flat projection around a.
  const k = earthRadiusM * pi / 180;
  final kx = k * cos(a.lat * pi / 180);
  final px = (p.lng - a.lng) * kx, py = (p.lat - a.lat) * k;
  final bx = (b.lng - a.lng) * kx, by = (b.lat - a.lat) * k;
  final len2 = bx * bx + by * by;
  final t = len2 == 0 ? 0.0 : ((px * bx + py * by) / len2).clamp(0.0, 1.0);
  final dx = px - t * bx, dy = py - t * by;
  return sqrt(dx * dx + dy * dy);
}

/// LoRa: one thinned summary of the longest line, or null if the line
/// can't be told in [radioRoutePoints] points within [radioMaxErrorM].
TrackMsg? routeRadioSummary(ImportedData d, int routeId, int id) {
  ImportedLine? longest;
  var best = -1.0;
  for (final l in d.lines) {
    final len = pathLengthM(l.points);
    if (len > best) {
      best = len;
      longest = l;
    }
  }
  if (longest == null || longest.points.length < 2) return null;
  final thin = thinTo<GeoPoint>(longest.points, (p) => p, radioRoutePoints);
  if (maxDeviationM(longest.points, thin) > radioMaxErrorM) return null;
  final pts = [for (final p in thin) TrackPt(p)];
  final chunks = TrackMsg.chunk(pts, max: radioRoutePoints);
  if (chunks.length != 1) return null; // a jump too long for 16 bit deltas
  return TrackMsg(
    id,
    trackId: routeId & 0xFFFF,
    index: 0,
    count: 1,
    summary: true,
    points: chunks.first,
  );
}

/// Joins [RouteMsg] parts from other phones.
class RouteAssembler {
  final Map<String, Map<int, Uint8List>> _parts = {};
  final Map<String, DateTime> _started = {};

  /// Returns the route once all parts are in (then forgets the parts).
  ({ImportedData data, int color})? add(
    int origin,
    RouteMsg m, {
    DateTime? now,
  }) {
    final key = '$origin:${m.routeId}:${m.count}';
    final t = now ?? DateTime.now();
    _started.removeWhere((k, s) {
      final old = t.difference(s).inMinutes > 30;
      if (old) _parts.remove(k);
      return old;
    });
    final parts = _parts.putIfAbsent(key, () => {});
    _started.putIfAbsent(key, () => t);
    parts[m.index] = m.data;
    if (parts.length < m.count) return null;
    _parts.remove(key);
    _started.remove(key);
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < m.count; i++) {
      final p = parts[i];
      if (p == null) return null;
      b.add(p);
    }
    return decodeRouteBlob(b.takeBytes());
  }

  int get pending => _parts.length;
}
