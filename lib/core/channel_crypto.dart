import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'frame.dart';

/// Key material for one private (passcode protected) channel.
///
/// * The passcode is stretched with PBKDF2-HMAC-SHA256 ([iterations] rounds)
///   using a fixed app salt plus the channel number, so the same passcode on
///   CH 3 and CH 4 gives unrelated keys.
/// * Two sub keys are derived from that with HMAC-SHA256: the AES-256-GCM
///   key, and a 16 bit "tag" that replaces the channel number in the frame
///   header. Outsiders only ever see the tag, not which channel it is.
/// * Every frame on a private channel travels as a [FrameType.sealed] frame:
///
/// ```
/// header (12 B, as Frame, type = sealed, channel = tag)   <- authenticated
/// nonce  (12 B, random per packet)
/// ciphertext of [inner type (1 B)] + [inner payload]
/// GCM tag (16 B)
/// ```
///
/// Frames that do not decrypt (wrong passcode, other group with the same
/// tag, tampering) are dropped without a trace.
class ChannelKey {
  ChannelKey._(
    this.channel,
    this._encKey,
    this.tag,
    this.fingerprint, {
    this.groupId,
  });

  /// Fixed app salt; the channel number is appended. Used by private
  /// groups made before v2.3.0 ("legacy": the old phones still derive the
  /// key this way, so they keep working together).
  static const String salt = 'WalkieTalkie/private-channel/v1/ch=';

  /// v2.3.0 private groups: the random group id is appended instead of a
  /// channel number (a group is not tied to any channel).
  static const String groupSalt = 'WalkieTalkie/private-group/v2/id=';
  static const int iterations = 120000;
  static const int nonceLength = 12;
  static const int macLength = 16;

  /// Extra bytes a sealed frame carries compared to the plain frame:
  /// nonce + GCM tag + the inner type byte.
  static const int overhead = nonceLength + macLength + 1;

  static final _aes = DartAesGcm(secretKeyLength: 32, nonceLength: nonceLength);
  static final _rng = Random.secure();

  /// Channel number for a legacy group key, 0 for a v2.3.0 group key.
  final int channel;

  /// Group id of a v2.3.0 group key, null for a legacy (channel number) key.
  final String? groupId;
  final SecretKeyData _encKey;

  /// 16 bit identifier sent in place of the channel number.
  final int tag;

  /// Short hex string that is the same on every phone with the same
  /// channel + passcode (shown in the UI to double check).
  final String fingerprint;

  /// Passcodes are compared after trimming surrounding spaces.
  static String normalize(String passcode) => passcode.trim();

  /// Derive the key (slow on purpose, runs in a background isolate).
  static Future<ChannelKey> derive(
    int channel,
    String passcode, {
    int iterations = iterations,
  }) async {
    final pass = normalize(passcode);
    final master = await Isolate.run(() => _stretch(channel, pass, iterations));
    return fromMaster(channel, master);
  }

  /// Synchronous derivation for tests (same result as [derive]).
  static Future<ChannelKey> deriveInline(
    int channel,
    String passcode, {
    int iterations = iterations,
  }) async => fromMaster(
    channel,
    await _stretch(channel, normalize(passcode), iterations),
  );

  /// Key of a v2.3.0 private group: the random group [id] plus the group's
  /// secret (a generated passcode, or one typed). No channel number.
  static Future<ChannelKey> deriveGroup(
    String id,
    String secret, {
    int iterations = iterations,
  }) async {
    final pass = normalize(secret);
    final master = await Isolate.run(
      () => _stretchWith('$groupSalt$id', pass, iterations),
    );
    return fromMaster(0, master, groupId: id);
  }

  /// Same as [deriveGroup] without the isolate (tests).
  static Future<ChannelKey> deriveGroupInline(
    String id,
    String secret, {
    int iterations = iterations,
  }) async => fromMaster(
    0,
    await _stretchWith('$groupSalt$id', normalize(secret), iterations),
    groupId: id,
  );

  static Future<List<int>> _stretch(
    int channel,
    String passcode,
    int iterations,
  ) => _stretchWith('$salt$channel', passcode, iterations);

  static Future<List<int>> _stretchWith(
    String saltText,
    String passcode,
    int iterations,
  ) async {
    final kdf = DartPbkdf2(
      macAlgorithm: DartHmac.sha256(),
      iterations: iterations,
      bits: 256,
      pauseFrequency: 1 << 30,
    );
    final k = await kdf.deriveKeyFromPassword(
      password: passcode,
      nonce: utf8.encode(saltText),
    );
    return k.extractBytes();
  }

  static ChannelKey fromMaster(
    int channel,
    List<int> master, {
    String? groupId,
  }) {
    final hmac = DartHmac.sha256();
    final mk = SecretKeyData(master);
    List<int> sub(String label) => hmac
        .calculateMacSync(
          utf8.encode(label),
          secretKeyData: mk,
          nonce: const [],
        )
        .bytes;
    final enc = sub('enc');
    final t = sub('tag');
    final fp = sub('fingerprint');
    return ChannelKey._(
      channel,
      SecretKeyData(enc),
      (t[0] << 8) | t[1],
      [for (final b in fp.take(3)) b.toRadixString(16).padLeft(2, '0')]
          .join()
          .toUpperCase(),
      groupId: groupId,
    );
  }

  /// Encrypt [inner] into a sealed frame (encoded bytes, ready to send).
  Uint8List seal(Frame inner) {
    final header = Frame(
      type: FrameType.sealed,
      senderId: inner.senderId,
      channel: tag,
      seq: inner.seq,
      payload: Uint8List(0),
    ).encode();
    final clear = Uint8List(1 + inner.payload.length)
      ..[0] = inner.type.code
      ..setRange(1, 1 + inner.payload.length, inner.payload);
    final nonce = Uint8List(nonceLength);
    for (var i = 0; i < nonceLength; i++) {
      nonce[i] = _rng.nextInt(256);
    }
    final box = _aes.encryptSync(
      clear,
      secretKeyData: _encKey,
      nonce: nonce,
      aad: header,
    );
    final out = Uint8List(
      Frame.headerSize + nonceLength + box.cipherText.length + macLength,
    );
    out.setRange(0, Frame.headerSize, header);
    var o = Frame.headerSize;
    out.setRange(o, o += nonceLength, nonce);
    out.setRange(o, o += box.cipherText.length, box.cipherText);
    out.setRange(o, o + macLength, box.mac.bytes);
    return out;
  }

  /// Decrypt a received sealed frame. Null if it is not for us or does not
  /// authenticate.
  Frame? open(Frame outer) {
    if (outer.type != FrameType.sealed || outer.channel != tag) return null;
    final p = outer.payload;
    if (p.length < nonceLength + 1 + macLength) return null;
    final header = Frame(
      type: FrameType.sealed,
      senderId: outer.senderId,
      channel: outer.channel,
      seq: outer.seq,
      payload: Uint8List(0),
    ).encode();
    try {
      final clear = _aes.decryptSync(
        SecretBox(
          Uint8List.sublistView(p, nonceLength, p.length - macLength),
          nonce: Uint8List.sublistView(p, 0, nonceLength),
          mac: Mac(Uint8List.sublistView(p, p.length - macLength)),
        ),
        secretKeyData: _encKey,
        aad: header,
      );
      if (clear.isEmpty) return null;
      final type = FrameType.fromCode(clear[0]);
      if (type == null || type == FrameType.sealed) return null;
      return Frame(
        type: type,
        senderId: outer.senderId,
        channel: tag,
        seq: outer.seq,
        payload: Uint8List.fromList(clear.sublist(1)),
      );
    } catch (_) {
      return null;
    }
  }
}
