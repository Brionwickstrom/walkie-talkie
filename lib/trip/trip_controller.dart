import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/transport.dart';
import '../core/transport_manager.dart' show InboundTrip;
import 'geo.dart';
import 'lost_contact.dart';
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
    weather = WeatherCache(
      File('${dir.path}/weather.json'),
      userAgent: userAgent,
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
  late final WeatherCache weather;
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
    'osm' => MapSource.osm,
    'custom' when settings.customTileUrl.trim().isNotEmpty => MapSource.custom(
      settings.customTileUrl.trim(),
    ),
    _ => MapSource.topo,
  };

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
    ]);
    unawaited(tiles.trim());
    await _updateLocationNeed();
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    tiles.close();
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

  bool get _needLocation =>
      settings.tripMode || recorder.recording || sos.active != null || _visible;

  Duration get _wantedInterval {
    final now = _clock();
    if (sos.active != null) return const Duration(seconds: 5);
    if (recorder.recording) {
      return recorder.interval(now, saver: host.powerSaver);
    }
    if (_visible) return const Duration(seconds: 5);
    return Duration(seconds: host.powerSaver ? 60 : 20);
  }

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
    final bg = settings.tripMode || recorder.recording || sos.active != null;
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
    notifyListeners();
  }

  void onHeading(double h) {
    final prev = heading;
    heading = smoothAngle(prev, h, 0.2);
    if (prev == null || deltaDeg(heading!, prev).abs() > 2) notifyListeners();
  }

  void _maybeSendLive() {
    if (!settings.tripMode) return;
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
  );

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
      final every = settings.checkInMinutes;
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
