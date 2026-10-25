import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'lan_transport.dart';

/// mDNS / Bonjour discovery via `bonsoir` (NsdManager on Android,
/// NWBrowser/NetService on iOS). On iOS this is the path that works without
/// Apple's restricted multicast entitlement; the service type must be listed
/// under NSBonjourServices in Info.plist.
class MdnsLanDiscovery implements LanDiscovery {
  static const String serviceType = '_walkietalkie._udp';

  final _found = StreamController<LanEndpoint>.broadcast();
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;
  String _ownName = '';

  @override
  Stream<LanEndpoint> get found => _found.stream;

  @override
  Future<void> start({required int localNodeId, required int port}) async {
    _ownName = 'wt-${localNodeId.toRadixString(16).padLeft(8, '0')}';
    final service = BonsoirService(
      name: _ownName,
      type: serviceType,
      port: port,
      attributes: {'id': localNodeId.toRadixString(16)},
    );
    final broadcast = BonsoirBroadcast(service: service);
    await broadcast.initialize();
    await broadcast.start();
    _broadcast = broadcast;

    final discovery = BonsoirDiscovery(type: serviceType);
    await discovery.initialize();
    _sub = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          if (event.service.name == _ownName) break;
          if (event.service.hostAddresses.isNotEmpty) {
            _emit(event.service);
          } else {
            event.service.resolve(discovery.serviceResolver);
          }
        case BonsoirDiscoveryServiceResolvedEvent():
          _emit(event.service);
        case BonsoirDiscoveryServiceUpdatedEvent():
          _emit(event.service);
        default:
          break;
      }
    });
    await discovery.start();
    _discovery = discovery;
  }

  void _emit(BonsoirService s) {
    if (s.name == _ownName) return;
    for (final a in s.hostAddresses) {
      final addr = InternetAddress.tryParse(a);
      if (addr != null && addr.type == InternetAddressType.IPv4) {
        _found.add(LanEndpoint(addr, s.port));
      }
    }
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _discovery?.stop();
    _discovery = null;
    await _broadcast?.stop();
    _broadcast = null;
  }
}
