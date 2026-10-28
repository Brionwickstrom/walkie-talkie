import 'package:flutter/material.dart';

/// The Chat tab (v2.3.1): this channel's / group's chat, Voice messages
/// (voicemail) and History in one place. Each opens its full page.
class ChatHubView extends StatelessWidget {
  const ChatHubView({
    super.key,
    required this.chatTitle,
    required this.chatPreview,
    required this.chatUnread,
    required this.onOpenChat,
    required this.voiceNew,
    required this.voiceWaiting,
    required this.onOpenVoice,
    required this.historyUnheard,
    required this.onOpenHistory,
  });

  final String chatTitle;
  final String? chatPreview;
  final int chatUnread;
  final VoidCallback onOpenChat;

  /// Voice messages not played yet / still waiting to be delivered.
  final int voiceNew;
  final int voiceWaiting;
  final VoidCallback onOpenVoice;

  /// Talk on this channel that was not heard.
  final int historyUnheard;
  final VoidCallback onOpenHistory;

  Widget _tile({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required int badge,
    required VoidCallback onTap,
  }) => ListTile(
    key: key,
    leading: CircleAvatar(child: Icon(icon)),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: badge > 0
        ? Badge(label: Text('$badge'))
        : const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      _tile(
        key: const Key('chat-hub-chat'),
        icon: Icons.chat_bubble_outline,
        title: chatTitle,
        subtitle: chatPreview ?? 'No messages yet. Write to everyone here.',
        badge: chatUnread,
        onTap: onOpenChat,
      ),
      _tile(
        key: const Key('chat-hub-voice'),
        icon: Icons.voicemail,
        title: 'Voice messages',
        subtitle: [
          voiceNew == 0 ? 'Nothing new' : '$voiceNew new',
          if (voiceWaiting > 0) '$voiceWaiting waiting to be delivered',
        ].join(' · '),
        badge: voiceNew,
        onTap: onOpenVoice,
      ),
      _tile(
        key: const Key('chat-hub-history'),
        icon: Icons.history,
        title: 'History',
        subtitle: historyUnheard == 0
            ? 'Replay what was said'
            : '$historyUnheard not heard yet. Replay, or Play all missed.',
        badge: historyUnheard,
        onTap: onOpenHistory,
      ),
    ],
  );
}
