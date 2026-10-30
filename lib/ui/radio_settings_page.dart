import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../lora/meshtastic_admin.dart';
import '../lora/meshtastic_session.dart';
import '../lora/meshtastic_settings.dart';
import 'adaptive_layout.dart';

/// Radio settings (v2.5.3): the basics of the paired Meshtastic radio
/// without leaving the app. A page on phones, a dialog on wide screens.
/// Nothing is read or sent until a button here is pressed.
Future<void> openRadioSettings(BuildContext context, WalkieController c) {
  final size = MediaQuery.sizeOf(context);
  if (isTwoPane(size.width, size.height)) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const Key('radio-settings-dialog'),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: RadioSettingsPage(controller: c, dialog: true),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => RadioSettingsPage(controller: c)),
  );
}

/// Why the radio cannot be edited right now, null when it can.
String? radioEditBlockedText(WalkieController c) {
  final s = c.radioDevice.session;
  if (!c.radioPaired || s == null || !c.radioDevice.ready) {
    return 'Connect your radio first (Settings > Long-range radio).';
  }
  if (c.radioEditing) return null;
  if (c.radioEditBlocked) {
    return 'A talk is going on. Settings can change when it is over.';
  }
  return null;
}

/// The "Not here" line.
const radioNotHereText =
    'Not here (use the Meshtastic app): factory reset, reboot, firmware, '
    'security keys, the main channel name and key, Wi-Fi / MQTT, modules, '
    'display, role, position precision and intervals, transmit power, '
    'custom speed.';

/// The lines of the read-only summary.
List<String> radioSummaryLines(MeshtasticSession s) {
  final me = s.myNodeNum == null ? null : s.nodes[s.myNodeNum];
  final long = me?.longName ?? '';
  final short = me?.shortName ?? '';
  final sec = s.positionSecs;
  return [
    if (long.isNotEmpty || short.isNotEmpty)
      'Name: ${long.isEmpty ? '(none)' : long}'
          '${short.isEmpty ? '' : ' ($short)'}',
    'Region: ${s.region == null ? 'unknown' : radioRegionText(s.region!)}',
    'Speed: ${s.modemPreset == null ? 'unknown' : radioPresetText(s.modemPreset!, usePreset: s.usePreset ?? true)}',
    'Hop limit: ${s.hopLimit ?? 3}${(s.hopLimit ?? 3) == 0 ? ' (not repeated)' : ''}',
    'Location sharing: ${sec == null
        ? 'unknown'
        : locationSharingOn(sec, s.positionSmart)
        ? 'on'
        : 'off'}',
  ];
}

class RadioSettingsPage extends StatefulWidget {
  const RadioSettingsPage({
    super.key,
    required this.controller,
    this.dialog = false,
  });
  final WalkieController controller;
  final bool dialog;

  @override
  State<RadioSettingsPage> createState() => _RadioSettingsPageState();
}

class _RadioSettingsPageState extends State<RadioSettingsPage> {
  late final TextEditingController _long;
  late final TextEditingController _short;
  String? _longError, _shortError;
  int _hop = 3;
  int _region = 0;
  int _preset = 0;
  MeshWriteStep? _step;
  String? _failed;
  String? _saved;

  WalkieController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _long = TextEditingController();
    _short = TextEditingController();
    _loadFields();
  }

  @override
  void dispose() {
    _long.dispose();
    _short.dispose();
    super.dispose();
  }

  void _loadFields() {
    final s = c.radioDevice.session;
    if (s == null) return;
    final me = s.myNodeNum == null ? null : s.nodes[s.myNodeNum];
    _long.text = me?.longName ?? '';
    _short.text = me?.shortName ?? '';
    _hop = (s.hopLimit ?? 3).clamp(0, 7);
    _region = s.region ?? 0;
    _preset = s.modemPreset ?? 0;
  }

  Future<void> _run(RadioChange change, String savedText) async {
    setState(() {
      _step = MeshWriteStep.preparing;
      _failed = null;
      _saved = null;
    });
    final err = await c.changeRadioSettings(
      change,
      onStep: (st) {
        if (mounted) setState(() => _step = st);
      },
    );
    _finish(err, savedText);
  }

  Future<void> _restore() async {
    final b = c.radioBackup;
    if (b == null) return;
    final ok = await _confirm(
      title: 'Restore previous settings?',
      lines: ['Back to: ${b.previous.summary}'],
    );
    if (ok != true || !mounted) return;
    setState(() {
      _step = MeshWriteStep.preparing;
      _failed = null;
      _saved = null;
    });
    final err = await c.restoreRadioSettings(
      onStep: (st) {
        if (mounted) setState(() => _step = st);
      },
    );
    _finish(err, 'Previous settings restored.');
  }

  void _finish(String? err, String savedText) {
    if (!mounted) return;
    setState(() {
      _step = null;
      _failed = err;
      _saved = err == null ? savedText : null;
      if (err == null) _loadFields();
    });
  }

  Future<bool?> _confirm({
    required String title,
    required List<String> lines,
  }) => showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('rs-confirm-dialog'),
      scrollable: true,
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(radioConfirmText, key: const Key('rs-confirm-text')),
          const SizedBox(height: 8),
          for (final l in lines) Text(l),
          const SizedBox(height: 8),
          const Text(
            'Your radio saves this and restarts (up to a minute); Bluetooth '
            'drops and comes back by itself.',
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('rs-cancel'),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('rs-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Change'),
        ),
      ],
    ),
  );

  Future<void> _saveNames() async {
    final le = validateLongName(_long.text);
    final se = validateShortName(_short.text);
    setState(() {
      _longError = le;
      _shortError = se;
    });
    if (le != null || se != null) return;
    await _run(
      RadioChange.names(longName: _long.text, shortName: _short.text),
      'Name saved.',
    );
  }

  Future<void> _saveHop() async {
    if (validateHopLimit(_hop) != null) return;
    await _run(RadioChange.hop(_hop), 'Hop limit saved.');
  }

  Future<void> _toggleLocation(bool on) async {
    final b = c.radioBackup;
    await _run(
      on
          ? RadioChange.sharingOn(secs: b?.sharingSecs, smart: b?.sharingSmart)
          : RadioChange.sharingOff(),
      on ? 'Location sharing is on.' : 'Location sharing is off.',
    );
  }

  Future<void> _changeRegion(MeshtasticSession s) async {
    final ok = await _confirm(
      title: 'Change region?',
      lines: [
        'Region: ${radioRegionText(s.region ?? 0)} → ${radioRegionText(_region)}',
      ],
    );
    if (ok != true || !mounted) return;
    await _run(RadioChange.region(_region), 'Region saved.');
  }

  Future<void> _changePreset(MeshtasticSession s) async {
    final ok = await _confirm(
      title: 'Change speed?',
      lines: [
        'Speed: ${radioPresetText(s.modemPreset ?? 0, usePreset: s.usePreset ?? true)} → ${radioPresetText(_preset)}',
      ],
    );
    if (ok != true || !mounted) return;
    await _run(RadioChange.preset(_preset), 'Speed saved.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.dialog,
        leading: widget.dialog
            ? IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: const Text('Radio settings'),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final s = c.radioDevice.session;
            final blocked = radioEditBlockedText(c);
            final busy = _step != null || c.radioEditing;
            final canEdit = blocked == null && !busy && s != null;
            final backup = c.radioBackup;
            final small = theme.textTheme.bodySmall;
            Widget head(String t) => Padding(
              padding: const EdgeInsets.only(top: 20, bottom: 4),
              child: Text(t, style: theme.textTheme.titleSmall),
            );
            return ListView(
              key: const Key('rs-list'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (blocked != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      blocked,
                      key: const Key('rs-blocked'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.error,
                      ),
                    ),
                  ),
                if (s != null)
                  Card(
                    key: const Key('rs-summary'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.radioDevice.deviceName ??
                                c.settings.radioName ??
                                'Your radio',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          for (final l in radioSummaryLines(s)) Text(l),
                        ],
                      ),
                    ),
                  ),
                if (_step != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      key: const Key('rs-progress'),
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(meshWriteStepText(_step!))),
                      ],
                    ),
                  ),
                if (_saved != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      key: const Key('rs-saved'),
                      children: [
                        Icon(Icons.check_circle, color: cs.primary),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Saved. $_saved')),
                      ],
                    ),
                  ),
                if (_failed != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      key: const Key('rs-failed'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Not saved: $_failed',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: cs.error,
                          ),
                        ),
                        if (backup != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: FilledButton.tonalIcon(
                              key: const Key('rs-restore-failed'),
                              icon: const Icon(Icons.restore),
                              label: const Text('Restore previous settings'),
                              onPressed: busy ? null : _restore,
                            ),
                          ),
                      ],
                    ),
                  ),
                head('Name'),
                TextField(
                  key: const Key('rs-long'),
                  controller: _long,
                  enabled: canEdit,
                  maxLength: 39,
                  decoration: InputDecoration(
                    labelText: 'Long name',
                    errorText: _longError,
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() => _longError = null),
                ),
                TextField(
                  key: const Key('rs-short'),
                  controller: _short,
                  enabled: canEdit,
                  maxLength: 4,
                  decoration: InputDecoration(
                    labelText: 'Short name (up to 4 characters)',
                    errorText: _shortError,
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() => _shortError = null),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('rs-name-save'),
                    onPressed: canEdit ? _saveNames : null,
                    child: const Text('Save name'),
                  ),
                ),
                head('Hop limit'),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        key: const Key('rs-hop'),
                        value: _hop.toDouble(),
                        min: 0,
                        max: 7,
                        divisions: 7,
                        label: '$_hop',
                        onChanged: canEdit
                            ? (v) => setState(() => _hop = v.round())
                            : null,
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      child: Text('$_hop', key: const Key('rs-hop-value')),
                    ),
                  ],
                ),
                Text(
                  'How many times a message is repeated by other radios. More '
                  'hops reach farther but use more airtime for everyone. 3 is '
                  'the usual; 0 means not repeated at all.',
                  style: small,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('rs-hop-save'),
                    onPressed: canEdit && s.hopLimit != _hop ? _saveHop : null,
                    child: const Text('Save hop limit'),
                  ),
                ),
                head('Location sharing'),
                SwitchListTile(
                  key: const Key('rs-location'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Radio shares its position'),
                  subtitle: const Text(
                    'Turns the radio\'s own position broadcast on or off. '
                    'Off stops the timed broadcasts (a radio can still send '
                    'one when it starts). The app does not send this phone\'s '
                    'GPS to the radio. Turning it on puts back the interval '
                    'it had.',
                  ),
                  value:
                      s != null &&
                      s.positionSecs != null &&
                      locationSharingOn(s.positionSecs, s.positionSmart),
                  onChanged: canEdit && s.positionSecs != null
                      ? _toggleLocation
                      : null,
                ),
                head('Region and speed'),
                DropdownButtonFormField<int>(
                  key: const Key('rs-region'),
                  initialValue: radioRegions.any((r) => r.code == _region)
                      ? _region
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Region',
                    helperText: _region == 0 || s?.region == 0
                        ? 'Not set: the radio will not transmit.'
                        : null,
                  ),
                  items: [
                    for (final r in radioRegions)
                      DropdownMenuItem(
                        value: r.code,
                        child: Text(
                          r.hint.isEmpty ? r.label : '${r.label} · ${r.hint}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: canEdit
                      ? (v) => setState(() => _region = v ?? _region)
                      : null,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('rs-region-change'),
                    onPressed:
                        canEdit && _region != 0 && _region != (s.region ?? 0)
                        ? () => _changeRegion(s)
                        : null,
                    child: const Text('Change region...'),
                  ),
                ),
                DropdownButtonFormField<int>(
                  key: const Key('rs-preset'),
                  initialValue: radioPresets.any((p) => p.code == _preset)
                      ? _preset
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Speed'),
                  items: [
                    for (final p in radioPresets)
                      DropdownMenuItem(
                        value: p.code,
                        child: Text(
                          p.hint.isEmpty ? p.label : '${p.label} · ${p.hint}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: canEdit
                      ? (v) => setState(() => _preset = v ?? _preset)
                      : null,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('rs-preset-change'),
                    onPressed:
                        canEdit &&
                            (_preset != (s.modemPreset ?? 0) ||
                                s.usePreset == false)
                        ? () => _changePreset(s)
                        : null,
                    child: const Text('Change speed...'),
                  ),
                ),
                Text(
                  'Slower speeds reach farther but carry less. Every radio in '
                  'your group needs the same region and speed.',
                  style: small,
                ),
                if (backup != null) ...[
                  head('Undo'),
                  Text(
                    'Before the last change your radio had: '
                    '${backup.previous.summary}.',
                    key: const Key('rs-backup-line'),
                    style: small,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const Key('rs-restore'),
                      icon: const Icon(Icons.restore),
                      label: const Text('Restore previous settings'),
                      onPressed: canEdit ? _restore : null,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  radioNotHereText,
                  key: const Key('rs-not-here'),
                  style: small?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
