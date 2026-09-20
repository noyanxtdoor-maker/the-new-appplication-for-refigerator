import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// OWNER HOTFIX (2026-09-19) — reminder delivery must never crash the process.
///
/// PROVEN DEFECT (device evidence, Infinix X6731 / build 3):
///
///   java.lang.RuntimeException: Unable to start receiver
///     com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver:
///     java.lang.NullPointerException: Attempt to invoke virtual method
///     'int java.lang.Integer.intValue()' on a null object reference
///   Caused by: ... at FlutterLocalNotificationsPlugin.setSmallIcon
///                       -> createNotification -> showNotification
///                       -> ScheduledNotificationReceiver.onReceive
///
/// Chain:
///   1. `ic_nt_notification` is referenced only from Dart, as a runtime resource
///      NAME, so the release resource shrinker removed it from the shipped bundle
///      (`aapt2 dump resources` finds `launch_background`/`ic_launcher*` but NOT
///      `drawable/ic_nt_notification`).
///   2. The plugin's `initialize()` validates the drawable and RETURNS EARLY without
///      persisting `defaultIcon` when the check fails. `main.dart` swallows that
///      error, so the failure is silent.
///   3. Every reminder the app scheduled carried `icon == null`, so at alarm time
///      the plugin fell through to `setSmallIcon(notificationDetails.iconResourceId)`
///      and unboxed a null `Integer` — killing the process before the notification
///      was posted. The user sees the reminder never arrive and the app disappear.
///
/// These guards are regression protection for the two independent halves of the fix:
/// the drawable must be KEPT in the release bundle, and every notification must NAME
/// its icon instead of depending on the startup-registered default.
void main() {
  final keepFile = File('android/app/src/main/res/raw/keep.xml');
  final gateway = File(
    'lib/core/notifications/flutter_local_notifications_gateway.dart',
  );
  final badgeGateway = File(
    'lib/core/notifications/flutter_local_notifications_launcher_badge_gateway.dart',
  );

  group(
    'D28 the notification drawable survives the release resource shrinker',
    () {
      test('res/raw/keep.xml keeps @drawable/ic_nt_notification', () {
        expect(
          keepFile.existsSync(),
          isTrue,
          reason:
              'Without this file the release build strips the drawable that the '
              'plugin resolves by name at runtime, which is the delivery crash.',
        );
        final source = keepFile.readAsStringSync().replaceAll('\r\n', '\n');
        expect(
          source.contains('tools:keep="@drawable/ic_nt_notification"'),
          isTrue,
          reason: 'the exact drawable the gateway names must be kept',
        );
      });
    },
  );

  group('D29 every notification names its icon explicitly', () {
    test('the shared resource constant is a bare drawable name', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains(
          "const String ntNotificationIconResource = 'ic_nt_notification';",
        ),
        isTrue,
        reason:
            'The plugin passes this string straight to '
            'getResourceIdentifier(name, "drawable", package), so it must be the '
            'bare resource name — no @drawable/ prefix and no slash.',
      );
    });

    test('the reminder/transient gateway sets an icon on every notification', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        _count(source, 'AndroidNotificationDetails('),
        _count(source, 'icon: ntNotificationIconResource'),
        reason:
            'Every AndroidNotificationDetails must name its icon, so a missing '
            'startup default can never take the process down again.',
      );
      expect(_count(source, 'AndroidNotificationDetails('), greaterThan(0));
    });

    test('the launcher-badge gateway sets an icon too', () {
      final source = badgeGateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        _count(source, 'AndroidNotificationDetails('),
        _count(source, 'icon: ntNotificationIconResource'),
      );
      expect(_count(source, 'AndroidNotificationDetails('), greaterThan(0));
    });

    test('the initialization still registers the same drawable by name', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains(
          "AndroidInitializationSettings('@drawable/ic_nt_notification')",
        ),
        isTrue,
      );
      // The full-color launcher icon must never be the notification small icon.
      expect(source.contains('mipmap'), isFalse);
    });
  });
}

int _count(String haystack, String needle) {
  var count = 0;
  var index = haystack.indexOf(needle);
  while (index != -1) {
    count += 1;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}
