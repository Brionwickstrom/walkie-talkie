import 'dart:convert';
import 'dart:typed_data';

import 'geo.dart';

/// Tiny binary Trip messages (v1.8.0), the payload of a
/// `FrameType.trip` frame. Built to fit a LoRa packet with room to spare:
/// a location is 14 bytes (up to 17 with battery, speed and heading), an SOS 16, a canned message 6.
///
/// Byte 0 = (version << 4) | kind, then a 16 bit message id (with the
/// sender id this de-duplicates repeats and copies that arrive over several
/// paths), then the kind's fields. Coordinates are int32 in 1e-5 degree
/// (about 1.1 m). All multi-byte fields are big endian.
enum TripKind {
  pos(1),
  sos(2),
  sosAck(3),
  canned(4),
  pin(5),
  pinDelete(6),
  track(7),
  held(8),
  route(9);

  const TripKind(this.code);
  final int code;
  static TripKind? fromCode(int c) {
    for (final k in values) {
      if (k.code == c) return k;
    }
    return null;
  }
}

const int tripVersion = 1;

sealed class TripMsg {
  const TripMsg(this.id);

  /// 16 bit message id (wraps), unique per sender and kind.
  final int id;
  TripKind get kind;

  Uint8List encode() {
    final w = _Writer()
      ..u8((tripVersion << 4) | kind.code)
      ..u16(id);
    _body(w);
    return w.take();
  }

  void _body(_Writer w);

  /// De-dup key with the sender id.
  String key(int origin) => '$origin:${kind.code}:$id';

  static TripMsg? tryDecode(List<int> bytes) {
    try {
      if (bytes.length < 3) return null;
      final r = _Reader(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
      final b0 = r.u8();
      if (b0 >> 4 != tripVersion) return null;
      final kind = TripKind.fromCode(b0 & 0xF);
      if (kind == null) return null;
      final id = r.u16();
      switch (kind) {
        case TripKind.pos:
          final flags = r.u8();
          final p = r.point();
          final acc = r.u8();
          final age = r.u8();
          // v1.8.3: battery byte at the end (older apps ignore it).
          final bt = flags & 4 != 0 ? r.u8() : null;
          // v2.5.6: speed (0.5 m/s steps) and heading (360/256 degree
          // steps) after the battery byte. Older apps stop reading before
          // them and ignore the rest, so nothing else changes.
          final spd = flags & 8 != 0 ? r.u8() : null;
          final hdg = flags & 16 != 0 ? r.u8() : null;
          return PosMsg(
            id,
            p,
            checkIn: flags & 1 != 0,
            accuracyM: flags & 2 != 0 ? acc.toDouble() : null,
            fixAge: Duration(seconds: age * 4),
            battery: bt != null && bt <= 100 ? bt : null,
            speedMps: spd == null ? null : spd / 2,
            headingDeg: hdg == null ? null : hdg * 360 / 256,
          );
        case TripKind.sos:
          final flags = r.u8();
          final rep = r.u8();
          final has = flags & 2 != 0;
          final p = has ? r.point() : null;
          final acc = has ? r.u8() : 0;
          return SosMsg(
            id,
            pos: p,
            cancel: flags & 1 != 0,
            repeat: rep,
            accuracyM: has && acc > 0 ? acc.toDouble() : null,
          );
        case TripKind.sosAck:
          return SosAckMsg(id, origin: r.u32(), sosId: r.u16());
        case TripKind.canned:
          final code = r.u8();
          final text = r.str();
          return CannedMsg(id, code, text: text);
        case TripKind.pin:
          final pinId = r.u16();
          final type = r.u8();
          final p = r.point();
          final label = r.str();
          return PinMsg(
            id,
            pinId: pinId,
            type: PinType.fromCode(type),
            pos: p,
            label: label,
          );
        case TripKind.pinDelete:
          return PinDeleteMsg(id, pinId: r.u16());
        case TripKind.track:
          final trackId = r.u16();
          final index = r.u8();
          final count = r.u8();
          final flags = r.u8();
          final n = r.u8();
          final hasTime = flags & 1 != 0;
          final pts = <TrackPt>[];
          if (n > 0) {
            var lat = r.i32(), lng = r.i32();
            var t = hasTime ? r.u32() : 0;
            pts.add(TrackPt(GeoPoint.fromE5(lat, lng), hasTime ? t : null));
            for (var i = 1; i < n; i++) {
              lat += r.i16();
              lng += r.i16();
              if (hasTime) t += r.u16();
              pts.add(TrackPt(GeoPoint.fromE5(lat, lng), hasTime ? t : null));
            }
          }
          return TrackMsg(
            id,
            trackId: trackId,
            index: index,
            count: count,
            summary: flags & 2 != 0,
            points: pts,
          );
        case TripKind.route:
          final routeId = r.u16();
          final index = r.u8();
          final count = r.u8();
          if (count == 0 || index >= count) return null;
          return RouteMsg(
            id,
            routeId: routeId,
            index: index,
            count: count,
            data: r.rest(),
          );
        case TripKind.held:
          final origin = r.u32();
          final age = r.u16();
          final inner = r.rest();
          final m = TripMsg.tryDecode(inner);
          if (m == null || m is HeldMsg) return null;
          return HeldMsg(
            id,
            origin: origin,
            age: Duration(seconds: age),
            inner: m,
          );
      }
    } catch (_) {
      return null;
    }
  }
}

/// Location update; [checkIn] = periodic "I'm OK" check-in (may go over
/// LoRa), otherwise a live update on fast links only.
class PosMsg extends TripMsg {
  const PosMsg(
    super.id,
    this.pos, {
    this.checkIn = false,
    this.accuracyM,
    this.fixAge = Duration.zero,
    this.battery,
    this.speedMps,
    this.headingDeg,
  });
  final GeoPoint pos;
  final bool checkIn;
  final double? accuracyM;

  /// Sender's speed in m/s (v2.5.6, one byte, 0.5 m/s steps up to
  /// 127 m/s), null = unknown.
  final double? speedMps;

  /// Sender's direction of travel in degrees from north (v2.5.6, one byte,
  /// 1.4 degree steps), null = unknown / not moving.
  final double? headingDeg;

  /// Sender's phone battery 0..100 (v1.8.3, one byte), null = unknown.
  final int? battery;

  /// How old the GPS fix was when sent (4 s steps, max 17 min).
  final Duration fixAge;
  @override
  TripKind get kind => TripKind.pos;
  @override
  void _body(_Writer w) {
    w
      ..u8(
        (checkIn ? 1 : 0) |
            (accuracyM != null ? 2 : 0) |
            (battery != null ? 4 : 0) |
            (speedMps != null ? 8 : 0) |
            (headingDeg != null ? 16 : 0),
      )
      ..point(pos)
      ..u8((accuracyM ?? 0).round().clamp(0, 255))
      ..u8((fixAge.inSeconds ~/ 4).clamp(0, 255));
    if (battery != null) w.u8(battery!.clamp(0, 100));
    if (speedMps != null) w.u8((speedMps! * 2).round().clamp(0, 255));
    if (headingDeg != null) {
      w.u8((normDeg(headingDeg!) * 256 / 360).round() % 256);
    }
  }
}

class SosMsg extends TripMsg {
  const SosMsg(
    super.id, {
    this.pos,
    this.cancel = false,
    this.repeat = 0,
    this.accuracyM,
  });
  final GeoPoint? pos;
  final bool cancel;

  /// How many times this alert was sent before (0 = first).
  final int repeat;
  final double? accuracyM;
  @override
  TripKind get kind => TripKind.sos;
  @override
  void _body(_Writer w) {
    w
      ..u8((cancel ? 1 : 0) | (pos != null ? 2 : 0))
      ..u8(repeat.clamp(0, 255));
    if (pos != null) {
      w
        ..point(pos!)
        ..u8((accuracyM ?? 0).round().clamp(0, 255));
    }
  }
}

class SosAckMsg extends TripMsg {
  const SosAckMsg(super.id, {required this.origin, required this.sosId});

  /// Phone that sent the SOS, and its SOS id.
  final int origin;
  final int sosId;
  @override
  TripKind get kind => TripKind.sosAck;
  @override
  void _body(_Writer w) => w
    ..u32(origin)
    ..u16(sosId);
}

/// Built-in quick messages (code 1..); code 0 = custom [CannedMsg.text].
const List<String> builtinCanned = [
  '', // 0 = custom
  'On my way',
  'Stopping',
  'Need help',
  'At camp',
  'OK',
  'Wait for me',
  'Turning back',
  'Water break',
];

class CannedMsg extends TripMsg {
  const CannedMsg(super.id, this.code, {this.text = ''});
  final int code;
  final String text;

  static const int maxText = 48;

  String get display =>
      code > 0 && code < builtinCanned.length ? builtinCanned[code] : text;
  @override
  TripKind get kind => TripKind.canned;
  @override
  void _body(_Writer w) => w
    ..u8(code)
    ..str(code == 0 ? text : '', maxText);
}

enum PinType {
  custom(0, 'Pin'),
  camp(1, 'Camp'),
  water(2, 'Water'),
  trailhead(3, 'Trailhead'),
  meetup(4, 'Meet-up'),
  danger(5, 'Hazard'),
  car(6, 'Car');

  const PinType(this.code, this.label);
  final int code;
  final String label;
  static PinType fromCode(int c) {
    for (final t in values) {
      if (t.code == c) return t;
    }
    return custom;
  }
}

class PinMsg extends TripMsg {
  const PinMsg(
    super.id, {
    required this.pinId,
    required this.type,
    required this.pos,
    this.label = '',
  });
  final int pinId;
  final PinType type;
  final GeoPoint pos;
  final String label;
  static const int maxLabel = 32;
  @override
  TripKind get kind => TripKind.pin;
  @override
  void _body(_Writer w) => w
    ..u16(pinId)
    ..u8(type.code)
    ..point(pos)
    ..str(label, maxLabel);
}

class PinDeleteMsg extends TripMsg {
  const PinDeleteMsg(super.id, {required this.pinId});
  final int pinId;
  @override
  TripKind get kind => TripKind.pinDelete;
  @override
  void _body(_Writer w) => w.u16(pinId);
}

/// One track point; [t] = unix seconds (absent in LoRa summaries).
class TrackPt {
  const TrackPt(this.pos, [this.t]);
  final GeoPoint pos;
  final int? t;
}

/// Part [index] of [count] of a shared trail; [summary] = thinned copy
/// (LoRa), no timestamps.
class TrackMsg extends TripMsg {
  const TrackMsg(
    super.id, {
    required this.trackId,
    required this.index,
    required this.count,
    required this.points,
    this.summary = false,
  });
  final int trackId;
  final int index;
  final int count;
  final bool summary;
  final List<TrackPt> points;

  /// Points per chunk on fast links (about 380 bytes).
  static const int maxPoints = 60;
  @override
  TripKind get kind => TripKind.track;
  @override
  void _body(_Writer w) {
    final hasTime = !summary && points.every((p) => p.t != null);
    w
      ..u16(trackId)
      ..u8(index)
      ..u8(count)
      ..u8((hasTime ? 1 : 0) | (summary ? 2 : 0))
      ..u8(points.length);
    if (points.isEmpty) return;
    var lat = points.first.pos.latE5, lng = points.first.pos.lngE5;
    var t = points.first.t ?? 0;
    w
      ..i32(lat)
      ..i32(lng);
    if (hasTime) w.u32(t);
    for (final p in points.skip(1)) {
      final nl = p.pos.latE5, ng = p.pos.lngE5;
      w
        ..i16(nl - lat)
        ..i16(ng - lng);
      lat = nl;
      lng = ng;
      if (hasTime) {
        w.u16((p.t! - t).clamp(0, 0xFFFF));
        t = p.t!;
      }
    }
  }

  /// Split [pts] into chunks whose deltas fit 16 bits (about 36 km and
  /// 18 h between points) and at most [maxPoints] points.
  static List<List<TrackPt>> chunk(List<TrackPt> pts, {int max = maxPoints}) {
    final out = <List<TrackPt>>[];
    var cur = <TrackPt>[];
    for (final p in pts) {
      if (cur.isNotEmpty) {
        final last = cur.last;
        final dl = (p.pos.latE5 - last.pos.latE5).abs();
        final dg = (p.pos.lngE5 - last.pos.lngE5).abs();
        final dt = (p.t ?? 0) - (last.t ?? 0);
        if (cur.length >= max ||
            dl > 32767 ||
            dg > 32767 ||
            dt < 0 ||
            dt > 0xFFFF) {
          out.add(cur);
          cur = [];
        }
      }
      cur.add(p);
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }
}

/// Part [index] of [count] of an imported route / map layer shared with
/// the group (v1.8.3): the parts joined are a zlib blob (see
/// `lib/trip/imports/route_share.dart`). Fast links only; LoRa gets a
/// thinned [TrackMsg] summary instead.
class RouteMsg extends TripMsg {
  const RouteMsg(
    super.id, {
    required this.routeId,
    required this.index,
    required this.count,
    required this.data,
  });
  final int routeId;
  final int index;
  final int count;
  final Uint8List data;

  /// Blob bytes per part (keeps each frame under about 380 bytes).
  static const int partBytes = 340;
  @override
  TripKind get kind => TripKind.route;
  @override
  void _body(_Writer w) => w
    ..u16(routeId)
    ..u8(index)
    ..u8(count)
    ..bytes(data);
}

/// A message a base camp phone held for someone who was out of range,
/// delivered when they came back ([age] = how long it was held).
class HeldMsg extends TripMsg {
  const HeldMsg(
    super.id, {
    required this.origin,
    required this.age,
    required this.inner,
  });
  final int origin;
  final Duration age;
  final TripMsg inner;
  @override
  TripKind get kind => TripKind.held;
  @override
  void _body(_Writer w) => w
    ..u32(origin)
    ..u16(age.inSeconds.clamp(0, 0xFFFF))
    ..bytes(inner.encode());
}

class _Writer {
  final BytesBuilder _b = BytesBuilder(copy: false);
  final _tmp = ByteData(4);
  void u8(int v) => _b.addByte(v & 0xFF);
  void u16(int v) {
    _tmp.setUint16(0, v & 0xFFFF);
    _b.add(_tmp.buffer.asUint8List(0, 2).toList());
  }

  void i16(int v) {
    _tmp.setInt16(0, v);
    _b.add(_tmp.buffer.asUint8List(0, 2).toList());
  }

  void u32(int v) {
    _tmp.setUint32(0, v & 0xFFFFFFFF);
    _b.add(_tmp.buffer.asUint8List(0, 4).toList());
  }

  void i32(int v) {
    _tmp.setInt32(0, v);
    _b.add(_tmp.buffer.asUint8List(0, 4).toList());
  }

  void point(GeoPoint p) {
    i32(p.latE5);
    i32(p.lngE5);
  }

  /// Length-prefixed UTF-8, cut to [max] bytes on a character boundary.
  void str(String s, int max) {
    var b = utf8.encode(s);
    if (b.length > max) {
      var cut = max;
      while (cut > 0 && (b[cut] & 0xC0) == 0x80) {
        cut--;
      }
      b = b.sublist(0, cut);
    }
    u8(b.length);
    _b.add(b);
  }

  void bytes(List<int> b) => _b.add(b);
  Uint8List take() => _b.takeBytes();
}

class _Reader {
  _Reader(this._d) : _bd = ByteData.sublistView(_d);
  final Uint8List _d;
  final ByteData _bd;
  int _o = 0;
  void _need(int n) {
    if (_o + n > _d.length) throw const FormatException('short');
  }

  int u8() {
    _need(1);
    return _d[_o++];
  }

  int u16() {
    _need(2);
    final v = _bd.getUint16(_o);
    _o += 2;
    return v;
  }

  int i16() {
    _need(2);
    final v = _bd.getInt16(_o);
    _o += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = _bd.getUint32(_o);
    _o += 4;
    return v;
  }

  int i32() {
    _need(4);
    final v = _bd.getInt32(_o);
    _o += 4;
    return v;
  }

  GeoPoint point() {
    final p = GeoPoint.fromE5(i32(), i32());
    if (!p.valid) throw const FormatException('bad point');
    return p;
  }

  String str() {
    final n = u8();
    _need(n);
    final s = utf8.decode(_d.sublist(_o, _o + n), allowMalformed: true);
    _o += n;
    return s;
  }

  Uint8List rest() {
    final r = Uint8List.fromList(_d.sublist(_o));
    _o = _d.length;
    return r;
  }
}
