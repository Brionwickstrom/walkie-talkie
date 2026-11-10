// MQTT bridge settings for the user's own broker (v2.6.15).
//
// The phone does not subscribe and does not poll. It stores the broker
// address and asks a connected radio to uplink and downlink. Packets stay
// channel-encrypted: JSON and the public Meshtastic broker are never turned
// on. Nothing in this file prints a password.
import 'dart:typed_data';

import '../lora/meshtastic_settings.dart' show patchVarints;
import '../lora/protobuf.dart';
import 'mqtt_client.dart';

/// Topic prefix written to radios and subscribed by the NAS logger.
const String defaultMqttRoot = 'msh/stalkie';

/// What a fix button on an MQTT error should do.
enum MqttFix { connectRadio, enterPassword, retry, checkBroker }

class MqttProblem {
  const MqttProblem(this.message, this.fix);
  final String message;
  final MqttFix fix;
}

/// A parsed `host:port`. [tls] is on for every port except 1883, and always
/// on for an `mqtts://` address. 8443 is the Tailscale Funnel port: TLS is
/// the Funnel certificate, and Mosquitto behind it is plain on the NAS.
class MqttAddress {
  const MqttAddress(this.host, this.port, this.tls);
  final String host;
  final int port;
  final bool tls;

  String get display => '$host:$port';
}

/// Null when [raw] is empty, has no port, or carries a password (`user:pass@`).
/// A password in the address is rejected so it is never stored or shown.
MqttAddress? tryParseMqttAddress(String raw) {
  var s = raw.trim();
  if (s.isEmpty || s.contains('@') || s.contains(' ')) return null;
  var tlsForced = false;
  final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://').firstMatch(s);
  if (scheme != null) {
    switch (scheme.group(1)!.toLowerCase()) {
      case 'mqtts':
      case 'ssl':
      case 'tls':
        tlsForced = true;
      case 'mqtt':
      case 'tcp':
        break;
      default:
        return null;
    }
    s = s.substring(scheme.end);
  }
  if (s.contains('/')) return null;
  final String host;
  final String portText;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end <= 1 || end + 1 >= s.length || s[end + 1] != ':') return null;
    host = s.substring(1, end);
    portText = s.substring(end + 2);
  } else {
    final colon = s.lastIndexOf(':');
    if (colon <= 0 || colon == s.length - 1) return null;
    host = s.substring(0, colon);
    portText = s.substring(colon + 1);
  }
  final port = int.tryParse(portText);
  if (host.isEmpty || port == null || port < 1 || port > 65535) return null;
  return MqttAddress(host, port, tlsForced || port != 1883);
}

/// The public Meshtastic broker and anything else under that domain.
/// This app never writes those addresses to a radio.
bool isPublicMeshtasticBroker(String host) {
  final h = host.toLowerCase().replaceAll(RegExp(r'\.$'), '');
  return h == 'meshtastic.org' ||
      h.endsWith('.meshtastic.org') ||
      h == 'meshtastic.net' ||
      h.endsWith('.meshtastic.net');
}

/// Null when [raw] is a usable topic prefix. Empty means [defaultMqttRoot].
String? validateMqttRoot(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  if (s.length > 64) return 'The topic root is too long.';
  if (s.startsWith('/') || s.endsWith('/') || s.contains('//')) {
    return 'The topic root cannot start or end with a slash.';
  }
  if (s.contains('+') || s.contains('#')) {
    return 'The topic root cannot contain a wildcard.';
  }
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_./-]*$').hasMatch(s)) {
    return 'The topic root can only use letters, numbers, and / . _ -';
  }
  return null;
}

String effectiveMqttRoot(String raw) {
  final s = raw.trim();
  return s.isEmpty ? defaultMqttRoot : s;
}

String? validateMqttUser(String raw, {required bool required}) {
  final s = raw.trim();
  if (!required && s.isEmpty) return null;
  if (s.isEmpty) return 'Type the broker username.';
  if (s.length > 64) return 'That username is too long.';
  if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(s)) {
    return 'The username can only use letters, numbers, and . _ -';
  }
  return null;
}

/// One channel as the preview needs it. No key, no URL.
class MqttChannelSnap {
  const MqttChannelSnap({
    required this.index,
    required this.name,
    required this.listenOnly,
  });
  final int index;
  final String name;
  final bool listenOnly;
}

class MqttChannelPlan {
  const MqttChannelPlan({
    required this.index,
    required this.name,
    required this.listenOnly,
    required this.selected,
  });
  final int index;
  final String name;

  /// The listen-only public LongFast channel. Never given uplink or downlink.
  final bool listenOnly;

  /// The user confirmed this channel should uplink and downlink.
  final bool selected;

  MqttChannelPlan copyWith({bool? selected}) => MqttChannelPlan(
    index: index,
    name: name,
    listenOnly: listenOnly,
    selected: selected ?? this.selected,
  );
}

/// What "Configure this radio" will write. The password is not in here.
class MqttRadioPlan {
  const MqttRadioPlan({
    required this.enabled,
    required this.address,
    required this.tls,
    required this.username,
    required this.passwordSaved,
    required this.root,
    required this.channels,
  });
  final bool enabled;
  final String address;
  final bool tls;
  final String username;
  final bool passwordSaved;
  final String root;
  final List<MqttChannelPlan> channels;

  MqttRadioPlan copyWith({List<MqttChannelPlan>? channels}) => MqttRadioPlan(
    enabled: enabled,
    address: address,
    tls: tls,
    username: username,
    passwordSaved: passwordSaved,
    root: root,
    channels: channels ?? this.channels,
  );
}

class MqttPrepare {
  const MqttPrepare({this.plan, this.problem});
  final MqttRadioPlan? plan;
  final MqttProblem? problem;
}

/// Builds the preview, or a plain error. Does not touch the radio.
MqttPrepare prepareMqttWrite({
  required bool radioReady,
  required bool hasChannels,
  required bool enabled,
  required String addressRaw,
  required String username,
  required String rootRaw,
  required bool hasPassword,
  required List<MqttChannelSnap> channels,
}) {
  if (!radioReady) {
    return const MqttPrepare(
      problem: MqttProblem(
        'Your radio is not connected, so its MQTT settings were not changed.',
        MqttFix.connectRadio,
      ),
    );
  }
  if (addressRaw.contains('@')) {
    return const MqttPrepare(
      problem: MqttProblem(
        'That address has a password in it. Take it out and type the '
        'password in the password box.',
        MqttFix.enterPassword,
      ),
    );
  }
  final addr = tryParseMqttAddress(addressRaw);
  if (addr == null) {
    return const MqttPrepare(
      problem: MqttProblem(
        'The broker address needs a host and a port, for example '
        'walkie-relay.tail1700cf.ts.net:8443.',
        MqttFix.retry,
      ),
    );
  }
  if (isPublicMeshtasticBroker(addr.host)) {
    return const MqttPrepare(
      problem: MqttProblem(
        'That address is the public Meshtastic server. This app only uses '
        'your own broker.',
        MqttFix.retry,
      ),
    );
  }
  final rootError = validateMqttRoot(rootRaw);
  if (rootError != null) {
    return MqttPrepare(problem: MqttProblem(rootError, MqttFix.retry));
  }
  final userError = validateMqttUser(username, required: enabled);
  if (userError != null) {
    return MqttPrepare(problem: MqttProblem(userError, MqttFix.retry));
  }
  if (enabled && !hasPassword) {
    return const MqttPrepare(
      problem: MqttProblem(
        'The broker password is not saved yet. Type it in the password box, '
        'then try again.',
        MqttFix.enterPassword,
      ),
    );
  }
  if (!hasChannels || channels.isEmpty) {
    return const MqttPrepare(
      problem: MqttProblem(
        'Your radio has not sent its channels yet. Wait a moment and try '
        'again.',
        MqttFix.retry,
      ),
    );
  }
  return MqttPrepare(
    plan: MqttRadioPlan(
      enabled: enabled,
      address: addr.display,
      tls: addr.tls,
      username: username.trim(),
      passwordSaved: hasPassword,
      root: effectiveMqttRoot(rootRaw),
      channels: [
        for (final c in channels)
          MqttChannelPlan(
            index: c.index,
            name: c.name,
            listenOnly: c.listenOnly,
            selected: enabled && !c.listenOnly,
          ),
      ],
    ),
  );
}

/// Words for the confirm dialog. No password, no channel key, no URL.
String mqttPreviewText(MqttRadioPlan p) {
  final b = StringBuffer()
    ..writeln(p.enabled ? 'MQTT on this radio: on' : 'MQTT on this radio: off')
    ..writeln('Broker: ${p.address}')
    ..writeln(p.tls ? 'TLS: on' : 'TLS: off')
    ..writeln('Username: ${p.username.isEmpty ? '(none)' : p.username}')
    ..writeln(
      p.passwordSaved ? 'Password: saved, not shown' : 'Password: not saved',
    )
    ..writeln('Topic root: ${p.root}')
    ..writeln('Encryption: on')
    ..writeln('JSON: off')
    ..writeln('Map reports: off')
    ..writeln('Phone proxy: off')
    ..writeln('Your radio will restart.');
  for (final c in p.channels) {
    if (c.listenOnly) {
      b.writeln('${c.name}: left alone (listen-only)');
    } else if (!p.enabled || !c.selected) {
      b.writeln('${c.name}: left as it is');
    } else {
      b.writeln('${c.name}: uplink on, downlink on');
    }
  }
  return b.toString().trimRight();
}

/// Broker line plus when a packet with via MQTT last arrived.
String mqttStatusLine({String? reach, DateTime? lastBridged, DateTime? now}) {
  final left = reach ?? 'Broker not checked';
  final right = lastBridged == null
      ? 'No bridged packet yet'
      : 'Last bridged packet ${mqttAgo((now ?? DateTime.now()).difference(lastBridged))}';
  return '$left. $right.';
}

String mqttAgo(Duration d) {
  if (d.isNegative || d.inSeconds < 15) return 'just now';
  if (d.inMinutes < 1) return '${d.inSeconds} s ago';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// `ModuleConfig` for the MQTT module. Encryption is always on, JSON is
/// always off, and the phone never proxies. [password] is written into the
/// protobuf and is not part of [toString].
class MqttModuleDraft {
  // The password stays a private field so toString cannot print it.
  // ignore: prefer_initializing_formals
  MqttModuleDraft({
    required this.enabled,
    required this.address,
    required this.username,
    required String password,
    required this.tls,
    required this.root,
    // ignore: prefer_initializing_formals
  }) : _password = password;

  final bool enabled;
  final String address;
  final String username;
  final bool tls;
  final String root;
  final String _password;

  Uint8List toModuleBytes() {
    final mqtt = PbWriter()
      ..boolean(1, enabled)
      ..string(2, address)
      ..string(3, username);
    if (_password.isNotEmpty) mqtt.string(4, _password);
    mqtt
      ..boolean(5, true) // encryption_enabled: channel encryption stays on
      ..boolean(7, tls)
      ..string(8, root);
    // json_enabled (6), proxy_to_client (9) and map_reporting (10) are
    // left out, which is proto3 false.
    return (PbWriter()..message(1, mqtt.toBytes())).toBytes();
  }

  @override
  String toString() =>
      'MqttModuleDraft(enabled: $enabled, $address, user: $username, '
      'password: ${_password.isEmpty ? 'none' : 'saved'}, tls: $tls, '
      'root: $root, encryption: on, json: off)';
}

/// MQTT module read back from a radio. The password, when the radio sends
/// it, stays bytes and is not in [toString].
class MqttModuleView {
  MqttModuleView({
    required this.enabled,
    required this.address,
    required this.username,
    required this.passwordBytes,
    required this.encryptionEnabled,
    required this.jsonEnabled,
    required this.tlsEnabled,
    required this.root,
  });

  final bool enabled;
  final String address;
  final String username;
  final Uint8List passwordBytes;
  final bool encryptionEnabled;
  final bool jsonEnabled;
  final bool tlsEnabled;
  final String root;

  bool get hasPassword => passwordBytes.isNotEmpty;

  static MqttModuleView? tryModule(Uint8List moduleConfig) {
    Uint8List? mqtt;
    for (final f in pbDecode(moduleConfig)) {
      if (f.number == 1 && f.wireType == 2) mqtt = f.asBytes;
    }
    if (mqtt == null) return null;
    var enabled = false, enc = false, json = false, tls = false;
    var address = '', user = '', root = '';
    var password = Uint8List(0);
    for (final f in pbDecode(mqtt)) {
      switch (f.number) {
        case 1:
          enabled = f.asBool;
        case 2:
          if (f.wireType == 2) address = f.asString;
        case 3:
          if (f.wireType == 2) user = f.asString;
        case 4:
          if (f.wireType == 2) password = Uint8List.fromList(f.asBytes);
        case 5:
          enc = f.asBool;
        case 6:
          json = f.asBool;
        case 7:
          tls = f.asBool;
        case 8:
          if (f.wireType == 2) root = f.asString;
      }
    }
    return MqttModuleView(
      enabled: enabled,
      address: address,
      username: user,
      passwordBytes: password,
      encryptionEnabled: enc,
      jsonEnabled: json,
      tlsEnabled: tls,
      root: root,
    );
  }

  @override
  String toString() =>
      'MqttModuleView(enabled: $enabled, $address, user: $username, '
      'password: ${hasPassword ? 'saved' : 'none'}, '
      'encryption: $encryptionEnabled, json: $jsonEnabled, tls: $tlsEnabled, '
      'root: $root)';
}

class MqttAdminView {
  MqttAdminView({this.passkey, this.mqtt});
  final Uint8List? passkey;
  final MqttModuleView? mqtt;

  static MqttAdminView? tryParse(Uint8List admin) {
    try {
      Uint8List? key;
      MqttModuleView? mqtt;
      for (final f in pbDecode(admin)) {
        if (f.number == 101 && f.wireType == 2) {
          key = Uint8List.fromList(f.asBytes);
        } else if (f.number == 8 && f.wireType == 2) {
          mqtt = MqttModuleView.tryModule(f.asBytes);
        }
      }
      if (key == null && mqtt == null) return null;
      return MqttAdminView(passkey: key, mqtt: mqtt);
    } on PbFormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  @override
  String toString() =>
      'MqttAdminView(${passkey != null ? 'passkey, ' : ''}${mqtt ?? ''})';
}

/// ChannelSettings with only uplink and downlink changed. The key and every
/// other field stay as the radio sent them.
Uint8List patchChannelBridge(
  Uint8List settings, {
  required bool uplink,
  required bool downlink,
}) => patchVarints(settings, {5: uplink ? 1 : 0, 6: downlink ? 1 : 0});

/// One sign-in check. [password] is sent only inside the MQTT connect packet.
Future<BrokerProbe> probeSavedBroker({
  required String address,
  required String username,
  required String password,
  MqttOpener? open,
  Duration timeout = const Duration(seconds: 4),
}) async {
  if (address.contains('@')) {
    return const BrokerProbe.down(
      'That address has a password in it. Type the password in the password box.',
    );
  }
  final addr = tryParseMqttAddress(address);
  if (addr == null) {
    return const BrokerProbe.down(
      'The broker address needs a host and a port.',
    );
  }
  if (isPublicMeshtasticBroker(addr.host)) {
    return const BrokerProbe.down(
      'That address is the public Meshtastic server. This app only uses your own broker.',
    );
  }
  if (username.trim().isEmpty || password.isEmpty) {
    return const BrokerProbe.down(
      'The broker username or password is not saved yet.',
    );
  }
  return probeMqtt(
    host: addr.host,
    port: addr.port,
    tls: addr.tls,
    username: username.trim(),
    password: password,
    open: open,
    timeout: timeout,
  );
}

/// Runs [write] only after [confirm] returns a plan. Cancel returns null
/// and does not write. A thrown error from [write] is returned as its
/// message when it is a [MqttWriteFailure]; anything else is rethrown.
Future<MqttProblem?> runMqttConfigure({
  required MqttRadioPlan plan,
  required Future<MqttRadioPlan?> Function(MqttRadioPlan plan) confirm,
  required Future<void> Function(MqttRadioPlan plan) write,
}) async {
  final chosen = await confirm(plan);
  if (chosen == null) return null;
  try {
    await write(chosen);
  } on MqttWriteFailure catch (e) {
    return MqttProblem(e.message, MqttFix.retry);
  }
  return null;
}

class MqttWriteFailure implements Exception {
  MqttWriteFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
