import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets('Task Preview has no superseded Event-link action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startupRepository.completeOnboarding();
    const date = PlannerDate(year: 2026, month: 7, day: 27);
    const taskId = '20000000-0000-4000-8000-000000000001';
    await DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    ).saveTask(
      profileId: profile.id,
      draft: const PlannerTaskDraft(
        id: taskId,
        title: 'Prepare visit',
        dueDate: date,
        requiresReport: false,
      ),
    );

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerDateSource: const FixedPlannerDateSource(date),
        plannerIdentifierSource: SequenceIdentifierSource(<String>[
          '40000000-0000-4000-8000-000000000001',
          '50000000-0000-4000-8000-000000000001',
        ]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-overflow-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tasks'));
    await tester.pumpAndSettle();
    // Owner law (2026-09-20): the Planner overflow `Tasks` row opens the ONE
    // canonical Tasks screen, whose row contract is `tasks-row-<id>`.
    final taskTile = find.byKey(const Key('tasks-row-$taskId'));
    final plannerScroll = find.descendant(
      of: find.byKey(const Key('tasks-incomplete-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(taskTile, 250, scrollable: plannerScroll);
    await tester.drag(plannerScroll, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(taskTile);
    await tester.pumpAndSettle();
    expect(find.text('Prepare visit'), findsWidgets);
    expect(find.text('Current Status'), findsOneWidget);
    expect(find.byKey(const Key('manage-task-event-links')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
