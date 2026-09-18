// VS16 M8 — Task reminder recurrence projection (Appendix T, T-E).
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late AppDatabase database;
  late DriftPlannerRepository planner;
  late String profileId;

  setUp(() async {
    database = openMemoryDatabase();
    addTearDown(database.close);
    planner = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 10, 9)),
    );
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
  });

  Future<PlannerTask> saveRecurring({
    required String id,
    required PlannerDate anchor,
    required PlannerTaskRecurrence recurrence,
    int? dueMinute = 480,
  }) => planner.saveTask(
    profileId: profileId,
    draft: PlannerTaskDraft(
      id: id,
      title: id,
      dueDate: anchor,
      dueMinute: dueMinute,
      recurrence: recurrence,
      requiresReport: true,
    ),
  );

  test(
    'T53 daily projection covers today..horizon and anchor-before-today',
    () async {
      await saveRecurring(
        id: 'daily',
        anchor: PlannerDate(year: 2026, month: 9, day: 1),
        recurrence: PlannerTaskRecurrence.daily,
      );
      final occurrences = await planner.readReminderTaskOccurrences(
        profileId: profileId,
        startDate: PlannerDate(year: 2026, month: 9, day: 10),
        endDate: PlannerDate(year: 2026, month: 9, day: 12),
      );
      expect(
        occurrences.map((occurrence) => occurrence.projectedDate.iso8601),
        <String>['2026-09-10', '2026-09-11', '2026-09-12'],
      );
      expect(occurrences.every((o) => o.task.id == 'daily'), isTrue);
      expect(occurrences.first.occurrenceId, 'task:daily:2026-09-10');
    },
  );

  test('T53 weekly and month-end and leap-year projections', () async {
    await saveRecurring(
      id: 'weekly',
      anchor: PlannerDate(year: 2026, month: 9, day: 3),
      recurrence: PlannerTaskRecurrence.weekly,
    );
    final weekly = await planner.readReminderTaskOccurrences(
      profileId: profileId,
      startDate: PlannerDate(year: 2026, month: 9, day: 10),
      endDate: PlannerDate(year: 2026, month: 9, day: 24),
    );
    expect(
      weekly.map((occurrence) => occurrence.projectedDate.iso8601),
      <String>['2026-09-10', '2026-09-17', '2026-09-24'],
    );

    await saveRecurring(
      id: 'month-end',
      anchor: PlannerDate(year: 2026, month: 1, day: 31),
      recurrence: PlannerTaskRecurrence.monthly,
    );
    final monthEnd = await planner.readReminderTaskOccurrences(
      profileId: profileId,
      startDate: PlannerDate(year: 2026, month: 2, day: 1),
      endDate: PlannerDate(year: 2026, month: 2, day: 28),
    );
    expect(
      monthEnd.map((occurrence) => occurrence.projectedDate.iso8601),
      <String>['2026-02-28'],
    );

    await saveRecurring(
      id: 'leap',
      anchor: PlannerDate(year: 2024, month: 2, day: 29),
      recurrence: PlannerTaskRecurrence.yearly,
    );
    final leap = await planner.readReminderTaskOccurrences(
      profileId: profileId,
      startDate: PlannerDate(year: 2028, month: 2, day: 1),
      endDate: PlannerDate(year: 2028, month: 2, day: 29),
    );
    expect(
      leap
          .where((occurrence) => occurrence.task.id == 'leap')
          .map((occurrence) => occurrence.projectedDate.iso8601),
      <String>['2028-02-29'],
    );
  });

  test('T55 date-only Task creates no reminder occurrence', () async {
    await saveRecurring(
      id: 'date-only',
      anchor: PlannerDate(year: 2026, month: 9, day: 10),
      recurrence: PlannerTaskRecurrence.none,
      dueMinute: null,
    );
    final occurrences = await planner.readReminderTaskOccurrences(
      profileId: profileId,
      startDate: PlannerDate(year: 2026, month: 9, day: 10),
      endDate: PlannerDate(year: 2026, month: 9, day: 12),
    );
    expect(occurrences, isEmpty);
  });

  test('T54 nonrecurring anchor before today is not resurrected', () async {
    await saveRecurring(
      id: 'one-off',
      anchor: PlannerDate(year: 2026, month: 9, day: 1),
      recurrence: PlannerTaskRecurrence.none,
    );
    final occurrences = await planner.readReminderTaskOccurrences(
      profileId: profileId,
      startDate: PlannerDate(year: 2026, month: 9, day: 10),
      endDate: PlannerDate(year: 2026, month: 9, day: 12),
    );
    expect(occurrences, isEmpty);
  });

  test('T57 whole-Task terminal status cancels every projected date', () async {
    await saveRecurring(
      id: 'terminal',
      anchor: PlannerDate(year: 2026, month: 9, day: 1),
      recurrence: PlannerTaskRecurrence.daily,
    );
    final before = await planner.readReminderTaskOccurrences(
      profileId: profileId,
      startDate: PlannerDate(year: 2026, month: 9, day: 10),
      endDate: PlannerDate(year: 2026, month: 9, day: 12),
    );
    expect(before, isNotEmpty);
    await planner.changeTaskStatus(
      profileId: profileId,
      taskId: 'terminal',
      target: PlannerTaskStatus.completed,
      operationId: 'op-1',
    );
    final after = await planner.readReminderTaskOccurrences(
      profileId: profileId,
      startDate: PlannerDate(year: 2026, month: 9, day: 10),
      endDate: PlannerDate(year: 2026, month: 9, day: 12),
    );
    expect(after, isEmpty);
  });
}
