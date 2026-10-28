import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../lora/meshtastic_channels.dart';
import '../lora/meshtastic_proto.dart';
import '../lora/meshtastic_session.dart';
import 'gateway_core.dart';
import 'stream_wire.dart';

/// Gateway container version (shown in /healthz).
const String gatewayVersion = '1.1.0';

void gwLog(String msg) {
  final t = DateTime.now().toIso8601String().substring(0, 19);
  stdout.writeln('$t $msg');
}

/// One radio from the config file.
class RadioConfig {
  RadioConfig({required this.name, this.serial, this.tcp});

  final String name;

  /// Serial device path, or "auto" (first /dev/ttyACM*, /dev/ttyUSB*).
  final String? serial;

  /// "host:port" of a network (Wi-Fi / Ethernet) radio; port 4403 if left
  /// out.
  final String? tcp;

  String get key => serial != null ? 'serial:$serial' : 'tcp:$tcp';

  static RadioConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    final serial = j['serial'] as String?;
    final tcp = j['tcp'] as String?;
    if ((serial == null) == (tcp == null)) return null;
    if (j['enabled'] == false) return null;
    return RadioConfig(
      name: (j['name'] as String?) ?? (serial != null ? 'USB radio' : tcp!),
      serial: serial,
      tcp: tcp,
    );
  }
}

class GatewayConfig {
  GatewayConfig({
    required this.name,
    required this.relay,
    required this.healthPort,
    required this.rooms,
    required this.radios,
    this.meshChannels = const {},
  });

  final String name;

  /// Walkie channel -> linked Meshtastic channel (v1.9.7):
  /// "meshChannels": {"5": {"name": "Trail", "hash": 123}}. Optional: the
  /// v1.9.7 app names the channel in its requests anyway.
  final Map<int, MeshChannelRef> meshChannels;
  final Uri relay;
  final int healthPort;
  final Set<String> rooms;
  final List<RadioConfig> radios;

  static const defaultJson = '''{
  "name": "Home gateway",
  "relay": "ws://127.0.0.1:47480/ws",
  "healthPort": 47481,
  "rooms": ["1", "2", "3", "4", "5", "6", "7", "8",
            "9", "10", "11", "12", "13", "14", "15", "16"],
  "radios": [
    {"name": "Home RAK (USB)", "serial": "auto"}
  ],
  "_help": [
    "Radios: add one entry per radio. USB: {\\"name\\": \\"...\\", \\"serial\\": \\"auto\\"} or a path like /dev/ttyACM0.",
    "Wi-Fi / network radio: {\\"name\\": \\"Van radio\\", \\"tcp\\": \\"192.168.1.50:4403\\"}.",
    "Turn one off without deleting it: \\"enabled\\": false.",
    "Radios and rooms are picked up within 15 s, no restart needed. Private groups join on their own when their LoRa traffic is heard.",
    "Optional meshChannels: {\\"5\\": {\\"name\\": \\"Trail\\", \\"hash\\": 123}} sends open Walkie channel 5 on that Meshtastic channel of each radio (the app shows name and hash under Meshtastic channels). Phones with v1.9.7 tell the gateway themselves."
  ]
}
''';

  static GatewayConfig parse(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    final radios = <RadioConfig>[];
    for (final r in (j['radios'] as List? ?? const [])) {
      final c = RadioConfig.fromJson(r);
      if (c != null) radios.add(c);
    }
    final mesh = <int, MeshChannelRef>{};
    final mc = j['meshChannels'];
    if (mc is Map) {
      mc.forEach((k, v) {
        final ch = int.tryParse('$k');
        final ref = MeshChannelRef.fromJson(v);
        if (ch != null && ch >= 1 && ch <= 16 && ref != null) mesh[ch] = ref;
      });
    }
    return GatewayConfig(
      meshChannels: mesh,
      name: (j['name'] as String?) ?? 'Home gateway',
      relay: Uri.parse((j['relay'] as String?) ?? 'ws://127.0.0.1:47480/ws'),
      healthPort: (j['healthPort'] as num?)?.toInt() ?? 47481,
      rooms: {for (final r in (j['rooms'] as List? ?? const [])) '$r'},
      radios: radios,
    );
  }
}

enum RadioConnState { waiting, connecting, ready, error }

/// A Meshtastic radio over USB serial or TCP, reconnecting forever. A
/// missing USB device is normal ("waiting for radio"): it is picked up
/// within a few seconds of being plugged in.
class GatewayRadio implements GatewayRadioLink {
  GatewayRadio(this.config, {this.retry = const Duration(seconds: 5)});

  final RadioConfig config;
  final Duration retry;

  RadioConnState state = RadioConnState.waiting;
  String detail = 'starting';
  String? device;
  MeshtasticSession? session;
  DateTime? connectedAt;
  DateTime? _lastRx;
  int reconnects = 0;
  bool _closed = false;
  Completer<void>? _stop;

  final _packets = StreamController<MeshPacketPb>.broadcast();

  @override
  String get name => config.name;
  @override
  bool get ready => state == RadioConnState.ready;
  @override
  int? get myNode => session?.myNodeNum;
  @override
  int? get queueFree => session?.queueFree;
  @override
  Stream<MeshPacketPb> get packets => _packets.stream;

  @override
  Future<void> send(
    Uint8List payload, {
    int to = meshBroadcast,
    bool wantAck = false,
    int priority = 0,
    int channel = 0,
  }) async {
    final s = session;
    if (s == null || !ready) throw StateError('radio not ready');
    await s.send(
      payload,
      to: to,
      wantAck: wantAck,
      priority: priority,
      channel: channel,
    );
  }

  @override
  int? meshChannelIndex(MeshChannelRef ref) => session?.indexOf(ref);

  void start() => unawaited(_loop());

  Future<void> close() async {
    _closed = true;
    final s = _stop;
    if (s != null && !s.isCompleted) s.complete();
  }

  void _set(RadioConnState s, String d) {
    if (s != state || d != detail) {
      gwLog('radio "${config.name}": ${s.name} ($d)');
    }
    state = s;
    detail = d;
  }

  static Future<String?> findSerial(String spec) async {
    if (spec != 'auto') return await File(spec).exists() ? spec : null;
    for (final prefix in ['ttyACM', 'ttyUSB']) {
      for (var i = 0; i < 8; i++) {
        final p = '/dev/$prefix$i';
        if (await File(p).exists()) return p;
      }
    }
    return null;
  }

  Future<void> _loop() async {
    while (!_closed) {
      try {
        await _connectOnce();
      } catch (e) {
        _set(RadioConnState.error, '$e'.split('\n').first);
      }
      session = null;
      if (_closed) break;
      if (state == RadioConnState.ready || state == RadioConnState.connecting) {
        _set(RadioConnState.error, 'link lost, retrying');
      }
      if (state != RadioConnState.waiting) reconnects++;
      await Future<void>.delayed(retry);
    }
  }

  Future<void> _connectOnce() async {
    StreamWire wire;
    Future<void> Function()? closer;
    if (config.serial != null) {
      final path = await findSerial(config.serial!);
      if (path == null) {
        _set(
          RadioConnState.waiting,
          config.serial == 'auto'
              ? 'waiting for radio: no /dev/ttyACM* or /dev/ttyUSB* (plug the radio into the NAS USB port)'
              : 'waiting for radio: ${config.serial} not present',
        );
        return;
      }
      device = path;
      _set(RadioConnState.connecting, 'opening $path');
      final stty = await Process.run('stty', [
        '-F',
        path,
        '115200',
        'raw',
        '-echo',
        '-echoe',
        '-echok',
        '-hupcl',
        'min',
        '1',
        'time',
        '0',
      ]);
      if (stty.exitCode != 0) {
        throw 'stty failed: ${'${stty.stderr}'.trim()}';
      }
      final out = await File(path).open(mode: FileMode.writeOnlyAppend);
      final input = File(path).openRead();
      wire = StreamWire(input, (b) async {
        await out.writeFrom(b);
      });
      closer = () async {
        await wire.close();
        try {
          await out.close();
        } catch (_) {}
      };
      await out.writeFrom(StreamFramer.wake());
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } else {
      final parts = config.tcp!.split(':');
      final host = parts.first;
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 4403 : 4403;
      device = '$host:$port';
      _set(RadioConnState.connecting, 'connecting to $host:$port');
      final sock = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );
      sock.setOption(SocketOption.tcpNoDelay, true);
      wire = StreamWire(sock, (b) async {
        sock.add(b);
        await sock.flush();
      });
      closer = () async {
        await wire.close();
        sock.destroy();
      };
    }
    final s = MeshtasticSession(wire, random: Random.secure());
    session = s;
    final sub = s.packets.listen((p) {
      _lastRx = DateTime.now();
      if (!_packets.isClosed) _packets.add(p);
    });
    final chg = s.changes.listen((_) => _lastRx = DateTime.now());
    _stop = Completer<void>();
    try {
      _set(RadioConnState.connecting, 'reading radio settings');
      await s.start(timeout: const Duration(seconds: 30));
      if (s.myNodeNum == null) throw 'no answer from the radio';
      connectedAt = DateTime.now();
      _lastRx = DateTime.now();
      _set(
        RadioConnState.ready,
        'node !${s.myNodeNum!.toRadixString(16)} on $device'
        '${s.configured ? '' : ' (settings incomplete)'}',
      );
      // Stay until the link drops, goes silent (the radio answers every
      // heartbeat), or the radio is removed from the config.
      final watchdog = Timer.periodic(const Duration(seconds: 30), (_) {
        final last = _lastRx;
        if (last != null &&
            DateTime.now().difference(last) > const Duration(minutes: 4)) {
          final st = _stop;
          if (st != null && !st.isCompleted) st.complete();
        }
      });
      await Future.any([wire.done, _stop!.future]);
      watchdog.cancel();
    } finally {
      await sub.cancel();
      await chg.cancel();
      await s.close();
      await closer();
      if (!_closed) _set(RadioConnState.error, 'link lost, retrying');
    }
  }

  Map<String, Object?> status() {
    final s = session;
    final now = DateTime.now();
    return {
      'name': config.name,
      'type': config.serial != null ? 'usb' : 'wifi/tcp',
      'target': config.serial ?? config.tcp,
      'device': device,
      'state': state.name,
      'detail': detail,
      if (s?.myNodeNum != null) 'node': '!${s!.myNodeNum!.toRadixString(16)}',
      if (s != null && ready) ...{
        'nodesInRadioDb': s.nodeCount,
        'channelName': s.primaryChannelName,
        'channelUsesDefaultKey': s.primaryUsesDefaultKey,
        // Names and hashes only, never keys.
        'meshChannels': [
          for (final c
              in (s.channels.values.toList()
                ..sort((a, b) => a.index.compareTo(b.index))))
            if (!c.isDisabled)
              {
                'index': c.index,
                'role': c.isPrimary ? 'primary' : 'secondary',
                'name': s.refOf(c).name,
                'hash': s.refOf(c).hash,
                'key': c.keyKind.name,
              },
        ],
        'battery': s.battery,
        'channelUtilization': s.channelUtilization,
        'txEnabled': s.txEnabled,
      },
      if (_lastRx != null) 'lastHeardSec': now.difference(_lastRx!).inSeconds,
      'reconnects': reconnects,
    };
  }
}

/// One relay room over WebSocket, reconnecting with backoff.
class WsRoom implements GatewayRoom {
  WsRoom(this.base, this.room, this.nodeId) {
    unawaited(_loop());
  }

  final Uri base;
  @override
  final String room;
  final int nodeId;

  WebSocket? _ws;
  bool _closed = false;
  final _frames = StreamController<Uint8List>.broadcast();

  @override
  bool get connected => _ws != null;
  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  void send(Uint8List bytes) {
    try {
      _ws?.add(bytes);
    } catch (_) {}
  }

  Future<void> _loop() async {
    var backoff = const Duration(seconds: 1);
    while (!_closed) {
      try {
        final uri = base.replace(
          queryParameters: {
            ...base.queryParameters,
            'ch': room,
            'id': nodeId.toRadixString(16),
          },
        );
        final ws = await WebSocket.connect(uri.toString())
            .timeout(const Duration(seconds: 10));
        ws.pingInterval = const Duration(seconds: 20);
        _ws = ws;
        backoff = const Duration(seconds: 1);
        final ping = Timer.periodic(const Duration(seconds: 25), (_) {
          try {
            ws.add('ping');
          } catch (_) {}
        });
        await for (final m in ws) {
          if (m is List<int> && !_frames.isClosed) {
            _frames.add(m is Uint8List ? m : Uint8List.fromList(m));
          }
        }
        ping.cancel();
      } catch (_) {}
      _ws = null;
      if (_closed) break;
      await Future<void>.delayed(backoff);
      backoff = Duration(seconds: min(30, backoff.inSeconds * 2));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _ws?.close();
    _ws = null;
    await _frames.close();
  }
}

/// The whole container: config, radios, rooms, /healthz.
class GatewayService {
  GatewayService(this.configPath, this.statePath);

  final String configPath;
  final String statePath;

  late GatewayConfig config;
  late GatewayCore core;
  final Map<String, GatewayRadio> _radios = {};
  HttpServer? _http;
  DateTime? _configTime;
  final DateTime startedAt = DateTime.now();
  final List<Timer> _timers = [];

  /// How often the config file is checked for changes.
  Duration reloadEvery = const Duration(seconds: 15);

  int? get healthPort => _http?.port;

  Future<void> stop() async {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    for (final r in _radios.values) {
      await r.close();
    }
    _radios.clear();
    await core.close();
    await _http?.close(force: true);
  }

  Future<int> _nodeId() async {
    final f = File(statePath);
    try {
      final j = jsonDecode(await f.readAsString()) as Map;
      final id = (j['id'] as num?)?.toInt();
      if (id != null && id > 0) return id;
    } catch (_) {}
    final id = Random.secure().nextInt(0x7FFFFFFF) + 1;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'id': id}));
    return id;
  }

  Future<GatewayConfig> _readConfig() async {
    final f = File(configPath);
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      await f.writeAsString(GatewayConfig.defaultJson);
      gwLog('wrote default config to $configPath');
    }
    _configTime = await f.lastModified();
    return GatewayConfig.parse(await f.readAsString());
  }

  Future<void> start() async {
    config = await _readConfig();
    final id = await _nodeId();
    gwLog(
      'walkie-gateway $gatewayVersion "${config.name}" id '
      '${id.toRadixString(16)} relay ${config.relay}',
    );
    core = GatewayCore(
      name: config.name,
      nodeId: id,
      roomFactory: (room) => WsRoom(config.relay, room, id),
      rooms: config.rooms,
    )..meshLinks = config.meshChannels;
    _applyRadios(config.radios);
    _timers.addAll([
      Timer.periodic(const Duration(milliseconds: 500), (_) => core.tick()),
      Timer.periodic(reloadEvery, (_) => _reload()),
      Timer.periodic(const Duration(minutes: 10), (_) => _logStatus()),
    ]);
    _http = await HttpServer.bind(InternetAddress.anyIPv4, config.healthPort);
    _http!.listen(_serve);
    gwLog('healthz on :${config.healthPort}/healthz');
  }

  void _applyRadios(List<RadioConfig> wanted) {
    final keys = {for (final r in wanted) r.key};
    for (final k in _radios.keys.toList()) {
      if (!keys.contains(k)) {
        final r = _radios.remove(k)!;
        gwLog('radio "${r.name}" removed from config');
        unawaited(core.removeRadio(r));
        unawaited(r.close());
      }
    }
    for (final c in wanted) {
      if (_radios.containsKey(c.key)) continue;
      final r = GatewayRadio(c);
      _radios[c.key] = r;
      core.addRadio(r);
      r.start();
      gwLog('radio "${c.name}" added (${c.serial ?? c.tcp})');
    }
  }

  Future<void> _reload() async {
    try {
      final t = await File(configPath).lastModified();
      if (t == _configTime) return;
      final c = await _readConfig();
      _applyRadios(c.radios);
      core.setRooms(c.rooms);
      core.meshLinks = c.meshChannels;
      config = c;
      gwLog('config reloaded');
    } catch (e) {
      gwLog('config not reloaded: $e');
    }
  }

  Map<String, Object?> status() => {
    'ok': true,
    'version': gatewayVersion,
    'name': config.name,
    'id': core.nodeId.toRadixString(16),
    'uptimeMin': DateTime.now().difference(startedAt).inMinutes,
    'state': core.radiosUp > 0
        ? 'bridging'
        : (_radios.isEmpty ? 'no radios configured' : 'waiting for radio'),
    'radioList': [for (final r in _radios.values) r.status()],
    ...core.status(),
  };

  void _logStatus() {
    final s = core.status();
    gwLog(
      'status: radios ${s['radiosUp']}/${s['radios']} up, '
      'radio->internet ${s['framesRadioToInternet']}, '
      'internet->radio ${s['framesInternetToRadio']}, '
      'rooms ${(s['rooms'] as List).length}',
    );
  }

  Future<void> _serve(HttpRequest req) async {
    try {
      final path = req.uri.path;
      final ok = path == '/healthz' || path == '/';
      req.response
        ..statusCode = ok ? HttpStatus.ok : HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..headers.set('cache-control', 'no-store')
        ..write(
          ok
              ? const JsonEncoder.withIndent('  ').convert(status())
              : '{"error":"not found"}',
        );
      await req.response.close();
    } catch (_) {}
  }
}
