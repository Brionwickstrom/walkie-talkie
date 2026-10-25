import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/transport.dart';
import 'lan_platform.dart';

export 'lan_platform.dart';

/// Something that finds candidate LAN addresses for other phones (mDNS,
/// manual entry, ...). UDP broadcast discovery is built into [LanTransport].
abstract class LanDiscovery {
  Stream<LanEndpoint> get found;
  Future<void> start({required int localNodeId, required int port});
  Future<void> stop();
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

/// Local network transport: works on any shared Wi-Fi or on a phone's
/// hotspot, with or without internet.
///
/// * One UDP socket on [port] (bound to 0.0.0.0, SO_REUSEADDR, broadcast
///   enabled) carries both discovery beacons and audio.
/// * Discovery, all at once, whichever gets through first wins:
///   1. hello frames to 255.255.255.255 and the real subnet broadcast of
///      every Wi-Fi interface (netmask from the OS on Android);
///   2. unicast to endpoints found by [discoveries] (mDNS/Bonjour);
///   3. unicast to endpoints a peer advertised in its hello over another
///      link (usually Bluetooth) via [learnPeerAddresses]. This is what
///      makes LAN work on routers that filter broadcast/multicast.
/// * On Android a WifiManager.MulticastLock is held while running; without
///   it many phones (Samsung included) silently drop incoming broadcasts.
/// * Audio: unicast UDP to the address each peer's frames came from.
class LanTransport extends Transport {
  LanTransport({
    this.port = defaultPort,
    this.discoveries = const [],
    this.staticPeers = const [],
    this.enableBroadcast = true,
    this.platform = const LanPlatform(),
    InternetAddress? bindAddress,
    DateTime Function()? clock,
  }) : _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _clock = clock ?? DateTime.now;

  static const int defaultPort = 47474;

  /// Hinted/mDNS endpoints are retried for this long after the last hint.
  static const Duration candidateTtl = Duration(seconds: 30);
  static const Duration _ifaceRefresh = Duration(seconds: 5);

  final int port;
  final List<LanDiscovery> discoveries;
  final List<LanEndpoint> staticPeers;
  final bool enableBroadcast;
  final LanPlatform platform;
  final InternetAddress _bindAddress;
  final DateTime Function() _clock;

  RawDatagramSocket? _socket;
  TransportStatus _status = TransportStatus.stopped;
  String? _detail;
  final _statusCtl = StreamController<TransportStatus>.broadcast();
  final _framesCtl = StreamController<InboundFrame>.broadcast();
  final Map<int, LanEndpoint> _peerEndpoints = {};

  /// Endpoint -> expiry (null = permanent, e.g. static peers).
  final Map<LanEndpoint, DateTime?> _candidates = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  List<InternetAddress> _broadcastTargets = const [];
  List<LanInterface> _ifaces = const [];
  DateTime? _ifacesAt;
  bool _refreshing = false;
  bool _lockHeld = false;
  int _rxCount = 0;
  int _txErrors = 0;

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
  List<InternetAddress> get broadcastTargets => _broadcastTargets;

  void _setStatus(TransportStatus s, [String? detail]) {
    _status = s;
    _detail = detail;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    if (_socket != null) return;
    _setStatus(TransportStatus.starting);
    try {
      _lockHeld = await platform.acquireMulticastLock();
      final socket = await RawDatagramSocket.bind(
        _bindAddress,
        port,
        reuseAddress: true,
      );
      socket.broadcastEnabled = enableBroadcast;
      socket.readEventsEnabled = true;
      _socket = socket;
      _subs.add(socket.listen(_onSocketEvent));
      for (final p in staticPeers) {
        _candidates[p] = null;
      }
      await _refreshInterfaces();
      for (final d in discoveries) {
        _subs.add(
          d.found.listen(
            (ep) => _addCandidate(ep, _clock().add(candidateTtl * 2)),
          ),
        );
        try {
          await d.start(localNodeId: localNodeId, port: socket.port);
        } catch (_) {
          // mDNS failing is not fatal: broadcast/hints still work.
        }
      }
      _setStatus(TransportStatus.running);
    } catch (e) {
      _setStatus(TransportStatus.error, '$e');
      rethrow;
    }
  }

  /// Re-read interfaces: Wi-Fi may connect, change network or turn into a
  /// hotspot after the app started.
  Future<void> _refreshInterfaces() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final all = await platform.interfaces();
      _ifaces = [
        for (final i in all)
          if (i.isLocalNetwork) i,
      ];
      if (enableBroadcast) {
        _broadcastTargets = <InternetAddress>{
          InternetAddress('255.255.255.255'),
          for (final i in _ifaces) i.effectiveBroadcast,
        }.toList();
      }
    } catch (_) {
    } finally {
      _ifacesAt = _clock();
      _refreshing = false;
    }
  }

  bool _isOwnAddress(InternetAddress a) =>
      a.isLoopback || _ifaces.any((i) => i.address == a);

  void _addCandidate(LanEndpoint ep, DateTime? expiry) {
    if (_isOwnAddress(ep.address) && ep.port == boundPort) return;
    if (_candidates.containsKey(ep) && _candidates[ep] == null) return;
    _candidates[ep] = expiry;
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
    final expiry = _clock().add(candidateTtl);
    for (final a in addresses) {
      final ep = LanEndpoint.tryParse(a);
      if (ep == null || ep.address.type != InternetAddressType.IPv4) continue;
      _addCandidate(ep, expiry);
    }
  }

  @override
  bool canReach(int peerId) => _peerEndpoints.containsKey(peerId);

  @override
  String? get debugInfo {
    final ips = _ifaces.map((i) => i.address.address).join(',');
    return 'IP ${ips.isEmpty ? 'none' : ips} · lock ${_lockHeld ? 'on' : 'off'}'
        ' · ${_candidates.length} direct · rx $_rxCount'
        '${_txErrors > 0 ? ' · tx err $_txErrors' : ''}';
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? dg;
    while ((dg = socket.receive()) != null) {
      final frame = Frame.tryDecode(dg!.data);
      if (frame == null) continue;
      _rxCount++;
      final ep = LanEndpoint(dg.address, dg.port);
      _peerEndpoints[frame.senderId] = ep;
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
      final now = _clock();
      if (_ifacesAt == null || now.difference(_ifacesAt!) > _ifaceRefresh) {
        unawaited(_refreshInterfaces());
      }
      _candidates.removeWhere((_, exp) => exp != null && exp.isBefore(now));
      final sentTo = <LanEndpoint>{};
      for (final b in _broadcastTargets) {
        _trySend(socket, frame, b, port);
      }
      // Known peers first (keeps the link fresh even if broadcast is
      // filtered), then every candidate.
      for (final ep in [..._peerEndpoints.values, ..._candidates.keys]) {
        if (sentTo.add(ep)) _trySend(socket, frame, ep.address, ep.port);
      }
      return;
    }
    for (final id in peerIds) {
      final ep = _peerEndpoints[id];
      if (ep != null) _trySend(socket, frame, ep.address, ep.port);
    }
  }

  void _trySend(RawDatagramSocket s, Uint8List data, InternetAddress a, int p) {
    try {
      s.send(data, a, p);
    } catch (_) {
      // e.g. network unreachable while Wi-Fi is switching; ignore.
      _txErrors++;
    }
  }

  @override
  Future<void> stop() async {
    for (final d in discoveries) {
      try {
        await d.stop();
      } catch (_) {}
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _socket?.close();
    _socket = null;
    _peerEndpoints.clear();
    _candidates.clear();
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
