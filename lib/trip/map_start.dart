// v2.6.11: faster map start. The map opens where it was last left (no
// waiting for GPS), and the home area is kept ready on the phone, but only
// on Wi-Fi or while charging, so it costs no battery or mobile data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'geo.dart';
import 'tile_cache.dart';

/// Where the map was last looking.
class SavedCamera {
  const SavedCamera(this.center, this.zoom, this.at);
  final GeoPoint center;
  final double zoom;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'la': center.lat,
    'lo': center.lng,
    'z': zoom,
    'at': at.millisecondsSinceEpoch,
  };

  static SavedCamera? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final lat = (j['la'] as num).toDouble();
      final lng = (j['lo'] as num).toDouble();
      final z = (j['z'] as num).toDouble();
      if (lat.abs() > 85 || lng.abs() > 180 || !z.isFinite) return null;
      return SavedCamera(
        GeoPoint(lat, lng),
        z.clamp(2.0, 19.0),
        DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Remembers the camera in a small file: written at most every few
/// seconds while the map moves, and when the map closes.
class CameraMemory {
  CameraMemory(this.file, {this.debounce = const Duration(seconds: 3)});
  final File file;
  final Duration debounce;
  SavedCamera? camera;
  Timer? _write;

  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      camera = SavedCamera.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {}
  }

  void remember(GeoPoint center, double zoom, {DateTime? at}) {
    if (!center.lat.isFinite || !center.lng.isFinite || !zoom.isFinite) {
      return;
    }
    camera = SavedCamera(center, zoom, at ?? DateTime.now());
    _write ??= Timer(debounce, () => unawaited(flush()));
  }

  Future<void> flush() async {
    _write?.cancel();
    _write = null;
    final c = camera;
    if (c == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(c.toJson()));
    } catch (_) {}
  }

  void dispose() {
    if (_write != null) unawaited(flush());
  }
}

/// Why the map opened where it did.
enum MapStartFrom { focus, gps, lastView, friend, pin, country }

/// Where the map opens: a point it was asked to show, else my GPS fix if
/// there already is one, else where it was last left (instead of the
/// whole country while GPS warms up), else a friend or a pin.
({GeoPoint center, double zoom, MapStartFrom from}) mapStartView({
  GeoPoint? focus,
  GeoPoint? fix,
  SavedCamera? saved,
  GeoPoint? friend,
  GeoPoint? pin,
}) {
  if (focus != null) return (center: focus, zoom: 15, from: MapStartFrom.focus);
  if (fix != null) return (center: fix, zoom: 15, from: MapStartFrom.gps);
  if (saved != null) {
    return (
      center: saved.center,
      zoom: saved.zoom,
      from: MapStartFrom.lastView,
    );
  }
  if (friend != null) {
    return (center: friend, zoom: 15, from: MapStartFrom.friend);
  }
  if (pin != null) return (center: pin, zoom: 15, from: MapStartFrom.pin);
  return (
    center: const GeoPoint(39.5, -98.35),
    zoom: 4,
    from: MapStartFrom.country,
  );
}

/// Whether the phone is on Wi-Fi (or the PC on a wired or Wi-Fi network):
/// an up Wi-Fi interface with an address. Cell data never counts.
Future<bool> isOnWifi() async {
  if (!Platform.isAndroid && !Platform.isIOS) return true; // PC: unmetered
  try {
    final list = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    return list.any(
      (i) =>
          (i.name.startsWith('wlan') || i.name == 'en0') &&
          i.addresses.any((a) => !a.isLinkLocal),
    );
  } catch (_) {
    return false;
  }
}

/// Keeps the map around home on the phone (v2.6.11), so the map opens
/// there with no download: about 100 tiles (1-3 MB) once a week, only on
/// Wi-Fi or while charging, only from map services that allow saving
/// ahead, polite (one tile a second), skipping tiles already there.
class HomeWarmer {
  HomeWarmer({
    required this.tiles,
    required this.stamp,
    DateTime Function()? clock,
    this.pause = const Duration(seconds: 1),
  }) : _clock = clock ?? DateTime.now;
  final TileCache tiles;
  final File stamp;
  final DateTime Function() _clock;
  final Duration pause;

  /// How far around home, and which zooms (town to street level).
  static const radiusM = 1500.0;
  static const minZoom = 12;
  static const maxZoom = 15;
  static const maxTiles = 120;
  static const every = Duration(days: 7);

  bool running = false;
  DownloadProgress? _p;

  /// The tiles around [home].
  static List<TileId> tilesAround(GeoPoint home) {
    final dLat = radiusM / 111320;
    final dLng =
        radiusM / (111320 * cos(home.lat * pi / 180)).abs().clamp(1, 1e9);
    final b = GeoBounds(
      home.lat - dLat,
      home.lng - dLng,
      home.lat + dLat,
      home.lng + dLng,
    );
    return tilesIn(b, minZoom, maxZoom).take(maxTiles).toList();
  }

  /// Null when it may run now, else why not (plain words).
  static String? blocker({
    required bool enabled,
    required bool wifi,
    required bool charging,
    required bool offlineSaver,
    required bool online,
    required GeoPoint? home,
    required MapSource source,
  }) {
    if (!enabled) return 'Keep home area ready is off.';
    if (offlineSaver) return 'Offline power save is on.';
    if (!online) return 'No internet.';
    if (!wifi && !charging) return 'Waiting for Wi-Fi or a charger.';
    if (home == null) return 'No home location yet.';
    if (!source.allowsOffline || source.onlineOnly) {
      return '${source.name} does not allow saving maps ahead.';
    }
    return null;
  }

  Future<Map<String, Object?>?> _last() async {
    try {
      if (!await stamp.exists()) return null;
      return (jsonDecode(await stamp.readAsString()) as Map)
          .cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  /// Due: never done, a week since, home moved over 1 km, or another map.
  Future<bool> due(GeoPoint home, MapSource s) async {
    final j = await _last();
    if (j == null) return true;
    try {
      final at = DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt());
      final p = GeoPoint(
        (j['la'] as num).toDouble(),
        (j['lo'] as num).toDouble(),
      );
      if (j['src'] != s.id) return true;
      if (distanceM(p, home) > 1000) return true;
      return _clock().difference(at) >= every;
    } catch (_) {
      return true;
    }
  }

  /// Fetches the missing tiles around [home]; returns how many it fetched.
  /// [stillOk] is asked before each tile (Wi-Fi / charger still there).
  Future<int> run(
    MapSource s,
    GeoPoint home, {
    Future<bool> Function()? stillOk,
  }) async {
    if (running) return 0;
    running = true;
    final p = _p = DownloadProgress(0);
    var got = 0, failsInRow = 0;
    try {
      for (final t in tilesAround(home)) {
        if (p.cancelled) break;
        if (await tiles.has(s, t.z, t.x, t.y)) continue;
        if (stillOk != null && !await stillOk()) break;
        final b = await tiles.get(s, t.z, t.x, t.y);
        if (b != null && b.isNotEmpty) {
          got++;
          failsInRow = 0;
        } else if (++failsInRow >= 6) {
          break; // no signal: stop, try another day
        }
        if (pause > Duration.zero) await Future<void>.delayed(pause);
      }
      if (!p.cancelled && failsInRow < 6) {
        try {
          await stamp.parent.create(recursive: true);
          await stamp.writeAsString(
            jsonEncode({
              'at': _clock().millisecondsSinceEpoch,
              'la': home.lat,
              'lo': home.lng,
              'src': s.id,
            }),
          );
        } catch (_) {}
      }
    } finally {
      running = false;
      _p = null;
    }
    return got;
  }

  void cancel() => _p?.cancelled = true;
}
