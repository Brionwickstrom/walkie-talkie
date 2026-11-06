import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../lora/meshtastic_session.dart';
import '../trip/geo.dart';
import 'radios_nearby_page.dart' show radioAgo, radioNodeId;

/// Show public nodes (v2.6.4) with names (v2.6.5): the public Meshtastic
/// radios our own radio has heard on its listen-only public LongFast
/// channel. Only what the radio already sent us is used: nothing is
/// transmitted to fill the list (no pings, no NodeInfo, position or
/// traceroute requests). Names come from NodeInfo / User packets the
/// radio already decoded with the default public key; they are sanitized
/// for display. Locations are never shown (distance only).

/// One public radio in the list.
class PublicNode {
  const PublicNode({
    required this.num,
    this.longName = '',
    this.shortName = '',
    this.lastHeard,
    this.snr,
    this.rssi,
    this.hops,
    this.distanceM,
  });
  final int num;

  /// Sanitized long name, empty when unknown or stripped.
  final String longName;

  /// Sanitized short name, empty when unknown or stripped.
  final String shortName;
  final DateTime? lastHeard;
  final double? snr;
  final int? rssi;

  /// 0 = heard directly.
  final int? hops;
  final double? distanceM;

  bool get hasName => longName.isNotEmpty;

  /// "!1a2b3c4d" (always shown, smaller when a name is known).
  String get idLabel => radioNodeId(num);

  /// Name (and short name), or "Public radio !id" when unknown.
  String get label {
    if (!hasName) return 'Public radio $idLabel';
    if (shortName.isEmpty || shortName == longName) return longName;
    return '$longName ($shortName)';
  }
}

/// What the "Show public nodes" section shows.
class PublicNodes {
  const PublicNodes({
    this.connected = false,
    this.listening = false,
    this.onPublicSlot = false,
    this.nodes = const [],
    this.more = 0,
  });

  /// A radio is connected.
  final bool connected;

  /// The radio has the listen-only public channel.
  final bool listening;

  /// The radio is on the public frequency ("Relay through public radios"
  /// on), so it can hear public radios at all.
  final bool onPublicSlot;

  /// Most recently heard first, at most [publicNodesShown].
  final List<PublicNode> nodes;

  /// Heard but not listed (past [publicNodesShown]).
  final int more;

  int get total => nodes.length + more;
}

/// Rows listed at most (the radio's own node list holds a few hundred).
const int publicNodesShown = 25;

/// Long-name byte budget (Meshtastic User.long_name).
const int publicLongNameMaxBytes = 39;

/// Short-name byte budget (Meshtastic User.short_name).
const int publicShortNameMaxBytes = 4;

/// Strip control characters and length-limit an untrusted public name.
/// Empty when nothing usable remains. Does not send or request anything.
String sanitizePublicName(String raw, {int maxBytes = publicLongNameMaxBytes}) {
  if (raw.isEmpty || maxBytes <= 0) return '';
  final buf = StringBuffer();
  for (final r in raw.runes) {
    if (r < 0x20 || r == 0x7F || (r >= 0x80 && r < 0xA0)) continue;
    buf.writeCharCode(r);
  }
  var t = buf.toString().trim();
  if (t.isEmpty) return '';
  // Collapse runs of whitespace to a single space.
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  var bytes = utf8.encode(t);
  if (bytes.length <= maxBytes) return t;
  // Drop trailing runes until it fits the byte budget.
  final runes = t.runes.toList();
  while (runes.isNotEmpty && bytes.length > maxBytes) {
    runes.removeLast();
    t = String.fromCharCodes(runes).trimRight();
    bytes = utf8.encode(t);
  }
  return t;
}

/// Build the list from the radio session. Pure: the page and the tests
/// call it; it reads only what is already in memory.
PublicNodes computePublicNodes({
  required MeshtasticSession? session,
  required bool onPublicSlot,
  GeoPoint? phone,
  int max = publicNodesShown,
}) {
  if (session == null) return const PublicNodes();
  final pub = session.publicListenIndex;
  if (pub == null) {
    return PublicNodes(connected: true, onPublicSlot: onPublicSlot);
  }
  final me = session.myNodeNum;
  final own = me == null ? null : session.nodes[me];
  GeoPoint? ownPos;
  if (own?.lat != null && own?.lng != null) {
    ownPos = GeoPoint(own!.lat!, own.lng!);
  }
  ownPos ??= phone;
  final all = <PublicNode>[];
  for (final n in session.nodes.values) {
    if (!session.isPublicNode(n)) continue;
    final pos = n.lat != null && n.lng != null && !(n.lat == 0 && n.lng == 0)
        ? GeoPoint(n.lat!, n.lng!)
        : null;
    all.add(
      PublicNode(
        num: n.num,
        longName: sanitizePublicName(n.longName),
        shortName: sanitizePublicName(
          n.shortName,
          maxBytes: publicShortNameMaxBytes,
        ),
        lastHeard: n.lastHeard,
        snr: n.snr == 0 ? null : n.snr,
        rssi: n.rssi == 0 ? null : n.rssi,
        hops: n.hopsAway,
        distanceM: pos != null && ownPos != null
            ? distanceM(ownPos, pos)
            : null,
      ),
    );
  }
  all.sort((a, b) {
    final x = a.lastHeard, y = b.lastHeard;
    if (x == null && y == null) return a.num.compareTo(b.num);
    if (x == null) return 1;
    if (y == null) return -1;
    final c = y.compareTo(x);
    return c != 0 ? c : a.num.compareTo(b.num);
  });
  final shown = all.length > max ? all.sublist(0, max) : all;
  return PublicNodes(
    connected: true,
    listening: true,
    onPublicSlot: onPublicSlot,
    nodes: shown,
    more: all.length - shown.length,
  );
}

/// "heard 5 min ago · SNR 6.5 dB · RSSI -92 dBm · 2 hops · 3.2 mi". What
/// the radio did not report is said as unknown, so every row has signal,
/// hops and distance.
String publicNodeLine(PublicNode n, {DateTime? now, bool imperial = true}) {
  final parts = <String>[];
  final t = n.lastHeard;
  if (t != null) {
    parts.add('heard ${radioAgo((now ?? DateTime.now()).difference(t))}');
  }
  final sig = [
    if (n.snr != null) 'SNR ${n.snr!.toStringAsFixed(1)} dB',
    if (n.rssi != null) 'RSSI ${n.rssi} dBm',
  ];
  parts.add(sig.isEmpty ? 'signal unknown' : sig.join(' · '));
  final h = n.hops;
  parts.add(
    h == null
        ? 'hops unknown'
        : h == 0
        ? 'direct'
        : '$h hop${h == 1 ? '' : 's'}',
  );
  final d = n.distanceM;
  parts.add(
    d == null ? 'distance unknown' : formatDistance(d, imperial: imperial),
  );
  return parts.join(' · ');
}

/// The plain state line above the list.
String publicNodesStateText(PublicNodes p) {
  if (!p.connected) return 'Connect your radio to see public radios.';
  if (!p.listening) return 'Off. Public radios are not listed.';
  if (!p.onPublicSlot) {
    return 'On, but your radio is not on the public frequency, so it hears '
        'no public radios. Turn on "Use the public frequency" above to hear '
        'them.';
  }
  if (p.total == 0) {
    return 'Listening. No public radios heard yet. Radios in reach show up '
        'when they next send something, which can take a while.';
  }
  return 'Public radios heard: ${p.total}';
}

/// The list, redrawn at most every [every] while it is on screen (the
/// radio can report many packets; nothing is redrawn while it is closed).
class PublicNodesList extends StatefulWidget {
  const PublicNodesList({
    super.key,
    required this.session,
    required this.build,
    this.every = const Duration(seconds: 5),
  });
  final MeshtasticSession? session;
  final Widget Function(BuildContext context) build;
  final Duration every;

  @override
  State<PublicNodesList> createState() => _PublicNodesListState();
}

class _PublicNodesListState extends State<PublicNodesList> {
  StreamSubscription<void>? _sub;
  Timer? _later;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(PublicNodesList old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, widget.session)) _follow();
  }

  void _follow() {
    _sub?.cancel();
    _sub = widget.session?.changes.listen((_) => _changed());
  }

  void _changed() {
    if (!mounted || _later != null) return;
    final wait = widget.every - DateTime.now().difference(_last);
    if (wait <= Duration.zero) {
      _redraw();
    } else {
      _later = Timer(wait, () {
        _later = null;
        _redraw();
      });
    }
  }

  void _redraw() {
    if (!mounted) return;
    _last = DateTime.now();
    setState(() {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _later?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.build(context);
}
