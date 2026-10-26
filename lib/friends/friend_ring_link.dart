import 'dart:async';

import '../core/frame.dart';
import '../core/transport_manager.dart';
import '../messaging/ringer.dart';
import 'friend_links.dart';

/// Rings, beeps and their answers for friends (v1.8.3): to a friend over
/// the private friend link (sealed with the pair key; direct, phone mesh
/// or LoRa radio), to anyone else over the channel as before.
class FriendAwareRingLink implements RingLink {
  FriendAwareRingLink(this.base, this._friends, this.friendScope);
  final RingLink base;
  final FriendLinks Function() _friends;

  /// Pseudo channel friend rings are filed under.
  final int friendScope;

  bool _friendPath(int peer) {
    final f = _friends();
    return f.isFriend(peer) && f.isOnline(peer);
  }

  @override
  int get channel => base.channel;

  @override
  Set<int> reachablePeersOn(int channel) => base.reachablePeersOn(channel);

  @override
  bool isReachable(int peerId) =>
      base.isReachable(peerId) || _friendPath(peerId);

  @override
  Future<bool> sendControlTo(int peerId, ControlMessage msg) async {
    // A friend: always the private link (sealed with the pair key), even
    // when the channel also reaches them.
    if (_friendPath(peerId)) return _friends().sendControl(peerId, msg);
    return base.sendControlTo(peerId, msg);
  }

  @override
  Future<Set<int>> sendControlToChannel(ControlMessage msg) =>
      base.sendControlToChannel(msg);

  @override
  late final Stream<InboundControl> controls = _merge();

  Stream<InboundControl> _merge() {
    final subs = <StreamSubscription<InboundControl>>[];
    late final StreamController<InboundControl> c;
    c = StreamController<InboundControl>.broadcast(
      onListen: () {
        subs.add(base.controls.listen(c.add));
        subs.add(
          _friends().inbound
              .where((f) => f.frame.type == FrameType.control)
              .expand<InboundControl>((f) {
                final m = f.frame.control;
                if (m == null) return const [];
                switch (m.kind) {
                  case ControlKind.ring:
                  case ControlKind.beep:
                  case ControlKind.ringAck:
                    return [InboundControl(f.friendId, friendScope, m, f.via)];
                  default:
                    return const [];
                }
              })
              .listen(c.add),
        );
      },
      onCancel: () {
        for (final s in subs) {
          unawaited(s.cancel());
        }
        subs.clear();
      },
    );
    return c.stream;
  }
}
