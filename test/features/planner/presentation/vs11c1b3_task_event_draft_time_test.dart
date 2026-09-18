import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/application/planner_task_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

/// VS-11C1B.3 fail-first tests.
///
/// Contract under test:
/// - floating "+" Event/Task uses the selected Planner day + the EXACT frozen
///   current local minute (never rounded, never "No time");
/// - the draft block is established IMMEDIATELY (before the form completes);
/// - the Task draft has exactly ONE move-time grip (no Event start/end grips),
///   dragging it changes the Task's single scheduled minute and the form Time
///   stays live-synced; the Task never gains a duration;
/// - Cancel removes the draft without saving; Save persists exactly one item;
/// - editing a saved Task converts it to an editable draft (grip appears);
/// - the Event draft keeps its existing two MP-06B grips;
/// - Task Backup suppresses Current Status; Backups is its own filter.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const taskId = '77777777-7777-4777-8777-777777777777';

  Future<AppDatabase> pumpApp(
    WidgetTester tester, {
    Future<void> Function({
      required String profileId,
      required AppDatabase database,
    })? seed,
  }) async {
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
    final linkRepository = DriftTaskEventLinkRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final reportingRepository = DriftOutcomeReportingRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final calendarRepository = DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
      taskContextSource: linkRepository,
      linkContextTransfer: linkRepository,
      reportSource: reportingRepository,
    );
    final plannerRepository = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      calendarSource: calendarRepository,
      taskContextSource: linkRepository,
      historicalEffectReader: reportingRepository,
    );
    if (seed != null) {
      await seed(profileId: profile.id, database: database);
    }

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerRepository: plannerRepository,
        calendarEventRepository: calendarRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    return database;
  }

  DriftPlannerRepository planner(AppDatabase database) {
    return DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      calendarSource: DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
        taskContextSource: DriftTaskEventLinkRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
        linkContextTransfer: DriftTaskEventLinkRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
        reportSource: DriftOutcomeReportingRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
      ),
      taskContextSource: DriftTaskEventLinkRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ),
      historicalEffectReader: DriftOutcomeReportingRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ),
    );
  }

  ProviderContainer containerOf(WidgetTester tester) {
    return ProviderScope.containerOf(
      tester.element(find.byKey(const Key('task-form-scroll'))),
    );
  }

  int nowMinute() {
    final now = DateTime.now();
    return now.hour * 60 + now.minute;
  }

  Future<void> openTaskFormFromFab(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-task-action')));
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------- B3-01: "+" Task anchor
  testWidgets('B3-01: "+" Task uses the selected Planner day + the exact '
      'current local minute (never "No time")', (tester) async {
    await pumpApp(tester);
    final beforeTap = nowMinute();
    await openTaskFormFromFab(tester);

    final draft = containerOf(tester).read(
      plannerTaskCreationDraftProvider,
    );
    expect(draft, isNotNull, reason: 'RED: no Task draft established');
    expect(draft!.date, selected, reason: 'draft must use the selected day');
    final afterTap = nowMinute();
    final capturedInWindow =
        draft.minute >= (beforeTap - 1) && draft.minute <= (afterTap + 1) ||
        draft.minute >= (afterTap - 1) && draft.minute <= (beforeTap + 1);
    expect(
      capturedInWindow,
      isTrue,
      reason: 'draft minute must be the frozen current local minute '
          '(got ${draft.minute}, window $beforeTap..$afterTap)',
    );
    expect(find.text('No time'), findsNothing);
    expect(find.text('Scheduling Details'), findsOneWidget);
  });

  // -------------------------------------------------- B3-02: "+" Event anchor
  testWidgets('B3-02: "+" Event draft + form start at the exact current '
      'minute; end = start + canonical default duration', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-calendar-event-action')));
    await tester.pumpAndSettle();
    final other = find.byKey(const Key('event-type-option-other'));
    await tester.ensureVisible(other);
    await tester.pumpAndSettle();
    final beforeTap = nowMinute();
    await tester.tap(other);
    await tester.pumpAndSettle();

    // The form sheet opens low and the From/To fields live below the
    // ListView fold, so read the draft from the always-built form scroll
    // context and scroll the form only to verify the displayed From value.
    final eventFormContext = tester.element(
      find.byKey(const Key('calendar-event-form-scroll')).first,
    );
    final container = ProviderScope.containerOf(eventFormContext);
    final draft = container.read(plannerEventCreationDraftProvider);
    expect(draft, isNotNull, reason: 'RED: no Event draft established');
    final afterTap = nowMinute();
    expect(
      draft!.startMinute >= (beforeTap - 1) && draft.startMinute <= (afterTap + 1) ||
          draft.startMinute >= (afterTap - 1) &&
              draft.startMinute <= (beforeTap + 1),
      isTrue,
      reason: 'Event draft must use the frozen current local minute',
    );
    expect(draft.date, selected);
    expect(
      draft.endMinute - draft.startMinute,
      30,
      reason: 'end must be start + the canonical default Event duration',
    );

    final startTime = find.byKey(const Key('event-start-time'));
    for (var attempt = 0; attempt < 8; attempt++) {
      if (startTime.evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(
        find.byKey(const Key('calendar-event-form-scroll')),
        const Offset(0, -220),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(startTime, findsWidgets);
    final expectedFrom = TimeOfDay(
      hour: draft.startMinute ~/ 60,
      minute: draft.startMinute % 60,
    ).format(eventFormContext);
    expect(find.text(expectedFrom), findsOneWidget);
  });

  // --------------------------------------- B3-03: Task draft block + ONE grip
  testWidgets('B3-03: Task draft shows ONE move-time grip and NO Event '
      'start/end resize grips', (tester) async {
    await pumpApp(tester);
    await openTaskFormFromFab(tester);

    expect(
      find.byKey(const Key('planner-task-draft-block')),
      findsOneWidget,
      reason: 'RED: no live Task draft block in the timeline',
    );
    expect(
      find.byKey(const Key('planner-task-draft-grip')),
      findsOneWidget,
      reason: 'RED: Task draft has no move-time grip',
    );
    // The Task draft must NOT get the Event start/end resize grips.
    expect(
      find.byKey(const Key('planner-provisional-start-handle')),
      findsNothing,
      reason: 'Task draft must not show the Event START grip',
    );
    expect(
      find.byKey(const Key('planner-provisional-resize-hit')),
      findsNothing,
      reason: 'Task draft must not show the Event END grip',
    );
  });

  // ----------------------------------------------- B3-04: grip drag sync
  testWidgets('B3-04: dragging the Task move grip changes the draft minute '
      'and the form Time stays live-synced', (tester) async {
    await pumpApp(tester);
    await openTaskFormFromFab(tester);

    final container = containerOf(tester);
    final before = container.read(plannerTaskCreationDraftProvider)!.minute;
    final grip = find.byKey(const Key('planner-task-draft-grip'));
    await tester.ensureVisible(grip);
    await tester.pumpAndSettle();
    await tester.drag(grip, const Offset(0, -90));
    await tester.pumpAndSettle();

    final after = container.read(plannerTaskCreationDraftProvider)!.minute;
    expect(
      after,
      isNot(before),
      reason: 'RED: grip drag did not move the Task time',
    );
    expect(
      find.text('No time'),
      findsNothing,
      reason: 'the Task must keep ONE scheduled time after the grip drag',
    );
    // The form Time field must reflect the new draft minute (live sync).
    // The field sits below the sheet ListView fold, so scroll it into view
    // first (the form and draft share one schedule source; the field renders
    // _dueMinute directly).
    final timeField = find.byKey(const Key('task-due-time-field'));
    for (var attempt = 0; attempt < 8; attempt++) {
      if (timeField.evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(
        find.byKey(const Key('task-form-scroll')),
        const Offset(0, -200),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(timeField, findsWidgets);
    final timeValue = tester
        .widget<Text>(
          find
              .descendant(
                of: timeField,
                matching: find.byType(Text),
              )
              .first,
        )
        .data;
    expect(timeValue, isNot('No time'));
    final expected = TimeOfDay(
      hour: after ~/ 60,
      minute: after % 60,
    ).format(tester.element(timeField));
    expect(timeValue, expected);
  });

  // -------------------------------------------- B3-05: form change -> draft
  testWidgets('B3-05: clearing the Task date in the form clears the draft '
      '(form is the source of truth)', (tester) async {
    await pumpApp(tester);
    await openTaskFormFromFab(tester);

    final container = containerOf(tester);
    expect(
      container.read(plannerTaskCreationDraftProvider),
      isNotNull,
    );
    await tester.ensureVisible(find.byKey(const Key('task-due-date-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-due-date-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-date-clear')));
    await tester.pumpAndSettle();

    expect(
      container.read(plannerTaskCreationDraftProvider),
      isNull,
      reason: 'RED: form date change did not update the draft',
    );
  });

  // --------------------------------------------------------- B3-06: cancel
  testWidgets('B3-06: cancelling a new Task removes the draft and saves '
      'nothing', (tester) async {
    final database = await pumpApp(tester);
    await openTaskFormFromFab(tester);
    final container = containerOf(tester);

    expect(
      container.read(plannerTaskCreationDraftProvider),
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('task-form-close')));
    await tester.pumpAndSettle();

    expect(
      container.read(plannerTaskCreationDraftProvider),
      isNull,
      reason: 'RED: cancel left the Task draft behind',
    );
    expect(
      await database.select(database.plannerTasks).get(),
      isEmpty,
      reason: 'cancel must save nothing',
    );
  });

  // ----------------------------------------------------------- B3-07: save
  testWidgets('B3-07: saving a new Task persists exactly one Task and '
      'replaces the draft (no duplicate)', (tester) async {
    final database = await pumpApp(tester);
    await openTaskFormFromFab(tester);
    final container = containerOf(tester);

    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      'Drafted task',
    );
    await tester.tap(find.byKey(const Key('save-task-button')));
    await tester.pumpAndSettle();

    final rows = await database.select(database.plannerTasks).get();
    expect(rows.length, 1, reason: 'save must persist exactly one Task');
    expect(rows.single.title, 'Drafted task');
    expect(rows.single.dueDate, selected.iso8601);
    expect(rows.single.dueMinute, isNotNull);
    expect(
      container.read(plannerTaskCreationDraftProvider),
      isNull,
      reason: 'save must clear the draft (replaced by the persisted Task)',
    );
    expect(
      find.byKey(const Key('planner-task-draft-block')),
      findsNothing,
    );
  });

  // ------------------------------------------- B3-08: edit -> draft + grip
  testWidgets('B3-08: editing a saved Task converts it to an editable draft '
      '(grip appears); cancel restores the original time', (tester) async {
    final database = await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Editable task',
            dueDate: selected,
            dueMinute: 10 * 60,
            requiresReport: false,
          ),
        );
      },
    );

    final block = find.byKey(Key('planner-task-block-$taskId'));
    await tester.ensureVisible(block);
    await tester.pumpAndSettle();
    await tester.tap(block);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('task-preview-title')),
      findsOneWidget,
      reason: 'tapping a saved Task block must open the Task preview',
    );
    await tester.tap(find.byKey(const Key('task-preview-edit')));
    await tester.pumpAndSettle();

    // The ProviderContainer stays valid after the sheet closes, so capture it
    // once and reuse it for the post-close assertion below.
    final container = containerOf(tester);
    final draft = container.read(plannerTaskCreationDraftProvider);
    expect(
      draft,
      isNotNull,
      reason: 'RED: edit did not create an editable draft',
    );
    expect(draft!.taskId, taskId);
    expect(draft.minute, 10 * 60, reason: 'draft must start at the saved time');
    expect(
      find.byKey(const Key('planner-task-draft-grip')),
      findsOneWidget,
      reason: 'RED: editing a Task does not show the move grip',
    );

    await tester.tap(find.byKey(const Key('task-form-close')));
    await tester.pumpAndSettle();
    expect(
      container.read(plannerTaskCreationDraftProvider),
      isNull,
    );
    final rows = await database.select(database.plannerTasks).get();
    expect(rows.single.dueMinute, 10 * 60);
    expect(rows.single.status, PlannerTaskStatus.incomplete.name);
  });

  // --------------------------------- B3-09: C1B.4 filter surgical revert
  // VS-11C1B.4 (defect 10): Backup is Event-only; the filter is the
  // pre-existing "Backup Events", and the C1B-added Task-specific controls
  // are gone.
  testWidgets('B3-09: the Planner filter keeps Events + Backup Events and '
      'exposes no Task-specific controls', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('planner-filter-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('Backup Events'),
      findsOneWidget,
      reason: 'C1B4 RED: the pre-existing Backup Events filter label is '
          'missing',
    );
    expect(find.text('Backups'), findsNothing);
    expect(
      find.byKey(const Key('planner-filter-events')),
      findsOneWidget,
      reason: 'the pre-existing Events filter must remain',
    );
    expect(
      find.byKey(const Key('planner-filter-tasks')),
      findsNothing,
      reason: 'C1B4 RED: the C1B-added Tasks filter control is still present',
    );
    expect(
      find.byKey(const Key('planner-filter-completed-tasks')),
      findsNothing,
      reason: 'C1B4 RED: the C1B-added Completed Tasks filter control is '
          'still present',
    );
    await tester.tap(find.byKey(const Key('planner-filter-apply')));
    await tester.pumpAndSettle();
  });

  // ------------------------------------------- B3-10: Event grips preserved
  testWidgets('B3-10: a timeline-created Event draft keeps its two accepted '
      'MP-06B grips', (tester) async {
    await pumpApp(tester);
    final surface = find.byKey(const Key('planner-timeline-create-surface'));
    final topLeft = tester.getTopLeft(surface);
    final size = tester.getSize(surface);
    // 9:30 AM = minute-of-day 570 at the default hour height (ppm 1).
    await tester.tapAt(topLeft + Offset(size.width / 2, 570));
    await tester.pumpAndSettle();
    final other = find.byKey(const Key('event-type-option-other'));
    await tester.ensureVisible(other);
    await tester.pumpAndSettle();
    await tester.tap(other);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('planner-provisional-start-handle')),
      findsOneWidget,
      reason: 'Event draft START grip must remain',
    );
    expect(
      find.byKey(const Key('planner-provisional-resize-hit')),
      findsOneWidget,
      reason: 'Event draft END grip must remain',
    );
  });

  // ----------------------------------------- B3-11: dormant Task Backup flag
  // VS-11C1B.4 (defect 3): Tasks are NOT Backup-capable in the active
  // product. A persisted (dormant) isBackup=true Task is a normal Task: it
  // stays in the timeline and is NEVER routed by the Backup Events filter.
  testWidgets('B3-11: a Task with the dormant isBackup flag is a normal '
      'timeline Task, never routed by the Backup Events filter', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Legacy backup-flagged task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: false,
            isBackup: true,
          ),
        );
      },
    );

    expect(
      find.byKey(Key('planner-task-block-$taskId')),
      findsOneWidget,
      reason: 'a dormant isBackup Task must render as a normal timeline Task',
    );
    // The Backup Events filter only ever governs Calendar Events; turning
    // it OFF must NOT remove the dormant-flagged Task.
    await tester.tap(find.byKey(const Key('planner-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-filter-backup-events')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-filter-apply')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('planner-task-block-$taskId')),
      findsOneWidget,
      reason: 'C1B4 RED: the Backup Events filter removed a Task',
    );
    expect(
      find.byKey(const Key('planner-filter-tasks')),
      findsNothing,
      reason: 'C1B4 RED: the C1B Tasks filter control is still present',
    );
  });

  // ---------------------------------------------------- B3-12: strikethrough
  testWidgets('B3-12: a completed Task timeline block strikes its title '
      'through (no completed style for skipped)', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        final repo = planner(database);
        await repo.saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Finished task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: false,
          ),
        );
        await repo.changeTaskStatus(
          profileId: profileId,
          taskId: taskId,
          target: PlannerTaskStatus.completed,
          operationId: 'op-complete-3',
        );
      },
    );

    expect(
      find.byKey(Key('planner-task-block-$taskId')),
      findsOneWidget,
      reason: 'completed Task block must render in the timeline',
    );
    final title = tester.widget<Text>(
      find.descendant(
        of: find.byKey(Key('planner-task-block-$taskId')),
        matching: find.text('Finished task'),
      ),
    );
    expect(
      title.style?.decoration,
      TextDecoration.lineThrough,
      reason: 'RED: completed Task block title is not struck through',
    );
  });

}

