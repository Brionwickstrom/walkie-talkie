import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import '../core/frame.dart';
import '../core/transport.dart';
import 'weather_alerts.dart';
import 'wx_alert.dart';
import 'wx_codec.dart';
import 'wx_keys.dart';

/// The relay rooms for weather: one per state, `wx-or`, on every relay the
/// phone uses (like the Who's where lobby room). A relay only ever learns
/// the state a phone is interested in.
class WxRooms {
  WxRooms({required this.factory, required this.onFrame});

  /// A transport for the relay room [room] (a [MultiRelayTransport] over the
  /// configured relays in the app, a fake in tests).
  final Transport Function(String room) factory;
  final void Function(Frame f) onFrame;

  final Map<String, Transport> _open = {};
  final Map<String, List<StreamSubscription<dynamic>>> _subs = {};

  /// At most this many states at once.
  static const maxStates = 4;

  static String roomFor(String state) => 'wx-${state.toLowerCase()}';

  Set<String> get states => _open.keys.toSet();
  bool isOpen(String state) => _open[state] != null;
  bool isUp(String state) => _open[state]?.status == TransportStatus.running;

  /// Join the rooms of [want], leave the others.
  Future<void> sync(Set<String> want, {required int localNodeId}) async {
    final wanted = (want.toList()..sort()).take(maxStates).toSet();
    for (final s in _open.keys.toList()) {
      if (!wanted.contains(s)) await _close(s);
    }
    for (final s in wanted) {
      if (_open.containsKey(s)) continue;
      final t = factory(roomFor(s));
      _open[s] = t;
      _subs[s] = [
        t.frames.listen((inb) {
          if (inb.frame.type == FrameType.alert) onFrame(inb.frame);
        }),
      ];
      try {
        await t.start(localNodeId: localNodeId, channel: 0);
      } catch (_) {}
    }
  }

  Future<void> _close(String state) async {
    final t = _open.remove(state);
    for (final s in _subs.remove(state) ?? const <StreamSubscription>[]) {
      await s.cancel();
    }
    if (t != null) {
      try {
        await t.dispose();
      } catch (_) {}
    }
  }

  Future<void> closeAll() async {
    for (final s in _open.keys.toList()) {
      await _close(s);
    }
  }

  /// [bytes] (an encoded frame) into the room of [state], if it is up.
  Future<bool> send(String state, Uint8List bytes) async {
    final t = _open[state];
    if (t == null || t.status != TransportStatus.running) return false;
    try {
      await t.send(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// What the weather layer did with one received packet (for tests / Details).
enum WxRx {
  stored,
  waiting,
  duplicate,
  badSignature,
  unknownKey,
  notForUs,
  ignored,
  ownEcho,
  rateLimited,
}

typedef WxTimerFn = Timer Function(Duration d, void Function() f);

/// Weather alerts over the relay and the radio (v2.5.2, stage 2).
///
/// **Sending.** Only a device that read an alert from the NWS itself
/// ([onNwsRead]) sends: a new alert, or a material change (worse severity,
/// extended end time, more zones), and one reminder every [reminder] while
/// it stays active. A phone that only heard it on the radio never sends and
/// never passes it on (the radio mesh floods it already).
///  * relay: a signed full packet into `wx-<state>` for the states of the
///    alert's zones this phone has joined, after 2-12 s;
///  * radio: a compact signed packet (one, or two when the zones do not
///    fit) after a random 5-30 s, one broadcast, no ack.
///  Before sending, skip it if the same alert (VTEC key, same or newer
///  revision) was heard on that path meanwhile or in the last [reminder];
///  per alert and path never twice within [cooldown].
///
/// **Receiving.** Every packet is checked against its own key before
/// anything else; a bad signature is dropped. The alert is "confirmed" when
/// it came on a private group's frames or from a device the user trusts, else
/// "unconfirmed". It goes into the same store as the NWS copy ([WeatherAlerts.handle])
/// so it is notified once across all paths.
class WxMesh {
  WxMesh({
    required this.key,
    required this.weather,
    required this.nodeId,
    required this.shareOn,
    required this.isTrusted,
    required this.deviceName,
    this.rooms,
    this.radioReady,
    this.radioBudget,
    this.sendRadio,
    this.radioChannel,
    DateTime Function()? clock,
    Random? rng,
    WxTimerFn? timer,
    this.stateFile,
  }) : _clock = clock ?? DateTime.now,
       _rng = rng ?? Random(),
       _timer = timer ?? ((d, f) => Timer(d, f));

  final WxDeviceKey key;
  final WeatherAlerts weather;
  final int Function() nodeId;

  /// "Share what I read with other phones" (Settings).
  final bool Function() shareOn;
  final bool Function(String keyId) isTrusted;

  /// A name for the device that signed ([nodeId] of the frame, key id).
  final String Function(int node, String keyId) deviceName;
  final WxRooms? rooms;
  final bool Function()? radioReady;

  /// Payload bytes left on the radio for an alert frame (sealing counted).
  final int Function()? radioBudget;
  final bool Function(Frame f)? sendRadio;
  final int Function()? radioChannel;
  final File? stateFile;
  final DateTime Function() _clock;
  final Random _rng;
  final WxTimerFn _timer;

  static const reminder = Duration(minutes: 20);
  static const cooldown = Duration(minutes: 3);
  static const relayDelay = (min: 2000, max: 12000);
  static const airDelay = (min: 5000, max: 30000);
  static const zonesWait = Duration(seconds: 15);
  static const maxVerifyBurst = 12;
  static const verifyEvery = Duration(seconds: 4);

  // ------------------------------------------------------------- counters
  int sentRelay = 0, sentAir = 0, skippedHeard = 0;
  int rxRelay = 0, rxAir = 0, rejected = 0;

  // -------------------------------------------------------------- sending
  final Map<String, _Pub> _pub = {};
  final Map<String, WxAlert> _latest = {};
  int _seq = Random().nextInt(0x8000);

  /// When each alert (key) was last heard from someone else: path ->
  /// (revision, time). Only verified packets count.
  final Map<String, (int, DateTime)> _heardRelay = {};
  final Map<String, (int, DateTime)> _heardAir = {};

  /// This device read [got] from the NWS for [zones]: share what is new.
  Future<void> onNwsRead(List<WxAlert> got, Set<String> zones) async {
    final now = _clock();
    await _loadState();
    _pub.removeWhere((k, p) => p.expMs < now.millisecondsSinceEpoch);
    if (!shareOn()) return;
    for (final a in got) {
      if (a.isCancel || !a.activeAt(now)) continue;
      if (!weather.store.kinds.contains(a.kind)) continue;
      _latest[a.key] = a;
      final p = _pub[a.key];
      final material = p == null || _material(p, a);
      final stateKey = _stateKey(a);
      if (p == null) {
        _pub[a.key] = _Pub(a, stateKey);
      } else if (material) {
        p.update(a, stateKey);
      }
      final pub = _pub[a.key]!;
      if (rooms != null && _relayDue(pub, now, material)) {
        _plan(pub, a, air: false, material: material);
      }
      if (sendRadio != null && _airDue(pub, now, material)) {
        _plan(pub, a, air: true, material: material);
      }
    }
    await _saveState();
  }

  bool _material(_Pub p, WxAlert a) {
    if (a.rev <= p.rev) return false;
    if (a.severity.index > p.sev) return true;
    if (a.isExtreme && !p.extreme) return true;
    if (a.expiresAt.millisecondsSinceEpoch > p.expMs + 5 * 60 * 1000) {
      return true;
    }
    if (_stateKey(a) != p.zonesKey) return true;
    return false;
  }

  String _stateKey(WxAlert a) => (a.ugc.toList()..sort()).join(',');

  bool _relayDue(_Pub p, DateTime now, bool material) =>
      p.relayTimer == null &&
      (material || p.relayAt == null || now.difference(p.relayAt!) >= reminder);

  bool _airDue(_Pub p, DateTime now, bool material) =>
      p.airTimer == null &&
      (material || p.airAt == null || now.difference(p.airAt!) >= reminder);

  void _plan(_Pub p, WxAlert a, {required bool air, required bool material}) {
    final now = _clock();
    final lim = air ? airDelay : relayDelay;
    var ms = lim.min + _rng.nextInt(lim.max - lim.min);
    final last = air ? p.airAt : p.relayAt;
    if (last != null) {
      final wait = last.add(cooldown).difference(now).inMilliseconds;
      if (wait > ms) ms = wait;
    }
    // Heard already (same or newer revision, within a reminder period):
    // someone else covers it.
    if (_heardRecently(air ? _heardAir : _heardRelay, a)) {
      skippedHeard++;
      if (air) {
        p.airAt = now;
      } else {
        p.relayAt = now;
      }
      return;
    }
    p.plannedAt = now;
    final t = _timer(Duration(milliseconds: ms), () {
      if (air) {
        p.airTimer = null;
      } else {
        p.relayTimer = null;
      }
      unawaited(_fire(p.key, air: air, since: p.plannedAt ?? now));
    });
    if (air) {
      p.airTimer = t;
    } else {
      p.relayTimer = t;
    }
  }

  bool _heardRecently(
    Map<String, (int, DateTime)> heard,
    WxAlert a, {
    DateTime? since,
  }) {
    final h = heard[a.key];
    if (h == null || h.$1 < a.rev) return false;
    final now = _clock();
    if (since != null && h.$2.isAfter(since)) return true;
    return now.difference(h.$2) < reminder;
  }

  Future<void> _fire(
    String k, {
    required bool air,
    required DateTime since,
  }) async {
    final p = _pub[k];
    final a = _latest[k];
    final now = _clock();
    if (p == null || a == null || !shareOn() || !a.activeAt(now)) return;
    // Still in force here? (cancelled / withdrawn meanwhile)
    final held = weather.store.byKey(k);
    if (held == null) return;
    if (_heardRecently(air ? _heardAir : _heardRelay, a, since: since)) {
      skippedHeard++;
      if (air) {
        p.airAt = now;
      } else {
        p.relayAt = now;
      }
      await _saveState();
      return;
    }
    if (air) {
      final ok = await _sendAir(a);
      if (ok) {
        p.airAt = now;
        sentAir++;
      }
    } else {
      final n = await _sendRelay(a);
      if (n > 0) {
        p.relayAt = now;
        sentRelay++;
      }
    }
    await _saveState();
  }

  Future<int> _sendRelay(WxAlert a) async {
    final r = rooms;
    if (r == null) return 0;
    final full = await wxEncodeFull(a, key: key, nodeId: nodeId());
    final bytes = _frame(full, channel: 0).encode();
    var n = 0;
    for (final s in wxStates(a.ugc)) {
      if (await r.send(s, bytes)) n++;
    }
    return n;
  }

  Future<bool> _sendAir(WxAlert a) async {
    final send = sendRadio;
    if (send == null || !(radioReady?.call() ?? true) || !wxRadioReady(a)) {
      return false;
    }
    final cover = weather.coveredZones;
    final zones = [
      for (final z in a.ugc)
        if (cover.contains(z)) z,
    ];
    final c = await wxEncodeCompact(
      a,
      key: key,
      nodeId: nodeId(),
      budget: radioBudget?.call() ?? 188,
      zones: zones.isEmpty ? null : zones,
    );
    if (c == null) return false;
    final ch = radioChannel?.call() ?? 0;
    var ok = false;
    for (final p in c.packets) {
      final f = _frame(p, channel: ch);
      if (!send(f)) break;
      ok = true;
    }
    return ok;
  }

  Frame _frame(Uint8List payload, {required int channel}) {
    _seq = (_seq + 1) & 0x7FFF;
    return Frame(
      type: FrameType.alert,
      senderId: nodeId(),
      channel: channel,
      seq: _seq,
      payload: payload,
    );
  }

  // ------------------------------------------------------------- receiving
  final Map<String, ({String key, int rev, DateTime at})> _seen = {};
  final Map<String, Uint8List> _keys = {};
  final Map<String, _Pending> _pending = {};
  double _verifyTokens = maxVerifyBurst.toDouble();
  DateTime? _verifyAt;

  bool _takeVerify() {
    final now = _clock();
    final last = _verifyAt;
    _verifyAt = now;
    if (last != null) {
      _verifyTokens = min(
        maxVerifyBurst.toDouble(),
        _verifyTokens +
            now.difference(last).inMicroseconds / verifyEvery.inMicroseconds,
      );
    }
    if (_verifyTokens < 1) return false;
    _verifyTokens -= 1;
    return true;
  }

  /// A packet from a relay room.
  Future<WxRx> onRelayFrame(Frame f) {
    rxRelay++;
    return _receive(f, WxSource.relay, group: false);
  }

  /// A packet heard on the radio. [group]: sealed with our private group's
  /// key (so a member of it sent it).
  Future<WxRx> onRadioFrame(Frame f, {bool group = false}) {
    rxAir++;
    return _receive(f, WxSource.lora, group: group);
  }

  static String _hash(int node, Uint8List p) {
    final b = BytesBuilder(copy: false)
      ..add(
        [node >> 24, node >> 16, node >> 8, node].map((x) => x & 0xFF).toList(),
      )
      ..add(p);
    final h = const DartSha256().hashSync(b.toBytes()).bytes;
    return [for (var i = 0; i < 12; i++) h[i].toRadixString(16).padLeft(2, '0')]
        .join();
  }

  Future<WxRx> _receive(Frame f, WxSource source, {required bool group}) async {
    if (f.senderId == nodeId()) return WxRx.ownEcho;
    final now = _clock();
    _seen.removeWhere((_, v) => now.difference(v.at) > reminder);
    final h = _hash(f.senderId, f.payload);
    final prior = _seen[h];
    if (prior != null) {
      // Same signed bytes again (a reminder or a second path): it still
      // tells us someone covers it.
      _noteHeard(source, prior.key, prior.rev);
      return WxRx.duplicate;
    }
    final d = wxDecode(f.payload);
    if (d == null) {
      rejected++;
      return WxRx.ignored;
    }
    if (d.keyId == key.id) return WxRx.ownEcho;
    if (!_takeVerify()) return WxRx.rateLimited;
    final pk = d.keyBytes ?? _keys[d.keyId];
    if (pk == null) return WxRx.unknownKey;
    if (!await d.verify(f.senderId, key: pk)) {
      rejected++;
      return WxRx.badSignature;
    }
    if (d.keyBytes != null) {
      _keys[d.keyId] = d.keyBytes!;
      if (_keys.length > 64) _keys.remove(_keys.keys.first);
    }
    final trust = group || isTrusted(d.keyId)
        ? WxTrust.confirmed
        : WxTrust.unconfirmed;
    // ---- zones packet: belongs to a compact alert.
    if (d.packet == WxPacket.zones) {
      final pk2 = '${d.keyId}/${d.alertKey}/${d.issuedSec}';
      final pend = _pending.remove(pk2);
      _seen[h] = (key: d.alertKey!, rev: (d.issuedSec ?? 0) * 1000, at: now);
      if (pend?.alert != null) {
        pend!.timer?.cancel();
        return _store(pend.alert!, d.zoneList, source, trust, f);
      }
      // Arrived first: keep the zones for the compact packet.
      _pending[pk2] = _Pending(zones: d.zoneList, at: now);
      return WxRx.waiting;
    }
    final a = d.alert!;
    _seen[h] = (key: a.key, rev: a.rev, at: now);
    _noteHeard(source, a.key, a.rev);
    if (a.issued.isAfter(now.add(const Duration(minutes: 10))) ||
        !a.activeAt(now)) {
      return WxRx.ignored;
    }
    if (d.packet == WxPacket.compact && d.moreZones) {
      final pk2 =
          '${d.keyId}/${a.key}/${a.issued.millisecondsSinceEpoch ~/ 1000}';
      final early = _pending.remove(pk2);
      if (early?.zones != null) {
        return _store(a, early!.zones!, source, trust, f);
      }
      final pend = _Pending(alert: a, at: now);
      _pending[pk2] = pend;
      pend.timer = _timer(zonesWait, () {
        final p = _pending.remove(pk2);
        if (p?.alert != null) {
          unawaited(_store(p!.alert!, const [], source, trust, f));
        }
      });
      return WxRx.waiting;
    }
    return _store(a, const [], source, trust, f);
  }

  Future<WxRx> _store(
    WxAlert base,
    List<String> moreZones,
    WxSource source,
    WxTrust trust,
    Frame f,
  ) async {
    final now = _clock();
    final zones = <String>[
      ...base.ugc,
      for (final z in moreZones)
        if (!base.ugc.contains(z)) z,
    ];
    // Relevant: names a zone we cover (when we know where we are).
    final cover = weather.coveredZones;
    if (cover.isNotEmpty && !zones.any(cover.contains)) return WxRx.notForUs;
    if (!weather.isOn) return WxRx.ignored;
    final a = WxAlert(
      key: base.key,
      nwsId: base.nwsId,
      event: base.event,
      severity: base.severity,
      urgency: base.urgency,
      headline: base.headline,
      description: base.description,
      instruction: base.instruction,
      areaDesc: base.areaDesc,
      issued: base.issued,
      rev: base.rev,
      onset: base.onset,
      expires: base.expires,
      ends: base.ends,
      ugc: zones,
      sender: base.sender,
      source: source,
      trust: trust,
      fromDevice: base.fromDevice,
      fromName: deviceName(f.senderId, base.fromDevice),
      firstSeen: now,
    );
    await weather.handle([a]);
    return WxRx.stored;
  }

  void _noteHeard(WxSource source, String k, int rev) {
    final m = source == WxSource.lora ? _heardAir : _heardRelay;
    final o = m[k];
    if (o == null || rev >= o.$1) m[k] = (rev, _clock());
    if (m.length > 200) m.remove(m.keys.first);
  }

  /// Packets waiting for their zones packet (tests).
  int get pending => _pending.length;

  // ----------------------------------------------------------- persistence
  bool _loaded = false;

  Future<void> _loadState() async {
    if (_loaded) return;
    _loaded = true;
    final f = stateFile;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      for (final e in j.entries) {
        final v = e.value;
        if (v is List && v.length == 6) {
          final p = _Pub.restore('${e.key}', v);
          if (p != null) _pub['${e.key}'] = p;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveState() async {
    final f = stateFile;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({for (final e in _pub.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {}
  }

  void dispose() {
    for (final p in _pub.values) {
      p.relayTimer?.cancel();
      p.airTimer?.cancel();
    }
    for (final p in _pending.values) {
      p.timer?.cancel();
    }
  }
}

class _Pub {
  _Pub(WxAlert a, this.zonesKey)
    : key = a.key,
      rev = a.rev,
      sev = a.severity.index,
      extreme = a.isExtreme,
      expMs = a.expiresAt.millisecondsSinceEpoch;

  _Pub._(
    this.key,
    this.rev,
    this.sev,
    this.extreme,
    this.expMs,
    this.zonesKey,
    this.relayAt,
    this.airAt,
  );

  final String key;
  int rev;
  int sev;
  bool extreme;
  int expMs;
  String zonesKey;
  DateTime? relayAt;
  DateTime? airAt;
  DateTime? plannedAt;
  Timer? relayTimer;
  Timer? airTimer;

  void update(WxAlert a, String zk) {
    rev = a.rev;
    sev = a.severity.index;
    extreme = a.isExtreme;
    expMs = a.expiresAt.millisecondsSinceEpoch;
    zonesKey = zk;
  }

  List<Object?> toJson() => [
    rev,
    sev,
    extreme ? 1 : 0,
    expMs,
    zonesKey,
    [relayAt?.millisecondsSinceEpoch, airAt?.millisecondsSinceEpoch],
  ];

  static _Pub? restore(String key, List<Object?> v) {
    try {
      final t = v[5] as List;
      DateTime? d(Object? x) =>
          x is num ? DateTime.fromMillisecondsSinceEpoch(x.toInt()) : null;
      return _Pub._(
        key,
        (v[0] as num).toInt(),
        (v[1] as num).toInt(),
        v[2] == 1,
        (v[3] as num).toInt(),
        v[4] as String,
        d(t[0]),
        d(t[1]),
      );
    } catch (_) {
      return null;
    }
  }
}

class _Pending {
  _Pending({this.alert, this.zones, required this.at});
  final WxAlert? alert;
  final List<String>? zones;
  final DateTime at;
  Timer? timer;
}

/// The states (`OR`, `WA`) of a list of UGC zone codes.
Set<String> wxStates(Iterable<String> ugc) => {
  for (final z in ugc)
    if (z.length >= 3 && RegExp(r'^[A-Z]{2}[ZC]').hasMatch(z))
      z.substring(0, 2),
};
