import 'dart:async';

import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../core/peer.dart';
import '../core/transport.dart';
import '../update/update_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});
  final WalkieController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  WalkieController get c => widget.controller;
  Timer? _tick;
  final UpdateFlow _updates = UpdateFlow();
  String _version = '';

  @override
  void initState() {
    super.initState();
    c.start();
    _updates.updater.currentVersionLabel().then((v) {
      if (mounted) setState(() => _version = v);
    }).catchError((_) {});
    // Quiet update check shortly after start (after permission prompts).
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _updates.check(context);
    });
    // Refresh link ages / debug lines.
    _tick = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(c.name),
          actions: [
            _ChannelPicker(
              channel: c.channel,
              onChanged: (ch) => c.setChannel(ch),
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => _openSettings(context),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              _TransportBar(transports: c.transports),
              _DebugBar(
                transports: c.transports,
                playbackDropped: c.playbackDropped,
              ),
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    c.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: _PeerList(
                  peers: c.peers,
                  channel: c.channel,
                  linkTimeout: c.manager.linkTimeout,
                ),
              ),
              _PttButton(
                transmitting: c.transmitting,
                busy: c.talkingPeer != null,
                onChanged: c.pushToTalk,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSettings(BuildContext context) async {
    final nameCtl = TextEditingController(text: c.name);
    final relayCtl = TextEditingController(text: c.relayUri?.toString() ?? '');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: 'Your name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: relayCtl,
              decoration: const InputDecoration(
                labelText: 'Internet relay URL',
                hintText: 'wss://relay.example.com/',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                c.setName(nameCtl.text);
                c.setRelayUrl(relayCtl.text);
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
            const Divider(height: 32),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _version.isEmpty ? 'Version' : 'Version $_version',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.system_update),
                  label: const Text('Check for updates'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _updates.check(context, userInitiated: true);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelPicker extends StatelessWidget {
  const _ChannelPicker({required this.channel, required this.onChanged});
  final int channel;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<int>(
      value: channel,
      underline: const SizedBox.shrink(),
      items: [
        for (var i = 1; i <= 16; i++)
          DropdownMenuItem(value: i, child: Text('CH $i')),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({required this.transports});
  final List<Transport> transports;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        spacing: 6,
        children: [
          for (final t in transports)
            Tooltip(
              message: t.statusDetail ?? t.status.name,
              child: Chip(
                avatar: Icon(
                  _iconFor(t.kind),
                  size: 16,
                  color: t.status == TransportStatus.running
                      ? Colors.green
                      : Colors.grey,
                ),
                label: Text(t.kind.label),
              ),
            ),
        ],
      ),
    );
  }
}

IconData _iconFor(TransportKind k) => switch (k) {
  TransportKind.lan => Icons.wifi,
  TransportKind.ble => Icons.bluetooth,
  TransportKind.internet => Icons.public,
};

/// One small monospace line per transport with its diagnostics.
class _DebugBar extends StatelessWidget {
  const _DebugBar({required this.transports, required this.playbackDropped});
  final List<Transport> transports;
  final int playbackDropped;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(fontFamily: 'monospace', fontSize: 11, color: Colors.grey);
    final lines = [
      for (final t in transports)
        if (t.debugInfo != null || t.status != TransportStatus.running)
          '${_short(t.kind)}: ${t.status.name}'
              '${t.debugInfo != null ? ' · ${t.debugInfo}' : ''}'
              '${t.status != TransportStatus.running && t.statusDetail != null ? ' · ${t.statusDetail}' : ''}',
      if (playbackDropped > 0) 'speaker: dropped $playbackDropped late frames',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final l in lines) Text(l, style: style)],
      ),
    );
  }
}

String _short(TransportKind k) => switch (k) {
  TransportKind.lan => 'WiFi',
  TransportKind.ble => 'BLE',
  TransportKind.internet => 'Net',
};

/// e.g. "via WiFi | WiFi 0.3s 8ms | BLE 0.7s 41ms"
String peerDebugLine(Peer p, DateTime now) {
  final parts = <String>[
    'via ${p.activeLink == null ? 'none' : _short(p.activeLink!)}',
  ];
  for (final k in TransportKind.values) {
    final seen = p.lastSeen[k];
    if (seen == null) continue;
    final age = now.difference(seen).inMilliseconds / 1000;
    final rtt = p.rtt[k];
    parts.add(
      '${_short(k)} ${age.toStringAsFixed(1)}s'
      '${rtt != null ? ' ${rtt.inMilliseconds}ms' : ''}',
    );
  }
  return parts.join(' | ');
}

class _PeerList extends StatelessWidget {
  const _PeerList({
    required this.peers,
    required this.channel,
    required this.linkTimeout,
  });
  final List<Peer> peers;
  final int channel;
  final Duration linkTimeout;

  @override
  Widget build(BuildContext context) {
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Looking for other phones...\n\nSame Wi-Fi or hotspot, Bluetooth '
            'nearby, or the same internet relay all work.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final now = DateTime.now();
    return ListView(
      children: [
        for (final p in peers)
          ListTile(
            leading: Icon(
              p.talking ? Icons.record_voice_over : Icons.person,
              color: p.talking ? Colors.red : null,
            ),
            title: Text(p.displayName),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.channel == channel
                      ? 'On your channel'
                      : 'On channel ${p.channel}',
                ),
                Text(
                  peerDebugLine(p, now),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ),
            trailing: Wrap(
              spacing: 4,
              children: [
                for (final k in p.liveLinks(now, linkTimeout))
                  Icon(
                    _iconFor(k),
                    size: 20,
                    color: k == p.activeLink
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PttButton extends StatelessWidget {
  const _PttButton({
    required this.transmitting,
    required this.busy,
    required this.onChanged,
  });
  final bool transmitting;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final color = transmitting
        ? Colors.red
        : busy
        ? Colors.orange
        : Theme.of(context).colorScheme.primary;
    return Listener(
      onPointerDown: (_) => onChanged(true),
      onPointerUp: (_) => onChanged(false),
      onPointerCancel: (_) => onChanged(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: transmitting ? 210 : 190,
        height: transmitting ? 210 : 190,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.4),
              blurRadius: transmitting ? 30 : 12,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              transmitting ? Icons.mic : Icons.mic_none,
              size: 64,
              color: Colors.white,
            ),
            Text(
              transmitting
                  ? 'TALKING'
                  : busy
                  ? 'RECEIVING'
                  : 'HOLD TO TALK',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
