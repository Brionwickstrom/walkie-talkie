/// Weather alert areas on the Trip map (v2.6.14): the layer switch, the
/// shaded polygons, the badge, and the sheet that opens when an area is
/// tapped. The geometry itself lives in `weather/wx_areas.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app/friendly_error.dart';
import '../weather/wx_alert.dart';
import '../weather/wx_areas.dart';
import '../weather/wx_notice.dart';

/// Small storm mark on a person or radio that is inside an alert.
class WxAlertBadge extends StatelessWidget {
  const WxAlertBadge({super.key, this.tip});

  final String? tip;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: const Color(0xFFB71C1C),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.4),
      ),
      child: const Icon(Icons.thunderstorm, size: 10, color: Colors.white),
    );
    final tip = this.tip;
    if (tip == null || tip.isEmpty) return mark;
    return Tooltip(message: tip, child: mark);
  }
}

/// A radio that is not already drawn as a friend, shown only while it
/// stands inside an alert.
class WxNodeMarker extends StatelessWidget {
  const WxNodeMarker({
    super.key,
    required this.name,
    this.alertLine,
    this.badgeKey,
  });

  final String name;
  final String? alertLine;
  final Key? badgeKey;

  @override
  Widget build(BuildContext context) {
    final line = alertLine;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        Stack(
          clipBehavior: Clip.none,
          children: [
            const CircleAvatar(
              radius: 13,
              backgroundColor: Color(0xFF455A64),
              child: Icon(
                Icons.settings_input_antenna,
                size: 14,
                color: Colors.white,
              ),
            ),
            if (line != null && line.isNotEmpty)
              Positioned(
                right: -6,
                top: -6,
                child: WxAlertBadge(key: badgeKey, tip: line),
              ),
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: const Color(0xFFB71C1C)),
          ),
          child: Text(
            name.isEmpty ? 'Radio' : name,
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
    );
  }
}

/// Polygons for [PolygonLayer], mild areas first so a warning sits on top.
List<Polygon> wxPolygonsToDraw(List<WxMapArea> areas) {
  final draw = [...areas]..sort((a, b) => compareWxAreas(b, a));
  final out = <Polygon>[];
  for (final a in draw) {
    final col = Color(a.colorArgb);
    for (final p in a.polygons) {
      if (p.outer.length < 3) continue;
      final holes = [
        for (final h in p.holes)
          if (h.length >= 3) [for (final g in h) LatLng(g.lat, g.lng)],
      ];
      out.add(
        Polygon(
          points: [for (final g in p.outer) LatLng(g.lat, g.lng)],
          holePointsList: holes.isEmpty ? null : holes,
          color: col.withValues(alpha: 0.48),
          borderStrokeWidth: 5,
          borderColor: col.withValues(alpha: 0.9),
        ),
      );
    }
  }
  return out;
}

/// Map style sheet switch. [activeCount] is alerts in force, not only the
/// ones that have a shape. "No active alerts" shows only while the layer
/// is on and that count is zero.
class WxMapLayerTile extends StatelessWidget {
  const WxMapLayerTile({
    super.key,
    required this.on,
    required this.activeCount,
    required this.onChanged,
    this.alertsEnabled = true,
    this.hint,
    this.onRetry,
  });

  final bool on;
  final int activeCount;

  /// Weather alerts themselves are on. The empty note stays hidden when
  /// they are off, even if this switch is still on.
  final bool alertsEnabled;
  final ValueChanged<bool> onChanged;

  /// A plain sentence when a zone outline is missing. Null when every
  /// active alert can be drawn, or when there is nothing active.
  final String? hint;

  /// Try the zone download again. Null hides the button (Battery Saver).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = wxLayerEmptyNote(
      layerOn: on && alertsEnabled,
      activeCount: activeCount,
    );
    final dim = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('wx-map-layer'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Weather alert areas'),
          subtitle: const Text(
            'Warning, watch and advisory areas on the Trip map. '
            'People inside one get a badge.',
          ),
          value: on,
          onChanged: onChanged,
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(note, key: const Key('wx-no-alerts'), style: dim),
          ),
        if (hint != null) ...[
          Text(
            hint!,
            key: const Key('fe-message'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
          if (onRetry != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('wx-zone-retry'),
                onPressed: onRetry,
                child: Text(FixAction.retry.label),
              ),
            ),
        ],
      ],
    );
  }
}

/// What a tap on a shaded area says.
class WxAreaSheet extends StatelessWidget {
  const WxAreaSheet({super.key, required this.area, this.also = const []});

  final WxMapArea area;
  final List<WxMapArea> also;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final a = area;
    final head = a.headline.isEmpty ? a.event : WxAlert.unwrap(a.headline);
    final desc = a.description.isEmpty ? '' : WxAlert.unwrap(a.description);
    final todo = a.instruction.isEmpty ? '' : WxAlert.unwrap(a.instruction);
    final dim = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      key: const Key('wx-area-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.thunderstorm, color: Color(a.colorArgb)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  head,
                  key: const Key('wx-area-headline'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            wxSeveritySentence(a.kind, a.severity),
            key: const Key('wx-area-severity'),
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 4),
          Text(
            _expiry(a.expiresAt, now),
            key: const Key('wx-area-expiry'),
            style: theme.textTheme.bodyMedium,
          ),
          if (a.areaDesc.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(a.areaDesc, style: dim),
          ],
          const SizedBox(height: 8),
          Text(
            desc.isEmpty ? 'No more detail came with this alert.' : desc,
            key: const Key('wx-area-desc'),
            style: theme.textTheme.bodyMedium,
          ),
          if (todo.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'What to do: ',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: todo),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(wxAreaOriginSentence(a), style: dim),
          const SizedBox(height: 4),
          Text(a.sourceLine, style: dim),
          if (also.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Also here: ${also.map((x) => x.event).join(', ')}',
              style: dim,
            ),
          ],
        ],
      ),
    );
  }

  static String _expiry(DateTime expires, DateTime now) {
    if (!now.isBefore(expires)) return 'This alert has ended.';
    final left = expires.difference(now);
    final remain = left.inMinutes < 1
        ? 'less than a minute'
        : left.inHours < 1
        ? '${left.inMinutes} min'
        : '${left.inHours} h ${left.inMinutes.remainder(60)} min';
    return 'Ends ${wxClock(expires.toLocal(), now: now.toLocal())} '
        '($remain left).';
  }
}
