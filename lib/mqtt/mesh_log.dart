// Mesh packets from the private broker, for the NAS node log and the
// signal half of range data (v2.6.15).
//
// Encryption stays on, so the payload is not decoded and is not stored.
// A JSON publish (encryption off) is counted and dropped. Channel keys,
// channel URLs and broker passwords are not fields of a log record.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lora/meshtastic_proto.dart';
import '../lora/protobuf.dart';

/// Why a publish was not stored. A fixed word, never the body or the topic.
enum MqttIgnore { offRoot, json, undecodable, empty, tooBig }

class MeshLogRecord {
  const MeshLogRecord({
    required this.from,
    required this.to,
    required this.packetId,
    required this.snr,
    required this.rssi,
    required this.hops,
    required this.channelName,
    required this.gatewayId,
    required this.encrypted,
    required this.plaintext,
    required this.at,
  });

  final int from;
  final int to;
  final int packetId;
  final double snr;
  final int rssi;
  final int? hops;
  final String channelName;
  final String gatewayId;

  /// The payload was the encrypted form (or there was no decoded payload).
  final bool encrypted;

  /// A decoded payload was present. It was discarded.
  final bool plaintext;
  final DateTime at;

  bool get hasSignal => snr != 0 || rssi != 0;

  String get nodeId => meshNodeHex(from);

  /// One range-data line: signal, hops, who, which gateway. No position,
  /// because that stays inside the encrypted payload.
  String rangeLine() {
    final m = <String, Object?>{
      't': at.millisecondsSinceEpoch,
      'from': nodeId,
      'enc': encrypted,
      if (snr != 0) 'snr': snr,
      if (rssi != 0) 'rssi': rssi,
      if (hops != null) 'hops': hops,
      if (gatewayId.isNotEmpty) 'gw': gatewayId,
      if (channelName.isNotEmpty) 'ch': channelName,
    };
    return jsonEncode(m);
  }

  Map<String, Object?> nodeJson(int packets) => {
    'id': nodeId,
    'last': at.millisecondsSinceEpoch,
    'n': packets,
    'enc': encrypted,
    if (plaintext) 'plaintext': true,
    if (snr != 0) 'snr': snr,
    if (rssi != 0) 'rssi': rssi,
    if (hops != null) 'hops': hops,
    if (gatewayId.isNotEmpty) 'gw': gatewayId,
    if (channelName.isNotEmpty) 'ch': channelName,
  };
}

class PublishTake {
  const PublishTake.record(this.record) : ignore = null;
  const PublishTake.ignore(this.ignore) : record = null;
  final MeshLogRecord? record;
  final MqttIgnore? ignore;
}

String meshNodeHex(int n) =>
    '!${(n & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

/// A channel name as Meshtastic sends it (short, no key material).
String safeChannelName(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t.length > 40) return '';
  if (RegExp(r'[^A-Za-z0-9 _.\-]').hasMatch(t)) return '';
  return t;
}

String safeGateway(String raw) {
  final t = raw.trim();
  if (RegExp(r'^!?[0-9a-fA-F]{1,8}$').hasMatch(t)) {
    final hex = t.startsWith('!') ? t.substring(1) : t;
    return '!${hex.toLowerCase().padLeft(8, '0')}';
  }
  return '';
}

/// One line for the container log. Header fields only.
String meshLogLine(MeshLogRecord r) =>
    'heard ${r.nodeId} ch=${r.channelName.isEmpty ? '-' : r.channelName} '
    'gw=${r.gatewayId.isEmpty ? '-' : r.gatewayId} '
    'enc=${r.encrypted} snr=${r.snr} rssi=${r.rssi}';

/// [body] is a Meshtastic ServiceEnvelope, or something to ignore.
PublishTake meshRecordFromPublish(
  Uint8List body, {
  required String topic,
  required String root,
  required DateTime at,
}) {
  if (body.length > 8192) return const PublishTake.ignore(MqttIgnore.tooBig);
  final prefix = root.endsWith('/') ? root : '$root/';
  if (topic != root && !topic.startsWith(prefix)) {
    return const PublishTake.ignore(MqttIgnore.offRoot);
  }
  if (topic.contains('/json/') || (body.isNotEmpty && body[0] == 0x7B)) {
    return const PublishTake.ignore(MqttIgnore.json);
  }
  try {
    Uint8List? packet;
    var channel = '';
    var gateway = '';
    for (final f in pbDecode(body)) {
      if (f.number == 1 && f.wireType == 2) packet = f.asBytes;
      if (f.number == 2 && f.wireType == 2) channel = f.asString;
      if (f.number == 3 && f.wireType == 2) gateway = f.asString;
    }
    if (packet == null) {
      return const PublishTake.ignore(MqttIgnore.undecodable);
    }
    final pkt = MeshPacketPb.decode(packet);
    if (pkt.from == 0) return const PublishTake.ignore(MqttIgnore.empty);
    return PublishTake.record(
      MeshLogRecord(
        from: pkt.from,
        to: pkt.to,
        packetId: pkt.id,
        snr: pkt.rxSnr,
        rssi: pkt.rxRssi,
        hops: pkt.hopsAway,
        channelName: safeChannelName(channel),
        gatewayId: safeGateway(gateway),
        encrypted: pkt.encrypted || pkt.decoded == null,
        plaintext: pkt.decoded != null && !pkt.encrypted,
        at: at,
      ),
    );
  } on PbFormatException {
    return const PublishTake.ignore(MqttIgnore.undecodable);
  } on RangeError {
    return const PublishTake.ignore(MqttIgnore.undecodable);
  }
}

class _NodeRow {
  _NodeRow(this.record, this.packets);
  MeshLogRecord record;
  int packets;
}

/// Node log (one row per radio) and range lines (one per signal sample).
class MqttLogStore {
  final Map<int, _NodeRow> _nodes = {};
  final List<String> rangeLines = [];
  final Set<int> _seen = {};
  int accepted = 0;
  int duplicates = 0;
  final Map<MqttIgnore, int> ignored = {};

  void ignore(MqttIgnore why) => ignored[why] = (ignored[why] ?? 0) + 1;

  /// False when this packet id was already stored.
  bool add(MeshLogRecord r) {
    if (r.packetId != 0) {
      final key = Object.hash(r.from, r.packetId);
      if (!_seen.add(key)) {
        duplicates++;
        return false;
      }
      if (_seen.length > 2048) {
        _seen.clear();
        _seen.add(key);
      }
    }
    accepted++;
    final row = _nodes[r.from];
    if (row == null) {
      _nodes[r.from] = _NodeRow(r, 1);
    } else {
      row.record = r;
      row.packets++;
    }
    if (r.hasSignal) rangeLines.add(r.rangeLine());
    return true;
  }

  String nodesJson() {
    final rows = _nodes.values.toList()
      ..sort((a, b) => b.record.at.compareTo(a.record.at));
    return jsonEncode({
      'nodes': [for (final r in rows) r.record.nodeJson(r.packets)],
    });
  }

  Map<String, Object?> status({required bool connected, DateTime? last}) => {
    'connected': connected,
    'accepted': accepted,
    'duplicates': duplicates,
    'ignored': ignored.map((k, v) => MapEntry(k.name, v)),
    if (last != null) 'lastPacket': last.toUtc().toIso8601String(),
  };
}

/// Writes [MqttLogStore] under [directory]: `nodes.json`, `range.jsonl`,
/// `status.json`. Range lines rotate at [maxRangeBytes].
class MqttLogFiles {
  MqttLogFiles(this.directory, {this.maxRangeBytes = 2 * 1024 * 1024});

  final Directory directory;
  final int maxRangeBytes;
  final store = MqttLogStore();
  DateTime? lastPacket;

  File get _nodes => File('${directory.path}/nodes.json');
  File get _range => File('${directory.path}/range.jsonl');
  File get _status => File('${directory.path}/status.json');

  void addTake(PublishTake take) {
    final rec = take.record;
    if (rec == null) {
      final why = take.ignore;
      if (why != null) store.ignore(why);
      _writeStatus(connected: true);
      return;
    }
    final fresh = store.add(rec);
    lastPacket = rec.at;
    if (fresh) {
      _writeNodes();
      if (rec.hasSignal) _appendRange(rec.rangeLine());
    }
    _writeStatus(connected: true);
  }

  void markConnected(bool connected) => _writeStatus(connected: connected);

  void _writeNodes() {
    directory.createSync(recursive: true);
    final tmp = File('${_nodes.path}.tmp');
    tmp.writeAsStringSync('${store.nodesJson()}\n', flush: true);
    tmp.renameSync(_nodes.path);
  }

  void _appendRange(String line) {
    directory.createSync(recursive: true);
    if (_range.existsSync() && _range.lengthSync() > maxRangeBytes) {
      final prev = File('${_range.path}.1');
      if (prev.existsSync()) prev.deleteSync();
      _range.renameSync(prev.path);
    }
    _range.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  void _writeStatus({required bool connected}) {
    directory.createSync(recursive: true);
    _status.writeAsStringSync(
      '${jsonEncode(store.status(connected: connected, last: lastPacket))}\n',
      flush: true,
    );
  }
}
