import 'dart:async';

import 'package:flutter/material.dart';

import '../app/friendly_error.dart' show FixAction;
import '../app/walkie_controller.dart';
import '../core/transport.dart';
import '../lora/meshtastic_ble.dart' show RadioState;
import '../lora/stream_radio.dart';
import '../trip/battery_mode.dart';
import '../trip/geo.dart' show formatAge;
import '../trip/location_source.dart';
import '../trip/range_test.dart' show defaultRangeHomeNode;
import 'battery_mode_ui.dart' show batteryModeIcon, batteryModeColor;
import 'sheets.dart';

/// v2.6.0: the one connection chip on the Talk status line.
///
/// Everything here is read from state the app already has: the link states,
/// the radio's session (signal and last-heard time of the home radio come
/// from packets the radio hears anyway). Nothing is sent, polled or
/// scheduled to make it; the chip only redraws when the app already
/// redraws, plus once every 30 s while it is on screen (so "3 min" counts
/// up).

/// How good a path (or the whole chip) is.
enum HealthLevel {
  /// Working.
  good,

  /// Working, but weak or stale.
  weak,

  /// Not working.
  down,

  /// Off, not in use, or still connecting.
  idle,
}

/// One row in the details sheet.
class PathHealth {
  const PathHealth({
    required this.name,
    required this.icon,
    required this.level,
    required this.text,
    this.active = false,
    this.fixes = const [],
  });
  final String name;
  final IconData icon;
  final HealthLevel level;

  /// Plain words: what it is doing, or why it is down.
  final String text;

  /// This is the path the app is talking over right now.
  final bool active;

  /// One-tap fixes shown under the row when it is down (v2.6.3).
  final List<FixAction> fixes;
}

/// What the app knows about the connected radio (a plain value so the logic
/// can be tested without a radio).
class RadioHealth {
  const RadioHealth({
    this.paired = false,
    this.state = RadioState.none,
    this.link = RadioLinkKind.bluetooth,
    this.port,
    this.homeName,
    this.homeHeard,
    this.homeSnr = 0,
    this.homeRssi = 0,
    this.homeHops,
  });

  /// A radio is saved / chosen (connected or not).
  final bool paired;
  final RadioState state;
  final RadioLinkKind link;

  /// "COM7" for a USB radio.
  final String? port;

  /// The home radio's name, or its !id.
  final String? homeName;

  /// When the radio last heard the home radio (any packet), null = never.
  final DateTime? homeHeard;

  /// 0 = not reported.
  final double homeSnr;
  final int homeRssi;
  final int? homeHops;

  bool get ready => state == RadioState.ready;
}

enum RadioLinkKind { bluetooth, usb, wifi }

/// The whole picture: the chip and the sheet are both drawn from this.
class ConnectionHealth {
  const ConnectionHealth({
    required this.level,
    required this.pathName,
    required this.pathIcon,
    required this.text,
    required this.shortText,
    required this.headline,
    required this.reasons,
    required this.paths,
    this.homeLine,
    this.homeNote,
    this.signalText,
  });

  final HealthLevel level;

  /// "Internet", "Wi-Fi", "Wi-Fi Direct", "Bluetooth", "Radio", or "No link".
  final String pathName;
  final IconData pathIcon;

  /// Chip text: "Internet · Home 3 min".
  final String text;

  /// Narrow chip text: "Internet · 3m".
  final String shortText;

  /// One plain sentence for the top of the sheet.
  final String headline;

  /// Everything that is not right, most important first.
  final List<String> reasons;
  final List<PathHealth> paths;

  /// "Skunk Ape: heard 3 min ago", null = no radio set up.
  final String? homeLine;
  final String? homeNote;

  /// "Good (SNR 6 dB, RSSI -88 dBm, direct)", null = not known.
  final String? signalText;

  /// Build it from plain values (see [connectionHealthOf] for the app's).
  factory ConnectionHealth.from({
    required DateTime now,
    TransportKind? bestKind,
    bool linkFailing = false,
    required TransportStatus internet,
    String? internetText,
    String? phoneNet,
    Map<TransportKind, TransportStatus> links = const {},
    Map<TransportKind, String?> linkDetail = const {},
    RadioHealth radio = const RadioHealth(),
    Duration homeStaleAfter = const Duration(minutes: 30),
    Duration signalFreshFor = const Duration(minutes: 15),
  }) {
    // ---- the radio and the home radio
    final heardAge = radio.homeHeard == null
        ? null
        : now.difference(radio.homeHeard!);
    final age = heardAge == null || heardAge.isNegative
        ? (heardAge == null ? null : Duration.zero)
        : heardAge;
    final homeFresh = age != null && age <= homeStaleAfter;
    final signalFresh = age != null && age <= signalFreshFor;
    final home = radio.homeName ?? 'Home base';

    String? signalText;
    var signalWeak = false;
    if (radio.ready && signalFresh && radio.homeSnr != 0) {
      final snr = radio.homeSnr;
      final grade = snr >= -7
          ? 'Good'
          : snr >= -15
          ? 'Fair'
          : 'Weak';
      signalWeak = snr < -15;
      final hops = radio.homeHops;
      signalText =
          '$grade (SNR ${snr.toStringAsFixed(snr == snr.roundToDouble() ? 0 : 1)} dB'
          '${radio.homeRssi != 0 ? ', RSSI ${radio.homeRssi} dBm' : ''}'
          '${hops == null
              ? ''
              : hops == 0
              ? ', direct'
              : ', $hops hop${hops == 1 ? '' : 's'}'})';
    }

    String? radioProblem; // why the radio is not up (plain)
    var radioConnecting = false;
    if (radio.paired && !radio.ready) {
      final how = switch (radio.link) {
        RadioLinkKind.bluetooth => 'Bluetooth',
        RadioLinkKind.usb => 'USB',
        RadioLinkKind.wifi => 'Wi-Fi',
      };
      switch (radio.state) {
        case RadioState.bluetoothOff:
          radioProblem =
              'Bluetooth is off or not allowed, so the radio can '
              'not connect';
        case RadioState.connecting:
          radioProblem = 'Connecting to the radio over $how…';
          radioConnecting = true;
        case RadioState.pairing:
          radioProblem = 'Waiting for the Bluetooth pairing PIN';
          radioConnecting = true;
        case RadioState.configuring:
          radioProblem = 'Reading the radio\'s settings…';
          radioConnecting = true;
        case RadioState.reconnecting:
        case RadioState.none:
        case RadioState.ready:
          radioProblem = switch (radio.link) {
            RadioLinkKind.usb =>
              'Radio not connected over USB: check the cable, and that no '
                  'other program is using ${radio.port ?? 'the port'}',
            RadioLinkKind.wifi => 'Radio not connected over Wi-Fi',
            RadioLinkKind.bluetooth =>
              'Radio not connected over Bluetooth: it is off, out of reach '
                  'or taken by another app',
          };
      }
    }

    // ---- the paths
    final netUp = internet == TransportStatus.running;
    final netStarting = internet == TransportStatus.starting;
    final localUp = <TransportKind>[
      for (final k in const [
        TransportKind.lan,
        TransportKind.wifiDirect,
        TransportKind.ble,
      ])
        if (links[k] == TransportStatus.running) k,
    ];
    TransportKind? active = bestKind;
    if (active == null) {
      if (netUp) {
        active = TransportKind.internet;
      } else if (localUp.isNotEmpty) {
        active = localUp.first;
      } else if (radio.ready) {
        active = TransportKind.lora;
      }
    }

    String netReason() {
      if (phoneNet == 'none') return 'No internet: the phone has no network';
      final d = internetText == null || internetText.isEmpty
          ? ''
          : ' ($internetText)';
      return 'No internet: the relay can not be reached$d';
    }

    final paths = <PathHealth>[
      PathHealth(
        name: 'Internet relay',
        icon: Icons.public,
        level: netUp
            ? HealthLevel.good
            : netStarting
            ? HealthLevel.idle
            : HealthLevel.down,
        text: netUp
            ? (internetText == null || internetText.isEmpty
                  ? 'Connected'
                  : internetText)
            : netStarting
            ? 'Connecting to the relay…'
            : netReason(),
        active: active == TransportKind.internet,
        fixes: !netUp && !netStarting
            ? [FixAction.retry, if (phoneNet == 'none') FixAction.wifiSettings]
            : const [],
      ),
      for (final k in const [
        TransportKind.lan,
        TransportKind.wifiDirect,
        TransportKind.ble,
      ])
        if (links.containsKey(k) &&
            (links[k] == TransportStatus.running ||
                links[k] == TransportStatus.starting ||
                links[k] == TransportStatus.stopped))
          PathHealth(
            name: switch (k) {
              TransportKind.lan => 'Wi-Fi / local network',
              TransportKind.wifiDirect => 'Wi-Fi Direct',
              _ => 'Bluetooth to phones',
            },
            icon: switch (k) {
              TransportKind.lan => Icons.wifi,
              TransportKind.wifiDirect => Icons.wifi_tethering,
              _ => Icons.bluetooth,
            },
            level: links[k] == TransportStatus.running
                ? HealthLevel.good
                : HealthLevel.idle,
            text: switch (links[k]!) {
              TransportStatus.running => 'On, looking for phones nearby',
              TransportStatus.starting => 'Starting…',
              _ => linkDetail[k] ?? 'Off',
            },
            active: active == k,
          ),
      if (radio.paired)
        PathHealth(
          name: switch (radio.link) {
            RadioLinkKind.usb => 'Radio (USB)',
            RadioLinkKind.wifi => 'Radio (Wi-Fi)',
            RadioLinkKind.bluetooth => 'Radio (Bluetooth)',
          },
          icon: Icons.settings_input_antenna,
          level: radio.ready
              ? ((homeFresh && !signalWeak) || radio.homeName == null
                    ? HealthLevel.good
                    : HealthLevel.weak)
              : radioConnecting
              ? HealthLevel.idle
              : HealthLevel.down,
          text: radio.ready
              ? 'Connected${radio.port != null ? ' on ${radio.port}' : ''}'
                    ' · messages and locations only, no live voice'
              : radioProblem!,
          active: active == TransportKind.lora,
          fixes: !radio.ready && !radioConnecting
              ? [
                  if (radio.state == RadioState.bluetoothOff)
                    FixAction.turnOnBluetooth,
                  FixAction.connectRadio,
                ]
              : const [],
        )
      else
        const PathHealth(
          name: 'Radio',
          icon: Icons.settings_input_antenna,
          level: HealthLevel.idle,
          text: 'No radio set up',
        ),
    ];

    // ---- the home base line
    String? homeLine;
    String? homeNote;
    final reasons = <String>[];
    final noPath = active == null;
    if (noPath) {
      if (netStarting || radioConnecting) {
        reasons.add('Still connecting…');
      } else {
        reasons.add(
          radio.paired && radioProblem != null && !netUp
              ? '${netReason()}. $radioProblem'
              : netReason(),
        );
      }
    }
    if (radio.paired) {
      if (!radio.ready) {
        if (!noPath && radioProblem != null) reasons.add(radioProblem);
        homeLine = '$home: can not tell, the radio is not connected';
      } else if (age == null) {
        homeLine = '$home: not heard yet';
        reasons.add('$home not heard yet');
      } else {
        homeLine =
            '$home: heard ${formatAge(age)}'
            '${formatAge(age) == 'just now' ? '' : ' ago'}';
        if (!homeFresh) reasons.add('$home not heard for ${formatAge(age)}');
      }
      if (radio.ready && signalWeak) {
        reasons.add('Weak signal to $home');
      }
      if (radio.ready) {
        homeNote =
            'Taken from what the radio already hears; nothing is sent '
            'to check. A quiet spell is normal: the home radio only speaks up '
            'now and then. Turn on Range logging (Trip map > the file icon) '
            'for exact checks.';
      }
    }
    if (linkFailing && !noPath) {
      reasons.add('A link just missed a check; a backup is carrying it');
    }

    // ---- the chip
    final level = noPath
        ? ((netStarting || radioConnecting)
              ? HealthLevel.idle
              : HealthLevel.down)
        : reasons.isEmpty
        ? HealthLevel.good
        : HealthLevel.weak;
    final name = switch (active) {
      TransportKind.internet => 'Internet',
      TransportKind.lan => 'Wi-Fi',
      TransportKind.wifiDirect => 'Wi-Fi Direct',
      TransportKind.ble => 'Bluetooth',
      TransportKind.lora => 'Radio',
      null => level == HealthLevel.idle ? 'Connecting' : 'No link',
    };
    final icon = switch (active) {
      TransportKind.internet => Icons.public,
      TransportKind.lan => Icons.wifi,
      TransportKind.wifiDirect => Icons.wifi_tethering,
      TransportKind.ble => Icons.bluetooth,
      TransportKind.lora => Icons.settings_input_antenna,
      null => Icons.link_off,
    };
    String homePart = '';
    String homeShort = '';
    if (radio.paired) {
      if (!radio.ready) {
        homePart = ' · Radio off';
        homeShort = ' · off';
      } else if (age == null) {
        homePart = ' · Home —';
        homeShort = ' · —';
      } else {
        final a = formatAge(age) == 'just now' ? 'now' : _short(age);
        homePart = ' · Home $a';
        homeShort = ' · $a';
      }
    }
    final headline = switch (level) {
      HealthLevel.good =>
        'All good: talking over $name'
            '${radio.paired && radio.ready ? ', radio connected' : ''}',
      HealthLevel.weak => reasons.first,
      HealthLevel.down => reasons.first,
      HealthLevel.idle => 'Connecting…',
    };
    return ConnectionHealth(
      level: level,
      pathName: name,
      pathIcon: icon,
      text: '$name$homePart',
      shortText: '$name$homeShort',
      headline: headline,
      reasons: reasons,
      paths: paths,
      homeLine: homeLine,
      homeNote: homeNote,
      signalText: signalText,
    );
  }
}

/// "now", "40s", "3m", "5h", "2d".
String _short(Duration d) {
  if (d.isNegative || d.inSeconds < 10) return 'now';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 48) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// The app's own values, for the chip.
ConnectionHealth connectionHealthOf(WalkieController c, {DateTime? now}) {
  final radioDev = c.radioDevice;
  final sess = radioDev.session;
  final range = c.trip?.range;
  final homeId = range?.homeNode ?? defaultRangeHomeNode;
  final node = sess?.nodes[homeId];
  final id = radioDev.deviceId;
  final kind = id == null
      ? RadioLinkKind.bluetooth
      : id.startsWith('tcp:')
      ? RadioLinkKind.wifi
      : StreamRadioId.isStream(id)
      ? RadioLinkKind.usb
      : RadioLinkKind.bluetooth;
  final name = node != null && node.longName.isNotEmpty
      ? node.longName
      : '!${homeId.toRadixString(16).padLeft(8, '0')}';
  final summary = c.connectionSummary;
  return ConnectionHealth.from(
    now: now ?? DateTime.now(),
    bestKind: summary.bestKind,
    linkFailing: summary.failing,
    internet: c.internetStatus.status,
    internetText: c.internetStatus.status == TransportStatus.running
        ? c.internetStatus.text
        : null,
    phoneNet: c.phoneNet,
    links: {
      for (final t in c.transports)
        if (t.kind != TransportKind.internet && t.kind != TransportKind.lora)
          t.kind: t.status,
    },
    linkDetail: {
      for (final t in c.transports)
        if (t.kind != TransportKind.internet && t.kind != TransportKind.lora)
          t.kind: t.statusDetail,
    },
    radio: RadioHealth(
      paired: c.radioPaired,
      state: radioDev.state,
      link: kind,
      port: id == null ? null : StreamRadioId.serialPort(id),
      homeName: name,
      homeHeard: node?.lastHeard,
      homeSnr: node?.snr ?? 0,
      homeRssi: node?.rssi ?? 0,
      homeHops: node?.hopsAway,
    ),
    // Range logging pings every 30 to 120 s, so a silent home radio shows
    // fast; without it only its own now-and-then beacons are heard.
    homeStaleAfter: (range?.logging ?? false)
        ? const Duration(minutes: 10)
        : const Duration(minutes: 30),
  );
}

Color healthColor(HealthLevel l, ColorScheme cs) => switch (l) {
  HealthLevel.good => Colors.green,
  HealthLevel.weak => Colors.amber.shade700,
  HealthLevel.down => Colors.redAccent,
  HealthLevel.idle => cs.outline,
};

String healthWord(HealthLevel l) => switch (l) {
  HealthLevel.good => 'good',
  HealthLevel.weak => 'weak',
  HealthLevel.down => 'down',
  HealthLevel.idle => 'idle',
};

/// The chip on the status line. [source] is read on every build and every
/// 30 s while it is on screen.
class ConnectionChip extends StatefulWidget {
  const ConnectionChip({
    super.key,
    required this.source,
    required this.onTap,
    this.batteryMode,
  });
  final ConnectionHealth Function() source;
  final VoidCallback onTap;

  /// v2.6.12: the Battery mode (a leaf for Saver, a target for Tracking,
  /// nothing for Normal). Null = not shown.
  final BatteryMode Function()? batteryMode;

  @override
  State<ConnectionChip> createState() => _ConnectionChipState();
}

class _ConnectionChipState extends State<ConnectionChip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final h = widget.source();
    final narrow = MediaQuery.of(context).size.width < 400;
    final color = healthColor(h.level, cs);
    final label = narrow ? h.shortText : h.text;
    final mode = widget.batteryMode?.call() ?? BatteryMode.normal;
    final modeWords = mode == BatteryMode.normal
        ? ''
        : ' Battery mode ${mode.label}.';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: 'Connection: ${h.headline}.$modeWords Tap for details',
        child: Semantics(
          button: true,
          label:
              'Connection ${healthWord(h.level)}: ${h.text}. ${h.headline}.'
              '$modeWords Tap for details',
          excludeSemantics: true,
          child: InkWell(
            key: const Key('connection-chip'),
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: narrow ? 108 : 190,
                minHeight: 28,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  border: Border.all(color: color.withValues(alpha: 0.7)),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(h.pathIcon, size: 14, color: color),
                      if (mode != BatteryMode.normal) ...[
                        const SizedBox(width: 2),
                        Icon(
                          batteryModeIcon(mode),
                          key: Key('connection-chip-mode-${mode.id}'),
                          size: 13,
                          color: batteryModeColor(mode),
                        ),
                      ],
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          label,
                          key: const Key('connection-chip-text'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The one-tap range test line on the connection sheet (v2.6.10).
class RangeRunLine {
  const RangeRunLine({
    required this.running,
    required this.homeName,
    required this.onTap,
    this.elapsed = Duration.zero,
  });
  final bool running;
  final String homeName;
  final Duration elapsed;

  /// Start (asks first) or Stop (shows the summary).
  final VoidCallback onTap;
}

/// The sheet behind the chip: the whole picture in plain words.
class ConnectionHealthSheet extends StatelessWidget {
  const ConnectionHealthSheet({
    super.key,
    required this.health,
    this.onMore,
    this.onFix,
    this.location,
    this.rangeTest,
    this.battery,
  });
  final ConnectionHealth health;

  /// The Battery mode picker (v2.6.12), null = not shown.
  final Widget? battery;

  /// Start / stop the range test (v2.6.10), null = not shown.
  final RangeRunLine? rangeTest;

  /// Which GPS is "where I am" (v2.6.7), null = not shown.
  final LocationChoice? location;

  /// Runs a path's fix button (v2.6.3); null = no buttons.
  final void Function(FixAction)? onFix;

  /// "More connection details" (the full status sheet), null = hidden.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = healthColor(health.level, cs);
    return Column(
      key: const Key('connection-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              Icon(health.pathIcon, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  health.headline,
                  key: const Key('connection-headline'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
        ),
        for (final r in health.reasons.skip(
          health.level == HealthLevel.good ? 0 : 1,
        ))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
            child: Text('• $r', style: theme.textTheme.bodyMedium),
          ),
        const Divider(height: 16),
        for (final p in health.paths) ...[
          ListTile(
            key: Key('path-${p.name}'),
            dense: true,
            leading: Icon(p.icon, color: healthColor(p.level, cs)),
            title: Text(p.active ? '${p.name} · in use' : p.name),
            subtitle: Text(p.text),
            trailing: Semantics(
              label: healthWord(p.level),
              child: Icon(
                Icons.circle,
                size: 12,
                color: healthColor(p.level, cs),
              ),
            ),
          ),
          if (onFix != null && p.fixes.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 4),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final f in p.fixes)
                      OutlinedButton(
                        key: Key('fix-${p.name}-${f.name}'),
                        onPressed: () => onFix!(f),
                        child: Text(f.label),
                      ),
                  ],
                ),
              ),
            ),
        ],
        if (health.homeLine != null) ...[
          const Divider(height: 16),
          ListTile(
            key: const Key('path-home'),
            dense: true,
            leading: const Icon(Icons.cell_tower),
            title: Text(health.homeLine!),
            subtitle: health.signalText == null
                ? null
                : Text('Signal: ${health.signalText}'),
          ),
          if (health.homeNote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(health.homeNote!, style: theme.textTheme.bodySmall),
            ),
        ],
        if (rangeTest != null) ...[
          const Divider(height: 16),
          ListTile(
            key: const Key('connection-range-test'),
            dense: true,
            leading: Icon(
              rangeTest!.running ? Icons.stop_circle : Icons.radar,
              color: rangeTest!.running ? Colors.redAccent : null,
            ),
            title: Text(
              rangeTest!.running
                  ? 'Range test running · ${rangeTest!.elapsed.inMinutes} min'
                  : 'Range test to ${rangeTest!.homeName}',
            ),
            subtitle: Text(
              rangeTest!.running
                  ? 'Stop to see the furthest reply, signal and connected %.'
                  : 'One tap: pings it and marks where you connect and drop '
                        'on the Trip map.',
            ),
            trailing: FilledButton.tonal(
              key: const Key('connection-range-test-go'),
              onPressed: rangeTest!.onTap,
              child: Text(rangeTest!.running ? 'Stop' : 'Start'),
            ),
            onTap: rangeTest!.onTap,
          ),
        ],
        if (battery != null) ...[
          const Divider(height: 16),
          Padding(
            key: const Key('connection-battery-mode'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: battery,
          ),
        ],
        if (location != null) ...[
          const Divider(height: 16),
          ListTile(
            key: const Key('location-source-line'),
            dense: true,
            leading: Icon(switch (location!.active) {
              ActiveLocation.radio => Icons.satellite_alt,
              ActiveLocation.phone => Icons.phone_android,
              ActiveLocation.none => Icons.gps_off,
            }),
            title: Text(location!.title),
            subtitle: Text(location!.subtitle),
          ),
        ],
        if (onMore != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
              child: TextButton(
                key: const Key('connection-more'),
                onPressed: onMore,
                child: const Text('More connection details'),
              ),
            ),
          ),
      ],
    );
  }
}

/// The range test button closes the sheet first (Talk then shows the
/// Trip map).
RangeRunLine? _closing(BuildContext ctx, RangeRunLine? l) => l == null
    ? null
    : RangeRunLine(
        running: l.running,
        homeName: l.homeName,
        elapsed: l.elapsed,
        onTap: () {
          Navigator.pop(ctx);
          l.onTap();
        },
      );

Future<void> showConnectionSheet(
  BuildContext context, {
  required ConnectionHealth Function() source,
  Listenable? listenable,
  VoidCallback? onMore,
  void Function(FixAction)? onFix,
  LocationChoice? Function()? location,
  RangeRunLine? Function()? rangeTest,
  Widget? battery,
}) => showAppSheet<void>(
  context: context,
  builder: (ctx) => ListenableBuilder(
    listenable: listenable ?? ValueNotifier(0),
    builder: (ctx, _) => ConnectionHealthSheet(
      health: source(),
      onFix: onFix,
      location: location?.call(),
      battery: battery,
      rangeTest: _closing(ctx, rangeTest?.call()),
      onMore: onMore == null
          ? null
          : () {
              Navigator.pop(ctx);
              onMore();
            },
    ),
  ),
);
