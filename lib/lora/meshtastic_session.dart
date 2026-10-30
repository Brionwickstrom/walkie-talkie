import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'meshtastic_channels.dart';
import 'meshtastic_proto.dart';

/// The three Meshtastic BLE characteristics, abstracted so the protocol can
/// be tested without a radio.
abstract class MeshtasticWire {
  /// Write one ToRadio protobuf.
  Future<void> write(Uint8List toRadio);

  /// Read FromRadio once; empty when the radio has nothing queued.
  Future<Uint8List> read();

  /// FromNum notifications ("new data in FromRadio").
  Stream<void> get notifications;
}

/// Another Meshtastic node in the radio's node DB.
class RadioNode {
  RadioNode(this.num);
  final int num;
  String longName = '';
  String shortName = '';
  double snr = 0;
  int? hopsAway;
  int? battery;
  DateTime? lastHeard;

  /// RSSI (dBm) of the last packet heard from it, 0 = unknown.
  int rssi = 0;

  /// Where it shares its position (v2.4.2), null if it does not.
  double? lat, lng;

  /// The radio's channel slot it was heard on (decoded traffic only).
  int? channel;
  int hwModel = 0;
  int role = 0;

  /// The radio knows who it is (a decoded NodeInfo).
  bool hasInfo = false;

  /// We have read at least one packet from it (so its channel is one we
  /// have the key for).
  bool decodedHeard = false;

  /// Readable: named by a NodeInfo or heard on a channel we can decode.
  bool get readable => hasInfo || decodedHeard;
}

/// What a received LoRa packet looked like on air.
class RadioSignal {
  RadioSignal(this.snr, this.rssi, this.hopsAway, this.at);
  final double snr;
  final int rssi;

  /// LoRa repeats it took (0 = heard directly), null if unknown.
  final int? hopsAway;
  final DateTime at;
}

/// One phone <-> radio session of the Meshtastic client API:
///
/// 1. write `ToRadio{want_config_id: nonce}`;
/// 2. read FromRadio until it returns an empty buffer; the radio sends
///    my_info, node_infos, config, channels ... then
///    `config_complete_id == nonce`;
/// 3. afterwards read FromRadio again whenever FromNum notifies (and every
///    [pollInterval] in case a notification is missed).
///
/// Mesh packets are sent as `ToRadio{packet: MeshPacket{decoded: Data}}`.
class MeshtasticSession {
  MeshtasticSession(
    this.wire, {
    Random? random,
    DateTime Function()? clock,
    this.pollInterval = const Duration(seconds: 10),
    this.heartbeatInterval = const Duration(seconds: 60),
  }) : _rng = random ?? Random.secure(),
       _clock = clock ?? DateTime.now;

  final MeshtasticWire wire;
  final Random _rng;
  final DateTime Function() _clock;
  final Duration pollInterval;
  final Duration heartbeatInterval;

  int? myNodeNum;
  int? _nonce;
  bool configured = false;
  int? region;
  int? modemPreset;

  /// LoRaConfig.use_preset / channel_num (v1.9.7).
  bool? usePreset;
  int? channelNum;
  int? hopLimit;
  bool? txEnabled;

  /// The radio's channels by slot (v1.9.7), keys dropped
  /// ([MeshRadioChannel] keeps only their kind and hash part).
  final Map<int, MeshRadioChannel> channels = {};

  /// Times the radio said it restarted / finished sending its settings.
  int rebootCount = 0;
  int configCount = 0;

  /// BluetoothConfig.mode: 0 random PIN, 1 fixed PIN, 2 no PIN.
  int? pairingMode;
  int? fixedPin;
  String? primaryChannelName;
  bool? primaryUsesDefaultKey;

  /// Our own radio's battery (%), 101 = on external power.
  int? battery;
  double? voltage;

  /// Channel busy % reported by the radio.
  double? channelUtilization;

  /// Free slots in the radio's transmit queue (null until reported).
  int? queueFree;
  int? queueMax;
  RadioSignal? lastSignal;
  final Map<int, RadioNode> nodes = {};
  int sent = 0;
  int received = 0;

  final _packets = StreamController<MeshPacketPb>.broadcast();
  final _admin = StreamController<MeshPacketPb>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _poll;
  Timer? _heartbeat;
  Future<void>? _draining;
  bool _drainAgain = false;
  bool _closed = false;
  Completer<void>? _configDone;

  /// Packets from other nodes (any port).
  Stream<MeshPacketPb> get packets => _packets.stream;
  Stream<void> get changes => _changes.stream;

  /// Admin (and routing) answers from our own radio (v1.9.7).
  Stream<MeshPacketPb> get adminReplies => _admin.stream;

  /// Name the radio gives unnamed channels (its preset, e.g. "LongFast").
  String get presetDisplayName =>
      meshPresetDisplayName(modemPreset ?? 0, usePreset: usePreset ?? true);

  MeshRadioChannel? get primaryChannel {
    for (final c in channels.values) {
      if (c.isPrimary) return c;
    }
    return null;
  }

  /// [c]'s link on this radio (name + hash as the firmware computes them).
  MeshChannelRef refOf(MeshRadioChannel c) =>
      c.ref(presetDisplayName, primaryKeyXor: primaryChannel?.keyXor ?? 0);

  /// Slot of the channel [ref] on this radio (primary or secondary), or
  /// null when it is not on it.
  int? indexOf(MeshChannelRef ref) {
    final list = channels.values.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    for (final c in list) {
      if (c.isDisabled) continue;
      if (refOf(c) == ref) return c.index;
    }
    return null;
  }

  /// Slot of the channel called "admin" (legacy admin channel), else 0.
  int get adminChannelIndex {
    for (final c in channels.values) {
      if (!c.isDisabled && c.name.toLowerCase() == 'admin') return c.index;
    }
    return 0;
  }

  /// Other nodes we only know as a number and a signal (heard on a channel
  /// we cannot decode, no NodeInfo).
  int get unreadableCount =>
      nodes.values.where((n) => n.num != myNodeNum && !n.readable).length;

  /// Other nodes in the radio's DB.
  int get nodeCount => nodes.keys.where((n) => n != myNodeNum).length;

  /// Start the session; completes when the configuration download is done
  /// (or after [timeout], the session keeps going either way).
  Future<void> start({Duration timeout = const Duration(seconds: 20)}) async {
    _subs.add(wire.notifications.listen((_) => drain()));
    _nonce = _rng.nextInt(0x7FFFFFF0) + 1;
    // 69420 / 69421 are special "only config / only nodes" nonces.
    if (_nonce == 69420 || _nonce == 69421) _nonce = _nonce! + 7;
    _configDone = Completer<void>();
    await wire.write(ToRadio.wantConfig(_nonce!));
    await drain();
    _poll = Timer.periodic(pollInterval, (_) => drain());
    _heartbeat = Timer.periodic(heartbeatInterval, (_) => _sendHeartbeat());
    try {
      await _configDone!.future.timeout(timeout);
    } on TimeoutException {
      // Old firmware or a lost packet: carry on with what we have.
    }
  }

  Future<void> _sendHeartbeat() async {
    if (_closed) return;
    try {
      await wire.write(ToRadio.heartbeat());
      await drain();
    } catch (_) {}
  }

  /// Read FromRadio until empty. Concurrent calls coalesce.
  Future<void> drain() {
    if (_closed) return Future.value();
    if (_draining != null) {
      _drainAgain = true;
      return _draining!;
    }
    final f = _drainLoop().whenComplete(() => _draining = null);
    _draining = f;
    return f;
  }

  Future<void> _drainLoop() async {
    do {
      _drainAgain = false;
      for (var i = 0; i < 500 && !_closed; i++) {
        final Uint8List b;
        try {
          b = await wire.read();
        } catch (_) {
          return;
        }
        if (b.isEmpty) break;
        final m = FromRadio.tryDecode(b);
        if (m != null) handle(m);
      }
    } while (_drainAgain && !_closed);
  }

  /// Process one FromRadio message (public for tests).
  void handle(FromRadio m) {
    var changed = false;
    final my = m.myInfo;
    if (my != null) {
      myNodeNum = my.myNodeNum;
      changed = true;
    }
    final n = m.nodeInfo;
    if (n != null && n.num != 0) {
      final node = nodes.putIfAbsent(n.num, () => RadioNode(n.num));
      if (n.longName.isNotEmpty) node.longName = n.longName;
      if (n.shortName.isNotEmpty) node.shortName = n.shortName;
      node.snr = n.snr;
      node.hopsAway = n.hopsAway;
      if (n.hasUser) {
        node.hasInfo = true;
        node.hwModel = n.hwModel;
        node.role = n.role;
        if (n.channel != null) node.channel = n.channel;
      }
      final pos = n.position;
      if (pos != null) {
        node.lat = pos.lat;
        node.lng = pos.lng;
      }
      if (n.lastHeard > 0) {
        node.lastHeard = DateTime.fromMillisecondsSinceEpoch(
          n.lastHeard * 1000,
        );
      }
      final bat = n.metrics?.batteryLevel;
      if (bat != null) node.battery = bat;
      if (n.num == myNodeNum) {
        battery = bat ?? battery;
        voltage = n.metrics?.voltage ?? voltage;
      }
      changed = true;
    }
    final c = m.config;
    if (c != null) {
      if (c.region != null) {
        region = c.region;
        modemPreset = c.modemPreset;
        usePreset = c.usePreset;
        channelNum = c.channelNum;
        hopLimit = c.hopLimit;
        txEnabled = c.txEnabled;
      }
      if (c.btMode != null) {
        pairingMode = c.btMode;
        fixedPin = c.fixedPin;
      }
      changed = true;
    }
    final ch = m.channel;
    if (ch != null && ch.index >= 0 && ch.index < meshMaxChannels) {
      channels[ch.index] = MeshRadioChannel.fromChannel(
        index: ch.index,
        role: ch.role,
        name: ch.name,
        psk: ch.psk,
        uplinkEnabled: ch.uplink,
      );
      changed = true;
    }
    if (ch != null && ch.isPrimary) {
      primaryChannelName = ch.name;
      primaryUsesDefaultKey = ch.usesDefaultKey;
      changed = true;
    }
    final q = m.queueStatus;
    if (q != null) {
      queueFree = q.free;
      queueMax = q.maxlen;
      changed = true;
    }
    if (m.configCompleteId != null && m.configCompleteId == _nonce) {
      configured = true;
      configCount++;
      final done = _configDone;
      if (done != null && !done.isCompleted) done.complete();
      changed = true;
    }
    if (m.rebooted) {
      // The radio restarted: ask for the configuration again.
      configured = false;
      rebootCount++;
      _nonce = _rng.nextInt(0x7FFFFFF0) + 1;
      unawaited(wire.write(ToRadio.wantConfig(_nonce!)).catchError((_) {}));
      changed = true;
    }
    final p = m.packet;
    if (p != null) changed |= _onPacket(p);
    if (changed && !_changes.isClosed) _changes.add(null);
  }

  bool _onPacket(MeshPacketPb p) {
    final d = p.decoded;
    if (d != null &&
        (d.portnum == PortNum.admin || d.portnum == PortNum.routing) &&
        (p.from == myNodeNum || p.from == 0)) {
      if (!_admin.isClosed) _admin.add(p);
      return false;
    }
    if (p.from == myNodeNum) {
      // Our own radio's telemetry (battery).
      if (d != null && d.portnum == PortNum.telemetry) {
        try {
          final dm = decodeTelemetryDeviceMetrics(d.payload);
          if (dm != null) {
            battery = dm.batteryLevel ?? battery;
            voltage = dm.voltage ?? voltage;
            channelUtilization = dm.channelUtilization ?? channelUtilization;
            return true;
          }
        } catch (_) {}
      }
      return false;
    }
    final now = _clock();
    if (p.rxSnr != 0 || p.rxRssi != 0) {
      lastSignal = RadioSignal(p.rxSnr, p.rxRssi, p.hopsAway, now);
    }
    final node = nodes.putIfAbsent(p.from, () => RadioNode(p.from));
    node.lastHeard = now;
    if (p.rxSnr != 0) node.snr = p.rxSnr;
    if (p.rxRssi != 0) node.rssi = p.rxRssi;
    if (p.hopsAway != null) node.hopsAway = p.hopsAway;
    if (d == null) return true; // not for our channel key
    node.decodedHeard = true;
    node.channel = p.channel;
    // Position and battery the node itself sent on a channel we read: free
    // information, nothing is asked for.
    try {
      if (d.portnum == PortNum.position) {
        final pos = PositionPb.decode(d.payload);
        if (pos != null) {
          node.lat = pos.lat;
          node.lng = pos.lng;
        }
      } else if (d.portnum == PortNum.telemetry) {
        final dm = decodeTelemetryDeviceMetrics(d.payload);
        if (dm?.batteryLevel != null) node.battery = dm!.batteryLevel;
      }
    } catch (_) {}
    received++;
    if (!_packets.isClosed) _packets.add(p);
    return true;
  }

  /// Queue [payload] on [port] for [to] (a node number or [meshBroadcast]).
  /// Returns the packet id.
  Future<int> send(
    Uint8List payload, {
    int to = meshBroadcast,
    int port = PortNum.privateApp,
    bool wantAck = false,
    bool wantResponse = false,
    int priority = 0,
    int channel = 0,
    int hopLimitOverride = 0,
  }) async {
    if (payload.length > meshDataPayloadLen) {
      throw ArgumentError('payload ${payload.length} > $meshDataPayloadLen');
    }
    final id = _rng.nextInt(0x7FFFFFFF) + 1;
    final pkt = MeshPacketPb(
      to: to,
      channel: channel,
      id: id,
      wantAck: wantAck,
      // The radio's own hop limit (Meshtastic repeats it that many
      // times); 3 is the firmware default.
      hopLimit: hopLimitOverride > 0
          ? hopLimitOverride
          : (hopLimit ?? 0) > 0
          ? hopLimit!
          : 3,
      priority: priority,
      decoded: MeshData(
        portnum: port,
        payload: payload,
        wantResponse: wantResponse,
      ),
    );
    await wire.write(ToRadio.packet(pkt));
    if (port == PortNum.admin) return id;
    sent++;
    if (queueFree != null && queueFree! > 0) queueFree = queueFree! - 1;
    return id;
  }

  /// One AdminMessage to our own radio (v1.9.7), on its admin channel.
  Future<int> sendAdmin(Uint8List admin, {bool wantResponse = true}) {
    final me = myNodeNum;
    if (me == null) throw StateError('radio not configured');
    return send(
      admin,
      to: me,
      port: PortNum.admin,
      wantAck: true,
      wantResponse: wantResponse,
      channel: adminChannelIndex,
    );
  }

  /// Download the radio's settings again (after a change that did not
  /// restart it). Completes when done or after [timeout].
  Future<void> requestConfig({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_closed) return;
    configured = false;
    _nonce = _rng.nextInt(0x7FFFFFF0) + 1;
    if (_nonce == 69420 || _nonce == 69421) _nonce = _nonce! + 7;
    final done = Completer<void>();
    _configDone = done;
    await wire.write(ToRadio.wantConfig(_nonce!));
    await drain();
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      // Carry on with what we have.
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    _heartbeat?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final done = _configDone;
    if (done != null && !done.isCompleted) done.complete();
    await _packets.close();
    await _admin.close();
    await _changes.close();
  }
}
