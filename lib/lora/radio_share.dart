// v2.6.9: Desktop USB sharing. The desktop app holds the radio's COM port
// (or its Wi-Fi link) by itself; this shares that one link with other
// programs on the same PC (Meshtastic Python CLI, scripts) over a
// localhost-only TCP server that speaks Meshtastic's standard stream
// protocol (the same as a Wi-Fi radio on port 4403):
//
//   meshtastic --host 127.0.0.1 --nodes
//   meshtastic.tcp_interface.TCPInterface('127.0.0.1')
//
// * FromRadio from the radio goes to every connected program; ToRadio from
//   a program goes to the radio, after the access check.
// * A program's want_config handshake never reaches the radio: it is
//   answered from the settings / node list the app's own link downloaded
//   (downloaded again first when that copy is older than [cacheMaxAge]),
//   so the app's own session is not disturbed.
// * Read-only (the default): text messages and requests (position, node
//   info, telemetry, traceroute, range test) only. Settings changes
//   (admin) and everything else are dropped and logged, and channel keys,
//   the radio's private key, Wi-Fi / MQTT passwords and the Bluetooth PIN
//   are taken out before anything is sent to the program.
// * Full access: everything goes through, as a Wi-Fi radio would; every
//   settings change is logged (which kind, never its contents).
// * Bound to 127.0.0.1 only. Off by default. Nothing runs (one bool check
//   per radio frame) while it is off.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../gateway/stream_wire.dart';
import 'lora_transport.dart' show LoraRateLimiter;
import 'meshtastic_proto.dart';
import 'meshtastic_session.dart';
import 'protobuf.dart';

/// What other programs may do with the shared radio.
enum RadioShareAccess {
  /// Read, send text messages and requests; no settings changes (default).
  readOnly,

  /// Everything, settings changes included (logged).
  full,
}

/// What the hub needs from the app's own radio link.
abstract class RadioShareLink {
  /// Write one ToRadio protobuf (unframed) to the radio.
  Future<void> write(Uint8List toRadio);

  /// Ask the radio for its settings and node list again; completes when the
  /// download is done (or timed out).
  Future<void> refreshConfig();

  /// The radio's listen-only public channel slot (v2.6.4), null if none.
  int? get listenOnlySlot;
}

/// One thing a program did that is worth showing (settings changes and
/// blocked packets). Never holds the packet's contents.
class RadioShareEvent {
  const RadioShareEvent(
    this.at,
    this.client,
    this.what, {
    required this.allowed,
  });
  final DateTime at;

  /// "127.0.0.1:53122".
  final String client;

  /// "settings change (set config)", "text message", ...
  final String what;
  final bool allowed;

  @override
  String toString() =>
      '${allowed ? 'Allowed' : 'Blocked'} $what from program $client';
}

/// Why sharing is not running.
enum RadioShareProblem { portInUse, cannotListen }

/// Field numbers (mesh.proto).
class _From {
  static const id = 1;
  static const packet = 2;
  static const myInfo = 3;
  static const nodeInfo = 4;
  static const config = 5;
  static const logRecord = 6;
  static const configComplete = 7;
  static const rebooted = 8;
  static const moduleConfig = 9;
  static const channel = 10;
  static const queueStatus = 11;
  static const metadata = 13;
  static const fileInfo = 15;
  static const clientNotification = 16;
  static const deviceUiConfig = 17;
}

class _To {
  static const packet = 1;
  static const wantConfig = 3;
  static const disconnect = 4;
  static const heartbeat = 7;
}

/// Special want_config nonces (firmware): settings only / node list only.
const int wantConfigNoNodes = 69420;
const int wantConfigOnlyNodes = 69421;

/// Meshtastic ports a read-only program may send on. Position, node info
/// and telemetry only as a request (want_response).
class RadioSharePorts {
  RadioSharePorts._();
  static const rangeTest = 66;
  static const traceroute = 70;

  static String name(int port) => switch (port) {
    PortNum.text => 'text message',
    PortNum.position => 'position',
    PortNum.nodeInfo => 'node info',
    PortNum.routing => 'routing',
    PortNum.admin => 'settings change',
    PortNum.telemetry => 'telemetry',
    rangeTest => 'range test',
    traceroute => 'traceroute',
    PortNum.privateApp => 'Stalkie Talkie packet',
    _ => 'port $port packet',
  };

  /// Allowed in read-only mode.
  static bool readOnlyAllows(int port, {required bool wantResponse}) =>
      switch (port) {
        PortNum.text || rangeTest || traceroute => true,
        PortNum.position ||
        PortNum.nodeInfo ||
        PortNum.telemetry => wantResponse,
        _ => false,
      };
}

/// "set config", "reboot", ... for an AdminMessage (its oneof field).
String adminKind(Uint8List admin) {
  try {
    for (final f in pbDecode(admin)) {
      if (f.number == 101) continue; // session_passkey
      return switch (f.number) {
        1 => 'get channel',
        3 => 'get owner',
        5 => 'get config',
        7 => 'get module config',
        12 => 'get device metadata',
        32 => 'set owner',
        33 => 'set channel',
        34 => 'set config',
        35 => 'set module config',
        38 => 'remove node',
        39 => 'set favorite',
        40 => 'remove favorite',
        41 => 'set fixed position',
        42 => 'remove fixed position',
        43 => 'set time',
        64 => 'begin edit',
        65 => 'commit edit',
        94 => 'factory reset settings',
        95 => 'reboot to update',
        97 => 'reboot',
        98 => 'shut down',
        99 => 'factory reset',
        100 => 'reset node list',
        _ => 'admin ${f.number}',
      };
    }
  } catch (_) {}
  return 'admin';
}

/// [msg] without field [drop].
Uint8List pbWithout(Uint8List msg, Set<int> drop) {
  final w = PbWriter();
  for (final f in pbDecode(msg)) {
    if (!drop.contains(f.number)) w.raw(f);
  }
  return w.toBytes();
}

/// [msg] with embedded message field [field] replaced by [edit] of it.
Uint8List pbEdit(Uint8List msg, int field, Uint8List Function(Uint8List) edit) {
  final w = PbWriter();
  for (final f in pbDecode(msg)) {
    if (f.number == field && f.wireType == 2) {
      w.message(field, edit(f.asBytes));
    } else {
      w.raw(f);
    }
  }
  return w.toBytes();
}

/// Which oneof a Config / ModuleConfig holds (its first field).
int? _oneof(List<PbField> fields) =>
    fields.isEmpty ? null : fields.first.number;

/// Which FromRadio / ToRadio variant (the first field that is not `id`).
int? _variant(List<PbField> fields) {
  for (final f in fields) {
    if (f.number != _From.id) return f.number;
  }
  return null;
}

/// A FromRadio settings frame made safe for a read-only program: channel
/// keys, the radio's private key, Wi-Fi / MQTT passwords and the fixed
/// Bluetooth PIN are taken out. Null = do not send it at all.
Uint8List? redactForReadOnly(Uint8List fromRadio) {
  final List<PbField> fields;
  try {
    fields = pbDecode(fromRadio);
  } catch (_) {
    return null;
  }
  final v = _variant(fields);
  try {
    switch (v) {
      case _From.channel:
        // Channel{settings=2: ChannelSettings{psk=2}}.
        return pbEdit(
          fromRadio,
          _From.channel,
          (ch) => pbEdit(ch, 2, (s) => pbWithout(s, {2})),
        );
      case _From.config:
        final cfg = fields.firstWhere((f) => f.number == _From.config).asBytes;
        final kind = _oneof(pbDecode(cfg)) ?? 0;
        // security=8 (keys), sessionkey=9: not at all.
        if (kind == 8 || kind == 9) return null;
        // network=4: wifi_psk=4. bluetooth=7: fixed_pin=3.
        if (kind == 4 || kind == 7) {
          return pbEdit(
            fromRadio,
            _From.config,
            (c) => pbEdit(c, kind, (n) => pbWithout(n, {kind == 4 ? 4 : 3})),
          );
        }
        return fromRadio;
      case _From.moduleConfig:
        final mc = fields
            .firstWhere((f) => f.number == _From.moduleConfig)
            .asBytes;
        // mqtt=1: password=4.
        if (_oneof(pbDecode(mc)) == 1) {
          return pbEdit(
            fromRadio,
            _From.moduleConfig,
            (c) => pbEdit(c, 1, (m) => pbWithout(m, {4})),
          );
        }
        return fromRadio;
      default:
        return fromRadio;
    }
  } catch (_) {
    return null;
  }
}

class _Client {
  _Client(this.sock, this.label, DateTime Function() clock)
    : limiter = LoraRateLimiter(
        burst: 8,
        refillEvery: const Duration(seconds: 2),
        clock: clock,
      );
  final Socket sock;
  final String label;
  final framer = StreamFramer();
  final LoraRateLimiter limiter;

  /// Its want_config was answered: live traffic goes to it.
  bool configured = false;
  bool closed = false;
  int replaying = 0;
}

/// The localhost server that shares the app's radio link (see the top of
/// this file).
class RadioShareHub {
  RadioShareHub({
    this.maxClients = 4,
    this.cacheMaxAge = const Duration(minutes: 2),
    this.refreshTimeout = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const int defaultPort = 4403;

  final int maxClients;

  /// The settings / node list copy is downloaded again for a program that
  /// connects when it is older than this.
  final Duration cacheMaxAge;
  final Duration refreshTimeout;
  final DateTime Function() _clock;

  RadioShareAccess access = RadioShareAccess.readOnly;

  /// One line per notable thing (connects, settings changes, blocks); no
  /// packet contents. Set by the app (debug log).
  void Function(String line)? log;

  ServerSocket? _server;
  final List<_Client> _clients = [];
  RadioShareLink? _link;

  /// The FromRadio settings frames of the last full download, in the order
  /// the radio sent them, and the one being received.
  List<Uint8List> _cache = [];
  DateTime? _cacheAt;
  List<Uint8List>? _pending;
  Completer<void>? _refreshing;
  Completer<void>? _linked;

  final List<RadioShareEvent> _events = [];
  final _changes = StreamController<void>.broadcast();

  int toRadio = 0;
  int fromRadio = 0;
  int blocked = 0;
  int settingsChanges = 0;

  RadioShareProblem? problem;

  /// The raw error behind [problem] (for "Details").
  String? problemDetails;

  /// The port it listens on (null when not running).
  int? get port => _server?.port;
  bool get running => _server != null;
  int get clientCount => _clients.length;

  /// Newest first, at most 50.
  List<RadioShareEvent> get events => List.unmodifiable(_events.reversed);
  Stream<void> get changes => _changes.stream;
  bool get radioAttached => _link != null;

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _event(_Client c, String what, {required bool allowed}) {
    final e = RadioShareEvent(_clock(), c.label, what, allowed: allowed);
    _events.add(e);
    if (_events.length > 50) _events.removeAt(0);
    log?.call(e.toString());
    _changed();
  }

  /// Listen on 127.0.0.1:[port] (0 = any free port, for tests). Returns
  /// false (and sets [problem]) when it cannot.
  Future<bool> start(int port) async {
    if (running && this.port == port) return true;
    await stop();
    problem = null;
    problemDetails = null;
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server = s;
      s.listen(_accept, onError: (Object _) {}, cancelOnError: false);
      log?.call('sharing the radio on 127.0.0.1:${s.port}');
      _changed();
      return true;
    } on SocketException catch (e) {
      problem = isAddressInUse(e)
          ? RadioShareProblem.portInUse
          : RadioShareProblem.cannotListen;
      problemDetails = e.toString();
      log?.call('cannot share the radio on port $port: ${e.message}');
      _changed();
      return false;
    }
  }

  /// "Address already in use" on Windows (10048), Linux (98), macOS (48).
  static bool isAddressInUse(SocketException e) {
    final c = e.osError?.errorCode;
    if (c == 10048 || c == 98 || c == 48) return true;
    final m = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    // The same process binding twice (Dart refuses before the OS does).
    return m.contains('in use') ||
        m.contains('only one usage') ||
        m.contains('binding multiple times');
  }

  /// A free port on 127.0.0.1 from [from] + 1 on (null if none of 20).
  static Future<int?> freePortAfter(int from) async {
    for (var p = from + 1; p <= from + 20 && p <= 65535; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } on SocketException {
        continue;
      }
    }
    return null;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    final w = _linked;
    _linked = null;
    if (w != null && !w.isCompleted) w.complete();
    for (final c in List.of(_clients)) {
      _drop(c);
    }
    if (s != null) {
      await s.close();
      log?.call('stopped sharing the radio');
    }
    _changed();
  }

  /// The app's radio link came up ([link]) or went away (null).
  void attach(RadioShareLink? link) {
    _link = link;
    _pending = null;
    if (link == null) {
      _cacheAt = null;
      final r = _refreshing;
      _refreshing = null;
      if (r != null && !r.isCompleted) r.complete();
    } else {
      final w = _linked;
      _linked = null;
      if (w != null && !w.isCompleted) w.complete();
    }
    _changed();
  }

  void _accept(Socket sock) {
    final a = sock.remoteAddress;
    if (!a.isLoopback || _clients.length >= maxClients) {
      sock.destroy();
      return;
    }
    try {
      sock.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final c = _Client(sock, '${a.address}:${sock.remotePort}', _clock);
    _clients.add(c);
    log?.call('program connected from ${c.label}');
    _changed();
    sock.listen(
      (b) {
        for (final p in c.framer.add(b)) {
          _fromClient(c, p);
        }
      },
      onError: (Object _) => _drop(c),
      onDone: () => _drop(c),
      cancelOnError: true,
    );
  }

  void _drop(_Client c) {
    if (c.closed) return;
    c.closed = true;
    _clients.remove(c);
    try {
      c.sock.destroy();
    } catch (_) {}
    log?.call('program ${c.label} disconnected');
    _changed();
  }

  void _send(_Client c, Uint8List fromRadio) {
    if (c.closed) return;
    try {
      c.sock.add(StreamFramer.frame(fromRadio));
    } catch (_) {
      _drop(c);
    }
  }

  // ------------------------------------------------------- program -> radio

  void _fromClient(_Client c, Uint8List toRadioMsg) {
    final List<PbField> fields;
    try {
      fields = pbDecode(toRadioMsg);
    } catch (_) {
      return;
    }
    for (final f in fields) {
      switch (f.number) {
        case _To.wantConfig:
          unawaited(_replay(c, f.asInt & 0xFFFFFFFF));
          return;
        case _To.disconnect:
          _drop(c);
          return;
        case _To.heartbeat:
          // The app keeps the link alive itself.
          return;
        case _To.packet:
          _clientPacket(c, toRadioMsg, f.asBytes);
          return;
        default:
          // File transfer (xmodem), MQTT proxy: not shared.
          blocked++;
          _event(c, 'unsupported request', allowed: false);
          return;
      }
    }
  }

  void _clientPacket(_Client c, Uint8List toRadioMsg, Uint8List pkt) {
    var channel = 0;
    Uint8List? decoded;
    var encrypted = false;
    try {
      for (final f in pbDecode(pkt)) {
        if (f.number == 3) channel = f.asInt;
        if (f.number == 4 && f.wireType == 2) decoded = f.asBytes;
        if (f.number == 5) encrypted = true;
      }
    } catch (_) {
      return;
    }
    var port = 0;
    var wantResponse = false;
    Uint8List? payload;
    if (decoded != null) {
      try {
        for (final f in pbDecode(decoded)) {
          if (f.number == 1) port = f.asInt;
          if (f.number == 2) payload = f.asBytes;
          if (f.number == 3) wantResponse = f.asBool;
        }
      } catch (_) {
        return;
      }
    }
    final full = access == RadioShareAccess.full;
    final what = decoded == null
        ? 'encrypted packet'
        : port == PortNum.admin
        ? 'settings change (${adminKind(payload ?? Uint8List(0))})'
        : RadioSharePorts.name(port);
    final link = _link;
    if (link == null) {
      blocked++;
      _event(c, '$what (radio not connected)', allowed: false);
      return;
    }
    final pub = link.listenOnlySlot;
    if (pub != null && channel == pub && port != PortNum.admin) {
      blocked++;
      _event(c, '$what on the listen-only public channel', allowed: false);
      return;
    }
    if (!full) {
      final ok =
          !encrypted &&
          decoded != null &&
          RadioSharePorts.readOnlyAllows(port, wantResponse: wantResponse);
      if (!ok) {
        blocked++;
        _event(c, '$what (read-only)', allowed: false);
        return;
      }
    }
    if (!c.limiter.tryTake()) {
      blocked++;
      _event(c, '$what (too many at once)', allowed: false);
      return;
    }
    if (port == PortNum.admin && decoded != null) {
      settingsChanges++;
      _event(c, what, allowed: true);
    }
    toRadio++;
    unawaited(link.write(toRadioMsg).catchError((Object _) {}));
  }

  // ------------------------------------------------------- the handshake

  Future<void> _replay(_Client c, int nonce) async {
    c.configured = false;
    final gen = ++c.replaying;
    // Wait for the radio (a program may connect before the app's link).
    while (_link == null && !c.closed && running) {
      _linked ??= Completer<void>();
      await _linked!.future;
    }
    if (c.closed || gen != c.replaying) return;
    final at = _cacheAt;
    if (_cache.isEmpty || at == null || _clock().difference(at) > cacheMaxAge) {
      await _refresh();
    }
    if (c.closed || gen != c.replaying) return;
    final readOnly = access == RadioShareAccess.readOnly;
    final my = _myNodeNum();
    for (final raw in _cache) {
      final fields = pbDecode(raw);
      final v = _variant(fields);
      if (nonce == wantConfigOnlyNodes &&
          v != _From.myInfo &&
          v != _From.nodeInfo) {
        continue;
      }
      if (nonce == wantConfigNoNodes && v == _From.nodeInfo) {
        final ni = fields.firstWhere((f) => f.number == _From.nodeInfo);
        if (_nodeNum(ni.asBytes) != my) continue;
      }
      final out = readOnly ? redactForReadOnly(raw) : raw;
      if (out != null) _send(c, out);
    }
    _send(
      c,
      (PbWriter()..uint(_From.configComplete, nonce, always: true)).toBytes(),
    );
    c.configured = true;
    log?.call('program ${c.label} got the radio settings and node list');
    _changed();
  }

  int? _myNodeNum() {
    for (final raw in _cache) {
      final fields = pbDecode(raw);
      if (_variant(fields) != _From.myInfo) continue;
      final m = fields.firstWhere((f) => f.number == _From.myInfo);
      return MyNodeInfoPb.decode(m.asBytes).myNodeNum;
    }
    return null;
  }

  static int? _nodeNum(Uint8List nodeInfo) {
    for (final f in pbDecode(nodeInfo)) {
      if (f.number == 1) return f.asInt & 0xFFFFFFFF;
    }
    return null;
  }

  Future<void> _refresh() async {
    final r = _refreshing;
    if (r != null) return r.future;
    final link = _link;
    if (link == null) return;
    final done = Completer<void>();
    _refreshing = done;
    try {
      // Python waits 30 s for the handshake: never longer than 15 s here.
      await link.refreshConfig().timeout(refreshTimeout);
    } catch (_) {
    } finally {
      if (identical(_refreshing, done)) _refreshing = null;
      if (!done.isCompleted) done.complete();
    }
  }

  // ------------------------------------------------------- radio -> programs

  /// Every FromRadio the app's link read (unframed). Cheap when off.
  void onFromRadio(Uint8List raw) {
    if (_server == null) return;
    final List<PbField> fields;
    try {
      fields = pbDecode(raw);
    } catch (_) {
      return;
    }
    final v = _variant(fields);
    switch (v) {
      case _From.myInfo:
        // A download starts with my_info.
        _pending = [raw];
      case _From.nodeInfo ||
          _From.config ||
          _From.moduleConfig ||
          _From.channel ||
          _From.metadata ||
          _From.fileInfo ||
          _From.deviceUiConfig:
        (_pending ??= []).add(raw);
      case _From.configComplete:
        final p = _pending;
        if (p != null && p.isNotEmpty) {
          _cache = p;
          _cacheAt = _clock();
        }
        _pending = null;
      case _From.rebooted:
        _pending = null;
        _cacheAt = null;
        _toPrograms(raw);
      case _From.packet:
        if (access == RadioShareAccess.readOnly && _isAdmin(fields)) {
          // Answers to settings requests (they can hold channel keys).
          return;
        }
        _toPrograms(raw);
      case _From.queueStatus || _From.logRecord || _From.clientNotification:
        _toPrograms(raw);
      default:
        break;
    }
  }

  static bool _isAdmin(List<PbField> fields) {
    try {
      final p = fields.firstWhere((f) => f.number == _From.packet).asBytes;
      for (final f in pbDecode(p)) {
        if (f.number == 4 && f.wireType == 2) {
          for (final d in pbDecode(f.asBytes)) {
            if (d.number == 1) return d.asInt == PortNum.admin;
          }
        }
      }
    } catch (_) {
      return true;
    }
    return false;
  }

  void _toPrograms(Uint8List raw) {
    if (_clients.isEmpty) return;
    for (final c in List.of(_clients)) {
      if (!c.configured) continue;
      _send(c, raw);
      fromRadio++;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }
}

/// The app's own [MeshtasticSession] as the shared link.
class SessionShareLink implements RadioShareLink {
  SessionShareLink(this.session);
  final MeshtasticSession session;

  @override
  Future<void> write(Uint8List toRadio) => session.wire.write(toRadio);

  @override
  Future<void> refreshConfig() => session.requestConfig();

  @override
  int? get listenOnlySlot => session.publicListenIndex;
}

/// Wire [hub] to [session] (every radio frame is offered to the hub, which
/// ignores it while sharing is off), or detach it (null).
void bindRadioShare(RadioShareHub hub, MeshtasticSession? session) {
  if (session == null) {
    hub.attach(null);
    return;
  }
  session.rawTap = hub.onFromRadio;
  hub.attach(SessionShareLink(session));
}
