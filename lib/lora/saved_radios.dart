import 'dart:convert';

import 'stream_radio.dart';

/// A radio the app remembers (v2.5.4): Settings > Long-range radio >
/// Saved radios. Only one is connected at a time.
class SavedRadio {
  SavedRadio({
    required this.id,
    this.name,
    this.shortName,
    this.nodeId,
    this.label,
    this.lastConnected,
  });

  /// Bluetooth id, "serial:COM7" or "tcp:host:port".
  String id;

  /// The radio's own long name (read from the radio, kept up to date), or
  /// the name it advertised when it was added.
  String? name;
  String? shortName;

  /// The Meshtastic node number, once the radio has been connected.
  int? nodeId;

  /// A name the user gave it here; empty / null = use [name].
  String? label;
  DateTime? lastConnected;

  bool get isSerial => StreamRadioId.serialPort(id) != null;
  bool get isWifi => StreamRadioId.tcpTarget(id) != null;

  /// What the list shows.
  String get title {
    final l = label?.trim() ?? '';
    if (l.isNotEmpty) return l;
    final n = name?.trim() ?? '';
    if (n.isNotEmpty) return n;
    return StreamRadioId.isStream(id) ? StreamRadioId.label(id) : 'Radio';
  }

  /// "Bluetooth", "USB cable on COM7", "Wi-Fi 192.168.1.40".
  String get kind {
    final p = StreamRadioId.serialPort(id);
    if (p != null) return 'USB cable on $p';
    final t = StreamRadioId.tcpTarget(id);
    if (t != null) {
      return 'Wi-Fi ${t.host}${t.port == StreamRadioId.defaultTcpPort ? '' : ':${t.port}'}';
    }
    return 'Bluetooth';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    if (name != null && name!.isNotEmpty) 'name': name,
    if (shortName != null && shortName!.isNotEmpty) 'short': shortName,
    if (nodeId != null) 'node': nodeId,
    if (label != null && label!.isNotEmpty) 'label': label,
    if (lastConnected != null) 'last': lastConnected!.millisecondsSinceEpoch,
  };

  static SavedRadio? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    final last = j['last'];
    return SavedRadio(
      id: id,
      name: j['name'] is String ? j['name'] as String : null,
      shortName: j['short'] is String ? j['short'] as String : null,
      nodeId: j['node'] is int ? j['node'] as int : null,
      label: j['label'] is String ? j['label'] as String : null,
      lastConnected: last is int
          ? DateTime.fromMillisecondsSinceEpoch(last)
          : null,
    );
  }

  static String encodeList(List<SavedRadio> l) =>
      jsonEncode([for (final r in l) r.toJson()]);

  static List<SavedRadio> decodeList(String? s) {
    if (s == null || s.isEmpty) return [];
    try {
      final j = jsonDecode(s);
      if (j is! List) return [];
      final out = <SavedRadio>[];
      for (final e in j) {
        final r = fromJson(e);
        if (r != null && !out.any((o) => o.id == r.id)) out.add(r);
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}

/// "just now", "5 min ago", "3 h ago", "2 days ago".
String radioSeen(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}
