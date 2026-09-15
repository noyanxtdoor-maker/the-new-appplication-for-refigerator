import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const periodStart = PlannerDate(year: 2026, month: 8, day: 3);
  final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));

  DriftGoalRepository createRepository(AppDatabase database) {
    return DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
  }

  Future<(AppDatabase, DriftGoalRepository, String)> arrange() async {
    final database = openMemoryDatabase();
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    // These tests describe an EXISTING user: a pre-M6 install already owns the
    // canonical six Goals.  M6 no longer creates Goals at onboarding, so the
    // legacy seed is applied explicitly (see the zero-goal law tests).
    await seedLegacyCanonicalGoals(database, profile.id, clock: clock);
    return (database, createRepository(database), profile.id);
  }

  test('migrates six canonical goals and reads are watcher-stable', () async {
    final (database, repository, profileId) = await arrange();
    addTearDown(database.close);

    final active = await repository.readActiveGoals(profileId);
    expect(active, hasLength(6));
    expect(
      active.where((goal) => goal.role == GoalRole.dailyWeekly),
      hasLength(1),
    );
    expect(active.where((goal) => goal.role == GoalRole.weekly), hasLength(4));
    expect(
      active.where((goal) => goal.role == GoalRole.weeklyMonthly),
      hasLength(1),
    );
    expect(active.map((goal) => goal.activeSlotIndex), <int?>[
      1,
      2,
      3,
      4,
      5,
      6,
    ]);
    expect(active[3].title, 'Budget Review');
    expect(active.every((goal) => goal.iconId == null), isTrue);

    final activityRows = await (database.select(
      database.goalActivities,
    )..where((table) => table.profileId.equals(profileId))).get();
    expect(activityRows, hasLength(6));

    var eventCount = 0;
    final subscription = repository.watchChanges(profileId).listen((_) {
      eventCount += 1;
    });
    addTearDown(subscription.cancel);
    await repository.readPlanning(
      profileId: profileId,
      periodStart: periodStart,
    );
    await Future<void>.delayed(Duration.zero);
    expect(eventCount, 0);
  });

  test(
    'planning projects only canonical active slots and orders replacements by role',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);

      final active = await repository.readActiveGoals(profileId);
      for (var index = 0; index < active.length; index += 1) {
        await repository.archiveGoal(
          profileId: profileId,
          goalId: active[index].id,
          operationId: 'pack1-archive-default-$index',
        );
      }

      const target = IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count');
      await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weeklyMonthly,
        title: 'Replacement Monthly',
        iconId: 'temple',
        targets: const GoalTargets(weekly: target, monthly: target),
        operationId: 'pack1-create-monthly',
      );
      for (var index = 4; index >= 1; index -= 1) {
        await repository.createGoal(
          profileId: profileId,
          role: GoalRole.weekly,
          title: 'Replacement Weekly $index',
          iconId: 'open_book',
          targets: const GoalTargets(weekly: target),
          operationId: 'pack1-create-weekly-$index',
        );
      }
      await repository.createGoal(
        profileId: profileId,
        role: GoalRole.dailyWeekly,
        title: 'Replacement Daily',
        iconId: 'briefcase',
        targets: const GoalTargets(daily: target, weekly: target),
        operationId: 'pack1-create-daily',
      );

      final planning = await repository.readPlanning(
        profileId: profileId,
        periodStart: periodStart,
      );
      expect(planning.daily?.goal.title, 'Replacement Daily');
      expect(planning.weekly.map((progress) => progress.goal.title), <String>[
        'Replacement Weekly 4',
        'Replacement Weekly 3',
        'Replacement Weekly 2',
        'Replacement Weekly 1',
      ]);
      expect(
        planning.weekly.map((progress) => progress.goal.activeSlotIndex),
        <int?>[2, 3, 4, 5],
      );
      expect(planning.monthly?.goal.title, 'Replacement Monthly');
      expect(planning.daily?.goal.iconId, 'briefcase');
      expect(planning.monthly?.goal.iconId, 'temple');

      await database
          .into(database.goals)
          .insert(
            GoalsCompanion.insert(
              id: 'pack1-invalid-active-goal',
              profileId: profileId,
              role: GoalRole.weekly.storageName,
              title: 'Invalid Unslotted Goal',
              status: GoalStatus.active.name,
              activeSlotIndex: const Value<int?>(null),
              indicatorKey: const Value<String?>(null),
              iconId: const Value<String?>(null),
              createdAtUtc: clock.value,
              updatedAtUtc: clock.value,
              archivedAtUtc: const Value<DateTime?>(null),
            ),
          );
      final reloaded = await repository.readPlanning(
        profileId: profileId,
        periodStart: periodStart,
      );
      final projectedTitles = <String>[
        if (reloaded.daily != null) reloaded.daily!.goal.title,
        ...reloaded.weekly.map((progress) => progress.goal.title),
        if (reloaded.monthly != null) reloaded.monthly!.goal.title,
      ];
      expect(projectedTitles, isNot(contains('Invalid Unslotted Goal')));
      // Pre-M6 law: readActiveGoals returns every active row; canonical
      // slot filtering belongs to planning/capacity/slot allocation.
      expect(
        (await repository.readActiveGoals(profileId)).map((goal) => goal.title),
        contains('Invalid Unslotted Goal'),
      );

      final occupiedWeekly = reloaded.weekly.first.goal;
      await repository.archiveGoal(
        profileId: profileId,
        goalId: occupiedWeekly.id,
        operationId: 'pack1-archive-for-invalid-slot-capacity',
      );
      expect((await repository.readCapacity(profileId)).availableWeekly, 1);
      final replacement = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Capacity ignores invalid active slot',
        targets: const GoalTargets(weekly: target),
        operationId: 'pack1-create-after-invalid-slot',
      );
      expect(replacement.activeSlotIndex, occupiedWeekly.activeSlotIndex);
    },
  );

  test(
    'daily target update changes only the target and one idempotent outbox row',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      final daily = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.role == GoalRole.dailyWeekly);
      final before = await repository.readProgress(
        profileId: profileId,
        goalId: daily.id,
        today: periodStart,
      );
      expect(before != null, isTrue);
      final baseline = before!;
      final activityCountBefore = await (database.select(
        database.goalActivities,
      )..where((table) => table.profileId.equals(profileId))).get();
      final outboxCountBefore = await (database.select(
        database.goalOutboxOperations,
      )..where((table) => table.profileId.equals(profileId))).get();
      final ledgerCountBefore = await (database.select(
        database.activityLedgerEntries,
      )..where((table) => table.profileId.equals(profileId))).get();
      final reportCountBefore = await (database.select(
        database.outcomeReports,
      )..where((table) => table.profileId.equals(profileId))).get();

      const nextDailyTarget = IndicatorAmount(
        scaledValue: 3,
        scale: 0,
        unit: 'count',
      );
      final targets = GoalTargets(
        daily: nextDailyTarget,
        weekly: baseline.weeklyTarget.value,
        monthly: baseline.monthlyTarget.value,
      );
      final updated = await repository.saveGoal(
        profileId: profileId,
        goalId: daily.id,
        title: daily.title,
        iconId: daily.iconId,
        targets: targets,
        operationId: 'pack1-daily-target-update',
      );
      final retried = await repository.saveGoal(
        profileId: profileId,
        goalId: daily.id,
        title: daily.title,
        iconId: daily.iconId,
        targets: targets,
        operationId: 'pack1-daily-target-update',
      );
      final after = await repository.readProgress(
        profileId: profileId,
        goalId: daily.id,
        today: periodStart,
      );

      expect(updated.id, daily.id);
      expect(retried.id, daily.id);
      expect(updated.title, daily.title);
      expect(updated.iconId, daily.iconId);
      expect(updated.role, daily.role);
      expect(updated.activeSlotIndex, daily.activeSlotIndex);
      expect(after?.dailyTarget.value?.scaledValue, 3);
      expect(after?.dailyActual.scaledValue, baseline.dailyActual.scaledValue);
      expect(after?.dailyActual.scale, baseline.dailyActual.scale);
      expect(after?.dailyActual.unit, baseline.dailyActual.unit);
      expect(
        after?.weeklyActual.scaledValue,
        baseline.weeklyActual.scaledValue,
      );
      expect(after?.weeklyActual.scale, baseline.weeklyActual.scale);
      expect(after?.weeklyActual.unit, baseline.weeklyActual.unit);
      expect(
        after?.monthlyActual.scaledValue,
        baseline.monthlyActual.scaledValue,
      );
      expect(after?.monthlyActual.scale, baseline.monthlyActual.scale);
      expect(after?.monthlyActual.unit, baseline.monthlyActual.unit);

      final activityCountAfter = await (database.select(
        database.goalActivities,
      )..where((table) => table.profileId.equals(profileId))).get();
      final outboxCountAfter = await (database.select(
        database.goalOutboxOperations,
      )..where((table) => table.profileId.equals(profileId))).get();
      final targetOperations = outboxCountAfter.where(
        (row) => row.operationId == 'pack1-daily-target-update',
      );
      final ledgerCountAfter = await (database.select(
        database.activityLedgerEntries,
      )..where((table) => table.profileId.equals(profileId))).get();
      final reportCountAfter = await (database.select(
        database.outcomeReports,
      )..where((table) => table.profileId.equals(profileId))).get();

      expect(activityCountAfter, hasLength(activityCountBefore.length));
      expect(outboxCountAfter.length, outboxCountBefore.length + 1);
      expect(targetOperations, hasLength(1));
      expect(ledgerCountAfter, hasLength(ledgerCountBefore.length));
      expect(reportCountAfter, hasLength(reportCountBefore.length));
    },
  );

  test(
    'rename, archive, restore, and target history keep the same identity',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      final original = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Scripture Study');
      const weeklyTarget = IndicatorAmount(
        scaledValue: 7,
        scale: 0,
        unit: 'count',
      );

      final renamed = await repository.saveGoal(
        profileId: profileId,
        goalId: original.id,
        title: 'Scripture Study Updated',
        targets: const GoalTargets(weekly: weeklyTarget),
        operationId: 'rename-scripture-study',
      );
      final retriedRename = await repository.saveGoal(
        profileId: profileId,
        goalId: original.id,
        title: 'Scripture Study Updated',
        targets: const GoalTargets(weekly: weeklyTarget),
        operationId: 'rename-scripture-study',
      );
      expect(renamed.id, original.id);
      expect(retriedRename.id, original.id);
      expect(renamed.activeSlotIndex, original.activeSlotIndex);
      expect(renamed.title, 'Scripture Study Updated');

      await repository.archiveGoal(
        profileId: profileId,
        goalId: original.id,
        operationId: 'archive-scripture-study',
      );
      await repository.archiveGoal(
        profileId: profileId,
        goalId: original.id,
        operationId: 'archive-scripture-study',
      );
      final archived = await repository.readGoal(
        profileId: profileId,
        goalId: original.id,
      );
      expect(archived?.status, GoalStatus.archived);
      expect(archived?.activeSlotIndex, equals(null));

      final replacement = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Replacement Weekly Goal',
        targets: const GoalTargets(weekly: weeklyTarget),
        operationId: 'create-replacement-goal',
      );
      await expectLater(
        repository.restoreGoal(
          profileId: profileId,
          goalId: original.id,
          operationId: 'restore-while-full',
        ),
        throwsA(isA<GoalCapacityException>()),
      );

      await repository.archiveGoal(
        profileId: profileId,
        goalId: replacement.id,
        operationId: 'archive-replacement-goal',
      );
      final restored = await repository.restoreGoal(
        profileId: profileId,
        goalId: original.id,
        operationId: 'restore-scripture-study',
      );
      final retriedRestore = await repository.restoreGoal(
        profileId: profileId,
        goalId: original.id,
        operationId: 'restore-scripture-study',
      );
      expect(restored.id, original.id);
      expect(retriedRestore.id, original.id);
      expect(restored.title, 'Scripture Study Updated');
      expect(restored.activeSlotIndex, original.activeSlotIndex);
      expect(restored.role, GoalRole.weekly);

      final progress = await repository.readProgress(
        profileId: profileId,
        goalId: original.id,
        today: periodStart,
      );
      expect(progress?.weeklyTarget.value?.scaledValue, 7);
      final history = await repository.readActivityHistory(profileId);
      expect(
        history.where(
          (item) =>
              item.activity.goalId == original.id &&
              item.activity.action == GoalActivityAction.renamed,
        ),
        hasLength(1),
      );
      expect(
        history.where(
          (item) =>
              item.activity.goalId == original.id &&
              item.activity.action == GoalActivityAction.archived,
        ),
        hasLength(1),
      );
      expect(
        history.where(
          (item) =>
              item.activity.goalId == original.id &&
              item.activity.action == GoalActivityAction.restored,
        ),
        hasLength(1),
      );
      expect(
        history.where(
          (item) =>
              item.activity.goalId == original.id &&
              item.activity.operationId == 'rename-scripture-study',
        ),
        hasLength(1),
      );
      expect(
        history.where(
          (item) =>
              item.activity.goalId == original.id &&
              item.activity.operationId == 'archive-scripture-study',
        ),
        hasLength(1),
      );
      expect(
        history.where(
          (item) =>
              item.activity.goalId == original.id &&
              item.activity.operationId == 'restore-scripture-study',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'archive removes its WLI card and frees its compatible planner slot',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      final reporting = DriftOutcomeReportingRepository(
        database: database,
        clock: clock,
      );
      final calendar = DriftCalendarEventRepository(
        database: database,
        clock: clock,
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
        reportSource: reporting,
      );
      final indicators = DriftIndicatorRepository(
        database: database,
        clock: clock,
        calendarEvents: calendar,
      );
      final scripture = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Scripture Study');

      await repository.archiveGoal(
        profileId: profileId,
        goalId: scripture.id,
        operationId: 'archive-scripture-for-visibility',
      );
      final home = await indicators.readHome(
        profileId: profileId,
        period: IndicatorPeriod.currentWeek(periodStart),
        today: periodStart,
      );
      expect(
        home.indicators.map((indicator) => indicator.label),
        isNot(contains('Scripture Study')),
      );
      final planning = await repository.readPlanning(
        profileId: profileId,
        periodStart: periodStart,
      );
      expect(
        planning.weekly.map((goal) => goal.goal.title),
        isNot(contains('Scripture Study')),
      );
      expect((await repository.readCapacity(profileId)).availableWeekly, 1);
    },
  );

  test(
    'create retries return one goal, activity, and outbox operation',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      final exercise = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Exercise');
      await repository.archiveGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 'archive-exercise-for-create-retry',
      );
      const target = IndicatorAmount(scaledValue: 3, scale: 0, unit: 'count');
      final created = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Retry-safe Goal',
        targets: const GoalTargets(weekly: target),
        operationId: 'create-retry-safe-goal',
      );
      final retried = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Retry-safe Goal',
        targets: const GoalTargets(weekly: target),
        operationId: 'create-retry-safe-goal',
      );
      expect(retried.id, created.id);
      expect(
        (await repository.readActiveGoals(
          profileId,
        )).where((goal) => goal.title == 'Retry-safe Goal'),
        hasLength(1),
      );
      expect(
        (await repository.readActivityHistory(profileId)).where(
          (item) => item.activity.operationId == 'create-retry-safe-goal',
        ),
        hasLength(1),
      );
      expect(
        await (database.select(database.goalOutboxOperations)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.operationId.equals('create-retry-safe-goal'),
            ))
            .get(),
        hasLength(1),
      );
    },
  );

  test(
    'backup preserves nullable icon readiness and rejects slot conflicts',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      final backup = await repository.exportGoalBackup(profileId);
      final rawGoals = (backup['goals']! as List<Object?>)
          .map((value) => Map<String, Object?>.from(value! as Map))
          .toList(growable: true);
      final scripture = rawGoals.firstWhere(
        (goal) => goal['title'] == 'Scripture Study',
      );
      expect(scripture['iconId'], equals(null));
      scripture['iconId'] = 'future-icon-id';
      await repository.importGoalBackup(
        profileId: profileId,
        backup: <String, Object?>{'goals': rawGoals},
      );
      expect(
        (await repository.readGoal(
          profileId: profileId,
          goalId: scripture['id']! as String,
        ))?.iconId,
        'future-icon-id',
      );

      final conflicting = rawGoals
          .map((goal) => Map<String, Object?>.from(goal))
          .toList(growable: true);
      final weekly = conflicting.firstWhere(
        (goal) => goal['role'] == GoalRole.weekly.storageName,
      );
      weekly['activeSlotIndex'] = 1;
      await expectLater(
        repository.importGoalBackup(
          profileId: profileId,
          backup: <String, Object?>{'goals': conflicting},
        ),
        throwsA(isA<GoalValidationException>()),
      );
      expect(
        (await repository.readGoal(
          profileId: profileId,
          goalId: weekly['id']! as String,
        ))?.activeSlotIndex,
        isNot(1),
      );
    },
  );

  test(
    'nextAvailableSlot resolves the exact first free slot per role',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);

      // With all six canonical slots active there is nothing free.
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.dailyWeekly,
        ),
        equals(null),
      );
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.weekly,
        ),
        equals(null),
      );
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.weeklyMonthly,
        ),
        equals(null),
      );

      final weekly = (await repository.readActiveGoals(
        profileId,
      )).where((goal) => goal.role == GoalRole.weekly).toList();
      expect(weekly, hasLength(4));

      // Archive slot 2 (Scripture Study) -> next free weekly slot is 2.
      await repository.archiveGoal(
        profileId: profileId,
        goalId: weekly.firstWhere((goal) => goal.activeSlotIndex == 2).id,
        operationId: 'slot-free-2',
      );
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.weekly,
        ),
        2,
      );

      // Deleting it keeps slot 2 free for a replacement.
      final slot2 = (await repository.readArchivedGoals(
        profileId: profileId,
      )).singleWhere((goal) => goal.activeSlotIndex == null);
      await repository.deleteGoal(
        profileId: profileId,
        goalId: slot2.id,
        operationId: 'slot-free-2-delete',
      );
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.weekly,
        ),
        2,
      );

      // Archive slot 6 (Temple Visit) -> next free monthly slot is 6.
      final temple = (await repository.readActiveGoals(
        profileId,
      )).singleWhere((goal) => goal.role == GoalRole.weeklyMonthly);
      await repository.archiveGoal(
        profileId: profileId,
        goalId: temple.id,
        operationId: 'slot-free-6',
      );
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.weeklyMonthly,
        ),
        6,
      );

      // Archive slot 1 -> next free daily slot is 1.
      final daily = (await repository.readActiveGoals(
        profileId,
      )).singleWhere((goal) => goal.role == GoalRole.dailyWeekly);
      await repository.archiveGoal(
        profileId: profileId,
        goalId: daily.id,
        operationId: 'slot-free-1',
      );
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.dailyWeekly,
        ),
        1,
      );
    },
  );

  test(
    'createGoal validates the previewed slot and rejects a stale expectation',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      const target = IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count');

      final freeSlot = await repository.nextAvailableSlot(
        profileId: profileId,
        role: GoalRole.weekly,
      );
      expect(freeSlot, equals(null)); // full before any archive

      final exercise = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Exercise');
      await repository.archiveGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 'stale-preview-archive',
      );
      final previewed = await repository.nextAvailableSlot(
        profileId: profileId,
        role: GoalRole.weekly,
      );
      expect(previewed, 3);

      final created = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Previewed Replacement',
        targets: const GoalTargets(weekly: target),
        expectedSlotIndex: previewed,
        operationId: 'stale-preview-create',
      );
      expect(created.activeSlotIndex, previewed);

      // A stale expectation from an older preview must be rejected instead
      // of silently creating the Goal in a different slot.  After archiving
      // the previewed Goal, slot 3 is again the next free weekly slot; an old
      // preview pointing at slot 4 is stale and must throw.
      await repository.archiveGoal(
        profileId: profileId,
        goalId: created.id,
        operationId: 'stale-preview-archive-2',
      );
      await expectLater(
        repository.createGoal(
          profileId: profileId,
          role: GoalRole.weekly,
          title: 'Stale Expectation',
          targets: const GoalTargets(weekly: target),
          expectedSlotIndex: 4,
          operationId: 'stale-preview-create-2',
        ),
        throwsA(isA<GoalValidationException>()),
      );
      // The Goal itself is not created when the slot expectation is stale.
      expect(
        (await repository.readActiveGoals(profileId)).map((goal) => goal.title),
        isNot(contains('Stale Expectation')),
      );
    },
  );

  test(
    'delete permanently hides an active Goal, frees its slot, and preserves history',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      final exercise = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Exercise');

      // Give the Goal some history to protect before deletion.
      await repository.saveGoal(
        profileId: profileId,
        goalId: exercise.id,
        title: 'Exercise Daily',
        targets: const GoalTargets(
          weekly: IndicatorAmount(scaledValue: 5, scale: 0, unit: 'count'),
        ),
        operationId: 'delete-history-rename',
      );
      await repository.archiveGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 'delete-history-archive',
      );
      await repository.restoreGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 'delete-history-restore',
      );

      await repository.deleteGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 'delete-exercise',
      );

      // Hidden from every user-facing surface.
      expect(
        (await repository.readActiveGoals(profileId)).map((goal) => goal.id),
        isNot(contains(exercise.id)),
      );
      expect(
        (await repository.readArchivedGoals(
          profileId: profileId,
        )).map((goal) => goal.id),
        isNot(contains(exercise.id)),
      );
      final deleted = await repository.readGoal(
        profileId: profileId,
        goalId: exercise.id,
      );
      expect(deleted?.status, GoalStatus.deleted);
      expect(deleted?.activeSlotIndex, equals(null));
      expect(deleted?.deletedAtUtc, isNot(equals(null)));

      // The freed slot can host a replacement with the same Event Type.
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.weekly,
        ),
        3,
      );
      const target = IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count');
      final replacement = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Replacement Exercise',
        targets: const GoalTargets(weekly: target),
        operationId: 'delete-replacement',
      );
      expect(replacement.activeSlotIndex, 3);
      // Pre-M6 law: create/save assign the canonical slot Event Type and
      // indicator; retired per-Goal goal: keys are never generated again.
      expect(
        replacement.assignedEventTypeStableKey,
        CanonicalGoalSlot.bySlot(3).eventTypeStableKey,
      );
      expect(replacement.indicatorKey, CanonicalGoalSlot.bySlot(3).indicatorKey);
      expect(replacement.title, 'Replacement Exercise');
      expect(replacement.iconId, equals(null));

      // Deleted Goals cannot be restored.
      await expectLater(
        repository.restoreGoal(
          profileId: profileId,
          goalId: exercise.id,
          operationId: 'delete-restore-attempt',
        ),
        throwsA(isA<GoalValidationException>()),
      );

      // Historical records keep the original identity.
      final history = await repository.readActivityHistory(profileId);
      final exerciseHistory = history
          .where((item) => item.activity.goalId == exercise.id)
          .toList();
      expect(exerciseHistory, isNotEmpty);
      expect(
        exerciseHistory.map((item) => item.activity.action),
        containsAll(<GoalActivityAction>[
          GoalActivityAction.created,
          GoalActivityAction.renamed,
          GoalActivityAction.archived,
          GoalActivityAction.restored,
          GoalActivityAction.deleted,
        ]),
      );
      expect(
        exerciseHistory.where(
          (item) => item.activity.operationId == 'delete-exercise',
        ),
        hasLength(1),
      );

      // The replacement's history is isolated from the deleted Goal's.
      final replacementHistory = history
          .where((item) => item.activity.goalId == replacement.id)
          .toList();
      expect(replacementHistory, isNotEmpty);
      expect(
        replacementHistory
            .map((item) => item.activity.operationId)
            .where((operation) => operation.startsWith('delete-history')),
        isEmpty,
      );

      // Re-running bootstrap must not resurrect the deleted Goal.
      final active = await repository.readActiveGoals(profileId);
      expect(active.map((goal) => goal.id), isNot(contains(exercise.id)));
    },
  );

  test(
    'delete permanently removes an archived Goal and frees its slot',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);
      final scripture = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Scripture Study');
      await repository.archiveGoal(
        profileId: profileId,
        goalId: scripture.id,
        operationId: 'delete-archived-archive',
      );

      await repository.deleteGoal(
        profileId: profileId,
        goalId: scripture.id,
        operationId: 'delete-archived',
      );

      expect(
        (await repository.readArchivedGoals(
          profileId: profileId,
        )).map((goal) => goal.id),
        isNot(contains(scripture.id)),
      );
      expect(
        await repository.nextAvailableSlot(
          profileId: profileId,
          role: GoalRole.weekly,
        ),
        2,
      );
      await expectLater(
        repository.restoreGoal(
          profileId: profileId,
          goalId: scripture.id,
          operationId: 'delete-archived-restore',
        ),
        throwsA(isA<GoalValidationException>()),
      );
    },
  );

  test(
    'a backup taken before deletion cannot resurrect the deleted Goal',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);

      final before = await repository.exportGoalBackup(profileId);
      final exercise = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Exercise');
      await repository.deleteGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 'backup-delete',
      );

      // Importing the older snapshot must not resurrect the deleted Goal.
      await repository.importGoalBackup(profileId: profileId, backup: before);
      final deleted = await repository.readGoal(
        profileId: profileId,
        goalId: exercise.id,
      );
      expect(deleted?.status, GoalStatus.deleted);
      expect(
        (await repository.readActiveGoals(profileId)).map((goal) => goal.id),
        isNot(contains(exercise.id)),
      );
    },
  );

  test('home indicator reads do not emit a write notification loop', () async {
    final (database, repository, profileId) = await arrange();
    addTearDown(database.close);
    final reporting = DriftOutcomeReportingRepository(
      database: database,
      clock: clock,
    );
    final calendar = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
      reportSource: reporting,
    );
    final indicators = DriftIndicatorRepository(
      database: database,
      clock: clock,
      calendarEvents: calendar,
    );
    var eventCount = 0;
    final subscription = indicators.watchChanges(profileId).listen((_) {
      eventCount += 1;
    });
    addTearDown(subscription.cancel);
    await indicators.readHome(
      profileId: profileId,
      period: IndicatorPeriod.currentWeek(periodStart),
      today: periodStart,
    );
    await Future<void>.delayed(Duration.zero);
    expect(eventCount, 0);
  });

  test('A2: bounded readPlanning is semantically equivalent to the canonical '
      'projection with a bounded query budget', () async {
    final counter = _CountingInterceptor();
    final database = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(counter),
    );
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, profile.id, clock: clock);
    final repository = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );

    final active = await repository.readActiveGoals(profile.id);
    final daily = active.singleWhere(
      (goal) => goal.role == GoalRole.dailyWeekly,
    );
    final weeklyA = active
        .where((goal) => goal.role == GoalRole.weekly)
        .elementAt(0);
    final weeklyB = active
        .where((goal) => goal.role == GoalRole.weekly)
        .elementAt(1);
    final weeklyC = active
        .where((goal) => goal.role == GoalRole.weekly)
        .elementAt(2);
    final weeklyD = active
        .where((goal) => goal.role == GoalRole.weekly)
        .elementAt(3);
    final monthly = active.singleWhere(
      (goal) => goal.role == GoalRole.weeklyMonthly,
    );
    final key = daily.indicatorKey!;

    const two = IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count');
    const three = IndicatorAmount(scaledValue: 3, scale: 0, unit: 'count');
    // Set + unset target states, daily/weekly/monthly targets, and a
    // latest-revision chain (2 then 3 on the same week wins as 3).
    await repository.saveGoal(
      profileId: profile.id,
      goalId: daily.id,
      title: daily.title,
      targets: const GoalTargets(daily: two, weekly: two),
      today: periodStart,
      startDay: DateTime.sunday,
      operationId: 'a2-daily-targets',
    );
    await repository.saveGoal(
      profileId: profile.id,
      goalId: weeklyA.id,
      title: weeklyA.title,
      targets: const GoalTargets(weekly: two),
      today: periodStart,
      startDay: DateTime.sunday,
      operationId: 'a2-weekly-a-1',
    );
    await repository.saveGoal(
      profileId: profile.id,
      goalId: weeklyA.id,
      title: weeklyA.title,
      targets: const GoalTargets(weekly: three),
      today: periodStart,
      startDay: DateTime.sunday,
      operationId: 'a2-weekly-a-2',
    );
    // weeklyB and weeklyD keep UNSET targets (no revisions at all).
    await repository.saveGoal(
      profileId: profile.id,
      goalId: weeklyC.id,
      title: weeklyC.title,
      targets: const GoalTargets(weekly: two),
      today: periodStart,
      startDay: DateTime.sunday,
      operationId: 'a2-weekly-c',
    );
    await repository.saveGoal(
      profileId: profile.id,
      goalId: monthly.id,
      title: monthly.title,
      targets: const GoalTargets(weekly: two, monthly: three),
      today: periodStart,
      startDay: DateTime.sunday,
      operationId: 'a2-monthly-targets',
    );

    // Archived and deleted Goals must stay out of the projection.
    await repository.archiveGoal(
      profileId: profile.id,
      goalId: weeklyB.id,
      operationId: 'a2-archive-weekly-b',
    );
    await repository.deleteGoal(
      profileId: profile.id,
      goalId: weeklyD.id,
      operationId: 'a2-delete-weekly-d',
    );

    final now = clock.value;
    Future<void> insertLedger({
      required String reportId,
      required String reportType,
      required String? eventId,
      required String? occurrenceId,
      required String entryId,
      required int value,
      required String activityDate,
    }) async {
      await database
          .into(database.outcomeReports)
          .insert(
            OutcomeReportsCompanion.insert(
              id: reportId,
              profileId: profile.id,
              sourceType: reportType,
              sourceId: reportId,
              sourceLabel: 'A2 fixture $reportId',
              sourceSlotKey: 'a2:$reportId',
              status: 'submitted',
              outcome: const Value<String?>('completed'),
              activityDate: activityDate,
              eventId: Value<String?>(eventId),
              occurrenceId: Value<String?>(occurrenceId),
              createdAtUtc: now,
              updatedAtUtc: now,
              submittedAtUtc: Value<DateTime?>(now),
            ),
          );
      await database
          .into(database.activityLedgerEntries)
          .insert(
            ActivityLedgerEntriesCompanion.insert(
              id: entryId,
              profileId: profile.id,
              sourceReportId: reportId,
              entryType: 'contribution',
              indicatorKey: key,
              valueScaled: value,
              valueScale: 0,
              unit: 'count',
              activityDate: activityDate,
              ruleKey: '$reportType:$key',
              idempotencyKey: entryId,
              recordedAtUtc: now,
            ),
          );
    }

    Future<void> insertEvent({
      required String eventId,
      required String status,
      String? occurrenceId,
    }) async {
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: eventId,
              profileId: profile.id,
              title: 'A2 event $eventId',
              timing: 'timed',
              startDate: '2026-08-04',
              startMinute: const Value<int?>(540),
              endMinute: const Value<int?>(600),
              timeZoneId: const Value<String?>('Asia/Manila'),
              requiresReport: const Value<bool>(true),
              contributionRuleKey: Value<String?>(
                'life-indicator:$key:1:0:count',
              ),
              goalId: Value<String?>(daily.id),
              recurrenceFrequency: const Value<String>('weekly'),
              status: Value<String>(status),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
    }

    // 1) Event-backed contribution that COUNTS (weekly + daily on Aug 5).
    await insertEvent(eventId: 'a2-event-active', status: 'scheduled');
    await insertLedger(
      reportId: 'a2-report-active',
      reportType: OutcomeSourceType.event.name,
      eventId: 'a2-event-active',
      occurrenceId: 'occ-active',
      entryId: 'a2-ledger-active',
      value: 1,
      activityDate: '2026-08-05',
    );

    // 2) Cancelled Event: the report/ledger history stays but the Event no
    //    longer qualifies for current Actual.
    await insertEvent(eventId: 'a2-event-cancelled', status: 'scheduled');
    await insertLedger(
      reportId: 'a2-report-cancelled',
      reportType: OutcomeSourceType.event.name,
      eventId: 'a2-event-cancelled',
      occurrenceId: 'occ-cancelled',
      entryId: 'a2-ledger-cancelled',
      value: 1,
      activityDate: '2026-08-05',
    );
    await (database.update(database.calendarEvents)
          ..where((table) => table.id.equals('a2-event-cancelled')))
        .write(CalendarEventsCompanion(status: Value<String>('cancelled')));

    // 3) Recurring Event with one cancelled/exception occurrence: that
    //    occurrence's ledger row must not count.
    await insertEvent(
      eventId: 'a2-event-recurring',
      status: 'scheduled',
      occurrenceId: 'occ-recurring',
    );
    await insertLedger(
      reportId: 'a2-report-recurring',
      reportType: OutcomeSourceType.event.name,
      eventId: 'a2-event-recurring',
      occurrenceId: 'occ-recurring',
      entryId: 'a2-ledger-recurring',
      value: 1,
      activityDate: '2026-08-05',
    );
    await database
        .into(database.calendarEventExceptions)
        .insert(
          CalendarEventExceptionsCompanion.insert(
            id: 'a2-exception-recurring',
            profileId: profile.id,
            eventId: 'a2-event-recurring',
            occurrenceId: 'occ-recurring',
            originalDate: '2026-08-05',
            effectiveDate: '2026-08-05',
            title: 'A2 cancelled occurrence',
            timing: 'timed',
            requiresReport: const Value<bool>(true),
            contributionRuleKey: Value<String?>(
              'life-indicator:$key:1:0:count',
            ),
            status: CalendarEventStatus.cancelled.name,
            createdAtUtc: now,
          ),
        );

    // 4) Another recurring Event occurrence WITH no exception: counts.
    await insertLedger(
      reportId: 'a2-report-recurring-ok',
      reportType: OutcomeSourceType.event.name,
      eventId: 'a2-event-recurring',
      occurrenceId: 'occ-recurring-ok',
      entryId: 'a2-ledger-recurring-ok',
      value: 1,
      activityDate: '2026-08-04',
    );

    // 5) Manual contribution: no event check, always counts.
    await insertLedger(
      reportId: 'a2-report-manual',
      reportType: OutcomeSourceType.manual.name,
      eventId: null,
      occurrenceId: null,
      entryId: 'a2-ledger-manual',
      value: 1,
      activityDate: '2026-08-05',
    );

    // 6) Task contributions: active counts, inactive does not.  Tasks
    //    reference PlannerTasks, so the linked rows must exist first.
    await database
        .into(database.plannerTasks)
        .insert(
          PlannerTasksCompanion.insert(
            id: 'a2-task-row',
            profileId: profile.id,
            title: 'A2 linked task',
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
    await database
        .into(database.plannerTasks)
        .insert(
          PlannerTasksCompanion.insert(
            id: 'a2-task-row-2',
            profileId: profile.id,
            title: 'A2 linked task 2',
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
    await database
        .into(database.taskGoalContributions)
        .insert(
          TaskGoalContributionsCompanion.insert(
            id: 'a2-task-active',
            profileId: profile.id,
            taskId: 'a2-task-row',
            indicatorKey: key,
            valueScaled: const Value<int>(1),
            activityDate: '2026-08-05',
            state: const Value<String>('active'),
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
    await database
        .into(database.taskGoalContributions)
        .insert(
          TaskGoalContributionsCompanion.insert(
            id: 'a2-task-inactive',
            profileId: profile.id,
            taskId: 'a2-task-row-2',
            indicatorKey: key,
            valueScaled: const Value<int>(9),
            activityDate: '2026-08-05',
            state: const Value<String>('completed'),
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );

    // Non-Monday week boundary: Sunday start.
    const today = PlannerDate(year: 2026, month: 8, day: 5);
    counter.reset();
    final planning = await repository.readPlanning(
      profileId: profile.id,
      periodStart: periodStart,
      today: today,
      startDay: DateTime.sunday,
    );
    final currentSelects = counter.selectCount;
    final oracle = _serializeSnapshot(planning);

    // Semantic facts the fixture pins down.
    expect(planning.periodStart.iso8601, '2026-08-02');
    expect(planning.periodEnd.iso8601, '2026-08-08');
    expect(planning.daily?.goal.id, daily.id);
    expect(planning.weekly, hasLength(2));
    expect(planning.monthly?.goal.id, monthly.id);
    // Daily actual: active event (1) + recurring-ok (1, Aug 4 -> weekly
    // only) + manual (1) + task active (1) = 3 on Aug 5; cancelled event
    // and the exception occurrence are excluded.
    expect(planning.daily!.dailyActual.scaledValue, 3);
    expect(planning.daily!.weeklyActual.scaledValue, 4);
    // Latest revision chain: weeklyA shows 3, not 2.
    final weeklyAProgress = planning.weekly.singleWhere(
      (progress) => progress.goal.id == weeklyA.id,
    );
    expect(weeklyAProgress.weeklyTarget.value?.scaledValue, 3);
    final weeklyCProgress = planning.weekly.singleWhere(
      (progress) => progress.goal.id == weeklyC.id,
    );
    expect(weeklyCProgress.weeklyTarget.value?.scaledValue, 2);
    expect(planning.monthly!.monthlyTarget.value?.scaledValue, 3);

    // The projection must be deterministic across repeated reads.
    counter.reset();
    final second = await repository.readPlanning(
      profileId: profile.id,
      periodStart: periodStart,
      today: today,
      startDay: DateTime.sunday,
    );
    expect(_serializeSnapshot(second), oracle);

    // Bounded query budget: the projection must be a small fixed set of
    // reads, not a per-Goal/per-field serial fan-out.
    expect(
      currentSelects,
      lessThanOrEqualTo(30),
      reason:
          'readPlanning must use a bounded batch projection; the '
          'current serial fan-out exceeds the budget.',
    );
  });

  group('MP-16 legacy Budget/Ministering compatibility reconciliation', () {
    test(
      'exact device-shape crossed pair reconciles to the historical '
      'Budget/Ministering identity and converges the derived definition label',
      () async {
        final (database, repository, profileId) = await _crossedFixture();
        addTearDown(database.close);
        final g4Id = '$profileId:goal:4';
        final g5Id = '$profileId:goal:5';

        await repository.ensureCanonicalGoals(profileId);

        final rows =
            await (database.select(database.goals)..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      (table.id.equals(g4Id) | table.id.equals(g5Id)),
                ))
                .get();
        final g4 = rows.singleWhere((row) => row.id == g4Id);
        final g5 = rows.singleWhere((row) => row.id == g5Id);
        // Desired MP-16 identity under the current canonical slot order.
        expect(g5.activeSlotIndex, 4);
        expect(g5.indicatorKey, SystemEventTypeKeys.budgetReview);
        expect(g5.assignedEventTypeStableKey, SystemEventTypeKeys.budgetReview);
        expect(g4.activeSlotIndex, 5);
        expect(g4.indicatorKey, 'meaningful_connections');
        expect(
          g4.assignedEventTypeStableKey,
          SystemEventTypeKeys.meaningfulConnection,
        );
        // Display customization is preserved.
        expect(g4.title, 'Ministering Visit');
        expect(g4.iconId, 'social_two_people');
        expect(g5.title, 'Budget Review');
        expect(g5.iconId, 'finance_wallet');
        // The derived position-3 definition label converges to the preserved
        // G4 title through the existing synchronization path.
        final definition =
            await (database.select(database.lifeIndicatorDefinitions)..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.indicatorKey.equals('meaningful_connections'),
                ))
                .getSingle();
        expect(definition.label, 'Ministering Visit');
      },
    );

    test('custom current titles/icons do not block semantic repair and are '
        'preserved byte-for-byte', () async {
      final (database, repository, profileId) = await _crossedFixture(
        g4Title: 'My Custom Ministering',
        g5Title: 'My Custom Budget',
        g4Icon: 'custom_people_icon',
        g5Icon: 'custom_wallet_icon',
      );
      addTearDown(database.close);
      final g4Id = '$profileId:goal:4';
      final g5Id = '$profileId:goal:5';

      await repository.ensureCanonicalGoals(profileId);

      final rows =
          await (database.select(database.goals)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    (table.id.equals(g4Id) | table.id.equals(g5Id)),
              ))
              .get();
      final g4 = rows.singleWhere((row) => row.id == g4Id);
      final g5 = rows.singleWhere((row) => row.id == g5Id);
      expect(g5.activeSlotIndex, 4);
      expect(g5.indicatorKey, SystemEventTypeKeys.budgetReview);
      expect(g4.activeSlotIndex, 5);
      expect(g4.indicatorKey, 'meaningful_connections');
      expect(g4.title, 'My Custom Ministering');
      expect(g4.iconId, 'custom_people_icon');
      expect(g5.title, 'My Custom Budget');
      expect(g5.iconId, 'custom_wallet_icon');
      // The derived label converges to the preserved custom G4 title.
      final definition =
          await (database.select(database.lifeIndicatorDefinitions)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.equals('meaningful_connections'),
              ))
              .getSingle();
      expect(definition.label, 'My Custom Ministering');
    });

    test('preserves Event Types, mappings, Events, reports, ledger, history, '
        'Planner, and unrelated rows exactly while repairing only the allowed '
        'Goal fields', () async {
      final (database, repository, profileId) = await _crossedFixture();
      addTearDown(database.close);
      final now = clock.value;
      final active = await repository.readActiveGoals(profileId);
      final g4 = active.singleWhere((goal) => goal.id == '$profileId:goal:4');
      final g5 = active.singleWhere((goal) => goal.id == '$profileId:goal:5');
      final types = await database.select(database.activityTypes).get();
      final budgetType = types.singleWhere(
        (row) => row.stableKey == SystemEventTypeKeys.budgetReview,
      );
      final ministeringType = types.singleWhere(
        (row) => row.stableKey == SystemEventTypeKeys.meaningfulConnection,
      );
      final jobType = types.singleWhere(
        (row) => row.stableKey == SystemEventTypeKeys.jobApplication,
      );

      // Calendar Events + exception with historical snapshot fields.
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'mp16-ev-budget',
              profileId: profileId,
              title: 'Budget check',
              timing: 'timed',
              startDate: '2026-08-10',
              startMinute: const Value<int?>(540),
              endMinute: const Value<int?>(600),
              timeZoneId: const Value<String?>('Asia/Manila'),
              requiresReport: const Value<bool>(true),
              activityTypeId: Value<String?>(budgetType.id),
              activityTypeMappingVersion: const Value<int?>(1),
              activityTypeStableKeySnapshot: const Value<String?>(
                'budget_review',
              ),
              activityTypeLabelSnapshot: const Value<String?>('Budget Review'),
              activityTypeColorValueSnapshot: const Value<int?>(4290749316),
              contributionRuleKey: const Value<String?>(
                'life-indicator:budget_review:1:0:count',
              ),
              goalId: Value<String?>(g4.id),
              recurrenceFrequency: const Value<String>('weekly'),
              status: const Value<String>('scheduled'),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'mp16-ev-ministering',
              profileId: profileId,
              title: 'Ministering visit',
              timing: 'timed',
              startDate: '2026-08-12',
              startMinute: const Value<int?>(600),
              endMinute: const Value<int?>(660),
              timeZoneId: const Value<String?>('Asia/Manila'),
              requiresReport: const Value<bool>(true),
              activityTypeId: Value<String?>(ministeringType.id),
              activityTypeMappingVersion: const Value<int?>(1),
              activityTypeStableKeySnapshot: const Value<String?>(
                'meaningful_connection',
              ),
              activityTypeLabelSnapshot: const Value<String?>(
                'Ministering Visit',
              ),
              activityTypeColorValueSnapshot: const Value<int?>(4289767793),
              contributionRuleKey: const Value<String?>(
                'life-indicator:meaningful_connections:1:0:count',
              ),
              goalId: Value<String?>(g5.id),
              recurrenceFrequency: const Value<String>('weekly'),
              status: const Value<String>('scheduled'),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
      await database
          .into(database.calendarEventExceptions)
          .insert(
            CalendarEventExceptionsCompanion.insert(
              id: 'mp16-exc-ministering',
              profileId: profileId,
              eventId: 'mp16-ev-ministering',
              occurrenceId: 'occ-1',
              originalDate: '2026-08-12',
              effectiveDate: '2026-08-13',
              title: 'Cancelled ministering',
              timing: 'timed',
              requiresReport: const Value<bool>(true),
              activityTypeId: Value<String?>(ministeringType.id),
              activityTypeMappingVersion: const Value<int?>(1),
              activityTypeStableKeySnapshot: const Value<String?>(
                'meaningful_connection',
              ),
              activityTypeLabelSnapshot: const Value<String?>(
                'Ministering Visit',
              ),
              contributionRuleKey: const Value<String?>(
                'life-indicator:meaningful_connections:1:0:count',
              ),
              status: 'cancelled',
              createdAtUtc: now,
            ),
          );

      // Outcome report + contribution draft + ledger facts.
      await database
          .into(database.outcomeReports)
          .insert(
            OutcomeReportsCompanion.insert(
              id: 'mp16-report',
              profileId: profileId,
              sourceType: OutcomeSourceType.event.name,
              sourceId: 'mp16-ev-budget',
              sourceLabel: 'Budget check',
              sourceSlotKey: 'mp16:budget',
              status: 'submitted',
              outcome: const Value<String?>('completed'),
              activityDate: '2026-08-10',
              eventId: const Value<String?>('mp16-ev-budget'),
              occurrenceId: const Value<String?>(null),
              createdAtUtc: now,
              updatedAtUtc: now,
              submittedAtUtc: Value<DateTime?>(now),
            ),
          );
      await database
          .into(database.outcomeReportContributionDrafts)
          .insert(
            OutcomeReportContributionDraftsCompanion.insert(
              reportId: 'mp16-report',
              ruleKey: 'life-indicator:budget_review:1:0:count',
              indicatorKey: 'budget_review',
              valueScaled: 1,
              valueScale: 0,
              unit: 'count',
            ),
          );
      await database
          .into(database.activityLedgerEntries)
          .insert(
            ActivityLedgerEntriesCompanion.insert(
              id: 'mp16-ledger',
              profileId: profileId,
              sourceReportId: 'mp16-report',
              entryType: 'contribution',
              indicatorKey: 'budget_review',
              valueScaled: 1,
              valueScale: 0,
              unit: 'count',
              activityDate: '2026-08-10',
              ruleKey: 'event:budget_review',
              idempotencyKey: 'mp16-ledger',
              recordedAtUtc: now,
            ),
          );

      // Historical target revisions keyed by the legacy indicators.
      await database
          .into(database.indicatorGoalRevisions)
          .insert(
            IndicatorGoalRevisionsCompanion.insert(
              id: 'mp16-rev-g4',
              profileId: profileId,
              goalId: Value<String?>(g4.id),
              indicatorKey: 'meaningful_connections',
              periodType: 'weekly',
              periodStartDate: '2026-08-10',
              periodEndDate: '2026-08-16',
              state: 'explicit',
              valueScaled: const Value<int?>(2),
              valueScale: 0,
              unit: 'count',
              supersedesRevisionId: const Value<String?>(null),
              operationId: 'mp16-op-g4',
              createdAtUtc: now,
            ),
          );
      await database
          .into(database.weeklyIndicatorTargetRevisions)
          .insert(
            WeeklyIndicatorTargetRevisionsCompanion.insert(
              id: 'mp16-wrev-g5',
              profileId: profileId,
              indicatorKey: 'budget_review',
              goalId: Value<String?>(g5.id),
              periodStartDate: '2026-08-10',
              state: 'explicit',
              valueScaled: const Value<int?>(2),
              valueScale: 0,
              unit: 'count',
              supersedesRevisionId: const Value<String?>(null),
              operationId: 'mp16-wop-g5',
              createdAtUtc: now,
            ),
          );

      // Planner Task + status change + contribution for the Job Goal.
      await database
          .into(database.plannerTasks)
          .insert(
            PlannerTasksCompanion.insert(
              id: 'mp16-task',
              profileId: profileId,
              title: 'Apply for a role',
              dueDate: const Value<String?>('2026-08-12'),
              dueMinute: const Value<int?>(600),
              status: const Value<String>('completed'),
              requiresReport: const Value<bool>(false),
              linkedActivityTypeId: Value<String?>(jobType.id),
              linkedActivityTypeStableKey: Value<String?>(jobType.stableKey),
              linkedActivityTypeLabelSnapshot: Value<String?>(jobType.label),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
      await database
          .into(database.taskStatusChanges)
          .insert(
            TaskStatusChangesCompanion.insert(
              id: 'mp16-task-status',
              profileId: profileId,
              taskId: 'mp16-task',
              operationId: 'mp16-task-op',
              fromStatus: 'incomplete',
              toStatus: 'completed',
              activityTypeId: Value<String?>(jobType.id),
              activityTypeStableKeySnapshot: Value<String?>(jobType.stableKey),
              activityTypeLabelSnapshot: Value<String?>(jobType.label),
              changedAtUtc: now,
            ),
          );
      await database
          .into(database.taskGoalContributions)
          .insert(
            TaskGoalContributionsCompanion.insert(
              id: 'mp16-task-contr',
              profileId: profileId,
              taskId: 'mp16-task',
              activityTypeId: Value<String?>(jobType.id),
              activityTypeStableKeySnapshot: Value<String?>(jobType.stableKey),
              activityTypeLabelSnapshot: Value<String?>(jobType.label),
              indicatorKey: 'job_applications',
              valueScaled: const Value<int>(1),
              activityDate: '2026-08-12',
              state: const Value<String>('completed'),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );

      final before = await _preservationSnapshot(database, profileId);
      await repository.ensureCanonicalGoals(profileId);
      final after = await _preservationSnapshot(database, profileId);

      // Only the allowed current Goal fields + derived definition label may
      // change; every other row is byte-for-byte identical.
      expect(after, before);
      final definition =
          await (database.select(database.lifeIndicatorDefinitions)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.equals('meaningful_connections'),
              ))
              .getSingle();
      expect(definition.label, 'Ministering Visit');
    });

    test(
      'fail-closed negative matrix: every one-sided/ambiguous/mismatched case '
      'produces zero compatibility writes',
      () async {
        final cases = <(String, Future<void> Function(AppDatabase, String))>[
          (
            'only G4 present',
            (database, profileId) => _setGoalStatus(
              database,
              profileId,
              '$profileId:goal:5',
              'deleted',
            ),
          ),
          (
            'only G5 present',
            (database, profileId) => _setGoalStatus(
              database,
              profileId,
              '$profileId:goal:4',
              'deleted',
            ),
          ),
          (
            'G4 archived',
            (database, profileId) => _setGoalStatus(
              database,
              profileId,
              '$profileId:goal:4',
              'archived',
            ),
          ),
          (
            'G5 archived',
            (database, profileId) => _setGoalStatus(
              database,
              profileId,
              '$profileId:goal:5',
              'archived',
            ),
          ),
          (
            'G4 deleted',
            (database, profileId) => _setGoalStatus(
              database,
              profileId,
              '$profileId:goal:4',
              'deleted',
            ),
          ),
          (
            'G5 deleted',
            (database, profileId) => _setGoalStatus(
              database,
              profileId,
              '$profileId:goal:5',
              'deleted',
            ),
          ),
          (
            'wrong role',
            (database, profileId) => _updateGoal(
              database,
              profileId,
              '$profileId:goal:4',
              GoalsCompanion(
                role: Value<String>(GoalRole.dailyWeekly.storageName),
              ),
            ),
          ),
          (
            'wrong G4 slot',
            (database, profileId) => _updateGoal(
              database,
              profileId,
              '$profileId:goal:4',
              const GoalsCompanion(activeSlotIndex: Value<int?>(6)),
            ),
          ),
          (
            'wrong G5 slot',
            (database, profileId) => _updateGoal(
              database,
              profileId,
              '$profileId:goal:5',
              const GoalsCompanion(activeSlotIndex: Value<int?>(3)),
            ),
          ),
          (
            'wrong G4 indicator',
            (database, profileId) => _updateGoal(
              database,
              profileId,
              '$profileId:goal:4',
              const GoalsCompanion(
                indicatorKey: Value<String?>('temple_visit'),
              ),
            ),
          ),
          (
            'wrong G5 indicator',
            (database, profileId) => _updateGoal(
              database,
              profileId,
              '$profileId:goal:5',
              const GoalsCompanion(indicatorKey: Value<String?>('exercise')),
            ),
          ),
          (
            'wrong G4 assignment',
            (database, profileId) => _updateGoal(
              database,
              profileId,
              '$profileId:goal:4',
              const GoalsCompanion(
                assignedEventTypeStableKey: Value<String?>('temple_visit'),
              ),
            ),
          ),
          (
            'wrong G5 assignment',
            (database, profileId) => _updateGoal(
              database,
              profileId,
              '$profileId:goal:5',
              const GoalsCompanion(
                assignedEventTypeStableKey: Value<String?>('job_application'),
              ),
            ),
          ),
          (
            'missing G4 created activity',
            (database, profileId) => _updateActivity(
              database,
              '$profileId:goal:4:created',
              const GoalActivitiesCompanion(action: Value<String>('updated')),
            ),
          ),
          (
            'missing G5 created activity',
            (database, profileId) => _updateActivity(
              database,
              '$profileId:goal:5:created',
              const GoalActivitiesCompanion(action: Value<String>('updated')),
            ),
          ),
          (
            'mismatched G4 activity title',
            (database, profileId) => _updateActivity(
              database,
              '$profileId:goal:4:created',
              const GoalActivitiesCompanion(
                newValue: Value<String?>('Something Else'),
              ),
            ),
          ),
          (
            'mismatched G5 activity title',
            (database, profileId) => _updateActivity(
              database,
              '$profileId:goal:5:created',
              const GoalActivitiesCompanion(
                newValue: Value<String?>('Something Else'),
              ),
            ),
          ),
          (
            'missing G4 created outbox',
            (database, profileId) => _updateOutboxAction(
              database,
              '$profileId:goal:4:created',
              'updated',
            ),
          ),
          (
            'missing G5 created outbox',
            (database, profileId) => _updateOutboxAction(
              database,
              '$profileId:goal:5:created',
              'updated',
            ),
          ),
          (
            'mismatched G4 outbox title',
            (database, profileId) => _updateOutboxPayload(
              database,
              '$profileId:goal:4:created',
              title: 'Wrong Title',
            ),
          ),
          (
            'mismatched G5 outbox slot',
            (database, profileId) => _updateOutboxPayload(
              database,
              '$profileId:goal:5:created',
              slot: 3,
            ),
          ),
          (
            'wrong Budget Event Type stable key',
            (database, profileId) => _updateEventTypeStableKey(
              database,
              profileId,
              SystemEventTypeIds.budgetReview,
              'budget_review_custom',
            ),
          ),
          (
            'wrong Ministering Event Type stable key',
            (database, profileId) => _updateEventTypeStableKey(
              database,
              profileId,
              SystemEventTypeIds.meaningfulConnection,
              'meaningful_connection_custom',
            ),
          ),
          (
            'wrong Budget mapping version',
            (database, profileId) => _updateMapping(
              database,
              profileId,
              SystemEventTypeIds.budgetReview,
              mappingVersion: 2,
            ),
          ),
          (
            'wrong Ministering mapping indicator',
            (database, profileId) => _updateMapping(
              database,
              profileId,
              SystemEventTypeIds.meaningfulConnection,
              indicatorKey: 'temple_visit',
            ),
          ),
          ('fresh canonical v24 profile', (database, profileId) async {}),
        ];

        for (final (name, mutate) in cases) {
          final (database, repository, profileId) = await _crossedFixture(
            rewrite: false,
          );
          addTearDown(database.close);
          if (name != 'fresh canonical v24 profile') {
            await _rewriteToLegacyCrossedPair(database, profileId);
          }
          await mutate(database, profileId);
          final evidenceBefore = await _evidenceSnapshot(database, profileId);

          await repository.ensureCanonicalGoals(profileId);

          final rows =
              await (database.select(database.goals)..where(
                    (table) =>
                        table.profileId.equals(profileId) &
                        (table.id.equals('$profileId:goal:4') |
                            table.id.equals('$profileId:goal:5')),
                  ))
                  .get();
          final g4 = rows.singleWhere((row) => row.id == '$profileId:goal:4');
          final g5 = rows.singleWhere((row) => row.id == '$profileId:goal:5');
          // No compatibility repair: the pair must never reach the repaired
          // MP-16 state (the helper's only effect is the key/slot swap).
          final repaired =
              g4.activeSlotIndex == 5 &&
              g5.activeSlotIndex == 4 &&
              g4.indicatorKey == 'meaningful_connections' &&
              g4.assignedEventTypeStableKey ==
                  SystemEventTypeKeys.meaningfulConnection &&
              g5.indicatorKey == SystemEventTypeKeys.budgetReview &&
              g5.assignedEventTypeStableKey == SystemEventTypeKeys.budgetReview;
          expect(
            repaired,
            isFalse,
            reason: '[$name] compatibility repair must not fire',
          );
          // The immutable evidence rows are untouched.
          expect(
            await _evidenceSnapshot(database, profileId),
            evidenceBefore,
            reason: '[$name] evidence rows must be byte-identical',
          );
        }
      },
    );

    test(
      'repair is idempotent: the second bootstrap run issues zero writes and '
      'no timestamp churn',
      () async {
        final (database, repository, profileId) = await _crossedFixture();
        addTearDown(database.close);

        await repository.ensureCanonicalGoals(profileId);
        final afterFirst = await _fullGoalSnapshot(database, profileId);
        final definitionFirst =
            await (database.select(database.lifeIndicatorDefinitions)..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.indicatorKey.equals('meaningful_connections'),
                ))
                .getSingle();

        await repository.ensureCanonicalGoals(profileId);

        expect(
          await _fullGoalSnapshot(database, profileId),
          afterFirst,
          reason: 'second run must not rewrite Goals or churn updated_at',
        );
        final definitionSecond =
            await (database.select(database.lifeIndicatorDefinitions)..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.indicatorKey.equals('meaningful_connections'),
                ))
                .getSingle();
        expect(definitionSecond.label, definitionFirst.label);
      },
    );

    test('an injected failure between clearing and assigning slots rolls the '
        'whole transaction back to the original crossed pair', () async {
      final (database, repository, profileId) = await _crossedFixture();
      addTearDown(database.close);
      final g5Id = '$profileId:goal:5';
      // Fire only on the G5 reassignment (after the NULL clears) so the
      // transaction aborts mid-swap.
      await database.customStatement(
        'CREATE TRIGGER mp16_rollback_inject '
        'BEFORE UPDATE ON goals '
        'WHEN NEW.id = \'$g5Id\' AND NEW.active_slot_index = 4 '
        'AND NEW.indicator_key = \'budget_review\' '
        'BEGIN SELECT RAISE(ABORT, \'mp16-injected\'); END',
      );
      await expectLater(
        repository.ensureCanonicalGoals(profileId),
        throwsA(isA<Exception>()),
      );
      await database.customStatement('DROP TRIGGER mp16_rollback_inject');

      Future<(int?, String?, String?, int?, String?, String?)> pair() async {
        final rows =
            await (database.select(database.goals)..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      (table.id.equals('$profileId:goal:4') |
                          table.id.equals('$profileId:goal:5')),
                ))
                .get();
        final g4 = rows.singleWhere((row) => row.id == '$profileId:goal:4');
        final g5 = rows.singleWhere((row) => row.id == '$profileId:goal:5');
        return (
          g4.activeSlotIndex,
          g4.indicatorKey,
          g4.assignedEventTypeStableKey,
          g5.activeSlotIndex,
          g5.indicatorKey,
          g5.assignedEventTypeStableKey,
        );
      }

      // The failed transaction left the original crossed pair intact.
      final rolledBack = await pair();
      expect(rolledBack.$1, 4);
      expect(rolledBack.$2, SystemEventTypeKeys.budgetReview);
      expect(rolledBack.$3, SystemEventTypeKeys.budgetReview);
      expect(rolledBack.$4, 5);
      expect(rolledBack.$5, 'meaningful_connections');
      expect(rolledBack.$6, SystemEventTypeKeys.meaningfulConnection);

      // Without the injected failure the same run repairs the pair.
      await repository.ensureCanonicalGoals(profileId);
      final repaired = await pair();
      expect(repaired.$1, 5);
      expect(repaired.$2, 'meaningful_connections');
      expect(repaired.$3, SystemEventTypeKeys.meaningfulConnection);
      expect(repaired.$4, 4);
      expect(repaired.$5, SystemEventTypeKeys.budgetReview);
      expect(repaired.$6, SystemEventTypeKeys.budgetReview);
    });
  });

  test('Delta 4 A1: cancelling a contributing Event immediately removes only '
      'that Event from Home Actual while preserving report history, manual '
      'contributions, and retry idempotency', () async {
    final (database, repository, profileId) = await arrange();
    addTearDown(database.close);
    final goal = (await repository.readActiveGoals(
      profileId,
    )).singleWhere((candidate) => candidate.role == GoalRole.dailyWeekly);
    final indicatorKey = goal.indicatorKey!;
    final reporting = DriftOutcomeReportingRepository(
      database: database,
      clock: clock,
    );
    final events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
      reportSource: reporting,
    );
    final changeGenerations = <int>[];
    final changeSubscription = repository
        .watchChanges(profileId)
        .listen(changeGenerations.add);
    addTearDown(changeSubscription.cancel);
    const eventId = '10101010-1010-4010-8010-101010101010';
    const eventReportId = '20202020-2020-4020-8020-202020202020';
    const eventReportOperation = '30303030-3030-4030-8030-303030303030';
    const manualReportId = '40404040-4040-4040-8040-404040404040';
    const manualSourceId = '50505050-5050-4050-8050-505050505050';
    const manualOperation = '60606060-6060-4060-8060-606060606060';
    const cancelOperation = '70707070-7070-4070-8070-707070707070';
    const contribution = IndicatorValue(
      scaledValue: 1,
      scale: 0,
      unit: 'count',
    );

    await events.saveEvent(
      profileId: profileId,
      draft: CalendarEventDraft(
        id: eventId,
        title: 'Delta 4 contributing Event',
        timing: CalendarEventTiming.timed,
        startDate: periodStart,
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: true,
        goalId: goal.id,
        contributionRuleKey: 'life-indicator:$indicatorKey:1:0:count',
      ),
    );
    final eventSource = await reporting.readEventSource(
      profileId: profileId,
      eventId: eventId,
      originalDate: periodStart,
    );
    await reporting.submit(
      profileId: profileId,
      draft: OutcomeReportDraft(
        id: eventReportId,
        source: eventSource!,
        activityDate: periodStart,
        outcome: OutcomeKind.completedHappened,
        contributions: <ContributionDraft>[
          ContributionDraft(
            ruleKey: 'event:$indicatorKey',
            indicatorKey: indicatorKey,
            value: contribution,
          ),
        ],
      ),
      operationId: eventReportOperation,
    );
    await reporting.submit(
      profileId: profileId,
      draft: OutcomeReportDraft(
        id: manualReportId,
        source: const OutcomeReportSource(
          type: OutcomeSourceType.manual,
          sourceId: manualSourceId,
          label: 'Manual Job Application',
          activityDate: periodStart,
        ),
        activityDate: periodStart,
        outcome: OutcomeKind.completedHappened,
        contributions: <ContributionDraft>[
          ContributionDraft(
            ruleKey: 'manual:$indicatorKey',
            indicatorKey: indicatorKey,
            value: contribution,
          ),
        ],
      ),
      operationId: manualOperation,
    );

    expect(
      (await repository.readProgress(
        profileId: profileId,
        goalId: goal.id,
        today: periodStart,
      ))!.dailyActual.scaledValue,
      2,
    );

    final lifecycleRefresh = repository.watchChanges(profileId).first;
    final changed = await events.cancelEvent(
      profileId: profileId,
      eventId: eventId,
      originalDate: periodStart,
      scope: CalendarEventEditScope.occurrence,
      operationId: cancelOperation,
    );
    await lifecycleRefresh;
    final retry = await events.cancelEvent(
      profileId: profileId,
      eventId: eventId,
      originalDate: periodStart,
      scope: CalendarEventEditScope.occurrence,
      operationId: cancelOperation,
    );

    expect(changed, CalendarEventMutationOutcome.changed);
    expect(retry, CalendarEventMutationOutcome.unchanged);
    expect(
      (await repository.readProgress(
        profileId: profileId,
        goalId: goal.id,
        today: periodStart,
      ))!.dailyActual.scaledValue,
      1,
      reason:
          'the manual contribution remains while the deleted Event '
          'no longer qualifies for current Actual',
    );
    expect(await database.select(database.outcomeReports).get(), hasLength(2));
    expect(
      await database.select(database.activityLedgerEntries).get(),
      hasLength(2),
      reason:
          'immutable factual history is retained; projection decides '
          'whether the Event still counts',
    );
    await Future<void>.delayed(Duration.zero);
    expect(changeGenerations.length, greaterThan(1));
    expect(
      changeGenerations.toSet(),
      hasLength(changeGenerations.length),
      reason:
          'every committed lifecycle change needs a distinct Riverpod value; '
          'a void or constant stream leaves Home stuck on stale Actuals',
    );
  });
}

/// Counts SELECT statements executed through the wrapped executor so a read
/// path can be proven to use a bounded query budget instead of a serial
/// per-Goal/per-field fan-out.
class _CountingInterceptor extends QueryInterceptor {
  int selectCount = 0;

  void reset() => selectCount = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.trimLeft().toUpperCase().startsWith('SELECT')) {
      selectCount += 1;
    }
    return super.runSelect(executor, statement, args);
  }
}

/// Deterministic textual projection of a [GoalPlanningSnapshot] used as the
/// semantic oracle when comparing the canonical projection to the bounded
/// batched projection.
String _serializeSnapshot(GoalPlanningSnapshot snapshot) {
  String amount(IndicatorAmount value) {
    return '${value.scaledValue}:${value.scale}:${value.unit}';
  }

  String target(IndicatorTarget value) {
    final resolved = value.value;
    return resolved == null ? 'unset' : amount(resolved);
  }

  String goal(Goal goal) {
    return '${goal.id}|${goal.title}|${goal.role.name}|${goal.activeSlotIndex}';
  }

  String progress(GoalProgress item) {
    return [
      goal(item.goal),
      'dA=${amount(item.dailyActual)}',
      'dT=${target(item.dailyTarget)}',
      'wA=${amount(item.weeklyActual)}',
      'wT=${target(item.weeklyTarget)}',
      'mA=${amount(item.monthlyActual)}',
      'mT=${target(item.monthlyTarget)}',
    ].join(';');
  }

  final parts = <String>[
    'start=${snapshot.periodStart.iso8601}',
    'end=${snapshot.periodEnd.iso8601}',
    if (snapshot.daily != null) 'daily=${progress(snapshot.daily!)}',
    for (final item in snapshot.weekly) 'weekly=${progress(item)}',
    if (snapshot.monthly != null) 'monthly=${progress(snapshot.monthly!)}',
  ];
  return parts.join('\n');
}

/// Fixed clock used by the file-level MP-16 fixture helpers.
final _mp16Clock = FixedClock(DateTime.utc(2026, 8, 14, 12));

/// MP-16 fixture: a fresh canonical profile whose G4/G5 pair is rewritten to
/// the exact legacy crossed post-bootstrap state with immutable v17 creation
/// evidence. `rewrite: false` leaves the fresh canonical evidence in place.
Future<(AppDatabase, DriftGoalRepository, String)> _crossedFixture({
  bool rewrite = true,
  String g4Title = 'Ministering Visit',
  String g5Title = 'Budget Review',
  String? g4Icon = 'social_two_people',
  String? g5Icon = 'finance_wallet',
}) async {
  final database = openMemoryDatabase();
  final startup = buildTestRepository(database: database);
  final profile = await startup.completeOnboarding();
  // The MP-16 fixture needs the pre-M6 seeded canonical six to rewrite the
  // G4/G5 pair, so the legacy seed is applied explicitly.
  await seedLegacyCanonicalGoals(database, profile.id, clock: _mp16Clock);
  final profileId = profile.id;
  final repository = DriftGoalRepository(
    database: database,
    clock: _mp16Clock,
    identifiers: const UuidIdentifierSource(),
  );
  await DriftEventTypeRepository(
    database: database,
    clock: _mp16Clock,
  ).readEventTypes(profileId: profileId);
  await repository.readActiveGoals(profileId);
  if (rewrite) {
    await _rewriteToLegacyCrossedPair(
      database,
      profileId,
      g4Title: g4Title,
      g5Title: g5Title,
      g4Icon: g4Icon,
      g5Icon: g5Icon,
    );
  }
  return (database, repository, profileId);
}

/// Rewrites the current G4/G5 rows into the exact crossed legacy state: the
/// preserved legacy titles/icons, the crossed current key/slot fields, the
/// immutable v17 created-activity evidence, the deterministic created-outbox
/// evidence, and the collateral wrong derived definition label.
Future<void> _rewriteToLegacyCrossedPair(
  AppDatabase database,
  String profileId, {
  String g4Title = 'Ministering Visit',
  String g5Title = 'Budget Review',
  String? g4Icon = 'social_two_people',
  String? g5Icon = 'finance_wallet',
}) async {
  final g4Id = '$profileId:goal:4';
  final g5Id = '$profileId:goal:5';
  final legacyUpdatedAt = DateTime.utc(2026, 8, 10, 3, 3, 10);
  await _updateGoal(
    database,
    profileId,
    g4Id,
    GoalsCompanion(
      title: Value<String>(g4Title),
      iconId: Value<String?>(g4Icon),
      updatedAtUtc: Value<DateTime>(legacyUpdatedAt),
    ),
  );
  await _updateGoal(
    database,
    profileId,
    g5Id,
    GoalsCompanion(
      title: Value<String>(g5Title),
      iconId: Value<String?>(g5Icon),
      updatedAtUtc: Value<DateTime>(legacyUpdatedAt),
    ),
  );
  await (database.update(
    database.goalActivities,
  )..where((table) => table.operationId.equals('$g4Id:created'))).write(
    const GoalActivitiesCompanion(
      action: Value<String>('created'),
      newValue: Value<String?>('Ministering Visit'),
    ),
  );
  await (database.update(
    database.goalActivities,
  )..where((table) => table.operationId.equals('$g5Id:created'))).write(
    const GoalActivitiesCompanion(
      action: Value<String>('created'),
      newValue: Value<String?>('Budget Review'),
    ),
  );
  await (database.update(
    database.goalOutboxOperations,
  )..where((table) => table.operationId.equals('$g4Id:created'))).write(
    GoalOutboxOperationsCompanion(
      action: const Value<String>('created'),
      payloadJson: Value<String>(
        jsonEncode(<String, Object?>{
          'goalId': g4Id,
          'role': 'weekly',
          'slot': 4,
          'title': 'Ministering Visit',
          'iconId': null,
        }),
      ),
    ),
  );
  await (database.update(
    database.goalOutboxOperations,
  )..where((table) => table.operationId.equals('$g5Id:created'))).write(
    GoalOutboxOperationsCompanion(
      action: const Value<String>('created'),
      payloadJson: Value<String>(
        jsonEncode(<String, Object?>{
          'goalId': g5Id,
          'role': 'weekly',
          'slot': 5,
          'title': 'Budget Review',
          'iconId': null,
        }),
      ),
    ),
  );
  await (database.update(database.lifeIndicatorDefinitions)..where(
        (table) =>
            table.profileId.equals(profileId) &
            table.indicatorKey.equals('meaningful_connections'),
      ))
      .write(
        const LifeIndicatorDefinitionsCompanion(
          label: Value<String>('Budget Review'),
        ),
      );
}

Future<void> _updateGoal(
  AppDatabase database,
  String profileId,
  String goalId,
  GoalsCompanion companion,
) async {
  await (database.update(database.goals)..where(
        (table) => table.profileId.equals(profileId) & table.id.equals(goalId),
      ))
      .write(companion);
}

Future<void> _setGoalStatus(
  AppDatabase database,
  String profileId,
  String goalId,
  String status,
) async {
  await _updateGoal(
    database,
    profileId,
    goalId,
    GoalsCompanion(status: Value<String>(status)),
  );
}

Future<void> _updateActivity(
  AppDatabase database,
  String operationId,
  GoalActivitiesCompanion companion,
) async {
  await (database.update(
    database.goalActivities,
  )..where((table) => table.operationId.equals(operationId))).write(companion);
}

Future<void> _updateOutboxAction(
  AppDatabase database,
  String operationId,
  String action,
) async {
  await (database.update(database.goalOutboxOperations)
        ..where((table) => table.operationId.equals(operationId)))
      .write(GoalOutboxOperationsCompanion(action: Value<String>(action)));
}

Future<void> _updateOutboxPayload(
  AppDatabase database,
  String operationId, {
  String? title,
  int? slot,
}) async {
  final existing = await (database.select(
    database.goalOutboxOperations,
  )..where((table) => table.operationId.equals(operationId))).getSingle();
  final payload = Map<String, Object?>.from(
    jsonDecode(existing.payloadJson) as Map,
  );
  if (title != null) payload['title'] = title;
  if (slot != null) payload['slot'] = slot;
  await (database.update(
    database.goalOutboxOperations,
  )..where((table) => table.operationId.equals(operationId))).write(
    GoalOutboxOperationsCompanion(
      payloadJson: Value<String>(jsonEncode(payload)),
    ),
  );
}

Future<void> _updateEventTypeStableKey(
  AppDatabase database,
  String profileId,
  String eventTypeId,
  String stableKey,
) async {
  await (database.update(database.activityTypes)..where(
        (table) =>
            table.profileId.equals(profileId) & table.id.equals(eventTypeId),
      ))
      .write(ActivityTypesCompanion(stableKey: Value<String>(stableKey)));
}

Future<void> _updateMapping(
  AppDatabase database,
  String profileId,
  String eventTypeId, {
  int? mappingVersion,
  String? indicatorKey,
}) async {
  await (database.update(database.activityTypeIndicatorMappings)..where(
        (table) =>
            table.profileId.equals(profileId) &
            table.activityTypeId.equals(eventTypeId),
      ))
      .write(
        ActivityTypeIndicatorMappingsCompanion(
          mappingVersion: mappingVersion == null
              ? const Value.absent()
              : Value<int>(mappingVersion),
          indicatorKey: indicatorKey == null
              ? const Value.absent()
              : Value<String>(indicatorKey),
        ),
      );
}

/// Byte-for-byte snapshot of every row the MP-16 repair MUST NOT change, plus
/// the Goal rows serialized through the allowed-fields whitelist so the test
/// can prove the ONLY changes are the permitted current fields. The derived
/// definition label is returned separately because it is allowed to converge.
Future<Map<String, List<Map<String, Object?>>>> _preservationSnapshot(
  AppDatabase database,
  String profileId,
) async {
  final goals = await (database.select(
    database.goals,
  )..where((table) => table.profileId.equals(profileId))).get();
  final definitions = await (database.select(
    database.lifeIndicatorDefinitions,
  )..where((table) => table.profileId.equals(profileId))).get();
  final types = await (database.select(
    database.activityTypes,
  )..where((table) => table.profileId.equals(profileId))).get();
  final mappings = await (database.select(
    database.activityTypeIndicatorMappings,
  )..where((table) => table.profileId.equals(profileId))).get();
  final events = await (database.select(
    database.calendarEvents,
  )..where((table) => table.profileId.equals(profileId))).get();
  final exceptions = await (database.select(
    database.calendarEventExceptions,
  )..where((table) => table.profileId.equals(profileId))).get();
  final reports = await (database.select(
    database.outcomeReports,
  )..where((table) => table.profileId.equals(profileId))).get();
  final drafts = await (database.select(
    database.outcomeReportContributionDrafts,
  )..where((table) => table.reportId.isIn(<String>['mp16-report']))).get();
  final ledger = await (database.select(
    database.activityLedgerEntries,
  )..where((table) => table.profileId.equals(profileId))).get();
  final activities = await (database.select(
    database.goalActivities,
  )..where((table) => table.profileId.equals(profileId))).get();
  final outbox = await (database.select(
    database.goalOutboxOperations,
  )..where((table) => table.profileId.equals(profileId))).get();
  final indicatorRevisions = await (database.select(
    database.indicatorGoalRevisions,
  )..where((table) => table.profileId.equals(profileId))).get();
  final weeklyRevisions = await (database.select(
    database.weeklyIndicatorTargetRevisions,
  )..where((table) => table.profileId.equals(profileId))).get();
  final tasks = await (database.select(
    database.plannerTasks,
  )..where((table) => table.profileId.equals(profileId))).get();
  final statusChanges = await (database.select(
    database.taskStatusChanges,
  )..where((table) => table.profileId.equals(profileId))).get();
  final contributions = await (database.select(
    database.taskGoalContributions,
  )..where((table) => table.profileId.equals(profileId))).get();

  final goalRows = <Map<String, Object?>>[
    for (final row in goals)
      if (row.id == '$profileId:goal:4' || row.id == '$profileId:goal:5')
        <String, Object?>{
          'id': row.id,
          'profileId': row.profileId,
          'role': row.role,
          'title': row.title,
          'iconId': row.iconId,
          'status': row.status,
          'createdAtUtc': row.createdAtUtc.toUtc().toIso8601String(),
          'archivedAtUtc': row.archivedAtUtc?.toUtc().toIso8601String(),
          'deletedAtUtc': row.deletedAtUtc?.toUtc().toIso8601String(),
        }
      else
        row.toJson(),
  ];
  final definitionRows = <Map<String, Object?>>[
    for (final row in definitions)
      if (row.indicatorKey == 'meaningful_connections' && row.position == 3)
        <String, Object?>{
          'id': row.id,
          'profileId': row.profileId,
          'indicatorKey': row.indicatorKey,
          'unit': row.unit,
          'position': row.position,
          'createdAtUtc': row.createdAtUtc.toUtc().toIso8601String(),
        }
      else
        row.toJson(),
  ];

  List<Map<String, Object?>> sorted(List<Map<String, Object?>> rows) {
    rows.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    return rows;
  }

  return <String, List<Map<String, Object?>>>{
    'goals': sorted(goalRows),
    'lifeIndicatorDefinitions': sorted(definitionRows),
    'activityTypes': sorted([for (final row in types) row.toJson()]),
    'activityTypeIndicatorMappings': sorted([
      for (final row in mappings) row.toJson(),
    ]),
    'calendarEvents': sorted([for (final row in events) row.toJson()]),
    'calendarEventExceptions': sorted([
      for (final row in exceptions) row.toJson(),
    ]),
    'outcomeReports': sorted([for (final row in reports) row.toJson()]),
    'outcomeReportContributionDrafts': sorted([
      for (final row in drafts) row.toJson(),
    ]),
    'activityLedgerEntries': sorted([for (final row in ledger) row.toJson()]),
    'goalActivities': sorted([for (final row in activities) row.toJson()]),
    'goalOutboxOperations': sorted([for (final row in outbox) row.toJson()]),
    'indicatorGoalRevisions': sorted([
      for (final row in indicatorRevisions) row.toJson(),
    ]),
    'weeklyIndicatorTargetRevisions': sorted([
      for (final row in weeklyRevisions) row.toJson(),
    ]),
    'plannerTasks': sorted([for (final row in tasks) row.toJson()]),
    'taskStatusChanges': sorted([
      for (final row in statusChanges) row.toJson(),
    ]),
    'taskGoalContributions': sorted([
      for (final row in contributions) row.toJson(),
    ]),
  };
}

/// Snapshot of the immutable evidence tables used by the negative matrix.
Future<Map<String, List<Map<String, Object?>>>> _evidenceSnapshot(
  AppDatabase database,
  String profileId,
) async {
  final activities = await (database.select(
    database.goalActivities,
  )..where((table) => table.profileId.equals(profileId))).get();
  final outbox = await (database.select(
    database.goalOutboxOperations,
  )..where((table) => table.profileId.equals(profileId))).get();
  final types = await (database.select(
    database.activityTypes,
  )..where((table) => table.profileId.equals(profileId))).get();
  final mappings = await (database.select(
    database.activityTypeIndicatorMappings,
  )..where((table) => table.profileId.equals(profileId))).get();
  List<Map<String, Object?>> sorted(List<Map<String, Object?>> rows) {
    rows.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    return rows;
  }

  return <String, List<Map<String, Object?>>>{
    'goalActivities': sorted([for (final row in activities) row.toJson()]),
    'goalOutboxOperations': sorted([for (final row in outbox) row.toJson()]),
    'activityTypes': sorted([for (final row in types) row.toJson()]),
    'activityTypeIndicatorMappings': sorted([
      for (final row in mappings) row.toJson(),
    ]),
  };
}

/// Full byte-for-byte snapshot of every Goal row (used for idempotence).
Future<Map<String, List<Map<String, Object?>>>> _fullGoalSnapshot(
  AppDatabase database,
  String profileId,
) async {
  final goals = await (database.select(
    database.goals,
  )..where((table) => table.profileId.equals(profileId))).get();
  final rows = [for (final row in goals) row.toJson()];
  rows.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  return <String, List<Map<String, Object?>>>{'goals': rows};
}
