import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets(
    'Task Current Status writes directly from Task preview and locks Unreported',
    (tester) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      await DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ).saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'required-report-task',
          title: 'Required reporting fixture',
          dueDate: selected,
          dueMinute: 9 * 60,
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
          plannerDateSource: const FixedPlannerDateSource(selected),
          plannerIdentifierSource: SequenceIdentifierSource(<String>[
            '60000000-0000-4000-8000-000000000001',
            '60000000-0000-4000-8000-000000000002',
            '60000000-0000-4000-8000-000000000003',
            '60000000-0000-4000-8000-000000000004',
            '60000000-0000-4000-8000-000000000005',
            '60000000-0000-4000-8000-000000000006',
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
      await tester.scrollUntilVisible(
        find.text('Required reporting fixture'),
        250,
        scrollable: find.descendant(
          of: find.byKey(const Key('tasks-incomplete-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('Required reporting fixture'));
      await tester.pumpAndSettle();

      for (final outcome in <String>[
        'didNotHappen',
        'partiallyCompleted',
        'completedHappened',
      ]) {
        expect(find.byKey(Key('task-status-option-$outcome')), findsOneWidget);
      }

      // Phase B owns Task Current Status in Task Preview. A tap commits only
      // through the canonical outcome repository; no duplicate Task Edit
      // status editor is opened.
      await tester.tap(
        find.byKey(const Key('task-status-option-didNotHappen')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('task-status-current-label')))
            .data,
        'Did Not Attempt',
        reason: 'the direct Task selection must settle on Did Not Attempt',
      );
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('task-status-current-label')))
            .data,
        'Did Not Attempt',
        reason: 'the settled Task sheet must not flash back to Unreported',
      );
      expect(find.byKey(const Key('task-form-scroll')), findsNothing);
      var reports = await (database.select(
        database.outcomeReports,
      )..where((row) => row.sourceId.equals('required-report-task'))).get();
      expect(reports, hasLength(1));
      expect(reports.single.outcome, OutcomeKind.didNotHappen.name);

      await tester.tap(
        find.byKey(const Key('task-status-option-partiallyCompleted')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('task-status-current-label')))
            .data,
        'Missed',
        reason: 'the direct correction must settle on Missed',
      );
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('task-status-current-label')))
            .data,
        'Missed',
        reason: 'the settled Task sheet must not repaint the prior outcome',
      );
      reports = await (database.select(
        database.outcomeReports,
      )..where((row) => row.sourceId.equals('required-report-task'))).get();
      expect(reports, hasLength(2));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('task-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('task-status-current-label')))
            .data,
        'Completed',
        reason: 'the direct correction must settle on Completed',
      );
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('task-status-current-label')))
            .data,
        'Completed',
        reason:
            'the settled Task sheet must not repaint the prior Missed state',
      );
      expect(find.byKey(const Key('task-form-scroll')), findsNothing);

      final task = await (database.select(
        database.plannerTasks,
      )..where((row) => row.id.equals('required-report-task'))).getSingle();
      // The canonical report transaction owns its existing derived lifecycle
      // projection while retaining the factual report as a distinct row.
      expect(task.status, PlannerTaskStatus.completed.name);
      reports = await (database.select(
        database.outcomeReports,
      )..where((row) => row.sourceId.equals('required-report-task'))).get();
      expect(reports, hasLength(3));
      expect(
        reports.where(
          (row) => row.status == OutcomeReportStatus.submitted.name,
        ),
        hasLength(1),
      );

      // Owner law: Unreported stays visibly in-place, but cannot clear a
      // factual Task report. Tapping its disabled control is a no-op.
      await tester.tap(find.byKey(const Key('task-status-option-unreported')));
      await tester.pumpAndSettle();
      reports = await (database.select(
        database.outcomeReports,
      )..where((row) => row.sourceId.equals('required-report-task'))).get();
      expect(reports, hasLength(3));
      expect(
        reports.where(
          (row) => row.status == OutcomeReportStatus.submitted.name,
        ),
        hasLength(1),
        reason: 'Unreported is disabled after a factual Task outcome.',
      );
      expect(
        reports.last.outcome,
        OutcomeKind.completedHappened.name,
        reason: 'The direct correction remains the effective Task outcome.',
      );
    },
  );
}
