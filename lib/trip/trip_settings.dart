import 'dart:convert';

import 'battery_mode.dart';
import 'geo.dart';
import 'trip_packet.dart';

/// Trip tab settings (saved as one JSON value).
class TripSettings {
  TripSettings({
    this.tripMode = false,
    this.checkInMinutes = 5,
    this.lostContactMinutes = 20,
    this.imperial = true,
    this.mapSource = 'topo',
    this.customTileUrl = '',
    List<String>? canned,
    this.baseCamp = false,
    this.radioCheckIns = true,
    this.radioTrailMinutes = 15,
    this.packsOffered = false,
    List<String>? overlays,
    this.driveVoice = true,
    this.trailVoice = false,
    this.locationSource = 'auto',
    this.mapCacheMb = 500,
    this.warmHome = true,
    this.batteryMode = BatteryMode.normal,
    this.batterySnapshot,
    this.showMySpeed = false,
  }) : overlays = overlays ?? [],
       canned = canned ?? List.of(defaultCustomCanned);

  /// Share my location with the channel and watch for lost contact.
  bool tripMode;

  /// Quiet check-in every N minutes while in trip mode (0 = off).
  int checkInMinutes;

  /// Warn when someone is silent this long (0 = off).
  int lostContactMinutes;
  bool imperial;

  /// topo / osm / custom.
  String mapSource;
  String customTileUrl;

  /// My own quick messages (editable).
  List<String> canned;

  /// Base camp: store-and-forward for people out of range (Off-grid).
  bool baseCamp;

  /// Check-ins also go over the LoRa radio to far phones.
  bool radioCheckIns;

  /// While a trail is recorded in trip mode, send a thinned summary of it
  /// over the LoRa radio to far phones every N minutes (0 = off), v1.8.3.
  int radioTrailMinutes;

  /// The "ready-made maps" banner was answered (v1.9.0).
  bool packsOffered;

  /// Map overlays switched on (v1.9.1), e.g. 'ov_land', 'ov_slope'.
  List<String> overlays;

  /// Spoken directions while driving (v1.9.2; the mute button).
  bool driveVoice;

  /// Spoken junctions / off-route on trail navigation (v1.9.2).
  bool trailVoice;

  /// Where "where I am" comes from (v2.6.7): 'auto' (the radio's GPS while
  /// it is good, else the phone's), 'phone' or 'radio'.
  String locationSource;

  /// Map cache limit in MB (v2.6.11): viewed tiles past it are dropped,
  /// least recently used first; saved offline areas never count against
  /// being dropped.
  int mapCacheMb;
  static const mapCacheChoices = [250, 500, 1000, 2000];

  /// Keep the map around home on the phone, on Wi-Fi or while charging
  /// only (v2.6.11).
  bool warmHome;

  /// Battery mode (v2.6.12): Saver / Normal / Tracking.
  BatteryMode batteryMode;

  /// Your own values of the settings the mode controls, saved when leaving
  /// Normal (null in Normal).
  BatterySnapshot? batterySnapshot;

  /// A small speed under my own blue dot (v2.6.16). Off until asked.
  bool showMySpeed;
  static const radioTrailChoices = [0, 5, 10, 15];

  static const defaultCustomCanned = ['Lunch spot', 'Going ahead', 'Found it'];
  static const checkInChoices = [0, 2, 5, 10, 15, 30];
  static const lostChoices = [0, 10, 20, 30, 45, 60];

  String encode() => jsonEncode({
    'tm': tripMode,
    'ci': checkInMinutes,
    'lc': lostContactMinutes,
    'imp': imperial,
    'map': mapSource,
    'url': customTileUrl,
    'cn': canned,
    'bc': baseCamp,
    'rci': radioCheckIns,
    'rtm': radioTrailMinutes,
    'po': packsOffered,
    if (overlays.isNotEmpty) 'ov': overlays,
    if (!driveVoice) 'dv': false,
    if (trailVoice) 'tv': true,
    if (locationSource != 'auto') 'ls': locationSource,
    if (mapCacheMb != 500) 'mc': mapCacheMb,
    if (!warmHome) 'wh': false,
    if (batteryMode != BatteryMode.normal) 'bm': batteryMode.id,
    if (batterySnapshot != null) 'bs': batterySnapshot!.toJson(),
    if (showMySpeed) 'sms': true,
  });

  static TripSettings decode(String? s) {
    if (s == null || s.isEmpty) return TripSettings();
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return TripSettings(
        tripMode: j['tm'] == true,
        checkInMinutes: (j['ci'] as num?)?.toInt() ?? 5,
        lostContactMinutes: (j['lc'] as num?)?.toInt() ?? 20,
        imperial: j['imp'] != false,
        mapSource: (j['map'] as String?) ?? 'topo',
        customTileUrl: (j['url'] as String?) ?? '',
        canned: [
          for (final x in (j['cn'] as List?) ?? defaultCustomCanned)
            if (x is String && x.trim().isNotEmpty) x,
        ],
        baseCamp: j['bc'] == true,
        radioCheckIns: j['rci'] != false,
        radioTrailMinutes: switch ((j['rtm'] as num?)?.toInt()) {
          final v? when radioTrailChoices.contains(v) => v,
          _ => 15,
        },
        packsOffered: j['po'] == true,
        overlays: [
          for (final o in (j['ov'] as List? ?? const []))
            if (o is String) o,
        ],
        driveVoice: j['dv'] != false,
        trailVoice: j['tv'] == true,
        locationSource: switch (j['ls']) {
          'phone' => 'phone',
          'radio' => 'radio',
          _ => 'auto',
        },
        mapCacheMb: switch ((j['mc'] as num?)?.toInt()) {
          final v? when mapCacheChoices.contains(v) => v,
          _ => 500,
        },
        warmHome: j['wh'] != false,
        batteryMode: BatteryMode.fromId(j['bm']),
        batterySnapshot: BatterySnapshot.fromJson(j['bs']),
        showMySpeed: j['sms'] == true,
      );
    } catch (_) {
      return TripSettings();
    }
  }
}

/// A shared map pin.
class MapPin {
  MapPin({
    required this.origin,
    required this.pinId,
    required this.type,
    required this.pos,
    required this.label,
    required this.at,
  });
  final int origin;
  final int pinId;
  PinType type;
  GeoPoint pos;
  String label;
  DateTime at;

  String get key => '$origin:$pinId';
  String get title => label.isNotEmpty ? label : type.label;

  Map<String, Object?> toJson() => {
    'o': origin,
    'i': pinId,
    't': type.code,
    'la': pos.latE5,
    'lo': pos.lngE5,
    'l': label,
    'at': at.millisecondsSinceEpoch,
  };

  static MapPin? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return MapPin(
        origin: (j['o'] as num).toInt(),
        pinId: (j['i'] as num).toInt(),
        type: PinType.fromCode((j['t'] as num).toInt()),
        pos: GeoPoint.fromE5(
          (j['la'] as num).toInt(),
          (j['lo'] as num).toInt(),
        ),
        label: (j['l'] as String?) ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }
}
