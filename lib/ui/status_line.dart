import 'package:flutter/material.dart';

import '../core/transport.dart';
import '../core/transport_manager.dart';
import 'connection_health.dart';
import 'home_view.dart';
import 'sheets.dart';
import 'who_can_hear.dart';

/// "Wi-Fi", "mobile data", "no internet": the short network part of the
/// status line ("Internet via Wi-Fi (Home relay)" -> "Wi-Fi").
String shortNetText(String text, TransportStatus status) {
  final c = compactInternetText(text);
  if (c.startsWith('Internet via ')) return c.substring('Internet via '.length);
  if (status == TransportStatus.starting) return 'connecting…';
  if (status != TransportStatus.running) return 'no internet';
  return c.replaceFirst('Internet: ', '');
}

/// "backup ready", "2 backups ready", "no backup".
String? backupText(ConnectionSummary? s) {
  if (s == null) return null;
  if (s.best == null) return 'looking for a connection';
  return switch (s.backups) {
    0 => 'no backup',
    1 => 'backup ready',
    _ => '${s.backups} backups ready',
  };
}

/// v2.3.1: the one line under the top bar that used to be two (Who can hear
/// this? and the connection status): "🔒 Private group · 3 people · Wi-Fi ·
/// backup ready". Chips are appended only when they apply (quiet hours,
/// low volume, "Allow mobile data"), each tappable on its own. Tapping the
/// line opens [onOpen]: one sheet with the full connection details and the
/// "Who can hear this?" explanation.
class TalkStatusLine extends StatelessWidget {
  const TalkStatusLine({
    super.key,
    required this.audience,
    required this.here,
    required this.netStatus,
    required this.netText,
    this.summary,
    this.quiet,
    this.volumeLow = false,
    this.onVolumeLow,
    this.mobileDataHint = false,
    this.onMobileData,
    required this.onOpen,
    this.onOpenMessages,
    this.messagesNew = false,
    this.weather,
    this.weatherExtreme = false,
    this.onOpenWeather,
    this.health,
    this.onOpenHealth,
  });

  final AudienceInfo audience;

  /// People on this channel / group, you included.
  final int here;
  final TransportStatus netStatus;
  final String netText;
  final ConnectionSummary? summary;

  /// The moon / muted chip (a [QuietChip]), or null.
  final Widget? quiet;
  final bool volumeLow;
  final VoidCallback? onVolumeLow;
  final bool mobileDataHint;
  final VoidCallback? onMobileData;
  final VoidCallback onOpen;

  /// v2.4.0: one small Messages icon at the end of the line (null = hidden):
  /// voice messages and missed live talk. The dot means audio nobody has
  /// listened to yet, in any place.
  final VoidCallback? onOpenMessages;
  final bool messagesNew;

  /// v2.5.0: the most important weather alert in force for your area, or
  /// null. Shown as one small icon (amber; the error colour for Extreme),
  /// never a banner.
  final String? weather;
  final bool weatherExtreme;
  final VoidCallback? onOpenWeather;

  /// v2.6.0: the connection chip (current path, signal, home base last
  /// heard). Null = no chip. Read on every build and every 30 s.
  final ConnectionHealth Function()? health;
  final VoidCallback? onOpenHealth;

  String get _audienceText {
    final people = '$here ${here == 1 ? 'person' : 'people'}';
    return switch (audience.kind) {
      Audience.open =>
        'Open channel${audience.channel == null ? '' : ' CH ${audience.channel}'}'
            ' · $people',
      Audience.privateGroup => 'Private group · $people',
      Audience.direct => 'Direct chat · ${audience.name ?? 'friend'}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final netColor = switch (netStatus) {
      TransportStatus.running => Colors.green,
      TransportStatus.starting => Colors.orange,
      _ => Colors.redAccent,
    };
    final backup = backupText(summary);
    final net = shortNetText(netText, netStatus);
    final plain = '$_audienceText · $net${backup == null ? '' : ' · $backup'}';
    final line = Semantics(
      button: true,
      label:
          'Status: $plain. Tap for connection details and who can hear '
          'this',
      excludeSemantics: true,
      child: InkWell(
        key: const Key('status-line'),
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: WhoCanHearLine.heightFor(context),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                Icon(audience.kind.icon, size: 15, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '$_audienceText · '),
                        TextSpan(
                          text: net,
                          style: TextStyle(
                            color: netColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (backup != null) TextSpan(text: ' · $backup'),
                      ],
                    ),
                    key: const Key('status-line-text'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Row(
      children: [
        Expanded(child: line),
        if (mobileDataHint && onMobileData != null)
          Tooltip(
            message: 'Allow mobile data',
            child: InkWell(
              key: const Key('allow-mobile-data'),
              customBorder: const CircleBorder(),
              onTap: onMobileData,
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(
                  Icons.signal_cellular_alt,
                  size: 20,
                  color: Colors.orange,
                  semanticLabel: 'Allow mobile data',
                ),
              ),
            ),
          ),
        if (volumeLow)
          Tooltip(
            message: 'Volume is low: tap to raise it',
            child: InkWell(
              key: const Key('volume-low-chip'),
              customBorder: const CircleBorder(),
              onTap: onVolumeLow,
              child: const Padding(
                padding: EdgeInsets.all(6),
                child: Icon(
                  Icons.volume_down,
                  size: 20,
                  color: Colors.amber,
                  semanticLabel: 'Volume is low. Tap to raise it',
                ),
              ),
            ),
          ),
        if (health != null && onOpenHealth != null)
          ConnectionChip(source: health!, onTap: onOpenHealth!),
        if (weather != null && onOpenWeather != null)
          _Shortcut(
            key: const Key('talk-weather-shortcut'),
            icon: weatherExtreme
                ? Icons.thunderstorm_outlined
                : Icons.warning_amber_rounded,
            tooltip: 'Weather alert: $weather',
            dot: false,
            color: weatherExtreme ? cs.error : Colors.amber,
            onTap: onOpenWeather!,
          ),
        if (onOpenMessages != null)
          _Shortcut(
            key: const Key('talk-messages-shortcut'),
            icon: Icons.voicemail,
            tooltip: messagesNew
                ? 'Messages (voice messages and talk you did not hear)'
                : 'Messages',
            dot: messagesNew,
            onTap: onOpenMessages!,
          ),
        if (quiet != null)
          Padding(
            padding: const EdgeInsets.only(left: 2, right: 8),
            child: quiet,
          ),
        if (quiet == null) const SizedBox(width: 4),
      ],
    );
  }
}

/// A small icon on the status line with an optional "something new" dot.
class _Shortcut extends StatelessWidget {
  const _Shortcut({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.dot,
    required this.onTap,
    this.color,
  });
  final Color? color;
  final IconData icon;
  final String tooltip;
  final bool dot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Semantics(
          button: true,
          label: tooltip,
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Badge(
              key: Key(dot ? 'shortcut-dot' : 'shortcut-nodot'),
              isLabelVisible: dot,
              smallSize: 8,
              child: Icon(icon, size: 20, color: color ?? cs.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet behind the status line: "Who can hear this?" and the full
/// connection details (icons you can tap, the full text, technical details).
class StatusSheetBody extends StatelessWidget {
  const StatusSheetBody({
    super.key,
    required this.audience,
    required this.connection,
    required this.lines,
    required this.technical,
    required this.onTechnical,
    this.onAddPeople,
  });

  final AudienceInfo audience;

  /// "Add people" in a private group (closes the sheet first).
  final VoidCallback? onAddPeople;

  /// The connection icons (a [StatusRow]).
  final Widget connection;

  /// Full "Internet: connected via Wi-Fi (Home relay)", the best path, the
  /// per-link lines.
  final List<String> lines;

  /// Technical details (also shown on people cards) on / off.
  final bool technical;
  final ValueChanged<bool> onTechnical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('status-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WhoCanHearSheetBody(info: audience, onAddPeople: onAddPeople),
        const Divider(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Connection', style: theme.textTheme.titleLarge),
        ),
        connection,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: SelectableText(
            lines.join('\n'),
            key: const Key('status-sheet-lines'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        SwitchListTile(
          key: const Key('status-technical'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: const Text('Technical details'),
          subtitle: const Text('Extra lines on each person'),
          value: technical,
          onChanged: onTechnical,
        ),
      ],
    );
  }
}

Future<void> showStatusSheet(
  BuildContext context, {
  required Widget Function(BuildContext) builder,
}) => showAppSheet<void>(context: context, builder: builder);
