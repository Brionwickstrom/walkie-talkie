/// A parsed app version like `1.2.3+4` (also accepts a leading `v`, e.g. the
/// GitHub release tag `v1.2.3` or `v1.2.3+4`).
///
/// Comparison is by major.minor.patch first, then by build number. Android
/// split-per-ABI builds report their build number as `1000 * abi + build`
/// (e.g. build 3 on arm64 -> versionCode 2003), so the build is compared
/// modulo 1000 to make `1.1.0+2003` (installed) equal to tag `v1.1.0+3`.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build]);

  final int major;
  final int minor;
  final int patch;

  /// Optional build number; null when the string had none.
  final int? build;

  static final RegExp _re = RegExp(
    r'^\s*[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-[0-9A-Za-z.\-]+)?(?:\+(\d+))?\s*$',
  );

  /// Parses `1.2.3`, `v1.2.3`, `1.2`, `1.2.3+4`, `v1.2.3-beta+4`.
  /// Returns null if [s] is not a version.
  static AppVersion? tryParse(String? s) {
    if (s == null) return null;
    final m = _re.firstMatch(s);
    if (m == null) return null;
    return AppVersion(
      int.parse(m.group(1)!),
      int.parse(m.group(2) ?? '0'),
      int.parse(m.group(3) ?? '0'),
      m.group(4) == null ? null : int.parse(m.group(4)!),
    );
  }

  /// Builds the running version from package_info_plus fields.
  static AppVersion? fromParts(String version, String buildNumber) {
    final v = tryParse(version);
    if (v == null) return null;
    return AppVersion(v.major, v.minor, v.patch, int.tryParse(buildNumber));
  }

  int? get _normBuild => build == null ? null : build! % 1000;

  @override
  int compareTo(AppVersion o) {
    if (major != o.major) return major.compareTo(o.major);
    if (minor != o.minor) return minor.compareTo(o.minor);
    if (patch != o.patch) return patch.compareTo(o.patch);
    final a = _normBuild, b = o._normBuild;
    // Only compare builds when both sides have one.
    if (a == null || b == null) return 0;
    return a.compareTo(b);
  }

  bool isNewerThan(AppVersion o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() =>
      '$major.$minor.$patch${build == null ? '' : '+$build'}';
}
