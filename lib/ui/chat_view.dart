import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../chat/chat_body.dart';
import '../chat/chat_store.dart';
import 'home_view.dart';

/// The chat screen without the controller (also used by layout tests).
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.messages,
    required this.loadPhoto,
    required this.onSend,
    required this.onAttach,
    required this.onOpenMap,
    this.showNames = true,
    this.header,
    this.notice,
    this.liveUntil,
    this.onStopLive,
    this.now,
    this.enabled = true,
  });

  final List<ChatMessage> messages;
  final Future<Uint8List?> Function(ChatMessage m) loadPhoto;
  final ValueChanged<String> onSend;
  final VoidCallback onAttach;
  final ValueChanged<ChatMessage> onOpenMap;

  /// Channel chats show who wrote each message.
  final bool showNames;
  final Widget? header;
  final String? notice;

  /// My live location in this chat runs until then.
  final DateTime? liveUntil;
  final VoidCallback? onStopLive;
  final DateTime? now;
  final bool enabled;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    widget.onSend(t);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final msgs = widget.messages.reversed.toList();
    final now = widget.now ?? DateTime.now();
    return Column(
      children: [
        ?widget.header,
        if (widget.notice != null)
          Container(
            width: double.infinity,
            color: cs.secondaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              widget.notice!,
              style: TextStyle(color: cs.onSecondaryContainer, fontSize: 13),
            ),
          ),
        if (widget.liveUntil != null)
          Material(
            color: cs.tertiaryContainer,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.share_location),
              title: Text(
                'Sharing your live location until ${hhmm(widget.liveUntil!)}',
              ),
              trailing: TextButton(
                onPressed: widget.onStopLive,
                child: const Text('Stop'),
              ),
            ),
          ),
        Expanded(
          child: msgs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No messages yet. Write something, or tap the clip '
                      'to send a photo or your location.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _Bubble(
                    m: msgs[i],
                    showName:
                        widget.showNames &&
                        !msgs[i].mine &&
                        (i == msgs.length - 1 ||
                            msgs[i + 1].sender != msgs[i].sender),
                    loadPhoto: widget.loadPhoto,
                    onOpenMap: widget.onOpenMap,
                    now: now,
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Photo or location',
                  icon: const Icon(Icons.attach_file),
                  onPressed: widget.enabled ? widget.onAttach : null,
                ),
                Expanded(
                  child: TextField(
                    controller: _text,
                    enabled: widget.enabled,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                      ),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                IconButton.filled(
                  tooltip: 'Send',
                  icon: const Icon(Icons.send),
                  onPressed: widget.enabled ? _send : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.m,
    required this.showName,
    required this.loadPhoto,
    required this.onOpenMap,
    required this.now,
  });
  final ChatMessage m;
  final bool showName;
  final Future<Uint8List?> Function(ChatMessage m) loadPhoto;
  final ValueChanged<ChatMessage> onOpenMap;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = m.mine ? cs.primaryContainer : cs.surfaceContainerHighest;
    final fg = m.mine ? cs.onPrimaryContainer : cs.onSurface;
    final status = m.mine
        ? (m.deliveredTo.isEmpty
              ? ' · waiting'
              : m.deliveredTo.length == 1
              ? ' · delivered'
              : ' · delivered to ${m.deliveredTo.length}')
        : '';
    Widget content;
    switch (m.type) {
      case ChatType.text:
        content = Text(m.text, style: TextStyle(color: fg, fontSize: 15));
      case ChatType.photo:
        content = _Photo(m: m, load: loadPhoto, fg: fg);
      case ChatType.location:
        final live = m.isLive(now);
        content = InkWell(
          onTap: () => onOpenMap(m),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                live ? Icons.share_location : Icons.location_on,
                color: live ? Colors.red : fg,
                size: 32,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      live
                          ? 'Live location (until ${hhmm(m.liveUntil!)})'
                          : m.liveUntil != null
                          ? 'Live location (ended)'
                          : 'Location',
                      style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${m.lat?.toStringAsFixed(5)}, ${m.lng?.toStringAsFixed(5)}'
                      '${m.accuracy != null ? ' (±${m.accuracy!.round()} m)' : ''}',
                      style: TextStyle(color: fg, fontSize: 12),
                    ),
                    Text(
                      'Tap to open in Google Maps',
                      style: TextStyle(
                        color: cs.primary,
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
    }
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Padding(
          padding: EdgeInsets.only(top: showName ? 8 : 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (showName) ...[
                Avatar(id: m.sender, name: m.senderName, size: 28),
                const SizedBox(width: 4),
              ] else if (!m.mine)
                const SizedBox(width: 32),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showName)
                        Text(
                          m.senderName,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      content,
                      const SizedBox(height: 2),
                      Text(
                        '${hhmm(m.at)}$status',
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Photo extends StatefulWidget {
  const _Photo({required this.m, required this.load, required this.fg});
  final ChatMessage m;
  final Future<Uint8List?> Function(ChatMessage m) load;
  final Color fg;

  @override
  State<_Photo> createState() => _PhotoState();
}

class _PhotoState extends State<_Photo> {
  late final Future<Uint8List?> _f = widget.load(widget.m);

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final aspect = m.width > 0 && m.height > 0 ? m.width / m.height : 4 / 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FutureBuilder<Uint8List?>(
          future: _f,
          builder: (context, snap) {
            final bytes = snap.data;
            final box = AspectRatio(
              aspectRatio: aspect.clamp(0.5, 2.0),
              child: bytes == null
                  ? Container(
                      color: Colors.black12,
                      child: Icon(Icons.photo, color: widget.fg, size: 40),
                    )
                  : Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          Icon(Icons.broken_image, color: widget.fg),
                    ),
            );
            return GestureDetector(
              onTap: bytes == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          backgroundColor: Colors.black,
                          appBar: AppBar(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                          ),
                          body: Center(
                            child: InteractiveViewer(
                              child: Image.memory(bytes),
                            ),
                          ),
                        ),
                      ),
                    ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: 220, child: box),
              ),
            );
          },
        ),
        if (m.thumbnailOnly)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Small preview only (sent over Bluetooth)',
              style: TextStyle(color: widget.fg, fontSize: 11),
            ),
          ),
      ],
    );
  }
}
