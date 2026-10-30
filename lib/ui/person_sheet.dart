import 'package:flutter/material.dart';

import '../weather/wx_keys.dart';
import 'home_view.dart';

/// Everything in the per-person sheet (long-press a person on Talk):
/// volume, "Always allow rings", Ring / Beep / Urgent ring / Voice message,
/// Private chat or Add friend, Mute, Block, Remove from channel (admins)
/// and the muted note. Pure view so a small phone can be tested.
///
/// Every callback is the plain action; the caller closes the sheet.
class PersonSheetView extends StatelessWidget {
  const PersonSheetView({
    super.key,
    required this.person,
    required this.volume,
    required this.alwaysAllow,
    required this.isFriend,
    required this.muted,
    required this.canRemove,
    required this.onVolume,
    required this.onAlwaysAllow,
    required this.onRing,
    required this.onBeep,
    required this.onUrgent,
    required this.onVoiceMessage,
    required this.onPrivateChat,
    required this.onAddFriend,
    required this.onMute,
    required this.onBlock,
    required this.onRemove,
    this.onWxTrust,
    this.wxKeyId,
    this.wxTrusted = false,
  });

  /// "Trust weather alerts from this device" (a friend's card only, v2.5.2).
  /// Null hides it. [wxKeyId]: the key their phone told us (null = not heard
  /// yet, the switch waits).
  final ValueChanged<bool>? onWxTrust;
  final String? wxKeyId;
  final bool wxTrusted;

  final PersonView person;
  final double volume;
  final bool alwaysAllow;
  final bool isFriend;
  final bool muted;

  /// I am an admin of the channel and they are here.
  final bool canRemove;
  final ValueChanged<double> onVolume;
  final ValueChanged<bool> onAlwaysAllow;
  final VoidCallback onRing;
  final VoidCallback onBeep;
  final VoidCallback onUrgent;
  final VoidCallback onVoiceMessage;
  final VoidCallback onPrivateChat;
  final VoidCallback onAddFriend;
  final VoidCallback onMute;
  final VoidCallback onBlock;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final v = volume;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Avatar(id: p.id, name: p.name),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Volume for this person: ${(v * 100).round()}%'),
          Row(
            children: [
              const Icon(Icons.volume_mute),
              Expanded(
                child: Slider(
                  value: v,
                  max: 2,
                  divisions: 20,
                  label: '${(v * 100).round()}%',
                  onChanged: onVolume,
                ),
              ),
              const Icon(Icons.volume_up),
            ],
          ),
          TextButton(
            onPressed: () => onVolume(1),
            child: const Text('Reset to 100%'),
          ),
          SwitchListTile(
            key: const Key('alwaysAllow'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Always allow rings'),
            subtitle: const Text(
              'Their rings still sound while you are muted or in '
              'quiet hours (with "Let urgent rings through" on).',
            ),
            value: alwaysAllow,
            onChanged: onAlwaysAllow,
          ),
          if (isFriend && onWxTrust != null)
            SwitchListTile(
              key: const Key('wx-trust'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Trust weather alerts from this device'),
              subtitle: Text(
                wxKeyId == null
                    ? 'Their key shows here once they are online with '
                          'weather alerts on.'
                    : 'Key ${wxKeyShow(wxKeyId!)}. Their alerts then count '
                          'as confirmed on any channel and over the radio. '
                          'It is the key shown in their Settings.',
                key: const Key('wx-trust-key'),
              ),
              value: wxKeyId != null && wxTrusted,
              onChanged: wxKeyId == null ? null : onWxTrust,
            ),
          const Divider(),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                key: const Key('person-ring'),
                icon: const Icon(Icons.ring_volume),
                label: const Text('Ring'),
                onPressed: onRing,
              ),
              OutlinedButton.icon(
                key: const Key('person-beep'),
                icon: const Icon(Icons.notifications_active),
                label: const Text('Beep'),
                onPressed: onBeep,
              ),
              FilledButton.tonalIcon(
                key: const Key('person-urgent'),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.errorContainer,
                  foregroundColor: theme.colorScheme.onErrorContainer,
                ),
                icon: const Icon(Icons.campaign),
                label: const Text('Urgent ring'),
                onPressed: onUrgent,
              ),
              OutlinedButton.icon(
                key: const Key('person-voice'),
                icon: const Icon(Icons.mic),
                label: const Text('Voice message'),
                onPressed: onVoiceMessage,
              ),
            ],
          ),
          const Divider(),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (isFriend)
                FilledButton.tonalIcon(
                  key: const Key('person-chat'),
                  icon: const Icon(Icons.forum),
                  label: const Text('Direct chat'),
                  onPressed: onPrivateChat,
                )
              else if (!p.left)
                FilledButton.tonalIcon(
                  key: const Key('person-add-friend'),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Add friend'),
                  onPressed: onAddFriend,
                ),
              OutlinedButton.icon(
                key: const Key('person-mute'),
                icon: Icon(muted ? Icons.volume_up : Icons.volume_off),
                label: Text(muted ? 'Unmute' : 'Mute'),
                onPressed: onMute,
              ),
              OutlinedButton.icon(
                key: const Key('person-block'),
                icon: const Icon(Icons.block),
                label: const Text('Block'),
                onPressed: onBlock,
              ),
              if (canRemove)
                OutlinedButton.icon(
                  key: const Key('person-remove'),
                  icon: const Icon(Icons.person_remove),
                  label: const Text('Remove from channel'),
                  onPressed: onRemove,
                ),
            ],
          ),
          if (muted)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Muted: their live talk is not played here.',
                key: Key('person-muted-note'),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
