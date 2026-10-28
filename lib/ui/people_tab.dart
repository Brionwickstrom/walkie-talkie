import 'package:flutter/material.dart';

import '../app/people_refresh.dart';
import 'friends_page.dart';
import 'people_refresh_view.dart';
import 'whos_where_page.dart';

/// The People tab (v2.3.1): who is here, with Refresh (pull down, tap, or
/// hold to also ask over the radio) and Who's where, then your friends.
/// These used to sit in the "1 on (group)" row on the Talk screen.
class PeopleTabView extends StatelessWidget {
  const PeopleTabView({
    super.key,
    required this.here,
    required this.channelLabel,
    required this.whosWhereCount,
    required this.onWhosWhere,
    required this.friends,
    this.requests = const [],
    required this.onOpenFriend,
    required this.onShowCode,
    required this.onScan,
    this.onLongPressFriend,
    this.onRefresh,
    this.radioAvailable,
  });

  /// People on this channel / group, you included.
  final int here;
  final String channelLabel;
  final int whosWhereCount;
  final VoidCallback onWhosWhere;
  final List<FriendItem> friends;
  final List<(String, VoidCallback, VoidCallback)> requests;
  final ValueChanged<FriendItem> onOpenFriend;
  final VoidCallback onShowCode;
  final VoidCallback onScan;
  final ValueChanged<FriendItem>? onLongPressFriend;
  final Future<RefreshResult> Function({required bool radio})? onRefresh;
  final bool Function()? radioAvailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PeopleRefreshScope(
      refresh: onRefresh,
      radioAvailable: radioAvailable,
      builder: (context, refreshButton) => FriendsView(
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Icon(Icons.groups, size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$here on $channelLabel',
                  key: const Key('people-count'),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?refreshButton,
              WhosWhereButton(count: whosWhereCount, onPressed: onWhosWhere),
            ],
          ),
        ),
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
