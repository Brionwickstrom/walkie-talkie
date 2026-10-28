import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Dart side of the Android "walkie/bg" channel (see BgBridge.kt): the
/// listening foreground service, ring / beep / talking / voice message
/// notifications and battery settings. Every call is a no-op off Android.
class BackgroundBridge {
  BackgroundBridge();

  static const _ch = MethodChannel('walkie/bg');
  final _actions = StreamController<Map<String, Object?>>.broadcast();
  bool _init = false;

  bool get supported => Platform.isAndroid;

  /// Notification buttons / launch intents: maps with a `type` of stop,
  /// answer, dismiss, ringOpen, play, openInbox, openChannel.
  Stream<Map<String, Object?>> get actions => _actions.stream;

  /// Start receiving actions; replays the ones that arrived before Dart was
  /// ready (e.g. the Answer tap that launched the app).
  Future<void> init() async {
    if (_init || !supported) return;
    _init = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is Map) {
        _actions.add(Map<String, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    final pending = await _call<List<Object?>>('ready');
    for (final a in pending ?? const []) {
      if (a is Map) _actions.add(Map<String, Object?>.from(a));
    }
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  /// [mic]: also claim the microphone (talk with the app in the
  /// background); only works while the app is on screen. [talk]: show a
  /// Talk button on the notification; [talking]: we are transmitting.
  Future<bool> startService({
    required String title,
    required String text,
    bool mic = false,
    bool talk = false,
    bool talking = false,
  }) async =>
      await _call<bool>('startService', {
        'title': title,
        'text': text,
        'mic': mic,
        'talk': talk,
        'talking': talking,
      }) ??
      false;

  Future<void> updateService({
    required String title,
    required String text,
    bool talk = false,
    bool talking = false,
  }) => _call<void>('updateService', {
    'title': title,
    'text': text,
    'talk': talk,
    'talking': talking,
  });

  /// The listening service may use the mic (background talk works).
  Future<bool> micInBackground() async =>
      await _call<bool>('micInBackground') ?? false;

  /// Hardware talk buttons (see PttKeys.kt).
  Future<void> setPttConfig({required bool volume, required bool headset}) =>
      _call<void>('setPttConfig', {'volume': volume, 'headset': headset});

  /// The optional accessibility service (volume-down in the background).
  Future<bool> accessibilityEnabled() async =>
      await _call<bool>('a11yEnabled') ?? false;

  Future<void> openAccessibilitySettings() => _call<void>('openA11ySettings');

  /// Do Not Disturb access (urgent rings may sound through DND).
  Future<bool> dndAccess() async => await _call<bool>('dndAccess') ?? false;

  Future<void> openDndSettings() => _call<void>('openDndSettings');

  Future<void> stopService() => _call<void>('stopService');

  Future<bool> serviceRunning() async =>
      await _call<bool>('serviceRunning') ?? false;

  Future<void> showRing({
    required int from,
    required int id,
    required String name,
    required int channel,
    bool urgent = false,
    bool loud = true,
  }) => _call<void>('showRing', {
    'from': from,
    'id': id,
    'name': name,
    'channel': channel,
    'urgent': urgent,
    'loud': loud,
  });

  Future<void> stopRing({required int from, required int id}) =>
      _call<void>('stopRing', {'from': from, 'id': id});

  /// Plays the roger chirp; [notify] also posts "X beeped you".
  Future<void> beep({
    required int from,
    required String name,
    bool notify = true,
  }) => _call<void>('beep', {'from': from, 'name': name, 'notify': notify});

  Future<void> showTalking({
    required int peer,
    required String name,
    required int channel,
    bool friend = false,
  }) => _call<void>('showTalking', {
    'peer': peer,
    'name': name,
    'channel': channel,
    'friend': friend,
  });

  Future<void> cancelTalking(int peer) =>
      _call<void>('cancelTalking', {'peer': peer});

  Future<void> showVoiceMessage({
    required String key,
    required int nid,
    required String name,
    required String duration,
    bool silent = false,
  }) => _call<void>('showVoiceMessage', {
    'key': key,
    'nid': nid,
    'name': name,
    'duration': duration,
    'silent': silent,
  });

  Future<void> showInfo({
    required int nid,
    required String title,
    required String text,
  }) => _call<void>('showInfo', {'nid': nid, 'title': title, 'text': text});

  Future<String?> filesDir() => _call<String>('filesDir');

  /// One location fix (Android), or null.
  Future<({double lat, double lng, double? acc})?> getLocation() async {
    final m = await _call<Map<Object?, Object?>>('getLocation');
    final lat = m?['lat'], lng = m?['lng'];
    if (lat is! num || lng is! num) return null;
    return (
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      acc: (m?['acc'] as num?)?.toDouble(),
    );
  }

  /// Continuous location fixes (Trip tab); they arrive on [actions] as
  /// `{type: loc, lat, lng, acc, t, alt, spd}`. False without permission.
  Future<bool> startLocationUpdates(
    Duration interval, {
    bool highAccuracy = true,
  }) async =>
      await _call<bool>('startLocationUpdates', {
        'interval': interval.inMilliseconds,
        'accurate': highAccuracy,
      }) ??
      false;

  Future<void> stopLocationUpdates() => _call<void>('stopLocationUpdates');

  /// Keep location working with the app in the background (adds the
  /// location type to the listening service).
  Future<void> setServiceLocation(bool on) =>
      _call<void>('setServiceLocation', {'on': on});

  /// Trip SOS: full-screen alert + alarm tone (through silent mode, and
  /// Do Not Disturb when allowed) until [stopSos].
  Future<void> showSos({
    required int from,
    required int id,
    required String name,
    required String text,
  }) => _call<void>('showSos', {
    'from': from,
    'id': id,
    'name': name,
    'text': text,
  });

  Future<void> stopSos({required int from, required int id}) =>
      _call<void>('stopSos', {'from': from, 'id': id});

  Future<void> silenceSos() => _call<void>('silenceSos');

  /// Share a file (e.g. a GPX trail) with another app.
  Future<bool> shareFile(
    String path, {
    required String mime,
    String title = '',
  }) async =>
      await _call<bool>('shareFile', {
        'path': path,
        'mime': mime,
        'title': title,
      }) ??
      false;

  /// Open a link (Google Maps) in another app.
  Future<bool> openUrl(String url) async =>
      await _call<bool>('openUrl', {'url': url}) ?? false;

  /// Manufacturer, model, Android SDK and release (v1.8.7, debug log).
  Future<Map<Object?, Object?>?> deviceInfo() =>
      _call<Map<Object?, Object?>>('deviceInfo');

  /// Share [text] through the Android share sheet (v1.8.7).
  Future<bool> shareText(String text, String title) async =>
      await _call<bool>('shareText', {'text': text, 'title': title}) ?? false;

  /// Open the phone maker's own auto-start / background screen; false when
  /// this phone has none we know (v1.8.7).
  Future<bool> openVendorBattery() async =>
      await _call<bool>('openVendorBattery') ?? false;

  Future<String> manufacturer() async =>
      await _call<String>('manufacturer') ?? '';

  /// Media-stream volume 0..1 (what walkie voices play on); null off Android.
  Future<double?> mediaVolume() => _call<double>('mediaVolume');

  /// Phone battery 0..100 (null when unknown / not Android), v1.8.3.
  Future<({int pct, bool charging})?> batteryLevel() async {
    final m = await _call<Map<Object?, Object?>>('batteryLevel');
    final p = (m?['pct'] as num?)?.toInt();
    if (p == null || p < 0 || p > 100) return null;
    return (pct: p, charging: m?['chg'] == true);
  }

  /// True when Android won't put the app to sleep.
  Future<bool> ignoringBatteryOptimizations() async =>
      await _call<bool>('ignoringBattery') ?? true;

  Future<void> requestIgnoreBatteryOptimizations() =>
      _call<void>('requestIgnoreBattery');

  Future<void> openAppSettings() => _call<void>('openAppSettings');

  /// v1.8.5: open a phone settings screen: "app" (App info: Mobile data,
  /// Background data, Battery), "wifi", "bluetooth" or "location".
  Future<bool> openSystemSettings(String which) async =>
      await _call<bool>('openSystemSettings', {'which': which}) ?? false;

  /// v1.8.5: the phone's network: "wifi", "cell", "other", "none"; null
  /// when unknown (not Android).
  Future<String?> netKind() => _call<String>('netKind');

  /// v1.8.6: cellular state for the Cell icon (no extra permission); null
  /// off Android.
  Future<Map<Object?, Object?>?> cellInfo() =>
      _call<Map<Object?, Object?>>('cellInfo');

  Future<bool> canUseFullScreen() async =>
      await _call<bool>('canFullScreen') ?? true;

  Future<void> openFullScreenSettings() =>
      _call<void>('openFullScreenSettings');

  Future<void> setBootStart(bool on) => _call<void>('setBootStart', {'on': on});
}
