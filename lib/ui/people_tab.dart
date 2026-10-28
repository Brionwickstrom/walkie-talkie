import 'package:flutter/material.dart';

import '../app/people_refresh.dart';
import 'friends_page.dart';
import 'home_view.dart' show PersonView;
import 'people_refresh_view.dart';
import 'reach.dart';

/// The People tab (v2.3.2), in two sections so it is clear who is who:
///
/// * "On CH 1 now": the people actually present on this channel / group (the
///   same people as the Talk screen), with Refresh (tap, pull down, or hold
///   to also ask over the radio) and Scan for people (who is on other
///   channels).
/// * "Friends (direct chats)": your friends, with online dots, Show my code
///   and Scan a code to add a friend. Friends are direct contacts, not
///   channel members.
class PeopleTabView extends StatelessWidget {
  const PeopleTabView({
    super.key,
    required this.place,
    required this.here,
    required this.whosWhereCount,
    required this.onWhosWhere,
    required this.friends,
    this.requests = const [],
    required this.onOpenFriend,
    required this.onShowCode,
    required this.onScan,
    this.onLongPressFriend,
    this.onOpenPerson,
    this.onRefresh,
    this.radioAvailable,
    this.onAddPeople,
  });

  /// The current channel or group.
  final Reach place;

  /// Who is present on [place] right now: you first, then the others.
  final List<PersonView> here;
  final int whosWhereCount;
  final VoidCallback onWhosWhere;
  final List<FriendItem> friends;
  final List<(String, VoidCallback, VoidCallback)> requests;
  final ValueChanged<FriendItem> onOpenFriend;
  final VoidCallback onShowCode;
  final VoidCallback onScan;
  final ValueChanged<FriendItem>? onLongPressFriend;
  final ValueChanged<PersonView>? onOpenPerson;
  final Future<RefreshResult> Function({required bool radio})? onRefresh;
  final bool Function()? radioAvailable;

  /// Private group only: invite more people.
  final VoidCallback? onAddPeople;

  static String _ago(Duration d) {
    if (d.inSeconds < 10) return 'just now';
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PeopleRefreshScope(
      refresh: onRefresh,
      radioAvailable: radioAvailable,
      builder: (context, refreshButton) => FriendsView(
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PlaceHeader(place),
            Padding(
              key: const Key('people-section-here'),
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
              child: Row(
                children: [
                  Icon(place.icon, size: 18, color: place.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'On ${place.label} now (${here.length})',
                      key: const Key('people-count'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ?refreshButton,
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton.icon(
                  key: const Key('whosWhereButton'),
                  onPressed: onWhosWhere,
                  icon: Badge(
                    isLabelVisible: whosWhereCount > 0,
                    label: Text('$whosWhereCount'),
                    child: const Icon(Icons.travel_explore),
                  ),
                  label: const Text('Scan for people'),
                ),
              ),
            ),
            for (final p in here)
              ListTile(
                key: Key('people-here-${p.id}'),
                dense: true,
                leading: CircleAvatar(
                  radius: 18,
                  child: Text(
                    p.name.isEmpty ? '?' : p.name.characters.first,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                title: Text(
                  p.me ? '${p.name} (you)' : p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: !p.me && (p.talking || p.lastHeard != null),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!p.me && p.talking)
                      const Text('Talking now')
                    else if (!p.me && p.lastHeard != null)
                      Text('Heard ${_ago(p.lastHeard!)}'),
                    ReachTag(place),
                  ],
                ),
                trailing: p.me || onOpenPerson == null
                    ? null
                    : const Icon(Icons.chevron_right),
                onTap: p.me || onOpenPerson == null
                    ? null
                    : () => onOpenPerson!(p),
              ),
            if (here.length <= 1)
              Padding(
                key: const Key('people-here-empty'),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nobody else on ${place.label} right now. Others '
                      'appear here automatically.',
                    ),
                    if (onAddPeople != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton.tonalIcon(
                          key: const Key('people-add-people'),
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('Add people'),
                          onPressed: onAddPeople,
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 20),
          ],
        ),
        sectionHeader: SectionTitle(
          'Friends (direct chats)',
          key: const Key('people-section-friends'),
          reach: Reach.direct('friends'),
          subtitle:
              'Your friends can talk and text you from any channel. '
              'Only you two.',
        ),
        addCaption: 'Add friends',
        showReach: true,
        friends: friends,
        requests: requests,
        onOpen: onOpenFriend,
        onShowCode: onShowCode,
        onScan: onScan,
        onLongPress: onLongPressFriend,
      ),
    );
  }
}
