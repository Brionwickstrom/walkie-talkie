import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/groups.dart';
import '../app/passcodes.dart';
import '../app/walkie_controller.dart';
import 'invite_sheet.dart';
import 'mesh_channels.dart';
import 'sheets.dart';

/// One open channel row in [ChannelsView].
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

/// One private group row in [ChannelsView] (v2.3.0): a group has its own
/// name, emoji and colour and no channel number.
class GroupRow {
  const GroupRow(
    this.id, {
    required this.name,
    this.emoji = '',
    this.color = 0xFF1E88E5,
    this.legacy = false,
    this.invitedBy,
    this.invited = false,
  });
  final String id;
  final String name;
  final String emoji;
  final int color;

  /// Made before 2.3.0: phones on older versions can still join it.
  final bool legacy;

  /// A friend invited us and we did not accept yet.
  final bool invited;
  final String? invitedBy;

  String get label => [if (emoji.isNotEmpty) emoji, name].join(' ');
}

/// The channel picker: a "Private groups" section (each group has its own
/// name and colour, no channel number) with "New private group" and "Join
/// with a code or QR" right there, and the open channels CH 1-16 below it.
/// Pure view, for tests.
class ChannelsView extends StatelessWidget {
  const ChannelsView({
    super.key,
    required this.current,
    this.currentGroup,
    required this.groupRows,
    required this.openRows,
    required this.onPick,
    required this.onPickGroup,
    required this.onNewGroup,
    required this.onJoinGroup,
    this.onAcceptInvite,
    this.onDeclineInvite,
    this.onMeshImport,
  });

  /// The open channel we are on (ignored while [currentGroup] is set).
  final int current;

  /// The private group we are in, or null.
  final String? currentGroup;
  final List<GroupRow> groupRows;
  final List<ChannelRow> openRows;
  final ValueChanged<int> onPick;
  final ValueChanged<String> onPickGroup;
  final VoidCallback onNewGroup;
  final VoidCallback onJoinGroup;
  final ValueChanged<String>? onAcceptInvite;
  final ValueChanged<String>? onDeclineInvite;

  /// "Share with Meshtastic" (import a Meshtastic channel QR), v1.9.7.
  final VoidCallback? onMeshImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(ChannelRow r) {
      final here = currentGroup == null && r.channel == current;
      return ListTile(
        key: Key('channel-row-${r.channel}'),
        dense: true,
        leading: const Icon(Icons.forum_outlined),
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
        trailing: here
            ? Icon(Icons.check, color: theme.colorScheme.primary)
            : null,
        selected: here,
        onTap: () => onPick(r.channel),
      );
    }

    Widget group(GroupRow g) {
      final here = currentGroup == g.id;
      final color = Color(g.color);
      return ListTile(
        key: Key('group-row-${g.id}'),
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: color,
          foregroundColor:
              ThemeData.estimateBrightnessForColor(color) == Brightness.dark
              ? Colors.white
              : Colors.black87,
          child: g.emoji.isNotEmpty
              ? Text(g.emoji, style: const TextStyle(fontSize: 16))
              : const Icon(Icons.lock, size: 16),
        ),
        title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: g.invited
            ? Text(
                'Invitation${g.invitedBy == null ? '' : ' from ${g.invitedBy}'}',
                key: Key('group-invited-${g.id}'),
              )
            : g.legacy
            ? const Text('Older phones can join too')
            : null,
        trailing: g.invited
            ? Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    key: Key('group-decline-${g.id}'),
                    onPressed: onDeclineInvite == null
                        ? null
                        : () => onDeclineInvite!(g.id),
                    child: const Text('Decline'),
                  ),
                  FilledButton(
                    key: Key('group-accept-${g.id}'),
                    onPressed: onAcceptInvite == null
                        ? null
                        : () => onAcceptInvite!(g.id),
                    child: const Text('Join'),
                  ),
                ],
              )
            : here
            ? Icon(Icons.check, color: theme.colorScheme.primary)
            : null,
        selected: here,
        onTap: g.invited ? null : () => onPickGroup(g.id),
      );
    }

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
                'Private groups',
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
            groupRows.isEmpty
                ? 'None yet. A private group is its own place, not a '
                      'channel number. Only people you invite, or who have '
                      'its code, can hear or see anything.'
                : 'Encrypted: only people in the group hear or see '
                      'anything.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final g in groupRows) group(g),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                key: const Key('new-private-group'),
                icon: const Icon(Icons.add),
                label: const Text('New private group'),
                onPressed: onNewGroup,
              ),
              OutlinedButton.icon(
                key: const Key('join-private-group'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Join with a code or QR'),
                onPressed: onJoinGroup,
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
            'CH 1 to 16. Anyone on the same channel number can hear you.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final r in openRows) row(r),
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

/// The group rows as the picker shows them: invitations first.
List<GroupRow> groupRowsFor(WalkieController c) {
  final all = c.settings.groups;
  GroupRow row(PrivateGroup g) => GroupRow(
    g.id,
    name: g.name,
    emoji: g.emoji,
    color: g.color,
    legacy: g.isLegacy,
    invited: g.invited,
    invitedBy: g.invitedBy,
  );
  return [
    for (final g in all)
      if (g.invited) row(g),
    for (final g in all)
      if (!g.invited) row(g),
  ];
}

/// Open the channel picker.
Future<void> showChannelsSheet(BuildContext context, WalkieController c) async {
  final pick = await showAppSheet<Object>(
    context: context,
    scrollable: false,
    builder: (ctx) => ListenableBuilder(
      listenable: c,
      builder: (ctx, _) => SingleChildScrollView(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        child: ChannelsView(
          current: c.channel,
          currentGroup: c.currentGroup?.id,
          groupRows: groupRowsFor(c),
          openRows: [for (var ch = 1; ch <= 16; ch++) _rowFor(c, ch)],
          onPick: (ch) => Navigator.pop(ctx, ch),
          onPickGroup: (id) => Navigator.pop(ctx, 'g:$id'),
          onNewGroup: () => Navigator.pop(ctx, 'new'),
          onJoinGroup: () => Navigator.pop(ctx, 'join'),
          onAcceptInvite: (id) => Navigator.pop(ctx, 'a:$id'),
          onDeclineInvite: (id) async {
            await c.leaveGroup(id);
          },
          onMeshImport: c.radioPaired ? () => Navigator.pop(ctx, 'mesh') : null,
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (pick is int) {
    if (c.isPrivate || pick != c.channel) await c.setChannel(pick);
  } else if (pick is String && pick.startsWith('g:')) {
    final id = pick.substring(2);
    if (c.currentGroup?.id != id) await c.setGroup(id);
  } else if (pick is String && pick.startsWith('a:')) {
    await c.acceptGroupInvite(pick.substring(2));
  } else if (pick == 'new') {
    await showNewGroupSheet(context, c);
  } else if (pick == 'join') {
    await showJoinPrivateSheet(context, c);
  } else if (pick == 'mesh') {
    await startMeshImport(context, c);
  }
}

/// Colour dots to pick from (v2.3.0).
class GroupColorPicker extends StatelessWidget {
  const GroupColorPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (var i = 0; i < GroupColors.palette.length; i++)
        Semantics(
          button: true,
          selected: GroupColors.palette[i] == value,
          label: '${GroupColors.names[i]} colour',
          child: InkWell(
            key: Key('group-color-$i'),
            customBorder: const CircleBorder(),
            onTap: () => onChanged(GroupColors.palette[i]),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: Color(GroupColors.palette[i]),
                child: GroupColors.palette[i] == value
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
          ),
        ),
    ],
  );
}

/// New private group (v2.3.0): a name, an emoji and a colour; a strong
/// passcode is made for you (or type your own, 10+ characters). You become
/// its admin, then add friends or show the QR code. A group is not a
/// channel: there is no channel number to pick.
Future<void> showNewGroupSheet(BuildContext context, WalkieController c) async {
  final passCtl = TextEditingController(text: Passcodes.generate());
  final nameCtl = TextEditingController();
  final emojiCtl = TextEditingController();
  var color = GroupColors.next(c.settings.groups.map((g) => g.color));
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
                      'New private group',
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'A private group is its own place, not a channel. '
                  'Everything in it is encrypted. A strong code is already '
                  'filled in; after you create it, add friends or show the '
                  'QR code.',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: TextField(
                        key: const Key('new-private-emoji'),
                        controller: emojiCtl,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(labelText: 'Emoji'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const Key('new-private-name'),
                        controller: nameCtl,
                        maxLength: 30,
                        decoration: const InputDecoration(
                          labelText: 'Name (e.g. Family)',
                          counterText: '',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                GroupColorPicker(
                  value: color,
                  onChanged: (v) => setSheet(() => color = v),
                ),
                TextField(
                  key: const Key('new-private-passcode'),
                  controller: passCtl,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        'Code (at least ${Passcodes.minNew} '
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
                          final e = await c.createGroup(
                            passcode: passCtl.text,
                            name: nameCtl.text,
                            emoji: emojiCtl.text,
                            color: color,
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
  if (made == true && context.mounted) await showAddPeopleSheet(context, c);
}

/// "Add people" (v2.3.0): pick friends and the group goes to each of them
/// as a Direct chat invitation (the secret sealed with the friend pair
/// key). People who are not friends join with the QR / link, offered here
/// too.
Future<void> showAddPeopleSheet(
  BuildContext context,
  WalkieController c,
) async {
  final g = c.currentGroup;
  if (g == null) return;
  final friends = c.groupInviteCandidates;
  final picked = <int>{};
  final go = await showAppSheet<String>(
    context: context,
    scrollable: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final theme = Theme.of(ctx);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: AddPeopleView(
            groupLabel: g.label,
            friends: [
              for (final f in friends)
                (
                  id: f.id,
                  name: c.friendName(f.id),
                  online: c.friendLinks.isOnline(f.id),
                ),
            ],
            picked: picked,
            onToggle: (id, v) => setSheet(() {
              v ? picked.add(id) : picked.remove(id);
            }),
            onSend: () => Navigator.pop(ctx, 'send'),
            onQr: () => Navigator.pop(ctx, 'qr'),
            theme: theme,
          ),
        );
      },
    ),
  );
  if (!context.mounted) return;
  if (go == 'send' && picked.isNotEmpty) {
    await c.inviteFriendsToGroup(picked);
  } else if (go == 'qr') {
    await showInviteSheet(context, c);
  }
}

/// Content of the "Add people" sheet (pure, for tests).
class AddPeopleView extends StatelessWidget {
  const AddPeopleView({
    super.key,
    required this.groupLabel,
    required this.friends,
    required this.picked,
    required this.onToggle,
    required this.onSend,
    required this.onQr,
    required this.theme,
  });
  final String groupLabel;
  final List<({int id, String name, bool online})> friends;
  final Set<int> picked;
  final void Function(int id, bool on) onToggle;
  final VoidCallback onSend;
  final VoidCallback onQr;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Add people to $groupLabel', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          friends.isEmpty
              ? 'You have no friends added yet. Add friends first, or share '
                    'the QR code or link instead.'
              : 'Pick friends. Each gets an invitation in their Direct chat '
                    'with you (kept up to 24 hours if they are out of '
                    'reach). The group code is sealed so only that friend '
                    'can open it. They need Walkie Talkie 2.3.0 or newer.',
          key: const Key('add-people-note'),
          style: theme.textTheme.bodySmall,
        ),
        for (final f in friends)
          CheckboxListTile(
            key: Key('add-people-${f.id}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: picked.contains(f.id),
            onChanged: (v) => onToggle(f.id, v ?? false),
            title: Text(f.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(f.online ? 'In reach' : 'Out of reach for now'),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.icon(
              key: const Key('add-people-send'),
              icon: const Icon(Icons.send),
              label: Text(
                picked.isEmpty ? 'Send invitations' : 'Send (${picked.length})',
              ),
              onPressed: picked.isEmpty ? null : onSend,
            ),
            OutlinedButton.icon(
              key: const Key('add-people-qr'),
              icon: const Icon(Icons.qr_code),
              label: const Text('QR or link instead'),
              onPressed: onQr,
            ),
          ],
        ),
      ],
    );
  }
}

/// Join someone's private group: scan / paste their invite. A group made
/// on an older version can also be joined by typing its channel number and
/// passcode (that is all those phones know).
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
                Text('Join a private group', style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const Key('join-private-scan'),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan or paste an invite'),
                  onPressed: () => Navigator.pop(ctx, 'scan'),
                ),
                const Divider(height: 32),
                const Text(
                  'Group made on an older version? Type the channel number '
                  'and passcode they gave you:',
                ),
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
    await c.joinGroupWithCode(channel: ch, passcode: passCtl.text);
  }
}

/// Copy [text] for the group's code.
void copyToClipboard(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('Copied')));
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
          'Connected to this private group without showing up. Tap '
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
                "private group's room than the people you can see. Without "
                'the code it only gets scrambled data, and the updated '
                'relay stops sending anything to a connection that stays '
                "silent. If you think someone has the code who "
                "shouldn't, ${isAdmin ? 'remove them (long-press their name), or make a new private group and share the new QR.' : 'ask the admin to remove them, or make a new private group together.'}"
                '\n\nIt can also be a phone that just lost signal; '
                'that clears in about a minute.'
          : 'This open channel has $count more '
                '${count == 1 ? 'connection' : 'connections'} on the '
                'internet relay than the people you can see. Open channels '
                'are not encrypted, so anyone can listen. Use a private '
                'group for anything you want to keep private.',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
    ],
  ),
);
