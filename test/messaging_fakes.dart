import 'dart:async';
import 'dart:typed_data';

import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/messaging/ringer.dart';

/// A tiny in-memory "radio" between phones, with optional loss.
class FakeNet {
  final Map<int, FakeNode> nodes = {};

  /// Return true to drop a packet (from, to, payload).
  bool Function(int from, int to, Uint8List payload) drop = (_, _, _) => false;

  /// Pairs that can hear each other (both directions). Empty = everyone.
  final Set<(int, int)> links = {};
  bool allConnected = true;

  /// What [FakeNode.bestLinkTo] reports (changes chunk size / pacing).
  TransportKind linkKind = TransportKind.lan;

  bool connected(int a, int b) =>
      allConnected || links.contains((a, b)) || links.contains((b, a));

  FakeNode add(int id, {int channel = 1}) =>
      nodes[id] = FakeNode(this, id, channel);

  int sent = 0;

  /// Deliver every data packet this many times, as if it arrived over
  /// Wi-Fi, Bluetooth and the relay at once.
  int copies = 1;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

class FakeNode implements MessengerLink, RingLink {
  FakeNode(this.net, this.id, this.channel);
  final FakeNet net;
  final int id;
  @override
  int channel;
  final _data = StreamController<InboundData>.broadcast();
  final _controls = StreamController<InboundControl>.broadcast();

  @override
  int get localNodeId => id;

  @override
  int get scope => channel;

  @override
  int get frameOverhead => 0;

  @override
  bool isReachable(int peerId) =>
      net.nodes.containsKey(peerId) &&
      peerId != id &&
      net.connected(id, peerId);

  @override
  TransportKind? bestLinkTo(int peerId) =>
      isReachable(peerId) ? net.linkKind : null;

  @override
  Set<int> reachablePeersOn(int channel) => {
    for (final n in net.nodes.values)
      if (n.channel == channel && isReachable(n.id)) n.id,
  };

  @override
  String nameOf(int peerId) => 'Node $peerId';

  /// Phones that understand chat (null = all of them).
  Set<int>? chatPeers;

  @override
  bool supportsChat(int peerId) => chatPeers?.contains(peerId) ?? true;

  @override
  Stream<InboundData> get data => _data.stream;

  @override
  Stream<InboundControl> get controls => _controls.stream;

  @override
  Future<bool> sendData(int peerId, Uint8List payload) async {
    if (!isReachable(peerId)) return false;
    net.sent++;
    if (net.drop(id, peerId, payload)) return true;
    final copy = Uint8List.fromList(payload);
    final to = net.nodes[peerId]!;
    for (var i = 0; i < net.copies; i++) {
      final kind = net.copies == 1
          ? net.linkKind
          : TransportKind.values[i % TransportKind.values.length];
      scheduleMicrotask(
        () => to._data.add(InboundData(id, channel, copy, kind)),
      );
    }
    return true;
  }

  @override
  Future<bool> sendControlTo(int peerId, ControlMessage msg) async {
    if (!isReachable(peerId)) return false;
    final bytes = msg.encode();
    if (net.drop(id, peerId, bytes)) return true;
    final to = net.nodes[peerId]!;
    final decoded = ControlMessage.tryDecode(bytes)!;
    scheduleMicrotask(
      () => to._controls.add(
        InboundControl(id, channel, decoded, TransportKind.lan),
      ),
    );
    return true;
  }

  @override
  Future<Set<int>> sendControlToChannel(ControlMessage msg) async {
    final targets = reachablePeersOn(channel);
    for (final t in targets) {
      await sendControlTo(t, msg);
    }
    return targets;
  }
}

/// Manually advanced clock.
class FakeClock {
  DateTime now = DateTime(2026, 10, 25, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}
