import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../history/talk_history.dart';
import 'home_view.dart';

/// Map a stored transmission to its view.
TakeView takeView(WalkieController c, TalkTake t) => TakeView(
  id: t.id,
  sender: t.sender,
  name: t.name.isEmpty ? c.nameOf(t.sender) : t.name,
  at: t.start,
  durationMs: t.durationMs,
  mine: t.mine,
  heard: t.heard,
  playing: c.playingTake?.id == t.id,
  positionMs: c.playingTake?.id == t.id ? c.playingPosMs : 0,
);

/// Replay missed talk on the current channel.
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final list = c.takes;
        return HistoryView(
          channelLabel: c.channelLabel,
          takes: [for (final t in list) takeView(c, t)],
          unheard: c.unheardTakes,
          speed: c.playbackSpeed,
          playingAll: c.playingAll,
          onPlay: (v) {
            final t = list.where((x) => x.id == v.id).firstOrNull;
            if (t != null) c.playTake(t);
          },
          onPlayMissed: () => c.playingAll ? c.pauseTake() : c.playAllMissed(),
          onSpeed: c.setPlaybackSpeed,
          onDelete: (v) {
            final t = list.where((x) => x.id == v.id).firstOrNull;
            if (t != null) c.deleteTake(t);
          },
          onMarkAllHeard: c.markAllHeard,
          onClear: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Clear history?'),
                content: Text(
                  'Deletes every saved transmission on ${c.channelLabel} '
                  'from this phone.',
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
            if (ok == true) await c.clearHistory();
          },
        );
      },
    );
  }
}

class HistoryView extends StatelessWidget {
  const HistoryView({
    super.key,
    required this.channelLabel,
    required this.takes,
    required this.unheard,
    required this.speed,
    required this.playingAll,
    required this.onPlay,
    required this.onPlayMissed,
    required this.onSpeed,
    required this.onDelete,
    required this.onMarkAllHeard,
    required this.onClear,
  });

  final String channelLabel;
  final List<TakeView> takes;
  final int unheard;
  final double speed;
  final bool playingAll;
  final ValueChanged<TakeView> onPlay;
  final VoidCallback onPlayMissed;
  final ValueChanged<double> onSpeed;
  final ValueChanged<TakeView> onDelete;
  final VoidCallback onMarkAllHeard;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('History · $channelLabel', overflow: TextOverflow.fade),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => v == 'heard' ? onMarkAllHeard() : onClear(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'heard', child: Text('Mark all as heard')),
              PopupMenuItem(value: 'clear', child: Text('Clear history')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<double>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1x')),
                    ButtonSegment(value: 1.5, label: Text('1.5x')),
                    ButtonSegment(value: 2, label: Text('2x')),
                  ],
                  selected: {speed},
                  onSelectionChanged: (s) => onSpeed(s.first),
                ),
                FilledButton.icon(
                  icon: Icon(playingAll ? Icons.stop : Icons.playlist_play),
                  label: Text(
                    playingAll
                        ? 'Stop'
                        : unheard > 0
                        ? 'Play all missed ($unheard)'
                        : 'Nothing missed',
                  ),
                  onPressed: playingAll || unheard > 0 ? onPlayMissed : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Text(
              'The last 50 transmissions (up to 24 hours) on this channel, '
              'kept only on this phone. Swipe one away to delete it.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: takes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Nothing said on $channelLabel yet.\nWhen people '
                        'talk, you can replay it here.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(
                      bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
                    ),
                    itemCount: takes.length,
                    itemBuilder: (context, i) {
                      final t = takes[i];
                      final progress = t.durationMs == 0
                          ? 0.0
                          : (t.positionMs / t.durationMs).clamp(0.0, 1.0);
                      return Dismissible(
                        key: ValueKey(t.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: cs.errorContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: const Icon(Icons.delete),
                        ),
                        onDismissed: (_) => onDelete(t),
                        child: Card(
                          margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                          color: t.playing ? cs.primaryContainer : null,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => onPlay(t),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Badge(
                                        isLabelVisible: !t.heard,
                                        smallSize: 12,
                                        child: Avatar(
                                          id: t.sender,
                                          name: t.name,
                                          size: 40,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              t.who,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                    fontWeight: t.heard
                                                        ? FontWeight.w500
                                                        : FontWeight.w800,
                                                  ),
                                            ),
                                            Text(
                                              '${clockText(t.at)} · '
                                              '${clipLength(t.durationMs)}'
                                              '${t.heard ? '' : ' · not heard'}',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    color: t.heard
                                                        ? null
                                                        : cs.primary,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton.filledTonal(
                                        tooltip: t.playing ? 'Pause' : 'Play',
                                        icon: Icon(
                                          t.playing
                                              ? Icons.pause
                                              : Icons.play_arrow,
                                        ),
                                        onPressed: () => onPlay(t),
                                      ),
                                    ],
                                  ),
                                  if (t.playing)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        50,
                                        6,
                                        12,
                                        0,
                                      ),
                                      child: LinearProgressIndicator(
                                        value: progress,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
