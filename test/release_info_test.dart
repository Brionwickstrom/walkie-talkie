import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/update/updater.dart';

Map<String, dynamic> rel(String tag, List<Map<String, dynamic>> assets) => {
  'tag_name': tag,
  'name': 'Walkie Talkie $tag',
  'body': 'Faster Wi-Fi.',
  'html_url': 'https://github.com/x/y/releases/tag/$tag',
  'assets': assets,
};

Map<String, dynamic> asset(String name) => {
  'name': name,
  'size': 1234,
  'browser_download_url': 'https://github.com/x/y/releases/download/v/$name',
};

void main() {
  test('picks WalkieTalkie.apk and parses fields', () {
    final r = ReleaseInfo.fromGitHubJson(
      rel('v1.1.0', [asset('other.apk'), asset('WalkieTalkie.apk')]),
    )!;
    expect(r.version.toString(), '1.1.0');
    expect(r.apkUrl.path, endsWith('/WalkieTalkie.apk'));
    expect(r.apkSize, 1234);
    expect(r.notes, 'Faster Wi-Fi.');
    expect(r.name, 'Walkie Talkie v1.1.0');
  });

  test('falls back to any .apk', () {
    final r = ReleaseInfo.fromGitHubJson(
      rel('v1.2.0', [asset('notes.txt'), asset('app-arm64.APK')]),
    )!;
    expect(r.apkUrl.path, endsWith('/app-arm64.APK'));
  });

  test('null without apk or with bad tag', () {
    expect(ReleaseInfo.fromGitHubJson(rel('v1.2.0', [asset('a.zip')])), isNull);
    expect(
      ReleaseInfo.fromGitHubJson(rel('nightly', [asset('WalkieTalkie.apk')])),
      isNull,
    );
  });
}
