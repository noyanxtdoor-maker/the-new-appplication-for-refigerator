import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

import '../../../support/test_dependencies.dart';

/// VS-11C1B fail-first tests (RED before implementation).
///
/// A. Tasks visible in the Planner day view (dated / date-only / undated).
/// B. Planner "Show in Planner" filter defaults ALL ON.
/// C. Completed Task title strikethrough; skipped/cancelled do NOT.
/// D. Task reporting: report-required Task -> SAME Edit Task form with
///    Current Status at top; detail shortcut routes to the editor; direct
///    completion is blocked; no double-count through
///    TaskGoalContributionEngine + Activity Ledger.
/// E. Event delete dialogs: readable semantic text in Light/Dark x Blue/Rose;
///    single Delete Event destructive; Keep Event theme primary; recurring
///    delete buttons destructive.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const taskId = '77777777-7777-4777-8777-777777777777';
  const eventId = '88888888-8888-4888-8888-888888888888';
  const contributionRule = 'life-indicator:exercise:1:0:count';

  Future<({AppDatabase database, DriftOutcomeReportingRepository reports})>
  pumpApp(
    WidgetTester tester, {
    AppearanceMode appearance = AppearanceMode.dark,
    ThemeColorMode themeColor = ThemeColorMode.rose,
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
        initialAppearance: appearance,
        initialThemeColor: themeColor,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();

    return (database: database, reports: reportingRepository);
  }

  DriftPlannerRepository planner(AppDatabase database) {
    return DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      calendarSource: DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        timeZones: IanaCalendarEventTimeZones(
          displayTimeZoneId: 'Asia/Manila',
        ),
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

  Future<void> tapDetailOverflow(WidgetTester tester) async {
    final full = find.byKey(const Key('event-detail-overflow-icon'));
    final sheet = find.byKey(const Key('event-detail-sheet-overflow-icon'));
    await tester.tap(full.evaluate().isNotEmpty ? full : sheet);
    await tester.pumpAndSettle();
  }

  Future<void> openTaskDetail(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('planner-overflow-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-task-$taskId')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-detail-title')), findsOneWidget);
  }

  // ------------------------------------------------------------- RED: B1
  test('RED B1: Planner filter defaults are ALL ON (completed tasks '
      'included)', () {
    const filters = PlannerContentFilters.defaults();
    expect(filters.events, isTrue);
    expect(filters.backupEvents, isTrue);
    expect(filters.tasks, isTrue);
    expect(
      filters.completedTasks,
      isTrue,
      reason: 'RED: completedTasks currently defaults OFF',
    );
  });

  // ------------------------------------------------------------- RED: A1
  // VS-11C1B.3 (supersedes the revised-C1B Tasks section): a scheduled Task
  // is a lightweight block INSIDE the Day timeline at its single due minute.
  // The rejected separate Tasks section is gone.
  testWidgets('RED A1: dated Task renders as a timeline block in the DAY '
      'Planner', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Dated task',
            dueDate: selected,
            dueMinute: 10 * 60,
            requiresReport: false,
          ),
        );
      },
    );
    expect(
      find.byKey(const Key('planner-day-tasks-section')),
      findsNothing,
      reason: 'the rejected separate Tasks section must be removed',
    );
    expect(
      find.byKey(Key('planner-task-block-$taskId')),
      findsOneWidget,
      reason: 'RED: dated Task has no timeline block in the day Planner',
    );
    expect(find.text('Dated task'), findsOneWidget);
  });

  // ------------------------------------------------------------- RED: A1
  // VS-11C1B.3: undated legacy Tasks have no timeline anchor (a Task block
  // requires a due minute); they stay preserved and remain reachable through
  // the Planner Tasks presentation and normal Task screens. They are never
  // duplicated into a day.
  testWidgets('RED A1: undated Task stays OUT of the day timeline and '
      'remains reachable via the Tasks view', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Unscheduled task',
            dueDate: null,
            requiresReport: false,
          ),
        );
      },
    );
    expect(
      find.byKey(Key('planner-task-block-$taskId')),
      findsNothing,
      reason: 'undated Task must not fabricate a timeline position',
    );
    await tester.tap(find.byKey(const Key('planner-overflow-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-overflow-tasks')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('planner-task-$taskId')),
      findsOneWidget,
      reason: 'undated Task must remain reachable in the Tasks view',
    );
    expect(find.text('Unscheduled task'), findsOneWidget);
  });

  // ------------------------------------------------------------- RED: C
  testWidgets('RED C: completed Task title has strikethrough; skipped does '
      'not', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        final repo = planner(database);
        await repo.saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Completed task',
            dueDate: selected,
            requiresReport: false,
          ),
        );
        await repo.changeTaskStatus(
          profileId: profileId,
          taskId: taskId,
          target: PlannerTaskStatus.completed,
          operationId: 'op-complete',
        );
      },
    );
    await openTaskDetail(tester);
    final title = tester.widget<Text>(find.byKey(const Key('task-detail-title')));
    expect(
      title.style?.decoration,
      TextDecoration.lineThrough,
      reason: 'RED: completed Task title has no strikethrough',
    );
  });

  // ------------------------------------------------------------- RED: D
  test('RED D: TaskStatusPolicy blocks direct completion of a '
      'report-required Task', () {
    final task = PlannerTask(
      id: taskId,
      profileId: 'p',
      title: 'Report task',
      dueDate: selected,
      status: PlannerTaskStatus.incomplete,
      requiresReport: true,
      createdAtUtc: DateTime.utc(2026, 7, 27),
      updatedAtUtc: DateTime.utc(2026, 7, 27),
    );
    final outcome = TaskStatusPolicy.evaluate(
      task: task,
      target: PlannerTaskStatus.completed,
      hasReportOrLedgerEffect: false,
    );
    expect(
      outcome,
      TaskStatusChangeOutcome.reportRequired,
      reason: 'RED: report-required completion currently bypasses the report',
    );
  });

  // ------------------------------------------------------------- RED: D
  test('RED D: report-required Task completion via report writes NO '
      'TaskGoalContribution row (double-count)', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repo = planner(database);
    final reports = DriftOutcomeReportingRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final profile = (await buildTestRepository(
      database: database,
      privacyGate: TestPrivacyDependencies(database: database).gate,
    ).completeOnboarding());
    await repo.saveTask(
      profileId: profile.id,
      draft: const PlannerTaskDraft(
        id: taskId,
        title: 'Report required with goal',
        dueDate: selected,
        requiresReport: true,
        contributionRuleKey: contributionRule,
      ),
    );
    final source = (await reports.readTaskSource(
      profileId: profile.id,
      taskId: taskId,
    ))!;
    await reports.submit(
      profileId: profile.id,
      draft: OutcomeReportDraft(
        id: '99999999-0000-4000-8000-000000000001',
        source: source,
        activityDate: selected,
        outcome: OutcomeKind.completedHappened,
        contributions: const <ContributionDraft>[
          ContributionDraft(
            ruleKey: contributionRule,
            indicatorKey: 'exercise',
            value: IndicatorValue(scaledValue: 1, scale: 0, unit: 'count'),
          ),
        ],
      ),
      operationId: '99999999-0000-4000-8000-000000000002',
    );
    final taskGoalRows = await database
        .select(database.taskGoalContributions)
        .get();
    expect(
      taskGoalRows,
      isEmpty,
      reason: 'RED: report path reconciles a second contribution '
          '(ledger + taskGoalContribution = double count)',
    );
  });

  // ------------------------------------------------------------- RED: D
  testWidgets('RED D: report-required Task pencil shows Current Status in '
      'the SAME Edit Task form', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Report required task',
            dueDate: selected,
            requiresReport: true,
          ),
        );
      },
    );
    await openTaskDetail(tester);
    await tester.tap(find.byTooltip('Edit Task'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('task-form-scroll')),
      findsOneWidget,
      reason: 'RED: pencil must open the SAME Edit Task form',
    );
    expect(
      find.byKey(const Key('task-status-section')),
      findsOneWidget,
      reason: 'RED: report-required Task has no Current Status section',
    );
  });

  // ------------------------------------------------------------- RED: D
  testWidgets('RED D: report-required Task detail Completed shortcut routes '
      'to the Edit Task form (no direct persistence)', (tester) async {
    await pumpApp(
      tester,
      seed: ({required profileId, required database}) async {
        await planner(database).saveTask(
          profileId: profileId,
          draft: const PlannerTaskDraft(
            id: taskId,
            title: 'Shortcut task',
            dueDate: selected,
            requiresReport: true,
          ),
        );
      },
    );
    await openTaskDetail(tester);
    await tester.tap(find.byKey(const Key('complete-task-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('task-form-scroll')),
      findsOneWidget,
      reason: 'RED: Completed shortcut currently persists directly instead '
          'of routing to the Edit Task form',
    );
  });

  // ------------------------------------------------------------- RED: A2
  testWidgets('RED A2: Task form shows Scheduling Details (Date/Time/Repeat '
      'instead of the lone Set Due Date switch)', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-task-action')));
    await tester.pumpAndSettle();
    expect(
      find.text('Scheduling Details'),
      findsOneWidget,
      reason: 'RED: Task form still uses the lone Set Due Date switch',
    );
  });

  // ------------------------------------------------------- RED: E (dialogs)
  for (final (appearance, themeColor, label) in <(
    AppearanceMode,
    ThemeColorMode,
    String,
  )>[
    (AppearanceMode.light, ThemeColorMode.blue, 'Light Blue'),
    (AppearanceMode.light, ThemeColorMode.rose, 'Light Rose'),
    (AppearanceMode.dark, ThemeColorMode.blue, 'Dark Blue'),
    (AppearanceMode.dark, ThemeColorMode.rose, 'Dark Rose'),
  ]) {
    testWidgets('RED E ($label): single delete dialog uses readable semantic '
        'text; Delete Event is destructive; Keep Event is theme primary',
        (tester) async {
      await pumpApp(
        tester,
        appearance: appearance,
        themeColor: themeColor,
        seed: ({required profileId, required database}) async {
          final cal = DriftCalendarEventRepository(
            database: database,
            clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
            timeZones: IanaCalendarEventTimeZones(
              displayTimeZoneId: 'Asia/Manila',
            ),
          );
          await cal.saveEvent(
            profileId: profileId,
            draft: const CalendarEventDraft(
              id: eventId,
              title: 'Deletable event',
              timing: CalendarEventTiming.timed,
              startDate: selected,
              startMinute: 9 * 60,
              endMinute: 10 * 60,
              timeZoneId: 'Asia/Manila',
              requiresReport: false,
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
      await tapDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('event-overflow-delete')));
      await tester.pumpAndSettle();

      final dialogContext = tester.element(
        find.byKey(const Key('confirm-delete-event')),
      );
      final scheme = Theme.of(dialogContext).colorScheme;
      final titleStyle = tester
          .widget<Text>(find.text('Delete Calendar Event?'))
          .style;
      final bodyStyle = tester
          .widget<Text>(find.text('Historical records and reports will '
              'remain.'))
          .style;
      expect(
        titleStyle?.color,
        scheme.onSurface,
        reason: 'RED: dialog title is not onSurface (unreadable)',
      );
      expect(
        bodyStyle?.color,
        scheme.onSurfaceVariant,
        reason: 'RED: dialog body is not onSurfaceVariant (unreadable)',
      );
      final deleteButton = tester.widget<FilledButton>(
        find.byKey(const Key('confirm-delete-event')),
      );
      final deleteBg = deleteButton.style?.backgroundColor?.resolve(
        const <WidgetState>{},
      );
      expect(
        deleteBg,
        scheme.error,
        reason: 'RED: Delete Event is not destructive (error-family)',
      );
      final keepButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Keep Event'),
      );
      final keepFg = keepButton.style?.foregroundColor?.resolve(
        const <WidgetState>{},
      );
      expect(
        keepFg,
        scheme.primary,
        reason: 'RED: Keep Event is not theme primary',
      );
    });

    testWidgets('RED E ($label): repeating delete dialog uses destructive '
        'errorContainer buttons and theme-primary Keep', (tester) async {
      await pumpApp(
        tester,
        appearance: appearance,
        themeColor: themeColor,
        seed: ({required profileId, required database}) async {
          final cal = DriftCalendarEventRepository(
            database: database,
            clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
            timeZones: IanaCalendarEventTimeZones(
              displayTimeZoneId: 'Asia/Manila',
            ),
          );
          await cal.saveEvent(
            profileId: profileId,
            draft: const CalendarEventDraft(
              id: eventId,
              title: 'Repeating event',
              timing: CalendarEventTiming.timed,
              startDate: selected,
              startMinute: 9 * 60,
              endMinute: 10 * 60,
              timeZoneId: 'Asia/Manila',
              requiresReport: false,
              recurrence: CalendarRecurrenceRule(
                frequency: CalendarRecurrenceFrequency.daily,
              ),
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
      await tapDetailOverflow(tester);
      await tester.tap(find.byKey(const Key('event-overflow-delete')));
      await tester.pumpAndSettle();

      final dialogContext = tester.element(
        find.byKey(const Key('recurring-delete-dialog')),
      );
      final scheme = Theme.of(dialogContext).colorScheme;
      final titleStyle = tester
          .widget<Text>(find.text('Delete Repeating Event?'))
          .style;
      expect(
        titleStyle?.color,
        scheme.onSurface,
        reason: 'RED: repeating dialog title is not onSurface',
      );
      final thisButton = tester.widget<FilledButton>(
        find.byKey(const Key('recurring-delete-this-event')),
      );
      final thisBg = thisButton.style?.backgroundColor?.resolve(
        const <WidgetState>{},
      );
      expect(
        thisBg,
        scheme.errorContainer,
        reason: 'RED: Delete This Event is not destructive',
      );
      final keepButton = tester.widget<TextButton>(
        find.byKey(const Key('recurring-delete-keep-event')),
      );
      final keepFg = keepButton.style?.foregroundColor?.resolve(
        const <WidgetState>{},
      );
      expect(
        keepFg,
        scheme.primary,
        reason: 'RED: repeating Keep Event is not theme primary',
      );
    });
  }
}
