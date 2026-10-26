import 'package:flutter/material.dart';

import '../app/link_settings.dart';
import '../core/transport.dart';
import 'home_view.dart';

/// Sheet shown when a connection icon is tapped (v1.8.5): what the link
/// is doing now and one button to the matching settings, so a tap never
/// jumps out of the app by surprise.
class LinkSheetView extends StatelessWidget {
  const LinkSheetView({
    super.key,
    required this.kind,
    required this.info,
    required this.onAction,
  });
  final TransportKind kind;
  final LinkInfo info;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = info.connected
        ? Colors.green
        : info.permissionMissing
        ? theme.colorScheme.error
        : theme.colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(transportIcon(kind), color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  info.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            info.state,
            key: const Key('link-state'),
            style: theme.textTheme.titleMedium?.copyWith(color: color),
          ),
          const SizedBox(height: 6),
          Text(info.help, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('link-open-settings'),
            icon: Icon(
              info.setting == PhoneSetting.radioPairing
                  ? Icons.settings_input_antenna
                  : info.permissionMissing
                  ? Icons.lock_open
                  : Icons.settings,
            ),
            label: Text(info.button),
            onPressed: onAction,
          ),
        ],
      ),
    );
  }
}
