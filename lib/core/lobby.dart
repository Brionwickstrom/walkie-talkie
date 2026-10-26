import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'frame.dart';

/// "Who's where" lobby beacon (v1.8.2).
///
/// Normal presence (hello) stays inside a channel: on the internet relay
/// each channel is its own room, and on a private channel every hello is
/// sealed, so a phone only ever sees people on its own channel over the
/// internet. The lobby beacon is a tiny, separate, *public* announcement
/// that says only:
///
/// * public channel: call sign / name, the channel number and (if set) the
///   channel's name + emoji;
/// * private channel: "private" and the phone's call sign. No channel
///   number, name, emoji, key tag or passcode-derived data, ever: the
///   encoder has no way to write them and the decoder throws them away.
///
/// It goes out at a low rate on the local links (Wi-Fi / LAN, Wi-Fi Direct,
/// Bluetooth; the phone mesh may pass it on, rate limited) and, while
/// online, in a shared relay room ([relayRoom]). Never over LoRa. Phones
/// with "Show me in Who's where" off send none at all.
///
/// ```
/// frame header (12 B: type 7, sender = node id, channel 0, seq)
/// ver      1 B  (1)
/// flags    1 B  bit0 private
/// channel  2 B  public channel number (0 when private)
/// feature  1 B  sender's feature level
/// every    1 B  sender's beacon interval in 5 s units (expiry hint)
/// nameLen  1 B  + UTF-8 name (max [maxName] bytes)
/// cnLen    1 B  + UTF-8 channel name (max [maxChannelName], public only)
/// ceLen    1 B  + UTF-8 channel emoji (max [maxEmoji], public only)
/// battery  1 B  optional (v1.8.3): phone battery 0..100; older apps
///               stop reading before it
/// ```
///
/// v1.8.3: a very rare copy (every [radioInterval]) also goes over the
/// LoRa radio, so people only the radio reaches show up. Same bytes, same
/// privacy: nothing about a private channel.
///
/// About 30-70 bytes: fits one Bluetooth packet with room to spare.
class LobbyBeacon {
  const LobbyBeacon._({
    required this.name,
    required this.channel,
    required this.feature,
    required this.every,
    this.channelName,
    this.channelEmoji,
    this.battery,
  });

  /// LoRa copy of the beacon: this rarely (receivers keep it 3x as long).
  static const Duration radioInterval = Duration(minutes: 15);

  /// Phone battery 0..100, null = not shared / unknown.
  final int? battery;

  /// Same beacon with [every] / [battery] replaced.
  LobbyBeacon copyWith({Duration? every, int? battery}) => LobbyBeacon._(
    name: name,
    channel: channel,
    feature: feature,
    every: every ?? this.every,
    channelName: channelName,
    channelEmoji: channelEmoji,
    battery: battery ?? this.battery,
  );

  /// On a public channel.
  factory LobbyBeacon.public({
    required String name,
    required int channel,
    int feature = featureLevel,
    Duration every = const Duration(seconds: 10),
    String? channelName,
    String? channelEmoji,
    int? battery,
  }) => LobbyBeacon._(
    name: _clip(name, maxName),
    channel: channel.clamp(1, 0xFFFF),
    feature: feature,
    every: every,
    channelName: _nonEmpty(_clip(channelName ?? '', maxChannelName)),
    channelEmoji: _nonEmpty(_clip(channelEmoji ?? '', maxEmoji)),
    battery: _pct(battery),
  );

  static int? _pct(int? b) => b != null && b >= 0 && b <= 100 ? b : null;

  /// On a private channel: only the call sign. There is deliberately no
  /// parameter for the channel.
  factory LobbyBeacon.private({
    required String callSign,
    int feature = featureLevel,
    Duration every = const Duration(seconds: 10),
    int? battery,
  }) => LobbyBeacon._(
    name: _clip(callSign, maxName),
    channel: null,
    feature: feature,
    every: every,
    battery: _pct(battery),
  );

  static const int version = 1;
  static const int maxName = 24;
  static const int maxChannelName = 30;
  static const int maxEmoji = 8;

  /// Relay room every online phone joins for lobby beacons.
  static const String relayRoom = 'lobby';

  final String name;

  /// Public channel number, null on a private channel.
  final int? channel;
  bool get isPrivate => channel == null;
  final int feature;

  /// How often the sender beacons (receivers expire it after ~3x).
  final Duration every;
  final String? channelName;
  final String? channelEmoji;

  Uint8List encodePayload() {
    final n = utf8.encode(name);
    final cn = isPrivate ? const <int>[] : utf8.encode(channelName ?? '');
    final ce = isPrivate ? const <int>[] : utf8.encode(channelEmoji ?? '');
    final b = BytesBuilder(copy: false)
      ..addByte(version)
      ..addByte(isPrivate ? 1 : 0)
      ..addByte(((channel ?? 0) >> 8) & 0xFF)
      ..addByte((channel ?? 0) & 0xFF)
      ..addByte(feature.clamp(0, 255))
      ..addByte((every.inSeconds / 5).ceil().clamp(1, 255))
      ..addByte(n.length)
      ..add(n)
      ..addByte(cn.length)
      ..add(cn)
      ..addByte(ce.length)
      ..add(ce);
    if (battery != null) b.addByte(battery!);
    return b.toBytes();
  }

  /// The whole frame, ready for any transport.
  Uint8List encode({required int senderId, required int seq}) => Frame(
    type: FrameType.lobby,
    senderId: senderId,
    channel: 0,
    seq: seq & 0xFFFF,
    payload: encodePayload(),
  ).encode();

  /// Null for anything malformed. A private beacon never yields a channel,
  /// name or emoji even if a (buggy or hostile) sender put bytes there.
  static LobbyBeacon? tryDecode(Frame f) {
    if (f.type != FrameType.lobby) return null;
    return tryDecodePayload(f.payload);
  }

  static LobbyBeacon? tryDecodePayload(Uint8List p) {
    try {
      if (p.length < 9 || p[0] != version) return null;
      final private = p[1] & 1 == 1;
      final ch = (p[2] << 8) | p[3];
      final feature = p[4];
      final every = Duration(seconds: p[5] * 5);
      var i = 6;
      String? str(int max) {
        final len = p[i++];
        if (len > max || i + len > p.length) throw const FormatException();
        final s = utf8.decode(p.sublist(i, i + len), allowMalformed: true);
        i += len;
        return s;
      }

      final name = str(maxName * 2)!;
      final cn = str(maxChannelName * 2);
      final ce = str(maxEmoji * 2);
      final battery = i < p.length ? p[i] : null;
      if (private) {
        return LobbyBeacon.private(
          callSign: name,
          feature: feature,
          every: every,
          battery: battery,
        );
      }
      if (ch == 0) return null;
      return LobbyBeacon.public(
        name: name,
        channel: ch,
        feature: feature,
        every: every,
        channelName: cn,
        channelEmoji: ce,
        battery: battery,
      );
    } catch (_) {
      return null;
    }
  }

  static String? _nonEmpty(String s) => s.trim().isEmpty ? null : s;

  /// Cut [s] to at most [maxBytes] UTF-8 bytes on a character boundary.
  static String _clip(String s, int maxBytes) {
    if (utf8.encode(s).length <= maxBytes) return s;
    final out = StringBuffer();
    var used = 0;
    for (final r in s.runes) {
      final c = String.fromCharCode(r);
      final l = utf8.encode(c).length;
      if (used + l > maxBytes) break;
      out.write(c);
      used += l;
    }
    return out.toString();
  }
}

/// Inbound lobby beacons are cheap, but a busy relay room or a chatty mesh
/// must not keep the phone busy: a global token bucket plus at most one
/// beacon per sender and path every [perSender].
class LobbyLimiter {
  LobbyLimiter({
    this.perSecond = 20,
    this.burst = 40,
    this.perSender = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _tokens = burst.toDouble();

  final int perSecond;
  final int burst;
  final Duration perSender;
  final DateTime Function() _clock;
  double _tokens;
  DateTime? _at;
  final Map<(int, Object), DateTime> _last = {};
  int dropped = 0;

  /// Whether a beacon from [sender] on [path] may be processed now.
  bool allow(int sender, Object path) {
    final now = _clock();
    final key = (sender, path);
    final prev = _last[key];
    if (prev != null && now.difference(prev) < perSender) {
      dropped++;
      return false;
    }
    final at = _at;
    if (at != null) {
      final dt = now.difference(at).inMicroseconds / 1e6;
      if (dt > 0) _tokens = min(burst.toDouble(), _tokens + dt * perSecond);
    }
    _at = now;
    if (_tokens < 1) {
      dropped++;
      return false;
    }
    _tokens -= 1;
    _last[key] = now;
    if (_last.length > 1024) {
      _last.removeWhere((_, t) => now.difference(t) > perSender);
    }
    return true;
  }
}

/// "Who's here?" probe (v1.8.5): sent when someone pulls the people list
/// or Who's where down to refresh. Phones that hear it answer right away
/// (after a short random delay) with their presence hello and lobby
/// beacon instead of waiting for their next timer.
///
/// It travels as a [FrameType.lobby] frame (public, never sealed) whose
/// payload starts with [magic] instead of [LobbyBeacon.version], and is
/// shorter than any beacon, so v1.8.2-v1.8.4 phones fail to decode it as
/// a beacon and ignore it (older ones drop the frame type).
///
/// ```
/// frame header (12 B: type 7, sender = node id, channel 0, seq)
/// magic    1 B  0x50 ('P')
/// ver      1 B  (1)
/// flags    1 B  bit0 sent over the LoRa radio
/// ttl      1 B  phone-mesh hops it may travel (1..[maxTtl])
/// nonce    2 B  per refresh (receivers answer one refresh once)
/// ```
class LobbyProbe {
  LobbyProbe({required this.nonce, int ttl = defaultTtl, this.radio = false})
    : ttl = ttl.clamp(1, maxTtl);

  static const int magic = 0x50;
  static const int version = 1;
  static const int size = 6;
  static const int defaultTtl = 3;
  static const int maxTtl = 6;

  /// Identifies one refresh (wraps at 16 bits).
  final int nonce;

  /// Phone-mesh hop limit.
  final int ttl;

  /// This copy is (meant to go) over the LoRa radio.
  final bool radio;

  Uint8List encodePayload() => Uint8List.fromList([
    magic,
    version,
    radio ? 1 : 0,
    ttl,
    (nonce >> 8) & 0xFF,
    nonce & 0xFF,
  ]);

  Uint8List encode({required int senderId, required int seq}) => Frame(
    type: FrameType.lobby,
    senderId: senderId,
    channel: 0,
    seq: seq & 0xFFFF,
    payload: encodePayload(),
  ).encode();

  static LobbyProbe? tryDecode(Frame f) {
    if (f.type != FrameType.lobby) return null;
    return tryDecodePayload(f.payload);
  }

  /// Null for beacons and anything malformed. Later versions may append
  /// bytes; they are ignored.
  static LobbyProbe? tryDecodePayload(Uint8List p) {
    if (p.length < size || p[0] != magic || p[1] != version) return null;
    final ttl = p[3];
    if (ttl == 0) return null;
    return LobbyProbe(
      nonce: (p[4] << 8) | p[5],
      ttl: ttl,
      radio: p[2] & 1 == 1,
    );
  }

  /// Whether [p] (a lobby payload) is a probe rather than a beacon.
  static bool isProbePayload(Uint8List p) =>
      p.isNotEmpty && p[0] == magic && p.length >= size;
}

/// Answer each requester at most once per [perRequester] (a refresh
/// spinner pulled again and again, or the same probe arriving over Wi-Fi,
/// Bluetooth and the mesh at once, gets one reply), and keep the number
/// of tracked requesters bounded.
class ProbeReplyLimiter {
  ProbeReplyLimiter({
    this.perRequester = const Duration(seconds: 5),
    this.maxTracked = 512,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration perRequester;
  final int maxTracked;
  final DateTime Function() _clock;
  final Map<int, DateTime> _last = {};
  int dropped = 0;

  bool allow(int requester) {
    final now = _clock();
    final prev = _last[requester];
    if (prev != null && now.difference(prev) < perRequester) {
      dropped++;
      return false;
    }
    _last[requester] = now;
    if (_last.length > maxTracked) {
      _last.removeWhere((_, t) => now.difference(t) >= perRequester);
      while (_last.length > maxTracked) {
        _last.remove(_last.keys.first);
      }
    }
    return true;
  }
}
