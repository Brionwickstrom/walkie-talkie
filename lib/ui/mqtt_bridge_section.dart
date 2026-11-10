// Settings > MQTT bridge (v2.6.15). The password box is obscured and cleared
// after it is saved. Nothing is written to the radio until the preview is
// confirmed. Check now is one sign-in; there is no timer.
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../lora/meshtastic_session.dart';
import '../mqtt/mqtt_config.dart';
import '../mqtt/mqtt_radio.dart';
import '../trip/battery_mode.dart';
import 'friendly_error.dart';

/// Channels the connected radio has already told us about. No keys.
List<MqttChannelSnap> mqttSnapsOf(MeshtasticSession? s) {
  if (s == null) return const [];
  final pub = s.publicListenIndex;
  final list = s.channels.values.toList()
    ..sort((a, b) => a.index.compareTo(b.index));
  return [
    for (final c in list)
      if (!c.isDisabled)
        MqttChannelSnap(
          index: c.index,
          name: c.effectiveName(s.presetDisplayName),
          listenOnly: c.index == pub,
        ),
  ];
}

FixAction mqttFixAction(MqttFix f) => switch (f) {
  MqttFix.connectRadio => FixAction.connectRadio,
  MqttFix.enterPassword => FixAction.enterMqttPassword,
  MqttFix.checkBroker => FixAction.checkBroker,
  MqttFix.retry => FixAction.retry,
};

/// The confirm step. Returns the plan the user accepted, or null.
Future<MqttRadioPlan?> showMqttWritePreview(
  BuildContext context,
  MqttRadioPlan plan,
) {
  return showDialog<MqttRadioPlan>(
    context: context,
    builder: (ctx) => _MqttPreviewDialog(plan: plan),
  );
}

class _MqttPreviewDialog extends StatefulWidget {
  const _MqttPreviewDialog({required this.plan});
  final MqttRadioPlan plan;

  @override
  State<_MqttPreviewDialog> createState() => _MqttPreviewDialogState();
}

class _MqttPreviewDialogState extends State<_MqttPreviewDialog> {
  late List<MqttChannelPlan> _channels = [
    for (final c in widget.plan.channels) c,
  ];

  MqttRadioPlan get _plan => widget.plan.copyWith(channels: _channels);

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return AlertDialog(
      key: const Key('mqtt-preview'),
      scrollable: true,
      title: const Text('Configure this radio for my broker'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(mqttPreviewText(plan), key: const Key('mqtt-preview-text')),
          const SizedBox(height: 8),
          for (final c in _channels)
            if (!c.listenOnly)
              CheckboxListTile(
                key: Key('mqtt-ch-${c.index}'),
                contentPadding: EdgeInsets.zero,
                title: Text(c.name),
                subtitle: Text(
                  plan.enabled && c.selected
                      ? 'Uplink and downlink on'
                      : 'Left as it is',
                ),
                value: c.selected,
                onChanged: plan.enabled
                    ? (v) => setState(() {
                        _channels = [
                          for (final x in _channels)
                            if (x.index == c.index)
                              x.copyWith(selected: v ?? false)
                            else
                              x,
                        ];
                      })
                    : null,
              ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('mqtt-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('mqtt-confirm'),
          onPressed: () => Navigator.pop(context, plan),
          child: const Text('Write to radio'),
        ),
      ],
    );
  }
}

class MqttBridgeSection extends StatefulWidget {
  const MqttBridgeSection({super.key, required this.controller});
  final WalkieController controller;

  @override
  State<MqttBridgeSection> createState() => _MqttBridgeSectionState();
}

class _MqttBridgeSectionState extends State<MqttBridgeSection> {
  late final TextEditingController _addr;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _root;
  final _passFocus = FocusNode();
  var _hasPassword = false;
  var _busy = false;
  FriendlyError? _error;
  String? _note;
  MqttWriteStep? _step;

  WalkieController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final s = c.settings;
    _addr = TextEditingController(text: s.mqttAddress);
    _user = TextEditingController(text: s.mqttUser);
    _pass = TextEditingController();
    _root = TextEditingController(text: s.mqttRoot);
    unawaited(_loadPasswordFlag());
  }

  Future<void> _loadPasswordFlag() async {
    final has = await c.mqttPasswordSaved();
    if (mounted) setState(() => _hasPassword = has);
  }

  @override
  void dispose() {
    final pass = _pass.text;
    final enabled = c.settings.mqttEnabled;
    final addr = _addr.text;
    final user = _user.text;
    final root = _root.text;
    _addr.dispose();
    _user.dispose();
    _pass.dispose();
    _root.dispose();
    _passFocus.dispose();
    unawaited(
      c.setMqttBridge(
        enabled: enabled,
        address: addr,
        username: user,
        root: root,
        password: pass.isEmpty ? null : pass,
      ),
    );
    super.dispose();
  }

  Future<void> _save({String? password}) async {
    final pass = password ?? _pass.text;
    await c.setMqttBridge(
      enabled: c.settings.mqttEnabled,
      address: _addr.text,
      username: _user.text,
      root: _root.text,
      password: pass.isEmpty ? null : pass,
    );
    if (pass.isNotEmpty) _pass.clear();
    if (!mounted) return;
    setState(() {
      if (pass.isNotEmpty) _hasPassword = true;
      _note = 'Saved on this phone.';
      _error = null;
    });
  }

  Future<void> _check() async {
    await _save();
    await c.checkMqttBroker();
    if (!mounted) return;
    final probe = c.mqttProbe;
    setState(() {
      _error = probe == null || probe.ok
          ? null
          : FriendlyError(
              probe.line,
              fix: FixAction.checkBroker,
              details: probe.details,
            );
    });
  }

  Future<void> _configure() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await _save();
    final session = c.radioDevice.session;
    final prep = prepareMqttWrite(
      radioReady: c.radioDevice.ready && session != null,
      hasChannels: session != null && session.channels.isNotEmpty,
      enabled: c.settings.mqttEnabled,
      addressRaw: c.settings.mqttAddress,
      username: c.settings.mqttUser,
      rootRaw: c.settings.mqttRoot,
      hasPassword: await c.mqttPasswordSaved(),
      channels: mqttSnapsOf(session),
    );
    if (!mounted) return;
    final problem = prep.problem;
    final plan = prep.plan;
    if (problem != null || plan == null) {
      setState(() {
        _busy = false;
        _error = FriendlyError(
          problem?.message ?? 'The MQTT settings could not be prepared.',
          fix: mqttFixAction(problem?.fix ?? MqttFix.retry),
        );
      });
      return;
    }
    final err = await runMqttConfigure(
      plan: plan,
      confirm: (p) => showMqttWritePreview(context, p),
      write: (p) async {
        if (mounted) setState(() => _step = MqttWriteStep.preparing);
        await c.mqttPasswordSaved();
        final writer = MqttRadioWriter(() => c.radioDevice.session);
        await writer.apply(
          p,
          password: c.settings.mqttEnabled ? await _password() : '',
          onStep: (s) {
            if (mounted) setState(() => _step = s);
          },
        );
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = null;
      _error = err == null
          ? null
          : FriendlyError(err.message, fix: mqttFixAction(err.fix));
      _note = err == null ? 'MQTT settings saved on your radio.' : _note;
    });
  }

  Future<String> _password() async {
    final p = await c.mqttSecrets.read();
    return p ?? '';
  }

  void _onFix(FixAction a) {
    switch (a) {
      case FixAction.enterMqttPassword:
        _passFocus.requestFocus();
      case FixAction.checkBroker:
        unawaited(_check());
      case FixAction.retry:
        unawaited(_configure());
      default:
        unawaited(runFix(context, c, a));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    final saver = s.offlineSaver || s.trip.batteryMode == BatteryMode.saver;
    final reach = c.mqttProbe?.line;
    final status = mqttStatusLine(reach: reach, lastBridged: s.mqttLastBridged);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('mqtt-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Bridge mesh over my broker'),
          subtitle: Text(
            'Radios with internet copy channel traffic to your broker and '
            'pick up traffic from radios that are out of LoRa range. '
            'Packets stay channel-encrypted. This phone does not stay '
            'connected.'
            '${saver ? ' Battery mode Saver does not check the broker unless you tap Check now.' : ''}',
          ),
          value: s.mqttEnabled,
          onChanged: _busy
              ? null
              : (v) async {
                  s.mqttEnabled = v;
                  await _save();
                },
        ),
        TextField(
          key: const Key('mqtt-address'),
          controller: _addr,
          decoration: const InputDecoration(
            labelText: 'Broker address',
            hintText: 'walkie-relay.tail1700cf.ts.net:8443',
            helperText:
                'Port 8443 is the Tailscale Funnel (TLS on). '
                'Port 1883 is the NAS on your home network (TLS off).',
            helperMaxLines: 3,
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
        ),
        TextField(
          key: const Key('mqtt-user'),
          controller: _user,
          decoration: const InputDecoration(labelText: 'Username'),
          autocorrect: false,
          enableSuggestions: false,
        ),
        TextField(
          key: const Key('mqtt-password'),
          controller: _pass,
          focusNode: _passFocus,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: _hasPassword
                ? 'A password is saved on this phone.'
                : 'Not saved yet. It is not shown again.',
            helperMaxLines: 2,
          ),
        ),
        TextField(
          key: const Key('mqtt-root'),
          controller: _root,
          decoration: const InputDecoration(
            labelText: 'Topic root',
            hintText: defaultMqttRoot,
            helperText: 'Empty uses msh/stalkie. Not the public mesh.',
          ),
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 8),
        Text(status, key: const Key('mqtt-status')),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              key: const Key('mqtt-save'),
              onPressed: _busy ? null : () => _save(),
              child: const Text('Save'),
            ),
            OutlinedButton(
              key: const Key('mqtt-check'),
              onPressed: _busy ? null : _check,
              child: const Text('Check now'),
            ),
            FilledButton(
              key: const Key('mqtt-configure'),
              onPressed: _busy ? null : _configure,
              child: const Text('Configure this radio for my broker'),
            ),
            if (_hasPassword)
              TextButton(
                key: const Key('mqtt-clear-password'),
                onPressed: _busy
                    ? null
                    : () async {
                        await c.clearMqttPassword();
                        if (mounted) setState(() => _hasPassword = false);
                      },
                child: const Text('Forget password'),
              ),
          ],
        ),
        if (_step != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(mqttWriteStepText(_step!), key: const Key('mqtt-step')),
          ),
        if (_note != null && _error == null && _step == null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: FriendlyErrorView(error: _error!, onFix: _onFix),
          ),
      ],
    );
  }
}
