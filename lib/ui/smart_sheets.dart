import 'package:flutter/material.dart';

import '../trip/geo.dart';
import '../trip/nav/foot_router.dart' show FootRouter;
import '../trip/nav/gentle_route.dart';
import '../trip/nav/trail_graph.dart' show naismith;
import '../trip/smart_plan.dart';
import 'drive_page.dart' show driveDuration;

/// "Gentle compass route": how steep is too steep (v2.1.0). Pops the
/// chosen [SlopeLimit].
class GentleSheetBody extends StatelessWidget {
  const GentleSheetBody({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          key: const Key('gentleSheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Gentle compass route to $name',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Goes across country the way the compass points, around steep '
              'ground, using trails that run your way. It reads the '
              'elevation map only.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Card(
              color: Colors.orange.shade100,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text('$gentleLabel.', key: const Key('gentleWarning')),
              ),
            ),
            const SizedBox(height: 8),
            for (final l in SlopeLimit.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: FilledButton.tonal(
                  key: Key('slope_${l.name}'),
                  onPressed: () => Navigator.pop(context, l),
                  child: Text('${l.label}: ${l.blurb}'),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The drive reached the trailhead and the hike started (or could not be
/// planned): what is next.
class HandoffSheetBody extends StatelessWidget {
  const HandoffSheetBody({
    super.key,
    required this.handoff,
    required this.imperial,
    required this.onFollow,
    required this.onRetry,
    required this.onGentle,
  });
  final TrailheadHandoff handoff;
  final bool imperial;
  final VoidCallback onFollow, onRetry, onGentle;

  @override
  Widget build(BuildContext context) {
    final h = handoff;
    final r = h.route;
    final gain = r?.climb().gain ?? 0;
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          key: const Key('handoffSheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'You are at ${h.trailheadName}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            if (r != null) ...[
              Text(
                'The hike to ${h.targetName} starts now: '
                '${formatDistance(r.lengthM, imperial: imperial)}, about '
                '${driveDuration(naismith(r.lengthM, gain))}'
                '${r.hasElevation ? ', up ${imperial ? '${(gain * 3.28084).round()} ft' : '${gain.round()} m'}' : ''}.',
                key: const Key('handoffFacts'),
              ),
              if (h.message.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(h.message, style: theme.textTheme.bodySmall),
              ],
              if (r.isOnline) ...[
                const SizedBox(height: 4),
                Text(FootRouter.attribution, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('handoffFollow'),
                icon: const Icon(Icons.hiking),
                label: const Text('Follow the hike'),
                onPressed: onFollow,
              ),
            ] else ...[
              Text(
                'I could not plan the hike to ${h.targetName}. ${h.message}',
                key: const Key('handoffNoRoute'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('handoffRetry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
              const SizedBox(height: 6),
              OutlinedButton(
                key: const Key('handoffGentle'),
                onPressed: onGentle,
                child: const Text('Gentle compass route'),
              ),
            ],
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "No route found": the choices are offline areas, a gentle compass route
/// or the plain compass; never a silent straight line. Pops 'offline',
/// 'gentle' or 'compass'.
class NoRouteDialog extends StatelessWidget {
  const NoRouteDialog({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('noRouteDialog'),
    title: const Text('No route found'),
    content: Text(
      '$message\n\nThe phone will not draw a straight line unless you ask '
      'for one.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('noRouteOffline'),
        onPressed: () => Navigator.pop(context, 'offline'),
        child: const Text('Offline areas'),
      ),
      TextButton(
        key: const Key('noRouteGentle'),
        onPressed: () => Navigator.pop(context, 'gentle'),
        child: const Text('Gentle compass route'),
      ),
      TextButton(
        key: const Key('noRouteCompass'),
        onPressed: () => Navigator.pop(context, 'compass'),
        child: const Text('Compass'),
      ),
    ],
  );
}

/// "Which road end?": no trailhead is known. Pops 'use' or 'gentle'.
class RoadEndDialog extends StatelessWidget {
  const RoadEndDialog({
    super.key,
    required this.name,
    required this.message,
    required this.hasRoadEnd,
    this.awayText = '',
  });
  final String name, message, awayText;
  final bool hasRoadEnd;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('roadEndDialog'),
    title: const Text('Which road end?'),
    content: Text(
      'I could not find a trailhead or parking for $name. $message\n\n'
      '${hasRoadEnd && awayText.isNotEmpty ? 'The closest road I know of ends $awayText away. ' : ''}'
      'Pick where to park, or choose another way.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('roadEndGentle'),
        onPressed: () => Navigator.pop(context, 'gentle'),
        child: const Text('Gentle compass route'),
      ),
      if (hasRoadEnd)
        FilledButton(
          key: const Key('roadEndUse'),
          onPressed: () => Navigator.pop(context, 'use'),
          child: const Text('Drive to that road end'),
        ),
    ],
  );
}
