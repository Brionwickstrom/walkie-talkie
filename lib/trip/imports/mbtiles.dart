import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../tile_cache.dart';

/// Read-only access to an MBTiles file (raster tiles in SQLite, spec 1.3).
/// Rows use TMS order: tile_row counts from the south, so XYZ y is flipped.
class MbTiles {
  MbTiles._(this.path, this._db, this.metadata);

  /// Opens [path] read only. Throws [FormatException] if it is not a raster
  /// MBTiles file.
  factory MbTiles.open(String path) {
    final Database db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);
    } catch (e) {
      throw FormatException('Not an MBTiles file ($e)');
    }
    try {
      final tables = {
        for (final r in db.select(
          "SELECT name FROM sqlite_master WHERE type IN ('table','view')",
        ))
          r['name'] as String,
      };
      if (!tables.contains('tiles') || !tables.contains('metadata')) {
        throw const FormatException('Not an MBTiles file (no tiles table)');
      }
      final meta = <String, String>{
        for (final r in db.select('SELECT name, value FROM metadata'))
          '${r['name']}': '${r['value']}',
      };
      final fmt = (meta['format'] ?? '').toLowerCase();
      if (fmt == 'pbf' || fmt == 'mvt') {
        throw const FormatException(
          'Vector MBTiles are not supported; use a raster (PNG/JPG) file',
        );
      }
      return MbTiles._(path, db, meta);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  final String path;
  final Database _db;
  final Map<String, String> metadata;
  PreparedStatement? _get;
  bool _closed = false;

  String get name => metadata['name'] ?? '';
  String get format => (metadata['format'] ?? 'png').toLowerCase();
  String get attribution => metadata['attribution'] ?? '';

  int get minZoom => int.tryParse(metadata['minzoom'] ?? '') ?? _zoomRange.$1;
  int get maxZoom => int.tryParse(metadata['maxzoom'] ?? '') ?? _zoomRange.$2;

  (int, int)? _zr;
  (int, int) get _zoomRange => _zr ??= () {
    final r = _db.select(
      'SELECT MIN(zoom_level) AS a, MAX(zoom_level) AS b FROM tiles',
    );
    final a = r.isEmpty ? null : r.first['a'] as int?;
    final b = r.isEmpty ? null : r.first['b'] as int?;
    return (a ?? 0, b ?? 0);
  }();

  /// "west,south,east,north" from metadata.
  GeoBounds? get bounds {
    final v = (metadata['bounds'] ?? '').split(',');
    if (v.length != 4) return null;
    final n = [for (final s in v) double.tryParse(s.trim())];
    if (n.any((x) => x == null)) return null;
    return GeoBounds(n[1]!, n[0]!, n[3]!, n[2]!);
  }

  /// "lng,lat,zoom" from metadata.
  (double lat, double lng, int zoom)? get center {
    final v = (metadata['center'] ?? '').split(',');
    if (v.length < 2) return null;
    final lng = double.tryParse(v[0].trim()), lat = double.tryParse(v[1]);
    if (lat == null || lng == null) return null;
    return (lat, lng, v.length > 2 ? int.tryParse(v[2].trim()) ?? 12 : 12);
  }

  int get tileCount =>
      _db.select('SELECT COUNT(*) AS n FROM tiles').first['n'] as int;

  /// Tile bytes for XYZ (slippy map) coordinates, null if absent.
  Uint8List? tile(int z, int x, int y) {
    if (_closed || z < 0 || z > 30) return null;
    final row = (1 << z) - 1 - y; // XYZ -> TMS
    final st = _get ??= _db.prepare(
      'SELECT tile_data FROM tiles '
      'WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?',
    );
    final r = st.select([z, x, row]);
    if (r.isEmpty) return null;
    final d = r.first['tile_data'];
    if (d is Uint8List) return d;
    if (d is List<int>) return Uint8List.fromList(d);
    return null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _get?.dispose();
    _db.dispose();
  }
}
