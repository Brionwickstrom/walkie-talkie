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
/// * the older private-channel QR text "Walkie Talkie private channel\nCH 3
///   \nPasscode: ...".
///
/// The Meshtastic radio channel key (PSK) is never part of an invite.
library;

import '../core/pair_key.dart';

class Invite {
  const Invite({this.channel, this.passcode, this.name, this.friendCode});

  /// Channel number 1..[maxChannel], or null (friend add only).
  final int? channel;

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
  bool get hasChannel => channel != null;
  bool get hasFriend => friendCode != null;
  bool get isEmpty => !hasChannel && !hasFriend;

  Map<String, String> get _params => {
    'v': '1',
    if (channel != null) 'ch': '$channel',
    if (isPrivate) 'p': passcode!,
    if (name != null && name!.isNotEmpty) 'n': name!,
    'f': ?friendCode,
  };

  String get _query => Uri(queryParameters: _params).query;

  /// Deep link that opens the app.
  String get appLink => '$scheme://join?$_query';

  /// Web fallback (the download page; the app reads the fragment).
  String get webLink => '$httpsBase#wt-join?$_query';

  /// Text for the share sheet.
  String shareText() {
    final what = [
      if (hasChannel) 'join ${isPrivate ? 'private ' : ''}channel CH $channel',
      if (hasFriend) 'add me as a friend',
    ].join(' and ');
    return 'Walkie Talkie: $what.\n'
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
    final f = q['f'];
    final friend = f != null && PairKey.parseQr(f) != null ? f : null;
    final inv = Invite(
      channel: validCh,
      passcode: validCh != null && p != null && p.isNotEmpty ? p : null,
      name: q['n'],
      friendCode: friend,
    );
    return inv.isEmpty ? null : inv;
  }

  static Invite? _legacyPrivate(String text) {
    final m = RegExp(
      r'Walkie Talkie private channel\s*:?\s*CH\s*(\d+)\s*,?\s*passcode:\s*(.+)',
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
