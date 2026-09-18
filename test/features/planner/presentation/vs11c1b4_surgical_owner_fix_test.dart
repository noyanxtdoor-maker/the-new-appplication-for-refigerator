import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

/// VS-11C1B.4 fail-first contract tests (owner physical review findings).
///
/// Under test:
/// - Backup Event stays in the right-side backup lane, including draft state;
/// - Backup Event suppresses ALL reporting while Backup is ON;
/// - Task has no Backup control anywhere active;
/// - Task has no Report Required toggle anywhere active; Tasks are
///   report-required by product policy; Current Status appears only after the
///   scheduled time has passed;
/// - Task block and Task draft use the long Event-style horizontal lane
///   language (not a compact right-edge pill); ONE move-time grip only;
/// - floating "+" Event reconnects to the SAME non-modal draft sheet as the
///   working timeline path (grips usable);
/// - Task block tap opens an Event-style Task preview sheet (X / title /
///   pencil, Current Status when eligible, no links / no Backup / no toggle /
///   no developer paragraph);
/// - C1B-added Task-specific Planner filter controls are gone; the older
///   Event / Backup Event filter behavior remains.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const taskId = '77777777-7777-4777-8777-777777777777';
  const eventId = '88888888-8888-4888-8888-888888888888';
  const backupEventId = '99999999-9999-4999-8999-999999999999';

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
      tester.element(find.byKey(const Key('planner-create-button'))),
    );
  }

  Future<void> openTaskFormFromFab(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-task-action')));
    await tester.pumpAndSettle();
  }

  Future<void> openEventFormFromFab(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-calendar-event-action')));
    await tester.pumpAndSettle();
    final other = find.byKey(const Key('event-type-option-other'));
    await tester.ensureVisible(other);
    await tester.pumpAndSettle();
    await tester.tap(other);
    await tester.pumpAndSettle();
  }

  Future<void> openTaskEditFromTasksView(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('planner-overflow-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('planner-task-$taskId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit Task'));
    await tester.pumpAndSettle();
  }

  /// Direct route navigation for Tasks that are NOT visible in the
  /// selected-day Tasks presentation (e.g. a future-dated Task):
  /// /tasks/:taskId/edit.
  Future<void> openTaskEditDirectly(WidgetTester tester) async {
    final context = tester.element(
      find.byKey(const Key('planner-create-button')),
    );
    unawaited(context.push('${RoutePaths.tasks}/$taskId/edit'));
    await tester.pumpAndSettle();
  }

  DriftCalendarEventRepository calendar(AppDatabase database) {
    return DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    );
  }

  // -------------------------------------------------- remove Task Backup UX
  // The Task form is a lazy ListView: scroll to the bottom first so absence
  // assertions prove the controls are really gone (not merely below the fold).
  Future<void> scrollTaskFormToBottom(WidgetTester tester) async {
    final scroll = find.byKey(const Key('task-form-scroll'));
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('C1B4-01: Create Task form has NO Backup switch', (tester) async {
    await pumpApp(tester);
    await openTaskFormFromFab(tester);
    await scrollTaskFormToBottom(tester);
    expect(
      find.byKey(const Key('task-backup-switch')),
      findsNothing,
      reason: 'C1B4 RED: Task create form still exposes the Backup switch',
    );
  });

  testWidgets('C1B4-02: Create Task form has NO Report Required switch',
      (tester) async {
    await pumpApp(tester);
    await openTaskFormFromFab(tester);
    await scrollTaskFormToBottom(tester);
    expect(
      find.byKey(const Key('task-report-required-switch')),
      findsNothing,
      reason: 'C1B4 RED: Task create form still exposes the Report Required '
          'switch',
    );
  });

  testWidgets('C1B4-03: Edit Task form has NO Backup / Report Required '
      'switches', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Editable task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: true,
          ),
        );
      },
    );
    await openTaskEditFromTasksView(tester);
    expect(
      find.byKey(const Key('task-backup-switch')),
      findsNothing,
      reason: 'C1B4 RED: Edit Task form still exposes the Backup switch',
    );
    expect(
      find.byKey(const Key('task-report-required-switch')),
      findsNothing,
      reason: 'C1B4 RED: Edit Task form still exposes the Report Required '
          'switch',
    );
  });

  // -------------------------------------------------- always report-required
  testWidgets('C1B4-04: future Task Edit form hides Current Status',
      (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Future task',
            dueDate: PlannerDate(year: 2027, month: 1, day: 1),
            dueMinute: 9 * 60,
            requiresReport: true,
          ),
        );
      },
    );
    await openTaskEditDirectly(tester);
    expect(
      find.byKey(const Key('task-status-section')),
      findsNothing,
      reason: 'C1B4 RED: future Task still shows Current Status in Edit',
    );
  });

  testWidgets('C1B4-05: past Task Edit form shows Current Status '
      'automatically', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Past task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: true,
          ),
        );
      },
    );
    await openTaskEditFromTasksView(tester);
    expect(
      find.byKey(const Key('task-status-section')),
      findsOneWidget,
      reason: 'C1B4 RED: past Task Current Status is not visible in Edit',
    );
  });

  // -------------------------------------------------- long Task blocks
  testWidgets('C1B4-06: non-overlapping Task block uses the long Event-style '
      'lane width (not a compact pill)', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Long block task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: true,
          ),
        );
      },
    );
    final block = find.byKey(Key('planner-task-block-$taskId'));
    await tester.ensureVisible(block);
    await tester.pumpAndSettle();
    final width = tester.getSize(block).width;
    expect(
      width > 200,
      isTrue,
      reason: 'C1B4 RED: Task block is a compact pill (width $width)',
    );
  });

  testWidgets('C1B4-07: Task draft uses the long Event-style lane width',
      (tester) async {
    await pumpApp(tester);
    await openTaskFormFromFab(tester);
    final block = find.byKey(const Key('planner-task-draft-block'));
    await tester.ensureVisible(block);
    await tester.pumpAndSettle();
    final width = tester.getSize(block).width;
    expect(
      width > 200,
      isTrue,
      reason: 'C1B4 RED: Task draft is a compact pill (width $width)',
    );
  });

  // ------------------------------------------ floating "+" Event reconnection
  testWidgets('C1B4-08: floating "+" Event opens the SAME non-modal '
      'provisional sheet as the working timeline path', (tester) async {
    await pumpApp(tester);
    await openEventFormFromFab(tester);
    expect(
      find.byKey(const Key('calendar-event-provisional-draggable-sheet')),
      findsOneWidget,
      reason: 'C1B4 RED: floating "+" Event still uses the modal sheet whose '
          'barrier blocks the draft grips',
    );
    expect(
      find.byKey(const Key('calendar-event-draggable-sheet')),
      findsNothing,
      reason: 'floating "+" Event must not open the modal sheet',
    );
  });

  // --------------------------------------------- Backup Event lane placement
  // VS-11C1B.4 (defect 1): a Backup Event must always occupy the established
  // RIGHT-side backup lane next to its main Event in the settled Planner.
  testWidgets('C1B4-17: a Backup Event stays in the right-side backup lane '
      'beside its main Event in the settled Planner', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await calendar(database).saveEvent(
          profileId: profileId,
          draft: const CalendarEventDraft(
            id: eventId,
            title: 'Main event',
            timing: CalendarEventTiming.timed,
            startDate: selected,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            timeZoneId: 'Asia/Manila',
            requiresReport: true,
          ),
        );
        await calendar(database).saveEvent(
          profileId: profileId,
          draft: const CalendarEventDraft(
            id: backupEventId,
            title: 'Backup lane event',
            timing: CalendarEventTiming.timed,
            startDate: selected,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            timeZoneId: 'Asia/Manila',
            requiresReport: false,
            isBackupAppointment: true,
          ),
        );
      },
    );
    final mainKey = find.byKey(
      Key(
        'planner-timed-event-'
        '${CalendarEventOccurrenceIdentity.forDate(eventId: eventId, originalDate: selected)}',
      ),
    );
    final backupKey = find.byKey(
      Key(
        'planner-timed-event-'
        '${CalendarEventOccurrenceIdentity.forDate(eventId: backupEventId, originalDate: selected)}',
      ),
    );
    await tester.ensureVisible(backupKey);
    await tester.pumpAndSettle();
    final mainCenter = tester.getCenter(mainKey);
    final backupCenter = tester.getCenter(backupKey);
    expect(
      backupCenter.dx,
      greaterThan(mainCenter.dx),
      reason: 'C1B4 RED: Backup Event did not stay in the right-side backup '
          'lane (main dx=${mainCenter.dx}, backup dx=${backupCenter.dx})',
    );
  });

  // -------------------------------------------- Backup Event report suppression
  testWidgets('C1B4-09: past report-required Backup Event shows NO Current '
      'Status in the detail sheet', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await calendar(database).saveEvent(
          profileId: profileId,
          draft: const CalendarEventDraft(
            id: eventId,
            title: 'Backup event',
            timing: CalendarEventTiming.timed,
            startDate: selected,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            timeZoneId: 'Asia/Manila',
            requiresReport: true,
            isBackupAppointment: true,
          ),
        );
      },
    );
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: selected,
    );
    await tester.tap(find.byKey(Key('planner-timed-event-$occurrenceId')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('event-status-control')),
      findsNothing,
      reason: 'C1B4 RED: past Backup Event detail still shows Current Status',
    );
  });

  testWidgets('C1B4-10: past report-required Backup Event shows NO Current '
      'Status in the Edit Event form', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await calendar(database).saveEvent(
          profileId: profileId,
          draft: const CalendarEventDraft(
            id: eventId,
            title: 'Backup event edit',
            timing: CalendarEventTiming.timed,
            startDate: selected,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            timeZoneId: 'Asia/Manila',
            requiresReport: true,
            isBackupAppointment: true,
          ),
        );
      },
    );
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: selected,
    );
    await tester.tap(find.byKey(Key('planner-timed-event-$occurrenceId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('event-status-control')),
      findsNothing,
      reason: 'C1B4 RED: Edit Event form still shows Current Status for a '
          'Backup Event',
    );
  });

  testWidgets('C1B4-11: Backup Event is excluded from awaitingReportEvents',
      (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await calendar(database).saveEvent(
          profileId: profileId,
          draft: const CalendarEventDraft(
            id: eventId,
            title: 'Backup awaiting',
            timing: CalendarEventTiming.timed,
            startDate: selected,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            timeZoneId: 'Asia/Manila',
            requiresReport: true,
            isBackupAppointment: true,
          ),
        );
      },
    );
    final container = containerOf(tester);
    final day = container.read(plannerControllerProvider).day;
    expect(day, isNotNull);
    final awaiting = day!.awaitingReportEvents;
    expect(
      awaiting.where((event) => event.id == eventId),
      isEmpty,
      reason: 'C1B4 RED: Backup Event leaks into awaitingReportEvents',
    );
  });

  // -------------------------------------------- Event-style Task preview
  testWidgets('C1B4-12: Task block tap opens the Event-style Task preview '
      'sheet with X + pencil', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Preview task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: true,
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
      reason: 'Task block must open the Task preview sheet',
    );
    expect(
      find.byKey(const Key('task-preview-close')),
      findsOneWidget,
      reason: 'C1B4 RED: Task preview has no X close button',
    );
    expect(
      find.byKey(const Key('task-preview-edit-icon')),
      findsOneWidget,
      reason: 'C1B4 RED: Task preview has no pencil',
    );
    expect(
      find.byKey(const Key('task-detail-title')),
      findsNothing,
      reason: 'Task block tap must NOT open the full-page Task detail',
    );
  });

  testWidgets('C1B4-13: past report-eligible Task preview shows Current '
      'Status', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Eligible preview task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: true,
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
      find.byKey(const Key('task-preview-status-section')),
      findsOneWidget,
      reason: 'C1B4 RED: report-eligible Task preview has no Current Status',
    );
  });

  testWidgets('C1B4-14: Task preview has no Backup / Report-Required / '
      'Calendar Event Links surfaces', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Clean preview task',
            dueDate: selected,
            dueMinute: 9 * 60,
            requiresReport: true,
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
      find.text('Backup Task — reporting skipped'),
      findsNothing,
      reason: 'C1B4 RED: Task preview still shows a Backup row',
    );
    expect(
      find.textContaining('Status tracking'),
      findsNothing,
      reason: 'C1B4 RED: Task preview still shows a status-tracking row',
    );
    expect(
      find.byKey(const Key('task-report-required-switch')),
      findsNothing,
    );
    expect(
      find.text('Link or manage Calendar Events'),
      findsNothing,
      reason: 'C1B4 RED: Task preview still exposes Calendar Event Links',
    );
    expect(
      find.text('Create Calendar Event from Task'),
      findsNothing,
    );
  });

  // ------------------------------------------------ filter surgical revert
  testWidgets('C1B4-15: Planner filter shows Backup Events (not the C1B '
      '"Backups" label) and no Task-specific controls', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('planner-filter-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('Backup Events'),
      findsOneWidget,
      reason: 'C1B4 RED: the pre-existing Backup Events filter label is gone',
    );
    expect(find.text('Backups'), findsNothing);
    expect(
      find.byKey(const Key('planner-filter-events')),
      findsOneWidget,
      reason: 'the pre-existing Events filter must remain',
    );
    expect(
      find.byKey(const Key('planner-filter-backup-events')),
      findsOneWidget,
      reason: 'the pre-existing Backup Events filter must remain',
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
  });

  // ------------------------------------------------ no active Task link UX
  testWidgets('C1B4-16: full-page Task detail has no active Calendar Event '
      'Links UX', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Detail task',
            dueDate: selected,
            requiresReport: true,
          ),
        );
      },
    );
    await tester.tap(find.byKey(const Key('planner-overflow-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('planner-task-$taskId')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('manage-task-event-links')),
      findsNothing,
      reason: 'C1B4 RED: full-page Task detail still exposes Link/manage '
          'Calendar Events',
    );
    expect(
      find.byKey(const Key('create-event-from-task')),
      findsNothing,
      reason: 'C1B4 RED: full-page Task detail still exposes Create Calendar '
          'Event from Task',
    );
  });
}
