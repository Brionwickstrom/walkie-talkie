import 'trip_packet.dart';
import 'trip_route.dart';

class HeldItem {
  HeldItem(this.origin, this.msg, this.packetId, this.at, this.pendingFor)
    : size = msg.encode().length;
  final int origin;
  final TripMsg msg;
  final int packetId;
  final DateTime at;
  final Set<int> pendingFor;
  final int size;
}

/// Base camp store-and-forward (v1.8.0): a phone left at camp keeps Trip
/// messages (SOS, quick messages, pins, check-ins) for people who were out
/// of range when they were sent, and hands them over when those people
/// come back (over any link, the LoRa radio included).
///
/// * Kept [ttl] at most, [maxItems] / [maxBytes] in all (oldest dropped).
/// * De-duplicated by the mesh packet id of the frame (every copy of one
///   packet shares it) and by message: only the newest location per person
///   and the newest copy of an SOS (or its cancel) is kept.
/// * Live locations and full trails are not kept (too big, quickly stale);
///   check-ins and LoRa trail summaries are.
class StoreForward {
  StoreForward({
    this.ttl = const Duration(hours: 6),
    this.maxItems = 300,
    this.maxBytes = 64 * 1024,
    Clock? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int maxItems;
  final int maxBytes;
  final Clock _clock;
  bool enabled = false;

  final List<HeldItem> _items = [];
  final Set<int> _packetIds = {};
  int delivered = 0;
  int dropped = 0;

  List<HeldItem> get items => List.unmodifiable(_items);
  int get bytes => _items.fold(0, (s, i) => s + i.size);

  /// Whether a message of this kind is worth holding.
  static bool holdable(TripMsg m) => switch (m) {
    PosMsg() => m.checkIn,
    SosMsg() || SosAckMsg() || CannedMsg() => true,
    PinMsg() || PinDeleteMsg() => true,
    TrackMsg() => m.summary,
    HeldMsg() => false,
  };

  /// Messages that replace an older one from the same sender.
  static String? _slot(int origin, TripMsg m) => switch (m) {
    PosMsg() => 'pos:$origin',
    SosMsg() => 'sos:$origin:${m.id}',
    TrackMsg() when m.summary => 'trk:$origin:${m.trackId}',
    PinMsg() => 'pin:$origin:${m.pinId}',
    PinDeleteMsg() => 'pin:$origin:${m.pinId}',
    _ => null,
  };

  /// Keep [m] from [origin] for the phones in [absent] (out of range now).
  /// Returns false if it was not kept.
  bool hold(int origin, TripMsg m, int packetId, Set<int> absent) {
    if (!enabled || !holdable(m)) return false;
    prune();
    if (packetId != 0 && _packetIds.contains(packetId)) return false;
    final who = {...absent}..remove(origin);
    if (who.isEmpty) return false;
    final slot = _slot(origin, m);
    if (slot != null) {
      _items.removeWhere((i) {
        if (_slot(i.origin, i.msg) != slot) return false;
        // Keep any pending recipients of the replaced copy.
        who.addAll(i.pendingFor);
        return true;
      });
      who.remove(origin);
    } else {
      // Same message id from the same sender (another copy).
      if (_items.any(
        (i) => i.origin == origin && i.msg.key(origin) == m.key(origin),
      )) {
        return false;
      }
    }
    final item = HeldItem(origin, m, packetId, _clock(), who);
    _items.add(item);
    if (packetId != 0) _packetIds.add(packetId);
    _enforceCaps();
    return _items.contains(item);
  }

  void _enforceCaps() {
    var total = bytes;
    while (_items.isNotEmpty &&
        (_items.length > maxItems || total > maxBytes)) {
      final old = _items.removeAt(0);
      total -= old.size;
      dropped++;
    }
  }

  /// [peer] is reachable again: what it missed, as [HeldMsg]s to send
  /// (oldest first). Each item is handed out once per recipient.
  List<HeldMsg> takeFor(int peer, int Function() nextId) {
    prune();
    final now = _clock();
    final out = <HeldMsg>[];
    for (final i in List.of(_items)) {
      if (!i.pendingFor.remove(peer)) continue;
      out.add(
        HeldMsg(
          nextId(),
          origin: i.origin,
          age: now.difference(i.at),
          inner: i.msg,
        ),
      );
      delivered++;
      if (i.pendingFor.isEmpty) _items.remove(i);
    }
    return out;
  }

  /// Anything waiting for [peer].
  bool pendingFor(int peer) => _items.any((i) => i.pendingFor.contains(peer));

  void prune() {
    final now = _clock();
    _items.removeWhere((i) {
      final old = now.difference(i.at) > ttl;
      if (old) dropped++;
      return old;
    });
    if (_packetIds.length > 2000) {
      _packetIds
        ..clear()
        ..addAll(_items.map((i) => i.packetId));
    }
  }

  void clear() {
    _items.clear();
    _packetIds.clear();
  }
}
