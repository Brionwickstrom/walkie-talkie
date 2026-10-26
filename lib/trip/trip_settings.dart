import 'dart:convert';

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
  }) : canned = canned ?? List.of(defaultCustomCanned);

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
