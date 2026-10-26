import 'dart:async';

import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../app/whos_where.dart';
import 'home_view.dart';
import 'sheets.dart';

/// Who's where (v1.8.2): everyone this phone can see, grouped by channel.
class WhosWherePage extends StatefulWidget {
  const WhosWherePage({super.key, required this.controller, this.onOpenPerson});
  final WalkieController controller;

  /// Opens the full person card (volume, ring...) for someone in the
  /// people list.
  final void Function(BuildContext context, int id)? onOpenPerson;

  @override
  State<WhosWherePage> createState() => _WhosWherePageState();
}

class _WhosWherePageState extends State<WhosWherePage> {
  WalkieController get c => widget.controller;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // "12s ago" and expiring beacons.
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _jump(WhoGroup g) async {
    final ch = g.channel;
    if (ch == null) return;
    final privateHere = c.settings.passcodeFor(ch) != null;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    await c.setChannel(ch);
    // This phone has a passcode saved for that number: we are now on our
    // private CH n, not the public one those people are on.
    if (privateHere) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'CH $ch is private on this phone, so you joined your private '
            'CH $ch. Make it public (lock icon) to join them.',
          ),
        ),
      );
    }
  }

  void _person(WhoGroup g, WhoPerson p) {
    if (p.me) return;
    if (p.known && widget.onOpenPerson != null) {
      widget.onOpenPerson!(context, p.id);
      return;
    }
    showAppSheet<void>(
      context: context,
      builder: (ctx) => WhoPersonSheet(
        person: p,
        group: g,
        onJump: g.canJump
            ? () {
                Navigator.pop(ctx);
                _jump(g);
              }
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => WhosWhereView(
        groups: c.whosWhereGroups,
        showMe: c.settings.showInWhosWhere,
        offline: c.settings.offlineSaver,
        lobbyOnline: c.whosWhere.relayOpen,
        privateNumbers: {
          for (final g in c.whosWhereGroups)
            if (g.channel != null && c.settings.passcodeFor(g.channel!) != null)
              g.channel!,
        },
        onJump: _jump,
        onPerson: _person,
        onShowMe: c.setShowInWhosWhere,
      ),
    );
  }
}

/// The Who's where screen (presentation only; previews and tests use it).
class WhosWhereView extends StatelessWidget {
  const WhosWhereView({
    super.key,
    required this.groups,
    required this.showMe,
    this.offline = false,
    this.lobbyOnline = false,
    this.privateNumbers = const {},
    this.onJump,
    this.onPerson,
    this.onShowMe,
  });
  final List<WhoGroup> groups;
  final bool showMe;
  final bool offline;
  final bool lobbyOnline;

  /// Channel numbers this phone has a passcode for (jumping there joins
  /// our private version).
  final Set<int> privateNumbers;
  final ValueChanged<WhoGroup>? onJump;
  final void Function(WhoGroup, WhoPerson)? onPerson;
  final ValueChanged<bool>? onShowMe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = whosWhereTotal(groups);
    final channels = groups
        .where((g) => g.kind != WhoGroupKind.friends && g.people.isNotEmpty)
        .length;
    return Scaffold(
      appBar: AppBar(title: const Text("Who's where")),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Text(
                total == 0
                    ? 'Nobody else in range or online yet.'
                    : '$total ${total == 1 ? 'person' : 'people'} on '
                          '$channels ${channels == 1 ? 'channel' : 'channels'}',
                key: const Key('whos-where-summary'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Text(
                offline
                    ? 'Offline power save: nearby phones only (Wi-Fi, '
                          'Bluetooth, phone relay).'
                    : lobbyOnline
                    ? 'Nearby phones and everyone online.'
                    : 'Nearby phones (internet lobby connecting...).',
                style: theme.textTheme.bodySmall,
              ),
            ),
            for (final g in groups)
              if (g.people.isNotEmpty)
                _GroupCard(
                  group: g,
                  privateHere:
                      g.channel != null && privateNumbers.contains(g.channel),
                  onJump: g.canJump && onJump != null ? () => onJump!(g) : null,
                  onPerson: onPerson == null ? null : (p) => onPerson!(g, p),
                ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('whosWhereShowMe'),
              title: const Text("Show me in Who's where"),
              subtitle: const Text(
                'Lets phones on other channels see your name and public '
                'channel. On a private channel they only see "Private" and '
                'your call sign, never the channel.',
              ),
              value: showMe,
              onChanged: onShowMe,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Tap a channel to go there, or a person for details. Phones '
                'on app versions before 1.8.2 only show up when they are '
                'nearby on a public channel or on your channel.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    this.privateHere = false,
    this.onJump,
    this.onPerson,
  });
  final WhoGroup group;
  final bool privateHere;
  final VoidCallback? onJump;
  final ValueChanged<WhoPerson>? onPerson;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mine = g.kind == WhoGroupKind.mine;
    final (IconData icon, Color color) = switch (g.kind) {
      WhoGroupKind.mine => (Icons.my_location, cs.primary),
      WhoGroupKind.public => (Icons.tag, cs.secondary),
      WhoGroupKind.private => (Icons.lock, cs.tertiary),
      WhoGroupKind.friends => (Icons.star, Colors.amber.shade700),
    };
    final n = g.count;
    final subtitle = switch (g.kind) {
      WhoGroupKind.mine =>
        'You are here${g.isPrivate ? ' (private)' : ''} · $n other${n == 1 ? '' : 's'}',
      WhoGroupKind.public =>
        '$n ${n == 1 ? 'person' : 'people'}'
            '${privateHere ? ' · public (yours is private)' : ''}',
      WhoGroupKind.private => '$n · channel not shown',
      WhoGroupKind.friends => '$n online · channel not shared',
    };
    return Card(
      key: Key('who-group-${g.kind.name}-${g.channel ?? ''}'),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      color: mine ? cs.primaryContainer.withValues(alpha: 0.45) : null,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onJump,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              child: Row(
                children: [
                  if ((g.emoji ?? '').isNotEmpty &&
                      g.kind != WhoGroupKind.private)
                    Text(g.emoji!, style: const TextStyle(fontSize: 22))
                  else
                    Icon(icon, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(g),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(subtitle, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  if (onJump != null)
                    FilledButton.tonalIcon(
                      key: Key('who-jump-${g.channel}'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: onJump,
                      icon: const Icon(Icons.login, size: 18),
                      label: const Text('Go'),
                    ),
                ],
              ),
            ),
          ),
          for (final p in g.people)
            _PersonRow(
              person: p,
              onTap: p.me || onPerson == null ? null : () => onPerson!(p),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  static String _title(WhoGroup g) => switch (g.kind) {
    WhoGroupKind.private => 'Private',
    WhoGroupKind.friends => 'Friends',
    _ =>
      (g.name ?? '').isNotEmpty
          ? '${g.name} · CH ${g.channel}'
          : 'CH ${g.channel}',
  };
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person, this.onTap});
  final WhoPerson person;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 12, 2),
        child: Row(
          children: [
            Avatar(id: p.id, name: p.name, size: 32, talking: p.talking),
            const SizedBox(width: 4),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      p.me ? '${p.name} (you)' : p.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: p.me ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  if (p.friend) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.star, size: 16, color: Colors.amber.shade700),
                  ],
                  if (p.talking) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.graphic_eq, size: 16, color: cs.primary),
                  ],
                ],
              ),
            ),
            if (p.battery != null && !p.me) ...[
              BatteryBadge(p.battery!),
              const SizedBox(width: 4),
            ],
            WhoPaths(person: p),
          ],
        ),
      ),
    );
  }
}

/// Path icons: Wi-Fi, Wi-Fi Direct, Bluetooth, internet, LoRa, and
/// "2 hops" for the phone mesh.
class WhoPaths extends StatelessWidget {
  const WhoPaths({super.key, required this.person});
  final WhoPerson person;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (p.me) return const SizedBox.shrink();
    final links = p.links.toList()
      ..sort((a, b) => b.defaultPriority.compareTo(a.defaultPriority));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final k in links)
          Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Tooltip(
              message: transportName(k),
              child: Icon(transportIcon(k), size: 16, color: cs.primary),
            ),
          ),
        if (p.hops != null) ...[
          const SizedBox(width: 3),
          Icon(Icons.hub, size: 16, color: cs.primary),
          Text(' ${p.hops} hops', style: theme.textTheme.bodySmall),
        ],
        if (links.isEmpty && p.hops == null)
          Icon(Icons.star_outline, size: 16, color: cs.outline),
      ],
    );
  }
}

/// Details for someone only heard through Who's where.
class WhoPersonSheet extends StatelessWidget {
  const WhoPersonSheet({
    super.key,
    required this.person,
    required this.group,
    this.onJump,
  });
  final WhoPerson person;
  final WhoGroup group;
  final VoidCallback? onJump;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final theme = Theme.of(context);
    final where = switch (group.kind) {
      WhoGroupKind.private => 'On a private channel',
      WhoGroupKind.friends => 'Online (channel not shared)',
      _ => 'On ${_GroupCard._title(group)}',
    };
    final via = [
      for (final k in p.links) transportName(k),
      if (p.hops != null) 'phone relay (${p.hops} hops)',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(id: p.id, name: p.name),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (p.friend) Icon(Icons.star, color: Colors.amber.shade700),
            ],
          ),
          const SizedBox(height: 8),
          Text(where, style: theme.textTheme.bodyLarge),
          if (via.isNotEmpty)
            Text(
              'Seen via ${via.join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
          if (p.lastHeard != null)
            Text(
              'Last heard ${agoText(p.lastHeard!)}',
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 12),
          if (onJump != null)
            FilledButton.icon(
              icon: const Icon(Icons.login),
              label: Text('Go to CH ${group.channel}'),
              onPressed: onJump,
            )
          else if (group.kind == WhoGroupKind.private)
            Text(
              'Private channels stay hidden. Ask them for the channel and '
              'passcode, or add them as a friend to talk privately.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

/// Talk screen entry point: people icon with the "elsewhere" count.
class WhosWhereButton extends StatelessWidget {
  const WhosWhereButton({super.key, required this.count, this.onPressed});
  final int count;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('whosWhereButton'),
    tooltip: "Who's where",
    visualDensity: VisualDensity.compact,
    icon: Badge(
      isLabelVisible: count > 0,
      label: Text('$count'),
      child: const Icon(Icons.travel_explore),
    ),
    onPressed: onPressed,
  );
}
