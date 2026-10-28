import '../app/walkie_controller.dart';
import '../core/transport_manager.dart';
import 'reach.dart';

/// [Reach] for what the controller is on / has (v2.3.2).
extension ReachOfController on WalkieController {
  /// The channel or group we are on right now.
  Reach get placeReach {
    final g = currentGroup;
    if (isPrivate) {
      return Reach.group(g?.name ?? 'private group', color: g?.color);
    }
    return Reach.open(channel, name: channelName?.name);
  }

  /// Any scope: an open channel, one of our groups, or the direct chats.
  Reach reachOfScope(int scope) {
    if (scope == WalkieController.friendScope) return Reach.direct('friends');
    if (!TransportManager.isPrivateScope(scope)) {
      return Reach.open(scope, name: channelNameOf(scope)?.name);
    }
    final g = groupForScope(scope);
    return Reach.group(g?.name ?? 'private group', color: g?.color);
  }
}
