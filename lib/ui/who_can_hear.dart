import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../core/transport_manager.dart';
import 'sheets.dart';

/// The three kinds of conversation, in the words used everywhere in the app
/// (v2.1.1): Open channel (CH 1-16, anyone on the number), Private group
/// (v2.3.0: its own place with a name and colour, not a channel number;
/// only people in it) and Direct chat (one friend).
enum Audience {
  open('Open channel', Icons.forum_outlined),
  privateGroup('Private group', Icons.lock),
  direct('Direct chat', Icons.person);

  const Audience(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// What the "Who can hear this?" line says for the conversation on screen.
class AudienceInfo {
  const AudienceInfo(this.kind, {this.channel, this.members, this.name});
  final Audience kind;

  /// Channel number (open channel only: a private group has none).
  final int? channel;

  /// Private group: people in it right now, you included (null = unknown).
  final int? members;

  /// Direct chat: the friend.
  final String? name;

  /// "Open channel · anyone on CH 3 can hear".
  String get line => switch (kind) {
    Audience.open =>
      'Open channel · anyone on ${channel == null ? 'this channel' : 'CH $channel'} can hear',
    Audience.privateGroup =>
      'Private group · only people with the code'
          '${members == null ? '' : ' ($members ${members == 1 ? 'member' : 'members'})'}',
    Audience.direct => 'Direct chat · just you and ${name ?? 'your friend'}',
  };

  /// The talk screen's current channel.
  factory AudienceInfo.ofChannel(WalkieController c) => c.isPrivate
      ? AudienceInfo(Audience.privateGroup, members: c.channelListeners + 1)
      : AudienceInfo(Audience.open, channel: c.channel);

  /// A channel chat for [scope] (an open channel number or a private
  /// group's scope). [currentScope] / [currentChannel] are the Talk
  /// screen's; [listeners] are the other people on it.
  factory AudienceInfo.forScope(
    int scope, {
    required int currentScope,
    required int currentChannel,
    required int listeners,
  }) {
    if (TransportManager.isPrivateScope(scope)) {
      // A private group has no channel number.
      return AudienceInfo(
        Audience.privateGroup,
        members: scope == currentScope ? listeners + 1 : null,
      );
    }
    return AudienceInfo(Audience.open, channel: scope);
  }

  /// A chat screen: a friend's Direct chat or a channel's chat.
  factory AudienceInfo.ofChat(WalkieController c, String conv) {
    final f = c.friendOf(conv);
    if (f != null) return AudienceInfo(Audience.direct, name: c.friendName(f));
    return AudienceInfo.forScope(
      int.tryParse(conv.substring(1)) ?? 0,
      currentScope: c.scope,
      currentChannel: c.channel,
      listeners: c.channelListeners,
    );
  }
}

/// A thin tappable line under the top-bar name: "Open channel · anyone on
/// CH 3 can hear". One line, cut with an ellipsis when it does not fit;
/// the height follows the text size so large text never overflows. Tap
/// for [showWhoCanHearSheet].
class WhoCanHearLine extends StatelessWidget implements PreferredSizeWidget {
  const WhoCanHearLine({super.key, required this.info, this.trailing});
  final AudienceInfo info;

  /// A small chip at the end of the line (the quiet-hours moon, v2.3.0).
  final Widget? trailing;

  static double heightFor(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(13) + 16;

  @override
  Size get preferredSize => const Size.fromHeight(30);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final line = Semantics(
      button: true,
      label: 'Who can hear this? ${info.line}',
      excludeSemantics: true,
      child: InkWell(
        key: const Key('who-can-hear'),
        onTap: () => showWhoCanHearSheet(context, info),
        child: SizedBox(
          height: heightFor(context),
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Icon(info.kind.icon, size: 14, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    info.line,
                    key: const Key('who-can-hear-text'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.info_outline, size: 14, color: cs.onSurfaceVariant),
                SizedBox(width: trailing == null ? 12 : 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (trailing == null) return line;
    return Row(
      children: [
        Expanded(child: line),
        Padding(padding: const EdgeInsets.only(right: 12), child: trailing),
      ],
    );
  }
}

/// App bar bottom that sizes itself to the text scale.
PreferredSizeWidget whoCanHearBottom(
  BuildContext context,
  AudienceInfo info, {
  Widget? trailing,
}) => PreferredSize(
  preferredSize: Size.fromHeight(WhoCanHearLine.heightFor(context)),
  child: WhoCanHearLine(info: info, trailing: trailing),
);

const _explain = {
  Audience.open:
      'CH 1 to 16. Anyone on the same channel number can hear you. It is '
      'not encrypted.',
  Audience.privateGroup:
      'Its own place with a name and colour, not a channel number. Only '
      'people you invited, or who have its code, can hear or see anything. '
      'It is encrypted.',
  Audience.direct:
      'One friend, on any channel. Only you two can read or hear it '
      '(end-to-end encrypted).',
};

/// "Who can hear this?": the three kinds side by side, the current one
/// highlighted.
Future<void> showWhoCanHearSheet(BuildContext context, AudienceInfo info) =>
    showAppSheet<void>(
      context: context,
      builder: (ctx) => WhoCanHearSheetBody(info: info),
    );

class WhoCanHearSheetBody extends StatelessWidget {
  const WhoCanHearSheetBody({super.key, required this.info});
  final AudienceInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          key: const Key('who-can-hear-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Who can hear this?', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Right now: ${info.line}.',
              key: const Key('who-can-hear-now'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            for (final k in Audience.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DecoratedBox(
                  key: Key('who-kind-${k.name}'),
                  decoration: BoxDecoration(
                    color: k == info.kind
                        ? cs.primaryContainer
                        : cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: k == info.kind
                        ? Border.all(color: cs.primary, width: 2)
                        : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(k.icon, color: cs.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                k == info.kind
                                    ? '${k.label} (this one)'
                                    : k.label,
                                style: theme.textTheme.titleSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(_explain[k]!),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
