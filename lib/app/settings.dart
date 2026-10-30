import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/link_policy.dart';
import '../friends/friend_links.dart';
import '../trip/trip_settings.dart';
import 'call_signs.dart';
import 'groups.dart';
import 'mesh_links.dart';
import 'quiet.dart';

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
    this.setupDone = false,
    this.setupPromptShown = false,
    this.newInstall = false,
    this.showDiagnostics = false,
    this.powerSaver = false,
    this.connectionSpeed = ConnectionSpeed.maxSpeed,
    this.offlineSaver = false,
    this.volumeKeyPtt = false,
    this.headsetPtt = false,
    this.toggleTalk = false,
    this.autoPlay = true,
    this.relayForOthers = true,
    this.showInWhosWhere = true,
    this.readReceipts = true,
    this.wifiDirect = true,
    this.notificationTalk = false,
    this.urgentLoud = true,
    this.wxAlerts = true,
    this.wxWifiOnly = false,
    this.wxExtremeSound = false,
    this.wxShare = true,
    Map<String, String>? wxTrusted,
    this.radioBackup,
    this.joinAlertPrivate = true,
    this.joinAlertPublic = false,
    this.shareRadio = true,
    QuietHours? quiet,
    this.radioId,
    this.radioName,
    TripSettings? trip,
    List<PrivateGroup>? groups,
    this.activeGroup,
    Map<int, String>? legacyPrivate,
    Map<int, double>? peerVolumes,
    List<Friend>? friends,
    Map<int, ChannelName>? channelNames,
    Map<int, int>? channelAdmins,
    Set<int>? announceScopes,
    Set<int>? muted,
    Map<int, String>? blocked,
    Map<int, MeshLink>? meshLinks,
  }) : quiet = quiet ?? QuietHours(),
       trip = trip ?? TripSettings(),
       groups = groups ?? PrivateGroup.migrate(legacyPrivate ?? const {}),
       peerVolumes = peerVolumes ?? {},
       friends = friends ?? [],
       wxTrusted = wxTrusted ?? {},
       channelNames = channelNames ?? {},
       channelAdmins = channelAdmins ?? {},
       announceScopes = announceScopes ?? {},
       muted = muted ?? {},
       blocked = blocked ?? {},
       meshLinks = meshLinks ?? {} {
    // v1.1.x prefilled the name box with "Phone 38EA", so pressing Save
    // stored it as if typed. Treat that as "never customized".
    if (customName != null &&
        customName!.trim() == legacyDefaultNameFor(nodeId)) {
      customName = null;
    }
    // v2.3.0: the old settings had the current channel number and, if it
    // was a private group, its passcode. The number is an open channel
    // now; the group is "CH n group" and stays the one we are in.
    final lp = legacyPrivate;
    if (groups == null && lp != null && lp.containsKey(channel)) {
      activeGroup ??= GroupIds.legacy(channel);
      // Leaving the group lands on CH 1, not on the open channel that
      // happens to share the old number (nobody should end up talking in
      // the open by accident).
      channel = 1;
    }
    final ag = activeGroup;
    if (ag != null && groupById(ag) == null) activeGroup = null;
  }

  /// Generated once on first launch, never changes.
  final int nodeId;

  /// v1.9.4: a short tone + notice when someone joins a private channel
  /// I am on (default on) / an open channel (default off).
  bool joinAlertPrivate;
  bool joinAlertPublic;

  /// v1.9.5: share my paired LoRa radio as a gateway with phones on the
  /// internet in my channel (default on).
  bool shareRadio;

  /// v1.9.5: mute (hold to mute) and programmable quiet hours.
  final QuietHours quiet;

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

  /// First-run setup wizard finished or skipped (v1.8.7).
  bool setupDone;

  /// Existing users (updated from an older version): the one-time
  /// "Run setup check" prompt was shown (v1.8.7).
  bool setupPromptShown;

  /// This launch created the phone id: a fresh install (not saved).
  final bool newInstall;

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

  /// v1.9.8: "Max speed (more battery)" (default) or "Balanced": how often
  /// connections are checked and how fast a failing one is replaced.
  ConnectionSpeed connectionSpeed;

  /// Offline power save (v1.8.1): no internet relay, no network sweeps,
  /// slow Bluetooth / GPS / announcements, dim dark UI. Talk, receive,
  /// mesh relay, LoRa, SOS and quick messages keep working.
  bool offlineSaver;

  /// Hold volume-down to talk (app open; background with the optional
  /// accessibility service).
  bool volumeKeyPtt;

  /// Bluetooth / wired headset play-pause button talks (while listening).
  bool headsetPtt;

  /// Tap the talk button to start, tap again to stop.
  bool toggleTalk;

  /// Incoming live talk plays by itself. Off: nothing plays unless tapped
  /// (talk is kept in Missed; voice messages never auto-play anyway).
  bool autoPlay;

  /// Pass other phones' packets on when there is no internet (mesh relay,
  /// v1.6.0). Uses some extra battery while relaying.
  bool relayForOthers;

  /// "Show me in Who's where" (v1.8.2): send lobby beacons so phones on
  /// other channels see this one. A private channel is never revealed
  /// either way (only "Private" and the call sign).
  bool showInWhosWhere;

  /// Send read receipts ("seen") for chats and voice messages (v1.8.3).
  bool readReceipts;

  /// Android: form a Wi-Fi Direct group with nearby app phones when there
  /// is no shared network.
  bool wifiDirect;

  /// "Talk" button on the listening notification (lock screen).
  bool notificationTalk;

  /// Urgent rings play at alarm volume, even in silent mode.
  bool urgentLoud;

  /// Weather alerts from the National Weather Service (v2.5.0): on / off.
  bool wxAlerts;

  /// Check for weather alerts on Wi-Fi only.
  bool wxWifiOnly;

  /// Tornado Warnings and other Extreme alerts may sound during quiet hours
  /// and Do Not Disturb. Off: they follow both (still shown on the lock
  /// screen).
  bool wxExtremeSound;

  /// Share the alerts this device reads from the NWS with other phones
  /// (relay rooms and the radio), v2.5.2. Receiving needs only [wxAlerts].
  bool wxShare;

  /// Devices whose weather alerts are trusted anywhere (v2.5.2): the key
  /// id (what the friend's phone shows) -> the name it had when trusted.
  final Map<String, String> wxTrusted;

  /// The paired radio's settings as they were before the last change on
  /// Radio settings (v2.5.3), for "Restore previous settings". JSON, see
  /// RadioBackup; null = nothing saved.
  String? radioBackup;

  /// Paired Meshtastic LoRa radio (Bluetooth id / name), v1.7.0.
  String? radioId;
  String? radioName;

  /// Trip tab settings (v1.8.0).
  final TripSettings trip;

  /// Private groups (v2.3.0). CH 1-16 are open only; a group has its own
  /// id, name, colour and secret and no channel number.
  final List<PrivateGroup> groups;

  /// Group we are in now (id), or null when on the open [channel].
  String? activeGroup;

  PrivateGroup? groupById(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// The group we are in, or null on an open channel.
  PrivateGroup? get currentGroup {
    final id = activeGroup;
    return id == null ? null : groupById(id);
  }

  /// Groups we joined (not just invited to).
  List<PrivateGroup> get joinedGroups => [
    for (final g in groups)
      if (!g.invited) g,
  ];

  /// Group with the same key as [g] that we already have, or null.
  PrivateGroup? groupLike(PrivateGroup g) {
    for (final o in groups) {
      if (o.sameKeyAs(g)) return o;
    }
    return null;
  }

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

  /// Open Walkie channels shared with a Meshtastic channel (v1.9.7).
  final Map<int, MeshLink> meshLinks;

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

Map<String, String> _decodeTrusted(String? s) {
  if (s == null || s.isEmpty) return {};
  try {
    final j = jsonDecode(s);
    if (j is! Map) return {};
    return {
      for (final e in j.entries)
        if (e.value is String) '${e.key}': e.value as String,
    };
  } catch (_) {
    return {};
  }
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
  static const _kSetupDone = 'setup_done';
  static const _kSetupPrompt = 'setup_prompt_shown';
  static const _kPrivate = 'private_channels';
  static const _kGroups = 'private_groups';
  static const _kActiveGroup = 'active_group';
  static const _kDiag = 'show_diagnostics';
  static const _kVolumes = 'peer_volumes';
  static const _kSaver = 'power_saver';
  static const _kSpeed = 'connection_speed';
  static const _kOffline = 'offline_saver';
  static const _kVolPtt = 'vol_ptt';
  static const _kHeadset = 'headset_ptt';
  static const _kToggle = 'toggle_talk';
  static const _kAutoPlay = 'auto_play';
  static const _kRelayOthers = 'relay_for_others';
  static const _kWhosWhere = 'show_whos_where';
  static const _kReadReceipts = 'read_receipts';
  static const _kWifiDirect = 'wifi_direct';
  static const _kNotifTalk = 'notif_talk';
  static const _kUrgent = 'urgent_loud';
  static const _kWxAlerts = 'wx_alerts';
  static const _kWxWifi = 'wx_wifi_only';
  static const _kWxExtreme = 'wx_extreme_sound';
  static const _kWxShare = 'wx_share';
  static const _kWxTrusted = 'wx_trusted';
  static const _kRadioBackup = 'radio_backup';
  static const _kJoinPrivate = 'join_alert_private';
  static const _kJoinPublic = 'join_alert_public';
  static const _kShareRadio = 'share_radio';
  static const _kQuiet = 'quiet_hours';
  static const _kFriends = 'friends';
  static const _kSocial = 'social';
  static const _kRadioId = 'lora_radio_id';
  static const _kRadioName = 'lora_radio_name';
  static const _kTrip = 'trip_settings';
  static const _kMeshLinks = 'mesh_links';

  @override
  Future<AppSettings> load({required int defaultChannel}) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    var id = prefs?.getInt(_kId);
    final fresh = prefs != null && (id == null || id <= 0);
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
      setupDone: prefs?.getBool(_kSetupDone) ?? false,
      setupPromptShown: prefs?.getBool(_kSetupPrompt) ?? false,
      newInstall: fresh,
      // v2.3.0: groups. Phones coming from an older version only have the
      // old "channel -> passcode" map: it is converted once.
      groups: prefs?.containsKey(_kGroups) == true
          ? PrivateGroup.decodeList(prefs?.getString(_kGroups))
          : null,
      activeGroup: prefs?.getString(_kActiveGroup),
      legacyPrivate: AppSettings.decodePrivate(prefs?.getString(_kPrivate)),
      showDiagnostics: prefs?.getBool(_kDiag) ?? false,
      peerVolumes: AppSettings.decodeVolumes(prefs?.getString(_kVolumes)),
      powerSaver: prefs?.getBool(_kSaver) ?? false,
      connectionSpeed: prefs?.getString(_kSpeed) == 'balanced'
          ? ConnectionSpeed.balanced
          : ConnectionSpeed.maxSpeed,
      offlineSaver: prefs?.getBool(_kOffline) ?? false,
      volumeKeyPtt: prefs?.getBool(_kVolPtt) ?? false,
      headsetPtt: prefs?.getBool(_kHeadset) ?? false,
      toggleTalk: prefs?.getBool(_kToggle) ?? false,
      autoPlay: prefs?.getBool(_kAutoPlay) ?? true,
      relayForOthers: prefs?.getBool(_kRelayOthers) ?? true,
      showInWhosWhere: prefs?.getBool(_kWhosWhere) ?? true,
      readReceipts: prefs?.getBool(_kReadReceipts) ?? true,
      wifiDirect: prefs?.getBool(_kWifiDirect) ?? true,
      notificationTalk: prefs?.getBool(_kNotifTalk) ?? false,
      urgentLoud: prefs?.getBool(_kUrgent) ?? true,
      wxAlerts: prefs?.getBool(_kWxAlerts) ?? true,
      wxWifiOnly: prefs?.getBool(_kWxWifi) ?? false,
      wxExtremeSound: prefs?.getBool(_kWxExtreme) ?? false,
      wxShare: prefs?.getBool(_kWxShare) ?? true,
      wxTrusted: _decodeTrusted(prefs?.getString(_kWxTrusted)),
      radioBackup: prefs?.getString(_kRadioBackup),
      joinAlertPrivate: prefs?.getBool(_kJoinPrivate) ?? true,
      joinAlertPublic: prefs?.getBool(_kJoinPublic) ?? false,
      shareRadio: prefs?.getBool(_kShareRadio) ?? true,
      quiet: QuietHours.decode(prefs?.getString(_kQuiet)),
      radioId: prefs?.getString(_kRadioId),
      radioName: prefs?.getString(_kRadioName),
      trip: TripSettings.decode(prefs?.getString(_kTrip)),
      meshLinks: MeshLink.decodeMap(prefs?.getString(_kMeshLinks)),
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
      await prefs.setBool(_kSetupDone, s.setupDone);
      await prefs.setBool(_kSetupPrompt, s.setupPromptShown);
      await prefs.setBool(_kDiag, s.showDiagnostics);
      await prefs.setBool(_kSaver, s.powerSaver);
      await prefs.setString(_kSpeed, s.connectionSpeed.name);
      await prefs.setBool(_kOffline, s.offlineSaver);
      await prefs.setBool(_kVolPtt, s.volumeKeyPtt);
      await prefs.setBool(_kHeadset, s.headsetPtt);
      await prefs.setBool(_kToggle, s.toggleTalk);
      await prefs.setBool(_kAutoPlay, s.autoPlay);
      await prefs.setBool(_kRelayOthers, s.relayForOthers);
      await prefs.setBool(_kWhosWhere, s.showInWhosWhere);
      await prefs.setBool(_kReadReceipts, s.readReceipts);
      await prefs.setBool(_kWifiDirect, s.wifiDirect);
      await prefs.setBool(_kNotifTalk, s.notificationTalk);
      await prefs.setBool(_kUrgent, s.urgentLoud);
      await prefs.setBool(_kWxAlerts, s.wxAlerts);
      await prefs.setBool(_kWxWifi, s.wxWifiOnly);
      await prefs.setBool(_kWxExtreme, s.wxExtremeSound);
      await prefs.setBool(_kWxShare, s.wxShare);
      await prefs.setString(_kWxTrusted, jsonEncode(s.wxTrusted));
      if (s.radioBackup == null) {
        await prefs.remove(_kRadioBackup);
      } else {
        await prefs.setString(_kRadioBackup, s.radioBackup!);
      }
      await prefs.setBool(_kJoinPrivate, s.joinAlertPrivate);
      await prefs.setBool(_kJoinPublic, s.joinAlertPublic);
      await prefs.setBool(_kShareRadio, s.shareRadio);
      await prefs.setString(_kQuiet, s.quiet.encode());
      if (s.radioId == null) {
        await prefs.remove(_kRadioId);
        await prefs.remove(_kRadioName);
      } else {
        await prefs.setString(_kRadioId, s.radioId!);
        await prefs.setString(_kRadioName, s.radioName ?? '');
      }
      await prefs.setString(
        _kVolumes,
        AppSettings.encodeVolumes(s.peerVolumes),
      );
      await prefs.setString(_kFriends, Friend.encodeList(s.friends));
      await prefs.setString(_kTrip, s.trip.encode());
      await prefs.setString(_kMeshLinks, MeshLink.encodeMap(s.meshLinks));
      await prefs.setString(_kSocial, AppSettings.encodeSocial(s));
      await prefs.setString(_kGroups, PrivateGroup.encodeList(s.groups));
      final ag = s.activeGroup;
      if (ag == null) {
        await prefs.remove(_kActiveGroup);
      } else {
        await prefs.setString(_kActiveGroup, ag);
      }
      // Also the old key (groups that have a channel number), so going
      // back to an older app keeps them.
      await prefs.setString(
        _kPrivate,
        AppSettings.encodePrivate(PrivateGroup.toLegacyMap(s.groups)),
      );
    } catch (_) {}
  }
}
