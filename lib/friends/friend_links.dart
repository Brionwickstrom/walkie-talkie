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
  FriendInbound(this.friendId, this.frame, this.via);
  final int friendId;
  final Frame frame;
  final TransportKind via;
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
    DateTime Function()? clock,
    this.feature = featureLevel,
  }) : _name = localName,
       _clock = clock ?? DateTime.now;

  final int localId;
  final FriendRadio radio;

  /// Feature level announced in presence (tests simulate older apps).
  final int feature;
  final String Function() _name;

  /// Opens the friend's relay room (null = no internet path).
  final Transport Function(String room)? relayFactory;
  final DateTime Function() _clock;

  static const presenceInterval = Duration(seconds: 3);
  static const saverPresenceInterval = Duration(seconds: 6);
  static const onlineFor = Duration(seconds: 15);

  final Map<int, Friend> _friends = {};
  final Map<String, PairKey> _pending = {}; // key.encoded -> key
  final Set<String> _pairedSeen = {};
  final Map<String, Transport> _relays = {}; // room -> transport
  final Map<String, StreamSubscription<InboundFrame>> _relaySubs = {};
  final Map<int, Map<TransportKind, DateTime>> _seen = {};
  final Map<int, _Window> _dedupe = {};
  final Map<int, int> _feature = {};

  /// Feature level the friend's app announced (0 = not heard yet / old).
  int featureOf(int id) => _feature[id] ?? 0;

  /// The friend's app is too old for private talk (v1.5.4+ needed: older
  /// apps answer with their big button, which goes to the whole channel).
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

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(
      _saver ? saverPresenceInterval : presenceInterval,
      (_) => sendPresence(),
    );
  }

  void setFriends(List<Friend> list) {
    final ids = {for (final f in list) f.id};
    for (final id in _friends.keys.toList()) {
      if (!ids.contains(id)) {
        final f = _friends.remove(id)!;
        _closeRelay(f.key.room);
        _seen.remove(id);
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
    if (f == null || _relays.containsKey(k.room)) return;
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

  bool isOnline(int id) => bestLink(id) != null;

  /// Paths a friend was heard on recently, best first.
  List<TransportKind> linksTo(int id) {
    final m = _seen[id];
    if (m == null) return const [];
    final now = _clock();
    final l = [
      for (final e in m.entries)
        if (now.difference(e.value) <= onlineFor && _canUse(e.key, id)) e.key,
    ]..sort((a, b) => b.defaultPriority.compareTo(a.defaultPriority));
    return l;
  }

  TransportKind? bestLink(int id) {
    final l = linksTo(id);
    return l.isEmpty ? null : l.first;
  }

  DateTime? lastSeen(int id) {
    DateTime? last;
    for (final t in _seen[id]?.values ?? const <DateTime>[]) {
      if (last == null || t.isAfter(last)) last = t;
    }
    return last;
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
            x: {'v': feature},
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
  }

  int _nextSeq() => _seq = (_seq + 1) & 0x7FFF;
  int nextAudioSeq() => _audioSeq = ((_audioSeq + 1) & 0x7FFF) | 0x8000;

  /// Seal [inner] for [friendId] and send it over the best path (plus the
  /// next one while the best was not heard for a couple of seconds).
  Future<bool> send(int friendId, Frame inner) async {
    final f = _friends[friendId];
    if (f == null) return false;
    final links = linksTo(friendId);
    if (links.isEmpty) return false;
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
        _seen.putIfAbsent(f.senderId, () => {})[inb.transport] = _clock();
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
    final now = _clock();
    final m = _seen.putIfAbsent(f.senderId, () => {});
    final wasOnline = isOnline(f.senderId);
    m[inb.transport] = now;
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
      final n = msg.name;
      if (n != null && n.isNotEmpty && n != friend!.name) {
        friend.name = n;
        _emit();
      }
      if (!wasOnline) _emit();
      return true;
    }
    if (!wasOnline) _emit();
    if (!_inbound.isClosed) {
      _inbound.add(FriendInbound(f.senderId, inner, inb.transport));
    }
    return true;
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
