import 'storage.dart';

/// A voice message of ours that reached someone (v2.4.0): who, when, how
/// long, and whether they listened. No audio is kept, only this line, so
/// "Sent" in Messages costs a few bytes.
class SentRecord {
  SentRecord({
    required this.msgId,
    required this.toPeer,
    required this.channel,
    required this.createdAt,
    required this.durationMs,
    required this.deliveredAt,
    Set<int>? peers,
    Set<int>? heardBy,
  }) : peers = peers ?? <int>{},
       heardBy = heardBy ?? <int>{};

  final int msgId;

  /// One person, or null for "everyone on [channel]".
  final int? toPeer;
  final int channel;
  final DateTime createdAt;
  final int durationMs;
  DateTime deliveredAt;

  /// Phones that have it / that played it.
  final Set<int> peers;
  final Set<int> heardBy;

  bool get isChannel => toPeer == null;
  bool get heard => heardBy.isNotEmpty;

  Map<String, Object?> toJson() => {
    'id': msgId,
    'to': toPeer,
    'ch': channel,
    'at': createdAt.millisecondsSinceEpoch,
    'dur': durationMs,
    'da': deliveredAt.millisecondsSinceEpoch,
    'p': peers.toList(),
    if (heardBy.isNotEmpty) 'h': heardBy.toList(),
  };

  static SentRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return SentRecord(
        msgId: (j['id'] as num).toInt(),
        toPeer: (j['to'] as num?)?.toInt(),
        channel: (j['ch'] as num).toInt(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (j['at'] as num).toInt(),
        ),
        durationMs: (j['dur'] as num).toInt(),
        deliveredAt: DateTime.fromMillisecondsSinceEpoch(
          (j['da'] as num).toInt(),
        ),
        peers: {for (final x in (j['p'] as List)) (x as num).toInt()},
        heardBy: {
          for (final x in (j['h'] as List?) ?? const []) (x as num).toInt(),
        },
      );
    } catch (_) {
      return null;
    }
  }
}

/// The last few delivered voice messages (newest first), kept for a day.
/// Written only when something is delivered or listened to: no timers.
class SentLog {
  SentLog(
    this.storage, {
    this.maxEntries = 30,
    this.maxAge = const Duration(hours: 24),
  });

  static const indexName = 'sent.json';
  final MessageStorage storage;
  final int maxEntries;
  final Duration maxAge;
  final List<SentRecord> entries = [];

  Future<void> load([DateTime? now]) async {
    final j = await storage.readJson(indexName);
    entries.clear();
    if (j is List) {
      for (final e in j) {
        final r = SentRecord.fromJson(e);
        if (r != null) entries.add(r);
      }
    }
    _trim(now ?? DateTime.now());
  }

  Future<void> save() =>
      storage.writeJson(indexName, [for (final e in entries) e.toJson()]);

  SentRecord? byId(int msgId) {
    for (final e in entries) {
      if (e.msgId == msgId) return e;
    }
    return null;
  }

  /// [peer] has message [e]. One record per message (a channel message may
  /// reach several phones).
  Future<void> delivered({
    required int msgId,
    required int? toPeer,
    required int channel,
    required DateTime createdAt,
    required int durationMs,
    required int peer,
    required DateTime now,
  }) async {
    var r = byId(msgId);
    if (r == null) {
      r = SentRecord(
        msgId: msgId,
        toPeer: toPeer,
        channel: channel,
        createdAt: createdAt,
        durationMs: durationMs,
        deliveredAt: now,
      );
      entries.insert(0, r);
    }
    r.peers.add(peer);
    r.deliveredAt = now;
    _trim(now);
    await save();
  }

  /// [peer] played message [msgId].
  Future<bool> heard(int msgId, int peer) async {
    final r = byId(msgId);
    if (r == null || !r.heardBy.add(peer)) return false;
    await save();
    return true;
  }

  Future<void> remove(int msgId) async {
    final r = byId(msgId);
    if (r == null) return;
    entries.remove(r);
    await save();
  }

  Future<void> clear() async {
    if (entries.isEmpty) return;
    entries.clear();
    await save();
  }

  void _trim(DateTime now) {
    entries.removeWhere((e) => now.difference(e.deliveredAt) > maxAge);
    if (entries.length > maxEntries) {
      entries.removeRange(maxEntries, entries.length);
    }
  }
}
