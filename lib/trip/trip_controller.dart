import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';

import '../app/conn_probes.dart' show probeInternet;
import '../app/power_plan.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart' show InboundTrip;
import 'friend_motion.dart';
import 'geo.dart';
import 'imagery.dart';
import 'imports/geo_import.dart' show ImportedData, ImportedLine;
import 'imports/map_layers.dart';
import 'imports/route_share.dart';
import 'lost_contact.dart';
import 'drive/drive_nav.dart' show spokenDistance;
import 'drive/drive_session.dart';
import 'drive/online_router.dart';
import 'drive/road_data.dart' show RoadData;
import 'drive/road_download.dart';
import 'drive/road_router.dart';
import 'drive/road_service.dart';
import 'drive/speech.dart';
import 'map_net.dart';
import 'nav/foot_router.dart';
import 'range_logger.dart';
import 'range_test.dart';
import 'nav/gentle_route.dart';
import 'search/trailhead_finder.dart';
import 'slope.dart' show DemSampler;
import 'smart_plan.dart';
import 'imports/geo_import.dart' show ImportedWaypoint;
import 'nav/nav_session.dart';
import 'offline_areas.dart';
import 'route_save.dart';
import 'nav/trail_graph.dart';
import 'search/fetch.dart';
import 'search/map_search.dart';
import 'search/nominatim.dart';
import 'search/offline_search.dart';
import 'search/overpass.dart';
import 'search/rate_limiter.dart';
import 'sos.dart';
import 'store_forward.dart';
import 'tile_cache.dart';
import 'track.dart';
import 'trip_packet.dart';
import 'trip_route.dart';
import 'trip_settings.dart';
import 'weather.dart';

/// A GPS fix.
class Fix {
  const Fix(
    this.pos,
    this.at, {
    this.accuracyM,
    this.speedMps,
    this.altM,
    this.bearingDeg,
  });
  final GeoPoint pos;
  final DateTime at;
  final double? accuracyM;
  final double? speedMps;

  /// Direction of travel in degrees from north (v2.5.6), null = unknown.
  final double? bearingDeg;
  final double? altM;
}

/// Where someone else is.
class PersonPos {
  PersonPos(this.id, this.pos, this.at, this.via, this.hops);
  final int id;
  GeoPoint pos;

  /// When the fix was taken (receive time minus its age).
  DateTime at;
  TransportKind via;
  int hops;
  double? accuracyM;
  bool held = false;

  /// Their speed (m/s) and direction (degrees) in that fix, when they sent
  /// them (v2.5.6); used to move their dot between updates.
  double? speedMps;
  double? headingDeg;
}

/// One line of the Trip feed (quick messages, check-ins, alerts).
class TripEvent {
  TripEvent(this.at, this.origin, this.text, this.kind, {this.via, this.pos});
  final DateTime at;
  final int origin;
  final String text;

  /// canned / sos / ack / lost / found / pin / track / held / info
  final String kind;
  final TransportKind? via;
  final GeoPoint? pos;
}

/// Phone on our channel, as the Trip layer needs it.
class TripPeer {
  const TripPeer(this.id, {this.lastHeard, this.reachable = false});
  final int id;
  final DateTime? lastHeard;
  final bool reachable;
}

/// What the Trip tab needs from the rest of the app (the WalkieController;
/// a fake in tests).
abstract class TripHost {
  int get localId;
  int get scope;
  bool get privateScope;
  String nameOf(int id);
  bool get powerSaver;
  Future<Set<int>> sendTrip(Uint8List payload, TripRoute route);
  Stream<InboundTrip> get trips;

  /// Phones on our channel right now.
  List<TripPeer> channelPeers();
  Future<void> saveTripSettings();

  /// [highAccuracy] false = balanced / network accuracy (v2.2.0): used
  /// while the phone is idle in the background, only to share your place
  /// with friends.
  Future<bool> startLocation(Duration interval, {bool highAccuracy = true});
  Future<void> stopLocation();
  Future<Fix?> locateOnce();
  Future<void> backgroundLocation(bool on);
  void showSosAlarm(IncomingSos s, String text);
  void stopSosAlarm(IncomingSos s);
  void notify(String title, String text);
  void notice(String text);
  Future<bool> shareFile(String path, String mime, String title);
}

/// The Trip tab (v1.8.0): live map positions, SOS, check-ins and
/// lost-contact alerts, quick messages, pins, trails, base camp
/// store-and-forward and the cached forecast. Every message is a tiny
/// [TripMsg] sent over whatever path reaches (fast links first, LoRa only
/// for phones nothing else reaches, and only for small important ones).
class TripController extends ChangeNotifier {
  TripController({
    required this.host,
    required this.settings,
    required this.dir,
    required this.userAgent,
    Clock? clock,
    Fetch? fetch,
    RateLimiter? searchLimiter,
    Future<bool> Function(Duration timeout)? netProbe,
  }) : _clock = clock ?? DateTime.now {
    sos =
        SosManager(
            localId: host.localId,
            send: _send,
            nextId: _nextId,
            clock: _clock,
          )
          ..onAlert = _onSosAlert
          ..onStop = host.stopSosAlarm
          ..onAcked = (from) {
            _event(from, '${host.nameOf(from)} acknowledged your SOS', 'ack');
            host.notice('${host.nameOf(from)} got your SOS');
          }
          ..onChange = notifyListeners;
    lost = LostContactMonitor(clock: _clock)
      ..onLost = _onLost
      ..onFound = (s) =>
          _event(s.id, '${host.nameOf(s.id)} is back in contact', 'found');
    store = StoreForward(clock: _clock)..enabled = settings.baseCamp;
    tiles = TileCache(Directory('${dir.path}/tiles'), userAgent: userAgent);
    // v2.1.0: one view of "does the internet work right now" for tiles,
    // search, routing and rerouting.
    mapNet = MapNet(
      probe: netProbe ?? ((t) async => (await probeInternet(timeout: t)).ok),
      clock: _clock,
    );
    tiles.onNet = (ok) => ok ? mapNet.ok() : mapNet.fail();
    mapNet.addListener(_onNetChanged);
    _routeLimiter =
        searchLimiter ?? RateLimiter(const Duration(milliseconds: 1100));
    layers = MapLayers(Directory('${dir.path}/layers'), clock: _clock);
    areas = OfflineAreas(
      File('${dir.path}/offline_areas.json'),
      tiles: tiles,
      layers: layers,
      clock: _clock,
    );
    routes = SavedRoutes(File('${dir.path}/saved_routes.json'));
    areas.routeFor = routes.byId;
    weather = WeatherCache(
      File('${dir.path}/weather.json'),
      userAgent: userAgent,
    );
    final inner = fetch ?? ioFetch(userAgent);
    // Every map request tells the network check how it went.
    final f = this.fetch = (FetchRequest r) async {
      try {
        final b = await inner(r);
        mapNet.ok();
        return b;
      } on NoSignalException {
        mapNet.fail();
        rethrow;
      } on FetchException {
        mapNet.ok(); // the server answered
        rethrow;
      }
    };
    search = MapSearch(
      fetch: f,
      // Tests pass an instant limiter; the app shares the polite ones.
      nominatim: NominatimClient(fetch: f, limiter: searchLimiter),
      overpass: OverpassClient(fetch: f, limiter: searchLimiter),
      canUseNetwork: () {
        if (_offline) {
          return 'Offline power save is on, so online map search is off. '
              'Offline search below.';
        }
        if (!tiles.online) return noSignalMessage;
        if (mapNet.isOffline && !mapNet.allowOnline) return noSignalMessage;
        return null;
      },
    );
    _applySettings();
  }

  final TripHost host;
  final TripSettings settings;
  final Directory dir;
  final String userAgent;
  final Clock _clock;

  late final SosManager sos;
  late final LostContactMonitor lost;
  late final StoreForward store;
  late final TileCache tiles;

  /// Online / weak / offline, for every map feature (v2.1.0).
  late final MapNet mapNet;
  late final RateLimiter _routeLimiter;

  /// Imported trails, offline MBTiles maps and park map overlays (v1.8.3).
  late final MapLayers layers;

  /// Range test connect / drop markers (v2.5.9), local to this device.
  late final RangeTest range = RangeTest(File('${dir.path}/range_test.json'));

  /// Range logging on this phone (v2.5.9): off until switched on.
  late final RangeLogger rangeLog = RangeLogger(
    store: range,
    fix: () => myFix,
    plugged: () => _pluggedIn,
  );
  bool _rangeLoggingSeen = false;

  void _rangeChanged() {
    if (range.logging == _rangeLoggingSeen) return;
    _rangeLoggingSeen = range.logging;
    unawaited(_updateLocationNeed());
  }

  /// GPS interval while range logging is on and nothing else asks for a
  /// faster one (one fix every 10 s, high accuracy).
  static const rangeGpsInterval = Duration(seconds: 10);

  /// Saved offline areas (v1.9.3): map tiles, trails and roads together.
  late final OfflineAreas areas;

  /// Routes saved with "Save route for offline" (v2.2.0), one per area.
  late final SavedRoutes routes;
  final RouteAssembler _routes = RouteAssembler();

  /// The newest route someone shared being stored (tests wait on it).
  Future<MapLayer>? lastSharedRoute;
  late final WeatherCache weather;

  /// Online "Find maps" (Nominatim + Overpass), v1.8.4.
  late final MapSearch search;

  /// HTTP for map search and saving roads.
  late final Fetch fetch;
  final TrackRecorder recorder = TrackRecorder();
  final TrackAssembler _assembler = TrackAssembler();

  Fix? myFix;

  /// Compass heading (degrees from magnetic north), null if unknown.
  double? heading;
  final Map<int, PersonPos> people = {};
  final Map<String, MapPin> _pins = {};
  final List<Track> savedTracks = [];

  /// Other people's shared trails: key origin:trackId.
  final Map<String, ({int origin, List<TrackPt> points, bool summary})>
  sharedTracks = {};
  final List<TripEvent> feed = [];
  final Map<int, DateTime> _members = {};
  final Set<int> _reachable = {};
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  StreamSubscription<InboundTrip>? _sub;
  Timer? _timer;
  int _id = DateTime.now().millisecondsSinceEpoch & 0xFFFF;
  bool _visible = false;
  bool _started = false;
  DateTime? _lastLiveSent;
  GeoPoint? _lastLivePos;
  DateTime? _lastCheckIn;
  Duration? _locInterval;
  bool _bgLoc = false;
  int _ticks = 0;
  DateTime? _weatherTried;

  /// Year of the NAIP photos at a place (asked rarely, see PhotoDateLine).
  /// Photo year of the Satellite style (not final so tests can swap it).
  NaipYears photoYears = NaipYears();

  List<MapPin> get pins =>
      _pins.values.toList()..sort((a, b) => a.at.compareTo(b.at));

  MapSource get mapSource => switch (settings.mapSource) {
    'custom' when settings.customTileUrl.trim().isNotEmpty => MapSource.custom(
      settings.customTileUrl.trim(),
    ),
    final id =>
      MapSource.bases.where((s) => s.id == id).firstOrNull ?? MapSource.topo,
  };

  /// Overlays switched on (v1.9.1), in drawing order.
  List<MapSource> get overlays => [
    for (final o in MapSource.overlays)
      if (settings.overlays.contains(o.id)) o,
  ];

  /// Selected offline MBTiles base map (`mbtiles:<layer id>`), if any.
  MapLayer? get baseTiles {
    final s = settings.mapSource;
    if (!s.startsWith('mbtiles:')) return null;
    final l = layers.byId(s.substring(8));
    return l != null && l.kind == MapLayerKind.tiles ? l : null;
  }

  int _nextId() => _id = (_id + 1) & 0xFFFF;

  void _applySettings() {
    lost
      ..enabled = settings.tripMode && settings.lostContactMinutes > 0
      ..threshold = Duration(
        minutes: settings.lostContactMinutes <= 0
            ? 20
            : settings.lostContactMinutes,
      );
    store.enabled = settings.baseCamp;
  }

  // ------------------------------------------------------------ lifecycle

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _sub = host.trips.listen(onTrip);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    await Future.wait([
      tiles.load(),
      weather.load(),
      _loadPins(),
      _loadTracks(),
      layers.load(),
      range.load(),
    ]);
    _rangeLoggingSeen = range.logging;
    range.addListener(_rangeChanged);
    await routes.load();
    await areas.load();
    await routes.prune({for (final a in areas.areas) a.id});
    await _restoreDrive();
    unawaited(tiles.trim());
    await _updateLocationNeed();
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    nav?.dispose();
    nav = null;
    drive?.dispose();
    drive = null;
    roads.dispose();
    unawaited(speaker.stop());
    _sub?.cancel();
    _timer?.cancel();
    mapNet.removeListener(_onNetChanged);
    mapNet.dispose();
    tiles.close();
    layers.close();
    range.removeListener(_rangeChanged);
    rangeLog.dispose();
    range.dispose();
    super.dispose();
  }

  /// The Trip tab is on screen (compass, faster fixes, weather refresh).
  void setVisible(bool v) {
    if (_visible == v) return;
    _visible = v;
    unawaited(_updateLocationNeed());
    if (v) unawaited(maybeRefreshWeather());
  }

  bool get visible => _visible;

  /// v2.0.0: the app is on screen. The Trip tab only counts as visible
  /// (fast GPS fixes, compass) while it is: a phone left on the Trip tab
  /// with the screen off no longer polls GPS every 5 s. Trip mode,
  /// recording, navigation, driving and SOS keep their own GPS needs.
  bool get appForeground => _appForeground;
  bool _appForeground = true;

  void setAppForeground(bool on) {
    if (_appForeground == on) return;
    _appForeground = on;
    unawaited(_updateLocationNeed());
    if (on && _visible) unawaited(maybeRefreshWeather());
  }

  /// The Trip tab is on screen and so is the app.
  bool get _onScreen => _visible && _appForeground;

  /// Offline power save (v1.8.1): slower GPS and check-ins, no live
  /// position updates, no map / weather downloads. SOS stays at full
  /// speed and priority; quick messages, pins and check-ins still go out.
  bool get offlineSaver => _offline;
  bool _offline = false;
  PowerPlan get plan => PowerPlan(saver: host.powerSaver, offline: _offline);

  Future<void> setOfflineSaver(bool on) async {
    if (on == _offline) return;
    _offline = on;
    tiles.online = plan.mapTileDownloads;
    await _updateLocationNeed();
    notifyListeners();
  }

  /// Check-in period in use (offline: slower, see [PowerPlan]).
  int get checkInMinutesNow => plan.checkInMinutes(settings.checkInMinutes);

  /// Battery saver switched (re-pick the GPS interval).
  Future<void> onPowerChanged() => _updateLocationNeed();

  bool get _needLocation =>
      settings.tripMode ||
      recorder.recording ||
      sos.active != null ||
      _onScreen ||
      nav != null ||
      drive != null ||
      range.logging;

  Duration get _wantedInterval {
    var base = _baseInterval;
    if (range.logging && base > rangeGpsInterval) base = rangeGpsInterval;
    return drivingMode && base > drivingGpsInterval ? drivingGpsInterval : base;
  }

  Duration get _baseInterval {
    final now = _clock();
    final p = plan;
    if (drive != null) return p.driveInterval;
    if (sos.active != null) return const Duration(seconds: 5);
    if (nav != null) return p.navInterval;
    if (recorder.recording) {
      return recorder.interval(now, saver: p.transportSaver);
    }
    return p.gpsInterval(visible: _onScreen, sosActive: false);
  }

  /// GPS interval asked for right now (tests / debug).
  Duration? get locationInterval => _locInterval;

  /// v2.2.0: high-accuracy GPS is needed right now: navigating, driving,
  /// recording a track, SOS, or the Trip screen on screen. Otherwise (Trip
  /// mode left running in the background) a balanced / network location
  /// with a longer interval is enough to keep friends' maps current.
  bool get _wantHighAccuracy =>
      drivingMode ||
      _onScreen ||
      nav != null ||
      drive != null ||
      recorder.recording ||
      range.logging ||
      sos.active != null;

  /// What the location was last started with (tests / debug).
  bool? get locationHighAccuracy => _locAccurate;
  bool? _locAccurate;

  /// Driving mode as of the last [_updateLocationNeed].
  bool _locDriving = false;

  Future<void> _updateLocationNeed() async {
    if (!_started) return;
    _locDriving = drivingMode;
    if (_needLocation) {
      final want = _wantedInterval;
      final acc = _wantHighAccuracy;
      if (_locInterval != want || _locAccurate != acc) {
        _locInterval = want;
        _locAccurate = acc;
        final ok = await host.startLocation(want, highAccuracy: acc);
        if (!ok) {
          _locInterval = null;
          _locAccurate = null;
        }
      }
    } else if (_locInterval != null) {
      _locInterval = null;
      _locAccurate = null;
      await host.stopLocation();
    }
    final bg =
        settings.tripMode ||
        recorder.recording ||
        sos.active != null ||
        nav != null ||
        drive != null ||
        range.logging;
    if (bg != _bgLoc) {
      _bgLoc = bg;
      await host.backgroundLocation(bg);
    }
  }

  // ------------------------------------------------------------ location

  /// A GPS fix from the phone.
  void onFix(Fix f) {
    if (!f.pos.valid) return;
    myFix = f;
    sos.updatePosition(f.pos, accuracyM: f.accuracyM);
    if (recorder.add(f.pos, f.at, accuracyM: f.accuracyM)) {
      if (recorder.track!.points.length % 20 == 0) unawaited(_saveTracks());
    }
    _noteSpeed(f);
    _maybeSendLive();
    _navFix(f.pos);
    _driveFix(f);
    // Driving mode started or ended (speed, or the 2 minute hold ran out).
    if (drivingMode != _locDriving) unawaited(_updateLocationNeed());
    notifyListeners();
  }

  // ------------------------------------------------------- driving mode

  /// GPS fix interval while Driving mode is on (v2.5.6).
  static const drivingGpsInterval = Duration(seconds: 2);

  /// Driving starts at this speed (m/s, about 13 mph) and is kept this long
  /// after the last fast fix (traffic lights, a short stop).
  static const drivingSpeedMps = 6.0;
  static const drivingHold = Duration(minutes: 2);

  bool _pluggedIn = false;
  DateTime? _movingUntil;
  Fix? _prevFix;

  /// The phone is on a charger (Android: plugged in / charging; Windows:
  /// on AC power).
  bool get pluggedIn => _pluggedIn;

  /// Driving mode (v2.5.6): faster, more precise GPS and live updates while
  /// you are driving, and ONLY while the phone is plugged in or charging.
  /// The moment it is unplugged this is false and everything is as before,
  /// so on battery it costs nothing. Needs Trip mode on (sharing your
  /// place) and is off in Offline power save.
  bool get drivingMode {
    final until = _movingUntil;
    return _pluggedIn &&
        settings.tripMode &&
        !_offline &&
        until != null &&
        _clock().isBefore(until);
  }

  /// Power source changed (called by the app from the phone's plug / unplug
  /// events and its battery reading).
  Future<void> setPluggedIn(bool on) async {
    if (on == _pluggedIn) return;
    _pluggedIn = on;
    rangeLog.powerChanged();
    await _updateLocationNeed();
    notifyListeners();
  }

  /// Fast movement seen in [f]: its own speed, else the speed between this
  /// and the previous fix (phones in balanced mode report no speed).
  void _noteSpeed(Fix f) {
    final prev = _prevFix;
    _prevFix = f;
    var v = f.speedMps;
    if (v == null || !v.isFinite || v < 0) {
      v = null;
      if (prev != null &&
          (f.accuracyM ?? 1000) <= 100 &&
          (prev.accuracyM ?? 1000) <= 100) {
        final dt = f.at.difference(prev.at).inMilliseconds / 1000;
        if (dt >= 1 && dt <= 180) v = distanceM(prev.pos, f.pos) / dt;
      }
    }
    if (v != null && v >= drivingSpeedMps) {
      _movingUntil = _clock().add(drivingHold);
    }
  }

  /// Where to draw a friend's dot now, and how big its circle is (v2.5.6).
  FriendEstimate friendEstimate(PersonPos pp) => estimateFriend(
    pos: pp.pos,
    at: pp.at,
    now: _clock(),
    speedMps: pp.speedMps,
    headingDeg: pp.headingDeg,
    accuracyM: pp.accuracyM,
    held: pp.held,
  );

  // ------------------------------------------------------------ navigation

  /// "Navigate here" in progress (v1.9.1), null when not navigating.
  NavSession? nav;
  final GraphCache _graphs = GraphCache();
  DateTime? _lastReroute;

  /// The trail network from the trail layers on this phone.
  Future<TrailGraph> trailGraph() => _graphs.of(layers);

  /// Start navigating to [to]: along trails when there are any (shortest
  /// path from where you are), else a straight compass line ([compass]
  /// forces that). Works offline; GPS speeds up while navigating.
  Future<NavSession> navigateTo(
    GeoPoint to, {
    String name = 'Destination',
    bool compass = false,
  }) async {
    final me = myFix?.pos ?? (await host.locateOnce())?.pos;
    TrailRoute? r;
    var note = '';
    if (!compass) {
      if (me == null) {
        note = 'Waiting for GPS: showing the straight line.';
      } else {
        final g = await trailGraph();
        r = g.isEmpty ? null : g.route(me, to);
        if (g.isEmpty) {
          note = 'No trails on this phone: straight line (compass).';
        } else if (r == null) {
          note = 'No trail route found: straight line (compass).';
        } else {
          note = await _elevation(r);
        }
      }
    }
    final s = NavSession(target: to, name: name, route: r, note: note);
    if (_disposed) return s;
    nav?.dispose();
    nav = s;
    _saidJunction = null;
    if (drive != null) {
      drive!.dispose();
      drive = null;
    }
    if (settings.trailVoice && r != null && me != null) {
      final first = r.junctions.firstOrNull;
      unawaited(
        _say(
          'Route to $name, ${spokenDistance(r.lengthM, imperial: settings.imperial)}'
          '${first == null ? '' : '. First: ${first.text}'}.',
        ),
      );
    }
    if (me != null) s.update(me);
    await _updateLocationNeed();
    notifyListeners();
    return s;
  }

  Future<String> _elevation(TrailRoute r) async {
    final src = await fillElevation(
      r,
      (z, x, y) => tiles.get(MapSource.terrarium, z, x, y),
    );
    return switch (src) {
      'dem' => '',
      'gpx' when r.source == 'brouter' => '',
      'gpx' => 'Elevation from the GPX file.',
      _ => 'No elevation data here (save the area with Download area).',
    };
  }

  /// Route again from where you are now.
  Future<bool> reroute() async {
    final s = nav;
    final me = myFix?.pos;
    if (s == null || me == null || s.compass) return false;
    _lastReroute = _clock();
    TrailRoute? r;
    if (s.route!.terrainOnly) {
      final g = await _planGentleRoute(
        me,
        s.target,
        s.gentleLimit ?? SlopeLimit.gentle,
      );
      r = g.plan?.route;
    } else {
      // Online first (v2.1.0), else the saved trails. The old route stays
      // when neither works.
      r = (await planWalk(me, s.target)).route;
    }
    if (r == null && !s.savedFallback) {
      // v2.2.0: no new route: carry on with the walk saved for offline.
      final saved = _savedHikeFor(s.target, me);
      if (saved != null && nav == s && !_disposed) {
        s.savedFallback = true;
        s.replaceRoute(saved);
        s.note =
            'No signal for a new route: following your saved walking route. '
            'It switches back to an online route when the signal returns.';
        notifyListeners();
        return true;
      }
    }
    if (r == null || nav != s || _disposed) return false;
    s.savedFallback = false;
    s.replaceRoute(r);
    notifyListeners();
    return true;
  }

  Future<void> stopNav() async {
    nav?.dispose();
    nav = null;
    await _updateLocationNeed();
    notifyListeners();
  }

  double? _saidJunction;

  void _navFix(GeoPoint p) {
    final s = nav;
    if (s == null) return;
    final ev = s.update(p);
    final voice = settings.trailVoice;
    if (ev == 'off') {
      final st = s.state!;
      host.notify(
        'Off route',
        '${formatDistance(st.offM, imperial: settings.imperial)} off the '
            'route to ${s.name}. Head ${cardinal(st.bearingToRoute)} to get back.',
      );
      if (voice) {
        unawaited(
          _say(
            'You are off the route. Head ${cardinalWord(st.bearingToRoute)} to get back.',
          ),
        );
      }
    } else if (ev == 'arrived') {
      host.notify('Arrived', 'You reached ${s.name}.');
      if (voice) unawaited(_say('You have arrived at ${s.name}.'));
    }
    // Spoken junctions (v1.9.2): once, about 40 m before.
    final st = s.state;
    if (voice && st != null && !st.offRoute && st.next != null) {
      final j = st.next!;
      if ((st.nextInM ?? 1e9) <= 45 && _saidJunction != j.alongM) {
        _saidJunction = j.alongM;
        unawaited(
          _say(
            'In ${spokenDistance(st.nextInM!, imperial: settings.imperial)}, '
            '${j.text.isEmpty ? '' : j.text[0].toLowerCase() + j.text.substring(1)}.',
          ),
        );
      }
    }
    // Way off for a while: route again from here (at most every 30 s).
    if (st != null && st.offRoute && st.offM > 60) {
      final last = _lastReroute;
      if (last == null || _clock().difference(last).inSeconds >= 30) {
        unawaited(reroute());
      }
    }
  }

  /// Send the planned route to the group (same as sharing a trail layer).
  ({int parts, bool radio}) shareNavRoute() {
    final s = nav;
    if (s == null) return (parts: 0, radio: false);
    return _shareData(s.asData(), s.asData().name, 0xFFE53935);
  }

  // ------------------------------------------------------------ v2.1.0: smart navigation

  /// The walk was started at the trailhead of a drive-then-hike (the
  /// screen shows it once), or why it could not be.
  TrailheadHandoff? handoff;

  /// Why the last [walkTo] made no route.
  String lastWalkMessage = '';

  static const String nearestRoadName = 'the nearest road';

  bool _netWasDown = false;
  DateTime? _lastUpgrade;

  /// The network check changed: tiles stop waiting for timeouts while it
  /// is down, and a route made from saved data is refreshed online when
  /// the signal comes back.
  void _onNetChanged() {
    tiles.net = !mapNet.isOffline;
    if (_disposed) return;
    if (mapNet.state != MapNetState.online) {
      _netWasDown = true;
    } else if (_netWasDown) {
      _netWasDown = false;
      unawaited(_upgradeRoutes());
    }
    notifyListeners();
  }

  /// Back online mid-route: swap a route made from saved data for an
  /// online one, only when the online one is really there (the current
  /// route is never dropped first).
  Future<void> _upgradeRoutes() async {
    final now = _clock();
    final last = _lastUpgrade;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastUpgrade = now;
    final d = drive;
    if (d != null &&
        !d.route.isOnline &&
        !d.arrived &&
        !d.rerouting &&
        d.me != null &&
        onlineRoutingAllowed) {
      final p = await planDrive(
        d.me!,
        d.target,
        name: d.name,
        course: d.course,
      );
      final r = p.route;
      if (r != null && r.isOnline && drive == d && !_disposed) {
        d.savedFallback = false;
        d.replaceRoute(r);
        d.notice = 'Back online: route updated.';
        unawaited(_saveDrive());
        notifyListeners();
      }
    }
    final n = nav;
    if (n != null &&
        n.route != null &&
        !n.terrainOnly &&
        !n.route!.isOnline &&
        n.me != null &&
        onlineRoutingAllowed) {
      try {
        mapNet.attempt();
        var r = await footRouter.route(
          n.me!,
          n.target,
          timeout: mapNet.routingTimeoutOverride,
        );
        r = routeWithEnds(r, n.me!, n.target);
        await _elevation(r);
        if (nav == n && !_disposed) {
          n.savedFallback = false;
          n.replaceRoute(r);
          n.note = 'Back online: route updated.';
          notifyListeners();
        }
      } on OnlineRouteException {
        // keep the saved-trail route
      }
    }
  }

  /// A walking route from [from] to [to], never a straight line: online
  /// first (Valhalla, then BRouter, then OSRM foot), else the trails saved
  /// on the phone. [note] says where it came from, or why there is none.
  Future<({TrailRoute? route, String note})> planWalk(
    GeoPoint from,
    GeoPoint to,
  ) async {
    var why = '';
    if (onlineRoutingAllowed) {
      mapNet.attempt();
      try {
        var r = await footRouter.route(
          from,
          to,
          timeout: mapNet.routingTimeoutOverride,
        );
        if (r.startOffM > OnlineRouter.maxSnapM ||
            r.endOffM > OnlineRouter.maxSnapM) {
          throw OnlineRouteException(
            OnlineFail.noRoute,
            'No path or road near the start or the destination.',
          );
        }
        r = routeWithEnds(r, from, to);
        final e = await _elevation(r);
        return (
          route: r,
          note: [
            'Walking route, online (${footRouter.lastProvider ?? r.source}).',
            if (r.endOffM > 40 || r.startOffM > 40)
              'The last ${formatDistance(max(r.endOffM, r.startOffM), imperial: settings.imperial)} has no mapped path.',
            e,
          ].where((x) => x.isNotEmpty).join(' '),
        );
      } on OnlineRouteException catch (e) {
        why = e.kind == OnlineFail.noSignal ? '' : e.message;
      }
    }
    final g = await trailGraph();
    if (!g.isEmpty) {
      final r = g.route(from, to);
      if (r != null) {
        final e = await _elevation(r);
        return (
          route: r,
          note: [
            'Route along your saved trails.',
            e,
          ].where((x) => x.isNotEmpty).join(' '),
        );
      }
      why = '$why No walking route in the saved trails.'.trim();
    }
    final offline = !onlineRoutingAllowed;
    return (
      route: null,
      note: [
        if (why.isNotEmpty) why,
        offline
            ? 'No signal, and no saved trails connect here. With signal I can '
                  'plan the walk; to have it offline, save the area first '
                  '(Offline areas > Save this area offline).'
            : 'No walking route found there.',
      ].join(' '),
    );
  }

  /// Start walking to [to]: [planWalk], then follow it. Null (with
  /// [lastWalkMessage]) when there is no route: a straight line is never
  /// started by itself. [preview]: a route planned earlier, used when the
  /// signal is gone by now.
  Future<NavSession?> walkTo(
    GeoPoint to, {
    String name = 'Destination',
    TrailRoute? preview,
  }) async {
    final me = myFix?.pos ?? (await host.locateOnce())?.pos;
    if (me == null) {
      lastWalkMessage = 'Waiting for GPS. Try again in a moment.';
      return null;
    }
    final w = await planWalk(me, to);
    var r = w.route;
    var note = w.note;
    preview ??= r == null ? _savedHikeFor(to, me) : null;
    if (r == null && preview != null && preview.points.length > 1) {
      r = routeWithEnds(preview, me, to);
      note = 'No signal here, so this is the walking route planned earlier.';
    }
    if (r == null) {
      lastWalkMessage = note;
      return null;
    }
    lastWalkMessage = '';
    if (_disposed) return NavSession(target: to, name: name, route: r);
    return _beginWalk(
      me,
      NavSession(target: to, name: name, route: r, note: note),
    );
  }

  Future<NavSession> _beginWalk(GeoPoint me, NavSession s) async {
    nav?.dispose();
    nav = s;
    _saidJunction = null;
    if (drive != null) {
      drive!.dispose();
      drive = null;
      try {
        if (await _driveFile.exists()) await _driveFile.delete();
      } catch (_) {}
    }
    final r = s.route;
    if (settings.trailVoice && r != null) {
      final first = r.junctions.firstOrNull;
      unawaited(
        _say(
          '${r.terrainOnly ? 'Terrain route' : 'Route'} to ${s.name}, '
          '${spokenDistance(r.lengthM, imperial: settings.imperial)}'
          '${first == null ? '' : '. First: ${first.text}'}.',
        ),
      );
    }
    s.update(me);
    await _updateLocationNeed();
    notifyListeners();
    return s;
  }

  /// Walk to the destination when [straightM] or less away.
  static const double walkOnlyM = 1500;

  /// A destination this close to a road (m) is reached by driving.
  static const double onRoadM = 150;

  /// "Navigate here": picks the way (v2.1.0). Close by: walk. On a road:
  /// drive. Off the roads: drive to the best trailhead, then walk. Online
  /// first, the saved roads and trails when there is no signal. Never a
  /// straight line unless asked for.
  Future<SmartPlan> planSmart(
    GeoPoint to, {
    String name = 'Destination',
  }) async {
    final p = await _planSmartLive(to, name: name);
    if (p.ok) return p;
    // v2.2.0: nothing could be planned (no signal, no saved roads): use the
    // route saved for offline to the same place, if you are near it.
    final me = myFix?.pos;
    if (me == null) return p;
    return _savedPlanFor(me, to) ?? p;
  }

  Future<SmartPlan> _planSmartLive(
    GeoPoint to, {
    String name = 'Destination',
  }) async {
    final me = myFix?.pos ?? (await host.locateOnce())?.pos;
    if (me == null) {
      return const SmartPlan(
        SmartKind.noRoute,
        message: 'Waiting for GPS. Try again in a moment.',
      );
    }
    final straight = distanceM(me, to);
    if (straight < 30) {
      return const SmartPlan(
        SmartKind.noRoute,
        message: 'You are already there.',
      );
    }
    if (straight <= walkOnlyM) {
      final w = await planWalk(me, to);
      return w.route == null
          ? SmartPlan(SmartKind.noRoute, message: w.note)
          : SmartPlan(SmartKind.hike, hike: w.route, hikeNote: w.note);
    }
    final p = await planDrive(me, to, name: name);
    final dr = p.route;
    if (dr != null && dr.endOffM <= onRoadM) {
      return SmartPlan(SmartKind.drive, drive: dr, message: p.message);
    }
    final th = await _planTrailhead(me, to, name, dr, p.message);
    if (th.kind == SmartKind.noRoute && dr == null) {
      // Maybe we are already out on the trails: try walking all the way.
      final w = await planWalk(me, to);
      if (w.route != null) {
        return SmartPlan(SmartKind.hike, hike: w.route, hikeNote: w.note);
      }
      return SmartPlan(
        SmartKind.noRoute,
        message: [p.message, th.message].where((x) => x.isNotEmpty).join(' '),
      );
    }
    return th;
  }

  /// Drive to a trailhead near [to], then walk. Online: OpenStreetMap
  /// trailheads and parking (Overpass, with Photon and Nominatim as
  /// backups); offline: trailhead pins and trails saved on the phone.
  Future<SmartPlan> _planTrailhead(
    GeoPoint me,
    GeoPoint to,
    String name,
    DriveRoute? direct,
    String driveMsg,
  ) async {
    final notes = <String>[];
    var cands = <TrailheadCandidate>[];
    if (onlineRoutingAllowed) {
      mapNet.attempt();
      final t = await trailheadFinder.find(to);
      cands = [...t.found];
      if (t.note.isNotEmpty) notes.add(t.note);
      if (t.found.isEmpty && (t.overpassFailed || t.noSignal)) {
        notes.add(
          t.noSignal
              ? 'The trailhead lookup got no answer (weak signal?).'
              : 'The trailhead lookup servers did not answer.',
        );
      }
    }
    final saved = await trailheadFor(to);
    if (saved != null && saved.name != nearestRoadName) {
      final c = TrailheadCandidate(
        name: saved.name,
        pos: saved.at,
        kind: 'trailhead',
        source: 'saved',
        distToTargetM: distanceM(saved.at, to),
      );
      if (!cands.any((x) => distanceM(x.pos, c.pos) < 80)) cands.add(c);
    }
    // Several to choose from: the one with the shortest walk wins.
    if (cands.length > 1) {
      final scored = <(TrailheadCandidate, double)>[];
      for (final c in cands.take(3)) {
        final w = await planWalk(c.pos, to);
        scored.add((c, w.route?.lengthM ?? c.distToTargetM * 1.6));
      }
      scored.sort((a, b) => a.$2.compareTo(b.$2));
      cands = [for (final x in scored) x.$1, ...cands.skip(3)];
    }
    for (final c in cands.take(4)) {
      final dp = await planDrive(me, c.pos, name: c.name);
      final dr = dp.route;
      if (dr == null || dr.endOffM > 400) continue; // no road to it
      final w = await planWalk(c.pos, to);
      return SmartPlan(
        SmartKind.driveThenHike,
        drive: dr,
        hike: w.route,
        trailhead: c,
        hikeNote: w.route == null ? '' : w.note,
        hikePending: w.route == null,
        message: [
          ...notes,
          dp.message,
          if (w.route == null)
            'The walk from the trailhead is planned when you get there.',
        ].where((x) => x.isNotEmpty).join(' '),
      );
    }
    // No usable trailhead: offer the closest road end.
    GeoPoint? end;
    double? off;
    if (direct != null) {
      end = direct.points.last;
      off = direct.endOffM;
    } else if (layers.roads.isNotEmpty) {
      await _loadRoads();
      final sn = await roads.snap(to, maxM: 10000);
      if (sn != null) {
        end = sn.pos;
        off = sn.distM;
      }
    }
    final base = [
      "I couldn't find a trailhead near $name.",
      ...notes.where(
        (n) => n.contains('did not answer') || n.contains('no answer'),
      ),
    ].join(' ');
    if (end != null) {
      return SmartPlan(
        SmartKind.needRoadEnd,
        roadEnd: end,
        roadEndOffM: off,
        message:
            '$base The closest road I know ends '
            '${formatDistance(off ?? 0, imperial: settings.imperial)} from '
            'there. Which road end should I take you to?',
      );
    }
    return SmartPlan(
      SmartKind.noRoute,
      message: [driveMsg, base].where((x) => x.isNotEmpty).join(' '),
    );
  }

  /// Start a plan made by [planSmart].
  Future<void> startPlan(SmartPlan p, GeoPoint to, String name) async {
    if (!p.ok) return;
    final me = myFix?.pos ?? (await host.locateOnce())?.pos;
    if (me == null || _disposed) return;
    switch (p.kind) {
      case SmartKind.drive:
        await _beginDrive(me, to, name, p.drive!, p.message);
      case SmartKind.hike:
        await _beginWalk(
          me,
          NavSession(target: to, name: name, route: p.hike, note: p.hikeNote),
        );
      case SmartKind.driveThenHike:
        final th = p.trailhead!;
        await _beginDrive(
          me,
          th.pos,
          th.name,
          p.drive!,
          p.message,
          hikeTo: to,
          hikeName: name,
          hikePreview: p.hike,
          hikeNote: p.hikeNote,
        );
      default:
        break;
    }
  }

  /// "Navigate here": plan and start.
  Future<SmartPlan> navigateSmart(
    GeoPoint to, {
    String name = 'Destination',
  }) async {
    final p = await planSmart(to, name: name);
    await startPlan(p, to, name);
    return p;
  }

  /// After "Which road end?": drive to [end], then walk to [to].
  Future<({DriveSession? session, String message})> driveToRoadEnd(
    GeoPoint end,
    GeoPoint to, {
    String name = 'Destination',
  }) => driveTo(end, name: 'the road end', hikeTo: to, hikeName: name);

  Future<({GentlePlan? plan, String reason})> _planGentleRoute(
    GeoPoint from,
    GeoPoint to,
    SlopeLimit limit,
  ) {
    final dem = DemSampler(
      (z, x, y) => tiles.get(MapSource.terrarium, z, x, y),
      keep: 64,
    );
    return planGentle(
      from,
      to,
      dem.elevationAt,
      limit: limit,
      // v2.4.1: hidden trail layers count too (same data, just not drawn).
      trails: graphLinesOf(layers, includeHidden: true),
    );
  }

  /// "Gentle compass route" (v2.1.0): an off-trail line from the elevation
  /// grid that avoids steep ground and prefers trails running your way.
  /// With no elevation data it falls back to the plain compass, saying so.
  Future<({NavSession? session, String message})> gentleTo(
    GeoPoint to, {
    String name = 'Destination',
    SlopeLimit limit = SlopeLimit.gentle,
  }) async {
    final me = myFix?.pos ?? (await host.locateOnce())?.pos;
    if (me == null) {
      return (
        session: null,
        message: 'Waiting for GPS. Try again in a moment.',
      );
    }
    final res = await _planGentleRoute(me, to, limit);
    final plan = res.plan;
    if (plan == null) {
      if (res.reason.startsWith('You are already')) {
        return (session: null, message: res.reason);
      }
      final s = await navigateTo(to, name: name, compass: true);
      s.note = '${res.reason} Showing the plain compass line instead.';
      notifyListeners();
      return (session: s, message: s.note);
    }
    if (_disposed) return (session: null, message: '');
    final s = NavSession(
      target: to,
      name: name,
      route: plan.route,
      note: '$gentleLabel. ${plan.summary(imperial: settings.imperial)}',
    )..gentleLimit = limit;
    await _beginWalk(me, s);
    return (session: s, message: s.note);
  }

  // ------------------------------------------------------------ driving

  /// "Drive here" in progress (v1.9.2), null when not driving.
  DriveSession? drive;

  /// Routing over the saved road areas (background isolate).
  RoadService roads = RoadService();

  /// Online directions while there is signal (v1.9.3); tests swap in one
  /// with a fake [Fetch].
  late OnlineRouter onlineRouter = OnlineRouter(
    fetch: fetch,
    limiter: _routeLimiter,
    valhallaAuto: true,
  );

  /// Online walking routes (v2.1.0): Valhalla, BRouter, OSRM foot.
  late FootRouter footRouter = FootRouter(fetch: fetch, limiter: _routeLimiter);

  /// Trailheads and parking near a trail destination (v2.1.0).
  late TrailheadFinder trailheadFinder = TrailheadFinder(
    fetch: fetch,
    limiter: _routeLimiter,
  );

  /// Spoken directions (the phone's offline text-to-speech).
  Speaker speaker = TtsSpeaker();
  DateTime? _lastDriveReroute;

  Future<void> _say(String text) => speaker.say(text);

  /// Saved road areas (all of them are used together).
  List<MapLayer> get roadAreas => layers.roads;

  /// Online directions may be tried (not in Offline power save, not
  /// told there is no network).
  bool get onlineRoutingAllowed =>
      plan.mapTileDownloads && tiles.online && mapNet.allowOnline;

  Future<void> _loadRoads() {
    final paths = [for (final l in layers.roads) layers.fileOf(l).path]..sort();
    return roads.load(paths);
  }

  static const noRoadsMessage =
      'No signal, and no roads saved on this phone for offline directions. '
      'With signal, Drive works anywhere. For places with no signal, save '
      'the area first (Offline areas > Save this area offline) or add '
      '"Portland to Gifford Pinchot roads" in Ready-made maps.';

  static const offRouteNoRoads =
      'Off route. No signal and no saved roads here, so I cannot re-route. '
      'Head back to the route.';

  /// Plan a drive (v1.9.3): online while there is signal (then checked
  /// against the saved roads for gates and rough roads), else over the
  /// saved roads. [message]: why not, or a note about the route.
  Future<({DriveRoute? route, String message})> planDrive(
    GeoPoint from,
    GeoPoint to, {
    String name = '',
    double? course,
  }) async {
    String? why;
    final haveRoads = layers.roads.isNotEmpty;
    if (onlineRoutingAllowed) {
      try {
        mapNet.attempt();
        final r = await onlineRouter.route(
          from,
          to,
          name: name,
          imperial: settings.imperial,
          course: course,
          timeout: mapNet.routingTimeoutOverride,
        );
        final c = await _checkOnline(r);
        if (c.locked && haveRoads) {
          final off = await _offlineRoute(from, to, name);
          if (off != null) {
            return (
              route: off,
              message:
                  'Offline route: the online route goes through a locked gate '
                  'in your saved roads.',
            );
          }
        }
        return (route: c.route, message: '');
      } on OnlineRouteException catch (e) {
        why = e.kind == OnlineFail.noSignal ? null : e.message;
      }
    }
    if (!haveRoads) {
      if (!plan.mapTileDownloads) {
        return (
          route: null,
          message:
              'Offline power save is on, so online directions are off, and no '
              'roads are saved on this phone. Turn Offline power save off, or '
              'save the area offline first.',
        );
      }
      return (
        route: null,
        message: why == null ? noRoadsMessage : '$why $noRoadsMessage',
      );
    }
    final r = await _offlineRoute(from, to, name);
    if (r != null) {
      return (
        route: r,
        message: !onlineRoutingAllowed || why == null
            ? ''
            : 'Offline route ($why)',
      );
    }
    final a = await roads.snap(from), b = await roads.snap(to);
    final off = a == null
        ? 'You are not near any saved roads${onlineRoutingAllowed ? ' and there is no signal' : ''}. '
              'Save the area you are in (Offline areas) or use a ready-made pack.'
        : b == null
        ? 'No saved roads near there${onlineRoutingAllowed ? ', and no signal for online directions' : ''}.'
        : 'No road route found: the roads there do not connect (a gate or '
              'private road may block the way).';
    return (route: null, message: why == null ? off : '$why $off');
  }

  Future<DriveRoute?> _offlineRoute(
    GeoPoint from,
    GeoPoint to,
    String name,
  ) async {
    if (layers.roads.isEmpty) return null;
    await _loadRoads();
    return roads.route(
      from,
      to,
      name: name,
      imperial: settings.imperial,
      now: _clock(),
    );
  }

  /// Rough roads, closures and gates on an online route, from the saved
  /// roads; what they do not cover is marked unknown.
  Future<({DriveRoute route, bool locked})> _checkOnline(DriveRoute r) async {
    RouteCheck? c;
    if (layers.roads.isNotEmpty) {
      await _loadRoads();
      try {
        c = await roads.check(r, now: _clock());
      } catch (_) {}
    }
    final unknown = c?.unknownM ?? r.lengthM;
    final warns = [
      ...?c?.warnings,
      if (unknown > 300)
        RoadWarning(
          'unknown',
          '',
          unknown,
          0,
          c == null
              ? 'Gates and road surface not checked (no roads saved on this '
                    'phone for this route)'
              : 'Gates and road surface not checked for '
                    '${formatDistance(unknown, imperial: settings.imperial)} '
                    'of the route (no saved roads there)',
        ),
    ];
    return (
      route: r.copyWith(segRough: c?.segRough, warnings: warns),
      locked: c?.lockedGate ?? false,
    );
  }

  /// Start driving to [to]: online directions with signal, else along the
  /// saved roads. [hikeTo]: walk on to there after arriving (trail
  /// navigation starts by itself). Returns the session, or a message
  /// saying why not.
  Future<({DriveSession? session, String message})> driveTo(
    GeoPoint to, {
    String name = 'Destination',
    GeoPoint? hikeTo,
    String hikeName = '',
  }) async {
    if (layers.roads.isEmpty && !onlineRoutingAllowed) {
      return (session: null, message: noRoadsMessage);
    }
    final me = myFix?.pos ?? (await host.locateOnce())?.pos;
    if (me == null) {
      return (
        session: null,
        message: 'Waiting for GPS. Try again in a moment.',
      );
    }
    final p = await planDrive(me, to, name: name);
    final r = p.route;
    if (r == null) return (session: null, message: p.message);
    if (_disposed) return (session: null, message: '');
    final s = await _beginDrive(
      me,
      to,
      name,
      r,
      p.message,
      hikeTo: hikeTo,
      hikeName: hikeName,
    );
    return (session: s, message: p.message);
  }

  /// Start following a planned driving route.
  Future<DriveSession> _beginDrive(
    GeoPoint me,
    GeoPoint to,
    String name,
    DriveRoute r,
    String message, {
    GeoPoint? hikeTo,
    String hikeName = '',
    TrailRoute? hikePreview,
    String hikeNote = '',
  }) async {
    final s =
        DriveSession(
            target: to,
            name: name,
            route: r,
            imperial: settings.imperial,
            hikeTo: hikeTo,
            hikeName: hikeName,
          )
          ..notice = message
          ..hikePreview = hikePreview
          ..hikeNote = hikeNote;
    nav?.dispose();
    nav = null;
    drive?.dispose();
    drive = s;
    _lastDriveReroute = null;
    handoff = null;
    final f = myFix;
    _speakDrive(s.update(me, speed: f?.speedMps, at: f?.at).say);
    await _saveDrive();
    await _updateLocationNeed();
    notifyListeners();
    return s;
  }

  void _speakDrive(String? text) {
    if (text == null || !settings.driveVoice) return;
    unawaited(_say(text));
  }

  /// Mute / unmute spoken directions.
  Future<void> setDriveVoice(bool on) async {
    await update((s) => s.driveVoice = on);
    if (!on) await speaker.stop();
  }

  Future<void> setTrailVoice(bool on) => update((s) => s.trailVoice = on);

  /// Route again from where you are: online with signal, else offline from
  /// the saved roads. False (with [DriveSession.notice] saying why) when
  /// neither works; the old route stays.
  Future<bool> rerouteDrive() async {
    final s = drive;
    final me = myFix?.pos ?? s?.me;
    if (s == null || me == null) return false;
    _lastDriveReroute = _clock();
    s.rerouting = true;
    notifyListeners();
    final p = await planDrive(me, s.target, name: s.name, course: s.course);
    if (drive != s || _disposed) return false;
    final r = p.route;
    if (r == null) {
      // v2.2.0: no new route (no signal, no saved roads here): keep going
      // on the route saved for offline, if there is one near you.
      final saved = s.savedFallback ? null : _savedDriveFor(s.target, me);
      if (saved != null) {
        s.savedFallback = true;
        s.replaceRoute(saved);
        s.notice =
            'No signal for a new route: following your saved route. It '
            'switches back to an online route when the signal returns.';
        unawaited(_saveDrive());
        notifyListeners();
        return true;
      }
      s.rerouting = false;
      s.notice = layers.roads.isEmpty || p.message.isEmpty
          ? offRouteNoRoads
          : 'Cannot re-route: ${p.message}';
      notifyListeners();
      return false;
    }
    s.savedFallback = false;
    s.replaceRoute(r);
    s.notice = p.message;
    unawaited(_saveDrive());
    notifyListeners();
    return true;
  }

  Future<void> stopDrive() async {
    drive?.dispose();
    drive = null;
    await speaker.stop();
    try {
      if (await _driveFile.exists()) await _driveFile.delete();
    } catch (_) {}
    await _updateLocationNeed();
    notifyListeners();
  }

  File get _driveFile => File('${dir.path}/drive_active.json');

  /// Keep the route on the phone (signal may drop; the app may restart).
  Future<void> _saveDrive() async {
    final s = drive;
    if (s == null) return;
    try {
      await dir.create(recursive: true);
      await _driveFile.writeAsString(jsonEncode(s.toJson(_clock())));
    } catch (_) {}
  }

  /// Carry on with a drive from before an app restart (up to 12 hours).
  Future<void> _restoreDrive() async {
    try {
      if (drive != null || !await _driveFile.exists()) return;
      final j = DriveSession.fromJson(
        jsonDecode(await _driveFile.readAsString()),
        imperial: settings.imperial,
      );
      if (j == null || _clock().difference(j.at) > const Duration(hours: 12)) {
        await _driveFile.delete();
        return;
      }
      drive = j.session
        ..notice = 'Carrying on with your drive (route kept on this phone).';
    } catch (_) {}
  }

  void _driveFix(Fix f) {
    final s = drive;
    if (s == null) return;
    final u = s.update(f.pos, speed: f.speedMps, at: f.at);
    _speakDrive(u.say);
    final st = s.state;
    if (u.event == 'arrived') {
      final hike = s.hikeTo;
      if (hike != null) {
        _speakDrive('Now walk to ${s.hikeName}.');
        unawaited(_handoffToHike(s));
      } else {
        host.notify('Arrived', 'You reached ${s.name}.');
      }
      return;
    }
    // Off the route: route again (at most every 10 s).
    if (st != null && st.offRoute && !s.rerouting) {
      final last = _lastDriveReroute;
      if (last == null || _clock().difference(last).inSeconds >= 10) {
        _speakDrive('Rerouting.');
        unawaited(
          rerouteDrive().then((ok) {
            if (!ok && drive == s && s.notice != s.spokenNotice) {
              s.spokenNotice = s.notice;
              _speakDrive(s.notice);
            }
          }),
        );
      }
    }
  }

  /// After driving: walk on to the hike target (or the destination when
  /// it is off the road), with trail navigation.
  Future<NavSession?> walkOn() async {
    final s = drive;
    if (s == null) return null;
    final to = s.hikeTo ?? s.target;
    final name = s.hikeTo != null ? s.hikeName : s.name;
    final w = await walkTo(to, name: name);
    if (w == null && drive == s) {
      handoff = TrailheadHandoff(
        trailheadName: s.name,
        targetName: name,
        at: _clock(),
        message: lastWalkMessage,
      );
      notifyListeners();
    }
    return w;
  }

  /// Reached the trailhead of a drive-then-hike: plan the walk from here,
  /// start it, and tell the screen to show the handoff.
  Future<void> _handoffToHike(DriveSession s) async {
    final to = s.hikeTo;
    if (to == null) return;
    final name = s.hikeName;
    final w = await walkTo(to, name: name, preview: s.hikePreview);
    if (_disposed) return;
    handoff = TrailheadHandoff(
      trailheadName: s.name,
      targetName: name,
      at: _clock(),
      route: w?.route,
      message: w == null ? lastWalkMessage : w.note,
    );
    notifyListeners();
  }

  /// "Drive to trailhead, then hike": the trailhead to drive to for
  /// walking to [to] (a trailhead waypoint near the trails that lead
  /// there, close to a saved road when roads are saved), or the nearest
  /// road point (online: the destination itself, the router finds the
  /// road end).
  Future<({GeoPoint at, String name})?> trailheadFor(GeoPoint to) async {
    final haveRoads = layers.roads.isNotEmpty;
    if (haveRoads) await _loadRoads();
    final g = await trailGraph();
    final cands = <ImportedWaypoint>[
      for (final l in layers.trails)
        if (l.visible && l.data != null)
          for (final w in l.data!.waypoints)
            if ((w.kind == 'trailhead' ||
                    RegExp(
                      r'trail ?head|\bTH\b',
                      caseSensitive: false,
                    ).hasMatch(w.name)) &&
                distanceM(w.pos, to) < 25000)
              w,
    ];
    ({GeoPoint at, String name})? best;
    var bestM = double.infinity;
    for (final w in cands) {
      if (haveRoads) {
        final road = await roads.snap(w.pos, maxM: 500);
        if (road == null) continue;
      }
      double hike;
      if (g.isEmpty) {
        hike = distanceM(w.pos, to) * 1.4;
      } else {
        final r = g.route(w.pos, to);
        if (r == null) continue;
        hike = r.lengthM + (r.startOffM + r.endOffM) * 3;
      }
      if (hike < bestM) {
        bestM = hike;
        best = (at: w.pos, name: w.name);
      }
    }
    if (best != null) return best;
    if (haveRoads) {
      final road = await roads.snap(to, maxM: 10000);
      if (road != null) return (at: road.pos, name: 'the nearest road');
    }
    if (onlineRoutingAllowed) return (at: to, name: 'the nearest road');
    return null;
  }

  /// Drive to the best trailhead for [to], then hike there.
  Future<({DriveSession? session, String message})> driveThenHike(
    GeoPoint to, {
    String name = 'Destination',
  }) async {
    if (layers.roads.isEmpty && !onlineRoutingAllowed) {
      return (session: null, message: noRoadsMessage);
    }
    final th = await trailheadFor(to);
    if (th == null) {
      return (session: null, message: 'No saved roads near there.');
    }
    return driveTo(th.at, name: th.name, hikeTo: to, hikeName: name);
  }

  // ------------------------------------------------------------ offline areas

  /// Size of what [o] saves; roads are counted by asking the server
  /// ([withRoads]), which needs signal.
  Future<AreaEstimate> estimateArea(
    AreaSaveOptions o, {
    bool withRoads = true,
    RoadDownloader? downloader,
  }) async {
    var n = 0, bytes = 0;
    String? tooBig;
    for (final j in areaTileJobs(o)) {
      final e = tiles.estimate(j.src, o.bounds, j.z0, j.z1);
      n += e.tiles;
      bytes += e.bytes;
      if (e.tiles > tiles.limitFor(j.src)) {
        tooBig =
            '${j.src.name}: ${e.tiles} tiles (up to ${tiles.limitFor(j.src)} '
            'per style). Make the box smaller or lower the detail.';
      }
    }
    int? road;
    if (withRoads && o.roads && plan.mapTileDownloads) {
      final pieces = roadPieces(o.bounds);
      if (pieces != null) {
        final dl = downloader ?? RoadDownloader(fetch: fetch, clock: _clock);
        try {
          var r = 0;
          for (final p in pieces) {
            r += (await dl.estimate(p)).bytes;
          }
          road = r;
        } catch (_) {}
      }
    }
    return AreaEstimate(
      tiles: n,
      tileBytes: bytes,
      roadBytes: road,
      tooBig: tooBig,
    );
  }

  /// "Save this area offline" (v1.9.3): map tiles of the chosen styles,
  /// elevation, trails and road data of one box, as one area. [updateId]:
  /// update that area (styles or parts left out are removed from it).
  /// Parts that fail are listed in the result; the rest is kept.
  Future<AreaSaveResult> saveArea(
    AreaSaveOptions o, {
    String? updateId,
    void Function(AreaSaveProgress p)? onProgress,
    bool Function()? cancelled,
    RoadDownloader? downloader,
    Duration tilePause = const Duration(milliseconds: 150),
  }) async {
    if (!plan.mapTileDownloads) {
      throw StateError(
        'Offline power save is on: saving an area needs the internet.',
      );
    }
    final jobs = areaTileJobs(o);
    for (final j in jobs) {
      final n = countTiles(o.bounds, j.z0, j.z1);
      if (n > tiles.limitFor(j.src)) {
        throw StateError(
          'Area too big for ${j.src.name}: $n tiles (up to '
          '${tiles.limitFor(j.src)}). Make the box smaller or lower the '
          'detail.',
        );
      }
    }
    final pieces = o.roads ? roadPieces(o.bounds) : null;
    final name = o.name.trim().isEmpty ? 'Offline area' : o.name.trim();
    final existing = updateId == null ? null : areas.byId(updateId);
    final area =
        existing ??
        await areas.create(
          name,
          o.bounds,
          styles: [for (final s in o.styles) s.id],
          minZoom: o.minZoom,
          maxZoom: o.maxZoom,
          roads: o.roads,
          trails: o.trails,
        );
    final old = areas.entry(area.id);
    final oldRegions = old?.regions ?? const <OfflineRegion>[];
    final oldRoads = old?.roadLayers ?? const <MapLayer>[];
    final oldTrails = old?.trailLayers ?? const <MapLayer>[];
    final problems = <String>[];
    final steps = jobs.length + (pieces?.length ?? 0) + (o.trails ? 1 : 0);
    var stepNo = 0;
    bool stop() => cancelled?.call() ?? false;
    void report(String step, double? f) =>
        onProgress?.call(AreaSaveProgress(step, stepNo, steps, f));

    // Map tiles, one style at a time.
    for (final j in jobs) {
      if (stop()) break;
      stepNo++;
      final p = DownloadProgress(countTiles(o.bounds, j.z0, j.z1));
      report('Map: ${j.src.name}', 0);
      final r = await tiles.download(
        j.src,
        o.bounds,
        j.z0,
        j.z1,
        name: name,
        progress: p,
        areaId: area.id,
        refresh: existing != null,
        pause: tilePause,
        onProgress: (p) {
          if (stop()) p.cancelled = true;
          report('Map: ${j.src.name}', p.fraction);
        },
      );
      if (p.failed > 0 && p.done == 0) {
        problems.add('${j.src.name}: could not download (no signal?)');
      } else if (p.failed > 0) {
        problems.add('${j.src.name}: ${p.failed} of ${p.total} tiles failed');
      }
      if (tiles.regions.contains(r)) {
        for (final o in oldRegions.where((x) => x.sourceId == j.src.id)) {
          await tiles.deleteRegion(o);
        }
      }
    }
    // Styles left out on update.
    for (final r in oldRegions) {
      if (!jobs.any((j) => j.src.id == r.sourceId) &&
          tiles.regions.contains(r)) {
        await tiles.deleteRegion(r);
      }
    }
    // Roads for offline driving.
    if (o.roads && pieces == null) {
      problems.add(
        'Roads: the box is too big for road data (up to 2° x 2°). Save '
        'roads with a smaller box; routes cross from one area to the next.',
      );
    }
    final keptRoads = <MapLayer>[];
    if (pieces != null) {
      for (var i = 0; i < pieces.length; i++) {
        if (stop()) break;
        stepNo++;
        report(
          'Roads${pieces.length > 1 ? ' (part ${i + 1} of ${pieces.length})' : ''}',
          null,
        );
        try {
          final l = await saveRoads(
            pieces[i],
            name: pieces.length > 1 ? '$name roads ${i + 1}' : '$name roads',
            replace: i < oldRoads.length ? oldRoads[i] : null,
            downloader: downloader,
            cancelled: stop,
            onProgress: (rp) => report(
              'Roads${pieces.length > 1 ? ' (part ${i + 1} of ${pieces.length})' : ''}',
              rp.fraction,
            ),
          );
          await layers.tagArea(l, area.id);
          keptRoads.add(l);
        } catch (e) {
          if (!stop()) problems.add('Roads: $e');
          if (i < oldRoads.length) keptRoads.add(oldRoads[i]);
        }
      }
    }
    // Roads left out on update (or old pieces past the new ones).
    if (!stop() && (!o.roads || pieces != null)) {
      for (final l in oldRoads) {
        if (!keptRoads.contains(l) && layers.byId(l.id) != null) {
          await layers.delete(l);
        }
      }
    }
    // Trails.
    if (o.trails && !stop()) {
      stepNo++;
      report('Trails', null);
      try {
        final box = capBounds(o.bounds, minKm: 0);
        final r = await search.trailsFor(box.bounds, name: '$name trails');
        if (r.data.isEmpty) {
          problems.add('Trails: none found here in OpenStreetMap');
        } else {
          final l = await layers.addTrail(
            r.data,
            attribution: osmAttribution,
            color: 0xFF6D4C41,
          );
          await layers.tagArea(l, area.id);
          for (final t in oldTrails) {
            if (layers.byId(t.id) != null) await layers.delete(t);
          }
          if (box.trimmed) {
            problems.add(
              'Trails: big box, so trails were saved for the middle '
              '${maxTrailAreaKm.round()} km',
            );
          }
        }
      } catch (e) {
        problems.add('Trails: $e');
      }
    } else if (!o.trails) {
      for (final t in oldTrails) {
        if (layers.byId(t.id) != null) await layers.delete(t);
      }
    }
    area
      ..name = name
      ..bounds = o.bounds
      ..styles = [for (final s in o.styles) s.id]
      ..minZoom = o.minZoom
      ..maxZoom = o.maxZoom
      ..roads = o.roads
      ..trails = o.trails;
    final entry = areas.entry(area.id);
    final empty =
        entry == null || (entry.regions.isEmpty && entry.layers.isEmpty);
    if (empty || (stop() && existing == null)) {
      if (entry != null) await areas.delete(entry);
      notifyListeners();
      if (stop()) return AreaSaveResult(null, problems, cancelled: true);
      throw StateError(
        problems.isEmpty ? 'Nothing could be saved.' : problems.join('\n'),
      );
    }
    await areas.touch(area);
    await tiles.trim();
    notifyListeners();
    return AreaSaveResult(areas.entry(area.id), problems, cancelled: stop());
  }

  // ------------------------------------------------------------ v2.2.0: save route for offline

  /// The route being followed (or just planned and started), ready to be
  /// saved: the drive, the walk, the trailhead. Null when there is none
  /// (nothing active, or only a compass line).
  SavedRoute? currentRouteForSave() {
    final d = drive;
    if (d != null) {
      final hikeTo = d.hikeTo;
      final base = mapSource.allowsOffline && !mapSource.onlineOnly
          ? mapSource.id
          : MapSource.topo.id;
      if (hikeTo != null) {
        final h = d.hikePreview;
        final saved = routes.all.where(
          (r) =>
              distanceM(r.destination, hikeTo) < 150 &&
              r.trailheadPos != null &&
              distanceM(r.trailheadPos!, d.target) < 300,
        );
        return SavedRoute(
          id: saved.firstOrNull?.id ?? '',
          status: saved.firstOrNull?.status ?? SavedRoute.partial,
          name: d.hikeName.isEmpty ? 'Destination' : d.hikeName,
          destination: hikeTo,
          drive: d.route,
          hike: h,
          hikeApprox: h == null,
          trailheadName: d.name,
          trailheadPos: d.target,
          baseId: base,
        );
      }
      final saved = routes.all.where(
        (r) => r.hike == null && distanceM(r.destination, d.target) < 150,
      );
      return SavedRoute(
        id: saved.firstOrNull?.id ?? '',
        status: saved.firstOrNull?.status ?? SavedRoute.partial,
        name: d.name,
        destination: d.target,
        drive: d.route,
        baseId: base,
      );
    }
    final n = nav;
    if (n != null && n.route != null && n.route!.points.length > 1) {
      final saved = routes.all.where(
        (r) => r.drive == null && distanceM(r.destination, n.target) < 150,
      );
      return SavedRoute(
        id: saved.firstOrNull?.id ?? '',
        status: saved.firstOrNull?.status ?? SavedRoute.partial,
        name: n.name,
        destination: n.target,
        hike: n.route,
        baseId: mapSource.allowsOffline && !mapSource.onlineOnly
            ? mapSource.id
            : MapSource.topo.id,
      );
    }
    return null;
  }

  /// The map style saved with a route: the one you use, else Topo.
  MapSource _routeBase(SavedRoute r) {
    final s = MapSource.byId(r.baseId);
    if (s != null && s.allowsOffline && !s.onlineOnly && !s.overlay) return s;
    return MapSource.topo;
  }

  /// Size and time of saving [r] (no network: known from the route).
  ({RouteSaveJobs jobs, int bytes, Duration time}) estimateRouteSave(
    SavedRoute r,
  ) {
    final j = routeSaveJobs(r, _routeBase(r));
    return (jobs: j, bytes: j.bytes(r), time: j.time(r));
  }

  /// "Save route for offline" (v2.2.0): map tiles along every leg, the
  /// roads and trails near it, elevation for the walk, the turn list and
  /// trailhead info, as ONE item in Offline areas, named after the
  /// destination. Only when called (the user tapped Save), one request at
  /// a time, polite pace, stops at once when [cancelled]. Calling it again
  /// for the same route resumes (tiles on the phone are skipped) or, for a
  /// finished one, downloads it again (fresh data).
  Future<RouteSaveResult> saveRoute(
    SavedRoute r, {
    void Function(AreaSaveProgress p)? onProgress,
    bool Function()? cancelled,
    RoadDownloader? downloader,
    Duration tilePause = routeTilePause,
  }) async {
    if (!plan.mapTileDownloads) {
      throw StateError(
        'Offline power save is on: saving a route needs the internet.',
      );
    }
    final base = _routeBase(r);
    final jobs = routeSaveJobs(r, base);
    if (jobs.tiles.isEmpty &&
        jobs.roadWindows.isEmpty &&
        jobs.trailWindows.isEmpty) {
      throw StateError('Nothing to save for this route.');
    }
    final redo = r.isReady;
    final name = r.name.trim().isEmpty ? 'Route' : r.name.trim();
    final existing = r.id.isEmpty ? null : areas.byId(r.id);
    final area =
        existing ??
        await areas.create(
          name,
          jobs.bounds,
          styles: [base.id],
          minZoom: 8,
          maxZoom: 16,
          roads: jobs.roadWindows.isNotEmpty,
          trails: true,
        );
    r.id = area.id;
    r.baseId = base.id;
    r.status = SavedRoute.partial;
    r.problems = [];
    await routes.put(r);
    final old = areas.entry(area.id);
    final oldRegions = List<OfflineRegion>.of(old?.regions ?? const []);
    final oldRoads = List<MapLayer>.of(old?.roadLayers ?? const []);
    final oldTrails = List<MapLayer>.of(old?.trailLayers ?? const []);
    final problems = <String>[...jobs.notes];
    final steps =
        jobs.tiles.length +
        (jobs.roadWindows.isEmpty ? 0 : 1) +
        (jobs.trailWindows.isEmpty ? 0 : 1);
    var stepNo = 0;
    bool stop() => cancelled?.call() ?? false;
    void report(String step, double? f) =>
        onProgress?.call(AreaSaveProgress(step, stepNo, steps, f));
    var complete = true;
    final newRegions = <OfflineRegion>[];

    // Map tiles: one strip at a time.
    for (final j in jobs.tiles) {
      if (stop()) break;
      stepNo++;
      final p = DownloadProgress(j.tiles.length);
      report(j.label, 0);
      final reg = await tiles.downloadTiles(
        j.src,
        j.tiles,
        name: name,
        bounds: j.bounds,
        areaId: area.id,
        progress: p,
        refresh: redo,
        pause: tilePause,
        onProgress: (p) {
          if (stop()) p.cancelled = true;
          report(j.label, p.fraction);
        },
      );
      if (tiles.regions.contains(reg)) {
        newRegions.add(reg);
        for (final o in oldRegions.where(
          (o) =>
              o.sourceId == reg.sourceId &&
              o.bounds.south == reg.bounds.south &&
              o.bounds.west == reg.bounds.west &&
              o.bounds.north == reg.bounds.north &&
              o.bounds.east == reg.bounds.east,
        )) {
          tiles.regions.remove(o);
        }
        await tiles.saveRegions();
      }
      if (p.stalled) {
        complete = false;
        problems.add('${j.label}: no signal, stopped. Tap Resume later.');
        break;
      } else if (p.failed > 0) {
        complete = false;
        problems.add('${j.label}: ${p.failed} of ${p.total} tiles failed');
      }
      if (p.cancelled && stop()) complete = false;
    }
    if (stop()) complete = false;

    // Roads (all legs together as one layer).
    var noSignal = problems.any((x) => x.contains('no signal'));
    if (!stop() && !noSignal && jobs.roadWindows.isNotEmpty) {
      stepNo++;
      report('Roads', null);
      try {
        final dl = downloader ?? RoadDownloader(fetch: fetch, clock: _clock);
        final parts = <RoadData>[];
        var km = 0.0;
        DateTime? built;
        for (var i = 0; i < jobs.roadWindows.length; i++) {
          if (stop()) break;
          final d = await dl.download(jobs.roadWindows[i], cancelled: stop);
          parts.add(d);
          km += d.roadKm;
          built ??= d.builtAt;
          report('Roads', (i + 1) / jobs.roadWindows.length);
        }
        if (!stop() && parts.isNotEmpty) {
          final all = parts.length == 1
              ? parts.first
              : await Isolate.run(() => RoadData.merge(parts));
          final l = await layers.importRoads(
            '$name roads',
            all.encode(),
            area: jobs.bounds,
            summary: roadsSummary(km, built ?? _clock()),
            attribution: '© OpenStreetMap contributors, ODbL',
          );
          await layers.tagArea(l, area.id);
          for (final x in oldRoads) {
            if (layers.byId(x.id) != null) await layers.delete(x);
          }
        }
      } on NoSignalException {
        complete = false;
        noSignal = true;
        problems.add('Roads: no signal, stopped. Tap Resume later.');
      } catch (e) {
        if (!stop()) {
          complete = false;
          problems.add('Roads: $e');
        }
      }
    }
    if (stop()) complete = false;

    // Trails and paths (unnamed ones too) along the walk.
    if (!stop() && !noSignal && jobs.trailWindows.isNotEmpty) {
      stepNo++;
      report('Trails', null);
      try {
        final lines = <ImportedLine>[];
        final wps = <ImportedWaypoint>[];
        final seen = <String>{};
        for (var i = 0; i < jobs.trailWindows.length; i++) {
          if (stop()) break;
          final res = await search.trailsFor(
            jobs.trailWindows[i],
            name: '$name trails',
          );
          for (final l in res.data.lines) {
            final f = l.points.first;
            final k =
                '${l.name}|${f.lat.toStringAsFixed(5)}|'
                '${f.lng.toStringAsFixed(5)}|${l.points.length}';
            if (seen.add(k)) lines.add(l);
          }
          for (final w in res.data.waypoints) {
            final k =
                'w|${w.name}|${w.pos.lat.toStringAsFixed(5)}|'
                '${w.pos.lng.toStringAsFixed(5)}';
            if (seen.add(k)) wps.add(w);
          }
          report('Trails', (i + 1) / jobs.trailWindows.length);
        }
        if (!stop()) {
          if (lines.isEmpty && wps.isEmpty) {
            problems.add('Trails: none found near the route in OpenStreetMap');
          } else {
            final l = await layers.addTrail(
              ImportedData(name: '$name trails', lines: lines, waypoints: wps),
              attribution: osmAttribution,
              color: 0xFF6D4C41,
            );
            await layers.tagArea(l, area.id);
            for (final x in oldTrails) {
              if (layers.byId(x.id) != null) await layers.delete(x);
            }
          }
        }
      } on NoSignalException {
        complete = false;
        problems.add('Trails: no signal, stopped. Tap Resume later.');
      } catch (e) {
        if (!stop()) {
          complete = false;
          problems.add('Trails: $e');
        }
      }
    }
    if (stop()) complete = false;

    // Finished: drop what an older save had that this one does not.
    if (complete) {
      for (final o in oldRegions) {
        if (tiles.regions.contains(o) && !newRegions.contains(o)) {
          await tiles.deleteRegion(o);
        }
      }
    }
    area
      ..name = name
      ..bounds = jobs.bounds
      ..styles = [base.id]
      ..minZoom = 8
      ..maxZoom = 16
      ..roads = jobs.roadWindows.isNotEmpty
      ..trails = true;
    r
      ..status = complete ? SavedRoute.ready : SavedRoute.partial
      ..problems = problems
      ..at = _clock();
    final entry = areas.entry(area.id);
    final empty =
        entry == null || (entry.regions.isEmpty && entry.layers.isEmpty);
    if (stop() && existing == null && empty) {
      // Cancelled before anything was kept: leave no empty item behind.
      await routes.remove(area.id);
      if (entry != null) await areas.delete(entry);
      notifyListeners();
      return RouteSaveResult(null, r, problems, cancelled: true);
    }
    // The turn list and trailhead info stay (even when a download part
    // failed): the route itself is always kept.
    await routes.put(r);
    await areas.touch(area);
    await tiles.trim();
    notifyListeners();
    return RouteSaveResult(
      areas.entry(area.id),
      r,
      problems,
      cancelled: stop(),
    );
  }

  /// A route saved for [dest] (within [withinM]) that has drive or walk
  /// data, for when no new route can be made.
  SavedRoute? savedRouteFor(GeoPoint dest, {double withinM = 250}) {
    for (final r in routes.all.toList().reversed) {
      if ((r.drive != null || r.hike != null) &&
          distanceM(r.destination, dest) <= withinM) {
        return r;
      }
    }
    return null;
  }

  /// The saved driving leg that ends at [target], if you are near it.
  DriveRoute? _savedDriveFor(GeoPoint target, GeoPoint me) {
    for (final r in routes.all.toList().reversed) {
      final d = r.drive;
      if (d == null || d.points.length < 2) continue;
      if (distanceM(d.points.last, target) > 300) continue;
      if (distanceToLineM(d.points, me) > 8000) continue;
      return d.copyWith(source: DriveRoute.saved);
    }
    return null;
  }

  /// The saved walking leg that ends at [target], if you are near it.
  TrailRoute? _savedHikeFor(GeoPoint target, GeoPoint me) {
    for (final r in routes.all.toList().reversed) {
      final h = r.hike;
      if (h == null || h.points.length < 2) continue;
      if (distanceM(h.points.last, target) > 300) continue;
      if (distanceToLineM(h.points, me) > 5000) continue;
      return copyTrailRoute(h, source: h.terrainOnly ? null : 'saved');
    }
    return null;
  }

  /// No signal and no live plan: use the saved route to the same place.
  SmartPlan? _savedPlanFor(GeoPoint me, GeoPoint to) {
    final r = savedRouteFor(to);
    if (r == null) return null;
    final dr = r.drive;
    final hike = r.hike;
    const msg =
        'No signal: using your saved route. It switches to a fresh one when '
        'the signal is back.';
    if (dr != null && distanceToLineM(dr.points, me) <= 8000) {
      final copy = dr.copyWith(source: DriveRoute.saved);
      final tp = r.trailheadPos;
      if ((tp != null && hike != null) || r.hikeApprox) {
        return SmartPlan(
          SmartKind.driveThenHike,
          drive: copy,
          hike: hike == null ? null : copyTrailRoute(hike, source: 'saved'),
          hikePending: hike == null,
          trailhead: TrailheadCandidate(
            name: r.trailheadName.isEmpty ? 'the trailhead' : r.trailheadName,
            pos: tp ?? dr.points.last,
            kind: 'trailhead',
            source: 'saved',
            distToTargetM: distanceM(tp ?? dr.points.last, to),
          ),
          message: msg,
        );
      }
      return SmartPlan(SmartKind.drive, drive: copy, message: msg);
    }
    if (hike != null && distanceToLineM(hike.points, me) <= 5000) {
      return SmartPlan(
        SmartKind.hike,
        hike: copyTrailRoute(hike, source: hike.terrainOnly ? null : 'saved'),
        hikeNote: msg,
      );
    }
    return null;
  }

  /// Delete an area (or a ready-made pack) and everything in it.
  Future<void> deleteArea(AreaEntry e) async {
    final base = baseTiles;
    if (base != null && e.layers.any((l) => l.id == base.id)) {
      await update((s) => s.mapSource = 'topo');
    }
    await areas.delete(e);
    await routes.remove(e.id);
    notifyListeners();
  }

  /// Share the driving route with the group.
  ({int parts, bool radio}) shareDriveRoute() {
    final s = drive;
    if (s == null) return (parts: 0, radio: false);
    return _shareData(s.asData(), s.asData().name, 0xFF1565C0);
  }

  // ------------------------------------------------------------ saved roads

  /// Save the roads of [area] from OpenStreetMap ([replace]: update that
  /// saved area). Throws [RoadDownloadException] / fetch errors.
  Future<MapLayer> saveRoads(
    GeoBounds area, {
    String name = '',
    MapLayer? replace,
    void Function(RoadProgress p)? onProgress,
    bool Function()? cancelled,
    RoadDownloader? downloader,
  }) async {
    if (!plan.mapTileDownloads) {
      throw RoadDownloadException(
        'Offline power save is on: saving roads needs the internet.',
      );
    }
    final dl = downloader ?? RoadDownloader(fetch: fetch, clock: _clock);
    final d = await dl.download(
      area,
      onProgress: onProgress,
      cancelled: cancelled,
    );
    final bytes = d.encode();
    final l = await layers.importRoads(
      name.isEmpty ? defaultRoadsName(area) : name,
      bytes,
      area: area,
      summary: roadsSummary(d.roadKm, d.builtAt),
      attribution: '© OpenStreetMap contributors, ODbL',
      replace: replace,
    );
    notifyListeners();
    return l;
  }

  static String defaultRoadsName(GeoBounds b) {
    final c = b.center;
    return 'Roads near ${c.lat.abs().toStringAsFixed(2)}° ${c.lat >= 0 ? 'N' : 'S'}, '
        '${c.lng.abs().toStringAsFixed(2)}° ${c.lng >= 0 ? 'E' : 'W'}';
  }

  static String roadsSummary(double km, DateTime at) =>
      '${km.round()} km of road · map data ${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

  void onHeading(double h) {
    final prev = heading;
    heading = smoothAngle(prev, h, 0.2);
    if (prev == null || deltaDeg(heading!, prev).abs() > 2) notifyListeners();
  }

  void _maybeSendLive() {
    if (!settings.tripMode) return;
    // Offline power save: no live updates (check-ins still carry it).
    if (!plan.liveLocation) return;
    final f = myFix;
    if (f == null) return;
    final now = _clock();
    final last = _lastLiveSent;
    final moved = _lastLivePos == null ? 1e9 : distanceM(_lastLivePos!, f.pos);
    // Driving mode (plugged in only): every 5 s once moved 20 m, at least
    // every 30 s; otherwise 15 s / 10 m, at least every 60 s.
    final fast = drivingMode;
    final due =
        last == null ||
        (now.difference(last) >= Duration(seconds: fast ? 5 : 15) &&
            moved > (fast ? 20 : 10)) ||
        now.difference(last) >= Duration(seconds: fast ? 30 : 60);
    if (!due) return;
    _lastLiveSent = now;
    _lastLivePos = f.pos;
    _send(_posMsg(f, checkIn: false), const TripRoute());
  }

  PosMsg _posMsg(Fix f, {required bool checkIn}) => PosMsg(
    _nextId(),
    f.pos,
    checkIn: checkIn,
    accuracyM: f.accuracyM,
    fixAge: _clock().difference(f.at),
    battery: checkIn ? battery?.call() : null,
    speedMps: _wireSpeed(f),
    headingDeg: _wireHeading(f),
  );

  static double? _wireSpeed(Fix f) {
    final v = f.speedMps;
    return v != null && v.isFinite && v >= 0 ? v : null;
  }

  /// Direction only while moving (a still phone's bearing is stale).
  static double? _wireHeading(Fix f) {
    final b = f.bearingDeg, v = _wireSpeed(f);
    return b != null && b.isFinite && b >= 0 && v != null && v >= 1.0
        ? b
        : null;
  }

  /// This phone's battery 0..100 for check-ins (null = unknown), v1.8.3.
  int? Function()? battery;

  /// Battery levels other phones sent with their check-ins.
  final Map<int, ({int pct, DateTime at})> batteries = {};

  DateTime? _lastRadioTrail;

  /// Radio trail summaries sent (tests / Details).
  int radioTrailsSent = 0;

  /// Every [TripSettings.radioTrailMinutes] while recording in trip mode:
  /// a thinned summary of the current trail, radio only, for phones only
  /// the radio reaches (the radio's own rate limit and bulk priority
  /// still apply). Public for tests.
  void maybeSendRadioTrail() {
    final every = settings.radioTrailMinutes;
    if (every <= 0 || !settings.tripMode || !recorder.recording) return;
    final t = recorder.track;
    if (t == null || t.points.length < 2) return;
    final now = _clock();
    final last = _lastRadioTrail;
    if (last != null && now.difference(last) < Duration(minutes: every)) {
      return;
    }
    _lastRadioTrail = now;
    radioTrailsSent++;
    _send(
      trackSummary(t, _nextId()),
      const TripRoute(fast: false, radio: true),
    );
  }

  /// Send a check-in now (also over the radio to far phones).
  Future<bool> checkInNow() async {
    var f = myFix;
    if (f == null || _clock().difference(f.at) > const Duration(minutes: 5)) {
      f = await host.locateOnce() ?? f;
    }
    if (f == null) {
      host.notice('No GPS fix yet: check-in not sent.');
      return false;
    }
    _lastCheckIn = _clock();
    _send(_posMsg(f, checkIn: true), TripRoute(radio: settings.radioCheckIns));
    return true;
  }

  // ------------------------------------------------------------ ticking

  /// Every second (public for tests).
  void tick() {
    final now = _clock();
    sos.tick();
    _ticks++;
    mapNet.tick(onScreen: _onScreen, routing: nav != null || drive != null);
    if (settings.tripMode) {
      final every = checkInMinutesNow;
      if (every > 0 && myFix != null) {
        final last = _lastCheckIn;
        if (last == null || now.difference(last) >= Duration(minutes: every)) {
          _lastCheckIn = now;
          _send(
            _posMsg(myFix!, checkIn: true),
            TripRoute(radio: settings.radioCheckIns),
          );
        }
      }
      _maybeSendLive();
      maybeSendRadioTrail();
    }
    if (_ticks % 5 == 0) {
      _refreshPeers();
      lost.tick();
      store.prune();
      if (recorder.recording) unawaited(_updateLocationNeed());
    }
  }

  void _refreshPeers() {
    final now = _clock();
    final list = host.channelPeers();
    final reach = <int>{};
    for (final p in list) {
      if (p.reachable) reach.add(p.id);
      final h = p.lastHeard;
      if (h != null) {
        final prev = _members[p.id];
        if (prev == null || h.isAfter(prev)) _members[p.id] = h;
        if (lost.enabled) lost.heard(p.id, at: h);
      }
    }
    _members.removeWhere(
      (_, t) => now.difference(t) > const Duration(hours: 24),
    );
    final back = reach.difference(_reachable);
    _reachable
      ..clear()
      ..addAll(reach);
    if (store.enabled) {
      for (final id in back) {
        _deliverHeld(id);
      }
    }
  }

  /// Call when the peer list changes (faster base camp hand-over).
  void onPeersChanged() => _refreshPeers();

  void _deliverHeld(int peer) {
    final items = store.takeFor(peer, _nextId);
    for (final h in items) {
      _send(h, TripRoute(to: peer, radio: true));
    }
    if (items.isNotEmpty) {
      _event(
        peer,
        'Base camp: delivered ${items.length} held message'
            '${items.length == 1 ? '' : 's'} to ${host.nameOf(peer)}',
        'held',
      );
    }
  }

  Set<int> _absent() => {
    for (final id in _members.keys)
      if (!_reachable.contains(id) && id != host.localId) id,
  };

  // ------------------------------------------------------------ sending

  void _send(TripMsg m, TripRoute r) {
    final bytes = m.encode();
    unawaited(host.sendTrip(bytes, r).catchError((_) => <int>{}));
  }

  Future<void> sendCanned({int code = 0, String text = ''}) async {
    final m = CannedMsg(_nextId(), code, text: text);
    _send(m, const TripRoute(radio: true));
    _event(host.localId, 'You: ${m.display}', 'canned');
  }

  Future<MapPin> addPin(PinType type, GeoPoint pos, {String label = ''}) async {
    final m = PinMsg(
      _nextId(),
      pinId: _nextId(),
      type: type,
      pos: pos,
      label: label,
    );
    final pin = MapPin(
      origin: host.localId,
      pinId: m.pinId,
      type: type,
      pos: pos,
      label: m.label,
      at: _clock(),
    );
    _pins[pin.key] = pin;
    _send(m, const TripRoute(radio: true));
    await _savePins();
    notifyListeners();
    return pin;
  }

  Future<void> deletePin(MapPin p) async {
    _pins.remove(p.key);
    if (p.origin == host.localId) {
      _send(
        PinDeleteMsg(_nextId(), pinId: p.pinId),
        const TripRoute(radio: true),
      );
    }
    await _savePins();
    notifyListeners();
  }

  /// Send my pins to everyone (e.g. after someone joins).
  void resendPins() {
    for (final p in pins.where((p) => p.origin == host.localId)) {
      _send(
        PinMsg(
          _nextId(),
          pinId: p.pinId,
          type: p.type,
          pos: p.pos,
          label: p.label,
        ),
        const TripRoute(),
      );
    }
  }

  // ------------------------------------------------------------ SOS

  Future<void> startSos() async {
    final f = myFix;
    final fresh =
        f != null && _clock().difference(f.at) < const Duration(minutes: 2);
    sos.start(fresh ? f.pos : f?.pos, accuracyM: f?.accuracyM);
    _event(host.localId, 'You sent an SOS', 'sos');
    unawaited(_updateLocationNeed());
    if (!fresh) {
      final g = await host.locateOnce();
      if (g != null) onFix(g);
    }
    notifyListeners();
  }

  void cancelSos() {
    sos.cancel();
    _event(host.localId, 'You cancelled your SOS', 'sos');
    unawaited(_updateLocationNeed());
    notifyListeners();
  }

  final _sosAlerts = StreamController<IncomingSos>.broadcast();

  /// New SOS alerts (the UI shows a full-screen alert).
  Stream<IncomingSos> get sosAlerts => _sosAlerts.stream;

  void _onSosAlert(IncomingSos s) {
    final name = host.nameOf(s.origin);
    final text = sosText(s);
    host.showSosAlarm(s, text);
    _event(s.origin, 'SOS from $name', 'sos', pos: s.pos);
    if (!_sosAlerts.isClosed) _sosAlerts.add(s);
  }

  String sosText(IncomingSos s) {
    final me = myFix?.pos;
    final p = s.pos;
    if (p == null) return 'Location unknown. Open the app to help.';
    final where = me == null
        ? '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}'
        : '${formatDistanceBearing(me, p, imperial: settings.imperial)} from you';
    return 'Needs help: $where';
  }

  void acknowledgeSos(IncomingSos s) {
    sos.acknowledge(s);
    _event(
      host.localId,
      'You acknowledged ${host.nameOf(s.origin)}\'s SOS',
      'ack',
    );
  }

  // ------------------------------------------------------------ receiving

  bool _firstTime(String key) {
    final now = _clock();
    while (_seen.isNotEmpty &&
        now.difference(_seen.values.first) > const Duration(hours: 6)) {
      _seen.remove(_seen.keys.first);
    }
    if (_seen.containsKey(key)) return false;
    _seen[key] = now;
    while (_seen.length > 4000) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  /// A Trip message from the transport layer (public for tests).
  void onTrip(InboundTrip t) {
    final decoded = TripMsg.tryDecode(t.payload);
    if (decoded == null) return;
    var origin = t.peerId;
    var msg = decoded;
    var age = Duration.zero;
    var held = false;
    if (decoded is HeldMsg) {
      origin = decoded.origin;
      msg = decoded.inner;
      age = decoded.age;
      held = true;
    }
    if (origin == host.localId) return;
    // SOS reaches you from any public channel; everything else only from
    // the channel you are on.
    final isSos = msg is SosMsg || msg is SosAckMsg;
    if (t.channel != host.scope &&
        !(isSos && !host.privateScope && t.channel < 0x10000)) {
      return;
    }
    if (msg is! SosMsg && !_firstTime(msg.key(origin))) return;
    final now = _clock();
    if (!held && store.enabled) {
      store.hold(origin, msg, t.packetId, _absent());
    }
    final at = now.subtract(age);
    if (lost.enabled) lost.heard(origin, at: at);
    switch (msg) {
      case PosMsg():
        final fixAt = at.subtract(msg.fixAge);
        final p = people[origin];
        if (p == null || !fixAt.isBefore(p.at)) {
          people[origin] =
              PersonPos(origin, msg.pos, fixAt, t.transport, t.hops)
                ..accuracyM = msg.accuracyM
                ..speedMps = msg.speedMps
                ..headingDeg = msg.headingDeg
                ..held = held;
        }
        if (lost.enabled) {
          lost.heard(origin, at: at, pos: msg.pos, posAt: fixAt);
        }
        final bt = msg.battery;
        if (bt != null) {
          final prev = batteries[origin];
          if (prev == null || !at.isBefore(prev.at)) {
            batteries[origin] = (pct: bt, at: at);
          }
        }
      case SosMsg():
        final s = sos.onSos(origin, msg, held: held, age: age);
        if (s != null && msg.pos != null) {
          people[origin] = PersonPos(origin, msg.pos!, at, t.transport, t.hops)
            ..accuracyM = msg.accuracyM;
        }
        if (msg.cancel && s != null) {
          _event(origin, '${host.nameOf(origin)} cancelled their SOS', 'sos');
        }
      case SosAckMsg():
        sos.onAck(origin, msg);
        if (msg.origin != host.localId) {
          _event(
            origin,
            '${host.nameOf(origin)} acknowledged ${host.nameOf(msg.origin)}\'s SOS',
            'ack',
          );
        }
      case CannedMsg():
        final text = msg.display;
        if (text.isEmpty) return;
        _event(
          origin,
          '${host.nameOf(origin)}: $text${held ? ' (${formatAge(age)} ago, via base camp)' : ''}',
          'canned',
          via: t.transport,
        );
        host.notify(host.nameOf(origin), text);
        if (msg.code == 3) host.notice('${host.nameOf(origin)} needs help!');
      case PinMsg():
        final pin = MapPin(
          origin: origin,
          pinId: msg.pinId,
          type: msg.type,
          pos: msg.pos,
          label: msg.label,
          at: at,
        );
        final isNew = !_pins.containsKey(pin.key);
        _pins[pin.key] = pin;
        unawaited(_savePins());
        if (isNew) {
          _event(
            origin,
            '${host.nameOf(origin)} added a pin: ${pin.title}',
            'pin',
            pos: pin.pos,
          );
        }
      case PinDeleteMsg():
        _pins.remove('$origin:${msg.pinId}');
        unawaited(_savePins());
      case TrackMsg():
        final pts = _assembler.add(origin, msg);
        final key = '$origin:${msg.trackId}';
        final first = !sharedTracks.containsKey(key);
        sharedTracks[key] = (origin: origin, points: pts, summary: msg.summary);
        if (first) {
          _event(origin, '${host.nameOf(origin)} shared a trail', 'track');
        }
      case RouteMsg():
        final got = _routes.add(origin, msg, now: now);
        if (got != null) {
          // The full route replaces its LoRa summary if one came first.
          sharedTracks.remove('$origin:${msg.routeId}');
          final who = host.nameOf(origin);
          final d = got.data;
          if (d.name.isEmpty) d.name = 'Route from $who';
          final added = layers.addTrail(d, color: got.color, from: origin);
          lastSharedRoute = added;
          unawaited(
            added.then(
              (_) => _event(origin, '$who shared a route: ${d.name}', 'track'),
              onError: (Object _) => _event(
                origin,
                '$who shared a route, but there is no room for imported maps',
                'track',
              ),
            ),
          );
        }
      case HeldMsg():
        break; // never nested
    }
    notifyListeners();
  }

  void _onLost(ContactState s) {
    final name = host.nameOf(s.id);
    final where = s.lastPos == null
        ? ''
        : ' Last seen ${myFix == null ? 'at ${s.lastPos}' : formatDistanceBearing(myFix!.pos, s.lastPos!, imperial: settings.imperial)}'
              '${s.lastPosAt == null ? '' : ', ${formatAge(_clock().difference(s.lastPosAt!))} ago'}.';
    final text =
        'Not heard from in ${formatAge(_clock().difference(s.lastHeard))}.$where';
    _event(s.id, '$name: $text', 'lost', pos: s.lastPos);
    host.notify('Lost contact with $name', text);
    notifyListeners();
  }

  void _event(
    int origin,
    String text,
    String kind, {
    TransportKind? via,
    GeoPoint? pos,
  }) {
    feed.insert(0, TripEvent(_clock(), origin, text, kind, via: via, pos: pos));
    if (feed.length > 100) feed.removeLast();
    notifyListeners();
  }

  // ------------------------------------------------------------ trails

  void startTrack() {
    if (recorder.recording) return;
    final now = DateTime.now();
    recorder.start(
      _nextId(),
      name:
          'Trail ${now.month}/${now.day} ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
    );
    final f = myFix;
    if (f != null) recorder.add(f.pos, f.at, accuracyM: f.accuracyM);
    unawaited(_updateLocationNeed());
    notifyListeners();
  }

  Future<Track?> stopTrack() async {
    final t = recorder.stop();
    if (t != null && t.points.length > 1) {
      savedTracks.insert(0, t);
      while (savedTracks.length > 20) {
        savedTracks.removeLast();
      }
    }
    await _saveTracks();
    unawaited(_updateLocationNeed());
    notifyListeners();
    return t;
  }

  /// Trail being recorded, or the newest saved one.
  Track? get currentTrack =>
      recorder.track ?? (savedTracks.isEmpty ? null : savedTracks.first);

  /// Share a trail: full detail on fast links, plus a thinned summary over
  /// the radio for far phones.
  void shareTrack(Track t) {
    if (t.points.length < 2) return;
    for (final m in trackMessages(t, _nextId)) {
      _send(m, const TripRoute());
    }
    _send(
      trackSummary(t, _nextId()),
      const TripRoute(fast: false, radio: true),
    );
    _event(
      host.localId,
      'You shared ${t.name.isEmpty ? 'a trail' : t.name}',
      'track',
    );
  }

  /// Share an imported trail layer: the whole thing, compressed, over fast
  /// links; over LoRa only a thinned line (16 points within 150 m of the
  /// real one) or nothing. Returns (fast parts, radio summary sent).
  ({int parts, bool radio}) shareLayer(MapLayer l) {
    final d = l.data;
    if (d == null || l.kind != MapLayerKind.trail || d.isEmpty) {
      return (parts: 0, radio: false);
    }
    return _shareData(d, l.name, l.color);
  }

  ({int parts, bool radio}) _shareData(ImportedData d, String name, int color) {
    final routeId = _nextId();
    final parts = routeMessages(d, routeId, _nextId, color: color) ?? [];
    for (final m in parts) {
      _send(m, const TripRoute());
    }
    final s = routeRadioSummary(d, routeId, _nextId());
    if (s != null) _send(s, const TripRoute(fast: false, radio: true));
    _event(host.localId, 'You shared $name', 'track');
    return (parts: parts.length, radio: s != null);
  }

  Future<void> deleteTrack(Track t) async {
    savedTracks.remove(t);
    await _saveTracks();
    notifyListeners();
  }

  /// Write a GPX file and open the share sheet. Returns the file path.
  Future<String?> exportGpx(Track t, Directory tmp) async {
    try {
      final dirOut = Directory('${tmp.path}/exports');
      await dirOut.create(recursive: true);
      final safe = t.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      final f = File('${dirOut.path}/${safe.isEmpty ? 'trail' : safe}.gpx');
      await f.writeAsString(
        toGpx(
          t.name.isEmpty ? 'Trail' : t.name,
          t.points,
          waypoints: [
            for (final p in pins)
              (pos: p.pos, name: p.title, type: p.type.label),
          ],
        ),
      );
      await host.shareFile(f.path, 'application/gpx+xml', t.name);
      return f.path;
    } catch (_) {
      host.notice('Could not export the trail.');
      return null;
    }
  }

  // ------------------------------------------------------------ weather

  Future<bool> refreshWeather({bool force = false}) async {
    final p = myFix?.pos ?? weather.forecast?.place;
    if (p == null) return false;
    final f = weather.forecast;
    if (!force &&
        f != null &&
        DateTime.now().difference(f.at) < const Duration(hours: 3) &&
        distanceM(f.place, p) < 20000 &&
        f.imperial == settings.imperial) {
      return false;
    }
    _weatherTried = DateTime.now();
    final ok = await weather.refresh(p, imperial: settings.imperial);
    notifyListeners();
    return ok;
  }

  Future<void> maybeRefreshWeather() async {
    if (!plan.weatherAutoRefresh) return;
    final t = _weatherTried;
    if (t != null &&
        DateTime.now().difference(t) < const Duration(minutes: 10)) {
      return;
    }
    await refreshWeather();
  }

  // ------------------------------------------------------------ settings

  Future<void> update(void Function(TripSettings s) f) async {
    f(settings);
    _applySettings();
    await host.saveTripSettings();
    await _updateLocationNeed();
    if (settings.tripMode) _maybeSendLive();
    notifyListeners();
  }

  // ------------------------------------------------------------ search

  /// Everything searchable besides imported layers: pins, people, recorded
  /// and shared trails, downloaded areas and imported MBTiles maps.
  List<SearchDoc> searchDocs() {
    final me = host.localId;
    final out = <SearchDoc>[
      for (final p in pins)
        SearchDoc(
          kind: p.origin == me ? SearchKind.pin : SearchKind.sharedPin,
          title: p.title,
          subtitle: [
            p.type.label,
            if (p.origin != me) 'from ${host.nameOf(p.origin)}',
          ].join(' · '),
          pos: p.pos,
          ref: p.key,
          placeKind: p.type.label,
        ),
      for (final pp in people.values)
        SearchDoc(
          kind: SearchKind.person,
          title: host.nameOf(pp.id),
          subtitle:
              'Last seen ${pp.at.hour.toString().padLeft(2, '0')}:'
              '${pp.at.minute.toString().padLeft(2, '0')}',
          pos: pp.pos,
          ref: '${pp.id}',
        ),
      for (final t in [...savedTracks, ?recorder.track])
        if (t.points.isNotEmpty)
          SearchDoc(
            kind: SearchKind.track,
            title: t.name.isEmpty ? 'Trail ${t.id}' : t.name,
            subtitle: t == recorder.track ? 'Recording now' : 'My trail',
            pos: t.points.last.pos,
            line: [for (final x in t.points) x.pos],
            bounds: boundsOfPoints(t.points.map((x) => x.pos)),
            ref: '${t.id}',
            lengthM: t.lengthM,
          ),
      for (final e in sharedTracks.entries)
        if (e.value.points.isNotEmpty)
          SearchDoc(
            kind: SearchKind.track,
            title: "${host.nameOf(e.value.origin)}'s trail",
            subtitle: 'Shared trail',
            pos: e.value.points.last.pos,
            line: [for (final x in e.value.points) x.pos],
            bounds: boundsOfPoints(e.value.points.map((x) => x.pos)),
            ref: e.key,
          ),
      for (final r in tiles.regions)
        SearchDoc(
          kind: SearchKind.area,
          title: r.name,
          subtitle: 'Downloaded map · zoom ${r.minZoom}-${r.maxZoom}',
          pos: r.bounds.center,
          bounds: r.bounds,
          ref: 'region:${r.name}',
        ),
    ];
    for (final l in layers.tileSets) {
      final b = layers.tilesOf(l.id)?.bounds;
      if (b == null) continue;
      out.add(
        SearchDoc(
          kind: SearchKind.area,
          title: l.name,
          subtitle: 'Imported offline map',
          pos: b.center,
          bounds: b,
          ref: 'layer:${l.id}',
          layerId: l.id,
        ),
      );
    }
    return out;
  }

  /// Offline search (no network): imported trails and places, pins,
  /// people, trails and downloaded areas, best first (closer wins ties).
  List<SearchHit> searchOffline(
    String query, {
    GeoPoint? near,
    int limit = 40,
  }) => layers.index.search(
    query,
    extra: searchDocs(),
    near: near ?? myFix?.pos,
    limit: limit,
  );

  /// Online places for [query] (never throws; says when there is no
  /// signal).
  Future<OnlineSearchResult> findPlaces(String query) =>
      search.findPlaces(query);

  /// "Get trails for this area": OSM trails and places for [place] (or the
  /// area on screen) saved as an offline layer with OSM attribution.
  /// Throws [NoSignalException], [FetchException] or
  /// [StorageLimitException].
  Future<({MapLayer layer, OverpassResult result, bool trimmed})>
  importTrailsFor({PlaceResult? place, GeoBounds? visible}) async {
    final area = areaForPlace(place, visible: visible);
    final name = place == null
        ? 'Trails on screen'
        : '${place.name.isEmpty ? 'Area' : place.name} trails';
    final r = await search.trailsFor(
      area.bounds,
      areaId: area.trimmed ? null : place?.overpassAreaId,
      name: name,
    );
    if (r.data.isEmpty) {
      throw FetchException(
        'No named trails or places found here in OpenStreetMap.',
      );
    }
    final l = await layers.addTrail(
      r.data,
      attribution: osmAttribution,
      color: 0xFF6D4C41,
    );
    return (layer: l, result: r, trimmed: area.trimmed);
  }

  // ------------------------------------------------------------ storage

  File get _pinsFile => File('${dir.path}/pins.json');
  File get _tracksFile => File('${dir.path}/tracks.json');

  Future<void> _loadPins() async {
    try {
      if (!await _pinsFile.exists()) return;
      for (final j in jsonDecode(await _pinsFile.readAsString()) as List) {
        final p = MapPin.fromJson(j);
        if (p != null) _pins[p.key] = p;
      }
    } catch (_) {}
  }

  Future<void> _savePins() async {
    try {
      await dir.create(recursive: true);
      await _pinsFile.writeAsString(
        jsonEncode([for (final p in pins) p.toJson()]),
      );
    } catch (_) {}
  }

  Future<void> _loadTracks() async {
    try {
      if (!await _tracksFile.exists()) return;
      final j = jsonDecode(await _tracksFile.readAsString()) as Map;
      savedTracks
        ..clear()
        ..addAll(decodeTracks(jsonEncode(j['saved'] ?? [])));
      final cur = Track.fromJson(j['rec']);
      if (cur != null) {
        // Recording survived an app restart: carry on.
        recorder.start(cur.id, name: cur.name);
        recorder.track!.points.addAll(cur.points);
      }
    } catch (_) {}
  }

  Future<void> _saveTracks() async {
    try {
      await dir.create(recursive: true);
      await _tracksFile.writeAsString(
        jsonEncode({
          'saved': [for (final t in savedTracks) t.toJson()],
          'rec': recorder.track?.toJson(),
        }),
      );
    } catch (_) {}
  }

  /// Forget everything shared (positions, pins from others, trails).
  Future<void> clearTripData() async {
    people.clear();
    _pins.removeWhere((_, p) => p.origin != host.localId);
    sharedTracks.clear();
    feed.clear();
    lost.clear();
    store.clear();
    await _savePins();
    notifyListeners();
  }
}
