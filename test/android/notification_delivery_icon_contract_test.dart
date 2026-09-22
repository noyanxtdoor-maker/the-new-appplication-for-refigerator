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

  // POST-P2 OWNER DECISION (2026-09-22) — R1, the COLOUR half of the icon fix.
  //
  // The audit proved the reported green notification glyph was a colour
  // problem, not a debug artefact: no notification colour was supplied and no
  // `colorAccent`/`colorPrimary` is declared in any Android theme, so Android
  // tinted the monochrome small icon with the AppCompat fallback
  // (`@color/material_deep_teal_500` = #ff008577 — the green the owner saw).
  // The same artwork ships in debug, profile, release and the AAB, so the tint
  // had to be named explicitly rather than inherited. These guards keep it
  // named, on every path, and keep its value identical to the one approved
  // brand field the launch surfaces already use.
  group('D30 the notification tint is the approved brand blue, named explicitly', () {
    /// Every AndroidNotificationDetails construction in [source] must carry an
    /// explicit `color:` — the fallback is what produced the green.
    void expectTinted(String source, String label) {
      final details = _count(source, 'AndroidNotificationDetails(');
      expect(details, greaterThan(0), reason: '$label must post notifications');
      // Matched WITH the trailing comma: the doc comments above these fields
      // discuss them in prose, and a bare substring count would silently accept
      // a comment in place of the real argument.
      expect(
        _count(source, 'color: ntNotificationTint,'),
        details,
        reason:
            'every AndroidNotificationDetails in $label must name the brand '
            'colour: relying on the theme accent is exactly the defect',
      );
      expect(
        _count(source, 'colorized: false,'),
        details,
        reason:
            'the artwork stays untinted so Android applies the colour the '
            'canonical way for a small icon',
      );
    }

    test('the canonical reminder/transient gateway tints every path', () {
      expectTinted(
        gateway.readAsStringSync().replaceAll('\r\n', '\n'),
        'the reminder gateway',
      );
    });

    test('the launcher-badge gateway tints its path too', () {
      expectTinted(
        badgeGateway.readAsStringSync().replaceAll('\r\n', '\n'),
        'the launcher-badge gateway',
      );
    });

    test('the tint value is the single approved brand field', () {
      // #FF002161 is the one brand field the Android launch window, the Android
      // 12+ platform splash, the app-owned splash and the adaptive launcher
      // background already resolve (`@color/nt_brand_blue`). A second,
      // drifting value would put the notification glyph out of family with
      // everything around it, so the two must be parsed and compared rather
      // than trusted to stay in step by comment.
      final android = File(
        'android/app/src/main/res/values/colors.xml',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final match = RegExp(
        r'<color name="nt_brand_blue">(#[0-9A-Fa-f]{8})</color>',
      ).firstMatch(android);
      expect(
        match,
        isNotNull,
        reason: 'the approved brand colour resource must still exist',
      );
      final brandArgb = match!.group(1)!.toUpperCase();
      expect(brandArgb, '#FF002161');

      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      final tint = RegExp(
        r'const Color ntNotificationTint = Color\((0x[0-9A-Fa-f]{8})\)',
      ).firstMatch(source);
      expect(tint, isNotNull, reason: 'the tint must be one named constant');
      expect(
        '#${tint!.group(1)!.substring(2).toUpperCase()}',
        brandArgb,
        reason:
            'ntNotificationTint must resolve to the same value as '
            '@color/nt_brand_blue, so the notification glyph cannot drift out of '
            'the brand family',
      );
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
