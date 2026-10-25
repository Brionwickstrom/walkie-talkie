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

  /// Transport currently used to send to this peer (best live link).
  TransportKind? activeLink;

  String get displayName =>
      name.isNotEmpty ? name : 'Phone ${id.toRadixString(16).padLeft(8, '0')}';

  Set<TransportKind> liveLinks(DateTime now, Duration timeout) => {
        for (final e in lastSeen.entries)
          if (now.difference(e.value) <= timeout) e.key,
      };
}
