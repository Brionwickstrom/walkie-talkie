import 'dart:io';

import 'package:flutter/services.dart';

/// One IPv4 address on a local interface.
class LanInterface {
  const LanInterface({
    required this.name,
    required this.address,
    this.broadcast,
    this.prefixLength,
  });

  final String name;
  final InternetAddress address;

  /// Directed broadcast address for the subnet, when the OS tells us.
  final InternetAddress? broadcast;
  final int? prefixLength;

  /// Cellular / VPN / tunnel interfaces never reach phones on the same Wi-Fi.
  bool get isLocalNetwork {
    final n = name.toLowerCase();
    const skip = [
      'rmnet',
      'ccmni',
      'pdp',
      'v4-',
      'clat',
      'dummy',
      'tun',
      'ppp',
      'ipsec',
      'lo',
      'utun',
      'ipv6',
      'bond',
      'radio',
    ];
    if (skip.any(n.startsWith)) return false;
    return address.type == InternetAddressType.IPv4 && !address.isLoopback;
  }

  /// The broadcast address to use: the OS-provided one, else a guess from
  /// the prefix length, else /24 (the usual home Wi-Fi / Android hotspot).
  InternetAddress get effectiveBroadcast {
    if (broadcast != null) return broadcast!;
    return computeBroadcast(address, prefixLength ?? 24);
  }

  static InternetAddress computeBroadcast(InternetAddress ip, int prefix) {
    final b = ip.rawAddress;
    final v = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    final mask = prefix <= 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    final bc = (v & mask) | (~mask & 0xFFFFFFFF);
    return InternetAddress(
      '${(bc >> 24) & 255}.${(bc >> 16) & 255}.${(bc >> 8) & 255}.${bc & 255}',
    );
  }

  @override
  String toString() => '$name ${address.address}/${prefixLength ?? '?'}';
}

/// What Android says about the Wi-Fi network (debug + socket rebinding).
class LanNetState {
  const LanNetState({
    this.wifi = false,
    this.validated = false,
    this.bound = false,
    this.wifiLock = false,
    this.generation = 0,
  });

  /// A Wi-Fi network is connected.
  final bool wifi;

  /// Android confirmed that Wi-Fi reaches the internet. Not needed for
  /// LAN; when false Android would otherwise send our traffic over mobile
  /// data, so the app is bound to Wi-Fi instead ([bound]).
  final bool validated;
  final bool bound;

  /// Low-latency Wi-Fi lock held (stops Wi-Fi power save batching packets).
  final bool wifiLock;

  /// Bumps whenever the process network binding changes. Sockets created
  /// before a change keep the old routing, so the LAN socket is recreated.
  final int generation;
}

/// OS hooks the LAN transport needs. The default works anywhere dart:io
/// does; [AndroidLanPlatform] adds the Wi-Fi multicast lock and real
/// netmasks via a small platform channel in MainActivity.kt.
class LanPlatform {
  const LanPlatform();

  /// Android drops incoming broadcast/multicast UDP to save power unless an
  /// app holds a WifiManager.MulticastLock.
  Future<bool> acquireMulticastLock() async => false;
  Future<void> releaseMulticastLock() async {}

  /// Network binding / Wi-Fi lock state, null where not applicable.
  Future<LanNetState?> netState() async => null;

  Future<List<LanInterface>> interfaces() async {
    final out = <LanInterface>[];
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final i in ifaces) {
      for (final a in i.addresses) {
        out.add(LanInterface(name: i.name, address: a));
      }
    }
    return out;
  }
}

class AndroidLanPlatform extends LanPlatform {
  const AndroidLanPlatform();
  static const _ch = MethodChannel('walkie/net');

  @override
  Future<bool> acquireMulticastLock() async {
    try {
      return await _ch.invokeMethod<bool>('acquireMulticastLock') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> releaseMulticastLock() async {
    try {
      await _ch.invokeMethod<void>('releaseMulticastLock');
    } catch (_) {}
  }

  @override
  Future<LanNetState?> netState() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('netState');
      if (m == null) return null;
      return LanNetState(
        wifi: m['wifi'] == true,
        validated: m['validated'] == true,
        bound: m['bound'] == true,
        wifiLock: m['wifiLock'] == true,
        generation: (m['generation'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<LanInterface>> interfaces() async {
    try {
      final list = await _ch.invokeListMethod<Map<dynamic, dynamic>>(
        'interfaces',
      );
      if (list != null) {
        final out = <LanInterface>[];
        for (final m in list) {
          final ip = InternetAddress.tryParse('${m['address']}');
          if (ip == null || ip.type != InternetAddressType.IPv4) continue;
          final bc = m['broadcast'] == null
              ? null
              : InternetAddress.tryParse('${m['broadcast']}');
          out.add(
            LanInterface(
              name: '${m['name']}',
              address: ip,
              broadcast: bc,
              prefixLength: (m['prefix'] as num?)?.toInt(),
            ),
          );
        }
        return out;
      }
    } catch (_) {}
    return super.interfaces();
  }
}
