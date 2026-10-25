import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'channel_crypto.dart';
import 'frame.dart';

/// Shared secret of two friends (32 random-looking bytes) and what is
/// derived from it: the AES-GCM sealing key + 16-bit tag (as for private
/// channels, see [ChannelKey]), the relay room both join, and a short
/// safety code both phones show so people can compare them.
class PairKey {
  PairKey._(this.secret, this._key, this.room, this.safetyCode);

  factory PairKey(List<int> secret) {
    final s = Uint8List.fromList(secret);
    final hmac = DartHmac.sha256();
    List<int> sub(String label) => hmac
        .calculateMacSync(
          utf8.encode(label),
          secretKeyData: SecretKeyData(s),
          nonce: const [],
        )
        .bytes;
    final master = sub('walkie/friend/v1');
    final room = sub('room');
    final code = sub('safety');
    final n = ((code[0] << 16) | (code[1] << 8) | code[2]) % 1000000;
    return PairKey._(
      s,
      ChannelKey.fromMaster(0, master),
      'f${[for (final b in room.take(8)) b.toRadixString(16).padLeft(2, '0')].join()}',
      '${(n ~/ 1000).toString().padLeft(3, '0')} ${(n % 1000).toString().padLeft(3, '0')}',
    );
  }

  final Uint8List secret;
  final ChannelKey _key;

  /// Relay room ("f" + 16 hex), never the ids or the key.
  final String room;

  /// "123 456": same on both phones only if nobody tampered with the
  /// exchange.
  final String safetyCode;

  int get tag => _key.tag;
  static const int overhead = ChannelKey.overhead;

  Uint8List seal(Frame inner) => _key.seal(inner);
  Frame? open(Frame outer) => _key.open(outer);

  String get encoded => base64Url.encode(secret);
  static PairKey? decode(String s) {
    try {
      final b = base64Url.decode(s);
      return b.length == 32 ? PairKey(b) : null;
    } catch (_) {
      return null;
    }
  }

  static Uint8List randomSecret() {
    final r = Random.secure();
    return Uint8List.fromList([for (var i = 0; i < 32; i++) r.nextInt(256)]);
  }

  // ------------------------------------------------ friend request (ECDH)

  static final _x25519 = X25519();

  static Future<SimpleKeyPair> newKeyPair() => _x25519.newKeyPair();

  static Future<String> publicKeyOf(SimpleKeyPair kp) async =>
      base64Url.encode((await kp.extractPublicKey()).bytes);

  /// Both phones get the same key from their own private key and the other
  /// one's public key; the key itself never travels.
  static Future<PairKey> agree(
    SimpleKeyPair mine,
    String theirPublic,
    int idA,
    int idB,
  ) async {
    final pub = SimplePublicKey(
      base64Url.decode(theirPublic),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: pub,
    );
    final lo = min(idA, idB), hi = max(idA, idB);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final k = await hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('walkie-friend'),
      info: utf8.encode('$lo-$hi'),
    );
    return PairKey(await k.extractBytes());
  }

  // ---------------------------------------------------------- QR pairing

  /// The QR shown by [ownerId]: a fresh random code. Whoever scans it and
  /// the owner both derive the pair key from it.
  static String qrText({
    required int ownerId,
    required String ownerName,
    required Uint8List code,
  }) =>
      'walkie-friend:1:${ownerId.toRadixString(16)}:'
      '${base64Url.encode(utf8.encode(ownerName))}:${base64Url.encode(code)}';

  static ({int id, String name, Uint8List code})? parseQr(String text) {
    final p = text.trim().split(':');
    if (p.length != 5 || p[0] != 'walkie-friend' || p[1] != '1') return null;
    try {
      final id = int.parse(p[2], radix: 16);
      final name = utf8.decode(base64Url.decode(p[3]));
      final code = base64Url.decode(p[4]);
      if (code.length != 32 || id <= 0) return null;
      return (id: id, name: name, code: Uint8List.fromList(code));
    } catch (_) {
      return null;
    }
  }

  static PairKey fromQrCode(Uint8List code, int ownerId) {
    final mac = DartHmac.sha256().calculateMacSync(
      utf8.encode('qr-${ownerId.toRadixString(16)}'),
      secretKeyData: SecretKeyData(code),
      nonce: const [],
    );
    return PairKey(mac.bytes);
  }
}
