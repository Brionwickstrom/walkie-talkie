import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/pair_key.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';

/// Someone added as a friend: their id, name and our shared pair key.
class Friend {
  Friend({
    required this.id,
    required this.name,
    required this.key,
    required this.added,
  });

  final int id;
  String name;
  final PairKey key;
  final DateTime added;

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    'k': key.encoded,
    'at': added.millisecondsSinceEpoch,
  };

  static Friend? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final k = PairKey.decode(j['k'] as String);
      if (k == null) return null;
      return Friend(
        id: (j['id'] as num).toInt(),
        name: j['n'] as String? ?? '',
        key: k,
        added: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }

  static String encodeList(List<Friend> l) =>
      jsonEncode([for (final f in l) f.toJson()]);

  static List<Friend> decodeList(String? s) {
    if (s == null || s.isEmpty) return [];
    try {
      return [for (final j in jsonDecode(s) as List) ?Friend.fromJson(j)];
    } catch (_) {
      return [];
    }
  }
}

/// A frame from a friend, already decrypted with the pair key.
class FriendInbound {
  FriendInbound(this.friendId, this.frame, this.via, {this.hops = 1});
  final int friendId;
  final Frame frame;
  final TransportKind via;

  /// > 1: carried by the phone mesh (other phones only saw ciphertext).
  final int hops;
}

/// How a friend is reached right now (v1.8.3).
enum FriendPathKind {
  /// A link of our own: Wi-Fi, Wi-Fi Direct, Bluetooth or the relay room.
  direct,

  /// Other app phones carry the sealed frames (phone mesh).
  mesh,

  /// The Meshtastic LoRa radio (slow, small packets).
  radio,
}

class FriendPath {
  const FriendPath(this.kind, this.link, {this.hops});
  final FriendPathKind kind;

  /// Transport used (mesh: the first hop's, radio: lora).
  final TransportKind link;

  /// Mesh hops when known.
  final int? hops;

  /// "Bluetooth", "phone mesh (2 hops)", "radio"...
  String get label => switch (kind) {
    FriendPathKind.mesh =>
      hops != null && hops! > 1 ? 'phone mesh ($hops hops)' : 'phone mesh',
    FriendPathKind.radio => 'radio',
    FriendPathKind.direct => switch (link) {
      TransportKind.lan => 'Wi-Fi',
      TransportKind.wifiDirect => 'Wi-Fi Direct',
      TransportKind.ble => 'Bluetooth',
      TransportKind.internet => 'Internet',
      TransportKind.lora => 'radio',
    },
  };

  @override
  bool operator ==(Object other) =>
      other is FriendPath &&
      other.kind == kind &&
      other.link == link &&
      other.hops == hops;
  @override
  int get hashCode => Object.hash(kind, link, hops);
}

/// What the friend chat header shows (see [FriendLinks.statusOf]).
class FriendLinkStatus {
  const FriendLinkStatus({this.path, this.lastPath, this.lastHeard});

  /// Usable right now (messages go out at once), or null.
  final FriendPath? path;

  /// Path of the last frame that opened with the pair key.
  final FriendPath? lastPath;
  final DateTime? lastHeard;

  bool get connected => path != null;
}

/// Direct chat header line for [s] (pure, for tests), in plain words:
///
///  * connected (any path: direct, phone mesh, radio):
///    "Connected to Sam · only you two can read this" (" · via radio, slow"
///    over LoRa);
///  * heard within [FriendLinks.recentFor] but not connected: the link is
///    coming back: "Reconnecting to Sam · only you two can read this";
///  * otherwise out of reach (also when never connected):
///    "Sam is out of reach (last heard 3 h ago) · your messages will send
///    when they're back (up to 24 h)".
String friendStatusLineFor(
  FriendLinkStatus s,
  DateTime now, {
  String name = 'Your friend',
}) {
  final p = s.path;
  if (p != null) {
    final slow = p.kind == FriendPathKind.radio ? ' · via radio, slow' : '';
    return 'Connected to $name · only you two can read this$slow';
  }
  final last = s.lastHeard;
  final lp = s.lastPath;
  const wait = "your messages will send when they're back (up to 24 h)";
  if (last != null && lp != null) {
    final ago = now.difference(last);
    if (ago <= FriendLinks.recentFor) {
      return 'Reconnecting to $name · only you two can read this';
    }
    return '$name is out of reach (last heard ${_ago(ago)} ago) · $wait';
  }
  return '$name is out of reach · $wait';
}

String _ago(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds < 1 ? 1 : d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} days';
}

/// How [FriendLinks] reaches the nearby radios (LAN / Bluetooth) the
/// channel traffic also uses.
abstract class FriendRadio {
  /// Send to everyone in range on LAN and Bluetooth.
  Future<void> broadcast(Uint8List bytes);
  Future<void> sendOn(TransportKind kind, Uint8List bytes, int peer);
  bool canReach(TransportKind kind, int peer);
}

class ManagerFriendRadio implements FriendRadio {
  ManagerFriendRadio(this.m);
  final TransportManager m;

  @override
  Future<void> broadcast(Uint8List bytes) async {
    await m.sendRaw(TransportKind.lan, bytes, null);
    await m.sendRaw(TransportKind.ble, bytes, null);
  }

  @override
  Future<void> sendOn(TransportKind kind, Uint8List bytes, int peer) =>
      m.sendRaw(kind, bytes, {peer});

  @override
  bool canReach(TransportKind kind, int peer) => m.canReachOn(kind, peer);
}

/// Slower ways to a friend (v1.8.3): the phone mesh and the LoRa radio.
/// Every frame handed over is already sealed with the pair key.
abstract class FriendFarPaths {
  bool get hasMeshNeighbours;

  /// The channel layer sees [peer] through the phone mesh.
  bool meshReachable(int peer);
  bool sendMesh(Uint8List bytes, int peer);

  /// [peer]'s phone was heard over the LoRa radio recently.
  bool radioReachable(int peer);

  /// Queue [bytes] (sealed [inner]) on the radio; false if [inner] may not
  /// go over LoRa (live audio, presence...) or does not fit.
  bool sendRadio(Frame inner, Uint8List bytes, int peer);

  /// [peer]'s phone is still heard on [kind] by the channel layer.
  bool heardOn(TransportKind kind, int peer);
}

class ManagerFriendFarPaths implements FriendFarPaths {
  ManagerFriendFarPaths(this.m);
  final TransportManager m;

  @override
  bool get hasMeshNeighbours => m.hasMeshNeighbours;
  @override
  bool meshReachable(int peer) => m.meshReachable(peer);
  @override
  bool sendMesh(Uint8List bytes, int peer) => m.sendSealedMesh(bytes, peer);
  @override
  bool radioReachable(int peer) => m.canReachOn(TransportKind.lora, peer);
  @override
  bool sendRadio(Frame inner, Uint8List bytes, int peer) =>
      m.sendSealedRadio(inner, bytes, peer);
  @override
  bool heardOn(TransportKind kind, int peer) => m.heardOn(kind, peer);
}

/// Private 1:1 links to friends, independent of the channel you are on.
///
/// * Every frame is sealed with the pair key (AES-256-GCM); only the two
///   friends can open it. Over Wi-Fi / Bluetooth it shares the radios with
///   channel traffic (other phones drop it, its tag means nothing to them).
///   Over the internet both friends join their own relay room, named from
///   a hash of the pair key.
/// * Friends send a sealed "fhello" every [presenceInterval]; a friend is
///   online while one was heard in the last [onlineFor].
/// * QR pairing: the phone showing the QR waits with a pending key; the
///   first fhello that opens with it reveals who scanned it ([paired]).
class FriendLinks {
  FriendLinks({
    required this.localId,
    required this.radio,
    required String Function() localName,
    this.relayFactory,
    this.far,
    DateTime Function()? clock,
    this.feature = featureLevel,
  }) : _name = localName,
       _clock = clock ?? DateTime.now;

  final int localId;
  final FriendRadio radio;

  /// Phone mesh + LoRa radio (null = direct links and relay rooms only).
  final FriendFarPaths? far;

  /// Feature level announced in presence (tests simulate older apps).
  final int feature;
  final String Function() _name;

  /// Opens the friend's relay room (null = no internet path).
  final Transport Function(String room)? relayFactory;
  final DateTime Function() _clock;

  static const presenceInterval = Duration(seconds: 3);
  static const saverPresenceInterval = Duration(seconds: 6);
  static const onlineFor = Duration(seconds: 15);

  /// A direct link the friend's phone is still heard on (its channel
  /// hellos) keeps counting this long after the last sealed frame on it,
  /// so a couple of lost presence beacons do not flip the status.
  static const trustFor = Duration(seconds: 60);

  /// Sealed frames relayed by the phone mesh keep the mesh path this long.
  static const meshFor = Duration(seconds: 30);

  /// Heard this recently over a path that is gone now: the header still
  /// says connected (reconnecting).
  static const recentFor = Duration(minutes: 2);

  final Map<int, Friend> _friends = {};
  final Map<String, PairKey> _pending = {}; // key.encoded -> key
  final Set<String> _pairedSeen = {};
  final Map<String, Transport> _relays = {}; // room -> transport
  final Map<String, StreamSubscription<InboundFrame>> _relaySubs = {};
  final Map<int, Map<TransportKind, DateTime>> _seen = {};
  final Map<int, (DateTime, int)> _meshSeen = {}; // id -> (when, hops)
  final Map<int, (DateTime, FriendPath)> _lastHeard = {};
  final Map<int, FriendPath?> _lastPathShown = {};
  final Map<int, _Window> _dedupe = {};
  final Map<int, int> _feature = {};

  /// Feature level the friend's app announced (0 = not heard yet / old).
  int featureOf(int id) => _feature[id] ?? 0;

  /// The friend's app is too old for private talk (v1.5.4+ needed: older
  /// apps answer with their big button, which goes to the whole channel).
  /// This device's weather key id, sent to friends in their presence
  /// (null = none yet). Sealed with the pair key, so only that friend reads it.
  String? Function()? wxKeyId;

  /// A friend told us their weather key id (v2.5.2).
  void Function(int friendId, String keyId)? onWxKey;

  bool needsUpdate(int id) => featureOf(id) < privateTalkFeature;
  final _inbound = StreamController<FriendInbound>.broadcast();
  final _paired = StreamController<(int, String, PairKey)>.broadcast();
  final _changes = StreamController<void>.broadcast();
  Timer? _timer;
  bool _saver = false;
  bool _running = false;
  // Random starts: a restarted phone must not reuse sequence numbers the
  // friend still remembers (they would be dropped as duplicates).
  int _seq = Random().nextInt(0x7FFF);
  int _audioSeq = 0x8000 | Random().nextInt(0x7FFF);

  Stream<FriendInbound> get inbound => _inbound.stream;

  /// Someone scanned our QR: (their id, name, the key).
  Stream<(int, String, PairKey)> get paired => _paired.stream;

  /// Online status changed.
  Stream<void> get changes => _changes.stream;

  List<Friend> get friends =>
      _friends.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  Friend? friend(int id) => _friends[id];
  bool isFriend(int id) => _friends.containsKey(id);

  void start() {
    if (_running) return;
    _running = true;
    _restartTimer();
    for (final f in _friends.values) {
      _openRelay(f.key);
    }
    for (final k in _pending.values) {
      _openRelay(k);
    }
  }

  void setPowerSaver(bool on) {
    _saver = on;
    if (_running) _restartTimer();
  }

  /// Offline power save: friend relay rooms closed (no internet sockets),
  /// presence every [offlinePresenceInterval] over the nearby links.
  static const offlinePresenceInterval = Duration(seconds: 7);
  bool _offline = false;
  bool get offlineSaver => _offline;

  /// Friend relay rooms open right now (tests / debug).
  int get openRelays => _relays.length;

  void setOfflineSaver(bool on) {
    if (on == _offline) return;
    _offline = on;
    if (on) {
      for (final r in _relays.keys.toList()) {
        _closeRelay(r);
      }
    } else if (_running) {
      for (final f in _friends.values) {
        _openRelay(f.key);
      }
      for (final k in _pending.values) {
        _openRelay(k);
      }
    }
    if (_running) _restartTimer();
  }

  Duration get currentPresenceInterval => _offline
      ? offlinePresenceInterval
      : ((_saver || _idle) ? saverPresenceInterval : presenceInterval);

  /// v2.0.0: the app is idle (background, nothing going on): presence
  /// every 6 s instead of 3 s (friends stay online for 15 s). Busy again:
  /// back to 3 s and a presence beacon right now.
  bool get idle => _idle;
  bool _idle = false;

  void setIdle(bool idle) {
    if (idle == _idle) return;
    _idle = idle;
    if (_running) {
      _restartTimer();
      if (!idle) unawaited(sendPresence());
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(currentPresenceInterval, (_) => sendPresence());
  }

  void setFriends(List<Friend> list) {
    final ids = {for (final f in list) f.id};
    for (final id in _friends.keys.toList()) {
      if (!ids.contains(id)) {
        final f = _friends.remove(id)!;
        _closeRelay(f.key.room);
        _seen.remove(id);
        _meshSeen.remove(id);
        _lastHeard.remove(id);
        _lastPathShown.remove(id);
      }
    }
    for (final f in list) {
      final old = _friends[f.id];
      _friends[f.id] = f;
      if (old == null || old.key.room != f.key.room) {
        if (old != null) _closeRelay(old.key.room);
        if (_running) _openRelay(f.key);
      }
    }
    _emit();
  }

  /// Wait for whoever scans our QR (see [PairKey.fromQrCode]).
  void addPending(PairKey k) {
    _pending[k.encoded] = k;
    if (_running) _openRelay(k);
  }

  void removePending(PairKey k) {
    if (_pending.remove(k.encoded) != null &&
        !_friends.values.any((f) => f.key.room == k.room)) {
      _closeRelay(k.room);
    }
  }

  void _openRelay(PairKey k) {
    final f = relayFactory;
    if (f == null || _offline || _relays.containsKey(k.room)) return;
    final t = f(k.room);
    _relays[k.room] = t;
    _relaySubs[k.room] = t.frames.listen(handle);
    unawaited(t.start(localNodeId: localId, channel: 0).catchError((_) {}));
  }

  void _closeRelay(String room) {
    _relaySubs.remove(room)?.cancel();
    final t = _relays.remove(room);
    if (t != null) unawaited(t.stop().catchError((_) {}));
  }

  // ------------------------------------------------------------ presence

  /// Reachable now over any path (direct, phone mesh or radio).
  bool isOnline(int id) => pathTo(id) != null;

  /// Direct links (Wi-Fi, Wi-Fi Direct, Bluetooth, relay room) a friend
  /// was heard on recently, best first. Never the radio.
  List<TransportKind> linksTo(int id) {
    final m = _seen[id];
    if (m == null) return const [];
    final now = _clock();
    final l = [
      for (final e in m.entries)
        if (e.key != TransportKind.lora &&
            _canUse(e.key, id) &&
            (now.difference(e.value) <= onlineFor ||
                (now.difference(e.value) <= trustFor &&
                    e.key != TransportKind.internet &&
                    (far?.heardOn(e.key, id) ?? false))))
          e.key,
    ]..sort((a, b) => b.defaultPriority.compareTo(a.defaultPriority));
    return l;
  }

  /// The phone mesh carries our sealed frames to [id] (they were heard
  /// relayed lately, or the channel layer sees them through the mesh).
  bool meshPathTo(int id) {
    final f = far;
    if (f == null || !f.hasMeshNeighbours) return false;
    final m = _meshSeen[id];
    if (m != null && _clock().difference(m.$1) <= meshFor) return true;
    return f.meshReachable(id);
  }

  /// The LoRa radio reaches [id]'s phone.
  bool radioPathTo(int id) => far?.radioReachable(id) ?? false;

  /// Best way to [id] right now: direct, else phone mesh, else radio.
  FriendPath? pathTo(int id) {
    final l = linksTo(id);
    if (l.isNotEmpty) return FriendPath(FriendPathKind.direct, l.first);
    if (meshPathTo(id)) {
      return FriendPath(
        FriendPathKind.mesh,
        TransportKind.ble,
        hops: _meshSeen[id]?.$2,
      );
    }
    if (radioPathTo(id)) {
      return const FriendPath(FriendPathKind.radio, TransportKind.lora);
    }
    return null;
  }

  /// Link kind for pacing (the [Messenger]): the direct link, Bluetooth
  /// for the phone mesh (slowest off-grid pacing), lora for the radio.
  TransportKind? bestLink(int id) => pathTo(id)?.link;

  /// Live private talk needs a direct link or the phone mesh (never LoRa).
  bool canTalkLive(int id) {
    final p = pathTo(id);
    return p != null && p.kind != FriendPathKind.radio;
  }

  DateTime? lastSeen(int id) {
    DateTime? last;
    for (final t in _seen[id]?.values ?? const <DateTime>[]) {
      if (last == null || t.isAfter(last)) last = t;
    }
    final m = _meshSeen[id]?.$1;
    if (m != null && (last == null || m.isAfter(last))) last = m;
    return last;
  }

  /// For the chat header ([friendStatusLineFor]).
  FriendLinkStatus statusOf(int id) {
    final h = _lastHeard[id];
    return FriendLinkStatus(
      path: pathTo(id),
      lastPath: h?.$2,
      lastHeard: h?.$1,
    );
  }

  /// Emit [changes] when a friend's path changed (e.g. timed out) since
  /// the last check; runs with every presence tick (public for tests).
  bool checkPaths() {
    var changed = false;
    for (final id in _friends.keys) {
      final p = pathTo(id);
      if (!_lastPathShown.containsKey(id) || _lastPathShown[id] != p) {
        _lastPathShown[id] = p;
        changed = true;
      }
    }
    if (changed) _emit();
    return changed;
  }

  bool _canUse(TransportKind k, int id) {
    if (k == TransportKind.internet) {
      final f = _friends[id];
      final t = f == null ? null : _relays[f.key.room];
      return t != null && t.status == TransportStatus.running;
    }
    return radio.canReach(k, id);
  }

  Future<void> sendPresence() async {
    final wasOnline = {for (final id in _friends.keys) id: isOnline(id)};
    final keys = <PairKey>[
      for (final f in _friends.values) f.key,
      ..._pending.values,
    ];
    for (final k in keys) {
      final bytes = k.seal(
        Frame.control(
          senderId: localId,
          channel: 0,
          seq: _nextSeq(),
          message: ControlMessage(
            ControlKind.fhello,
            name: _name(),
            x: {'v': feature, 'wk': ?wxKeyId?.call()},
          ),
        ),
      );
      await radio.broadcast(bytes);
      final t = _relays[k.room];
      if (t != null && t.status == TransportStatus.running) {
        try {
          await t.send(bytes);
        } catch (_) {}
      }
    }
    if (wasOnline.entries.any((e) => isOnline(e.key) != e.value)) _emit();
    checkPaths();
  }

  int _nextSeq() => _seq = (_seq + 1) & 0x7FFF;
  int nextAudioSeq() => _audioSeq = ((_audioSeq + 1) & 0x7FFF) | 0x8000;

  /// Seal [inner] for [friendId] and send it over the best path (plus the
  /// next one while the best was not heard for a couple of seconds). With
  /// no direct link: through the phone mesh, else over the LoRa radio
  /// (only what the radio may carry: chat / voice-message data, rings).
  /// Every path only ever carries the sealed bytes.
  Future<bool> send(int friendId, Frame inner) async {
    final f = _friends[friendId];
    if (f == null) return false;
    final links = linksTo(friendId);
    if (links.isEmpty) {
      final fp = far;
      if (fp == null) return false;
      if (meshPathTo(friendId)) {
        if (fp.sendMesh(f.key.seal(inner), friendId)) return true;
      }
      if (radioPathTo(friendId)) {
        return fp.sendRadio(inner, f.key.seal(inner), friendId);
      }
      return false;
    }
    final bytes = f.key.seal(inner);
    final now = _clock();
    final best = links.first;
    final route = [best];
    final seen = _seen[friendId]?[best];
    if (links.length > 1 &&
        seen != null &&
        now.difference(seen) > const Duration(milliseconds: 2500)) {
      route.add(links[1]);
    }
    for (final k in route) {
      if (k == TransportKind.internet) {
        try {
          await _relays[f.key.room]?.send(bytes);
        } catch (_) {}
      } else {
        await radio.sendOn(k, bytes, friendId);
      }
    }
    return true;
  }

  Frame frame(FrameType type, Uint8List payload, {int? seq}) => Frame(
    type: type,
    senderId: localId,
    channel: 0,
    seq: seq ?? _nextSeq(),
    payload: payload,
  );

  Future<bool> sendControl(int friendId, ControlMessage m) => send(
    friendId,
    Frame.control(senderId: localId, channel: 0, seq: _nextSeq(), message: m),
  );

  // ------------------------------------------------------------- receive

  /// A sealed frame from any transport. Returns true if it was for us.
  bool handle(InboundFrame inb) {
    final f = inb.frame;
    if (f.type != FrameType.sealed || f.senderId == localId) return false;
    final friend = _friends[f.senderId];
    Frame? inner;
    if (friend != null && friend.key.tag == f.channel) {
      inner = friend.key.open(f);
    }
    if (inner == null) {
      for (final k in _pending.values) {
        if (k.tag != f.channel) continue;
        final o = k.open(f);
        if (o == null) continue;
        final msg = o.control;
        // They have the key: count them as heard, so private talk works
        // right away in both directions once the friend is added here.
        _heard(f.senderId, inb);
        if (msg?.kind == ControlKind.fhello) {
          _feature[f.senderId] = (msg!.x['v'] as num?)?.toInt() ?? 0;
        }
        if (msg?.kind == ControlKind.fhello &&
            !_friends.containsKey(f.senderId) &&
            _pairedSeen.add('${k.encoded}/${f.senderId}')) {
          if (!_paired.isClosed) {
            _paired.add((f.senderId, msg!.name ?? '', k));
          }
        }
        return true;
      }
      return false;
    }
    final wasOnline = isOnline(f.senderId);
    _heard(f.senderId, inb);
    if (!_dedupe.putIfAbsent(f.senderId, _Window.new).add(inner.seq)) {
      return true;
    }
    final msg = inner.control;
    if (msg != null && msg.kind == ControlKind.fhello) {
      final v = (msg.x['v'] as num?)?.toInt() ?? 0;
      if (_feature[f.senderId] != v) {
        _feature[f.senderId] = v;
        _emit();
      }
      // The friend's weather signing key id (v2.5.2), sealed with the pair
      // key: it is really theirs, so it can be shown on their card.
      final wk = msg.x['wk'];
      if (wk is String && RegExp(r'^[0-9a-f]{20}$').hasMatch(wk)) {
        onWxKey?.call(f.senderId, wk);
      }
      final n = msg.name;
      if (n != null && n.isNotEmpty && n != friend!.name) {
        friend.name = n;
        _emit();
      }
      if (!wasOnline) _emit();
      checkPaths();
      return true;
    }
    if (!wasOnline) _emit();
    checkPaths();
    if (!_inbound.isClosed) {
      _inbound.add(
        FriendInbound(f.senderId, inner, inb.transport, hops: inb.hops),
      );
    }
    return true;
  }

  /// A frame that opened with the pair key arrived: remember the path.
  /// Mesh-relayed copies (hops > 1) never count as a direct link.
  void _heard(int id, InboundFrame inb) {
    final now = _clock();
    final FriendPath path;
    if (inb.hops > 1) {
      _meshSeen[id] = (now, inb.hops);
      path = FriendPath(FriendPathKind.mesh, inb.transport, hops: inb.hops);
    } else {
      _seen.putIfAbsent(id, () => {})[inb.transport] = now;
      path = inb.transport == TransportKind.lora
          ? const FriendPath(FriendPathKind.radio, TransportKind.lora)
          : FriendPath(FriendPathKind.direct, inb.transport);
    }
    _lastHeard[id] = (now, path);
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    for (final r in _relays.keys.toList()) {
      _closeRelay(r);
    }
    await _inbound.close();
    await _paired.close();
    await _changes.close();
  }
}

class _Window {
  final _order = Queue<int>();
  final _set = <int>{};
  bool add(int seq) {
    if (_set.contains(seq)) return false;
    _set.add(seq);
    _order.addLast(seq);
    if (_order.length > 256) _set.remove(_order.removeFirst());
    return true;
  }
}
