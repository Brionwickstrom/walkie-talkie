import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'lan_transport.dart';

/// mDNS / Bonjour discovery via `bonsoir` (NsdManager on Android,
/// NWBrowser/NetService on iOS). On iOS this is the path that works without
/// Apple's restricted multicast entitlement; the service type must be listed
/// under NSBonjourServices in Info.plist.
///
/// Every found service is resolved (Android's NsdManager reports services
/// without addresses until resolved) and only IPv4 addresses are used.
/// Resolved endpoints are re-announced every [reannounce] while the service
/// is still advertised, so the LAN transport keeps probing them.
class MdnsLanDiscovery implements LanDiscovery {
  static const String serviceType = '_walkietalkie._udp';
  static const Duration reannounce = Duration(seconds: 60);

  final _found = StreamController<LanEndpoint>.broadcast();
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  Timer? _timer;
  String _ownName = '';
  String _ownId = '';
  final Map<String, Set<LanEndpoint>> _known = {};

  @override
  Stream<LanEndpoint> get found => _found.stream;

  @override
  int get foundCount => _known.values.fold(0, (n, s) => n + s.length);

  @override
  Future<void> start({required int localNodeId, required int port}) async {
    _ownId = localNodeId.toRadixString(16);
    _ownName = 'wt-${localNodeId.toRadixString(16).padLeft(8, '0')}';
    final service = BonsoirService(
      name: _ownName,
      type: serviceType,
      port: port,
      attributes: {'id': _ownId},
    );
    // Advertising and browsing are independent: one failing must not stop
    // the other.
    try {
      final broadcast = BonsoirBroadcast(service: service);
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (_) {}

    final discovery = BonsoirDiscovery(type: serviceType);
    await discovery.initialize();
    _sub = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          if (_isOwn(event.service)) break;
          if (event.service.hostAddresses.isNotEmpty) {
            _emit(event.service);
          } else {
            try {
              event.service.resolve(discovery.serviceResolver);
            } catch (_) {}
          }
        case BonsoirDiscoveryServiceResolvedEvent():
          _emit(event.service);
        case BonsoirDiscoveryServiceUpdatedEvent():
          _emit(event.service);
        case BonsoirDiscoveryServiceLostEvent():
          _known.remove(event.service.name);
        default:
          break;
      }
    });
    await discovery.start();
    _discovery = discovery;
    _timer = Timer.periodic(reannounce, (_) {
      for (final s in _known.values) {
        s.forEach(_found.add);
      }
    });
  }

  /// Android may rename a duplicate registration ("wt-xxxx (2)"), so also
  /// compare the id attribute.
  bool _isOwn(BonsoirService s) =>
      s.name == _ownName ||
      s.name.startsWith('$_ownName ') ||
      s.attributes['id'] == _ownId;

  void _emit(BonsoirService s) {
    if (_isOwn(s)) return;
    for (final a in s.hostAddresses) {
      final addr = InternetAddress.tryParse(a);
      if (addr != null &&
          addr.type == InternetAddressType.IPv4 &&
          !addr.isLoopback &&
          s.port > 0) {
        final ep = LanEndpoint(addr, s.port);
        _known.putIfAbsent(s.name, () => {}).add(ep);
        _found.add(ep);
      }
    }
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _discovery?.stop();
    } catch (_) {}
    _discovery = null;
    try {
      await _broadcast?.stop();
    } catch (_) {}
    _broadcast = null;
    _known.clear();
  }
}
