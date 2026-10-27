/// Connection test (v1.8.7): one row per link / setting with a traffic
/// light and a fix button. Pure: [evaluateConnection] turns a
/// [ConnSnapshot] (gathered by the controller) into rows, for tests.
library;

import '../core/transport.dart';
import 'battery_guide.dart';
import 'link_settings.dart';
import 'setup.dart';

enum CheckLevel {
  /// Green: works.
  ok,

  /// Yellow: works partly, or not needed right now.
  warn,

  /// Red: broken and it matters.
  fail,

  /// Grey: intentionally off (Offline power save, off in Settings).
  off,
}

/// What a row's fix button does.
enum CheckFix {
  none,
  wifiSettings,
  bluetoothPermission,
  bluetoothSettings,
  appInfo,
  mobileNetwork,
  batteryExemption,
  batteryGuide,
  radioPairing,
  permissions,
  relaySettings,
}

String fixLabel(CheckFix f) => switch (f) {
  CheckFix.none => '',
  CheckFix.wifiSettings => 'Wi-Fi settings',
  CheckFix.bluetoothPermission => 'Allow Nearby devices',
  CheckFix.bluetoothSettings => 'Bluetooth settings',
  CheckFix.appInfo => 'Open App info',
  CheckFix.mobileNetwork => 'Mobile network settings',
  CheckFix.batteryExemption => 'Allow in background',
  CheckFix.batteryGuide => 'Show steps',
  CheckFix.radioPairing => 'Pair radio',
  CheckFix.permissions => 'Allow',
  CheckFix.relaySettings => 'Relay settings',
};

class CheckRow {
  const CheckRow(
    this.id,
    this.title,
    this.level,
    this.detail, [
    this.fix = CheckFix.none,
  ]);

  /// Stable key: 'wifi', 'wifiDirect', 'bluetooth', 'cell', 'internet',
  /// 'relay', 'radio', 'permissions', 'battery'.
  final String id;
  final String title;
  final CheckLevel level;
  final String detail;
  final CheckFix fix;

  @override
  String toString() => '$id: ${level.name} - $detail';
}

/// Internet reachability probe (HTTPS to a 204 page).
class NetProbe {
  const NetProbe({required this.ok, this.ms, this.error});
  final bool ok;
  final int? ms;
  final String? error;
}

/// Relay probe: a separate WebSocket to the relay room, "ping" -> "pong".
class RelayProbe {
  const RelayProbe({
    required this.ok,
    this.connectMs,
    this.rttMs,
    this.room,
    this.host,
    this.error,
  });
  final bool ok;
  final int? connectMs;
  final int? rttMs;
  final String? room;
  final String? host;
  final String? error;
}

class ConnSnapshot {
  const ConnSnapshot({
    this.offlineSaver = false,
    this.ios = false,
    this.phoneNet,
    this.lan,
    this.lanDetail,
    this.wifiDirect,
    this.wifiDirectDetail,
    this.wifiDirectEnabled = true,
    this.ble,
    this.bleDetail,
    this.bluetoothOn,
    this.bluetoothPermissionMissing = false,
    this.cell = CellState.unknown,
    this.cellInfo,
    this.internet,
    this.relayConfigured = true,
    this.relayLink,
    this.relayLinkDetail,
    this.relay,
    this.radioPaired = false,
    this.radioReady = false,
    this.radioDetail,
    this.permissions = const {},
    this.batteryExempt,
    this.stayReachable = true,
    this.serviceRunning,
    this.manufacturer = '',
  });

  final bool offlineSaver;
  final bool ios;

  /// "wifi", "cell", "other", "none" or null.
  final String? phoneNet;
  final TransportStatus? lan;
  final String? lanDetail;
  final TransportStatus? wifiDirect;
  final String? wifiDirectDetail;
  final bool wifiDirectEnabled;
  final TransportStatus? ble;
  final String? bleDetail;

  /// Adapter on (null = unknown).
  final bool? bluetoothOn;
  final bool bluetoothPermissionMissing;
  final CellState cell;
  final CellInfo? cellInfo;

  /// null: not tested (Offline power save).
  final NetProbe? internet;
  final bool relayConfigured;

  /// The app's own relay link right now.
  final TransportStatus? relayLink;
  final String? relayLinkDetail;

  /// null: not tested.
  final RelayProbe? relay;
  final bool radioPaired;
  final bool radioReady;
  final String? radioDetail;
  final Map<AppPermission, PermState> permissions;

  /// Battery optimization off for the app (null = unknown / not Android).
  final bool? batteryExempt;
  final bool stayReachable;
  final bool? serviceRunning;
  final String manufacturer;
}

String _d(String? s, String fallback) =>
    (s == null || s.trim().isEmpty) ? fallback : s.trim();

/// The rows, in display order.
List<CheckRow> evaluateConnection(ConnSnapshot s) => [
  _wifi(s),
  _wifiDirect(s),
  _bluetooth(s),
  _cell(s),
  _internet(s),
  _relay(s),
  _radio(s),
  _permissions(s),
  _battery(s),
];

/// Overall: the worst level that matters (off rows are ignored).
CheckLevel overallLevel(List<CheckRow> rows) {
  var worst = CheckLevel.ok;
  for (final r in rows) {
    if (r.level == CheckLevel.fail) return CheckLevel.fail;
    if (r.level == CheckLevel.warn) worst = CheckLevel.warn;
  }
  return worst;
}

CheckRow _wifi(ConnSnapshot s) {
  const t = 'Wi-Fi / local network';
  final st = s.lan;
  if (st == TransportStatus.running) {
    return CheckRow(
      'wifi',
      t,
      s.phoneNet == 'wifi' ? CheckLevel.ok : CheckLevel.warn,
      s.phoneNet == 'wifi'
          ? 'On a Wi-Fi network. Phones on the same Wi-Fi or hotspot are found '
                'directly.'
          : 'Ready, but this phone is not on Wi-Fi. Phones on the same Wi-Fi '
                'or hotspot would be found directly.',
      s.phoneNet == 'wifi' ? CheckFix.none : CheckFix.wifiSettings,
    );
  }
  if (st == TransportStatus.starting) {
    return const CheckRow('wifi', t, CheckLevel.warn, 'Starting...');
  }
  return CheckRow(
    'wifi',
    t,
    CheckLevel.warn,
    'Not running (${_d(s.lanDetail, 'no Wi-Fi')}). Not needed when the '
        'internet relay or Bluetooth works.',
    CheckFix.wifiSettings,
  );
}

CheckRow _wifiDirect(ConnSnapshot s) {
  const t = 'Wi-Fi Direct';
  if (s.ios || s.wifiDirect == null) {
    return const CheckRow(
      'wifiDirect',
      t,
      CheckLevel.off,
      'Not available on this phone.',
    );
  }
  if (!s.wifiDirectEnabled) {
    return const CheckRow(
      'wifiDirect',
      t,
      CheckLevel.off,
      'Off in Settings (intentionally).',
    );
  }
  return switch (s.wifiDirect!) {
    TransportStatus.running => CheckRow(
      'wifiDirect',
      t,
      CheckLevel.ok,
      'Ready. ${_d(s.wifiDirectDetail, 'Links app phones with no shared network.')}',
    ),
    TransportStatus.starting => const CheckRow(
      'wifiDirect',
      t,
      CheckLevel.warn,
      'Starting...',
    ),
    _ => CheckRow(
      'wifiDirect',
      t,
      CheckLevel.warn,
      '${_d(s.wifiDirectDetail, 'Not running')}. Needs Wi-Fi turned on (no '
          'network needed) and the Nearby devices permission.',
      CheckFix.wifiSettings,
    ),
  };
}

CheckRow _bluetooth(ConnSnapshot s) {
  const t = 'Bluetooth';
  if (s.bluetoothPermissionMissing) {
    return const CheckRow(
      'bluetooth',
      t,
      CheckLevel.fail,
      'Permission "Nearby devices" not allowed: phones nearby cannot be found '
          'over Bluetooth.',
      CheckFix.bluetoothPermission,
    );
  }
  if (s.bluetoothOn == false) {
    return const CheckRow(
      'bluetooth',
      t,
      CheckLevel.warn,
      'Bluetooth is off. Turn it on to find phones nearby without Wi-Fi or '
          'internet.',
      CheckFix.bluetoothSettings,
    );
  }
  return switch (s.ble) {
    TransportStatus.running => CheckRow(
      'bluetooth',
      t,
      CheckLevel.ok,
      'On, advertising and scanning${s.offlineSaver ? ' (slower in Offline power save)' : ''}.',
    ),
    TransportStatus.starting => const CheckRow(
      'bluetooth',
      t,
      CheckLevel.warn,
      'Starting...',
    ),
    null => const CheckRow(
      'bluetooth',
      t,
      CheckLevel.off,
      'Not available on this phone.',
    ),
    _ => CheckRow(
      'bluetooth',
      t,
      CheckLevel.warn,
      _d(s.bleDetail, 'Not running'),
      CheckFix.bluetoothSettings,
    ),
  };
}

CheckRow _cell(ConnSnapshot s) {
  const t = 'Cell / mobile data';
  final i = s.cellInfo;
  final sig = i == null ? '' : cellLabel(i);
  final extra = sig.isEmpty ? '' : ' ($sig)';
  return switch (s.cell) {
    CellState.saver => const CheckRow(
      'cell',
      t,
      CheckLevel.off,
      'Not used: Offline power save is on (intentionally).',
    ),
    CellState.active => CheckRow(
      'cell',
      t,
      CheckLevel.ok,
      'The relay runs over mobile data$extra.',
    ),
    CellState.available => CheckRow(
      'cell',
      t,
      CheckLevel.ok,
      'Mobile data available$extra; the app uses Wi-Fi right now.',
    ),
    CellState.off => CheckRow(
      'cell',
      t,
      s.phoneNet == 'wifi' ? CheckLevel.warn : CheckLevel.fail,
      i?.airplane == true
          ? 'Airplane mode is on.'
          : i != null && !i.sim
          ? 'No SIM / no cell service.'
          : 'No mobile service or mobile data is off.',
      CheckFix.mobileNetwork,
    ),
    CellState.blocked => CheckRow(
      'cell',
      t,
      CheckLevel.fail,
      'Mobile data works$extra but the relay cannot be reached over it. '
          '${i?.dataSaver == true ? 'Data Saver is on: allow "Unrestricted data" for this app. ' : ''}'
          'In App info > Mobile data turn on Mobile data and Background data.',
      CheckFix.appInfo,
    ),
    CellState.unknown => const CheckRow(
      'cell',
      t,
      CheckLevel.off,
      'No cellular details on this phone.',
    ),
  };
}

CheckRow _internet(ConnSnapshot s) {
  const t = 'Internet';
  if (s.offlineSaver) {
    return const CheckRow(
      'internet',
      t,
      CheckLevel.off,
      'Not used: Offline power save is on (intentionally).',
    );
  }
  final p = s.internet;
  if (p == null) {
    return const CheckRow('internet', t, CheckLevel.warn, 'Not tested.');
  }
  if (p.ok) {
    return CheckRow(
      'internet',
      t,
      CheckLevel.ok,
      'Reachable${p.ms != null ? ' (${p.ms} ms)' : ''}'
          '${s.phoneNet == 'cell'
              ? ' over mobile data'
              : s.phoneNet == 'wifi'
              ? ' over Wi-Fi'
              : ''}.',
    );
  }
  return CheckRow(
    'internet',
    t,
    CheckLevel.fail,
    'Not reachable (${_d(p.error, 'no answer')}). Check Wi-Fi / mobile data; '
        'the app still works nearby over Wi-Fi, Bluetooth and the radio.',
    s.phoneNet == 'wifi' ? CheckFix.wifiSettings : CheckFix.mobileNetwork,
  );
}

CheckRow _relay(ConnSnapshot s) {
  const t = 'Internet relay';
  if (s.offlineSaver) {
    return const CheckRow(
      'relay',
      t,
      CheckLevel.off,
      'Off: Offline power save is on (intentionally).',
    );
  }
  if (!s.relayConfigured) {
    return const CheckRow(
      'relay',
      t,
      CheckLevel.off,
      'Turned off in Settings (relay server "off"). Phones far away cannot '
          'be reached.',
      CheckFix.relaySettings,
    );
  }
  final p = s.relay;
  final link = s.relayLink;
  if (p != null && p.ok) {
    final linkNote = link == TransportStatus.running
        ? ''
        : ' The app\'s own link is ${link?.name ?? 'down'}'
              '${s.relayLinkDetail != null ? ' (${s.relayLinkDetail})' : ''}; '
              'it retries on its own.';
    return CheckRow(
      'relay',
      t,
      link == TransportStatus.running ? CheckLevel.ok : CheckLevel.warn,
      'Connected to ${p.host ?? 'the relay'}'
          '${p.connectMs != null ? ' in ${p.connectMs} ms' : ''}, '
          'ping ${p.rttMs ?? '?'} ms, room ${p.room ?? '?'}.$linkNote',
    );
  }
  final why = _d(p?.error, 'not tested');
  final internetOk = s.internet?.ok ?? false;
  return CheckRow(
    'relay',
    t,
    CheckLevel.fail,
    'Cannot reach the relay ($why). '
        '${internetOk ? 'The internet works, so the relay may be waking up (up to a minute) or blocked on this network; try again.' : 'No internet: fix that first.'}',
    internetOk
        ? CheckFix.relaySettings
        : (s.cell == CellState.blocked
              ? CheckFix.appInfo
              : CheckFix.mobileNetwork),
  );
}

CheckRow _radio(ConnSnapshot s) {
  const t = 'Long-range radio (optional)';
  if (!s.radioPaired) {
    return const CheckRow(
      'radio',
      t,
      CheckLevel.off,
      'No Meshtastic radio paired (optional, for miles of range off-grid).',
      CheckFix.radioPairing,
    );
  }
  if (s.radioReady) {
    return CheckRow(
      'radio',
      t,
      CheckLevel.ok,
      'Connected${s.radioDetail != null ? ': ${s.radioDetail}' : ''}.',
    );
  }
  return CheckRow(
    'radio',
    t,
    CheckLevel.warn,
    'Paired but not connected (${_d(s.radioDetail, 'out of range or off')}).',
    CheckFix.radioPairing,
  );
}

CheckRow _permissions(ConnSnapshot s) {
  const t = 'Permissions';
  final missing = [
    for (final e in s.permissions.entries)
      if (e.value == PermState.denied || e.value == PermState.permanentlyDenied)
        e.key,
  ];
  if (s.permissions.isEmpty) {
    return const CheckRow(
      'permissions',
      t,
      CheckLevel.off,
      'Not checked on this phone.',
    );
  }
  if (missing.isEmpty) {
    return const CheckRow('permissions', t, CheckLevel.ok, 'All allowed.');
  }
  final blocked = missing.any(
    (p) => s.permissions[p] == PermState.permanentlyDenied,
  );
  final critical =
      missing.contains(AppPermission.microphone) ||
      missing.contains(AppPermission.nearby);
  return CheckRow(
    'permissions',
    t,
    critical ? CheckLevel.fail : CheckLevel.warn,
    'Not allowed: ${missing.map((p) => p.label).join(', ')}.',
    blocked ? CheckFix.appInfo : CheckFix.permissions,
  );
}

CheckRow _battery(ConnSnapshot s) {
  const t = 'Background / battery';
  if (s.batteryExempt == null) {
    return const CheckRow(
      'battery',
      t,
      CheckLevel.off,
      'Not checked on this phone.',
    );
  }
  if (!s.stayReachable) {
    return const CheckRow(
      'battery',
      t,
      CheckLevel.off,
      '"Stay reachable when app is closed" is off (intentionally): rings and '
          'messages only arrive while the app is open.',
    );
  }
  final guide = batteryGuideFor(s.manufacturer);
  final vendor =
      guide.brand == PhoneBrand.other || guide.brand == PhoneBrand.pixel
      ? ''
      : ' ${guide.name} phones also need their own setting: tap Show steps.';
  if (s.batteryExempt == false) {
    return CheckRow(
      'battery',
      t,
      CheckLevel.fail,
      'Battery optimization is on for this app: Android may put it to sleep '
          'and you stop getting rings and messages.$vendor',
      CheckFix.batteryExemption,
    );
  }
  if (s.serviceRunning == false) {
    return const CheckRow(
      'battery',
      t,
      CheckLevel.warn,
      'Allowed in the background, but the listening service is not running. '
          'Open the app once more, or turn "Stay reachable" off and on.',
      CheckFix.batteryGuide,
    );
  }
  return CheckRow(
    'battery',
    t,
    vendor.isEmpty ? CheckLevel.ok : CheckLevel.warn,
    'Battery optimization is off; the listening service keeps links open.$vendor',
    vendor.isEmpty ? CheckFix.none : CheckFix.batteryGuide,
  );
}
