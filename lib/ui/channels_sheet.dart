import 'package:flutter/material.dart';

import '../app/passcodes.dart';
import '../app/walkie_controller.dart';
import 'invite_sheet.dart';
import 'mesh_channels.dart';
import 'sheets.dart';

/// One channel row in [ChannelsView].
class ChannelRow {
  const ChannelRow(
    this.channel, {
    this.title = '',
    this.emoji = '',
    this.meshName,
  });
  final int channel;

  /// Shared with this Meshtastic channel (v1.9.7), null if not.
  final String? meshName;

  /// Channel name, '' for none.
  final String title;
  final String emoji;

  String get label => [
    if (emoji.isNotEmpty) emoji,
    title.isNotEmpty ? '$title (CH $channel)' : 'CH $channel',
  ].join(' ');
}

/// The channel picker (v1.9.4): a "Private channels" section with a lock,
/// with "New private channel" and "Join with a code or QR" right there,
/// and the open channels CH 1-16 below it. Pure view, for tests.
class ChannelsView extends StatelessWidget {
  const ChannelsView({
    super.key,
    required this.current,
    required this.privateRows,
    required this.openRows,
    required this.onPick,
    required this.onNewPrivate,
    required this.onJoinPrivate,
    this.onMeshImport,
  });
  final int current;
  final List<ChannelRow> privateRows;
  final List<ChannelRow> openRows;
  final ValueChanged<int> onPick;
  final VoidCallback onNewPrivate;
  final VoidCallback onJoinPrivate;

  /// "Share with Meshtastic" (import a Meshtastic channel QR), v1.9.7.
  final VoidCallback? onMeshImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(ChannelRow r, {required bool private}) => ListTile(
      key: Key('channel-row-${r.channel}'),
      dense: true,
      leading: Icon(
        private ? Icons.lock : Icons.forum_outlined,
        color: private ? theme.colorScheme.primary : null,
      ),
      title: Text(r.label),
      subtitle: r.meshName == null
          ? null
          : Row(
              key: Key('mesh-badge-${r.channel}'),
              children: [
                Icon(
                  Icons.hub_outlined,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Shared with Meshtastic · ${r.meshName}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
      trailing: r.channel == current
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
      selected: r.channel == current,
      onTap: () => onPick(r.channel),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              Icon(Icons.lock, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'Private channels',
                key: const Key('private-channels-title'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Text(
            privateRows.isEmpty
                ? 'None yet. Only phones with the passcode can hear or see '
                      'anything on a private channel.'
                : 'Encrypted: only phones with the passcode hear or see '
                      'anything.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final r in privateRows) row(r, private: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                key: const Key('new-private-channel'),
                icon: const Icon(Icons.add),
                label: const Text('New private channel'),
                onPressed: onNewPrivate,
              ),
              OutlinedButton.icon(
                key: const Key('join-private-channel'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Join with a code or QR'),
                onPressed: onJoinPrivate,
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Row(
            children: [
              const Icon(Icons.forum_outlined),
              const SizedBox(width: 8),
              Text(
                'Open channels',
                key: const Key('open-channels-title'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Text(
            'Anyone on the same channel number can hear you.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final r in openRows) row(r, private: false),
        if (onMeshImport != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('mesh-import-picker'),
                icon: const Icon(Icons.hub_outlined),
                label: const Text('Share with Meshtastic'),
                onPressed: onMeshImport,
              ),
            ),
          ),
      ],
    );
  }
}

ChannelRow _rowFor(WalkieController c, int ch) {
  final n = c.nameForChannel(ch);
  return ChannelRow(
    ch,
    title: n?.name ?? '',
    emoji: n?.emoji ?? '',
    meshName: c.meshLinkOf(ch)?.ref.name,
  );
}

/// Open the channel picker.
Future<void> showChannelsSheet(BuildContext context, WalkieController c) async {
  final private = [for (final ch in c.privateChannelNumbers) _rowFor(c, ch)];
  final open = [
    for (var ch = 1; ch <= 16; ch++)
      if (!c.settings.isPrivate(ch)) _rowFor(c, ch),
  ];
  final pick = await showAppSheet<Object>(
    context: context,
    scrollable: false,
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: ChannelsView(
        current: c.channel,
        privateRows: private,
        openRows: open,
        onPick: (ch) => Navigator.pop(ctx, ch),
        onNewPrivate: () => Navigator.pop(ctx, 'new'),
        onJoinPrivate: () => Navigator.pop(ctx, 'join'),
        onMeshImport: c.radioPaired ? () => Navigator.pop(ctx, 'mesh') : null,
      ),
    ),
  );
  if (!context.mounted) return;
  if (pick is int) {
    if (pick != c.channel) await c.setChannel(pick);
  } else if (pick == 'new') {
    await showNewPrivateChannelSheet(context, c);
  } else if (pick == 'join') {
    await showJoinPrivateSheet(context, c);
  } else if (pick == 'mesh') {
    await startMeshImport(context, c);
  }
}

/// New private channel (v1.9.4): a strong passcode is made for you (or
/// type your own, 10+ characters), you become its admin, then share it
/// with the invite QR.
Future<void> showNewPrivateChannelSheet(
  BuildContext context,
  WalkieController c,
) async {
  final free = c.freeChannelForPrivate();
  if (free == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All 16 channels are private already.')),
    );
    return;
  }
  var ch = free;
  final passCtl = TextEditingController(text: Passcodes.generate());
  final nameCtl = TextEditingController();
  String? err;
  var busy = false;
  final made = await showAppSheet<bool>(
    context: context,
    scrollable: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final theme = Theme.of(ctx);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock),
                    const SizedBox(width: 8),
                    Text(
                      'New private channel',
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Everything on it is encrypted. A strong passcode is '
                  'already filled in; after you create it, show the QR '
                  'code so others join with one scan.',
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('new-private-name'),
                  controller: nameCtl,
                  maxLength: 30,
                  decoration: const InputDecoration(
                    labelText: 'Name (optional, e.g. Family)',
                    counterText: '',
                  ),
                ),
                Row(
                  children: [
                    const Text('Channel number'),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      key: const Key('new-private-number'),
                      value: ch,
                      items: [
                        for (var i = 1; i <= 16; i++)
                          if (!c.settings.isPrivate(i))
                            DropdownMenuItem(value: i, child: Text('CH $i')),
                      ],
                      onChanged: (v) => setSheet(() => ch = v ?? ch),
                    ),
                  ],
                ),
                TextField(
                  key: const Key('new-private-passcode'),
                  controller: passCtl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        'Passcode (at least ${Passcodes.minNew} '
                        'characters)',
                    errorText: err,
                    suffixIcon: IconButton(
                      key: const Key('new-private-generate'),
                      tooltip: 'Make one for me',
                      icon: const Icon(Icons.casino_outlined),
                      onPressed: () => setSheet(() {
                        passCtl.text = Passcodes.generate();
                        err = null;
                      }),
                    ),
                  ),
                  onChanged: (_) {
                    if (err != null) setSheet(() => err = null);
                  },
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('new-private-create'),
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.lock),
                  label: const Text('Create and share'),
                  onPressed: busy
                      ? null
                      : () async {
                          final problem = Passcodes.problemForNew(passCtl.text);
                          if (problem != null) {
                            setSheet(() => err = problem);
                            return;
                          }
                          setSheet(() => busy = true);
                          final e = await c.createPrivateChannel(
                            ch: ch,
                            passcode: passCtl.text,
                            name: nameCtl.text,
                          );
                          if (!ctx.mounted) return;
                          if (e != null) {
                            setSheet(() {
                              busy = false;
                              err = e;
                            });
                            return;
                          }
                          Navigator.pop(ctx, true);
                        },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  if (made == true && context.mounted) await showInviteSheet(context, c);
}

/// Join someone's private channel: scan / paste their invite, or type the
/// channel number and passcode they give you (any saved passcode of 6+
/// characters works, also from older phones).
Future<void> showJoinPrivateSheet(
  BuildContext context,
  WalkieController c,
) async {
  var ch = c.channel;
  final passCtl = TextEditingController();
  String? err;
  final pick = await showAppSheet<String>(
    context: context,
    scrollable: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final theme = Theme.of(ctx);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Join a private channel',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('join-private-scan'),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan or paste an invite'),
                  onPressed: () => Navigator.pop(ctx, 'scan'),
                ),
                const Divider(height: 32),
                const Text('Or type what they tell you:'),
                Row(
                  children: [
                    const Text('Channel number'),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      key: const Key('join-private-number'),
                      value: ch,
                      items: [
                        for (var i = 1; i <= 16; i++)
                          DropdownMenuItem(value: i, child: Text('CH $i')),
                      ],
                      onChanged: (v) => setSheet(() => ch = v ?? ch),
                    ),
                  ],
                ),
                TextField(
                  key: const Key('join-private-passcode'),
                  controller: passCtl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Passcode',
                    errorText: err,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('join-private-go'),
                  icon: const Icon(Icons.login),
                  label: const Text('Join'),
                  onPressed: () {
                    final p = Passcodes.problemForJoin(passCtl.text);
                    if (p != null) {
                      setSheet(() => err = p);
                      return;
                    }
                    Navigator.pop(ctx, 'type');
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
  if (!context.mounted) return;
  if (pick == 'scan') {
    await scanInvite(context, c);
  } else if (pick == 'type') {
    await c.setChannelPrivacy(ch, passCtl.text);
    if (ch != c.channel) await c.setChannel(ch);
  }
}

/// "Unknown listener" warning (v1.9.4) under the people header.
class UnknownListenerCard extends StatelessWidget {
  const UnknownListenerCard({
    super.key,
    required this.count,
    required this.isPrivate,
    this.onTap,
  });
  final int count;
  final bool isPrivate;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!isPrivate) {
      // Open channels: just a quiet count.
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: InkWell(
          key: const Key('hidden-listeners-open'),
          onTap: onTap,
          child: Row(
            children: [
              Icon(Icons.hearing, size: 16, color: theme.colorScheme.outline),
              const SizedBox(width: 6),
              Text(
                '$count more connected without showing up',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      key: const Key('unknown-listener'),
      color: theme.colorScheme.errorContainer,
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.hearing, color: theme.colorScheme.onErrorContainer),
        title: Text(
          'Unknown listener ($count)',
          style: TextStyle(
            color: theme.colorScheme.onErrorContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          'Connected to this private channel without showing up. Tap '
          'for what to do.',
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
        ),
        onTap: onTap,
      ),
    );
  }
}

/// What an unknown listener means and what to do.
Future<void> explainUnknownListener(
  BuildContext context, {
  required bool isPrivate,
  required int count,
  required bool isAdmin,
}) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    scrollable: true,
    title: Text(isPrivate ? 'Unknown listener ($count)' : 'Hidden connections'),
    content: Text(
      isPrivate
          ? 'The internet relay has $count more '
                '${count == 1 ? 'connection' : 'connections'} in this '
                "private channel's room than the people you can see. Without "
                'the passcode it only gets scrambled data, and the updated '
                'relay stops sending anything to a connection that stays '
                "silent. If you think someone has the passcode who "
                "shouldn't, ${isAdmin ? 'remove them (long-press their name), or make a new private channel and share the new QR.' : 'ask the admin to remove them, or make a new private channel together.'}"
                '\n\nIt can also be a phone that just lost signal; '
                'that clears in about a minute.'
          : 'This open channel has $count more '
                '${count == 1 ? 'connection' : 'connections'} on the '
                'internet relay than the people you can see. Open channels '
                'are not encrypted, so anyone can listen. Use a private '
                'channel for anything you want to keep private.',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
    ],
  ),
);
