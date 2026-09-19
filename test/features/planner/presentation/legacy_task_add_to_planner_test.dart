import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets(
    'Planner Tasks Preview restores one legacy Task in place and never offers '
    'the action for a fully scheduled Task',
    (tester) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final selected = PlannerDate.fromDateTime(DateTime.now());
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final planner = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 8, 29, 12)),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'legacy-task',
          title: 'Legacy Task',
          dueDate: null,
          requiresReport: true,
        ),
      );
      await planner.saveTask(
        profileId: profile.id,
        draft: PlannerTaskDraft(
          id: 'scheduled-task',
          title: 'Scheduled Task',
          dueDate: selected,
          dueMinute: 18 * 60,
          requiresReport: true,
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
          plannerRepository: planner,
          plannerDateSource: FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tasks-back')), findsOneWidget);

      await tester.tap(find.text('Legacy Task'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('task-detail-sheet-overflow-icon')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('task-overflow-add-to-planner')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('task-overflow-add-to-planner')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('task-add-to-planner-title')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('task-set-due-date-switch')), findsNothing);
      expect(find.byKey(const Key('task-add-people-button')), findsNothing);

      await tester.tap(find.byKey(const Key('task-form-close')));
      await tester.pumpAndSettle();
      var legacy = await planner.readTask(
        profileId: profile.id,
        taskId: 'legacy-task',
      );
      expect(legacy!.dueDate, isNull, reason: 'Cancel is a no-op.');
      expect(legacy.dueMinute, isNull, reason: 'Cancel is a no-op.');

      await tester.tap(
        find.byKey(const Key('task-detail-sheet-overflow-icon')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-overflow-add-to-planner')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-due-date-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-date-picker-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-due-time-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-task-button')));
      await tester.pumpAndSettle();

      legacy = await planner.readTask(
        profileId: profile.id,
        taskId: 'legacy-task',
      );
      expect(legacy, isNotNull);
      expect(
        legacy!.id,
        'legacy-task',
        reason: 'Restoration keeps the Task ID.',
      );
      expect(legacy.dueDate, selected);
      expect(legacy.dueMinute, 18 * 60);
      final rows = await (database.select(
        database.plannerTasks,
      )..where((table) => table.id.equals('legacy-task'))).get();
      expect(
        rows,
        hasLength(1),
        reason: 'Restoration must not duplicate rows.',
      );

      await tester.tap(find.byKey(const Key('task-preview-sheet-close')));
      await tester.pumpAndSettle();
      // Back to the Planner: the trip through the canonical Tasks screen
      // never disturbs the Planner's own Day timeline.
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      final footprint = find.byKey(const Key('task-footprint:legacy-task'));
      expect(footprint, findsOneWidget);
      expect(tester.widget<Positioned>(footprint).height, 15);

      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tasks-back')), findsOneWidget);
      expect(find.text('Legacy Task'), findsOneWidget);

      await tester.tap(find.text('Scheduled Task'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('task-detail-sheet-overflow-icon')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-overflow-duplicate')), findsOneWidget);
      expect(find.byKey(const Key('task-overflow-delete')), findsOneWidget);
      expect(
        find.byKey(const Key('task-overflow-add-to-planner')),
        findsNothing,
        reason:
            'A fully scheduled Task keeps its ordinary edit/reschedule path.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
