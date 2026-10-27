import '../core/transport.dart';

/// Phone settings screens the connection icons can open (v1.8.5).
enum PhoneSetting {
  /// This app's App info page (Mobile data, Background data, Unrestricted
  /// data, Battery, Permissions).
  appInfo('app'),
  wifi('wifi'),
  bluetooth('bluetooth'),
  location('location'),

  /// The phone's mobile network settings (Android
  /// ACTION_DATA_ROAMING_SETTINGS, else ACTION_WIRELESS_SETTINGS; v1.8.6).
  mobileNetwork('mobile'),

  /// Not a phone screen: the in-app radio pairing (Meshtastic).
  radioPairing('radio');

  const PhoneSetting(this.wire);

  /// Name sent to the Android bridge.
  final String wire;
}

/// Which settings a tap on [k]'s status icon leads to.
PhoneSetting settingFor(TransportKind k) => switch (k) {
  TransportKind.lan || TransportKind.wifiDirect => PhoneSetting.wifi,
  TransportKind.ble => PhoneSetting.bluetooth,
  TransportKind.internet => PhoneSetting.appInfo,
  TransportKind.lora => PhoneSetting.radioPairing,
};

/// What the connection sheet says for one link.
class LinkInfo {
  const LinkInfo({
    required this.title,
    required this.state,
    required this.help,
    required this.button,
    required this.setting,
    this.connected = false,
    this.permissionMissing = false,
    this.secondButton,
    this.secondSetting,
  });

  /// Optional second button (Cell: mobile network settings).
  final String? secondButton;
  final PhoneSetting? secondSetting;
  final String title;

  /// "Connected", "Off", "Bluetooth permission missing", ...
  final String state;
  final String help;

  /// Label of the action button.
  final String button;
  final PhoneSetting setting;
  final bool connected;
  final bool permissionMissing;
}

String _stateText(TransportStatus s) => switch (s) {
  TransportStatus.running => 'Connected',
  TransportStatus.starting => 'Connecting...',
  TransportStatus.stopped => 'Off',
  TransportStatus.unavailable => 'Not available',
  TransportStatus.error => 'Not working',
};

/// The sheet for a tap on [k]'s icon. [netKind]: the phone's network
/// ("wifi", "cell", "none", "other", null = unknown). [permissionMissing]:
/// Bluetooth permission not granted (Bluetooth only).
LinkInfo describeLink(
  TransportKind k,
  TransportStatus s, {
  String? detail,
  String? netKind,
  bool permissionMissing = false,
  bool offlineSaver = false,
  bool ios = false,
  String? relayInUse,
}) {
  final up = s == TransportStatus.running;
  var state = _stateText(s);
  if (detail != null && detail.trim().isNotEmpty && !up) {
    state = '$state: ${detail.trim()}';
  }
  final setting = settingFor(k);
  switch (k) {
    case TransportKind.internet:
      if (offlineSaver) state = 'Off (Offline power save)';
      // v1.8.8: which relay (home / backup).
      if (up && !offlineSaver && relayInUse != null) {
        state = '$state · $relayInUse';
      }
      final cell = netKind == 'cell';
      return LinkInfo(
        title: 'Internet (relay)',
        state: state,
        help: up
            ? switch (relayInUse) {
                'Home relay' =>
                  'Talking through your Home relay (the Synology). The '
                      'Backup relay stays connected too, so phones that '
                      'cannot reach home still hear you. Works on Wi-Fi or '
                      'mobile data.',
                'Backup relay' =>
                  'Talking through the Backup relay: the Home relay (the '
                      'Synology) cannot be reached right now. The app keeps '
                      'trying it (every few minutes and when the network '
                      'changes). Everyone still meets on the backup.',
                _ =>
                  'Talking through the internet relay. Works on Wi-Fi or '
                      'mobile data.',
              }
            : cell
            ? 'You are on mobile data but the relay is not reachable. '
                  'In App info, open Mobile data (or Data usage) and turn on '
                  'Mobile data and Background data (and Unrestricted data '
                  'if Data saver is on).'
            : 'Needs Wi-Fi or mobile data. If mobile data is on but this '
                  'stays off, allow Mobile data and Background data for '
                  'this app in App info.',
        button: ios ? 'Open app settings' : 'Open phone settings',
        setting: setting,
        connected: up,
      );
    case TransportKind.lan:
    case TransportKind.wifiDirect:
      return LinkInfo(
        title: k == TransportKind.lan ? 'Wi-Fi' : 'Wi-Fi Direct',
        state: state,
        help: k == TransportKind.lan
            ? 'Phones on the same Wi-Fi (or hotspot) find each other here.'
            : 'Phones nearby connect over Wi-Fi Direct when there is no '
                  'shared network. Wi-Fi must be on.',
        button: ios ? 'Open app settings' : 'Open Wi-Fi settings',
        setting: setting,
        connected: up,
      );
    case TransportKind.ble:
      return LinkInfo(
        title: 'Bluetooth',
        state: permissionMissing ? 'Bluetooth permission missing' : state,
        help: permissionMissing
            ? 'Allow "Nearby devices" so the app can find phones and your '
                  'radio over Bluetooth.'
            : 'Phones within about 100 m, and your LoRa radio, use '
                  'Bluetooth. Keep it on.',
        button: permissionMissing
            ? 'Allow Bluetooth'
            : ios
            ? 'Open app settings'
            : 'Open Bluetooth settings',
        setting: setting,
        connected: up,
        permissionMissing: permissionMissing,
      );
    case TransportKind.lora:
      return LinkInfo(
        title: 'LoRa radio',
        state: up ? 'Connected' : state,
        help: 'The paired Meshtastic radio reaches phones miles away.',
        button: 'Radio pairing',
        setting: setting,
        connected: up,
      );
  }
}

/// Show "Allow mobile data" next to the internet status: relays are set,
/// the relay is not connected, the phone is on mobile data and Offline
/// power save is off.
bool showMobileDataHint({
  required TransportStatus internet,
  required String? netKind,
  required bool hasRelay,
  required bool offlineSaver,
}) =>
    hasRelay &&
    !offlineSaver &&
    netKind == 'cell' &&
    internet != TransportStatus.running &&
    internet != TransportStatus.starting;

// ------------------------------------------------------- Cell icon (v1.8.6)

/// The phone's cellular side, as Android reports it without any extra
/// permission (see BgBridge.cellInfo). Null fields = not known.
class CellInfo {
  const CellInfo({
    this.dataUp = false,
    this.validated = false,
    this.defaultCell = false,
    this.sim = false,
    this.service = false,
    this.level,
    this.type,
    this.airplane = false,
    this.dataSaver = false,
  });

  /// A cellular data network exists (mobile data is on and connected).
  final bool dataUp;

  /// ... and it really reaches the internet.
  final bool validated;

  /// Mobile data is the phone's default network (no Wi-Fi).
  final bool defaultCell;
  final bool sim;

  /// The phone has cell service (or a data network).
  final bool service;

  /// Signal bars 0..4.
  final int? level;

  /// "5G", "LTE", "3G", "2G".
  final String? type;
  final bool airplane;

  /// Data Saver is on and restricts this app in the background.
  final bool dataSaver;

  bool get cellUp => dataUp || (service && !airplane);

  static CellInfo? fromMap(Map<Object?, Object?>? m) {
    if (m == null) return null;
    bool b(String k) => m[k] == true;
    final level = m['level'];
    final type = m['type'];
    return CellInfo(
      dataUp: b('dataUp'),
      validated: b('validated'),
      defaultCell: b('defaultCell'),
      sim: b('sim'),
      service: b('service'),
      level: level is int && level >= 0 && level <= 4 ? level : null,
      type: type is String && type.isNotEmpty ? type : null,
      airplane: b('airplane'),
      dataSaver: b('dataSaver'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CellInfo &&
      other.dataUp == dataUp &&
      other.validated == validated &&
      other.defaultCell == defaultCell &&
      other.sim == sim &&
      other.service == service &&
      other.level == level &&
      other.type == type &&
      other.airplane == airplane &&
      other.dataSaver == dataSaver;

  @override
  int get hashCode => Object.hash(
    dataUp,
    validated,
    defaultCell,
    sim,
    service,
    level,
    type,
    airplane,
    dataSaver,
  );
}

enum CellState {
  /// The relay runs over mobile data right now.
  active,

  /// Cell is up, the app uses Wi-Fi (or needs no relay).
  available,

  /// No service, no SIM or airplane mode.
  off,

  /// Cell is up but the relay cannot be reached over it: mobile data is
  /// off or restricted for this app.
  blocked,

  /// Offline power save: the app does not use the internet.
  saver,

  /// Not known on this phone (iOS: no cellular details).
  unknown,
}

/// The Cell icon's state.
///
/// * [relayUp] / [relayNet]: a relay is connected and over which network
///   ("mobile data", "Wi-Fi", ...).
/// * [phoneNet]: the phone's default network ("wifi", "cell", "none",
///   "other"). While the phone is on Wi-Fi the app does not use mobile
///   data, so a relay problem there is not the Cell icon's business.
CellState cellState({
  required CellInfo? info,
  required bool relayUp,
  String? relayNet,
  String? phoneNet,
  required bool hasRelay,
  required bool offlineSaver,
}) {
  if (offlineSaver) return CellState.saver;
  if (relayUp && relayNet == 'mobile data') return CellState.active;
  final i = info;
  if (i == null) return CellState.unknown;
  if (!i.cellUp) return CellState.off;
  if (relayUp || !hasRelay) return CellState.available;
  if (phoneNet == 'wifi' && !i.defaultCell) return CellState.available;
  // No Wi-Fi to use, cell service is there, but no relay: mobile data is
  // off or restricted for this app (or the relay itself is down; the
  // sheet mentions it).
  return CellState.blocked;
}

String cellLabel(CellInfo? i) {
  if (i == null) return '';
  final parts = [?i.type, if (i.level != null) '${i.level}/4 bars'];
  return parts.join(', ');
}

/// The sheet for a tap on the Cell icon.
LinkInfo describeCell(CellState s, CellInfo? i, {bool ios = false}) {
  final details = cellLabel(i);
  final suffix = details.isEmpty ? '' : ' ($details)';
  final (state, help) = switch (s) {
    CellState.active => (
      'Using mobile data$suffix',
      'The internet relay is connected over mobile data.',
    ),
    CellState.available => (
      'Available$suffix',
      'Mobile data is there; the app is on Wi-Fi (or has no relay set). '
          'It switches to mobile data by itself when Wi-Fi goes away.',
    ),
    CellState.off => (
      i?.airplane == true
          ? 'Off (airplane mode)'
          : i?.sim == false
          ? 'No SIM / no service'
          : 'No service',
      'No cell signal here. Wi-Fi, Bluetooth, the phone mesh and the LoRa '
          'radio still work.',
    ),
    CellState.blocked => (
      'Not reaching the relay$suffix',
      'There is cell service, but the app cannot reach the internet relay '
          'over it. Mobile data may be off, or limited for this app: in App '
          'info > Mobile data, turn on Mobile data and Background data '
          '(and Unrestricted data${i?.dataSaver == true ? ', Data saver is on' : ' if Data saver is on'}). '
          'Check that mobile data is on in the phone\'s network settings. '
          '(If it still fails, the relay itself may be down.)',
    ),
    CellState.saver => (
      'Off (Offline power save)',
      'Offline power save does not use the internet. Turn it off to talk '
          'over mobile data.',
    ),
    CellState.unknown => (
      'Not available on this phone',
      'Cellular details are not shown here. Mobile data for this app can '
          'be allowed in its settings.',
    ),
  };
  return LinkInfo(
    title: 'Mobile data',
    state: state,
    help: help,
    button: ios ? 'Open app settings' : 'Open phone settings',
    setting: PhoneSetting.appInfo,
    connected: s == CellState.active,
    secondButton: ios ? null : 'Mobile network settings',
    secondSetting: ios ? null : PhoneSetting.mobileNetwork,
  );
}

// ------------------------------------------- "why can't I see anyone?"

/// Why the internet path cannot find anyone, shown under an empty people
/// list (v1.8.7). Null = the relay is fine (then the other phone is not on
/// it, or is on another channel / passcode).
class AloneReason {
  const AloneReason(this.text, {this.fix});
  final String text;

  /// What a "Fix" button opens, if anything.
  final PhoneSetting? fix;
}

AloneReason aloneReason({
  required bool offlineSaver,
  required bool hasRelay,
  required TransportStatus internet,
  String? internetDetail,
  required CellState cell,
  required String channelLabel,
  bool isPrivate = false,
}) {
  if (offlineSaver) {
    return const AloneReason(
      'Offline power save is on, so the internet relay is off. Only phones '
      'nearby (Wi-Fi, Bluetooth, radio) can be found. Turn it off to reach '
      'people far away.',
    );
  }
  if (!hasRelay) {
    return const AloneReason(
      'The internet relay is turned off in Settings, so only phones nearby '
      'can be found.',
    );
  }
  if (internet == TransportStatus.starting) {
    return const AloneReason(
      'Connecting to the internet relay. If it was asleep this can take up '
      'to a minute.',
    );
  }
  if (internet != TransportStatus.running) {
    final why = (internetDetail ?? '').trim();
    return AloneReason(
      switch (cell) {
        CellState.off =>
          'Not connected to the internet relay: no Wi-Fi and no mobile '
              'service${why.isEmpty ? '' : ' ($why)'}.',
        CellState.blocked =>
          'Not connected to the internet relay over mobile data'
              '${why.isEmpty ? '' : ' ($why)'}. Mobile data may be off or '
              'restricted for this app: allow Mobile data and Background '
              'data in App info.',
        _ =>
          'Not connected to the internet relay'
              '${why.isEmpty ? '' : ' ($why)'}.',
      },
      fix: cell == CellState.off
          ? PhoneSetting.mobileNetwork
          : PhoneSetting.appInfo,
    );
  }
  return AloneReason(
    'Connected to the internet relay on $channelLabel. The other phone must '
    'be online with the app open, on the same channel'
    '${isPrivate ? ' and the same passcode' : ''}, and not in Offline power '
    'save. Pull down to ask again.',
  );
}
