/// Debug-only sample speeds for screenshots (v2.6.16).
///
/// Off unless the app is a debug build AND it was started with
/// `--dart-define=SAMPLE_SPEED=true`. A release build stays off even if
/// that flag is set. The dots are made-up. Nothing is requested from GPS
/// or a radio.
library;

import 'package:flutter/foundation.dart';

import '../weather/wx_areas.dart';
import 'geo.dart';

/// Compile-time flag. Default false, so a normal debug run does not
/// invent speeds.
const bool kSampleSpeedDefine = bool.fromEnvironment('SAMPLE_SPEED');

/// True only for a debug process that was asked for sample speeds.
bool sampleSpeedActive({
  bool debug = kDebugMode,
  bool enabled = kSampleSpeedDefine,
}) => debug && enabled;

/// A made-up app user near downtown Portland, with a fresh speed.
const int sampleSpeedFriendId = 0x51EED;
const String sampleSpeedFriendName = 'Yeti';

/// Southwest of the sample weather friend so the two dots do not stack.
const GeoPoint sampleSpeedFriendPoint = GeoPoint(45.4200, -122.7800);

/// 42 mph, using the same miles factor as [formatSpeed].
const double sampleSpeedFriendMps = 42 / 2.23694;

/// A made-up radio north of the sample Oregon counties, so it sits
/// outside those weather areas. ground_speed 68 km/h is 42 mph.
const int sampleRadioNodeNum = 0x5A010;
const String sampleRadioName = 'Ridge';
const GeoPoint sampleRadioPoint = GeoPoint(45.95, -122.40);
const int sampleRadioKmh = 68;

/// Wide enough that the friend, the radio and the three sample counties
/// can share one view.
const GeoPoint sampleSpeedView = GeoPoint(45.74, -122.53);
const double sampleSpeedZoom = 8.2;

WxNodeSpot sampleRadioSpot(DateTime now) => WxNodeSpot(
  id: sampleRadioNodeNum,
  name: sampleRadioName,
  pos: sampleRadioPoint,
  speedMps: sampleRadioKmh / 3.6,
  posAt: now,
);
