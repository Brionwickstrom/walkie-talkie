// v2.6.12: the Battery mode picker (Settings > Battery > Battery mode, and
// the Talk connection sheet). See lib/trip/battery_mode.dart for the rules.
import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../trip/battery_mode.dart';
import '../trip/trip_controller.dart';
import 'friendly_error.dart';

IconData batteryModeIcon(BatteryMode m) => switch (m) {
  BatteryMode.saver => Icons.eco,
  BatteryMode.normal => Icons.battery_std,
  BatteryMode.tracking => Icons.track_changes,
};

Color? batteryModeColor(BatteryMode m) => switch (m) {
  BatteryMode.saver => Colors.green,
  BatteryMode.normal => null,
  BatteryMode.tracking => Colors.deepOrange,
};

/// What a locked setting says under its title (null = not locked).
String? lockedNote(TripController? t, BatterySetting s) {
  if (t == null) return null;
  final m = t.batteryMode;
  if (!controls(m, s)) return null;
  return '$controlledNote (${m.label}). Pick Normal to change it.';
}

class BatteryModePicker extends StatefulWidget {
  const BatteryModePicker({
    super.key,
    required this.trip,
    this.controller,
    this.compact = false,
  });
  final TripController trip;

  /// For fix buttons that act on the app; null in tests.
  final WalkieController? controller;

  /// The connection sheet: one line and the buttons.
  final bool compact;

  @override
  State<BatteryModePicker> createState() => _BatteryModePickerState();
}

class _BatteryModePickerState extends State<BatteryModePicker> {
  FriendlyError? _error;
  BatteryMode? _wanted;
  bool _busy = false;

  TripController get t => widget.trip;

  Future<void> _pick(BatteryMode m) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _wanted = m;
    });
    FriendlyError? fe;
    try {
      fe = await t.setBatteryMode(m);
    } catch (e) {
      fe = batteryModeSaveError(e);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = fe;
    });
  }

  Future<void> _fix(FixAction a) async {
    switch (a) {
      case FixAction.stopRangeTest:
        await t.rangeRun.stop();
        final w = _wanted;
        if (w != null) await _pick(w);
      case FixAction.useTrackingMode:
        await _pick(BatteryMode.tracking);
      case FixAction.useNormalMode:
        await _pick(BatteryMode.normal);
      case FixAction.retry:
        final w = _wanted;
        if (w != null) await _pick(w);
      default:
        if (widget.controller != null) {
          await runFix(context, widget.controller, a);
        }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: t,
    builder: (context, _) {
      final theme = Theme.of(context);
      final m = t.batteryMode;
      return Column(
        key: const Key('battery-mode-picker'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(batteryModeIcon(m), size: 20, color: batteryModeColor(m)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.compact
                      ? 'Battery mode: ${m.label}'
                      : 'Battery mode',
                  key: const Key('battery-mode-title'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SegmentedButton<BatteryMode>(
            key: const Key('battery-mode'),
            showSelectedIcon: false,
            segments: [
              for (final x in BatteryMode.values)
                ButtonSegment(
                  value: x,
                  label: Text(x.label, key: Key('battery-mode-${x.id}')),
                  icon: Icon(batteryModeIcon(x)),
                ),
            ],
            selected: {m},
            onSelectionChanged: _busy ? null : (v) => _pick(v.first),
          ),
          const SizedBox(height: 6),
          Text(
            widget.compact ? m.summary : '${m.summary} ${m.battery}',
            key: const Key('battery-mode-about'),
            style: theme.textTheme.bodySmall,
          ),
          if (!widget.compact) ...[
            const SizedBox(height: 4),
            Text(
              'Saver and Tracking lock the settings they control (Share my '
              'location, Range logging, Keep home area ready) and put them '
              'back exactly when you pick Normal. SOS always works.',
              key: const Key('battery-mode-rules'),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (t.trackingNudge) ...[
            const SizedBox(height: 8),
            Container(
              key: const Key('battery-mode-nudge'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tracking has been on for 3 hours without a charger. '
                    'Switch back to Normal to save battery?',
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonal(
                        key: const Key('battery-mode-nudge-normal'),
                        onPressed: () => _pick(BatteryMode.normal),
                        child: const Text('Switch to Normal'),
                      ),
                      TextButton(
                        key: const Key('battery-mode-nudge-keep'),
                        onPressed: t.dismissTrackingNudge,
                        child: const Text('Keep Tracking'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            FriendlyErrorView(
              key: const Key('battery-mode-error'),
              error: _error!,
              onFix: (a) => _fix(a),
              onDismiss: () => setState(() => _error = null),
            ),
          ],
        ],
      );
    },
  );
}
