import '../core/transport.dart';

/// Phone settings screens the connection icons can open (v1.8.5).
enum PhoneSetting {
  /// This app's App info page (Mobile data, Background data, Unrestricted
  /// data, Battery, Permissions).
  appInfo('app'),
  wifi('wifi'),
  bluetooth('bluetooth'),
  location('location'),

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
  });
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
      final cell = netKind == 'cell';
      return LinkInfo(
        title: 'Internet (relay)',
        state: state,
        help: up
            ? 'Talking through the internet relay. Works on Wi-Fi or '
                  'mobile data.'
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
