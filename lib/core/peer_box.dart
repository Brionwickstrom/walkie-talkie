import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// One-to-one encryption between two phones in a room (v1.9.4).
///
/// Every phone makes a fresh X25519 key pair when the app starts and
/// announces the public half in its hellos (`x.kx`). Two phones that know
/// each other's public key share a secret nobody else in the room can work
/// out, not even a phone that knows the channel passcode. Used for:
///
/// * the new passcode after the admin removes someone from a private
///   channel (rekey `k: 2`), so the removed phone cannot read it, and
/// * direct link setup (dx `e`), so a hidden listener on a public channel
///   does not learn the other phone's addresses / tokens.
///
/// Boxes are AES-256-GCM with a random nonce, keyed by HKDF-SHA256 of the
/// X25519 secret, a purpose label and both public keys. `aad` binds a box
/// to its message (ids, round). The key pair never leaves the phone and is
/// not saved (a new one every app start).
///
/// This protects against listening, not against a phone that actively
/// fakes another phone's hellos with its own key (it would need the
/// passcode on a private channel). Callers only use a key they have seen
/// from exactly one source (see [KxBook]).
class PeerBox {
  PeerBox._(this._kp, this.publicKey);

  static const _x = DartX25519();
  static final _aes = DartAesGcm(secretKeyLength: 32, nonceLength: 12);
  static final _rng = Random.secure();

  final SimpleKeyPairData _kp;

  /// Our public key, base64url (32 bytes).
  final String publicKey;

  final Map<String, Uint8List> _shared = {};

  static Future<PeerBox> create([List<int>? seed]) async {
    final s = seed ?? List<int>.generate(32, (_) => _rng.nextInt(256));
    final kp = await _x.newKeyPairFromSeed(s);
    final data = await kp.extract();
    final pub = await kp.extractPublicKey();
    return PeerBox._(data, base64Url.encode(pub.bytes));
  }

  /// A plausible public key (32 bytes base64url).
  static bool validKey(Object? k) {
    if (k is! String || k.length < 40 || k.length > 48) return false;
    try {
      return base64Url.decode(k).length == 32;
    } catch (_) {
      return false;
    }
  }

  Uint8List? _keyFor(String theirs, String label) {
    if (!validKey(theirs) || theirs == publicKey) return null;
    final cacheKey = '$label\u0000$theirs';
    final hit = _shared[cacheKey];
    if (hit != null) return hit;
    try {
      final secret = _x.sharedSecretSync(
        keyPairData: _kp,
        remotePublicKey: SimplePublicKey(
          base64Url.decode(theirs),
          type: KeyPairType.x25519,
        ),
      );
      final ikm = (secret as SecretKeyData).bytes;
      final lo = publicKey.compareTo(theirs) < 0 ? publicKey : theirs;
      final hi = lo == publicKey ? theirs : publicKey;
      final k = _hkdf(ikm, utf8.encode('walkie-box/v1/$label/$lo/$hi'));
      if (_shared.length > 256) _shared.clear();
      return _shared[cacheKey] = k;
    } catch (_) {
      return null;
    }
  }

  static Uint8List _hkdf(List<int> ikm, List<int> info) {
    final h = DartHmac.sha256();
    final prk = h
        .calculateMacSync(
          ikm,
          secretKeyData: SecretKeyData(utf8.encode('walkie-box-salt')),
          nonce: const [],
        )
        .bytes;
    return Uint8List.fromList(
      h
          .calculateMacSync(
            [...info, 1],
            secretKeyData: SecretKeyData(prk),
            nonce: const [],
          )
          .bytes,
    );
  }

  /// Encrypt [clear] for the phone with public key [theirs]. Null when the
  /// key is not usable.
  String? seal(
    String theirs,
    List<int> clear, {
    required String label,
    List<int> aad = const [],
  }) {
    final k = _keyFor(theirs, label);
    if (k == null) return null;
    final nonce = List<int>.generate(12, (_) => _rng.nextInt(256));
    final box = _aes.encryptSync(
      clear,
      secretKeyData: SecretKeyData(k),
      nonce: nonce,
      aad: aad,
    );
    return base64Url.encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Decrypt a box from the phone with public key [theirs]. Null if it is
  /// not for us, was changed, or [aad] does not match.
  List<int>? open(
    String theirs,
    Object? box, {
    required String label,
    List<int> aad = const [],
  }) {
    if (box is! String || box.length > 4096) return null;
    final k = _keyFor(theirs, label);
    if (k == null) return null;
    try {
      final b = base64Url.decode(box);
      if (b.length < 12 + 16) return null;
      return _aes.decryptSync(
        SecretBox(
          b.sublist(12, b.length - 16),
          nonce: b.sublist(0, 12),
          mac: Mac(b.sublist(b.length - 16)),
        ),
        secretKeyData: SecretKeyData(k),
        aad: aad,
      );
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------- with a shared secret

  /// Box with a secret both phones already share (a friend pair key),
  /// for the same uses as [seal]. Authenticated: only the friend can make
  /// or read it.
  static String sealShared(
    List<int> secret,
    String text, {
    required String label,
    String aad = '',
  }) {
    final k = _hkdf(secret, utf8.encode('walkie-box/v1/shared/$label'));
    final nonce = List<int>.generate(12, (_) => _rng.nextInt(256));
    final box = _aes.encryptSync(
      utf8.encode(text),
      secretKeyData: SecretKeyData(k),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    return base64Url.encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static String? openShared(
    List<int> secret,
    Object? box, {
    required String label,
    String aad = '',
  }) {
    if (box is! String || box.length > 4096) return null;
    try {
      final k = _hkdf(secret, utf8.encode('walkie-box/v1/shared/$label'));
      final b = base64Url.decode(box);
      if (b.length < 12 + 16) return null;
      return utf8.decode(
        _aes.decryptSync(
          SecretBox(
            b.sublist(12, b.length - 16),
            nonce: b.sublist(0, 12),
            mac: Mac(b.sublist(b.length - 16)),
          ),
          secretKeyData: SecretKeyData(k),
          aad: utf8.encode(aad),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  String? sealText(
    String theirs,
    String text, {
    required String label,
    String aad = '',
  }) => seal(theirs, utf8.encode(text), label: label, aad: utf8.encode(aad));

  String? openText(
    String theirs,
    Object? box, {
    required String label,
    String aad = '',
  }) {
    final b = open(theirs, box, label: label, aad: utf8.encode(aad));
    if (b == null) return null;
    try {
      return utf8.decode(b);
    } catch (_) {
      return null;
    }
  }
}

/// Which public keys ([PeerBox.publicKey]) a phone announced recently
/// (kept per phone in `Peer.kxSeen`, updated by every hello).
///
/// A phone with exactly one key in the last [window] is "clear"; two
/// different keys for the same phone id within [window] means someone is
/// faking that phone's hellos (every phone sends one every 1-4 s), and its
/// key is not used. A phone that restarted (new key) is clear again once
/// its old key is older than [window].
class KxBook {
  static const window = Duration(seconds: 20);

  /// Remember [kx] (if it looks like a key) as seen [now].
  static void record(Map<String, DateTime> seen, Object? kx, DateTime now) {
    if (!PeerBox.validKey(kx)) return;
    seen[kx as String] = now;
    if (seen.length > 4) {
      final oldest = seen.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      seen.remove(oldest.key);
    }
  }

  static Iterable<String> _recent(Map<String, DateTime> seen, DateTime now) =>
      seen.entries
          .where((e) => now.difference(e.value) <= window)
          .map((e) => e.key);

  /// The one key seen recently, null when none or several.
  static String? keyIn(Map<String, DateTime> seen, DateTime now) {
    final r = _recent(seen, now).toList();
    return r.length == 1 ? r.first : null;
  }

  /// More than one key seen recently (someone fakes this phone).
  static bool conflictIn(Map<String, DateTime> seen, DateTime now) =>
      _recent(seen, now).length > 1;
}
