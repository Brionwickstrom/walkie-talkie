import 'dart:convert';

import '../lora/meshtastic_channels.dart';

/// An open Walkie channel shared with a Meshtastic channel (v1.9.7):
/// Walkie's LoRa traffic for that channel goes out on the Meshtastic
/// channel (still Walkie packets on PRIVATE_APP, which the stock apps
/// ignore). Saved by name + hash ([ref]) only: no key, no slot index (the
/// slot is looked up on each radio).
class MeshLink {
  MeshLink({
    required this.ref,
    this.preset = '',
    this.keyKind = MeshKeyKind.custom,
    this.uplink = false,
    this.created = 0,
  });

  final MeshChannelRef ref;

  /// Preset label of the QR ("LongFast"), '' if unknown.
  final String preset;
  final MeshKeyKind keyKind;

  /// The QR had MQTT uplink on.
  final bool uplink;
  final int created;

  Map<String, Object?> toJson() => {
    ...ref.toJson(),
    if (preset.isNotEmpty) 'preset': preset,
    'key': keyKind.name,
    if (uplink) 'up': 1,
    't': created,
  };

  static MeshLink? fromJson(Object? j) {
    final ref = MeshChannelRef.fromJson(j);
    if (ref == null || j is! Map) return null;
    final k = j['key'];
    return MeshLink(
      ref: ref,
      preset: j['preset'] is String ? j['preset'] as String : '',
      keyKind: MeshKeyKind.values.firstWhere(
        (v) => v.name == k,
        orElse: () => MeshKeyKind.custom,
      ),
      uplink: j['up'] == 1,
      created: (j['t'] as num?)?.toInt() ?? 0,
    );
  }

  static String encodeMap(Map<int, MeshLink> m) =>
      jsonEncode({for (final e in m.entries) '${e.key}': e.value.toJson()});

  static Map<int, MeshLink> decodeMap(String? s) {
    final out = <int, MeshLink>{};
    if (s == null || s.isEmpty) return out;
    try {
      final j = jsonDecode(s);
      if (j is! Map) return out;
      j.forEach((k, v) {
        final ch = int.tryParse('$k');
        final l = MeshLink.fromJson(v);
        if (ch != null && ch >= 1 && ch <= 16 && l != null) out[ch] = l;
      });
    } catch (_) {}
    return out;
  }

  @override
  String toString() => 'MeshLink($ref)';
}
