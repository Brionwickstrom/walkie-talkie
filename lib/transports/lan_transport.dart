import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/frame.dart';
import '../core/transport.dart';

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
}

/// Local network transport: works on any shared Wi-Fi or on a phone's
/// hotspot, with or without internet.
///
/// * One UDP socket on [port] carries both discovery beacons and audio.
/// * Discovery: hello frames are sent to the limited broadcast address and a
///   best-guess /24 directed broadcast for every interface, plus unicast to
///   every endpoint found by [discoveries] (mDNS/Bonjour) or [staticPeers].
///   iOS needs the multicast entitlement to send/receive broadcasts, so on
///   iPhone mDNS (no entitlement needed) + unicast is the reliable path.
/// * Audio: unicast UDP to the address each peer's frames came from. Opus
///   at 12-24 kbps is a few KB/s, far below what any Wi-Fi can do, and UDP
///   avoids head-of-line blocking (a late audio packet is a useless one).
class LanTransport extends Transport {
  LanTransport({
    this.port = defaultPort,
    this.discoveries = const [],
    this.staticPeers = const [],
    this.enableBroadcast = true,
    InternetAddress? bindAddress,
  }) : _bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  static const int defaultPort = 47474;

  final int port;
  final List<LanDiscovery> discoveries;
  final List<LanEndpoint> staticPeers;
  final bool enableBroadcast;
  final InternetAddress _bindAddress;

  RawDatagramSocket? _socket;
  TransportStatus _status = TransportStatus.stopped;
  String? _detail;
  final _statusCtl = StreamController<TransportStatus>.broadcast();
  final _framesCtl = StreamController<InboundFrame>.broadcast();
  final Map<int, LanEndpoint> _peerEndpoints = {};
  final Set<LanEndpoint> _candidates = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  List<InternetAddress> _broadcastTargets = const [];

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
      final socket = await RawDatagramSocket.bind(_bindAddress, port,
          reuseAddress: true);
      socket.broadcastEnabled = enableBroadcast;
      socket.readEventsEnabled = true;
      _socket = socket;
      _subs.add(socket.listen(_onSocketEvent));
      _candidates.addAll(staticPeers);
      if (enableBroadcast) _broadcastTargets = await _computeBroadcasts();
      for (final d in discoveries) {
        _subs.add(d.found.listen(_candidates.add));
        try {
          await d.start(localNodeId: localNodeId, port: socket.port);
        } catch (_) {
          // mDNS failing is not fatal: broadcast/static still work.
        }
      }
      _setStatus(TransportStatus.running);
    } catch (e) {
      _setStatus(TransportStatus.error, '$e');
      rethrow;
    }
  }

  Future<List<InternetAddress>> _computeBroadcasts() async {
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          final parts = a.address.split('.');
          if (parts.length == 4) {
            // dart:io does not expose netmasks; /24 is by far the most
            // common for home Wi-Fi and phone hotspots (Android 192.168.x,
            // iPhone 172.20.10.x is a /28, still covered by 255.255.255.255).
            targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
          }
        }
      }
    } catch (_) {}
    return targets.toList();
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    Datagram? dg;
    while ((dg = socket.receive()) != null) {
      final frame = Frame.tryDecode(dg!.data);
      if (frame == null) continue;
      final ep = LanEndpoint(dg.address, dg.port);
      _peerEndpoints[frame.senderId] = ep;
      _candidates.add(ep);
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
      for (final b in _broadcastTargets) {
        _trySend(socket, frame, b, port);
      }
      for (final ep in _candidates) {
        _trySend(socket, frame, ep.address, ep.port);
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
    _setStatus(TransportStatus.stopped);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _statusCtl.close();
    await _framesCtl.close();
  }
}
