import 'package:flutter/material.dart';

import '../app/quiet.dart';
import '../app/walkie_controller.dart';
import 'sheets.dart';

/// Mute button on the talk screen: a plain on/off switch, no time limit.
/// v1.9.9: both ways need a deliberate 2.5 s hold (a ring fills up while
/// you hold); letting go early cancels and shows "Keep holding to mute" /
/// "Keep holding to unmute". When the hold completes a "Mute Walkie?" /
/// "Unmute Walkie?" dialog asks first (Cancel has focus); only confirming
/// changes anything. Also used, [compact], as the banner's Unmute button
/// and on the desktop app.
class MuteButton extends StatefulWidget {
  const MuteButton({
    super.key,
    required this.muted,
    required this.onMute,
    required this.onUnmute,
    this.hold = QuietHours.holdToMute,
    this.compact = false,
    this.buttonKey = const Key('muteButton'),
  });

  final bool muted;

  /// Called after the hold completes and the dialog is confirmed.
  final VoidCallback onMute;
  final VoidCallback onUnmute;
  final Duration hold;

  /// Short label ("Unmute") for the banner.
  final bool compact;
  final Key buttonKey;

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
      _confirm();
    }
  }

  Future<void> _confirm() async {
    final wasMuted = widget.muted;
    final ok = await confirmMuteChange(context, mute: !wasMuted);
    if (!ok || !mounted || widget.muted != wasMuted) return;
    if (wasMuted) {
      widget.onUnmute();
    } else {
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
      SnackBar(
        content: Text(
          widget.muted ? 'Keep holding to unmute' : 'Keep holding to mute',
        ),
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = widget.muted;
    final ring = SizedBox(
      width: 20,
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _ring,
            builder: (_, _) => CircularProgressIndicator(
              key: Key('${(widget.buttonKey as ValueKey).value}Progress'),
              value: _ring.value,
              strokeWidth: 2.5,
              color: muted ? cs.primary : cs.error,
              backgroundColor: Colors.transparent,
            ),
          ),
          Icon(muted ? Icons.volume_off : Icons.volume_up, size: 14),
        ],
      ),
    );
    final label = Text(
      muted ? (widget.compact ? 'Unmute' : 'Muted · hold to unmute') : 'Mute',
    );
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10),
      ),
      backgroundColor: muted && !widget.compact
          ? WidgetStatePropertyAll(cs.errorContainer)
          : null,
      foregroundColor: muted && !widget.compact
          ? WidgetStatePropertyAll(cs.onErrorContainer)
          : null,
    );
    // Taps are handled by the Listener (hint / hold), never the button.
    final button = muted && !widget.compact
        ? FilledButton.tonalIcon(
            key: widget.buttonKey,
            style: style,
            icon: ring,
            label: label,
            onPressed: () {},
          )
        : OutlinedButton.icon(
            key: widget.buttonKey,
            style: style,
            icon: ring,
            label: label,
            onPressed: () {},
          );
    return Listener(
      onPointerDown: (_) {
        _fired = false;
        _ring.forward(from: 0);
      },
      onPointerUp: (_) {
        if (!_fired) {
          _ring.stop();
          _ring.value = 0;
          _hint();
        }
      },
      onPointerCancel: (_) {
        _ring.stop();
        _ring.value = 0;
      },
      child: button,
    );
  }
}

/// "Mute Walkie?" / "Unmute Walkie?" (v1.9.9). Cancel has the focus;
/// tapping outside or Back cancels. True only when confirmed.
Future<bool> confirmMuteChange(
  BuildContext context, {
  required bool mute,
}) async {
  final word = mute ? 'Mute' : 'Unmute';
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      key: const Key('muteConfirm'),
      title: Text('$word Walkie?'),
      content: Text(
        mute
            ? 'Incoming talk, rings and beeps go quiet and are kept in '
                  'Missed until you unmute.'
            : 'Talk, rings and beeps will play again.',
      ),
      actions: [
        TextButton(
          key: const Key('muteConfirmCancel'),
          autofocus: true,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('muteConfirmOk'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(word),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Banner under the header while muted or in quiet hours. Its Unmute
/// button needs the same hold as the Mute button (v1.9.7).
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
            ? MuteButton(
                muted: true,
                compact: true,
                buttonKey: const Key('bannerUnmute'),
                onMute: () {},
                onUnmute: onUnmute,
              )
            : TextButton(onPressed: onSettings, child: const Text('Change')),
      ),
    );
  }
}

/// v2.3.0: the quiet-hours / muted state as a small moon (or speaker-off)
/// chip on the "Who can hear this?" line instead of a big card on the Talk
/// screen. Tap it for [showQuietSheet] (the same Change / Unmute options
/// the card had).
class QuietChip extends StatelessWidget {
  const QuietChip({
    super.key,
    required this.text,
    required this.muted,
    required this.onTap,
  });

  final String text;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$text. Tap for options',
      excludeSemantics: true,
      child: Tooltip(
        message: text,
        child: InkWell(
          key: const Key('quiet-chip'),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: muted ? cs.errorContainer : cs.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Icon(
                muted ? Icons.volume_off : Icons.bedtime,
                size: 16,
                color: muted ? cs.onErrorContainer : cs.onSecondaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The options behind [QuietChip]: what is quiet, "Change" (quiet hours) or
/// the held "Unmute" (muted). Closes itself when one is used.
Future<void> showQuietSheet(
  BuildContext context, {
  required String text,
  required bool muted,
  required VoidCallback onUnmute,
  required VoidCallback onSettings,
}) => showAppSheet<void>(
  context: context,
  builder: (ctx) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: QuietBanner(
      text: text,
      muted: muted,
      onUnmute: () {
        Navigator.of(ctx).pop();
        onUnmute();
      },
      onSettings: () {
        Navigator.of(ctx).pop();
        onSettings();
      },
    ),
  ),
);

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
              'Mute: hold the Mute button on the Talk screen for a second; '
              'it stays on until you hold it again to unmute. Quiet hours '
              'do the same on a schedule. Either way incoming talk is kept '
              'in Missed, and rings, beeps, join tones and notification '
              'sounds stay silent.',
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
                  key: Key('quietSwitch$i'),
                  value: q.schedules[i].enabled,
                  onChanged: (v) {
                    q.schedules[i].enabled = v;
                    c.saveQuietHours();
                  },
                ),
                title: Text(label(context, q.schedules[i])),
                subtitle: Text(q.schedules[i].enabled ? 'On' : 'Off'),
                onTap: () => editQuietSchedule(context, c, index: i),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('quietEdit$i'),
                      tooltip: 'Edit',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => editQuietSchedule(context, c, index: i),
                    ),
                    IconButton(
                      key: Key('quietDelete$i'),
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        final removed = q.schedules.removeAt(i);
                        c.saveQuietHours();
                        final m = ScaffoldMessenger.maybeOf(context);
                        m?.hideCurrentSnackBar();
                        m?.showSnackBar(
                          SnackBar(
                            content: const Text('Quiet hours deleted'),
                            action: SnackBarAction(
                              label: 'Undo',
                              onPressed: () {
                                q.schedules.insert(
                                  i.clamp(0, q.schedules.length),
                                  removed,
                                );
                                c.saveQuietHours();
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ],
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
          scrollable: true,
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
