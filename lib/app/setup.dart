/// First-run setup wizard and the "Run setup check" prompt (v1.8.7).
library;

/// What the app shows at start for setup.
enum SetupEntry {
  /// Fresh install: the setup wizard (skippable).
  wizard,

  /// Updated from an older version: a one-time "Run setup check" prompt,
  /// never the forced wizard.
  prompt,

  /// Nothing.
  none,
}

/// [newInstall]: this launch created the phone id. [setupDone]: the wizard
/// was finished or skipped. [promptShown]: the update prompt was shown.
SetupEntry setupEntryFor({
  required bool newInstall,
  required bool setupDone,
  required bool promptShown,
}) {
  if (setupDone) return SetupEntry.none;
  if (newInstall) return SetupEntry.wizard;
  return promptShown ? SetupEntry.none : SetupEntry.prompt;
}

/// Wizard pages, in order.
enum SetupStep {
  name('Your call sign'),
  permissions('Permissions'),
  data('Mobile data'),
  battery('Run in the background'),
  channel('Pick a channel'),
  radio('Long-range radio (optional)');

  const SetupStep(this.title);
  final String title;

  bool get last => index == SetupStep.values.length - 1;
}

/// A permission the app asks for, with why (plain words).
enum AppPermission {
  microphone('Microphone', 'To talk. Without it you can only listen.'),
  nearby(
    'Nearby devices (Bluetooth, Wi-Fi Direct)',
    'To find phones nearby with no Wi-Fi or internet.',
  ),
  location(
    'Location',
    'Older Android needs it for Bluetooth scans; also for sharing your '
        'location and the Trip map. Never sent anywhere unless you share it.',
  ),
  notifications(
    'Notifications',
    'Rings, voice messages and the "listening" notification that keeps '
        'you reachable.',
  );

  const AppPermission(this.label, this.why);
  final String label;
  final String why;
}

enum PermState {
  granted,
  denied,

  /// "Don't ask again": only App info can turn it on.
  permanentlyDenied,

  /// Not used on this phone / Android version.
  notNeeded,
}

/// Button text for a permission row.
String permissionAction(PermState s) => switch (s) {
  PermState.granted || PermState.notNeeded => '',
  PermState.denied => 'Allow',
  PermState.permanentlyDenied => 'Open App info',
};
