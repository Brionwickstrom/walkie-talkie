/// Private groups (v2.3.0).
///
/// CH 1-16 are open channels only: no passcodes, no members. A private
/// group is a separate thing with its own random id, a name, a colour and
/// an emoji, and a secret (a generated passcode, or one typed). It is not
/// tied to any channel number, and the number never goes on the air for it:
/// frames carry only a 16 bit tag made from the key.
///
/// Key: PBKDF2(secret) salted with the group id ([ChannelKey.deriveGroup]).
///
/// Groups made before v2.3.0 were "CH 3 + passcode". They are converted
/// automatically ("CH 3 group") and keep their old key derivation
/// ([PrivateGroup.legacyChannel]), so they still work with phones on older
/// versions that only know CH 3 + the passcode.
library;

import 'dart:convert';
import 'dart:math';

import '../core/channel_crypto.dart';

/// The colours a group can wear (ARGB).
class GroupColors {
  static const List<int> palette = [
    0xFF1E88E5, // blue
    0xFF43A047, // green
    0xFFF4511E, // orange
    0xFF8E24AA, // purple
    0xFFE53935, // red
    0xFF00897B, // teal
    0xFFFDD835, // yellow
    0xFF6D4C41, // brown
  ];

  static const List<String> names = [
    'Blue',
    'Green',
    'Orange',
    'Purple',
    'Red',
    'Teal',
    'Yellow',
    'Brown',
  ];

  /// A colour for a new group: the first one not used yet.
  static int next(Iterable<int> used) {
    final u = used.toSet();
    for (final c in palette) {
      if (!u.contains(c)) return c;
    }
    return palette[u.length % palette.length];
  }

  static bool valid(int c) => palette.contains(c);
}

class GroupIds {
  /// A new random group id: 16 hex characters.
  static String generate([Random? rng]) {
    final r = rng ?? Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// Id of a group converted from "CH [n] + passcode".
  static String legacy(int channel) => 'ch$channel';

  static final _ok = RegExp(r'^[A-Za-z0-9_-]{3,32}$');
  static bool valid(String? id) => id != null && _ok.hasMatch(id);
}

class PrivateGroup {
  PrivateGroup({
    required this.id,
    required this.name,
    this.emoji = '',
    required this.color,
    required this.secret,
    this.legacyChannel,
    this.invited = false,
    this.invitedBy,
    this.autoNamed = false,
    this.adminId,
    this.scope,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  /// Random id (hex), or "chN" for a converted CH N group.
  final String id;
  String name;
  String emoji;

  /// ARGB, one of [GroupColors.palette].
  int color;

  /// Passcode / secret the key is made from.
  String secret;

  /// Set for groups from before v2.3.0: the key is derived with this old
  /// channel number (not the id) so phones on older versions still match.
  /// The number is never sent.
  int? legacyChannel;

  /// A friend sent an invitation that is not accepted yet (not joined).
  bool invited;
  String? invitedBy;

  /// The name is the placeholder ("CH 3 group"), so a real name learned
  /// from the group's admin may replace it.
  bool autoNamed;

  /// Admin's phone id, when known.
  int? adminId;

  /// Frame scope (0x10000 | tag) once the key was made; null before.
  int? scope;
  final int createdAt;

  bool get isLegacy => legacyChannel != null;

  /// "🔥 Family".
  String get label => [emoji, name].where((s) => s.isNotEmpty).join(' ').trim();

  /// Same key (used to spot a group we already have).
  String get keyId => isLegacy
      ? 'ch$legacyChannel\u0000${ChannelKey.normalize(secret)}'
      : '$id\u0000${ChannelKey.normalize(secret)}';

  bool sameKeyAs(PrivateGroup o) => keyId == o.keyId;

  /// Derive the key (slow on purpose: runs in an isolate).
  Future<ChannelKey> deriveKey({bool inline = false}) {
    final n = legacyChannel;
    if (n != null) {
      return inline
          ? ChannelKey.deriveInline(n, secret)
          : ChannelKey.derive(n, secret);
    }
    return inline
        ? ChannelKey.deriveGroupInline(id, secret)
        : ChannelKey.deriveGroup(id, secret);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    if (emoji.isNotEmpty) 'e': emoji,
    'c': color,
    's': secret,
    'lc': ?legacyChannel,
    if (invited) 'inv': 1,
    if (invitedBy != null) 'by': invitedBy,
    if (autoNamed) 'an': 1,
    'ad': ?adminId,
    'sc': ?scope,
    'at': createdAt,
  };

  static PrivateGroup? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], n = j['n'], s = j['s'];
    if (id is! String || !GroupIds.valid(id) || n is! String) return null;
    if (s is! String || s.isEmpty) return null;
    final c = j['c'];
    final lc = (j['lc'] as num?)?.toInt();
    return PrivateGroup(
      id: id,
      name: n,
      emoji: j['e'] is String ? j['e'] as String : '',
      color: c is num && GroupColors.valid(c.toInt())
          ? c.toInt()
          : GroupColors.palette.first,
      secret: s,
      legacyChannel: lc != null && lc >= 1 && lc <= 16 ? lc : null,
      invited: j['inv'] == 1,
      invitedBy: j['by'] is String ? j['by'] as String : null,
      autoNamed: j['an'] == 1,
      adminId: (j['ad'] as num?)?.toInt(),
      scope: (j['sc'] as num?)?.toInt(),
      createdAt: (j['at'] as num?)?.toInt(),
    );
  }

  static String encodeList(List<PrivateGroup> l) =>
      jsonEncode([for (final g in l) g.toJson()]);

  static List<PrivateGroup> decodeList(String? s) {
    if (s == null || s.isEmpty) return [];
    try {
      final j = jsonDecode(s);
      if (j is! List) return [];
      final out = <PrivateGroup>[];
      for (final x in j) {
        final g = PrivateGroup.fromJson(x);
        if (g != null && !out.any((o) => o.id == g.id)) out.add(g);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// "CH 3 group" for a converted group.
  static String legacyName(int channel) => 'CH $channel group';

  /// Convert the old "channel number -> passcode" map into groups.
  /// Deterministic ids, so converting twice never doubles a group.
  static List<PrivateGroup> migrate(Map<int, String> legacy) {
    final keys = legacy.keys.toList()..sort();
    final out = <PrivateGroup>[];
    for (final ch in keys) {
      final p = legacy[ch]!;
      if (ch < 1 || ch > 16 || p.trim().isEmpty) continue;
      out.add(
        PrivateGroup(
          id: GroupIds.legacy(ch),
          name: legacyName(ch),
          color: GroupColors.next(out.map((g) => g.color)),
          secret: p,
          legacyChannel: ch,
          autoNamed: true,
        ),
      );
    }
    return out;
  }

  /// The pre-2.3.0 map for the groups that have a channel number (kept in
  /// the old settings key too, so going back to an older app keeps them).
  static Map<int, String> toLegacyMap(Iterable<PrivateGroup> l) => {
    for (final g in l)
      if (g.legacyChannel != null && !g.invited) g.legacyChannel!: g.secret,
  };
}
