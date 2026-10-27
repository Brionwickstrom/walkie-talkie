import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/power_plan.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart' show InboundTrip;
import 'geo.dart';
import 'imports/geo_import.dart' show ImportedData;
import 'imports/map_layers.dart';
import 'imports/route_share.dart';
import 'lost_contact.dart';
import 'drive/drive_nav.dart' show spokenDistance;
import 'drive/drive_session.dart';
import 'drive/road_download.dart';
import 'drive/road_service.dart';
import 'drive/speech.dart';
import 'imports/geo_import.dart' show ImportedWaypoint;
import 'nav/nav_session.dart';
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
  const Fix(this.pos, this.at, {this.accuracyM, this.speedMps, this.altM});
  final GeoPoint pos;
  final DateTime at;
  final double? accuracyM;
  final double? speedMps;
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
  Future<bool> startLocation(Duration interval);
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
    layers = MapLayers(Directory('${dir.path}/layers'), clock: _clock);
    weather = WeatherCache(
      File('${dir.path}/weather.json'),
      userAgent: userAgent,
    );
    final f = fetch ?? ioFetch(userAgent);
    this.fetch = f;
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

  /// Imported trails, offline MBTiles maps and park map overlays (v1.8.3).
  late final MapLayers layers;
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
    ]);
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
    tiles.close();
    layers.close();
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
      _visible ||
      nav != null ||
      drive != null;

  Duration get _wantedInterval {
    final now = _clock();
    final p = plan;
    if (drive != null) return p.driveInterval;
    if (sos.active != null) return const Duration(seconds: 5);
    if (nav != null) return p.navInterval;
    if (recorder.recording) {
      return recorder.interval(now, saver: p.transportSaver);
    }
    return p.gpsInterval(visible: _visible, sosActive: false);
  }

  /// GPS interval asked for right now (tests / debug).
  Duration? get locationInterval => _locInterval;

  Future<void> _updateLocationNeed() async {
    if (!_started) return;
    if (_needLocation) {
      final want = _wantedInterval;
      if (_locInterval != want) {
        _locInterval = want;
        final ok = await host.startLocation(want);
        if (!ok) _locInterval = null;
      }
    } else if (_locInterval != null) {
      _locInterval = null;
      await host.stopLocation();
    }
    final bg =
        settings.tripMode ||
        recorder.recording ||
        sos.active != null ||
        nav != null ||
        drive != null;
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
    _maybeSendLive();
    _navFix(f.pos);
    _driveFix(f);
    notifyListeners();
  }

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
    final g = await trailGraph();
    final r = g.route(me, s.target);
    if (r == null || nav != s) return false;
    await _elevation(r);
    if (nav != s || _disposed) return false;
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

  // ------------------------------------------------------------ driving

  /// "Drive here" in progress (v1.9.2), null when not driving.
  DriveSession? drive;

  /// Routing over the saved road areas (background isolate).
  RoadService roads = RoadService();

  /// Spoken directions (the phone's offline text-to-speech).
  Speaker speaker = TtsSpeaker();
  DateTime? _lastDriveReroute;

  Future<void> _say(String text) => speaker.say(text);

  /// Saved road areas (all of them are used together).
  List<MapLayer> get roadAreas => layers.roads;

  Future<void> _loadRoads() {
    final paths = [for (final l in layers.roads) layers.fileOf(l).path]..sort();
    return roads.load(paths);
  }

  static const noRoadsMessage =
      'No roads saved on this phone yet. Add "Portland to Gifford Pinchot '
      'roads" in Ready-made maps, or save an area in Offline roads.';

  /// Start driving to [to] along the saved roads. [hikeTo]: walk on to
  /// there after arriving (trail navigation starts by itself). Returns the
  /// session, or a message saying why not.
  Future<({DriveSession? session, String message})> driveTo(
    GeoPoint to, {
    String name = 'Destination',
    GeoPoint? hikeTo,
    String hikeName = '',
  }) async {
    if (layers.roads.isEmpty) return (session: null, message: noRoadsMessage);
    final me = myFix?.pos ?? (await host.locateOnce())?.pos;
    if (me == null) {
      return (
        session: null,
        message: 'Waiting for GPS. Try again in a moment.',
      );
    }
    await _loadRoads();
    final r = await roads.route(
      me,
      to,
      name: name,
      imperial: settings.imperial,
      now: _clock(),
    );
    if (r == null) {
      final a = await roads.snap(me), b = await roads.snap(to);
      final why = a == null
          ? 'You are not near any saved roads. Save the area you are in '
                '(Offline roads) or use a ready-made pack.'
          : b == null
          ? 'No saved roads near there.'
          : 'No road route found: the roads there do not connect (a gate or '
                'private road may block the way).';
      return (session: null, message: why);
    }
    if (_disposed) return (session: null, message: '');
    final s = DriveSession(
      target: to,
      name: name,
      route: r,
      imperial: settings.imperial,
      hikeTo: hikeTo,
      hikeName: hikeName,
    );
    nav?.dispose();
    nav = null;
    drive?.dispose();
    drive = s;
    _lastDriveReroute = null;
    final f = myFix;
    _speakDrive(s.update(me, speed: f?.speedMps, at: f?.at).say);
    await _updateLocationNeed();
    notifyListeners();
    return (session: s, message: '');
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

  /// Route again from where you are.
  Future<bool> rerouteDrive() async {
    final s = drive;
    final me = myFix?.pos ?? s?.me;
    if (s == null || me == null) return false;
    _lastDriveReroute = _clock();
    s.rerouting = true;
    notifyListeners();
    await _loadRoads();
    final r = await roads.route(
      me,
      s.target,
      name: s.name,
      imperial: settings.imperial,
      now: _clock(),
    );
    if (drive != s || _disposed) return false;
    if (r == null) {
      s.rerouting = false;
      notifyListeners();
      return false;
    }
    s.replaceRoute(r);
    notifyListeners();
    return true;
  }

  Future<void> stopDrive() async {
    drive?.dispose();
    drive = null;
    await speaker.stop();
    await _updateLocationNeed();
    notifyListeners();
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
        unawaited(walkOn());
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
        unawaited(rerouteDrive());
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
    return navigateTo(to, name: name);
  }

  /// "Drive to trailhead, then hike": the trailhead to drive to for
  /// walking to [to] (a trailhead waypoint near the trails that lead
  /// there, close to a saved road), or the nearest road point.
  Future<({GeoPoint at, String name})?> trailheadFor(GeoPoint to) async {
    await _loadRoads();
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
      final road = await roads.snap(w.pos, maxM: 500);
      if (road == null) continue;
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
    final road = await roads.snap(to, maxM: 10000);
    if (road == null) return null;
    return (at: road.pos, name: 'the nearest road');
  }

  /// Drive to the best trailhead for [to], then hike there.
  Future<({DriveSession? session, String message})> driveThenHike(
    GeoPoint to, {
    String name = 'Destination',
  }) async {
    if (layers.roads.isEmpty) return (session: null, message: noRoadsMessage);
    final th = await trailheadFor(to);
    if (th == null) {
      return (session: null, message: 'No saved roads near there.');
    }
    return driveTo(th.at, name: th.name, hikeTo: to, hikeName: name);
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
    final due =
        last == null ||
        (now.difference(last) >= const Duration(seconds: 15) && moved > 10) ||
        now.difference(last) >= const Duration(seconds: 60);
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
  );

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
