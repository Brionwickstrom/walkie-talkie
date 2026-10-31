import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../lora/radio_match.dart';
import '../lora/saved_radios.dart' show radioSeen;
import '../lora/meshtastic_settings.dart' show radioPrecisionText;
import '../trip/range_test.dart' show defaultRangeHomeNode;

/// The saved radios as the match check sees them: the connected radio is
/// read from its live settings, the others from what they had when they
/// were last connected.
List<MatchRadio> matchRadiosOf(WalkieController c, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final dev = c.radioDevice;
  final s = dev.session;
  final live = dev.ready && s != null ? readingFromSession(s, t) : null;
  final homeId = c.trip?.range.homeNode ?? defaultRangeHomeNode;
  return [
    for (final r in c.savedRadios)
      MatchRadio(
        id: r.id,
        name: r.title,
        connected: live != null && r.id == dev.deviceId,
        reading: live != null && r.id == dev.deviceId ? live : r.reading,
        home: r.nodeId == homeId,
      ),
  ];
}

/// "Slot 20 · Hop 4 · BigfootNet Full (exact)".
String readingText(RadioReading r) => [
  if (r.slot != null) 'Slot ${slotText(r.slot)}',
  if (r.hop != null) 'Hop ${r.hop}',
  for (final e in r.precisions.entries)
    '${e.key} ${radioPrecisionText(e.value)}',
].join(' · ');

/// v2.6.1: "Radio match check" on the Radio settings page. Compares slot,
/// hop limit and channel location precision across the saved radios, says
/// in plain words what differs, and offers Fix for the connected radio.
class RadioMatchCard extends StatelessWidget {
  const RadioMatchCard({
    super.key,
    required this.controller,
    required this.canEdit,
    required this.onFix,
    this.targetId,
    this.onTarget,
    this.now,
  });

  final WalkieController controller;

  /// The connected radio can be changed right now.
  final bool canEdit;

  /// Fix pressed: the page confirms and writes [fix].
  final void Function(MatchFix fix, MatchRadio target) onFix;

  /// The radio picked as the reference, null = the default.
  final String? targetId;
  final ValueChanged<String?>? onTarget;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final t = now ?? DateTime.now();
    final radios = matchRadiosOf(controller, now: t);
    final m = RadioMatch.compare(radios, targetId: targetId);
    final s = controller.radioDevice.session;
    final conn = radios.where((r) => r.connected).firstOrNull;
    final target = m.target;

    MatchFix? fix;
    if (conn != null &&
        s != null &&
        target != null &&
        target.id != conn.id &&
        conn.reading != null &&
        target.reading != null) {
      fix = matchFix(conn.reading!, target.reading!, channelIndexByName(s));
    }
    final others = m.rows.any(
      (r) => r.radio.id != conn?.id && r.diffs.isNotEmpty,
    );

    final String headline;
    if (radios.isEmpty) {
      headline = 'No radios saved yet.';
    } else if (m.checked < 2) {
      headline =
          'Not enough to compare yet: connect each of your radios once and '
          'the app remembers its settings.';
    } else if (m.allMatch) {
      headline = 'All ${m.checked} checked radios match: ${m.targetSummary}.';
    } else {
      headline = 'Your radios do not match.';
    }

    return Card(
      key: const Key('rs-match'),
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Radio match check', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              headline,
              key: const Key('rs-match-headline'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: m.checked >= 2 && !m.allMatch ? cs.error : null,
                fontWeight: FontWeight.w600,
              ),
            ),
            for (final p in m.problems)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('• $p', key: const Key('rs-match-problem')),
              ),
            const SizedBox(height: 8),
            for (final r in m.rows) _row(context, r, m, t),
            if (m.checked >= 2 && onTarget != null && target != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Text('Match to ', style: small),
                    Flexible(
                      child: DropdownButton<String>(
                        key: const Key('rs-match-target'),
                        value: target.id,
                        isDense: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final r in radios)
                            if (r.reading != null)
                              DropdownMenuItem(
                                value: r.id,
                                child: Text(
                                  r.home ? '${r.name} (home base)' : r.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                        ],
                        onChanged: onTarget == null
                            ? null
                            : (v) => onTarget!(v),
                      ),
                    ),
                  ],
                ),
              ),
            if (fix != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.icon(
                  key: const Key('rs-match-fix'),
                  icon: const Icon(Icons.build_circle_outlined),
                  label: Text('Fix ${conn!.name} to match ${target!.name}'),
                  onPressed: canEdit ? () => onFix(fix!, target) : null,
                ),
              ),
            if (fix == null &&
                conn != null &&
                target != null &&
                target.id == conn.id &&
                others)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${conn.name} is the one the others should match. To fix '
                  'another radio, connect to it (Settings > Long-range radio '
                  '> Saved radios) and open this page.',
                  key: const Key('rs-match-hint'),
                  style: small,
                ),
              ),
            if (conn == null && radios.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Connect a radio to fix it.',
                  key: const Key('rs-match-hint'),
                  style: small,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Only the radio connected to this phone is read and changed, '
                'with the same safe save as the rest of this page (previous '
                'settings kept, Restore previous settings). The app cannot '
                'read your other radios over the air, so they are shown as '
                'they were the last time they were connected. A frequency '
                'slot change needs every radio switched together.',
                key: const Key('rs-match-note'),
                style: small,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, MatchRow row, RadioMatch m, DateTime t) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final r = row.radio;
    final rd = r.reading;
    final isTarget = m.target?.id == r.id;
    final String status;
    if (rd == null) {
      status =
          'Not checked: not connected. Never read: connect it once and '
          'the app remembers it.';
    } else if (r.connected) {
      status = 'Connected now, read just now';
    } else {
      status =
          'Not checked: not connected. Last read ${radioSeen(rd.at, now: t)}.';
    }
    final bad = row.diffs.isNotEmpty;
    return Padding(
      key: Key('rs-match-row-${r.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            rd == null
                ? Icons.help_outline
                : bad
                ? Icons.error_outline
                : Icons.check_circle_outline,
            size: 20,
            color: rd == null
                ? cs.outline
                : bad
                ? cs.error
                : Colors.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.name}${r.home ? ' · home base' : ''}'
                  '${isTarget && m.checked >= 2 ? ' · reference' : ''}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (rd != null) Text(readingText(rd), style: small),
                Text(status, style: small),
                for (final d in row.diffs)
                  Text(
                    'Different: ${d.field} is ${d.have}, should be ${d.want}',
                    style: small?.copyWith(color: cs.error),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
