import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../lora/meshtastic_ble.dart';
import '../lora/saved_radios.dart';
import '../lora/stream_radio.dart';
import '../platform/platform_caps.dart';

String radioStateText(RadioState s) => switch (s) {
  RadioState.none => 'No radio paired',
  RadioState.bluetoothOff => 'Bluetooth is off',
  RadioState.connecting => 'Connecting...',
  RadioState.pairing => 'Waiting for the PIN (see below)',
  RadioState.configuring => 'Loading radio settings...',
  RadioState.ready => 'Connected',
  RadioState.reconnecting => 'Not connected, retrying',
};

/// The second line of a saved radio's row.
String savedRadioSubtitle(WalkieController c, SavedRadio r, {DateTime? now}) {
  final dev = c.radioDevice;
  if (r.id == dev.deviceId) {
    final ok = dev.state == RadioState.ready;
    return [
      radioStateText(dev.state),
      if (!ok && dev.detail != null) dev.detail!,
      if (ok) r.kind,
    ].join(' · ');
  }
  final parts = <String>[r.kind];
  if (r.isSerial && PlatformCaps.streamRadios) {
    if (!dev.usbRadios().contains(r.id)) {
      parts.add('Not found: plug it in');
      return parts.join(' · ');
    }
  }
  final t = r.lastConnected;
  parts.add(t == null ? 'Not connected yet' : 'Seen ${radioSeen(t, now: now)}');
  return parts.join(' · ');
}

/// Settings > Long-range radio > Saved radios (v2.5.4): every radio
/// connected so far. The one in use is marked Connected; tap another to
/// switch to it.
class SavedRadiosList extends StatelessWidget {
  const SavedRadiosList({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final list = c.savedRadios;
    if (list.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Saved radios', style: theme.textTheme.titleSmall),
        for (final r in list) _row(context, r),
      ],
    );
  }

  Widget _row(BuildContext context, SavedRadio r) {
    final c = controller;
    final cs = Theme.of(context).colorScheme;
    final active = r.id == c.radioDevice.deviceId;
    final ok = active && c.radioDevice.state == RadioState.ready;
    return ListTile(
      key: Key('savedRadio-${r.id}'),
      contentPadding: EdgeInsets.zero,
      selected: active,
      selectedTileColor: cs.primaryContainer.withValues(alpha: 0.35),
      leading: Icon(
        r.isSerial
            ? Icons.usb
            : r.isWifi
            ? Icons.wifi
            : Icons.bluetooth,
        color: ok ? cs.primary : (active ? cs.onSurface : cs.outline),
      ),
      title: Text(r.title),
      subtitle: Text(savedRadioSubtitle(c, r)),
      onTap: active ? null : () => c.switchRadio(r.id),
      trailing: PopupMenuButton<String>(
        key: Key('savedRadioMenu-${r.id}'),
        tooltip: 'Radio options',
        onSelected: (v) {
          switch (v) {
            case 'disconnect':
              c.disconnectRadio();
            case 'rename':
              _rename(context, r);
            case 'remove':
              _remove(context, r);
          }
        },
        itemBuilder: (_) => [
          if (active)
            const PopupMenuItem(
              key: Key('savedRadioDisconnect'),
              value: 'disconnect',
              child: Text('Disconnect'),
            ),
          const PopupMenuItem(
            key: Key('savedRadioRename'),
            value: 'rename',
            child: Text('Rename'),
          ),
          const PopupMenuItem(
            key: Key('savedRadioRemove'),
            value: 'remove',
            child: Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, SavedRadio r) async {
    final ctl = TextEditingController(text: r.title);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename radio'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('savedRadioName'),
              controller: ctl,
              autofocus: true,
              maxLength: 40,
              decoration: InputDecoration(
                hintText: r.name ?? StreamRadioId.label(r.id),
              ),
              onSubmitted: (t) => Navigator.pop(ctx, t),
            ),
            const Text(
              'Only a name in this app. The radio keeps its own name; '
              'leave it empty to use that.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('savedRadioNameSave'),
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (v != null) await controller.renameRadio(r.id, v);
  }

  Future<void> _remove(BuildContext context, SavedRadio r) async {
    final active = r.id == controller.radioDevice.deviceId;
    final bt = !StreamRadioId.isStream(r.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('removeRadioDialog'),
        title: Text('Remove ${r.title}?'),
        content: Text(
          '${active ? 'It is disconnected first. ' : ''}'
          'It leaves this list${bt ? ' and Android forgets its pairing' : ''}.'
          ' Add it again any time with Find '
          '${PlatformCaps.streamRadios ? 'USB radio or Wi-Fi radio' : 'my radio'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('removeRadioConfirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await controller.removeRadio(r.id);
  }
}
