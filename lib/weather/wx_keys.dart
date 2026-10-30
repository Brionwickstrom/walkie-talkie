import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// This device's own Ed25519 key for signing weather alerts (v2.5.2).
///
/// Made on the device the first time it is needed and kept in a file in the
/// app's private folder (Android: the app's private storage, wrapped by
/// nothing: the Android Keystore has no Ed25519 on the phones we support;
/// Windows: the user's app-data folder next to the settings). There is NO
/// master key in the app and none to share: every device signs with its
/// own, and the people who trust it pin its [id]. Reinstalling the app
/// makes a new key, which has to be trusted again.
class WxDeviceKey {
  WxDeviceKey._(this._seed, this.publicKey);

  final Uint8List _seed;

  /// The 32 byte public key (goes out with every alert).
  final Uint8List publicKey;

  static final _ed = DartEd25519();

  /// Short stable name of this key: the first 10 bytes of SHA-256 of the
  /// public key, in hex (20 characters). What people compare and trust.
  String get id => wxKeyId(publicKey);

  static Future<WxDeviceKey> generate() async {
    final kp = await _ed.newKeyPair();
    final data = await kp.extract();
    final pk = await kp.extractPublicKey();
    return WxDeviceKey._(
      Uint8List.fromList(await data.extractPrivateKeyBytes()),
      Uint8List.fromList(pk.bytes),
    );
  }

  /// The key kept in [file], or a new one saved there. A file that cannot
  /// be read makes a new key (the old one is lost: people who trusted it
  /// must trust the new one).
  static Future<WxDeviceKey> loadOrCreate(File? file) async {
    if (file != null) {
      try {
        if (await file.exists()) {
          final j = jsonDecode(await file.readAsString());
          if (j is Map) {
            final seed = base64Decode(j['seed'] as String);
            final pk = base64Decode(j['pk'] as String);
            if (seed.length == 32 && pk.length == 32) {
              final k = WxDeviceKey._(
                Uint8List.fromList(seed),
                Uint8List.fromList(pk),
              );
              // The pair must belong together.
              final sig = await k.sign(const [1, 2, 3]);
              if (await verify(const [1, 2, 3], sig, pk)) return k;
            }
          }
        }
      } catch (_) {}
    }
    final k = await generate();
    if (file != null) {
      try {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(
          jsonEncode({
            'v': 1,
            'seed': base64Encode(k._seed),
            'pk': base64Encode(k.publicKey),
          }),
        );
        await tmp.rename(file.path);
      } catch (_) {}
    }
    return k;
  }

  Future<Uint8List> sign(List<int> message) async {
    final kp = SimpleKeyPairData(
      _seed,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
    final s = await _ed.sign(message, keyPair: kp);
    return Uint8List.fromList(s.bytes);
  }

  /// Whether [signature] over [message] was made by the key [publicKey].
  static Future<bool> verify(
    List<int> message,
    List<int> signature,
    List<int> publicKey,
  ) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    try {
      return await _ed.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

/// The id of a public key (see [WxDeviceKey.id]): 20 hex characters.
String wxKeyId(List<int> publicKey) {
  final h = const DartSha256().hashSync(publicKey).bytes;
  final sb = StringBuffer();
  for (var i = 0; i < 10; i++) {
    sb.write(h[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// "A1B2 C3D4 E5F6": the id as people compare it (first 12 characters).
String wxKeyShow(String id) {
  final u = id.toUpperCase();
  final s = u.length > 12 ? u.substring(0, 12) : u;
  return [
    for (var i = 0; i < s.length; i += 4)
      s.substring(i, i + 4 > s.length ? s.length : i + 4),
  ].join(' ');
}
