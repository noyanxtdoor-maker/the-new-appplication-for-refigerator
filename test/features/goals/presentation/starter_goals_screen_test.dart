import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/starter_goals_screen.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

/// Optional **Starter Goals** are ADD-ONLY and write nothing until confirm.
void main() {
  Future<void> openCatalog(WidgetTester tester) async {
    final context = tester.element(find.byType(Scaffold).first);
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const StarterGoalsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.dragUntilVisible(
      finder,
      find.byType(ListView),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
  }

  Future<TestPrivacyDependencies> pumpApp(
    WidgetTester tester,
    AppDatabase database,
    DriftStartupRepository startup,
  ) async {
    final privacy = TestPrivacyDependencies(database: database);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
      ),
    );
    await tester.pumpAndSettle();
    return privacy;
  }

  Future<int> goalCount(AppDatabase database) async =>
      (await database.select(database.goals).get()).length;

  testWidgets('browsing Starter Goals writes nothing and confirm starts disabled',
      (tester) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    await startup.completeOnboarding();
    await pumpApp(tester, database, startup);

    expect(await goalCount(database), 0);

    await openCatalog(tester);
    expect(find.text('Starter Goals'), findsOneWidget);
    expect(find.byKey(const Key('starter-goal-job_application')), findsOneWidget);

    // Opening the catalog is a pure read.
    expect(await goalCount(database), 0);
    await scrollTo(tester, find.byKey(const Key('starter-goals-confirm')));
    final confirm = tester.widget<FilledButton>(
      find.byKey(const Key('starter-goals-confirm')),
    );
    expect(confirm.onPressed, isNull);
  });

  testWidgets('selecting a starter writes nothing; confirm creates only it',
      (tester) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    await startup.completeOnboarding();
    await pumpApp(tester, database, startup);
    await openCatalog(tester);

    await tester.tap(
      find.byKey(const Key('starter-goal-job_application-select')),
    );
    await tester.pumpAndSettle();
    // Selection alone still writes nothing.
    expect(await goalCount(database), 0);

    await scrollTo(tester, find.byKey(const Key('starter-goals-confirm')));
    await tester.tap(find.byKey(const Key('starter-goals-confirm')));
    await tester.pumpAndSettle();

    final goals = await database.select(database.goals).get();
    expect(goals, hasLength(1));
    expect(goals.single.title, 'Job Applications');
    expect(goals.single.role, GoalRole.dailyWeekly.storageName);
  });

  testWidgets('confirm creates exactly the selected subset, target is editable',
      (tester) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    await startup.completeOnboarding();
    await pumpApp(tester, database, startup);
    await openCatalog(tester);

    // Two weekly templates, imported together.
    for (final id in <String>['scripture_study', 'exercise']) {
      await scrollTo(tester, find.byKey(Key('starter-goal-$id-select')));
      await tester.tap(find.byKey(Key('starter-goal-$id-select')));
      await tester.pumpAndSettle();
    }

    // The weekly target stepper is visible and adjustable before confirming.
    final weeklyStepper = find.byKey(
      const Key('starter-goal-scripture_study-weekly'),
    );
    await scrollTo(tester, weeklyStepper);
    expect(
      find.descendant(of: weeklyStepper, matching: find.text('1')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('starter-goal-scripture_study-weekly-increment')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: weeklyStepper, matching: find.text('2')),
      findsOneWidget,
    );

    await scrollTo(tester, find.byKey(const Key('starter-goals-confirm')));
    await tester.tap(find.byKey(const Key('starter-goals-confirm')));
    await tester.pumpAndSettle();

    final goals = await database.select(database.goals).get();
    expect(goals, hasLength(2));
    expect(
      goals.map((goal) => goal.title).toSet(),
      <String>{'Scripture Study', 'Exercise'},
    );
  });

  testWidgets('an already-owned canonical identity is unavailable, never replaced',
      (tester) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();

    // A user who already owns one weekly Goal (no auto-seed involved).
    final repository = DriftGoalRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 9, 12)),
      identifiers: const UuidIdentifierSource(),
    );
    final slot = await repository.nextAvailableSlot(
      profileId: profile.id,
      role: GoalRole.weekly,
    );
    await repository.createGoal(
      profileId: profile.id,
      role: GoalRole.weekly,
      title: 'Scripture Study',
      targets: const GoalTargets(),
      expectedSlotIndex: slot,
    );

    await pumpApp(tester, database, startup);
    await openCatalog(tester);

    // The occupied canonical slot is reported unavailable, with no way to
    // overwrite the existing Goal.
    await scrollTo(
      tester,
      find.byKey(const Key('starter-goal-scripture_study-unavailable')),
    );
    expect(
      find.byKey(const Key('starter-goal-scripture_study-unavailable')),
      findsOneWidget,
    );
    expect(find.text('Already active'), findsWidgets);
    expect(
      find.byKey(const Key('starter-goal-scripture_study-select')),
      findsNothing,
    );

    // Hard law: there is no Replace / Override / Delete affordance anywhere.
    expect(find.textContaining('Replace'), findsNothing);
    expect(find.textContaining('Override'), findsNothing);
    expect(find.textContaining('Delete'), findsNothing);
    expect(find.textContaining('Archive'), findsNothing);
  });
}
