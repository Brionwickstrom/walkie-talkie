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

  /// Last signal strength (dBm) per transport, where the link reports it
  /// (Bluetooth, LoRa). Shown on the network map.
  final Map<TransportKind, int> rssi = {};

  /// Last measured round trip per transport (ping/pong).
  final Map<TransportKind, Duration> rtt = {};

  /// LAN endpoints the peer advertised in its hello ("ip:port").
  List<String> lanAddrs = const [];

  /// Hello interval the peer announced (battery saver), if longer than
  /// normal.
  Duration? helloInterval;

  /// Feature level from the hello (15 = v1.5 friends / chat), 0 = older.
  int feature = 0;

  /// Phone battery 0..100 from its hellos (`bt`, v1.8.3), null = unknown.
  int? battery;

  /// Per-phone public keys announced in its hellos (`x.kx`, v1.9.4) and
  /// when each was last seen; see `KxBook` in peer_box.dart.
  final Map<String, DateTime> kxSeen = {};

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

  /// Last time this phone was heard through a LoRa gateway (v1.9.5) and
  /// which one.
  DateTime? gatewaySeen;
  int? gatewayId;

  /// "Home gateway" while a LoRa gateway is the only way to this phone
  /// (shown as "via Home gateway (LoRa)"), else null. Set by the
  /// TransportManager.
  String? viaGateway;

  String get displayName => name.isNotEmpty ? name : callSignFor(id);

  Set<TransportKind> liveLinks(DateTime now, Duration timeout) => {
    for (final e in lastSeen.entries)
      if (now.difference(e.value) <= timeout) e.key,
  };
}
