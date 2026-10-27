import 'dart:async';
import 'dart:typed_data';

import 'meshtastic_channels.dart';
import 'meshtastic_proto.dart';
import 'meshtastic_session.dart';
import 'protobuf.dart';

/// `AdminMessage` (admin.proto) for our own radio (v1.9.7):
/// get_channel_request=1 (index + 1), get_channel_response=2,
/// get_config_request=5 (ConfigType), get_config_response=6,
/// set_channel=33, set_config=34, begin_edit_settings=64,
/// commit_edit_settings=65, session_passkey=101 (from any get reply, valid
/// 300 s, sent back with every set).
class AdminPb {
  AdminPb._();

  static const configLora = 5; // AdminMessage.ConfigType.LORA_CONFIG
  static const configSessionKey = 8; // SESSIONKEY_CONFIG

  static Uint8List _with(void Function(PbWriter w) f, List<int>? passkey) {
    final w = PbWriter();
    f(w);
    if (passkey != null && passkey.isNotEmpty) w.bytes(101, passkey);
    return w.toBytes();
  }

  static Uint8List getConfig(int type) =>
      _with((w) => w.uint(5, type, always: true), null);

  static Uint8List getChannel(int index) =>
      _with((w) => w.uint(1, index + 1), null);

  static Uint8List beginEdit({List<int>? passkey}) =>
      _with((w) => w.boolean(64, true), passkey);

  static Uint8List commitEdit({List<int>? passkey}) =>
      _with((w) => w.boolean(65, true), passkey);

  /// set_channel: Channel{index, settings (raw ChannelSettings), role}.
  static Uint8List setChannel({
    required int index,
    required Uint8List settings,
    required int role,
    List<int>? passkey,
  }) {
    final ch = PbWriter()..uint(1, index);
    if (role != MeshChannelRole.disabled || settings.isNotEmpty) {
      ch.message(2, settings);
    }
    ch.uint(3, role);
    return _with((w) => w.message(33, ch.toBytes()), passkey);
  }

  /// set_config: Config{lora: [lora]}.
  static Uint8List setLoraConfig(Uint8List lora, {List<int>? passkey}) {
    final cfg = (PbWriter()..message(6, lora)).toBytes();
    return _with((w) => w.message(34, cfg), passkey);
  }
}

/// A decoded answer from our radio's admin module.
class AdminReply {
  AdminReply({this.passkey, this.loraConfig, this.channel});
  final Uint8List? passkey;

  /// get_config_response.lora (raw LoRaConfig).
  final Uint8List? loraConfig;
  final ChannelPb? channel;

  static AdminReply? tryDecode(Uint8List b) {
    try {
      Uint8List? key, lora;
      ChannelPb? ch;
      for (final f in pbDecode(b)) {
        if (f.number == 101 && f.wireType == 2) {
          key = Uint8List.fromList(f.asBytes);
        } else if (f.number == 6 && f.wireType == 2) {
          for (final c in pbDecode(f.asBytes)) {
            if (c.number == 6 && c.wireType == 2) {
              lora = Uint8List.fromList(c.asBytes);
            }
          }
        } else if (f.number == 2 && f.wireType == 2) {
          ch = ChannelPb.decode(f.asBytes);
        }
      }
      return AdminReply(passkey: key, loraConfig: lora, channel: ch);
    } on PbFormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  @override
  String toString() =>
      'AdminReply(${passkey != null ? 'passkey, ' : ''}'
      '${loraConfig != null ? 'lora, ' : ''}${channel ?? ''})';
}

/// The radio's LoRa settings with a QR's radio part put in: modem preset
/// / custom modem, region (when the QR has one) and frequency slot.
/// Everything else the radio has (transmit power, hop limit, transmit on,
/// ...) is kept byte for byte.
Uint8List patchLoraConfig(Uint8List radioLora, MeshLoraSettings qr) {
  const replaced = {1, 2, 3, 4, 5, 11};
  final w = PbWriter();
  for (final f in pbDecode(radioLora)) {
    if (replaced.contains(f.number)) continue;
    if (f.number == 7 && qr.region != 0) continue;
    w.raw(f);
  }
  final use = qr.effectiveUsePreset;
  w
    ..boolean(1, use)
    ..uint(2, qr.modemPreset);
  if (!use) {
    w
      ..uint(3, qr.bandwidth)
      ..uint(4, qr.spreadFactor)
      ..uint(5, qr.codingRate);
  }
  if (qr.region != 0) w.uint(7, qr.region);
  w.uint(11, qr.channelNum);
  return w.toBytes();
}

/// Steps of [MeshChannelWriter] for the progress text.
enum MeshWriteStep { preparing, writing, restarting, verifying, done }

String meshWriteStepText(MeshWriteStep s) => switch (s) {
  MeshWriteStep.preparing => 'Talking to your radio...',
  MeshWriteStep.writing => 'Saving the channel on your radio...',
  MeshWriteStep.restarting => 'Your radio is restarting (up to a minute)...',
  MeshWriteStep.verifying => 'Checking the channel on your radio...',
  MeshWriteStep.done => 'Done',
};

class MeshWriteException implements Exception {
  MeshWriteException(this.message);
  final String message;
  @override
  String toString() => 'MeshWriteException: $message';
}

/// Result of writing a channel: where it ended up and its link.
class MeshWriteResult {
  MeshWriteResult(this.index, this.ref, {this.alreadyThere = false});
  final int index;
  final MeshChannelRef ref;

  /// Nothing was written: the radio had this channel already.
  final bool alreadyThere;

  @override
  String toString() =>
      'MeshWriteResult($index, $ref${alreadyThere ? ', already there' : ''})';
}

/// Adds / removes a secondary channel on the paired radio with admin
/// messages (v1.9.7), the same way the official apps do:
///
/// 1. `get_config_request` (session key, valid 300 s; the LoRa config too
///    when its radio settings are to be applied);
/// 2. `begin_edit_settings`;
/// 3. `set_channel` (index = first free slot 1-7, role SECONDARY);
///    optionally `set_config` with the patched LoRa config;
/// 4. `commit_edit_settings`: the radio saves, drops Bluetooth and
///    restarts. The app reconnects on its own ([session] returns the new
///    session), then the channels are read back and checked by name and
///    hash.
///
/// The primary channel is never touched. [session] returns the radio's
/// current session (a new one after a reconnect).
class MeshChannelWriter {
  MeshChannelWriter(
    this.session, {
    this.replyTimeout = const Duration(seconds: 8),
    this.rebootWait = const Duration(seconds: 20),
    this.reconnectTimeout = const Duration(seconds: 120),
    this.poll = const Duration(milliseconds: 250),
    this.writeGap = const Duration(milliseconds: 150),
  });

  final MeshtasticSession? Function() session;
  final Duration replyTimeout;

  /// How long to wait for the restart after the commit before asking the
  /// radio for its settings again on the same link.
  final Duration rebootWait;
  final Duration reconnectTimeout;
  final Duration poll;
  final Duration writeGap;

  MeshtasticSession _ready() {
    final s = session();
    if (s == null || s.myNodeNum == null) {
      throw MeshWriteException('Connect your radio first.');
    }
    if (s.channels.isEmpty) {
      throw MeshWriteException(
        'Your radio has not sent its channels yet. Wait a moment and try '
        'again.',
      );
    }
    return s;
  }

  /// Where channel [i] of [set] already is on the radio (by name + hash).
  static int? findOnRadio(MeshtasticSession s, MeshChannelSet set, int i) =>
      s.indexOf(set.refFor(i, s.presetDisplayName));

  /// Ask for a session key (and optionally the LoRa config).
  Future<AdminReply?> _get(MeshtasticSession s, int configType) async {
    final reply = s.adminReplies
        .where((p) => p.decoded?.portnum == PortNum.admin)
        .map((p) => AdminReply.tryDecode(p.decoded!.payload))
        .where(
          (r) =>
              r != null &&
              (configType == AdminPb.configLora
                  ? r.loraConfig != null
                  : r.passkey != null),
        )
        .first
        .timeout(replyTimeout, onTimeout: () => null);
    await s.sendAdmin(AdminPb.getConfig(configType));
    unawaited(s.drain());
    return reply;
  }

  Future<void> _gap() => writeGap == Duration.zero
      ? Future.value()
      : Future<void>.delayed(writeGap);

  /// Write channel [i] of [set] as a secondary channel.
  /// [applyLora]: also put the QR's radio settings on the radio (cuts it
  /// off from its current group when they differ).
  Future<MeshWriteResult> addChannel(
    MeshChannelSet set,
    int i, {
    bool applyLora = false,
    void Function(MeshWriteStep step)? onStep,
  }) async {
    onStep?.call(MeshWriteStep.preparing);
    final s = _ready();
    final lora = applyLora ? set.loraToApply : null;
    final existing = findOnRadio(s, set, i);
    if (existing != null && lora == null) {
      onStep?.call(MeshWriteStep.done);
      return MeshWriteResult(
        existing,
        set.refFor(i, s.presetDisplayName),
        alreadyThere: true,
      );
    }
    final slot = existing ?? meshFreeSlot(s.channels.values);
    if (slot == null) {
      throw MeshWriteException(
        'All 7 extra channel slots on your radio are in use. Remove one in '
        'the Meshtastic app (or unlink one here with "also remove from the '
        'radio") and try again.',
      );
    }
    final got = await _get(
      s,
      lora != null ? AdminPb.configLora : AdminPb.configSessionKey,
    );
    if (lora != null && got?.loraConfig == null) {
      throw MeshWriteException(
        'Your radio did not send its radio settings, so they were not '
        'changed. Nothing was saved.',
      );
    }
    final key = got?.passkey;
    onStep?.call(MeshWriteStep.writing);
    final before = (s.rebootCount, s.configCount);
    await s.sendAdmin(AdminPb.beginEdit(passkey: key), wantResponse: false);
    await _gap();
    await s.sendAdmin(
      AdminPb.setChannel(
        index: slot,
        settings: set.settingsForSecondary(i),
        role: MeshChannelRole.secondary,
        passkey: key,
      ),
      wantResponse: false,
    );
    if (lora != null) {
      await _gap();
      await s.sendAdmin(
        AdminPb.setLoraConfig(
          patchLoraConfig(got!.loraConfig!, lora),
          passkey: key,
        ),
        wantResponse: false,
      );
    }
    await _gap();
    await s.sendAdmin(AdminPb.commitEdit(passkey: key), wantResponse: false);
    onStep?.call(MeshWriteStep.restarting);
    final after = await _afterCommit(s, before);
    onStep?.call(MeshWriteStep.verifying);
    final want = set.refFor(
      i,
      lora != null ? lora.presetDisplayName : after.presetDisplayName,
    );
    final c = after.channels[slot];
    if (c == null || c.isDisabled || after.refOf(c) != want) {
      final idx = after.indexOf(want);
      if (idx == null) {
        throw MeshWriteException(
          'Your radio restarted but the channel is not on it. Try again, or '
          'add it with the Meshtastic app.',
        );
      }
      onStep?.call(MeshWriteStep.done);
      return MeshWriteResult(idx, want);
    }
    onStep?.call(MeshWriteStep.done);
    return MeshWriteResult(slot, want);
  }

  /// Turn off secondary channel [index] (the primary is never removed).
  Future<void> removeChannel(
    int index, {
    void Function(MeshWriteStep step)? onStep,
  }) async {
    onStep?.call(MeshWriteStep.preparing);
    final s = _ready();
    final c = s.channels[index];
    if (index <= 0 || index >= meshMaxChannels || c == null || c.isPrimary) {
      throw MeshWriteException(
        'Only extra (secondary) channels can be removed.',
      );
    }
    if (c.isDisabled) {
      onStep?.call(MeshWriteStep.done);
      return;
    }
    final key = (await _get(s, AdminPb.configSessionKey))?.passkey;
    onStep?.call(MeshWriteStep.writing);
    final before = (s.rebootCount, s.configCount);
    await s.sendAdmin(AdminPb.beginEdit(passkey: key), wantResponse: false);
    await _gap();
    await s.sendAdmin(
      AdminPb.setChannel(
        index: index,
        settings: Uint8List(0),
        role: MeshChannelRole.disabled,
        passkey: key,
      ),
      wantResponse: false,
    );
    await _gap();
    await s.sendAdmin(AdminPb.commitEdit(passkey: key), wantResponse: false);
    onStep?.call(MeshWriteStep.restarting);
    final after = await _afterCommit(s, before);
    onStep?.call(MeshWriteStep.verifying);
    final now = after.channels[index];
    if (now != null && !now.isDisabled) {
      throw MeshWriteException('Your radio still has that channel.');
    }
    onStep?.call(MeshWriteStep.done);
  }

  /// Wait for the restart and the new settings download: a new session
  /// (Bluetooth / USB reconnected) or the same one after "rebooted". When
  /// nothing happens within [rebootWait], ask for the settings again.
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
        // No restart seen (firmware that applies channels live): read the
        // settings again on the same link.
        asked = true;
        try {
          unawaited(s0.requestConfig());
        } catch (_) {}
      }
      if (elapsed >= reconnectTimeout) {
        throw MeshWriteException(
          'Your radio did not come back after saving. Check that it is on '
          'and connected, then look in Settings > Long-range radio.',
        );
      }
      await Future<void>.delayed(poll);
    }
  }
}
