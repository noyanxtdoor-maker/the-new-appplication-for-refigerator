import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/domain/goal_icon_registry.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const periodStart = PlannerDate(year: 2026, month: 8, day: 3);
  const weeklyTarget = IndicatorAmount(scaledValue: 3, scale: 0, unit: 'count');
  final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));

  DriftGoalRepository repositoryFor(AppDatabase database) {
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
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
    // seeded explicitly instead of being created implicitly at onboarding.
    await seedLegacyCanonicalGoals(database, profile.id);
    return (database, repositoryFor(database), profile.id);
  }

  Future<Map<String, Object?>> outboxPayload(
    AppDatabase database,
    String operationId,
  ) async {
    final row =
        await (database.select(database.goalOutboxOperations)
              ..where((table) => table.operationId.equals(operationId))
              ..limit(1))
            .getSingle();
    return Map<String, Object?>.from(
      jsonDecode(row.payloadJson) as Map<Object?, Object?>,
    );
  }

  test(
    'iconId survives create, rename, archive, restore, outbox, and backup import',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);

      final exercise = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Exercise');
      await repository.archiveGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 'd1-free-weekly-slot',
      );

      final created = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Career Applications',
        targets: const GoalTargets(weekly: weeklyTarget),
        iconId: 'work_briefcase',
        operationId: 'd1-icon-create',
      );
      expect(created.iconId, 'work_briefcase');
      expect(
        (await outboxPayload(database, 'd1-icon-create'))['iconId'],
        'work_briefcase',
      );

      final renamed = await repository.saveGoal(
        profileId: profileId,
        goalId: created.id,
        title: 'Career Applications Renamed',
        targets: const GoalTargets(weekly: weeklyTarget),
        operationId: 'd1-icon-rename',
      );
      expect(renamed.iconId, 'work_briefcase');
      expect(
        (await outboxPayload(database, 'd1-icon-rename'))['iconId'],
        'work_briefcase',
      );

      final edited = await repository.saveGoal(
        profileId: profileId,
        goalId: created.id,
        title: renamed.title,
        targets: const GoalTargets(weekly: weeklyTarget),
        iconId: 'finance_wallet',
        operationId: 'd1-icon-edit',
      );
      expect(edited.iconId, 'finance_wallet');
      expect(
        (await outboxPayload(database, 'd1-icon-edit'))['iconId'],
        'finance_wallet',
      );

      await repository.archiveGoal(
        profileId: profileId,
        goalId: created.id,
        operationId: 'd1-icon-archive',
      );
      final archived = await repository.readGoal(
        profileId: profileId,
        goalId: created.id,
      );
      expect(archived?.status, GoalStatus.archived);
      expect(archived?.iconId, 'finance_wallet');
      expect(
        (await outboxPayload(database, 'd1-icon-archive'))['iconId'],
        'finance_wallet',
      );

      final restored = await repository.restoreGoal(
        profileId: profileId,
        goalId: created.id,
        operationId: 'd1-icon-restore',
      );
      expect(restored.status, GoalStatus.active);
      expect(restored.iconId, 'finance_wallet');
      expect(
        (await outboxPayload(database, 'd1-icon-restore'))['iconId'],
        'finance_wallet',
      );

      final backup = await repository.exportGoalBackup(profileId);
      final backupGoal = (backup['goals']! as List<Object?>)
          .map((value) => Map<String, Object?>.from(value! as Map))
          .firstWhere((goal) => goal['id'] == created.id);
      expect(backupGoal['iconId'], 'finance_wallet');
      expect(
        (backup['goalOutboxOperations']! as List<Object?>).any((value) {
          final operation = Map<String, Object?>.from(value! as Map);
          return operation['operationId'] == 'd1-icon-restore' &&
              (jsonDecode(operation['payloadJson']! as String)
                      as Map<String, Object?>)['iconId'] ==
                  'finance_wallet';
        }),
        isTrue,
      );

      final importedDatabase = openMemoryDatabase();
      addTearDown(importedDatabase.close);
      final importedStartup = buildTestRepository(database: importedDatabase);
      final importedProfile = await importedStartup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(importedDatabase, importedProfile.id);
      expect(importedProfile.id, profileId);
      final importedRepository = repositoryFor(importedDatabase);
      await importedRepository.importGoalBackup(
        profileId: importedProfile.id,
        backup: backup,
      );
      expect(
        (await importedRepository.readGoal(
          profileId: importedProfile.id,
          goalId: created.id,
        ))?.iconId,
        'finance_wallet',
      );

      final planning = await importedRepository.readPlanning(
        profileId: importedProfile.id,
        periodStart: periodStart,
      );
      expect(
        planning.weekly.any((progress) => progress.goal.id == created.id),
        isTrue,
      );
    },
  );

  test(
    'stored retired-alias iconIds (find_job, finance_pie_chart) survive the '
    'full lifecycle as raw strings and resolve to their canonical visuals '
    '(Stage-1.1 alias contract, no migration)',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);

      for (final retiredId in <String>['find_job', 'finance_pie_chart']) {
        // Free one WEEKLY slot per iteration (weekly capacity is bounded);
        // archiving a non-weekly goal does not free a weekly slot.
        final active = await repository.readActiveGoals(profileId);
        final toFree = active.firstWhere(
          (goal) => goal.role == GoalRole.weekly,
        );
        await repository.archiveGoal(
          profileId: profileId,
          goalId: toFree.id,
          operationId: 'ra-free-slot-$retiredId',
        );

        final created = await repository.createGoal(
          profileId: profileId,
          role: GoalRole.weekly,
          title: 'Retired Alias Goal $retiredId',
          targets: const GoalTargets(weekly: weeklyTarget),
          iconId: retiredId,
          operationId: 'ra-create-$retiredId',
        );
        expect(created.iconId, retiredId,
            reason: 'stored ID must never be rewritten to the canonical ID');

        final renamed = await repository.saveGoal(
          profileId: profileId,
          goalId: created.id,
          title: 'Renamed $retiredId',
          targets: const GoalTargets(weekly: weeklyTarget),
          operationId: 'ra-rename-$retiredId',
        );
        expect(renamed.iconId, retiredId);

        final backup = await repository.exportGoalBackup(profileId);
        final backupGoal = (backup['goals']! as List<Object?>)
            .map((value) => Map<String, Object?>.from(value! as Map))
            .firstWhere((goal) => goal['id'] == created.id);
        expect(backupGoal['iconId'], retiredId);

        final importedDatabase = openMemoryDatabase();
        addTearDown(importedDatabase.close);
        final importedStartup = buildTestRepository(database: importedDatabase);
        final importedProfile = await importedStartup.completeOnboarding();
        // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
        // seeded explicitly instead of being created implicitly at onboarding.
        await seedLegacyCanonicalGoals(importedDatabase, importedProfile.id);
        final importedRepository = repositoryFor(importedDatabase);
        await importedRepository.importGoalBackup(
          profileId: importedProfile.id,
          backup: backup,
        );
        expect(
          (await importedRepository.readGoal(
            profileId: importedProfile.id,
            goalId: created.id,
          ))?.iconId,
          retiredId,
          reason: 'alias must round-trip raw through backup/import',
        );

        // The registry resolves the retired alias to its canonical visual
        // without the stored value changing.
        final definition = GoalIconRegistry.instance.findById(retiredId);
        expect(definition, isNotNull);
        expect(
          definition!.id,
          retiredId == 'find_job' ? 'work_briefcase' : 'finance_wallet',
        );
        expect(
          GoalIconRegistry.allIcons.any((d) => d.id == retiredId),
          isFalse,
        );
      }
    },
  );

  test(
    'stored social_two_people iconId survives create, rename, archive, '
    'restore, and backup import untouched (Stage-1 interim, no migration)',
    () async {
      final (database, repository, profileId) = await arrange();
      addTearDown(database.close);

      final exercise = (await repository.readActiveGoals(
        profileId,
      )).firstWhere((goal) => goal.title == 'Exercise');
      await repository.archiveGoal(
        profileId: profileId,
        goalId: exercise.id,
        operationId: 's2p-free-slot',
      );

      final created = await repository.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Meaningful Connections',
        targets: const GoalTargets(weekly: weeklyTarget),
        iconId: 'social_two_people',
        operationId: 's2p-create',
      );
      expect(created.iconId, 'social_two_people');
      expect(
        (await outboxPayload(database, 's2p-create'))['iconId'],
        'social_two_people',
      );

      final renamed = await repository.saveGoal(
        profileId: profileId,
        goalId: created.id,
        title: 'Meaningful Connections Renamed',
        targets: const GoalTargets(weekly: weeklyTarget),
        operationId: 's2p-rename',
      );
      expect(renamed.iconId, 'social_two_people',
          reason: 'rename must never rewrite the stored iconId');

      await repository.archiveGoal(
        profileId: profileId,
        goalId: created.id,
        operationId: 's2p-archive',
      );
      final archived = await repository.readGoal(
        profileId: profileId,
        goalId: created.id,
      );
      expect(archived?.iconId, 'social_two_people');

      final restored = await repository.restoreGoal(
        profileId: profileId,
        goalId: created.id,
        operationId: 's2p-restore',
      );
      expect(restored.iconId, 'social_two_people');

      final backup = await repository.exportGoalBackup(profileId);
      final backupGoal = (backup['goals']! as List<Object?>)
          .map((value) => Map<String, Object?>.from(value! as Map))
          .firstWhere((goal) => goal['id'] == created.id);
      expect(backupGoal['iconId'], 'social_two_people');

      final importedDatabase = openMemoryDatabase();
      addTearDown(importedDatabase.close);
      final importedStartup = buildTestRepository(database: importedDatabase);
      final importedProfile = await importedStartup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(importedDatabase, importedProfile.id);
      final importedRepository = repositoryFor(importedDatabase);
      await importedRepository.importGoalBackup(
        profileId: importedProfile.id,
        backup: backup,
      );
      expect(
        (await importedRepository.readGoal(
          profileId: importedProfile.id,
          goalId: created.id,
        ))?.iconId,
        'social_two_people',
        reason: 'Stage-1 must preserve the stored ID; the unknown-ID fallback '
            'renders it safely until Stage 2 restores the registry entry',
      );
    },
  );
}
