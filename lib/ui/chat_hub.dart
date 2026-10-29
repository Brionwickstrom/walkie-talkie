import 'package:flutter/material.dart';

import 'chat_page.dart' show OnlineAvatar;
import 'reach.dart';

/// One friend in the "Friends" section.
class DirectChatItem {
  const DirectChatItem({
    required this.id,
    required this.name,
    required this.online,
    this.last,
    this.unread = 0,
  });
  final int id;
  final String name;
  final bool online;

  /// Preview of the last message, null = nothing written yet.
  final String? last;
  final int unread;
}

/// The Chat tab (v2.4.0): text only. The banner says where you are (once),
/// the first row is this channel's / group's chat ("CH 1 chat"), then one
/// row per friend ("Friends"). Voice messages and missed live talk are in
/// Messages (the icon on the Talk screen), not here.
class ChatHubView extends StatelessWidget {
  const ChatHubView({
    super.key,
    required this.place,
    required this.chatPreview,
    required this.chatUnread,
    required this.onOpenChat,
    this.direct = const [],
    this.onOpenDirect,
    this.onAddFriends,
  });

  /// The current channel or group.
  final Reach place;
  final String? chatPreview;
  final int chatUnread;
  final VoidCallback onOpenChat;

  final List<DirectChatItem> direct;
  final ValueChanged<DirectChatItem>? onOpenDirect;

  /// Empty state: go add a friend (People tab).
  final VoidCallback? onAddFriends;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        PlaceHeader(place),
        ListTile(
          key: const Key('chat-hub-chat'),
          leading: const CircleAvatar(child: Icon(Icons.chat_bubble_outline)),
          title: Text(
            '${place.label} chat',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            chatPreview ?? 'No messages yet',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: chatUnread > 0
                ? const TextStyle(fontWeight: FontWeight.w700)
                : null,
          ),
          trailing: chatUnread > 0
              ? Badge(label: Text('$chatUnread'))
              : const Icon(Icons.chevron_right),
          onTap: onOpenChat,
        ),
        const Divider(height: 24),
        Padding(
          key: const Key('chat-section-friends'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Friends',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (direct.isEmpty)
          Padding(
            key: const Key('direct-empty'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'No friends yet. Add a friend and you get a direct chat '
                  'that only the two of you can read, on any channel.',
                ),
                if (onAddFriends != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.tonalIcon(
                      key: const Key('direct-add-friends'),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Add a friend'),
                      onPressed: onAddFriends,
                    ),
                  ),
              ],
            ),
          ),
        for (final f in direct)
          ListTile(
            key: Key('direct-chat-${f.id}'),
            leading: OnlineAvatar(id: f.id, name: f.name, online: f.online),
            title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              f.last ?? 'No messages yet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: f.unread > 0
                  ? const TextStyle(fontWeight: FontWeight.w700)
                  : null,
            ),
            trailing: f.unread > 0
                ? Badge(label: Text('${f.unread}'))
                : const Icon(Icons.chevron_right),
            onTap: onOpenDirect == null ? null : () => onOpenDirect!(f),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}
