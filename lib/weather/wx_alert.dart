import 'dart:convert';

/// Weather alerts (v2.5.0, stage 1).
///
/// One alert model for every way an alert can reach the phone, so the next
/// stage (relay push plus the LoRa backup) plugs into the same store without
/// changing it. Any device with internet (phone, Windows, optionally the
/// Synology) checks the NWS itself; one with a radio also injects a compact
/// signed alert. Every device signs with its OWN Ed25519 key made on the
/// device: there is no master key and no single gateway key anywhere. An
/// alert carries the sending device's id and the NWS id / VTEC (its [key]).
///  * [WxSource.nws]: this phone asked api.weather.gov itself (stage 1).
///  * [WxSource.relay]: another device pushed it into a relay room.
///  * [WxSource.lora]: a signed compact `FrameType.alert` over the radio.
/// Whatever is not [WxSource.nws] must have its signature checked BEFORE it
/// is handed to the store (the store trusts what it is given) and carries
/// a [WxTrust] from the channel it arrived on (see [WxTrust]). Stage 1 never
/// creates the other two.
enum WxSource {
  nws('National Weather Service, via internet'),
  relay('National Weather Service, via relay'),
  lora('National Weather Service, via radio');

  const WxSource(this.label);

  /// The line shown under an alert.
  final String label;

  static WxSource byName(String? n) =>
      values.firstWhere((s) => s.name == n, orElse: () => WxSource.nws);
}

/// How far an alert is to be believed, lowest to highest.
///  * [unconfirmed]: arrived on an Open channel from a device we do not
///    trust: shown as "unconfirmed, from (device)".
///  * [confirmed]: arrived on a private group (group key) or from a device
///    the user trusts: confirmed anywhere.
///  * [nws]: this phone read it from the NWS itself (a radio alert is
///    re-checked against the NWS once the phone is online and is upgraded
///    to this).
enum WxTrust {
  unconfirmed,
  confirmed,
  nws;

  static WxTrust byName(String? n) =>
      values.firstWhere((s) => s.name == n, orElse: () => WxTrust.nws);
}

/// What kind of product an alert is, from its event name.
enum WxKind { warning, watch, advisory, statement, marine, other }

/// NWS severity (CAP), lowest to highest.
enum WxSeverity {
  unknown,
  minor,
  moderate,
  severe,
  extreme;

  static WxSeverity parse(Object? s) => switch (s) {
    'Extreme' => WxSeverity.extreme,
    'Severe' => WxSeverity.severe,
    'Moderate' => WxSeverity.moderate,
    'Minor' => WxSeverity.minor,
    _ => WxSeverity.unknown,
  };
}

/// Marine products: not wanted on land (default settings).
const _marineEvents = {
  'Gale Warning',
  'Storm Warning',
  'Hurricane Force Wind Warning',
  'Freezing Spray Warning',
  'Heavy Freezing Spray Warning',
  'Hazardous Seas Warning',
};

/// Life-safety messages that are warnings in everything but the name.
const _emergencyEvents = {
  'Civil Emergency Message',
  'Evacuation - Immediate',
  'Local Area Emergency',
};

/// Event names that always count as extreme (sound allowed to break quiet
/// hours / DND when the switch is on), besides CAP severity "Extreme".
const _extremeEvents = {
  'Tornado Warning',
  'Extreme Wind Warning',
  'Tsunami Warning',
};

WxKind wxKindOf(String event) {
  if (event.contains('Marine') || _marineEvents.contains(event)) {
    return WxKind.marine;
  }
  if (event.endsWith(' Warning') || _emergencyEvents.contains(event)) {
    return WxKind.warning;
  }
  if (event.endsWith(' Watch')) return WxKind.watch;
  if (event.endsWith(' Advisory')) return WxKind.advisory;
  if (event.contains('Statement') || event.contains('Outlook')) {
    return WxKind.statement;
  }
  return WxKind.other;
}

/// Which kinds the phone keeps and notifies. Warnings only (v2.5.0 default).
/// A per-type picker is planned for a later polish stage; the type is
/// already a set so it needs no migration.
const Set<WxKind> kDefaultWxKinds = {WxKind.warning};

/// One weather alert.
class WxAlert {
  WxAlert({
    required this.key,
    required this.event,
    required this.issued,
    required this.rev,
    this.nwsId,
    this.severity = WxSeverity.unknown,
    this.urgency = '',
    this.headline = '',
    this.description = '',
    this.instruction = '',
    this.areaDesc = '',
    this.onset,
    this.expires,
    this.ends,
    this.ugc = const [],
    this.refs = const [],
    this.sender = '',
    this.messageType = 'alert',
    this.source = WxSource.nws,
    this.trust = WxTrust.nws,
    this.fromDevice = '',
    this.fromName = '',
    DateTime? firstSeen,
    this.notified = false,
  }) : firstSeen = firstSeen ?? issued;

  /// Dedupe key: the VTEC event (`vtec:KPQR.TO.W.0012.2026`) when the
  /// product has one, else the NWS id (`nws:urn:oid:...`). Every source
  /// (internet, relay, radio) must produce the same key for the same event.
  final String key;

  /// The NWS message id (changes with every update of the same event).
  final String? nwsId;
  final String event;
  final WxSeverity severity;
  final String urgency;
  final String headline;
  final String description;
  final String instruction;
  final String areaDesc;

  /// When it was sent / took effect.
  final DateTime issued;

  /// Ordering of updates of the same event (ms since epoch of `sent`).
  final int rev;
  final DateTime? onset;
  final DateTime? expires;
  final DateTime? ends;

  /// Zones it covers (UGC codes: `ORZ006`, `ORC051`).
  final List<String> ugc;

  /// Ids of the messages this one replaces.
  final List<String> refs;
  final String sender;

  /// `alert`, `update` or `cancel`.
  final String messageType;
  final WxSource source;

  /// How far it is to be believed (see [WxTrust]).
  final WxTrust trust;

  /// The device that sent it (its Ed25519 public key id), '' for the NWS
  /// read by this phone itself, and its name when known.
  final String fromDevice;
  final String fromName;

  /// When this phone first learned of it.
  final DateTime firstSeen;

  /// The phone already notified for it (so a restart never repeats it).
  bool notified;

  WxKind get kind => wxKindOf(event);

  /// Tornado Warnings and anything NWS rates Extreme.
  bool get isExtreme =>
      severity == WxSeverity.extreme || _extremeEvents.contains(event);

  bool get isCancel => messageType == 'cancel';

  /// When it stops counting (never null).
  DateTime get expiresAt =>
      ends ?? expires ?? issued.add(const Duration(hours: 6));

  bool activeAt(DateTime now) => now.isBefore(expiresAt);

  /// Small stable number for this alert's notification.
  int get notificationId {
    var h = 0x811C9DC5;
    for (final u in key.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0xFFFFFFFF;
    }
    return 8000000 + (h & 0xFFFFF);
  }

  WxAlert copyWith({
    WxSource? source,
    WxTrust? trust,
    bool? notified,
    DateTime? firstSeen,
    String? messageType,
  }) => WxAlert(
    key: key,
    nwsId: nwsId,
    event: event,
    severity: severity,
    urgency: urgency,
    headline: headline,
    description: description,
    instruction: instruction,
    areaDesc: areaDesc,
    issued: issued,
    rev: rev,
    onset: onset,
    expires: expires,
    ends: ends,
    ugc: ugc,
    refs: refs,
    sender: sender,
    messageType: messageType ?? this.messageType,
    source: source ?? this.source,
    trust: trust ?? this.trust,
    fromDevice: fromDevice,
    fromName: fromName,
    firstSeen: firstSeen ?? this.firstSeen,
    notified: notified ?? this.notified,
  );

  Map<String, Object?> toJson() => {
    'k': key,
    if (nwsId != null) 'id': nwsId,
    'ev': event,
    'sv': severity.name,
    if (urgency.isNotEmpty) 'ur': urgency,
    if (headline.isNotEmpty) 'h': headline,
    if (description.isNotEmpty) 'd': description,
    if (instruction.isNotEmpty) 'i': instruction,
    if (areaDesc.isNotEmpty) 'a': areaDesc,
    't': issued.millisecondsSinceEpoch,
    'r': rev,
    if (onset != null) 'on': onset!.millisecondsSinceEpoch,
    if (expires != null) 'ex': expires!.millisecondsSinceEpoch,
    if (ends != null) 'en': ends!.millisecondsSinceEpoch,
    if (ugc.isNotEmpty) 'z': ugc,
    if (refs.isNotEmpty) 'rf': refs,
    if (sender.isNotEmpty) 'by': sender,
    if (messageType != 'alert') 'mt': messageType,
    'src': source.name,
    if (trust != WxTrust.nws) 'tr': trust.name,
    if (fromDevice.isNotEmpty) 'dv': fromDevice,
    if (fromName.isNotEmpty) 'dn': fromName,
    'fs': firstSeen.millisecondsSinceEpoch,
    'nt': notified,
  };

  static WxAlert? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      DateTime? ms(Object? v) => v is num
          ? DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true)
          : null;
      final issued = ms(j['t']);
      final key = j['k'], ev = j['ev'];
      if (issued == null || key is! String || ev is! String) return null;
      List<String> strs(Object? v) => v is List
          ? [
              for (final x in v)
                if (x is String) x,
            ]
          : const [];
      return WxAlert(
        key: key,
        nwsId: j['id'] as String?,
        event: ev,
        severity: WxSeverity.values.firstWhere(
          (s) => s.name == j['sv'],
          orElse: () => WxSeverity.unknown,
        ),
        urgency: (j['ur'] as String?) ?? '',
        headline: (j['h'] as String?) ?? '',
        description: (j['d'] as String?) ?? '',
        instruction: (j['i'] as String?) ?? '',
        areaDesc: (j['a'] as String?) ?? '',
        issued: issued,
        rev: (j['r'] as num?)?.toInt() ?? issued.millisecondsSinceEpoch,
        onset: ms(j['on']),
        expires: ms(j['ex']),
        ends: ms(j['en']),
        ugc: strs(j['z']),
        refs: strs(j['rf']),
        sender: (j['by'] as String?) ?? '',
        messageType: (j['mt'] as String?) ?? 'alert',
        source: WxSource.byName(j['src'] as String?),
        trust: WxTrust.byName(j['tr'] as String?),
        fromDevice: (j['dv'] as String?) ?? '',
        fromName: (j['dn'] as String?) ?? '',
        firstSeen: ms(j['fs']),
        notified: j['nt'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// One alert from an NWS GeoJSON feature (`properties`), or null for
  /// tests / exercises / something unreadable.
  static WxAlert? fromNws(Object? feature) {
    if (feature is! Map) return null;
    final p = feature['properties'];
    if (p is! Map) return null;
    try {
      if ((p['status'] ?? 'Actual') != 'Actual') return null;
      final event = p['event'];
      if (event is! String || event.isEmpty) return null;
      final id = p['id'] as String? ?? feature['id'] as String?;
      DateTime? t(Object? v) =>
          v is String ? DateTime.tryParse(v)?.toUtc() : null;
      final sent = t(p['sent']) ?? t(p['effective']);
      if (sent == null) return null;
      // VTEC: /O.NEW.KPQR.TO.W.0012.261030T0912Z-261030T1000Z/
      String? vtec;
      var vtecAction = '';
      final params = p['parameters'];
      if (params is Map && params['VTEC'] is List) {
        for (final v in params['VTEC'] as List) {
          if (v is! String) continue;
          final parts = v.replaceAll('/', '').split('.');
          if (parts.length >= 6) {
            vtec = '${parts[2]}.${parts[3]}.${parts[4]}.${parts[5]}';
            vtecAction = parts[1];
            break;
          }
        }
      }
      if (vtec == null && id == null) return null;
      final key = vtec != null ? 'vtec:$vtec.${sent.year}' : 'nws:$id';
      final geo = p['geocode'];
      final refs = <String>[
        if (p['references'] is List)
          for (final r in p['references'] as List)
            if (r is Map && r['identifier'] is String)
              r['identifier'] as String,
      ];
      var type = switch (p['messageType']) {
        'Cancel' => 'cancel',
        'Update' => 'update',
        _ => 'alert',
      };
      // VTEC CAN / EXP end the event even when the message type is Update.
      if (vtecAction == 'CAN' || vtecAction == 'EXP') type = 'cancel';
      return WxAlert(
        key: key,
        nwsId: id,
        event: event,
        severity: WxSeverity.parse(p['severity']),
        urgency: (p['urgency'] as String?) ?? '',
        headline: _clean(p['headline']),
        description: _clean(p['description']),
        instruction: _clean(p['instruction']),
        areaDesc: _clean(p['areaDesc']),
        issued: sent,
        rev: sent.millisecondsSinceEpoch,
        onset: t(p['onset']),
        expires: t(p['expires']),
        ends: t(p['ends']),
        ugc: [
          if (geo is Map && geo['UGC'] is List)
            for (final z in geo['UGC'] as List)
              if (z is String) z,
        ],
        refs: refs,
        sender: _clean(p['senderName']),
        messageType: type,
      );
    } catch (_) {
      return null;
    }
  }

  static String _clean(Object? s) =>
      s is String ? s.replaceAll('\r', '').trim() : '';

  /// NWS text is hard-wrapped at about 65 columns: join the lines of a
  /// paragraph, keep paragraph breaks.
  static String unwrap(String s) => s
      .split(RegExp(r'\n\s*\n'))
      .map((para) => para.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim())
      .where((p) => p.isNotEmpty)
      .join('\n\n');

  @override
  String toString() => 'WxAlert($key $event)';
}

/// The alerts out of an `/alerts/active` answer; null when it is not a
/// feature collection (an error page, not "no alerts").
List<WxAlert>? parseNwsAlerts(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map || j['features'] is! List) return null;
    return [for (final f in j['features'] as List) ?WxAlert.fromNws(f)];
  } catch (_) {
    return null;
  }
}
