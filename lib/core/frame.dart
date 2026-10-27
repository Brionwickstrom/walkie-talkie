import 'dart:convert';
import 'dart:typed_data';

/// Kinds of frames that travel over every transport.
enum FrameType {
  /// One (or more) Opus packets of push-to-talk audio.
  audio(1),

  /// Small JSON control message (hello / talk start / talk end / ring...).
  control(2),

  /// Binary payload for reliable transfers (voice message chunks / acks),
  /// see `messaging/voice_transfer.dart`. Ignored by v1.1.x phones.
  data(3),

  /// Encrypted frame of a private channel (see `core/channel_crypto.dart`):
  /// the real type and payload are inside the ciphertext and the channel
  /// field holds a key-derived tag. v1.2.x phones do not know this type and
  /// drop it.
  sealed(4),

  /// Off-grid mesh: a beacon, or another phone's frame passed on by a relay
  /// (see `core/mesh.dart`). v1.6.0+; older phones drop it.
  mesh(5),

  /// Trip tab message (location, SOS, quick message, map pin, trail...),
  /// see `trip/trip_packet.dart`. v1.8.0+; older phones drop it.
  trip(6),

  /// "Who's where" lobby beacon (v1.8.2): call sign + public channel (or
  /// just "private"), never sealed, never tied to a channel or relay
  /// room. See `core/lobby.dart`. Older phones drop it.
  lobby(7);

  const FrameType(this.code);
  final int code;

  static FrameType? fromCode(int code) {
    for (final t in FrameType.values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// Wire format shared by every transport (LAN UDP, BLE GATT, internet relay).
///
/// ```
/// offset size field
/// 0      2    magic 'W' 'T'
/// 2      1    version (1)
/// 3      1    type (FrameType.code)
/// 4      4    sender node id (uint32, big endian)
/// 8      2    channel (uint16)
/// 10     2    sequence number (uint16, wraps)
/// 12     n    payload (Opus packet or UTF-8 JSON)
/// ```
///
/// The header is deliberately tiny (12 bytes) so a 20 ms Opus packet at
/// 12 kbps (~30 bytes) plus header fits a single BLE notification.
class Frame {
  Frame({
    required this.type,
    required this.senderId,
    required this.channel,
    required this.seq,
    required this.payload,
  }) : assert(senderId >= 0 && senderId <= 0xFFFFFFFF),
       assert(channel >= 0 && channel <= 0xFFFF),
       assert(seq >= 0 && seq <= 0xFFFF);

  static const int headerSize = 12;
  static const int version = 1;
  static const int magic0 = 0x57; // 'W'
  static const int magic1 = 0x54; // 'T'

  final FrameType type;
  final int senderId;
  final int channel;
  final int seq;
  final Uint8List payload;

  factory Frame.control({
    required int senderId,
    required int channel,
    required int seq,
    required ControlMessage message,
  }) => Frame(
    type: FrameType.control,
    senderId: senderId,
    channel: channel,
    seq: seq,
    payload: message.encode(),
  );

  Uint8List encode() {
    final out = Uint8List(headerSize + payload.length);
    final bd = ByteData.sublistView(out);
    out[0] = magic0;
    out[1] = magic1;
    out[2] = version;
    out[3] = type.code;
    bd.setUint32(4, senderId);
    bd.setUint16(8, channel);
    bd.setUint16(10, seq);
    out.setRange(headerSize, out.length, payload);
    return out;
  }

  /// Returns null for anything that is not a valid frame (foreign traffic on
  /// the same port, truncated packets, future versions).
  static Frame? tryDecode(List<int> bytes) {
    if (bytes.length < headerSize) return null;
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data[0] != magic0 || data[1] != magic1 || data[2] != version) {
      return null;
    }
    final type = FrameType.fromCode(data[3]);
    if (type == null) return null;
    final bd = ByteData.sublistView(data);
    return Frame(
      type: type,
      senderId: bd.getUint32(4),
      channel: bd.getUint16(8),
      seq: bd.getUint16(10),
      payload: Uint8List.fromList(data.sublist(headerSize)),
    );
  }

  ControlMessage? get control =>
      type == FrameType.control ? ControlMessage.tryDecode(payload) : null;

  @override
  String toString() =>
      'Frame(${type.name}, from=${senderId.toRadixString(16)}, ch=$channel, '
      'seq=$seq, ${payload.length}B)';
}

enum ControlKind {
  hello,
  talkStart,
  talkEnd,
  ping,
  pong,

  /// Ring someone ([ControlMessage.to]) or, with no `to`, everyone on the
  /// channel. Repeated until acknowledged; [ControlMessage.id] de-dups.
  ring,

  /// Short "roger" chirp, same addressing as [ring].
  beep,

  /// Reply to [ring]/[beep]: [ControlMessage.status] is one of
  /// [RingStatus] names (delivered / answered / dismissed / missed).
  ringAck,

  // ---- v1.5.0 (older phones fail to decode these and ignore them) ----

  /// Friend request with our X25519 public key in `x.pk`.
  friendReq,

  /// Friend request accepted (their public key in `x.pk`).
  friendAcc,

  /// Friend request declined.
  friendDec,

  /// Presence between friends (sealed with the pair key).
  fhello,

  /// Private-channel admin hands remaining members a new passcode
  /// (`x.pc`) after removing someone (`x.ex`).
  rekey,

  /// Member got the [rekey].
  rekeyAck,

  // ---- v1.8.9 (older phones fail to decode it and ignore it) ----

  /// Direct link signaling (candidates, tokens) in `x`, to [ControlMessage.to].
  /// Sent through the relays only; sealed on private channels like every
  /// other frame. See `transports/direct_links.dart`.
  dx,
}

/// Feature level we announce in hello and friend presence `x.v`:
/// 15 = v1.5.0-1.5.3 (friends, chat, channel names, moderation),
/// 16 = v1.5.4 (private reply on the home screen), 17 = v1.6.0 (mesh relay,
/// Wi-Fi Direct), 18 = v1.8.0 (Trip tab: map, SOS, check-ins, pins,
/// trails, base camp), 19 = v1.8.2 (Who's where lobby beacons), 20 =
/// v1.8.9 (direct internet links, [ControlKind.dx]), 21 = v1.9.4 (per
/// phone key `kx` in hellos: private rekey `k: 2` and sealed direct link
/// setup, see core/peer_box.dart). Absent on older phones.
const int featureLevel = 21;

/// Phones at this level announce `kx` and read rekey `k: 2` / sealed dx.
const int peerBoxFeature = 21;

/// Phones at this level set up direct internet links.
const int directFeature = 20;

/// Phones at this level send / read [FrameType.lobby] beacons.
const int lobbyFeature = 19;

/// Phones at this level understand [FrameType.trip].
const int tripFeature = 18;

/// Friends need at least this to talk privately (v1.5.4: their big talk
/// button replies privately instead of to the whole channel).
const int privateTalkFeature = 16;

/// What happened to a ring on the receiving phone.
enum RingStatus { sending, delivered, answered, dismissed, missed, unreachable }

/// Small JSON control payload. Kept short because it may travel over BLE.
class ControlMessage {
  const ControlMessage(
    this.kind, {
    this.name,
    this.lanAddrs = const [],
    this.to,
    this.time,
    this.id,
    this.status,
    this.urgent = false,
    this.interval,
    this.x = const {},
  });

  /// Extension fields of newer versions (older phones ignore the whole
  /// map): hello `v` feature level, `cn`/`ce`/`ct` channel name / emoji /
  /// time set, `adm` admin, `ann` announcement mode; friend keys, rekey
  /// passcodes.
  final Map<String, Object?> x;

  /// [ControlKind.ring]: urgent ring (repeats up to 60 s, may sound in
  /// silent mode). Older phones ignore it and ring normally.
  final bool urgent;

  /// [ControlKind.hello]: the sender's hello interval in ms when it is
  /// longer than normal (battery saver), so we wait longer before treating
  /// it as gone. Older phones ignore it.
  final int? interval;

  final ControlKind kind;

  /// Ring/beep id (random), echoed in [ControlKind.ringAck].
  final int? id;

  /// [ControlKind.ringAck] status ([RingStatus] name).
  final String? status;

  /// Display name, sent with [ControlKind.hello].
  final String? name;

  /// The sender's own LAN endpoints ("ip:port"), sent with
  /// [ControlKind.hello]. Lets a peer we only hear over Bluetooth try direct
  /// UDP to us when broadcast and mDNS are blocked by the router.
  final List<String> lanAddrs;

  /// Intended recipient (ping/pong). Transports may over-deliver.
  final int? to;

  /// Sender's clock in ms (ping); echoed back unchanged in the pong.
  final int? time;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'k': kind.name,
        if (name != null) 'n': name,
        if (lanAddrs.isNotEmpty) 'a': lanAddrs,
        if (to != null) 'to': to,
        if (time != null) 't': time,
        if (id != null) 'i': id,
        if (status != null) 's': status,
        if (urgent) 'u': 1,
        if (interval != null) 'iv': interval,
        if (x.isNotEmpty) 'x': x,
      }),
    ),
  );

  static ControlMessage? tryDecode(List<int> bytes) {
    try {
      final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final kind = ControlKind.values.byName(map['k'] as String);
      final a = map['a'];
      return ControlMessage(
        kind,
        name: map['n'] as String?,
        lanAddrs: a is List
            ? [
                for (final x in a)
                  if (x is String) x,
              ]
            : const [],
        to: (map['to'] as num?)?.toInt(),
        time: (map['t'] as num?)?.toInt(),
        id: (map['i'] as num?)?.toInt(),
        status: map['s'] as String?,
        urgent: map['u'] == 1 || map['u'] == true,
        interval: (map['iv'] as num?)?.toInt(),
        x: map['x'] is Map
            ? Map<String, Object?>.from(map['x'] as Map)
            : const {},
      );
    } catch (_) {
      return null;
    }
  }
}

/// Sequence numbers wrap at 16 bits; this compares them RFC 1982 style.
bool seqNewer(int a, int b) {
  final diff = (a - b) & 0xFFFF;
  return diff != 0 && diff < 0x8000;
}
