import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/connection_test.dart';
import '../app/link_settings.dart';
import '../app/setup.dart';
import '../app/walkie_controller.dart';
import 'battery_help.dart';
import 'radio_settings.dart';
import 'sheets.dart';

Color checkColor(CheckLevel l, ThemeData theme) => switch (l) {
  CheckLevel.ok => Colors.green,
  CheckLevel.warn => Colors.orange,
  CheckLevel.fail => theme.colorScheme.error,
  CheckLevel.off => theme.colorScheme.outline,
};

IconData checkIcon(CheckLevel l) => switch (l) {
  CheckLevel.ok => Icons.check_circle,
  CheckLevel.warn => Icons.warning_amber_rounded,
  CheckLevel.fail => Icons.cancel,
  CheckLevel.off => Icons.do_not_disturb_on_outlined,
};

/// The connection test's rows (pure, for tests).
class ConnectionTestView extends StatelessWidget {
  const ConnectionTestView({
    super.key,
    required this.rows,
    required this.running,
    required this.onFix,
    required this.onRun,
    this.onSendLog,
  });
  final List<CheckRow>? rows;
  final bool running;
  final void Function(CheckRow row) onFix;
  final VoidCallback onRun;
  final VoidCallback? onSendLog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = rows;
    final overall = r == null ? null : overallLevel(r);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (running)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Testing... the relay can take up to a minute to wake up.',
                  ),
                ),
              ],
            ),
          ),
        if (overall != null && !running)
          Card(
            key: const Key('conn-overall'),
            color: checkColor(overall, theme).withValues(alpha: 0.15),
            child: ListTile(
              leading: Icon(
                checkIcon(overall),
                color: checkColor(overall, theme),
              ),
              title: Text(switch (overall) {
                CheckLevel.ok => 'Everything works',
                CheckLevel.warn => 'Works, with some limits',
                CheckLevel.fail => 'Something needs fixing',
                CheckLevel.off => 'Everything works',
              }),
              subtitle: const Text(
                'Grey rows are off on purpose (Offline power save, Settings).',
              ),
            ),
          ),
        for (final row in r ?? const <CheckRow>[])
          Card(
            key: Key('conn-${row.id}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        checkIcon(row.level),
                        color: checkColor(row.level, theme),
                        semanticLabel: row.level.name,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          row.title,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(row.detail, style: theme.textTheme.bodyMedium),
                  if (row.fix != CheckFix.none && row.level != CheckLevel.ok)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: Key('conn-fix-${row.id}'),
                        onPressed: () => onFix(row),
                        child: Text(fixLabel(row.fix)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('conn-run'),
          icon: const Icon(Icons.refresh),
          label: Text(r == null ? 'Run test' : 'Test again'),
          onPressed: running ? null : onRun,
        ),
        if (onSendLog != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('conn-send-log'),
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('Send debug log'),
            onPressed: onSendLog,
          ),
        ],
      ],
    );
  }
}

Future<void> openConnectionTest(BuildContext context, WalkieController c) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectionTestPage(controller: c),
      ),
    );

class ConnectionTestPage extends StatefulWidget {
  const ConnectionTestPage({super.key, required this.controller});
  final WalkieController controller;

  @override
  State<ConnectionTestPage> createState() => _ConnectionTestPageState();
}

class _ConnectionTestPageState extends State<ConnectionTestPage> {
  WalkieController get c => widget.controller;
  List<CheckRow>? _rows;
  bool _running = false;
  AppLifecycleListener? _life;

  @override
  void initState() {
    super.initState();
    _run();
    // Back from a settings screen: test again.
    _life = AppLifecycleListener(
      onResume: () {
        if (mounted && !_running) _run();
      },
    );
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final rows = await c.runConnectionTest();
      if (mounted) setState(() => _rows = rows);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _fix(CheckRow row) async {
    switch (row.fix) {
      case CheckFix.none:
        return;
      case CheckFix.wifiSettings:
        await c.openPhoneSettings(PhoneSetting.wifi);
      case CheckFix.bluetoothPermission:
        if (await c.requestAppPermission(AppPermission.nearby)) await _run();
      case CheckFix.bluetoothSettings:
        await c.openPhoneSettings(PhoneSetting.bluetooth);
      case CheckFix.appInfo:
        await c.openPhoneSettings(PhoneSetting.appInfo);
      case CheckFix.mobileNetwork:
        await c.openPhoneSettings(PhoneSetting.mobileNetwork);
      case CheckFix.batteryExemption:
        await c.requestBatteryExemption();
      case CheckFix.batteryGuide:
        await showBatteryGuide(context, c);
      case CheckFix.radioPairing:
        await showAppSheet<void>(
          context: context,
          scrollable: false,
          builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: RadioSettings(controller: c),
            ),
          ),
        );
        await _run();
      case CheckFix.permissions:
        await c.requestAllPermissions();
        await _run();
      case CheckFix.relaySettings:
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            scrollable: true,
            title: const Text('Internet relay'),
            content: Text(
              c.relayOverride.isEmpty
                  ? 'This phone uses the app\'s default relay. If it keeps '
                        'failing while the internet works, the network may '
                        'block it (some work / school Wi-Fi): try mobile data.'
                  : 'Settings > Relay server is set to "${c.relayOverride}". '
                        'Clear it to use the default relay.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Connection test')),
    body: ConnectionTestView(
      rows: _rows,
      running: _running,
      onFix: _fix,
      onRun: _run,
      onSendLog: () => sendDebugLog(context, c),
    ),
  );
}

/// "Send debug log": share sheet with the log file, or copy it.
Future<void> sendDebugLog(BuildContext context, WalkieController c) async {
  final pick = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('Send debug log'),
      content: const Text(
        'A text file with connection events from this phone: app version, '
        'phone model, Android version and link states. Passcodes, keys and '
        'precise locations are removed. Call signs are included.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('log-copy'),
          onPressed: () => Navigator.pop(ctx, 'copy'),
          child: const Text('Copy'),
        ),
        FilledButton(
          key: const Key('log-share'),
          onPressed: () => Navigator.pop(ctx, 'share'),
          child: const Text('Share'),
        ),
      ],
    ),
  );
  if (pick == null) return;
  if (pick == 'copy') {
    final text = await c.debugReport();
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Debug log copied')));
    }
    return;
  }
  final ok = await c.shareDebugLog();
  if (!ok && context.mounted) {
    final text = await c.debugReport();
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the share sheet; copied instead'),
        ),
      );
    }
  }
}
