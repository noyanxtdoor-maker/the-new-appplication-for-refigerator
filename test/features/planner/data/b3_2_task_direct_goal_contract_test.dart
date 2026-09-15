import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../support/test_dependencies.dart';

void main() {
  group('v26 -> v27 migration (B3.2 additive schema)', () {
    test(
      'adds goal_id columns + contact index, preserves legacy rows, no backfill',
      () async {
        final sqliteDatabase = sqlite3.openInMemory();
        try {
          final v26 = AppDatabase.forTesting(
            NativeDatabase.opened(
              sqliteDatabase,
              closeUnderlyingOnClose: false,
            ),
            schemaVersionOverride: 26,
          );
          final profile = (await buildTestRepository(
            database: v26,
          ).completeOnboarding()).id;
          // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
          await seedLegacyCanonicalGoals(v26, profile);
          final now = DateTime.utc(2026, 8, 3, 12);

          // Legacy Task with free-text people + no direct Goal.
          await v26
              .into(v26.plannerTasks)
              .insert(
                PlannerTasksCompanion.insert(
                  id: 'legacy-task',
                  profileId: profile,
                  title: 'Legacy task',
                  peopleJson: const Value<String>('["Mia"]'),
                  status: const Value<String>('completed'),
                  requiresReport: const Value<bool>(false),
                  createdAtUtc: now,
                  updatedAtUtc: now,
                ),
              );
          // Legacy contribution from the pre-B3.2 Event-Type inference path.
          await v26
              .into(v26.taskGoalContributions)
              .insert(
                TaskGoalContributionsCompanion.insert(
                  id: 'legacy-task:goal-contribution',
                  profileId: profile,
                  taskId: 'legacy-task',
                  indicatorKey: 'job_applications',
                  valueScaled: const Value<int>(1),
                  valueScale: const Value<int>(0),
                  unit: const Value<String>('count'),
                  activityDate: '2026-08-03',
                  state: const Value<String>('active'),
                  createdAtUtc: now,
                  updatedAtUtc: now,
                ),
              );
          // Legacy Contact + Task-Contact link (table exists since v22).
          await v26
              .into(v26.contacts)
              .insert(
                ContactsCompanion.insert(
                  id: 'legacy-contact',
                  profileId: profile,
                  displayName: 'Legacy Person',
                  createdAtUtc: now,
                  updatedAtUtc: now,
                ),
              );
          await v26
              .into(v26.taskContactLinks)
              .insert(
                TaskContactLinksCompanion.insert(
                  id: 'legacy-link',
                  profileId: profile,
                  taskId: 'legacy-task',
                  contactId: 'legacy-contact',
                  createdAtUtc: now,
                ),
              );

          // Simulate a TRUE v26 schema: remove the B3.2 additions so the
          // guarded addColumn / index-creation path actually runs on upgrade.
          await v26
              .customStatement('ALTER TABLE planner_tasks DROP COLUMN goal_id');
          await v26.customStatement(
            'ALTER TABLE task_goal_contributions DROP COLUMN goal_id',
          );
          await v26.customStatement(
            'DROP INDEX IF EXISTS task_contact_link_contact',
          );
          await v26.close();

          final v27 = AppDatabase.forTesting(
            NativeDatabase.opened(
              sqliteDatabase,
              closeUnderlyingOnClose: false,
            ),
            schemaVersionOverride: 27,
          );

          final taskColumns =
              await (v27.customSelect('PRAGMA table_info(planner_tasks)'))
                  .get();
          expect(
            taskColumns.any((row) => row.read<String>('name') == 'goal_id'),
            isTrue,
          );
          final contributionColumns = await (v27.customSelect(
            'PRAGMA table_info(task_goal_contributions)',
          )).get();
          expect(
            contributionColumns.any(
              (row) => row.read<String>('name') == 'goal_id',
            ),
            isTrue,
          );

          // Legacy data preserved byte-for-byte; NO backfill of goal_id.
          final task = await (v27.select(v27.plannerTasks)..where(
                (table) => table.id.equals('legacy-task'),
              ))
              .getSingle();
          expect(task.peopleJson, '["Mia"]');
          expect(task.goalId, isNull);
          final contribution = await (v27.select(
            v27.taskGoalContributions,
          )..where((table) => table.id.equals('legacy-task:goal-contribution')))
              .getSingle();
          expect(contribution.state, 'active');
          expect(contribution.indicatorKey, 'job_applications');
          expect(contribution.goalId, isNull);

          // Link table + contact_id index recreated.
          final links = await v27.select(v27.taskContactLinks).get();
          expect(links, hasLength(1));
          expect(links.single.taskId, 'legacy-task');
          final indexes = await (v27.customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'task_contact_link_contact'",
          )).get();
          expect(indexes, isNotEmpty);

          // Reopening at v27 is idempotent (no-op migration).
          await v27.close();
          final reopened = AppDatabase.forTesting(
            NativeDatabase.opened(
              sqliteDatabase,
              closeUnderlyingOnClose: false,
            ),
            schemaVersionOverride: 27,
          );
          expect(
            await reopened.select(reopened.plannerTasks).get(),
            hasLength(1),
          );
          await reopened.close();
        } finally {
          sqliteDatabase.close();
        }
      },
    );
  });

  group('Task direct Life Goal (D2)', () {
    late AppDatabase database;
    late DriftGoalRepository goals;
    late DriftPlannerRepository planner;
    late String profileId;

    final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));
    const today = PlannerDate(year: 2026, month: 8, day: 3);

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

    Future<Goal> activeGoal(String indicatorKey) async {
      return (await goals.readActiveGoals(
        profileId,
      )).singleWhere((goal) => goal.indicatorKey == indicatorKey);
    }

    test('goalId round-trips and completion contributes to THAT Goal', () async {
      final jobGoal = await activeGoal('job_applications');
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'direct-task',
          title: 'Apply directly',
          dueDate: today,
          dueMinute: 600,
          requiresReport: false,
          goalId: jobGoal.id,
        ),
      );
      expect(task.goalId, jobGoal.id);

      await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'direct-complete',
      );

      final rows = await database.select(database.taskGoalContributions).get();
      expect(rows, hasLength(1));
      expect(rows.single.state, 'active');
      expect(rows.single.goalId, jobGoal.id);
      expect(rows.single.indicatorKey, 'job_applications');
      expect(rows.single.activityTypeStableKeySnapshot, isNull);
      expect(rows.single.activityTypeLabelSnapshot, isNull);

      final progress = await goals.readProgress(
        profileId: profileId,
        goalId: jobGoal.id,
        today: today,
      );
      expect(progress!.weeklyActual.scaledValue, 1);
    });

    test('goalId null and Event-Type-only Task => NO contribution (no inference)',
        () async {
      final jobType = (await database.select(database.activityTypes).get())
          .singleWhere(
            (row) => row.stableKey == SystemEventTypeKeys.jobApplication,
          );
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'type-only-task',
          title: 'Event Type only',
          dueDate: today,
          requiresReport: false,
          linkedActivityTypeId: jobType.id,
          linkedActivityTypeStableKey: jobType.stableKey,
          linkedActivityTypeLabelSnapshot: jobType.label,
        ),
      );
      await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'type-only-complete',
      );
      expect(
        await database.select(database.taskGoalContributions).get(),
        isEmpty,
      );
    });

    test('missing goalId => no contribution, no throw, Task data intact',
        () async {
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'missing-goal-task',
          title: 'Missing goal',
          dueDate: today,
          requiresReport: false,
          goalId: 'no-such-goal-id',
        ),
      );
      final outcome = await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'missing-goal-complete',
      );
      expect(outcome, TaskStatusChangeOutcome.changed);
      expect(
        await database.select(database.taskGoalContributions).get(),
        isEmpty,
      );
      final restored = await planner.readTask(
        profileId: profileId,
        taskId: task.id,
      );
      expect(restored, isNotNull);
      expect(restored!.goalId, 'no-such-goal-id');
      expect(restored.status, PlannerTaskStatus.completed);
    });

    test('archived goal => no contribution (fail-closed)', () async {
      final jobGoal = await activeGoal('job_applications');
      await goals.archiveGoal(profileId: profileId, goalId: jobGoal.id);
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'archived-goal-task',
          title: 'Archived goal',
          dueDate: today,
          requiresReport: false,
          goalId: jobGoal.id,
        ),
      );
      await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'archived-goal-complete',
      );
      expect(
        await database.select(database.taskGoalContributions).get(),
        isEmpty,
      );
    });

    test(
      'relink needs explicit confirmation; confirmed relink reverses old and '
      'posts exactly one new contribution',
      () async {
        final goalA = await activeGoal('job_applications');
        final goalB = await activeGoal('budget_review');
        final task = await planner.saveTask(
          profileId: profileId,
          draft: PlannerTaskDraft(
            id: 'relink-task',
            title: 'Relink me',
            dueDate: today,
            requiresReport: false,
            goalId: goalA.id,
          ),
        );
        await planner.changeTaskStatus(
          profileId: profileId,
          taskId: task.id,
          target: PlannerTaskStatus.completed,
          operationId: 'relink-complete',
        );

        await expectLater(
          planner.saveTask(
            profileId: profileId,
            draft: PlannerTaskDraft(
              id: 'relink-task',
              title: 'Relink me',
              dueDate: today,
              requiresReport: false,
              goalId: goalB.id,
            ),
          ),
          throwsA(isA<PlannerTaskValidationException>()),
        );

        await planner.saveTask(
          profileId: profileId,
          draft: PlannerTaskDraft(
            id: 'relink-task',
            title: 'Relink me',
            dueDate: today,
            requiresReport: false,
            goalId: goalB.id,
          ),
          confirmLinkedTypeTransfer: true,
        );

        // task_goal_contributions carries a UNIQUE(task_id) index: a Task
        // has exactly one contribution row, and a confirmed relink reverses
        // the old effective contribution and reactivates that same row for
        // the new Goal (one net effective contribution).
        final rows = await database.select(database.taskGoalContributions).get();
        expect(rows, hasLength(1));
        expect(rows.single.state, 'active');
        expect(rows.single.goalId, goalB.id);

        final progressA = await goals.readProgress(
          profileId: profileId,
          goalId: goalA.id,
          today: today,
        );
        final progressB = await goals.readProgress(
          profileId: profileId,
          goalId: goalB.id,
          today: today,
        );
        expect(progressA!.weeklyActual.scaledValue, 0);
        expect(progressB!.weeklyActual.scaledValue, 1);
      },
    );

    test('unlink after completion reverses and posts no replacement', () async {
      final goalA = await activeGoal('job_applications');
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'unlink-task',
          title: 'Unlink me',
          dueDate: today,
          requiresReport: false,
          goalId: goalA.id,
        ),
      );
      await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'unlink-complete',
      );
      await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'unlink-task',
          title: 'Unlink me',
          dueDate: today,
          requiresReport: false,
          goalId: null,
        ),
        confirmLinkedTypeTransfer: true,
      );
      final rows = await database.select(database.taskGoalContributions).get();
      expect(rows, hasLength(1));
      expect(rows.single.state, 'reversed');
      expect(rows.single.goalId, goalA.id);
    });

    test('Event Type change alone never moves progress, no confirmation needed',
        () async {
      final goalA = await activeGoal('job_applications');
      final jobType = (await database.select(database.activityTypes).get())
          .singleWhere(
            (row) => row.stableKey == SystemEventTypeKeys.jobApplication,
          );
      final otherType = (await database.select(database.activityTypes).get())
          .firstWhere((row) => row.id != jobType.id);
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'type-move-task',
          title: 'Type changes',
          dueDate: today,
          requiresReport: false,
          goalId: goalA.id,
          linkedActivityTypeId: jobType.id,
          linkedActivityTypeStableKey: jobType.stableKey,
          linkedActivityTypeLabelSnapshot: jobType.label,
        ),
      );
      await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'type-move-complete',
      );

      // Editing Event Type metadata only: no guard, no contribution change.
      final saved = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'type-move-task',
          title: 'Type changes',
          dueDate: today,
          requiresReport: false,
          goalId: goalA.id,
          linkedActivityTypeId: otherType.id,
          linkedActivityTypeStableKey: otherType.stableKey,
          linkedActivityTypeLabelSnapshot: otherType.label,
        ),
      );
      expect(saved.goalId, goalA.id);
      final rows = await database.select(database.taskGoalContributions).get();
      expect(rows, hasLength(1));
      expect(rows.single.state, 'active');
      expect(rows.single.goalId, goalA.id);
    });

    test('double-complete is idempotent (one active contribution)', () async {
      final goalA = await activeGoal('job_applications');
      final task = await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'idem-task',
          title: 'Idempotent',
          dueDate: today,
          requiresReport: false,
          goalId: goalA.id,
        ),
      );
      await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'idem-complete',
      );
      final second = await planner.changeTaskStatus(
        profileId: profileId,
        taskId: task.id,
        target: PlannerTaskStatus.completed,
        operationId: 'idem-complete',
      );
      expect(second, TaskStatusChangeOutcome.unchanged);
      final rows = await database.select(database.taskGoalContributions).get();
      expect(rows, hasLength(1));
      expect(rows.single.state, 'active');
    });
  });

  group('Task People (D3 via task_contact_links)', () {
    late AppDatabase database;
    late DriftContactRepository contacts;
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
      contacts = DriftContactRepository(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
      );
      planner = DriftPlannerRepository(database: database, clock: clock);
    });

    tearDown(() async {
      await database.close();
    });

    Future<String> createContact(String id, String name) async {
      final contact = await contacts.createContact(
        profileId: profileId,
        draft: ContactDraft(
          id: id,
          firstName: name.split(' ').first,
          lastName: name.split(' ').length > 1 ? name.split(' ').last : name,
          displayName: name,
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
      return contact.id;
    }

    test(
      'new Contact selections persist via task_contact_links only and never '
      'touch peopleJson',
      () async {
        final mia = await createContact('contact-mia', 'Mia Smith');
        final jo = await createContact('contact-jo', 'Jo Doe');

        await planner.saveTask(
          profileId: profileId,
          draft: PlannerTaskDraft(
            id: 'people-task',
            title: 'With people',
            dueDate: const PlannerDate(year: 2026, month: 8, day: 3),
            requiresReport: false,
            people: const <String>[],
          ),
        );
        await contacts.setTaskContacts(
          profileId: profileId,
          taskId: 'people-task',
          contactIds: <String>[mia, jo],
        );

        final links = await database.select(database.taskContactLinks).get();
        expect(links, hasLength(2));
        expect(links.map((link) => link.contactId).toSet(), <String>{mia, jo});

        final summaries = await contacts.readTaskContacts(
          profileId: profileId,
          taskId: 'people-task',
        );
        expect(
          summaries.map((summary) => summary.contact.id).toSet(),
          <String>{mia, jo},
        );

        // Re-selecting the same set (with a duplicate) stays deduplicated.
        await contacts.setTaskContacts(
          profileId: profileId,
          taskId: 'people-task',
          contactIds: <String>[mia, mia, jo],
        );
        expect(
          await database.select(database.taskContactLinks).get(),
          hasLength(2),
        );

        // Contact ids never leak into peopleJson.
        final row = await (database.select(database.plannerTasks)..where(
              (table) => table.id.equals('people-task'),
            ))
            .getSingle();
        expect(row.peopleJson, '[]');
      },
    );

    test('legacy peopleJson survives edit-save unchanged', () async {
      await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'legacy-people-task',
          title: 'Legacy people',
          dueDate: const PlannerDate(year: 2026, month: 8, day: 3),
          requiresReport: false,
          people: const <String>['Mia'],
        ),
      );
      // Re-save the same legacy Task (unrelated edit path).
      await planner.saveTask(
        profileId: profileId,
        draft: PlannerTaskDraft(
          id: 'legacy-people-task',
          title: 'Legacy people edited',
          dueDate: const PlannerDate(year: 2026, month: 8, day: 3),
          requiresReport: false,
          people: const <String>['Mia'],
        ),
      );
      final row = await (database.select(database.plannerTasks)..where(
            (table) => table.id.equals('legacy-people-task'),
          ))
          .getSingle();
      expect(row.peopleJson, '["Mia"]');
    });
  });
}
