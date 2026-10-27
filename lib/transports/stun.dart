import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Minimal STUN (RFC 5389) Binding client pieces, used by the direct
/// phone-to-phone links (v1.8.9) to learn the public address a NAT gives
/// our UDP socket. Only what is needed: build a request, recognise and
/// parse a success response (XOR-MAPPED-ADDRESS, or MAPPED-ADDRESS from
/// old servers).
class Stun {
  static const int magicCookie = 0x2112A442;
  static const int bindingRequest = 0x0001;
  static const int bindingSuccess = 0x0101;

  /// Free public STUN servers (no account, no TURN): Google and Cloudflare.
  static const List<(String, int)> defaultServers = [
    ('stun.l.google.com', 19302),
    ('stun.cloudflare.com', 3478),
    ('stun1.l.google.com', 19302),
  ];

  static final _rnd = Random.secure();

  /// A fresh 12-byte transaction id.
  static Uint8List newTxId() =>
      Uint8List.fromList(List.generate(12, (_) => _rnd.nextInt(256)));

  static Uint8List request(Uint8List txId) {
    final b = Uint8List(20);
    final bd = ByteData.sublistView(b);
    bd.setUint16(0, bindingRequest);
    bd.setUint16(2, 0);
    bd.setUint32(4, magicCookie);
    b.setRange(8, 20, txId);
    return b;
  }

  /// Looks like a STUN message (first two bits zero + magic cookie).
  static bool isStun(Uint8List d) =>
      d.length >= 20 &&
      (d[0] & 0xC0) == 0 &&
      ByteData.sublistView(d).getUint32(4) == magicCookie;

  static String txKey(Uint8List d) =>
      d.sublist(8, 20).map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// The mapped (public) address in a Binding success response, else null.
  static ({InternetAddress address, int port})? parseMapped(Uint8List d) {
    if (!isStun(d)) return null;
    final bd = ByteData.sublistView(d);
    if (bd.getUint16(0) != bindingSuccess) return null;
    final len = bd.getUint16(2);
    if (20 + len > d.length) return null;
    var i = 20;
    ({InternetAddress address, int port})? plain;
    while (i + 4 <= 20 + len) {
      final type = bd.getUint16(i);
      final alen = bd.getUint16(i + 2);
      final v = i + 4;
      if (v + alen > d.length) return null;
      if ((type == 0x0020 || type == 0x8020 || type == 0x0001) && alen >= 8) {
        final fam = d[v + 1];
        final xor = type != 0x0001;
        var port = bd.getUint16(v + 2);
        if (xor) port ^= magicCookie >> 16;
        Uint8List? raw;
        if (fam == 0x01 && alen >= 8) {
          raw = Uint8List.fromList(d.sublist(v + 4, v + 8));
        } else if (fam == 0x02 && alen >= 20) {
          raw = Uint8List.fromList(d.sublist(v + 4, v + 20));
        }
        if (raw != null) {
          if (xor) {
            final key = Uint8List(16);
            ByteData.sublistView(key).setUint32(0, magicCookie);
            key.setRange(4, 16, d.sublist(8, 20));
            for (var k = 0; k < raw.length; k++) {
              raw[k] ^= key[k];
            }
          }
          final r = (address: InternetAddress.fromRawAddress(raw), port: port);
          if (xor) return r;
          plain ??= r;
        }
      }
      i = v + ((alen + 3) & ~3);
    }
    return plain;
  }

  /// Test helper / tiny server side: a success response for [request]
  /// telling the client it was seen at [address]:[port].
  static Uint8List successFor(
    Uint8List request,
    InternetAddress address,
    int port,
  ) {
    final raw = address.rawAddress;
    final alen = 4 + raw.length;
    final b = Uint8List(20 + 4 + alen);
    final bd = ByteData.sublistView(b);
    bd.setUint16(0, bindingSuccess);
    bd.setUint16(2, 4 + alen);
    bd.setUint32(4, magicCookie);
    b.setRange(8, 20, request.sublist(8, 20));
    bd.setUint16(20, 0x0020);
    bd.setUint16(22, alen);
    b[25] = raw.length == 4 ? 0x01 : 0x02;
    bd.setUint16(26, port ^ (magicCookie >> 16));
    final key = Uint8List(16);
    ByteData.sublistView(key).setUint32(0, magicCookie);
    key.setRange(4, 16, request.sublist(8, 20));
    for (var k = 0; k < raw.length; k++) {
      b[28 + k] = raw[k] ^ key[k];
    }
    return b;
  }
}
