import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Where voice messages and their index files live.
abstract class MessageStorage {
  Future<Object?> readJson(String name);
  Future<void> writeJson(String name, Object? value);
  Future<void> putBlob(String name, Uint8List bytes);
  Future<Uint8List?> getBlob(String name);
  Future<void> deleteBlob(String name);
}

class MemoryMessageStorage implements MessageStorage {
  final Map<String, String> json = {};
  final Map<String, Uint8List> blobs = {};

  @override
  Future<Object?> readJson(String name) async =>
      json[name] == null ? null : jsonDecode(json[name]!);

  @override
  Future<void> writeJson(String name, Object? value) async =>
      json[name] = jsonEncode(value);

  @override
  Future<void> putBlob(String name, Uint8List bytes) async =>
      blobs[name] = bytes;

  @override
  Future<Uint8List?> getBlob(String name) async => blobs[name];

  @override
  Future<void> deleteBlob(String name) async => blobs.remove(name);
}

/// Files in an app-private folder.
class FileMessageStorage implements MessageStorage {
  FileMessageStorage(this.dir);
  final Directory dir;

  File _f(String name) => File('${dir.path}/$name');

  Future<void> _ensure() async {
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  @override
  Future<Object?> readJson(String name) async {
    try {
      final f = _f(name);
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeJson(String name, Object? value) async {
    await _ensure();
    final tmp = _f('$name.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(_f(name).path);
  }

  @override
  Future<void> putBlob(String name, Uint8List bytes) async {
    await _ensure();
    await _f(name).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> getBlob(String name) async {
    try {
      final f = _f(name);
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> deleteBlob(String name) async {
    try {
      final f = _f(name);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
