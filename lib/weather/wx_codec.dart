import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'wx_alert.dart';
import 'wx_keys.dart';

/// The signed weather alert wire formats (v2.5.2, [FrameType.alert]).
///
/// Every packet is signed with the sending device's own Ed25519 key. The
/// signature covers the sender's node id (the frame header's sender, so a
/// copy cannot be passed off as another phone's) and the whole payload up to
/// the signature. There are three kinds:
///
/// * [WxKind.compact] (LoRa, one packet, at most 200 bytes with the 12 byte
///   frame header):
///   ```
///   b0       1  version 1 (high nibble) | kind 1
///   flags    1  bits 0-2 severity (0 unknown .. 4 extreme), bit 3 urgency
///                Immediate, bit 4 "more zones follow in a zones packet"
///   event    1  [wxEvents] code (phenomenon + significance)
///   office   3  the 4 letter NWS office, base 26
///   etn      2  event tracking number
///   issued   4  when the NWS sent it, seconds (UTC)
///   expires  2  minutes after issued it stops counting
///   nz       1  zone count, then 3 bytes each (state, Z/C, number)
///   tl       1  text length, then the text (UTF-8, at most 64 bytes)
///   pubkey  32  the sender's public key
///   sig     64  Ed25519
///   ```
///   Fixed 112 bytes + 12 byte frame header: 124. With 64 bytes of text 4
///   zones fit exactly in the 200 byte radio budget; more zones go in:
/// * [WxKind.zones] (LoRa, only when needed): event, office, etn, issued
///   (they name the alert), more zones, the sender's key id (10 bytes, not
///   the whole key: the receiver has it from the compact packet), signature.
/// * [WxKind.full] (internet relay rooms `wx-<state>`): the whole alert as
///   JSON (headline, instruction, details, every zone), public key and
///   signature.
enum WxPacket {
  compact(1),
  zones(2),
  full(3);

  const WxPacket(this.code);
  final int code;
}

const int wxVersion = 1;

/// One row of the event code table: VTEC phenomenon + significance and the
/// name the app shows. Only warnings are sent over the radio.
class WxEvent {
  const WxEvent(this.code, this.ph, this.sig, this.name);
  final int code;
  final String ph;
  final String sig;
  final String name;
}

const List<WxEvent> wxEvents = [
  WxEvent(1, 'TO', 'W', 'Tornado Warning'),
  WxEvent(2, 'SV', 'W', 'Severe Thunderstorm Warning'),
  WxEvent(3, 'FF', 'W', 'Flash Flood Warning'),
  WxEvent(4, 'FL', 'W', 'Flood Warning'),
  WxEvent(5, 'FA', 'W', 'Flood Warning'),
  WxEvent(6, 'EW', 'W', 'Extreme Wind Warning'),
  WxEvent(7, 'BZ', 'W', 'Blizzard Warning'),
  WxEvent(8, 'WS', 'W', 'Winter Storm Warning'),
  WxEvent(9, 'IS', 'W', 'Ice Storm Warning'),
  WxEvent(10, 'LE', 'W', 'Lake Effect Snow Warning'),
  WxEvent(11, 'WC', 'W', 'Wind Chill Warning'),
  WxEvent(12, 'EC', 'W', 'Extreme Cold Warning'),
  WxEvent(13, 'HW', 'W', 'High Wind Warning'),
  WxEvent(14, 'EH', 'W', 'Excessive Heat Warning'),
  WxEvent(15, 'XH', 'W', 'Extreme Heat Warning'),
  WxEvent(16, 'FW', 'W', 'Red Flag Warning'),
  WxEvent(17, 'HU', 'W', 'Hurricane Warning'),
  WxEvent(18, 'TR', 'W', 'Tropical Storm Warning'),
  WxEvent(19, 'SS', 'W', 'Storm Surge Warning'),
  WxEvent(20, 'TS', 'W', 'Tsunami Warning'),
  WxEvent(21, 'DS', 'W', 'Dust Storm Warning'),
  WxEvent(22, 'SQ', 'W', 'Snow Squall Warning'),
  WxEvent(23, 'AV', 'W', 'Avalanche Warning'),
  WxEvent(24, 'AF', 'W', 'Ashfall Warning'),
  WxEvent(25, 'CF', 'W', 'Coastal Flood Warning'),
  WxEvent(26, 'LS', 'W', 'Lakeshore Flood Warning'),
  WxEvent(27, 'SU', 'W', 'High Surf Warning'),
  WxEvent(28, 'HZ', 'W', 'Hard Freeze Warning'),
  WxEvent(29, 'FZ', 'W', 'Freeze Warning'),
  WxEvent(30, 'EQ', 'W', 'Earthquake Warning'),
  WxEvent(31, 'VO', 'W', 'Volcano Warning'),
  WxEvent(32, 'FR', 'W', 'Fire Warning'),
  WxEvent(33, 'HM', 'W', 'Hazardous Materials Warning'),
  WxEvent(34, 'SP', 'W', 'Shelter In Place Warning'),
  WxEvent(35, 'NU', 'W', 'Nuclear Power Plant Warning'),
  WxEvent(36, 'RH', 'W', 'Radiological Hazard Warning'),
];

WxEvent? wxEventByCode(int code) {
  for (final e in wxEvents) {
    if (e.code == code) return e;
  }
  return null;
}

WxEvent? wxEventByVtec(String ph, String sig) {
  for (final e in wxEvents) {
    if (e.ph == ph && e.sig == sig) return e;
  }
  return null;
}

/// The parts of a VTEC based alert key (`vtec:KPQR.TO.W.0012.2026`).
class WxVtec {
  const WxVtec(this.office, this.ph, this.sig, this.etn, this.year);
  final String office;
  final String ph;
  final String sig;
  final int etn;
  final int year;

  String get key =>
      'vtec:$office.$ph.$sig.${etn.toString().padLeft(4, '0')}.$year';

  static WxVtec? parse(String key) {
    final m = RegExp(
      r'^vtec:([A-Z]{4})\.([A-Z]{2})\.([A-Z])\.(\d{1,4})\.(\d{4})$',
    ).firstMatch(key);
    if (m == null) return null;
    return WxVtec(m[1]!, m[2]!, m[3]!, int.parse(m[4]!), int.parse(m[5]!));
  }
}

/// Pack a UGC code (`ORZ006`, `ORC051`) into 3 bytes (null if it is not
/// one): two letters of state, Z or C, a number 0-999.
int? wxPackZone(String z) {
  final m = RegExp(r'^([A-Z]{2})([ZC])(\d{3})$').firstMatch(z);
  if (m == null) return null;
  final st = (m[1]!.codeUnitAt(0) - 65) * 26 + (m[1]!.codeUnitAt(1) - 65);
  return ((st * 2 + (m[2] == 'C' ? 1 : 0)) * 1000) + int.parse(m[3]!);
}

String wxUnpackZone(int v) {
  final n = v % 1000;
  final rest = v ~/ 1000;
  final type = rest % 2 == 1 ? 'C' : 'Z';
  final st = rest ~/ 2;
  return '${String.fromCharCode(65 + st ~/ 26)}'
      '${String.fromCharCode(65 + st % 26)}$type${n.toString().padLeft(3, '0')}';
}

int _packOffice(String o) {
  var v = 0;
  for (final c in o.codeUnits) {
    v = v * 26 + (c - 65);
  }
  return v;
}

String _unpackOffice(int v) {
  final out = List<int>.filled(4, 65);
  for (var i = 3; i >= 0; i--) {
    out[i] = 65 + v % 26;
    v ~/= 26;
  }
  return String.fromCharCodes(out);
}

/// [s] cut to at most [max] UTF-8 bytes, on a character boundary.
String wxCutBytes(String s, int max) {
  if (utf8.encode(s).length <= max) return s;
  final sb = StringBuffer();
  var n = 0;
  for (final r in s.runes) {
    final b = utf8.encode(String.fromCharCode(r)).length;
    if (n + b > max) break;
    sb.writeCharCode(r);
    n += b;
  }
  return sb.toString();
}

/// The short area text of a compact alert: at most [max] bytes, cut at a
/// place boundary (";") when it has to be shortened.
String wxShortArea(String area, int max) {
  final a = area.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (utf8.encode(a).length <= max) return a;
  final parts = a.split(RegExp(r'\s*;\s*'));
  var out = '';
  for (final p in parts) {
    final next = out.isEmpty ? p : '$out; $p';
    if (utf8.encode(next).length > max) break;
    out = next;
  }
  if (out.isEmpty) return wxCutBytes(a, max);
  return out;
}

/// Bytes of a compact packet that do not depend on text or zones, with
/// the frame header: header 12 + b0 + body 15 + key 32 + signature 64.
const int wxCompactFixed = 12 + 1 + 15 + 32 + 64;

/// Longest text of a compact alert.
const int wxMaxText = 64;

/// Longest zone list of the second (zones only) packet.
const int wxMaxZonesExtra = 26;

/// Whether [a] can go over the radio: a VTEC alert whose event is in the
/// code table.
bool wxRadioReady(WxAlert a) {
  final v = WxVtec.parse(a.key);
  if (v == null) return false;
  return wxEventByVtec(v.ph, v.sig) != null &&
      a.ugc.any((z) => wxPackZone(z) != null);
}

/// What [wxEncodeCompact] made.
class WxCompact {
  WxCompact(this.packets, this.zonesSent, this.text);

  /// Payloads (the first is the alert, the second, if any, more zones).
  final List<Uint8List> packets;
  final int zonesSent;
  final String text;

  /// Total bytes with the 12 byte frame header, per packet.
  List<int> get frameSizes => [for (final p in packets) p.length + 12];
}

/// Encode [a] for the radio, or null when it cannot go ([wxRadioReady]).
/// [budget] is the room for the payload (200 - 12 header, less the
/// sealing overhead on a private group). [zones] are the zones to name
/// (the sender's covered ones; all of the alert's when null).
Future<WxCompact?> wxEncodeCompact(
  WxAlert a, {
  required WxDeviceKey key,
  required int nodeId,
  int budget = 188,
  Iterable<String>? zones,
}) async {
  final v = WxVtec.parse(a.key);
  if (v == null) return null;
  final ev = wxEventByVtec(v.ph, v.sig);
  if (ev == null) return null;
  final all = <int>[];
  final wanted = zones ?? a.ugc;
  for (final z in wanted) {
    final p = wxPackZone(z);
    if (p != null && !all.contains(p)) all.add(p);
  }
  if (all.isEmpty) {
    for (final z in a.ugc) {
      final p = wxPackZone(z);
      if (p != null && !all.contains(p)) all.add(p);
    }
  }
  if (all.isEmpty) return null;
  // Room: payload = 1 + 15 + 32 + 64 + 3*nz + text.
  const fixed = 1 + 15 + 32 + 64;
  final room = budget - fixed;
  if (room < 3) return null;
  // At least one zone; the text up to 64 bytes; then as many zones as fit.
  var nz = min(all.length, max(1, (room - wxMaxText) ~/ 3));
  var textRoom = min(wxMaxText, room - 3 * nz);
  if (textRoom < 0) {
    nz = 1;
    textRoom = max(0, room - 3);
  }
  // Spare room after the text goes to more zones.
  final text = wxShortArea(a.areaDesc, textRoom);
  final tb = utf8.encode(text);
  while (nz < all.length && fixed + 3 * (nz + 1) + tb.length <= budget) {
    nz++;
  }
  final inFirst = all.sublist(0, nz);
  final rest = all.sublist(nz, min(all.length, nz + wxMaxZonesExtra));
  final issued = a.issued.millisecondsSinceEpoch ~/ 1000;
  final expMin = max(
    0,
    min(
      0xFFFF,
      ((a.expiresAt.millisecondsSinceEpoch ~/ 1000) - issued + 59) ~/ 60,
    ),
  );
  final flags =
      a.severity.index |
      (a.urgency == 'Immediate' ? 8 : 0) |
      (rest.isNotEmpty ? 16 : 0);
  final b = BytesBuilder(copy: false)
    ..addByte((wxVersion << 4) | WxPacket.compact.code)
    ..addByte(flags)
    ..addByte(ev.code);
  final off = _packOffice(v.office);
  b
    ..addByte((off >> 16) & 0xFF)
    ..addByte((off >> 8) & 0xFF)
    ..addByte(off & 0xFF)
    ..addByte((v.etn >> 8) & 0xFF)
    ..addByte(v.etn & 0xFF)
    ..add(_u32(issued))
    ..addByte((expMin >> 8) & 0xFF)
    ..addByte(expMin & 0xFF)
    ..addByte(inFirst.length);
  for (final z in inFirst) {
    _add24(b, z);
  }
  b
    ..addByte(tb.length)
    ..add(tb);
  final first = await _sign(b.toBytes(), nodeId, key, withKey: true);
  final packets = [first];
  if (rest.isNotEmpty) {
    final z = BytesBuilder(copy: false)
      ..addByte((wxVersion << 4) | WxPacket.zones.code)
      ..addByte(ev.code)
      ..addByte((off >> 16) & 0xFF)
      ..addByte((off >> 8) & 0xFF)
      ..addByte(off & 0xFF)
      ..addByte((v.etn >> 8) & 0xFF)
      ..addByte(v.etn & 0xFF)
      ..add(_u32(issued))
      ..addByte(rest.length);
    for (final x in rest) {
      _add24(z, x);
    }
    packets.add(await _sign(z.toBytes(), nodeId, key, withKey: false));
  }
  return WxCompact(packets, inFirst.length + rest.length, text);
}

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v & 0xFFFFFFFF);

void _add24(BytesBuilder b, int v) => b
  ..addByte((v >> 16) & 0xFF)
  ..addByte((v >> 8) & 0xFF)
  ..addByte(v & 0xFF);

/// What is signed: the sending node id, then the payload up to the key id /
/// signature. For a zones packet the key id (10 bytes) is part of it.
Uint8List wxSignedBytes(int nodeId, List<int> body) {
  final b = BytesBuilder(copy: false)
    ..add(_u32(nodeId))
    ..add(body);
  return b.toBytes();
}

Future<Uint8List> _sign(
  Uint8List body,
  int nodeId,
  WxDeviceKey key, {
  required bool withKey,
}) async {
  final tail = withKey ? key.publicKey : _idBytes(key.id);
  final unsigned =
      (BytesBuilder(copy: false)
            ..add(body)
            ..add(tail))
          .toBytes();
  final sig = await key.sign(wxSignedBytes(nodeId, unsigned));
  return (BytesBuilder(copy: false)
        ..add(unsigned)
        ..add(sig))
      .toBytes();
}

Uint8List _idBytes(String id) => Uint8List.fromList([
  for (var i = 0; i + 1 < id.length; i += 2)
    int.parse(id.substring(i, i + 2), radix: 16),
]);

/// The relay (full) form of [a].
Future<Uint8List> wxEncodeFull(
  WxAlert a, {
  required WxDeviceKey key,
  required int nodeId,
}) async {
  String cut(String s, int n) => wxCutBytes(s, n);
  final j = <String, Object?>{
    'k': a.key,
    if (a.nwsId != null) 'id': cut(a.nwsId!, 120),
    'ev': a.event,
    'sv': a.severity.name,
    if (a.urgency.isNotEmpty) 'ur': a.urgency,
    if (a.headline.isNotEmpty) 'h': cut(a.headline, 300),
    if (a.description.isNotEmpty) 'd': cut(a.description, 900),
    if (a.instruction.isNotEmpty) 'i': cut(a.instruction, 400),
    if (a.areaDesc.isNotEmpty) 'a': cut(a.areaDesc, 300),
    't': a.issued.millisecondsSinceEpoch,
    'r': a.rev,
    if (a.onset != null) 'on': a.onset!.millisecondsSinceEpoch,
    if (a.expires != null) 'ex': a.expires!.millisecondsSinceEpoch,
    if (a.ends != null) 'en': a.ends!.millisecondsSinceEpoch,
    if (a.ugc.isNotEmpty) 'z': a.ugc.take(80).toList(),
    if (a.sender.isNotEmpty) 'by': cut(a.sender, 80),
  };
  final body =
      (BytesBuilder(copy: false)
            ..addByte((wxVersion << 4) | WxPacket.full.code)
            ..add(utf8.encode(jsonEncode(j))))
          .toBytes();
  return _sign(body, nodeId, key, withKey: true);
}

const _fullFields = [
  'k', 'id', 'ev', 'sv', 'ur', 'h', 'd', 'i', 'a', 't', 'r', 'on', 'ex',
  'en', 'z', 'by', //
];

/// A packet read from the wire, not yet checked.
class WxDecoded {
  WxDecoded._({
    required this.packet,
    required this.signed,
    required this.sig,
    required this.keyBytes,
    required this.keyId,
    this.alert,
    this.zoneList = const [],
    this.alertKey,
    this.issuedSec,
    this.moreZones = false,
  });

  final WxPacket packet;

  /// What the signature covers, without the node id (see [wxSignedBytes]).
  final Uint8List signed;
  final Uint8List sig;

  /// The sender's public key (compact / full), null in a zones packet.
  final Uint8List? keyBytes;

  /// The sender's key id (from the key, or given in a zones packet).
  final String keyId;

  /// The alert (compact / full), without source / trust.
  final WxAlert? alert;

  /// [WxPacket.zones]: the zones it adds.
  final List<String> zoneList;

  /// [WxPacket.zones]: which alert it belongs to (key) and its issue time.
  final String? alertKey;
  final int? issuedSec;

  /// [WxPacket.compact]: a zones packet follows.
  final bool moreZones;

  /// Whether the signature is right for the sender [nodeId] (for a zones
  /// packet the key must be passed: the one the compact packet brought).
  Future<bool> verify(int nodeId, {List<int>? key}) async {
    final pk = keyBytes ?? key;
    if (pk == null) return false;
    if (wxKeyId(pk) != keyId) return false;
    return WxDeviceKey.verify(wxSignedBytes(nodeId, signed), sig, pk);
  }
}

/// Read a payload, or null when it is not one of ours / is malformed.
WxDecoded? wxDecode(Uint8List p) {
  try {
    if (p.length < 1 + 10 + 64 || p.length > 4000) return null;
    if ((p[0] >> 4) != wxVersion) return null;
    final kind = p[0] & 0xF;
    final sig = Uint8List.fromList(p.sublist(p.length - 64));
    if (kind == WxPacket.zones.code) {
      if (p.length < 1 + 1 + 3 + 2 + 4 + 1 + 10 + 64) return null;
      final tail = p.length - 64;
      final idStart = tail - 10;
      final keyId = [
        for (var i = idStart; i < tail; i++)
          p[i].toRadixString(16).padLeft(2, '0'),
      ].join();
      final ev = wxEventByCode(p[1]);
      if (ev == null) return null;
      final office = _unpackOffice((p[2] << 16) | (p[3] << 8) | p[4]);
      final etn = (p[5] << 8) | p[6];
      final issued = ByteData.sublistView(p, 7, 11).getUint32(0);
      final nz = p[11];
      if (12 + nz * 3 != idStart) return null;
      final zs = <String>[];
      for (var i = 0; i < nz; i++) {
        zs.add(wxUnpackZone(_get24(p, 12 + i * 3)));
      }
      final year = DateTime.fromMillisecondsSinceEpoch(
        issued * 1000,
        isUtc: true,
      ).year;
      return WxDecoded._(
        packet: WxPacket.zones,
        signed: Uint8List.fromList(p.sublist(0, tail)),
        sig: sig,
        keyBytes: null,
        keyId: keyId,
        zoneList: zs,
        alertKey: WxVtec(office, ev.ph, ev.sig, etn, year).key,
        issuedSec: issued,
      );
    }
    if (p.length < 1 + 32 + 64) return null;
    final keyStart = p.length - 64 - 32;
    final pk = Uint8List.fromList(p.sublist(keyStart, keyStart + 32));
    final keyId = wxKeyId(pk);
    final signed = Uint8List.fromList(p.sublist(0, p.length - 64));
    if (kind == WxPacket.full.code) {
      final j = jsonDecode(utf8.decode(p.sublist(1, keyStart)));
      if (j is! Map) return null;
      // Only the alert's own fields: a sender cannot set our local flags
      // (notified, trust, source, cancel).
      final clean = <String, Object?>{
        for (final k in _fullFields)
          if (j.containsKey(k)) k: j[k],
        'src': 'relay',
        'tr': 'unconfirmed',
      };
      final a = WxAlert.fromJson(clean);
      if (a == null || a.key.length > 120) return null;
      return WxDecoded._(
        packet: WxPacket.full,
        signed: signed,
        sig: sig,
        keyBytes: pk,
        keyId: keyId,
        alert: a.copyWith(fromDevice: keyId, fromName: ''),
      );
    }
    if (kind != WxPacket.compact.code) return null;
    if (keyStart < 1 + 15) return null;
    final flags = p[1];
    final ev = wxEventByCode(p[2]);
    if (ev == null) return null;
    final office = _unpackOffice((p[3] << 16) | (p[4] << 8) | p[5]);
    final etn = (p[6] << 8) | p[7];
    final issued = ByteData.sublistView(p, 8, 12).getUint32(0);
    final expMin = (p[12] << 8) | p[13];
    final nz = p[14];
    var o = 15;
    if (o + nz * 3 + 1 > keyStart) return null;
    final zs = <String>[];
    for (var i = 0; i < nz; i++) {
      zs.add(wxUnpackZone(_get24(p, o)));
      o += 3;
    }
    final tl = p[o++];
    if (o + tl != keyStart) return null;
    final text = utf8.decode(p.sublist(o, o + tl), allowMalformed: true);
    final at = DateTime.fromMillisecondsSinceEpoch(issued * 1000, isUtc: true);
    final sevIdx = flags & 7;
    final a = WxAlert(
      key: WxVtec(office, ev.ph, ev.sig, etn, at.year).key,
      event: ev.name,
      severity: sevIdx < WxSeverity.values.length
          ? WxSeverity.values[sevIdx]
          : WxSeverity.unknown,
      urgency: flags & 8 != 0 ? 'Immediate' : '',
      areaDesc: text,
      issued: at,
      rev: issued * 1000,
      expires: at.add(Duration(minutes: expMin)),
      ugc: zs,
      sender: 'NWS $office',
      source: WxSource.lora,
      trust: WxTrust.unconfirmed,
      fromDevice: keyId,
    );
    return WxDecoded._(
      packet: WxPacket.compact,
      signed: signed,
      sig: sig,
      keyBytes: pk,
      keyId: keyId,
      alert: a,
      moreZones: flags & 16 != 0,
    );
  } catch (_) {
    return null;
  }
}

int _get24(Uint8List p, int o) => (p[o] << 16) | (p[o + 1] << 8) | p[o + 2];

/// Rough time on the air for [appBytes] of app frame over a Meshtastic
/// radio (LoRa, 125 kHz-class presets by spreading factor): the packet is
/// the app frame plus about 24 bytes (16 byte radio header, protobuf
/// wrapper). [sf] 11 / [bwHz] 250000 is LongFast, the default preset.
double wxAirtimeMs(
  int appBytes, {
  int sf = 11,
  int bwHz = 250000,
  int preamble = 16,
}) {
  final pl = appBytes + 24;
  final tSym = pow(2, sf) / bwHz * 1000;
  final de = tSym > 16 ? 1 : 0;
  final nPayload =
      8 +
      max(((8 * pl - 4 * sf + 28 + 16) / (4 * (sf - 2 * de))).ceil() * 5, 0);
  return (preamble + 4.25 + nPayload) * tSym;
}
