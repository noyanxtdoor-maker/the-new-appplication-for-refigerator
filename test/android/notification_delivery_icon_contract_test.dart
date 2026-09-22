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
/// OWNER DECISION (2026-09-22, final notification-identity restoration) — the
/// identity named on every path is now the app icon itself (`@mipmap/ic_launcher`),
/// not the monochrome mark: the owner rejected the mark and asked for the actual
/// app-icon presentation, and Android derives the card's identity from the small
/// icon, so that input is the only lever. The monochrome mark stays maintained and
/// kept as the documented one-constant revert, and the raw launcher raster
/// (`ic_launcher_foreground`) stays banned as an icon input.
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
      // OWNER DECISION (2026-09-22, final restoration): the card's large icon
      // stays removed, and the identity resolved by name at runtime is now the
      // app icon, so the keep list carries exactly those two names.
      expect(
        source.contains(
          'tools:keep="@drawable/ic_nt_notification,@mipmap/ic_launcher" />',
        ),
        isTrue,
        reason:
            'both runtime-resolved names must be kept: the icon actually sent '
            'today and the monochrome revert',
      );
      // Asserted on the keep VALUE, not the prose: the comment above it
      // explains why the launcher artwork is no longer listed.
      expect(
        RegExp(r'tools:keep="[^"]*ic_launcher_foreground').hasMatch(source),
        isFalse,
        reason:
            'nothing resolves the launcher artwork by name at runtime any '
            'more, so a stale keep entry would be dead configuration',
      );
    });
  });

  group('D29 every notification names its icon explicitly', () {
    test('the shared identity constant is the canonical app-icon resource', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains(
          "const String ntNotificationAppIconResource = '@mipmap/ic_launcher';",
        ),
        isTrue,
        reason:
            'OWNER DECISION (2026-09-22, final restoration): the notification '
            'identity is the app icon. The plugin passes this string to '
            'getResourceIdentifier(name, "drawable", package), and a '
            'TYPE-PREFIXED name is what lets the launcher mipmap resolve out of '
            'that drawable-type lookup — the plugin documents this exact value '
            'for this purpose.',
      );
      expect(
        source.contains(
          "const String ntNotificationIconResource = 'ic_nt_notification';",
        ),
        isTrue,
        reason:
            'the Android-compliant monochrome mark stays maintained as the '
            'documented one-constant revert',
      );
    });

    test('the reminder/transient gateway sets an icon on every notification', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        _count(source, 'AndroidNotificationDetails('),
        _count(source, 'icon: ntNotificationAppIconResource,'),
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
        _count(source, 'icon: ntNotificationAppIconResource,'),
      );
      expect(_count(source, 'AndroidNotificationDetails('), greaterThan(0));
    });

    test('the initialization registers the SAME identity as every send', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains(
          'AndroidInitializationSettings(ntNotificationAppIconResource)',
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

    //
    // OWNER DECISION (2026-09-22, final restoration) — the identity lives in the
    // SMALL icon only, and it is the app icon itself. The owner rejected the
    // full-colour logo on the right of the card (`largeIcon`, still banned here)
    // and then rejected the redrawn monochrome glyphs, asking for the actual
    // app-icon presentation. So: no notification sets a large icon, and every
    // path names the canonical launcher icon resource.
    test('no notification sets a largeIcon any more', () {
      for (final (label, file) in <(String, File)>[
        ('the reminder/transient gateway', gateway),
        ('the launcher-badge gateway', badgeGateway),
      ]) {
        final source = file.readAsStringSync().replaceAll('\r\n', '\n');
        expect(
          _count(source, 'largeIcon:'),
          0,
          reason:
              'the owner asked for the logo to be REMOVED from the card, so no '
              'AndroidNotificationDetails in $label may set a large icon',
        );
        expect(
          source.contains('ntNotificationLargeIconResource'),
          isFalse,
          reason:
              'the shared large-icon constant must be gone with the feature, so '
              'it cannot be re-wired by accident',
        );
      }
    });

    test('the raw launcher raster is never an icon input', () {
      for (final (label, file) in <(String, File)>[
        ('the reminder/transient gateway', gateway),
        ('the launcher-badge gateway', badgeGateway),
      ]) {
        final source = file.readAsStringSync();
        expect(
          source.contains('ic_launcher_foreground'),
          isFalse,
          reason:
              'the identity is the canonical launcher ICON resource (the '
              'adaptive mipmap), never the raw foreground raster: $label must not '
              'name a bitmap that decodes to an unmasked square',
        );
        expect(
          source.contains('ntNotificationAppIconResource'),
          isTrue,
          reason: '$label must name the one shared identity constant',
        );
      }
    });

    test('the app icon is the one icon input on every path', () {
      final source = gateway.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        _count(source, 'icon: ntNotificationAppIconResource,'),
        _count(source, 'AndroidNotificationDetails('),
        reason:
            'every AndroidNotificationDetails must name the same identity, so '
            'no card can drift back to the rejected mark on its own',
      );
      // The raw raster must never be named in the icon slot.
      expect(source.contains("icon: 'ic_launcher_foreground'"), isFalse);
      expect(
        source.contains(
          'AndroidInitializationSettings(ntNotificationAppIconResource)',
        ),
        isTrue,
      );
    });

    test('the release shrinker keeps every runtime-resolved name', () {
      final source = keepFile.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        source.contains(
          'tools:keep="@drawable/ic_nt_notification,@mipmap/ic_launcher" />',
        ),
        isTrue,
        reason:
            'the icon the app sends today and the monochrome revert are both '
            'resolved by name from Dart, so both must survive the shrinker',
      );
      expect(
        RegExp(r'tools:keep="[^"]*ic_launcher_foreground').hasMatch(source),
        isFalse,
        reason:
            'the large-icon entry must be gone with the feature: a release '
            'build should not keep an asset for a notification field nothing '
            'sets any more',
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
