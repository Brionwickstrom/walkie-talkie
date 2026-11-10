// Writes the MQTT module and per-channel uplink / downlink to a connected
// radio (v2.6.15). Callers show a preview first; this runs only after the
// user confirms. The password is sent to the radio and is not put in any
// error text.
import 'dart:async';

import '../lora/meshtastic_admin.dart';
import '../lora/meshtastic_proto.dart';
import '../lora/meshtastic_session.dart';
import 'mqtt_config.dart';

enum MqttWriteStep { preparing, writing, restarting, verifying, done }

String mqttWriteStepText(MqttWriteStep s) => switch (s) {
  MqttWriteStep.preparing => 'Talking to your radio...',
  MqttWriteStep.writing => 'Saving MQTT settings on your radio...',
  MqttWriteStep.restarting => 'Your radio is restarting (up to a minute)...',
  MqttWriteStep.verifying => 'Checking the MQTT settings...',
  MqttWriteStep.done => 'Done',
};

class MqttWriteResult {
  MqttWriteResult(this.address, this.root, {required this.enabled});
  final String address;
  final String root;
  final bool enabled;

  @override
  String toString() =>
      'MqttWriteResult($address, root $root, enabled: $enabled)';
}

class MqttRadioWriter {
  MqttRadioWriter(
    this.session, {
    this.replyTimeout = const Duration(seconds: 8),
    this.rebootWait = const Duration(seconds: 20),
    this.reconnectTimeout = const Duration(seconds: 120),
    this.poll = const Duration(milliseconds: 250),
    this.writeGap = const Duration(milliseconds: 150),
  });

  final MeshtasticSession? Function() session;
  final Duration replyTimeout;
  final Duration rebootWait;
  final Duration reconnectTimeout;
  final Duration poll;
  final Duration writeGap;

  /// [password] is empty when [plan] turns MQTT off. It is not logged.
  Future<MqttWriteResult> apply(
    MqttRadioPlan plan, {
    required String password,
    void Function(MqttWriteStep step)? onStep,
  }) async {
    onStep?.call(MqttWriteStep.preparing);
    final s = _ready();
    if (plan.enabled && password.isEmpty) {
      throw MqttWriteFailure(
        'The broker password is not saved yet, so the radio was not changed.',
      );
    }
    final key = (await _module(s, (v) => v.passkey != null))?.passkey;
    onStep?.call(MqttWriteStep.writing);
    final before = (s.rebootCount, s.configCount);
    await s.sendAdmin(AdminPb.beginEdit(passkey: key), wantResponse: false);
    await _gap();
    final module = MqttModuleDraft(
      enabled: plan.enabled,
      address: plan.address,
      username: plan.username,
      password: plan.enabled ? password : '',
      tls: plan.tls,
      root: plan.root,
    ).toModuleBytes();
    await s.sendAdmin(
      AdminPb.setModuleConfig(module, passkey: key),
      wantResponse: false,
    );
    if (plan.enabled) {
      for (final c in plan.channels) {
        if (!c.selected || c.listenOnly) continue;
        final ch = await _readChannel(s, c.index);
        final raw = ch.rawSettings;
        if (raw == null) {
          throw MqttWriteFailure(
            'Your radio did not send ${c.name}, so nothing more was written. '
            'Try again.',
          );
        }
        await _gap();
        await s.sendAdmin(
          AdminPb.setChannel(
            index: c.index,
            settings: patchChannelBridge(raw, uplink: true, downlink: true),
            role: ch.role,
            passkey: key,
          ),
          wantResponse: false,
        );
      }
    }
    await _gap();
    await s.sendAdmin(AdminPb.commitEdit(passkey: key), wantResponse: false);
    onStep?.call(MqttWriteStep.restarting);
    final after = await _afterCommit(s, before);
    onStep?.call(MqttWriteStep.verifying);
    final back = await _module(after, (v) => v.mqtt != null);
    final m = back?.mqtt;
    if (m == null ||
        m.enabled != plan.enabled ||
        m.address != plan.address ||
        m.root != plan.root ||
        m.username != plan.username ||
        !m.encryptionEnabled ||
        m.jsonEnabled ||
        m.tlsEnabled != plan.tls) {
      throw MqttWriteFailure(
        'Your radio restarted but the MQTT settings did not stick. Try again.',
      );
    }
    if (plan.enabled) {
      for (final c in plan.channels) {
        if (!c.selected || c.listenOnly) continue;
        final now = await _readChannel(after, c.index);
        if (!now.uplink || !now.downlink) {
          throw MqttWriteFailure(
            'Uplink did not stick on ${c.name}. Try again.',
          );
        }
      }
    }
    onStep?.call(MqttWriteStep.done);
    return MqttWriteResult(plan.address, plan.root, enabled: plan.enabled);
  }

  MeshtasticSession _ready() {
    final s = session();
    if (s == null || s.myNodeNum == null) {
      throw MqttWriteFailure(
        'Your radio is not connected, so its MQTT settings were not changed.',
      );
    }
    return s;
  }

  Future<void> _gap() => writeGap == Duration.zero
      ? Future<void>.value()
      : Future<void>.delayed(writeGap);

  Future<MqttAdminView?> _module(
    MeshtasticSession s,
    bool Function(MqttAdminView v) match,
  ) async {
    final reply = s.adminReplies
        .where((p) => p.decoded?.portnum == PortNum.admin)
        .map((p) => MqttAdminView.tryParse(p.decoded!.payload))
        .where((v) {
          if (v == null) return false;
          return match(v);
        })
        .first
        .timeout(replyTimeout, onTimeout: () => null);
    await s.sendAdmin(AdminPb.getModuleConfig(AdminPb.moduleMqtt));
    unawaited(s.drain());
    return reply;
  }

  Future<ChannelPb> _readChannel(MeshtasticSession s, int index) async {
    final reply = s.adminReplies
        .where((p) => p.decoded?.portnum == PortNum.admin)
        .map((p) => AdminReply.tryDecode(p.decoded!.payload))
        .where((r) {
          final ch = r?.channel;
          return ch != null && ch.index == index;
        })
        .first
        .timeout(replyTimeout, onTimeout: () => null);
    await s.sendAdmin(AdminPb.getChannel(index));
    unawaited(s.drain());
    final got = await reply;
    final c = got?.channel;
    if (c == null || c.rawSettings == null) {
      throw MqttWriteFailure(
        'Your radio did not send channel ${index + 1}, so nothing more was '
        'written. Try again.',
      );
    }
    return c;
  }

  Future<MeshtasticSession> _afterCommit(
    MeshtasticSession s0,
    (int, int) before,
  ) async {
    final start = DateTime.now();
    var asked = false;
    while (true) {
      final cur = session();
      final elapsed = DateTime.now().difference(start);
      if (cur != null && cur.configured && cur.channels.isNotEmpty) {
        final fresh = !identical(cur, s0);
        final restarted =
            identical(cur, s0) &&
            (cur.rebootCount > before.$1 || cur.configCount > before.$2);
        if (fresh || restarted) return cur;
      }
      if (!asked && elapsed >= rebootWait && identical(cur, s0)) {
        asked = true;
        try {
          unawaited(s0.requestConfig());
        } catch (_) {}
      }
      if (elapsed >= reconnectTimeout) {
        throw MqttWriteFailure(
          'Your radio did not come back after saving. Check that it is on '
          'and connected, then try again.',
        );
      }
      await Future<void>.delayed(poll);
    }
  }
}
