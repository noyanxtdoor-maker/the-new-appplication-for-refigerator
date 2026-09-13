// VS16 M8 — Task recurrence reminder projection (contract section 37,
// scenarios T53-T57).
//
// The law under test:
//  * a Task keeps its WHOLE-SOURCE lifecycle. Recurrence is a projection over
//    dates built from the canonical `PlannerTask.projectsOn`, never a second
//    persisted occurrence row and never a rewritten `dueDate`;
//  * only INCOMPLETE and TIMED Tasks project. A date-only Task has no truthful
//    reminder time, so it never produces a reminder;
//  * a recurring Task whose anchor lies BEFORE today still projects future
//    occurrences inside the bounded horizon;
//  * the reminder fires on the PROJECTED date, and an exact dated override wins
//    over source/series policy, which wins over the global default;
//  * a terminal whole-Task status cancels EVERY projected reminder, because a
//    finished Task has no future occurrence.
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/notifications/domain/task_reminder_occurrence.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

/// The reconciler owns neither platform transport; it only needs a gateway so
/// a cancellation/re-schedule can be observed. This suite asserts PROJECTION
/// facts, so the gateway is deliberately inert.
final class _InertNotificationGateway implements NotificationGateway {
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<List<PendingLocalNotification>> pending() async =>
      const <PendingLocalNotification>[];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

void main() {
  // A fixed "today" so anchor-before-today and the bounded horizon are exact.
  final now = DateTime.utc(2026, 3, 15, 9);
  const today = PlannerDate(year: 2026, month: 3, day: 15);
  final horizonEnd = today.addDays(42);

  DriftPlannerRepository repositoryFor(dynamic database) =>
      DriftPlannerRepository(database: database, clock: FixedClock(now));

  Future<PlannerTask> saveTask(
    dynamic database, {
    required String profileId,
    required String id,
    required PlannerDate dueDate,
    int? dueMinute,
    PlannerTaskRecurrence recurrence = PlannerTaskRecurrence.none,
    String title = 'Task',
  }) async {
    final repository = repositoryFor(database);
    await repository.saveTask(
      profileId: profileId,
      draft: PlannerTaskDraft(
        id: id,
        title: title,
        dueDate: dueDate,
        dueMinute: dueMinute,
        recurrence: recurrence,
        requiresReport: true,
      ),
    );
    final saved = await repository.readTask(profileId: profileId, taskId: id);
    return saved!;
  }

  List<String> projectedDates(List<TaskReminderOccurrence> occurrences) =>
      occurrences
          .map((occurrence) => occurrence.projectedDate.iso8601)
          .toList(growable: false);

  group('T53 recurring incomplete timed Task projection', () {
    test('T53 daily recurrence projects every day inside the horizon', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'daily-task',
        dueDate: today,
        dueMinute: 9 * 60,
        recurrence: PlannerTaskRecurrence.daily,
      );

      final occurrences = await repositoryFor(database)
          .readTaskReminderOccurrences(
            profileId: profile.id,
            startDate: today,
            endDate: horizonEnd,
          );

      // 43 inclusive dates: today .. today+42.
      expect(occurrences, hasLength(43));
      expect(projectedDates(occurrences).first, today.iso8601);
      expect(projectedDates(occurrences).last, horizonEnd.iso8601);
      // Every occurrence carries the SAME single Task and its own date; no Task
      // source row was duplicated and no `dueDate` was rewritten.
      expect(occurrences.map((o) => o.task.id).toSet(), <String>{'daily-task'});
      expect(occurrences.first.task.dueDate, today);
    });

    test('T53 weekly recurrence projects only matching weekdays', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      // 2026-03-15 is a Sunday; weekly cadence repeats every 7th day.
      await saveTask(
        database,
        profileId: profile.id,
        id: 'weekly-task',
        dueDate: today,
        dueMinute: 9 * 60,
        recurrence: PlannerTaskRecurrence.weekly,
      );

      final occurrences = await repositoryFor(database)
          .readTaskReminderOccurrences(
            profileId: profile.id,
            startDate: today,
            endDate: horizonEnd,
          );

      final dates = projectedDates(occurrences);
      expect(dates, <String>[
        '2026-03-15',
        '2026-03-22',
        '2026-03-29',
        '2026-04-05',
        '2026-04-12',
        '2026-04-19',
        '2026-04-26',
      ]);
      for (final occurrence in occurrences) {
        expect(
          occurrence.projectedDate.weekday,
          today.weekday,
          reason: 'a weekly series never drifts to another weekday',
        );
      }
    });

    test('T53 monthly month-end behaviour clamps to the shorter month', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      // 31 January: canonical monthly arithmetic clamps to 28 Feb, then returns
      // to 31 March (schema-free matching dates).
      await saveTask(
        database,
        profileId: profile.id,
        id: 'month-end-task',
        dueDate: PlannerDate(year: 2026, month: 1, day: 31),
        dueMinute: 8 * 60,
        recurrence: PlannerTaskRecurrence.monthly,
      );

      final task = await repositoryFor(
        database,
      ).readTask(profileId: profile.id, taskId: 'month-end-task');

      expect(
        task!.projectsOn(PlannerDate(year: 2026, month: 2, day: 28)),
        isTrue,
        reason: '31 Jan clamps to 28 Feb in a non-leap year',
      );
      expect(
        task.projectsOn(PlannerDate(year: 2026, month: 2, day: 27)),
        isFalse,
      );
      expect(
        task.projectsOn(PlannerDate(year: 2026, month: 4, day: 30)),
        isTrue,
        reason: '31 Jan clamps to 30 Apr',
      );
      expect(
        task.projectsOn(PlannerDate(year: 2026, month: 5, day: 31)),
        isTrue,
      );
    });

    test('T53 leap-year behaviour projects 29 February', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'leap-task',
        dueDate: PlannerDate(year: 2024, month: 2, day: 29),
        dueMinute: 7 * 60,
        recurrence: PlannerTaskRecurrence.yearly,
      );

      final task = await repositoryFor(
        database,
      ).readTask(profileId: profile.id, taskId: 'leap-task');

      expect(
        task!.projectsOn(PlannerDate(year: 2028, month: 2, day: 29)),
        isTrue,
        reason: '29 Feb recurs on the next leap year',
      );
      // The canonical `CalendarRecurrenceRule` clamps a day that does not
      // exist in the target year to the last day of that month, exactly as the
      // monthly rule clamps 31 Jan to 28 Feb. M8 must NOT change that shared
      // arithmetic, so the projection follows it: a 29 Feb anchor lands on
      // 28 Feb in a non-leap year, never on 1 Mar.
      expect(
        task.projectsOn(PlannerDate(year: 2027, month: 2, day: 28)),
        isTrue,
        reason: '29 Feb clamps to the last day of a non-leap February',
      );
      expect(
        task.projectsOn(PlannerDate(year: 2027, month: 3, day: 1)),
        isFalse,
        reason: 'a clamped occurrence never rolls into the next month',
      );
    });

    test('T53 yearly recurrence projects the same month and day', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'yearly-task',
        dueDate: PlannerDate(year: 2020, month: 9, day: 14),
        dueMinute: 6 * 60,
        recurrence: PlannerTaskRecurrence.yearly,
      );

      final occurrences = await repositoryFor(database)
          .readTaskReminderOccurrences(
            profileId: profile.id,
            startDate: PlannerDate(year: 2026, month: 9, day: 1),
            endDate: PlannerDate(year: 2026, month: 9, day: 30),
          );

      expect(projectedDates(occurrences), <String>['2026-09-14']);
    });
  });

  group('T54 anchor before today still projects inside the horizon', () {
    test('T54 a daily Task anchored last week projects from today onward',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      // Anchor is 10 days BEFORE today: the anchor-only query is blind to it.
      await saveTask(
        database,
        profileId: profile.id,
        id: 'anchor-past-task',
        dueDate: today.addDays(-10),
        dueMinute: 9 * 60,
        recurrence: PlannerTaskRecurrence.daily,
      );

      final repository = repositoryFor(database);
      // The legacy anchor-only port genuinely misses it, which is exactly the
      // defect section 37 corrects.
      expect(
        await repository.readPendingReminderTasks(
          profileId: profile.id,
          startDate: today,
          endDate: horizonEnd,
        ),
        isEmpty,
      );
      // The recurrence-aware port still projects future occurrences.
      final occurrences = await repository.readTaskReminderOccurrences(
        profileId: profile.id,
        startDate: today,
        endDate: horizonEnd,
      );
      expect(occurrences, hasLength(43));
      expect(
        projectedDates(occurrences).first,
        today.iso8601,
        reason: 'the first projected date inside the window is today',
      );
      expect(
        occurrences.any((o) => o.projectedDate.compareTo(today) < 0),
        isFalse,
        reason: 'nothing before the window is projected',
      );
    });

    test('T54 a monthly Task anchored long ago still projects inside the '
        'horizon', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'old-monthly-task',
        dueDate: PlannerDate(year: 2025, month: 8, day: 15),
        dueMinute: 10 * 60,
        recurrence: PlannerTaskRecurrence.monthly,
      );

      final occurrences = await repositoryFor(database)
          .readTaskReminderOccurrences(
            profileId: profile.id,
            startDate: today,
            endDate: horizonEnd,
          );

      expect(projectedDates(occurrences), <String>[
        '2026-03-15',
        '2026-04-15',
      ]);
    });
  });

  group('T55 date-only Task produces no reminder', () {
    test('T55 a date-only Task never projects, even when recurring', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'date-only-task',
        dueDate: today,
        recurrence: PlannerTaskRecurrence.daily,
      );

      final occurrences = await repositoryFor(database)
          .readTaskReminderOccurrences(
            profileId: profile.id,
            startDate: today,
            endDate: horizonEnd,
          );

      expect(
        occurrences,
        isEmpty,
        reason:
            'a date-only Task has no truthful reminder time, so no reminder '
            'time may be fabricated for it',
      );
    });

    test('T55 a date-only Task is also absent from the anchor-only port',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'date-only-plain-task',
        dueDate: today.addDays(1),
      );

      expect(
        await repositoryFor(database).readPendingReminderTasks(
          profileId: profile.id,
          startDate: today,
          endDate: horizonEnd,
        ),
        isEmpty,
      );
    });
  });

  group('T56 exact dated override wins over source/series policy', () {
    test('T56 a dated occurrence override supplies the timing for that date',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'override-task',
        dueDate: today,
        dueMinute: 9 * 60,
        recurrence: PlannerTaskRecurrence.daily,
      );

      final foundation = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final reconciler = ReminderReconciler(
        repository: foundation,
        gateway: _InertNotificationGateway(),
        clock: FixedClock(now),
      );
      final occurrenceId = TaskReminderOccurrence(
        task: (await repositoryFor(
          database,
        ).readTask(profileId: profile.id, taskId: 'override-task'))!,
        projectedDate: today,
      ).occurrenceId;

      // Series policy: inherit the global default.
      await reconciler.savePolicy(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'override-task',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.inherit,
      );
      // Exact dated override for THIS occurrence: a 30-minute offset.
      await reconciler.savePolicy(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'override-task',
        occurrenceId: occurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 30,
      );

      final exact = await foundation.readPolicies(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'override-task',
      );
      final exactRow = exact.singleWhere(
        (p) => p.occurrenceId == occurrenceId,
      );
      expect(exactRow.mode, ReminderPolicyMode.offset);
      expect(exactRow.offsetMinutes, 30);

      // The exact dated row is a DIFFERENT logical key from the series row, so
      // the override never overwrites the series policy.
      final series = await foundation.readPolicies(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'override-task',
      );
      final seriesRow = series.singleWhere(
        (p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId,
      );
      expect(seriesRow.occurrenceId, ReminderPolicy.seriesOccurrenceId);
      expect(seriesRow.mode, ReminderPolicyMode.inherit);
    });

    test('T56 the projected occurrence key is per date, not per Task', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final task = await saveTask(
        database,
        profileId: profile.id,
        id: 'key-task',
        dueDate: today,
        dueMinute: 9 * 60,
        recurrence: PlannerTaskRecurrence.daily,
      );

      final first = TaskReminderOccurrence(
        task: task,
        projectedDate: today,
      ).occurrenceId;
      final second = TaskReminderOccurrence(
        task: task,
        projectedDate: today.addDays(1),
      ).occurrenceId;

      expect(first, isNot(second));
      expect(first, 'task:key-task:2026-03-15');
      expect(second, 'task:key-task:2026-03-16');
      // Canonical section 12 shape.
      expect(
        ReminderReconciler.stableKey(
          sourceKind: ReminderSourceKind.task,
          profileId: profile.id,
          occurrenceId: first,
        ),
        'reminder:task:${profile.id}:task:key-task:2026-03-15:base',
      );
      // The logical key never carries Contact, title, location or time.
      expect(
        ReminderReconciler.stableKey(
          sourceKind: ReminderSourceKind.task,
          profileId: profile.id,
          occurrenceId: first,
        ).contains(task.title),
        isFalse,
      );
    });
  });

  group('T57 whole-Task terminal status cancels all projected work', () {
    for (final terminal in <(PlannerTaskStatus, String)>[
      (PlannerTaskStatus.completed, 'completed'),
      (PlannerTaskStatus.skipped, 'skipped'),
      (PlannerTaskStatus.cancelled, 'cancelled'),
    ]) {
      test('T57 a ${terminal.$2} Task projects no occurrence', () async {
        final database = openMemoryDatabase();
        addTearDown(database.close);
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await saveTask(
          database,
          profileId: profile.id,
          id: 'terminal-task',
          dueDate: today,
          dueMinute: 9 * 60,
          recurrence: PlannerTaskRecurrence.daily,
        );
        // Before the status change the Task genuinely projects.
        expect(
          await repositoryFor(database).readTaskReminderOccurrences(
            profileId: profile.id,
            startDate: today,
            endDate: horizonEnd,
          ),
          hasLength(43),
        );

        await repositoryFor(database).changeTaskStatus(
          profileId: profile.id,
          taskId: 'terminal-task',
          target: terminal.$1,
          operationId: 'm8-t57-${terminal.$2}',
        );

        expect(
          await repositoryFor(database).readTaskReminderOccurrences(
            profileId: profile.id,
            startDate: today,
            endDate: horizonEnd,
          ),
          isEmpty,
          reason:
              'a terminal whole-Task status cancels ALL projected reminder '
              'work, not just the current occurrence',
        );
      });
    }

    test('T57 a hard-deleted Task projects no occurrence', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await saveTask(
        database,
        profileId: profile.id,
        id: 'deleted-task',
        dueDate: today,
        dueMinute: 9 * 60,
        recurrence: PlannerTaskRecurrence.daily,
      );

      final outcome = await repositoryFor(database).hardDeleteTask(
        profileId: profile.id,
        taskId: 'deleted-task',
      );
      expect(outcome.name, 'deleted');

      expect(
        await repositoryFor(database).readTaskReminderOccurrences(
          profileId: profile.id,
          startDate: today,
          endDate: horizonEnd,
        ),
        isEmpty,
      );
    });

    test('T57 terminal status cancels every projected DURABLE work row',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final task = await saveTask(
        database,
        profileId: profile.id,
        id: 'cancel-all-task',
        dueDate: today,
        dueMinute: 9 * 60,
        recurrence: PlannerTaskRecurrence.daily,
      );
      final foundation = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );

      // Persist three projected occurrences of ONE Task.
      final keys = <String>[];
      for (var dayOffset = 0; dayOffset < 3; dayOffset++) {
        final occurrenceId = TaskReminderOccurrence(
          task: task,
          projectedDate: today.addDays(dayOffset),
        ).occurrenceId;
        final key = ReminderReconciler.stableKey(
          sourceKind: ReminderSourceKind.task,
          profileId: profile.id,
          occurrenceId: occurrenceId,
        );
        keys.add(key);
        await foundation.upsertWorkRequest(
          BackgroundWorkRequest(
            stableKey: key,
            profileId: profile.id,
            category: BackgroundWorkCategory.reminderRecovery,
            ownerKind: BackgroundWorkOwnerKind.task,
            ownerId: 'cancel-all-task',
            occurrenceId: occurrenceId,
            sourceRevision: 'm7n_generic',
            scheduledForUtc: DateTime.utc(2026, 3, 15 + dayOffset, 9),
            state: BackgroundWorkState.scheduled,
            platformNotificationId: 900 + dayOffset,
            attemptCount: 0,
            snoozeCount: 0,
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
      }
      expect(
        await foundation.readReminderWork(
          profileId: profile.id,
          sourceKind: ReminderSourceKind.task,
          windowStartUtc: DateTime.utc(2026, 3, 1),
          windowEndUtc: DateTime.utc(2026, 5, 1),
        ),
        hasLength(3),
      );

      // Completing the WHOLE Task is the only truth that matters.
      await repositoryFor(database).changeTaskStatus(
        profileId: profile.id,
        taskId: 'cancel-all-task',
        target: PlannerTaskStatus.completed,
        operationId: 'm8-t57-cancel-all',
      );

      final reconciler = ReminderReconciler(
        repository: foundation,
        gateway: _InertNotificationGateway(),
        clock: FixedClock(now),
      );
      // A whole-Task terminal status cancels every projected occurrence.
      for (var dayOffset = 0; dayOffset < 3; dayOffset++) {
        await reconciler.cancel(
          sourceKind: ReminderSourceKind.task,
          profileId: profile.id,
          occurrenceId: TaskReminderOccurrence(
            task: task,
            projectedDate: today.addDays(dayOffset),
          ).occurrenceId,
          exactStableKey: keys[dayOffset],
        );
      }

      final remaining = await foundation.readReminderWork(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        windowStartUtc: DateTime.utc(2026, 3, 1),
        windowEndUtc: DateTime.utc(2026, 5, 1),
      );
      expect(
        remaining.where(
          (work) => work.state != BackgroundWorkState.cancelledObsolete,
        ),
        isEmpty,
        reason: 'no projected reminder survives a completed Task',
      );
    });
  });
}
