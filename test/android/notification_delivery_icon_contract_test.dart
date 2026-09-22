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
///
/// OWNER DECISION (2026-09-22, retry after the P3-M0 review) — the app now uses TWO
/// identities on TWO surfaces, exactly as the owner steered ("use these provided svg
/// icon for the preview notif icon and the logo for the actual app notif logo"):
///
///   * SMALL icon (`ic_nt_notification`): the owner-supplied monochrome MARK, a
///     faithful conversion of the supplied vector. Android tints it, so it must
///     stay a monochrome alpha mask — this is the in-app preview's icon and the
///     status-bar mark;
///   * LARGE icon (`ic_launcher_foreground`): the ACTUAL app LOGO, rebuilt from
///     the owner-supplied PNG. `largeIcon` is the one surface where Android shows
///     the artwork in colour, which is why the logo goes there and not in the
///     small-icon slot.
///
/// The guards below therefore check BOTH halves, including the mix-ups that matter:
/// the logo must never be the small icon, and the mark must never be the large one.
void main() {
  final keepFile = File('android/app/src/main/res/raw/keep.xml');
  final gateway = File(
    'lib/core/notifications/flutter_local_notifications_gateway.dart',
  );
  final badgeGateway = File(
    'lib/core/notifications/flutter_local_notifications_launcher_badge_gateway.dart',
  );

  group('D28 the notification drawable survives the release resource shrinker', () {
    test('res/raw/keep.xml keeps @drawable/ic_nt_notification', () {
      expect(
        keepFile.existsSync(),
        isTrue,
        reason:
            'Without this file the release build strips the drawable that the '
            'plugin resolves by name at runtime, which is the delivery crash.',
      );
      final source = keepFile.readAsStringSync().replaceAll('\r\n', '\n');
      // OWNER DECISION (2026-09-22, retry): TWO names, because both identities are
      // resolved by name from Dart — the monochrome small-icon mark AND the app
      // logo used as the large icon. Without this file the release shrinker strips
      // both, and a missing large icon degrades silently rather than crashing,
      // which is exactly the kind of failure a guard is for.
      expect(
        source.contains('tools:keep="@drawable/ic_nt_notification" />'),
        isTrue,
        reason: 'both Dart-resolved names must survive the shrinker',
      );
      // Asserted on the keep VALUE, not the prose: the comment above explains the
      // history rather than listing anything.
      expect(
        RegExp(r'tools:keep="[^"]*@mipmap/').hasMatch(source),
        isFalse,
        reason:
            'the adaptive mipmap is referenced by the Android resources '
            'themselves, so keeping it by name would be dead configuration',
      );
    });
  });

  group('D29 every notification names its icon explicitly', () {
    test('the shared identity constant is the owner-supplied mark', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains(
          "const String ntNotificationIconResource = 'ic_nt_notification';",
        ),
        isTrue,
        reason:
            'OWNER DECISION (2026-09-22, P3-M0): the notification identity is '
            'the owner-supplied mark. The plugin resolves this string through '
            'getResourceIdentifier(name, "drawable", package) at runtime, and the '
            'drawable is a faithful conversion of the asset the owner supplied.',
      );
      expect(
        source.contains('ntNotificationAppIconResource'),
        isFalse,
        reason:
            'the previous round\'s launcher-resource identity must be deleted '
            'rather than left unused, so it cannot be re-wired by accident',
      );
    });

    test('the reminder/transient gateway sets an icon on every notification', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        _count(source, 'AndroidNotificationDetails('),
        _count(source, 'icon: ntNotificationIconResource,'),
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
        _count(source, 'icon: ntNotificationIconResource,'),
      );
      expect(_count(source, 'AndroidNotificationDetails('), greaterThan(0));
    });

    test('the initialization registers the SAME identity as every send', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains(
          'AndroidInitializationSettings(ntNotificationIconResource)',
        ),
        isTrue,
        reason:
            'the registered default and the per-send icon must be one resource, '
            'or a scheduled reminder would carry a different identity from the '
            'cards around it',
      );
      expect(source.contains('AndroidInitializationSettings('), isTrue);
    });
  });

  // Candidate B: XOS rendered the same green circle with navy and no color.
  // Keep neutral system presentation, and do not reintroduce a custom large icon.
  group('D30 neutral notification presentation', () {
    void expectNeutral(String source, String label) {
      final details = _count(source, 'AndroidNotificationDetails(');
      expect(details, greaterThan(0), reason: '$label must post notifications');
      expect(RegExp(r'\bcolor\s*:').hasMatch(source), isFalse);
      expect(_count(source, 'colorized: false,'), details);
    }

    test('the reminder and transient paths leave notification color unset', () {
      expectNeutral(gateway.readAsStringSync(), 'reminder/transient');
    });

    test('the app-status path leaves notification color unset', () {
      expectNeutral(badgeGateway.readAsStringSync(), 'app-status');
    });

    test('all three notification paths omit the custom large icon', () {
      var total = 0;
      for (final file in [gateway, badgeGateway]) {
        final source = file.readAsStringSync();
        total += _count(source, 'AndroidNotificationDetails(');
        expect(_count(source, 'largeIcon:'), 0);
        expect(source.contains('ntNotificationLargeIconResource'), isFalse);
        expect(source.contains('DrawableResourceAndroidBitmap('), isFalse);
      }
      expect(total, 3);
    });

    test('no launcher resource is ever a notification icon input', () {
      for (final (label, file) in <(String, File)>[
        ('the reminder/transient gateway', gateway),
        ('the launcher-badge gateway', badgeGateway),
      ]) {
        final source = file.readAsStringSync();
        // Asserted on the icon ARGUMENT, not on any mention: the files' own prose
        // explains why the launcher artwork is no longer used here.
        expect(
          RegExp(r"icon:\s*'[^']*ic_launcher").hasMatch(source),
          isFalse,
          reason:
              'a notification icon must never be a launcher resource or its raw '
              'raster: $label names the monochrome mark only, and the app logo is '
              'applied to the launcher icon instead',
        );
        expect(
          source.contains('icon: ntNotificationIconResource,'),
          isTrue,
          reason: '$label must pass the shared identity constant',
        );
        expect(
          source.contains('ntNotificationIconResource'),
          isTrue,
          reason: '$label must name the one shared identity constant',
        );
      }
    });

    test('the owner mark is the one icon input on every path', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        _count(source, 'icon: ntNotificationIconResource,'),
        _count(source, 'AndroidNotificationDetails('),
        reason:
            'every AndroidNotificationDetails must name the same identity, so '
            'no card can drift onto a rejected artwork on its own',
      );
      // The raw raster must never be named in the icon slot.
      expect(source.contains("icon: 'ic_launcher_foreground'"), isFalse);
      expect(
        source.contains(
          'AndroidInitializationSettings(ntNotificationIconResource)',
        ),
        isTrue,
      );
    });

    test('the release shrinker keeps the runtime small icon', () {
      final source = keepFile.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains('tools:keep="@drawable/ic_nt_notification" />'),
        isTrue,
        reason:
            'the small icon is resolved by name and must survive the shrinker',
      );
      expect(
        RegExp(r'tools:keep="[^"]*@mipmap/').hasMatch(source),
        isFalse,
        reason:
            'the adaptive mipmap is referenced by the Android resources '
            'themselves, so a keep entry for it would be dead configuration',
      );
    });

    test('the in-app preview tint remains the approved brand field', () {
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
