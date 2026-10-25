import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'call_signs.dart';

/// Everything that must survive an app restart: the phone's stable id (so
/// other phones keep showing the same name), its display name, the channel
/// and the relay URL.
class AppSettings {
  AppSettings({
    required this.nodeId,
    this.customName,
    required this.channel,
    this.relayUrl,
    this.callSignSalt = 0,
    this.stayReachable = true,
    this.startOnBoot = false,
    this.batteryPromptShown = false,
    this.showDiagnostics = false,
    Map<int, String>? privateChannels,
    Map<int, double>? peerVolumes,
  }) : privateChannels = privateChannels ?? {},
       peerVolumes = peerVolumes ?? {} {
    // v1.1.x prefilled the name box with "Phone 38EA", so pressing Save
    // stored it as if typed. Treat that as "never customized".
    if (customName != null &&
        customName!.trim() == legacyDefaultNameFor(nodeId)) {
      customName = null;
    }
  }

  /// Generated once on first launch, never changes.
  final int nodeId;

  /// Name the user typed, or null to use [defaultName].
  String? customName;
  int channel;

  /// Relay URL the user set; null = app default.
  String? relayUrl;

  /// Reroll counter for the default call sign (0 = original).
  int callSignSalt;

  /// Keep a foreground service running so rings / voice messages / live
  /// audio still arrive after the app is closed (Android).
  bool stayReachable;

  /// Start listening after the phone reboots (Android, needs [stayReachable]).
  bool startOnBoot;

  /// The battery-optimization explanation was shown once already.
  bool batteryPromptShown;

  /// Per-person playback volume (peer id -> 0..2, 1 = normal).
  final Map<int, double> peerVolumes;

  static String encodeVolumes(Map<int, double> m) =>
      jsonEncode({for (final e in m.entries) '${e.key}': e.value});

  static Map<int, double> decodeVolumes(String? s) {
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return {
        for (final e in m.entries)
          if (int.tryParse(e.key) != null && e.value is num)
            int.parse(e.key): (e.value as num).toDouble().clamp(0.0, 2.0),
      };
    } catch (_) {
      return {};
    }
  }

  /// Home screen "Details" (link diagnostics) expanded.
  bool showDiagnostics;

  /// Passcodes of the channels marked private (channel -> passcode).
  /// Channels not in the map are public.
  final Map<int, String> privateChannels;

  String? passcodeFor(int channel) => privateChannels[channel];
  bool isPrivate(int channel) => privateChannels.containsKey(channel);

  static String encodePrivate(Map<int, String> m) =>
      jsonEncode({for (final e in m.entries) '${e.key}': e.value});

  static Map<int, String> decodePrivate(String? s) {
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return {
        for (final e in m.entries)
          if (int.tryParse(e.key) != null && e.value is String)
            int.parse(e.key): e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  /// Name used by v1.1.x before call signs existed.
  static String legacyDefaultNameFor(int nodeId) =>
      'Phone ${nodeId.toRadixString(16).padLeft(8, '0').substring(0, 4).toUpperCase()}';

  static String defaultNameFor(int nodeId, {int salt = 0}) =>
      callSignFor(nodeId, salt: salt);

  bool get hasCustomName => customName != null && customName!.trim().isNotEmpty;

  String get defaultName => defaultNameFor(nodeId, salt: callSignSalt);
  String get name => (customName == null || customName!.trim().isEmpty)
      ? defaultName
      : customName!;
}

abstract class SettingsStore {
  Future<AppSettings> load({required int defaultChannel});
  Future<void> save(AppSettings s);
}

int newNodeId([Random? rng]) =>
    (rng ?? Random.secure()).nextInt(0xFFFFFFFF) + 1;

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.saved]);
  AppSettings? saved;

  @override
  Future<AppSettings> load({required int defaultChannel}) async =>
      saved ??= AppSettings(nodeId: newNodeId(), channel: defaultChannel);

  @override
  Future<void> save(AppSettings s) async => saved = s;
}

class SharedPrefsSettingsStore implements SettingsStore {
  const SharedPrefsSettingsStore();
  static const _kId = 'node_id';
  static const _kName = 'display_name';
  static const _kChannel = 'channel';
  static const _kRelay = 'relay_url';
  static const _kSalt = 'call_sign_salt';
  static const _kReach = 'stay_reachable';
  static const _kBoot = 'start_on_boot';
  static const _kBattery = 'battery_prompt_shown';
  static const _kPrivate = 'private_channels';
  static const _kDiag = 'show_diagnostics';
  static const _kVolumes = 'peer_volumes';

  @override
  Future<AppSettings> load({required int defaultChannel}) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    var id = prefs?.getInt(_kId);
    if (id == null || id <= 0) {
      id = newNodeId();
      try {
        await prefs?.setInt(_kId, id);
      } catch (_) {}
    }
    return AppSettings(
      nodeId: id,
      customName: prefs?.getString(_kName),
      channel: prefs?.getInt(_kChannel) ?? defaultChannel,
      relayUrl: prefs?.getString(_kRelay),
      callSignSalt: prefs?.getInt(_kSalt) ?? 0,
      stayReachable: prefs?.getBool(_kReach) ?? true,
      startOnBoot: prefs?.getBool(_kBoot) ?? false,
      batteryPromptShown: prefs?.getBool(_kBattery) ?? false,
      privateChannels: AppSettings.decodePrivate(prefs?.getString(_kPrivate)),
      showDiagnostics: prefs?.getBool(_kDiag) ?? false,
      peerVolumes: AppSettings.decodeVolumes(prefs?.getString(_kVolumes)),
    );
  }

  @override
  Future<void> save(AppSettings s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kId, s.nodeId);
      final n = s.customName?.trim();
      if (n == null || n.isEmpty) {
        await prefs.remove(_kName);
      } else {
        await prefs.setString(_kName, n);
      }
      await prefs.setInt(_kChannel, s.channel);
      final r = s.relayUrl;
      if (r == null) {
        await prefs.remove(_kRelay);
      } else {
        await prefs.setString(_kRelay, r);
      }
      await prefs.setInt(_kSalt, s.callSignSalt);
      await prefs.setBool(_kReach, s.stayReachable);
      await prefs.setBool(_kBoot, s.startOnBoot);
      await prefs.setBool(_kBattery, s.batteryPromptShown);
      await prefs.setBool(_kDiag, s.showDiagnostics);
      await prefs.setString(
        _kVolumes,
        AppSettings.encodeVolumes(s.peerVolumes),
      );
      await prefs.setString(
        _kPrivate,
        AppSettings.encodePrivate(s.privateChannels),
      );
    } catch (_) {}
  }
}
