import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../trip/geo.dart';
import '../trip/imports/georef.dart';
import '../trip/imports/map_layers.dart';
import '../trip/trip_controller.dart';
import 'map_layer_widgets.dart';

enum _Mode { fit, points }

/// Place an imported park map (image / PDF page) on the map: either drag,
/// pinch and twist it into place ("Fit"), or tap 2-3 matching spots on the
/// image and then on the map ("Control points").
class OverlayPlacePage extends StatefulWidget {
  const OverlayPlacePage({super.key, required this.trip, required this.layer});
  final TripController trip;
  final MapLayer layer;
  @override
  State<OverlayPlacePage> createState() => _OverlayPlacePageState();
}

class _OverlayPlacePageState extends State<OverlayPlacePage> {
  MapLayer get l => widget.layer;
  TripController get trip => widget.trip;
  final MapController _map = MapController();
  final TransformationController _img = TransformationController();
  bool _fitted = false;
  _Mode _mode = _Mode.fit;
  bool _ready = false;

  // Fit mode.
  GeoPoint? _center;
  double _widthM = 1000;
  double _rotation = 0;
  bool _adjust = true;
  GeoPoint? _startCenter;
  double _startWidth = 1000, _startRot = 0;
  Offset _startFocal = Offset.zero;

  // Control point mode: pairs (image pixel, map spot).
  final List<ImagePx?> _px = [];
  final List<GeoPoint?> _geo = [];

  late double _opacity = l.opacity;

  double get _w => l.imageW.toDouble();
  double get _h => l.imageH.toDouble();

  GeoPoint get _start =>
      l.georef?.toMap((u: _w / 2, v: _h / 2)) ??
      trip.myFix?.pos ??
      (trip.people.values.isNotEmpty ? trip.people.values.first.pos : null) ??
      const GeoPoint(39.5, -98.35);

  @override
  void initState() {
    super.initState();
    final g = l.georef;
    if (g != null) {
      _center = g.toMap((u: _w / 2, v: _h / 2));
      _widthM = g.metresPerPixel(_center!) * _w;
      _rotation = g.rotationDeg > 180 ? g.rotationDeg - 360 : g.rotationDeg;
    }
  }

  Georef? get _fitRef => _center == null
      ? null
      : Georef.fit(
          center: _center!,
          widthM: _widthM,
          rotationDeg: _rotation,
          w: _w,
          h: _h,
        );

  List<ControlPoint> get _pairs => [
    for (var i = 0; i < min(_px.length, _geo.length); i++)
      if (_px[i] != null && _geo[i] != null) ControlPoint(_px[i]!, _geo[i]!),
  ];

  Georef? get _ref => _mode == _Mode.fit
      ? _fitRef
      : Georef.fromControlPoints(_pairs.take(3).toList());

  void _onMapReady() {
    _ready = true;
    if (_center == null) {
      final b = _map.camera.visibleBounds;
      setState(() {
        _center = gpOf(_map.camera.center);
        _widthM =
            distanceM(
              GeoPoint(_map.camera.center.latitude, b.west),
              GeoPoint(_map.camera.center.latitude, b.east),
            ) *
            0.8;
      });
    }
  }

  static GeoPoint gpOf(LatLng p) => GeoPoint(p.latitude, p.longitude);

  Future<void> _save() async {
    final g = _ref;
    if (g == null) return;
    await trip.layers.setOpacity(l, _opacity);
    await trip.layers.setGeoref(l, g);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final g = _ref;
    return Scaffold(
      appBar: AppBar(
        title: Text('Place ${l.name}'),
        actions: [
          TextButton(
            onPressed: g == null ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(
                  value: _Mode.fit,
                  icon: Icon(Icons.open_with),
                  label: Text('Drag to fit'),
                ),
                ButtonSegment(
                  value: _Mode.points,
                  icon: Icon(Icons.control_point),
                  label: Text('Control points'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _mode == _Mode.fit
                  ? 'Drag the park map, pinch to size it, twist to turn it '
                        'until roads and trails line up. Turn off "Adjust" to '
                        'move the map instead.'
                  : 'Tap a spot on the park map (top), then the same spot on '
                        'the real map (bottom). 2 points: move, size and turn. '
                        '3 points: also fixes maps not drawn to scale.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_mode == _Mode.points) Expanded(child: _imagePicker()),
          Expanded(flex: _mode == _Mode.fit ? 1 : 1, child: _mapView(g)),
          _controls(g),
        ],
      ),
    );
  }

  Widget _imagePicker() {
    final next = _px.length > _geo.length ? null : _px.length;
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, box) {
            if (!_fitted && box.maxWidth > 0 && box.maxHeight > 0) {
              _fitted = true;
              final k = min(box.maxWidth / _w, box.maxHeight / _h);
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _img.value = Matrix4.diagonal3Values(k, k, 1),
              );
            }
            return const SizedBox.shrink();
          },
        ),
        Container(
          color: Colors.black12,
          child: InteractiveViewer(
            transformationController: _img,
            maxScale: 12,
            minScale: 0.2,
            constrained: false,
            boundaryMargin: const EdgeInsets.all(400),
            child: GestureDetector(
              onTapUp: (d) {
                if (_pairs.length >= 3 && _px.length == _geo.length) return;
                final p = d.localPosition;
                setState(() {
                  final px = (u: p.dx, v: p.dy);
                  if (_px.length > _geo.length) {
                    _px[_px.length - 1] = px;
                  } else {
                    _px.add(px);
                  }
                });
              },
              child: SizedBox(
                width: _w,
                height: _h,
                child: Stack(
                  children: [
                    Image.file(
                      trip.layers.fileOf(l),
                      width: _w,
                      height: _h,
                      fit: BoxFit.fill,
                    ),
                    for (var i = 0; i < _px.length; i++)
                      if (_px[i] != null)
                        Positioned(
                          left: _px[i]!.u - 14,
                          top: _px[i]!.v - 14,
                          child: _num(i, big: true),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 8,
          top: 8,
          child: Chip(
            label: Text(
              next == null
                  ? 'Now tap point ${_px.length} on the map below'
                  : _pairs.length >= 3
                  ? '3 points set'
                  : 'Tap point ${next + 1} on the park map',
            ),
          ),
        ),
      ],
    );
  }

  Widget _num(int i, {bool big = false}) => Container(
    width: big ? 28 : 22,
    height: big ? 28 : 22,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Colors.deepOrange,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
    ),
    child: Text(
      '${i + 1}',
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: 12,
      ),
    ),
  );

  Widget _mapView(Georef? g) {
    final fitAdjust = _mode == _Mode.fit && _adjust;
    final map = FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: LatLng(_start.lat, _start.lng),
        initialZoom: 14,
        maxZoom: 19,
        minZoom: 2,
        onMapReady: _onMapReady,
        interactionOptions: InteractionOptions(
          flags: fitAdjust
              ? InteractiveFlag.none
              : InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onTap: _mode == _Mode.points
            ? (_, p) {
                if (_px.length <= _geo.length) return;
                setState(() => _geo.add(gpOf(p)));
              }
            : null,
      ),
      children: [
        ...baseTileLayers(trip),
        ...importedLayers(trip, skipOverlay: l.id),
        if (g != null)
          OverlayImageLayer(
            overlayImages: [
              placedOverlay(
                FileImage(trip.layers.fileOf(l)),
                g,
                l.imageW,
                l.imageH,
                _opacity,
              ),
            ],
          ),
        if (_mode == _Mode.points)
          MarkerLayer(
            markers: [
              for (var i = 0; i < _geo.length; i++)
                if (_geo[i] != null)
                  Marker(
                    point: LatLng(_geo[i]!.lat, _geo[i]!.lng),
                    width: 24,
                    height: 24,
                    child: _num(i),
                  ),
            ],
          ),
      ],
    );
    if (!fitAdjust) return map;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (d) {
        _startCenter = _center;
        _startWidth = _widthM;
        _startRot = _rotation;
        _startFocal = d.localFocalPoint;
      },
      onScaleUpdate: (d) {
        if (!_ready || _startCenter == null) return;
        final cam = _map.camera;
        final a = cam.screenOffsetToLatLng(_startFocal);
        final b = cam.screenOffsetToLatLng(d.localFocalPoint);
        setState(() {
          _center = GeoPoint(
            (_startCenter!.lat + b.latitude - a.latitude).clamp(-85.0, 85.0),
            _startCenter!.lng + b.longitude - a.longitude,
          );
          _widthM = (_startWidth * d.scale).clamp(20.0, 200000.0);
          _rotation = _norm(_startRot + d.rotation * 180 / pi);
        });
      },
      child: map,
    );
  }

  static double _norm(double d) {
    var x = d % 360;
    if (x > 180) x -= 360;
    return x;
  }

  Widget _controls(Georef? g) {
    final mpp = g == null || _center == null
        ? null
        : g.metresPerPixel(_center ?? _start);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_mode == _Mode.fit) ...[
              Row(
                children: [
                  const Text('Adjust'),
                  Switch(
                    value: _adjust,
                    onChanged: (v) => setState(() => _adjust = v),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: !_ready
                        ? null
                        : () => setState(() {
                            _center = gpOf(_map.camera.center);
                          }),
                    icon: const Icon(Icons.center_focus_strong),
                    label: const Text('Centre here'),
                  ),
                ],
              ),
              _slider(
                'Turn',
                _rotation,
                -180,
                180,
                (v) => setState(() => _rotation = v),
                '${_rotation.round()}°',
              ),
              _slider(
                'Size',
                log(_widthM) / ln10,
                log(20) / ln10,
                log(200000) / ln10,
                (v) => setState(() => _widthM = pow(10, v).toDouble()),
                formatDistance(_widthM, imperial: trip.settings.imperial),
              ),
            ] else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_pairs.length} of 2-3 points'
                      '${mpp == null ? '' : ' · ${mpp.toStringAsFixed(2)} m per pixel'}',
                    ),
                  ),
                  TextButton(
                    onPressed: _px.isEmpty
                        ? null
                        : () => setState(() {
                            if (_px.length > _geo.length) {
                              _px.removeLast();
                            } else {
                              _px.removeLast();
                              _geo.removeLast();
                            }
                          }),
                    child: const Text('Undo'),
                  ),
                  TextButton(
                    onPressed: _px.isEmpty
                        ? null
                        : () => setState(() {
                            _px.clear();
                            _geo.clear();
                          }),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            _slider(
              'Opacity',
              _opacity,
              0.1,
              1,
              (v) => setState(() => _opacity = v),
              '${(_opacity * 100).round()}%',
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    double v,
    double lo,
    double hi,
    ValueChanged<double> on,
    String text,
  ) => Row(
    children: [
      SizedBox(width: 60, child: Text(label)),
      Expanded(
        child: Slider(value: v.clamp(lo, hi), min: lo, max: hi, onChanged: on),
      ),
      SizedBox(width: 64, child: Text(text, textAlign: TextAlign.end)),
    ],
  );
}
