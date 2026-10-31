// v2.6.2: the Settings search index. One entry per setting people can look
// for. To add a setting: wrap its widget in a `SettingAnchor` with an id
// (settings_search.dart) and add an entry here with the same id. The test
// `v262_settings_search_test.dart` fails when an anchor has no entry, an
// entry has no anchor, a section title has no entry, or an entry's label is
// not text that really exists in the app.

/// Where a setting lives.
enum SettingsHome {
  /// The Settings sheet itself: the search scrolls to it.
  settings,

  /// The Radio settings page: the search opens it, then scrolls to it.
  radio,

  /// The Trip map's Range test page: the search opens it.
  trip,
}

/// When a setting is on screen at all (a phone-only switch is not shown on
/// the PC, and so on). Entries that are not shown are not offered.
enum SettingNeeds {
  phone,
  wifiDirect,
  weatherOn,
  blocked,
  trip,
  radioBackup,
  savedRadios,
  radioPaired,
}

/// What the app can do right now; decides which entries are offered.
class SettingsEnv {
  const SettingsEnv({
    this.phone = true,
    this.wifiDirect = true,
    this.weatherOn = true,
    this.hasBlocked = true,
    this.hasTrip = true,
    this.radioBackup = true,
    this.savedRadios = true,
    this.radioPaired = true,
    this.radioReady = true,
  });

  /// Android / iOS features (background listening, volume-key talk).
  final bool phone;
  final bool wifiDirect;
  final bool weatherOn;
  final bool hasBlocked;
  final bool hasTrip;
  final bool radioBackup;
  final bool savedRadios;
  final bool radioPaired;

  /// The radio is connected, so its settings can be changed.
  final bool radioReady;

  bool allows(SettingNeeds? n) => switch (n) {
    null => true,
    SettingNeeds.phone => phone,
    SettingNeeds.wifiDirect => wifiDirect,
    SettingNeeds.weatherOn => weatherOn,
    SettingNeeds.blocked => hasBlocked,
    SettingNeeds.trip => hasTrip,
    SettingNeeds.radioBackup => radioBackup,
    SettingNeeds.savedRadios => savedRadios,
    SettingNeeds.radioPaired => radioPaired,
  };
}

class SettingEntry {
  const SettingEntry({
    required this.id,
    required this.title,
    required this.section,
    required this.about,
    this.words = const [],
    this.home = SettingsHome.settings,
    this.needs,
    String? label,
  }) : label = label ?? title;

  /// Same as the `SettingAnchor` id on the widget.
  final String id;

  /// What the result says.
  final String title;

  /// The words really on screen for this setting (a title, a heading). The
  /// test checks it exists in the app, so renaming a setting without
  /// updating the index fails.
  final String label;

  /// The heading it sits under (a section title on the Settings sheet).
  final String section;

  /// One short line on what it does.
  final String about;

  /// Other words people would type for it.
  final List<String> words;
  final SettingsHome home;
  final SettingNeeds? needs;

  /// "Settings > Off-grid (no internet)".
  String get path => switch (home) {
    SettingsHome.settings => 'Settings › $section',
    SettingsHome.radio => 'Settings › Long-range radio › Radio settings',
    SettingsHome.trip => 'Trip map › $section',
  };
}

const _ps = 'Long-range radio (Meshtastic)';

/// Every searchable setting, in the order they appear.
const settingsIndex = <SettingEntry>[
  // --- Settings sheet -----------------------------------------------------
  SettingEntry(
    id: 'name',
    title: 'Your call sign',
    section: 'Your name',
    about: 'Pick another call sign, or set a custom name.',
    words: [
      'name',
      'custom name',
      'nickname',
      'identity',
      'rename',
      'callsign',
      'dice',
      'who am i',
    ],
  ),
  SettingEntry(
    id: 'relay-url',
    title: 'Internet relays',
    section: 'Your name',
    about: 'Which internet relay server to use. Empty is the default.',
    words: ['relay', 'server', 'url', 'address', 'online', 'off', 'host'],
  ),
  SettingEntry(
    id: 'stay-reachable',
    title: 'Stay reachable when app is closed',
    section: 'Background',
    about: 'Keep listening for rings and talk with the app closed.',
    words: [
      'background',
      'listening',
      'notification',
      'closed',
      'battery',
      'power',
      'service',
    ],
    needs: SettingNeeds.phone,
  ),
  SettingEntry(
    id: 'start-boot',
    title: 'Start listening after phone restarts',
    section: 'Background',
    about: 'Start again by itself when the phone turns on.',
    words: ['boot', 'restart', 'startup', 'reboot', 'turn on', 'auto start'],
    needs: SettingNeeds.phone,
  ),
  SettingEntry(
    id: 'battery-help',
    title: 'Battery settings',
    section: 'Background',
    about: 'Let Android keep the app running (maker-specific steps).',
    words: [
      'battery',
      'power',
      'unrestricted',
      'optimization',
      'optimisation',
      'doze',
      'killed',
      'background',
      'samsung',
      'xiaomi',
      'oneplus',
      'huawei',
      'full screen',
    ],
    needs: SettingNeeds.phone,
  ),
  SettingEntry(
    id: 'whos-where',
    title: "Show me in Who's where",
    section: 'Visibility',
    about: 'Let phones on other channels see your name.',
    words: [
      'privacy',
      'visible',
      'hide',
      'invisible',
      'discoverable',
      'find me',
      'nearby',
      'online',
    ],
  ),
  SettingEntry(
    id: 'read-receipts',
    title: 'Send read receipts',
    section: 'Visibility',
    about: 'Tell people when you have seen their message.',
    words: ['seen', 'privacy', 'receipts', 'read', 'double check'],
  ),
  SettingEntry(
    id: 'offline-saver',
    title: 'Offline power save',
    section: 'Off-grid (no internet)',
    about: 'Longest battery life when you know there is no internet.',
    words: [
      'battery',
      'power',
      'hike',
      'off grid',
      'offgrid',
      'dark',
      'dim',
      'saver',
      'no internet',
    ],
  ),
  SettingEntry(
    id: 'relay-others',
    title: 'Relay for others',
    section: 'Off-grid (no internet)',
    about: 'Pass talk on to phones that are out of range of each other.',
    words: ['relay', 'hops', 'repeat', 'forward', 'mesh', 'rebroadcast'],
  ),
  SettingEntry(
    id: 'wifi-direct',
    title: 'Wi-Fi Direct',
    section: 'Off-grid (no internet)',
    about:
        'Link straight to nearby Android phones, about 2-3x Bluetooth range.',
    words: ['wifi', 'wi fi', 'range', 'nearby', 'direct', 'android'],
    needs: SettingNeeds.wifiDirect,
  ),
  SettingEntry(
    id: 'base-camp',
    title: 'Base camp mode',
    section: 'Off-grid (no internet)',
    about: 'Leave a plugged-in phone at camp as a fixed relay.',
    words: ['camp', 'fixed relay', 'plugged', 'trip messages', 'hold', 'sos'],
  ),
  SettingEntry(
    id: 'radio-section',
    title: _ps,
    section: _ps,
    about: 'Pair a LoRa radio to reach phones miles away with no signal.',
    words: ['radio', 'lora', 'meshtastic', 'long range', 'miles', 'pair'],
  ),
  SettingEntry(
    id: 'radio-saved',
    title: 'Saved radios',
    section: _ps,
    about: 'Every radio you connected: switch, rename or remove one.',
    words: ['radio', 'my radios', 'switch', 'rename', 'remove', 'forget'],
    needs: SettingNeeds.savedRadios,
  ),
  SettingEntry(
    id: 'radio-add',
    title: 'Find my radio',
    section: _ps,
    about: 'Pair a Meshtastic radio over Bluetooth, or plug in USB.',
    words: [
      'pair',
      'add radio',
      'scan',
      'bluetooth',
      'usb',
      'connect',
      'wifi radio',
      'find usb radio',
      'meshtastic',
    ],
  ),
  SettingEntry(
    id: 'radio-share',
    title: 'Share my radio with phones on the internet',
    section: _ps,
    about: 'Let online phones reach radio-only people through your radio.',
    words: ['radio', 'gateway', 'share', 'bridge', 'internet'],
    needs: SettingNeeds.radioPaired,
  ),
  SettingEntry(
    id: 'radio-gateways',
    title: 'LoRa gateways',
    section: _ps,
    about: 'Home gateways and phones sharing a radio on this channel.',
    words: ['radio', 'gateway', 'home gateway', 'synology', 'bridge'],
  ),
  SettingEntry(
    id: 'radio-settings-row',
    title: 'Radio settings',
    section: _ps,
    about: 'Name, hop limit, location sharing, region and speed.',
    words: ['radio', 'tune', 'hop', 'region', 'speed', 'name', 'open'],
  ),
  SettingEntry(
    id: 'radio-channels',
    title: 'Meshtastic channels',
    section: _ps,
    about: 'Link your Walkie channels to channels on the radio.',
    words: ['radio', 'channel', 'link', 'qr', 'import', 'unlink', 'key'],
  ),
  SettingEntry(
    id: 'quiet',
    title: 'Mute & quiet hours',
    section: 'Mute & quiet hours',
    about: 'Silence rings and talk, now or on a schedule.',
    words: ['mute', 'quiet', 'silence', 'sleep', 'night', 'dnd', 'hours'],
  ),
  SettingEntry(
    id: 'quiet-add',
    title: 'Add quiet hours',
    section: 'Mute & quiet hours',
    about: 'Mute automatically at night or at work.',
    words: ['schedule', 'sleep', 'night', 'mute', 'quiet', 'time'],
  ),
  SettingEntry(
    id: 'quiet-urgent',
    title: 'Let urgent rings through',
    section: 'Mute & quiet hours',
    about: 'Urgent rings and SOS still ring while muted.',
    words: ['urgent', 'sos', 'mute', 'quiet', 'always allow', 'emergency'],
  ),
  SettingEntry(
    id: 'weather',
    title: 'Weather alerts',
    section: 'Weather alerts',
    about: 'National Weather Service warnings for where you are (US only).',
    words: [
      'weather',
      'storm',
      'nws',
      'warning',
      'tornado',
      'flood',
      'fire',
      'alert',
      'alerts',
    ],
  ),
  SettingEntry(
    id: 'wx-wifi',
    title: 'Wi-Fi only',
    section: 'Weather alerts',
    about: 'Do not check the weather on mobile data.',
    words: ['weather', 'wifi', 'wi fi', 'mobile data', 'cellular', 'data'],
    needs: SettingNeeds.weatherOn,
  ),
  SettingEntry(
    id: 'wx-extreme',
    title: 'Extreme alerts can sound anytime',
    section: 'Weather alerts',
    about: 'Tornado warnings sound even in quiet hours.',
    words: ['weather', 'tornado', 'alarm', 'quiet hours', 'do not disturb'],
    needs: SettingNeeds.weatherOn,
  ),
  SettingEntry(
    id: 'wx-share',
    title: 'Share alerts with other phones',
    section: 'Weather alerts',
    about: 'Pass a warning on to phones in radio range.',
    words: ['weather', 'share', 'signed', 'key', 'trust', 'radio'],
    needs: SettingNeeds.weatherOn,
  ),
  SettingEntry(
    id: 'toggle-talk',
    title: 'Tap to talk (toggle)',
    section: 'Talk button',
    about: 'Tap once to start talking, again to stop. Off = hold to talk.',
    words: ['ptt', 'push to talk', 'hold', 'tap', 'button', 'toggle'],
  ),
  SettingEntry(
    id: 'volume-ptt',
    title: 'Use volume-down as talk button',
    section: 'Talk button',
    about: 'Hold volume-down to talk while the app is open.',
    words: ['ptt', 'volume', 'key', 'accessibility', 'button', 'hardware'],
    needs: SettingNeeds.phone,
  ),
  SettingEntry(
    id: 'headset-ptt',
    title: 'Headset button talks',
    section: 'Talk button',
    about: 'Use a Bluetooth or wired headset button to talk.',
    words: ['ptt', 'headset', 'earbuds', 'bluetooth', 'play pause', 'button'],
    needs: SettingNeeds.phone,
  ),
  SettingEntry(
    id: 'notif-talk',
    title: 'Talk button on the notification',
    section: 'Talk button',
    about: 'A Talk button on the listening notification and lock screen.',
    words: ['ptt', 'notification', 'lock screen', 'button'],
    needs: SettingNeeds.phone,
  ),
  SettingEntry(
    id: 'urgent-loud',
    title: 'Urgent rings sound in silent mode',
    section: 'Urgent rings',
    about: 'Urgent rings at alarm volume, even on silent.',
    words: ['alarm', 'silent', 'do not disturb', 'dnd', 'loud', 'ring', 'sos'],
    needs: SettingNeeds.phone,
  ),
  SettingEntry(
    id: 'blocked',
    title: 'Blocked',
    section: 'Blocked',
    about: 'People you blocked, with an Unblock button.',
    words: ['block', 'unblock', 'ban', 'mute person'],
    needs: SettingNeeds.blocked,
  ),
  SettingEntry(
    id: 'join-private',
    title: 'Alert when someone joins a private group',
    section: 'Privacy',
    about: 'A short tone and their name.',
    words: ['join', 'alert', 'tone', 'notify', 'private', 'group'],
  ),
  SettingEntry(
    id: 'join-open',
    title: 'Alert when someone joins an open channel',
    section: 'Privacy',
    about: 'A short tone when someone joins your open channel.',
    words: ['join', 'alert', 'tone', 'notify', 'public', 'channel'],
  ),
  SettingEntry(
    id: 'auto-play',
    title: 'Auto-play incoming talk',
    section: 'Messages',
    about: 'Off: talk waits in Messages until you tap Play.',
    words: ['autoplay', 'play', 'voice', 'messages', 'audio', 'speak'],
  ),
  SettingEntry(
    id: 'playback-log',
    title: 'Playback log',
    section: 'Messages',
    about: 'What played, from whom, and why.',
    words: ['history', 'log', 'repeat', 'repeating', 'debug', 'played'],
  ),
  SettingEntry(
    id: 'clear-all',
    title: 'Clear all messages and queues',
    section: 'Messages',
    about: 'Delete voice messages and cancel everything waiting to send.',
    words: ['delete', 'wipe', 'erase', 'reset', 'clean', 'queue', 'stuck'],
  ),
  SettingEntry(
    id: 'power-saver',
    title: 'Battery saver',
    label: 'Saver',
    section: 'Battery',
    about: 'Normal or Saver: roughly 20-35% less battery while waiting.',
    words: ['battery', 'power', 'normal', 'save', 'saving', 'life'],
  ),
  SettingEntry(
    id: 'connection-speed',
    title: 'Connection speed',
    section: 'Battery',
    about: 'Max speed (more battery) or Balanced.',
    words: ['battery', 'power', 'fast', 'balanced', 'bluetooth', 'link'],
  ),
  SettingEntry(
    id: 'phone-settings',
    title: 'Phone settings for this app (mobile data, battery)',
    section: 'Battery',
    about: 'Open App info: mobile data, background data, battery.',
    words: [
      'battery',
      'power',
      'mobile data',
      'background data',
      'data saver',
      'unrestricted',
      'app info',
      'permissions',
    ],
  ),
  SettingEntry(
    id: 'setup-wizard',
    title: 'Setup wizard',
    section: 'Help & setup',
    about: 'Call sign, permissions, mobile data, battery, channel, radio.',
    words: ['setup', 'help', 'first run', 'permissions', 'guide', 'start'],
  ),
  SettingEntry(
    id: 'conn-test',
    title: 'Connection test',
    section: 'Help & setup',
    about: 'Checks Wi-Fi, Bluetooth, internet, the relay, the radio, battery.',
    words: ['test', 'diagnose', 'problem', 'not working', 'fix', 'check'],
  ),
  SettingEntry(
    id: 'invite',
    title: 'Invite (QR code / link)',
    section: 'Help & setup',
    about: 'Share this channel or add a friend.',
    words: ['qr', 'share', 'friend', 'link', 'add', 'code'],
  ),
  SettingEntry(
    id: 'join-code',
    title: 'Join with a code',
    section: 'Help & setup',
    about: 'Scan or paste an invite.',
    words: ['qr', 'scan', 'paste', 'invite', 'link', 'friend', 'group'],
  ),
  SettingEntry(
    id: 'debug-log',
    title: 'Send debug log',
    section: 'Help & setup',
    about: 'Connection log for troubleshooting (keys removed).',
    words: ['support', 'bug', 'report', 'troubleshoot', 'logs', 'problem'],
  ),
  SettingEntry(
    id: 'updates',
    title: 'Check for updates',
    section: 'Help & setup',
    about: 'See the version and look for a newer one.',
    words: ['update', 'upgrade', 'version', 'new version', 'download'],
  ),
  // --- Radio settings page ------------------------------------------------
  SettingEntry(
    id: 'radio-match',
    title: 'Radio match check',
    section: 'Radio settings',
    about: 'Compare your radios on frequency slot, location precision, hops.',
    words: [
      'match',
      'compare',
      'mismatch',
      'frequency',
      'slot',
      'channel number',
      'hop',
      'precision',
      'same',
      'different',
      'fix',
      'majority',
      'home base',
    ],
    home: SettingsHome.radio,
  ),
  SettingEntry(
    id: 'radio-name',
    title: 'Radio name',
    label: 'Name',
    section: 'Radio settings',
    about: 'The long and short name other radios see.',
    words: ['long name', 'short name', 'rename', 'call sign', 'label'],
    home: SettingsHome.radio,
  ),
  SettingEntry(
    id: 'radio-hop',
    title: 'Hop limit',
    section: 'Radio settings',
    about: 'How many radios may pass your messages on.',
    words: ['hops', 'repeat', 'relay', 'range', 'far', 'rebroadcast', 'ttl'],
    home: SettingsHome.radio,
  ),
  SettingEntry(
    id: 'radio-location',
    title: 'Location sharing',
    section: 'Radio settings',
    about: 'Whether your radio sends your position.',
    words: ['gps', 'position', 'share location', 'where', 'send position'],
    home: SettingsHome.radio,
  ),
  SettingEntry(
    id: 'radio-precision',
    title: 'Location precision',
    section: 'Radio settings',
    about: 'How exactly your radio says where you are, per channel.',
    words: [
      'precision',
      'blur',
      'blurry',
      'fuzzy',
      'privacy',
      'exact',
      'accuracy',
      'location',
      'approximate',
      'coarse',
      'position',
      'hide location',
    ],
    home: SettingsHome.radio,
  ),
  SettingEntry(
    id: 'radio-region',
    title: 'Region and speed',
    section: 'Radio settings',
    about: 'The radio region (country) and the speed preset.',
    words: [
      'region',
      'country',
      'preset',
      'speed',
      'longfast',
      'modem',
      'band',
      'us',
      'eu',
      '915',
      '868',
    ],
    home: SettingsHome.radio,
  ),
  SettingEntry(
    id: 'radio-relay',
    title: 'Relay through public radios',
    section: 'Radio settings',
    about: 'Use the public frequency so other radios pass your messages.',
    words: [
      'relay',
      'public',
      'frequency',
      'slot',
      'channel number',
      'longfast',
      'hops',
      'mesh',
      'share',
    ],
    home: SettingsHome.radio,
  ),
  SettingEntry(
    id: 'radio-undo',
    title: 'Restore previous radio settings',
    label: 'Undo',
    section: 'Radio settings',
    about: 'Put back what your radio had before the last change.',
    words: ['undo', 'restore', 'backup', 'previous', 'revert', 'rollback'],
    home: SettingsHome.radio,
    needs: SettingNeeds.radioBackup,
  ),
  // --- Trip map -----------------------------------------------------------
  SettingEntry(
    id: 'range-logging',
    title: 'Range logging',
    section: 'Range test',
    about: 'Log where your radio hears the home radio while you drive.',
    words: [
      'range',
      'log',
      'drive',
      'ping',
      'home radio',
      'coverage',
      'test',
      'battery',
      'power',
      'gps',
    ],
    home: SettingsHome.trip,
    needs: SettingNeeds.trip,
  ),
  SettingEntry(
    id: 'range-markers',
    title: 'Range test markers',
    section: 'Range test',
    about: 'Green and red markers on the Trip map from range tests.',
    words: ['range', 'markers', 'green', 'red', 'coverage', 'map', 'export'],
    home: SettingsHome.trip,
    needs: SettingNeeds.trip,
  ),
];
