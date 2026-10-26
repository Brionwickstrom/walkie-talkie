import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/frame.dart';
import '../core/transport.dart';

/// Native side of Wi-Fi Direct (Android `WifiDirectBridge.kt`).
abstract class WifiDirectPlatform {
  /// Events: `{t: found, addr, id}` an app phone advertising our service;
  /// `{t: conn, formed, owner, go}` group state; `{t: state, enabled}`
  /// Wi-Fi P2P on/off; `{t: error, msg}`.
  Stream<Map<String, Object?>> get events;

  /// Register our service and start discovery. Returns null when running,
  /// else a short reason ("permission", "unsupported", "disabled", ...).
  Future<String?> start(int nodeId);
  Future<void> stop();

  /// Ask to join [address]'s group (or form one with it). [ownerIntent] is
  /// 0..15, the wish to be group owner.
  Future<void> connect(String address, {int ownerIntent = 0});

  /// Faster / slower service discovery (battery saver, already in a group).
  Future<void> setDiscoveryInterval(Duration every);
}

class MethodChannelWifiDirect implements WifiDirectPlatform {
  const MethodChannelWifiDirect();
  static const _m = MethodChannel('walkie/wifidirect');
  static const _e = EventChannel('walkie/wifidirect/events');

  @override
  Stream<Map<String, Object?>> get events => _e.receiveBroadcastStream().map(
    (e) => e is Map ? Map<String, Object?>.from(e) : const {},
  );

  @override
  Future<String?> start(int nodeId) async {
    try {
      return await _m.invokeMethod<String>('start', {'id': nodeId});
    } on MissingPluginException {
      return 'unsupported';
    } catch (e) {
      return '$e';
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _m.invokeMethod<void>('stop');
    } catch (_) {}
  }

  @override
  Future<void> connect(String address, {int ownerIntent = 0}) async {
    try {
      await _m.invokeMethod<void>('connect', {
        'addr': address,
        'intent': ownerIntent,
      });
    } catch (_) {}
  }

  @override
  Future<void> setDiscoveryInterval(Duration every) async {
    try {
      await _m.invokeMethod<void>('interval', {'ms': every.inMilliseconds});
    } catch (_) {}
  }
}

/// A phone running the app found over Wi-Fi Direct service discovery.
class WifiDirectPeer {
  WifiDirectPeer(this.address, this.nodeId, this.firstSeen);
  final String address;
  final int nodeId;
  final DateTime firstSeen;
  DateTime lastSeen = DateTime.now();
  DateTime? lastAttempt;
}

/// When to ask the system to form / join a group (pure, unit tested).
///
/// * Never while we are already in a group (others join us instead).
/// * Never when a shared network already links us (LAN works, faster and
///   with no pairing prompt).
/// * Only the phone with the larger id asks (it then becomes a client, the
///   smaller id the group owner), so both sides do not invite each other at
///   once; after [fallbackAfter] without a group either side may ask, in
///   case the other one cannot see us.
/// * At most one attempt per peer per [retryEvery].
class WifiDirectPolicy {
  const WifiDirectPolicy({
    this.retryEvery = const Duration(seconds: 60),
    this.fallbackAfter = const Duration(seconds: 25),
  });
  final Duration retryEvery;
  final Duration fallbackAfter;

  bool shouldConnect({
    required int localId,
    required WifiDirectPeer peer,
    required bool inGroup,
    required bool sharedNetwork,
    required DateTime now,
  }) {
    if (inGroup || sharedNetwork) return false;
    final last = peer.lastAttempt;
    if (last != null && now.difference(last) < retryEvery) return false;
    if (localId > peer.nodeId) return true;
    return now.difference(peer.firstSeen) >= fallbackAfter;
  }
}

/// Wi-Fi Direct (Wi-Fi P2P) transport, Android only.
///
/// With no router or internet, nearby app phones find each other with
/// Wi-Fi P2P service discovery and form a group (range ~100-200 m, much
/// more bandwidth than Bluetooth). Inside the group the same frames as on
/// the LAN travel as UDP on [port]: clients start by sending to the group
/// owner (always 192.168.49.1 on Android), the owner answers, and
/// everyone also broadcasts on the group subnet. Phones that cannot hear
/// each other inside the group are joined by the mesh relay.
///
/// Groups are only formed when we have no shared network with that phone.
/// iOS has no public Wi-Fi Direct API: the transport reports unavailable
/// there and iPhones keep using Bluetooth / hotspot.
class WifiDirectTransport extends Transport {
  WifiDirectTransport({
    WifiDirectPlatform? platform,
    this.port = defaultPort,
    this.policy = const WifiDirectPolicy(),
    this.sharedNetworkWith,
    bool? supported,
    DateTime Function()? clock,
  }) : _platform = platform ?? const MethodChannelWifiDirect(),
       _supported = supported ?? Platform.isAndroid,
       _clock = clock ?? DateTime.now;

  static const int defaultPort = 47475;
  static final InternetAddress groupOwner = InternetAddress('192.168.49.1');
  static final InternetAddress groupBroadcast = InternetAddress(
    '192.168.49.255',
  );

  final WifiDirectPlatform _platform;
  final bool _supported;
  final int port;
  final WifiDirectPolicy policy;
  final DateTime Function() _clock;

  /// True when [nodeId] is already reachable over a shared network (LAN).
  bool Function(int nodeId)? sharedNetworkWith;

  /// Off in Settings: stay stopped.
  bool enabled = true;

  TransportStatus _status = TransportStatus.stopped;
  String? _detail;
  final _statusCtl = StreamController<TransportStatus>.broadcast();
  final _framesCtl = StreamController<InboundFrame>.broadcast();
  StreamSubscription<Map<String, Object?>>? _eventsSub;
  RawDatagramSocket? _socket;
  int _localId = 0;
  bool _inGroup = false;
  bool _owner = false;
  final Map<String, WifiDirectPeer> _found = {};
  final Map<int, (InternetAddress, int)> _endpoints = {};
  final Map<int, DateTime> _heard = {};
  bool _saver = false;

  @override
  TransportKind get kind => TransportKind.wifiDirect;

  @override
  TransportStatus get status => _status;

  @override
  String? get statusDetail => _detail;

  @override
  Stream<TransportStatus> get statusChanges => _statusCtl.stream;

  @override
  Stream<InboundFrame> get frames => _framesCtl.stream;

  bool get inGroup => _inGroup;
  bool get isGroupOwner => _owner;
  Iterable<WifiDirectPeer> get found => _found.values;

  void _setStatus(TransportStatus s, [String? detail]) {
    _status = s;
    _detail = detail;
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  @override
  Future<void> start({required int localNodeId, required int channel}) async {
    _localId = localNodeId;
    if (!_supported) {
      _setStatus(
        TransportStatus.unavailable,
        'Android only (iPhone uses Bluetooth / hotspot)',
      );
      return;
    }
    if (!enabled) {
      _setStatus(TransportStatus.unavailable, 'Off in Settings');
      return;
    }
    _setStatus(TransportStatus.starting);
    _eventsSub ??= _platform.events.listen(onEvent, onError: (Object _) {});
    final err = await _platform.start(localNodeId);
    if (err != null) {
      _setStatus(TransportStatus.unavailable, switch (err) {
        'permission' => 'Allow "Nearby devices" / location for Wi-Fi Direct',
        'disabled' => 'Turn Wi-Fi on for Wi-Fi Direct',
        'unsupported' => 'Not supported on this phone',
        _ => err,
      });
      return;
    }
    await _platform.setDiscoveryInterval(_discoveryInterval);
    // Searching counts as running: frames flow as soon as a group forms.
    _setStatus(TransportStatus.running, 'searching');
  }

  Duration get _discoveryInterval => _burstUntil != null
      ? const Duration(seconds: 10)
      : _offline
      ? const Duration(minutes: 15)
      : Duration(seconds: _inGroup ? 120 : (_saver ? 90 : 30));

  /// Offline power save: discovery only on demand ([discoverNow]).
  bool _offline = false;
  bool get offlineSaver => _offline;
  DateTime? _burstUntil;
  Timer? _burstTimer;

  /// Current discovery period (tests / debug).
  Duration get discoveryInterval => _discoveryInterval;

  @override
  void setOfflineSaver(bool on) {
    _offline = on;
    if (on) _saver = true;
    if (_status == TransportStatus.running) {
      unawaited(_platform.setDiscoveryInterval(_discoveryInterval));
    }
  }

  /// Look for Wi-Fi Direct phones now (fast discovery for [forTime]).
  void discoverNow({Duration forTime = const Duration(seconds: 45)}) {
    _burstUntil = DateTime.now().add(forTime);
    _burstTimer?.cancel();
    _burstTimer = Timer(forTime, () {
      _burstUntil = null;
      if (_status == TransportStatus.running) {
        unawaited(_platform.setDiscoveryInterval(_discoveryInterval));
      }
    });
    if (_status == TransportStatus.running) {
      unawaited(_platform.setDiscoveryInterval(_discoveryInterval));
    }
  }

  @override
  Future<void> stop() async {
    _burstTimer?.cancel();
    _burstUntil = null;
    await _eventsSub?.cancel();
    _eventsSub = null;
    _closeSocket();
    _inGroup = false;
    _found.clear();
    if (_supported) await _platform.stop();
    if (_status != TransportStatus.unavailable) {
      _setStatus(TransportStatus.stopped);
    }
  }

  @override
  void setPowerSaver(bool on) {
    _saver = on;
    if (_status == TransportStatus.running) {
      unawaited(_platform.setDiscoveryInterval(_discoveryInterval));
    }
  }

  /// Native event (public for tests).
  void onEvent(Map<String, Object?> e) {
    switch (e['t']) {
      case 'found':
        final addr = e['addr'] as String?;
        final id = (e['id'] as num?)?.toInt();
        if (addr == null || id == null || id == _localId) return;
        final now = _clock();
        final p = _found.putIfAbsent(addr, () => WifiDirectPeer(addr, id, now))
          ..lastSeen = now;
        _maybeConnect(p, now);
      case 'conn':
        final formed = e['formed'] == true;
        _owner = formed && e['owner'] == true;
        if (formed && !_inGroup) {
          _inGroup = true;
          unawaited(_openSocket());
          unawaited(_platform.setDiscoveryInterval(_discoveryInterval));
        } else if (!formed && _inGroup) {
          _inGroup = false;
          _closeSocket();
          unawaited(_platform.setDiscoveryInterval(_discoveryInterval));
        }
        if (_status == TransportStatus.running) {
          _setStatus(
            TransportStatus.running,
            _inGroup ? (_owner ? 'group owner' : 'in group') : 'searching',
          );
        }
      case 'state':
        if (e['enabled'] == false) {
          _inGroup = false;
          _closeSocket();
          _setStatus(TransportStatus.unavailable, 'Turn Wi-Fi on');
        } else if (_status == TransportStatus.unavailable &&
            _detail == 'Turn Wi-Fi on') {
          _setStatus(TransportStatus.running, 'searching');
        }
    }
  }

  void _maybeConnect(WifiDirectPeer p, DateTime now) {
    if (_status != TransportStatus.running) return;
    final shared = sharedNetworkWith?.call(p.nodeId) ?? false;
    if (!policy.shouldConnect(
      localId: _localId,
      peer: p,
      inGroup: _inGroup,
      sharedNetwork: shared,
      now: now,
    )) {
      return;
    }
    p.lastAttempt = now;
    // The asking phone prefers to be a client; the other one (or an
    // existing group's owner) hosts.
    unawaited(_platform.connect(p.address, ownerIntent: 0));
  }

  Future<void> _openSocket() async {
    if (_socket != null) return;
    try {
      final s = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        Datagram? dg;
        while ((dg = s.receive()) != null) {
          onDatagram(dg!.data, dg.address, dg.port);
        }
      });
      _socket = s;
    } catch (e) {
      _detail = 'socket: $e';
    }
  }

  void _closeSocket() {
    _socket?.close();
    _socket = null;
    _endpoints.clear();
    _heard.clear();
  }

  /// A UDP datagram arrived on the group (public for tests).
  void onDatagram(Uint8List data, InternetAddress from, int fromPort) {
    final f = Frame.tryDecode(data);
    if (f == null || f.senderId == _localId) return;
    _endpoints[f.senderId] = (from, fromPort);
    _heard[f.senderId] = _clock();
    if (!_framesCtl.isClosed) {
      _framesCtl.add(InboundFrame(f, TransportKind.wifiDirect));
    }
  }

  @override
  bool canReach(int peerId) => _endpoints.containsKey(peerId);

  @override
  Future<void> send(Uint8List frame, {Set<int>? peerIds}) async {
    final s = _socket;
    if (s == null) return;
    if (peerIds == null) {
      final sent = <(InternetAddress, int)>{};
      for (final ep in _endpoints.values) {
        if (sent.add(ep)) _try(s, frame, ep.$1, ep.$2);
      }
      if (!_owner) _try(s, frame, groupOwner, port);
      _try(s, frame, groupBroadcast, port);
      return;
    }
    for (final id in peerIds) {
      final ep = _endpoints[id];
      if (ep != null) _try(s, frame, ep.$1, ep.$2);
    }
  }

  void _try(RawDatagramSocket s, Uint8List b, InternetAddress a, int p) {
    try {
      s.send(b, a, p);
    } catch (_) {}
  }

  @override
  String? get debugInfo =>
      '${_inGroup ? (_owner ? 'owner' : 'client') : 'no group'} · '
      '${_found.length} found · ${_endpoints.length} linked';

  @override
  Future<void> dispose() async {
    await stop();
    await _statusCtl.close();
    await _framesCtl.close();
  }
}
