import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/transport.dart';
import '../core/transport_manager.dart';
import 'stun.dart';

/// Direct phone-to-phone links over the internet (v1.8.9).
///
/// Two phones in the same relay room on different networks (cell, other
/// Wi-Fi) try to reach each other straight over UDP, skipping the relay:
///
/// 1. Each phone learns its public UDP address from free public STUN
///    servers (Google, Cloudflare) and lists its local addresses (IPv4 and
///    IPv6; many carriers give phones real IPv6 addresses with no NAT).
/// 2. They swap those "candidates" plus a random per-link token through
///    the relays, as normal (and, on private channels, sealed) room frames
///    ([ControlKind.dx], see [TransportManager.sendDirectSignal]).
/// 3. Both send small probes to every candidate of the other for a few
///    seconds ("hole punching"). The first probe that gets through opens
///    the link. Strict carrier NATs (CGNAT, symmetric NAT) often block
///    this; then nothing changes and the relays carry everything, as
///    before. No TURN server.
///
/// Every packet carries the receiver's token (learnt only through the
/// relay signaling), so nobody else can inject traffic. Frames are the
/// same bytes the relay gets (sealed on private channels).
///
/// While up, a tiny ping every [keepAlive] keeps the NAT mapping open; no
/// answer for [deadAfter] closes the link. A failed attempt is retried
/// after [retryDelays] (30 s, 2, 5, then every 10 min), right away after a
/// network change.
class DirectLinks {
  DirectLinks({
    this.stunServers = Stun.defaultServers,
    this.hostAddresses,
    this.enableV6 = true,
    this.punchInterval = const Duration(milliseconds: 200),
    this.punchFor = const Duration(seconds: 8),
    this.keepAlive = const Duration(seconds: 15),
    this.deadAfter = const Duration(seconds: 40),
    this.stunTimeout = const Duration(milliseconds: 1500),
    this.offerTimeout = const Duration(seconds: 12),
    this.checkEvery = const Duration(seconds: 5),
    this.retryDelays = const [
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 5),
      Duration(minutes: 10),
    ],
    this.forgetAfter = const Duration(seconds: 60),
    this.gatherCacheFor = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final List<(String, int)> stunServers;

  /// Local addresses to offer instead of the phone's interfaces (tests).
  final Future<List<InternetAddress>> Function()? hostAddresses;
  final bool enableV6;
  final Duration punchInterval;
  final Duration punchFor;
  Duration keepAlive;
  final Duration deadAfter;
  final Duration stunTimeout;
  final Duration offerTimeout;
  final Duration checkEvery;
  final List<Duration> retryDelays;
  final Duration forgetAfter;
  final Duration gatherCacheFor;
  final DateTime Function() _clock;

  /// Sends a signaling message to [to] through the relays.
  void Function(int to, Map<String, Object?> x)? signal;

  /// Peers that should have a direct link right now (same room, new enough
  /// app, heard over the internet, no local Wi-Fi / Bluetooth link).
  Iterable<int> Function()? wantedPeers;

  /// Debug log lines ("direct link up to 1a2b via IPv6", ...).
  void Function(String line)? onEvent;

  static const int _magic0 = 0x57; // 'W'
  static const int _magic1 = 0x44; // 'D'
  static const int _version = 1;
  static const int headerSize = 16;
  static const int _probe = 1, _probeAck = 2, _data = 3, _ping = 4;
  static const int _pong = 5, _bye = 6;

  /// Feature level ([featureLevel]) of phones that do direct links.
  static const int feature = 20;

  int localId = 0;
  bool _running = false;
  bool _saver = false;
  RawDatagramSocket? _v4;
  RawDatagramSocket? _v6;
  final Map<int, _Link> _links = {};
  final Map<String, _Link> _byToken = {};
  final Map<String, Completer<({InternetAddress address, int port})>> _stun =
      {};
  Timer? _tick;
  _Gather? _gather;
  Future<_Gather>? _gathering;
  final _frames = StreamController<InboundFrame>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final _rnd = Random.secure();

  /// Counters for the debug line.
  int linksOpened = 0;
  int attemptsFailed = 0;

  Stream<InboundFrame> get frames => _frames.stream;

  /// A link came up or went down.
  Stream<void> get changes => _changes.stream;

  bool get running => _running;

  bool isUp(int peerId) => _links[peerId]?.state == _State.up;

  Set<int> get upPeers => {
    for (final l in _links.values)
      if (l.state == _State.up) l.peerId,
  };

  /// "IPv6" / "IPv4" path of the link to [peerId], null when not up.
  String? pathOf(int peerId) {
    final l = _links[peerId];
    if (l == null || l.state != _State.up) return null;
    return l.endpoint!.address.type == InternetAddressType.IPv6
        ? 'IPv6'
        : 'IPv4';
  }

  /// What the last STUN check found (null = not run yet).
  NatInfo? get nat => _gather?.nat;

  String get debugInfo {
    final up = upPeers.length;
    final n = nat;
    return 'direct $up up'
        '${n != null ? ' · ${n.summary}' : ''}'
        '${attemptsFailed > 0 ? ' · failed $attemptsFailed' : ''}';
  }

  /// Signal through [m] (sealed on private channels) and take its list of
  /// phones that should get a direct link.
  void attach(TransportManager m) {
    signal = (to, x) => unawaited(m.sendDirectSignal(to, x));
    wantedPeers = m.directCandidates;
    m.onDirectSignal = onSignal;
  }

  /// Connection test: a fresh STUN check of this network (null when
  /// direct links are off, e.g. Offline power save).
  Future<NatInfo?> probeNat() async {
    if (!_running) return null;
    _gather = null;
    try {
      return (await _gatherNow()).nat;
    } catch (_) {
      return null;
    }
  }

  Future<void> start({required int localNodeId}) async {
    localId = localNodeId;
    if (_running) return;
    _running = true;
    _tick?.cancel();
    _tick = Timer.periodic(checkEvery, (_) => _onTick());
    // First check soon (peers are learnt from the first hellos).
    Timer(const Duration(milliseconds: 500), _onTick);
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _tick?.cancel();
    _tick = null;
    for (final l in _links.values.toList()) {
      if (l.state == _State.up) _sendPacket(l, _bye);
      _close(l, null, notify: false);
    }
    _links.clear();
    _byToken.clear();
    _closeSockets();
    _gather = null;
    _gathering = null;
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _changes.close();
  }

  void setPowerSaver(bool on) {
    _saver = on;
    keepAlive = on ? const Duration(seconds: 25) : const Duration(seconds: 15);
  }

  /// The phone changed networks: every link and address is stale. Drop
  /// them and ask the peers to start over right away.
  void networkChanged() {
    if (!_running) return;
    final had = [
      for (final l in _links.values)
        if (l.state != _State.idle) l.peerId,
    ];
    for (final l in _links.values.toList()) {
      _close(l, null, notify: false);
      l.failures = 0;
      l.nextTry = null;
    }
    _closeSockets();
    _gather = null;
    _gathering = null;
    if (!_changes.isClosed) _changes.add(null);
    for (final id in had) {
      if (localId < id) {
        final l = _links[id];
        if (l != null) unawaited(_offer(l));
      } else {
        signal?.call(id, {'op': 'r'});
      }
    }
  }

  /// Send [bytes] (an encoded frame) to [peerId] when its link is up.
  bool send(int peerId, Uint8List bytes) {
    final l = _links[peerId];
    if (l == null || l.state != _State.up) return false;
    return _sendPacket(l, _data, bytes);
  }

  // ------------------------------------------------------------ signaling

  void onSignal(int from, Map<String, Object?> x) {
    if (!_running || from == localId) return;
    final op = x['op'];
    final now = _clock();
    switch (op) {
      case 'o':
        final tk = _token(x['tk']);
        final s = (x['s'] as num?)?.toInt();
        final cands = _parseCands(x['c']);
        if (tk == null || s == null) return;
        final l = _links.putIfAbsent(from, () => _Link(from));
        l.lastWanted ??= now;
        // Rate limit: one answered offer per peer per 3 s.
        if (l.lastOfferIn != null &&
            now.difference(l.lastOfferIn!) < const Duration(seconds: 3) &&
            l.session == s) {
          return;
        }
        l.lastOfferIn = now;
        _close(l, null, notify: l.state == _State.up);
        l.session = s;
        l.theirToken = tk;
        l.cands = cands;
        _newToken(l);
        unawaited(() async {
          final g = await _gatherNow();
          if (!_running || l.session != s) return;
          signal?.call(from, {
            'op': 'a',
            's': s,
            'tk': _hex(l.myToken!),
            'c': g.candidates,
          });
          _punch(l);
        }());
      case 'a':
        final l = _links[from];
        final s = (x['s'] as num?)?.toInt();
        final tk = _token(x['tk']);
        if (l == null || l.state != _State.offering || l.session != s) return;
        if (tk == null) return;
        l.theirToken = tk;
        l.cands = _parseCands(x['c']);
        _punch(l);
      case 'r':
        // The other phone changed networks and asks for a fresh offer.
        if (localId > from) return;
        final l = _links.putIfAbsent(from, () => _Link(from));
        // Already starting over (an offer in flight): nothing to do.
        if ((l.state == _State.offering || l.state == _State.punching) &&
            l.lastOfferOut != null &&
            now.difference(l.lastOfferOut!) < const Duration(seconds: 3)) {
          return;
        }
        _close(l, null, notify: l.state == _State.up);
        l.failures = 0;
        l.nextTry = null;
        unawaited(_offer(l));
      case 'x':
        final l = _links[from];
        if (l != null) _close(l, 'closed by the other phone');
    }
  }

  Future<void> _offer(_Link l) async {
    if (!_running) return;
    l.state = _State.offering;
    l.session = _rnd.nextInt(0x7FFFFFFF);
    l.theirToken = null;
    l.cands = const [];
    l.lastOfferOut = _clock();
    l.deadline = _clock().add(offerTimeout);
    _newToken(l);
    final s = l.session;
    final g = await _gatherNow();
    if (!_running || l.session != s || l.state != _State.offering) return;
    signal?.call(l.peerId, {
      'op': 'o',
      's': s,
      'tk': _hex(l.myToken!),
      'c': g.candidates,
    });
  }

  void _punch(_Link l) {
    if (!_running) return;
    l.state = _State.punching;
    l.deadline = _clock().add(punchFor);
    l.punchTimer?.cancel();
    void burst() {
      if (l.state != _State.punching) {
        l.punchTimer?.cancel();
        return;
      }
      if (_clock().isAfter(l.deadline!)) {
        l.punchTimer?.cancel();
        _fail(l, 'no answer (strict NAT / carrier NAT)');
        return;
      }
      for (final c in l.cands) {
        _sendTo(l, _probe, c.$1, c.$2);
      }
    }

    burst();
    l.punchTimer = Timer.periodic(punchInterval, (_) => burst());
  }

  void _fail(_Link l, String why) {
    _close(l, null, notify: false);
    l.failures++;
    attemptsFailed++;
    final d = retryDelays[min(l.failures - 1, retryDelays.length - 1)];
    l.nextTry = _clock().add(d);
    onEvent?.call(
      'direct link to ${_id(l.peerId)} failed: $why; relay keeps working, '
      'retry in ${d.inSeconds >= 120 ? '${d.inMinutes} min' : '${d.inSeconds}s'}',
    );
  }

  void _close(_Link l, String? why, {bool notify = true}) {
    final wasUp = l.state == _State.up;
    l.punchTimer?.cancel();
    l.punchTimer = null;
    if (l.myToken != null) _byToken.remove(_hex(l.myToken!));
    l.myToken = null;
    l.theirToken = null;
    l.state = _State.idle;
    l.endpoint = null;
    if (wasUp) {
      if (why != null) {
        onEvent?.call('direct link to ${_id(l.peerId)} down: $why');
      }
      if (notify && !_changes.isClosed) _changes.add(null);
    }
  }

  void _onTick() {
    if (!_running) return;
    final now = _clock();
    final wanted = (wantedPeers?.call() ?? const <int>[]).toSet();
    for (final id in wanted) {
      if (id == localId) continue;
      final l = _links.putIfAbsent(id, () => _Link(id));
      l.lastWanted = now;
      final due = l.nextTry == null || !now.isBefore(l.nextTry!);
      if (l.state == _State.idle && due && localId < id) unawaited(_offer(l));
    }
    for (final l in _links.values.toList()) {
      switch (l.state) {
        case _State.offering:
          if (l.deadline != null && now.isAfter(l.deadline!)) {
            _fail(l, 'no answer through the relay');
          }
        case _State.up:
          if (now.difference(l.lastRx) > deadAfter) {
            _close(l, 'no answer for ${deadAfter.inSeconds}s');
            l.nextTry = null; // try again at the next check
          } else if (now.difference(l.lastTx) >= keepAlive) {
            _sendPacket(l, _ping);
          }
        default:
          break;
      }
      final last = l.lastWanted;
      if (!wanted.contains(l.peerId) &&
          (last == null || now.difference(last) > forgetAfter)) {
        if (l.state == _State.up) _sendPacket(l, _bye);
        _close(l, l.state == _State.up ? 'not needed any more' : null);
        _links.remove(l.peerId);
      }
    }
  }

  // ------------------------------------------------------------- packets

  bool _sendPacket(_Link l, int type, [Uint8List? payload]) {
    final e = l.endpoint;
    if (e == null) return false;
    return _sendTo(l, type, e.address, e.port, payload);
  }

  bool _sendTo(
    _Link l,
    int type,
    InternetAddress addr,
    int port, [
    Uint8List? payload,
  ]) {
    final tk = l.theirToken;
    if (tk == null) return false;
    final s = addr.type == InternetAddressType.IPv6 ? _v6 : _v4;
    if (s == null) return false;
    final p = Uint8List(headerSize + (payload?.length ?? 0));
    p[0] = _magic0;
    p[1] = _magic1;
    p[2] = _version;
    p[3] = type;
    p.setRange(4, 12, tk);
    ByteData.sublistView(p).setUint32(12, localId);
    if (payload != null) p.setRange(headerSize, p.length, payload);
    try {
      final n = s.send(p, addr, port);
      if (type != _probe) l.lastTx = _clock();
      return n > 0;
    } catch (_) {
      return false;
    }
  }

  void _onPacket(Datagram d, RawDatagramSocket sock) {
    final b = d.data;
    if (Stun.isStun(b)) {
      final c = _stun.remove(Stun.txKey(b));
      final m = Stun.parseMapped(b);
      if (c != null && m != null && !c.isCompleted) c.complete(m);
      return;
    }
    if (b.length < headerSize || b[0] != _magic0 || b[1] != _magic1) return;
    if (b[2] != _version) return;
    final l = _byToken[_hex(Uint8List.sublistView(b, 4, 12))];
    if (l == null) return;
    final from = ByteData.sublistView(b).getUint32(12);
    if (from != l.peerId) return;
    final now = _clock();
    final type = b[3];
    if (type == _bye) {
      _close(l, 'closed by the other phone');
      return;
    }
    if (l.theirToken == null) return; // offer still on its way
    l.lastRx = now;
    switch (type) {
      case _probe:
        _sendTo(l, _probeAck, d.address, d.port);
        _up(l, d.address, d.port);
      case _probeAck:
        _up(l, d.address, d.port);
      case _data:
        l.lastWanted = now; // the other phone uses it: keep it
        _up(l, d.address, d.port);
        final f = Frame.tryDecode(Uint8List.sublistView(b, headerSize));
        if (f != null && !_frames.isClosed) {
          _frames.add(InboundFrame(f, TransportKind.internet));
        }
      case _ping:
        l.lastWanted = now;
        _up(l, d.address, d.port);
        _sendTo(l, _pong, d.address, d.port);
      case _pong:
        _up(l, d.address, d.port);
    }
  }

  void _up(_Link l, InternetAddress addr, int port) {
    if (l.state == _State.up) {
      // NAT rebinding / the peer moved: follow the newest working address.
      final e = l.endpoint!;
      if (e.address != addr || e.port != port) {
        l.endpoint = (address: addr, port: port);
      }
      return;
    }
    if (l.state != _State.punching && l.state != _State.offering) return;
    l.punchTimer?.cancel();
    l.punchTimer = null;
    l.state = _State.up;
    l.endpoint = (address: addr, port: port);
    l.lastRx = _clock();
    l.lastTx = _clock();
    l.failures = 0;
    l.nextTry = null;
    linksOpened++;
    onEvent?.call(
      'direct link up to ${_id(l.peerId)} via '
      '${addr.type == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4'}',
    );
    if (!_changes.isClosed) _changes.add(null);
  }

  // ------------------------------------------------------------- gather

  Future<_Gather> _gatherNow() {
    final g = _gather;
    if (g != null && _clock().difference(g.at) < gatherCacheFor) {
      return Future.value(g);
    }
    return _gathering ??= _doGather().whenComplete(() => _gathering = null);
  }

  Future<void> _bind() async {
    if (_v4 == null) {
      try {
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        _v4 = s;
        s.listen((e) {
          if (e != RawSocketEvent.read) return;
          Datagram? d;
          while ((d = s.receive()) != null) {
            _onPacket(d!, s);
          }
        }, onError: (_) {});
      } catch (_) {}
    }
    if (enableV6 && _v6 == null) {
      try {
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
        _v6 = s;
        s.listen((e) {
          if (e != RawSocketEvent.read) return;
          Datagram? d;
          while ((d = s.receive()) != null) {
            _onPacket(d!, s);
          }
        }, onError: (_) {});
      } catch (_) {}
    }
  }

  void _closeSockets() {
    _v4?.close();
    _v6?.close();
    _v4 = null;
    _v6 = null;
    for (final c in _stun.values) {
      if (!c.isCompleted) c.completeError('closed');
    }
    _stun.clear();
  }

  Future<_Gather> _doGather() async {
    await _bind();
    final cands = <String>[];
    final v4 = _v4, v6 = _v6;
    void add(InternetAddress a, int port) {
      final s = '${a.address}#$port';
      if (!cands.contains(s) && cands.length < 10) cands.add(s);
    }

    // Public addresses from STUN (IPv4 and, where there is one, IPv6).
    final queries = <Future<({InternetAddress address, int port})?>>[];
    for (final (host, port) in stunServers) {
      if (v4 != null) queries.add(_stunQuery(v4, host, port, v6: false));
    }
    if (v6 != null && stunServers.isNotEmpty) {
      final (host, port) = stunServers.first;
      queries.add(_stunQuery(v6, host, port, v6: true));
    }
    final results = await Future.wait(queries);
    final mapped4 = <({InternetAddress address, int port})>[];
    InternetAddress? public6;
    for (final r in results) {
      if (r == null) continue;
      if (r.address.type == InternetAddressType.IPv6) {
        public6 = r.address;
        add(r.address, r.port);
      } else {
        mapped4.add(r);
        add(r.address, r.port);
      }
    }

    // Local addresses (same Wi-Fi behind one router, IPv6 without NAT).
    final hosts = await (hostAddresses?.call() ?? _interfaceAddresses());
    for (final a in hosts) {
      if (a.type == InternetAddressType.IPv6) {
        if (v6 != null) add(a, v6.port);
      } else if (v4 != null) {
        add(a, v4.port);
      }
    }
    final ports = {for (final m in mapped4) m.port};
    final nat = NatInfo(
      public4: mapped4.isEmpty
          ? null
          : '${mapped4.first.address.address}:${mapped4.first.port}',
      symmetric: ports.length > 1,
      ipv6:
          public6 != null ||
          hosts.any((a) => a.type == InternetAddressType.IPv6),
      stunAnswered: results.whereType<Object>().isNotEmpty,
    );
    final g = _Gather(_clock(), cands, nat);
    _gather = g;
    return g;
  }

  Future<({InternetAddress address, int port})?> _stunQuery(
    RawDatagramSocket s,
    String host,
    int port, {
    required bool v6,
  }) async {
    try {
      final addrs = await InternetAddress.lookup(
        host,
        type: v6 ? InternetAddressType.IPv6 : InternetAddressType.IPv4,
      ).timeout(stunTimeout);
      if (addrs.isEmpty) return null;
      final tx = Stun.newTxId();
      final c = Completer<({InternetAddress address, int port})>();
      final key = tx.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      _stun[key] = c;
      final req = Stun.request(tx);
      s.send(req, addrs.first, port);
      // One resend halfway (UDP may drop the first).
      final again = Timer(stunTimeout ~/ 2, () {
        try {
          if (!c.isCompleted) s.send(req, addrs.first, port);
        } catch (_) {}
      });
      try {
        return await c.future.timeout(stunTimeout);
      } finally {
        again.cancel();
        _stun.remove(key);
      }
    } catch (_) {
      return null;
    }
  }

  static Future<List<InternetAddress>> _interfaceAddresses() async {
    try {
      final out = <InternetAddress>[];
      for (final i in await NetworkInterface.list(includeLoopback: false)) {
        for (final a in i.addresses) {
          if (a.isLoopback || a.isLinkLocal || a.isMulticast) continue;
          if (a.type == InternetAddressType.IPv4 &&
              a.address.startsWith('169.254.')) {
            continue;
          }
          out.add(a);
        }
      }
      return out.take(6).toList();
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------- helpers

  void _newToken(_Link l) {
    if (l.myToken != null) _byToken.remove(_hex(l.myToken!));
    final t = Uint8List.fromList(List.generate(8, (_) => _rnd.nextInt(256)));
    l.myToken = t;
    _byToken[_hex(t)] = l;
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _token(Object? v) {
    if (v is! String || v.length != 16) return null;
    try {
      return Uint8List.fromList([
        for (var i = 0; i < 16; i += 2)
          int.parse(v.substring(i, i + 2), radix: 16),
      ]);
    } catch (_) {
      return null;
    }
  }

  /// Candidates from a signal: "ip#port" strings, at most 10, no
  /// broadcast / multicast / unspecified addresses.
  static List<(InternetAddress, int)> _parseCands(Object? v) {
    if (v is! List) return const [];
    final out = <(InternetAddress, int)>[];
    for (final s in v.take(10)) {
      if (s is! String) continue;
      final i = s.lastIndexOf('#');
      if (i <= 0) continue;
      final a = InternetAddress.tryParse(s.substring(0, i));
      final p = int.tryParse(s.substring(i + 1));
      if (a == null || p == null || p <= 0 || p > 65535) continue;
      if (a.isMulticast || a.address == '0.0.0.0' || a.address == '::') {
        continue;
      }
      if (a.address == '255.255.255.255') continue;
      out.add((a, p));
    }
    return out;
  }

  static String _id(int id) => id.toRadixString(16);

  bool get powerSaver => _saver;
}

/// What STUN said about this network.
class NatInfo {
  const NatInfo({
    this.public4,
    this.symmetric = false,
    this.ipv6 = false,
    this.stunAnswered = false,
  });

  /// Public IPv4 "ip:port" the NAT gave our socket.
  final String? public4;

  /// Different public ports per server: a strict (symmetric / carrier)
  /// NAT; direct IPv4 links rarely work through it.
  final bool symmetric;
  final bool ipv6;
  final bool stunAnswered;

  /// How likely a direct link is from here: 'good', 'maybe', 'unlikely'.
  String get outlook => ipv6
      ? 'good'
      : !stunAnswered
      ? 'unlikely'
      : symmetric
      ? 'unlikely'
      : 'maybe';

  String get summary => !stunAnswered && !ipv6
      ? 'STUN no answer'
      : '${symmetric ? 'strict NAT' : 'NAT ok'}${ipv6 ? ' + IPv6' : ''}';
}

enum _State { idle, offering, punching, up }

class _Link {
  _Link(this.peerId);
  final int peerId;
  _State state = _State.idle;
  int session = 0;
  Uint8List? myToken;
  Uint8List? theirToken;
  List<(InternetAddress, int)> cands = const [];
  ({InternetAddress address, int port})? endpoint;
  DateTime lastRx = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastTx = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? deadline;
  DateTime? nextTry;
  DateTime? lastWanted;
  DateTime? lastOfferIn;
  DateTime? lastOfferOut;
  int failures = 0;
  Timer? punchTimer;
}

class _Gather {
  _Gather(this.at, this.candidates, this.nat);
  final DateTime at;
  final List<String> candidates;
  final NatInfo nat;
}
