import 'package:flutter/material.dart';

import 'chat_page.dart' show OnlineAvatar;
import 'reach.dart';

/// One friend in the "Direct chats" section.
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

/// The Chat tab (v2.3.2): two sections so it is clear who each thing
/// reaches. "Here (CH 1)": this channel's / group's chat, its voice messages
/// and its History. "Direct chats": one row per friend, only you two.
class ChatHubView extends StatelessWidget {
  const ChatHubView({
    super.key,
    required this.place,
    required this.chatPreview,
    required this.chatUnread,
    required this.onOpenChat,
    required this.voiceNew,
    required this.voiceWaiting,
    required this.onOpenVoice,
    required this.historyUnheard,
    required this.onOpenHistory,
    this.direct = const [],
    this.onOpenDirect,
    this.onAddFriends,
    this.directVoiceNew = 0,
    this.onOpenDirectVoice,
  });

  /// The current channel or group.
  final Reach place;
  final String? chatPreview;
  final int chatUnread;
  final VoidCallback onOpenChat;

  /// Voice messages for this place: not played yet / still waiting.
  final int voiceNew;
  final int voiceWaiting;
  final VoidCallback onOpenVoice;

  /// Talk here that was not heard.
  final int historyUnheard;
  final VoidCallback onOpenHistory;

  final List<DirectChatItem> direct;
  final ValueChanged<DirectChatItem>? onOpenDirect;

  /// Empty state: go add a friend (People tab).
  final VoidCallback? onAddFriends;

  /// Voice messages from friends (not played yet), 0 = hide the row.
  final int directVoiceNew;
  final VoidCallback? onOpenDirectVoice;

  Widget _tile(
    BuildContext context, {
    required Key key,
    required Widget leading,
    required String title,
    required Reach reach,
    String? extra,
    required String subtitle,
    required int badge,
    required VoidCallback onTap,
  }) => ListTile(
    key: key,
    leading: leading,
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (extra != null)
          Text(
            extra,
            key: const Key('reach-line'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 2),
        ReachTag(reach),
      ],
    ),
    isThreeLine: true,
    trailing: badge > 0
        ? Badge(label: Text('$badge'))
        : const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  CircleAvatar _icon(IconData i) => CircleAvatar(child: Icon(i));

  @override
  Widget build(BuildContext context) {
    final here = place.label;
    return ListView(
      children: [
        PlaceHeader(place),
        SectionTitle(
          'Here ($here)',
          key: const Key('chat-section-here'),
          reach: place,
        ),
        _tile(
          context,
          key: const Key('chat-hub-chat'),
          leading: _icon(Icons.chat_bubble_outline),
          title: 'Chat · $here',
          reach: place,
          extra: place.reads,
          subtitle: chatPreview ?? 'No messages yet. Write to everyone here.',
          badge: chatUnread,
          onTap: onOpenChat,
        ),
        _tile(
          context,
          key: const Key('chat-hub-voice'),
          leading: _icon(Icons.voicemail),
          title: 'Voice messages · $here',
          reach: place,
          extra: 'Only voice messages on ${place.label}. ${place.hears}',
          subtitle: [
            voiceNew == 0 ? 'Nothing new' : '$voiceNew new',
            if (voiceWaiting > 0) '$voiceWaiting waiting to be delivered',
          ].join(' · '),
          badge: voiceNew,
          onTap: onOpenVoice,
        ),
        _tile(
          context,
          key: const Key('chat-hub-history'),
          leading: _icon(Icons.history),
          title: 'History · $here',
          reach: place,
          extra: 'Only talk on ${place.label}',
          subtitle: historyUnheard == 0
              ? 'Replay what was said here'
              : '$historyUnheard not heard yet. Replay, or Play all missed.',
          badge: historyUnheard,
          onTap: onOpenHistory,
        ),
        const Divider(height: 24),
        SectionTitle(
          'Direct chats',
          key: const Key('chat-section-direct'),
          reach: Reach.direct('friends'),
          subtitle: 'One chat per friend, only you two',
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
            isThreeLine: true,
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  f.last ?? 'No messages yet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: f.unread > 0
                      ? const TextStyle(fontWeight: FontWeight.w700)
                      : null,
                ),
                const SizedBox(height: 2),
                ReachTag(Reach.direct(f.name)),
              ],
            ),
            trailing: f.unread > 0
                ? Badge(label: Text('${f.unread}'))
                : const Icon(Icons.chevron_right),
            onTap: onOpenDirect == null ? null : () => onOpenDirect!(f),
          ),
        if (onOpenDirectVoice != null)
          ListTile(
            key: const Key('chat-hub-direct-voice'),
            leading: _icon(Icons.voicemail),
            title: const Text('Voice messages from friends'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  directVoiceNew == 0 ? 'Nothing new' : '$directVoiceNew new',
                ),
                const SizedBox(height: 2),
                ReachTag(Reach.direct('friends')),
              ],
            ),
            isThreeLine: true,
            trailing: directVoiceNew > 0
                ? Badge(label: Text('$directVoiceNew'))
                : const Icon(Icons.chevron_right),
            onTap: onOpenDirectVoice,
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}
