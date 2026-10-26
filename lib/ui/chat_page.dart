import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/walkie_controller.dart';
import 'chat_view.dart';
import 'home_view.dart';
import 'sheets.dart';

/// Chat for the current channel, or with one friend (private, with a
/// hold-to-talk button and voice messages).
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.controller, required this.conv});
  final WalkieController controller;
  final String conv;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  WalkieController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.openChat = widget.conv;
    c.markChatRead(widget.conv);
  }

  @override
  void dispose() {
    if (c.openChat == widget.conv) c.openChat = null;
    c.markChatRead(widget.conv);
    super.dispose();
  }

  Future<void> _attach() async {
    final conv = widget.conv;
    final live = c.isSharingLive(conv);
    await showAppSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Photo from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pick(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pick(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.location_on),
              title: const Text('Send my location'),
              subtitle: const Text('One pin, where you are now'),
              onTap: () {
                Navigator.pop(ctx);
                c.shareLocation(conv);
              },
            ),
            if (live)
              ListTile(
                leading: const Icon(Icons.location_off),
                title: const Text('Stop sharing live location'),
                onTap: () {
                  Navigator.pop(ctx);
                  c.stopLiveLocation(conv);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.share_location),
                title: const Text('Share live location'),
                subtitle: Wrap(
                  spacing: 6,
                  children: [
                    for (final m in const [15, 30, 60])
                      ActionChip(
                        label: Text('$m min'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          c.shareLocation(conv, live: Duration(minutes: m));
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(ImageSource src) async {
    try {
      if (src == ImageSource.camera &&
          !(await Permission.camera.request()).isGranted) {
        _snack('Camera permission is needed to take a photo.');
        return;
      }
      final f = await ImagePicker().pickImage(
        source: src,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90,
      );
      if (f == null) return;
      _snack('Preparing photo...');
      await c.sendPhoto(widget.conv, await f.readAsBytes());
    } catch (e) {
      _snack('Could not get the photo: $e');
    }
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final conv = widget.conv;
        final friend = c.friendOf(conv);
        if (c.openChat == conv && (c.chats?.unread(conv) ?? 0) > 0) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => c.markChatRead(conv),
          );
        }
        final channelHere = friend == null && conv == c.channelChat;
        final old = c.peersWithoutChat;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              friend == null
                  ? 'Chat · ${c.chatTitle(conv)}'
                  : c.chatTitle(conv),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: ChatView(
            messages: c.chatMessages(conv),
            loadPhoto: c.chatPhoto,
            onSend: (t) => c.sendChatText(conv, t),
            onAttach: _attach,
            onOpenMap: c.openMap,
            showNames: friend == null,
            enabled: friend != null || channelHere,
            liveUntil: c.liveUntil(conv),
            onStopLive: () => c.stopLiveLocation(conv),
            notice: friend != null
                ? null
                : !channelHere
                ? 'You are on another channel now: switch back to write here.'
                : old.isNotEmpty
                ? '${old.map((p) => p.displayName).join(', ')} '
                      '${old.length == 1 ? 'has' : 'have'} an older app and '
                      'cannot see chats.'
                : null,
            header: friend == null
                ? null
                : FriendTalkBar(
                    name: c.friendName(friend),
                    online: c.friendOnline(friend),
                    via: c.friendVia(friend),
                    needsUpdate:
                        c.friendOnline(friend) &&
                        c.friendLinks.needsUpdate(friend),
                    talking: c.privateTalkTo == friend,
                    hearing: c.friendsTalking.contains(friend),
                    recording:
                        c.recording?.toFriend == true &&
                        c.recording?.toPeer == friend,
                    onTalk: (down) => c.talkToFriend(friend, down),
                    onRecord: (down) => down
                        ? c.startRecording(toPeer: friend, toFriend: true)
                        : c.stopRecording(),
                  ),
          ),
        );
      },
    );
  }
}

/// Top of a friend chat: status, hold to talk privately, hold to record.
class FriendTalkBar extends StatelessWidget {
  const FriendTalkBar({
    super.key,
    required this.name,
    required this.online,
    required this.via,
    required this.talking,
    required this.hearing,
    required this.recording,
    required this.onTalk,
    required this.onRecord,
    this.needsUpdate = false,
  });
  final String name;
  final bool online;

  /// Their app is too old for private talk (voice messages still work).
  final bool needsUpdate;
  final String? via;
  final bool talking;
  final bool hearing;
  final bool recording;
  final ValueChanged<bool> onTalk;
  final ValueChanged<bool> onRecord;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget holdButton({
      required String label,
      required IconData icon,
      required bool active,
      required Color activeColor,
      required ValueChanged<bool> onHold,
      bool enabled = true,
    }) => Listener(
      onPointerDown: enabled ? (_) => onHold(true) : null,
      onPointerUp: enabled ? (_) => onHold(false) : null,
      onPointerCancel: enabled ? (_) => onHold(false) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? activeColor
              : enabled
              ? cs.secondaryContainer
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: active ? Colors.white : cs.onSecondaryContainer,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : cs.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
    return Material(
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: online ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    hearing
                        ? '$name is talking to you...'
                        : needsUpdate
                        ? '$name needs to update to talk privately · '
                              'voice messages work'
                        : online
                        ? 'Online${via != null ? ' via $via' : ''} · '
                              'end-to-end encrypted'
                        : 'Not connected privately yet · messages wait '
                              'up to 24 h',
                    style: TextStyle(
                      color: hearing ? Colors.orange.shade800 : null,
                      fontWeight: hearing ? FontWeight.w600 : null,
                    ),
                  ),
                ),
                const Icon(Icons.lock, size: 14),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                holdButton(
                  label: talking ? 'Talking...' : 'Hold to talk',
                  icon: Icons.mic,
                  active: talking,
                  activeColor: Colors.red,
                  onHold: onTalk,
                  enabled: online && !needsUpdate,
                ),
                holdButton(
                  label: recording ? 'Recording...' : 'Hold: voice msg',
                  icon: Icons.keyboard_voice,
                  active: recording,
                  activeColor: Colors.red,
                  onHold: onRecord,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Small helper for lists: avatar with an online dot.
class OnlineAvatar extends StatelessWidget {
  const OnlineAvatar({
    super.key,
    required this.id,
    required this.name,
    required this.online,
    this.talking = false,
  });
  final int id;
  final String name;
  final bool online;
  final bool talking;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      Avatar(id: id, name: name, talking: talking, size: 44),
      Positioned(
        right: -1,
        bottom: -1,
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: online ? Colors.green : Colors.grey,
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).colorScheme.surface,
              width: 2,
            ),
          ),
        ),
      ),
    ],
  );
}
