import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../core/gateway_protocol.dart' show GatewayInfo;
import '../lora/meshtastic_ble.dart';
import '../lora/meshtastic_proto.dart';
import '../lora/meshtastic_session.dart';
import '../lora/stream_radio.dart';
import '../platform/platform_caps.dart';
import 'mesh_channels.dart';

/// How to pair, shown before and while pairing.
const radioPinHelp =
    'When Android asks for a PIN: radios without a screen (SenseCAP '
    'T1000-E) use 123456. Radios with a screen (RAK WisMesh Pocket) show '
    'the PIN on their screen. Unless you changed it in the Meshtastic app.';

String radioStateText(RadioState s) => switch (s) {
  RadioState.none => 'No radio paired',
  RadioState.bluetoothOff => 'Bluetooth is off',
  RadioState.connecting => 'Connecting...',
  RadioState.pairing => 'Waiting for the PIN (see below)',
  RadioState.configuring => 'Loading radio settings...',
  RadioState.ready => 'Connected',
  RadioState.reconnecting => 'Not connected, retrying',
};

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// Lines describing the connected radio (also used by tests).
List<String> radioDetailLines(MeshtasticSession s, {int appPhones = 0}) {
  final out = <String>[];
  final b = s.battery;
  if (b != null) {
    out.add(b > 100 ? 'Battery: charging / powered' : 'Battery: $b%');
  }
  out.add('Meshtastic nodes heard: ${s.nodeCount}');
  out.add('App phones on the radio: $appPhones');
  final sig = s.lastSignal;
  if (sig != null) {
    out.add(
      'Last signal: SNR ${sig.snr.toStringAsFixed(1)} dB, '
      'RSSI ${sig.rssi} dBm'
      '${sig.hopsAway != null && sig.hopsAway! > 0 ? ', ${sig.hopsAway} hops' : ''}'
      ' (${_ago(sig.at)})',
    );
  }
  final r = s.region;
  if (r != null) {
    out.add(
      'Region ${regionName(r)} · ${presetName(s.modemPreset ?? 0)}'
      ' · hop limit ${(s.hopLimit ?? 0) > 0 ? s.hopLimit : 3}',
    );
  }
  final ch = s.primaryChannelName;
  if (ch != null) {
    out.add('Channel: ${ch.isEmpty ? '(default)' : ch}');
  }
  return out;
}

/// Problems the user should fix in the official Meshtastic app.
List<String> radioWarnings(MeshtasticSession s) => [
  if (s.region == 0)
    'Region is not set: the radio will not transmit. Set it to US in the '
        'Meshtastic app (Radio config > LoRa).',
  if (s.txEnabled == false && s.region != null && s.region != 0)
    'Transmit is turned off on this radio (LoRa > Transmit enabled).',
  if (s.primaryUsesDefaultKey == true)
    'The radio uses the public default channel: strangers with Meshtastic '
        'radios carry (and on public app channels can read) your packets. '
        'Make a private channel in the Meshtastic app and share it to every '
        'radio of your group (QR code).',
];

/// Settings > Long-range radio (Meshtastic).
/// "1 radio connected", "Waiting for its radio", "Phone sharing its radio".
String gatewayStatusText(GatewayInfo g) {
  if (g.phone) return 'A phone sharing its radio';
  if (g.radiosUp <= 0) return 'Online, waiting for its radio';
  return '${g.radiosUp} radio${g.radiosUp == 1 ? '' : 's'} connected'
      '${g.radios > g.radiosUp ? ' (of ${g.radios})' : ''}';
}

class RadioSettings extends StatefulWidget {
  const RadioSettings({super.key, required this.controller});
  final WalkieController controller;

  @override
  State<RadioSettings> createState() => _RadioSettingsState();
}

class _RadioSettingsState extends State<RadioSettings> {
  bool _scanning = false;
  List<FoundRadio>? _found;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = null;
    });
    final r = await widget.controller.scanRadios();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _found = r;
    });
  }

  Future<void> _addWifiRadio(BuildContext context) async {
    final id = await askWifiRadio(context);
    if (id == null) return;
    await widget.controller.pairRadio(
      FoundRadio(id, StreamRadioId.label(id), 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final dev = c.radioDevice;
        final s = dev.session;
        final children = <Widget>[
          const Text(
            'Pair a Meshtastic LoRa radio to reach phones miles away with no '
            'cell or Wi-Fi. Only used for people nothing else reaches. It is '
            'slow (a few small packets a minute), so no live talk: texts, '
            'locations, rings and short voice messages (up to 8 s). Each '
            'person needs a radio on the same Meshtastic channel.',
          ),
          const SizedBox(height: 8),
        ];
        final desktop = PlatformCaps.streamRadios;
        if (desktop) {
          children.add(
            Text(
              'On this computer the radio connects by USB cable or over '
              'Wi-Fi (radios with Wi-Fi, set to Wi-Fi mode in the Meshtastic '
              'app). Close the Meshtastic app / web client first: only one '
              'program can use the radio at a time.',
              style: theme.textTheme.bodySmall,
            ),
          );
          children.add(const SizedBox(height: 8));
        }
        if (!c.radioPaired) {
          children.addAll([
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const Key('radioScan'),
                  icon: const Icon(Icons.settings_input_antenna),
                  label: Text(
                    _scanning
                        ? 'Looking...'
                        : desktop
                        ? 'Find USB radio'
                        : 'Find my radio',
                  ),
                  onPressed: _scanning ? null : _scan,
                ),
                if (desktop)
                  OutlinedButton.icon(
                    key: const Key('radioWifi'),
                    icon: const Icon(Icons.wifi),
                    label: const Text('Wi-Fi radio'),
                    onPressed: () => _addWifiRadio(context),
                  ),
                if (_scanning)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_found != null && _found!.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  desktop
                      ? 'No USB radio found. Plug it in with a data USB cable '
                            '(some cables only charge), wait a few seconds and '
                            'try again.'
                      : 'No radio found. Turn it on, keep it close, and make '
                            'sure the official Meshtastic app is not connected '
                            'to it.',
                ),
              ),
            for (final r in _found ?? const <FoundRadio>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings_input_antenna),
                title: Text(r.name),
                subtitle: Text(
                  r.isStream ? 'USB serial' : 'Signal ${r.rssi} dBm',
                ),
                trailing: FilledButton.tonal(
                  onPressed: () => c.pairRadio(r),
                  child: Text(r.isStream ? 'Connect' : 'Pair'),
                ),
              ),
            if (!desktop) ...[
              const SizedBox(height: 4),
              Text(radioPinHelp, style: theme.textTheme.bodySmall),
            ],
          ]);
        } else {
          final ok = dev.state == RadioState.ready;
          children.add(
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.settings_input_antenna,
                color: ok ? cs.primary : cs.outline,
              ),
              title: Text(dev.deviceName ?? c.settings.radioName ?? 'Radio'),
              subtitle: Text(
                [
                  radioStateText(dev.state),
                  if (!ok && dev.detail != null) dev.detail!,
                ].join(' · '),
              ),
            ),
          );
          if (!dev.isStream &&
              (dev.state == RadioState.pairing ||
                  dev.state == RadioState.connecting)) {
            children.add(Text(radioPinHelp, style: theme.textTheme.bodySmall));
          }
          if (s != null) {
            for (final l in radioDetailLines(s, appPhones: c.radioPeers)) {
              children.add(Text(l, style: theme.textTheme.bodySmall));
            }
            final q = c.loraTransport.queued;
            if (q > 0) {
              children.add(
                Text(
                  'Waiting to send over the radio: $q packet${q == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            for (final w in radioWarnings(s)) {
              children.add(
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    w,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
              );
            }
          }
          if (!c.radioVoiceSupported) {
            children.add(
              Text(
                'Voice messages over the radio are not available on this '
                '${desktop ? 'computer' : 'phone'} (texts, locations and rings '
                'still work).',
                style: theme.textTheme.bodySmall,
              ),
            );
          }
          children.add(
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.link_off),
                label: Text(dev.isStream ? 'Disconnect radio' : 'Forget radio'),
                onPressed: c.forgetRadio,
              ),
            ),
          );
        }
        // v1.9.5: LoRa gateways (Home gateway on the Synology, phones
        // sharing their radio) in this channel's relay room.
        if (c.radioPaired) {
          children.add(
            SwitchListTile(
              key: const Key('shareRadio'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Share my radio with phones on the internet'),
              subtitle: const Text(
                'While you have signal, phones on this channel that are on '
                'the internet can reach radio-only people through your '
                'radio, and the other way round. Private channels stay '
                'encrypted. Never live talk.',
              ),
              value: c.settings.shareRadio,
              onChanged: c.setShareRadio,
            ),
          );
        }
        final gws = c.gateways;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('LoRa gateways', style: theme.textTheme.titleSmall),
          ),
        );
        if (gws.isEmpty) {
          children.add(
            Text(
              'None on this channel right now. A Home gateway (radio at '
              'home on the Synology) or a phone sharing its radio shows up '
              'here; then people with only a radio can reach you over the '
              'internet, and you them.',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        for (final g in gws) {
          children.add(
            ListTile(
              key: Key('gateway${g.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                g.phone ? Icons.phone_android : Icons.router,
                color: g.radiosUp > 0 ? cs.primary : cs.outline,
              ),
              title: Text(g.name),
              subtitle: Text(gatewayStatusText(g)),
            ),
          );
        }
        // v1.9.7: Meshtastic channels shared with Walkie channels.
        children.add(MeshChannelsSection(controller: c));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}

/// Asks for a Wi-Fi radio's address; a "tcp:host:port" radio id or null.
Future<String?> askWifiRadio(BuildContext context) {
  final ctl = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void done() {
          final id = StreamRadioId.fromTyped(ctl.text);
          if (id == null) {
            setState(() => error = 'Type an address like 192.168.1.40');
            return;
          }
          Navigator.pop(ctx, id);
        }

        return AlertDialog(
          title: const Text('Wi-Fi radio'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The radio\'s address on your network. The Meshtastic app '
                'shows it under Settings > Network once Wi-Fi is on, or try '
                'meshtastic.local.',
              ),
              TextField(
                key: const Key('wifiRadioAddress'),
                controller: ctl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '192.168.1.40',
                  errorText: error,
                ),
                onSubmitted: (_) => done(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(onPressed: done, child: const Text('Connect')),
          ],
        );
      },
    ),
  );
}
