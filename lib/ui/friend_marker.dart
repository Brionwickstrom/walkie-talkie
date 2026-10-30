import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../trip/friend_motion.dart';
import '../trip/trip_controller.dart';
import 'home_view.dart';

/// A friend on the Trip map (v2.5.6): the dot at its guessed place between
/// updates, faded by how old the fix is, a small arrow for the direction of
/// travel, and the real age ("12 s", "3 min 5 s") under the name.
Marker friendMarker(
  TripController trip,
  PersonPos pp,
  String name, {
  VoidCallback? onTap,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  final age = t.difference(pp.at);
  final est = trip.friendEstimate(pp);
  final color = avatarColor(pp.id);
  final heading = pp.headingDeg;
  return Marker(
    key: Key('friend${pp.id}'),
    point: LatLng(est.pos.lat, est.pos.lng),
    width: 130,
    height: 66,
    child: Opacity(
      opacity: friendOpacity(age),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 17),
            Stack(
              clipBehavior: Clip.none,
              children: [
                if (heading != null &&
                    (pp.speedMps ?? 0) >= deadReckonMinSpeedMps)
                  Positioned(
                    left: -20,
                    top: -20,
                    right: -20,
                    bottom: -20,
                    child: Transform.rotate(
                      key: Key('friendHeading${pp.id}'),
                      angle: heading * pi / 180,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Icon(
                          Icons.arrow_drop_up,
                          size: 20,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                CircleAvatar(
                  radius: 14,
                  backgroundColor: color,
                  child: Text(
                    initials(name),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Positioned(
                  right: -8,
                  bottom: -4,
                  child: CircleAvatar(
                    radius: 8,
                    backgroundColor: Colors.white,
                    child: Icon(
                      pp.hops > 1 ? Icons.hub : transportIcon(pp.via),
                      size: 11,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: color, width: 1),
              ),
              child: Text(
                '$name · ${exactAge(age)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The accuracy circles (true metres on the map), faded like the dots.
/// Circles under 8 m are not worth drawing.
List<CircleMarker> friendCircles(TripController trip, {DateTime? now}) {
  final t = now ?? DateTime.now();
  return [
    for (final pp in trip.people.values)
      if (trip.friendEstimate(pp).radiusM >= 8)
        _circle(trip, pp, friendOpacity(t.difference(pp.at))),
  ];
}

CircleMarker _circle(TripController trip, PersonPos pp, double opacity) {
  final est = trip.friendEstimate(pp);
  final color = avatarColor(pp.id);
  return CircleMarker(
    point: LatLng(est.pos.lat, est.pos.lng),
    radius: est.radiusM,
    useRadiusInMeter: true,
    color: color.withValues(alpha: 0.14 * opacity),
    borderColor: color.withValues(alpha: 0.55 * opacity),
    borderStrokeWidth: 1,
  );
}
