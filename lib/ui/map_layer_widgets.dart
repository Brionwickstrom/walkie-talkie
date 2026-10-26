import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../trip/geo.dart';
import '../trip/imports/georef.dart';
import '../trip/imports/map_layers.dart';
import '../trip/imports/mbtiles_provider.dart';
import '../trip/tile_provider.dart';
import '../trip/trip_controller.dart';

LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);

/// The base map: the chosen online / cached source, with an imported
/// MBTiles map on top when one is selected (the online map shows outside
/// its area).
List<Widget> baseTileLayers(TripController trip) {
  final src = trip.mapSource;
  final base = trip.baseTiles;
  final mb = base == null ? null : trip.layers.tilesOf(base.id);
  return [
    TileLayer(
      key: ValueKey('${src.id}:${src.urlTemplate}'),
      urlTemplate: src.urlTemplate,
      subdomains: src.subdomains,
      maxNativeZoom: src.maxZoom,
      userAgentPackageName: 'com.walkie.walkie_talkie',
      tileProvider: CachedTileProvider(trip.tiles, src),
    ),
    if (mb != null)
      TileLayer(
        key: ValueKey('mbtiles:${base!.id}'),
        tileProvider: MbTilesProvider(mb),
        minNativeZoom: mb.minZoom,
        maxNativeZoom: mb.maxZoom,
        tileBounds: mb.bounds == null
            ? null
            : LatLngBounds(
                LatLng(mb.bounds!.south, mb.bounds!.west),
                LatLng(mb.bounds!.north, mb.bounds!.east),
              ),
      ),
  ];
}

/// An overlay image placed with [g].
RotatedOverlayImage placedOverlay(
  ImageProvider image,
  Georef g,
  int w,
  int h,
  double opacity,
) {
  final c = g.corners(w.toDouble(), h.toDouble());
  return RotatedOverlayImage(
    imageProvider: image,
    topLeftCorner: _ll(c.topLeft),
    bottomLeftCorner: _ll(c.bottomLeft),
    bottomRightCorner: _ll(c.bottomRight),
    opacity: opacity,
  );
}

/// Imported park map overlays, trail lines and waypoints (visible ones).
List<Widget> importedLayers(
  TripController trip, {
  String? skipOverlay,
  void Function(MapLayer l, String name, GeoPoint at)? onWaypoint,
}) {
  final layers = trip.layers;
  final overlays = [
    for (final l in layers.overlays.reversed)
      if (l.visible && l.placed && l.id != skipOverlay)
        placedOverlay(
          FileImage(layers.fileOf(l)),
          l.georef!,
          l.imageW,
          l.imageH,
          l.opacity,
        ),
  ];
  final trails = [
    for (final l in layers.trails.reversed)
      if (l.visible && l.data != null) l,
  ];
  return [
    if (overlays.isNotEmpty) OverlayImageLayer(overlayImages: overlays),
    if (trails.isNotEmpty)
      PolylineLayer(
        polylines: [
          for (final l in trails)
            for (final line in l.data!.lines)
              if (line.points.length > 1)
                Polyline(
                  points: [for (final p in line.points) _ll(p)],
                  strokeWidth: 3.5,
                  color: Color(l.color).withValues(alpha: 0.9),
                  borderStrokeWidth: 1,
                  borderColor: Colors.white.withValues(alpha: 0.7),
                  pattern: line.isRoute
                      ? StrokePattern.dashed(segments: const [10, 5])
                      : const StrokePattern.solid(),
                ),
        ],
      ),
    if (trails.any((l) => l.data!.waypoints.isNotEmpty))
      MarkerLayer(
        markers: [
          for (final l in trails)
            for (final w in l.data!.waypoints.take(500))
              Marker(
                point: _ll(w.pos),
                width: 100,
                height: 44,
                child: GestureDetector(
                  onTap: onWaypoint == null
                      ? null
                      : () => onWaypoint(l, w.name, w.pos),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Icon(Icons.place, size: 20, color: Color(l.color)),
                      if (w.name.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          color: Colors.white.withValues(alpha: 0.85),
                          child: Text(
                            w.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
  ];
}
