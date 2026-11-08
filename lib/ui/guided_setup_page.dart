// v2.6.13: Guided radio setup. One step at a time, from the Radio settings
// page (and from Settings search). Nothing is read or sent until Apply,
// and Apply goes through the existing backup / read-back writer and the
// existing "Listen to public radios" path. No channel key, PSK or channel
// link is shown.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/walkie_controller.dart';
import '../lora/guided_setup.dart';
import '../lora/meshtastic_admin.dart';
import '../lora/meshtastic_settings.dart';
import '../lora/radio_match.dart';
import '../lora/saved_radios.dart';
import 'adaptive_layout.dart';
import 'friendly_error.dart';

/// The wizard. A page on phones, a dialog on wide screens.
Future<void> openGuidedSetup(BuildContext context, WalkieController c) {
  final size = MediaQuery.sizeOf(context);
  if (isTwoPane(size.width, size.height)) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const Key('gs-dialog'),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: GuidedSetupPage(controller: c, dialog: true),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => GuidedSetupPage(controller: c)),
  );
}

enum _Step {
  connect('Connect'),
  name('Name'),
  radio('Region and hops'),
  channel('BigfootNet'),
  location('Location sharing'),
  public('Public radios'),
  review('Review'),
  apply('Apply'),
  done('Done');

  const _Step(this.title);
  final String title;
}

class GuidedSetupPage extends StatefulWidget {
  const GuidedSetupPage({
    super.key,
    required this.controller,
    this.dialog = false,
  });

  final WalkieController controller;
  final bool dialog;

  @override
  State<GuidedSetupPage> createState() => _GuidedSetupPageState();
}

class _GuidedSetupPageState extends State<GuidedSetupPage> {
  final _long = TextEditingController();
  final _short = TextEditingController();
  final _slot = TextEditingController();
  _Step _step = _Step.connect;
  int _region = guidedDefaultRegion;
  int _hop = guidedDefaultHop;
  bool _share = true;
  bool _listen = false;
  String? _seededFor;
  String? _fieldError;
  bool _applying = false;
  bool _applyStarted = false;
  bool _restored = false;
  MeshWriteStep? _writeStep;
  GuidedApplyResult? _result;
  bool _pinging = false;
  bool _pingSent = false;
  String? _pingError;

  WalkieController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
    _seed();
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    _long.dispose();
    _short.dispose();
    _slot.dispose();
    super.dispose();
  }

  void _onController() {
    if (_step == _Step.connect) _seed();
    if (mounted) setState(() {});
  }

  GuidedNow get _now => guidedFromRadio(
    ready: c.radioDevice.ready,
    radioId: c.radioDevice.deviceId,
    radioTitle: c.radioDevice.deviceName,
    session: c.radioDevice.session,
  );

  List<RadioReading> get _others => [
    for (final r in c.savedRadios)
      if (r.id != c.radioDevice.deviceId && r.reading != null) r.reading!,
  ];

  void _seed() {
    final now = _now;
    if (!now.connected || _seededFor == now.radioId) return;
    final want = suggestGuided(now, _others);
    _long.text = want.longName;
    _short.text = want.shortName;
    _region = want.region;
    _hop = want.hop;
    _slot.text = '${want.slot}';
    _share = want.shareLocation;
    _listen = want.listenPublic;
    _seededFor = now.radioId;
    _fieldError = null;
  }

  GuidedChoice? _choice() {
    final slot = int.tryParse(_slot.text.trim());
    if (slot == null) return null;
    return GuidedChoice(
      longName: _long.text,
      shortName: _short.text,
      region: _region,
      slot: slot,
      hop: _hop,
      shareLocation: _share,
      listenPublic: _listen,
    );
  }

  GuidedPlan? get _plan {
    final want = _choice();
    if (want == null || !_now.connected) return null;
    final b = c.radioBackup;
    return buildGuidedPlan(
      _now,
      want,
      sharingSecs: b?.sharingSecs,
      sharingSmart: b?.sharingSmart,
    );
  }

  /// Why Next cannot leave this step, as a plain sentence. Null when it can.
  String? _nextBlock() {
    switch (_step) {
      case _Step.connect:
        if (!_now.connected) return 'Connect your radio first.';
        return null;
      case _Step.name:
        return validateLongName(_long.text) ?? validateShortName(_short.text);
      case _Step.radio:
        final slot = int.tryParse(_slot.text.trim());
        if (slot == null) return 'Type a frequency slot, or 0 for automatic.';
        return validateGuidedRegion(_region) ??
            validateFrequencySlot(slot, _region) ??
            validateHopLimit(_hop);
      case _Step.channel:
        if (_now.bigfootIndex == null) return guidedMissingChannelText;
        return null;
      case _Step.location:
      case _Step.public:
      case _Step.review:
      case _Step.apply:
      case _Step.done:
        return null;
    }
  }

  void _go(_Step next) {
    setState(() {
      _step = next;
      _fieldError = null;
    });
    if (next == _Step.apply && !_applyStarted) {
      _applyStarted = true;
      _run();
    }
  }

  void _next() {
    final why = _nextBlock();
    if (why != null) {
      setState(() => _fieldError = why);
      return;
    }
    final i = _Step.values.indexOf(_step);
    if (i < _Step.values.length - 1) _go(_Step.values[i + 1]);
  }

  void _back() {
    if (_applying) return;
    final i = _Step.values.indexOf(_step);
    if (i == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    _go(_Step.values[i - 1]);
  }

  Future<void> _useRadio(SavedRadio r) async {
    final err = await c.switchRadio(r.id);
    if (!mounted) return;
    setState(() => _fieldError = err);
  }

  Future<void> _run() async {
    final want = _choice();
    if (want == null) return;
    setState(() {
      _applying = true;
      _restored = false;
      _result = null;
      _writeStep = MeshWriteStep.preparing;
      _fieldError = null;
    });
    final result = await c.applyGuidedSetup(
      want,
      onStep: (st) {
        if (mounted) setState(() => _writeStep = st);
      },
    );
    if (!mounted) return;
    setState(() {
      _applying = false;
      _writeStep = null;
      _result = result;
    });
  }

  Future<void> _restore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('gs-restore-dialog'),
        title: const Text('Restore the backup?'),
        content: const Text(
          'This puts back the settings this radio had before the guided '
          'setup, including whether it was listening to public radios.',
        ),
        actions: [
          TextButton(
            key: const Key('gs-restore-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('gs-restore-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _applying = true;
      _result = null;
      _writeStep = MeshWriteStep.preparing;
    });
    final err = await c.restoreRadioSettings(
      onStep: (st) {
        if (mounted) setState(() => _writeStep = st);
      },
    );
    if (!mounted) return;
    if (err == null) c.refreshSavedRadio();
    setState(() {
      _applying = false;
      _writeStep = null;
      _restored = err == null;
      _result = err == null
          ? null
          : GuidedApplyResult(error: err, backupSaved: c.radioBackup != null);
    });
  }

  Future<void> _ping() async {
    setState(() {
      _pinging = true;
      _pingError = null;
      _pingSent = false;
    });
    final err = await c.sendGuidedPing();
    if (!mounted) return;
    setState(() {
      _pinging = false;
      _pingSent = err == null;
      _pingError = err;
    });
  }

  FriendlyError _applyError(GuidedApplyResult r) {
    final raw = r.error ?? 'Your radio did not take the change.';
    if (raw == guidedMissingChannelText) {
      return const FriendlyError(
        guidedMissingChannelText,
        fix: FixAction.retry,
      );
    }
    if (raw == 'Connect your radio first.') {
      return const FriendlyError(
        'Not saved because your radio is not connected.',
        cause: ErrorCause.radioNotConnected,
        fix: FixAction.connectRadio,
      );
    }
    return radioWriteError(raw, hasBackup: r.backupSaved);
  }

  Future<void> _onApplyFix(FixAction a) async {
    if (a == FixAction.restoreBackup) {
      await _restore();
      return;
    }
    if (a == FixAction.retry) {
      if (_step == _Step.channel) {
        setState(() => _fieldError = _nextBlock());
        return;
      }
      await _run();
      return;
    }
    if (!mounted) return;
    await runFix(
      context,
      c,
      a,
      callbacks: FixCallbacks(retry: _run, restoreBackup: _restore),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = _Step.values.indexOf(_step);
    final onApply = _step == _Step.apply;
    final onDone = _step == _Step.done;
    final canNext =
        !_applying &&
        !onApply &&
        !onDone &&
        (_step != _Step.channel || _now.bigfootIndex != null) &&
        (_step != _Step.connect || _now.connected);
    String nextLabel = 'Next';
    if (_step == _Step.review) {
      final plan = _plan;
      nextLabel = plan != null && !plan.writes
          ? 'Continue'
          : 'Save a backup and apply';
    }
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
        title: const Text('Guided radio setup'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Step ${i + 1} of ${_Step.values.length}',
                    key: const Key('gs-progress'),
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (i + 1) / _Step.values.length,
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _step.title,
                    key: const Key('gs-title'),
                    style: theme.textTheme.titleLarge,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  _body(theme),
                  if (_fieldError != null &&
                      _step != _Step.channel &&
                      _step != _Step.connect)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _fieldError!,
                        key: const Key('gs-field-error'),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  TextButton(
                    key: const Key('gs-back'),
                    onPressed: _applying ? null : _back,
                    child: Text(i == 0 ? 'Close' : 'Back'),
                  ),
                  const Spacer(),
                  if (onDone)
                    FilledButton(
                      key: const Key('gs-close'),
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Done'),
                    )
                  else if (!onApply)
                    FilledButton(
                      key: const Key('gs-next'),
                      onPressed: canNext ? _next : null,
                      child: Text(nextLabel),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final small = theme.textTheme.bodySmall;
    switch (_step) {
      case _Step.connect:
        return _connect(theme, small);
      case _Step.name:
        return _name(small);
      case _Step.radio:
        return _radio(theme, small);
      case _Step.channel:
        return _channel(theme, small);
      case _Step.location:
        return _location(small);
      case _Step.public:
        return _public(theme, small);
      case _Step.review:
        return _review(theme, small);
      case _Step.apply:
        return _apply(theme, small);
      case _Step.done:
        return _done(theme, small);
    }
  }

  Widget _connect(ThemeData theme, TextStyle? small) {
    final now = _now;
    final radios = c.savedRadios;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pick the radio to bring in line with your others. '
          'Nothing is changed on this step.',
          style: small,
        ),
        const SizedBox(height: 12),
        if (now.connected)
          Card(
            key: const Key('gs-connected'),
            child: ListTile(
              leading: Icon(Icons.radio, color: theme.colorScheme.primary),
              title: Text(now.radioTitle),
              subtitle: const Text('Connected'),
            ),
          )
        else
          FriendlyErrorView(
            error: const FriendlyError(
              'Connect your radio first. Pick a saved radio below, or '
              'connect the one you use.',
              cause: ErrorCause.radioNotConnected,
              fix: FixAction.connectRadio,
            ),
            onFix: (a) => runFix(context, c, a),
          ),
        if (_fieldError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FriendlyErrorView(
              error: FriendlyError(_fieldError!, fix: FixAction.retry),
              onFix: (a) {
                if (a == FixAction.retry) setState(() => _fieldError = null);
              },
            ),
          ),
        if (radios.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Saved radios', style: theme.textTheme.titleSmall),
          for (final r in radios)
            ListTile(
              key: Key('gs-radio-${r.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(r.title),
              subtitle: Text(
                r.id == c.radioDevice.deviceId ? 'Connected' : r.kind,
              ),
              trailing: r.id == c.radioDevice.deviceId
                  ? const Icon(Icons.check)
                  : TextButton(
                      key: Key('gs-use-${r.id}'),
                      onPressed: () => _useRadio(r),
                      child: const Text('Use this radio'),
                    ),
            ),
        ],
      ],
    );
  }

  Widget _name(TextStyle? small) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Other radios see the long name. The short name is up to 4 '
          'characters.',
          style: small,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('gs-long'),
          controller: _long,
          maxLength: 39,
          decoration: InputDecoration(
            labelText: 'Long name',
            errorText:
                validateLongName(_long.text) != null && _fieldError != null
                ? validateLongName(_long.text)
                : null,
            counterText: '',
          ),
          onChanged: (_) => setState(() => _fieldError = null),
        ),
        TextField(
          key: const Key('gs-short'),
          controller: _short,
          maxLength: 4,
          decoration: InputDecoration(
            labelText: 'Short name',
            errorText:
                validateShortName(_short.text) != null && _fieldError != null
                ? validateShortName(_short.text)
                : null,
            counterText: '',
          ),
          onChanged: (_) => setState(() => _fieldError = null),
        ),
      ],
    );
  }

  Widget _radio(ThemeData theme, TextStyle? small) {
    final pub = radioPublicSlot(_region);
    final mhz = pub == null ? null : radioSlotMhz(_region, pub);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'These have to match your other radios, or they will not hear '
          'each other. Hop limit starts at $guidedDefaultHop when your '
          'other radios have not been read.',
          style: small,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          key: const Key('gs-region'),
          initialValue: radioRegions.any((r) => r.code == _region)
              ? _region
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Region'),
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
          onChanged: (v) => setState(() => _region = v ?? _region),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('gs-slot'),
          controller: _slot,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 3,
          decoration: InputDecoration(
            labelText: 'Frequency slot',
            counterText: '',
            helperText: pub == null
                ? '0 means automatic, from the main channel name.'
                : '0 means automatic. The public LongFast slot here is '
                      '$pub${mhz == null ? '' : ' (${radioMhzText(mhz)})'}.',
            helperMaxLines: 2,
          ),
          onChanged: (_) => setState(() => _fieldError = null),
        ),
        const SizedBox(height: 8),
        Text('Hop limit', style: theme.textTheme.titleSmall),
        Row(
          children: [
            Expanded(
              child: Slider(
                key: const Key('gs-hop'),
                value: _hop.toDouble(),
                min: 0,
                max: 7,
                divisions: 7,
                label: '$_hop',
                onChanged: (v) => setState(() => _hop = v.round()),
              ),
            ),
            SizedBox(
              width: 24,
              child: Text('$_hop', key: const Key('gs-hop-value')),
            ),
          ],
        ),
        Text(
          'How many times other radios repeat a message. More hops reach '
          'farther and use more airtime for everyone. 0 means not repeated.',
          style: small,
        ),
      ],
    );
  }

  Widget _channel(ThemeData theme, TextStyle? small) {
    final now = _now;
    if (now.bigfootIndex == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'BigfootNet is set to Full, which is your exact spot '
            '(precision $guidedBigfootPrecision).',
            style: small,
          ),
          const SizedBox(height: 12),
          FriendlyErrorView(
            error: const FriendlyError(
              guidedMissingChannelText,
              fix: FixAction.retry,
            ),
            onFix: (_) => setState(() {}),
          ),
        ],
      );
    }
    final have = radioPrecisionText(now.bigfootPrecision ?? 0);
    final same = now.bigfootPrecision == guidedBigfootPrecision;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'BigfootNet will use Full (exact), precision '
          '$guidedBigfootPrecision. That shows your exact spot to everyone '
          'on the channel. The channel name is not changed.',
          key: const Key('gs-precision-note'),
          style: small,
        ),
        const SizedBox(height: 12),
        Text(
          same
              ? 'Already ${radioPrecisionText(guidedBigfootPrecision)}. '
                    'Nothing to change on this step.'
              : 'Now: $have. This step sets it to '
                    '${radioPrecisionText(guidedBigfootPrecision)}.',
          key: const Key('gs-precision'),
        ),
      ],
    );
  }

  Widget _location(TextStyle? small) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'This is the radio\'s own position broadcast, not this phone\'s '
          'GPS. Off stops the timed broadcasts.',
          style: small,
        ),
        SwitchListTile(
          key: const Key('gs-location'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Radio shares its position'),
          value: _share,
          onChanged: (v) => setState(() => _share = v),
        ),
      ],
    );
  }

  Widget _public(ThemeData theme, TextStyle? small) {
    final slot = radioPublicSlot(_region);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Listen to public radios'),
        Text(
          'Optional. This is the same listen-only public LongFast channel '
          'as on the Radio settings page. Nothing is sent on it: no '
          'messages, no location, no internet upload.'
          '${slot == null ? '' : ' In this region that channel is frequency slot $slot.'}',
          key: const Key('gs-public-note'),
          style: small,
        ),
        SwitchListTile(
          key: const Key('gs-public'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Listen to public radios'),
          value: _listen,
          onChanged: (v) => setState(() => _listen = v),
        ),
        if (_listen && _now.publicShares)
          Text(
            'This public LongFast channel was set up outside the app and '
            'shares more than listening. Leaving this on makes it '
            'listen-only.',
            key: const Key('gs-public-shares'),
            style: small?.copyWith(color: theme.colorScheme.error),
          ),
      ],
    );
  }

  Widget _review(ThemeData theme, TextStyle? small) {
    final plan = _plan;
    if (plan == null) {
      return const Text('Connect your radio first.');
    }
    return Column(
      key: const Key('gs-review'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          plan.writes
              ? 'A backup of this radio\'s current settings is saved before '
                    'anything is written. You can put that backup back on '
                    'the next step.'
              : 'This radio already matches. Nothing will be written, so '
                    'no backup is needed.',
          key: const Key('gs-backup-note'),
          style: small,
        ),
        const SizedBox(height: 8),
        for (final line in plan.lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              line.sentence,
              key: Key(
                'gs-line-${line.label.toLowerCase().replaceAll(' ', '-')}',
              ),
              style: line.changes
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    )
                  : small,
            ),
          ),
        if (plan.lines.any(
          (l) => l.label.startsWith('BigfootNet') && l.changes,
        ))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Only the location precision of BigfootNet is changed.',
              style: small,
            ),
          ),
      ],
    );
  }

  Widget _apply(ThemeData theme, TextStyle? small) {
    final result = _result;
    return Column(
      key: const Key('gs-apply'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_applying)
          Row(
            key: const Key('gs-writing'),
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _writeStep == null
                      ? 'Talking to your radio...'
                      : meshWriteStepText(_writeStep!),
                ),
              ),
            ],
          ),
        if (_restored)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Previous settings are back on this radio.',
              key: Key('gs-restored'),
            ),
          ),
        if (result != null && result.checks.isNotEmpty)
          Column(
            key: const Key('gs-checks'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final check in result.checks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        check.ok ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: check.ok
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          check.sentence,
                          key: Key('gs-check-${check.id}'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        if (result != null && result.ok && !_restored) ...[
          Text(
            result.alreadyMatched
                ? 'Nothing was written.'
                : 'A backup of the previous settings is saved.',
            key: const Key('gs-applied'),
            style: small,
          ),
          const SizedBox(height: 8),
          if (result.backupSaved)
            OutlinedButton.icon(
              key: const Key('gs-restore'),
              onPressed: _applying ? null : _restore,
              icon: const Icon(Icons.restore),
              label: const Text('Restore'),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('gs-to-done'),
              onPressed: () => _go(_Step.done),
              child: const Text('Next'),
            ),
          ),
        ],
        if (result != null && result.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FriendlyErrorView(
              error: _applyError(result),
              keyFor: (a) =>
                  a == FixAction.restoreBackup ? const Key('gs-restore') : null,
              onFix: _onApplyFix,
            ),
          ),
      ],
    );
  }

  Widget _done(ThemeData theme, TextStyle? small) {
    final name = _long.text.trim().isEmpty
        ? _now.radioTitle
        : _long.text.trim();
    return Column(
      key: const Key('gs-done'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$name is ready.', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '$name is in your saved radios.',
          key: const Key('gs-saved-radio'),
        ),
        const SizedBox(height: 12),
        Text(
          'Send a short test ping so the other radios can hear this one. '
          'It is repeated at most once, to keep airtime and battery low.',
          style: small,
        ),
        const SizedBox(height: 8),
        if (_pingSent)
          const Text('Test ping sent.', key: Key('gs-ping-sent'))
        else
          FilledButton.tonalIcon(
            key: const Key('gs-ping'),
            onPressed: _pinging ? null : _ping,
            icon: const Icon(Icons.sensors),
            label: Text(_pinging ? 'Sending...' : 'Send test ping'),
          ),
        if (_pingError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FriendlyErrorView(
              error: _pingError == 'Connect your radio first.'
                  ? const FriendlyError(
                      'Connect your radio first.',
                      cause: ErrorCause.radioNotConnected,
                      fix: FixAction.connectRadio,
                    )
                  : FriendlyError(_pingError!, fix: FixAction.retry),
              onFix: (a) {
                if (a == FixAction.retry) _ping();
                if (a == FixAction.connectRadio) runFix(context, c, a);
              },
            ),
          ),
      ],
    );
  }
}
