import 'dart:convert';

import 'frame.dart';
import 'peer_box.dart';

/// How the admin hands remaining members a new passcode after removing
/// someone from a private channel ([ControlKind.rekey], v1.9.4).
///
/// The rekey travels inside the channel's encryption, which the removed
/// phone can still open (it knows the old passcode). Before 1.9.4 the new
/// passcode was in there in the clear (`pc`), so a modified app on the
/// removed phone could read it. Now every phone on 1.9.4+ gets its own
/// copy that only it can open (`k: 2`):
///
/// * `friend` (`pf`): sealed with the admin's friend pair key with that
///   phone: only the two of them can make or read it.
/// * `key` (`pk` + `pcx`): sealed to the phone's own key (`kx` in its
///   hellos, X25519 with the admin's key). The removed phone sees the box
///   but cannot open it.
/// * `legacy` (`pc`): phones older than 1.9.4 only read the clear copy,
///   exactly as before (no worse than today). The admin is told who got it
///   that way, since the removed phone could read that copy.
/// * `conflict`: two different keys claim to be that phone right now
///   (someone fakes its hellos): nothing is sent, the admin gives that
///   phone the passcode in person.
///
/// A box is bound to its round id, sender and receiver (AES-GCM aad), so
/// it cannot be replayed to another phone or round.
class Rekey {
  static String aad(int rid, int from, int to) =>
      'rekey/$rid/${from.toRadixString(16)}>${to.toRadixString(16)}';

  /// The rekey `x` for member [to] (null with how `conflict`).
  static ({Map<String, Object?>? x, String how}) build({
    required int from,
    required int to,
    required int rid,
    required String passcode,
    required int removed,
    required int toFeature,
    required Map<String, DateTime> toKx,
    PeerBox? box,
    List<int>? friendSecret,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    final a = aad(rid, from, to);
    final ex = [removed];
    if (toFeature >= peerBoxFeature) {
      if (friendSecret != null) {
        return (
          x: {
            'k': 2,
            'ex': ex,
            'pf': PeerBox.sealShared(
              friendSecret,
              passcode,
              label: 'rekey',
              aad: a,
            ),
          },
          how: 'friend',
        );
      }
      if (KxBook.conflictIn(toKx, t)) return (x: null, how: 'conflict');
      final kx = KxBook.keyIn(toKx, t);
      final sealed = kx == null
          ? null
          : box?.sealText(kx, passcode, label: 'rekey', aad: a);
      if (sealed != null) {
        return (
          x: {'k': 2, 'ex': ex, 'pk': box!.publicKey, 'pcx': sealed},
          how: 'key',
        );
      }
    }
    return (x: {'pc': passcode, 'ex': ex}, how: 'legacy');
  }

  /// The new passcode in rekey [x] (round [rid]) from admin [from] to me
  /// ([me]), or null if it is not for us / does not open / is too short.
  static String? open({
    required int from,
    required int me,
    required int rid,
    required Map<String, Object?> x,
    required Map<String, DateTime> fromKx,
    PeerBox? box,
    List<int>? friendSecret,
    int minLength = 6,
    DateTime? now,
  }) {
    String? pc;
    if (x['k'] == 2) {
      final a = aad(rid, from, me);
      if (x['pf'] != null) {
        if (friendSecret == null) return null;
        pc = PeerBox.openShared(friendSecret, x['pf'], label: 'rekey', aad: a);
      } else {
        final pk = x['pk'];
        if (box == null || pk is! String) return null;
        // Only the admin's own key (the one in its hellos, no look-alike).
        if (KxBook.keyIn(fromKx, now ?? DateTime.now()) != pk) return null;
        pc = box.openText(pk, x['pcx'], label: 'rekey', aad: a);
      }
    } else {
      final v = x['pc'];
      pc = v is String ? v : null;
    }
    if (pc == null || pc.length < minLength) return null;
    return pc;
  }
}

/// Direct link setup ([ControlKind.dx], v1.9.4) sealed to the other
/// phone's own key, so nobody else in the relay room (a hidden listener
/// on an open channel, a removed member on a private one) learns its
/// addresses or link tokens. Phones on older apps (or before their key is
/// known) get the plain message as before.
class DirectSeal {
  static String aad(int from, int to) =>
      'dx/${from.toRadixString(16)}>${to.toRadixString(16)}';

  static Map<String, Object?> seal({
    required int from,
    required int to,
    required Map<String, Object?> x,
    required int toFeature,
    required Map<String, DateTime> toKx,
    PeerBox? box,
    DateTime? now,
  }) {
    if (box == null || toFeature < peerBoxFeature) return x;
    final kx = KxBook.keyIn(toKx, now ?? DateTime.now());
    if (kx == null) return x;
    final e = box.sealText(kx, jsonEncode(x), label: 'dx', aad: aad(from, to));
    return e == null ? x : {'e': e, 'pk': box.publicKey};
  }

  /// [x] opened if sealed (null if it does not open), else unchanged.
  static Map<String, Object?>? open({
    required int from,
    required int me,
    required Map<String, Object?> x,
    required Map<String, DateTime> fromKx,
    PeerBox? box,
    DateTime? now,
  }) {
    if (!x.containsKey('e')) return x;
    final pk = x['pk'];
    if (box == null || pk is! String) return null;
    if (KxBook.keyIn(fromKx, now ?? DateTime.now()) != pk) return null;
    final t = box.openText(pk, x['e'], label: 'dx', aad: aad(from, me));
    if (t == null) return null;
    try {
      final j = jsonDecode(t);
      return j is Map<String, Object?> ? j : null;
    } catch (_) {
      return null;
    }
  }
}
