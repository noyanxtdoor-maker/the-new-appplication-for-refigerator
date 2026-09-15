import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const monday = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets(
    'VS08: Weekly Planning is WLI-only and has no global commitment creation',
    (tester) async {
      tester.view.physicalSize = const Size(941, 1672);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
      final m6LegacySeedProfile = await startup.completeOnboarding();
      await seedLegacyCanonicalGoals(database, m6LegacySeedProfile.id);
      final privacy = TestPrivacyDependencies(database: database);

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('weekly-targets-button')),
      );
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Goal Planning'), findsOneWidget);
      expect(find.textContaining('Jul 27'), findsOneWidget);
      expect(find.textContaining('Jul 27'), findsOneWidget);
      expect(find.textContaining('Asia/Manila'), findsNothing);
      expect(find.byKey(const Key('weekly-plan-identity')), findsNothing);
      expect(find.textContaining('Actual is factual'), findsNothing);
      expect(
        find.byKey(const Key('weekly-plan-indicator-job_applications')),
        findsOneWidget,
      );
      expect(find.text('Create Goal'), findsOneWidget);
      expect(find.text('Daily Progress Goal'), findsOneWidget);
      expect(find.text('Weekly Goals'), findsOneWidget);
      expect(find.text('Set Goal'), findsNWidgets(5));
      expect(find.byKey(const Key('weekly-plan-add-commitment')), findsNothing);
      expect(find.byKey(const Key('weekly-plan-create-task')), findsNothing);
      expect(find.byKey(const Key('weekly-plan-create-event')), findsNothing);
      expect(find.text('Commitments'), findsNothing);
      expect(find.text('New Task'), findsNothing);
      expect(find.text('New Event'), findsNothing);

      final historyButton = tester.widget<IconButton>(
        find.byKey(const Key('weekly-plan-history-button')),
      );
      expect(historyButton.onPressed, isNotNull);
      historyButton.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Plan History'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'Q4 / AC-I-002,004,008,019: Weekly Planning remains usable at 200% text',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 2.5;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
      final m6LegacySeedProfile = await startup.completeOnboarding();
      await seedLegacyCanonicalGoals(database, m6LegacySeedProfile.id);
      final privacy = TestPrivacyDependencies(database: database);

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pumpAndSettle();
      expect(find.text('Goal Planning'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('weekly-plan-indicator-meaningful_connections')),
        250,
        scrollable: find.descendant(
          of: find.byKey(const Key('weekly-plan-list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.byKey(const Key('weekly-plan-indicator-meaningful_connections')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'Pack 1: limit dialog is local and Manage Goals mode stays active until Cancel',
    (tester) async {
      tester.view.physicalSize = const Size(393, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(database, profile.id);
      final goalRepository = DriftGoalRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 3, 12)),
        identifiers: const UuidIdentifierSource(),
      );
      final firstGoal = (await goalRepository.readActiveGoals(
        profile.id,
      )).first;
      final privacy = TestPrivacyDependencies(database: database);

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('weekly-plan-create-goal')));
      await tester.pumpAndSettle();
      expect(find.text('Goal limit reached'), findsOneWidget);
      expect(
        find.text(
          'All 6 goal slots are currently in use. Archive at least one '
          'goal before creating another.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('weekly-plan-goal-limit-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Goal limit reached'), findsNothing);
      expect(
        find.byKey(const Key('weekly-plan-management-mode')),
        findsNothing,
      );
      expect(find.text('Goal Planning'), findsOneWidget);

      await tester.tap(find.byKey(const Key('weekly-plan-create-goal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-plan-goal-limit-manage')));
      await tester.pumpAndSettle();
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(
        find.byKey(const Key('weekly-plan-management-mode')),
        findsOneWidget,
      );

      // Management mode hides Create Goal, Manage Goals, the top-right
      // actions, and every row three-dot menu; direct Archive/Trash actions
      // and the X Cancel control are shown instead.
      expect(find.byKey(const Key('weekly-plan-create-goal')), findsNothing);
      expect(find.byKey(const Key('weekly-plan-manage-goals')), findsNothing);
      expect(
        find.byKey(Key('weekly-plan-goal-menu-${firstGoal.id}')),
        findsNothing,
      );
      expect(
        find.byKey(Key('weekly-plan-goal-direct-archive-${firstGoal.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('weekly-plan-goal-direct-delete-${firstGoal.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('weekly-plan-cancel-management')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('goal-archive-button')), findsNothing);

      // Canceling the shared archive confirmation preserves management mode.
      await tester.tap(
        find.byKey(Key('weekly-plan-goal-direct-archive-${firstGoal.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Archive "${firstGoal.title}"?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('weekly-plan-archive-cancel')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('weekly-plan-management-mode')),
        findsOneWidget,
      );

      // X Cancel exits management mode and the three-dot menus return.
      await tester.tap(find.byKey(const Key('weekly-plan-cancel-management')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('weekly-plan-management-mode')),
        findsNothing,
      );
      expect(
        find.byKey(Key('weekly-plan-goal-menu-${firstGoal.id}')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('weekly-plan-manage-goals')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
