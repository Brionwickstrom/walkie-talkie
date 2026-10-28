/// Handing a private group to a friend (v2.3.0).
///
/// "Add people": the admin (or any member) picks friends and the group
/// goes to each of them as a Direct chat message. The group's secret is
/// sealed once more with the friend pair key, with the same
/// [PeerBox.sealShared] box the admin's passcode hand-off ([Rekey], v1.9.4)
/// uses. The box is bound (AES-GCM aad) to the group id, the sender and
/// the receiver, so a copy cannot be replayed to another phone or group,
/// and the secret is never written into chat history (only the name).
///
/// A friend who is out of reach gets it when they are back (Direct chat
/// keeps it up to 24 hours). People who are not friends join with the
/// group's code or QR instead.
library;

import '../core/peer_box.dart';
import 'groups.dart';
import 'passcodes.dart';

class GroupHandoff {
  static String aad(String groupId, int from, int to) =>
      'group/$groupId/${from.toRadixString(16)}>${to.toRadixString(16)}';

  /// The invitation header (ChatBody `gi`) for [to].
  static Map<String, Object?> build({
    required PrivateGroup group,
    required int from,
    required int to,
    required List<int> friendSecret,
  }) {
    final ci = GroupColors.palette.indexOf(group.color);
    return {
      'g': group.id,
      'n': group.name,
      if (group.emoji.isNotEmpty) 'e': group.emoji,
      if (ci >= 0) 'c': ci,
      'lc': ?group.legacyChannel,
      'x': PeerBox.sealShared(
        friendSecret,
        group.secret,
        label: 'group',
        aad: aad(group.id, from, to),
      ),
    };
  }

  /// The group in [invite] (sent by [from] to [me]), marked as invited, or
  /// null when it is not for us, was changed, or is not valid.
  static PrivateGroup? open({
    required Map<String, Object?> invite,
    required int from,
    required int me,
    required List<int> friendSecret,
    String? fromName,
  }) {
    final id = invite['g'];
    if (id is! String || !GroupIds.valid(id)) return null;
    final secret = PeerBox.openShared(
      friendSecret,
      invite['x'],
      label: 'group',
      aad: aad(id, from, me),
    );
    if (secret == null || secret.length < Passcodes.minJoin) return null;
    String clip(Object? s, int n) =>
        s is String ? (s.length > n ? s.substring(0, n) : s) : '';
    final ci = (invite['c'] as num?)?.toInt();
    final lc = (invite['lc'] as num?)?.toInt();
    final name = clip(invite['n'], 30).trim();
    return PrivateGroup(
      id: id,
      name: name.isEmpty ? 'Private group' : name,
      emoji: clip(invite['e'], 8),
      color: ci != null && ci >= 0 && ci < GroupColors.palette.length
          ? GroupColors.palette[ci]
          : GroupColors.palette.first,
      secret: secret,
      legacyChannel: lc != null && lc >= 1 && lc <= 16 ? lc : null,
      invited: true,
      invitedBy: fromName,
    );
  }
}
