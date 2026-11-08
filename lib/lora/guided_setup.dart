// v2.6.13: Guided radio setup. The numbers and the plain sentences for the
// wizard (lib/ui/guided_setup_page.dart). Nothing here talks to a radio by
// itself: the page applies a [RadioChange] through the existing settings
// writer (which saves a backup first and reads every field back) and turns
// the public channel on or off through the existing listen-only path.
// Channel keys and channel links are never read, stored or written into
// any sentence.
import 'dart:typed_data';

import 'meshtastic_proto.dart';
import 'meshtastic_session.dart';
import 'meshtastic_settings.dart';
import 'radio_match.dart';

/// The group's channel, matched by the name the Meshtastic apps show.
const String guidedBigfootName = 'BigfootNet';

/// Full location precision (exact). Same value as [precisionFull].
const int guidedBigfootPrecision = precisionFull;

/// Hop limit used when the other radios have not been read yet.
const int guidedDefaultHop = 4;

/// Region used when the radio has not chosen one (US 915).
const int guidedDefaultRegion = 1;

/// Shown when the radio has no channel of that name. The wizard cannot
/// create one: that would need the channel key, which is never handled here.
const String guidedMissingChannelText =
    'This radio does not have the BigfootNet channel, so its location '
    'precision cannot be set. Add that channel from your group, then try '
    'again.';

/// What the connected radio has right now, from the settings it already
/// sent. No extra radio traffic.
class GuidedNow {
  const GuidedNow({
    required this.connected,
    required this.radioId,
    required this.radioTitle,
    required this.longName,
    required this.shortName,
    required this.region,
    required this.slot,
    required this.hop,
    required this.bigfootIndex,
    required this.bigfootPrecision,
    required this.sharing,
    required this.publicListen,
    required this.publicShares,
  });

  final bool connected;
  final String? radioId;

  /// What to call it on the Connect step.
  final String radioTitle;
  final String longName;
  final String shortName;

  /// Null until the radio has sent its LoRa config.
  final int? region;
  final int? slot;
  final int? hop;

  /// Slot of the BigfootNet channel, null when the radio does not have it.
  final int? bigfootIndex;
  final int? bigfootPrecision;

  /// Null until position settings have been read.
  final bool? sharing;

  /// The listen-only public LongFast channel is on the radio.
  final bool publicListen;

  /// That channel was set up elsewhere and uploads or shares a location.
  final bool publicShares;

  /// "Yeti (YETI)", or the radio title when it has no name yet.
  String get nameLine {
    final long = longName.trim();
    final short = shortName.trim();
    if (long.isEmpty && short.isEmpty) return radioTitle;
    if (short.isEmpty) return long;
    if (long.isEmpty) return short;
    return '$long ($short)';
  }
}

/// The choices the person made in the wizard.
class GuidedChoice {
  const GuidedChoice({
    required this.longName,
    required this.shortName,
    required this.region,
    required this.slot,
    required this.hop,
    required this.shareLocation,
    required this.listenPublic,
  });

  final String longName;
  final String shortName;
  final int region;
  final int slot;
  final int hop;
  final bool shareLocation;
  final bool listenPublic;
}

/// One row of the review: what the radio has, and what it will have.
class GuidedLine {
  const GuidedLine(this.label, this.before, this.after);

  final String label;
  final String before;
  final String after;

  bool get changes => before != after;

  String get sentence =>
      changes ? '$label: $before to $after' : '$label: $before (no change)';
}

/// What Apply will write. [change] is empty when the radio already has
/// those settings. [publicListen] is null when the public channel stays
/// as it is.
class GuidedPlan {
  GuidedPlan({
    required this.lines,
    required this.change,
    required this.missingChannel,
    this.publicListen,
    this.publicReset = false,
  });

  final List<GuidedLine> lines;
  final RadioChange change;
  final bool missingChannel;

  /// true = add the listen-only public channel, false = remove it.
  final bool? publicListen;

  /// The public channel is there but not listen-only. Take it off, then
  /// add the listen-only one (the same two steps as the Radio settings
  /// switch).
  final bool publicReset;

  bool get writes => !change.isEmpty || publicListen != null || publicReset;
}

/// One setting read back after Apply.
class GuidedCheck {
  const GuidedCheck(this.id, this.label, this.ok, this.sentence);

  /// "hop", "slot", ... for the widget key.
  final String id;
  final String label;
  final bool ok;
  final String sentence;
}

/// Result of Apply. [error] is a plain sentence (never a key or a link).
class GuidedApplyResult {
  const GuidedApplyResult({
    this.checks = const [],
    this.error,
    this.backupSaved = false,
    this.alreadyMatched = false,
  });

  final List<GuidedCheck> checks;
  final String? error;
  final bool backupSaved;

  /// Nothing differed, so the radio was not written and no backup was taken.
  final bool alreadyMatched;

  bool get ok => error == null && checks.every((c) => c.ok);
}

/// null when [code] is a region the page offers.
String? validateGuidedRegion(int code) =>
    radioRegions.any((r) => r.code == code) ? null : 'Pick a region.';

/// null when [slot] is 0 (automatic) or a slot that exists in [region].
String? validateFrequencySlot(int slot, int region) {
  if (slot < 0 || slot > 511) {
    return 'Type a frequency slot from 0 to 511.';
  }
  final n = radioSlotCount(region);
  if (slot != 0 && n != null && slot > n) {
    return 'This region has frequency slots 1 to $n. 0 means automatic.';
  }
  return null;
}

/// The radio as the app already knows it. [ready] is the link state.
GuidedNow guidedFromRadio({
  required bool ready,
  required String? radioId,
  required String? radioTitle,
  required MeshtasticSession? session,
}) {
  final s = session;
  final connected = ready && s != null && s.configured && s.myNodeNum != null;
  if (!connected) {
    return GuidedNow(
      connected: false,
      radioId: radioId,
      radioTitle: _title(radioTitle, null, null),
      longName: '',
      shortName: '',
      region: null,
      slot: null,
      hop: null,
      bigfootIndex: null,
      bigfootPrecision: null,
      sharing: null,
      publicListen: false,
      publicShares: false,
    );
  }
  final me = s.nodes[s.myNodeNum];
  final names = channelIndexByName(s);
  final idx = names[guidedBigfootName];
  final ch = idx == null ? null : s.channels[idx];
  final pub = s.publicListenIndex;
  final pubCh = pub == null ? null : s.channels[pub];
  final sharing = s.positionSecs == null
      ? null
      : locationSharingOn(s.positionSecs, s.positionSmart);
  return GuidedNow(
    connected: true,
    radioId: radioId,
    radioTitle: _title(radioTitle, me?.longName, me?.shortName),
    longName: me?.longName ?? '',
    shortName: me?.shortName ?? '',
    region: s.region,
    slot: s.channelNum,
    hop: s.hopLimit,
    bigfootIndex: idx,
    bigfootPrecision: ch?.positionPrecision,
    sharing: sharing,
    publicListen: pub != null,
    publicShares:
        pubCh != null && (pubCh.uplinkEnabled || pubCh.positionPrecision != 0),
  );
}

String _title(String? device, String? long, String? short) {
  final l = long?.trim() ?? '';
  if (l.isNotEmpty) return l;
  final d = device?.trim() ?? '';
  if (d.isNotEmpty) return d;
  final s = short?.trim() ?? '';
  if (s.isNotEmpty) return s;
  return 'This radio';
}

/// The value that appears most often. A tie goes to [prefer] when it is
/// one of the values, otherwise the first one seen.
int? _majority(List<int> values, {int? prefer}) {
  if (values.isEmpty) return null;
  final counts = <int, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  var best = counts.keys.first;
  var bestN = 0;
  for (final e in counts.entries) {
    final preferTie = e.value == bestN && e.key == prefer;
    if (e.value > bestN || preferTie) {
      best = e.key;
      bestN = e.value;
    }
  }
  return best;
}

/// Starting choices: the other radios where they agree, otherwise hop
/// limit [guidedDefaultHop] and the public LongFast slot of the region
/// (20 in the US). Names and location sharing start as this radio has
/// them. Public listening stays as it is (the step is optional).
GuidedChoice suggestGuided(GuidedNow now, List<RadioReading> others) {
  final region = (now.region != null && now.region! > 0)
      ? now.region!
      : guidedDefaultRegion;
  final hop =
      _majority([
        for (final r in others)
          if (r.hop != null) r.hop!,
      ], prefer: guidedDefaultHop) ??
      guidedDefaultHop;
  final pub = radioPublicSlot(region);
  final slot =
      _majority([
        for (final r in others)
          if (r.slot != null) r.slot!,
      ], prefer: pub) ??
      pub ??
      now.slot ??
      0;
  return GuidedChoice(
    longName: now.longName,
    shortName: now.shortName,
    region: region,
    slot: slot.clamp(0, 511),
    hop: hop.clamp(0, 7),
    shareLocation: now.sharing ?? true,
    // Leave the public channel as the radio has it. The step is optional;
    // a channel that shares more than listening is made listen-only only
    // when this stays on.
    listenPublic: now.publicListen,
  );
}

String _nameText(String s) {
  final t = s.trim();
  return t.isEmpty ? '(none)' : t;
}

String _onOff(bool? v) => v == null ? 'unknown' : (v ? 'on' : 'off');

String _regionText(int? code) =>
    code == null ? 'unknown' : radioRegionText(code);

String _precisionText(int? p) => p == null ? 'unknown' : radioPrecisionText(p);

/// The review, and the [RadioChange] that makes the radio match [want].
/// [sharingSecs] / [sharingSmart] are the last interval the radio used
/// while sharing was on, so turning it back on puts that interval back.
GuidedPlan buildGuidedPlan(
  GuidedNow now,
  GuidedChoice want, {
  int? sharingSecs,
  bool? sharingSmart,
}) {
  final long = want.longName.trim();
  final short = want.shortName.trim();
  final lora = <int, int?>{};
  if (now.region != want.region) lora[7] = want.region;
  if (now.slot != want.slot) lora[11] = want.slot;
  if (now.hop != want.hop) lora[8] = want.hop;
  final prec = <int, int>{};
  final missing = now.connected && now.bigfootIndex == null;
  if (!missing &&
      now.bigfootIndex != null &&
      now.bigfootPrecision != guidedBigfootPrecision) {
    prec[now.bigfootIndex!] = guidedBigfootPrecision;
  }
  final pos = <int, int?>{};
  if (now.sharing != want.shareLocation) {
    pos.addAll(
      want.shareLocation
          ? RadioChange.sharingOn(
              secs: sharingSecs,
              smart: sharingSmart,
            ).position
          : RadioChange.sharingOff().position,
    );
  }
  final change = RadioChange(
    longName: now.longName.trim() == long ? null : long,
    shortName: now.shortName.trim() == short ? null : short,
    lora: lora,
    position: pos,
    channelPrecision: prec,
    what: 'guided setup',
  );
  final wantListen = want.listenPublic;
  final haveListen = now.publicListen && !now.publicShares;
  bool? public;
  var reset = false;
  if (wantListen && now.publicShares) {
    reset = true;
  } else if (wantListen != now.publicListen || wantListen != haveListen) {
    public = wantListen;
  }
  final beforePrec = missing
      ? 'not on this radio'
      : _precisionText(now.bigfootPrecision);
  return GuidedPlan(
    lines: [
      GuidedLine('Long name', _nameText(now.longName), _nameText(long)),
      GuidedLine('Short name', _nameText(now.shortName), _nameText(short)),
      GuidedLine('Region', _regionText(now.region), _regionText(want.region)),
      GuidedLine('Frequency slot', slotText(now.slot), slotText(want.slot)),
      GuidedLine(
        'Hop limit',
        now.hop == null ? 'unknown' : '${now.hop}',
        '${want.hop}',
      ),
      GuidedLine(
        'BigfootNet location precision',
        beforePrec,
        radioPrecisionText(guidedBigfootPrecision),
      ),
      GuidedLine(
        'Location sharing',
        _onOff(now.sharing),
        _onOff(want.shareLocation),
      ),
      GuidedLine(
        'Listen to public radios',
        now.publicShares ? 'on, but not listen-only' : _onOff(now.publicListen),
        wantListen ? 'on, listen-only' : 'off',
      ),
    ],
    change: change,
    missingChannel: missing,
    publicListen: public,
    publicReset: reset,
  );
}

GuidedCheck _check(
  String id,
  String label,
  bool ok,
  String have,
  String want,
) => GuidedCheck(
  id,
  label,
  ok,
  ok ? '$label is $have.' : '$label is still $have, not $want.',
);

/// Read every wizard setting back off [now] and compare it with [want].
List<GuidedCheck> checkGuided(GuidedNow now, GuidedChoice want) {
  if (!now.connected) {
    return const [
      GuidedCheck(
        'link',
        'Radio',
        false,
        'Your radio is not connected, so the settings could not be read back.',
      ),
    ];
  }
  final long = want.longName.trim();
  final short = want.shortName.trim();
  final precOk =
      now.bigfootIndex != null &&
      now.bigfootPrecision == guidedBigfootPrecision;
  final precHave = now.bigfootIndex == null
      ? 'not on this radio'
      : _precisionText(now.bigfootPrecision);
  final listenOk = want.listenPublic
      ? now.publicListen && !now.publicShares
      : !now.publicListen;
  final listenHave = !now.publicListen
      ? 'off'
      : (now.publicShares ? 'on, but not listen-only' : 'on, listen-only');
  final listenWant = want.listenPublic ? 'on, listen-only' : 'off';
  return [
    _check(
      'long',
      'Long name',
      now.longName.trim() == long,
      _nameText(now.longName),
      _nameText(long),
    ),
    _check(
      'short',
      'Short name',
      now.shortName.trim() == short,
      _nameText(now.shortName),
      _nameText(short),
    ),
    _check(
      'region',
      'Region',
      now.region == want.region,
      _regionText(now.region),
      _regionText(want.region),
    ),
    _check(
      'slot',
      'Frequency slot',
      now.slot == want.slot,
      slotText(now.slot),
      slotText(want.slot),
    ),
    _check(
      'hop',
      'Hop limit',
      now.hop == want.hop,
      now.hop == null ? 'unknown' : '${now.hop}',
      '${want.hop}',
    ),
    GuidedCheck(
      'precision',
      'BigfootNet location precision',
      precOk,
      precOk
          ? 'BigfootNet location precision is ${radioPrecisionText(guidedBigfootPrecision)}.'
          : 'BigfootNet location precision is still $precHave, not '
                '${radioPrecisionText(guidedBigfootPrecision)}.',
    ),
    _check(
      'location',
      'Location sharing',
      now.sharing == want.shareLocation,
      _onOff(now.sharing),
      _onOff(want.shareLocation),
    ),
    GuidedCheck(
      'public',
      'Listen to public radios',
      listenOk,
      listenOk
          ? 'Listen to public radios is $listenHave.'
          : 'Listen to public radios is still $listenHave, not $listenWant.',
    ),
  ];
}

/// The plain failure when one or more read-backs do not match. The same
/// shape as the settings writer's message, so the existing error text and
/// Restore button apply.
String guidedMismatchMessage(List<GuidedCheck> checks) {
  final bad = [
    for (final c in checks)
      if (!c.ok) c.label.toLowerCase(),
  ];
  final what = bad.isEmpty ? 'a setting' : bad.join(', ');
  return 'Your radio did not keep: $what. Nothing else was touched. '
      'You can restore the previous settings.';
}

/// One small want-ack packet on the radio's own channel, repeated at most
/// once, so the group can hear that the radio is on the air. Nothing in
/// the packet is a name, a place or a key. Returns null when the radio
/// accepted it, otherwise one plain sentence.
Future<String?> sendGuidedTestPing(
  MeshtasticSession? session, {
  required bool ready,
}) async {
  final s = session;
  if (!ready || s == null || !s.configured || s.myNodeNum == null) {
    return 'Connect your radio first.';
  }
  if ((s.queueFree ?? 3) < 1) {
    return 'Your radio is busy sending. Wait a moment and try again.';
  }
  try {
    await s.send(
      Uint8List.fromList(const [0x50]),
      wantAck: true,
      priority: MeshPacketPb.priorityReliable,
      hopLimitOverride: 1,
    );
    return null;
  } catch (_) {
    return 'The test ping did not send. Wait a moment and try again.';
  }
}
