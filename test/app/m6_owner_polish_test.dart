import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/startup/presentation/onboarding_screen.dart';

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

  testWidgets('Get Started is anchored to the bottom safe area', (tester) async {
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

  testWidgets('Setup previews Light and Dark immediately from canonical state',
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
  });

  testWidgets('Setup System follows the platform brightness live',
      (tester) async {
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

  testWidgets('Setup previews Blue and Rose immediately from canonical state',
      (tester) async {
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

  testWidgets('Ready check and illustration never overlap', (tester) async {
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

    final check = tester.getRect(find.byKey(const Key('m6-ready-check')));
    final illustration = tester.getRect(
      find.byKey(const Key('m6-ready-illustration')),
    );
    // Clean separation: the restrained mark sits wholly above the artwork.
    expect(check.bottom, lessThanOrEqualTo(illustration.top));
    // The mark is restrained, not the owner-rejected oversized glyph.
    expect(check.width, lessThanOrEqualTo(90));
    expect(check.height, lessThanOrEqualTo(90));
  });

  test('Ready illustration crop stays inside the splash tile (no app mark)', () {
    expect(
      m6ReadyIllustrationSource.left,
      greaterThanOrEqualTo(
        m6SplashTileBounds.left + m6ReadyIllustrationMinTileMargin,
      ),
    );
    expect(
      m6ReadyIllustrationSource.right,
      lessThanOrEqualTo(
        m6SplashTileBounds.right - m6ReadyIllustrationMinTileMargin,
      ),
    );
    expect(
      m6ReadyIllustrationSource.top,
      greaterThanOrEqualTo(
        m6SplashTileBounds.top + m6ReadyIllustrationMinTileMargin,
      ),
    );
    expect(
      m6ReadyIllustrationSource.bottom,
      lessThanOrEqualTo(
        m6SplashTileBounds.bottom - m6ReadyIllustrationMinTileMargin,
      ),
    );
  });
}
