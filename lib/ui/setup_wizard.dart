import 'dart:async';

import 'package:flutter/material.dart';

import '../app/battery_guide.dart';
import '../app/link_settings.dart';
import '../app/setup.dart';
import '../app/walkie_controller.dart';
import 'battery_help.dart';
import 'home_view.dart' show cellIcon;
import 'invite_sheet.dart';
import 'radio_settings.dart';
import 'sheets.dart';

/// What the setup wizard needs from the app (a fake in tests).
abstract class SetupHost {
  String get callSign;
  String get customName;
  void rerollCallSign();

  Future<Map<AppPermission, PermState>> permissionStates();
  Future<bool> requestPermission(AppPermission p);
  Future<void> requestAllPermissions();

  /// Start the links (after the permission step).
  Future<void> startLinks();

  String get internetText;
  CellState get cell;
  Future<void> refreshNet();
  Future<void> openSetting(PhoneSetting s);

  Future<bool?> batteryExempt();
  Future<String> manufacturer();
  Future<void> requestBattery();
  Future<void> openVendorBattery();

  int get channel;
  bool isPrivate(int channel);

  /// Wizard finished: apply name and channel ([private] false makes the
  /// channel public; a null [passcode] keeps the saved one).
  Future<void> finish({
    required String name,
    required int channel,
    required bool private,
    String? passcode,
  });

  /// Skipped / closed.
  Future<void> skip();

  Future<void> pairRadio(BuildContext context);
  Future<void> scanInvite(BuildContext context);
}

class ControllerSetupHost implements SetupHost {
  ControllerSetupHost(this.c);
  final WalkieController c;

  @override
  String get callSign => c.settings.defaultName;
  @override
  String get customName => c.settings.customName ?? '';
  @override
  void rerollCallSign() => c.rerollCallSign();
  @override
  Future<Map<AppPermission, PermState>> permissionStates() =>
      c.permissionStates();
  @override
  Future<bool> requestPermission(AppPermission p) => c.requestAppPermission(p);
  @override
  Future<void> requestAllPermissions() => c.requestAllPermissions();
  @override
  Future<void> startLinks() async {
    await c.start();
    await c.restartDownLinks();
  }

  @override
  String get internetText => c.internetStatus.text;
  @override
  CellState get cell => c.cellStatus;
  @override
  Future<void> refreshNet() => c.refreshPhoneNet();
  @override
  Future<void> openSetting(PhoneSetting s) => c.openPhoneSettings(s);
  @override
  Future<bool?> batteryExempt() async =>
      c.bridge.supported ? await c.bridge.ignoringBatteryOptimizations() : null;
  @override
  Future<String> manufacturer() => c.bridge.manufacturer();
  @override
  Future<void> requestBattery() => c.requestBatteryExemption();
  @override
  Future<void> openVendorBattery() => c.openVendorBattery();
  @override
  int get channel => c.channel;
  @override
  bool isPrivate(int ch) => c.settings.isPrivate(ch);

  @override
  Future<void> finish({
    required String name,
    required int channel,
    required bool private,
    String? passcode,
  }) async {
    await c.start();
    if (name.trim() != customName) c.setName(name);
    if (private && passcode != null && passcode.trim().isNotEmpty) {
      await c.setChannelPrivacy(channel, passcode);
    } else if (!private && c.settings.isPrivate(channel)) {
      await c.setChannelPrivacy(channel, null);
    }
    if (channel != c.channel) await c.setChannel(channel);
    await c.markSetupDone();
  }

  @override
  Future<void> skip() async {
    await c.markSetupDone();
    // Skipped before the permission step: ask the usual way.
    c.permissionsBySetup = false;
    await c.start();
  }

  @override
  Future<void> pairRadio(BuildContext context) => showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: RadioSettings(controller: c),
      ),
    ),
  );

  @override
  Future<void> scanInvite(BuildContext context) async {
    await c.start();
    if (context.mounted) await scanInviteFlow(context, c);
  }
}

/// Indirection so tests never touch the camera.
Future<void> scanInviteFlow(BuildContext context, WalkieController c) =>
    scanInvite(context, c);

/// Open the wizard (first run, or Settings > Setup wizard).
Future<void> openSetupWizard(BuildContext context, WalkieController c) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => SetupWizardPage(host: ControllerSetupHost(c)),
      ),
    );

/// First-run setup (v1.8.7): call sign, permissions, mobile data, battery,
/// channel and an optional radio. Skippable at every step.
class SetupWizardPage extends StatefulWidget {
  const SetupWizardPage({super.key, required this.host});
  final SetupHost host;

  @override
  State<SetupWizardPage> createState() => _SetupWizardPageState();
}

class _SetupWizardPageState extends State<SetupWizardPage> {
  SetupHost get h => widget.host;
  SetupStep _step = SetupStep.name;
  late final TextEditingController _name = TextEditingController(
    text: h.customName,
  );
  final TextEditingController _pass = TextEditingController();
  Map<AppPermission, PermState> _perms = {};
  bool? _exempt;
  BatteryGuide? _guide;
  late int _channel = h.channel;
  late bool _private = h.isPrivate(h.channel);
  String? _passErr;
  bool _busy = false;
  AppLifecycleListener? _life;
  bool _linksStarted = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _life = AppLifecycleListener(onResume: _refresh);
  }

  @override
  void dispose() {
    _life?.dispose();
    _name.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final p = await h.permissionStates();
    final e = await h.batteryExempt();
    final g = batteryGuideFor(await h.manufacturer());
    await h.refreshNet();
    if (!mounted) return;
    setState(() {
      _perms = p;
      _exempt = e;
      _guide = g;
    });
  }

  Future<void> _next() async {
    if (_step == SetupStep.permissions && !_linksStarted) {
      _linksStarted = true;
      unawaited(h.startLinks());
    }
    if (_step == SetupStep.channel && _private) {
      final p = _pass.text.trim();
      if (p.length < 6 && !h.isPrivate(_channel)) {
        setState(() => _passErr = 'Use at least 6 characters');
        return;
      }
    }
    if (_step.last) {
      await _finish();
      return;
    }
    setState(() => _step = SetupStep.values[_step.index + 1]);
    if (_step == SetupStep.data) await _refresh();
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      await h.finish(
        name: _name.text,
        channel: _channel,
        private: _private,
        passcode: _private && _pass.text.trim().isNotEmpty
            ? _pass.text.trim()
            : null,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _skip() async {
    await h.skip();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = SetupStep.values.length;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_step.index > 0) {
          setState(() => _step = SetupStep.values[_step.index - 1]);
        } else {
          _skip();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Setup ${_step.index + 1} of $n'),
          automaticallyImplyLeading: false,
          actions: [
            TextButton(
              key: const Key('setup-skip'),
              onPressed: _busy ? null : _skip,
              child: const Text('Skip setup'),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              LinearProgressIndicator(value: (_step.index + 1) / n),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      _step.title,
                      key: const Key('setup-title'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._body(context),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Row(
                  children: [
                    if (_step.index > 0)
                      TextButton(
                        key: const Key('setup-back'),
                        onPressed: _busy
                            ? null
                            : () => setState(
                                () => _step = SetupStep.values[_step.index - 1],
                              ),
                        child: const Text('Back'),
                      ),
                    const Spacer(),
                    FilledButton(
                      key: const Key('setup-next'),
                      onPressed: _busy ? null : _next,
                      child: Text(_step.last ? 'Done' : 'Next'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final theme = Theme.of(context);
    switch (_step) {
      case SetupStep.name:
        return [
          const Text(
            'Others see you by this name. Keep the random call sign or type '
            'your own.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  h.callSign,
                  key: const Key('setup-callsign'),
                  style: theme.textTheme.titleLarge,
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Pick another call sign',
                icon: const Icon(Icons.casino),
                onPressed: () => setState(h.rerollCallSign),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('setup-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Your name (optional)',
              hintText: 'Empty = call sign',
            ),
          ),
        ];
      case SetupStep.permissions:
        return [
          const Text(
            'Walkie Talkie works without internet by talking to phones '
            'nearby. That needs these permissions.',
          ),
          const SizedBox(height: 8),
          for (final p in AppPermission.values)
            if (_perms[p] != PermState.notNeeded)
              ListTile(
                key: Key('setup-perm-${p.name}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _perms[p] == PermState.granted
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: _perms[p] == PermState.granted ? Colors.green : null,
                ),
                title: Text(p.label),
                subtitle: Text(p.why),
                trailing: _perms[p] == null || _perms[p] == PermState.granted
                    ? null
                    : TextButton(
                        onPressed: () async {
                          await h.requestPermission(p);
                          await _refresh();
                        },
                        child: Text(permissionAction(_perms[p]!)),
                      ),
              ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            key: const Key('setup-allow-all'),
            onPressed: () async {
              await h.requestAllPermissions();
              await _refresh();
            },
            child: const Text('Allow all'),
          ),
        ];
      case SetupStep.data:
        return [
          const Text(
            'Far away (other towns), phones meet over the internet relay. '
            'It works on Wi-Fi and on mobile data, if the phone lets this '
            'app use mobile data in the background.',
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              key: const Key('setup-net'),
              leading: Icon(cellIcon(h.cell, null)),
              title: Text(h.internetText),
              subtitle: Text(switch (h.cell) {
                CellState.active => 'Mobile data: in use by the app',
                CellState.available => 'Mobile data: available',
                CellState.off => 'Mobile data: off or no service',
                CellState.blocked =>
                  'Mobile data: blocked for this app (fix below)',
                CellState.saver => 'Mobile data: Offline power save is on',
                CellState.unknown => 'Mobile data: unknown',
              }),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'In App info > Mobile data (or "Data usage"): turn on Mobile '
            'data and Background data, and "Unrestricted data" if Data '
            'Saver is on.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                key: const Key('setup-appinfo'),
                onPressed: () => h.openSetting(PhoneSetting.appInfo),
                child: const Text('Open App info'),
              ),
              OutlinedButton(
                onPressed: () => h.openSetting(PhoneSetting.mobileNetwork),
                child: const Text('Mobile network'),
              ),
            ],
          ),
        ];
      case SetupStep.battery:
        final g = _guide;
        return [
          if (g == null)
            const LinearProgressIndicator()
          else
            BatteryGuideView(
              guide: g,
              exempt: _exempt,
              onAllow: () async {
                await h.requestBattery();
              },
              onVendor: h.openVendorBattery,
              onAppInfo: () => h.openSetting(PhoneSetting.appInfo),
            ),
        ];
      case SetupStep.channel:
        return [
          const Text(
            'Everyone on the same channel hears each other. A private '
            'channel needs the same passcode on every phone.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Channel'),
              const SizedBox(width: 12),
              DropdownButton<int>(
                key: const Key('setup-channel'),
                value: _channel,
                items: [
                  for (var i = 1; i <= 16; i++)
                    DropdownMenuItem(value: i, child: Text('CH $i')),
                ],
                onChanged: (v) => setState(() {
                  _channel = v ?? _channel;
                  _private = h.isPrivate(_channel);
                }),
              ),
            ],
          ),
          SegmentedButton<bool>(
            key: const Key('setup-privacy'),
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Public'),
                icon: Icon(Icons.lock_open),
              ),
              ButtonSegment(
                value: true,
                label: Text('Private'),
                icon: Icon(Icons.lock),
              ),
            ],
            selected: {_private},
            onSelectionChanged: (v) => setState(() => _private = v.first),
          ),
          if (_private) ...[
            const SizedBox(height: 8),
            TextField(
              key: const Key('setup-passcode'),
              controller: _pass,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: h.isPrivate(_channel)
                    ? 'New passcode (empty = keep the saved one)'
                    : 'Passcode (at least 6 characters)',
                errorText: _passErr,
              ),
              onChanged: (_) {
                if (_passErr != null) setState(() => _passErr = null);
              },
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('setup-scan'),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan an invite instead'),
            onPressed: () => h.scanInvite(context),
          ),
        ];
      case SetupStep.radio:
        return [
          const Text(
            'Optional: a Meshtastic LoRa radio paired over Bluetooth reaches '
            'miles further, with no phone signal at all (slow: texts, '
            'rings, locations and short voice messages).',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('setup-radio'),
            icon: const Icon(Icons.settings_input_antenna),
            label: const Text('Pair a radio'),
            onPressed: () => h.pairRadio(context),
          ),
          const SizedBox(height: 12),
          const Text(
            'No radio? Tap Done. You can run this setup again any time from '
            'Settings > Setup wizard, and test everything with Settings > '
            'Connection test.',
          ),
        ];
    }
  }
}
