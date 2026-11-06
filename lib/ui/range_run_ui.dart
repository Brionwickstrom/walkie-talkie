// v2.6.10: the one-tap range test. Start (pick the home radio and the time
// limit), the live strip on the Trip map, Stop and the summary with Copy
// summary and Export CSV / GPX. Built on Range logging (v2.5.9): nothing
// new goes over the air.
import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'friendly_error.dart';
import '../trip/battery_mode.dart';
import '../trip/geo.dart';
import '../trip/range_logger.dart';
import '../trip/range_run.dart';
import '../trip/range_test.dart';
import 'range_test_ui.dart' show rangeClock, rangeHops, rangeGreen, rangeRed;
import 'sheets.dart';

/// What the Start / Stop buttons need (the Trip map and Talk's connection
/// sheet both use it).
class RangeRunActions {
  const RangeRunActions({
    required this.run,
    required this.logger,
    required this.radioReady,
    this.homeChoices,
    this.imperial = true,
    this.share,
    this.onFix,
    this.exportDir,
    this.onStarted,
    this.saverOn,
    this.setMode,
  });
  final RangeRun run;
  final RangeLogger logger;

  /// The radio is connected and set up.
  final bool Function() radioReady;

  /// Radios the connected radio knows (for "Home radio").
  final List<({int num, String name})> Function()? homeChoices;
  final bool imperial;

  /// Share a file; false = could not (the text is copied instead).
  final Future<bool> Function(String path, String mime, String title)? share;

  /// Runs a plain error's fix button (Connect radio, Turn on location).
  final void Function(FixAction a)? onFix;

  /// Tests: where exports are written.
  final Directory? exportDir;

  /// After Start (Talk switches to the Trip map).
  final VoidCallback? onStarted;

  /// v2.6.12: Battery mode is Saver (pings off: the test cannot start).
  final bool Function()? saverOn;

  /// v2.6.12: switch the Battery mode from the start sheet.
  final Future<FriendlyError?> Function(BatteryMode m)? setMode;

  RangeTest get store => run.store;
}

String _homeLabel(RangeRunActions a, int n) {
  for (final c in a.homeChoices?.call() ?? const <({int num, String name})>[]) {
    if (c.num == n) return c.name;
  }
  return n == defaultRangeHomeNode ? 'Skunk Ape' : radioNodeLabel(n);
}

String _stopLabel(int m) => m < 60
    ? '$m min'
    : m % 60 == 0
    ? '${m ~/ 60} h'
    : '${m ~/ 60} h ${m % 60} min';

/// The one button: starts a test (asks for the home radio and time limit
/// first), or stops the running one and shows its summary.
Future<void> rangeRunTap(BuildContext context, RangeRunActions a) async {
  if (a.run.running) {
    final s = await a.run.stop();
    if (s != null && context.mounted) {
      await showRangeSummarySheet(context, a, s);
    }
    return;
  }
  final ok = await showRangeStartSheet(context, a);
  if (ok == true) a.onStarted?.call();
}

/// Start sheet: home radio, "Stop by itself after", the battery note and
/// Start. Returns true when a test was started.
Future<bool?> showRangeStartSheet(BuildContext context, RangeRunActions a) {
  var home = a.store.homeNode;
  var max = a.run.maxMinutes;
  return showAppSheet<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final ready = a.radioReady();
        final saver = a.saverOn?.call() ?? false;
        final problem =
            rangeTestProblem(radioReady: ready) ??
            (saver ? rangeTestSaverError : null);
        final choices = [
          (num: defaultRangeHomeNode, name: 'Skunk Ape'),
          for (final c in a.homeChoices?.call() ?? const [])
            if (c.num != defaultRangeHomeNode) c,
          if (home != defaultRangeHomeNode &&
              !(a.homeChoices?.call() ?? const []).any((c) => c.num == home))
            (num: home, name: radioNodeLabel(home)),
        ];
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              key: const Key('rangeStartSheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'One-tap range test',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Drive or walk away from the home radio. Green and red '
                  'markers show on the Trip map where you connect and drop.',
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: const Key('rangeStartHome'),
                  initialValue: home,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Home radio',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final c in choices)
                      DropdownMenuItem(
                        value: c.num,
                        child: Text(
                          '${c.name} (${radioNodeLabel(c.num)})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => home = v ?? home),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  key: const Key('rangeStartMax'),
                  initialValue: max,
                  decoration: const InputDecoration(
                    labelText: 'Stop by itself after',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final m in {
                      ...RangeRun.maxChoices,
                      max,
                    }.toList()..sort())
                      DropdownMenuItem(value: m, child: Text(_stopLabel(m))),
                  ],
                  onChanged: (v) => setState(() => max = v ?? max),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    key: const Key('rangeStartBattery'),
                    'Battery: the same as Range logging. A ping every 30 s '
                    'while charging, otherwise every ${a.store.pingSecs} s, '
                    'and high-accuracy GPS every 10 s while the test runs. '
                    'It stops by itself after ${_stopLabel(max)}.',
                    style: TextStyle(color: cs.onSurface, fontSize: 13),
                  ),
                ),
                if (problem != null) ...[
                  const SizedBox(height: 12),
                  FriendlyErrorView(
                    error: problem,
                    onFix: (f) async {
                      if ((f == FixAction.useTrackingMode ||
                              f == FixAction.useNormalMode) &&
                          a.setMode != null) {
                        // Stays open: Start works right after.
                        await a.setMode!(
                          f == FixAction.useTrackingMode
                              ? BatteryMode.tracking
                              : BatteryMode.normal,
                        );
                        setState(() {});
                        return;
                      }
                      Navigator.pop(ctx, false);
                      a.onFix?.call(f);
                    },
                  ),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('rangeStartGo'),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start range test'),
                  onPressed: !ready || saver
                      ? null
                      : () async {
                          await a.run.setMaxMinutes(max);
                          await a.run.start(home: home);
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// The live strip on the Trip map while a test runs.
class RangeRunStrip extends StatefulWidget {
  const RangeRunStrip({super.key, required this.actions});
  final RangeRunActions actions;

  @override
  State<RangeRunStrip> createState() => _RangeRunStripState();
}

class _RangeRunStripState extends State<RangeRunStrip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The clock on screen only; nothing else runs on this timer.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.actions;
    final run = a.run;
    final live = run.live;
    final white = const TextStyle(color: Colors.white, fontSize: 12);
    final bold = white.copyWith(fontWeight: FontWeight.w700, fontSize: 13);
    final problem = rangeTestProblem(
      radioReady: a.radioReady(),
      running: true,
      waitingForGps: a.logger.waitingForGps,
    );
    final reply = live.lastReplyAt == null
        ? 'No reply yet · ${a.logger.status}'
        : [
            'Last reply ${rangeClock(live.lastReplyAt!, seconds: true)}',
            'SNR ${live.snr == null ? '-' : '${live.snr} dB'}',
            rangeHops(live.hops),
            if (live.distM != null)
              formatDistance(live.distM!, imperial: a.imperial),
          ].join(' · ');
    return Material(
      key: const Key('rangeRunStrip'),
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.radar, size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Range test · ${_hms(live.elapsed)} · '
                    '${_homeLabel(a, a.store.homeNode)}',
                    key: const Key('rangeRunElapsed'),
                    style: bold,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const Key('rangeRunStop'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed: () => rangeRunTap(context, a),
                  child: const Text('Stop'),
                ),
              ],
            ),
            Text(reply, key: const Key('rangeRunReply'), style: white),
            Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  key: const Key('rangeRunCounts'),
                  '${live.replies} replies · ${live.noReplies} no reply',
                  style: white,
                ),
                Row(
                  key: const Key('rangeRunGps'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.gps_fixed, size: 13, color: Colors.amber[300]),
                    const SizedBox(width: 3),
                    Text(
                      'High-accuracy GPS on',
                      style: white.copyWith(color: Colors.amber[200]),
                    ),
                  ],
                ),
              ],
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        problem.message,
                        key: const Key('rangeRunProblem'),
                        style: white.copyWith(color: Colors.orange[200]),
                      ),
                    ),
                    if (problem.fix != null && a.onFix != null)
                      TextButton(
                        key: const Key('rangeRunFix'),
                        onPressed: () => a.onFix!(problem.fix!),
                        child: Text(problem.fix!.label),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _hms(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// The summary after Stop (or after it stopped by itself).
Future<void> showRangeSummarySheet(
  BuildContext context,
  RangeRunActions a,
  RangeRunSummary s,
) => showAppSheet<void>(
  context: context,
  builder: (ctx) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: RangeSummaryView(actions: a, summary: s),
    ),
  ),
);

class RangeSummaryView extends StatelessWidget {
  const RangeSummaryView({
    super.key,
    required this.actions,
    required this.summary,
  });
  final RangeRunActions actions;
  final RangeRunSummary summary;

  Future<void> _export(BuildContext context, bool csv) async {
    final a = actions;
    final s = summary;
    await a.store.flush();
    final text = csv ? a.run.csvOf(s) : a.run.gpxOf(s, imperial: a.imperial);
    var shared = false;
    try {
      final dir = a.exportDir ?? await getTemporaryDirectory();
      await dir.create(recursive: true);
      final stamp = s.startedAt
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(':', '-');
      final f = File('${dir.path}/range-test-$stamp.${csv ? 'csv' : 'gpx'}');
      await f.writeAsString(text);
      final share = a.share;
      if (share != null) {
        shared = await share(
          f.path,
          csv ? 'text/csv' : 'application/gpx+xml',
          'Stalkie Talkie range test',
        );
      }
    } catch (e) {
      if (context.mounted) {
        showFriendlySnack(
          context,
          friendlyFromError(e, what: 'save the range test file'),
          null,
        );
      }
      return;
    }
    if (shared) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Could not open the share sheet. Copied it instead.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final im = actions.imperial;
    final pct = s.connectedPct;
    Widget row(String k, String v, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(k)),
          Expanded(
            child: Text(
              v,
              key: key,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return Column(
      key: const Key('rangeSummary'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Range test summary',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(
          'To ${s.homeName} · ${formatRunDuration(s.duration)}'
          '${s.autoStopped ? ' · stopped by itself at the time limit' : ''}',
        ),
        const SizedBox(height: 10),
        row(
          'Furthest reply',
          s.furthestReplyM == null
              ? 'none'
              : formatDistance(s.furthestReplyM!, imperial: im),
          key: const Key('rangeSumFar'),
        ),
        row(
          'Best SNR',
          s.bestSnr == null ? 'none' : '${s.bestSnr} dB',
          key: const Key('rangeSumBest'),
        ),
        row(
          'Worst SNR',
          s.worstSnr == null ? 'none' : '${s.worstSnr} dB',
          key: const Key('rangeSumWorst'),
        ),
        row(
          'Connected',
          pct == null
              ? 'no pings sent'
              : '$pct% (${s.replies} of ${s.pings} pings)',
          key: const Key('rangeSumPct'),
        ),
        if (pct != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 8,
                color: rangeGreen,
                backgroundColor: rangeRed.withValues(alpha: 0.35),
              ),
            ),
          ),
        row('Packets heard', '${s.heard}'),
        row('Connects / drops', '${s.connects} / ${s.drops}'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('rangeCopySummary'),
              icon: const Icon(Icons.copy),
              label: const Text('Copy summary'),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: s.toText(imperial: im)),
                );
                if (!context.mounted) return;
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('Summary copied.')),
                );
              },
            ),
            OutlinedButton.icon(
              key: const Key('rangeExportRunCsv'),
              icon: const Icon(Icons.table_chart),
              label: const Text('Export CSV'),
              onPressed: () => _export(context, true),
            ),
            OutlinedButton.icon(
              key: const Key('rangeExportRunGpx'),
              icon: const Icon(Icons.route),
              label: const Text('Export GPX'),
              onPressed: () => _export(context, false),
            ),
          ],
        ),
      ],
    );
  }
}
