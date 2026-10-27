/// Background reliability guidance per phone maker (v1.8.7).
library;

enum PhoneBrand { samsung, xiaomi, oneplus, oppo, huawei, pixel, other }

PhoneBrand brandOf(String manufacturer) {
  final m = manufacturer.toLowerCase().trim();
  if (m.contains('samsung')) return PhoneBrand.samsung;
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
    return PhoneBrand.xiaomi;
  }
  if (m.contains('oneplus')) return PhoneBrand.oneplus;
  if (m.contains('oppo') || m.contains('realme')) return PhoneBrand.oppo;
  if (m.contains('huawei') || m.contains('honor')) return PhoneBrand.huawei;
  if (m.contains('google')) return PhoneBrand.pixel;
  return PhoneBrand.other;
}

class BatteryGuide {
  const BatteryGuide(this.brand, this.name, this.steps);
  final PhoneBrand brand;

  /// "Samsung", "Xiaomi / Redmi / POCO", ...
  final String name;

  /// Steps on top of the standard "ignore battery optimization" request.
  final List<String> steps;
}

/// Extra steps for [manufacturer]'s own battery killer. The standard
/// Android exemption (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) comes first on
/// every phone.
BatteryGuide batteryGuideFor(String manufacturer) {
  final b = brandOf(manufacturer);
  return switch (b) {
    PhoneBrand.samsung => const BatteryGuide(PhoneBrand.samsung, 'Samsung', [
      'Settings > Apps > Walkie Talkie > Battery: choose "Unrestricted".',
      'Settings > Battery > Background usage limits > Never sleeping apps: '
          'add Walkie Talkie.',
      'Make sure Walkie Talkie is not in "Sleeping apps" or "Deep sleeping '
          'apps" on the same screen.',
    ]),
    PhoneBrand.xiaomi => const BatteryGuide(
      PhoneBrand.xiaomi,
      'Xiaomi / Redmi / POCO',
      [
        'Settings > Apps > Manage apps > Walkie Talkie > Autostart: on.',
        'Same screen > Battery saver: choose "No restrictions".',
        'Open recent apps, long-press Walkie Talkie and tap the lock so it is '
            'not cleared.',
      ],
    ),
    PhoneBrand.oneplus => const BatteryGuide(PhoneBrand.oneplus, 'OnePlus', [
      'Settings > Apps > Walkie Talkie > Battery usage: allow background '
          'activity (or "Don\'t optimize").',
      'Settings > Battery > Battery optimization > Walkie Talkie: '
          '"Don\'t optimize".',
      'Open recent apps and lock Walkie Talkie so it is not cleared.',
    ]),
    PhoneBrand.oppo => const BatteryGuide(PhoneBrand.oppo, 'Oppo / Realme', [
      'Settings > Apps > App management > Walkie Talkie > Battery usage: '
          'allow background activity and auto launch.',
      'Settings > Battery > More settings: turn off "Optimize battery use" '
          'for Walkie Talkie.',
      'Open recent apps and lock Walkie Talkie.',
    ]),
    PhoneBrand.huawei => const BatteryGuide(
      PhoneBrand.huawei,
      'Huawei / Honor',
      [
        'Settings > Battery > App launch > Walkie Talkie: turn off "Manage '
            'automatically", then turn on Auto-launch, Secondary launch and '
            'Run in background.',
        'Open recent apps and lock Walkie Talkie.',
      ],
    ),
    PhoneBrand.pixel => const BatteryGuide(PhoneBrand.pixel, 'Pixel', [
      'Settings > Apps > Walkie Talkie > App battery usage: choose '
          '"Unrestricted".',
    ]),
    PhoneBrand.other => const BatteryGuide(PhoneBrand.other, 'this phone', [
      'Settings > Apps > Walkie Talkie > Battery: choose "Unrestricted" (or '
          'turn off battery optimization).',
      'If the phone has its own "auto-launch" or "sleeping apps" list, allow '
          'Walkie Talkie there.',
    ]),
  };
}
