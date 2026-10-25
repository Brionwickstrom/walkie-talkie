import 'dart:typed_data';

import 'storage.dart';

/// A received voice message.
class InboxEntry {
  InboxEntry({
    required this.sender,
    required this.msgId,
    required this.senderName,
    required this.channel,
    required this.channelMessage,
    required this.receivedAt,
    required this.durationMs,
    this.played = false,
  });

  final int sender;
  final int msgId;
  final String senderName;
  final int channel;
  final bool channelMessage;
  final DateTime receivedAt;
  final int durationMs;
  bool played;

  String get key => '${sender}_$msgId';
  String get blobName => 'in_$key.wtv';

  /// Stable small int for notification ids.
  int get notificationId => (sender * 31 + msgId) & 0x3FFFFFFF;

  Map<String, Object?> toJson() => {
    's': sender,
    'id': msgId,
    'n': senderName,
    'ch': channel,
    'cm': channelMessage,
    'at': receivedAt.millisecondsSinceEpoch,
    'dur': durationMs,
    'p': played,
  };

  static InboxEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return InboxEntry(
        sender: (j['s'] as num).toInt(),
        msgId: (j['id'] as num).toInt(),
        senderName: j['n'] as String,
        channel: (j['ch'] as num).toInt(),
        channelMessage: j['cm'] == true,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          (j['at'] as num).toInt(),
        ),
        durationMs: (j['dur'] as num).toInt(),
        played: j['p'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Received voice messages, newest first. Keeps at most [maxEntries].
class Inbox {
  Inbox(this.storage, {this.maxEntries = 100});

  static const indexName = 'inbox.json';
  final MessageStorage storage;
  final int maxEntries;
  final List<InboxEntry> entries = [];

  int get unplayed => entries.where((e) => !e.played).length;

  Future<void> load() async {
    final j = await storage.readJson(indexName);
    entries.clear();
    if (j is List) {
      for (final e in j) {
        final x = InboxEntry.fromJson(e);
        if (x != null) entries.add(x);
      }
    }
  }

  Future<void> save() =>
      storage.writeJson(indexName, [for (final e in entries) e.toJson()]);

  bool contains(int sender, int msgId) =>
      entries.any((e) => e.sender == sender && e.msgId == msgId);

  InboxEntry? byKey(String key) {
    for (final e in entries) {
      if (e.key == key) return e;
    }
    return null;
  }

  Future<void> add(InboxEntry e, Uint8List body) async {
    await storage.putBlob(e.blobName, body);
    entries.insert(0, e);
    while (entries.length > maxEntries) {
      await storage.deleteBlob(entries.removeLast().blobName);
    }
    await save();
  }

  Future<Uint8List?> body(InboxEntry e) => storage.getBlob(e.blobName);

  Future<void> markPlayed(InboxEntry e) async {
    if (e.played) return;
    e.played = true;
    await save();
  }

  Future<void> delete(InboxEntry e) async {
    entries.remove(e);
    await storage.deleteBlob(e.blobName);
    await save();
  }
}
