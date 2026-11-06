// v2.6.9: Settings > Long-range radio (Meshtastic) > "Share radio with
// other programs on this PC" (desktop app only).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/walkie_controller.dart';
import '../lora/radio_share.dart';
import 'friendly_error.dart';

String _hm(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// "On at 127.0.0.1:4403 · 2 programs connected".
String radioShareStatusText(RadioShareHub h) {
  if (!h.running) return 'Not running';
  final n = h.clientCount;
  final who = n == 0
      ? 'no programs connected'
      : n == 1
      ? '1 program connected'
      : '$n programs connected';
  return 'On at 127.0.0.1:${h.port} · $who'
      '${h.radioAttached ? '' : ' · radio not connected'}';
}

/// What to type in Python / the meshtastic command for [port].
String radioShareHowTo(int port) => port == RadioShareHub.defaultPort
    ? "meshtastic --host 127.0.0.1   or   TCPInterface('127.0.0.1')"
    : "meshtastic --host 127.0.0.1:$port   or   "
          "TCPInterface('127.0.0.1', portNumber=$port)";

class RadioShareSetting extends StatelessWidget {
  const RadioShareSetting({super.key, required this.controller});
  final WalkieController controller;

  Future<void> _pickPort(BuildContext context) async {
    final c = controller;
    final ctl = TextEditingController(text: '${c.settings.radioSharePort}');
    String? error;
    final port = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          void done() {
            final p = int.tryParse(ctl.text.trim());
            if (p == null || p < 1024 || p > 65535) {
              setState(() => error = 'Use a number from 1024 to 65535.');
              return;
            }
            Navigator.pop(ctx, p);
          }

          return AlertDialog(
            title: const Text('Sharing port'),
            content: TextField(
              key: const Key('radioSharePortField'),
              controller: ctl,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                helperText: 'Default 4403, like a Wi-Fi radio.',
                errorText: error,
              ),
              onSubmitted: (_) => done(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: done, child: const Text('Save')),
            ],
          );
        },
      ),
    );
    if (port != null) await c.setRadioSharePort(port);
  }

  Future<void> _setAccess(BuildContext context, bool full) async {
    final c = controller;
    if (full && !c.settings.radioShareFull) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Give programs full access?'),
          content: const Text(
            'Programs on this PC could then change the radio\'s settings, '
            'channels and keys, or restart it, like the Meshtastic app can. '
            'Every change is logged here. Only do this for scripts you '
            'trust.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('radioShareFullConfirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Allow changes'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await c.setRadioShareFull(full);
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final h = c.radioShare;
    return RadioShareSection(
      on: c.settings.radioShareLocal,
      status: radioShareStatusText(h),
      error: c.radioShareError,
      port: c.settings.radioSharePort,
      full: c.settings.radioShareFull,
      events: h.events.take(3).toList(),
      onToggle: (v) => c.setRadioShareLocal(v),
      onPort: () => _pickPort(context),
      onAccess: (full) => _setAccess(context, full),
      onFix: (a) => runFix(context, c, a),
    );
  }
}

/// The switch, its status line or error, port, access and the last few
/// things programs did (plain data, for tests and screenshots).
class RadioShareSection extends StatelessWidget {
  const RadioShareSection({
    super.key,
    required this.on,
    required this.status,
    required this.port,
    required this.full,
    this.error,
    this.events = const [],
    required this.onToggle,
    required this.onPort,
    required this.onAccess,
    required this.onFix,
  });
  final bool on;
  final String status;
  final FriendlyError? error;
  final int port;
  final bool full;
  final List<RadioShareEvent> events;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPort;
  final ValueChanged<bool> onAccess;
  final void Function(FixAction) onFix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final err = error;
    final children = <Widget>[
      SwitchListTile(
        key: const Key('radioShareLocal'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Share radio with other programs on this PC'),
        subtitle: const Text(
          'Lets Meshtastic Python scripts and the meshtastic command use the '
          'radio while this app stays open. Only programs on this PC can '
          'connect.',
        ),
        value: on,
        onChanged: onToggle,
      ),
    ];
    if (on) {
      if (err != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FriendlyErrorView(error: err, onFix: onFix),
          ),
        );
      } else {
        children.add(
          Text(
            status,
            key: const Key('radioShareStatus'),
            style: theme.textTheme.bodyMedium,
          ),
        );
      }
      children.addAll([
        ListTile(
          key: const Key('radioSharePort'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Port'),
          subtitle: Text('$port'),
          trailing: const Icon(Icons.edit_outlined),
          onTap: onPort,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: SegmentedButton<bool>(
            key: const Key('radioShareAccess'),
            segments: const [
              ButtonSegment(value: false, label: Text('Read-only')),
              ButtonSegment(value: true, label: Text('Full access')),
            ],
            selected: {full},
            onSelectionChanged: (s) => onAccess(s.first),
          ),
        ),
        Text(
          full
              ? 'Full access: programs can also change the radio\'s '
                    'settings. Every change is logged below.'
              : 'Read-only: programs can read the node list and send text '
                    'messages and requests (position, traceroute, telemetry, '
                    'range test). Settings changes are blocked, and channel '
                    'keys and passwords are hidden from them.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        SelectableText(
          radioShareHowTo(port),
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ]);
      if (events.isNotEmpty) {
        children.add(const SizedBox(height: 4));
        for (final e in events) {
          children.add(
            Text(
              '${_hm(e.at)}  ${e.allowed ? 'Allowed' : 'Blocked'} ${e.what}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: e.allowed
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.outline,
              ),
            ),
          );
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
