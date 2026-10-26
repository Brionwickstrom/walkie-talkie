import 'dart:async';
import 'dart:typed_data';

import '../messaging/storage.dart';
import 'chat_body.dart';

/// One chat message in a conversation (sent or received).
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.sender,
    required this.senderName,
    required this.mine,
    required this.at,
    required this.type,
    this.text = '',
    this.hasPhoto = false,
    this.thumbnailOnly = false,
    this.width = 0,
    this.height = 0,
    this.lat,
    this.lng,
    this.accuracy,
    this.liveUntil,
    this.liveId,
    this.viaRadio = false,
    Set<int>? deliveredTo,
    Set<int>? seenBy,
    this.receiptSent = false,
  }) : deliveredTo = deliveredTo ?? <int>{},
       seenBy = seenBy ?? <int>{};

  factory ChatMessage.fromBody(
    ChatBody b, {
    required int id,
    required int sender,
    required String senderName,
    required bool mine,
    required DateTime at,
    bool viaRadio = false,
  }) => ChatMessage(
    viaRadio: viaRadio,
    id: id,
    sender: sender,
    senderName: senderName,
    mine: mine,
    at: at,
    type: b.type,
    text: b.text,
    hasPhoto: b.type == ChatType.photo && (b.data?.isNotEmpty ?? false),
    thumbnailOnly: b.thumbnailOnly,
    width: b.width,
    height: b.height,
    lat: b.lat,
    lng: b.lng,
    accuracy: b.accuracy,
    liveUntil: b.liveUntil,
    liveId: b.liveId,
  );

  final int id;
  final int sender;
  final String senderName;
  final bool mine;
  DateTime at;
  final ChatType type;
  final String text;
  final bool hasPhoto;
  final bool thumbnailOnly;
  final int width;
  final int height;
  double? lat;
  double? lng;
  double? accuracy;
  DateTime? liveUntil;
  final int? liveId;

  /// Arrived over a LoRa radio (v1.7.0); for our own messages: delivered
  /// over the radio (v1.8.3).
  bool viaRadio;

  /// Phones that confirmed receiving it (sent messages).
  final Set<int> deliveredTo;

  /// Phones that saw it (read receipts, v1.8.3; sent messages).
  final Set<int> seenBy;

  /// We sent the read receipt for it (received messages).
  bool receiptSent;

  String get photoBlob => 'p_${sender}_$id.jpg';

  bool isLive(DateTime now) => liveUntil != null && now.isBefore(liveUntil!);

  String? get mapsUrl => lat == null || lng == null
      ? null
      : ChatBody(type: ChatType.location, lat: lat, lng: lng).mapsUrl;

  static const _typeKeys = {
    ChatType.text: 't',
    ChatType.photo: 'p',
    ChatType.location: 'l',
  };

  Map<String, Object?> toJson() => {
    'id': id,
    's': sender,
    'n': senderName,
    'm': mine,
    'at': at.millisecondsSinceEpoch,
    'ty': _typeKeys[type],
    if (text.isNotEmpty) 'tx': text,
    if (hasPhoto) 'ph': 1,
    if (thumbnailOnly) 'th': 1,
    if (width > 0) 'w': width,
    if (height > 0) 'h': height,
    'lat': ?lat,
    'lng': ?lng,
    'acc': ?accuracy,
    if (liveUntil != null) 'lu': liveUntil!.millisecondsSinceEpoch,
    'lid': ?liveId,
    if (deliveredTo.isNotEmpty) 'd': deliveredTo.toList(),
    if (seenBy.isNotEmpty) 'sb': seenBy.toList(),
    if (receiptSent) 'rs': 1,
    if (viaRadio) 'vr': 1,
  };

  static ChatMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final ty = _typeKeys.entries.firstWhere((e) => e.value == j['ty']).key;
      final lu = (j['lu'] as num?)?.toInt();
      return ChatMessage(
        id: (j['id'] as num).toInt(),
        sender: (j['s'] as num).toInt(),
        senderName: j['n'] as String? ?? '',
        mine: j['m'] == true,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
        type: ty,
        text: j['tx'] as String? ?? '',
        hasPhoto: j['ph'] == 1,
        thumbnailOnly: j['th'] == 1,
        width: (j['w'] as num?)?.toInt() ?? 0,
        height: (j['h'] as num?)?.toInt() ?? 0,
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
        accuracy: (j['acc'] as num?)?.toDouble(),
        liveUntil: lu == null ? null : DateTime.fromMillisecondsSinceEpoch(lu),
        liveId: (j['lid'] as num?)?.toInt(),
        viaRadio: j['vr'] == 1,
        receiptSent: j['rs'] == 1,
        seenBy: {
          for (final x in (j['sb'] as List?) ?? const []) (x as num).toInt(),
        },
        deliveredTo: {
          for (final x in (j['d'] as List?) ?? const []) (x as num).toInt(),
        },
      );
    } catch (_) {
      return null;
    }
  }
}

/// Conversation keys: a channel scope, or a friend.
String channelConversation(int scope) => 'c$scope';
String friendConversation(int friendId) => 'f$friendId';

/// Chat history on the phone: one list per conversation (channel or
/// friend), newest last, at most [maxPerConversation] messages each.
/// Photos are stored as separate files.
class ChatStore {
  ChatStore(this.storage, {this.maxPerConversation = 300});

  final MessageStorage storage;
  final int maxPerConversation;

  static const indexName = 'chats.json';

  final Map<String, List<ChatMessage>> _convs = {};
  final Map<String, int> _unread = {};
  final _changes = StreamController<String>.broadcast();
  Future<void> _saving = Future.value();

  /// A conversation changed (its key).
  Stream<String> get changes => _changes.stream;

  Iterable<String> get conversations => _convs.keys;

  Future<void> load() async {
    final j = await storage.readJson(indexName);
    _convs.clear();
    _unread.clear();
    if (j is! Map) return;
    final convs = j['c'];
    if (convs is Map) {
      convs.forEach((k, v) {
        if (v is! List) return;
        _convs[k as String] = [for (final m in v) ?ChatMessage.fromJson(m)];
      });
    }
    final un = j['u'];
    if (un is Map) {
      un.forEach((k, v) {
        if (v is num && v > 0) _unread[k as String] = v.toInt();
      });
    }
  }

  Future<void> _save() {
    final snapshot = {
      'c': {
        for (final e in _convs.entries)
          e.key: [for (final m in e.value) m.toJson()],
      },
      'u': _unread,
    };
    return _saving = _saving.then(
      (_) => storage.writeJson(indexName, snapshot),
    );
  }

  List<ChatMessage> messages(String conv) =>
      List.unmodifiable(_convs[conv] ?? const <ChatMessage>[]);

  ChatMessage? lastOf(String conv) {
    final l = _convs[conv];
    return l == null || l.isEmpty ? null : l.last;
  }

  bool contains(int sender, int id) {
    for (final l in _convs.values) {
      for (final m in l) {
        if (m.sender == sender && m.id == id) return true;
      }
    }
    return false;
  }

  int unread(String conv) => _unread[conv] ?? 0;

  int unreadWhere(bool Function(String conv) test) {
    var n = 0;
    _unread.forEach((k, v) {
      if (test(k)) n += v;
    });
    return n;
  }

  Future<void> markRead(String conv) async {
    if (_unread.remove(conv) == null) return;
    _emit(conv);
    await _save();
  }

  /// Add a message. A live-location update replaces the earlier pin with
  /// the same sender and live id. Returns false for duplicates.
  Future<bool> add(String conv, ChatMessage m, {Uint8List? photo}) async {
    final list = _convs.putIfAbsent(conv, () => []);
    if (list.any((x) => x.sender == m.sender && x.id == m.id)) return false;
    if (m.liveId != null) {
      for (final x in list) {
        if (x.sender == m.sender && x.liveId == m.liveId) {
          if (m.at.isBefore(x.at)) return false; // out of order
          x
            ..lat = m.lat
            ..lng = m.lng
            ..accuracy = m.accuracy
            ..at = m.at
            ..liveUntil = m.liveUntil;
          _emit(conv);
          await _save();
          return true;
        }
      }
    }
    if (photo != null && m.hasPhoto) {
      await storage.putBlob(m.photoBlob, photo);
    }
    list.add(m);
    list.sort((a, b) => a.at.compareTo(b.at));
    while (list.length > maxPerConversation) {
      final old = list.removeAt(0);
      if (old.hasPhoto) await storage.deleteBlob(old.photoBlob);
    }
    if (!m.mine) _unread[conv] = unread(conv) + 1;
    _emit(conv);
    await _save();
    return true;
  }

  bool hasLive(int sender, int liveId) => _convs.values.any(
    (l) => l.any((m) => m.sender == sender && m.liveId == liveId),
  );

  /// Move a conversation (a private channel got a new passcode).
  Future<void> rename(String from, String to) async {
    final l = _convs.remove(from);
    if (l == null || from == to) {
      if (l != null) _convs[from] = l;
      return;
    }
    _convs.putIfAbsent(to, () => []).insertAll(0, l);
    final u = _unread.remove(from);
    if (u != null) _unread[to] = unread(to) + u;
    _emit(to);
    await _save();
  }

  Future<Uint8List?> photo(ChatMessage m) =>
      m.hasPhoto ? storage.getBlob(m.photoBlob) : Future.value(null);

  /// A sent message reached [peer].
  Future<void> markDelivered(
    int sender,
    int id,
    int peer, {
    bool viaRadio = false,
  }) async {
    for (final e in _convs.entries) {
      for (final m in e.value) {
        if (m.sender == sender && m.id == id && m.mine) {
          final radioNew = viaRadio && !m.viaRadio;
          if (viaRadio) m.viaRadio = true;
          if (m.deliveredTo.add(peer) || radioNew) {
            _emit(e.key);
            await _save();
          }
          return;
        }
      }
    }
  }

  /// [peer] saw our message [id] (read receipt). Also counts as delivered.
  Future<bool> markSeen(int sender, int id, int peer) async {
    for (final e in _convs.entries) {
      for (final m in e.value) {
        if (m.sender == sender && m.id == id && m.mine) {
          final a = m.seenBy.add(peer);
          final b = m.deliveredTo.add(peer);
          if (a || b) {
            _emit(e.key);
            await _save();
          }
          return true;
        }
      }
    }
    return false;
  }

  /// Received messages in [conv] we have not sent a read receipt for yet
  /// (marks them as sent). Live-location updates are skipped.
  Future<List<ChatMessage>> takeUnreceipted(String conv) async {
    final out = <ChatMessage>[];
    for (final m in _convs[conv] ?? const <ChatMessage>[]) {
      if (m.mine || m.receiptSent) continue;
      m.receiptSent = true;
      if (m.liveId != null) continue;
      out.add(m);
    }
    if (out.isNotEmpty) await _save();
    return out;
  }

  /// Stop a live location early (sets its end time to [now]).
  Future<void> endLive(int sender, int liveId, DateTime now) async {
    for (final e in _convs.entries) {
      for (final m in e.value) {
        if (m.sender == sender && m.liveId == liveId && m.isLive(now)) {
          m.liveUntil = now;
          _emit(e.key);
          await _save();
        }
      }
    }
  }

  Future<void> clear(String conv) async {
    final l = _convs.remove(conv);
    _unread.remove(conv);
    for (final m in l ?? const <ChatMessage>[]) {
      if (m.hasPhoto) await storage.deleteBlob(m.photoBlob);
    }
    _emit(conv);
    await _save();
  }

  void _emit(String conv) {
    if (!_changes.isClosed) _changes.add(conv);
  }

  Future<void> dispose() => _changes.close();
}
