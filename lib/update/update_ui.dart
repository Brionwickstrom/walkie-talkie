import 'dart:io';

import 'package:flutter/material.dart';

import 'updater.dart';

/// Dialog flow around [Updater]: "update available" -> download with
/// progress -> make sure installs are allowed -> system installer.
class UpdateFlow {
  UpdateFlow([Updater? updater]) : updater = updater ?? Updater();

  final Updater updater;
  bool _busy = false;
  String? _dismissedTag; // "Later" on the startup check, this session only

  /// Checks GitHub and, if a newer release exists, offers it.
  /// [userInitiated] also reports "up to date" and errors.
  Future<void> check(BuildContext context, {bool userInitiated = false}) async {
    if (!Updater.supported && !Updater.desktopSupported) {
      if (userInitiated && context.mounted) {
        _snack(context, 'Updates are installed from the App Store on this device.');
      }
      return;
    }
    if (_busy) return;
    _busy = true;
    try {
      final ReleaseInfo? rel;
      try {
        rel = await updater.checkForUpdate();
      } catch (e) {
        if (userInitiated && context.mounted) {
          _snack(context, 'Could not check for updates. Check your internet.');
        }
        return;
      }
      if (!context.mounted) return;
      if (rel == null) {
        if (userInitiated) {
          final cur = await updater.currentVersionLabel();
          if (context.mounted) _snack(context, 'You have the latest version ($cur).');
        }
        return;
      }
      if (!userInitiated && rel.tag == _dismissedTag) return;
      final ok = await _offer(context, rel);
      if (ok != true) {
        _dismissedTag = rel.tag;
        return;
      }
      if (!Updater.supported) {
        // Windows: the browser downloads the new zip.
        try {
          await updater.openInBrowser(rel.apkUrl);
          if (context.mounted) {
            _snack(
              context,
              'Downloading in your browser. Close Walkie Talkie, unzip it '
              'over the old folder and start WalkieTalkie.exe again.',
            );
          }
        } catch (e) {
          if (context.mounted) _snack(context, 'Open ${rel.apkUrl} to download it.');
        }
        return;
      }
      if (context.mounted) await _downloadAndInstall(context, rel);
    } finally {
      _busy = false;
    }
  }

  Future<bool?> _offer(BuildContext context, ReleaseInfo rel) async {
    final cur = await updater.currentVersionLabel();
    if (!context.mounted) return false;
    final size = rel.apkSize == null
        ? ''
        : ' (${(rel.apkSize! / (1024 * 1024)).toStringAsFixed(1)} MB)';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update available: ${rel.version}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('You have $cur.'),
              if (rel.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text("What's new", style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(rel.notes),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(Updater.supported ? 'Update$size' : 'Download$size'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(BuildContext context, ReleaseInfo rel) async {
    final progress = ValueNotifier<double?>(0);
    var cancelled = false;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Downloading update'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, p, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: p),
                const SizedBox(height: 8),
                Text(p == null ? '' : '${(p * 100).round()}%'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.pop(ctx);
              },
              child: const Text('Hide'),
            ),
          ],
        ),
      ),
    );
    File? apk;
    Object? error;
    try {
      apk = await updater.download(rel, onProgress: (p) => progress.value = p);
    } catch (e) {
      error = e;
    }
    if (!cancelled && context.mounted) Navigator.of(context).pop();
    await dialog;
    progress.dispose();
    if (!context.mounted) return;
    if (apk == null) {
      _snack(context, 'Update download failed: $error');
      return;
    }
    await _install(context, apk);
  }

  Future<void> _install(BuildContext context, File apk) async {
    // Android 8+: the user has to allow "Install unknown apps" for us once.
    while (!await updater.canInstall()) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow installing updates'),
          content: const Text(
            'To install updates, Android needs you to allow Walkie Talkie to '
            'install apps (one time only).\n\n'
            'Tap "Open settings", turn on "Allow from this source", then come '
            'back here.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (go != true) return;
      await updater.openInstallSettings();
      if (!context.mounted) return;
      final again = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ready to install?'),
          content: const Text(
            'Once you have turned on "Allow from this source", tap Install.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Install'),
            ),
          ],
        ),
      );
      if (again != true) return;
    }
    try {
      await updater.install(apk);
    } catch (e) {
      if (context.mounted) _snack(context, 'Could not open the installer: $e');
    }
  }

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));
  }
}
