import 'dart:convert';
import 'dart:typed_data';

import 'protobuf.dart';

/// Meshtastic channels shared as a QR code / link (v1.9.7): the
/// `https://meshtastic.org/e/#<base64url ChannelSet>` format of the official
/// apps, channel keys (PSKs), channel hashes and the link between a Walkie
/// channel and a Meshtastic channel ([MeshChannelRef]).
///
/// Checked against meshtastic/protobufs `apponly.proto` (ChannelSet:
/// settings=1 repeated, lora_config=2), `channel.proto` (ChannelSettings:
/// channel_num=1, psk=2, name=3, id=4 fixed32, uplink_enabled=5,
/// downlink_enabled=6, module_settings=7, use_aead=8; Channel: index=1,
/// settings=2, role=3), `config.proto` (LoRaConfig) and the firmware's
/// `src/mesh/Channels.cpp` (getKey, getName, generateHash).
///
/// **Keys never leave this file in readable form**: [MeshChannelSettings]
/// keeps the PSK private, its [toString] and every error message here
/// leave it (and the link, which contains it) out. Only [keyKind] and the
/// one-byte channel hash are ever shown.

/// The firmware's default channel key (`defaultpsk`, "AQ==" = index 1).
const List<int> meshDefaultPsk = [
  0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59, //
  0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01,
];

/// Channel.Role.
class MeshChannelRole {
  static const disabled = 0;
  static const primary = 1;
  static const secondary = 2;
}

/// Max channels on a radio (index 0 = primary, 1-7 secondary).
const int meshMaxChannels = 8;

/// What kind of key a channel has (shown instead of the key).
enum MeshKeyKind {
  /// Encryption turned off: anyone can read it.
  none,

  /// The well-known default key (or one of the "simple" 1-byte keys every
  /// Meshtastic radio knows): anyone with a Meshtastic radio can read it.
  defaultPublic,

  /// A real 128 / 256 bit key: only radios with this QR can read it.
  custom,

  /// A secondary channel with no key of its own: it uses the radio's
  /// primary channel key.
  primaryKey,
}

String meshKeyKindText(MeshKeyKind k) => switch (k) {
  MeshKeyKind.none => 'No encryption',
  MeshKeyKind.defaultPublic => 'Default (public) key',
  MeshKeyKind.custom => 'Custom key',
  MeshKeyKind.primaryKey => 'Same key as the radio\'s main channel',
};

/// Firmware's `xorHash`.
int meshXorHash(List<int> bytes) {
  var h = 0;
  for (final b in bytes) {
    h ^= b & 0xFF;
  }
  return h;
}

/// The firmware's key expansion (Channels::getKey) for a non-empty [psk]:
/// 1 byte 0 -> no key, 1 byte n -> default key with its last byte + n - 1,
/// short keys zero padded to 16 / 32 bytes.
Uint8List meshExpandPsk(List<int> psk) {
  if (psk.isEmpty) return Uint8List(0);
  if (psk.length == 1) {
    final i = psk[0] & 0xFF;
    if (i == 0) return Uint8List(0);
    final k = Uint8List.fromList(meshDefaultPsk);
    k[15] = (k[15] + i - 1) & 0xFF;
    return k;
  }
  if (psk.length < 16) return Uint8List(16)..setRange(0, psk.length, psk);
  if (psk.length < 32 && psk.length != 16) {
    return Uint8List(32)..setRange(0, psk.length, psk);
  }
  return Uint8List.fromList(psk);
}

/// Kind of [psk] on a channel ([secondary]: an empty key means "use the
/// primary channel's key").
MeshKeyKind meshClassifyPsk(List<int> psk, {bool secondary = false}) {
  if (psk.isEmpty) return secondary ? MeshKeyKind.primaryKey : MeshKeyKind.none;
  final k = meshExpandPsk(psk);
  if (k.isEmpty) return MeshKeyKind.none;
  if (psk.length == 1) return MeshKeyKind.defaultPublic;
  var same = k.length == meshDefaultPsk.length;
  for (var i = 0; same && i < k.length; i++) {
    if (k[i] != meshDefaultPsk[i]) same = false;
  }
  return same ? MeshKeyKind.defaultPublic : MeshKeyKind.custom;
}

/// Display name of a modem preset as the firmware uses it for unnamed
/// channels (DisplayFormatters::getModemPresetDisplayName, long form).
String meshPresetDisplayName(int preset, {bool usePreset = true}) {
  if (!usePreset) return 'Custom';
  return switch (preset) {
    0 => 'LongFast',
    1 => 'LongSlow',
    3 => 'MediumSlow',
    4 => 'MediumFast',
    5 => 'ShortSlow',
    6 => 'ShortFast',
    7 => 'LongMod',
    8 => 'ShortTurbo',
    9 => 'LongTurbo',
    _ => 'Invalid',
  };
}

/// Readable preset name for the UI ("LongFast", "Custom radio settings").
String meshPresetLabel(int preset, {bool usePreset = true}) {
  if (!usePreset) return 'Custom radio settings';
  return switch (preset) {
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
    10 => 'LiteFast',
    11 => 'LiteSlow',
    12 => 'NarrowFast',
    13 => 'NarrowSlow',
    14 => 'TinyFast',
    15 => 'TinySlow',
    16 => 'MediumTurbo',
    _ => 'Preset $preset',
  };
}

/// Readable region name (Config.LoRaConfig.RegionCode).
String meshRegionLabel(int code) => switch (code) {
  0 => 'Not set',
  1 => 'US',
  2 => 'EU 433',
  3 => 'EU 868',
  4 => 'China',
  5 => 'Japan',
  6 => 'Australia / NZ',
  7 => 'Korea',
  8 => 'Taiwan',
  9 => 'Russia',
  10 => 'India',
  11 => 'NZ 865',
  12 => 'Thailand',
  13 => '2.4 GHz',
  14 => 'Ukraine 433',
  15 => 'Ukraine 868',
  16 => 'Malaysia 433',
  17 => 'Malaysia 919',
  18 => 'Singapore 923',
  19 => 'Philippines 433',
  20 => 'Philippines 868',
  21 => 'Philippines 915',
  22 => 'ANZ 433',
  23 => 'Kazakhstan 433',
  24 => 'Kazakhstan 863',
  25 => 'Nepal 865',
  26 => 'Brazil 902',
  _ => 'Region $code',
};

/// The firmware's channel hash: xor of the (effective) name and the
/// expanded key, 0-255.
int meshChannelHash(String effectiveName, List<int> expandedKey) =>
    meshXorHash(utf8.encode(effectiveName)) ^ meshXorHash(expandedKey);

/// A Walkie channel <-> Meshtastic channel link: the channel's effective
/// name (as the radio uses it: its name, or the preset name when it has
/// none) and its channel hash. Never the slot index: each radio may keep
/// the channel in a different slot, resolved with [MeshRadioChannel.ref].
class MeshChannelRef {
  const MeshChannelRef(this.name, this.hash);
  final String name;
  final int hash;

  Map<String, Object?> toJson() => {'name': name, 'hash': hash};

  static MeshChannelRef? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['name'], h = j['hash'];
    if (n is! String || h is! num) return null;
    if (h < 0 || h > 255 || n.length > 64) return null;
    return MeshChannelRef(n, h.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is MeshChannelRef && other.name == name && other.hash == hash;

  @override
  int get hashCode => Object.hash(name, hash);

  @override
  String toString() => 'MeshChannelRef("$name" #$hash)';
}

/// One `ChannelSettings` from a QR code. The key stays private.
class MeshChannelSettings {
  MeshChannelSettings._(
    this._psk,
    this._raw, {
    required this.name,
    required this.uplinkEnabled,
    required this.downlinkEnabled,
    required this.id,
    required this.positionPrecision,
  });

  /// Name as set ('' = unnamed: the radio shows its preset name).
  final String name;
  final Uint8List _psk;
  final Uint8List _raw;

  /// MQTT uplink: the radio copies this channel's traffic to the internet
  /// (an MQTT server) when it has internet.
  final bool uplinkEnabled;
  final bool downlinkEnabled;
  final int id;

  /// Location precision shared on this channel (bits, 0 = none).
  final int positionPrecision;

  /// Kind of key, as a channel of a ChannelSet ([secondary] = not the first
  /// one in the set).
  MeshKeyKind keyKind({bool secondary = false}) =>
      meshClassifyPsk(_psk, secondary: secondary);

  /// Key length in bytes after expansion (0, 16 or 32), for the preview.
  int get keyBits => meshExpandPsk(_psk).length * 8;

  /// The key is not 0, 1, 16 or 32 bytes (the firmware zero pads it).
  bool get unusualKeyLength =>
      _psk.isNotEmpty &&
      _psk.length != 1 &&
      _psk.length != 16 &&
      _psk.length != 32;

  /// Name the radio uses for it with [presetName] as its preset.
  String effectiveName(String presetName) => name.isEmpty ? presetName : name;

  static MeshChannelSettings decode(Uint8List b) {
    var name = '';
    var psk = Uint8List(0);
    var up = false, down = false;
    var id = 0, prec = 0;
    for (final f in pbDecode(b)) {
      switch (f.number) {
        case 2:
          if (f.wireType == 2) psk = Uint8List.fromList(f.asBytes);
        case 3:
          if (f.wireType == 2) name = f.asString;
        case 4:
          id = f.asFixed32;
        case 5:
          up = f.asBool;
        case 6:
          down = f.asBool;
        case 7:
          if (f.wireType == 2) {
            for (final m in pbDecode(f.asBytes)) {
              if (m.number == 1) prec = m.asInt;
            }
          }
      }
    }
    return MeshChannelSettings._(
      psk,
      Uint8List.fromList(b),
      name: name,
      uplinkEnabled: up,
      downlinkEnabled: down,
      id: id,
      positionPrecision: prec,
    );
  }

  /// The `ChannelSettings` bytes to write to a radio as a secondary
  /// channel: the QR's own bytes (unknown newer fields kept), with the key
  /// made explicit so it means the same on our radio. A key-less first
  /// channel of a set means "no encryption" (write key 0); a key-less
  /// later channel used the set's first channel's key ([setPrimaryPsk]).
  Uint8List settingsForSecondary({
    List<int>? setPrimaryPsk,
    bool first = true,
  }) {
    if (_psk.isNotEmpty) return Uint8List.fromList(_raw);
    final List<int> psk = first
        ? const [0]
        : ((setPrimaryPsk == null || setPrimaryPsk.isEmpty)
              ? const [0]
              : setPrimaryPsk);
    final w = PbWriter();
    for (final f in pbDecode(_raw)) {
      if (f.number == 2) continue;
      w.raw(f);
    }
    w.bytes(2, psk);
    return w.toBytes();
  }

  /// The key the radio will use once written as a secondary channel
  /// (expanded), for the expected channel hash.
  Uint8List expandedKeyForSecondary({
    List<int>? setPrimaryPsk,
    bool first = true,
  }) {
    if (_psk.isNotEmpty) return meshExpandPsk(_psk);
    if (first || setPrimaryPsk == null) return Uint8List(0);
    return meshExpandPsk(setPrimaryPsk);
  }

  Uint8List get pskForSet => Uint8List.fromList(_psk);

  @override
  String toString() =>
      'MeshChannelSettings("$name", ${meshKeyKindText(keyKind())}'
      '${uplinkEnabled ? ', uplink' : ''})';
}

/// The `LoRaConfig` in a QR code (only what the preview needs; the raw
/// bytes are kept for "Also apply radio settings").
class MeshLoraSettings {
  MeshLoraSettings._(this.raw, this.fields);
  final Uint8List raw;
  final Map<int, int> fields;

  bool get usePreset => (fields[1] ?? 0) != 0;
  int get modemPreset => fields[2] ?? 0;
  int get bandwidth => fields[3] ?? 0;
  int get spreadFactor => fields[4] ?? 0;
  int get codingRate => fields[5] ?? 0;
  int get region => fields[7] ?? 0;
  int get hopLimit => fields[8] ?? 0;
  int get channelNum => fields[11] ?? 0;

  /// Old apps left use_preset out (proto3 false) and set no custom radio
  /// either: that still means the preset.
  bool get effectiveUsePreset =>
      usePreset || (bandwidth == 0 && spreadFactor == 0);

  String get presetLabel =>
      meshPresetLabel(modemPreset, usePreset: effectiveUsePreset);

  /// Name the radio uses for unnamed channels with these settings.
  String get presetDisplayName =>
      meshPresetDisplayName(modemPreset, usePreset: effectiveUsePreset);

  static MeshLoraSettings decode(Uint8List b) {
    final m = <int, int>{};
    for (final f in pbDecode(b)) {
      if (f.wireType == 0) m[f.number] = f.asInt;
    }
    return MeshLoraSettings._(Uint8List.fromList(b), m);
  }
}

/// Why a link / QR could not be read (never includes the link itself).
class MeshLinkException implements Exception {
  MeshLinkException(this.message);
  final String message;
  @override
  String toString() => 'MeshLinkException: $message';
}

/// A decoded Meshtastic channel QR / link.
class MeshChannelSet {
  MeshChannelSet._(this.channels, this.lora, {this.addMode = false});

  final List<MeshChannelSettings> channels;
  final MeshLoraSettings? lora;

  /// "?add=true" links: add the channels, do not change the radio's
  /// settings (the official apps ignore the LoRa part then).
  final bool addMode;

  /// The LoRa settings to compare / apply (null in add mode).
  MeshLoraSettings? get loraToApply => addMode ? null : lora;

  /// Looks like a Meshtastic channel link (without decoding it).
  static bool looksLikeLink(String text) {
    final t = text.trim().toLowerCase();
    return RegExp(r'^(https?://)?(www\.)?meshtastic\.org/').hasMatch(t) &&
        t.contains('#');
  }

  static final _hostRe = RegExp(
    r'^(?:https?://)?(?:www\.)?meshtastic\.org(/[^#]*)#(.*)$',
    caseSensitive: false,
  );

  /// Parse `https://meshtastic.org/e/#...` (also `/e#`, `/d/#`,
  /// `/channel/e/#`, `www.`, `?add=true` before or after the `#`, with or
  /// without base64 padding). Throws [MeshLinkException].
  static MeshChannelSet parseUrl(String text) {
    final t = text.trim();
    final m = _hostRe.firstMatch(t);
    if (m == null) {
      throw MeshLinkException('That is not a Meshtastic channel link.');
    }
    final pathAndQuery = m[1]!;
    var fragment = m[2]!;
    final q = pathAndQuery.indexOf('?');
    final path = (q < 0 ? pathAndQuery : pathAndQuery.substring(0, q))
        .toLowerCase();
    var query = q < 0 ? '' : pathAndQuery.substring(q + 1);
    final okPath = RegExp(r'^/(?:channel/)?[ed]/?$').hasMatch(path);
    if (!okPath) {
      throw MeshLinkException(
        'That Meshtastic link is not a channel link (it should contain '
        'meshtastic.org/e/#).',
      );
    }
    final fq = fragment.indexOf('?');
    if (fq >= 0) {
      query = '$query&${fragment.substring(fq + 1)}';
      fragment = fragment.substring(0, fq);
    }
    final add = query.split('&').any((p) => p.toLowerCase() == 'add=true');
    return parseBase64(fragment, addMode: add);
  }

  /// Decode the base64url ChannelSet ([addMode] as for `?add=true`).
  static MeshChannelSet parseBase64(String b64, {bool addMode = false}) {
    var s = b64.trim().replaceAll('-', '+').replaceAll('_', '/');
    s = s.replaceAll('=', '');
    if (s.isEmpty || !RegExp(r'^[A-Za-z0-9+/]+$').hasMatch(s)) {
      throw MeshLinkException('The channel link is damaged (not base64).');
    }
    if (s.length % 4 == 1) {
      throw MeshLinkException('The channel link is damaged (cut off?).');
    }
    s = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
    final Uint8List bytes;
    try {
      bytes = base64.decode(s);
    } on FormatException {
      throw MeshLinkException('The channel link is damaged (not base64).');
    }
    return decode(bytes, addMode: addMode);
  }

  /// Decode a ChannelSet protobuf.
  static MeshChannelSet decode(Uint8List bytes, {bool addMode = false}) {
    final channels = <MeshChannelSettings>[];
    MeshLoraSettings? lora;
    try {
      for (final f in pbDecode(bytes)) {
        if (f.number == 1 && f.wireType == 2) {
          channels.add(MeshChannelSettings.decode(f.asBytes));
        } else if (f.number == 2 && f.wireType == 2) {
          lora = MeshLoraSettings.decode(f.asBytes);
        }
      }
    } on PbFormatException {
      throw MeshLinkException('The channel link is damaged (bad data).');
    } on RangeError {
      throw MeshLinkException('The channel link is damaged (bad data).');
    }
    if (channels.isEmpty) {
      throw MeshLinkException('That link has no channels in it.');
    }
    if (channels.length > meshMaxChannels) {
      throw MeshLinkException('That link has too many channels.');
    }
    return MeshChannelSet._(channels, lora, addMode: addMode);
  }

  /// The ChannelSet bytes (tests; contains the keys).
  Uint8List encode() {
    final w = PbWriter();
    for (final c in channels) {
      w.message(1, c._raw);
    }
    final l = lora;
    if (l != null) w.message(2, l.raw);
    return w.toBytes();
  }

  /// The share link (tests; contains the keys, never log it).
  String toUrl() {
    final b = base64Url.encode(encode()).replaceAll('=', '');
    return 'https://meshtastic.org/e/#$b';
  }

  /// [i]'s bytes for set_channel, as a secondary channel on our radio.
  Uint8List settingsForSecondary(int i) => channels[i].settingsForSecondary(
    setPrimaryPsk: channels.first._psk,
    first: i == 0,
  );

  /// The expanded key channel [i] will have on our radio (for its hash).
  Uint8List expandedKeyForSecondary(int i) =>
      channels[i].expandedKeyForSecondary(
        setPrimaryPsk: channels.first._psk,
        first: i == 0,
      );

  /// What channel [i] is called on a radio with [presetName] (unnamed ->
  /// the preset name) and its hash there.
  MeshChannelRef refFor(int i, String presetName) {
    final name = channels[i].effectiveName(presetName);
    return MeshChannelRef(
      name,
      meshChannelHash(name, expandedKeyForSecondary(i)),
    );
  }

  /// Kind of key channel [i] really has (a key-less later channel uses the
  /// set's first key).
  MeshKeyKind keyKindOf(int i) {
    final c = channels[i];
    if (i == 0 || c._psk.isNotEmpty) return c.keyKind();
    return channels.first.keyKind();
  }

  @override
  String toString() =>
      'MeshChannelSet(${channels.length} channel(s)${lora == null ? '' : ', lora'})';
}

/// A channel as read back from a radio (no key kept, just its kind and
/// the xor of its key for the hash).
class MeshRadioChannel {
  MeshRadioChannel({
    required this.index,
    required this.role,
    required this.name,
    required this.keyKind,
    required this.keyXor,
    this.uplinkEnabled = false,
  });

  /// From a decoded `Channel` with its raw [psk] (dropped here).
  factory MeshRadioChannel.fromChannel({
    required int index,
    required int role,
    required String name,
    required List<int> psk,
    bool uplinkEnabled = false,
  }) {
    final secondary = role == MeshChannelRole.secondary;
    return MeshRadioChannel(
      index: index,
      role: role,
      name: name,
      keyKind: meshClassifyPsk(psk, secondary: secondary),
      keyXor: meshXorHash(meshExpandPsk(psk)),
      uplinkEnabled: uplinkEnabled,
    );
  }

  final int index;
  final int role;
  final String name;
  final MeshKeyKind keyKind;

  /// Xor of the expanded key (one byte of the channel hash, not the key).
  final int keyXor;
  final bool uplinkEnabled;

  bool get isPrimary => role == MeshChannelRole.primary;
  bool get isSecondary => role == MeshChannelRole.secondary;
  bool get isDisabled => role == MeshChannelRole.disabled;

  String effectiveName(String presetName) => name.isEmpty ? presetName : name;

  /// Its link on this radio ([presetName] = the radio's preset display
  /// name, [primaryKeyXor] = its primary channel's key xor for key-less
  /// secondary channels).
  MeshChannelRef ref(String presetName, {int primaryKeyXor = 0}) {
    final n = effectiveName(presetName);
    final k = keyKind == MeshKeyKind.primaryKey ? primaryKeyXor : keyXor;
    return MeshChannelRef(n, meshXorHash(utf8.encode(n)) ^ k);
  }

  @override
  String toString() =>
      'MeshRadioChannel($index, role $role, "$name", ${keyKind.name})';
}

/// The first free slot for a new secondary channel (1-7), or null.
int? meshFreeSlot(
  Iterable<MeshRadioChannel> channels, {
  int max = meshMaxChannels,
}) {
  final used = {
    for (final c in channels)
      if (!c.isDisabled) c.index,
  };
  for (var i = 1; i < max; i++) {
    if (!used.contains(i)) return i;
  }
  return null;
}
