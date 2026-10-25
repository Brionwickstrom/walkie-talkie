import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A LAN address ("ip:port") we have heard another phone on, and when.
class KnownLanPeer {
  const KnownLanPeer(this.endpoint, this.lastHeard);
  final String endpoint;
  final DateTime lastHeard;

  Map<String, Object> toJson() => {
    'ep': endpoint,
    't': lastHeard.millisecondsSinceEpoch,
  };

  static KnownLanPeer? fromJson(Object? j) {
    if (j is! Map) return null;
    final ep = j['ep'];
    final t = j['t'];
    if (ep is! String || t is! int) return null;
    return KnownLanPeer(ep, DateTime.fromMillisecondsSinceEpoch(t));
  }
}

/// Remembers LAN addresses of other phones across app restarts, so a phone
/// can be found again by plain unicast even when the router blocks
/// broadcast, multicast and mDNS and Bluetooth is off.
abstract class LanPeerStore {
  Future<List<KnownLanPeer>> load();
  Future<void> save(List<KnownLanPeer> peers);
}

class MemoryLanPeerStore implements LanPeerStore {
  List<KnownLanPeer> saved = [];
  int saves = 0;

  @override
  Future<List<KnownLanPeer>> load() async => List.of(saved);

  @override
  Future<void> save(List<KnownLanPeer> peers) async {
    saved = List.of(peers);
    saves++;
  }
}

class SharedPrefsLanPeerStore implements LanPeerStore {
  const SharedPrefsLanPeerStore();
  static const String key = 'lan_known_peers_v1';

  @override
  Future<List<KnownLanPeer>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final j in list) ?KnownLanPeer.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(List<KnownLanPeer> peers) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode([for (final p in peers) p.toJson()]),
      );
    } catch (_) {}
  }
}
