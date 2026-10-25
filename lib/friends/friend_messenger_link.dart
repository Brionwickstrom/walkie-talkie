import 'dart:typed_data';

import '../core/channel_crypto.dart';
import '../core/frame.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
import '../messaging/messenger.dart';
import 'friend_links.dart';

/// Voice messages and chats between friends: the normal [Messenger]
/// (chunks, acks, store-and-forward) running over [FriendLinks], so
/// everything is sealed with the pair key and works on any channel.
class FriendMessengerLink implements MessengerLink {
  FriendMessengerLink(this.links, this.scope);
  final FriendLinks links;

  /// Pseudo channel the friend messages are filed under.
  @override
  final int scope;

  @override
  int get localNodeId => links.localId;
  @override
  bool isReachable(int peerId) => links.isOnline(peerId);
  @override
  TransportKind? bestLinkTo(int peerId) => links.bestLink(peerId);
  @override
  Set<int> reachablePeersOn(int channel) => const {};
  @override
  int get frameOverhead => ChannelKey.overhead;
  @override
  Future<bool> sendData(int peerId, Uint8List payload) =>
      links.send(peerId, links.frame(FrameType.data, payload));
  @override
  Stream<InboundData> get data => links.inbound
      .where((f) => f.frame.type == FrameType.data)
      .map((f) => InboundData(f.friendId, scope, f.frame.payload, f.via));
  @override
  String nameOf(int peerId) => links.friend(peerId)?.name ?? '';
  @override
  bool supportsChat(int peerId) => true;
}
