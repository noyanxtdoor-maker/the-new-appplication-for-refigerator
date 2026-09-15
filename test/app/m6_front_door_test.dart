import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/m5_app_splash.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/settings/data/drift_appearance_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';

import '../support/test_dependencies.dart';

void main() {
  testWidgets(
    'M6 front door with the real splash: Welcome -> Setup -> Ready -> Home',
    (tester) async {
      // The default test surface is used because this journey ends on the
      // seeded, established Home grid — the same surface every other
      // seeded-Home journey uses.
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
          enableAppSplash: true,
        ),
      );

      // The branded splash is up first, over the guarded front door.
      await tester.pump();
      expect(find.byType(M5AppSplash), findsOneWidget);
      expect(find.text('Your next transfer\nstarts here.'), findsNothing);

      // The splash leaves as soon as a guarded destination (the front door
      // itself) has rendered — never lingering over onboarding.
      await tester.pumpAndSettle();
      expect(find.byType(M5AppSplash), findsNothing);
      expect(find.text('Your next transfer\nstarts here.'), findsOneWidget);
      expect(
        find.text('Plan what matters, privately on this device.'),
        findsOneWidget,
      );

      // Welcome -> Setup creates the real incomplete checkpoint.
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.text('Setup')),
      );
      expect(
        container.read(startupControllerProvider),
        isA<StartupOnboarding>(),
      );

      // Real, persisted appearance selection.
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(container.read(appearanceProvider), AppearanceMode.light);
      final appearanceRepository = DriftAppearanceRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      expect(await appearanceRepository.readAppearance(), AppearanceMode.light);

      // Deferred rows are truthful and never "Coming soon".
      // The list is lazily built: scroll to the deferred section first.
      await tester.dragUntilVisible(
        find.text('You can add contacts later.'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      expect(find.text('You can set this up later.'), findsNWidgets(2));
      expect(find.text('You can add contacts later.'), findsOneWidget);
      expect(find.textContaining('Coming soon'), findsNothing);

      // Continue -> Ready; nothing is completed yet.
      await tester.dragUntilVisible(
        find.text('Continue'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text("You're ready."), findsOneWidget);
      expect(
        container.read(startupControllerProvider),
        isA<StartupOnboarding>(),
      );

      // The ONLY completion path: Go to Home.
      await tester.tap(find.text('Go to Home'));
      await tester.pumpAndSettle();

      expect(container.read(startupControllerProvider), isA<StartupReady>());
      expect(find.byKey(const Key('main-bottom-navigation')), findsOneWidget);
      expect(find.text('Get Started'), findsNothing);

      // Home renders with the seeded weekly plan, as before M6.
      final ready = container.read(startupControllerProvider) as StartupReady;
      await container
          .read(weeklyPlanningRepositoryProvider)
          .openOrCreate(
            profileId: ready.profile.id,
            date: const PlannerDate(year: 2026, month: 7, day: 27),
          );
      container.invalidate(weeklyPlanEstablishedProvider);
      await tester.pumpAndSettle();
      expect(find.text('Life Goals'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'a returning user bypasses every M6 screen, with or without a checkpoint',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);

      // Owner-continuity case: a profile created BEFORE M6 exists and the
      // onboarding checkpoint row is absent entirely.
      final seeding = buildTestRepository(database: database);
      await seeding.completeOnboarding();
      await (database.delete(database.onboardingCheckpoints)).go();

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
          enableAppSplash: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('main-bottom-navigation')), findsOneWidget);
      expect(find.text('Get Started'), findsNothing);
      expect(find.text('Setup'), findsNothing);
      expect(find.text("You're ready."), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'after completion, a restart lands on Home with the persisted appearance',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);

      // Session 1: full M6 flow with the Light choice.
      final firstRepository = buildTestRepository(database: database);
      final firstPrivacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        firstPrivacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: firstRepository,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      final firstContainer = ProviderScope.containerOf(
        tester.element(find.text('Setup')),
      );
      await tester.dragUntilVisible(
        find.text('Continue'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go to Home'));
      await tester.pumpAndSettle();
      expect(
        firstContainer.read(startupControllerProvider),
        isA<StartupReady>(),
      );
      expect(firstContainer.read(appearanceProvider), AppearanceMode.dark);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));

      // Session 2: a returning launch on the SAME database.
      final secondRepository = buildTestRepository(database: database);
      final secondPrivacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        secondPrivacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: secondRepository,
        ),
      );
      await tester.pumpAndSettle();

      // No M6 replay.
      expect(find.byKey(const Key('main-bottom-navigation')), findsOneWidget);
      expect(find.text('Get Started'), findsNothing);

      // The persisted appearance survived the restart (device-scoped row).
      final appearanceRepository = DriftAppearanceRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      expect(await appearanceRepository.readAppearance(), AppearanceMode.dark);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'Skip for now reaches Ready without completing; Back never deletes the checkpoint',
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
      await tester.pumpAndSettle();

      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('Skip for now'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.text("You're ready.")),
      );
      expect(
        container.read(startupControllerProvider),
        isA<StartupOnboarding>(),
      );

      // Ready Back returns to Setup.
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Setup'), findsOneWidget);

      // Setup Back returns to Welcome; the checkpoint stays for resume.
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Your next transfer\nstarts here.'), findsOneWidget);
      final snapshot = await repository.resolveStartup();
      expect(snapshot.onboardingCheckpoint, isNotNull);
      expect(snapshot.profile, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'M6 interrupted onboarding resumes Setup with the saved appearance',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final repository = buildTestRepository(database: database);
      // A previous visit left an incomplete checkpoint (process-death law)
      // and a saved accent choice.
      await repository.beginOrResumeOnboarding();
      final appearanceRepository = DriftAppearanceRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 26, 12)),
      );
      await appearanceRepository.saveThemeColor(ThemeColorMode.rose);

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
      await tester.pumpAndSettle();

      // Resume lands on Setup — never a fake Ready and never Welcome.
      expect(find.text('Setup'), findsOneWidget);
      expect(find.text("You're ready."), findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.text('Setup')),
      );
      expect(container.read(themeColorProvider), ThemeColorMode.rose);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

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
