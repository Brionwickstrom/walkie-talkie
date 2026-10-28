// v2.3.0: the private-group flows on the controller (create, join, leave,
// accept an invitation from a friend, switch back to an open channel).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walkie_talkie/app/mesh_links.dart';
import 'package:walkie_talkie/chat/chat_body.dart';
import 'package:walkie_talkie/core/pair_key.dart';
import 'package:walkie_talkie/friends/friend_links.dart';
import 'package:walkie_talkie/messaging/messenger.dart';
import 'package:walkie_talkie/app/group_handoff.dart';
import 'package:walkie_talkie/core/channel_crypto.dart';
import 'package:walkie_talkie/lora/meshtastic_channels.dart';
import 'package:walkie_talkie/app/groups.dart';
import 'package:walkie_talkie/app/invite.dart';
import 'package:walkie_talkie/app/settings.dart';
import 'package:walkie_talkie/app/walkie_controller.dart';
import 'package:walkie_talkie/core/frame.dart';
import 'package:walkie_talkie/core/transport_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The controller builds the audio engine and the Android bridge; every
  // plugin channel answers "nothing" here.
  void quietPlugins() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in [
      'com.llfbandit.record/messages',
      'com.llfbandit.record/events',
      'com.llfbandit.record/eventsRecord',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  }

  Future<WalkieController> make({AppSettings? s}) async {
    quietPlugins();
    SharedPreferences.setMockInitialValues({});
    final store = MemorySettingsStore(
      s ?? AppSettings(nodeId: 0x1234, channel: 1),
    );
    final c = await WalkieController.load(store: store);
    addTearDown(c.dispose);
    return c;
  }

  test('create: a private group with no channel number', () async {
    final c = await make();
    expect(c.isPrivate, isFalse);
    final problem = await c.createGroup(passcode: 'abc');
    expect(problem, isNotNull, reason: 'weak secret refused');
    expect(c.settings.groups, isEmpty);
    expect(
      await c.createGroup(
        passcode: 'correct-horse-staple',
        name: 'Family',
        emoji: '🏕',
      ),
      isNull,
    );
    expect(c.isPrivate, isTrue);
    final g = c.currentGroup!;
    expect(g.name, 'Family');
    expect(g.isLegacy, isFalse);
    expect(g.id, matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(c.settings.activeGroup, g.id);
    expect(TransportManager.isPrivateScope(c.scope), isTrue);
    expect(g.scope, c.scope);
    expect(c.settings.channel, 1, reason: 'the open channel we come back to');
  });

  test('leave: back on the open channel, the group is gone', () async {
    final c = await make();
    await c.createGroup(passcode: 'correct-horse-staple', name: 'Family');
    final id = c.currentGroup!.id;
    await c.leaveGroup(id);
    expect(c.isPrivate, isFalse);
    expect(c.settings.groups, isEmpty);
    expect(c.settings.activeGroup, isNull);
    expect(c.channel, 1);
  });

  test('open channels never ask for a passcode and leave the group', () async {
    final c = await make();
    await c.createGroup(passcode: 'correct-horse-staple', name: 'Family');
    await c.setChannel(5);
    expect(c.isPrivate, isFalse);
    expect(c.channel, 5);
    expect(c.settings.groups.length, 1, reason: 'still ours, just not here');
    expect(c.scope, 5);
    await c.setGroup(c.settings.groups.single.id);
    expect(c.isPrivate, isTrue);
    expect(c.settings.channel, 5, reason: 'CH 5 is where leaving lands');
  });

  test('join with an old "CH n + passcode" invite: a "CH n group" with the '
      'old key', () async {
    final c = await make();
    final g = await c.joinGroupFromInvite(
      const Invite(channel: 3, passcode: 'abcdef12'),
    );
    expect(g.id, 'ch3');
    expect(g.name, 'CH 3 group');
    expect(g.legacyChannel, 3);
    expect(c.isPrivate, isTrue);
    // Same room as an older phone on CH 3 + the passcode.
    final older = await g.deriveKey(inline: true);
    expect(c.scope, TransportManager.scopeFor(3, older));
    // Joining again does not double it.
    await c.joinGroupFromInvite(const Invite(channel: 3, passcode: 'abcdef12'));
    expect(c.settings.groups.length, 1);
  });

  test(
    'join with a v2.3.0 invite: name, emoji and colour come along',
    () async {
      final c = await make();
      final g = await c.joinGroupFromInvite(
        const Invite(
          groupId: 'a1b2c3d4e5f60718',
          passcode: 'correct-horse-staple',
          groupName: 'Family',
          groupEmoji: '🏕',
          groupColor: 0xFF8E24AA,
        ),
      );
      expect(g.id, 'a1b2c3d4e5f60718');
      expect(g.name, 'Family');
      expect(g.emoji, '🏕');
      expect(g.color, 0xFF8E24AA);
      expect(g.isLegacy, isFalse);
      expect(c.currentGroup?.id, g.id);
    },
  );

  test('a new code for a group we have replaces the secret (remove '
      'someone)', () async {
    final c = await make();
    const id = 'a1b2c3d4e5f60718';
    await c.joinGroupFromInvite(
      const Invite(groupId: id, passcode: 'first-secret-1', groupName: 'F'),
    );
    final scope1 = c.scope;
    await c.joinGroupFromInvite(
      const Invite(groupId: id, passcode: 'second-secret-2', groupName: 'F'),
    );
    expect(c.settings.groups.length, 1);
    expect(c.currentGroup!.secret, 'second-secret-2');
    expect(c.scope, isNot(scope1));
  });

  test('accept: a saved invitation becomes a group we are in', () async {
    final s = AppSettings(nodeId: 0x1234, channel: 1);
    s.groups.add(
      PrivateGroup(
        id: 'a1b2c3d4e5f60718',
        name: 'Family',
        color: GroupColors.palette[0],
        secret: 'correct-horse-staple',
        invited: true,
        invitedBy: 'Bandit',
      ),
    );
    final c = await make(s: s);
    expect(c.isPrivate, isFalse, reason: 'an invitation joins nothing');
    await c.acceptGroupInvite('a1b2c3d4e5f60718');
    expect(c.isPrivate, isTrue);
    expect(c.currentGroup!.invited, isFalse);
  });

  test('decline: leaving an invitation removes it and stays put', () async {
    final s = AppSettings(nodeId: 0x1234, channel: 4);
    s.groups.add(
      PrivateGroup(
        id: 'a1b2c3d4e5f60718',
        name: 'Family',
        color: GroupColors.palette[0],
        secret: 'correct-horse-staple',
        invited: true,
      ),
    );
    final c = await make(s: s);
    await c.leaveGroup('a1b2c3d4e5f60718');
    expect(c.settings.groups, isEmpty);
    expect(c.channel, 4);
    expect(c.isPrivate, isFalse);
  });

  test('migrated settings: starts in the converted group on the same '
      'passcode', () async {
    final s = AppSettings(
      nodeId: 0x1234,
      channel: 3,
      legacyPrivate: {3: 'abcdef12'},
    );
    expect(s.activeGroup, 'ch3');
    final c = await make(s: s);
    expect(c.isPrivate, isTrue);
    expect(c.currentGroup!.name, 'CH 3 group');
    final older = await ChannelKey.deriveInline(3, 'abcdef12');
    expect(c.scope, TransportManager.scopeFor(3, older));
  });

  test('Meshtastic: only open channels have a radio link; private traffic '
      'never does', () async {
    final c = await make();
    c.settings.meshLinks[3] = MeshLink(ref: const MeshChannelRef('Hike', 7));
    final f = Frame(
      type: FrameType.audio,
      senderId: 1,
      channel: 3,
      seq: 1,
      payload: Uint8List.fromList([1, 2, 3]),
    );
    expect(c.meshLinkForFrame(f)?.name, 'Hike', reason: 'open CH 3 is linked');
    await c.createGroup(passcode: 'correct-horse-staple', name: 'Family');
    expect(
      c.meshLinkForFrame(f)?.name,
      'Hike',
      reason:
          'the open channel '
          'is unchanged by being in a group',
    );
    final sealed = Frame(
      type: FrameType.sealed,
      senderId: 1,
      channel: 3,
      seq: 1,
      payload: Uint8List.fromList([1, 2, 3]),
    );
    expect(c.meshLinkForFrame(sealed), isNull);
  });

  group('a friend adds me to a group', () {
    Future<(WalkieController, PairKey, PairKey)> withFriend() async {
      final kx = await PairKey.newKeyPair(), ky = await PairKey.newKeyPair();
      // Pair key as I (0x1234) and my friend (0x2222) both get it.
      final mine = await PairKey.agree(
        kx,
        await PairKey.publicKeyOf(ky),
        0x1234,
        0x2222,
      );
      final theirs = await PairKey.agree(
        ky,
        await PairKey.publicKeyOf(kx),
        0x2222,
        0x1234,
      );
      final s = AppSettings(nodeId: 0x1234, channel: 1);
      s.friends.add(
        Friend(id: 0x2222, name: 'Bandit', key: mine, added: DateTime.now()),
      );
      return (await make(s: s), mine, theirs);
    }

    ChatArrival arrival(int from, Map<String, Object?> box) => ChatArrival(
      sender: from,
      msgId: 1,
      senderName: 'Bandit',
      channel: 0,
      channelMessage: false,
      receivedAt: DateTime.now(),
      body: ChatBody(
        type: ChatType.groupInvite,
        text: 'Family',
        sentAt: DateTime.now(),
        invite: box,
      ),
    );

    final group = PrivateGroup(
      id: 'a1b2c3d4e5f60718',
      name: 'Family',
      emoji: '🏕',
      color: GroupColors.palette[3],
      secret: 'correct-horse-staple',
    );

    test('the invitation is kept, nothing is joined until I accept', () async {
      final (c, _, theirs) = await withFriend();
      final box = GroupHandoff.build(
        group: group,
        from: 0x2222,
        to: 0x1234,
        friendSecret: theirs.secret,
      );
      expect(c.takeGroupInvite(arrival(0x2222, box)), isTrue);
      expect(c.isPrivate, isFalse);
      final g = c.settings.groupById('a1b2c3d4e5f60718')!;
      expect(g.invited, isTrue);
      expect(g.invitedBy, 'Bandit');
      expect(g.secret, 'correct-horse-staple');
      // The same invitation again changes nothing (still one).
      c.takeGroupInvite(arrival(0x2222, box));
      expect(c.settings.groups.length, 1);
      await c.acceptGroupInvite(g.id);
      expect(c.isPrivate, isTrue);
      expect(c.currentGroup!.name, 'Family');
      // Once joined, a later invitation never replaces the group.
      expect(c.takeGroupInvite(arrival(0x2222, box)), isFalse);
    });

    test('not from a friend, or not for me: refused', () async {
      final (c, _, theirs) = await withFriend();
      final box = GroupHandoff.build(
        group: group,
        from: 0x2222,
        to: 0x1234,
        friendSecret: theirs.secret,
      );
      // A stranger (no friend key) cannot hand me a group.
      expect(c.takeGroupInvite(arrival(0x9999, box)), isFalse);
      // A friend relaying one meant for somebody else.
      final other = GroupHandoff.build(
        group: group,
        from: 0x2222,
        to: 0x5555,
        friendSecret: theirs.secret,
      );
      expect(c.takeGroupInvite(arrival(0x2222, other)), isFalse);
      expect(c.settings.groups, isEmpty);
    });
  });

  group('low media volume', () {
    test('a calm reminder when talk starts: not when the volume is fine, '
        'at most once per gap, not when muted', () async {
      final c = await make();
      final seen = <String>[];
      c.notices.listen(seen.add);
      expect(c.volumeLow, isFalse, reason: 'unknown counts as fine');
      expect(c.remindLowVolume(), isFalse);
      c.mediaVolume = 0.2;
      expect(c.volumeLow, isTrue);
      final t0 = DateTime(2026, 10, 28, 8);
      expect(c.remindLowVolume(now: t0), isTrue);
      expect(
        c.remindLowVolume(now: t0.add(const Duration(minutes: 3))),
        isFalse,
        reason: 'once per gap',
      );
      expect(
        c.remindLowVolume(now: t0.add(const Duration(minutes: 11))),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.length, 2);
      expect(seen.first, contains('20%'));
      expect(seen.first, contains('Tap the speaker icon'));
      c.mediaVolume = 0.5;
      expect(c.remindLowVolume(now: t0.add(const Duration(hours: 1))), isFalse);
      c.mediaVolume = 0.2;
      await c.mute();
      expect(
        c.remindLowVolume(now: t0.add(const Duration(hours: 2))),
        isFalse,
        reason: 'muted: nothing plays anyway',
      );
    });
  });
}
