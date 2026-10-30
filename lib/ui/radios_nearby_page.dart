import 'dart:async';

import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../core/transport_manager.dart';
import '../lora/lora_transport.dart';
import '../lora/meshtastic_channels.dart';
import '../lora/meshtastic_proto.dart';
import '../lora/meshtastic_session.dart';
import '../trip/geo.dart';
import 'adaptive_layout.dart';
import 'reach.dart';
import 'reach_of.dart';

/// Radios nearby (v2.4.2): the Meshtastic radios our own radio already
/// knows about, from data it has already sent us. Nothing is transmitted to
/// make this list: no pings, no NodeInfo or position requests, no
/// traceroute, no public channel. The page rebuilds only while it is open.

/// "just now", "5 min ago", "2 h ago", "3 d ago".
String radioAgo(Duration d) {
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// "!1a2b3c4d", how Meshtastic writes a node number.
String radioNodeId(int num) => '!${num.toRadixString(16).padLeft(8, '0')}';

/// The channel a radio was heard on: a Walkie channel (open or private
/// group, with the app's lock and colour), or the radio channel's own name.
class RadioChannelLabel {
  const RadioChannelLabel({this.reach, this.text = ''});

  /// Walkie channel or group, null for another radio channel.
  final Reach? reach;

  /// The radio channel's name ("LongFast (Meshtastic default)"), '' if the
  /// slot is not known.
  final String text;

  bool get isEmpty => reach == null && text.isEmpty;
}

class NearbyRadio {
  NearbyRadio({
    required this.num,
    required this.name,
    this.shortName = '',
    this.walkieName,
    this.lastHeard,
    this.snr,
    this.rssi,
    this.hops,
    this.battery,
    this.distanceM,
    this.channel = const RadioChannelLabel(),
    this.hardware,
    this.role,
  });
  final int num;

  /// Long name, else the Walkie name, else "!1a2b3c4d".
  final String name;
  final String shortName;

  /// Set when this radio is a phone running Walkie we have heard.
  final String? walkieName;
  final DateTime? lastHeard;
  final double? snr;
  final int? rssi;

  /// 0 = heard directly.
  final int? hops;

  /// Percent, 101 = powered.
  final int? battery;
  final double? distanceM;
  final RadioChannelLabel channel;
  final String? hardware;
  final String? role;
}

class RadiosNearby {
  RadiosNearby({
    this.connected = false,
    this.mine,
    this.radios = const [],
    this.unreadable = 0,
  });

  /// A radio is paired and its session is running.
  final bool connected;

  /// Our own radio (the "This radio" header).
  final NearbyRadio? mine;
  final List<NearbyRadio> radios;

  /// Nodes known only as a number and a signal (another channel).
  final int unreadable;
}

/// Build the list from what the radio session and the LoRa transport already
/// hold. Pure: the page, the tests and nothing else call it.
RadiosNearby computeRadiosNearby({
  required MeshtasticSession? session,
  required Map<int, LoraPeerSignal> signals,
  required String Function(int walkieId) walkieName,
  required Reach? Function(MeshChannelRef ref) openByLink,
  required Reach? Function(int tag) groupByTag,
  required Reach? Function(int channel) openByNumber,
  GeoPoint? phone,
}) {
  if (session == null) return RadiosNearby();
  final me = session.myNodeNum;
  final own = me == null ? null : session.nodes[me];
  GeoPoint? ownPos;
  if (own?.lat != null && own?.lng != null) {
    ownPos = GeoPoint(own!.lat!, own.lng!);
  }
  ownPos ??= phone;

  // Walkie phones heard over the radio, by their radio's node number.
  final walkie = <int, MapEntry<int, LoraPeerSignal>>{};
  for (final e in signals.entries) {
    final w = walkie[e.value.node];
    if (w == null || e.value.at.isAfter(w.value.at)) {
      walkie[e.value.node] = e;
    }
  }

  RadioChannelLabel channelOf(RadioNode n, LoraPeerSignal? sig) {
    Reach? r;
    if (sig != null) {
      if (sig.sealed) {
        r = groupByTag(sig.frameChannel);
      } else if (sig.frameChannel >= 1 && sig.frameChannel <= 16) {
        r = openByNumber(sig.frameChannel);
      }
    }
    if (r != null) return RadioChannelLabel(reach: r);
    final slot = n.channel;
    final rc = slot == null ? null : session.channels[slot];
    if (rc == null || rc.isDisabled) return const RadioChannelLabel();
    r = openByLink(session.refOf(rc));
    if (r != null) return RadioChannelLabel(reach: r);
    final name = rc.effectiveName(session.presetDisplayName);
    final suffix = switch (rc.keyKind) {
      MeshKeyKind.defaultPublic => ' (Meshtastic default)',
      MeshKeyKind.none => ' (no encryption)',
      _ => '',
    };
    return RadioChannelLabel(text: '$name$suffix');
  }

  NearbyRadio build(RadioNode n, {required bool mine}) {
    final w = walkie[n.num];
    final wName = w == null ? null : walkieName(w.key);
    final pos = n.lat != null && n.lng != null
        ? GeoPoint(n.lat!, n.lng!)
        : null;
    final hw = n.hwModel == 0 ? null : meshHardwareName(n.hwModel);
    return NearbyRadio(
      num: n.num,
      name: n.longName.isNotEmpty
          ? n.longName
          : (wName != null && wName.isNotEmpty ? wName : radioNodeId(n.num)),
      shortName: n.shortName,
      walkieName: wName,
      lastHeard: n.lastHeard,
      snr: n.snr == 0 ? null : n.snr,
      rssi: n.rssi != 0
          ? n.rssi
          : (w != null && w.value.rssi != 0 ? w.value.rssi : null),
      hops: n.hopsAway,
      battery: n.battery,
      distanceM: !mine && pos != null && ownPos != null
          ? distanceM(ownPos, pos)
          : null,
      channel: mine ? const RadioChannelLabel() : channelOf(n, w?.value),
      hardware: hw,
      role: meshRoleName(n.role),
    );
  }

  final list = <NearbyRadio>[];
  var unreadable = 0;
  for (final n in session.nodes.values) {
    if (n.num == me) continue;
    if (!n.readable) {
      unreadable++;
      continue;
    }
    list.add(build(n, mine: false));
  }
  list.sort((a, b) {
    final x = a.lastHeard, y = b.lastHeard;
    if (x == null && y == null) {
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    if (x == null) return 1;
    if (y == null) return -1;
    final c = y.compareTo(x);
    return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return RadiosNearby(
    connected: true,
    mine: own == null ? null : build(own, mine: true),
    radios: list,
    unreadable: unreadable,
  );
}

/// [computeRadiosNearby] from the controller's own data.
RadiosNearby radiosNearbyOf(WalkieController c) => computeRadiosNearby(
  session: c.radioDevice.session,
  signals: c.loraTransport.peerSignals,
  walkieName: c.nameOf,
  openByLink: (ref) {
    final ch = c.walkieChannelFor(ref);
    return ch == null ? null : c.reachOfScope(ch);
  },
  groupByTag: (tag) {
    final scope = TransportManager.privateScopeBit | tag;
    return c.groupForScope(scope) == null ? null : c.reachOfScope(scope);
  },
  openByNumber: c.reachOfScope,
  phone: c.trip?.myFix?.pos,
);

/// The signal line: "heard 5 min ago · SNR 6.5 dB · RSSI -92 dBm · direct ·
/// battery 80% · 3.2 km".
String nearbyRadioLine(NearbyRadio r, {DateTime? now, bool imperial = true}) {
  final parts = <String>[];
  final t = r.lastHeard;
  if (t != null) {
    parts.add('heard ${radioAgo((now ?? DateTime.now()).difference(t))}');
  }
  if (r.snr != null) parts.add('SNR ${r.snr!.toStringAsFixed(1)} dB');
  if (r.rssi != null) parts.add('RSSI ${r.rssi} dBm');
  final h = r.hops;
  if (h != null) parts.add(h == 0 ? 'direct' : '$h hop${h == 1 ? '' : 's'}');
  final b = r.battery;
  if (b != null) parts.add(b > 100 ? 'powered' : 'battery $b%');
  final d = r.distanceM;
  if (d != null) parts.add(formatDistance(d, imperial: imperial));
  return parts.join(' · ');
}

/// Open Radios nearby: a page on phones, a dialog on wide screens.
Future<void> openRadiosNearby(BuildContext context, WalkieController c) {
  final size = MediaQuery.sizeOf(context);
  if (isTwoPane(size.width, size.height)) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const Key('radios-dialog'),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: RadiosNearbyPage(controller: c, dialog: true),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => RadiosNearbyPage(controller: c)),
  );
}

class RadiosNearbyPage extends StatefulWidget {
  const RadiosNearbyPage({
    super.key,
    required this.controller,
    this.dialog = false,
  });
  final WalkieController controller;
  final bool dialog;

  @override
  State<RadiosNearbyPage> createState() => _RadiosNearbyPageState();
}

class _RadiosNearbyPageState extends State<RadiosNearbyPage> {
  WalkieController get c => widget.controller;
  MeshtasticSession? _session;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
    _follow();
  }

  /// Rebuild when the radio reports something (only while this page is
  /// open): nothing is requested, this just redraws what already arrived.
  void _follow() {
    final s = c.radioDevice.session;
    if (identical(s, _session)) return;
    _sub?.cancel();
    _session = s;
    _sub = s?.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _onController() {
    if (!mounted) return;
    _follow();
    setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = radiosNearbyOf(c);
    final theme = Theme.of(context);
    final imperial = c.trip?.settings.imperial ?? true;
    final now = DateTime.now();
    final children = <Widget>[];
    if (!data.connected) {
      children.add(const _Note('Connect your radio to see radios nearby.'));
    } else {
      final mine = data.mine;
      if (mine != null) {
        children.add(_ThisRadio(mine));
      }
      if (data.radios.isEmpty && data.unreadable == 0) {
        children.add(const _Note('No other radios heard yet.'));
      }
      for (final r in data.radios) {
        children.add(
          _RadioTile(
            r,
            line: nearbyRadioLine(r, now: now, imperial: imperial),
          ),
        );
      }
      if (data.unreadable > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              "Other channel, can't read: ${data.unreadable}",
              key: const Key('radios-unreadable'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
    }
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.dialog,
        leading: widget.dialog
            ? IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        title: const Text('Radios nearby'),
      ),
      body: SafeArea(
        child: ListView(key: const Key('radios-list'), children: children),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(text, key: const Key('radios-empty')),
  );
}

class _ThisRadio extends StatelessWidget {
  const _ThisRadio(this.r);
  final NearbyRadio r;

  @override
  Widget build(BuildContext context) {
    final b = r.battery;
    return ListTile(
      key: const Key('radios-this'),
      dense: true,
      leading: const Icon(Icons.settings_input_antenna),
      title: Text('This radio · ${r.name}'),
      subtitle: b == null ? null : Text(b > 100 ? 'powered' : 'battery $b%'),
    );
  }
}

class _RadioTile extends StatelessWidget {
  const _RadioTile(this.r, {required this.line});
  final NearbyRadio r;
  final String line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final extra = [?r.hardware, ?r.role].join(' · ');
    final ch = r.channel;
    return ListTile(
      key: Key('radio-${r.num}'),
      leading: Icon(
        r.walkieName != null ? Icons.directions_walk : Icons.cell_tower,
        color: r.walkieName != null ? cs.primary : cs.outline,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              r.shortName.isEmpty || r.shortName == r.name
                  ? r.name
                  : '${r.name} (${r.shortName})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (r.walkieName != null) ...[
            const SizedBox(width: 8),
            Container(
              key: Key('radio-walkie-${r.num}'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                r.walkieName == r.name || r.walkieName!.isEmpty
                    ? 'Stalkie'
                    : 'Stalkie · ${r.walkieName}',
                style: small?.copyWith(color: cs.onPrimaryContainer),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.isNotEmpty) Text(line),
          if (!ch.isEmpty || extra.isNotEmpty)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (ch.reach != null)
                  ReachTag(ch.reach!, key: Key('radio-channel-${r.num}'))
                else if (ch.text.isNotEmpty)
                  Row(
                    key: Key('radio-channel-${r.num}'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cell_tower, size: 13, color: cs.outline),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          ch.text,
                          style: small?.copyWith(color: cs.outline),
                        ),
                      ),
                    ],
                  ),
                if (extra.isNotEmpty)
                  Text(extra, style: small?.copyWith(color: cs.outline)),
              ],
            ),
        ],
      ),
    );
  }
}
