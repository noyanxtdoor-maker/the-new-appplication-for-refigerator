// `workmanager` re-exports the platform interface, so `WorkmanagerPlatform`
// resolves from this single import.
import 'package:workmanager/workmanager.dart';

/// Installs [platform] as the active WorkManager implementation for a test.
///
/// ## Why this is a function instead of a bare assignment
///
/// `Workmanager` is a lazily-initialised singleton that, on its **first** touch
/// in an isolate, installs a host-OS platform implementation over whatever the
/// platform interface currently holds
/// (`workmanager/lib/src/workmanager_impl.dart`):
///
/// ```dart
/// factory Workmanager() => _instance;
/// Workmanager._internal() { _ensurePlatformImplementation(); }
/// static final Workmanager _instance = Workmanager._internal();  // runs ONCE
///
/// static void _ensurePlatformImplementation() {
///   if (WorkmanagerPlatform.instance is! WorkmanagerAndroid &&
///       WorkmanagerPlatform.instance is! WorkmanagerApple) {
///     if (Platform.isAndroid) { WorkmanagerPlatform.instance = WorkmanagerAndroid(); }
///     else if (Platform.isIOS || Platform.isMacOS) { … }
///     else if (Platform.isLinux) { WorkmanagerPlatform.instance = WorkmanagerLinux(); }
///   }
/// }
/// ```
///
/// A test that assigns `WorkmanagerPlatform.instance` and then calls
/// `FlutterLocalNotificationsGateway().schedule(...)` — which evaluates
/// `Workmanager()` to cancel the retired delivery tag — therefore loses its fake
/// on the first `schedule()` in the isolate. That failure is **platform
/// dependent**, because the registration has no `Platform.isWindows` branch:
///
/// * On **Linux** the fake is replaced by `WorkmanagerLinux()`, whose
///   `cancelByTag` throws `UnsupportedError` — the test fails with an exception
///   that has nothing to do with the notification contract it is asserting.
/// * On **Windows** nothing is assigned, the fake survives, and the same test
///   passes.
///
/// Because the singleton is `static final`, that registration happens at most
/// once per isolate and `_platform` is read through a getter at call time.
/// Touching the singleton first therefore consumes the one-time registration,
/// and a fake installed immediately afterwards survives on every host platform.
///
/// This keeps the assertions in the calling test exactly as strong as they were:
/// no expectation is relaxed, made platform-conditional, or skipped. Production
/// code is not involved — it never exercises the Linux branch, because the app
/// ships for Android only.
void installWorkmanagerPlatform(WorkmanagerPlatform platform) {
  // Consume `Workmanager`'s one-time host-OS platform registration. The
  // returned singleton is deliberately unused; only its initialisation matters.
  Workmanager();
  WorkmanagerPlatform.instance = platform;
}
