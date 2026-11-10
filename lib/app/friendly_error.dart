// v2.6.3: plain error messages with a fix button. One place maps what went
// wrong to one plain sentence (what happened and why) and, where a fix
// exists, the action that does it. Raw exception text is never the main
// message: it goes under "Details", with keys and links scrubbed.
import 'dart:async';
import 'dart:io';

import '../lora/radio_share.dart';
import '../trip/battery_mode.dart';
import '../trip/location_source.dart';
import 'settings.dart';

/// What a fix button does. The UI runs it (lib/ui/friendly_error.dart).
enum FixAction {
  turnOnBluetooth('Turn on Bluetooth'),
  allowNearby('Allow'),
  allowLocation('Allow location'),
  turnOnLocation('Turn on location'),
  allowMicrophone('Allow microphone'),
  allowNotifications('Allow notifications'),
  allowCamera('Allow camera'),
  openAppSettings('Open settings'),
  allowMobileData('Allow mobile data'),
  wifiSettings('Wi-Fi settings'),
  allowDnd('Allow Do Not Disturb'),
  connectRadio('Connect radio'),
  retry('Try again'),
  restoreBackup('Restore backup'),
  turnOnLocationSharing('Turn it on'),
  openRadioSettings('Radio settings'),
  usePhoneGps('Use Auto'),
  useFreePort('Use a free port'),
  stopRadioShare('Turn off sharing'),
  stopRangeTest('Stop range test'),
  useTrackingMode('Switch to Tracking'),
  useNormalMode('Switch to Normal'),
  checkBroker('Check again'),
  enterMqttPassword('Enter password');

  const FixAction(this.label);
  final String label;
}

/// Why something did not work, when it is one of the known causes.
enum ErrorCause {
  bluetoothOff,
  bluetoothDenied,
  locationDenied,
  locationOff,
  microphoneDenied,
  microphoneFailed,
  notificationsDenied,
  cameraDenied,
  noInternet,
  mobileDataBlocked,
  dndDenied,
  radioNotConnected,
  audioFailed,
  voiceMessagesFailed,
  installerFailed,
  other,
}

/// One plain sentence, up to two fix buttons, and the raw text for
/// "Details".
class FriendlyError {
  const FriendlyError(
    this.message, {
    this.cause = ErrorCause.other,
    this.fix,
    this.fix2,
    this.details,
  });

  /// What happened and why, one sentence.
  final String message;
  final ErrorCause cause;

  /// The main fix (null = nothing the user can do from here).
  final FixAction? fix;

  /// A second choice, for example Restore backup next to Try again.
  final FixAction? fix2;

  /// The technical text, shown only when the user asks for it.
  final String? details;

  List<FixAction> get fixes => [?fix, ?fix2];

  FriendlyError copyWith({
    String? message,
    FixAction? fix,
    FixAction? fix2,
    String? details,
  }) => FriendlyError(
    message ?? this.message,
    cause: cause,
    fix: fix ?? this.fix,
    fix2: fix2 ?? this.fix2,
    details: details ?? this.details,
  );

  @override
  String toString() => message;
}

/// v2.6.7: why the radio's GPS is not giving the location, as a plain
/// error with the fix that helps (Connect radio, Radio settings, or back to
/// Auto). Null while the radio's GPS is used, with Phone GPS only, or when
/// the phone is used on purpose (navigation and so on).
FriendlyError? radioGpsError(LocationChoice c) {
  if (c.setting == LocationSource.phone || c.usingRadio) return null;
  final why = c.why;
  if (why == null || why == RadioGpsWhy.needPhone) return null;
  final r = c.reason ?? '';
  final onlyRadio = c.setting == LocationSource.radio;
  final lead = onlyRadio
      ? 'No location: Radio GPS only is on and '
      : "Using the phone's GPS: ";
  final because = r.isEmpty ? r : r[0].toLowerCase() + r.substring(1);
  final message = '$lead$because';
  final second = onlyRadio ? FixAction.usePhoneGps : null;
  return switch (why) {
    RadioGpsWhy.notConnected => FriendlyError(
      message,
      cause: ErrorCause.radioNotConnected,
      fix: FixAction.connectRadio,
      fix2: second,
    ),
    RadioGpsWhy.notSharing || RadioGpsWhy.blurred => FriendlyError(
      message,
      fix: FixAction.openRadioSettings,
      fix2: second,
    ),
    _ => FriendlyError(message, fix: second),
  };
}

/// v2.6.10: why the one-tap range test cannot start or is not pinging, as
/// one plain sentence with its fix. Null = nothing wrong.
FriendlyError? rangeTestProblem({
  required bool radioReady,
  bool running = false,
  bool waitingForGps = false,
}) {
  if (!radioReady) {
    return FriendlyError(
      running
          ? 'Your radio is not connected, so the range test cannot ping the '
                'home radio. It carries on when the radio is back.'
          : 'The range test needs your radio connected, so it can ping the '
                'home radio.',
      cause: ErrorCause.radioNotConnected,
      fix: FixAction.connectRadio,
    );
  }
  if (running && waitingForGps) {
    return const FriendlyError(
      'No GPS fix on this phone yet, so no pings are being sent. Turn on '
      'location or move where the sky is open.',
      cause: ErrorCause.locationOff,
      fix: FixAction.turnOnLocation,
      fix2: FixAction.allowLocation,
    );
  }
  return null;
}

/// v2.6.12: why a Battery mode cannot be picked right now (null = it can).
FriendlyError? batteryModeProblem({
  required BatteryMode want,
  required bool rangeTestRunning,
}) {
  if (want == BatteryMode.saver && rangeTestRunning) {
    return const FriendlyError(
      'A range test is running, and Saver turns its pings off. Stop the '
      'test first, or use Tracking.',
      fix: FixAction.stopRangeTest,
      fix2: FixAction.useTrackingMode,
    );
  }
  return null;
}

/// v2.6.12: the one-tap range test cannot start while Battery mode is
/// Saver (Saver turns the pings off).
const rangeTestSaverError = FriendlyError(
  'Battery mode is Saver, which turns radio pings off, so the range test '
  'cannot run. Switch to Tracking (or Normal) to start it.',
  fix: FixAction.useTrackingMode,
  fix2: FixAction.useNormalMode,
);

/// v2.6.12: the Battery mode could not be saved.
FriendlyError batteryModeSaveError(Object e) {
  final fe = friendlyFromError(e);
  if (fe.message.contains('out of storage')) return fe;
  return FriendlyError(
    'Could not change the Battery mode: the phone did not let the app save '
    'the setting. Nothing else was changed.',
    fix: FixAction.retry,
    details: detailsOf(e),
  );
}

/// v2.6.9: why "Share radio with other programs on this PC" is not
/// running, as one plain sentence with its fix. Null when it runs (or is
/// off).
FriendlyError? radioShareProblem(RadioShareHub hub, AppSettings s) {
  if (!s.radioShareLocal || hub.running) return null;
  final port = s.radioSharePort;
  return switch (hub.problem) {
    RadioShareProblem.portInUse => FriendlyError(
      'Port $port is already used by another program on this PC, so the '
      'radio cannot be shared on it. Pick another port.',
      fix: FixAction.useFreePort,
      fix2: FixAction.stopRadioShare,
      details: hub.problemDetails == null
          ? null
          : scrubDetails(hub.problemDetails!),
    ),
    RadioShareProblem.cannotListen => FriendlyError(
      'Windows did not let the app share the radio on port $port. Try '
      'another port, or turn sharing off.',
      fix: FixAction.useFreePort,
      fix2: FixAction.stopRadioShare,
      details: hub.problemDetails == null
          ? null
          : scrubDetails(hub.problemDetails!),
    ),
    null => null,
  };
}

/// v2.6.11: "Clear map cache" did not finish.
FriendlyError mapCacheClearError(Object e) {
  final fe = friendlyFromError(e);
  if (fe.message.contains('out of storage')) return fe;
  return FriendlyError(
    'Could not clear the map cache: the phone did not let the app delete '
    'some map files. Saved offline areas were not touched.',
    fix: FixAction.retry,
    details: detailsOf(e),
  );
}

/// Raw text safe to show: no Meshtastic links, no key-like strings, no
/// web addresses.
String scrubDetails(String raw) {
  var s = raw;
  s = s.replaceAllMapped(
    RegExp(r'mqtts?://[^:\s/@]+:[^@\s]+@', caseSensitive: false),
    (_) => 'mqtt://[redacted]@',
  );
  s = s.replaceAllMapped(
    RegExp(r'(password|mqtt[_\s-]?pass)(\s*[:=]\s*)\S+', caseSensitive: false),
    (m) => '${m[1]}${m[2]}[redacted]',
  );
  s = s.replaceAll(
    RegExp(r'https?://\S+|meshtastic\.org/\S+|walkietalkie://\S+'),
    '[link removed]',
  );
  // Keys, passcodes and tokens: long runs of base64 / hex characters.
  s = s.replaceAll(RegExp(r'[A-Za-z0-9_\-+/=]{24,}'), '[removed]');
  if (s.length > 400) s = '${s.substring(0, 400)}…';
  return s.trim();
}

/// The text under "Details" for [e].
String detailsOf(Object? e) {
  if (e == null) return '';
  final t = e is StateError ? e.message : e.toString();
  return scrubDetails(t);
}

FriendlyError _cause(ErrorCause c, {Object? error, String? details}) {
  final d = details ?? (error == null ? null : detailsOf(error));
  final dd = d == null || d.isEmpty ? null : d;
  return switch (c) {
    ErrorCause.bluetoothOff => FriendlyError(
      'Bluetooth is off, so this phone cannot find or reach radios.',
      cause: c,
      fix: FixAction.turnOnBluetooth,
      details: dd,
    ),
    ErrorCause.bluetoothDenied => FriendlyError(
      'This app is not allowed to use Bluetooth, so it cannot find nearby '
      'devices.',
      cause: c,
      fix: FixAction.allowNearby,
      details: dd,
    ),
    ErrorCause.locationDenied => FriendlyError(
      'Location is off for this app, so it cannot share where you are.',
      cause: c,
      fix: FixAction.allowLocation,
      details: dd,
    ),
    ErrorCause.locationOff => FriendlyError(
      'Your phone\'s location is turned off, so it cannot find where you '
      'are.',
      cause: c,
      fix: FixAction.turnOnLocation,
      details: dd,
    ),
    ErrorCause.microphoneDenied => FriendlyError(
      'Microphone access is off, so you cannot talk.',
      cause: c,
      fix: FixAction.allowMicrophone,
      details: dd,
    ),
    ErrorCause.microphoneFailed => FriendlyError(
      'The microphone could not start. Another app may be using it, or '
      'microphone access is off.',
      cause: c,
      fix: FixAction.allowMicrophone,
      details: dd,
    ),
    ErrorCause.notificationsDenied => FriendlyError(
      'Notifications are off, so rings and messages will not show while '
      'the app is closed.',
      cause: c,
      fix: FixAction.allowNotifications,
      details: dd,
    ),
    ErrorCause.cameraDenied => FriendlyError(
      'Camera access is off, so a photo cannot be taken.',
      cause: c,
      fix: FixAction.allowCamera,
      details: dd,
    ),
    ErrorCause.noInternet => FriendlyError(
      'There is no internet right now, so this could not finish.',
      cause: c,
      fix: FixAction.retry,
      fix2: FixAction.wifiSettings,
      details: dd,
    ),
    ErrorCause.mobileDataBlocked => FriendlyError(
      'This app is not allowed to use mobile data, so it only works on '
      'Wi-Fi.',
      cause: c,
      fix: FixAction.allowMobileData,
      fix2: FixAction.retry,
      details: dd,
    ),
    ErrorCause.dndDenied => FriendlyError(
      'Do Not Disturb is on and this app is not allowed through it, so '
      'urgent rings and extreme alerts stay quiet.',
      cause: c,
      fix: FixAction.allowDnd,
      details: dd,
    ),
    ErrorCause.radioNotConnected => FriendlyError(
      'Your radio is not connected.',
      cause: c,
      fix: FixAction.connectRadio,
      details: dd,
    ),
    ErrorCause.audioFailed => FriendlyError(
      'Sound could not start on this phone, so you may not hear talk.',
      cause: c,
      fix: FixAction.retry,
      details: dd,
    ),
    ErrorCause.voiceMessagesFailed => FriendlyError(
      'Voice messages could not start, so they will not be saved or sent '
      'until the app is restarted.',
      cause: c,
      details: dd,
    ),
    ErrorCause.installerFailed => FriendlyError(
      'Android would not open the installer. The app may not be allowed to '
      'install updates.',
      cause: c,
      fix: FixAction.openAppSettings,
      fix2: FixAction.retry,
      details: dd,
    ),
    ErrorCause.other => FriendlyError(
      'Something went wrong, so this did not finish.',
      fix: FixAction.retry,
      details: dd,
    ),
  };
}

/// The friendly version of a known [cause]. [error] is kept under Details.
FriendlyError friendlyCause(ErrorCause cause, {Object? error}) =>
    _cause(cause, error: error);

/// Works out the cause of [e] when it is one we know (no internet, mobile
/// data blocked, Bluetooth off, a denied permission, the microphone in
/// use), else a generic sentence with [e] under Details. [what] finishes
/// "Could not ..." for the generic case ("download the forecast").
FriendlyError friendlyFromError(Object e, {String? what}) {
  final text = e is StateError ? e.message : e.toString();
  final low = text.toLowerCase();
  if (e is SocketException) {
    final code = e.osError?.errorCode;
    if (code == 1 || code == 13 || low.contains('operation not permitted')) {
      return _cause(ErrorCause.mobileDataBlocked, error: e);
    }
    return _cause(ErrorCause.noInternet, error: e);
  }
  if (e is TimeoutException ||
      e is HttpException ||
      e.runtimeType.toString() == 'ClientException' ||
      low.contains('failed host lookup') ||
      low.contains('network is unreachable') ||
      low.contains('connection refused') ||
      low.contains('connection reset')) {
    return _cause(ErrorCause.noInternet, error: e);
  }
  if (low.contains('turn bluetooth on') || low.contains('bluetooth is off')) {
    return _cause(ErrorCause.bluetoothOff, error: e);
  }
  if (low.contains('bluetooth') &&
      (low.contains('permission') || low.contains('denied'))) {
    return _cause(ErrorCause.bluetoothDenied, error: e);
  }
  if (low.contains('microphone') || low.contains('record')) {
    return _cause(
      low.contains('permission') || low.contains('denied')
          ? ErrorCause.microphoneDenied
          : ErrorCause.microphoneFailed,
      error: e,
    );
  }
  if (low.contains('location') &&
      (low.contains('permission') || low.contains('denied'))) {
    return _cause(ErrorCause.locationDenied, error: e);
  }
  if (e is FileSystemException && low.contains('no space')) {
    return FriendlyError(
      'This phone is out of storage space, so it could not be saved.',
      details: detailsOf(e),
    );
  }
  final base = _cause(ErrorCause.other, error: e);
  if (what == null) return base;
  return base.copyWith(message: 'Could not $what, so it did not finish.');
}

/// The Radio settings "Not saved" text for [raw] (a MeshWriteException
/// message, already plain), as "Not saved because ...", with the buttons
/// that fit: Try again, Restore backup (when one exists), Connect radio.
FriendlyError radioWriteError(String raw, {bool hasBackup = false}) {
  final low = raw.toLowerCase();
  FriendlyError notSaved(
    String because, {
    FixAction? fix = FixAction.retry,
    FixAction? fix2,
  }) => FriendlyError(
    'Not saved because $because',
    cause: ErrorCause.other,
    fix: fix,
    fix2:
        fix2 ??
        (hasBackup && fix != FixAction.restoreBackup
            ? FixAction.restoreBackup
            : null),
    details: raw,
  );
  if (low.contains('connect your radio first')) {
    return FriendlyError(
      'Not saved because your radio is not connected.',
      cause: ErrorCause.radioNotConnected,
      fix: FixAction.connectRadio,
      fix2: hasBackup ? FixAction.restoreBackup : null,
      details: raw,
    );
  }
  if (low.contains('did not come back')) {
    return notSaved(
      'your radio did not come back after restarting. Check that it is on '
      'and in reach, connect it again, then check the settings.',
      fix: FixAction.connectRadio,
      fix2: hasBackup ? FixAction.restoreBackup : null,
    );
  }
  if (low.contains('did not keep')) {
    final what = RegExp(r'did not keep: ([^.]+)\.').firstMatch(raw)?.group(1);
    return notSaved(
      'your radio did not keep ${what ?? 'everything'}. Nothing else was '
      'touched.',
      fix: hasBackup ? FixAction.restoreBackup : FixAction.retry,
      fix2: hasBackup ? FixAction.retry : null,
    );
  }
  if (low.contains('did not send') ||
      low.contains('has not sent') ||
      low.contains('not configured')) {
    return notSaved('your radio did not answer in time. Nothing was changed.');
  }
  if (low.contains('talk is going on') || low.contains('being changed')) {
    return notSaved('a talk is going on. Try again when it is over.');
  }
  if (low.contains('extra channel slots')) {
    return notSaved(
      'all 7 extra channel slots on your radio are in use. Remove one in '
      'the Meshtastic app, then try again.',
    );
  }
  if (low.contains('nothing to change') || low.contains('pick a precision')) {
    return FriendlyError('Not saved. $raw', details: null);
  }
  // A MeshWriteException message is already a plain sentence: keep it,
  // but lead with what happened.
  final one = raw.trim().isEmpty ? 'something went wrong.' : raw.trim();
  return FriendlyError(
    'Not saved. $one',
    fix: FixAction.retry,
    fix2: hasBackup ? FixAction.restoreBackup : null,
    details: null,
  );
}
