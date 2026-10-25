import 'dart:convert';
import 'dart:typed_data';

/// Kinds of frames that travel over every transport.
enum FrameType {
  /// One (or more) Opus packets of push-to-talk audio.
  audio(1),

  /// Small JSON control message (hello / talk start / talk end).
  control(2);

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

enum ControlKind { hello, talkStart, talkEnd, ping, pong }

/// Small JSON control payload. Kept short because it may travel over BLE.
class ControlMessage {
  const ControlMessage(
    this.kind, {
    this.name,
    this.lanAddrs = const [],
    this.to,
    this.time,
  });

  final ControlKind kind;

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
