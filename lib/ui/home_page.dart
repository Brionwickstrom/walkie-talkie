import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/config.dart';
import '../app/walkie_controller.dart';
import '../core/peer.dart';
import '../core/transport.dart';
import '../update/update_ui.dart';
import 'inbox_page.dart';

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
  final List<StreamSubscription<dynamic>> _subs = [];
  AppLifecycleListener? _lifecycle;
  DateTime _lastUpdateCheck = DateTime.now();

  @override
  void initState() {
    super.initState();
    c.start().then((_) => _maybeAskBattery());
    _updates.updater
        .currentVersionLabel()
        .then((v) {
          if (mounted) setState(() => _version = v);
        })
        .catchError((_) {});
    // Quiet update check shortly after start (after permission prompts).
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _updates.check(context);
    });
    // The app can now live for days in the background: check again when
    // it comes back to the screen after a while.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (DateTime.now().difference(_lastUpdateCheck) >
            const Duration(hours: 6)) {
          _lastUpdateCheck = DateTime.now();
          if (mounted) _updates.check(context);
        }
      },
    );
    _subs.add(
      c.notices.listen((msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(msg)));
      }),
    );
    _subs.add(
      c.uiRequests.listen((r) {
        if (r == 'inbox' && mounted) _openInbox(context);
      }),
    );
    // Refresh link ages / debug lines / recording timer.
    _tick = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    _lifecycle?.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// One-time friendly explanation before Android's battery prompt.
  Future<void> _maybeAskBattery() async {
    if (!mounted || !c.bridge.supported) return;
    if (!c.settings.stayReachable || c.settings.batteryPromptShown) return;
    if (await c.bridge.ignoringBatteryOptimizations()) return;
    if (!mounted) return;
    await c.markBatteryPromptShown();
    if (!mounted) return;
    await showBatteryHelp(context, c);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(c.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Voice messages',
              icon: Badge(
                isLabelVisible: c.unplayedMessages > 0,
                label: Text('${c.unplayedMessages}'),
                child: const Icon(Icons.voicemail),
              ),
              onPressed: () => _openInbox(context),
            ),
            IconButton(
              tooltip: c.isPrivate
                  ? 'Private channel (tap for passcode)'
                  : 'Make this channel private',
              icon: c.switchingChannel
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(c.isPrivate ? Icons.lock : Icons.lock_open),
              onPressed: () => showPrivacySheet(context, c),
            ),
            _ChannelPicker(
              channel: c.channel,
              isPrivate: c.settings.isPrivate,
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
              for (final r in List.of(c.activeRings))
                _RingBanner(
                  name: c.nameOf(r.from),
                  channel: c.labelFor(r.channel),
                  onAnswer: () => c.answerRing(r),
                  onDismiss: () => c.dismissRing(r),
                ),
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
                  controller: c,
                  peers: c.peers,
                  channel: c.scope,
                  linkTimeout: c.manager.linkTimeout,
                  onRecordFor: (p) => _openRecordSheet(context, p),
                ),
              ),
              if (c.outgoing.isNotEmpty || c.waitingForAnyone.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.schedule_send, size: 18),
                  label: Text(_queuedLabel()),
                  onPressed: () => _openInbox(context),
                ),
              _ActionRow(controller: c),
              const SizedBox(height: 8),
              _PttButton(
                transmitting: c.transmitting,
                busy: c.talkingPeer != null,
                onChanged: c.pushToTalk,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  String _queuedLabel() {
    final sending = c.outgoing.where((o) => o.sending).length;
    final waiting =
        c.outgoing.where((o) => !o.sending).length + c.waitingForAnyone.length;
    final parts = [
      if (sending > 0) 'sending $sending',
      if (waiting > 0) '$waiting waiting for someone to come in range',
    ];
    return 'Voice messages: ${parts.join(', ')}';
  }

  void _openInbox(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => InboxPage(controller: c)));
  }

  Future<void> _openRecordSheet(BuildContext context, Peer p) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Voice message to ${p.displayName}',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                'Hold the button and talk (up to 30 s). Let go to send. '
                'If they are out of range it is delivered when they come back.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              _RecordButton(controller: c, toPeer: p.id, big: true),
            ],
          ),
        ),
      ),
    );
    if (c.recording != null) await c.stopRecording();
  }

  Future<void> _openSettings(BuildContext context) async {
    final nameCtl = TextEditingController(text: c.settings.customName ?? '');
    final relayCtl = TextEditingController(text: c.relayOverride);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your call sign',
                            style: Theme.of(ctx).textTheme.labelMedium,
                          ),
                          Text(
                            c.settings.defaultName,
                            style: Theme.of(ctx).textTheme.titleLarge,
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Pick another call sign',
                      icon: const Icon(Icons.casino),
                      onPressed: c.rerollCallSign,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                    labelText: 'Custom name (optional)',
                    hintText: c.settings.defaultName,
                    helperText: 'Leave empty to use your call sign',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: relayCtl,
                  decoration: InputDecoration(
                    labelText: 'Internet relays (optional)',
                    hintText: AppConfig.relayUrl,
                    helperText:
                        'Empty = default. Several: comma separated, first '
                        'is preferred. "off" = no internet relay.',
                    helperMaxLines: 3,
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
                if (c.bridge.supported) ...[
                  const Divider(height: 32),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Stay reachable when app is closed'),
                    subtitle: const Text(
                      'Rings, voice messages and live talk still come '
                      'through. Shows a small "listening" notification. '
                      'Uses more battery.',
                    ),
                    value: c.settings.stayReachable,
                    onChanged: (v) async {
                      await c.setStayReachable(v);
                      if (v && ctx.mounted) await showBatteryHelp(ctx, c);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start listening after phone restarts'),
                    value: c.settings.startOnBoot,
                    onChanged: c.settings.stayReachable
                        ? (v) => c.setStartOnBoot(v)
                        : null,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.battery_saver),
                        label: const Text('Battery settings'),
                        onPressed: () => showBatteryHelp(ctx, c),
                      ),
                      _FullScreenButton(controller: c),
                    ],
                  ),
                ],
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
                        _lastUpdateCheck = DateTime.now();
                        _updates.check(context, userInitiated: true);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Explains why Android / Samsung battery saving must leave the app alone,
/// then opens the right system screen.
Future<void> showBatteryHelp(BuildContext context, WalkieController c) async {
  final samsung = (await c.bridge.manufacturer()).toLowerCase().contains(
    'samsung',
  );
  final ignoring = await c.bridge.ignoringBatteryOptimizations();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Let Walkie Talkie run in the background'),
      content: SingleChildScrollView(
        child: Text(
          'To ring you or deliver voice messages while the app is closed, '
          'Android must not put it to sleep.\n\n'
          '${ignoring ? 'Battery optimization is already off for this app. ' : 'Tap Allow, then choose "Allow" (or "Unrestricted"). '}'
          '${samsung ? '\n\nSamsung phones also put apps to sleep on their own. Open Settings > Battery > Background usage limits > Never sleeping apps and add Walkie Talkie. Also set Settings > Apps > Walkie Talkie > Battery to "Unrestricted".' : ''}'
          '\n\nA phone that is turned off, or where the app was force-stopped, '
          'cannot be reached.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Not now'),
        ),
        if (samsung || ignoring)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              c.bridge.openAppSettings();
            },
            child: const Text('App settings'),
          ),
        if (!ignoring)
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              c.bridge.requestIgnoreBatteryOptimizations();
            },
            child: const Text('Allow'),
          ),
      ],
    ),
  );
}

class _FullScreenButton extends StatefulWidget {
  const _FullScreenButton({required this.controller});
  final WalkieController controller;

  @override
  State<_FullScreenButton> createState() => _FullScreenButtonState();
}

class _FullScreenButtonState extends State<_FullScreenButton> {
  bool _allowed = true;

  @override
  void initState() {
    super.initState();
    widget.controller.bridge.canUseFullScreen().then((v) {
      if (mounted) setState(() => _allowed = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed) return const SizedBox.shrink();
    return OutlinedButton.icon(
      icon: const Icon(Icons.fullscreen),
      label: const Text('Allow full-screen rings'),
      onPressed: widget.controller.bridge.openFullScreenSettings,
    );
  }
}

class _RingBanner extends StatelessWidget {
  const _RingBanner({
    required this.name,
    required this.channel,
    required this.onAnswer,
    required this.onDismiss,
  });
  final String name;
  final String channel;
  final VoidCallback onAnswer;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.tertiaryContainer,
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.ring_volume, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$name is ringing you ($channel)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
            FilledButton(onPressed: onAnswer, child: const Text('Answer')),
          ],
        ),
      ),
    );
  }
}

/// Ring all / Beep all / hold-to-record for the whole channel.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.ring_volume),
            label: const Text('Ring all'),
            onPressed: () => c.ring(),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.notifications_active),
            label: const Text('Beep'),
            onPressed: () => c.ring(beep: true),
          ),
          _RecordButton(controller: c),
        ],
      ),
    );
  }
}

/// Hold to record a voice message, release to send.
class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.controller,
    this.toPeer,
    this.big = false,
  });
  final WalkieController controller;
  final int? toPeer;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final rec = c.recording;
    final mine = rec != null && rec.toPeer == toPeer;
    final secs = mine
        ? DateTime.now().difference(rec.startedAt).inSeconds.clamp(0, 30)
        : 0;
    final cs = Theme.of(context).colorScheme;
    final label = mine
        ? 'Recording 0:${secs.toString().padLeft(2, '0')} / 0:30'
        : big
        ? 'Hold to record'
        : 'Hold: message';
    return Listener(
      onPointerDown: (_) => c.startRecording(toPeer: toPeer),
      onPointerUp: (_) => c.stopRecording(),
      onPointerCancel: (_) => c.stopRecording(cancel: true),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: big ? 32 : 14,
          vertical: big ? 22 : 10,
        ),
        decoration: BoxDecoration(
          color: mine ? Colors.red : cs.secondaryContainer,
          borderRadius: BorderRadius.circular(40),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              mine ? Icons.fiber_manual_record : Icons.keyboard_voice,
              color: mine ? Colors.white : cs.onSecondaryContainer,
              size: big ? 32 : 20,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: mine ? Colors.white : cs.onSecondaryContainer,
                fontWeight: FontWeight.w600,
                fontSize: big ? 18 : 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelPicker extends StatelessWidget {
  const _ChannelPicker({
    required this.channel,
    required this.isPrivate,
    required this.onChanged,
  });
  final int channel;
  final bool Function(int channel) isPrivate;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<int>(
      value: channel,
      underline: const SizedBox.shrink(),
      items: [
        for (var i = 1; i <= 16; i++)
          DropdownMenuItem(
            value: i,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('CH $i'),
                if (isPrivate(i)) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.lock, size: 14),
                ],
              ],
            ),
          ),
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
    required this.controller,
    required this.peers,
    required this.channel,
    required this.linkTimeout,
    required this.onRecordFor,
  });
  final WalkieController controller;
  final List<Peer> peers;
  final int channel;
  final Duration linkTimeout;
  final void Function(Peer) onRecordFor;

  @override
  Widget build(BuildContext context) {
    if (peers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Looking for other phones...\n\nSame Wi-Fi or hotspot, Bluetooth '
            'nearby, or the same internet relay all work.\n\nVoice messages '
            'you record now are delivered when someone shows up.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final now = DateTime.now();
    final c = controller;
    return ListView(
      children: [
        for (final p in peers)
          ListTile(
            onLongPress: () => onRecordFor(p),
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
                      : 'On ${c.labelFor(p.channel)}',
                ),
                if (c.ringStatusText(p.id) != null)
                  Text(
                    c.ringStatusText(p.id)!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  peerDebugLine(p, now),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final k in p.liveLinks(now, linkTimeout))
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Icon(
                      _iconFor(k),
                      size: 18,
                      color: k == p.activeLink
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                  ),
                IconButton(
                  tooltip: 'Ring ${p.displayName}',
                  icon: const Icon(Icons.ring_volume),
                  onPressed: () => c.ring(toPeer: p.id),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'ring':
                        c.ring(toPeer: p.id);
                      case 'beep':
                        c.ring(toPeer: p.id, beep: true);
                      case 'msg':
                        onRecordFor(p);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'ring', child: Text('Ring')),
                    PopupMenuItem(value: 'beep', child: Text('Beep')),
                    PopupMenuItem(value: 'msg', child: Text('Voice message')),
                  ],
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

/// Make the current channel private / public, and show its passcode with a
/// QR code so others can join.
Future<void> showPrivacySheet(BuildContext context, WalkieController c) async {
  final ch = c.channel;
  final passCtl = TextEditingController();
  var show = false;
  String? err;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final pass = c.settings.passcodeFor(ch);
        final theme = Theme.of(ctx);
        final key = c.manager.channelKey;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(pass != null ? Icons.lock : Icons.lock_open),
                    const SizedBox(width: 8),
                    Text(
                      pass != null ? 'CH $ch is private' : 'CH $ch is public',
                      style: theme.textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (pass == null) ...[
                  const Text(
                    'Set a passcode to make this channel private. Everything '
                    'on it (talk, rings, beeps, voice messages, who is here) '
                    'is encrypted. Only phones on the same channel number '
                    'with the same passcode can hear or see each other.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passCtl,
                    obscureText: !show,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Passcode (at least 6 characters)',
                      errorText: err,
                      suffixIcon: IconButton(
                        icon: Icon(
                          show ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setSheet(() => show = !show),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.lock),
                    label: const Text('Make private'),
                    onPressed: () async {
                      final p = passCtl.text.trim();
                      if (p.length < 6) {
                        setSheet(() => err = 'Use at least 6 characters');
                        return;
                      }
                      await c.setChannelPrivacy(ch, p);
                      setSheet(() => err = null);
                    },
                  ),
                ] else ...[
                  const Text(
                    'To join: on the other phone pick the same channel '
                    'number, tap the lock and type this passcode.',
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(
                        data:
                            'Walkie Talkie private channel\nCH $ch\nPasscode: $pass',
                        size: 180,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    show ? pass : '\u2022' * pass.length,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (key != null && key.channel == ch)
                    Text(
                      'Check code ${key.fingerprint} (same on every phone '
                      'with the right passcode)',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        icon: Icon(
                          show ? Icons.visibility_off : Icons.visibility,
                        ),
                        label: Text(show ? 'Hide' : 'Show'),
                        onPressed: () => setSheet(() => show = !show),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy'),
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(
                              text:
                                  'Walkie Talkie private channel: CH $ch, '
                                  'passcode: $pass',
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Copied')),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Make public again'),
                    onPressed: () async {
                      await c.setChannelPrivacy(ch, null);
                      setSheet(() {});
                    },
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}
