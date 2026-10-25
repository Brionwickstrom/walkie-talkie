import 'dart:async';
import 'dart:typed_data';

import '../messaging/storage.dart';
import '../messaging/voice_clip.dart';

/// One recorded push-to-talk transmission (someone else's or our own).
class TalkTake {
  TalkTake({
    required this.id,
    required this.scope,
    required this.sender,
    required this.name,
    required this.start,
    required this.durationMs,
    required this.bytes,
    this.mine = false,
    this.heard = false,
  });

  final int id;

  /// Channel number, or a private-channel scope (see TransportManager).
  final int scope;
  final int sender;
  final String name;
  final DateTime start;
  final int durationMs;
  final int bytes;
  final bool mine;

  /// Played live with the app open, or replayed since.
  bool heard;

  String get blobName => 'h_$id.wtv';

  Map<String, Object?> toJson() => {
    'id': id,
    'sc': scope,
    's': sender,
    'n': name,
    'at': start.millisecondsSinceEpoch,
    'dur': durationMs,
    'b': bytes,
    if (mine) 'me': true,
    if (heard) 'h': true,
  };

  static TalkTake? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return TalkTake(
        id: (j['id'] as num).toInt(),
        scope: (j['sc'] as num).toInt(),
        sender: (j['s'] as num).toInt(),
        name: j['n'] as String? ?? '',
        start: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
        durationMs: (j['dur'] as num).toInt(),
        bytes: (j['b'] as num?)?.toInt() ?? 0,
        mine: j['me'] == true,
        heard: j['h'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

class _OpenTake {
  _OpenTake(
    this.scope,
    this.sender,
    this.name,
    this.start,
    this.heard,
    this.mine,
  );
  final int scope;
  final int sender;
  String name;
  final DateTime start;
  bool heard;
  final bool mine;
  final List<Uint8List> packets = [];
  DateTime last = DateTime.now();
}

/// "Replay missed talk": keeps the last [maxPerScope] transmissions per
/// channel (and nothing older than [maxAge], at most [maxBytes] in total)
/// as Opus packets on the device. Private channels are kept under their own
/// scope, so they only show while you are on that private channel.
class TalkHistory {
  TalkHistory({
    required this.storage,
    DateTime Function()? clock,
    this.maxPerScope = 50,
    this.maxAge = const Duration(hours: 24),
    this.maxBytes = 20 * 1024 * 1024,
    this.idleClose = const Duration(milliseconds: 1500),
    this.maxTake = const Duration(minutes: 5),
    this.minTake = const Duration(milliseconds: 400),
  }) : _clock = clock ?? DateTime.now;

  final MessageStorage storage;
  final DateTime Function() _clock;
  final int maxPerScope;
  final Duration maxAge;
  final int maxBytes;

  /// A transmission ends at talk-end, or after this much silence.
  final Duration idleClose;
  final Duration maxTake;

  /// Shorter blips (accidental taps) are not kept.
  final Duration minTake;

  static const _index = 'history.json';
  final List<TalkTake> _takes = [];
  final Map<int, _OpenTake> _open = {};
  final _changes = StreamController<void>.broadcast();
  int _lastId = 0;
  Future<void> _saving = Future.value();

  Stream<void> get changes => _changes.stream;

  Future<void> load() async {
    final j = await storage.readJson(_index);
    if (j is List) {
      for (final e in j) {
        final t = TalkTake.fromJson(e);
        if (t != null) _takes.add(t);
      }
    }
    await _prune();
  }

  /// Newest first.
  List<TalkTake> takesFor(int scope) =>
      _takes.where((t) => t.scope == scope).toList()
        ..sort((a, b) => b.start.compareTo(a.start));

  int unheardIn(int scope) =>
      _takes.where((t) => t.scope == scope && !t.heard).length;

  /// Someone (or we, with [mine]) is talking on [scope]. [heard]: it is
  /// being played live with the app open.
  void addPacket({
    required int scope,
    required int sender,
    required String name,
    required Uint8List opus,
    bool heard = false,
    bool mine = false,
  }) {
    final now = _clock();
    var t = _open[sender];
    if (t != null && (t.scope != scope || now.difference(t.start) > maxTake)) {
      endTake(sender);
      t = null;
    }
    t ??= _open[sender] = _OpenTake(scope, sender, name, now, heard, mine);
    if (!heard) t.heard = false;
    if (name.isNotEmpty) t.name = name;
    t.packets.add(opus);
    t.last = now;
  }

  bool isRecording(int sender) => _open.containsKey(sender);

  /// Close [sender]'s current transmission (talk end).
  void endTake(int sender) {
    final t = _open.remove(sender);
    if (t == null) return;
    final dur = t.packets.length * VoiceClip.frameMs;
    if (dur < minTake.inMilliseconds) return;
    var id = t.start.millisecondsSinceEpoch;
    if (id <= _lastId) id = _lastId + 1;
    _lastId = id;
    final body = VoiceClip(
      t.packets.length > 0xFFFF ? t.packets.sublist(0, 0xFFFF) : t.packets,
    ).encode();
    final take = TalkTake(
      id: id,
      scope: t.scope,
      sender: t.sender,
      name: t.name,
      start: t.start,
      durationMs: dur,
      bytes: body.length,
      mine: t.mine,
      heard: t.mine || t.heard,
    );
    _takes.add(take);
    _save(() async {
      // Skip if it was already pruned / deleted before this ran.
      if (_takes.contains(take)) await storage.putBlob(take.blobName, body);
      await _prune();
    });
    _emit();
  }

  /// Close transmissions that went quiet (talk-end lost). Call ~1/s.
  void tick() {
    final now = _clock();
    for (final e in _open.entries.toList()) {
      if (now.difference(e.value.last) > idleClose) endTake(e.key);
    }
  }

  Future<List<Uint8List>?> packetsOf(TalkTake t) async {
    final b = await storage.getBlob(t.blobName);
    return b == null ? null : VoiceClip.tryDecode(b)?.packets;
  }

  void markHeard(TalkTake t) {
    if (t.heard) return;
    t.heard = true;
    _save(_writeIndex);
    _emit();
  }

  void markAllHeard(int scope) {
    var any = false;
    for (final t in _takes) {
      if (t.scope == scope && !t.heard) {
        t.heard = true;
        any = true;
      }
    }
    if (!any) return;
    _save(_writeIndex);
    _emit();
  }

  Future<void> delete(TalkTake t) async {
    _takes.remove(t);
    _save(() async {
      await storage.deleteBlob(t.blobName);
      await _writeIndex();
    });
    _emit();
    await _saving;
  }

  Future<void> clear(int scope) async {
    final gone = _takes.where((t) => t.scope == scope).toList();
    _takes.removeWhere((t) => t.scope == scope);
    _save(() async {
      for (final t in gone) {
        await storage.deleteBlob(t.blobName);
      }
      await _writeIndex();
    });
    _emit();
    await _saving;
  }

  /// Waits for pending writes (tests).
  Future<void> flush() => _saving;

  Future<void> _prune() async {
    final now = _clock();
    final drop = <TalkTake>{};
    for (final t in _takes) {
      if (now.difference(t.start) > maxAge) drop.add(t);
    }
    final byScope = <int, List<TalkTake>>{};
    for (final t in _takes) {
      if (!drop.contains(t)) byScope.putIfAbsent(t.scope, () => []).add(t);
    }
    for (final l in byScope.values) {
      l.sort((a, b) => b.start.compareTo(a.start));
      drop.addAll(l.skip(maxPerScope));
    }
    final rest = _takes.where((t) => !drop.contains(t)).toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    var total = 0;
    for (final t in rest) {
      total += t.bytes;
      if (total > maxBytes) drop.add(t);
    }
    if (drop.isNotEmpty) {
      _takes.removeWhere(drop.contains);
      for (final t in drop) {
        await storage.deleteBlob(t.blobName);
      }
      _emit();
    }
    await _writeIndex();
  }

  Future<void> _writeIndex() =>
      storage.writeJson(_index, [for (final t in _takes) t.toJson()]);

  void _save(Future<void> Function() f) {
    _saving = _saving.then((_) => f()).catchError((_) {});
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await _saving;
    await _changes.close();
  }
}
