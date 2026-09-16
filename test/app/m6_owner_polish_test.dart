import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

import '../support/test_dependencies.dart';

/// M6 owner polish: the front door must react to the CANONICAL appearance
/// state on the same frame, keep the CTA anchored to the bottom safe area, and
/// carry the chosen appearance into You're Ready.
void main() {
  const appEnvironment = AppEnvironment(
    name: AppEnvironmentName.production,
    label: 'PRODUCTION',
  );

  Color fieldColor(WidgetTester tester) => tester
      .widget<ColoredBox>(find.byKey(const Key('m6-front-door-field')))
      .color;

  Color ctaColor(WidgetTester tester, Key key) => tester
      .widget<FilledButton>(find.byKey(key))
      .style!
      .backgroundColor!
      .resolve(<WidgetState>{})!;

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.dragUntilVisible(
      finder,
      find.byType(ListView),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpFrontDoor(
    WidgetTester tester,
    AppDatabase database, {
    Size size = const Size(393, 874),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final privacy = TestPrivacyDependencies(database: database);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: appEnvironment,
        diagnostics: SanitizedDiagnostics(),
        startupRepository: buildTestRepository(database: database),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Get Started is anchored to the bottom safe area', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    tester.view.padding = const FakeViewPadding(bottom: 48);
    await tester.pumpAndSettle();

    final viewHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final cta = tester.getRect(find.byKey(const Key('m6-welcome-cta')));
    final bottomGap = viewHeight - cta.bottom;

    // Lower part of the screen, clear of the system inset (single-counted),
    // never clipped at the very edge.
    expect(cta.bottom, greaterThan(viewHeight * 0.7));
    expect(bottomGap, greaterThanOrEqualTo(20));
    expect(bottomGap, lessThan(120));
  });

  testWidgets('Get Started stays reachable on a short screen', (tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database, size: const Size(393, 560));

    await tester.dragUntilVisible(
      find.byKey(const Key('m6-welcome-cta')),
      find.byType(ListView),
      const Offset(0, -160),
    );
    await tester.tap(find.byKey(const Key('m6-welcome-cta')));
    await tester.pumpAndSettle();
    expect(find.text('Setup'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Setup previews Light and Dark immediately from canonical state',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await pumpFrontDoor(tester, database);
      final darkField = fieldColor(tester);

      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.text('Setup')),
      );

      await tester.tap(find.byKey(const Key('m6-theme-option-light')));
      await tester.pumpAndSettle();
      final lightField = fieldColor(tester);
      expect(container.read(appearanceProvider), AppearanceMode.light);
      expect(lightField, isNot(darkField));

      await tester.tap(find.byKey(const Key('m6-theme-option-dark')));
      await tester.pumpAndSettle();
      expect(container.read(appearanceProvider), AppearanceMode.dark);
      expect(fieldColor(tester), darkField);
    },
  );

  testWidgets('Setup System follows the platform brightness live', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.text('Setup')),
    );

    await tester.tap(find.byKey(const Key('m6-theme-option-system')));
    await tester.pumpAndSettle();
    expect(container.read(appearanceProvider), AppearanceMode.system);

    // The platform is light, so the System choice must render the light field.
    final systemField = fieldColor(tester);
    await tester.tap(find.byKey(const Key('m6-theme-option-dark')));
    await tester.pumpAndSettle();
    expect(systemField, isNot(fieldColor(tester)));
  });

  testWidgets('Setup previews Blue and Rose immediately from canonical state', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.text('Setup')),
    );

    await scrollTo(tester, find.byKey(const Key('m6-setup-continue')));
    final roseAccent = ctaColor(tester, const Key('m6-setup-continue'));

    await scrollTo(tester, find.byKey(const Key('m6-accent-option-blue')));
    await tester.tap(find.byKey(const Key('m6-accent-option-blue')));
    await tester.pumpAndSettle();
    expect(container.read(themeColorProvider), ThemeColorMode.blue);
    final blueAccent = ctaColor(tester, const Key('m6-setup-continue'));
    expect(blueAccent, isNot(roseAccent));

    await scrollTo(tester, find.byKey(const Key('m6-accent-option-rose')));
    await tester.tap(find.byKey(const Key('m6-accent-option-rose')));
    await tester.pumpAndSettle();
    expect(container.read(themeColorProvider), ThemeColorMode.rose);
    expect(ctaColor(tester, const Key('m6-setup-continue')), roseAccent);
  });

  testWidgets("You're Ready inherits the chosen appearance", (tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('m6-theme-option-light')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('m6-accent-option-blue')));
    await tester.tap(find.byKey(const Key('m6-accent-option-blue')));
    await tester.pumpAndSettle();

    final setupLightField = fieldColor(tester);
    await scrollTo(tester, find.byKey(const Key('m6-setup-continue')));
    final setupAccent = ctaColor(tester, const Key('m6-setup-continue'));
    await tester.tap(find.byKey(const Key('m6-setup-continue')));
    await tester.pumpAndSettle();
    expect(find.text("You're ready."), findsOneWidget);

    // The Ready screen paints the SAME live appearance, not a hardcoded dark.
    expect(fieldColor(tester), setupLightField);
    final checkIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('m6-ready-check')),
        matching: find.byType(Icon),
      ),
    );
    expect(checkIcon.color, setupAccent);
  });

  testWidgets('Ready is minimal: one restrained white check, no artwork', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('m6-setup-continue')));
    await tester.tap(find.byKey(const Key('m6-setup-continue')));
    await tester.pumpAndSettle();

    // Both approved copy lines must be mounted: a fixed-height lazy list
    // previously left the subtitle outside the build window.
    expect(find.text("You're ready."), findsOneWidget);
    expect(
      find.text('Your next transfer starts with one step.'),
      findsOneWidget,
    );

    // M6 FINAL CORRECTION: You're Ready is MINIMAL.  The splash crop, the
    // mountain/path artwork, the app mark and any secondary artwork tile were
    // removed, so no illustration node and no image may exist here.
    expect(find.byKey(const Key('m6-ready-illustration')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('m6-ready-check')),
        matching: find.byType(Image),
      ),
      findsNothing,
      reason: 'the success mark must never be artwork',
    );

    // Owner-locked restrained size: the old 76px circle read oversized.
    final check = tester.getRect(find.byKey(const Key('m6-ready-check')));
    expect(check.width, 64);
    expect(check.height, 64);

    final glyph = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('m6-ready-check')),
        matching: find.byType(Icon),
      ),
    );
    expect(glyph.size, 32);
    expect(glyph.icon, Icons.check);

    expect(tester.takeException(), isNull);
  });

  testWidgets('Ready has no splash artwork anywhere on the screen', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('m6-setup-continue')));
    await tester.tap(find.byKey(const Key('m6-setup-continue')));
    await tester.pumpAndSettle();

    // The frozen splash PNG is still used by the Welcome mark, but You're
    // Ready must carry none of it.
    expect(
      find.descendant(
        of: find.byType(Scaffold),
        matching: find.byType(ClipRRect),
      ),
      findsNothing,
    );

    // Go to Home stays present and reachable on the minimal screen.
    final cta = find.byKey(const Key('m6-ready-cta'));
    expect(cta, findsOneWidget);
    expect(
      tester.getRect(cta).bottom,
      lessThanOrEqualTo(
        tester.view.physicalSize.height / tester.view.devicePixelRatio,
      ),
    );
  });

  testWidgets('Welcome carries the owner tagline and drops the old line', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);

    expect(find.text('Your next transfer\nstarts here.'), findsOneWidget);
    expect(
      find.text('The mission has ended. The next transfer begins.'),
      findsOneWidget,
    );
    expect(
      find.text('Plan what matters, privately on this device.'),
      findsNothing,
    );
    expect(find.text('Get Started'), findsOneWidget);
  });

  testWidgets('the Setup Blue and Rose swatches show the APPLIED accent', (
    tester,
  ) async {
    // Fresh install: dark + blue, so the chooser must show the DARK tonal step
    // of the canonical brand accents — never a stray decorative blue.
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpFrontDoor(tester, database);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('m6-accent-option-blue')));
    expect(swatchColor(tester, 'blue'), AppTheme.blueDarkPrimary);
    expect(swatchColor(tester, 'rose'), AppTheme.roseDarkPrimary);

    // Light resolves the light tonal step of the SAME two identities.
    await tester.tap(find.byKey(const Key('m6-theme-option-light')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('m6-accent-option-blue')));
    expect(swatchColor(tester, 'blue'), AppTheme.blueLightPrimary);
    expect(swatchColor(tester, 'rose'), AppTheme.roseLightPrimary);
  });

  test('dark primary-filled surfaces use the canonical WHITE foreground', () {
    expect(AppTheme.darkOnPrimary, Colors.white);
    for (final mode in ThemeColorMode.values) {
      final dark = AppTheme.dark(mode);
      expect(dark.colorScheme.onPrimary, AppTheme.darkOnPrimary);
      // POST-M7 CLOSURE (owner law, 2026-09-16): the floating-control surface is
      // the LIGHT tonal step of the active family in BOTH themes, while the dark
      // `colorScheme.primary` accent itself stays exactly as accepted.
      expect(
        dark.floatingActionButtonTheme.backgroundColor,
        mode == ThemeColorMode.blue
            ? AppTheme.blueLightPrimary
            : AppTheme.roseLightPrimary,
      );
      expect(
        dark.colorScheme.primary,
        mode == ThemeColorMode.blue
            ? AppTheme.blueDarkPrimary
            : AppTheme.roseDarkPrimary,
      );
      expect(dark.floatingActionButtonTheme.foregroundColor, Colors.white);

      final light = AppTheme.light(mode);
      expect(light.floatingActionButtonTheme.foregroundColor, Colors.white);
    }
  });

  test('the white foreground keeps every pinned contrast gate', () {
    for (final primary in <Color>[
      AppTheme.blueDarkPrimary,
      AppTheme.roseDarkPrimary,
    ]) {
      expect(_contrast(Colors.white, primary), greaterThanOrEqualTo(4.5));
      expect(
        _contrast(primary, const Color(0xFF0D0E10)),
        greaterThanOrEqualTo(4.0),
      );
      expect(_contrast(primary, AppTheme.surface), greaterThanOrEqualTo(3.5));
      expect(
        _contrast(primary, const Color(0xFF101113)),
        greaterThanOrEqualTo(4.0),
      );
    }
  });

  test('dark blue surfaces no longer seed from a stray pale blue', () {
    final blue = AppTheme.dark(ThemeColorMode.blue).colorScheme;
    final straySeed = ColorScheme.fromSeed(
      seedColor: const Color(0xFF9FC8F0),
      brightness: Brightness.dark,
      surface: AppTheme.surface,
    );
    // `surfaceTint` is the seed-derived channel Material leaves least damped,
    // so it is the reliable observable that the dark scheme is no longer
    // derived from the stray pale blue.  Container tones are deliberately NOT
    // asserted here: Material rounds them onto a shared tonal ramp, so two
    // different blue seeds can legitimately land on the same container value.
    expect(blue.surfaceTint, isNot(straySeed.surfaceTint));
    // The dark seed IS the documented brand identity.
    expect(AppTheme.brandBlueHue, AppTheme.blueDarkPrimary);
  });
}

/// WCAG relative-luminance contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// The colour painted by the accent chooser's swatch for [storageName].
Color swatchColor(WidgetTester tester, String storageName) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byKey(Key('m6-accent-option-$storageName')),
      matching: find.byType(Container),
    ),
  );
  return (container.decoration! as BoxDecoration).color!;
}
