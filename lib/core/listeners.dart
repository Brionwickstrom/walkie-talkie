import 'dart:convert';

/// One socket in a relay room, from the relay's roster (relay 1.4.0+).
class RosterEntry {
  const RosterEntry(this.id, this.idle, this.age, {this.sent = false});

  /// Node id it claimed (hex, lower case), '' if none. Not verified.
  final String id;

  /// Seconds since it last sent anything (frame or text ping).
  final int idle;

  /// Seconds since it connected.
  final int age;

  /// It sent at least one binary frame.
  final bool sent;
}

/// The roster one relay sent for our room (v1.9.4).
class RelayRoster {
  RelayRoster(this.entries, this.at);
  final List<RosterEntry> entries;
  final DateTime at;

  /// `{"t":"roster","n":3,"s":[["a1b2",1,40,1],...]}`, null for any other
  /// text ("pong", future messages).
  static RelayRoster? tryParse(String text, {DateTime? at}) {
    if (text.isEmpty || text.codeUnitAt(0) != 0x7B /* { */ ) return null;
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['t'] != 'roster') return null;
      final s = j['s'];
      if (s is! List || s.length > 256) return null;
      final out = <RosterEntry>[];
      for (final e in s) {
        if (e is! List || e.length < 3) continue;
        final id = e[0], idle = e[1], age = e[2];
        if (id is! String || idle is! num || age is! num) continue;
        out.add(
          RosterEntry(
            id.toLowerCase(),
            idle.toInt(),
            age.toInt(),
            sent: e.length > 3 && e[3] == 1,
          ),
        );
      }
      return RelayRoster(out, at ?? DateTime.now());
    } catch (_) {
      return null;
    }
  }
}

/// How many sockets in a relay room are listening without showing up.
///
/// [heard]: the ids (hex) of everyone we hear on this channel right now,
/// including ourselves. A socket counts as an unknown listener when it has
/// been connected for at least [joinGrace] (a new phone's hello is a second
/// away) and either
/// * claims an id we do not hear and is active (sent something in the last
///   [activeIdle] seconds), or claims a heard id that already has its own
///   socket (a copy of someone's id), or
/// * has been silent longer than [ghostIdle] seconds: the relay closes
///   dead sockets (a phone that changed networks) well before that, so
///   whatever is left is listening on purpose.
/// Sockets in between (silent a little while, unknown id) are treated as a
/// phone that just dropped off, not as a listener.
int unknownListeners(
  RelayRoster roster,
  Set<String> heard, {
  int joinGrace = 8,
  int activeIdle = 15,
  int ghostIdle = 60,
}) {
  final byId = <String, List<RosterEntry>>{};
  for (final e in roster.entries) {
    byId.putIfAbsent(e.id, () => []).add(e);
  }
  var n = 0;
  for (final MapEntry(key: id, value: list) in byId.entries) {
    list.sort((a, b) => a.idle.compareTo(b.idle));
    // A heard phone owns its freshest socket.
    final rest = heard.contains(id) && id.isNotEmpty ? list.skip(1) : list;
    for (final e in rest) {
      if (e.age < joinGrace) continue;
      if (e.idle < activeIdle || e.idle > ghostIdle) n++;
    }
  }
  return n;
}

/// Combines the rosters of every relay (home + backup): the most unknown
/// listeners any one relay shows, smoothed over the last two rosters of
/// that relay so a phone joining between two rosters does not flash a
/// warning.
class ListenerWatch {
  ListenerWatch({
    this.freshFor = const Duration(seconds: 15),
    this.joinGrace = 8,
  });
  final Duration freshFor;

  /// See [unknownListeners].
  final int joinGrace;
  final Map<Object, (int, int, DateTime)> _byRelay = {};

  /// Count from a new roster of relay [relay].
  void update(Object relay, RelayRoster roster, Set<String> heard) {
    final now = unknownListeners(roster, heard, joinGrace: joinGrace);
    final prev = _byRelay[relay];
    _byRelay[relay] = (now, prev?.$1 ?? now, roster.at);
  }

  /// Unknown listeners right now (0 without fresh rosters).
  int count(DateTime now) {
    var best = 0;
    for (final (cur, prev, at) in _byRelay.values) {
      if (now.difference(at) > freshFor) continue;
      final v = cur < prev ? cur : prev;
      if (v > best) best = v;
    }
    return best;
  }

  /// Rosters fresh from at least one relay (relay 1.4.0 or newer).
  bool supported(DateTime now) =>
      _byRelay.values.any((r) => now.difference(r.$3) <= freshFor);

  void clear() => _byRelay.clear();
}
