/// Canonical, human-verifiable app identity used by the canonical About
/// screen (Pack 3, locked policy 6).
///
/// Values mirror the locked `pubspec.yaml` (`version: 0.1.1+3`) and the
/// approved Next Transfer branding.  No runtime plugin is required because
/// the version is fixed per build in this project.
abstract final class AppInfo {
  static const String appName = 'Next Transfer';
  static const String tagline = 'The mission ended. The next transfer begins.';
  static const String version = '0.1.1';
  static const String buildNumber = '3';
}
