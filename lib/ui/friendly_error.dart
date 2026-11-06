// v2.6.3: showing a FriendlyError (lib/app/friendly_error.dart): one plain
// sentence, the fix button(s), and the technical text under "Details".
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/friendly_error.dart';
import '../app/link_settings.dart';
import '../app/setup.dart';
import '../app/walkie_controller.dart';
import '../lora/radio_share.dart';
import '../trip/battery_mode.dart';
import '../trip/location_source.dart';
import 'radio_settings.dart';
import 'radio_settings_page.dart' show openRadioSettings;
import 'sheets.dart';

export '../app/friendly_error.dart';

/// What the buttons that need a screen do. Everything else (permissions,
/// phone settings, the radio) runs from the controller.
class FixCallbacks {
  const FixCallbacks({
    this.retry,
    this.restoreBackup,
    this.turnOnLocationSharing,
    this.afterFix,
  });

  /// "Try again": do the thing again.
  final VoidCallback? retry;
  final VoidCallback? restoreBackup;
  final VoidCallback? turnOnLocationSharing;

  /// Called after a fix that may have solved it (a permission was given).
  final VoidCallback? afterFix;
}

/// Runs [a]. Permission fixes ask again (and open App info when the phone
/// will not ask any more); the rest open the right phone screen or act on
/// the controller.
Future<void> runFix(
  BuildContext context,
  WalkieController? controller,
  FixAction a, {
  FixCallbacks callbacks = const FixCallbacks(),
}) async {
  if (controller == null) {
    // A screen without the controller (maps): only its own callbacks work.
    switch (a) {
      case FixAction.retry:
        callbacks.retry?.call();
      case FixAction.restoreBackup:
        callbacks.restoreBackup?.call();
      case FixAction.turnOnLocationSharing:
        callbacks.turnOnLocationSharing?.call();
      default:
        break;
    }
    return;
  }
  final c = controller;
  switch (a) {
    case FixAction.turnOnBluetooth:
      await c.openPhoneSettings(PhoneSetting.bluetooth);
    case FixAction.allowNearby:
      if (await c.requestAppPermission(AppPermission.nearby)) {
        callbacks.afterFix?.call();
      }
    case FixAction.allowLocation:
      if (await c.requestAppPermission(AppPermission.location)) {
        callbacks.afterFix?.call();
      }
    case FixAction.turnOnLocation:
      await c.openPhoneSettings(PhoneSetting.location);
    case FixAction.allowMicrophone:
      if (await c.requestAppPermission(AppPermission.microphone)) {
        c.clearError();
        callbacks.afterFix?.call();
      }
    case FixAction.allowNotifications:
      if (await c.requestAppPermission(AppPermission.notifications)) {
        callbacks.afterFix?.call();
      }
    case FixAction.allowCamera:
      final st = await Permission.camera.request();
      if (st.isPermanentlyDenied) {
        await c.openPhoneSettings(PhoneSetting.appInfo);
      } else if (st.isGranted) {
        callbacks.afterFix?.call();
      }
    case FixAction.openAppSettings:
    case FixAction.allowMobileData:
      await c.openPhoneSettings(PhoneSetting.appInfo);
    case FixAction.wifiSettings:
      await c.openPhoneSettings(PhoneSetting.wifi);
    case FixAction.allowDnd:
      await c.bridge.openDndSettings();
    case FixAction.connectRadio:
      final started = await c.reconnectRadio();
      if (!started && context.mounted) {
        await showAppSheet<void>(
          context: context,
          scrollable: false,
          builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: RadioSettings(controller: c),
            ),
          ),
        );
      }
      callbacks.afterFix?.call();
    case FixAction.retry:
      callbacks.retry?.call();
    case FixAction.restoreBackup:
      callbacks.restoreBackup?.call();
    case FixAction.turnOnLocationSharing:
      callbacks.turnOnLocationSharing?.call();
    case FixAction.openRadioSettings:
      if (!c.radioDevice.ready) {
        await runFix(context, c, FixAction.connectRadio, callbacks: callbacks);
      } else if (context.mounted) {
        await openRadioSettings(
          context,
          c,
          jumpTo: c.locationChoice?.why == RadioGpsWhy.blurred
              ? 'radio-precision'
              : 'radio-location',
        );
      }
    case FixAction.usePhoneGps:
      await c.setLocationSource(LocationSource.auto);
      callbacks.afterFix?.call();
    case FixAction.useFreePort:
      final p =
          c.radioShareFreePort ??
          await RadioShareHub.freePortAfter(c.settings.radioSharePort);
      if (p != null) await c.setRadioSharePort(p);
      callbacks.afterFix?.call();
    case FixAction.stopRadioShare:
      await c.setRadioShareLocal(false);
      callbacks.afterFix?.call();
    case FixAction.stopRangeTest:
      await c.trip?.rangeRun.stop();
      callbacks.afterFix?.call();
    case FixAction.useTrackingMode:
      await _useMode(context, c, BatteryMode.tracking);
      callbacks.afterFix?.call();
    case FixAction.useNormalMode:
      await _useMode(context, c, BatteryMode.normal);
      callbacks.afterFix?.call();
  }
}

/// v2.6.12: a fix button that switches the Battery mode.
Future<void> _useMode(
  BuildContext context,
  WalkieController c,
  BatteryMode m,
) async {
  final fe = await c.trip?.setBatteryMode(m);
  if (fe != null && context.mounted) showFriendlySnack(context, fe, c);
}

/// The raw text in a dialog (for snack bars, which have room for one
/// button).
Future<void> showErrorDetails(BuildContext context, String details) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('fe-details-dialog'),
        scrollable: true,
        title: const Text('Details'),
        content: SelectableText(details),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );

/// A snack bar with the message and its first fix button. With no fix but
/// Details, the button is "Details". [callbacks] lets Try again work.
void showFriendlySnack(
  BuildContext context,
  FriendlyError fe,
  WalkieController? c, {
  FixCallbacks callbacks = const FixCallbacks(),
}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  final fix = fe.fixes
      .where((f) => _available(f, callbacks, c != null))
      .firstOrNull;
  final hasDetails = fe.details?.isNotEmpty ?? false;
  SnackBarAction? action;
  if (fix != null) {
    action = SnackBarAction(
      label: fix.label,
      onPressed: () => runFix(context, c, fix, callbacks: callbacks),
    );
  } else if (hasDetails) {
    action = SnackBarAction(
      label: 'Details',
      onPressed: () => showErrorDetails(context, fe.details!),
    );
  }
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(fe.message),
        action: action,
      ),
    );
}

bool _available(FixAction f, FixCallbacks cb, bool hasController) =>
    switch (f) {
      FixAction.retry => cb.retry != null,
      FixAction.restoreBackup => cb.restoreBackup != null,
      FixAction.turnOnLocationSharing => cb.turnOnLocationSharing != null,
      _ => hasController,
    };

/// An error in the page: the sentence, buttons, and "Details" that opens
/// the technical text. [onDismiss] adds a close button.
class FriendlyErrorView extends StatelessWidget {
  const FriendlyErrorView({
    super.key,
    required this.error,
    required this.onFix,
    this.onDismiss,
    this.color,
    this.keyFor,
  });
  final FriendlyError error;

  /// A button was tapped.
  final void Function(FixAction) onFix;
  final VoidCallback? onDismiss;
  final Color? color;

  /// Different keys for some buttons (tests that know a button by an old key).
  final Key? Function(FixAction)? keyFor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.error;
    final details = error.details;
    return Column(
      key: const Key('fe-view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                error.message,
                key: const Key('fe-message'),
                style: TextStyle(color: c),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                key: const Key('fe-dismiss'),
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: onDismiss,
              ),
          ],
        ),
        if (error.fixes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < error.fixes.length; i++)
                  i == 0
                      ? FilledButton.tonal(
                          key:
                              keyFor?.call(error.fixes[i]) ??
                              Key('fe-fix-${error.fixes[i].name}'),
                          onPressed: () => onFix(error.fixes[i]),
                          child: Text(error.fixes[i].label),
                        )
                      : OutlinedButton(
                          key:
                              keyFor?.call(error.fixes[i]) ??
                              Key('fe-fix-${error.fixes[i].name}'),
                          onPressed: () => onFix(error.fixes[i]),
                          child: Text(error.fixes[i].label),
                        ),
              ],
            ),
          ),
        if (details != null && details.isNotEmpty)
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const Key('fe-details'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text('Details', style: theme.textTheme.bodySmall),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  details,
                  key: const Key('fe-details-text'),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
