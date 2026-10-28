import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/invite.dart';
import '../app/walkie_controller.dart';
import '../chat/chat_body.dart';
import '../chat/chat_store.dart';
import 'chat_page.dart';
import 'invite_sheet.dart';
import '../platform/platform_caps.dart';

/// One row of the friends list.
class FriendItem {
  const FriendItem({
    required this.id,
    required this.name,
    required this.online,
    this.via,
    this.unread = 0,
    this.last,
    this.talking = false,
  });
  final int id;
  final String name;
  final bool online;
  final String? via;
  final int unread;
  final String? last;
  final bool talking;
}

/// Friends list without the controller (also used by layout tests).
class FriendsView extends StatelessWidget {
  const FriendsView({
    super.key,
    required this.friends,
    this.requests = const [],
    required this.onOpen,
    required this.onShowCode,
    required this.onScan,
    this.onLongPress,
  });
  final List<FriendItem> friends;

  /// (name, accept, decline)
  final List<(String, VoidCallback, VoidCallback)> requests;
  final ValueChanged<FriendItem> onOpen;
  final VoidCallback onShowCode;
  final VoidCallback onScan;
  final ValueChanged<FriendItem>? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = friends.where((f) => f.online).length;
    return ListView(
      children: [
        for (final r in requests)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            color: theme.colorScheme.tertiaryContainer,
            child: ListTile(
              leading: const Icon(Icons.person_add),
              title: Text('${r.$1} wants to be friends'),
              subtitle: Wrap(
                spacing: 8,
                children: [
                  FilledButton(onPressed: r.$2, child: const Text('Accept')),
                  OutlinedButton(onPressed: r.$3, child: const Text('Decline')),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Show my code'),
                  onPressed: onShowCode,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan a code'),
                  onPressed: onScan,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            friends.isEmpty
                ? 'No friends yet'
                : '$online of ${friends.length} online',
            style: theme.textTheme.labelLarge,
          ),
        ),
        if (friends.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Friends get a Direct chat: talk and text each other from '
              'anywhere, on any channel, end-to-end encrypted.\n\n'
              'Add one: both open Friends, one taps "Show my code", the '
              'other "Scan a code". Or long-press someone on the main '
              'screen and tap "Add friend".',
            ),
          ),
        for (final f in friends)
          ListTile(
            leading: OnlineAvatar(
              id: f.id,
              name: f.name,
              online: f.online,
              talking: f.talking,
            ),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              f.talking
                  ? 'Talking to you...'
                  : f.last ??
                        (f.online
                            ? 'Online${f.via != null ? ' via ${f.via}' : ''}'
                            : 'Offline'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: f.unread > 0
                ? Badge(label: Text('${f.unread}'))
                : const Icon(Icons.chevron_right),
            onTap: () => onOpen(f),
            onLongPress: onLongPress == null ? null : () => onLongPress!(f),
          ),
      ],
    );
  }
}

String chatPreview(ChatMessage m) {
  final who = m.mine ? 'You: ' : '';
  return who +
      switch (m.type) {
        ChatType.text => m.text,
        ChatType.photo => 'Photo',
        ChatType.location => m.liveUntil != null ? 'Live location' : 'Location',
        ChatType.groupInvite => 'Private group invitation',
      };
}

class FriendsPage extends StatelessWidget {
  const FriendsPage({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Friends')),
        body: FriendsView(
          friends: [
            for (final f in c.friends)
              FriendItem(
                id: f.id,
                name: f.name,
                online: c.friendOnline(f.id),
                via: c.friendVia(f.id),
                unread: c.unreadFriendChat(f.id),
                talking: c.friendsTalking.contains(f.id),
                last: switch (c.chats?.lastOf(friendConversation(f.id))) {
                  final m? => chatPreview(m),
                  null => null,
                },
              ),
          ],
          requests: [
            for (final r in List.of(c.friendRequests))
              (
                r.name,
                () => answerFriendRequest(context, c, r, true),
                () => answerFriendRequest(context, c, r, false),
              ),
          ],
          onOpen: (f) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  ChatPage(controller: c, conv: friendConversation(f.id)),
            ),
          ),
          onShowCode: () => showFriendCode(context, c),
          onScan: () => scanFriendCode(context, c),
          onLongPress: (f) => _remove(context, c, f),
        ),
      ),
    );
  }

  Future<void> _remove(
    BuildContext context,
    WalkieController c,
    FriendItem f,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text('Remove ${f.name}?'),
        content: const Text(
          'You stop seeing each other in Friends. Add them again any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await c.removeFriend(f.id);
  }
}

Future<void> answerFriendRequest(
  BuildContext context,
  WalkieController c,
  FriendRequest r,
  bool accept,
) async {
  final code = await c.answerFriendRequest(r, accept);
  if (code == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text('${r.name} is now your friend'),
      content: Text(
        'Safety code: $code\n\nIt should show the same on both phones. '
        'If not, someone may be listening in: remove the friend and add '
        'them again with the QR code.',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> showFriendCode(BuildContext context, WalkieController c) async {
  final text = c.friendQrText();
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('My friend code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: 220,
              height: 220,
              child: QrImageView(data: text, size: 220),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Let your friend scan this in Friends > Scan a code. Valid for '
            '10 minutes. Both phones need to be online (any network).',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            Navigator.pop(ctx);
          },
          child: const Text('Copy as text'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

Future<void> scanFriendCode(BuildContext context, WalkieController c) async {
  final text = await scanCode(context, title: 'Scan friend code');
  if (text == null || !context.mounted) return;
  // An invite link / QR (v1.8.7) works here too.
  final inv = Invite.parse(text);
  if (inv != null && !text.trim().startsWith('walkie-friend:')) {
    await confirmInvite(context, c, inv);
    return;
  }
  final err = await c.addFriendFromQr(text);
  if (err != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }
}

/// Camera scan of a friend code or an invite (paste when the camera is not
/// allowed). Null when cancelled.
Future<String?> scanCode(
  BuildContext context, {
  String title = 'Scan a code',
  bool Function(String text)? accept,
  String? pasteHint,
}) async {
  // Desktop (v1.9.6): no camera scanning, paste the code or link instead.
  if (!PlatformCaps.camera) return _pasteCode(context, hint: pasteHint);
  final granted = (await Permission.camera.request()).isGranted;
  if (!context.mounted) return null;
  if (granted) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            QrScanPage(title: title, accept: accept, pasteHint: pasteHint),
      ),
    );
  }
  return _pasteCode(context, hint: pasteHint);
}

/// A scanned / pasted text this app understands.
bool isWalkieCode(String v) =>
    v.startsWith('walkie-friend:') || Invite.parse(v) != null;

Future<String?> _pasteCode(BuildContext context, {String? hint}) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Paste a code or link'),
      content: TextField(
        key: const Key('paste-code-field'),
        controller: ctl,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: hint ?? 'walkie-friend:1:... or walkietalkie://join?...',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class QrScanPage extends StatefulWidget {
  const QrScanPage({
    super.key,
    this.title = 'Scan a code',
    this.accept,
    this.pasteHint,
  });
  final String title;

  /// Which scanned texts to take (default: Walkie codes / invites).
  final bool Function(String text)? accept;
  final String? pasteHint;

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: () async {
              final t = await _pasteCode(context, hint: widget.pasteHint);
              if (t != null && context.mounted && !_done) {
                _done = true;
                Navigator.pop(context, t);
              }
            },
            child: const Text('Paste'),
          ),
        ],
      ),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && (widget.accept ?? isWalkieCode)(v)) {
              _done = true;
              Navigator.pop(context, v);
              return;
            }
          }
        },
      ),
    );
  }
}
