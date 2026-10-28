import 'package:flutter/material.dart';

/// Who a conversation or list reaches (v2.3.2). The same icon, colour and
/// wording is used on every tab, row and header, so you can always tell an
/// open channel (anyone on the number), a private group (only its members)
/// and a direct chat (only you two) apart.
enum ReachKind { open, group, direct }

class Reach {
  const Reach._(this.kind, this.label, this.color, this.channelName);

  /// An open channel: "CH 1" ([name] is its optional title, "General Room").
  factory Reach.open(int channel, {String? name}) => Reach._(
    ReachKind.open,
    'CH $channel',
    const Color(0xFFFFB74D),
    (name == null || name.trim().isEmpty) ? null : name.trim(),
  );

  /// A private group: its name, in the group's own colour.
  factory Reach.group(String name, {int? color}) => Reach._(
    ReachKind.group,
    name,
    color == null ? const Color(0xFF4DB6AC) : Color(color),
    null,
  );

  /// A direct chat with a friend.
  factory Reach.direct(String friend) =>
      Reach._(ReachKind.direct, friend, const Color(0xFFB39DDB), null);

  final ReachKind kind;

  /// "CH 1", the group name or the friend's name.
  final String label;
  final Color color;

  /// Open channel title, if it has one.
  final String? channelName;

  IconData get icon => switch (kind) {
    ReachKind.open => Icons.lock_open,
    ReachKind.group => Icons.lock,
    ReachKind.direct => Icons.person,
  };

  /// The one tag every row carries: "Open channel · CH 1", "Private group ·
  /// privates club", "Direct · Ann · only you two".
  String get tag => switch (kind) {
    ReachKind.open => 'Open channel · $label',
    ReachKind.group => 'Private group · $label',
    ReachKind.direct => 'Direct · $label · only you two',
  };

  /// Tab headers: "CH 1 · open", "privates club · private".
  String get header => switch (kind) {
    ReachKind.open =>
      '${channelName == null ? '' : '$channelName · '}$label · open',
    ReachKind.group => '$label · private',
    ReachKind.direct => '$label · direct',
  };

  /// Who can read a chat here.
  String get reads => switch (kind) {
    ReachKind.open => 'Anyone on $label can read this',
    ReachKind.group => 'Only people in $label',
    ReachKind.direct => 'Only you two',
  };

  /// Who a voice message / talk here reaches.
  String get hears => switch (kind) {
    ReachKind.open => 'Anyone on $label can hear',
    ReachKind.group => 'Only people in $label can hear',
    ReachKind.direct => 'Only you two',
  };

  @override
  bool operator ==(Object other) =>
      other is Reach &&
      other.kind == kind &&
      other.label == label &&
      other.color == color &&
      other.channelName == channelName;

  @override
  int get hashCode => Object.hash(kind, label, color, channelName);
}

/// The small icon + text tag ("Open channel · CH 1") on every row.
class ReachTag extends StatelessWidget {
  const ReachTag(this.reach, {super.key, this.text, this.size = 12});
  final Reach reach;

  /// Replaces [Reach.tag] (a longer line starting with the same tag).
  final String? text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = reach.color;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(reach.icon, size: size + 1, color: c),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text ?? reach.tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w600,
              color: c,
            ),
          ),
        ),
      ],
    );
  }
}

/// Top of the Chat and People tabs: where you are right now.
class PlaceHeader extends StatelessWidget {
  const PlaceHeader(this.reach, {super.key});
  final Reach reach;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('place-header'),
      width: double.infinity,
      color: reach.color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(reach.icon, size: 20, color: reach.color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reach.header,
              key: const Key('place-header-text'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A section title: "Here (CH 1)", "Direct chats".
class SectionTitle extends StatelessWidget {
  const SectionTitle(
    this.title, {
    super.key,
    this.reach,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final Reach? reach;
  final String? subtitle;
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
      child: Row(
        children: [
          if (reach != null) ...[
            Icon(reach!.icon, size: 18, color: reach!.color),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ...?trailing,
        ],
      ),
    );
  }
}
