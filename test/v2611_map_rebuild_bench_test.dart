// v2.6.11: the Trip map's layers rebuilding, measured (a widget test, so
// in its own file: widget tests answer every HTTP request with 400, which
// would spoil the tile timings in v2611_map_start_bench_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:walkie_talkie/trip/trip_controller.dart';
import 'package:walkie_talkie/trip/trip_settings.dart';
import 'package:walkie_talkie/ui/map_layer_widgets.dart';

import 'trip_integration_test.dart' show FakeHost;

void _say(String s) => debugPrint('bench: $s');

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('b2611w'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<TripController> bigTrail(WidgetTester tester) async {
    final dir = Directory('${tmp.path}/trip');
    late TripController t;
    await tester.runAsync(() async {
      t = TripController(
        host: FakeHost(0x1234),
        settings: TripSettings(),
        dir: dir,
        userAgent: 't',
      );
      t.tiles.online = false;
      await t.start();
      final b = StringBuffer(
        '<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>',
      );
      for (var i = 0; i < 50000; i++) {
        final w = (i % 7) * 3e-4 * (i.isEven ? 1 : -1);
        b.write('<trkpt lat="${45 + i * 2e-5}" lon="${-122 + w}"/>');
      }
      b.write('</trkseg></trk></gpx>');
      await t.layers.importTrail('big.gpx', utf8.encode(b.toString()));
    });
    return t;
  }

  for (final v2611 in [false, true]) {
    final how = v2611 ? 'v2.6.11' : 'v2.6.10';
    testWidgets('$how: the map with a 7000-point imported trail', (
      tester,
    ) async {
      final t = await bigTrail(tester);
      // Warm up (the first map built in a run pays for loading code).
      for (final w in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: _BenchMap(trip: t, v2611: w),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
      }
      final key = GlobalKey<_BenchMapState>();
      final first = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: _BenchMap(key: key, trip: t, v2611: v2611),
        ),
      );
      first.stop();
      _say(
        '$how first map frame with the imported trail: '
        '${first.elapsedMilliseconds} ms',
      );
      final second = Stopwatch()..start();
      await tester.pump();
      await tester.pump();
      second.stop();
      _say('$how next frames (trail drawn): ${second.elapsedMilliseconds} ms');
      expect(find.byType(PolylineLayer), findsOneWidget);
      final sw = Stopwatch();
      for (var i = 0; i < 10; i++) {
        key.currentState!.poke();
        sw.start();
        await tester.pump();
        sw.stop();
      }
      final per = sw.elapsedMicroseconds / 10 / 1000;
      _say(
        '$how map refresh with the imported trail: '
        '${per.toStringAsFixed(2)} ms',
      );
      // A change to the layers still shows (the cache follows it).
      final l = t.layers.trails.first;
      await tester.runAsync(() => t.layers.setVisible(l, false));
      key.currentState!.poke();
      await tester.pump();
      await tester.pump();
      expect(find.byType(PolylineLayer), findsNothing);
      await tester.pumpWidget(const SizedBox());
      t.dispose();
    });
  }
}

/// The Trip map's layer stack the way each version builds it (the 2 s
/// refresh = poke): v2.6.10 builds every layer in the first frame and
/// again on every refresh; v2.6.11 adds them one frame after the map
/// and reuses them until they change (as lib/ui/trip_page.dart does).
class _BenchMap extends StatefulWidget {
  const _BenchMap({super.key, required this.trip, required this.v2611});
  final TripController trip;
  final bool v2611;
  @override
  State<_BenchMap> createState() => _BenchMapState();
}

class _BenchMapState extends State<_BenchMap> {
  final _cache = ImportedLayersCache();
  bool _ready = false;
  void poke() => setState(() {});
  @override
  Widget build(BuildContext context) => FlutterMap(
    options: MapOptions(
      initialCenter: const LatLng(45.3, -122),
      initialZoom: 11,
      onMapReady: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _ready = true);
        });
      },
    ),
    children: [
      if (!widget.v2611) ...importedLayers(widget.trip),
      if (widget.v2611 && _ready) ..._cache.of(widget.trip),
    ],
  );
}
