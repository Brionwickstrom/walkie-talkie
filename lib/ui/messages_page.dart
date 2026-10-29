import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../history/talk_history.dart';
import '../messaging/inbox.dart';
import '../messaging/messenger.dart';
import '../messaging/outbox.dart';
import '../messaging/sent_log.dart';
import '../messaging/voice_clip.dart';
import 'adaptive_layout.dart';
import 'home_view.dart';
import 'reach.dart';
import 'reach_of.dart';
import 'stop_on_leave.dart';

/// Messages (v2.4.0): the one place for voice messages and live talk you
/// missed, opened from the Messages icon on the Talk screen, the "waiting
/// to send" button, a voice message notification and the Direct chat page.
///
/// Filters: "Here" (this channel or group), "Direct" (friends) and "All".
enum MessagesFilter { here, direct, all }

/// Map a stored transmission to its view.
TakeView takeView(WalkieController c, TalkTake t) => TakeView(
  id: t.id,
  sender: t.sender,
  name: t.name.isEmpty ? c.nameOf(t.sender) : t.name,
  at: t.start,
  durationMs: t.durationMs,
  mine: t.mine,
  heard: t.heard,
  hops: t.hops,
  playing: c.playingTake?.id == t.id,
  positionMs: c.playingTake?.id == t.id ? c.playingPosMs : 0,
);

/// Open Messages: a page on phones, a dialog on wide screens.
Future<void> openMessages(
  BuildContext context,
  WalkieController c, {
  MessagesFilter filter = MessagesFilter.here,
  String? focusKey,
}) {
  final size = MediaQuery.sizeOf(context);
  if (isTwoPane(size.width, size.height)) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const Key('messages-dialog'),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: MessagesPage(
            controller: c,
            initial: filter,
            focusKey: focusKey,
            dialog: true,
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          MessagesPage(controller: c, initial: filter, focusKey: focusKey),
    ),
  );
}

/// The filter a list of queued messages belongs to.
MessagesFilter queuedFilter(WalkieController c) {
  final here = c.outgoing.any(
    (o) => o.entry.isChannel && o.entry.channel == c.scope,
  );
  final direct = c.outgoing.any((o) => !o.entry.isChannel);
  final elsewhere =
      c.waitingForAnyone.any((e) => e.channel != c.scope) ||
      c.outgoing.any((o) => o.entry.isChannel && o.entry.channel != c.scope);
  if (elsewhere || (here && direct)) return MessagesFilter.all;
  if (direct) return MessagesFilter.direct;
  return MessagesFilter.here;
}

class MessagesPage extends StatefulWidget {
  const MessagesPage({
    super.key,
    required this.controller,
    this.initial = MessagesFilter.here,
    this.focusKey,
    this.dialog = false,
  });
  final WalkieController controller;
  final MessagesFilter initial;

  /// Scroll to (and highlight) this voice message ([InboxEntry.key]).
  final String? focusKey;
  final bool dialog;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  late MessagesFilter _filter = widget.initial;
  bool _allSent = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return StopOnLeave(
      onLeave: c.stopSavedPlayback,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final f = _filter;
          final place = c.placeReach;
          final allPlaces = f == MessagesFilter.all;

          bool voiceIn(InboxEntry e, MessagesFilter x) => switch (x) {
            MessagesFilter.all => true,
            MessagesFilter.here => e.channel == c.scope,
            MessagesFilter.direct => e.channel == WalkieController.friendScope,
          };
          bool outIn(OutboxEntry o, MessagesFilter x) => switch (x) {
            MessagesFilter.all => true,
            MessagesFilter.here => o.isChannel && o.channel == c.scope,
            MessagesFilter.direct => !o.isChannel,
          };
          final allTakes = c.takesAll;
          int unheard(MessagesFilter x) =>
              c.inbox.where((e) => !e.played && voiceIn(e, x)).length +
              switch (x) {
                MessagesFilter.here => c.unheardTakes,
                MessagesFilter.direct => 0,
                MessagesFilter.all => c.unheardTakesAll,
              };

          final takes = switch (f) {
            MessagesFilter.here => c.takes,
            MessagesFilter.direct => const <TalkTake>[],
            MessagesFilter.all => allTakes,
          };
          final voice = c.inbox.where((e) => voiceIn(e, f)).toList();
          final waiting = <WaitingRow>[
            for (final o in c.outgoing)
              if (outIn(o.entry, f)) _waitingOut(c, o, allPlaces),
            if (f != MessagesFilter.direct)
              for (final e in c.waitingForAnyone)
                if (allPlaces || e.channel == c.scope) _waitingAnyone(c, e),
          ];
          final sent = <SentRow>[
            for (final (r, friend) in c.sentMessages)
              if (switch (f) {
                MessagesFilter.all => true,
                MessagesFilter.here => r.isChannel && r.channel == c.scope,
                MessagesFilter.direct => !r.isChannel,
              })
                _sentRow(c, r, friend, allPlaces),
          ];
          final unheardTakes = takes.where((t) => !t.heard).length;

          return MessagesView(
            dialog: widget.dialog,
            focusKey: widget.focusKey,
            filter: f,
            onFilter: (x) => setState(() => _filter = x),
            place: place,
            chips: [
              (MessagesFilter.here, 'Here · ${place.label}', place.icon),
              (MessagesFilter.direct, 'Direct', Icons.person),
              (MessagesFilter.all, 'All', Icons.all_inbox),
            ],
            unheard: {for (final x in MessagesFilter.values) x: unheard(x)},
            waiting: waiting,
            sent: sent,
            allSent: _allSent,
            onAllSent: () => setState(() => _allSent = true),
            takes: [
              for (final t in takes)
                TakeRow(
                  take: takeView(c, t),
                  tag: allPlaces ? c.reachOfScope(t.scope) : null,
                  onPlay: () => c.playTake(t),
                  onDelete: () => c.deleteTake(t),
                ),
            ],
            voice: [
              for (final e in voice)
                VoiceRow(
                  key: e.key,
                  sender: e.sender,
                  who: e.senderName.isEmpty ? c.nameOf(e.sender) : e.senderName,
                  when: _when(e.receivedAt),
                  to: allPlaces && e.channelMessage
                      ? c.labelFor(e.channel)
                      : null,
                  durationMs: e.durationMs,
                  played: e.played,
                  playing: c.playingKey == e.key,
                  viaRadio: e.viaRadio,
                  tag: allPlaces
                      ? (e.channel == WalkieController.friendScope
                            ? Reach.direct(
                                e.senderName.isEmpty
                                    ? c.nameOf(e.sender)
                                    : e.senderName,
                              )
                            : c.reachOfScope(e.channel))
                      : null,
                  onPlay: () => c.playingKey == e.key
                      ? c.stopPlayback()
                      : c.playMessage(e),
                  onDelete: () => c.deleteMessage(e),
                ),
            ],
            speed: c.playbackSpeed,
            playingAll: c.playingAll,
            unheardTakes: unheardTakes,
            onSpeed: c.setPlaybackSpeed,
            onPlayMissed: () => c.playingAll
                ? c.pauseTake()
                : c.playAllMissed(allPlaces: allPlaces),
            onMarkAllHeard: () async {
              c.markAllHeard(allPlaces: allPlaces);
              await c.markVoicePlayed((e) => voiceIn(e, f));
            },
            onClearTalk: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  scrollable: true,
                  title: const Text('Clear live talk history?'),
                  content: Text(
                    allPlaces
                        ? 'Deletes every saved transmission on every channel '
                              'and group from this phone.'
                        : 'Deletes every saved transmission on '
                              '${c.channelLabel} from this phone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
              if (ok == true) await c.clearHistory(allPlaces: allPlaces);
            },
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

  WaitingRow _waitingOut(WalkieController c, OutgoingStatus o, bool showTag) {
    final e = o.entry;
    return WaitingRow(
      id: '${e.msgId}',
      icon: o.viaRadio
          ? Icons.settings_input_antenna
          : o.sending
          ? Icons.upload
          : Icons.schedule,
      title:
          'To ${c.nameOf(o.peer)}'
          '${e.isChannel && showTag ? ' (${c.labelFor(e.channel)})' : ''}'
          ' - ${formatDuration(e.durationMs)}',
      subtitle: o.sending && o.viaRadio
          ? 'Sending over the radio: ${o.chunksDone}/${o.chunksTotal} packets'
          : o.sending
          ? 'Sending ${(o.progress * 100).round()}%'
          : o.viaRadio && !e.hasRadioBody
          ? 'Too long for the radio: waits for Wi-Fi, Bluetooth or internet '
                '(${_expires(e.createdAt)})'
          : 'Will send when they are in range (${_expires(e.createdAt)})',
      progress: o.sending && o.viaRadio ? o.progress : null,
      onCancel: () => c.cancelOutgoing(e.msgId),
    );
  }

  WaitingRow _waitingAnyone(WalkieController c, OutboxEntry e) => WaitingRow(
    id: '${e.msgId}',
    icon: Icons.schedule,
    title: 'To ${c.labelFor(e.channel)} - ${formatDuration(e.durationMs)}',
    subtitle: 'Nobody on that channel yet (${_expires(e.createdAt)})',
    onCancel: () => c.cancelOutgoing(e.msgId),
  );

  SentRow _sentRow(
    WalkieController c,
    SentRecord r,
    bool friend,
    bool showTag,
  ) {
    String who(int id) => friend ? c.friendName(id) : c.nameOf(id);
    final to = r.isChannel
        ? (r.peers.length == 1
              ? who(r.peers.first)
              : '${r.peers.length} people')
        : who(r.toPeer!);
    final status = r.heard
        ? 'Listened'
        : r.peers.length > 1
        ? 'Delivered to ${r.peers.length}'
        : 'Delivered';
    return SentRow(
      id: '${r.msgId}',
      title: 'To $to · ${formatDuration(r.durationMs)}',
      status: status,
      when: _when(r.deliveredAt),
      heard: r.heard,
      tag: showTag
          ? (r.isChannel ? c.reachOfScope(r.channel) : Reach.direct(to))
          : null,
      onForget: () => c.forgetSent(r, friend: friend),
    );
  }
}

/// A voice message or transmission waiting to be delivered.
class WaitingRow {
  const WaitingRow({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onCancel,
    this.progress,
  });
  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final double? progress;
  final VoidCallback onCancel;
}

/// A delivered voice message of ours: "Sent".
class SentRow {
  const SentRow({
    required this.id,
    required this.title,
    required this.status,
    required this.when,
    required this.onForget,
    this.heard = false,
    this.tag,
  });
  final String id;
  final String title;
  final String status;
  final String when;
  final bool heard;
  final Reach? tag;
  final VoidCallback onForget;
}

/// One missed (or replayable) live transmission.
class TakeRow {
  const TakeRow({
    required this.take,
    required this.onPlay,
    required this.onDelete,
    this.tag,
  });
  final TakeView take;
  final Reach? tag;
  final VoidCallback onPlay;
  final VoidCallback onDelete;
}

/// One received voice message.
class VoiceRow {
  const VoiceRow({
    required this.key,
    required this.sender,
    required this.who,
    required this.when,
    required this.durationMs,
    required this.played,
    required this.playing,
    required this.onPlay,
    required this.onDelete,
    this.to,
    this.viaRadio = false,
    this.tag,
  });
  final String key;
  final int sender;
  final String who;
  final String when;
  final String? to;
  final int durationMs;
  final bool played;
  final bool playing;
  final bool viaRadio;
  final Reach? tag;
  final VoidCallback onPlay;
  final VoidCallback onDelete;
}

/// The Messages screen without the controller (also used by layout tests).
class MessagesView extends StatefulWidget {
  const MessagesView({
    super.key,
    required this.filter,
    required this.onFilter,
    required this.place,
    required this.chips,
    required this.unheard,
    required this.waiting,
    required this.sent,
    required this.takes,
    required this.voice,
    required this.speed,
    required this.playingAll,
    required this.unheardTakes,
    required this.onSpeed,
    required this.onPlayMissed,
    required this.onMarkAllHeard,
    required this.onClearTalk,
    this.allSent = false,
    this.onAllSent,
    this.focusKey,
    this.dialog = false,
  });

  final MessagesFilter filter;
  final ValueChanged<MessagesFilter> onFilter;
  final Reach place;
  final List<(MessagesFilter, String, IconData)> chips;

  /// Not heard yet per filter (shown on the chip).
  final Map<MessagesFilter, int> unheard;
  final List<WaitingRow> waiting;
  final List<SentRow> sent;
  final bool allSent;
  final VoidCallback? onAllSent;
  final List<TakeRow> takes;
  final List<VoiceRow> voice;
  final double speed;
  final bool playingAll;
  final int unheardTakes;
  final ValueChanged<double> onSpeed;
  final VoidCallback onPlayMissed;
  final VoidCallback onMarkAllHeard;
  final VoidCallback onClearTalk;
  final String? focusKey;
  final bool dialog;

  /// Sent messages shown before "Show all".
  static const sentPreview = 3;

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final _scroll = ScrollController();
  final _focus = GlobalKey();
  String? _scrolledTo;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToFocus(int index, [int tries = 0]) {
    final key = widget.focusKey;
    if (key == null || _scrolledTo == key) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final ctx = _focus.currentContext;
      if (ctx != null) {
        _scrolledTo = key;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: const Duration(milliseconds: 250),
        );
      } else if (tries < 6) {
        // Not built yet (far down the list): jump near it first.
        final max = _scroll.position.maxScrollExtent;
        _scroll.jumpTo((index * 92.0).clamp(0.0, max));
        _scrollToFocus(index, tries + 1);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final theme = Theme.of(context);
    final f = w.filter;
    final showTalk = f != MessagesFilter.direct;
    final empty =
        w.waiting.isEmpty &&
        w.sent.isEmpty &&
        w.voice.isEmpty &&
        (w.takes.isEmpty || !showTalk);
    final children = <Widget>[];
    var focusIndex = -1;

    children.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Wrap(
          spacing: 8,
          children: [
            for (final (x, label, icon) in w.chips)
              ChoiceChip(
                key: Key('messages-filter-${x.name}'),
                showCheckmark: false,
                avatar: Icon(icon, size: 16),
                label: Text(
                  (w.unheard[x] ?? 0) > 0 ? '$label (${w.unheard[x]})' : label,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: f == x,
                onSelected: (_) => w.onFilter(x),
              ),
          ],
        ),
      ),
    );
    if (f != MessagesFilter.here) {
      children.add(
        Padding(
          key: const Key('messages-direct-note'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            f == MessagesFilter.direct
                ? 'Live talk in a direct chat is not recorded. Only voice '
                      'messages are kept here.'
                : 'Live talk in direct chats is not recorded, only voice '
                      'messages.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }

    if (empty) {
      children.add(
        Padding(
          key: const Key('messages-empty'),
          padding: const EdgeInsets.all(24),
          child: Text(
            f == MessagesFilter.direct
                ? 'No voice messages from friends yet.'
                : 'Nothing here yet. Hold Message on the Talk screen to send '
                      'a voice message; talk you miss shows up here.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (w.waiting.isNotEmpty) {
      children.add(const _Header('Waiting to send'));
      for (final o in w.waiting) {
        children.add(
          ListTile(
            key: Key('waiting-${o.id}'),
            leading: Icon(o.icon),
            title: Text(o.title),
            subtitle: o.progress == null
                ? Text(o.subtitle)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(o.subtitle),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: o.progress),
                    ],
                  ),
            trailing: IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: o.onCancel,
            ),
          ),
        );
      }
    }

    if (showTalk && w.takes.isNotEmpty) {
      children.add(
        _Header(
          'Live talk',
          key: const Key('messages-talk-header'),
          note:
              'The last 50 per place (up to 24 hours), kept only on this '
              'phone. Swipe one away to delete it.',
        ),
      );
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<double>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 1, label: Text('1x')),
                  ButtonSegment(value: 1.5, label: Text('1.5x')),
                  ButtonSegment(value: 2, label: Text('2x')),
                ],
                selected: {w.speed},
                onSelectionChanged: (s) => w.onSpeed(s.first),
              ),
              FilledButton.icon(
                key: const Key('messages-play-missed'),
                icon: Icon(w.playingAll ? Icons.stop : Icons.playlist_play),
                label: Text(
                  w.playingAll
                      ? 'Stop'
                      : w.unheardTakes > 0
                      ? 'Play all missed (${w.unheardTakes})'
                      : 'Nothing missed',
                ),
                onPressed: w.playingAll || w.unheardTakes > 0
                    ? w.onPlayMissed
                    : null,
              ),
            ],
          ),
        ),
      );
      for (final r in w.takes) {
        final focused = false;
        children.add(_takeCard(context, r, focused));
      }
    }

    if (w.voice.isNotEmpty) {
      children.add(const _Header('Voice messages'));
      for (final r in w.voice) {
        final focused = r.key == w.focusKey;
        if (focused) focusIndex = children.length;
        children.add(
          KeyedSubtree(
            key: focused ? _focus : ValueKey('voice-row-${r.key}'),
            child: _voiceCard(context, r, focused),
          ),
        );
      }
    }

    if (w.sent.isNotEmpty) {
      children.add(const _Header('Sent'));
      final shown = w.allSent
          ? w.sent
          : w.sent.take(MessagesView.sentPreview).toList();
      for (final s in shown) {
        children.add(
          ListTile(
            key: Key('sent-${s.id}'),
            dense: true,
            leading: Icon(
              s.heard ? Icons.done_all : Icons.check,
              size: 20,
              color: s.heard ? theme.colorScheme.primary : null,
            ),
            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${s.status} · ${s.when}',
              style: TextStyle(
                color: s.heard ? theme.colorScheme.primary : null,
              ),
            ),
            trailing: IconButton(
              tooltip: 'Remove from Sent',
              icon: const Icon(Icons.close, size: 18),
              onPressed: s.onForget,
            ),
          ),
        );
      }
      if (!w.allSent && w.sent.length > MessagesView.sentPreview) {
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('sent-show-all'),
              onPressed: w.onAllSent,
              child: Text('Show all (${w.sent.length})'),
            ),
          ),
        );
      }
    }

    if (focusIndex >= 0) _scrollToFocus(focusIndex);

    final body = ListView(
      key: const Key('messages-list'),
      controller: _scroll,
      padding: EdgeInsets.only(
        bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: children,
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !w.dialog,
        leading: w.dialog
            ? IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: const Text('Messages'),
        actions: [
          PopupMenuButton<String>(
            key: const Key('messages-menu'),
            onSelected: (v) =>
                v == 'heard' ? w.onMarkAllHeard() : w.onClearTalk(),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'heard',
                child: Text('Mark all as heard'),
              ),
              if (showTalk)
                const PopupMenuItem(
                  value: 'clear',
                  child: Text('Clear live talk history'),
                ),
            ],
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _takeCard(BuildContext context, TakeRow r, bool focused) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = r.take;
    final progress = t.durationMs == 0
        ? 0.0
        : (t.positionMs / t.durationMs).clamp(0.0, 1.0);
    return Dismissible(
      key: ValueKey('take-${t.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: cs.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) => r.onDelete(),
      child: Card(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        color: t.playing ? cs.primaryContainer : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: r.onPlay,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Badge(
                      isLabelVisible: !t.heard,
                      smallSize: 12,
                      child: Avatar(id: t.sender, name: t.name, size: 40),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.who,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: t.heard
                                  ? FontWeight.w500
                                  : FontWeight.w800,
                            ),
                          ),
                          Text(
                            'Live talk · ${clockText(t.at)} · '
                            '${clipLength(t.durationMs)}'
                            '${t.hops > 1 ? ' · ${hopsText(t.hops)}' : ''}'
                            '${t.heard ? '' : ' · not heard'}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: t.heard ? null : cs.primary,
                            ),
                          ),
                          if (r.tag != null) ReachTag(r.tag!),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: t.playing ? 'Pause' : 'Play',
                      icon: Icon(t.playing ? Icons.pause : Icons.play_arrow),
                      onPressed: r.onPlay,
                    ),
                  ],
                ),
                if (t.playing)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(50, 6, 12, 0),
                    child: LinearProgressIndicator(value: progress),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _voiceCard(BuildContext context, VoiceRow r, bool focused) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Dismissible(
      key: ValueKey('voice-dismiss-${r.key}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: cs.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) => r.onDelete(),
      child: Card(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        color: r.playing
            ? cs.primaryContainer
            : focused
            ? cs.secondaryContainer
            : null,
        shape: focused
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.primary, width: 2),
              )
            : null,
        child: InkWell(
          key: Key('voice-${r.key}'),
          borderRadius: BorderRadius.circular(12),
          onTap: r.onPlay,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
            child: Row(
              children: [
                Badge(
                  isLabelVisible: !r.played,
                  smallSize: 12,
                  child: Avatar(id: r.sender, name: r.who, size: 40),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${r.who} · ${formatDuration(r.durationMs)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: r.played
                              ? FontWeight.w500
                              : FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${r.when}'
                        '${r.to != null ? ' · to ${r.to}' : ''}'
                        '${r.viaRadio ? ' · via radio' : ''}'
                        '${r.played ? '' : ' · new'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: r.played ? null : cs.primary,
                        ),
                      ),
                      if (r.tag != null) ReachTag(r.tag!),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: r.playing ? 'Stop' : 'Play',
                  icon: Icon(r.playing ? Icons.stop : Icons.play_arrow),
                  onPressed: r.onPlay,
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: r.onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {super.key, this.note});
  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: theme.textTheme.titleSmall),
          if (note != null) Text(note!, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
