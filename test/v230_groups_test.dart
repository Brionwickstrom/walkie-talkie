// v2.3.0: private groups. CH 1-16 are open only; a private group has its own
// id, name, colour and secret and no channel number. Tests: the migration of
// "CH n + passcode" groups, key interop with phones on older versions, the
// invite links / QR text, the friend hand-off, and that nothing about a
// private group needs a channel number on the air.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/group_handoff.dart';
import 'package:walkie_talkie/app/groups.dart';
import 'package:walkie_talkie/app/invite.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/gateway_protocol.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/core/transport_manager.dart';
import 'package:walkie_talkie/transports/relay_transport.dart';

/// Fewer PBKDF2 rounds where the test only compares keys with each other.
const _fast = 600;

Frame _talk(int sender, int seq, [List<int> payload = const [1, 2, 3]]) =>
    Frame(
      type: FrameType.audio,
      senderId: sender,
      channel: 0,
      seq: seq,
      payload: Uint8List.fromList(payload),
    );

void main() {
  group('migration of "CH n + passcode" groups', () {
    test('each one becomes a named group that keeps its old key', () {
      final gs = PrivateGroup.migrate({7: 'bluebird77', 3: 'abcdef12'});
      expect(gs.map((g) => g.id), ['ch3', 'ch7'], reason: 'sorted by channel');
      expect(gs[0].name, 'CH 3 group');
      expect(gs[1].name, 'CH 7 group');
      expect(gs[0].legacyChannel, 3);
      expect(gs[0].isLegacy, isTrue);
      expect(gs[0].secret, 'abcdef12');
      expect(
        gs.every((g) => g.autoNamed),
        isTrue,
        reason:
            'name may be '
            'replaced by the real one learned from the group',
      );
      expect(gs[0].color, isNot(gs[1].color));
      expect(gs.every((g) => !g.invited), isTrue);
    });

    test('idempotent: converting again gives the same ids', () {
      final a = PrivateGroup.migrate({3: 'abcdef12'});
      final b = PrivateGroup.migrate({3: 'abcdef12'});
      expect(a.single.id, b.single.id);
      expect(a.single.keyId, b.single.keyId);
    });

    test('bad entries are skipped', () {
      final gs = PrivateGroup.migrate({0: 'abcdef', 17: 'abcdef', 5: '  '});
      expect(gs, isEmpty);
    });

    test('old settings: the group we were in stays the one we are in, '
        'CH n is open again', () async {
      SharedPreferences.setMockInitialValues({
        'node_id': 42,
        'channel': 3,
        'private_channels': AppSettings.encodePrivate({
          3: 'abcdef12',
          9: 'otherpass9',
        }),
      });
      const store = SharedPrefsSettingsStore();
      final s = await store.load(defaultChannel: 1);
      expect(s.groups.map((g) => g.id), ['ch3', 'ch9']);
      expect(s.activeGroup, 'ch3');
      expect(s.currentGroup?.name, 'CH 3 group');
      expect(
        s.channel,
        1,
        reason:
            'leaving the group lands on CH 1, not '
            'on the open CH 3',
      );
      // Saved in the new place; the old key stays for older apps.
      await store.save(s);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('private_groups'), isNotNull);
      expect(AppSettings.decodePrivate(prefs.getString('private_channels')), {
        3: 'abcdef12',
        9: 'otherpass9',
      });
      // Loading again does not convert twice.
      final again = await store.load(defaultChannel: 1);
      expect(again.groups.map((g) => g.id), ['ch3', 'ch9']);
      expect(again.activeGroup, 'ch3');
      expect(again.groups.first.secret, 'abcdef12');
      expect(again.groups.first.legacyChannel, 3);
    });

    test('old settings on an open channel stay on it', () async {
      SharedPreferences.setMockInitialValues({
        'node_id': 42,
        'channel': 5,
        'private_channels': AppSettings.encodePrivate({3: 'abcdef12'}),
      });
      final s = await const SharedPrefsSettingsStore().load(defaultChannel: 1);
      expect(s.channel, 5);
      expect(s.activeGroup, isNull);
      expect(s.groups.single.id, 'ch3');
    });

    test('a new install has no groups', () async {
      SharedPreferences.setMockInitialValues({});
      final s = await const SharedPrefsSettingsStore().load(defaultChannel: 1);
      expect(s.groups, isEmpty);
      expect(s.activeGroup, isNull);
    });

    test('groups survive a save and load; new ones are not written to the '
        'old key', () async {
      SharedPreferences.setMockInitialValues({'node_id': 42});
      const store = SharedPrefsSettingsStore();
      final s = await store.load(defaultChannel: 1);
      s.groups.addAll([
        PrivateGroup(
          id: 'a1b2c3d4e5f60718',
          name: 'Family',
          emoji: '🏕',
          color: GroupColors.palette[2],
          secret: 'correct-horse-staple',
          adminId: 77,
          scope: 0x1ABCD,
        ),
        PrivateGroup(
          id: 'ch4',
          name: 'CH 4 group',
          color: GroupColors.palette[0],
          secret: 'abcdef12',
          legacyChannel: 4,
          autoNamed: true,
        ),
        PrivateGroup(
          id: 'ffeeddccbbaa9988',
          name: 'Invite',
          color: GroupColors.palette[1],
          secret: 'invited-secret',
          legacyChannel: 6,
          invited: true,
          invitedBy: 'Bandit',
        ),
      ]);
      s.activeGroup = 'a1b2c3d4e5f60718';
      await store.save(s);
      final back = await store.load(defaultChannel: 1);
      expect(back.groups.length, 3);
      final fam = back.groupById('a1b2c3d4e5f60718')!;
      expect(fam.name, 'Family');
      expect(fam.emoji, '🏕');
      expect(fam.color, GroupColors.palette[2]);
      expect(fam.secret, 'correct-horse-staple');
      expect(fam.adminId, 77);
      expect(fam.scope, 0x1ABCD);
      expect(fam.isLegacy, isFalse);
      expect(back.activeGroup, 'a1b2c3d4e5f60718');
      expect(back.groupById('ch4')!.legacyChannel, 4);
      expect(back.groupById('ch4')!.autoNamed, isTrue);
      expect(back.groupById('ffeeddccbbaa9988')!.invited, isTrue);
      expect(back.groupById('ffeeddccbbaa9988')!.invitedBy, 'Bandit');
      // The old key only has the joined group that has a channel number.
      final prefs = await SharedPreferences.getInstance();
      expect(AppSettings.decodePrivate(prefs.getString('private_channels')), {
        4: 'abcdef12',
      });
    });

    test('a damaged group list is ignored, not a crash', () {
      expect(PrivateGroup.decodeList('not json'), isEmpty);
      expect(PrivateGroup.decodeList('{"a":1}'), isEmpty);
      expect(PrivateGroup.decodeList(null), isEmpty);
      final ok = {
        'id': 'abc123',
        'n': 'X',
        'c': GroupColors.palette[0],
        's': 'secret1',
      };
      final l = PrivateGroup.decodeList(
        jsonEncode([
          ok,
          ok, // a duplicate id
          {...ok, 'id': 'bad id!'},
          {...ok, 'id': 'zzz999', 's': ''},
          {...ok, 'id': 'ccc333', 'lc': 99}, // channel out of range
          'junk',
        ]),
      );
      expect(l.map((g) => g.id), ['abc123', 'ccc333']);
      expect(l.last.legacyChannel, isNull);
    });
  });

  group('keys: older phones still interoperate', () {
    test('the old and new salts are different, the old one unchanged', () {
      expect(ChannelKey.salt, 'WalkieTalkie/private-channel/v1/ch=');
      expect(ChannelKey.groupSalt, 'WalkieTalkie/private-group/v2/id=');
    });

    test('a converted group has the key an older phone derives from '
        '"CH n + passcode"', () async {
      final g = PrivateGroup.migrate({3: 'abcdef12'}).single;
      final mine = await g.deriveKey(inline: true);
      final theirs = await ChannelKey.deriveInline(3, 'abcdef12');
      expect(mine.tag, theirs.tag);
      expect(mine.fingerprint, theirs.fingerprint);
      // Audio sealed by the new app opens on the older phone, and back.
      final f = _talk(0x11, 5);
      final sealed = Frame.tryDecode(mine.seal(f))!;
      expect(sealed.type, FrameType.sealed);
      final opened = theirs.open(sealed)!;
      expect(opened.type, FrameType.audio);
      expect(opened.payload, f.payload);
      final back = Frame.tryDecode(theirs.seal(_talk(0x22, 6)))!;
      expect(mine.open(back)!.senderId, 0x22);
      // Same room on the relay and in the gateway.
      final scope = TransportManager.scopeFor(1, mine);
      expect(scope, TransportManager.scopeFor(3, theirs));
      expect(
        RelayTransport.roomFor(scope),
        'p${mine.tag.toRadixString(16).padLeft(4, '0')}',
      );
    });

    test('the secret is trimmed like before', () async {
      final a = await PrivateGroup.migrate({3: '  abcdef12 '}).single
          .deriveKey(inline: true);
      final b = await ChannelKey.deriveInline(3, 'abcdef12');
      expect(a.fingerprint, b.fingerprint);
    });

    test('a new group has its own key: the id matters, a channel number '
        'does not', () async {
      const secret = 'correct-horse-staple';
      final a = await ChannelKey.deriveGroupInline(
        'a1b2c3d4e5f60718',
        secret,
        iterations: _fast,
      );
      final b = await ChannelKey.deriveGroupInline(
        '0011223344556677',
        secret,
        iterations: _fast,
      );
      final a2 = await ChannelKey.deriveGroupInline(
        'a1b2c3d4e5f60718',
        ' $secret ',
        iterations: _fast,
      );
      expect(
        a.fingerprint,
        isNot(b.fingerprint),
        reason:
            'same secret, '
            'different group',
      );
      expect(a.fingerprint, a2.fingerprint);
      expect(a.groupId, 'a1b2c3d4e5f60718');
      // No channel number makes the same key (so an older phone cannot
      // stumble into it, and CH n never opens it).
      final sealed = Frame.tryDecode(a.seal(_talk(1, 1)))!;
      for (var ch = 1; ch <= 16; ch++) {
        final old = await ChannelKey.deriveInline(
          ch,
          secret,
          iterations: _fast,
        );
        expect(old.fingerprint, isNot(a.fingerprint), reason: 'CH $ch');
        expect(old.open(sealed), isNull, reason: 'CH $ch');
      }
      expect(b.open(sealed), isNull);
      expect(a2.open(sealed), isNotNull);
    });

    test('keyId: the same group + secret is the same key, a new secret is '
        'a new key', () {
      PrivateGroup g(String id, String s, {int? lc}) => PrivateGroup(
        id: id,
        name: 'x',
        color: GroupColors.palette[0],
        secret: s,
        legacyChannel: lc,
      );
      expect(g('abc', 'secret1').sameKeyAs(g('abc', ' secret1')), isTrue);
      expect(g('abc', 'secret1').sameKeyAs(g('abc', 'secret2')), isFalse);
      expect(g('abc', 'secret1').sameKeyAs(g('abd', 'secret1')), isFalse);
      // A legacy group is identified by its channel number.
      expect(
        g('ch3', 'secret1', lc: 3).sameKeyAs(g('ch3', 'secret1', lc: 3)),
        isTrue,
      );
      expect(
        g('ch3', 'secret1', lc: 3).sameKeyAs(g('ch4', 'secret1', lc: 4)),
        isFalse,
      );
    });

    test('a private group does not depend on a channel number: scope, room '
        'and gateway room come from the key only', () async {
      final k = await ChannelKey.deriveGroupInline(
        'a1b2c3d4e5f60718',
        'correct-horse-staple',
        iterations: _fast,
      );
      for (final ch in [1, 7, 16]) {
        expect(
          TransportManager.scopeFor(ch, k),
          TransportManager.scopeFor(2, k),
        );
      }
      final scope = TransportManager.scopeFor(1, k);
      expect(TransportManager.isPrivateScope(scope), isTrue);
      expect(scope & 0xFFFF, k.tag);
      final room = RelayTransport.roomFor(scope);
      expect(room, startsWith('p'));
      // Sealed frames: gateways and radios see the tag only.
      final sealed = Frame.tryDecode(k.seal(_talk(9, 2)))!;
      expect(sealed.channel, k.tag);
      expect(gatewayRoomOf(sealed), room);
      // The inner frame's channel is not on the air: opening gives the tag.
      expect(k.open(sealed)!.channel, k.tag);
    });
  });

  group('invites', () {
    test('an old "CH n + passcode" link still parses (and is a group)', () {
      final i = Invite.parse(
        'walkietalkie://join?v=1&ch=3&p=abcdef12&n=Bandit',
      )!;
      expect(i.channel, 3);
      expect(i.passcode, 'abcdef12');
      expect(i.name, 'Bandit');
      expect(i.hasGroup, isTrue);
      expect(i.groupId, isNull);
      expect(i.needsNewVersion, isFalse, reason: 'older phones can use it');
      expect(i.hasChannel, isFalse);
    });

    test('an old web link, inside a shared text, still parses', () {
      final i = Invite.parse(
        'Join us!\nhttps://github.com/Brionwickstrom/walkie-talkie/releases/'
        'latest#wt-join?v=1&ch=5&p=secret55\nthanks',
      )!;
      expect(i.channel, 5);
      expect(i.passcode, 'secret55');
      expect(i.hasGroup, isTrue);
    });

    test('the old private QR text still parses', () {
      final i = Invite.parse(
        'Walkie Talkie private channel\nCH 4\nPasscode: bluebird77',
      )!;
      expect(i.channel, 4);
      expect(i.passcode, 'bluebird77');
      expect(i.hasGroup, isTrue);
      expect(
        Invite.parse('Walkie Talkie private channel\nCH 99\nPasscode: x'),
        isNull,
      );
    });

    test('an open channel link is still just a channel', () {
      final i = Invite.parse('walkietalkie://join?v=1&ch=5')!;
      expect(i.hasChannel, isTrue);
      expect(i.hasGroup, isFalse);
      expect(i.channel, 5);
    });

    test('a v2.3.0 group invite carries the group id, name, emoji, '
        'colour and no channel number', () {
      const inv = Invite(
        groupId: 'a1b2c3d4e5f60718',
        passcode: 'correct-horse-staple',
        groupName: 'Family',
        groupEmoji: '🏕',
        groupColor: 0xFF43A047,
        name: 'Bandit',
      );
      expect(inv.hasGroup, isTrue);
      expect(inv.needsNewVersion, isTrue);
      expect(inv.appLink, isNot(contains('ch=')));
      for (final link in [inv.appLink, inv.webLink, inv.shareText()]) {
        final p = Invite.parse(link)!;
        expect(p.groupId, 'a1b2c3d4e5f60718');
        expect(p.passcode, 'correct-horse-staple');
        expect(p.groupName, 'Family');
        expect(p.groupEmoji, '🏕');
        expect(p.groupColor, 0xFF43A047);
        expect(p.channel, isNull);
        expect(p.name, 'Bandit');
        expect(p.needsNewVersion, isTrue);
      }
    });

    test('the share text says older versions must update', () {
      const inv = Invite(
        groupId: 'a1b2c3d4e5f60718',
        passcode: 'correct-horse-staple',
        groupName: 'Family',
      );
      expect(inv.shareText(), contains('Needs Stalkie Talkie 2.3.0 or newer'));
      expect(inv.shareText(), contains('private group'));
      // A converted group still works on older phones: no such note.
      const legacy = Invite(
        groupId: 'ch3',
        channel: 3,
        passcode: 'abcdef12',
        groupName: 'CH 3 group',
      );
      expect(legacy.needsNewVersion, isFalse);
      expect(legacy.shareText(), isNot(contains('Needs Stalkie Talkie')));
      expect(Invite.parse(legacy.appLink)!.channel, 3);
      expect(Invite.parse(legacy.appLink)!.groupId, 'ch3');
    });

    test('friend add still rides along', () {
      final code = PairKey.qrText(
        ownerId: 0x1234abcd,
        ownerName: 'Bandit',
        code: PairKey.randomSecret(),
      );
      final inv = Invite(
        groupId: 'a1b2c3d4e5f60718',
        passcode: 'correct-horse-staple',
        friendCode: code,
      );
      final p = Invite.parse(inv.appLink)!;
      expect(p.hasFriend, isTrue);
      expect(p.hasGroup, isTrue);
    });

    test('nonsense is not an invite', () {
      // A passcode alone means nothing without a group or a channel.
      expect(Invite.parse('walkietalkie://join?v=2&p=secret55'), isNull);
      // A group id must look like one.
      expect(
        Invite.parse('walkietalkie://join?v=2&g=a%20b&p=secret55'),
        isNull,
      );
      expect(Invite.parse('hello'), isNull);
      expect(Invite.parse(''), isNull);
      expect(Invite.parse('walkietalkie://join?v=1&ch=99&p=abc'), isNull);
    });

    test('a hostile name is clipped', () {
      final long = 'N' * 200;
      final p = Invite.parse(
        'walkietalkie://join?v=2&g=abc123&p=secret55&gn=$long&ge=${'E' * 50}',
      )!;
      expect(p.groupName!.length, 30);
      expect(p.groupEmoji!.length, 8);
    });
  });

  group('adding people: the friend hand-off', () {
    final secret = List<int>.generate(32, (i) => i * 7 + 1);
    final other = List<int>.generate(32, (i) => i * 5 + 3);
    final group = PrivateGroup(
      id: 'a1b2c3d4e5f60718',
      name: 'Family',
      emoji: '🏕',
      color: GroupColors.palette[3],
      secret: 'correct-horse-staple',
    );

    test('only the friend can open it, and gets the whole group', () {
      final box = GroupHandoff.build(
        group: group,
        from: 0xA1,
        to: 0xB2,
        friendSecret: secret,
      );
      expect(
        jsonEncode(box),
        isNot(contains('correct-horse-staple')),
        reason: 'the secret is sealed',
      );
      final g = GroupHandoff.open(
        invite: box,
        from: 0xA1,
        me: 0xB2,
        friendSecret: secret,
        fromName: 'Bandit',
      )!;
      expect(g.id, 'a1b2c3d4e5f60718');
      expect(g.name, 'Family');
      expect(g.emoji, '🏕');
      expect(g.color, GroupColors.palette[3]);
      expect(g.secret, 'correct-horse-staple');
      expect(g.invited, isTrue, reason: 'nothing is joined until accepted');
      expect(g.invitedBy, 'Bandit');
      expect(g.isLegacy, isFalse);
    });

    test('nobody else can: wrong friend key, recipient, sender or group', () {
      final box = GroupHandoff.build(
        group: group,
        from: 0xA1,
        to: 0xB2,
        friendSecret: secret,
      );
      PrivateGroup? open({
        Map<String, Object?>? b,
        int from = 0xA1,
        int me = 0xB2,
        List<int>? key,
      }) => GroupHandoff.open(
        invite: b ?? box,
        from: from,
        me: me,
        friendSecret: key ?? secret,
      );
      expect(open(), isNotNull);
      expect(open(key: other), isNull, reason: 'another friend key');
      expect(open(me: 0xC3), isNull, reason: 'meant for someone else');
      expect(open(from: 0xD4), isNull, reason: 'claimed to be from another');
      expect(
        open(b: {...box, 'g': '0011223344556677'}),
        isNull,
        reason: 'swapped to another group',
      );
      expect(open(b: {...box, 'x': 'AAAA'}), isNull);
      expect(open(b: {...box, 'x': null}), isNull);
      expect(open(b: {...box, 'g': 'bad id!'}), isNull);
      expect(open(b: {...box, 'g': 5}), isNull);
    });

    test('a legacy group hands over its channel number so older phones '
        'derive the same key', () {
      final legacy = PrivateGroup.migrate({3: 'abcdef12'}).single;
      final box = GroupHandoff.build(
        group: legacy,
        from: 1,
        to: 2,
        friendSecret: secret,
      );
      final g = GroupHandoff.open(
        invite: box,
        from: 1,
        me: 2,
        friendSecret: secret,
      )!;
      expect(g.legacyChannel, 3);
      expect(g.keyId, legacy.keyId);
    });

    test('names are clipped and a weak secret is refused', () {
      final box = GroupHandoff.build(
        group: group,
        from: 1,
        to: 2,
        friendSecret: secret,
      );
      final long = GroupHandoff.open(
        invite: {...box, 'n': 'N' * 500, 'e': 'E' * 99, 'c': 99},
        from: 1,
        me: 2,
        friendSecret: secret,
      )!;
      expect(long.name.length, 30);
      expect(long.emoji.length, 8);
      expect(long.color, GroupColors.palette.first);
      final weak = GroupHandoff.build(
        group: PrivateGroup(
          id: 'abc123',
          name: 'x',
          color: GroupColors.palette[0],
          secret: 'abc',
        ),
        from: 1,
        to: 2,
        friendSecret: secret,
      );
      expect(
        GroupHandoff.open(invite: weak, from: 1, me: 2, friendSecret: secret),
        isNull,
      );
    });

    test('it travels in a Direct chat message (type groupInvite)', () {
      final box = GroupHandoff.build(
        group: group,
        from: 1,
        to: 2,
        friendSecret: secret,
      );
      final body = ChatBody(
        type: ChatType.groupInvite,
        text: group.label,
        sentAt: DateTime(2026, 10, 28, 8),
        invite: box,
      );
      final back = ChatBody.tryDecode(body.encode())!;
      expect(back.type, ChatType.groupInvite);
      expect(back.text, '🏕 Family');
      final g = GroupHandoff.open(
        invite: back.invite!,
        from: 1,
        me: 2,
        friendSecret: secret,
      );
      expect(g?.secret, 'correct-horse-staple');
      // An invitation without its box is not a message.
      final broken = ChatBody(type: ChatType.groupInvite, text: 'x');
      expect(ChatBody.tryDecode(broken.encode()), isNull);
    });
  });

  group('ids and colours', () {
    test('ids are random hex and valid', () {
      final a = GroupIds.generate(), b = GroupIds.generate();
      expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(a, isNot(b));
      expect(GroupIds.valid(a), isTrue);
      expect(GroupIds.valid('ch3'), isTrue);
      expect(GroupIds.valid('a b'), isFalse);
      expect(GroupIds.valid(null), isFalse);
      expect(GroupIds.valid('x' * 40), isFalse);
    });

    test('a new group gets a colour not used yet', () {
      expect(GroupColors.next([]), GroupColors.palette[0]);
      expect(
        GroupColors.next([GroupColors.palette[0]]),
        GroupColors.palette[1],
      );
      expect(GroupColors.next(GroupColors.palette).isNegative, isFalse);
    });
  });
}
