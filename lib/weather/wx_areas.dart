/// Which alert areas to draw, and who is standing in one (v2.6.14).
///
/// Pure: the map, the badges and the tests all call this. Expired alerts
/// are left out, so a badge disappears when the warning ends even if the
/// store has not pruned it yet.
library;

import '../trip/geo.dart';
import 'wx_alert.dart';
import 'wx_geom.dart';

/// One drawable alert area.
class WxMapArea {
  const WxMapArea({
    required this.key,
    required this.event,
    required this.headline,
    required this.description,
    required this.instruction,
    required this.areaDesc,
    required this.kind,
    required this.severity,
    required this.extreme,
    required this.expiresAt,
    required this.colorArgb,
    required this.polygons,
    required this.fromZone,
    required this.source,
    required this.sourceLine,
  });

  final String key;
  final String event;
  final String headline;
  final String description;
  final String instruction;
  final String areaDesc;
  final WxKind kind;
  final WxSeverity severity;
  final bool extreme;
  final DateTime expiresAt;
  final int colorArgb;
  final List<WxPolygon> polygons;

  /// The shape is the county or zone the alert named, not a storm polygon
  /// that came with the alert.
  final bool fromZone;
  final WxSource source;
  final String sourceLine;

  bool containsPoint(GeoPoint p) => pointInWxPolygons(p, polygons);
}

/// Fill / stroke colour. Warning, watch and advisory are distinct; an
/// extreme warning is a darker red.
int wxAreaColor({
  required WxKind kind,
  required WxSeverity severity,
  required bool extreme,
}) {
  if (extreme || severity == WxSeverity.extreme) return 0xFFB71C1C;
  return switch (kind) {
    WxKind.warning => switch (severity) {
      WxSeverity.moderate => 0xFFFB8C00,
      WxSeverity.minor => 0xFFF9A825,
      _ => 0xFFE53935,
    },
    WxKind.watch => 0xFFF9A825,
    WxKind.advisory => 0xFF1E88E5,
    _ => 0xFF6D4C41,
  };
}

/// Most important first (extreme, then severity).
int compareWxAreas(WxMapArea a, WxMapArea b) {
  if (a.extreme != b.extreme) return a.extreme ? -1 : 1;
  final s = b.severity.index.compareTo(a.severity.index);
  if (s != 0) return s;
  return a.event.compareTo(b.event);
}

/// Areas that can be drawn at [now]. An alert with no polygon and no
/// saved zone outline is skipped (it is still listed on the Alerts page).
List<WxMapArea> wxMapAreas({
  required Iterable<WxAlert> alerts,
  required Map<String, List<WxPolygon>> zones,
  required DateTime now,
}) {
  final out = <WxMapArea>[];
  for (final a in alerts) {
    if (!a.activeAt(now) || a.isCancel) continue;
    var polys = a.polygons;
    var fromZone = false;
    if (polys.isEmpty) {
      final merged = <WxPolygon>[];
      for (final z in a.ugc) {
        final g = zones[z];
        if (g != null) merged.addAll(g);
      }
      if (merged.isEmpty) continue;
      polys = merged;
      fromZone = true;
    }
    out.add(
      WxMapArea(
        key: a.key,
        event: a.event,
        headline: a.headline,
        description: a.description,
        instruction: a.instruction,
        areaDesc: a.areaDesc,
        kind: a.kind,
        severity: a.severity,
        extreme: a.isExtreme,
        expiresAt: a.expiresAt,
        colorArgb: wxAreaColor(
          kind: a.kind,
          severity: a.severity,
          extreme: a.isExtreme,
        ),
        polygons: polys,
        fromZone: fromZone,
        source: a.source,
        sourceLine: a.sourceLine,
      ),
    );
  }
  out.sort(compareWxAreas);
  return out;
}

/// Areas that contain [p], most important first.
List<WxMapArea> wxAreasAt(GeoPoint p, List<WxMapArea> areas) {
  if (!p.valid) return const [];
  final hits = [
    for (final a in areas)
      if (a.containsPoint(p)) a,
  ];
  hits.sort(compareWxAreas);
  return hits;
}

/// "In a weather alert: Tornado Warning". Empty when [hits] is empty.
String wxInAlertLine(List<WxMapArea> hits) {
  if (hits.isEmpty) return '';
  final top = hits.first.event;
  if (hits.length == 1) return 'In a weather alert: $top';
  return 'In ${hits.length} weather alerts: $top';
}

/// The line under the map layer switch when it is on and nothing is active.
String? wxLayerEmptyNote({required bool layerOn, required int activeCount}) {
  if (layerOn && activeCount == 0) return 'No active alerts';
  return null;
}

/// "This is a Severe warning."
String wxSeveritySentence(WxKind kind, WxSeverity severity) {
  final kindWord = switch (kind) {
    WxKind.warning => 'warning',
    WxKind.watch => 'watch',
    WxKind.advisory => 'advisory',
    WxKind.statement => 'statement',
    WxKind.marine => 'marine alert',
    WxKind.other => 'alert',
  };
  final sev = switch (severity) {
    WxSeverity.extreme => 'Extreme',
    WxSeverity.severe => 'Severe',
    WxSeverity.moderate => 'Moderate',
    WxSeverity.minor => 'Minor',
    WxSeverity.unknown => '',
  };
  if (sev.isEmpty) {
    return 'This is ${kindWord.startsWith('a') ? 'an' : 'a'} $kindWord.';
  }
  final phrase = '$sev $kindWord';
  final article = 'AEIOU'.contains(phrase[0]) ? 'an' : 'a';
  return 'This is $article $phrase.';
}

/// Where the shaded shape came from, in plain language.
String wxAreaOriginSentence(WxMapArea a) {
  if (!a.fromZone) {
    return 'The shaded area is the shape that came with this alert.';
  }
  if (a.source == WxSource.lora) {
    return 'The radio message is too small to carry the storm shape. '
        'This outline is the county or zone it named, from a map saved '
        'on this phone.';
  }
  return 'This alert named a county or zone and did not include a storm '
      'shape. The outline is that county or zone.';
}

/// A radio or friend that might stand in an alert. Public nodes are never
/// placed on the map (their location is not shown).
class WxNodeSpot {
  const WxNodeSpot({
    required this.id,
    required this.name,
    required this.pos,
    this.public = false,
    this.self = false,
    this.speedMps,
    this.posAt,
  });

  final int id;
  final String name;
  final GeoPoint pos;
  final bool public;
  final bool self;

  /// Latest ground speed in m/s, when the position included one (v2.6.16).
  final double? speedMps;

  /// When that position was taken.
  final DateTime? posAt;
}

/// A radio node as a map spot, or null when it has not reported a position.
/// (0, 0) is Meshtastic's empty fix and is not a position.
WxNodeSpot? spotForRadio({
  required int id,
  required String longName,
  required String shortName,
  required double? lat,
  required double? lng,
  required bool public,
  required bool self,
  double? speedMps,
  DateTime? posAt,
}) {
  if (lat == null || lng == null || (lat == 0 && lng == 0)) return null;
  final name = longName.isNotEmpty
      ? longName
      : (shortName.isNotEmpty ? shortName : 'Radio');
  return WxNodeSpot(
    id: id,
    name: name,
    pos: GeoPoint(lat, lng),
    public: public,
    self: self,
    speedMps: speedMps,
    posAt: posAt,
  );
}

/// Radios that have reported a GPS position, drawn on the Trip map
/// everywhere (v2.6.16). Weather does not decide this list: a storm badge
/// is added later, only while the radio stands inside an alert. Public
/// nodes stay off the map. A node already drawn as a friend is skipped.
/// No position means it is not here.
List<WxNodeSpot> radioSpotsToDraw({
  required Iterable<WxNodeSpot> nodes,
  required Set<int> skipIds,
}) {
  final out = <WxNodeSpot>[];
  final seen = <int>{};
  for (final n in nodes) {
    if (n.public || n.self || skipIds.contains(n.id)) continue;
    if (!n.pos.valid || (n.pos.lat == 0 && n.pos.lng == 0)) continue;
    if (!seen.add(n.id)) continue;
    out.add(n);
  }
  return out;
}

/// Nodes that should gain a map marker because they are inside an alert
/// and are not already drawn as a friend. Empty when there is nothing to
/// draw, so the map stays as it was.
List<WxNodeSpot> wxNodesInside({
  required Iterable<WxNodeSpot> nodes,
  required Set<int> skipIds,
  required List<WxMapArea> areas,
}) {
  if (areas.isEmpty) return const [];
  final out = <WxNodeSpot>[];
  final seen = <int>{};
  for (final n in nodes) {
    if (n.public || n.self || skipIds.contains(n.id)) continue;
    if (!n.pos.valid || !seen.add(n.id)) continue;
    if (wxAreasAt(n.pos, areas).isEmpty) continue;
    out.add(n);
  }
  return out;
}

/// Extra zone-outline downloads. Never in Battery Saver, never with the
/// layer off, never when the network is not allowed. There is no timer:
/// a caller asks once when alerts change.
bool wxZoneFetchAllowed({
  required bool layerOn,
  required bool alertsOn,
  required bool saver,
  required bool networkOk,
}) => layerOn && alertsOn && !saver && networkOk;

/// An active alert still needs a zone outline we have not saved.
bool wxOutlinesPending({
  required Iterable<WxAlert> alerts,
  required WxZoneCache cache,
  required DateTime now,
}) {
  for (final a in alerts) {
    if (!a.activeAt(now) || a.isCancel) continue;
    if (a.polygons.isNotEmpty || a.ugc.isEmpty) continue;
    var drawable = false;
    var unknown = false;
    for (final z in a.ugc) {
      final hit = cache.lookup(z, now);
      if (hit == null) {
        unknown = true;
      } else if (hit.polygons.isNotEmpty) {
        drawable = true;
      }
    }
    if (!drawable && unknown) return true;
  }
  return false;
}

/// Shown by the layer switch. Saver never offers a download button.
/// [fetchFailed] is a real try that did not succeed.
String? wxOutlineHint({
  required bool layerOn,
  required bool saver,
  required bool pending,
  required bool fetchFailed,
}) {
  if (!layerOn || !pending) return null;
  if (saver) {
    return 'Some alert areas are not drawn yet. Their outlines download '
        'when Battery mode is not Saver. The warning is still listed.';
  }
  if (fetchFailed) {
    return 'Some alert areas could not be downloaded. The warning is '
        'still listed.';
  }
  return null;
}
