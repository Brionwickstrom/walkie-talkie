// The broker password, sealed, outside SharedPreferences (v2.6.15).
//
// The key and the ciphertext are separate files in the app's private
// support directory, mode 0600 where the OS allows it. They are not in
// the debug log, a settings export, or a radio backup. Android Keystore
// and Windows DPAPI are not used: a copy of this directory contains both
// files, so it is private to the app account, not a hardware-backed secret.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

abstract class MqttSecretStore {
  Future<void> save(String password);
  Future<String?> read();
  Future<void> clear();
}

/// In-memory stand-in for tests. The password is not written anywhere.
class MemoryMqttSecretStore implements MqttSecretStore {
  String? _password;

  @override
  Future<void> save(String password) async {
    _password = password;
  }

  @override
  Future<String?> read() async => _password;

  @override
  Future<void> clear() async {
    _password = null;
  }
}

class SecureMqttSecretStore implements MqttSecretStore {
  SecureMqttSecretStore(this.directory);

  final Directory directory;
  static final _algo = AesGcm.with256bits();

  File get _keyFile => File('${directory.path}/key');
  File get _boxFile => File('${directory.path}/box');

  @override
  Future<void> save(String password) async {
    await directory.create(recursive: true);
    final key = await _algo.newSecretKey();
    final box = await _algo.encrypt(utf8.encode(password), secretKey: key);
    final keyBytes = await key.extractBytes();
    await _keyFile.writeAsBytes(keyBytes, flush: true);
    await _boxFile.writeAsBytes(_pack(box), flush: true);
    await _lock(_keyFile);
    await _lock(_boxFile);
    await _lockDir();
  }

  @override
  Future<String?> read() async {
    if (!await _keyFile.exists() || !await _boxFile.exists()) return null;
    try {
      final key = await _algo.newSecretKeyFromBytes(
        await _keyFile.readAsBytes(),
      );
      final box = _unpack(await _boxFile.readAsBytes());
      if (box == null) return null;
      final clear = await _algo.decrypt(box, secretKey: key);
      final text = utf8.decode(clear);
      return text.isEmpty ? null : text;
    } on SecretBoxAuthenticationError {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> clear() async {
    for (final f in [_keyFile, _boxFile]) {
      if (await f.exists()) await f.delete();
    }
  }

  Uint8List _pack(SecretBox box) {
    final mac = box.mac.bytes;
    final out = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(_len(box.nonce.length))
      ..add(box.nonce)
      ..add(_len(mac.length))
      ..add(mac)
      ..add(_len(box.cipherText.length))
      ..add(box.cipherText);
    return out.toBytes();
  }

  SecretBox? _unpack(Uint8List b) {
    if (b.isEmpty || b[0] != 1) return null;
    var o = 1;
    Uint8List take() {
      if (o + 2 > b.length) throw const FormatException();
      final n = (b[o] << 8) | b[o + 1];
      o += 2;
      if (n < 0 || o + n > b.length) throw const FormatException();
      final v = Uint8List.sublistView(b, o, o + n);
      o += n;
      return Uint8List.fromList(v);
    }

    final nonce = take();
    final mac = take();
    final cipher = take();
    return SecretBox(cipher, nonce: nonce, mac: Mac(mac));
  }

  List<int> _len(int n) => [(n >> 8) & 0xFF, n & 0xFF];

  Future<void> _lock(File f) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', f.path]);
    } catch (_) {}
  }

  Future<void> _lockDir() async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['700', directory.path]);
    } catch (_) {}
  }
}
