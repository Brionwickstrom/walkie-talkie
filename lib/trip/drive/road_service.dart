import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../geo.dart';
import 'road_data.dart';
import 'road_router.dart';

/// Routing over the saved road areas (all of them joined into one
/// network). Runs in a background isolate so the map stays smooth; the
/// [RoadService.inline] form runs on the calling isolate (tests).
class RoadService {
  RoadService() : _inline = false;
  RoadService.inline() : _inline = true;

  final bool _inline;
  String _key = '';
  RoadGraph? _graph; // inline
  SendPort? _port;
  Isolate? _iso;
  Future<void>? _loading;

  /// Files loaded (paths joined).
  String get loadedKey => _key;

  /// Load these `.wtr` files (no-op when already loaded).
  Future<void> load(List<String> paths) async {
    final key = paths.join('|');
    if (key == _key && _loading != null) return _loading;
    _key = key;
    return _loading = _inline
        ? _loadInline(paths)
        : _call(('load', paths)).then((_) {});
  }

  Future<void> _loadInline(List<String> paths) async {
    _graph = buildGraph(paths);
  }

  static RoadGraph? buildGraph(List<String> paths) {
    final parts = <RoadData>[];
    for (final p in paths) {
      try {
        parts.add(RoadData.decode(File(p).readAsBytesSync()));
      } catch (_) {}
    }
    if (parts.isEmpty) return null;
    return RoadGraph(RoadData.merge(parts));
  }

  Future<DriveRoute?> route(
    GeoPoint from,
    GeoPoint to, {
    String name = '',
    bool imperial = true,
    DateTime? now,
  }) async {
    await _loading;
    if (_inline) {
      return _graph?.route(
        from,
        to,
        targetName: name,
        imperial: imperial,
        now: now,
      );
    }
    return await _call(('route', from, to, name, imperial, now)) as DriveRoute?;
  }

  /// Nearest road within [maxM].
  Future<RoadSnap?> snap(GeoPoint p, {double maxM = 3000}) async {
    await _loading;
    if (_inline) return _graph?.snap(p, maxM: maxM);
    return await _call(('snap', p, maxM)) as RoadSnap?;
  }

  Future<Object?> _call(Object msg) async {
    final port = await _worker();
    final reply = ReceivePort();
    port.send((msg, reply.sendPort));
    final r = await reply.first;
    reply.close();
    if (r is RemoteError) throw r;
    return r;
  }

  Future<SendPort> _worker() async {
    final p = _port;
    if (p != null) return p;
    final rp = ReceivePort();
    _iso = await Isolate.spawn(_main, rp.sendPort, debugName: 'roads');
    return _port = await rp.first as SendPort;
  }

  static void _main(SendPort out) {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    RoadGraph? g;
    inbox.listen((m) {
      final (msg, SendPort reply) = m as (Object, SendPort);
      try {
        switch (msg) {
          case ('load', List<String> paths):
            g = buildGraph(paths);
            reply.send(null);
          case (
            'route',
            GeoPoint a,
            GeoPoint b,
            String n,
            bool imp,
            DateTime? now,
          ):
            reply.send(g?.route(a, b, targetName: n, imperial: imp, now: now));
          case ('snap', GeoPoint p, double maxM):
            reply.send(g?.snap(p, maxM: maxM));
          default:
            reply.send(null);
        }
      } catch (e, st) {
        reply.send(RemoteError('$e', '$st'));
      }
    });
  }

  void dispose() {
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _port = null;
  }
}
