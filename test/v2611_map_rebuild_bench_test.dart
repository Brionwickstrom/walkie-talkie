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

  testWidgets('the map rebuilding with a 7000-point imported trail', (
    tester,
  ) async {
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
    final key = GlobalKey<_BenchMapState>();
    final first = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        home: _BenchMap(key: key, trip: t),
      ),
    );
    first.stop();
    _say(
      'first map frame with the imported trail: '
      '${first.elapsedMilliseconds} ms',
    );
    await tester.pump();
    final sw = Stopwatch();
    for (var i = 0; i < 10; i++) {
      key.currentState!.poke();
      sw.start();
      await tester.pump();
      sw.stop();
    }
    final per = sw.elapsedMicroseconds / 10 / 1000;
    _say('map rebuild with the imported trail: ${per.toStringAsFixed(2)} ms');
    await tester.pumpWidget(const SizedBox());
    t.dispose();
  });
}

/// The Trip map's layer stack as the page builds it (2 s tick = poke).
class _BenchMap extends StatefulWidget {
  const _BenchMap({super.key, required this.trip});
  final TripController trip;
  @override
  State<_BenchMap> createState() => _BenchMapState();
}

class _BenchMapState extends State<_BenchMap> {
  void poke() => setState(() {});
  @override
  Widget build(BuildContext context) => FlutterMap(
    options: const MapOptions(
      initialCenter: LatLng(45.3, -122),
      initialZoom: 11,
    ),
    children: [...benchLayers(widget.trip)],
  );
}

/// The imported layers the way the Trip map gets them.
List<Widget> benchLayers(TripController t) => importedLayers(t);
