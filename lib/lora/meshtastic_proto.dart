import 'dart:typed_data';

import 'protobuf.dart';

/// Meshtastic client API (BLE) constants and the handful of protobuf
/// messages the app needs, hand-encoded with [PbWriter] / [pbDecode].
///
/// Checked against meshtastic/protobufs `meshtastic/mesh.proto`,
/// `portnums.proto`, `config.proto`, `channel.proto`, `telemetry.proto`
/// (master, Oct 2026) and docs/development/device/client-api:
/// * service 6ba1b218-15a8-461f-9fa8-5dcae273eafd
/// * ToRadio  f75c76d2-129e-4dad-a1dd-7866124401e7 (write)
/// * FromRadio 2c55e69e-4993-11ed-b878-0242ac120002 (read until empty)
/// * FromNum  ed9da18c-a800-4f66-a670-aa7547e34453 (notify: new data)
class MeshtasticUuids {
  static const service = '6ba1b218-15a8-461f-9fa8-5dcae273eafd';
  static const toRadio = 'f75c76d2-129e-4dad-a1dd-7866124401e7';
  static const fromRadio = '2c55e69e-4993-11ed-b878-0242ac120002';

  /// FromRadio UUID of firmware before 2.1 (still accepted).
  static const fromRadioLegacy = '8ba2bcc2-ee02-4a55-a531-c525c5e454d5';
  static const fromNum = 'ed9da18c-a800-4f66-a670-aa7547e34453';
}

/// `PortNum` values used here (portnums.proto).
class PortNum {
  static const text = 1;
  static const position = 3;
  static const nodeInfo = 4;
  static const routing = 5;
  static const telemetry = 67;

  /// "Private applications should use portnums >= 256": the stock apps
  /// ignore it, the firmware still relays it.
  static const privateApp = 256;
}

/// Destination for "everyone" (NODENUM_BROADCAST).
const int meshBroadcast = 0xFFFFFFFF;

/// Constants.DATA_PAYLOAD_LEN: max bytes in Data.payload.
const int meshDataPayloadLen = 233;

/// Our payload budget per LoRa packet (leaves room for Data/MeshPacket
/// framing and the encryption header inside the 255 byte LoRa frame).
const int loraPayloadBudget = 200;

/// `Data` (mesh.proto): portnum=1, payload=2, want_response=3, dest=4,
/// source=5, request_id=6, reply_id=7, emoji=8.
class MeshData {
  MeshData({
    required this.portnum,
    required this.payload,
    this.wantResponse = false,
    this.requestId = 0,
  });
  final int portnum;
  final Uint8List payload;
  final bool wantResponse;
  final int requestId;

  Uint8List encode() =>
      (PbWriter()
            ..uint(1, portnum)
            ..bytes(2, payload)
            ..boolean(3, wantResponse)
            ..fixed32(6, requestId))
          .toBytes();

  static MeshData decode(Uint8List b) {
    var port = 0;
    var payload = Uint8List(0);
    var want = false;
    var req = 0;
    for (final f in pbDecode(b)) {
      switch (f.number) {
        case 1:
          port = f.asInt;
        case 2:
          payload = Uint8List.fromList(f.asBytes);
        case 3:
          want = f.asBool;
        case 6:
          req = f.asFixed32;
      }
    }
    return MeshData(
      portnum: port,
      payload: payload,
      wantResponse: want,
      requestId: req,
    );
  }
}

/// `MeshPacket`: from=1 fixed32, to=2 fixed32, channel=3, decoded=4,
/// encrypted=5, id=6 fixed32, rx_time=7 fixed32, rx_snr=8 float,
/// hop_limit=9, want_ack=10, priority=11, rx_rssi=12 int32, hop_start=15.
class MeshPacketPb {
  MeshPacketPb({
    this.from = 0,
    required this.to,
    this.channel = 0,
    this.decoded,
    this.encrypted = false,
    this.id = 0,
    this.rxTime = 0,
    this.rxSnr = 0,
    this.hopLimit = 0,
    this.wantAck = false,
    this.priority = 0,
    this.rxRssi = 0,
    this.hopStart = 0,
  });

  final int from;
  final int to;
  final int channel;
  final MeshData? decoded;

  /// The radio could not decrypt it (other channel / key).
  final bool encrypted;
  final int id;
  final int rxTime;
  final double rxSnr;
  final int hopLimit;
  final bool wantAck;

  /// MeshPacket.Priority: 64 = DEFAULT, 70 = RELIABLE, 100 = ALERT ...
  final int priority;
  final int rxRssi;
  final int hopStart;

  /// LoRa hops it took to reach our radio (0 = heard directly), when the
  /// sender's firmware reports hop_start.
  int? get hopsAway =>
      hopStart > 0 && hopStart >= hopLimit ? hopStart - hopLimit : null;

  static const priorityDefault = 64;
  static const priorityReliable = 70;
  static const priorityHigh = 100; // ALERT

  Uint8List encode() {
    final w = PbWriter()
      ..fixed32(1, from)
      ..fixed32(2, to)
      ..uint(3, channel);
    final d = decoded;
    if (d != null) w.message(4, d.encode());
    w
      ..fixed32(6, id)
      ..uint(9, hopLimit)
      ..boolean(10, wantAck)
      ..uint(11, priority);
    return w.toBytes();
  }

  static MeshPacketPb decode(Uint8List b) {
    var from = 0, to = 0, channel = 0, id = 0, rxTime = 0, hopLimit = 0;
    var hopStart = 0, rssi = 0, prio = 0;
    var snr = 0.0;
    var wantAck = false, encrypted = false;
    MeshData? decoded;
    for (final f in pbDecode(b)) {
      switch (f.number) {
        case 1:
          from = f.asFixed32;
        case 2:
          to = f.asFixed32;
        case 3:
          channel = f.asInt;
        case 4:
          decoded = MeshData.decode(f.asBytes);
        case 5:
          encrypted = true;
        case 6:
          id = f.asFixed32;
        case 7:
          rxTime = f.asFixed32;
        case 8:
          snr = f.asFloat;
        case 9:
          hopLimit = f.asInt;
        case 10:
          wantAck = f.asBool;
        case 11:
          prio = f.asInt;
        case 12:
          rssi = f.asInt32;
        case 15:
          hopStart = f.asInt;
      }
    }
    return MeshPacketPb(
      from: from,
      to: to,
      channel: channel,
      decoded: decoded,
      encrypted: encrypted,
      id: id,
      rxTime: rxTime,
      rxSnr: snr,
      hopLimit: hopLimit,
      wantAck: wantAck,
      priority: prio,
      rxRssi: rssi,
      hopStart: hopStart,
    );
  }
}

/// `ToRadio`: packet=1, want_config_id=3, disconnect=4, heartbeat=7.
class ToRadio {
  static Uint8List packet(MeshPacketPb p) =>
      (PbWriter()..message(1, p.encode())).toBytes();

  static Uint8List wantConfig(int nonce) =>
      (PbWriter()..uint(3, nonce, always: true)).toBytes();

  static Uint8List disconnect() => (PbWriter()..boolean(4, true)).toBytes();

  /// Heartbeat{nonce: 1}: the firmware answers with a QueueStatus.
  static Uint8List heartbeat() =>
      (PbWriter()..message(7, (PbWriter()..uint(1, 1)).toBytes())).toBytes();
}

/// `MyNodeInfo`: my_node_num=1, nodedb_count=15.
class MyNodeInfoPb {
  MyNodeInfoPb(this.myNodeNum, this.nodedbCount);
  final int myNodeNum;
  final int nodedbCount;

  static MyNodeInfoPb decode(Uint8List b) {
    var num = 0, count = 0;
    for (final f in pbDecode(b)) {
      if (f.number == 1) num = f.asInt & 0xFFFFFFFF;
      if (f.number == 15) count = f.asInt;
    }
    return MyNodeInfoPb(num, count);
  }
}

/// `DeviceMetrics` (telemetry.proto): battery_level=1 (101 = powered),
/// voltage=2, channel_utilization=3, air_util_tx=4, uptime_seconds=5.
class DeviceMetricsPb {
  DeviceMetricsPb({
    this.batteryLevel,
    this.voltage,
    this.channelUtilization,
    this.airUtilTx,
  });
  final int? batteryLevel;
  final double? voltage;
  final double? channelUtilization;
  final double? airUtilTx;

  static DeviceMetricsPb decode(Uint8List b) {
    int? bat;
    double? v, cu, au;
    for (final f in pbDecode(b)) {
      switch (f.number) {
        case 1:
          bat = f.asInt;
        case 2:
          v = f.asFloat;
        case 3:
          cu = f.asFloat;
        case 4:
          au = f.asFloat;
      }
    }
    return DeviceMetricsPb(
      batteryLevel: bat,
      voltage: v,
      channelUtilization: cu,
      airUtilTx: au,
    );
  }
}

/// `Telemetry`: time=1, device_metrics=2 (others ignored).
DeviceMetricsPb? decodeTelemetryDeviceMetrics(Uint8List b) {
  for (final f in pbDecode(b)) {
    if (f.number == 2 && f.wireType == 2) {
      return DeviceMetricsPb.decode(f.asBytes);
    }
  }
  return null;
}

/// `NodeInfo`: num=1, user=2 (User: id=1, long_name=2, short_name=3,
/// hw_model=5), snr=4, last_heard=5, device_metrics=6, hops_away=9.
class NodeInfoPb {
  NodeInfoPb({
    required this.num,
    this.userId = '',
    this.longName = '',
    this.shortName = '',
    this.hwModel = 0,
    this.snr = 0,
    this.lastHeard = 0,
    this.metrics,
    this.hopsAway,
  });
  final int num;
  final String userId;
  final String longName;
  final String shortName;
  final int hwModel;
  final double snr;
  final int lastHeard;
  final DeviceMetricsPb? metrics;
  final int? hopsAway;

  static NodeInfoPb decode(Uint8List b) {
    var num = 0, hw = 0, last = 0;
    int? hops;
    var snr = 0.0;
    var id = '', long = '', short = '';
    DeviceMetricsPb? m;
    for (final f in pbDecode(b)) {
      switch (f.number) {
        case 1:
          num = f.asInt & 0xFFFFFFFF;
        case 2:
          for (final u in pbDecode(f.asBytes)) {
            switch (u.number) {
              case 1:
                id = u.asString;
              case 2:
                long = u.asString;
              case 3:
                short = u.asString;
              case 5:
                hw = u.asInt;
            }
          }
        case 4:
          snr = f.asFloat;
        case 5:
          last = f.asFixed32;
        case 6:
          m = DeviceMetricsPb.decode(f.asBytes);
        case 9:
          hops = f.asInt;
      }
    }
    return NodeInfoPb(
      num: num,
      userId: id,
      longName: long,
      shortName: short,
      hwModel: hw,
      snr: snr,
      lastHeard: last,
      metrics: m,
      hopsAway: hops,
    );
  }
}

/// `QueueStatus`: res=1, free=2, maxlen=3, mesh_packet_id=4.
class QueueStatusPb {
  QueueStatusPb(this.res, this.free, this.maxlen, this.meshPacketId);
  final int res;
  final int free;
  final int maxlen;
  final int meshPacketId;

  static QueueStatusPb decode(Uint8List b) {
    var res = 0, free = 0, maxlen = 0, id = 0;
    for (final f in pbDecode(b)) {
      switch (f.number) {
        case 1:
          res = f.asInt32;
        case 2:
          free = f.asInt;
        case 3:
          maxlen = f.asInt;
        case 4:
          id = f.asInt & 0xFFFFFFFF;
      }
    }
    return QueueStatusPb(res, free, maxlen, id);
  }
}

/// The parts of `Config` we show: lora (6: region=7, modem_preset=2,
/// hop_limit=8, tx_enabled=9) and bluetooth (7: enabled=1, mode=2,
/// fixed_pin=3).
class RadioConfigPb {
  RadioConfigPb({
    this.region,
    this.modemPreset,
    this.hopLimit,
    this.txEnabled,
    this.btMode,
    this.fixedPin,
  });
  final int? region;
  final int? modemPreset;
  final int? hopLimit;
  final bool? txEnabled;

  /// 0 = random PIN (shown on screen), 1 = fixed PIN, 2 = no PIN.
  final int? btMode;
  final int? fixedPin;

  static RadioConfigPb? decode(Uint8List b) {
    for (final f in pbDecode(b)) {
      if (f.wireType != 2) continue;
      if (f.number == 6) {
        var region = 0, preset = 0, hop = 0;
        var tx = false;
        for (final l in pbDecode(f.asBytes)) {
          switch (l.number) {
            case 2:
              preset = l.asInt;
            case 7:
              region = l.asInt;
            case 8:
              hop = l.asInt;
            case 9:
              tx = l.asBool;
          }
        }
        return RadioConfigPb(
          region: region,
          modemPreset: preset,
          hopLimit: hop,
          txEnabled: tx,
        );
      }
      if (f.number == 7) {
        var mode = 0, pin = 0;
        for (final l in pbDecode(f.asBytes)) {
          if (l.number == 2) mode = l.asInt;
          if (l.number == 3) pin = l.asInt;
        }
        return RadioConfigPb(btMode: mode, fixedPin: pin);
      }
    }
    return null;
  }
}

/// `Channel`: index=1, settings=2 (psk=2, name=3), role=3 (1 = primary).
class ChannelPb {
  ChannelPb(this.index, this.name, this.psk, this.role);
  final int index;
  final String name;
  final Uint8List psk;
  final int role;

  bool get isPrimary => role == 1;

  /// No key or the well known one-byte default key ("AQ==", index 1):
  /// anyone with a Meshtastic radio can read it.
  bool get usesDefaultKey => psk.isEmpty || (psk.length == 1 && psk[0] <= 1);

  static ChannelPb decode(Uint8List b) {
    var index = 0, role = 0;
    var name = '';
    var psk = Uint8List(0);
    for (final f in pbDecode(b)) {
      switch (f.number) {
        case 1:
          index = f.asInt32;
        case 2:
          for (final s in pbDecode(f.asBytes)) {
            if (s.number == 2) psk = Uint8List.fromList(s.asBytes);
            if (s.number == 3) name = s.asString;
          }
        case 3:
          role = f.asInt;
      }
    }
    return ChannelPb(index, name, psk, role);
  }
}

/// `FromRadio`: id=1, packet=2, my_info=3, node_info=4, config=5,
/// config_complete_id=7, rebooted=8, channel=10, queueStatus=11.
class FromRadio {
  FromRadio({
    this.id = 0,
    this.packet,
    this.myInfo,
    this.nodeInfo,
    this.config,
    this.configCompleteId,
    this.rebooted = false,
    this.channel,
    this.queueStatus,
  });
  final int id;
  final MeshPacketPb? packet;
  final MyNodeInfoPb? myInfo;
  final NodeInfoPb? nodeInfo;
  final RadioConfigPb? config;
  final int? configCompleteId;
  final bool rebooted;
  final ChannelPb? channel;
  final QueueStatusPb? queueStatus;

  /// Null when [b] is not a valid protobuf.
  static FromRadio? tryDecode(Uint8List b) {
    try {
      var id = 0;
      MeshPacketPb? packet;
      MyNodeInfoPb? my;
      NodeInfoPb? node;
      RadioConfigPb? config;
      int? complete;
      var rebooted = false;
      ChannelPb? channel;
      QueueStatusPb? q;
      for (final f in pbDecode(b)) {
        switch (f.number) {
          case 1:
            id = f.asInt;
          case 2:
            packet = MeshPacketPb.decode(f.asBytes);
          case 3:
            my = MyNodeInfoPb.decode(f.asBytes);
          case 4:
            node = NodeInfoPb.decode(f.asBytes);
          case 5:
            config = RadioConfigPb.decode(f.asBytes);
          case 7:
            complete = f.asInt;
          case 8:
            rebooted = f.asBool;
          case 10:
            channel = ChannelPb.decode(f.asBytes);
          case 11:
            q = QueueStatusPb.decode(f.asBytes);
        }
      }
      return FromRadio(
        id: id,
        packet: packet,
        myInfo: my,
        nodeInfo: node,
        config: config,
        configCompleteId: complete,
        rebooted: rebooted,
        channel: channel,
        queueStatus: q,
      );
    } on PbFormatException {
      return null;
    } on RangeError {
      return null;
    }
  }
}

/// Region names for the settings screen.
String regionName(int code) => switch (code) {
  0 => 'not set',
  1 => 'US 915',
  2 => 'EU 433',
  3 => 'EU 868',
  6 => 'ANZ',
  _ => 'region $code',
};

String presetName(int code) => switch (code) {
  0 => 'LongFast',
  1 => 'LongSlow',
  2 => 'VeryLongSlow',
  3 => 'MediumSlow',
  4 => 'MediumFast',
  5 => 'ShortSlow',
  6 => 'ShortFast',
  7 => 'LongModerate',
  8 => 'ShortTurbo',
  9 => 'LongTurbo',
  _ => 'preset $code',
};
