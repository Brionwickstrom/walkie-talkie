import 'dart:async';

import 'package:flutter/material.dart';

import '../app/mesh_links.dart';
import '../app/walkie_controller.dart';
import '../lora/meshtastic_admin.dart';
import '../lora/meshtastic_channels.dart';
import '../lora/meshtastic_session.dart';
import 'friends_page.dart' show scanCode;
import 'sheets.dart';

/// Meshtastic channels (v1.9.7): import a Meshtastic channel QR / link,
/// add it to the paired radio as an extra channel and share an open
/// Walkie channel with it. Keys are never shown.

/// What the radio has now, for the preview.
class MeshRadioInfo {
  const MeshRadioInfo({
    this.region,
    this.modemPreset,
    this.usePreset,
    this.channelNum,
    this.presetDisplayName = 'LongFast',
    this.onRadio = const {},
    this.freeSlot,
  });

  factory MeshRadioInfo.of(MeshtasticSession s) => MeshRadioInfo(
    region: s.region,
    modemPreset: s.modemPreset,
    usePreset: s.usePreset,
    channelNum: s.channelNum,
    presetDisplayName: s.presetDisplayName,
    onRadio: {
      for (final c in s.channels.values)
        if (!c.isDisabled) s.refOf(c): c.index,
    },
    freeSlot: meshFreeSlot(s.channels.values),
  );

  final int? region;
  final int? modemPreset;
  final bool? usePreset;
  final int? channelNum;
  final String presetDisplayName;

  /// Channels on the radio (link -> slot).
  final Map<MeshChannelRef, int> onRadio;
  final int? freeSlot;
}

/// One channel of a QR as the preview shows it.
class MeshPreviewChannel {
  MeshPreviewChannel({
    required this.index,
    required this.title,
    required this.keyKind,
    required this.uplink,
    required this.ref,
    this.onRadioSlot,
  });
  final int index;
  final String title;
  final MeshKeyKind keyKind;
  final bool uplink;
  final MeshChannelRef ref;

  /// Slot of the same channel (name + hash) on the radio already.
  final int? onRadioSlot;

  String get keyText => meshKeyKindText(keyKind);
}

/// Everything the import preview shows (pure, for tests).
class MeshImportPreview {
  MeshImportPreview(this.set, this.channels, this.radioLines, this.mismatch);

  final MeshChannelSet set;
  final List<MeshPreviewChannel> channels;

  /// "Preset: LongFast", "Region: US".
  final List<String> radioLines;

  /// Why the QR's radio settings differ from the radio's, null if same /
  /// unknown.
  final String? mismatch;

  static MeshImportPreview build(MeshChannelSet set, MeshRadioInfo radio) {
    final lora = set.loraToApply;
    final chans = <MeshPreviewChannel>[];
    for (var i = 0; i < set.channels.length; i++) {
      final c = set.channels[i];
      final ref = set.refFor(i, radio.presetDisplayName);
      chans.add(
        MeshPreviewChannel(
          index: i,
          title: c.name.isEmpty
              ? '${radio.presetDisplayName} (unnamed)'
              : c.name,
          keyKind: set.keyKindOf(i),
          uplink: c.uplinkEnabled,
          ref: ref,
          onRadioSlot: radio.onRadio[ref],
        ),
      );
    }
    final lines = <String>[];
    String? mismatch;
    if (lora != null) {
      lines.add('Radio preset: ${lora.presetLabel}');
      if (lora.region != 0) {
        lines.add('Region: ${meshRegionLabel(lora.region)}');
      }
      if (lora.channelNum != 0) lines.add('Frequency slot: ${lora.channelNum}');
      final diffs = <String>[];
      final rp = radio.modemPreset;
      if (rp != null) {
        final radioUse = radio.usePreset ?? true;
        final radioLabel = meshPresetLabel(rp, usePreset: radioUse);
        if (radioUse != lora.effectiveUsePreset ||
            (radioUse && rp != lora.modemPreset)) {
          diffs.add('preset ${lora.presetLabel} (your radio: $radioLabel)');
        }
      }
      final rr = radio.region;
      if (lora.region != 0 && rr != null && rr != lora.region) {
        diffs.add(
          'region ${meshRegionLabel(lora.region)} (your radio: '
          '${meshRegionLabel(rr)})',
        );
      }
      final rs = radio.channelNum;
      if (lora.channelNum != 0 && rs != null && rs != lora.channelNum) {
        diffs.add(
          'frequency slot ${lora.channelNum} (your radio: '
          '${rs == 0 ? 'default' : rs})',
        );
      }
      if (diffs.isNotEmpty) mismatch = diffs.join(', ');
    } else {
      lines.add(
        set.addMode
            ? 'Radio settings: not included (add-only link)'
            : 'Radio settings: not included',
      );
    }
    return MeshImportPreview(set, chans, lines, mismatch);
  }

  /// Warnings for channel [i] (and the radio settings).
  List<String> warningsFor(int i) {
    final c = channels[i];
    return [
      if (c.keyKind == MeshKeyKind.defaultPublic)
        'This channel uses the default public key: anyone with a '
            'Meshtastic radio nearby can read it.',
      if (c.keyKind == MeshKeyKind.none)
        'This channel has no encryption: anyone with a Meshtastic radio '
            'nearby can read it.',
      if (c.uplink)
        'MQTT uplink is on: radios with internet copy this channel to an '
            'MQTT server on the internet.',
    ];
  }
}

/// The preview sheet's body (pure view, for tests). Pops nothing itself.
class MeshImportView extends StatefulWidget {
  const MeshImportView({
    super.key,
    required this.preview,
    required this.radioReady,
    required this.onAdd,
  });
  final MeshImportPreview preview;
  final bool radioReady;

  /// (channel index in the QR, also apply the radio settings).
  final void Function(int index, bool applyRadio) onAdd;

  @override
  State<MeshImportView> createState() => _MeshImportViewState();
}

class _MeshImportViewState extends State<MeshImportView> {
  int _pick = 0;
  bool _applyRadio = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = widget.preview;
    final ch = p.channels[_pick];
    final already = ch.onRadioSlot != null;
    Widget warn(String t) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, size: 18, color: cs.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              t,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
            ),
          ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.hub_outlined),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Meshtastic channel',
                style: theme.textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final c in p.channels)
          p.channels.length == 1
              ? ListTile(
                  key: Key('mesh-preview-${c.index}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.hub_outlined),
                  title: Text(c.title),
                  subtitle: Text(
                    [
                      c.keyText,
                      if (c.onRadioSlot != null) 'already on your radio',
                    ].join(' · '),
                  ),
                )
              : RadioListTile<int>(
                  key: Key('mesh-preview-${c.index}'),
                  contentPadding: EdgeInsets.zero,
                  value: c.index,
                  // ignore: deprecated_member_use
                  groupValue: _pick,
                  // ignore: deprecated_member_use
                  onChanged: (v) => setState(() => _pick = v ?? _pick),
                  title: Text(c.title),
                  subtitle: Text(
                    [
                      c.keyText,
                      if (c.onRadioSlot != null) 'already on your radio',
                    ].join(' · '),
                  ),
                ),
        for (final l in p.radioLines)
          Text(l, key: Key('mesh-line-$l'), style: theme.textTheme.bodySmall),
        for (final w in p.warningsFor(_pick)) warn(w),
        if (p.mismatch != null) ...[
          const SizedBox(height: 4),
          Text(
            'This QR\'s radio settings differ from your radio: '
            '${p.mismatch}. The channel only reaches radios on the same '
            'settings as yours. Your radio keeps its settings unless you '
            'choose otherwise below.',
            key: const Key('mesh-mismatch'),
            style: theme.textTheme.bodySmall,
          ),
          ExpansionTile(
            key: const Key('mesh-advanced'),
            tilePadding: EdgeInsets.zero,
            title: const Text('Advanced'),
            children: [
              CheckboxListTile(
                key: const Key('mesh-apply-radio'),
                contentPadding: EdgeInsets.zero,
                value: _applyRadio,
                onChanged: (v) => setState(() => _applyRadio = v ?? false),
                title: const Text('Also apply radio settings'),
                subtitle: const Text(
                  'Retunes your radio to this QR\'s settings. This cuts it '
                  'off from your current group: you will not hear people on '
                  'your current settings any more (Walkie over LoRa too) '
                  'until you change it back.',
                ),
              ),
              if (_applyRadio)
                warn('Your radio will be cut off from your current group.'),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'The key is never shown. Your radio\'s main channel stays as it '
          'is; this one is added as an extra channel.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (!widget.radioReady)
          Text(
            'Connect your radio first (Settings > Long-range radio).',
            key: const Key('mesh-no-radio'),
            style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
          ),
        FilledButton.icon(
          key: const Key('mesh-add'),
          icon: Icon(already && !_applyRadio ? Icons.link : Icons.add),
          label: Text(
            already && !_applyRadio
                ? 'Already on my radio: link it'
                : 'Add to my radio',
          ),
          onPressed: widget.radioReady
              ? () => widget.onAdd(_pick, _applyRadio)
              : null,
        ),
      ],
    );
  }
}

/// Settings > Long-range radio > "Meshtastic channels".
class MeshChannelsSection extends StatelessWidget {
  const MeshChannelsSection({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final links = c.settings.meshLinks.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final session = c.radioDevice.session;
    final unlinked = [
      for (final rc in c.radioChannels)
        if (rc.isSecondary &&
            c.radioChannelRef(rc) != null &&
            c.walkieChannelFor(c.radioChannelRef(rc)!) == null)
          rc,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text('Meshtastic channels', style: theme.textTheme.titleSmall),
        ),
        Text(
          'Share an open Walkie channel with a Meshtastic channel: scan '
          'its QR (from the Meshtastic app) and it is added to your radio '
          'as an extra channel. Your main channel stays as it is.',
          style: theme.textTheme.bodySmall,
        ),
        for (final e in links)
          ListTile(
            key: Key('mesh-link-${e.key}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.hub_outlined),
            title: Text('${_channelLabel(c, e.key)} ↔ ${e.value.ref.name}'),
            subtitle: Text(
              [
                'Shared with Meshtastic',
                if (session != null)
                  session.indexOf(e.value.ref) == null
                      ? 'not on this radio'
                      : 'radio slot ${session.indexOf(e.value.ref)}',
                meshKeyKindText(e.value.keyKind),
              ].join(' · '),
            ),
            trailing: PopupMenuButton<String>(
              key: Key('mesh-link-menu-${e.key}'),
              icon: const Icon(Icons.more_vert),
              onSelected: (_) => confirmUnlink(context, c, e.key),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  key: Key('mesh-unlink'),
                  value: 'unlink',
                  child: Text('Unlink'),
                ),
              ],
            ),
          ),
        for (final rc in unlinked)
          ListTile(
            key: Key('mesh-radio-${rc.index}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.settings_input_antenna),
            title: Text(c.radioChannelRef(rc)!.name),
            subtitle: Text(
              'On your radio (slot ${rc.index}) · '
              '${meshKeyKindText(rc.keyKind)}',
            ),
            trailing: TextButton(
              key: Key('mesh-radio-link-${rc.index}'),
              onPressed: () => pickWalkieChannel(
                context,
                c,
                MeshLink(
                  ref: c.radioChannelRef(rc)!,
                  keyKind: rc.keyKind,
                  uplink: rc.uplinkEnabled,
                  preset: session == null
                      ? ''
                      : meshPresetLabel(
                          session.modemPreset ?? 0,
                          usePreset: session.usePreset ?? true,
                        ),
                  created: DateTime.now().millisecondsSinceEpoch,
                ),
              ),
              child: const Text('Link'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: OutlinedButton.icon(
            key: const Key('mesh-import'),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Import channel QR or link'),
            onPressed: () => startMeshImport(context, c),
          ),
        ),
      ],
    );
  }
}

String _channelLabel(WalkieController c, int ch) {
  final n = c.nameForChannel(ch);
  return n == null || n.name.isEmpty ? 'CH $ch' : '${n.name} (CH $ch)';
}

/// Scan (Android) or paste (desktop) a Meshtastic channel QR / link, show
/// what is in it, add it to the radio, then link it.
Future<void> startMeshImport(BuildContext context, WalkieController c) async {
  final text = await scanCode(
    context,
    title: 'Scan a Meshtastic channel QR',
    accept: MeshChannelSet.looksLikeLink,
    pasteHint: 'https://meshtastic.org/e/#...',
  );
  if (text == null || !context.mounted) return;
  final MeshChannelSet set;
  try {
    set = MeshChannelSet.parseUrl(text);
  } on MeshLinkException catch (e) {
    _snack(context, e.message);
    return;
  }
  await showMeshImportSheet(context, c, set);
}

void _snack(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

Future<void> showMeshImportSheet(
  BuildContext context,
  WalkieController c,
  MeshChannelSet set,
) async {
  final s = c.radioDevice.session;
  final info = s == null ? const MeshRadioInfo() : MeshRadioInfo.of(s);
  final preview = MeshImportPreview.build(set, info);
  final pick = await showAppSheet<(int, bool)>(
    context: context,
    scrollable: false,
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: MeshImportView(
        preview: preview,
        radioReady: c.radioDevice.ready && s != null,
        onAdd: (i, apply) => Navigator.pop(ctx, (i, apply)),
      ),
    ),
  );
  if (pick == null || !context.mounted) return;
  final (i, apply) = pick;
  if (apply) {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Change your radio\'s settings?'),
        content: Text(
          'Your radio will switch to ${preview.mismatch ?? 'this QR\'s settings'}. '
          'It will no longer hear your current group until you change it '
          'back in the Meshtastic app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('mesh-apply-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Change radio settings'),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
  }
  final result = await _runWithProgress<MeshWriteResult>(
    context,
    (onStep) =>
        c.meshWriter().addChannel(set, i, applyLora: apply, onStep: onStep),
  );
  if (result == null || !context.mounted) return;
  final lora = set.loraToApply;
  final link = MeshLink(
    ref: result.ref,
    keyKind: set.keyKindOf(i),
    uplink: set.channels[i].uplinkEnabled,
    preset: lora?.presetLabel ?? '',
    created: DateTime.now().millisecondsSinceEpoch,
  );
  c.debugLog.add(
    'mesh',
    result.alreadyThere
        ? 'channel already on the radio (slot ${result.index})'
        : 'channel added to radio slot ${result.index}',
  );
  final linkedTo = c.walkieChannelFor(link.ref);
  if (linkedTo != null) {
    _snack(context, 'Already shared with ${_channelLabel(c, linkedTo)}.');
    return;
  }
  await pickWalkieChannel(context, c, link);
}

/// Shows progress while [work] runs; null (after a message) on failure.
Future<T?> _runWithProgress<T>(
  BuildContext context,
  Future<T> Function(void Function(MeshWriteStep) onStep) work,
) async {
  final step = ValueNotifier(MeshWriteStep.preparing);
  final nav = Navigator.of(context);
  var open = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder(
            valueListenable: step,
            builder: (_, s, _) => Row(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text(meshWriteStepText(s))),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => open = false),
  );
  try {
    final r = await work((s) => step.value = s);
    if (open) nav.pop();
    return r;
  } on MeshWriteException catch (e) {
    if (open) nav.pop();
    if (context.mounted) _snack(context, e.message);
    return null;
  } catch (_) {
    if (open) nav.pop();
    if (context.mounted) {
      _snack(context, 'Your radio did not take the change. Try again.');
    }
    return null;
  }
}

/// "Share with which Walkie channel?": a new channel (named after the
/// Meshtastic channel) or an existing open one. Private channels are not
/// offered.
Future<void> pickWalkieChannel(
  BuildContext context,
  WalkieController c,
  MeshLink link,
) async {
  final options = c.linkableChannels;
  if (options.isEmpty) {
    _snack(context, 'No open Walkie channel is free to share.');
    return;
  }
  // A new channel: the highest free open number (low ones stay for talk).
  final fresh = options.last;
  var pick = fresh;
  var makeNew = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        scrollable: true,
        title: const Text('Share with a Walkie channel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ignore: deprecated_member_use
            RadioListTile<bool>(
              key: const Key('mesh-link-new'),
              contentPadding: EdgeInsets.zero,
              value: true,
              // ignore: deprecated_member_use
              groupValue: makeNew,
              // ignore: deprecated_member_use
              onChanged: (v) => set(() {
                makeNew = true;
                pick = fresh;
              }),
              title: Text('New channel "${link.ref.name}" (CH $fresh)'),
            ),
            // ignore: deprecated_member_use
            RadioListTile<bool>(
              key: const Key('mesh-link-existing'),
              contentPadding: EdgeInsets.zero,
              value: false,
              // ignore: deprecated_member_use
              groupValue: makeNew,
              // ignore: deprecated_member_use
              onChanged: (v) => set(() => makeNew = false),
              title: Row(
                children: [
                  const Text('Open channel '),
                  DropdownButton<int>(
                    key: const Key('mesh-link-number'),
                    value: pick,
                    items: [
                      for (final ch in options)
                        DropdownMenuItem(
                          value: ch,
                          child: Text(_channelLabel(c, ch)),
                        ),
                    ],
                    onChanged: (v) => set(() {
                      makeNew = false;
                      pick = v ?? pick;
                    }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Shared with Meshtastic: anyone with that Meshtastic QR can '
              'listen, and you cannot see them. Removing someone needs a '
              'new QR shared with everyone else.',
              key: Key('mesh-link-note'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('mesh-link-go'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Share'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final ch = makeNew ? fresh : pick;
  final err = await c.linkMeshChannel(
    ch,
    link,
    name: makeNew ? link.ref.name : null,
  );
  if (!context.mounted) return;
  _snack(
    context,
    err ?? 'CH $ch is now shared with Meshtastic channel "${link.ref.name}".',
  );
}

/// ⋮ > Unlink, optionally also removing the channel from the radio.
Future<void> confirmUnlink(
  BuildContext context,
  WalkieController c,
  int ch,
) async {
  var remove = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        scrollable: true,
        title: Text('Unlink ${_channelLabel(c, ch)}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Walkie stops using the Meshtastic channel for this channel.',
            ),
            CheckboxListTile(
              key: const Key('mesh-unlink-remove'),
              contentPadding: EdgeInsets.zero,
              value: remove,
              onChanged: (v) => set(() => remove = v ?? false),
              title: const Text('Also remove the channel from my radio'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('mesh-unlink-go'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unlink'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  String? err;
  if (remove) {
    final r = await _runWithProgress<String?>(
      context,
      (onStep) =>
          c.unlinkMeshChannel(ch, removeFromRadio: true, onStep: onStep),
    );
    err = r;
  } else {
    err = await c.unlinkMeshChannel(ch);
  }
  if (context.mounted) _snack(context, err ?? 'Unlinked.');
}
