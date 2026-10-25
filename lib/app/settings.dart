import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Everything that must survive an app restart: the phone's stable id (so
/// other phones keep showing the same name), its display name, the channel
/// and the relay URL.
class AppSettings {
  AppSettings({
    required this.nodeId,
    this.customName,
    required this.channel,
    this.relayUrl,
  });

  /// Generated once on first launch, never changes.
  final int nodeId;

  /// Name the user typed, or null to use [defaultName].
  String? customName;
  int channel;

  /// Relay URL the user set; null = app default.
  String? relayUrl;

  static String defaultNameFor(int nodeId) =>
      'Phone ${nodeId.toRadixString(16).padLeft(8, '0').substring(0, 4).toUpperCase()}';

  String get defaultName => defaultNameFor(nodeId);
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
    } catch (_) {}
  }
}
