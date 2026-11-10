/// Debug-only sample weather for screenshots (v2.6.14).
///
/// Off unless the app is a debug build AND it was started with
/// `--dart-define=SAMPLE_WX=true`. A release build stays off even if
/// that flag is set. The shapes are simplified outlines of real Oregon
/// counties from the National Weather Service zone service. The words
/// are sample text, not a live warning.
library;

import 'package:flutter/foundation.dart';

import '../trip/geo.dart';
import 'wx_alert.dart';
import 'wx_geom.dart';

/// Compile-time flag. Default false, so a normal debug run does not
/// invent warnings.
const bool kSampleWxDefine = bool.fromEnvironment('SAMPLE_WX');

/// True only for a debug process that was asked for sample weather.
bool sampleWeatherActive({
  bool debug = kDebugMode,
  bool enabled = kSampleWxDefine,
}) => debug && enabled;

/// A made-up friend standing in downtown Portland, inside Multnomah County.
const int sampleFriendId = 0xC0FFEE;
const GeoPoint sampleFriendPoint = GeoPoint(45.5300, -122.6550);

/// Where the Trip map opens: on the sample friend, wide enough that the
/// three counties around Portland are on screen.
const GeoPoint sampleMapCenter = sampleFriendPoint;
const double sampleMapZoom = 9;

const List<String> sampleAlertKeys = [
  'sample:winter',
  'sample:wind',
  'sample:flood',
];

WxPolygon _ring(List<GeoPoint> pts) => WxPolygon(List.unmodifiable(pts));

final WxPolygon _multnomah = _ring(const [
  GeoPoint(45.7284, -122.7725),
  GeoPoint(45.7282, -122.7626),
  GeoPoint(45.6804, -122.7745),
  GeoPoint(45.6568, -122.7631),
  GeoPoint(45.6180, -122.6750),
  GeoPoint(45.5968, -122.5481),
  GeoPoint(45.5636, -122.4387),
  GeoPoint(45.5759, -122.3803),
  GeoPoint(45.5694, -122.3528),
  GeoPoint(45.5482, -122.3315),
  GeoPoint(45.5435, -122.2954),
  GeoPoint(45.5477, -122.2490),
  GeoPoint(45.5638, -122.2025),
  GeoPoint(45.5776, -122.1838),
  GeoPoint(45.5837, -122.1012),
  GeoPoint(45.6095, -122.0444),
  GeoPoint(45.6228, -121.9830),
  GeoPoint(45.6439, -121.9548),
  GeoPoint(45.6491, -121.9222),
  GeoPoint(45.6104, -121.9216),
  GeoPoint(45.6016, -121.9133),
  GeoPoint(45.5861, -121.9182),
  GeoPoint(45.5565, -121.9024),
  GeoPoint(45.5464, -121.9215),
  GeoPoint(45.5214, -121.9068),
  GeoPoint(45.5126, -121.8895),
  GeoPoint(45.5134, -121.8694),
  GeoPoint(45.4993, -121.8598),
  GeoPoint(45.4923, -121.8627),
  GeoPoint(45.4614, -121.8208),
  GeoPoint(45.4610, -122.6403),
  GeoPoint(45.4576, -122.6599),
  GeoPoint(45.4427, -122.6459),
  GeoPoint(45.4325, -122.6496),
  GeoPoint(45.4340, -122.7438),
  GeoPoint(45.5193, -122.7441),
  GeoPoint(45.5198, -122.7642),
  GeoPoint(45.5336, -122.7657),
  GeoPoint(45.5338, -122.7850),
  GeoPoint(45.5486, -122.7848),
  GeoPoint(45.5491, -122.8056),
  GeoPoint(45.5627, -122.8056),
  GeoPoint(45.5628, -122.8264),
  GeoPoint(45.5776, -122.8267),
  GeoPoint(45.5776, -122.8472),
  GeoPoint(45.5917, -122.8467),
  GeoPoint(45.5921, -122.8672),
  GeoPoint(45.6054, -122.8675),
  GeoPoint(45.6067, -122.8870),
  GeoPoint(45.6206, -122.8881),
  GeoPoint(45.6218, -122.9090),
  GeoPoint(45.6336, -122.9087),
  GeoPoint(45.6361, -122.9291),
  GeoPoint(45.7218, -122.9287),
  GeoPoint(45.7212, -122.7848),
  GeoPoint(45.7286, -122.7821),
]);

final WxPolygon _washington = _ring(const [
  GeoPoint(45.7793, -123.0514),
  GeoPoint(45.7792, -123.0310),
  GeoPoint(45.7515, -123.0319),
  GeoPoint(45.7361, -122.9285),
  GeoPoint(45.6342, -122.9285),
  GeoPoint(45.5193, -122.7441),
  GeoPoint(45.3319, -122.7441),
  GeoPoint(45.3462, -122.8466),
  GeoPoint(45.3178, -122.8466),
  GeoPoint(45.3171, -122.9089),
  GeoPoint(45.3457, -122.9090),
  GeoPoint(45.3465, -122.9700),
  GeoPoint(45.4040, -123.0321),
  GeoPoint(45.4043, -123.1119),
  GeoPoint(45.4333, -123.1384),
  GeoPoint(45.4336, -123.4861),
  GeoPoint(45.4479, -123.4856),
  GeoPoint(45.4481, -123.4638),
  GeoPoint(45.4916, -123.4609),
  GeoPoint(45.4913, -123.4416),
  GeoPoint(45.5209, -123.4425),
  GeoPoint(45.5362, -123.4017),
  GeoPoint(45.5501, -123.4023),
  GeoPoint(45.5499, -123.3618),
  GeoPoint(45.5789, -123.3611),
  GeoPoint(45.5930, -123.2992),
  GeoPoint(45.6073, -123.3012),
  GeoPoint(45.6075, -123.3410),
  GeoPoint(45.6217, -123.3408),
  GeoPoint(45.6366, -123.4221),
  GeoPoint(45.6651, -123.4435),
  GeoPoint(45.6650, -123.4645),
  GeoPoint(45.6795, -123.4644),
  GeoPoint(45.6793, -123.4847),
  GeoPoint(45.7091, -123.4848),
  GeoPoint(45.7088, -123.3609),
  GeoPoint(45.7797, -123.3585),
  GeoPoint(45.7801, -123.1042),
]);

final WxPolygon _clackamas = _ring(const [
  GeoPoint(45.4616, -122.3425),
  GeoPoint(45.4614, -121.8208),
  GeoPoint(45.4542, -121.8071),
  GeoPoint(45.4366, -121.8075),
  GeoPoint(45.4047, -121.7787),
  GeoPoint(45.3813, -121.7035),
  GeoPoint(45.3333, -121.7023),
  GeoPoint(45.2988, -121.6810),
  GeoPoint(45.2601, -121.6972),
  GeoPoint(45.2500, -121.6812),
  GeoPoint(45.2293, -121.6832),
  GeoPoint(45.2301, -121.7015),
  GeoPoint(45.2132, -121.7131),
  GeoPoint(45.2066, -121.7463),
  GeoPoint(45.1934, -121.7488),
  GeoPoint(45.1226, -121.6994),
  GeoPoint(45.1192, -121.6655),
  GeoPoint(45.0856, -121.6528),
  GeoPoint(45.0695, -121.6603),
  GeoPoint(45.0512, -121.7173),
  GeoPoint(45.0375, -121.7204),
  GeoPoint(45.0399, -121.7705),
  GeoPoint(45.0161, -121.7811),
  GeoPoint(45.0122, -121.8047),
  GeoPoint(44.9573, -121.7906),
  GeoPoint(44.9386, -121.7983),
  GeoPoint(44.9395, -121.7600),
  GeoPoint(44.9151, -121.7476),
  GeoPoint(44.9015, -121.7145),
  GeoPoint(44.8878, -121.7346),
  GeoPoint(44.8849, -122.3667),
  GeoPoint(44.8856, -122.3949),
  GeoPoint(44.9031, -122.3986),
  GeoPoint(44.9191, -122.5067),
  GeoPoint(44.9378, -122.5362),
  GeoPoint(44.9838, -122.5694),
  GeoPoint(44.9896, -122.5929),
  GeoPoint(45.0196, -122.5960),
  GeoPoint(45.0578, -122.7024),
  GeoPoint(45.1071, -122.7499),
  GeoPoint(45.1291, -122.7866),
  GeoPoint(45.1626, -122.7744),
  GeoPoint(45.1817, -122.7524),
  GeoPoint(45.2085, -122.7580),
  GeoPoint(45.2164, -122.7455),
  GeoPoint(45.2447, -122.7509),
  GeoPoint(45.2593, -122.7391),
  GeoPoint(45.2596, -122.7849),
  GeoPoint(45.2741, -122.8045),
  GeoPoint(45.2596, -122.8669),
  GeoPoint(45.3166, -122.8680),
  GeoPoint(45.3173, -122.8524),
  GeoPoint(45.3462, -122.8466),
  GeoPoint(45.3453, -122.8057),
  GeoPoint(45.3317, -122.7693),
  GeoPoint(45.3527, -122.7442),
  GeoPoint(45.4333, -122.7409),
  GeoPoint(45.4365, -122.6513),
  GeoPoint(45.4427, -122.6459),
  GeoPoint(45.4537, -122.6586),
  GeoPoint(45.4610, -122.6403),
  GeoPoint(45.4613, -122.3728),
]);

/// Three sample alerts on real county outlines. [now] sets the expiry so
/// the sheet shows a time that is still ahead.
List<WxAlert> sampleOregonAlerts(DateTime now) {
  final issued = now.subtract(const Duration(minutes: 35));
  WxAlert one({
    required String key,
    required String event,
    required WxSeverity severity,
    required String county,
    required WxPolygon area,
    required String headline,
    required String description,
    required String instruction,
  }) => WxAlert(
    key: key,
    event: event,
    severity: severity,
    headline: headline,
    description: description,
    instruction: instruction,
    areaDesc: '$county County, OR',
    issued: issued,
    rev: now.millisecondsSinceEpoch,
    expires: now.add(const Duration(hours: 6)),
    // No zone code: a live NWS check treats its own alerts as the full
    // list for the zones it asked about, and would drop these samples.
    polygons: [area],
    sender: 'NWS Portland OR',
    source: WxSource.nws,
    trust: WxTrust.nws,
  );
  return [
    one(
      key: 'sample:winter',
      event: 'Winter Storm Warning',
      severity: WxSeverity.severe,
      county: 'Multnomah',
      area: _multnomah,
      headline: 'Winter Storm Warning for Multnomah County until this evening',
      description:
          'Snow and ice are expected across Multnomah County, including '
          'Portland. Roads may become slick. This is sample data for the '
          'map, not a live National Weather Service warning.',
      instruction: 'Slow down and leave extra room. Stay home if you can.',
    ),
    one(
      key: 'sample:wind',
      event: 'Wind Advisory',
      severity: WxSeverity.minor,
      county: 'Washington',
      area: _washington,
      headline: 'Wind Advisory for Washington County',
      description:
          'Southwest winds 25 to 35 mph with gusts near 50 mph. Loose '
          'objects may blow around. This is sample data, not a live '
          'advisory.',
      instruction: 'Secure outdoor furniture and watch for falling branches.',
    ),
    one(
      key: 'sample:flood',
      event: 'Flood Watch',
      severity: WxSeverity.moderate,
      county: 'Clackamas',
      area: _clackamas,
      headline: 'Flood Watch for Clackamas County',
      description:
          'Heavy rain may push creeks and low spots over their banks in '
          'Clackamas County. This is sample data, not a live watch.',
      instruction: 'Stay out of flooded roads. Turn around if you meet water.',
    ),
  ];
}

/// Cancels that remove a previous sample load. A later real launch, or
/// Clear samples, uses these so the made-up warnings do not stay.
List<WxAlert> sampleAlertCancels(DateTime now) => [
  for (final key in sampleAlertKeys)
    WxAlert(
      key: key,
      event: 'Sample',
      issued: now,
      rev: now.millisecondsSinceEpoch,
      expires: now.add(const Duration(hours: 1)),
      messageType: 'cancel',
    ),
];
