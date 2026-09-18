import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/intro_splash.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/router/startup_route_guard.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/startup/presentation/startup_screen.dart';

/// M5 — Next Transfer native branding and intro splash.
///
/// These tests guard the contracts that M5 is responsible for.  They read the
/// real Android resources and the real generated PNGs (not a copy of them), so a
/// future change that silently reverts to the stock launch surface, drops the
/// adaptive icon, re-introduces a spinner, or adds an artificial splash delay
/// fails here.
const _res = 'android/app/src/main/res';
const _manifest = 'android/app/src/main/AndroidManifest.xml';
const _router = 'lib/app/router/app_router.dart';
const _startupScreen = 'lib/features/startup/presentation/startup_screen.dart';
const _introSplash = 'lib/app/intro_splash.dart';
const _main = 'lib/main.dart';
const _pubspec = 'pubspec.yaml';

const _densities = <String>['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];
const _scale = <String, double>{
  'mdpi': 1,
  'hdpi': 1.5,
  'xhdpi': 2,
  'xxhdpi': 3,
  'xxxhdpi': 4,
};
const _legacyPx = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

String _read(String path) => File(path).readAsStringSync();

/// Source with comments removed.
///
/// The contracts below are about executable code and real resource items, not
/// about prose, so a comment that *names* a forbidden thing (for example an
/// explanation of why no monochrome layer is declared) must not fail the check.
String _stripDartComments(String source) {
  return source
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '')
      .replaceAll(RegExp(r'\s//[^\n]*'), '');
}

String _stripXmlComments(String source) {
  return source.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
}

/// Dart source of [path] with comments stripped.
String _code(String path) => _stripDartComments(_read(path));

/// XML resource of [path] with comments stripped.
String _doc(String path) => _stripXmlComments(_read(path));

String _assetPath(String density, String name) =>
    '$_res/drawable-$density/$name.png';

/// Raw RGBA pixels of a decoded PNG, so resource contracts can be checked
/// against the bytes that actually ship rather than against a description.
final class _Pixels {
  _Pixels(this.width, this.height, this._bytes);

  final int width;
  final int height;
  final Uint8List _bytes;

  static Future<_Pixels> load(String path) async {
    final image = await decodeImageFromList(File(path).readAsBytesSync());
    final data = await image.toByteData();
    return _Pixels(image.width, image.height, data!.buffer.asUint8List());
  }

  int _at(int x, int y, int channel) => _bytes[(y * width + x) * 4 + channel];

  int r(int x, int y) => _at(x, y, 0);
  int g(int x, int y) => _at(x, y, 1);
  int b(int x, int y) => _at(x, y, 2);
  int a(int x, int y) => _at(x, y, 3);

  /// Distinct quantised colours, a cheap way to tell a flat plate apart from a
  /// graded, multi-band piece of scenery.
  int distinctColours() {
    final seen = <int>{};
    for (var y = 0; y < height; y += 2) {
      for (var x = 0; x < width; x += 2) {
        seen.add((r(x, y) >> 4) << 8 | (g(x, y) >> 4) << 4 | (b(x, y) >> 4));
      }
    }
    return seen.length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M5 native / resource contract', () {
    test('N1: manifest keeps the app label, launcher icon and launch theme', () {
      final manifest = _read(_manifest);
      expect(manifest, contains('android:label="Next Transfer"'));
      expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
      expect(manifest, contains('android:theme="@style/LaunchTheme"'));
    });

    test('N2: an adaptive launcher icon is declared for API 26+', () {
      final path = '$_res/mipmap-anydpi-v26/ic_launcher.xml';
      expect(File(path).existsSync(), isTrue);
      final xml = _doc(path);
      expect(xml, contains('<adaptive-icon'));
      expect(xml, contains('@drawable/nt_launcher_background'));
      expect(xml, contains('@drawable/nt_launcher_foreground'));
      // No monochrome derivative of the approved artwork was authorised.
      expect(xml, isNot(contains('<monochrome')));
      expect(
        File('$_res/drawable/nt_launcher_background.xml').existsSync(),
        isTrue,
      );
    });

    test('N3: launcher artwork is the graded scenic logo, not a flat plate', () async {
      // The pre-M5 icon was a FLAT #002A67 field (top and bottom corners byte
      // identical).  The owner-approved launcher artwork is the deep blue field
      // with mountains, so its field is graded top-to-bottom and carries many
      // more colour bands.  Both facts are asserted here so a revert to the old
      // flat icon - or to a plain emblem-only plate - fails.
      for (final density in _densities) {
        final px = await _Pixels.load(
          '$_res/mipmap-$density/ic_launcher.png',
        );
        expect(px.width, _legacyPx[density]);
        expect(px.height, _legacyPx[density]);

        for (final corner in <List<int>>[
          <int>[2, 2],
          <int>[px.width - 3, 2],
          <int>[2, px.height - 3],
          <int>[px.width - 3, px.height - 3],
        ]) {
          expect(px.a(corner[0], corner[1]), 255, reason: '$density is opaque');
          // deep Next Transfer blue: blue-dominant and very low red
          expect(px.r(corner[0], corner[1]), lessThan(24));
          expect(px.g(corner[0], corner[1]), lessThan(60));
          expect(px.b(corner[0], corner[1]), greaterThan(45));
          expect(
            px.b(corner[0], corner[1]),
            greaterThan(px.g(corner[0], corner[1])),
          );
        }

        final topBlue = px.b(2, 2);
        final bottomBlue = px.b(2, px.height - 3);
        expect(
          (topBlue - bottomBlue).abs(),
          greaterThan(20),
          reason:
              '$density launcher field must be the graded scenic artwork, not a '
              'flat plate',
        );
        expect(px.distinctColours(), greaterThan(50));
      }
    });

    test('N4: adaptive foreground is mask-safe with a transparent margin', () async {
      for (final density in _densities) {
        final px = await _Pixels.load(
          _assetPath(density, 'nt_launcher_foreground'),
        );
        final expected = (108 * _scale[density]!).round();
        expect(px.width, expected);
        expect(px.height, expected);

        // mask-safe transparent margin
        expect(px.a(0, 0), 0);
        expect(px.a(px.width - 1, px.height - 1), 0);
        // the artwork itself is opaque
        expect(px.a(px.width ~/ 2, px.height ~/ 2), 255);

        // Every bright (important) pixel must fall inside the Android adaptive
        // safe zone: the central 66dp of the 108dp layer.
        final safeRadius = px.width / 2 * (66 / 108);
        final centre = px.width / 2;
        var worst = 0.0;
        var checked = 0;
        for (var y = 0; y < px.height; y++) {
          for (var x = 0; x < px.width; x++) {
            if (px.a(x, y) == 0) continue;
            final luma = (px.r(x, y) * 299 + px.g(x, y) * 587 + px.b(x, y) * 114) ~/ 1000;
            if (luma < 200) continue;
            checked++;
            worst = math.max(worst, math.sqrt(math.pow(x - centre, 2) + math.pow(y - centre, 2)));
          }
        }
        expect(checked, greaterThan(0), reason: 'artwork has bright content');
        expect(
          worst,
          lessThanOrEqualTo(safeRadius),
          reason:
              '$density: a bright launcher pixel sits outside the adaptive safe '
              'zone and could be cropped by a mask',
        );
      }
    });

    test('N5: the Android 12+ system splash is the brand field and nothing else', () {
      for (final path in <String>[
        '$_res/values-v31/styles.xml',
        '$_res/values-night-v31/styles.xml',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: '$path must exist');
        final xml = _doc(path);
        expect(xml, contains('name="LaunchTheme"'));
        expect(
          xml,
          contains('<item name="android:windowSplashScreenBackground">'
              '@color/nt_native_blue</item>'),
        );
        // The splash icon is deliberately EMPTY.  Any emblem here is a small
        // logo centred in the brand blue - the composition of the rejected old
        // splash - and would make the app read as old splash -> new splash.
        expect(
          xml,
          contains('<item name="android:windowSplashScreenAnimatedIcon">'
              '@drawable/nt_splash_no_icon</item>'),
        );
        expect(xml, isNot(contains('nt_splash_emblem')));
        // No icon tile: the platform must not draw a rounded plate that clashes
        // with the next frame.
        expect(
          xml,
          isNot(
            contains(
              '<item name="android:windowSplashScreenIconBackgroundColor">',
            ),
          ),
        );
        // No text can reach the system splash through this theme.
        expect(xml, isNot(contains('android:text')));
      }

      // The empty icon really is empty: no artwork can be drawn from it, so the
      // platform surface cannot present a second, older-looking design.
      final iconPath = '$_res/drawable/nt_splash_no_icon.xml';
      expect(File(iconPath).existsSync(), isTrue);
      final icon = _doc(iconPath);
      expect(icon, contains('@android:color/transparent'));
      expect(icon, isNot(contains('<bitmap')));
      expect(icon, isNot(contains('@drawable/nt_launcher')));
    });

    test('N6: the launch field is the intro splash own top colour, day and night', () {
      final splashTop = kIntroSplashEdgeColors.first;
      final splashTopHex =
          '#FF'
          '${(splashTop.r * 255).round().toRadixString(16).padLeft(2, '0')}'
          '${(splashTop.g * 255).round().toRadixString(16).padLeft(2, '0')}'
          '${(splashTop.b * 255).round().toRadixString(16).padLeft(2, '0')}'
              .toUpperCase();

      final day = _doc('$_res/values/colors.xml');
      final night = _doc('$_res/values-night/colors.xml');
      expect(day, contains('<color name="nt_native_blue">$splashTopHex</color>'));
      expect(night, contains('<color name="nt_native_blue">$splashTopHex</color>'));

      final dayStyle = _doc('$_res/values/styles.xml');
      final nightStyle = _doc('$_res/values-night/styles.xml');
      expect(dayStyle, contains('@color/nt_native_blue'));
      expect(nightStyle, contains('@color/nt_native_blue'));
      expect(dayStyle, isNot(contains('?android:colorBackground')));
      expect(nightStyle, isNot(contains('?android:colorBackground')));
      // The launch window background on every API level and every mode is the
      // same brand field.
      expect(
        dayStyle,
        contains('<item name="android:windowBackground">@color/nt_native_blue'),
      );
      expect(
        nightStyle,
        contains('<item name="android:windowBackground">@color/nt_native_blue'),
      );

      // v31 and night-v31 carry the same launch items, including the same icon.
      final v31 = _doc('$_res/values-v31/styles.xml');
      final nightV31 = _doc('$_res/values-night-v31/styles.xml');
      for (final item in <String>[
        'android:windowSplashScreenBackground',
        'android:windowSplashScreenAnimatedIcon',
        'android:windowBackground',
      ]) {
        expect(v31, contains(item));
        expect(nightV31, contains(item));
      }
      // Day and night must resolve to the same launch brand: same field, same
      // (empty) icon, same window background.
      for (final item in <String>[
        '<item name="android:windowSplashScreenBackground">@color/nt_native_blue</item>',
        '<item name="android:windowSplashScreenAnimatedIcon">@drawable/nt_splash_no_icon</item>',
        '<item name="android:windowBackground">@drawable/launch_background</item>',
      ]) {
        expect(v31, contains(item));
        expect(nightV31, contains(item));
      }
    });

    test('N7: no launch surface carries a second design or a wrong colour', () {
      for (final path in <String>[
        '$_res/drawable/launch_background.xml',
        '$_res/drawable-v21/launch_background.xml',
      ]) {
        expect(File(path).existsSync(), isTrue);
        final xml = _doc(path);
        expect(xml, contains('@color/nt_native_blue'));
        expect(xml, isNot(contains('@android:color/white')));
        expect(xml, isNot(contains('?android:colorBackground')));
        expect(xml, isNot(contains('launch_image')));
        // No artwork is layered over the launch field: the approved composition
        // is painted by the first Flutter frame, not by the platform surface.
        expect(xml, isNot(contains('<bitmap')));
        expect(xml, isNot(contains('nt_splash_emblem')));
        expect(xml, isNot(contains('nt_launcher')));
      }
    });

    test('N8: the emblem-only native splash is gone from every density', () {
      // The retired native emblem was the whole reason the launch read as the
      // old splash: deep blue plus one small centred mark.  It must not exist in
      // any density bucket, and nothing may reference it.
      for (final density in _densities) {
        expect(
          File(_assetPath(density, 'nt_splash_emblem')).existsSync(),
          isFalse,
          reason: '$density must no longer ship an emblem-only splash asset',
        );
      }
      for (final path in <String>[
        '$_res/values-v31/styles.xml',
        '$_res/values-night-v31/styles.xml',
        '$_res/values/styles.xml',
        '$_res/values-night/styles.xml',
        '$_res/drawable/launch_background.xml',
        '$_res/drawable-v21/launch_background.xml',
      ]) {
        expect(_read(path), isNot(contains('nt_splash_emblem')));
      }
    });
  });

  group('M5 Flutter intro contract', () {
    test('F1: the app still opens on the splash route', () {
      final source = _code(_router);
      expect(source, contains('initialLocation: RoutePaths.startup'));
    });

    test('F2: leaving the splash cannot fade it over the destination', () {
      final source = _code(_router);
      expect(
        source,
        contains('NoTransitionPage<void>(child: StartupScreen())'),
        reason:
            'the splash route must ignore both animations, otherwise the default '
            'Android exit transition fades it out over the resolved destination',
      );
      // The correction is scoped to the startup route only: destinations keep
      // their own transitions, and no global pageTransitionsTheme is introduced.
      expect(source, isNot(contains('pageTransitionsTheme')));
      expect(source, isNot(contains('PageTransitionsTheme')));
      expect(source, isNot(contains('PageTransitionsBuilder')));
      expect(source, contains('const HomeScreen()'));
    });

    test('F3: the splash paints the approved artwork whole, never stretched', () {
      final source = _code(_startupScreen);
      expect(source, contains('kIntroSplashAsset'));
      expect(source, contains('BoxFit.contain'));
      expect(source, isNot(contains('BoxFit.fill')));
      expect(source, isNot(contains('BoxFit.cover')));
    });

    test('F4: the approved splash asset is registered and is the approved file', () async {
      expect(_read(_pubspec), contains(kIntroSplashAsset));
      expect(File(kIntroSplashAsset).existsSync(), isTrue);

      final px = await _Pixels.load(kIntroSplashAsset);
      // The owner-approved artwork is 941 x 1672 portrait.
      expect(px.width, 941);
      expect(px.height, 1672);
      expect(kIntroSplashAspectRatio, closeTo(941 / 1672, 1e-9));

      // Fully opaque artwork: the splash can never be see-through.
      for (final probe in <List<int>>[
        <int>[2, 2],
        <int>[px.width - 3, 2],
        <int>[2, px.height - 3],
        <int>[px.width - 3, px.height - 3],
        <int>[px.width ~/ 2, px.height ~/ 2],
      ]) {
        expect(px.a(probe[0], probe[1]), 255);
      }
    });

    test('F5: the approved title and exact tagline are carried verbatim', () {
      expect(
        StartupScreen.semanticsLabel,
        'Next Transfer. The mission ended. The next transfer begins.',
      );
      expect(StartupScreen.semanticsLabel, contains('Next Transfer'));
      expect(StartupScreen.semanticsLabel.toLowerCase(), isNot(contains('prepare')));
      expect(StartupScreen.semanticsLabel.toLowerCase(), isNot(contains('progress')));
    });

    test('F6: the splash root surface is fully opaque', () {
      final source = _code(_startupScreen);
      for (final translucent in <String>[
        'withOpacity',
        'withAlpha',
        'Opacity(',
        'AnimatedOpacity',
        'FadeTransition',
        'AnimatedSwitcher',
        'Color(0x00',
      ]) {
        expect(
          source,
          isNot(contains(translucent)),
          reason:
              'the splash must not contain a translucent surface: $translucent',
        );
      }
      // The one transparent colour on this screen is the status-bar window that
      // sits OVER the splash, never the splash field itself.
      expect(RegExp(r'Colors\.transparent').allMatches(source).length, 1);
      expect(source, contains('statusBarColor: Colors.transparent'));
      expect(source, isNot(contains('backgroundColor: Colors.transparent')));

      for (final screen in <Size>[
        const Size(1080, 2400),
        const Size(941, 1672),
        const Size(1440, 2560),
        const Size(800, 600),
      ]) {
        final gradient = introSplashBackdropGradient(screen);
        for (final colour in gradient.colors) {
          expect(colour.a, 1.0, reason: 'backdrop must be opaque at $screen');
        }
      }
    });

    test('F7: no spinner, progress or control on the splash', () {
      final source = _code(_startupScreen);
      for (final forbidden in <String>[
        'CircularProgressIndicator',
        'LinearProgressIndicator',
        'RefreshProgressIndicator',
        'ProgressIndicator',
        'ElevatedButton',
        'TextButton',
        'FilledButton',
        'IconButton',
        'Text(',
      ]) {
        expect(
          source,
          isNot(contains(forbidden)),
          reason: 'the approved splash carries no $forbidden',
        );
      }
    });

    test('F8: backdrop gradient anchors exactly to the artwork edges', () {
      const screen = Size(1080, 2400);
      final gradient = introSplashBackdropGradient(screen);
      final stops = gradient.stops!;
      expect(gradient.colors.length, stops.length);
      expect(gradient.colors.length, greaterThanOrEqualTo(2));

      for (var i = 1; i < stops.length; i++) {
        expect(
          stops[i],
          greaterThan(stops[i - 1]),
          reason: 'stops must be strictly increasing',
        );
      }
      expect(stops.first, 0.0);
      expect(stops.last, 1.0);

      // On this ratio the artwork fits by width, so it is letterboxed top and
      // bottom: the artwork's own top colour must land exactly on the artwork's
      // top edge and its bottom colour exactly on the bottom edge.
      final artworkHeight = screen.width / kIntroSplashAspectRatio;
      final top = (screen.height - artworkHeight) / 2;
      expect(gradient.colors.first, kIntroSplashEdgeColors.first);
      expect(gradient.colors.last, kIntroSplashEdgeColors.last);
      expect(
        stops[1],
        closeTo(top / screen.height, 1e-9),
        reason: "the artwork's top edge colour must sit on the artwork's top edge",
      );
      expect(
        stops[stops.length - 2],
        closeTo((top + artworkHeight) / screen.height, 1e-9),
      );
      // Leftover area clamps to the artwork's own edge colours.
      expect(stops[1], greaterThan(0));
    });

    test('F9: no artificial splash hold was introduced', () {
      for (final path in <String>[_startupScreen, _introSplash]) {
        final source = _code(path);
        for (final delay in <String>[
          'Future.delayed',
          'Timer(',
          'Timer.periodic',
          'minimumSplashDuration',
          'splashDuration',
          'Duration(milliseconds:',
          'minSplash',
        ]) {
          expect(
            source,
            isNot(contains(delay)),
            reason: '$path must not delay startup for branding: $delay',
          );
        }
      }
      // The only wait on the splash decode is the bounded, swallowed join.
      final main = _code(_main);
      expect(main, contains('preloadIntroSplashArtwork()'));
      expect(main, contains('introSplashPreload.timeout('));
      expect(
        main.indexOf('introSplashPreload.timeout('),
        lessThan(main.indexOf('runApp(')),
        reason: 'the decode is joined BEFORE the first frame',
      );
    });
  });

  group('M5 startup / privacy contract', () {
    test('S1: the splash is the destination only while startup is unresolved', () {
      expect(
        StartupRouteGuard.redirect(
          state: const StartupOpening(),
          currentLocation: RoutePaths.home,
        ),
        RoutePaths.startup,
      );
      expect(
        StartupRouteGuard.redirect(
          state: const StartupOpening(),
          currentLocation: RoutePaths.startup,
        ),
        isNull,
      );
      expect(
        StartupRouteGuard.redirect(
          state: const StartupProtected(),
          currentLocation: RoutePaths.startup,
        ),
        RoutePaths.protectedContent,
        reason: 'privacy lock still intercepts after the splash',
      );
    });

    test('S2: the splash is branding, not authentication', () {
      final source = _code(_startupScreen);
      for (final forbidden in <String>[
        'privacyControllerProvider',
        'PrivacyController',
        'privacyGateProvider',
        'PrivacyGate',
        'authenticate(',
        'local_auth',
        'LocalAuthDeviceAuthenticator',
        'startupControllerProvider',
      ]) {
        expect(
          source,
          isNot(contains(forbidden)),
          reason: 'the splash must not take part in the privacy gate: $forbidden',
        );
      }
      // The lock screen itself is untouched, including its unlock control.
      final lock = _read(
        'lib/features/startup/presentation/protected_content_screen.dart',
      );
      expect(lock, contains("key: const Key('unlock-button')"));
      expect(lock, contains('Next Transfer is locked'));
    });

    test('S3: the splash renders no destination of its own', () {
      final source = _code(_startupScreen);
      for (final forbidden in <String>[
        'HomeScreen',
        'PlannerScreen',
        'ContactsScreen',
        'MapsScreen',
        'MainShell',
        'OnboardingScreen',
        'RecoveryScreen',
      ]) {
        expect(source, isNot(contains(forbidden)));
      }
      expect(File('lib/features/startup/presentation/startup_screen.dart').existsSync(), isTrue);
    });

    test('S4: M6 has not been started', () {
      for (final forbidden in <String>[
        'welcome',
        'front_door',
        'profile_setup',
        'optional_setup',
        'ready_screen',
      ]) {
        expect(
          Directory('lib').listSync(recursive: true).whereType<File>(),
          isNot(
            contains(
              predicate<File>(
                (file) => file.path.toLowerCase().contains(forbidden),
              ),
            ),
          ),
          reason: 'M6 surface "$forbidden" must not exist yet',
        );
      }
      final names = _code('lib/app/router/route_names.dart').toLowerCase();
      for (final forbidden in <String>['welcome', 'frontdoor', 'profile-setup']) {
        expect(names, isNot(contains(forbidden)));
      }
    });
  });

  group('M5 widget surface', () {
    testWidgets('W1: StartupScreen paints the approved asset, opaque, no motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: StartupScreen(),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, kIntroSplashAsset);
      expect(image.fit, BoxFit.contain);
      expect(image.alignment, Alignment.center);

      final decorated = tester.widget<DecoratedBox>(
        find.byType(DecoratedBox).first,
      );
      final gradient = (decorated.decoration as BoxDecoration).gradient;
      expect(gradient, isA<LinearGradient>());
      for (final colour in (gradient! as LinearGradient).colors) {
        expect(colour.a, 1.0);
      }

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Opacity), findsNothing);
      expect(find.byType(FadeTransition), findsNothing);
    });

    testWidgets('W2: the splash really paints the approved composition', (
      tester,
    ) async {
      // Render the splash surface at the authorized device's resolution and
      // inspect the pixels it produces, so "the approved artwork is on screen"
      // is proven by rendering rather than asserted by intent.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final boundaryKey = GlobalKey();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(key: boundaryKey, child: const StartupScreen()),
        ),
      );
      // Let the approved artwork decode for real: this is exactly what the
      // bounded preload in main.dart does before the first frame.  It is bounded
      // here too, so an unrunnable asset fails the test instead of hanging it.
      await tester.runAsync(() async {
        await preloadIntroSplashArtwork().timeout(const Duration(seconds: 20));
      });
      await tester.pumpAndSettle();

      // Rasterising the boundary needs the real event loop, so it runs inside
      // runAsync as well; the assertions below then read plain bytes.
      late Uint8List data;
      late int w;
      late int h;
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        data = (await image.toByteData())!.buffer.asUint8List();
        w = image.width;
        h = image.height;
      });
      int r(int x, int y) => data[(y * w + x) * 4];
      int g(int x, int y) => data[(y * w + x) * 4 + 1];
      int b(int x, int y) => data[(y * w + x) * 4 + 2];

      // ignore: avoid_print
      print('DIAG size=${w}x$h topLeft=${r(8, 8)},${g(8, 8)},${b(8, 8)} '
          'topMid=${r(w ~/ 2, 8)},${g(w ~/ 2, 8)},${b(w ~/ 2, 8)} '
          'midLeft=${r(w ~/ 5, h ~/ 2)},${g(w ~/ 5, h ~/ 2)},${b(w ~/ 5, h ~/ 2)} '
          'midMid=${r(w ~/ 2, h ~/ 2)},${g(w ~/ 2, h ~/ 2)},${b(w ~/ 2, h ~/ 2)} '
          'bot=${r(w ~/ 2, h - 8)},${g(w ~/ 2, h - 8)},${b(w ~/ 2, h - 8)}');

      // The surface is opaque everywhere: no destination can show through.
      for (final y in <int>[5, h ~/ 4, h ~/ 2, (h * 3) ~/ 4, h - 5]) {
        expect(data[(y * w + w ~/ 4) * 4 + 3], 255);
      }

      // Deep blue field, graded top to bottom exactly like the approved artwork.
      final topBlue = b(8, 8);
      final bottomBlue = b(8, h - 8);
      expect(topBlue, greaterThan(bottomBlue), reason: 'graded, not flat');
      expect(r(8, 8), lessThan(24));
      expect(topBlue, greaterThan(60));

      // The approved white title sits in the artwork's title band; a bright band
      // must exist between the emblem and the bottom quarter of the screen.
      var brightestRow = 0;
      var brightestLuma = 0;
      for (var y = (h * 0.30).round(); y < (h * 0.80).round(); y++) {
        var brightPixels = 0;
        for (var x = 0; x < w; x += 2) {
          final luma = (r(x, y) * 299 + g(x, y) * 587 + b(x, y) * 114) ~/ 1000;
          if (luma > 200) brightPixels++;
        }
        if (brightPixels > brightestLuma) {
          brightestLuma = brightPixels;
          brightestRow = y;
        }
      }
      expect(
        brightestLuma,
        greaterThan(40),
        reason: 'the approved white title/tagline must be painted',
      );
      expect(
        brightestRow / h,
        inInclusiveRange(0.35, 0.72),
        reason: 'the title band must sit where the approved artwork places it',
      );
    });
  });
}
