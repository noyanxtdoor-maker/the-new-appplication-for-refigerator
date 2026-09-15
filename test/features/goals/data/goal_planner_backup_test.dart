import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late AppDatabase database;
  late DriftGoalRepository goals;
  late DriftPlannerRepository planner;
  late String profileId;

  final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));

  setUp(() async {
    database = openMemoryDatabase();
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    await seedLegacyCanonicalGoals(database, profileId);
    goals = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    planner = DriftPlannerRepository(database: database, clock: clock);
    await DriftEventTypeRepository(
      database: database,
      clock: clock,
    ).readEventTypes(profileId: profileId);
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'backup round trip preserves linked Tasks, status history, and contributions',
    () async {
      final jobGoal = (await goals.readActiveGoals(
        profileId,
      )).singleWhere((goal) => goal.indicatorKey == 'job_applications');
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'backup-task',
          title: 'Apply for a role',
          dueDate: const PlannerDate(year: 2026, month: 8, day: 3),
          dueMinute: 600,
          requiresReport: false,
          goalId: jobGoal.id,
        ),
      );
      expect(task.goalId, jobGoal.id);

      final outcome = await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'backup-task-complete',
      );
      expect(outcome, TaskStatusChangeOutcome.changed);

      final backup = await goals.exportBackup(profileId);
      expect(backup['format'], 'rmplanner.backup.v2');
      expect(backup['schemaVersion'], 2);
      expect(backup['plannerTasks'], hasLength(1));
      expect(backup['taskStatusChanges'], hasLength(1));
      expect(backup['taskGoalContributions'], hasLength(1));

      await database.delete(database.taskGoalContributions).go();
      await database.delete(database.taskStatusChanges).go();
      await database.delete(database.plannerTasks).go();

      await goals.importBackup(profileId: profileId, backup: backup);

      final restored = await planner.readTask(
        profileId: profileId,
        taskId: task.id,
      );
      expect(restored, isNotNull);
      expect(restored!.title, 'Apply for a role');
      expect(restored.status, PlannerTaskStatus.completed);
      expect(restored.dueDate, const PlannerDate(year: 2026, month: 8, day: 3));
      expect(restored.dueMinute, 600);
      expect(restored.goalId, jobGoal.id);
      expect(restored.linkedActivityTypeId, isNull);
      expect(restored.linkedActivityTypeStableKey, isNull);
      expect(restored.linkedActivityTypeLabelSnapshot, isNull);

      final statusChanges = await database
          .select(database.taskStatusChanges)
          .get();
      expect(statusChanges, hasLength(1));
      expect(statusChanges.single.operationId, 'backup-task-complete');
      expect(statusChanges.single.activityTypeStableKeySnapshot, isNull);
      expect(statusChanges.single.activityTypeLabelSnapshot, isNull);

      final contributions = await database
          .select(database.taskGoalContributions)
          .get();
      expect(contributions, hasLength(1));
      expect(contributions.single.taskId, task.id);
      expect(contributions.single.indicatorKey, 'job_applications');
      expect(contributions.single.state, 'active');
      expect(contributions.single.goalId, jobGoal.id);
      expect(contributions.single.activityTypeStableKeySnapshot, isNull);
      expect(contributions.single.activityTypeLabelSnapshot, isNull);

      final progress = await goals.readProgress(
        profileId: profileId,
        goalId: jobGoal.id,
        today: const PlannerDate(year: 2026, month: 8, day: 3),
      );
      expect(progress!.weeklyActual.scaledValue, 1);

      await goals.importBackup(profileId: profileId, backup: backup);
      expect(await database.select(database.plannerTasks).get(), hasLength(1));
      expect(
        await database.select(database.taskStatusChanges).get(),
        hasLength(1),
      );
      expect(
        await database.select(database.taskGoalContributions).get(),
        hasLength(1),
      );
    },
  );

  test(
    'completing a linked Task while the Goal slot is empty creates no orphan '
    'contribution',
    () async {
      final jobGoal = (await goals.readActiveGoals(
        profileId,
      )).singleWhere((goal) => goal.indicatorKey == 'job_applications');

      // Permanently delete the active Goal so its slot has no compatible
      // active Goal, then complete a linked Task.
      await goals.deleteGoal(
        profileId: profileId,
        goalId: jobGoal.id,
        operationId: 'empty-slot-delete',
      );
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'empty-slot-task',
          title: 'Apply while slot empty',
          dueDate: const PlannerDate(year: 2026, month: 8, day: 3),
          dueMinute: 600,
          requiresReport: false,
          goalId: jobGoal.id,
        ),
      );
      final outcome = await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'empty-slot-complete',
      );
      expect(outcome, TaskStatusChangeOutcome.changed);

      // No orphan contribution row is created while the slot is empty, and
      // no progress is attributed to the deleted Goal.
      final contributions = await database
          .select(database.taskGoalContributions)
          .get();
      expect(contributions, isEmpty);
      final deleted = await goals.readGoal(
        profileId: profileId,
        goalId: jobGoal.id,
      );
      expect(deleted?.status, GoalStatus.deleted);

      // A replacement Goal takes the freed slot; a newly completed linked
      // Task then contributes exactly once under the new identity.
      final replacement = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.dailyWeekly,
        title: 'Job Applications Renewed',
        targets: const GoalTargets(
          daily: IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count'),
          weekly: IndicatorAmount(scaledValue: 3, scale: 0, unit: 'count'),
        ),
        operationId: 'empty-slot-replacement',
      );
      expect(replacement.activeSlotIndex, 1);
      expect(replacement.indicatorKey, 'job_applications');

      final second = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'empty-slot-task-2',
          title: 'Apply after replacement',
          dueDate: const PlannerDate(year: 2026, month: 8, day: 3),
          dueMinute: 600,
          requiresReport: false,
          goalId: replacement.id,
        ),
      );
      final secondOutcome = await planner.changeTaskStatus(
        profileId: profileId,
        taskId: second.id,
        target: PlannerTaskStatus.completed,
        operationId: 'empty-slot-complete-2',
      );
      expect(secondOutcome, TaskStatusChangeOutcome.changed);

      final afterReplacement = await database
          .select(database.taskGoalContributions)
          .get();
      expect(afterReplacement, hasLength(1));
      expect(afterReplacement.single.taskId, second.id);
      expect(afterReplacement.single.indicatorKey, 'job_applications');
      expect(afterReplacement.single.goalId, replacement.id);
      final progress = await goals.readProgress(
        profileId: profileId,
        goalId: replacement.id,
        today: const PlannerDate(year: 2026, month: 8, day: 3),
      );
      expect(progress!.weeklyActual.scaledValue, 1);
    },
  );

  group('MP-16 legacy crossed backup convergence', () {
    test(
      'an old crossed Goal-only backup converges before the import returns '
      'and preserves the imported history',
      () async {
        final canonical = await goals.exportGoalBackup(profileId);
        final crossed =
            _legacyCrossedGoalBackup(canonical, profileId: profileId);
        // The device already holds the crossed pair with its legacy creation
        // evidence (the exact state an old backup captures), then the old
        // backup is imported over it.
        await _prepareCrossedDeviceState(database, profileId);

        await goals.importGoalBackup(
          profileId: profileId,
          backup: crossed,
        );

        final rows = await (database.select(
          database.goals,
        )..where(
          (table) =>
              table.profileId.equals(profileId) &
              (table.id.equals('$profileId:goal:4') |
                  table.id.equals('$profileId:goal:5')),
        )).get();
        final g4 = rows.singleWhere(
          (row) => row.id == '$profileId:goal:4',
        );
        final g5 = rows.singleWhere(
          (row) => row.id == '$profileId:goal:5',
        );
        // Reconciled to the historical identity before the import returned.
        expect(g5.activeSlotIndex, 4);
        expect(g5.indicatorKey, SystemEventTypeKeys.budgetReview);
        expect(
          g5.assignedEventTypeStableKey,
          SystemEventTypeKeys.budgetReview,
        );
        expect(g4.activeSlotIndex, 5);
        expect(g4.indicatorKey, 'meaningful_connections');
        expect(
          g4.assignedEventTypeStableKey,
          SystemEventTypeKeys.meaningfulConnection,
        );
        // Titles/icons from the backup are preserved.
        expect(g4.title, 'Ministering Visit');
        expect(g4.iconId, 'social_two_people');
        expect(g5.title, 'Budget Review');
        expect(g5.iconId, 'finance_wallet');
        // The immutable created evidence imported with the backup is intact.
        final activities = await (database.select(
          database.goalActivities,
        )..where(
          (table) =>
              table.operationId.isIn(<String>[
                '$profileId:goal:4:created',
                '$profileId:goal:5:created',
              ]),
        )).get();
        expect(
          activities.singleWhere(
            (row) => row.operationId == '$profileId:goal:4:created',
          ).newValue,
          'Ministering Visit',
        );
        expect(
          activities.singleWhere(
            (row) => row.operationId == '$profileId:goal:5:created',
          ).newValue,
          'Budget Review',
        );
        final outbox = await (database.select(
          database.goalOutboxOperations,
        )..where(
          (table) =>
              table.operationId.isIn(<String>[
                '$profileId:goal:4:created',
                '$profileId:goal:5:created',
              ]),
        )).get();
        expect(outbox, hasLength(2));

        // Importing the repaired profile again is a no-op for the helper.
        final before = await _serializeGoals(database, profileId);
        await goals.importGoalBackup(
          profileId: profileId,
          backup: crossed,
        );
        expect(await _serializeGoals(database, profileId), before);
      },
    );

    test(
      'a combined Goal/Planner backup converges inside the combined '
      'transaction and leaves Planner records untouched',
      () async {
        final jobType = (await database.select(database.activityTypes).get())
            .singleWhere(
              (row) => row.stableKey == SystemEventTypeKeys.jobApplication,
            );
        final task = await planner.saveTask(
          profileId: profileId,
          draft: PlannerTaskDraft(
            id: 'mp16-backup-task',
            title: 'MP-16 apply',
            dueDate: const PlannerDate(year: 2026, month: 8, day: 10),
            dueMinute: 600,
            requiresReport: false,
            linkedActivityTypeId: jobType.id,
            linkedActivityTypeStableKey: jobType.stableKey,
            linkedActivityTypeLabelSnapshot: jobType.label,
          ),
        );
        final backup = await goals.exportBackup(profileId);
        final crossed =
            _legacyCrossedGoalBackup(backup, profileId: profileId);
        await _prepareCrossedDeviceState(database, profileId);

        await goals.importBackup(profileId: profileId, backup: crossed);

        final rows = await (database.select(
          database.goals,
        )..where(
          (table) =>
              table.profileId.equals(profileId) &
              (table.id.equals('$profileId:goal:4') |
                  table.id.equals('$profileId:goal:5')),
        )).get();
        final g4 = rows.singleWhere(
          (row) => row.id == '$profileId:goal:4',
        );
        final g5 = rows.singleWhere(
          (row) => row.id == '$profileId:goal:5',
        );
        expect(g5.activeSlotIndex, 4);
        expect(g5.indicatorKey, SystemEventTypeKeys.budgetReview);
        expect(g4.activeSlotIndex, 5);
        expect(g4.indicatorKey, 'meaningful_connections');
        // Planner records remain untouched.
        final restored = await planner.readTask(
          profileId: profileId,
          taskId: task.id,
        );
        expect(restored, isNotNull);
        expect(restored!.title, 'MP-16 apply');
        expect(
          await database.select(database.taskStatusChanges).get(),
          isEmpty,
        );
        expect(
          await database.select(database.taskGoalContributions).get(),
          isEmpty,
        );
      },
    );

    test(
      'a canonical backup is a helper no-op and imports byte-identically',
      () async {
        final backup = await goals.exportGoalBackup(profileId);
        final before = await _serializeGoals(database, profileId);

        await goals.importGoalBackup(
          profileId: profileId,
          backup: backup,
        );

        expect(await _serializeGoals(database, profileId), before);
      },
    );

    test(
      'an incomplete crossed backup without outbox evidence fails closed '
      '(import succeeds, pair stays crossed, no guess repair)',
      () async {
        final canonical = await goals.exportGoalBackup(profileId);
        final crossed =
            _legacyCrossedGoalBackup(canonical, profileId: profileId);
        crossed['goalOutboxOperations'] = <Object?>[];
        await _prepareCrossedDeviceState(database, profileId, outboxAction: 'updated');

        await goals.importGoalBackup(
          profileId: profileId,
          backup: crossed,
        );

        final rows = await (database.select(
          database.goals,
        )..where(
          (table) =>
              table.profileId.equals(profileId) &
              (table.id.equals('$profileId:goal:4') |
                  table.id.equals('$profileId:goal:5')),
        )).get();
        final g4 = rows.singleWhere(
          (row) => row.id == '$profileId:goal:4',
        );
        final g5 = rows.singleWhere(
          (row) => row.id == '$profileId:goal:5',
        );
        // No guess: the imported crossed rows stay exactly as imported.
        expect(g4.activeSlotIndex, 4);
        expect(g4.indicatorKey, SystemEventTypeKeys.budgetReview);
        expect(g5.activeSlotIndex, 5);
        expect(g5.indicatorKey, 'meaningful_connections');
      },
    );
  });

  test(
    'invalid Planner backup does not partially apply Goal changes',
    () async {
      final backup = await goals.exportBackup(profileId);
      final goalRows = [
        for (final row in (backup['goals']! as List))
          Map<String, Object?>.from(row as Map),
      ];
      final originalTitle = goalRows.first['title'];
      goalRows.first['title'] = 'Should not be imported';

      final invalidBackup = <String, Object?>{
        ...backup,
        'goals': goalRows,
        'plannerTasks': <Object?>[
          <String, Object?>{
            'id': 'invalid-task',
            'title': 'Invalid task',
            'createdAtUtc': 'not-a-date',
            'updatedAtUtc': 'not-a-date',
          },
        ],
      };

      await expectLater(
        goals.importBackup(profileId: profileId, backup: invalidBackup),
        throwsA(isA<GoalValidationException>()),
      );

      final unchanged = (await goals.readActiveGoals(profileId)).first;
      expect(unchanged.title, originalTitle);
      expect(await database.select(database.plannerTasks).get(), isEmpty);
    },
  );
}

/// Puts the current profile into the exact legacy crossed device state: the
/// crossed Goal keys/slots with preserved legacy titles/icons, the immutable
/// v17 created-activity evidence, and the deterministic created-outbox
/// evidence. `outboxAction: 'updated'` removes the created-outbox evidence
/// (fail-closed setup).
Future<void> _prepareCrossedDeviceState(
  AppDatabase database,
  String profileId, {
  String outboxAction = 'created',
}) async {
  final g4Id = '$profileId:goal:4';
  final g5Id = '$profileId:goal:5';
  await (database.update(database.goals)..where(
    (table) => table.profileId.equals(profileId) & table.id.equals(g4Id),
  )).write(
    GoalsCompanion(
      indicatorKey: const Value<String?>(
        SystemEventTypeKeys.budgetReview,
      ),
      assignedEventTypeStableKey: const Value<String?>(
        SystemEventTypeKeys.budgetReview,
      ),
      activeSlotIndex: const Value<int?>(4),
      title: const Value<String>('Ministering Visit'),
      iconId: const Value<String?>('social_two_people'),
    ),
  );
  await (database.update(database.goals)..where(
    (table) => table.profileId.equals(profileId) & table.id.equals(g5Id),
  )).write(
    GoalsCompanion(
      indicatorKey: const Value<String?>('meaningful_connections'),
      assignedEventTypeStableKey: const Value<String?>(
        SystemEventTypeKeys.meaningfulConnection,
      ),
      activeSlotIndex: const Value<int?>(5),
      title: const Value<String>('Budget Review'),
      iconId: const Value<String?>('finance_wallet'),
    ),
  );
  await (database.update(database.goalActivities)..where(
    (table) => table.operationId.equals('$g4Id:created'),
  )).write(
    const GoalActivitiesCompanion(
      action: Value<String>('created'),
      newValue: Value<String?>('Ministering Visit'),
    ),
  );
  await (database.update(database.goalActivities)..where(
    (table) => table.operationId.equals('$g5Id:created'),
  )).write(
    const GoalActivitiesCompanion(
      action: Value<String>('created'),
      newValue: Value<String?>('Budget Review'),
    ),
  );
  await (database.update(database.goalOutboxOperations)..where(
    (table) => table.operationId.equals('$g4Id:created'),
  )).write(
    GoalOutboxOperationsCompanion(
      action: Value<String>(outboxAction),
      payloadJson: Value<String>(jsonEncode(<String, Object?>{
        'goalId': g4Id,
        'role': 'weekly',
        'slot': 4,
        'title': 'Ministering Visit',
        'iconId': 'social_two_people',
      })),
    ),
  );
  await (database.update(database.goalOutboxOperations)..where(
    (table) => table.operationId.equals('$g5Id:created'),
  )).write(
    GoalOutboxOperationsCompanion(
      action: Value<String>(outboxAction),
      payloadJson: Value<String>(jsonEncode(<String, Object?>{
        'goalId': g5Id,
        'role': 'weekly',
        'slot': 5,
        'title': 'Budget Review',
        'iconId': 'finance_wallet',
      })),
    ),
  );
}

/// Rewrites a valid exported backup into the exact legacy crossed state: the
/// crossed Goal keys/slots with preserved legacy titles/icons, the immutable
/// v17 created-activity evidence, and the deterministic created-outbox
/// evidence. The parser accepts these rows because their stored keys match
/// their current slots, mirroring the real old backup.
Map<String, Object?> _legacyCrossedGoalBackup(
  Map<String, Object?> backup, {
  required String profileId,
}) {
  final g4Id = '$profileId:goal:4';
  final g5Id = '$profileId:goal:5';
  final goals = [
    for (final row in (backup['goals']! as List))
      Map<String, Object?>.from(row as Map),
  ];
  for (final goal in goals) {
    if (goal['id'] == g4Id) {
      goal['indicatorKey'] = SystemEventTypeKeys.budgetReview;
      goal['assignedEventTypeStableKey'] = SystemEventTypeKeys.budgetReview;
      goal['activeSlotIndex'] = 4;
      goal['title'] = 'Ministering Visit';
      goal['iconId'] = 'social_two_people';
    } else if (goal['id'] == g5Id) {
      goal['indicatorKey'] = 'meaningful_connections';
      goal['assignedEventTypeStableKey'] =
          SystemEventTypeKeys.meaningfulConnection;
      goal['activeSlotIndex'] = 5;
      goal['title'] = 'Budget Review';
      goal['iconId'] = 'finance_wallet';
    }
  }
  final activities = [
    for (final row in (backup['goalActivities']! as List))
      Map<String, Object?>.from(row as Map),
  ];
  for (final activity in activities) {
    if (activity['operationId'] == '$g4Id:created') {
      activity['newValue'] = 'Ministering Visit';
    } else if (activity['operationId'] == '$g5Id:created') {
      activity['newValue'] = 'Budget Review';
    }
  }
  final outbox = [
    for (final row in (backup['goalOutboxOperations']! as List))
      Map<String, Object?>.from(row as Map),
  ];
  for (final operation in outbox) {
    if (operation['operationId'] == '$g4Id:created') {
      operation['payloadJson'] = jsonEncode(<String, Object?>{
        'goalId': g4Id,
        'role': 'weekly',
        'slot': 4,
        'title': 'Ministering Visit',
        'iconId': 'social_two_people',
      });
    } else if (operation['operationId'] == '$g5Id:created') {
      operation['payloadJson'] = jsonEncode(<String, Object?>{
        'goalId': g5Id,
        'role': 'weekly',
        'slot': 5,
        'title': 'Budget Review',
        'iconId': 'finance_wallet',
      });
    }
  }
  return <String, Object?>{
    ...backup,
    'goals': goals,
    'goalActivities': activities,
    'goalOutboxOperations': outbox,
  };
}

/// Deterministic byte-level snapshot of every Goal row (for import no-op
/// assertions).
Future<String> _serializeGoals(
  AppDatabase database,
  String profileId,
) async {
  final rows = await (database.select(
    database.goals,
  )..where((table) => table.profileId.equals(profileId))).get();
  final maps = [for (final row in rows) row.toJson()];
  maps.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  return jsonEncode(maps);
}
