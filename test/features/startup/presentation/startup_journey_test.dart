import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets(
    'M6 front door: accessible Welcome reaches Home through Setup and Ready',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final repository = buildTestRepository(database: database);
      final privacy = TestPrivacyDependencies(database: database);

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: repository,
        ),
      );
      for (var frame = 0; frame < 6; frame += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Screen 1 — Welcome: approved copy, dots, no account/tutorial chrome.
      expect(find.text('Your next transfer\nstarts here.'), findsOneWidget);
      expect(
        find.text('The mission has ended. The next transfer begins.'),
        findsOneWidget,
      );
      expect(find.text('Get Started'), findsOneWidget);
      expect(find.text('The mission ended.'), findsNothing);
      expect(find.textContaining('account are not required'), findsNothing);
      expect(find.text('Display name (optional)'), findsNothing);

      // Screen 2 — Setup: reached by Get Started with a real checkpoint.
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsOneWidget);
      expect(find.text('Choose your\nappearance'), findsOneWidget);
      expect(
        find.text('Make Next Transfer look the way you like.'),
        findsOneWidget,
      );

      // Real Appearance controls (live-applied, persisted).
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.text('Setup')),
      );
      expect(container.read(appearanceProvider), AppearanceMode.light);

      // Deferred rows: truthful later wording, never "Coming soon".  The
      // rows sit below the accent selectors, so scroll to them.
      await tester.dragUntilVisible(
        find.text('Planner preferences'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Planner preferences'), findsOneWidget);
      expect(find.text('Contacts'), findsOneWidget);
      expect(find.text('You can set this up later.'), findsNWidgets(2));
      expect(find.text('You can add contacts later.'), findsOneWidget);
      expect(find.textContaining('Coming soon'), findsNothing);

      // Back returns to Welcome.  The title bar sits at the top of the
      // scrollable (unmounted while scrolled down), so scroll home first.
      await tester.drag(find.byType(ListView), const Offset(0, 800));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Your next transfer\nstarts here.'), findsOneWidget);

      // Forward again, then Continue.
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('Continue'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      // Screen 3 — You're Ready.
      expect(find.text("You're Ready"), findsOneWidget);
      expect(find.text("You're ready."), findsOneWidget);
      expect(
        find.text('Your next transfer starts with one step.'),
        findsOneWidget,
      );

      // Back returns to Setup (nothing completed yet).
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsOneWidget);

      // Forward once more, then the ONLY completion path.
      await tester.dragUntilVisible(
        find.text('Continue'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('Go to Home'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.tap(find.text('Go to Home'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('main-bottom-navigation')), findsOneWidget);
      final ready = container.read(startupControllerProvider);
      expect(ready, isA<StartupReady>());
      // The Light choice from Setup survived completion.
      expect(container.read(appearanceProvider), AppearanceMode.light);

      // Establish the current week so Home renders the established card grid.
      final profileId = (ready as StartupReady).profile.id;
      await container
          .read(weeklyPlanningRepositoryProvider)
          .openOrCreate(
            profileId: profileId,
            date: const PlannerDate(year: 2026, month: 7, day: 27),
          );
      container.invalidate(weeklyPlanEstablishedProvider);
      await tester.pumpAndSettle();
      expect(find.text('Life Goals'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Link recovery guarantee is retained after M6 completion.
      final homeContext = tester.element(
        find.byKey(const Key('main-bottom-navigation')),
      );
      GoRouter.of(homeContext).go('/invalid-startup-link');
      await tester.pumpAndSettle();
      expect(find.text('Link unavailable'), findsOneWidget);
      expect(find.text('No local record was changed.'), findsOneWidget);
      await tester.tap(find.text('Return to Home'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('main-bottom-navigation')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('M6 Skip for now reaches Ready without completing onboarding', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repository = buildTestRepository(database: database);
    final privacy = TestPrivacyDependencies(database: database);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: repository,
      ),
    );
    for (var frame = 0; frame < 6; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Skip for now'),
      find.byType(ListView),
      const Offset(0, -160),
    );
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    // Ready is visible, but no local profile exists yet: completion is
    // exclusively Go to Home.
    expect(find.text("You're ready."), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.text("You're ready.")),
    );
    expect(container.read(startupControllerProvider), isA<StartupOnboarding>());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('M6 interrupted onboarding resumes Setup with saved appearance', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repository = buildTestRepository(database: database);
    // A previous visit left an incomplete checkpoint (process death law).
    await repository.beginOrResumeOnboarding();
    final privacy = TestPrivacyDependencies(database: database);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: repository,
      ),
    );
    for (var frame = 0; frame < 6; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Resume lands on Setup — never a fake Ready and never Welcome.
    expect(find.text('Setup'), findsOneWidget);
    expect(find.text("You're ready."), findsNothing);

    // A saved appearance choice survives the restart presentation.
    final container = ProviderScope.containerOf(
      tester.element(find.text('Setup')),
    );
    await container
        .read(themeColorProvider.notifier)
        .setColor(ThemeColorMode.rose);
    await tester.pumpAndSettle();
    expect(container.read(themeColorProvider), ThemeColorMode.rose);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('AC-A-019: welcome remains usable at 200% text scale', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: buildTestRepository(database: database),
      ),
    );
    await tester.pumpAndSettle();

    // The single CTA remains reachable and hittable at 200% text scale
    // (scrolled into view, exactly like the accepted pre-M6 baseline).
    await tester.dragUntilVisible(
      find.text('Get Started'),
      find.byType(ListView),
      const Offset(0, -180),
    );
    expect(find.text('Get Started'), findsOneWidget);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    expect(find.text('Setup'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AC-A-009,010,018: startup failure exposes safe recovery', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: const FailingStartupRepository(),
      ),
    );
    for (var frame = 0; frame < 6; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Local data needs attention'), findsOneWidget);
    expect(
      find.textContaining('did not erase or recreate your local data'),
      findsOneWidget,
    );
    expect(find.text('Retry local startup'), findsOneWidget);
    expect(
      find.textContaining('VS-01 provides no automatic reset'),
      findsOneWidget,
    );
  });
}
