import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/transport.dart';
import 'lan_peer_store.dart';
import 'lan_platform.dart';

export 'lan_peer_store.dart';
export 'lan_platform.dart';

/// Something that finds candidate LAN addresses for other phones (mDNS,
/// manual entry, ...). UDP broadcast discovery is built into [LanTransport].
abstract class LanDiscovery {
  Stream<LanEndpoint> get found;
  Future<void> start({required int localNodeId, required int port});
  Future<void> stop();

  /// Endpoints found so far (debug).
  int get foundCount => 0;
}

class LanEndpoint {
  const LanEndpoint(this.address, this.port);
  final InternetAddress address;
  final int port;

  @override
  bool operator ==(Object other) =>
      other is LanEndpoint && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);

  @override
  String toString() => '${address.address}:$port';

  /// Parses "1.2.3.4:5678".
  static LanEndpoint? tryParse(String s) {
    final i = s.lastIndexOf(':');
    if (i <= 0) return null;
    final a = InternetAddress.tryParse(s.substring(0, i));
    final p = int.tryParse(s.substring(i + 1));
    if (a == null || p == null || p <= 0 || p > 65535) return null;
    return LanEndpoint(a, p);
  }
}

/// A unicast target and what we know about it.
class LanCandidate {
  LanCandidate(this.endpoint, {this.permanent = false, DateTime? hinted})
    : lastHinted = hinted;
  final LanEndpoint endpoint;

  /// Static peers never expire.
  final bool permanent;

  /// Last time something told us about this address (Bluetooth hello,
  /// mDNS, saved from an earlier session).
  DateTime? lastHinted;

  /// Last time a packet from another phone actually arrived from it.
  DateTime? lastHeard;

  DateTime? get lastActivity {
    final h = lastHeard, n = lastHinted;
    if (h == null) return n;
    if (n == null) return h;
    return h.isAfter(n) ? h : n;
  }
}

/// Local network transport: works on any shared Wi-Fi or on a phone's
/// hotspot, with or without internet. Nothing here needs DNS or internet.
///
/// * One UDP socket on [port] (bound to 0.0.0.0, SO_REUSEADDR, broadcast
///   enabled) carries both discovery beacons and audio.
/// * Discovery, all at once, whichever gets through first wins:
///   1. hello frames to 255.255.255.255, the subnet broadcast of every
///      Wi-Fi interface, and the multicast group [multicastGroup];
///   2. unicast to endpoints found by [discoveries] (mDNS/Bonjour);
///   3. unicast to endpoints a peer advertised in its hello over another
///      link (usually Bluetooth) via [learnPeerAddresses];
///   4. unicast to addresses remembered from earlier ([store]), kept and
///      re-probed for [knownPeerTtl] after they were last heard;
///   5. when no phone has been heard for [sweepAfter], a rate-limited
///      unicast sweep of the local subnet (/24, or the real one up to /22),
///      repeated every [sweepInterval]. Mesh routers (TP-Link Deco etc.)
///      often filter broadcast/multicast between wireless clients but pass
///      unicast, which this catches.
/// * Any packet from a new address is answered at once with our hello, so
///   a single probe that gets through is enough to link both phones.
/// * Audio: unicast UDP to the address each peer's frames came from.
class LanTransport extends Transport {
  LanTransport({
    this.port = defaultPort,
    this.discoveries = const [],
    this.staticPeers = const [],
    this.enableBroadcast = true,
    this.enableSweep = true,
    this.platform = const LanPlatform(),
    this.store,
    this.sweepPort,
    this.sweepBatch = 16,
    this.sweepBatchDelay = const Duration(milliseconds: 40),
    this.allowLoopbackInterfaces = false,
    InternetAddress? bindAddress,
    DateTime Function()? clock,
  }) : _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _clock = clock ?? DateTime.now;

  static const int defaultPort = 47474;
  static final InternetAddress multicastGroup = InternetAddress(
    '239.255.42.99',
  );

  /// Addresses heard/hinted within this are sent every hello.
  static const Duration freshFor = Duration(seconds: 30);

  /// Older ones are re-probed every [staleProbeEvery] hellos until this.
  static const Duration knownPeerTtl = Duration(minutes: 10);
  static const int staleProbeEvery = 5;

  /// Saved addresses older than this are not loaded.
  static const Duration storeMaxAge = Duration(days: 7);
  static const int storeMaxEntries = 16;

  static const Duration sweepAfter = Duration(seconds: 5);
  static const Duration sweepInterval = Duration(seconds: 30);
  static const Duration _ifaceRefresh = Duration(seconds: 5);
  static const Duration _saveEvery = Duration(seconds: 30);

  final int port;
  final List<LanDiscovery> discoveries;
  final List<LanEndpoint> staticPeers;
  final bool enableBroadcast;
  final bool enableSweep;
  final LanPlatform platform;
  final LanPeerStore? store;

  /// Port probed by the sweep (default: [port], or our bound port).
  final int? sweepPort;
  final int sweepBatch;
  final Duration sweepBatchDelay;

  /// Tests run on 127.x; real phones ignore loopback.
  final bool allowLoopbackInterfaces;
  final InternetAddress _bindAddress;
  final DateTime Function() _clock;

  RawDatagramSocket? _socket;
  int _boundPort = 0;
  int _localId = -1;
  TransportStatus _status = TransportStatus.stopped;
  String? _detail;
  final _statusCtl = StreamController<TransportStatus>.broadcast();
  final _framesCtl = StreamController<InboundFrame>.broadcast();
  final Map<int, LanEndpoint> _peerEndpoints = {};
  final Map<LanEndpoint, LanCandidate> _candidates = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  StreamSubscription<RawSocketEvent>? _socketSub;
  List<InternetAddress> _broadcastTargets = const [];
  List<LanInterface> _ifaces = const [];
  Set<String> _joinedOn = const {};
  DateTime? _ifacesAt;
  DateTime? _startedAt;
  DateTime? _lastPeerHeard;
  DateTime? _lastSave;
  bool _dirty = false;
  bool _refreshing = false;
  bool _lockHeld = false;
  LanNetState? _net;
  int _netGeneration = 0;
  Uint8List? _lastHello;
  int _helloCount = 0;

  // Sweep state.
  bool _sweeping = false;
  DateTime? _lastSweep;
  int _sweeps = 0;
  int _sweepSent = 0;

  // Counters for the debug line.
  int _rxPeer = 0;
  int _rxOwn = 0;
  int _txBcast = 0;
  int _txUnicast = 0;
  int _txErrors = 0;
  int _rebinds = 0;

  @override
  TransportKind get kind => TransportKind.lan;
  @override
  TransportStatus get status => _status;
  @override
  String? get statusDetail => _detail;
  @override
  Stream<TransportStatus> get statusChanges => _statusCtl.stream;
  @override
  Stream<InboundFrame> get frames => _framesCtl.stream;

  /// The port actually bound (useful when [port] is 0 in tests).
  int? get boundPort => _socket?.port;

  /// Visible for tests/debug: current unicast discovery targets.
  Set<LanEndpoint> get candidates => _candidates.keys.toSet();
  LanCandidate? candidate(LanEndpoint ep) => _candidates[ep];
  List<InternetAddress> get broadcastTargets => _broadcastTargets;
  int get rxFromPeers => _rxPeer;
  int get rxOwn => _rxOwn;
  int get sweepsDone => _sweeps;
  bool get isSweeping => _sweeping;

  void _setStatus(TransportStatus s, [String? detail]) {
    _status = s;
    _detail = detail;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    if (_socket != null) return;
    _localId = localNodeId;
    _startedAt = _clock();
    _setStatus(TransportStatus.starting);
    try {
      _lockHeld = await platform.acquireMulticastLock();
      _net = await platform.netState();
      _netGeneration = _net?.generation ?? 0;
      await _bind(port);
      for (final p in staticPeers) {
        _candidates[p] = LanCandidate(p, permanent: true);
      }
      await _loadStore();
      await _refreshInterfaces();
      for (final d in discoveries) {
        _subs.add(d.found.listen((ep) => _addCandidate(ep, hinted: _clock())));
        try {
          await d.start(localNodeId: localNodeId, port: _boundPort);
        } catch (_) {
          // mDNS failing is not fatal: broadcast/hints/sweep still work.
        }
      }
      _setStatus(TransportStatus.running);
    } catch (e) {
      _setStatus(TransportStatus.error, '$e');
      rethrow;
    }
  }

  Future<void> _bind(int p) async {
    final socket = await RawDatagramSocket.bind(
      _bindAddress,
      p,
      reuseAddress: true,
    );
    socket.broadcastEnabled = enableBroadcast;
    socket.readEventsEnabled = true;
    try {
      socket.multicastLoopback = false; // fewer own echoes
    } catch (_) {}
    _socket = socket;
    _boundPort = socket.port;
    _joinedOn = const {};
    _socketSub = socket.listen(
      _onSocketEvent,
      // e.g. ICMP "port unreachable" from a probed address: not fatal.
      onError: (Object _) => _txErrors++,
    );
  }

  /// Recreate the socket on the same port. Only when the Wi-Fi address or
  /// Android's network binding changed: an old socket keeps routing to the
  /// network it was created on.
  Future<void> _rebind() async {
    final old = _socket;
    if (old == null) return;
    await _socketSub?.cancel();
    _socketSub = null;
    old.close();
    _socket = null;
    try {
      await _bind(_boundPort);
      _rebinds++;
    } catch (e) {
      _setStatus(TransportStatus.error, 'rebind failed: $e');
    }
  }

  Future<void> _loadStore() async {
    final s = store;
    if (s == null) return;
    final now = _clock();
    try {
      for (final k in await s.load()) {
        if (now.difference(k.lastHeard) > storeMaxAge) continue;
        final ep = LanEndpoint.tryParse(k.endpoint);
        if (ep == null || ep.address.type != InternetAddressType.IPv4) {
          continue;
        }
        // Re-probe saved addresses for a while after every start.
        final c = _candidates.putIfAbsent(ep, () => LanCandidate(ep));
        c.lastHinted = now;
      }
    } catch (_) {}
  }

  Future<void> _saveStore({bool force = false}) async {
    final s = store;
    if (s == null || (!_dirty && !force)) return;
    final now = _clock();
    if (!force &&
        _lastSave != null &&
        now.difference(_lastSave!) < _saveEvery) {
      return;
    }
    _dirty = false;
    _lastSave = now;
    final heard = [
      for (final c in _candidates.values)
        if (c.lastHeard != null) KnownLanPeer('${c.endpoint}', c.lastHeard!),
    ]..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    try {
      await s.save(heard.take(storeMaxEntries).toList());
    } catch (_) {}
  }

  /// Re-read interfaces: Wi-Fi may connect, change network or turn into a
  /// hotspot after the app started. The socket is kept unless our address
  /// set or Android's network binding actually changed.
  Future<void> _refreshInterfaces() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final before = _ifaces.map((i) => i.address.address).toSet();
      final all = await platform.interfaces();
      final ifaces = [
        for (final i in all)
          if (i.isLocalNetwork ||
              (allowLoopbackInterfaces &&
                  i.address.type == InternetAddressType.IPv4))
            i,
      ]..sort((a, b) => _ifaceRank(a).compareTo(_ifaceRank(b)));
      _ifaces = ifaces;
      if (enableBroadcast) {
        _broadcastTargets = <InternetAddress>{
          InternetAddress('255.255.255.255'),
          for (final i in _ifaces) i.effectiveBroadcast,
        }.toList();
      }
      // Keep the multicast lock held (cheap no-op if it already is).
      _lockHeld = await platform.acquireMulticastLock() || _lockHeld;
      final net = await platform.netState();
      _net = net;
      final after = _ifaces.map((i) => i.address.address).toSet();
      final ipChanged =
          before.isNotEmpty &&
          (before.length != after.length || !before.containsAll(after));
      final genChanged = net != null && net.generation != _netGeneration;
      _netGeneration = net?.generation ?? _netGeneration;
      if (_socket != null && (ipChanged || genChanged)) {
        await _rebind();
      }
      _joinMulticast();
    } catch (_) {
    } finally {
      _ifacesAt = _clock();
      _refreshing = false;
    }
  }

  /// Wi-Fi first so the addresses we advertise (max 3) include it.
  static int _ifaceRank(LanInterface i) {
    final n = i.name.toLowerCase();
    if (n.startsWith('wlan')) return 0;
    if (n.startsWith('eth') || n.startsWith('en')) return 1;
    if (n.startsWith('swlan') || n.startsWith('ap') || n.startsWith('wl')) {
      return 2; // hotspot
    }
    return 3;
  }

  void _joinMulticast() {
    final socket = _socket;
    if (socket == null || !enableBroadcast) return;
    final want = _ifaces.map((i) => i.name).toSet();
    if (want.length == _joinedOn.length && _joinedOn.containsAll(want)) return;
    unawaited(() async {
      final joined = <String>{};
      try {
        final osIfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        for (final ni in osIfaces) {
          if (!want.contains(ni.name)) continue;
          try {
            socket.joinMulticast(multicastGroup, ni);
            joined.add(ni.name);
          } catch (_) {}
        }
        if (joined.isEmpty) {
          socket.joinMulticast(multicastGroup);
          joined.addAll(want);
        }
      } catch (_) {}
      if (identical(socket, _socket)) _joinedOn = joined;
    }());
  }

  bool _isOwnAddress(InternetAddress a) =>
      _ifaces.any((i) => i.address == a) ||
      (a.isLoopback && !allowLoopbackInterfaces);

  void _addCandidate(LanEndpoint ep, {DateTime? hinted}) {
    if (_isOwnAddress(ep.address) && ep.port == boundPort) return;
    final c = _candidates.putIfAbsent(ep, () => LanCandidate(ep));
    if (hinted != null) c.lastHinted = hinted;
  }

  @override
  List<String> get localAddresses {
    final p = boundPort;
    if (p == null) return const [];
    // Cap at 3 to keep hello small enough for Bluetooth.
    return [for (final i in _ifaces.take(3)) '${i.address.address}:$p'];
  }

  @override
  void learnPeerAddresses(int peerId, List<String> addresses) {
    final now = _clock();
    for (final a in addresses) {
      final ep = LanEndpoint.tryParse(a);
      if (ep == null || ep.address.type != InternetAddressType.IPv4) continue;
      _addCandidate(ep, hinted: now);
    }
  }

  @override
  bool canReach(int peerId) => _peerEndpoints.containsKey(peerId);

  String _ago(DateTime? t, DateTime now) {
    if (t == null) return 'never';
    final s = now.difference(t).inSeconds;
    return s < 120 ? '${s}s' : '${s ~/ 60}m';
  }

  /// Several lines:
  ///   IP 192.168.68.54/22 · lock on · wifi-lock on · no-internet: bound
  ///   rx peers 120 · own echo 900 · tx bcast 450 · direct 300
  ///   mDNS found 1 · sweeps 2 (last 12s ago)
  ///   192.168.68.60:47474 heard 1s · 192.168.69.3:47474 heard never
  @override
  String? get debugInfo {
    final now = _clock();
    final ips = _ifaces
        .map((i) => '${i.address.address}/${i.prefixLength ?? '?'}')
        .join(',');
    final net = _net;
    final netStr = net == null
        ? ''
        : ' · wifi-lock ${net.wifiLock ? 'on' : 'off'}'
              '${net.wifi && !net.validated ? ' · no-internet${net.bound ? ': bound' : ''}' : ''}';
    final mdns = discoveries.fold<int>(0, (n, d) => n + d.foundCount);
    final direct = _candidates.values.toList()
      ..sort(
        (a, b) => (b.lastActivity ?? DateTime(0)).compareTo(
          a.lastActivity ?? DateTime(0),
        ),
      );
    final directStr = direct
        .take(4)
        .map(
          (c) =>
              '${c.endpoint.address.address} heard ${_ago(c.lastHeard, now)}',
        )
        .join(' · ');
    return 'IP ${ips.isEmpty ? 'none' : ips} · lock ${_lockHeld ? 'on' : 'off'}$netStr'
        '\nrx peers $_rxPeer · own echo $_rxOwn · tx bcast $_txBcast · direct $_txUnicast'
        '${_txErrors > 0 ? ' · tx err $_txErrors' : ''}'
        '${_rebinds > 0 ? ' · rebinds $_rebinds' : ''}'
        '\nmDNS found $mdns · sweeps $_sweeps ($_sweepSent probes)'
        '${_sweeping
            ? ' (running)'
            : _lastSweep != null
            ? ' (last ${_ago(_lastSweep, now)} ago)'
            : ''}'
        '\ndirect ${_candidates.length}${directStr.isEmpty ? '' : ': $directStr'}';
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? dg;
    while ((dg = socket.receive()) != null) {
      final frame = Frame.tryDecode(dg!.data);
      if (frame == null) continue;
      if (frame.senderId == _localId) {
        _rxOwn++; // our own broadcast/multicast looped back
        continue;
      }
      _rxPeer++;
      final now = _clock();
      final ep = LanEndpoint(dg.address, dg.port);
      final isNew = _peerEndpoints[frame.senderId] != ep;
      _peerEndpoints[frame.senderId] = ep;
      _lastPeerHeard = now;
      final c = _candidates.putIfAbsent(ep, () => LanCandidate(ep));
      final firstHeard = c.lastHeard == null;
      c.lastHeard = now;
      _dirty = true;
      if (isNew) {
        // Answer right away so a single probe/hello that got through is
        // enough for the other phone to find us too.
        final hello = _lastHello;
        if (hello != null) _sendUnicast(socket, hello, ep);
      }
      if (firstHeard || isNew) {
        unawaited(_saveStore(force: true));
      } else {
        unawaited(_saveStore());
      }
      if (!_framesCtl.isClosed) {
        _framesCtl.add(InboundFrame(frame, TransportKind.lan));
      }
    }
  }

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    final socket = _socket;
    if (socket == null) return;
    if (peerIds == null) {
      await _sendHello(socket, frame);
      return;
    }
    for (final id in peerIds) {
      final ep = _peerEndpoints[id];
      if (ep != null) _sendUnicast(socket, frame, ep);
    }
  }

  /// Hello beacon (called about once a second by the manager).
  Future<void> _sendHello(RawDatagramSocket socket, Uint8List frame) async {
    _lastHello = frame;
    _helloCount++;
    final now = _clock();
    if (_ifacesAt == null || now.difference(_ifacesAt!) > _ifaceRefresh) {
      unawaited(_refreshInterfaces());
    }
    _pruneCandidates(now);
    final s = _socket ?? socket;
    if (enableBroadcast) {
      for (final b in _broadcastTargets) {
        if (_trySend(s, frame, b, port)) _txBcast++;
      }
      if (_trySend(s, frame, multicastGroup, port)) _txBcast++;
    }
    final probeStale = _helloCount % staleProbeEvery == 1;
    final sentTo = <LanEndpoint>{};
    // Known peers first (keeps the link fresh even if broadcast is
    // filtered), then every candidate.
    for (final ep in _peerEndpoints.values) {
      if (sentTo.add(ep)) _sendUnicast(s, frame, ep);
    }
    for (final c in _candidates.values) {
      if (sentTo.contains(c.endpoint)) continue;
      final last = c.lastActivity;
      final fresh =
          c.permanent || (last != null && now.difference(last) <= freshFor);
      if (fresh || probeStale) {
        sentTo.add(c.endpoint);
        _sendUnicast(s, frame, c.endpoint);
      }
    }
    _maybeSweep(now);
  }

  /// Drop addresses not heard or hinted for [knownPeerTtl].
  void _pruneCandidates(DateTime now) {
    _candidates.removeWhere((_, c) {
      if (c.permanent) return false;
      final last = c.lastActivity;
      return last == null || now.difference(last) > knownPeerTtl;
    });
  }

  bool get _hasRecentPeer {
    final t = _lastPeerHeard;
    return t != null && _clock().difference(t) <= sweepAfter;
  }

  void _maybeSweep(DateTime now) {
    if (!enableSweep || _sweeping || _ifaces.isEmpty) return;
    if (_hasRecentPeer) return;
    final since = _lastPeerHeard ?? _startedAt;
    if (since == null || now.difference(since) < sweepAfter) return;
    if (_lastSweep != null && now.difference(_lastSweep!) < sweepInterval) {
      return;
    }
    unawaited(runSweep());
  }

  /// Unicast our last hello to every host on our subnet(s), [sweepBatch]
  /// at a time. Stops early once a phone answers. Public for tests.
  Future<void> runSweep() async {
    final hello = _lastHello;
    if (_sweeping || hello == null) return;
    _sweeping = true;
    _lastSweep = _clock();
    _sweeps++;
    final targetPort = sweepPort ?? (port == 0 ? _boundPort : port);
    try {
      final targets = <InternetAddress>{
        for (final i in _ifaces) ...sweepTargets(i),
      };
      var n = 0;
      for (final a in targets) {
        final s = _socket;
        if (s == null || _hasRecentPeer) break;
        _trySend(s, hello, a, targetPort);
        _sweepSent++;
        if (++n % sweepBatch == 0) await Future<void>.delayed(sweepBatchDelay);
      }
    } finally {
      _sweeping = false;
    }
  }

  /// Hosts to probe on [i]'s subnet, own /24 first. Subnets bigger than
  /// /22 (1022 hosts) are limited to our own /24. Excludes our address and
  /// the network/broadcast addresses.
  static List<InternetAddress> sweepTargets(LanInterface i) {
    final b = i.address.rawAddress;
    final ip = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    var prefix = i.prefixLength ?? 24;
    if (prefix < 22) prefix = 24;
    if (prefix > 30) return const [];
    final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    final net = ip & mask;
    final bcast = net | (~mask & 0xFFFFFFFF);
    final own24 = ip & 0xFFFFFF00;
    InternetAddress addr(int v) => InternetAddress.fromRawAddress(
      Uint8List.fromList([v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255]),
    );
    final first = <InternetAddress>[];
    final rest = <InternetAddress>[];
    for (var v = net + 1; v < bcast; v++) {
      if (v == ip) continue;
      ((v & 0xFFFFFF00) == own24 ? first : rest).add(addr(v));
    }
    return [...first, ...rest];
  }

  void _sendUnicast(RawDatagramSocket s, Uint8List data, LanEndpoint ep) {
    if (_trySend(s, data, ep.address, ep.port)) _txUnicast++;
  }

  bool _trySend(RawDatagramSocket s, Uint8List data, InternetAddress a, int p) {
    try {
      return s.send(data, a, p) > 0;
    } catch (_) {
      // e.g. network unreachable while Wi-Fi is switching; ignore.
      _txErrors++;
      return false;
    }
  }

  @override
  Future<void> stop() async {
    await _saveStore(force: true);
    for (final d in discoveries) {
      try {
        await d.stop();
      } catch (_) {}
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _peerEndpoints.clear();
    _candidates.clear();
    _lastHello = null;
    if (_lockHeld) {
      await platform.releaseMulticastLock();
      _lockHeld = false;
    }
    _setStatus(TransportStatus.stopped);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _statusCtl.close();
    await _framesCtl.close();
  }
}
