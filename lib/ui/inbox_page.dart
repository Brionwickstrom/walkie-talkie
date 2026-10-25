import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../messaging/voice_clip.dart';

/// Received voice messages (play / delete) and ones still waiting to be
/// delivered.
class InboxPage extends StatelessWidget {
  const InboxPage({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final out = c.outgoing;
        final waiting = c.waitingForAnyone;
        return Scaffold(
          appBar: AppBar(title: const Text('Voice messages')),
          body: ListView(
            children: [
              if (out.isNotEmpty || waiting.isNotEmpty) ...[
                const _Header('Waiting to be delivered'),
                for (final o in out)
                  ListTile(
                    leading: Icon(o.sending ? Icons.upload : Icons.schedule),
                    title: Text(
                      'To ${c.nameOf(o.peer)}'
                      '${o.entry.isChannel ? ' (${c.labelFor(o.entry.channel)})' : ''}'
                      ' - ${formatDuration(o.entry.durationMs)}',
                    ),
                    subtitle: Text(
                      o.sending
                          ? 'Sending ${(o.progress * 100).round()}%'
                          : 'Will send when they are in range '
                                '(${_expires(o.entry.createdAt)})',
                    ),
                    trailing: IconButton(
                      tooltip: 'Cancel',
                      icon: const Icon(Icons.close),
                      onPressed: () => c.cancelOutgoing(o.entry.msgId),
                    ),
                  ),
                for (final e in waiting)
                  ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text(
                      'To ${c.labelFor(e.channel)} - ${formatDuration(e.durationMs)}',
                    ),
                    subtitle: Text(
                      'Nobody on that channel yet (${_expires(e.createdAt)})',
                    ),
                    trailing: IconButton(
                      tooltip: 'Cancel',
                      icon: const Icon(Icons.close),
                      onPressed: () => c.cancelOutgoing(e.msgId),
                    ),
                  ),
              ],
              const _Header('Received'),
              if (c.inbox.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No voice messages yet. Long-press a person (or use '
                    '"Hold: message") to send one.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final e in c.inbox)
                ListTile(
                  leading: IconButton.filledTonal(
                    icon: Icon(
                      c.playingKey == e.key ? Icons.stop : Icons.play_arrow,
                    ),
                    onPressed: () => c.playingKey == e.key
                        ? c.stopPlayback()
                        : c.playMessage(e),
                  ),
                  title: Text(
                    '${e.senderName.isEmpty ? c.nameOf(e.sender) : e.senderName}'
                    ' - ${formatDuration(e.durationMs)}',
                    style: TextStyle(
                      fontWeight: e.played
                          ? FontWeight.normal
                          : FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    '${_when(e.receivedAt)}'
                    '${e.channelMessage ? ' - to ${c.labelFor(e.channel)}' : ''}',
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => c.deleteMessage(e),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }

  static String _expires(DateTime created) {
    final left = const Duration(hours: 24) - DateTime.now().difference(created);
    return left.inHours >= 1
        ? 'gives up in ${left.inHours} h'
        : 'gives up in ${left.inMinutes.clamp(0, 59)} min';
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}
