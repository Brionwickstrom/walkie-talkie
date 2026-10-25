import 'dart:typed_data';

/// Reliable transfer of a voice message over the lossy, unordered links
/// (UDP / BLE / relay) as [FrameType.data] payloads.
///
/// The message body is cut into small chunks (they must fit a BLE frame
/// even at the 23 byte default MTU). The receiver answers with selective
/// acks; the sender keeps a window of chunks in flight and resends anything
/// not acked within a timeout. Chunks and acks carry the intended
/// recipient so over-delivery (BLE notify, relay fan-out) is harmless.
///
/// ```
/// chunk: 1 | msgId u32 | to u32 | index u16 | total u16 | durMs u32 | flags u8 | data
/// ack:   2 | msgId u32 | to u32 | total u16 | nextMissing u16 | bitmap u32
/// ```
/// `nextMissing` = lowest chunk index not received yet (== total when
/// complete); bit i of `bitmap` = chunk nextMissing+1+i received.
abstract class DataPacket {
  static const int chunkType = 1;
  static const int ackType = 2;

  int get msgId;
  int get to;
  Uint8List encode();

  static DataPacket? tryDecode(Uint8List b) {
    if (b.isEmpty) return null;
    final bd = ByteData.sublistView(b);
    try {
      switch (b[0]) {
        case chunkType:
          if (b.length < ChunkPacket.headerSize) return null;
          final total = bd.getUint16(11);
          final index = bd.getUint16(9);
          if (total == 0 || index >= total) return null;
          return ChunkPacket(
            msgId: bd.getUint32(1),
            to: bd.getUint32(5),
            index: index,
            total: total,
            durationMs: bd.getUint32(13),
            channelMessage: (b[17] & 1) != 0,
            data: Uint8List.fromList(b.sublist(ChunkPacket.headerSize)),
          );
        case ackType:
          if (b.length < 17) return null;
          return AckPacket(
            msgId: bd.getUint32(1),
            to: bd.getUint32(5),
            total: bd.getUint16(9),
            nextMissing: bd.getUint16(11),
            bitmap: bd.getUint32(13),
          );
      }
    } catch (_) {}
    return null;
  }
}

class ChunkPacket implements DataPacket {
  ChunkPacket({
    required this.msgId,
    required this.to,
    required this.index,
    required this.total,
    required this.durationMs,
    required this.channelMessage,
    required this.data,
  });

  static const int headerSize = 18;

  @override
  final int msgId;
  @override
  final int to;
  final int index;
  final int total;
  final int durationMs;

  /// Sent to a whole channel rather than one person.
  final bool channelMessage;
  final Uint8List data;

  @override
  Uint8List encode() {
    final out = Uint8List(headerSize + data.length);
    ByteData.sublistView(out)
      ..setUint8(0, DataPacket.chunkType)
      ..setUint32(1, msgId)
      ..setUint32(5, to)
      ..setUint16(9, index)
      ..setUint16(11, total)
      ..setUint32(13, durationMs)
      ..setUint8(17, channelMessage ? 1 : 0);
    out.setRange(headerSize, out.length, data);
    return out;
  }
}

class AckPacket implements DataPacket {
  AckPacket({
    required this.msgId,
    required this.to,
    required this.total,
    required this.nextMissing,
    required this.bitmap,
  });

  @override
  final int msgId;
  @override
  final int to;
  final int total;
  final int nextMissing;
  final int bitmap;

  bool get complete => nextMissing >= total;

  /// Every chunk index this ack confirms.
  Iterable<int> get ackedIndexes sync* {
    for (var i = 0; i < nextMissing && i < total; i++) {
      yield i;
    }
    for (var b = 0; b < 32; b++) {
      if ((bitmap >> b) & 1 == 1) {
        final i = nextMissing + 1 + b;
        if (i < total) yield i;
      }
    }
  }

  @override
  Uint8List encode() {
    final out = Uint8List(17);
    ByteData.sublistView(out)
      ..setUint8(0, DataPacket.ackType)
      ..setUint32(1, msgId)
      ..setUint32(5, to)
      ..setUint16(9, total)
      ..setUint16(11, nextMissing)
      ..setUint32(13, bitmap);
    return out;
  }
}

/// Chunk size for Bluetooth: 12 byte frame header + 18 byte chunk header +
/// 150 = 180 bytes, one BLE packet at the usual negotiated MTU (185) and
/// within the 15-fragment limit even at the 23 byte default MTU.
const int bleChunkSize = 150;

/// Chunk size for Wi-Fi / internet (well under a UDP packet).
const int fastChunkSize = 1000;

const int defaultChunkSize = bleChunkSize;

List<Uint8List> splitBody(Uint8List body, {int chunkSize = defaultChunkSize}) {
  if (body.isEmpty) return [Uint8List(0)];
  return [
    for (var o = 0; o < body.length; o += chunkSize)
      Uint8List.sublistView(
        body,
        o,
        o + chunkSize > body.length ? body.length : o + chunkSize,
      ),
  ];
}

/// Pacing for one link type.
class TransferPacing {
  const TransferPacing({
    required this.window,
    required this.burst,
    required this.rto,
  });

  /// Max chunks sent but not acked.
  final int window;

  /// Max chunks sent per tick.
  final int burst;

  /// Resend a chunk if not acked after this long.
  final Duration rto;

  static const fast = TransferPacing(
    window: 64,
    burst: 16,
    rto: Duration(milliseconds: 400),
  );
  static const ble = TransferPacing(
    window: 12,
    burst: 3,
    rto: Duration(milliseconds: 1500),
  );
}

/// Sending side of one message to one recipient.
class TransferSender {
  TransferSender({
    required this.msgId,
    required this.to,
    required Uint8List body,
    required this.durationMs,
    required this.channelMessage,
    required DateTime now,
    int chunkSize = defaultChunkSize,
  }) : chunks = splitBody(body, chunkSize: chunkSize),
       lastProgress = now;

  final int msgId;
  final int to;
  final int durationMs;
  final bool channelMessage;
  final List<Uint8List> chunks;
  final Set<int> acked = {};
  final Map<int, DateTime> _sentAt = {};
  DateTime lastProgress;
  int sentCount = 0;

  int get total => chunks.length;
  bool get complete => acked.length >= total;
  double get progress => total == 0 ? 1 : acked.length / total;

  /// Encoded chunk packets that should go out now.
  List<Uint8List> due(DateTime now, TransferPacing pacing) {
    final out = <Uint8List>[];
    var inFlight = 0;
    for (final e in _sentAt.entries) {
      if (!acked.contains(e.key) && now.difference(e.value) < pacing.rto) {
        inFlight++;
      }
    }
    for (var i = 0; i < total && out.length < pacing.burst; i++) {
      if (acked.contains(i)) continue;
      final sent = _sentAt[i];
      final timedOut = sent != null && now.difference(sent) >= pacing.rto;
      if (sent != null && !timedOut) continue;
      if (!timedOut && inFlight >= pacing.window) break;
      _sentAt[i] = now;
      if (!timedOut) inFlight++;
      sentCount++;
      out.add(
        ChunkPacket(
          msgId: msgId,
          to: to,
          index: i,
          total: total,
          durationMs: durationMs,
          channelMessage: channelMessage,
          data: chunks[i],
        ).encode(),
      );
    }
    return out;
  }

  /// Returns true if the ack confirmed something new.
  bool onAck(AckPacket a, DateTime now) {
    if (a.msgId != msgId) return false;
    final before = acked.length;
    if (a.complete) {
      for (var i = 0; i < total; i++) {
        acked.add(i);
      }
    } else {
      acked.addAll(a.ackedIndexes);
    }
    if (acked.length > before) {
      lastProgress = now;
      return true;
    }
    return false;
  }
}

/// Receiving side of one message from one sender.
class TransferReceiver {
  TransferReceiver({
    required this.sender,
    required this.msgId,
    required this.total,
    required this.durationMs,
    required this.channelMessage,
    required DateTime now,
  }) : lastActivity = now;

  final int sender;
  final int msgId;
  final int total;
  final int durationMs;
  final bool channelMessage;
  final Map<int, Uint8List> _parts = {};
  DateTime lastActivity;

  /// Chunks received since the last ack was sent.
  int unacked = 0;

  bool get complete => _parts.length >= total;
  int get received => _parts.length;

  /// Returns true if [c] was new.
  bool add(ChunkPacket c, DateTime now) {
    lastActivity = now;
    if (c.total != total || c.index >= total) return false;
    if (_parts.containsKey(c.index)) return false;
    _parts[c.index] = c.data;
    unacked++;
    return true;
  }

  int get nextMissing {
    var i = 0;
    while (i < total && _parts.containsKey(i)) {
      i++;
    }
    return i;
  }

  AckPacket ack() {
    final next = nextMissing;
    var bitmap = 0;
    for (var b = 0; b < 32; b++) {
      if (_parts.containsKey(next + 1 + b)) bitmap |= 1 << b;
    }
    unacked = 0;
    return AckPacket(
      msgId: msgId,
      to: sender,
      total: total,
      nextMissing: next,
      bitmap: bitmap,
    );
  }

  Uint8List assemble() {
    final b = BytesBuilder(copy: false);
    for (var i = 0; i < total; i++) {
      b.add(_parts[i]!);
    }
    return b.takeBytes();
  }
}
