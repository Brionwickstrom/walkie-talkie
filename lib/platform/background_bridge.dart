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

  Future<bool> startService({
    required String title,
    required String text,
  }) async =>
      await _call<bool>('startService', {'title': title, 'text': text}) ??
      false;

  Future<void> updateService({required String title, required String text}) =>
      _call<void>('updateService', {'title': title, 'text': text});

  Future<void> stopService() => _call<void>('stopService');

  Future<bool> serviceRunning() async =>
      await _call<bool>('serviceRunning') ?? false;

  Future<void> showRing({
    required int from,
    required int id,
    required String name,
    required int channel,
  }) => _call<void>('showRing', {
    'from': from,
    'id': id,
    'name': name,
    'channel': channel,
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
  }) => _call<void>('showTalking', {
    'peer': peer,
    'name': name,
    'channel': channel,
  });

  Future<void> cancelTalking(int peer) =>
      _call<void>('cancelTalking', {'peer': peer});

  Future<void> showVoiceMessage({
    required String key,
    required int nid,
    required String name,
    required String duration,
  }) => _call<void>('showVoiceMessage', {
    'key': key,
    'nid': nid,
    'name': name,
    'duration': duration,
  });

  Future<void> showInfo({
    required int nid,
    required String title,
    required String text,
  }) => _call<void>('showInfo', {'nid': nid, 'title': title, 'text': text});

  Future<String?> filesDir() => _call<String>('filesDir');

  Future<String> manufacturer() async =>
      await _call<String>('manufacturer') ?? '';

  /// True when Android won't put the app to sleep.
  Future<bool> ignoringBatteryOptimizations() async =>
      await _call<bool>('ignoringBattery') ?? true;

  Future<void> requestIgnoreBatteryOptimizations() =>
      _call<void>('requestIgnoreBattery');

  Future<void> openAppSettings() => _call<void>('openAppSettings');

  Future<bool> canUseFullScreen() async =>
      await _call<bool>('canFullScreen') ?? true;

  Future<void> openFullScreenSettings() =>
      _call<void>('openFullScreenSettings');

  Future<void> setBootStart(bool on) => _call<void>('setBootStart', {'on': on});
}
