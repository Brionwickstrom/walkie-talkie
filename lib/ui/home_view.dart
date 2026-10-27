import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/link_settings.dart';
import '../app/people_refresh.dart';
import '../core/transport.dart';
import 'people_refresh_view.dart';

/// One row in the people list (presentation only, no controller).
class PersonView {
  const PersonView({
    required this.id,
    required this.name,
    this.me = false,
    this.talking = false,
    this.left = false,
    this.links = const [],
    this.active,
    this.lastHeard,
    this.elsewhere,
    this.ringStatus,
    this.debug,
    this.volume = 1.0,
    this.hops,
    this.distance,
    this.arrowDeg,
    this.battery,
    this.path,
    this.gateway,
  });

  final int id;

  /// "Home gateway" when only a LoRa gateway reaches this phone (v1.9.5),
  /// shown as "via Home gateway (LoRa)".
  final String? gateway;

  /// "Direct" when [active] is the internet and the phone is reached over
  /// a direct link (v1.8.9), else null.
  final String? path;

  /// Their phone battery 0..100 (v1.8.3), null = unknown.
  final int? battery;

  /// Trip: "0.8 mi NE" from my GPS fix to theirs, else null.
  final String? distance;

  /// Trip: compass arrow angle towards them (0 = up), else null.
  final double? arrowDeg;

  /// Reachable only through other phones (mesh relay): radio hops, else
  /// null.
  final int? hops;

  /// Playback volume set for this person (1 = 100 %).
  final double volume;
  final String name;
  final bool me;
  final bool talking;

  /// Dropped off recently (shown greyed out for ~30 s).
  final bool left;
  final List<TransportKind> links;
  final TransportKind? active;

  /// Time since we last heard them (or since they left).
  final Duration? lastHeard;

  /// "On CH 4" when they are on another channel; null = on ours.
  final String? elsewhere;
  final String? ringStatus;

  /// Diagnostics line, only shown with Details on.
  final String? debug;

  bool get here => !left && elsewhere == null;
}

IconData transportIcon(TransportKind k) => switch (k) {
  TransportKind.lan => Icons.wifi,
  TransportKind.wifiDirect => Icons.wifi_tethering,
  TransportKind.ble => Icons.bluetooth,
  TransportKind.internet => Icons.public,
  TransportKind.lora => Icons.settings_input_antenna,
};

String transportName(TransportKind k) => switch (k) {
  TransportKind.lan => 'Wi-Fi',
  TransportKind.wifiDirect => 'Wi-Fi Direct',
  TransportKind.ble => 'Bluetooth',
  TransportKind.internet => 'Internet',
  TransportKind.lora => 'LoRa radio',
};

/// The Cell / mobile data icon (v1.8.6): bars when the level is known.
IconData cellIcon(CellState s, int? level) => switch (s) {
  CellState.off || CellState.saver => Icons.signal_cellular_off,
  CellState.blocked => Icons.signal_cellular_connected_no_internet_4_bar,
  CellState.unknown => Icons.signal_cellular_alt,
  _ => switch (level) {
    0 => Icons.signal_cellular_0_bar,
    1 => Icons.signal_cellular_alt_1_bar,
    2 => Icons.signal_cellular_alt_2_bar,
    _ => Icons.signal_cellular_alt,
  },
};

/// Green = the relay is on mobile data, blue = available, amber =
/// blocked, grey = off / Offline power save / unknown (like other icons).
Color cellColor(CellState s) => switch (s) {
  CellState.active => Colors.green,
  CellState.available => Colors.blueGrey,
  CellState.blocked => Colors.orange,
  _ => Colors.grey,
};

String cellTooltip(CellState s) => switch (s) {
  CellState.active => 'Mobile data: in use',
  CellState.available => 'Mobile data: available',
  CellState.blocked => 'Mobile data: not reaching the relay',
  CellState.off => 'Mobile data: no service',
  CellState.saver => 'Mobile data: off (Offline power save)',
  CellState.unknown => 'Mobile data',
};

/// Stable, pleasant color per phone id.
Color avatarColor(int id) {
  final hue = (id * 137.508) % 360;
  return HSLColor.fromAHSL(1, hue, 0.55, 0.45).toColor();
}

String initials(String name) {
  final words = name
      .split(RegExp(r'[\s\-_]+'))
      .where((w) => w.isNotEmpty && RegExp(r'[A-Za-z0-9]').hasMatch(w[0]))
      .toList();
  if (words.isEmpty) return name.isEmpty ? '?' : name[0].toUpperCase();
  if (words.length == 1) {
    final w = words.first;
    return (w.length > 1 ? w.substring(0, 2) : w).toUpperCase();
  }
  return (words[0][0] + words[1][0]).toUpperCase();
}

String agoText(Duration d) {
  final s = d.inSeconds;
  if (s < 2) return 'just now';
  if (s < 60) return '${s}s ago';
  return '${d.inMinutes}m ago';
}

/// A recorded transmission in the "recent" strip / History (presentation).
class TakeView {
  const TakeView({
    required this.id,
    required this.sender,
    required this.name,
    required this.at,
    required this.durationMs,
    this.mine = false,
    this.heard = true,
    this.playing = false,
    this.positionMs = 0,
    this.hops = 1,
  });
  final int id;

  /// Radio hops the talk travelled (2+ = relayed by other phones).
  final int hops;
  final int sender;
  final String name;
  final DateTime at;
  final int durationMs;
  final bool mine;
  final bool heard;
  final bool playing;
  final int positionMs;

  String get who => mine ? 'You' : name;
}

/// "via 2 hops" (relayed through other phones).
String hopsText(int hops) => 'via $hops hops';

/// A phone only a LoRa gateway reaches (v1.9.5).
String gatewayText(String gateway) => 'via $gateway (LoRa)';

/// "0:07"
String clipLength(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// "14:05" today, "Mon 09:12" otherwise.
String clockText(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final hm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == n.year && t.month == n.month && t.day == n.day) return hm;
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${days[t.weekday - 1]} $hm';
}

/// Last few transmissions on this channel, one tap to replay; "Missed"
/// plays everything not heard yet; History opens the full list.
class RecentStrip extends StatelessWidget {
  const RecentStrip({
    super.key,
    required this.takes,
    required this.unheard,
    required this.onPlay,
    required this.onPlayMissed,
    required this.onOpenHistory,
  });
  final List<TakeView> takes;
  final int unheard;
  final ValueChanged<TakeView> onPlay;
  final VoidCallback onPlayMissed;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            key: const Key('open-history'),
            tooltip: 'History: replay what was said',
            icon: Badge(
              isLabelVisible: unheard > 0,
              label: Text('$unheard'),
              child: const Icon(Icons.history),
            ),
            onPressed: onOpenHistory,
          ),
          if (unheard > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: const Icon(Icons.playlist_play, size: 18),
                label: const Text('Missed'),
                onPressed: onPlayMissed,
              ),
            ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(right: 8),
              itemCount: takes.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final t = takes[i];
                return ActionChip(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  backgroundColor: t.playing ? cs.primaryContainer : null,
                  avatar: Icon(
                    t.playing ? Icons.pause : Icons.play_arrow,
                    size: 18,
                    color: !t.heard ? cs.primary : null,
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            t.who,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: t.heard
                                  ? FontWeight.normal
                                  : FontWeight.bold,
                            ),
                          ),
                        ),
                        Text(
                          ' · ${clipLength(t.durationMs)}'
                          '${t.hops > 1 ? ' · ${t.hops} hops' : ''}',
                        ),
                      ],
                    ),
                  ),
                  onPressed: () => onPlay(t),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The whole home screen below the app bar.
class HomeBody extends StatelessWidget {
  const HomeBody({
    super.key,
    this.banners = const [],
    required this.links,
    required this.internet,
    required this.showDetails,
    required this.onToggleDetails,
    this.details = const [],
    required this.channelLabel,
    this.isPrivate = false,
    this.listenerWarning,
    required this.me,
    required this.people,
    required this.onRing,
    required this.onBeep,
    required this.onMessage,
    this.onVolume,
    this.notice,
    this.onEditMe,
    this.error,
    this.queued,
    this.recent,
    this.headerAction,
    this.onRefresh,
    this.radioAvailable,
    this.onLinkTap,
    this.mobileDataHint = false,
    this.cell,
    this.cellLevel,
    this.onCellTap,
    this.alone,
    this.onConnectionTest,
    this.onAloneFix,
    required this.actions,
    required this.ptt,
  });

  /// Pull-to-refresh / the refresh button on the people list (v1.8.5).
  final Future<RefreshResult> Function({required bool radio})? onRefresh;

  /// Offer "Also ask over radio (slow)" after a refresh.
  final bool Function()? radioAvailable;

  /// Connection icon tapped (v1.8.5).
  final ValueChanged<TransportKind>? onLinkTap;
  final bool mobileDataHint;

  /// The Cell icon (v1.8.6).
  final CellState? cell;
  final int? cellLevel;
  final VoidCallback? onCellTap;

  /// Why nobody shows up over the internet (empty list only, v1.8.7).
  final AloneReason? alone;

  /// "Connection test" under the alone reason (v1.8.7).
  final VoidCallback? onConnectionTest;
  final ValueChanged<PhoneSetting>? onAloneFix;

  /// Trailing button on the "N on CH 3" header (Who's where).
  final Widget? headerAction;

  /// The "recent talk" strip (replay), or null when there is none.
  final Widget? recent;

  final List<Widget> banners;
  final List<(TransportKind, TransportStatus)> links;
  final ({TransportStatus status, String text}) internet;
  final bool showDetails;
  final ValueChanged<bool> onToggleDetails;
  final List<String> details;
  final String channelLabel;
  final bool isPrivate;

  /// "Unknown listener" warning under the header (v1.9.4), or null.
  final Widget? listenerWarning;
  final PersonView me;
  final List<PersonView> people;
  final ValueChanged<PersonView> onRing;
  final ValueChanged<PersonView> onBeep;
  final ValueChanged<PersonView> onMessage;

  /// Long-press on a person: volume slider etc.
  final ValueChanged<PersonView>? onVolume;

  /// e.g. the "media volume is low" hint.
  final Widget? notice;
  final VoidCallback? onEditMe;
  final String? error;
  final Widget? queued;
  final Widget actions;
  final Widget ptt;

  @override
  Widget build(BuildContext context) {
    final here = people.where((p) => p.here).length + 1;
    final theme = Theme.of(context);
    // Edge to edge (Android 15+): keep the talk button above the
    // navigation bar and nothing under the status bar.
    return SafeArea(
      child: Column(
        children: [
          ...banners,
          StatusRow(
            links: links,
            internet: internet,
            showDetails: showDetails,
            onToggleDetails: onToggleDetails,
            onLinkTap: onLinkTap,
            mobileDataHint: mobileDataHint,
            cell: cell,
            cellLevel: cellLevel,
            onCellTap: onCellTap,
          ),
          if (showDetails && details.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SelectableText(
                  details.join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ?notice,
          ?recent,
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Expanded(
            child: PeopleRefreshScope(
              refresh: onRefresh,
              radioAvailable: radioAvailable,
              builder: (context, refreshButton) => ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.groups,
                          size: 22,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$here on $channelLabel',
                            key: const Key('people-count'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (isPrivate)
                          Icon(
                            Icons.lock,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ?refreshButton,
                        ?headerAction,
                      ],
                    ),
                  ),
                  ?listenerWarning,
                  PersonCard(person: me, onEdit: onEditMe),
                  if (people.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 24,
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.person_search,
                            size: 40,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Nobody on $channelLabel yet.\nOthers will appear '
                            'here automatically.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Same Wi-Fi, Bluetooth nearby or the internet all '
                            'work. Voice messages you record now are delivered '
                            'when someone shows up.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                          if (alone != null) ...[
                            const SizedBox(height: 10),
                            Card(
                              key: const Key('alone-reason'),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  children: [
                                    Text(
                                      alone!.text,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                    if (alone!.fix != null &&
                                        onAloneFix != null)
                                      TextButton(
                                        key: const Key('alone-fix'),
                                        onPressed: () =>
                                            onAloneFix!(alone!.fix!),
                                        child: const Text(
                                          'Open phone settings',
                                        ),
                                      ),
                                    if (onConnectionTest != null)
                                      TextButton.icon(
                                        key: const Key('alone-test'),
                                        icon: const Icon(Icons.network_check),
                                        onPressed: onConnectionTest,
                                        label: const Text('Connection test'),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  for (final p in people)
                    PersonCard(
                      person: p,
                      showDebug: showDetails,
                      onRing: () => onRing(p),
                      onBeep: () => onBeep(p),
                      onMessage: () => onMessage(p),
                      onLongPress: onVolume == null ? null : () => onVolume!(p),
                    ),
                ],
              ),
            ),
          ),
          ?queued,
          actions,
          const SizedBox(height: 6),
          ptt,
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// Small link icons + "Internet: connected via Wi-Fi" + Details toggle.
class StatusRow extends StatelessWidget {
  const StatusRow({
    super.key,
    required this.links,
    required this.internet,
    required this.showDetails,
    required this.onToggleDetails,
    this.onLinkTap,
    this.mobileDataHint = false,
    this.cell,
    this.cellLevel,
    this.onCellTap,
  });
  final List<(TransportKind, TransportStatus)> links;

  /// The Cell / mobile data icon (v1.8.6), null = not shown.
  final CellState? cell;
  final int? cellLevel;
  final VoidCallback? onCellTap;
  final ({TransportStatus status, String text}) internet;
  final bool showDetails;
  final ValueChanged<bool> onToggleDetails;

  /// Tap on a connection icon (or the internet line): the connection
  /// sheet with its status and a settings button (v1.8.5).
  final ValueChanged<TransportKind>? onLinkTap;

  /// Show "Allow mobile data" (on mobile data, relay unreachable).
  final bool mobileDataHint;

  Widget _cellIcon() {
    final c = cell!;
    return Tooltip(
      message: cellTooltip(c),
      child: InkWell(
        key: const Key('link-cell'),
        customBorder: const CircleBorder(),
        onTap: onCellTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(3, 4, 3, 4),
          child: Icon(cellIcon(c, cellLevel), size: 18, color: cellColor(c)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final netColor = switch (internet.status) {
      TransportStatus.running => Colors.green,
      TransportStatus.starting => Colors.orange,
      _ => Colors.redAccent,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 0, 0),
      child: Row(
        children: [
          for (final (k, s) in links) ...[
            Tooltip(
              message: '${transportName(k)}: ${s.name}',
              child: InkWell(
                key: Key('link-${k.name}'),
                customBorder: const CircleBorder(),
                onTap: onLinkTap == null ? null : () => onLinkTap!(k),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(3, 4, 3, 4),
                  child: Icon(
                    transportIcon(k),
                    size: 18,
                    color: s == TransportStatus.running
                        ? Colors.green
                        : Colors.grey,
                  ),
                ),
              ),
            ),
            if (k == TransportKind.internet && cell != null) _cellIcon(),
          ],
          if (cell != null && !links.any((l) => l.$1 == TransportKind.internet))
            _cellIcon(),
          const SizedBox(width: 4),
          Expanded(
            child: InkWell(
              key: const Key('internet-status'),
              onTap: onLinkTap == null
                  ? null
                  : () => onLinkTap!(TransportKind.internet),
              child: Text(
                internet.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: netColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (mobileDataHint && onLinkTap != null)
            TextButton.icon(
              key: const Key('allow-mobile-data'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              icon: const Icon(Icons.signal_cellular_alt, size: 16),
              label: const Text('Allow mobile data'),
              onPressed: () => onLinkTap!(TransportKind.internet),
            ),
          TextButton(
            onPressed: () => onToggleDetails(!showDetails),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Details'),
                Icon(showDetails ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A person on the channel (or "You").
/// "🔋 64%" (red at 15 % or less).
class BatteryBadge extends StatelessWidget {
  const BatteryBadge(this.pct, {super.key});
  final int pct;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final low = pct <= 15;
    final color = low ? Colors.red : theme.colorScheme.outline;
    final icon = pct >= 90
        ? Icons.battery_full
        : pct >= 50
        ? Icons.battery_5_bar
        : pct > 15
        ? Icons.battery_3_bar
        : Icons.battery_alert;
    return Tooltip(
      message: 'Phone battery',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          Text(
            '$pct%',
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.person,
    this.showDebug = false,
    this.onRing,
    this.onBeep,
    this.onMessage,
    this.onEdit,
    this.onLongPress,
  });
  final PersonView person;
  final VoidCallback? onLongPress;
  final bool showDebug;
  final VoidCallback? onRing;
  final VoidCallback? onBeep;
  final VoidCallback? onMessage;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final faded = p.left || p.elsewhere != null;
    final status = <Widget>[];
    if (p.me) {
      status.add(
        Text(
          p.talking ? 'You are talking' : 'This phone',
          style: theme.textTheme.bodySmall,
        ),
      );
    } else if (p.left) {
      status.add(
        Text(
          'Left${p.lastHeard != null ? ' ${agoText(p.lastHeard!)}' : ''}',
          style: theme.textTheme.bodySmall?.copyWith(
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    } else {
      for (final k in p.links) {
        final on = k == p.active;
        status.add(
          Tooltip(
            message: transportName(k),
            child: Icon(
              transportIcon(k),
              size: 16,
              color: on ? cs.primary : cs.outline,
            ),
          ),
        );
      }
      if (p.hops != null) {
        status.add(
          Tooltip(
            message: 'Relayed by other phones',
            child: Icon(Icons.hub, size: 16, color: cs.primary),
          ),
        );
      } else if (p.links.isEmpty) {
        status.add(Text('no path', style: theme.textTheme.bodySmall));
      }
      if (p.distance != null) {
        status.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (p.arrowDeg != null)
                Transform.rotate(
                  angle: p.arrowDeg! * math.pi / 180,
                  child: Icon(Icons.navigation, size: 15, color: cs.secondary),
                ),
              Text(
                p.distance!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.secondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }
      if (p.battery != null) status.add(BatteryBadge(p.battery!));
      if ((p.volume - 1).abs() > 0.01) {
        status.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                p.volume == 0 ? Icons.volume_off : Icons.volume_up,
                size: 15,
                color: cs.tertiary,
              ),
              Text(
                '${(p.volume * 100).round()}%',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary),
              ),
            ],
          ),
        );
      }
      status.add(
        Text(
          [
            if (p.active == TransportKind.lora)
              'via radio'
            else if (p.active != null)
              'via ${p.active == TransportKind.internet && p.path != null ? '${p.path} (internet)' : transportName(p.active!)}',
            if (p.active == null && p.hops != null) hopsText(p.hops!),
            if (p.active == null && p.hops == null && p.gateway != null)
              gatewayText(p.gateway!),
            if (p.elsewhere != null) p.elsewhere!,
            if (p.lastHeard != null) agoText(p.lastHeard!),
          ].join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
        ),
      );
    }

    final card = Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: p.talking
          ? cs.primaryContainer
          : p.me
          ? cs.surfaceContainerHighest
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: p.talking
            ? BorderSide(color: cs.primary, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Avatar(id: p.id, name: p.name, talking: p.talking),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 2,
                      children: [
                        Text(
                          p.name,
                          maxLines: 2,
                          softWrap: true,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.15,
                          ),
                        ),
                        if (p.me) const _Tag(text: 'You'),
                        if (p.talking && !p.me)
                          _Tag(text: 'Talking', color: cs.primary),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: status,
                    ),
                    if (p.ringStatus != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          p.ringStatus!,
                          style: TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (showDebug && p.debug != null)
                      Text(
                        p.debug!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              ),
              if (p.me && onEdit != null)
                IconButton(
                  tooltip: 'Change your name',
                  icon: const Icon(Icons.edit),
                  onPressed: onEdit,
                ),
              if (!p.me && !p.left) ...[
                GestureDetector(
                  onLongPress: onBeep,
                  // No tooltip: its long-press would swallow "hold to beep".
                  child: IconButton(
                    icon: const Icon(Icons.ring_volume),
                    onPressed: onRing,
                  ),
                ),
                IconButton(
                  tooltip: 'Voice message',
                  icon: const Icon(Icons.mic),
                  onPressed: onMessage,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return faded ? Opacity(opacity: 0.5, child: card) : card;
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}

/// Initials in a colored circle; pulses while the person talks.
class Avatar extends StatefulWidget {
  const Avatar({
    super.key,
    required this.id,
    required this.name,
    this.talking = false,
    this.size = 48,
  });
  final int id;
  final String name;
  final bool talking;
  final double size;

  @override
  State<Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<Avatar> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.talking) _pulse.repeat();
  }

  @override
  void didUpdateWidget(Avatar old) {
    super.didUpdateWidget(old);
    if (widget.talking && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.talking && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final color = avatarColor(widget.id);
    final circle = Container(
      width: s,
      height: s,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        initials(widget.name),
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: s * 0.36,
        ),
      ),
    );
    return SizedBox(
      width: s + 12,
      height: s + 12,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final t = _pulse.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.talking)
                Container(
                  width: s + 12 * t,
                  height: s + 12 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 1 - t),
                      width: 3,
                    ),
                  ),
                ),
              child!,
              if (widget.talking)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.graphic_eq,
                      size: 14 + 2 * math.sin(t * math.pi),
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ),
            ],
          );
        },
        child: circle,
      ),
    );
  }
}

/// The big round push-to-talk button. [size] scales with screen height.
class PttButton extends StatelessWidget {
  const PttButton({
    super.key,
    required this.transmitting,
    required this.busy,
    required this.onChanged,
    this.size = 160,
    this.toggle = false,
    this.onTap,
    this.caption,
    this.private = false,
  });
  final bool transmitting;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final double size;

  /// Toggle mode: tap to start, tap to stop ([onTap]).
  final bool toggle;
  final VoidCallback? onTap;

  /// Who hears it, under the button: "Talk to CH 1 (3 people)" or
  /// "Reply privately to Ann".
  final String? caption;

  /// Private reply mode: lock icon, purple, "HOLD TO REPLY".
  final bool private;

  static const privateColor = Color(0xFF7B1FA2);

  Widget _gesture(Widget child) {
    if (toggle) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      );
    }
    return Listener(
      onPointerDown: (_) => onChanged(true),
      onPointerUp: (_) => onChanged(false),
      onPointerCancel: (_) => onChanged(false),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = transmitting
        ? (private ? const Color(0xFFC2185B) : Colors.red)
        : busy && !private
        ? Colors.orange
        : private
        ? privateColor
        : Theme.of(context).colorScheme.primary;
    final d = transmitting ? size * 1.08 : size;
    final circle = SizedBox(
      width: size * 1.08,
      height: size * 1.08,
      child: Center(
        child: _gesture(
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: d,
            height: d,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: transmitting ? 30 : 12,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      private
                          ? Icons.lock
                          : transmitting
                          ? Icons.mic
                          : Icons.mic_none,
                      size: size * 0.32,
                      color: Colors.white,
                    ),
                    Text(
                      transmitting
                          ? (toggle ? 'TAP TO STOP' : 'TALKING')
                          : busy && !private
                          ? 'RECEIVING'
                          : private
                          ? (toggle ? 'TAP TO REPLY' : 'HOLD TO REPLY')
                          : (toggle ? 'TAP TO TALK' : 'HOLD TO TALK'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final cap = caption;
    if (cap == null) return circle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        circle,
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (private)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.lock, size: 14, color: privateColor),
              ),
            Flexible(
              child: Text(
                cap,
                key: const Key('ptt-caption'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: private ? privateColor : null,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "🔒 Private from Ann: Hold here to reply privately", pinned above the
/// big talk button while private talk / a voice message from a friend is
/// recent. Holding the banner talks privately to that friend only.
class PrivateReplyBanner extends StatelessWidget {
  const PrivateReplyBanner({
    super.key,
    required this.name,
    required this.onTalk,
    required this.onChannelInstead,
    this.transmitting = false,
    this.onOpenChat,
  });
  final String name;
  final ValueChanged<bool> onTalk;
  final VoidCallback onChannelInstead;
  final VoidCallback? onOpenChat;
  final bool transmitting;

  @override
  Widget build(BuildContext context) {
    const purple = PttButton.privateColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Material(
        color: transmitting ? const Color(0xFFF8BBD0) : const Color(0xFFF3E5F5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: purple, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Listener(
                  key: const Key('private-reply-hold'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => onTalk(true),
                  onPointerUp: (_) => onTalk(false),
                  onPointerCancel: (_) => onTalk(false),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: transmitting
                              ? const Color(0xFFC2185B)
                              : purple,
                          child: Icon(
                            transmitting ? Icons.mic : Icons.lock,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            transmitting
                                ? '🔒 Talking privately to $name… '
                                      '(only $name hears you)'
                                : '🔒 Private from $name: '
                                      'Hold here to reply privately',
                            style: const TextStyle(
                              color: Color(0xFF4A148C),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (onOpenChat != null)
                    IconButton(
                      tooltip: 'Open private chat',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.chat_bubble_outline,
                        color: purple,
                      ),
                      onPressed: onOpenChat,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bottom of the home screen: optional private reply banner, the big
/// talk button with "who hears it", and "Talk to channel instead".
class MainTalkArea extends StatelessWidget {
  const MainTalkArea({
    super.key,
    required this.button,
    this.replyName,
    this.onReplyTalk,
    this.onChannelInstead,
    this.replyTransmitting = false,
    this.onOpenChat,
  });
  final Widget button;
  final String? replyName;
  final ValueChanged<bool>? onReplyTalk;
  final VoidCallback? onChannelInstead;
  final VoidCallback? onOpenChat;
  final bool replyTransmitting;

  @override
  Widget build(BuildContext context) {
    final name = replyName;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (name != null)
          PrivateReplyBanner(
            name: name,
            transmitting: replyTransmitting,
            onTalk: onReplyTalk ?? (_) {},
            onChannelInstead: onChannelInstead ?? () {},
            onOpenChat: onOpenChat,
          ),
        button,
        if (name != null)
          TextButton(
            key: const Key('talk-to-channel'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
            ),
            onPressed: onChannelInstead,
            child: const Text('Talk to channel instead'),
          ),
      ],
    );
  }
}

/// Ring all / Beep / Hold: message, wrapping on narrow screens.
class ChannelActions extends StatelessWidget {
  const ChannelActions({
    super.key,
    required this.onRingAll,
    required this.onBeepAll,
    required this.record,
    this.mute,
  });
  final VoidCallback onRingAll;
  final VoidCallback onBeepAll;
  final Widget record;

  /// Hold-to-mute button (v1.9.5).
  final Widget? mute;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          OutlinedButton.icon(
            style: style,
            icon: const Icon(Icons.ring_volume, size: 18),
            label: const Text('Ring all'),
            onPressed: onRingAll,
          ),
          OutlinedButton.icon(
            style: style,
            icon: const Icon(Icons.notifications_active, size: 18),
            label: const Text('Beep'),
            onPressed: onBeepAll,
          ),
          record,
          ?mute,
        ],
      ),
    );
  }
}
