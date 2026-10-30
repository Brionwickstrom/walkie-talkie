import 'package:flutter/material.dart';

import '../app/walkie_controller.dart';
import '../weather/weather_alerts.dart';
import '../weather/wx_alert.dart';
import '../weather/wx_notice.dart';
import 'adaptive_layout.dart';

/// Weather alerts (v2.5.0): what the National Weather Service warns about
/// for where you are and the places you saved. A page on phones, a dialog
/// on wide screens (like Messages). Quiet: no banner, no red wall; the Talk
/// screen only gets a small icon while a warning is in force.
Future<void> openWeatherAlerts(BuildContext context, WalkieController c) {
  final size = MediaQuery.sizeOf(context);
  if (isTwoPane(size.width, size.height)) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const Key('alerts-dialog'),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: WeatherAlertsPage(controller: c, dialog: true),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => WeatherAlertsPage(controller: c)),
  );
}

class WeatherAlertsPage extends StatefulWidget {
  const WeatherAlertsPage({
    super.key,
    required this.controller,
    this.dialog = false,
  });
  final WalkieController controller;
  final bool dialog;

  @override
  State<WeatherAlertsPage> createState() => _WeatherAlertsPageState();
}

class _WeatherAlertsPageState extends State<WeatherAlertsPage> {
  bool _checking = false;

  Future<void> _refresh() async {
    final w = widget.controller.weatherAlerts;
    if (w == null || _checking) return;
    setState(() => _checking = true);
    await w.poll(force: true);
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.controller.weatherAlerts;
    final theme = Theme.of(context);
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
        title: const Text('Weather alerts'),
        actions: [
          if (w != null)
            IconButton(
              key: const Key('alerts-refresh'),
              tooltip: 'Check now',
              icon: _checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
        ],
      ),
      body: SafeArea(
        child: w == null
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Weather alerts are starting…'),
              )
            : ListenableBuilder(
                listenable: w,
                builder: (context, _) {
                  final now = DateTime.now();
                  final list = w.active;
                  return ListView(
                    key: const Key('alerts-list'),
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      if (list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Text(
                            w.isOn ? 'No warnings for your area.' : 'Weather alerts are off. Turn them on in Settings.',
                            key: const Key('alerts-empty'),
                            style: theme.textTheme.bodyLarge,
                          ),
                        ),
                      for (var i = 0; i < list.length; i++)
                        _AlertCard(
                          key: Key('wx-alert-$i'),
                          a: list[i],
                          now: now,
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          w.statusLine(),
                          key: const Key('alerts-status'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (w.isOn) _AreasList(w),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _AreasList extends StatelessWidget {
  const _AreasList(this.w);
  final WeatherAlerts w;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final areas = w.areas;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            areas.isEmpty
                ? 'No place to watch yet. Open the Trip map once, or save an '
                      'offline area.'
                : 'Areas covered',
            key: const Key('alerts-areas'),
            style: style,
          ),
          for (final a in areas) Text(a.text, style: style),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({super.key, required this.a, required this.now});
  final WxAlert a;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final head = a.headline.isEmpty ? '' : WxAlert.unwrap(a.headline);
    final todo = a.instruction.isEmpty ? '' : WxAlert.unwrap(a.instruction);
    final desc = a.description.isEmpty ? '' : WxAlert.unwrap(a.description);
    final dim = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final issued = wxClock(a.issued.toLocal(), now: now);
    final until = wxClock(a.expiresAt.toLocal(), now: now);
    final trust = switch (a.trust) {
      WxTrust.unconfirmed =>
        'Unconfirmed, from ${a.fromName.isNotEmpty ? a.fromName : 'another device'}',
      WxTrust.confirmed => 'Confirmed by your group',
      WxTrust.nws => null,
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  a.isExtreme
                      ? Icons.thunderstorm
                      : Icons.warning_amber_rounded,
                  size: 20,
                  color: a.isExtreme ? cs.error : Colors.amber,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(a.event, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            if (a.areaDesc.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(a.areaDesc, style: theme.textTheme.bodyMedium),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Issued $issued · Expires $until', style: dim),
            ),
            if (head.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(head, style: theme.textTheme.bodyMedium),
              ),
            if (todo.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: 'What to do: ',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: todo),
                    ],
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            if (desc.isNotEmpty)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  dense: true,
                  title: Text('Details', style: dim),
                  children: [Text(desc, style: theme.textTheme.bodySmall)],
                ),
              ),
            const SizedBox(height: 6),
            if (trust != null)
              Text(
                trust,
                style: dim?.copyWith(
                  color: a.trust == WxTrust.unconfirmed ? Colors.amber : null,
                ),
              ),
            Text(a.source.label, key: const Key('wx-source'), style: dim),
          ],
        ),
      ),
    );
  }
}

/// Settings > Weather alerts.
class WeatherAlertsSettings extends StatelessWidget {
  const WeatherAlertsSettings({super.key, required this.controller});
  final WalkieController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final w = c.weatherAlerts;
        final dim = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('wx-on'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Weather alerts'),
              subtitle: Text(
                'Warnings from the National Weather Service for where you '
                'are and the places you saved (US only). Checked every 10 '
                'minutes while the app is listening or open; only a few '
                'KB each time.'
                '${c.bridge.supported ? '' : ' On this computer they show in the app while it is running.'}',
              ),
              value: c.settings.wxAlerts,
              onChanged: c.setWxAlerts,
            ),
            if (c.settings.wxAlerts) ...[
              SwitchListTile(
                key: const Key('wx-wifi'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Wi-Fi only'),
                subtitle: const Text(
                  'Do not check on mobile data. Alerts can arrive late '
                  'while you are away from Wi-Fi.',
                ),
                value: c.settings.wxWifiOnly,
                onChanged: c.setWxWifiOnly,
              ),
              SwitchListTile(
                key: const Key('wx-extreme'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Extreme alerts can sound anytime'),
                subtitle: Text(
                  'Tornado Warnings and other Extreme alerts sound an alarm '
                  'even in quiet hours and Do Not Disturb. Off: they still '
                  'show on the lock screen, but stay quiet in quiet hours '
                  'and Do Not Disturb.'
                  '${c.settings.wxExtremeSound && c.bridge.supported ? ' Android also needs Do Not Disturb access for this app.' : ''}',
                ),
                value: c.settings.wxExtremeSound,
                onChanged: c.setWxExtremeSound,
              ),
              if (c.settings.wxExtremeSound && c.bridge.supported)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('wx-dnd'),
                    onPressed: c.bridge.openDndSettings,
                    child: const Text('Allow Do Not Disturb access'),
                  ),
                ),
              ListTile(
                key: const Key('wx-open'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Alerts'),
                subtitle: Text(w?.statusLine() ?? 'Starting…'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openWeatherAlerts(context, c),
              ),
              if (w != null) ...[
                Text(
                  w.areas.isEmpty
                      ? 'Areas covered: none yet. Alerts start once the app '
                            'knows where you are (open the Trip map once) or '
                            'you save an offline area. Weather alerts never '
                            'turn the GPS on.'
                      : 'Areas covered',
                  key: const Key('wx-areas'),
                  style: dim,
                ),
                for (final a in w.areas) Text(a.text, style: dim),
              ],
            ],
          ],
        );
      },
    );
  }
}
