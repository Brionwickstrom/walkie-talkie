import 'package:flutter/material.dart';

import '../app/battery_guide.dart';
import '../app/link_settings.dart';
import '../app/walkie_controller.dart';

/// Background reliability guide (v1.8.7): the standard Android exemption
/// plus the phone maker's own steps.
class BatteryGuideView extends StatelessWidget {
  const BatteryGuideView({
    super.key,
    required this.guide,
    required this.exempt,
    required this.onAllow,
    required this.onVendor,
    required this.onAppInfo,
  });
  final BatteryGuide guide;

  /// Battery optimization already off for the app (null = unknown).
  final bool? exempt;
  final VoidCallback onAllow;
  final VoidCallback onVendor;
  final VoidCallback onAppInfo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'To ring you, deliver voice messages and keep Wi-Fi and internet '
          'links open while the app is closed, Android must not put it to '
          'sleep. The "listening" notification keeps it running.',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              exempt == true ? Icons.check_circle : Icons.battery_alert,
              color: exempt == true ? Colors.green : theme.colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                exempt == true
                    ? 'Step 1 done: battery optimization is off for this app.'
                    : 'Step 1: allow the app to run in the background (tap '
                          'Allow, then "Allow").',
                key: const Key('battery-step1'),
              ),
            ),
          ],
        ),
        if (exempt != true)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('battery-allow'),
              onPressed: onAllow,
              child: const Text('Allow'),
            ),
          ),
        const SizedBox(height: 12),
        Text(
          guide.brand == PhoneBrand.other
              ? 'Step 2: on this phone'
              : 'Step 2: ${guide.name} settings',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        for (final (i, s) in guide.steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${i + 1}. $s', key: Key('battery-guide-$i')),
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          alignment: WrapAlignment.end,
          children: [
            if (guide.brand != PhoneBrand.other &&
                guide.brand != PhoneBrand.pixel)
              OutlinedButton(
                key: const Key('battery-vendor'),
                onPressed: onVendor,
                child: Text('Open ${guide.name} screen'),
              ),
            OutlinedButton(
              key: const Key('battery-appinfo'),
              onPressed: onAppInfo,
              child: const Text('App info'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'A phone that is off, or where the app was force-stopped, cannot be '
          'reached.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// The guide as a dialog.
Future<void> showBatteryGuide(BuildContext context, WalkieController c) async {
  final guide = batteryGuideFor(await c.bridge.manufacturer());
  final exempt = c.bridge.supported
      ? await c.bridge.ignoringBatteryOptimizations()
      : null;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Let Walkie Talkie run in the background'),
      content: SingleChildScrollView(
        child: BatteryGuideView(
          guide: guide,
          exempt: exempt,
          onAllow: () {
            Navigator.pop(ctx);
            c.requestBatteryExemption();
          },
          onVendor: () {
            Navigator.pop(ctx);
            c.openVendorBattery();
          },
          onAppInfo: () {
            Navigator.pop(ctx);
            c.openPhoneSettings(PhoneSetting.appInfo);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
