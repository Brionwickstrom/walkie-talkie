import 'package:flutter/material.dart';

import '../app/quiet.dart';
import '../app/walkie_controller.dart';

/// Mute button on the talk screen (v1.9.5): hold about 1 s to mute (a
/// ring fills up while you hold), a plain tap only shows "Hold to mute".
/// While muted a single tap turns sound back on.
class MuteButton extends StatefulWidget {
  const MuteButton({
    super.key,
    required this.muted,
    required this.onMute,
    required this.onUnmute,
    this.hold = QuietHours.holdToMute,
  });

  final bool muted;

  /// Called when the hold completes.
  final VoidCallback onMute;
  final VoidCallback onUnmute;
  final Duration hold;

  @override
  State<MuteButton> createState() => _MuteButtonState();
}

class _MuteButtonState extends State<MuteButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: widget.hold,
  )..addStatusListener(_onStatus);
  bool _fired = false;

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed && !_fired) {
      _fired = true;
      _ring.value = 0;
      widget.onMute();
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  void _hint() {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(
      const SnackBar(
        content: Text('Hold to mute'),
        duration: Duration(milliseconds: 1500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (widget.muted) {
      return FilledButton.tonalIcon(
        key: const Key('muteButton'),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: cs.errorContainer,
          foregroundColor: cs.onErrorContainer,
        ),
        icon: const Icon(Icons.volume_off, size: 18),
        label: const Text('Muted · tap to unmute'),
        onPressed: widget.onUnmute,
      );
    }
    return Listener(
      onPointerDown: (_) {
        _fired = false;
        _ring.forward(from: 0);
      },
      onPointerUp: (_) {
        if (!_fired) {
          final short = _ring.value < 0.6;
          _ring.stop();
          _ring.value = 0;
          if (short) _hint();
        }
      },
      onPointerCancel: (_) {
        _ring.stop();
        _ring.value = 0;
      },
      child: OutlinedButton.icon(
        key: const Key('muteButton'),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        icon: SizedBox(
          width: 20,
          height: 20,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _ring,
                builder: (_, _) => CircularProgressIndicator(
                  key: const Key('muteProgress'),
                  value: _ring.value,
                  strokeWidth: 2.5,
                  color: cs.error,
                  backgroundColor: Colors.transparent,
                ),
              ),
              const Icon(Icons.volume_up, size: 14),
            ],
          ),
        ),
        label: const Text('Mute'),
        // Taps are handled by the Listener (hint / hold).
        onPressed: () {},
      ),
    );
  }
}

/// "For how long?" right after the hold (mute is already on, until I turn
/// it off, if this is dismissed).
Future<void> showMuteDurationSheet(
  BuildContext context,
  WalkieController c,
) async {
  final picked = await showModalBottomSheet<Duration?>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget opt(String label, Duration? d, {Key? key}) => ListTile(
        key: key,
        leading: const Icon(Icons.timer_outlined),
        title: Text(label),
        onTap: () => Navigator.pop(ctx, d ?? Duration.zero),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.volume_off),
              title: Text('Muted. For how long?'),
              subtitle: Text(
                'Talk, rings and voice messages are saved for later.',
              ),
            ),
            opt(
              '30 minutes',
              const Duration(minutes: 30),
              key: const Key('mute30'),
            ),
            opt('1 hour', const Duration(hours: 1), key: const Key('mute60')),
            opt('2 hours', const Duration(hours: 2), key: const Key('mute120')),
            opt('Until I turn it off', null, key: const Key('muteOff')),
          ],
        ),
      );
    },
  );
  if (picked == null || picked == Duration.zero) return; // stays "until off"
  await c.muteFor(picked);
}

/// Banner under the header while muted or in quiet hours.
class QuietBanner extends StatelessWidget {
  const QuietBanner({
    super.key,
    required this.text,
    required this.muted,
    required this.onUnmute,
    required this.onSettings,
  });

  final String text;
  final bool muted;
  final VoidCallback onUnmute;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: const Key('quietBanner'),
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      color: cs.secondaryContainer,
      child: ListTile(
        dense: true,
        leading: Icon(muted ? Icons.volume_off : Icons.bedtime),
        title: Text(text),
        subtitle: const Text('Missed talk, rings and voice messages are kept.'),
        trailing: muted
            ? TextButton(onPressed: onUnmute, child: const Text('Unmute'))
            : TextButton(onPressed: onSettings, child: const Text('Change')),
      ),
    );
  }
}

/// Settings > Mute & quiet hours.
class QuietSettings extends StatelessWidget {
  const QuietSettings({super.key, required this.controller});
  final WalkieController controller;

  static String _fmt(BuildContext context, int minutes) =>
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60).format(context);

  static String label(BuildContext context, QuietSchedule s) {
    final d = s.days.length == 7
        ? 'Every day'
        : s.days.isEmpty
        ? 'No days'
        : (s.days.toList()..sort())
              .map((x) => QuietSchedule.dayNames[x - 1])
              .join(', ');
    return '${_fmt(context, s.start)} – ${_fmt(context, s.end)} · $d';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final q = c.quiet;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mute: hold the Mute button on the Talk screen for a second. '
              'Quiet hours do the same on a schedule. Either way incoming '
              'talk is kept in Missed, and rings, beeps, join tones and '
              'notification sounds stay silent.',
            ),
            if (c.quietStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Now: ${c.quietStatus}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            for (var i = 0; i < q.schedules.length; i++)
              ListTile(
                key: Key('quietSchedule$i'),
                contentPadding: EdgeInsets.zero,
                leading: Switch(
                  value: q.schedules[i].enabled,
                  onChanged: (v) {
                    q.schedules[i].enabled = v;
                    c.saveQuietHours();
                  },
                ),
                title: Text(label(context, q.schedules[i])),
                onTap: () => editQuietSchedule(context, c, index: i),
                trailing: IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    q.schedules.removeAt(i);
                    c.saveQuietHours();
                  },
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('addQuietHours'),
                icon: const Icon(Icons.add),
                label: const Text('Add quiet hours'),
                onPressed: () => editQuietSchedule(context, c),
              ),
            ),
            SwitchListTile(
              key: const Key('letUrgent'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Let urgent rings through'),
              subtitle: const Text(
                'While muted or in quiet hours, still ring for an urgent '
                'ring or SOS, a second ring from the same person within 2 '
                'minutes, and people you marked "Always allow" (tap a '
                'person on the Talk screen).',
              ),
              value: q.letUrgentThrough,
              onChanged: c.setLetUrgentThrough,
            ),
          ],
        );
      },
    );
  }
}

/// Add ([index] null) or change a quiet-hours schedule.
Future<void> editQuietSchedule(
  BuildContext context,
  WalkieController c, {
  int? index,
}) async {
  final old = index == null ? null : c.quiet.schedules[index];
  var start = old?.start ?? 22 * 60;
  var end = old?.end ?? 7 * 60;
  final days = {...?old?.days};
  if (old == null) days.addAll([1, 2, 3, 4, 5, 6, 7]);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        Future<void> pick(bool isStart) async {
          final m = isStart ? start : end;
          final t = await showTimePicker(
            context: ctx,
            initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
          );
          if (t == null) return;
          set(() {
            if (isStart) {
              start = t.hour * 60 + t.minute;
            } else {
              end = t.hour * 60 + t.minute;
            }
          });
        }

        return AlertDialog(
          title: Text(old == null ? 'Add quiet hours' : 'Quiet hours'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                key: const Key('quietStart'),
                contentPadding: EdgeInsets.zero,
                title: const Text('From'),
                trailing: Text(QuietSettings._fmt(ctx, start)),
                onTap: () => pick(true),
              ),
              ListTile(
                key: const Key('quietEnd'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Until'),
                subtitle: end <= start
                    ? const Text('Ends the next morning')
                    : null,
                trailing: Text(QuietSettings._fmt(ctx, end)),
                onTap: () => pick(false),
              ),
              Wrap(
                spacing: 4,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(QuietSchedule.dayNames[d - 1]),
                      selected: days.contains(d),
                      onSelected: (v) => set(() {
                        if (v) {
                          days.add(d);
                        } else {
                          days.remove(d);
                        }
                      }),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('quietSave'),
              onPressed: days.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true) return;
  if (old == null) {
    c.quiet.schedules.add(QuietSchedule(start: start, end: end, days: days));
  } else {
    old
      ..start = start
      ..end = end
      ..days = days;
  }
  await c.saveQuietHours();
}
