/// Invite links / QR codes (v1.8.7): share a channel (public CH or private
/// passcode) and/or a friend add.
///
/// Forms (all parsed by [Invite.parse]):
/// * `walkietalkie://join?v=1&ch=3&p=<passcode>&n=<name>&f=<friend code>`
///   (opens the app directly when installed);
/// * `https://github.com/Brionwickstrom/walkie-talkie/releases/latest#wt-join?...`
///   (same parameters after `#wt-join?`; phones without the app land on the
///   download page). The parameters are in the fragment, which browsers
///   never send to the server, so the passcode is not logged by GitHub;
/// * v2.3.0 private groups: `walkietalkie://join?v=2&g=ID&p=SECRET&gn=NAME
///   &ge=EMOJI&gc=COLOUR` (no channel number; a group made before 2.3.0
///   also carries `ch=3`, so phones on older versions can still join it);
/// * the older private-channel QR text "Walkie Talkie private channel\nCH 3
///   \nPasscode: ...".
///
/// The Meshtastic radio channel key (PSK) is never part of an invite.
library;

import '../core/pair_key.dart';
import 'groups.dart';

class Invite {
  const Invite({
    this.channel,
    this.passcode,
    this.name,
    this.friendCode,
    this.groupId,
    this.groupName,
    this.groupEmoji,
    this.groupColor,
  });

  /// Channel number 1..[maxChannel], or null (friend add only, or a
  /// v2.3.0 group). With a [passcode] it is the old number of a group made
  /// before 2.3.0 (that group's old key still uses it).
  final int? channel;

  /// v2.3.0: id of the private group; null for an open channel / old link.
  final String? groupId;

  /// Name, emoji and colour (ARGB) of the group, as the sender has them.
  final String? groupName;
  final String? groupEmoji;
  final int? groupColor;

  /// Private channel passcode, or null (public channel).
  final String? passcode;

  /// Who sent it (shown in the confirm dialog).
  final String? name;

  /// A `walkie-friend:` code (see [PairKey.qrText]), or null.
  final String? friendCode;

  static const scheme = 'walkietalkie';
  static const httpsBase =
      'https://github.com/Brionwickstrom/walkie-talkie/releases/latest';
  static const maxChannel = 16;

  bool get isPrivate => passcode != null && passcode!.isNotEmpty;

  /// A private group (new style, or an old "CH n + passcode" one).
  bool get hasGroup => isPrivate && (groupId != null || channel != null);

  /// An open channel to join (no passcode).
  bool get hasChannel => channel != null && !isPrivate;
  bool get hasFriend => friendCode != null;
  bool get isEmpty => !hasChannel && !hasGroup && !hasFriend;

  /// Only phones on 2.3.0 or newer can join this group (it has no channel
  /// number an older phone could use).
  bool get needsNewVersion => hasGroup && channel == null;

  /// Colour as a palette index for the link.
  int? get _colorIndex {
    final c = groupColor;
    if (c == null) return null;
    final i = GroupColors.palette.indexOf(c);
    return i < 0 ? null : i;
  }

  Map<String, String> get _params => {
    'v': groupId != null ? '2' : '1',
    if (channel != null) 'ch': '$channel',
    'g': ?groupId,
    if (isPrivate) 'p': passcode!,
    if (name != null && name!.isNotEmpty) 'n': name!,
    if (groupName != null && groupName!.isNotEmpty) 'gn': groupName!,
    if (groupEmoji != null && groupEmoji!.isNotEmpty) 'ge': groupEmoji!,
    if (_colorIndex != null) 'gc': '$_colorIndex',
    'f': ?friendCode,
  };

  String get _query => Uri(queryParameters: _params).query;

  /// Deep link that opens the app.
  String get appLink => '$scheme://join?$_query';

  /// Web fallback (the download page; the app reads the fragment).
  String get webLink => '$httpsBase#wt-join?$_query';

  /// Text for the share sheet.
  String shareText() {
    final g = [
      groupEmoji,
      groupName,
    ].whereType<String>().where((e) => e.isNotEmpty).join(' ');
    final what = [
      if (hasGroup)
        'join the private group${g.isEmpty ? '' : ' $g'}'
      else if (hasChannel)
        'join open channel CH $channel',
      if (hasFriend) 'add me as a friend',
    ].join(' and ');
    final note = needsNewVersion
        ? '\nNeeds Walkie Talkie 2.3.0 or newer: update the app first if '
              'you have an older version.'
        : '';
    return 'Walkie Talkie: $what.$note\n'
        'Open in the app: $appLink\n'
        'No app yet? Get it here (then open the link above): $webLink';
  }

  /// Parse any supported form; null when it is not an invite.
  static Invite? parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    // An invite inside a longer shared text: take the first link.
    final m = RegExp(
      r'(walkietalkie://join\?\S+|https://github\.com/\S*#wt-join\?\S+)',
    ).firstMatch(text);
    if (m != null) return _fromLink(m.group(1)!);
    return _legacyPrivate(text);
  }

  static Invite? _fromLink(String link) {
    String query;
    if (link.startsWith('$scheme://')) {
      final i = link.indexOf('?');
      query = i < 0 ? '' : link.substring(i + 1);
    } else {
      final i = link.indexOf('#wt-join?');
      query = link.substring(i + 9);
    }
    Map<String, String> q;
    try {
      q = Uri.splitQueryString(query);
    } catch (_) {
      return null;
    }
    final ch = int.tryParse(q['ch'] ?? '');
    final validCh = ch != null && ch >= 1 && ch <= maxChannel ? ch : null;
    final p = q['p'];
    final hasP = p != null && p.isNotEmpty;
    final g = q['g'];
    final gid = hasP && GroupIds.valid(g) ? g : null;
    final f = q['f'];
    final friend = f != null && PairKey.parseQr(f) != null ? f : null;
    final ci = int.tryParse(q['gc'] ?? '');
    String clip(String? s, int n) =>
        s == null ? '' : (s.length > n ? s.substring(0, n) : s);
    final inv = Invite(
      // A passcode needs a group id or a channel number to mean anything.
      channel: validCh,
      passcode: (validCh != null || gid != null) && hasP ? p : null,
      groupId: gid,
      groupName: gid == null ? null : clip(q['gn'], 30),
      groupEmoji: gid == null ? null : clip(q['ge'], 8),
      groupColor: gid != null && ci != null && ci >= 0 && ci < 8
          ? GroupColors.palette[ci]
          : null,
      name: q['n'],
      friendCode: friend,
    );
    return inv.isEmpty ? null : inv;
  }

  static Invite? _legacyPrivate(String text) {
    final m = RegExp(
      r'Walkie Talkie private (?:channel|group)\s*:?\s*CH\s*(\d+)\s*,?\s*passcode:\s*(.+)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(text);
    if (m == null) return null;
    final ch = int.tryParse(m.group(1)!);
    final p = m.group(2)!.trim();
    if (ch == null || ch < 1 || ch > maxChannel || p.isEmpty) return null;
    return Invite(channel: ch, passcode: p);
  }
}
