import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/invite.dart';
import '../app/walkie_controller.dart';
import 'friends_page.dart';
import 'sheets.dart';

/// Invite (v1.8.7): QR code + share link for this channel and / or a
/// friend add. A private channel's QR / link contains its passcode, so it
/// is only shown after a warning. The radio's channel key never is.
Future<void> showInviteSheet(BuildContext context, WalkieController c) async {
  var withChannel = true;
  var withFriend = false;
  var revealed = false;
  Invite? cached;
  String? cacheKey;
  Invite inviteFor() {
    final k = '$withChannel/$withFriend/${c.channel}';
    if (cached == null || cacheKey != k) {
      cached = c.makeInvite(channel: withChannel, friend: withFriend);
      cacheKey = k;
    }
    return cached!;
  }

  await showAppSheet<void>(
    context: context,
    scrollable: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final private = c.isPrivate && withChannel;
        final nothing = !withChannel && !withFriend;
        final hide = private && !revealed;
        final inv = nothing || hide ? null : inviteFor();
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: InviteView(
            channelLabel: c.channelLabel,
            withChannel: withChannel,
            withFriend: withFriend,
            isPrivate: c.isPrivate,
            revealed: revealed,
            invite: inv,
            onChannel: (v) => setSheet(() => withChannel = v),
            onFriend: (v) => setSheet(() => withFriend = v),
            onReveal: () => setSheet(() => revealed = true),
            onShare: inv == null
                ? null
                : () => c.bridge.shareText(
                    inv.shareText(),
                    'Walkie Talkie invite',
                  ),
            onCopy: inv == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: inv.shareText()));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite link copied')),
                    );
                  },
            onScan: () async {
              Navigator.pop(ctx);
              await scanInvite(context, c);
            },
          ),
        );
      },
    ),
  );
}

/// The invite sheet's content (pure, for tests).
class InviteView extends StatelessWidget {
  const InviteView({
    super.key,
    required this.channelLabel,
    required this.withChannel,
    required this.withFriend,
    required this.isPrivate,
    required this.revealed,
    required this.invite,
    required this.onChannel,
    required this.onFriend,
    required this.onReveal,
    required this.onShare,
    required this.onCopy,
    required this.onScan,
  });
  final String channelLabel;
  final bool withChannel;
  final bool withFriend;
  final bool isPrivate;
  final bool revealed;

  /// Null: nothing picked, or a private channel not revealed yet.
  final Invite? invite;
  final ValueChanged<bool> onChannel;
  final ValueChanged<bool> onFriend;
  final VoidCallback onReveal;
  final VoidCallback? onShare;
  final VoidCallback? onCopy;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inv = invite;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Invite someone',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        CheckboxListTile(
          key: const Key('invite-channel'),
          contentPadding: EdgeInsets.zero,
          value: withChannel,
          onChanged: (v) => onChannel(v ?? false),
          title: Text('Join $channelLabel'),
          subtitle: Text(
            isPrivate
                ? 'Includes the passcode of this private group.'
                : 'Open channel: anyone on it can hear you.',
          ),
        ),
        CheckboxListTile(
          key: const Key('invite-friend'),
          contentPadding: EdgeInsets.zero,
          value: withFriend,
          onChanged: (v) => onFriend(v ?? false),
          title: const Text('Add me as a friend'),
          subtitle: const Text(
            'Direct chat: end-to-end encrypted talk and text from anywhere. '
            'Works for 1 hour.',
          ),
        ),
        const SizedBox(height: 8),
        if (isPrivate && withChannel && !revealed)
          Card(
            key: const Key('invite-private-warning'),
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'This QR code and link contain the passcode of your '
                    'private group. Anyone who sees or gets them can join '
                    'and listen. Only share with people you trust, and not '
                    'in public posts.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('invite-reveal'),
                    onPressed: onReveal,
                    child: const Text('I understand, show it'),
                  ),
                ],
              ),
            ),
          )
        else if (inv != null) ...[
          Center(
            child: Container(
              key: const Key('invite-qr'),
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(data: inv.webLink, size: 220),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scan it in Walkie Talkie (Settings > Join with a code, or '
            'Friends > Scan). A phone camera opens the download page.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          if (inv.isPrivate)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Contains the passcode.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('invite-share'),
                icon: const Icon(Icons.share),
                label: const Text('Share link'),
                onPressed: onShare,
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const Key('invite-copy'),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
                onPressed: onCopy,
              ),
            ],
          ),
        ] else
          const Text('Pick what to share.', textAlign: TextAlign.center),
        const Divider(height: 24),
        TextButton.icon(
          key: const Key('invite-scan'),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan someone else\'s code'),
          onPressed: onScan,
        ),
      ],
    );
  }
}

/// Scan (or paste) an invite / friend code and confirm it.
Future<void> scanInvite(BuildContext context, WalkieController c) async {
  final text = await scanCode(context, title: 'Scan an invite');
  if (text == null || !context.mounted) return;
  final inv = Invite.parse(text);
  if (inv != null) {
    await confirmInvite(context, c, inv);
    return;
  }
  final err = await c.addFriendFromQr(text);
  if (err != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }
}

/// Ask before an invite changes anything; then apply it.
Future<void> confirmInvite(
  BuildContext context,
  WalkieController c,
  Invite inv,
) async {
  final choice = await showDialog<({bool join, bool friend})>(
    context: context,
    builder: (ctx) =>
        InviteConfirmDialog(invite: inv, currentChannel: c.channelLabel),
  );
  if (choice == null || (!choice.join && !choice.friend)) return;
  final msg = await c.applyInvite(
    inv,
    joinChannel: choice.join,
    addFriend: choice.friend,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Invite: $msg')));
  }
}

/// Confirm dialog for an opened / scanned invite. Pops a record with what
/// to do, or null.
class InviteConfirmDialog extends StatefulWidget {
  const InviteConfirmDialog({
    super.key,
    required this.invite,
    required this.currentChannel,
  });
  final Invite invite;
  final String currentChannel;

  @override
  State<InviteConfirmDialog> createState() => _InviteConfirmDialogState();
}

class _InviteConfirmDialogState extends State<InviteConfirmDialog> {
  late bool _join = widget.invite.hasChannel;
  late bool _friend = widget.invite.hasFriend;

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    final from = (inv.name ?? '').isEmpty ? 'Someone' : inv.name!;
    return AlertDialog(
      scrollable: true,
      title: Text('Invite from $from'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (inv.hasChannel)
            CheckboxListTile(
              key: const Key('invite-join'),
              contentPadding: EdgeInsets.zero,
              value: _join,
              onChanged: (v) => setState(() => _join = v ?? false),
              title: Text(
                'Join CH ${inv.channel}${inv.isPrivate ? ' (private group)' : ''}',
              ),
              subtitle: Text(
                'You leave ${widget.currentChannel}.'
                '${inv.isPrivate ? ' The passcode is saved for that channel.' : ''}',
              ),
            ),
          if (inv.hasFriend)
            CheckboxListTile(
              key: const Key('invite-add-friend'),
              contentPadding: EdgeInsets.zero,
              value: _friend,
              onChanged: (v) => setState(() => _friend = v ?? false),
              title: Text('Add $from as a friend'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('invite-accept'),
          onPressed: _join || _friend
              ? () => Navigator.pop(context, (join: _join, friend: _friend))
              : null,
          child: const Text('OK'),
        ),
      ],
    );
  }
}
