import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_version.dart';

/// Where releases are published. Public repo, so no token is needed.
const String kReleasesRepo = 'Brionwickstrom/walkie-talkie';
const String kLatestReleaseApi =
    'https://api.github.com/repos/$kReleasesRepo/releases/latest';

/// Release assets: the Android app (what phones update to, and what the
/// is.gd/getwalkie short link downloads) and the Windows app (v1.9.6).
const String kApkAsset = 'WalkieTalkie.apk';
const String kWindowsAsset = 'WalkieTalkie-Windows.zip';

/// Always the newest Windows download.
const String kWindowsLatestUrl =
    'https://github.com/$kReleasesRepo/releases/latest/download/$kWindowsAsset';

/// A GitHub release that has an installable APK attached.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.name,
    required this.notes,
    required this.apkUrl,
    required this.apkSize,
    required this.pageUrl,
  });

  final String tag;
  final AppVersion version;
  final String name;
  final String notes;
  final Uri apkUrl;
  final int? apkSize;
  final String? pageUrl;

  /// Parses GitHub's `releases/latest` JSON. Returns null if there is no
  /// usable version tag or no .apk asset. Prefers an asset named
  /// `WalkieTalkie.apk`, else the first `.apk`. Never picks the Windows zip
  /// (v1.9.6 attaches `WalkieTalkie-Windows.zip` to the same release).
  static ReleaseInfo? fromGitHubJson(Map<String, dynamic> j) =>
      _fromGitHubJson(j, ext: '.apk', preferred: kApkAsset);

  /// The Windows desktop download (v1.9.6) of the same release JSON:
  /// `WalkieTalkie-Windows.zip`, else the first `.zip` with "windows" in
  /// its name; null when the release has none. [apkUrl] is the zip.
  static ReleaseInfo? windowsFromGitHubJson(Map<String, dynamic> j) =>
      _fromGitHubJson(
        j,
        ext: '.zip',
        preferred: kWindowsAsset,
        nameFilter: (n) => n.contains('windows'),
      );

  static ReleaseInfo? _fromGitHubJson(
    Map<String, dynamic> j, {
    required String ext,
    required String preferred,
    bool Function(String lowerName)? nameFilter,
  }) {
    final tag = j['tag_name'] as String?;
    final version = AppVersion.tryParse(tag);
    if (tag == null || version == null) return null;
    final assets = (j['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((a) {
          final n = (a['name'] as String? ?? '').toLowerCase();
          return n.endsWith(ext) && (nameFilter == null || nameFilter(n));
        })
        .toList();
    if (assets.isEmpty) return null;
    final asset = assets.firstWhere(
      (a) => a['name'] == preferred,
      orElse: () => assets.first,
    );
    final url = Uri.tryParse(asset['browser_download_url'] as String? ?? '');
    if (url == null || !url.hasScheme) return null;
    final name = (j['name'] as String?)?.trim();
    return ReleaseInfo(
      tag: tag,
      version: version,
      name: (name == null || name.isEmpty) ? tag : name,
      notes: (j['body'] as String? ?? '').trim(),
      apkUrl: url,
      apkSize: (asset['size'] as num?)?.toInt(),
      pageUrl: j['html_url'] as String?,
    );
  }
}

/// Checks GitHub Releases for a newer APK, downloads it and hands it to the
/// Android package installer. Everything is a no-op on non-Android platforms.
class Updater {
  Updater({HttpClient Function()? httpClient})
    : _newClient = httpClient ?? HttpClient.new;

  static const MethodChannel _ch = MethodChannel('walkie/update');
  final HttpClient Function() _newClient;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Windows desktop app (v1.9.6): checks and offers the download link (no
  /// in-place install; the zip is unpacked over the old folder).
  static bool get desktopSupported => !kIsWeb && Platform.isWindows;

  AppVersion? _current;
  String _currentLabel = '';

  /// The running version, e.g. `1.1.0 (2003)`.
  Future<String> currentVersionLabel() async {
    await _loadCurrent();
    return _currentLabel;
  }

  Future<AppVersion?> _loadCurrent() async {
    if (_current != null) return _current;
    final info = await PackageInfo.fromPlatform();
    _current = AppVersion.fromParts(info.version, info.buildNumber);
    _currentLabel = info.buildNumber.isEmpty
        ? info.version
        : '${info.version} (${info.buildNumber})';
    return _current;
  }

  /// Returns the latest release if it is newer than the running app, else
  /// null. Throws on network / API errors.
  Future<ReleaseInfo?> checkForUpdate() async {
    if (!supported && !desktopSupported) return null;
    final current = await _loadCurrent();
    final client = _newClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(kLatestReleaseApi));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'walkie-talkie-updater');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) return null; // no releases yet
      if (res.statusCode != 200) {
        throw HttpException('GitHub returned ${res.statusCode}');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final rel = supported
          ? ReleaseInfo.fromGitHubJson(json)
          : ReleaseInfo.windowsFromGitHubJson(json);
      if (rel == null) return null;
      if (current != null && !rel.version.isNewerThan(current)) return null;
      return rel;
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads the APK to the app's cache dir. [onProgress] gets 0..1, or
  /// null when the size is unknown.
  Future<File> download(
    ReleaseInfo rel, {
    void Function(double? progress)? onProgress,
  }) async {
    final dir = await _ch.invokeMethod<String>('updateDir');
    if (dir == null) throw StateError('No download folder');
    final file = File('$dir/WalkieTalkie-${rel.version}.apk');
    final part = File('${file.path}.part');
    final client = _newClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(rel.apkUrl); // follows redirects
      req.headers.set(HttpHeaders.userAgentHeader, 'walkie-talkie-updater');
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('Download failed (${res.statusCode})');
      }
      final total = res.contentLength > 0 ? res.contentLength : rel.apkSize;
      final sink = part.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          got += chunk.length;
          onProgress?.call(total == null ? null : got / total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (total != null && got != total) {
        throw HttpException('Download incomplete ($got of $total bytes)');
      }
      if (await file.exists()) await file.delete();
      return await part.rename(file.path);
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Whether Android lets this app open the package installer
  /// ("Install unknown apps" for Walkie Talkie).
  Future<bool> canInstall() async =>
      await _ch.invokeMethod<bool>('canInstall') ?? false;

  /// Opens the "Install unknown apps" settings page for this app.
  Future<void> openInstallSettings() => _ch.invokeMethod('openInstallSettings');

  /// Desktop: open [url] in the default browser.
  Future<void> openInBrowser(Uri url) async {
    if (Platform.isWindows) {
      await Process.start('rundll32', [
        'url.dll,FileProtocolHandler',
        url.toString(),
      ]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url.toString()]);
    } else {
      await Process.start('xdg-open', [url.toString()]);
    }
  }

  /// Launches the system installer for [apk].
  Future<void> install(File apk) =>
      _ch.invokeMethod('install', {'path': apk.path});
}
