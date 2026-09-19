// Owner law (2026-09-19) — the dedicated Tasks screen is the ONE canonical
// home for Tasks.
//
// It reads the real Drift Task universe: Incomplete and Completed are a split
// of the same persisted set, a completed Task is never hidden behind a
// retention window (PMG's seven-day rule is deliberately not imported), rows
// open the existing canonical Task Preview, and the FAB opens the existing
// create flow.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/task_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/tasks_screen.dart';

import '../../../support/test_dependencies.dart';

typedef _Seeded = ({AppDatabase database, DriftPlannerRepository repository});

void main() {
  /// One seeded database: onboarding runs ONCE here, and the app then starts
  /// against the same populated file — the same way a returning tester's
  /// device does.
  Future<_Seeded> seed() async {
    final database = openMemoryDatabase();
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    final repository = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 6, 10)),
    );
    final profileId = profile.id;

    Future<void> save({
      required String id,
      required String title,
      required PlannerDate? dueDate,
      int? dueMinute,
    }) => repository.saveTask(
      profileId: profileId,
      draft: PlannerTaskDraft(
        id: id,
        title: title,
        dueDate: dueDate,
        dueMinute: dueMinute,
        requiresReport: false,
      ),
    );

    await save(
      id: '30000000-0000-4000-8000-000000000001',
      title: 'Call ward clerk',
      dueDate: const PlannerDate(year: 2026, month: 9, day: 7),
      dueMinute: 9 * 60,
    );
    await save(
      id: '30000000-0000-4000-8000-000000000002',
      title: 'Undated follow-up',
      dueDate: null,
    );
    // Deliberately far in the past: a completed Task must stay findable no
    // matter how old it is.
    await save(
      id: '30000000-0000-4000-8000-000000000003',
      title: 'Completed long ago',
      dueDate: const PlannerDate(year: 2026, month: 1, day: 5),
      dueMinute: 8 * 60,
    );
    await repository.changeTaskStatus(
      profileId: profileId,
      taskId: '30000000-0000-4000-8000-000000000003',
      target: PlannerTaskStatus.completed,
      operationId: 'complete-old-task',
    );
    return (database: database, repository: repository);
  }

  Future<void> pumpTasksScreen(
    WidgetTester tester, {
    required _Seeded seeded,
  }) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(seeded.database.close);

    final privacy = TestPrivacyDependencies(database: seeded.database);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: buildTestRepository(
          database: seeded.database,
          privacyGate: privacy.gate,
        ),
        plannerRepository: seeded.repository,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-tasks')));
    await tester.pumpAndSettle();
  }

  testWidgets('Incomplete and Completed split the same persisted Task set', (
    tester,
  ) async {
    final seeded = await seed();
    await pumpTasksScreen(tester, seeded: seeded);

    expect(find.byType(TasksScreen), findsOneWidget);
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.byKey(const Key('tasks-tab-incomplete')), findsOneWidget);
    expect(find.byKey(const Key('tasks-tab-completed')), findsOneWidget);

    // Incomplete shows the two open Tasks and never the completed one.
    expect(
      find.byKey(const Key('tasks-row-30000000-0000-4000-8000-000000000001')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tasks-row-30000000-0000-4000-8000-000000000002')),
      findsOneWidget,
    );
    expect(find.text('Call ward clerk'), findsOneWidget);
    expect(find.text('Undated follow-up'), findsOneWidget);
    expect(
      find.byKey(const Key('tasks-row-30000000-0000-4000-8000-000000000003')),
      findsNothing,
      reason: 'a completed Task is not an incomplete Task',
    );

    // Completed shows the completed Task regardless of how old it is: there is
    // no retention window in Next Transfer.
    await tester.tap(find.byKey(const Key('tasks-tab-completed')));
    await tester.pumpAndSettle();
    expect(find.text('Completed long ago'), findsOneWidget);
    expect(find.text('Call ward clerk'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row opens the canonical Task Preview', (tester) async {
    final seeded = await seed();
    await pumpTasksScreen(tester, seeded: seeded);

    await tester.tap(
      find.byKey(const Key('tasks-row-30000000-0000-4000-8000-000000000001')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('task-preview-sheet')), findsOneWidget);
    expect(find.byKey(const Key('task-detail-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the FAB opens the existing create-Task flow', (tester) async {
    final seeded = await seed();
    await pumpTasksScreen(tester, seeded: seeded);

    expect(find.byKey(const Key('tasks-create-fab')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tasks-create-fab')));
    await tester.pumpAndSettle();

    expect(find.byType(TaskFormScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
