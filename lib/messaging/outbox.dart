import 'dart:typed_data';

import 'storage.dart';

/// A voice message waiting to be delivered (store-and-forward).
class OutboxEntry {
  OutboxEntry({
    required this.msgId,
    required this.toPeer,
    required this.channel,
    required this.createdAt,
    required this.durationMs,
    Set<int>? recipients,
    Set<int>? delivered,
  }) : recipients = recipients ?? (toPeer == null ? <int>{} : {toPeer}),
       delivered = delivered ?? <int>{};

  final int msgId;

  /// One person, or null for "everyone on [channel]".
  final int? toPeer;
  final int channel;
  final DateTime createdAt;
  final int durationMs;

  /// Who should get it. For channel messages: everyone on the channel when
  /// it was sent, or (if nobody was around) the first phones that show up.
  final Set<int> recipients;
  final Set<int> delivered;

  bool get isChannel => toPeer == null;
  String get blobName => 'out_$msgId.wtv';

  bool get done =>
      recipients.isNotEmpty && recipients.every(delivered.contains);

  /// Channel message nobody has received yet: keep adding phones that
  /// appear on the channel.
  bool get acceptsNewRecipients => isChannel && delivered.isEmpty;

  Iterable<int> get pending => recipients.where((r) => !delivered.contains(r));

  Map<String, Object?> toJson() => {
    'id': msgId,
    'to': toPeer,
    'ch': channel,
    'at': createdAt.millisecondsSinceEpoch,
    'dur': durationMs,
    'r': recipients.toList(),
    'd': delivered.toList(),
  };

  static OutboxEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return OutboxEntry(
        msgId: (j['id'] as num).toInt(),
        toPeer: (j['to'] as num?)?.toInt(),
        channel: (j['ch'] as num).toInt(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (j['at'] as num).toInt(),
        ),
        durationMs: (j['dur'] as num).toInt(),
        recipients: {for (final x in j['r'] as List) (x as num).toInt()},
        delivered: {for (final x in j['d'] as List) (x as num).toInt()},
      );
    } catch (_) {
      return null;
    }
  }
}

/// Persistent queue of outgoing voice messages. Entries expire after [ttl].
class Outbox {
  Outbox(this.storage, {this.ttl = const Duration(hours: 24)});

  static const indexName = 'outbox.json';
  final MessageStorage storage;
  final Duration ttl;
  final List<OutboxEntry> entries = [];

  Future<void> load() async {
    final j = await storage.readJson(indexName);
    entries.clear();
    if (j is List) {
      for (final e in j) {
        final o = OutboxEntry.fromJson(e);
        if (o != null) entries.add(o);
      }
    }
  }

  Future<void> save() =>
      storage.writeJson(indexName, [for (final e in entries) e.toJson()]);

  OutboxEntry? byId(int msgId) {
    for (final e in entries) {
      if (e.msgId == msgId) return e;
    }
    return null;
  }

  Future<void> add(OutboxEntry e, Uint8List body) async {
    await storage.putBlob(e.blobName, body);
    entries.add(e);
    await save();
  }

  /// Records a delivery; removes the entry when everyone has it. Returns
  /// true if this was new.
  Future<bool> markDelivered(int msgId, int peer) async {
    final e = byId(msgId);
    if (e == null || e.delivered.contains(peer)) return false;
    e.recipients.add(peer);
    e.delivered.add(peer);
    if (e.done) await _remove(e);
    await save();
    return true;
  }

  /// Add phones now seen on a channel message's channel (see
  /// [OutboxEntry.acceptsNewRecipients]).
  bool addRecipients(Set<int> Function(int channel) peersOn) {
    var changed = false;
    for (final e in entries) {
      if (!e.acceptsNewRecipients) continue;
      for (final p in peersOn(e.channel)) {
        if (e.recipients.add(p)) changed = true;
      }
    }
    return changed;
  }

  /// Drops entries older than [ttl]; returns them.
  Future<List<OutboxEntry>> expire(DateTime now) async {
    final old = [
      for (final e in entries)
        if (now.difference(e.createdAt) > ttl) e,
    ];
    for (final e in old) {
      await _remove(e);
    }
    if (old.isNotEmpty) await save();
    return old;
  }

  Future<void> cancel(int msgId) async {
    final e = byId(msgId);
    if (e == null) return;
    await _remove(e);
    await save();
  }

  Future<void> _remove(OutboxEntry e) async {
    entries.remove(e);
    await storage.deleteBlob(e.blobName);
  }
}
