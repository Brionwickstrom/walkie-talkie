import '../app/call_signs.dart';
import 'transport.dart';

/// What we know about one remote phone.
class Peer {
  Peer(this.id);

  final int id;
  String name = '';
  int channel = 0;
  bool talking = false;

  /// Last time we heard anything from this peer on each transport.
  final Map<TransportKind, DateTime> lastSeen = {};

  /// Last measured round trip per transport (ping/pong).
  final Map<TransportKind, Duration> rtt = {};

  /// LAN endpoints the peer advertised in its hello ("ip:port").
  List<String> lanAddrs = const [];

  /// Hello interval the peer announced (battery saver), if longer than
  /// normal.
  Duration? helloInterval;

  /// Feature level from the hello (15 = v1.5 friends / chat), 0 = older.
  int feature = 0;

  /// Hello extension fields (channel name, admin, announcement mode...).
  Map<String, Object?> info = const {};

  bool get supportsChat => feature >= 15;

  /// Transport currently used to send to this peer (best live link).
  TransportKind? activeLink;

  /// Last time we heard this peer through other phones (mesh relay), and
  /// how many radio hops that took (2 = one phone in between).
  DateTime? meshSeen;
  int hops = 1;

  /// Hop count to show ("via 2 hops") when the peer is only reachable
  /// through the mesh, else null. Set by the TransportManager.
  int? meshHops;

  String get displayName => name.isNotEmpty ? name : callSignFor(id);

  Set<TransportKind> liveLinks(DateTime now, Duration timeout) => {
    for (final e in lastSeen.entries)
      if (now.difference(e.value) <= timeout) e.key,
  };
}
