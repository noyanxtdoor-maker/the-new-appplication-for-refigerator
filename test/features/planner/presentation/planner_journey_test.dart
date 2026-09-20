import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets(
    'AC-C-001..020 and AC-D-001..020: Planner and Task journey remains '
    'offline, distinct, factual, and non-destructive',
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
      final calendarSource = MemoryPlannerCalendarSource(<PlannerCalendarItem>[
        PlannerCalendarItem(
          id: 'event-all-day',
          title: 'All-day fixture',
          date: selected,
          timing: PlannerEventTiming.allDay,
          state: PlannerEventState.scheduled,
          requiresReport: false,
          hasOutcomeReport: false,
          locationText: 'Stored location fixture',
        ),
        PlannerCalendarItem(
          id: 'event-timed',
          title: 'Timed fixture',
          date: selected,
          timing: PlannerEventTiming.timed,
          state: PlannerEventState.scheduled,
          requiresReport: false,
          hasOutcomeReport: false,
          startLocal: DateTime(2026, 7, 27, 14),
          endLocal: DateTime(2026, 7, 27, 15),
          isRecurring: true,
          linkedTaskIds: const <String>['linked-task'],
        ),
        PlannerCalendarItem(
          id: 'event-awaiting',
          title: 'Awaiting fixture',
          date: selected,
          timing: PlannerEventTiming.timed,
          state: PlannerEventState.scheduled,
          requiresReport: true,
          hasOutcomeReport: false,
          startLocal: DateTime(2020, 1, 1, 8),
          endLocal: DateTime(2020, 1, 1, 9),
        ),
        PlannerCalendarItem(
          id: 'event-cancelled',
          title: 'Cancelled fixture',
          date: selected,
          timing: PlannerEventTiming.allDay,
          state: PlannerEventState.cancelled,
          requiresReport: false,
          hasOutcomeReport: false,
        ),
      ]);
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        calendarSource: calendarSource,
        taskContextSource: const MemoryPlannerTaskContextSource(
          <String, PlannerTaskContext>{
            'task-ui': PlannerTaskContext(
              linkedEventIds: <String>['event-timed'],
              pathwayContextLabels: <String>[
                'Employment pathway · Application milestone',
              ],
            ),
          },
        ),
      );
      await plannerRepository.saveTask(
        profileId: profile.id,
        draft: const PlannerTaskDraft(
          id: 'report-task',
          title: 'Report-required fixture',
          dueDate: selected,
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
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
          plannerIdentifierSource: SequenceIdentifierSource(<String>[
            'task-ui',
            '10000000-0000-4000-8000-000000000001',
            '10000000-0000-4000-8000-000000000002',
          ]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('planner-selected-date')), findsOneWidget);
      expect(find.byKey(const Key('planner-day-2026-07-27')), findsOneWidget);
      // Day view must not render an all-day lane; all-day records remain in
      // storage and surface through Schedule, Search, and Event details.
      expect(find.byKey(const Key('all-day-section')), findsNothing);
      expect(find.text('All-day fixture'), findsNothing);
      expect(find.textContaining('Timed fixture'), findsOneWidget);
      // Compact presentation keeps title/time stable through the shared
      // sub-hour zoom transition. The optional linked secondary row waits for
      // tall geometry, while the linked domain/report relationship remains
      // unchanged and is verified below through the task workflow.
      final timedEventContent = find.descendant(
        of: find.byKey(const Key('planner-timed-event-event-timed')),
        matching: find.byKey(const Key('planner-event-block-content')),
      );
      expect(timedEventContent, findsOneWidget);
      expect(
        find.descendant(of: timedEventContent, matching: find.text('1 linked')),
        findsNothing,
      );
      expect(find.byKey(const Key('planner-time-grid')), findsOneWidget);
      final timedEvent = tester.widget<Positioned>(
        find.byKey(const Key('planner-timed-event-event-timed')),
      );
      // Full civil-day canvas: 14:00 is minute-of-day 840, so
      // the block top is 840 at the default hour height of 60.
      expect(timedEvent.top, 840);
      expect(timedEvent.height, 60);

      await tester.tap(find.byKey(const Key('planner-create-button')));
      await tester.pumpAndSettle();
      expect(find.text('Task'), findsOneWidget);
      expect(find.text('Event'), findsOneWidget);
      await tester.tap(find.byKey(const Key('create-task-action')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('task-title-field')),
        'Offline Task',
      );
      await tester.enterText(
        find.byKey(const Key('task-notes-field')),
        'Input survives until an atomic save.',
      );
      await tester.tap(find.byKey(const Key('save-task-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tasks'));
      await tester.pumpAndSettle();

      // Owner law (2026-09-20): the overflow `Tasks` row opens the ONE
      // canonical Tasks screen; there is no in-Planner Tasks list any more.
      expect(find.byKey(const Key('tasks-tab-incomplete')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Offline Task'),
        250,
        scrollable: find.descendant(
          of: find.byKey(const Key('tasks-incomplete-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(find.text('Offline Task'));
      await tester.pumpAndSettle();
      expect(find.text('Offline Task'), findsOneWidget);
      await tester.tap(find.text('Offline Task'));
      await tester.pumpAndSettle();
      expect(find.text('Offline Task'), findsWidgets);
      expect(find.text('Current Status'), findsOneWidget);
      expect(find.text('Unreported'), findsOneWidget);
      expect(find.byKey(const Key('complete-task-button')), findsNothing);
      expect(find.byKey(const Key('manage-task-event-links')), findsNothing);
      expect(
        find.text('Employment pathway · Application milestone'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('task-preview-sheet-close')));
      await tester.pumpAndSettle();
      expect(find.text('Offline Task'), findsOneWidget);

      // The Planner content filters used to narrow the retired in-Planner
      // Tasks list; the canonical screen has its own Incomplete/Completed
      // split, so only the timeline scroll itself is exercised here.
      final tasksTimeline = find.descendant(
        of: find.byKey(const Key('tasks-incomplete-list')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.textContaining('Report-required fixture'),
        250,
        scrollable: tasksTimeline,
      );
      await tester.drag(tasksTimeline, const Offset(0, 180));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Report-required fixture'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('task-status-option-completedHappened')),
      );
      await tester.pumpAndSettle();
      // Task Preview exposes only its Task-scoped Activity History route.
      // Its completion state remains visible here.
      expect(find.text('Completed'), findsWidgets);

      // Task reporting commits directly through the canonical Task path; it
      // has no reporting-editor Save control to stage the outcome.
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-preview-sheet-close')));
      await tester.pumpAndSettle();
      // The canonical screen's back arrow returns to the Planner, which was
      // the recorded origin of this entry (owner law, 2026-09-20).
      await tester.tap(find.byKey(const Key('tasks-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-overflow-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Day'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Awaiting fixture'), findsOneWidget);
      // Elapsed report-required Event with no saved status shows the locked
      // Unreported [!] badge in its block, not a redundant text label.
      final awaitingBlock = find.byKey(
        const Key('planner-timed-event-event-awaiting'),
      );
      final awaitingBadge = find.descendant(
        of: awaitingBlock,
        matching: find.byType(PlannerEventStatusBadge),
      );
      expect(awaitingBadge, findsOneWidget);
      // Unreported renders as the canonical amber exclamation icon.
      expect(
        tester.widget<PlannerEventStatusBadge>(awaitingBadge).kind,
        PlannerReportStatusKind.unreported,
      );
      expect(find.text('Cancelled fixture'), findsNothing);

      final taskRows = await database.select(database.plannerTasks).get();
      expect(taskRows, hasLength(2));
      expect(
        taskRows.singleWhere((row) => row.id == 'report-task').status,
        PlannerTaskStatus.completed.name,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Planner Task form keeps Due Date controls optional while preserving its '
    'existing provisional placement on Save',
    (tester) async {
      tester.view.physicalSize = const Size(393, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      await startupRepository.completeOnboarding();

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
            'task-owner-form',
          ]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-create-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create-task-action')));
      await tester.pumpAndSettle();

      // Task creation begins as a partial sheet; expanding its real handle
      // exposes the form controls without using a separate full-screen route.
      await tester.drag(
        find.byKey(const Key('task-form-drag-handle')),
        const Offset(0, -480),
      );
      await tester.pumpAndSettle();

      // New Planner Tasks begin with Due Date deliberately off. Its controls
      // remain optional; the already-visible provisional position is still
      // preserved at Save so the canonical Task remains in Day.
      expect(find.byKey(const Key('task-due-date-field')), findsNothing);
      expect(find.byKey(const Key('task-due-time-field')), findsNothing);
      expect(find.byKey(const Key('task-repeat-field')), findsNothing);
      expect(find.text('Task Owner'), findsNothing);
      expect(find.text('Members Participating'), findsNothing);

      final dueDateSwitch = find.byKey(const Key('task-set-due-date-switch'));
      await tester.tap(dueDateSwitch);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-due-date-field')), findsOneWidget);
      expect(find.byKey(const Key('task-due-time-field')), findsOneWidget);
      expect(find.byKey(const Key('task-repeat-field')), findsOneWidget);

      await tester.tap(dueDateSwitch);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-due-date-field')), findsNothing);
      expect(find.byKey(const Key('task-due-time-field')), findsNothing);
      expect(find.byKey(const Key('task-repeat-field')), findsNothing);
      expect(find.byKey(const Key('task-notifications-notice')), findsNothing);
      expect(find.byKey(const Key('task-reminders-notice')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('task-title-field')),
        'Unscheduled Task',
      );
      await tester.enterText(
        find.byKey(const Key('task-notes-field')),
        'Description stays optional.',
      );
      // The DraggableScrollableSheet consumes the first extent to expand the
      // sheet; once expanded, the same controller exposes the form content.
      for (var index = 0; index < 3; index++) {
        await tester.drag(
          find.byKey(const Key('task-form-scroll')),
          const Offset(0, -480),
        );
        await tester.pumpAndSettle();
      }
      // B3.2: exactly ONE + Contacts affordance.  The legacy free-text add
      // dialog and the redundant Contacts/Add row no longer exist; tapping
      // Contacts opens the reusable selector flow.
      expect(find.byKey(const Key('task-person-name-field')), findsNothing);
      expect(find.byKey(const Key('task-add-contacts-button')), findsNothing);
      expect(find.byKey(const Key('task-add-people-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-add-people-button')));
      await tester.pumpAndSettle();
      expect(find.text('Add Contacts'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-task-button')));
      await tester.pumpAndSettle();

      final taskRow = await database.select(database.plannerTasks).getSingle();
      expect(taskRow.title, 'Unscheduled Task');
      expect(taskRow.dueDate, selected.iso8601);
      expect(taskRow.dueMinute, isNotNull);
      expect(taskRow.recurrenceFrequency, PlannerTaskRecurrence.none.name);
      expect(taskRow.peopleJson, '[]');
      expect(await database.select(database.calendarEvents).get(), isEmpty);
    },
  );

  testWidgets('AC-C-019 and AC-D-016: recoverable save failure retains input', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startupRepository.completeOnboarding();
    final failingRepository = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      writeGuard: const FailingTaskWriteGuard(),
    );

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerRepository: failingRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
        plannerIdentifierSource: SequenceIdentifierSource(<String>[
          'failed-task',
        ]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-task-action')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      'Retained Task Input',
    );
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('task-title-field')))
          .controller
          ?.text,
      'Retained Task Input',
    );
    expect(find.byKey(const Key('task-form-error')), findsOneWidget);
    expect(await database.select(database.plannerTasks).get(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Q4 / AC-C-001,002 and AC-D-001,004: Planner is usable at '
      '200% text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startupRepository.completeOnboarding();

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('planner-day-scroll')), findsOneWidget);
    expect(find.byKey(const Key('planner-create-button')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
