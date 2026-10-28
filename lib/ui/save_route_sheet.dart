import 'dart:async';

import 'package:flutter/material.dart';

import '../trip/imports/map_layers.dart' show formatBytes;
import '../trip/offline_areas.dart';
import '../trip/route_save.dart';
import '../trip/trip_controller.dart';
import 'sheets.dart';

/// Opens "Save route for offline" for the route being followed (or for a
/// saved one, to resume or download again). Does nothing when there is no
/// route.
Future<void> showSaveRoute(
  BuildContext context,
  TripController trip, {
  SavedRoute? route,
  Duration? tilePause,
}) async {
  final r = route ?? trip.currentRouteForSave();
  if (r == null) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Start a route first (Navigate here), then save it.'),
      ),
    );
    return;
  }
  await showAppSheet<void>(
    context: context,
    builder: (_) =>
        SaveRouteSheetBody(trip: trip, route: r, tilePause: tilePause),
  );
}

/// The one button: Save route for offline.
class SaveRouteButton extends StatelessWidget {
  const SaveRouteButton({super.key, required this.trip});
  final TripController trip;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => showSaveRoute(context, trip),
      icon: const Icon(Icons.download_for_offline, size: 18),
      label: const Text('Save route for offline'),
    );
  }
}

/// Estimate, then progress with Cancel, then the result with Resume.
class SaveRouteSheetBody extends StatefulWidget {
  const SaveRouteSheetBody({
    super.key,
    required this.trip,
    required this.route,
    this.tilePause,
  });
  final TripController trip;
  final SavedRoute route;

  /// Tests: no pause between tiles.
  final Duration? tilePause;

  @override
  State<SaveRouteSheetBody> createState() => _SaveRouteSheetBodyState();
}

class _SaveRouteSheetBodyState extends State<SaveRouteSheetBody> {
  bool _saving = false;
  bool _cancel = false;
  AreaSaveProgress? _progress;
  RouteSaveResult? _result;
  String? _error;

  TripController get trip => widget.trip;
  SavedRoute get route => widget.route;

  Future<void> _go() async {
    setState(() {
      _saving = true;
      _cancel = false;
      _result = null;
      _error = null;
      _progress = null;
    });
    try {
      final r = await trip.saveRoute(
        route,
        cancelled: () => _cancel,
        tilePause: widget.tilePause ?? routeTilePause,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _minutes(Duration d) {
    final m = (d.inSeconds / 60).ceil();
    return m <= 1 ? 'about a minute' : 'about $m min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imperial = trip.settings.imperial;
    final est = trip.estimateRouteSave(route);
    final jobs = est.jobs;
    final res = _result;
    final p = _progress;
    final again = route.isReady;
    final goLabel = again
        ? 'Download again'
        : route.id.isNotEmpty
        ? 'Resume'
        : 'Save';
    return PopScope(
      canPop: !_saving,
      child: Padding(
        key: const Key('saveRouteSheet'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Save route for offline', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'To ${route.name}: ${route.summary(imperial: imperial)}',
              key: const Key('saveRouteTitle'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (!_saving && res == null) ...[
              Text(
                'Saved as one item in Offline areas, named ${route.name}. '
                'It has:',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              for (final line in _contents(jobs))
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text('• $line'),
                ),
              const SizedBox(height: 8),
              Text(
                'About ${formatBytes(est.bytes)} · ${_minutes(est.time)}',
                key: const Key('saveRouteEstimate'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Needs internet. It asks the free map servers for one file a '
                'second, only now (nothing runs in the background). You can '
                'cancel and carry on later.',
                style: theme.textTheme.bodySmall,
              ),
              if (route.problems.isNotEmpty && !again)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Last time: ${route.problems.join('; ')}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (!trip.plan.mapTileDownloads)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Offline power save is on: saving needs the internet.',
                  ),
                ),
            ],
            if (_saving) ...[
              Text(
                p == null
                    ? 'Starting…'
                    : '${_cancel ? 'Stopping… ' : ''}${p.step} '
                          '(${p.stepNo} of ${p.steps})',
                key: const Key('saveRouteStep'),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                key: const Key('saveRouteProgress'),
                value: p?.fraction,
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('saveRouteError'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (res != null)
              Text(
                _resultText(res),
                key: const Key('saveRouteResult'),
                style: theme.textTheme.bodyMedium,
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.end,
              children: [
                if (_saving)
                  OutlinedButton(
                    key: const Key('saveRouteCancel'),
                    onPressed: _cancel
                        ? null
                        : () => setState(() => _cancel = true),
                    child: Text(_cancel ? 'Stopping…' : 'Cancel'),
                  )
                else ...[
                  TextButton(
                    key: const Key('saveRouteClose'),
                    onPressed: () => Navigator.pop(context),
                    child: Text(res == null ? 'Not now' : 'Done'),
                  ),
                  if (res == null || !res.complete)
                    FilledButton.icon(
                      key: const Key('saveRouteGo'),
                      onPressed: trip.plan.mapTileDownloads ? _go : null,
                      icon: const Icon(Icons.download_for_offline),
                      label: Text(
                        res != null && !res.complete ? 'Resume' : goLabel,
                      ),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<String> _contents(RouteSaveJobs jobs) {
    final out = <String>[];
    for (final j in jobs.tiles) {
      out.add(
        j.src.id == 'terrarium'
            ? '${j.label} (${j.tiles.length} tiles)'
            : '${j.label}: ${j.src.name}, zoom ${j.z0}-${j.z1} '
                  '(${j.tiles.length} tiles)',
      );
    }
    if (jobs.roadWindows.isNotEmpty) {
      out.add('Roads near the route (for offline re-routing)');
    }
    out.add('Trails and paths near the route, unnamed ones too');
    out.add(
      'The turn list (${route.turns} turns)'
      '${route.trailheadName.isEmpty ? '' : ' and the trailhead: ${route.trailheadName}'}',
    );
    return out;
  }

  String _resultText(RouteSaveResult r) {
    final e = r.entry;
    if (r.cancelled && e == null) return 'Cancelled. Nothing was saved.';
    final size = e == null ? '' : ' (${formatBytes(e.bytes)})';
    if (r.cancelled) {
      return 'Stopped. Kept what was saved so far$size. Tap Resume to '
          'carry on.';
    }
    if (!r.complete) {
      return 'Saved part of ${route.name}$size. Not saved: '
          '${r.problems.join('; ')}. Tap Resume to try again.';
    }
    return 'Saved ${route.name}$size. Find it in Offline areas. '
        '${r.problems.isEmpty ? '' : 'Note: ${r.problems.join('; ')}. '}'
        'Maps © OpenStreetMap contributors, OpenTopoMap / USGS.';
  }
}
