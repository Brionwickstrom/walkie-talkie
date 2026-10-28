import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/frame.dart';
import '../core/lobby.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
import 'power_plan.dart';

/// One phone heard through lobby beacons.
class LobbyEntry {
  LobbyEntry(this.id, this.beacon);
  final int id;
  LobbyBeacon beacon;

  /// Last beacon per path (internet = the relay lobby room).
  final Map<TransportKind, DateTime> heard = {};

  /// Radio hops of the last copy that came through the phone mesh.
  int? hops;
  DateTime? meshAt;

  DateTime get lastAt {
    var t = meshAt;
    for (final h in heard.values) {
      if (t == null || h.isAfter(t)) t = h;
    }
    return t ?? DateTime(0);
  }

  /// A beacon counts this long: 3x the sender's announced interval, at
  /// least [WhosWhere.minTtl].
  Duration get ttl {
    final t = beacon.every * 3;
    return t < WhosWhere.minTtl ? WhosWhere.minTtl : t;
  }

  /// The LoRa copy comes every [LobbyBeacon.radioInterval]: it counts
  /// 3x that long.
  Duration ttlFor(TransportKind k) {
    if (k != TransportKind.lora) return ttl;
    final r = LobbyBeacon.radioInterval * 3;
    return r > ttl ? r : ttl;
  }

  Set<TransportKind> liveLinks(DateTime now) => {
    for (final e in heard.entries)
      if (now.difference(e.value) <= ttlFor(e.key)) e.key,
  };

  int? liveHops(DateTime now) {
    final m = meshAt;
    return m != null && now.difference(m) <= ttl ? hops : null;
  }

  bool alive(DateTime now) =>
      liveLinks(now).isNotEmpty || liveHops(now) != null;
}

/// "Who's where" (v1.8.2): sends this phone's lobby beacon at a low rate
/// and collects everyone else's.
///
/// * Local links (Wi-Fi / LAN, Wi-Fi Direct, Bluetooth, and further through
///   the phone mesh): every [PowerPlan.lobbyLocalInterval] (10 s, 20 s in
///   battery saver, 60 s in offline power save).
/// * Internet: while online the phone joins one extra relay room,
///   [LobbyBeacon.relayRoom], and beacons there every
///   [PowerPlan.lobbyRelayInterval] (30 s / 60 s). Only lobby frames are
///   read from that room. Off in offline power save; battery saver keeps
///   it only while the app is on screen.
/// * LoRa (v1.8.3): one copy every [LobbyBeacon.radioInterval] (15 min)
///   while a radio is connected ([sendRadio]), at the radio's lowest
///   priority and rate limit, so people only the radio reaches show up
///   (kept for 3x that). Same privacy rules as every other copy.
/// * "Show me in Who's where" off: nothing is sent (we still listen).
/// * Inbound beacons go through a [LobbyLimiter]; at most [maxEntries]
///   phones are kept.
class WhosWhere extends ChangeNotifier {
  WhosWhere({
    required this.localId,
    required this.sendLocal,
    required this.beacon,
    this.relayFactory,
    this.sendRadio,
    this._plan = const PowerPlan(),
    this.replyPresence,
    DateTime Function()? clock,
    LobbyLimiter? limiter,
    ProbeReplyLimiter? probeLimiter,
    Duration Function()? replyJitter,
    void Function(Duration delay, void Function() run)? schedule,
  }) : _clock = clock ?? DateTime.now,
       limiter = limiter ?? LobbyLimiter(clock: clock),
       probeLimiter = probeLimiter ?? ProbeReplyLimiter(clock: clock),
       _jitter = replyJitter ?? _randomJitter,
       _schedule = schedule ?? _timer;

  // ------------------------------------------------ "who's here?" (v1.8.5)

  /// Answers to a probe wait a random 0..[maxReplyJitter] so phones that
  /// heard the same probe do not all transmit at once.
  static const Duration maxReplyJitter = Duration(milliseconds: 500);

  /// A probe heard over the LoRa radio is answered over the radio at most
  /// this often (whoever asks).
  static const Duration radioReplyInterval = Duration(minutes: 2);

  static final Random _rng = Random();
  static Duration _randomJitter() =>
      Duration(milliseconds: _rng.nextInt(maxReplyJitter.inMilliseconds + 1));
  static void _timer(Duration d, void Function() run) => Timer(d, run);

  /// Sends our presence hello right away (all links, or the radio's
  /// presence hello when [radio]). Set by the controller.
  Future<void> Function({required bool radio})? replyPresence;
  final ProbeReplyLimiter probeLimiter;
  final Duration Function() _jitter;
  final void Function(Duration delay, void Function() run) _schedule;
  DateTime? _lastRadioReply;

  /// Probes answered (tests / Details).
  int probeReplies = 0;
  int probeRadioReplies = 0;

  /// Someone refreshed: answer with our presence and lobby beacon, after
  /// a small random delay, at most once per requester every
  /// [ProbeReplyLimiter.perRequester]. Over LoRa only every
  /// [radioReplyInterval].
  void onProbe(InboundProbe p) {
    if (!_running || p.peerId == localId) return;
    final radio = p.transport == TransportKind.lora;
    if (radio) {
      final last = _lastRadioReply;
      final now = _clock();
      if (last != null && now.difference(last) < radioReplyInterval) return;
      if (!probeLimiter.allow(p.peerId)) return;
      _lastRadioReply = now;
    } else if (!probeLimiter.allow(p.peerId)) {
      return;
    }
    final delay = _jitter();
    _schedule(delay < Duration.zero ? Duration.zero : delay, () {
      if (!_running) return;
      unawaited(_reply(p, radio));
    });
  }

  Future<void> _reply(InboundProbe p, bool radio) async {
    if (radio) {
      probeRadioReplies++;
      try {
        await replyPresence?.call(radio: true);
      } catch (_) {}
      _sendRadio();
      return;
    }
    probeReplies++;
    try {
      await replyPresence?.call(radio: false);
    } catch (_) {}
    if (p.transport == TransportKind.internet) {
      await _sendRelay();
    } else {
      await _sendLocal();
    }
  }

  /// Our own refresh: the probe into the relay lobby room too. Reopens the
  /// room if it should be open and is not, and reconnects it when it is
  /// down (the probe then goes out once it is joined, if that happens
  /// within [probeRelayWait]). Nothing in offline power save.
  Future<bool> probeRelay(Uint8List bytes) async {
    if (!wantRelay) return false;
    if (_relay == null) await _syncRelay();
    final t = _relay;
    if (t == null) return false;
    if (t.status == TransportStatus.running) {
      try {
        await t.send(bytes);
      } catch (_) {}
      return true;
    }
    _pendingProbe = (bytes, _clock());
    try {
      t.kickDiscovery();
    } catch (_) {}
    return true;
  }

  static const Duration probeRelayWait = Duration(seconds: 3);
  (Uint8List, DateTime)? _pendingProbe;

  void _flushPendingProbe(Transport t) {
    final p = _pendingProbe;
    _pendingProbe = null;
    if (p == null || _clock().difference(p.$2) > probeRelayWait) return;
    unawaited(() async {
      try {
        await t.send(p.$1);
      } catch (_) {}
    }());
  }

  static const Duration minTtl = Duration(seconds: 25);
  static const int maxEntries = 256;

  final int localId;

  /// Sends lobby frame bytes on the local links (TransportManager).
  final Future<void> Function(Uint8List bytes) sendLocal;

  /// This phone's beacon for a path announcing [every], or null when
  /// "Show me in Who's where" is off.
  final LobbyBeacon? Function(Duration every) beacon;

  /// Queues lobby frame bytes on the LoRa radio; false when no radio is
  /// connected (tried again next tick). Null = no radio support.
  bool Function(Uint8List bytes)? sendRadio;
  DateTime? _lastRadio;
  int sentRadio = 0;

  /// Opens the relay lobby room (null = no relay configured).
  Transport Function()? relayFactory;
  final LobbyLimiter limiter;
  final DateTime Function() _clock;

  PowerPlan _plan;
  PowerPlan get plan => _plan;
  bool _foreground = true;
  bool _running = false;
  int _seq = 0;
  DateTime? _lastLocal;
  DateTime? _lastRelay;
  DateTime? _soon;
  Transport? _relay;
  final List<StreamSubscription<dynamic>> _relaySubs = [];
  final Map<int, LobbyEntry> _entries = {};

  /// Counters for tests / Details.
  int sentLocal = 0;
  int sentRelay = 0;

  bool get running => _running;
  bool get relayOpen => _relay != null;
  Transport? get relay => _relay;

  /// The relay lobby room should be open right now.
  bool get wantRelay =>
      _running &&
      relayFactory != null &&
      _plan.lobbyRelay &&
      (_foreground || _plan.lobbyRelayInBackground);

  List<LobbyEntry> get entries {
    final now = _clock();
    return [
      for (final e in _entries.values)
        if (e.alive(now)) e,
    ];
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _syncRelay();
    await _sendLocal();
  }

  Future<void> stop() async {
    _running = false;
    await _closeRelay();
  }

  Future<void> setPlan(PowerPlan p) async {
    _plan = p;
    await _syncRelay();
  }

  Future<void> setForeground(bool on) async {
    if (on == _foreground) return;
    _foreground = on;
    await _syncRelay();
  }

  /// Relay list changed: reopen the lobby room on the new relays.
  Future<void> setRelayFactory(Transport Function()? f) async {
    relayFactory = f;
    await _closeRelay();
    await _syncRelay();
  }

  /// Channel / name / visibility changed: announce within ~1 s (debounced
  /// so flipping through channels does not spam).
  void announceSoon() {
    _soon = _clock().add(const Duration(seconds: 1));
  }

  /// Call about once a second.
  Future<void> tick() async {
    if (!_running) return;
    final now = _clock();
    final soon = _soon;
    if (soon != null && !now.isBefore(soon)) {
      _soon = null;
      await _sendLocal();
      await _sendRelay();
      return;
    }
    final l = _lastLocal;
    if (l == null || now.difference(l) >= _plan.lobbyLocalInterval) {
      await _sendLocal();
    }
    final r = _lastRelay;
    if (_relay != null &&
        (r == null || now.difference(r) >= _plan.lobbyRelayInterval)) {
      await _sendRelay();
    }
    final rd = _lastRadio;
    if (sendRadio != null &&
        (rd == null || now.difference(rd) >= LobbyBeacon.radioInterval)) {
      _sendRadio();
    }
    prune();
  }

  void _sendRadio() {
    final send = sendRadio;
    if (send == null) return;
    final b = beacon(LobbyBeacon.radioInterval);
    if (b == null) return;
    if (send(b.encode(senderId: localId, seq: _nextSeq()))) {
      _lastRadio = _clock();
      sentRadio++;
    }
  }

  Future<void> _sendLocal() async {
    _lastLocal = _clock();
    final b = beacon(_plan.lobbyLocalInterval);
    if (b == null) return;
    sentLocal++;
    await sendLocal(b.encode(senderId: localId, seq: _nextSeq()));
  }

  Future<void> _sendRelay() async {
    final t = _relay;
    if (t == null || t.status != TransportStatus.running) return;
    _lastRelay = _clock();
    final b = beacon(_plan.lobbyRelayInterval);
    if (b == null) return;
    sentRelay++;
    try {
      await t.send(b.encode(senderId: localId, seq: _nextSeq()));
    } catch (_) {}
  }

  int _nextSeq() => _seq = (_seq + 1) & 0xFFFF;

  Future<void> _syncRelay() async {
    if (wantRelay && _relay == null) {
      final t = relayFactory!();
      _relay = t;
      _relaySubs.add(
        t.frames.listen((inb) {
          // Only lobby beacons count in the lobby room.
          final f = inb.frame;
          if (f.type != FrameType.lobby) return;
          final probe = LobbyProbe.tryDecode(f);
          if (probe != null) {
            onProbe(InboundProbe(f.senderId, probe, TransportKind.internet));
            return;
          }
          final b = LobbyBeacon.tryDecode(f);
          if (b == null) return;
          onLobby(InboundLobby(f.senderId, b, TransportKind.internet));
        }),
      );
      _relaySubs.add(
        t.statusChanges.listen((s) {
          if (s == TransportStatus.running) {
            _flushPendingProbe(t);
            unawaited(_sendRelay());
          }
        }),
      );
      // The status listener above beacons once the room is joined.
      try {
        await t.start(localNodeId: localId, channel: 0);
      } catch (_) {}
    } else if (!wantRelay && _relay != null) {
      await _closeRelay();
      // Internet-only entries go stale on their own (TTL).
    }
  }

  Future<void> _closeRelay() async {
    final t = _relay;
    _relay = null;
    for (final s in _relaySubs) {
      await s.cancel();
    }
    _relaySubs.clear();
    if (t != null) {
      try {
        await t.dispose();
      } catch (_) {}
    }
  }

  /// A lobby beacon arrived (local link, mesh or relay room).
  void onLobby(InboundLobby m) {
    if (m.peerId == localId) return;
    final path = m.hops > 1 ? 'mesh' : m.transport;
    if (!limiter.allow(m.peerId, path)) return;
    final now = _clock();
    var e = _entries[m.peerId];
    var changed = false;
    if (e == null) {
      if (_entries.length >= maxEntries) {
        final oldest = _entries.values.reduce(
          (a, b) => a.lastAt.isBefore(b.lastAt) ? a : b,
        );
        _entries.remove(oldest.id);
      }
      e = _entries[m.peerId] = LobbyEntry(m.peerId, m.beacon);
      changed = true;
    } else {
      final o = e.beacon;
      final n = m.beacon;
      if (o.channel != n.channel ||
          o.name != n.name ||
          o.battery != n.battery ||
          o.channelName != n.channelName ||
          o.channelEmoji != n.channelEmoji) {
        changed = true;
      }
      // A rare radio copy keeps the interval the local copies announced
      // (the radio path has its own, longer lifetime: [LobbyEntry.ttlFor]).
      e.beacon = m.transport == TransportKind.lora
          ? n.copyWith(every: o.every)
          : n;
      if (!e.alive(now)) changed = true;
    }
    if (m.hops > 1) {
      e.meshAt = now;
      e.hops = m.hops;
    } else {
      if (!e.heard.containsKey(m.transport)) changed = true;
      e.heard[m.transport] = now;
    }
    if (changed) notifyListeners();
  }

  /// Forget expired beacons.
  void prune() {
    final now = _clock();
    final before = _entries.length;
    _entries.removeWhere((_, e) {
      e.heard.removeWhere((k, t) => now.difference(t) > e.ttlFor(k));
      final m = e.meshAt;
      if (m != null && now.difference(m) > e.ttl) e.meshAt = null;
      return e.heard.isEmpty && e.meshAt == null;
    });
    if (_entries.length != before) notifyListeners();
  }

  @override
  void dispose() {
    _running = false;
    unawaited(_closeRelay());
    super.dispose();
  }
}

// ------------------------------------------------------------------ groups

enum WhoGroupKind {
  /// The channel this phone is on (may be private: only we know which).
  mine,

  /// Another public channel (tap to jump there).
  public,

  /// Everyone on some private channel: no number, name or tag.
  private,

  /// Friends who are online but have not said where.
  friends,
}

/// A person in the Who's where list.
class WhoPerson {
  const WhoPerson({
    required this.id,
    required this.name,
    this.me = false,
    this.friend = false,
    this.talking = false,
    this.links = const {},
    this.hops,
    this.lastHeard,
    this.known = false,
    this.feature = 0,
    this.battery,
  });
  final int id;
  final String name;

  /// Phone battery 0..100 when shared (v1.8.3).
  final int? battery;
  final bool me;
  final bool friend;
  final bool talking;
  final Set<TransportKind> links;

  /// Only through the phone mesh: radio hops.
  final int? hops;
  final Duration? lastHeard;

  /// In the people list (full person card available).
  final bool known;
  final int feature;
}

class WhoGroup {
  WhoGroup({
    required this.kind,
    this.channel,
    this.name,
    this.emoji,
    this.isPrivate = false,
    List<WhoPerson>? people,
  }) : people = people ?? [];
  final WhoGroupKind kind;

  /// Channel number: public groups and (for us only) our own channel.
  final int? channel;
  String? name;
  String? emoji;

  /// Our own channel is private.
  final bool isPrivate;
  final List<WhoPerson> people;

  bool get canJump => kind == WhoGroupKind.public && channel != null;
  int get count => people.where((p) => !p.me).length;

  /// "🔥 Family · CH 3", "CH 5", "Private groups", "Friends".
  String get title => switch (kind) {
    WhoGroupKind.private => 'Private groups',
    WhoGroupKind.friends => 'Friends',
    _ => [
      if ((emoji ?? '').isNotEmpty) emoji!,
      if ((name ?? '').isNotEmpty) '${name!} ·',
      'CH $channel',
    ].join(' '),
  };
}

/// A phone the TransportManager hears (people list).
class WhoSeen {
  const WhoSeen({
    required this.id,
    required this.name,
    required this.scope,
    this.links = const {},
    this.hops,
    this.lastHeard,
    this.talking = false,
    this.info = const {},
    this.feature = 0,
    this.battery,
  });
  final int id;
  final String name;
  final int? battery;

  /// Channel number, or a private scope (see TransportManager.scope).
  final int scope;
  final Set<TransportKind> links;
  final int? hops;
  final Duration? lastHeard;
  final bool talking;

  /// Hello extras (`cn` / `ce` channel name, `hw` = 0 hidden).
  final Map<String, Object?> info;
  final int feature;

  bool get hidden => info['hw'] == 0;
}

/// Group everyone this phone can see by channel.
///
/// Privacy: a private channel's number / name is only ever shown for our
/// own channel (we know it anyway). Everyone else on a private channel
/// goes into the one [WhoGroupKind.private] group with their call sign.
/// Phones that turned "Show me in Who's where" off (`hw` 0) are only
/// listed when they are on our own channel (as in the people list).
List<WhoGroup> buildWhosWhere({
  required int myId,
  required String myName,
  required int myChannel,
  required int myScope,
  required bool iAmPrivate,
  String? myChannelName,
  String? myChannelEmoji,
  List<WhoSeen> seen = const [],
  Iterable<LobbyEntry> lobby = const [],
  Map<int, String> friends = const {},
  Set<int> onlineFriends = const {},
  Map<int, ({String name, String emoji})> knownNames = const {},
  required DateTime now,
}) {
  final mine = WhoGroup(
    kind: WhoGroupKind.mine,
    channel: myChannel,
    name: myChannelName,
    emoji: myChannelEmoji,
    isPrivate: iAmPrivate,
    people: [WhoPerson(id: myId, name: myName, me: true)],
  );
  final public = <int, WhoGroup>{};
  final private = WhoGroup(kind: WhoGroupKind.private);
  final friendsGroup = WhoGroup(kind: WhoGroupKind.friends);
  final placed = <int>{myId};
  final lobbyById = {for (final e in lobby) e.id: e};

  WhoGroup pub(int ch) => public.putIfAbsent(
    ch,
    () => WhoGroup(kind: WhoGroupKind.public, channel: ch),
  );

  void nameGroup(WhoGroup g, String? cn, String? ce) {
    if (g.kind != WhoGroupKind.public) return;
    if ((g.name ?? '').isEmpty && cn != null && cn.isNotEmpty) g.name = cn;
    if ((g.emoji ?? '').isEmpty && ce != null && ce.isNotEmpty) g.emoji = ce;
  }

  for (final s in seen) {
    if (s.id == myId || placed.contains(s.id)) continue;
    final l = lobbyById[s.id];
    final links = {...s.links, ...?l?.liveLinks(now)};
    WhoGroup g;
    if (s.scope == myScope) {
      g = mine;
    } else if (TransportManager.isPrivateScope(s.scope)) {
      if (s.hidden) continue;
      g = private;
    } else {
      if (s.hidden) continue;
      g = pub(s.scope);
      final cn = s.info['cn'], ce = s.info['ce'];
      nameGroup(g, cn is String ? cn : null, ce is String ? ce : null);
    }
    placed.add(s.id);
    final isPriv = g.kind == WhoGroupKind.private;
    g.people.add(
      WhoPerson(
        id: s.id,
        name: friends[s.id] ?? s.name,
        friend: friends.containsKey(s.id),
        talking: s.talking && g.kind == WhoGroupKind.mine,
        links: links,
        hops: isPriv ? null : s.hops,
        lastHeard: s.lastHeard,
        known: true,
        feature: s.feature,
        battery: s.battery ?? l?.beacon.battery,
      ),
    );
  }

  for (final e in lobby) {
    if (placed.contains(e.id) || !e.alive(now)) continue;
    final b = e.beacon;
    WhoGroup g;
    final ch = b.channel;
    if (ch == null) {
      g = private;
    } else if (!iAmPrivate && ch == myChannel) {
      g = mine;
    } else {
      g = pub(ch);
      nameGroup(g, b.channelName, b.channelEmoji);
    }
    placed.add(e.id);
    g.people.add(
      WhoPerson(
        id: e.id,
        name: friends[e.id] ?? b.name,
        friend: friends.containsKey(e.id),
        links: e.liveLinks(now),
        hops: e.liveHops(now),
        lastHeard: now.difference(e.lastAt),
        feature: b.feature,
        battery: b.battery,
      ),
    );
  }

  for (final id in onlineFriends) {
    if (placed.contains(id) || !friends.containsKey(id)) continue;
    placed.add(id);
    friendsGroup.people.add(
      WhoPerson(id: id, name: friends[id]!, friend: true),
    );
  }

  for (final g in public.values) {
    final k = knownNames[g.channel];
    if (k != null) nameGroup(g, k.name, k.emoji);
  }

  int byPerson(WhoPerson a, WhoPerson b) {
    if (a.me != b.me) return a.me ? -1 : 1;
    if (a.friend != b.friend) return a.friend ? -1 : 1;
    if (a.talking != b.talking) return a.talking ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  final pubs = public.values.toList()
    ..sort((a, b) => a.channel!.compareTo(b.channel!));
  final out = [
    mine,
    ...pubs,
    if (private.people.isNotEmpty) private,
    if (friendsGroup.people.isNotEmpty) friendsGroup,
  ];
  for (final g in out) {
    g.people.sort(byPerson);
  }
  return out;
}

/// People not on our channel (the Talk screen badge).
int whosWhereElsewhere(List<WhoGroup> groups) => groups
    .where((g) => g.kind != WhoGroupKind.mine)
    .fold(0, (n, g) => n + g.count);

/// Everyone listed, not counting this phone.
int whosWhereTotal(List<WhoGroup> groups) =>
    groups.fold(0, (n, g) => n + g.count);
