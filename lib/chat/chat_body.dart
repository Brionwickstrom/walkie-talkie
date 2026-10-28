import 'dart:convert';
import 'dart:typed_data';

enum ChatType { text, photo, location, groupInvite }

/// A chat message on the wire: 'WM', version 1, header length (u16 BE),
/// JSON header, then raw data (the JPEG for photos).
///
/// Header fields: t (text/photo/loc), s (text), w/h (photo size), th (the
/// data is only a small thumbnail: the full photo was not sent, e.g. over
/// Bluetooth), lat/lng/acc (location), live (live-location end time, ms
/// since epoch), lid (live share id: later updates replace earlier ones),
/// gi (v2.3.0 private group invitation: id, name, emoji, colour, channel
/// number of an old group, and the secret sealed to the friend; s is the
/// group's name for the chat list).
class ChatBody {
  ChatBody({
    required this.type,
    this.text = '',
    this.data,
    this.width = 0,
    this.height = 0,
    this.thumbnailOnly = false,
    this.lat,
    this.lng,
    this.accuracy,
    this.liveUntil,
    this.liveId,
    this.sentAt,
    this.invite,
  });

  ChatBody.text(String s, {DateTime? sentAt})
    : this(type: ChatType.text, text: s, sentAt: sentAt);

  final ChatType type;
  final String text;
  final Uint8List? data;
  final int width;
  final int height;
  final bool thumbnailOnly;
  final double? lat;
  final double? lng;
  final double? accuracy;
  final DateTime? liveUntil;
  final int? liveId;
  final DateTime? sentAt;

  /// [ChatType.groupInvite]: the invitation (see header `gi`).
  final Map<String, Object?>? invite;

  static const _magic0 = 0x57; // W
  static const _magic1 = 0x4D; // M
  static const _version = 1;

  static const _typeNames = {
    ChatType.text: 'text',
    ChatType.photo: 'photo',
    ChatType.location: 'loc',
    ChatType.groupInvite: 'gi',
  };

  Map<String, Object?> header() => {
    't': _typeNames[type],
    if (text.isNotEmpty) 's': text,
    if (width > 0) 'w': width,
    if (height > 0) 'h': height,
    if (thumbnailOnly) 'th': 1,
    'lat': ?lat,
    'lng': ?lng,
    'acc': ?accuracy,
    if (liveUntil != null) 'live': liveUntil!.millisecondsSinceEpoch,
    'lid': ?liveId,
    if (sentAt != null) 'at': sentAt!.millisecondsSinceEpoch,
    'gi': ?invite,
  };

  Uint8List encode() {
    final h = utf8.encode(jsonEncode(header()));
    final d = data ?? Uint8List(0);
    final out = Uint8List(5 + h.length + d.length);
    out[0] = _magic0;
    out[1] = _magic1;
    out[2] = _version;
    out[3] = h.length >> 8;
    out[4] = h.length & 0xFF;
    out.setRange(5, 5 + h.length, h);
    out.setRange(5 + h.length, out.length, d);
    return out;
  }

  ChatBody copyWith({Uint8List? data, bool? thumbnailOnly}) => ChatBody(
    type: type,
    text: text,
    data: data ?? this.data,
    width: width,
    height: height,
    thumbnailOnly: thumbnailOnly ?? this.thumbnailOnly,
    lat: lat,
    lng: lng,
    accuracy: accuracy,
    liveUntil: liveUntil,
    liveId: liveId,
    sentAt: sentAt,
    invite: invite,
  );

  static bool looksLike(Uint8List b) =>
      b.length >= 5 && b[0] == _magic0 && b[1] == _magic1;

  static ChatBody? tryDecode(Uint8List b) {
    if (!looksLike(b) || b[2] != _version) return null;
    final hl = (b[3] << 8) | b[4];
    if (5 + hl > b.length) return null;
    try {
      final j = jsonDecode(utf8.decode(b.sublist(5, 5 + hl)));
      if (j is! Map) return null;
      final t = _typeNames.entries
          .where((e) => e.value == j['t'])
          .map((e) => e.key)
          .firstOrNull;
      if (t == null) return null;
      final data = b.length > 5 + hl ? Uint8List.sublistView(b, 5 + hl) : null;
      double? d(String k) => (j[k] as num?)?.toDouble();
      int? i(String k) => (j[k] as num?)?.toInt();
      final live = i('live');
      final at = i('at');
      final lat = d('lat'), lng = d('lng');
      if (t == ChatType.location && (lat == null || lng == null)) return null;
      final giRaw = j['gi'];
      final gi = giRaw is Map ? Map<String, Object?>.from(giRaw) : null;
      if (t == ChatType.groupInvite && gi == null) return null;
      return ChatBody(
        type: t,
        text: j['s'] is String ? j['s'] as String : '',
        data: data == null ? null : Uint8List.fromList(data),
        width: i('w') ?? 0,
        height: i('h') ?? 0,
        thumbnailOnly: j['th'] == 1,
        lat: lat,
        lng: lng,
        accuracy: d('acc'),
        liveUntil: live == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(live),
        liveId: i('lid'),
        sentAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
        invite: gi,
      );
    } catch (_) {
      return null;
    }
  }

  /// Google Maps link for a location.
  String? get mapsUrl => lat == null || lng == null
      ? null
      : 'https://www.google.com/maps/search/?api=1&query='
            '${lat!.toStringAsFixed(6)},${lng!.toStringAsFixed(6)}';
}
