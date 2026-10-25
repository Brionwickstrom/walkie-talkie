import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../friends/friend_links.dart';
import 'call_signs.dart';

/// A channel's display name and emoji (shared with the others on it via
/// presence; the newest [updated] wins).
class ChannelName {
  const ChannelName(this.name, this.emoji, this.updated);
  final String name;
  final String emoji;
  final int updated; // ms since epoch

  bool get isEmpty => name.isEmpty && emoji.isEmpty;

  Map<String, Object?> toJson() => {'n': name, 'e': emoji, 't': updated};

  static ChannelName? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['n'], e = j['e'], t = j['t'];
    if (n is! String || e is! String || t is! num) return null;
    return ChannelName(n, e, t.toInt());
  }
}

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
    this.powerSaver = false,
    this.volumeKeyPtt = false,
    this.headsetPtt = false,
    this.toggleTalk = false,
    this.notificationTalk = false,
    this.urgentLoud = true,
    Map<int, String>? privateChannels,
    Map<int, double>? peerVolumes,
    List<Friend>? friends,
    Map<int, ChannelName>? channelNames,
    Map<int, int>? channelAdmins,
    Set<int>? announceScopes,
    Set<int>? muted,
    Map<int, String>? blocked,
  }) : privateChannels = privateChannels ?? {},
       peerVolumes = peerVolumes ?? {},
       friends = friends ?? [],
       channelNames = channelNames ?? {},
       channelAdmins = channelAdmins ?? {},
       announceScopes = announceScopes ?? {},
       muted = muted ?? {},
       blocked = blocked ?? {} {
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

  /// Battery saver: slower beacons / scans / keep-alives.
  bool powerSaver;

  /// Hold volume-down to talk (app open; background with the optional
  /// accessibility service).
  bool volumeKeyPtt;

  /// Bluetooth / wired headset play-pause button talks (while listening).
  bool headsetPtt;

  /// Tap the talk button to start, tap again to stop.
  bool toggleTalk;

  /// "Talk" button on the listening notification (lock screen).
  bool notificationTalk;

  /// Urgent rings play at alarm volume, even in silent mode.
  bool urgentLoud;

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

  /// Friends with their pair keys.
  final List<Friend> friends;

  /// Channel names by scope (channel number or private scope).
  final Map<int, ChannelName> channelNames;

  /// Admin of each private channel (scope -> phone id).
  final Map<int, int> channelAdmins;

  /// Private channels (scopes) where I am admin and only admins may talk.
  final Set<int> announceScopes;

  /// People whose live talk is not played.
  final Set<int> muted;

  /// Blocked people (id -> name, for the unblock list).
  final Map<int, String> blocked;

  static String encodeSocial(AppSettings s) => jsonEncode({
    'cn': {
      for (final e in s.channelNames.entries) '${e.key}': e.value.toJson(),
    },
    'ad': {for (final e in s.channelAdmins.entries) '${e.key}': e.value},
    'an': s.announceScopes.toList(),
    'mu': s.muted.toList(),
    'bl': {for (final e in s.blocked.entries) '${e.key}': e.value},
  });

  /// Decodes [encodeSocial] into the given maps (bad parts are skipped).
  static void decodeSocial(
    String? str, {
    required Map<int, ChannelName> names,
    required Map<int, int> admins,
    required Set<int> announce,
    required Set<int> muted,
    required Map<int, String> blocked,
  }) {
    if (str == null || str.isEmpty) return;
    Object? j;
    try {
      j = jsonDecode(str);
    } catch (_) {
      return;
    }
    if (j is! Map) return;
    void eachEntry(Object? m, void Function(int k, Object? v) f) {
      if (m is! Map) return;
      m.forEach((k, v) {
        final i = int.tryParse('$k');
        if (i != null) f(i, v);
      });
    }

    eachEntry(j['cn'], (k, v) {
      final n = ChannelName.fromJson(v);
      if (n != null) names[k] = n;
    });
    eachEntry(j['ad'], (k, v) {
      if (v is num) admins[k] = v.toInt();
    });
    eachEntry(j['bl'], (k, v) {
      if (v is String) blocked[k] = v;
    });
    for (final x in (j['an'] as List?) ?? const []) {
      if (x is num) announce.add(x.toInt());
    }
    for (final x in (j['mu'] as List?) ?? const []) {
      if (x is num) muted.add(x.toInt());
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
  static const _kSaver = 'power_saver';
  static const _kVolPtt = 'vol_ptt';
  static const _kHeadset = 'headset_ptt';
  static const _kToggle = 'toggle_talk';
  static const _kNotifTalk = 'notif_talk';
  static const _kUrgent = 'urgent_loud';
  static const _kFriends = 'friends';
  static const _kSocial = 'social';

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
    final names = <int, ChannelName>{};
    final admins = <int, int>{};
    final announce = <int>{};
    final muted = <int>{};
    final blocked = <int, String>{};
    AppSettings.decodeSocial(
      prefs?.getString(_kSocial),
      names: names,
      admins: admins,
      announce: announce,
      muted: muted,
      blocked: blocked,
    );
    return AppSettings(
      nodeId: id,
      friends: Friend.decodeList(prefs?.getString(_kFriends)),
      channelNames: names,
      channelAdmins: admins,
      announceScopes: announce,
      muted: muted,
      blocked: blocked,
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
      powerSaver: prefs?.getBool(_kSaver) ?? false,
      volumeKeyPtt: prefs?.getBool(_kVolPtt) ?? false,
      headsetPtt: prefs?.getBool(_kHeadset) ?? false,
      toggleTalk: prefs?.getBool(_kToggle) ?? false,
      notificationTalk: prefs?.getBool(_kNotifTalk) ?? false,
      urgentLoud: prefs?.getBool(_kUrgent) ?? true,
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
      await prefs.setBool(_kSaver, s.powerSaver);
      await prefs.setBool(_kVolPtt, s.volumeKeyPtt);
      await prefs.setBool(_kHeadset, s.headsetPtt);
      await prefs.setBool(_kToggle, s.toggleTalk);
      await prefs.setBool(_kNotifTalk, s.notificationTalk);
      await prefs.setBool(_kUrgent, s.urgentLoud);
      await prefs.setString(
        _kVolumes,
        AppSettings.encodeVolumes(s.peerVolumes),
      );
      await prefs.setString(_kFriends, Friend.encodeList(s.friends));
      await prefs.setString(_kSocial, AppSettings.encodeSocial(s));
      await prefs.setString(
        _kPrivate,
        AppSettings.encodePrivate(s.privateChannels),
      );
    } catch (_) {}
  }
}
