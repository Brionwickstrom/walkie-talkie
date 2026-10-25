import 'package:flutter_test/flutter_test.dart';
import 'package:walkie_talkie/update/app_version.dart';

AppVersion v(String s) => AppVersion.tryParse(s)!;

void main() {
  group('AppVersion.tryParse', () {
    test('parses common forms', () {
      expect(v('1.2.3').toString(), '1.2.3');
      expect(v('v1.2.3').toString(), '1.2.3');
      expect(v('V1.2.3+4').toString(), '1.2.3+4');
      expect(v('1.2').toString(), '1.2.0');
      expect(v('v2').toString(), '2.0.0');
      expect(v(' v1.1.0-beta.1+7 ').toString(), '1.1.0+7');
    });

    test('rejects junk', () {
      expect(AppVersion.tryParse(null), isNull);
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('1.x.3'), isNull);
      expect(AppVersion.tryParse('release-1.2.3'), isNull);
    });

    test('fromParts uses package_info fields', () {
      final r = AppVersion.fromParts('1.1.0', '2003')!;
      expect(r.toString(), '1.1.0+2003');
      expect(AppVersion.fromParts('1.1.0', '')!.build, isNull);
      expect(AppVersion.fromParts('nope', '3'), isNull);
    });
  });

  group('AppVersion compare', () {
    test('major/minor/patch ordering', () {
      expect(v('1.1.0').isNewerThan(v('1.0.0')), isTrue);
      expect(v('1.0.10').isNewerThan(v('1.0.9')), isTrue);
      expect(v('2.0.0').isNewerThan(v('1.99.99')), isTrue);
      expect(v('1.0.0').isNewerThan(v('1.1.0')), isFalse);
      expect(v('1.0.0').isNewerThan(v('1.0.0')), isFalse);
    });

    test('version beats build number', () {
      expect(v('1.1.0+1').isNewerThan(v('1.0.0+999')), isTrue);
    });

    test('build number breaks ties', () {
      expect(v('v1.1.0+4').isNewerThan(v('1.1.0+3')), isTrue);
      expect(v('v1.1.0+3').isNewerThan(v('1.1.0+4')), isFalse);
    });

    test('split-ABI versionCode is compared modulo 1000', () {
      // Installed arm64 build reports 2003 for build 3.
      expect(v('v1.1.0+3') == v('1.1.0+2003'), isTrue);
      expect(v('v1.1.0+3').isNewerThan(v('1.1.0+2003')), isFalse);
      expect(v('v1.1.0+4').isNewerThan(v('1.1.0+2003')), isTrue);
      expect(v('v1.1.1').isNewerThan(v('1.1.0+2003')), isTrue);
    });

    test('missing build on either side means same version', () {
      expect(v('v1.1.0').isNewerThan(v('1.1.0+2003')), isFalse);
      expect(v('v1.1.0+5').isNewerThan(v('1.1.0')), isFalse);
      expect(v('v1.1.0') == v('1.1.0+7'), isTrue);
    });

    test('installed 1.0.0+2001 sees v1.1.0 as newer', () {
      expect(v('v1.1.0').isNewerThan(v('1.0.0+2001')), isTrue);
    });
  });
}
