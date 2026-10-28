import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../messaging/inbox.dart';
import '../messaging/messenger.dart';
import '../messaging/outbox.dart';
import '../messaging/voice_clip.dart';
import 'reach.dart';
import 'reach_of.dart';
import 'stop_on_leave.dart';

/// Received voice messages (play / delete) and ones still waiting to be
/// delivered.
///
/// v2.3.2: filter chips say whose messages these are: this channel / group
/// ("Here"), friends ("Direct") or "All". The Chat tab opens it already on
/// the right one.
enum InboxFilter { here, direct, all }

class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.controller,
    this.initial = InboxFilter.all,
  });
  final WalkieController controller;
  final InboxFilter initial;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  late InboxFilter _filter = widget.initial;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    bool outMine(OutgoingStatus o) => switch (_filter) {
      InboxFilter.all => true,
      InboxFilter.here => o.entry.isChannel && o.entry.channel == c.scope,
      InboxFilter.direct => !o.entry.isChannel,
    };
    bool inMine(InboxEntry e) => switch (_filter) {
      InboxFilter.all => true,
      InboxFilter.here => e.channel == c.scope,
      InboxFilter.direct => e.channel == WalkieController.friendScope,
    };
    return StopOnLeave(
      onLeave: c.stopSavedPlayback,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final out = c.outgoing.where(outMine).toList();
          final waiting = _filter == InboxFilter.direct
              ? const <OutboxEntry>[]
              : c.waitingForAnyone
                    .where(
                      (e) => _filter == InboxFilter.all || e.channel == c.scope,
                    )
                    .toList();
          final inbox = c.inbox.where(inMine).toList();
          final place = c.placeReach;
          return Scaffold(
            appBar: AppBar(title: const Text('Voice messages')),
            body: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final (f, label, icon) in [
                        (InboxFilter.here, 'Here · ${place.label}', place.icon),
                        (InboxFilter.direct, 'Direct', Icons.person),
                        (InboxFilter.all, 'All', Icons.all_inbox),
                      ])
                        ChoiceChip(
                          key: Key('inbox-filter-${f.name}'),
                          avatar: Icon(icon, size: 16),
                          label: Text(label, overflow: TextOverflow.ellipsis),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                    ],
                  ),
                ),
                if (out.isNotEmpty || waiting.isNotEmpty) ...[
                  const _Header('Waiting to be delivered'),
                  for (final o in out)
                    ListTile(
                      leading: Icon(
                        o.viaRadio
                            ? Icons.settings_input_antenna
                            : o.sending
                            ? Icons.upload
                            : Icons.schedule,
                      ),
                      title: Text(
                        'To ${c.nameOf(o.peer)}'
                        '${o.entry.isChannel ? ' (${c.labelFor(o.entry.channel)})' : ''}'
                        ' - ${formatDuration(o.entry.durationMs)}',
                      ),
                      subtitle: o.sending && o.viaRadio
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sending over the radio: '
                                  '${o.chunksDone}/${o.chunksTotal} packets',
                                ),
                                const SizedBox(height: 4),
                                LinearProgressIndicator(value: o.progress),
                              ],
                            )
                          : Text(
                              o.sending
                                  ? 'Sending ${(o.progress * 100).round()}%'
                                  : o.viaRadio && !o.entry.hasRadioBody
                                  ? 'Too long for the radio: waits for '
                                        'Wi-Fi, Bluetooth or internet '
                                        '(${_expires(o.entry.createdAt)})'
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
                if (inbox.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No voice messages yet. Long-press a person (or use '
                      '"Hold: message") to send one.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final e in inbox)
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
                    isThreeLine: true,
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_when(e.receivedAt)}'
                          '${e.channelMessage ? ' - to ${c.labelFor(e.channel)}' : ''}'
                          '${e.viaRadio ? ' - via radio' : ''}',
                        ),
                        const SizedBox(height: 2),
                        ReachTag(
                          e.channel == WalkieController.friendScope
                              ? Reach.direct(
                                  e.senderName.isEmpty
                                      ? c.nameOf(e.sender)
                                      : e.senderName,
                                )
                              : c.reachOfScope(e.channel),
                        ),
                      ],
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
      ),
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
