import 'dart:convert';
import 'dart:typed_data';

/// Just enough protobuf (proto3 wire format) for the Meshtastic client API:
/// varints, fixed32, float and length-delimited fields. Unknown fields are
/// skipped, so newer firmware with extra fields still decodes.
///
/// Wire types: 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32.
class PbWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void _key(int field, int wireType) => _varint((field << 3) | wireType);

  void _varint(int v) {
    // Negative int32 values are sign extended to 64 bits (10 bytes): the
    // unsigned shift turns them positive after the first group.
    final out = <int>[];
    var x = v;
    while (x < 0 || x >= 0x80) {
      out.add((x & 0x7F) | 0x80);
      x = x >>> 7;
    }
    out.add(x);
    _b.add(out);
  }

  /// uint32 / int32 / bool / enum. Zero values are skipped (proto3).
  void uint(int field, int? v, {bool always = false}) {
    if (v == null || (v == 0 && !always)) return;
    _key(field, 0);
    _varint(v);
  }

  void boolean(int field, bool v) {
    if (!v) return;
    _key(field, 0);
    _varint(1);
  }

  void fixed32(int field, int? v) {
    if (v == null || v == 0) return;
    _key(field, 5);
    final d = ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  void bytes(int field, List<int>? v) {
    if (v == null || v.isEmpty) return;
    _key(field, 2);
    _varint(v.length);
    _b.add(v);
  }

  void string(int field, String? v) {
    if (v == null || v.isEmpty) return;
    bytes(field, utf8.encode(v));
  }

  /// Embedded message (always written, even when empty).
  void message(int field, Uint8List v) {
    _key(field, 2);
    _varint(v.length);
    _b.add(v);
  }

  /// A decoded field written back unchanged (any wire type).
  void raw(PbField f) {
    switch (f.wireType) {
      case 0:
        _key(f.number, 0);
        _varint(f.asInt);
      case 1:
        _key(f.number, 1);
        final d = ByteData(8)..setUint64(0, f.asInt, Endian.little);
        _b.add(d.buffer.asUint8List());
      case 2:
        _key(f.number, 2);
        _varint(f.asBytes.length);
        _b.add(f.asBytes);
      case 5:
        _key(f.number, 5);
        final d = ByteData(4)..setUint32(0, f.asFixed32, Endian.little);
        _b.add(d.buffer.asUint8List());
    }
  }

  Uint8List toBytes() => _b.toBytes();
}

/// One decoded field.
class PbField {
  PbField(this.number, this.wireType, this._int, this._bytes);
  final int number;
  final int wireType;
  final int _int;
  final Uint8List? _bytes;

  int get asInt => _int;

  /// int32 fields are sent as 64 bit sign extended varints.
  int get asInt32 => _int.toSigned(32);
  bool get asBool => _int != 0;
  int get asFixed32 => _int & 0xFFFFFFFF;
  int get asSFixed32 => (_int & 0xFFFFFFFF).toSigned(32);
  double get asFloat {
    final d = ByteData(4)..setUint32(0, _int & 0xFFFFFFFF, Endian.little);
    return d.getFloat32(0, Endian.little);
  }

  Uint8List get asBytes => _bytes ?? Uint8List(0);
  String get asString => utf8.decode(asBytes, allowMalformed: true);
}

class PbFormatException implements Exception {
  PbFormatException(this.message);
  final String message;
  @override
  String toString() => 'PbFormatException: $message';
}

/// Decodes every top level field of [data]. Throws [PbFormatException] on
/// truncated input.
List<PbField> pbDecode(Uint8List data) {
  final out = <PbField>[];
  var o = 0;
  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (o >= data.length) throw PbFormatException('truncated varint');
      final b = data[o++];
      if (shift < 64) result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
      if (shift > 70) throw PbFormatException('varint too long');
    }
    return result;
  }

  while (o < data.length) {
    final key = varint();
    final field = key >> 3;
    final wt = key & 7;
    if (field == 0) throw PbFormatException('field 0');
    switch (wt) {
      case 0:
        out.add(PbField(field, wt, varint(), null));
      case 1:
        if (o + 8 > data.length) throw PbFormatException('truncated fixed64');
        final v = ByteData.sublistView(
          data,
          o,
          o + 8,
        ).getUint64(0, Endian.little);
        o += 8;
        out.add(PbField(field, wt, v, null));
      case 2:
        final len = varint();
        if (len < 0 || o + len > data.length) {
          throw PbFormatException('truncated bytes');
        }
        out.add(PbField(field, wt, 0, Uint8List.sublistView(data, o, o + len)));
        o += len;
      case 5:
        if (o + 4 > data.length) throw PbFormatException('truncated fixed32');
        final v = ByteData.sublistView(
          data,
          o,
          o + 4,
        ).getUint32(0, Endian.little);
        o += 4;
        out.add(PbField(field, wt, v, null));
      default:
        throw PbFormatException('wire type $wt');
    }
  }
  return out;
}
