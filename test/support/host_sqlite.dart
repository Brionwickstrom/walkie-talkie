import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// Point package:sqlite3 at the machine's own SQLite for host tests (on
/// phones sqlite3_flutter_libs bundles one). Linux often only has
/// libsqlite3.so.0; Windows 10+ ships winsqlite3.dll. Returns false if none
/// loads (tests that need it are skipped then).
bool useHostSqlite() {
  final names = Platform.isWindows
      ? ['sqlite3.dll', 'winsqlite3.dll']
      : Platform.isMacOS
      ? ['libsqlite3.dylib', '/usr/lib/libsqlite3.dylib']
      : ['libsqlite3.so', 'libsqlite3.so.0'];
  for (final n in names) {
    try {
      final lib = DynamicLibrary.open(n);
      open.overrideForAll(() => lib);
      sqlite3.version; // really usable?
      return true;
    } catch (_) {}
  }
  return false;
}
