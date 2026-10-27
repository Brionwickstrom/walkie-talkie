import 'dart:convert';
import 'dart:typed_data';

import '../lora/meshtastic_channels.dart' show MeshChannelRef;
import 'frame.dart';
import 'mesh.dart' show meshPacketId;

/// LoRa gateway protocol (v1.9.5).
///
/// A gateway bridges the internet relay rooms and the Meshtastic LoRa mesh.
/// It is either the always-on "Home gateway" container (Synology, any
/// number of USB / Wi-Fi radios) or a phone that shares its paired radio.
/// Every envelope is a [FrameType.gateway] frame that only ever travels
/// over the internet relay:
///
/// ```
/// header 12 B (sender = gateway / phone id, channel = inner channel, seq)
/// kind   1 B
///  1 fromRadio: hops 1 B, radio node 4 B, snr 1 B (signed, x4), inner
///  2 toRadio:   priority 1 B (LoraPriority index), to 4 B (0 = all), inner
///  3 toRadio on a linked Meshtastic channel (v1.9.7): priority 1 B, to
///               4 B, channel hash 1 B, name length 1 B, name (UTF-8),
///               inner. Decoded as [GatewayKind.toRadio] with [mesh] set;
///               phones send it right before the plain kind 2 copy (older
///               gateways only know that one, newer ones drop it as a
///               duplicate).
///  4 announce:  UTF-8 JSON {"n": name, "r": radios up, "t": radios,
///               "v": 1, "ph": 1 for a phone}
/// ```
///
/// * `inner` is the original app frame, byte for byte (sealed frames stay
///   sealed: gateways never need channel passcodes).
/// * Loop prevention: only `toRadio` puts anything on the air, and only
///   phones originate it (for frames they decided may use the radio,
///   before sealing). `fromRadio` copies are never put back on the air.
///   Every gateway remembers the [gatewayPacketId] of each inner frame it
///   forwarded, transmitted or saw in a room, so a frame heard back over
///   LoRa (or from a second radio) is not forwarded again.
/// * The hop byte is 1 when a gateway forwards; envelopes are never
///   re-wrapped.
enum GatewayKind {
  fromRadio(1),
  toRadio(2),
  announce(4);

  const GatewayKind(this.code);
  final int code;

  static GatewayKind? fromCode(int c) {
    for (final k in GatewayKind.values) {
      if (k.code == c) return k;
    }
    return null;
  }
}

/// Dedupe id of an inner frame (same hash as the phone mesh packet id).
int gatewayPacketId(List<int> inner) => meshPacketId(inner);

class GatewayEnvelope {
  GatewayEnvelope._(
    this.kind, {
    this.inner,
    this.hops = 1,
    this.radioNode = 0,
    this.snr = 0,
    this.priority = 2,
    this.to = 0,
    this.info = const {},
    this.mesh,
  });

  factory GatewayEnvelope.fromRadio(
    Uint8List inner, {
    int hops = 1,
    int radioNode = 0,
    double snr = 0,
  }) => GatewayEnvelope._(
    GatewayKind.fromRadio,
    inner: inner,
    hops: hops,
    radioNode: radioNode,
    snr: snr,
  );

  factory GatewayEnvelope.toRadio(
    Uint8List inner, {
    int priority = 2,
    int to = 0,
    MeshChannelRef? mesh,
  }) => GatewayEnvelope._(
    GatewayKind.toRadio,
    inner: inner,
    priority: priority,
    to: to,
    mesh: mesh,
  );

  factory GatewayEnvelope.announce({
    required String name,
    int radiosUp = 0,
    int radios = 0,
    bool phone = false,
  }) => GatewayEnvelope._(
    GatewayKind.announce,
    info: {'n': name, 'r': radiosUp, 't': radios, 'v': 1, if (phone) 'ph': 1},
  );

  final GatewayKind kind;
  final Uint8List? inner;
  final int hops;
  final int radioNode;
  final double snr;
  final int priority;
  final int to;
  final Map<String, Object?> info;

  /// toRadio: the Meshtastic channel to send it on (v1.9.7), null for
  /// the radio's primary channel.
  final MeshChannelRef? mesh;

  String get name => (info['n'] as String?) ?? 'Gateway';
  int get radiosUp => (info['r'] as num?)?.toInt() ?? 0;
  int get radios => (info['t'] as num?)?.toInt() ?? 0;
  bool get isPhone => info['ph'] == 1;

  /// The inner frame, decoded (null for announcements or junk).
  Frame? get innerFrame => inner == null ? null : Frame.tryDecode(inner!);

  int get packetId => gatewayPacketId(inner ?? const []);

  Uint8List encodePayload() {
    switch (kind) {
      case GatewayKind.fromRadio:
        final i = inner!;
        final out = Uint8List(7 + i.length);
        out[0] = kind.code;
        out[1] = hops.clamp(0, 255);
        ByteData.sublistView(out).setUint32(2, radioNode & 0xFFFFFFFF);
        out[6] = (snr * 4).round().clamp(-128, 127) & 0xFF;
        out.setRange(7, out.length, i);
        return out;
      case GatewayKind.toRadio when mesh != null:
        final i = inner!;
        var name = utf8.encode(mesh!.name);
        if (name.length > 32) name = name.sublist(0, 32);
        final out = Uint8List(8 + name.length + i.length);
        out[0] = 3;
        out[1] = priority.clamp(0, 255);
        ByteData.sublistView(out).setUint32(2, to & 0xFFFFFFFF);
        out[6] = mesh!.hash & 0xFF;
        out[7] = name.length;
        out.setRange(8, 8 + name.length, name);
        out.setRange(8 + name.length, out.length, i);
        return out;
      case GatewayKind.toRadio:
        final i = inner!;
        final out = Uint8List(6 + i.length);
        out[0] = kind.code;
        out[1] = priority.clamp(0, 255);
        ByteData.sublistView(out).setUint32(2, to & 0xFFFFFFFF);
        out.setRange(6, out.length, i);
        return out;
      case GatewayKind.announce:
        return Uint8List.fromList([
          kind.code,
          ...utf8.encode(jsonEncode(info)),
        ]);
    }
  }

  Frame toFrame({
    required int senderId,
    required int channel,
    required int seq,
  }) => Frame(
    type: FrameType.gateway,
    senderId: senderId,
    channel: channel & 0xFFFF,
    seq: seq & 0xFFFF,
    payload: encodePayload(),
  );

  static GatewayEnvelope? tryDecode(Frame f) {
    if (f.type != FrameType.gateway) return null;
    final p = f.payload;
    if (p.isEmpty) return null;
    if (p[0] == 3) return _decodeMesh(p);
    final kind = GatewayKind.fromCode(p[0]);
    if (kind == null) return null;
    try {
      switch (kind) {
        case GatewayKind.fromRadio:
          if (p.length < 7 + Frame.headerSize) return null;
          final bd = ByteData.sublistView(p);
          final inner = Uint8List.fromList(p.sublist(7));
          if (Frame.tryDecode(inner) == null) return null;
          return GatewayEnvelope._(
            kind,
            inner: inner,
            hops: p[1],
            radioNode: bd.getUint32(2),
            snr: bd.getInt8(6) / 4,
          );
        case GatewayKind.toRadio:
          if (p.length < 6 + Frame.headerSize) return null;
          final bd = ByteData.sublistView(p);
          final inner = Uint8List.fromList(p.sublist(6));
          final f2 = Frame.tryDecode(inner);
          // Envelopes are never nested, and never go on the air.
          if (f2 == null || f2.type == FrameType.gateway) return null;
          if (f2.type == FrameType.mesh) return null;
          return GatewayEnvelope._(
            kind,
            inner: inner,
            priority: p[1],
            to: bd.getUint32(2),
          );
        case GatewayKind.announce:
          final m = jsonDecode(utf8.decode(p.sublist(1)));
          if (m is! Map) return null;
          return GatewayEnvelope._(kind, info: Map<String, Object?>.from(m));
      }
    } catch (_) {
      return null;
    }
  }
}

GatewayEnvelope? _decodeMesh(Uint8List p) {
  try {
    if (p.length < 8) return null;
    final n = p[7];
    if (n > 32 || p.length < 8 + n + Frame.headerSize) return null;
    final name = utf8.decode(p.sublist(8, 8 + n));
    final inner = Uint8List.fromList(p.sublist(8 + n));
    final f2 = Frame.tryDecode(inner);
    if (f2 == null || f2.type == FrameType.gateway) return null;
    if (f2.type == FrameType.mesh) return null;
    return GatewayEnvelope._(
      GatewayKind.toRadio,
      inner: inner,
      priority: p[1],
      to: ByteData.sublistView(p).getUint32(2),
      mesh: MeshChannelRef(name, p[6]),
    );
  } catch (_) {
    return null;
  }
}

/// Relay room an inner frame belongs to: the channel number for plain
/// frames, "p" + tag for sealed ones (private channels; see
/// RelayTransport.roomFor).
String gatewayRoomOf(Frame inner) => inner.type == FrameType.sealed
    ? 'p${(inner.channel & 0xFFFF).toRadixString(16).padLeft(4, '0')}'
    : '${inner.channel}';

/// Seen-id cache shared by everything a gateway touches (all radios, all
/// rooms): ids expire after [ttl] or when more than [max] are kept.
class SeenIds {
  SeenIds({
    this.ttl = const Duration(minutes: 10),
    this.max = 4096,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int max;
  final DateTime Function() _clock;
  final _at = <int, DateTime>{};

  bool contains(int id) {
    final t = _at[id];
    if (t == null) return false;
    if (_clock().difference(t) > ttl) {
      _at.remove(id);
      return false;
    }
    return true;
  }

  /// Mark [id]; returns false if it was already (recently) seen.
  bool add(int id) {
    final fresh = !contains(id);
    _at.remove(id);
    _at[id] = _clock();
    while (_at.length > max) {
      _at.remove(_at.keys.first);
    }
    return fresh;
  }

  int get length => _at.length;
}

/// A gateway that announced itself in a relay room (as a phone sees it).
class GatewayInfo {
  GatewayInfo(
    this.id,
    this.name,
    this.radiosUp,
    this.radios,
    this.phone,
    this.at,
  );
  final int id;
  final String name;
  final int radiosUp;
  final int radios;

  /// A phone sharing its radio (not the always-on Home gateway).
  final bool phone;
  final DateTime at;
}
