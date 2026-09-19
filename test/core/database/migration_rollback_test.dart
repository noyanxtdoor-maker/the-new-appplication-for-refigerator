import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/test_dependencies.dart';

void main() {
  test(
    'AC-A-020 / Q0: failed migration rolls back and preserves prior data',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();

      try {
        final versionOne = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 1,
        );
        final repository = buildTestRepository(database: versionOne);
        final original = await repository.completeOnboarding();
        await versionOne.close();

        final failingVersionTwo = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 2,
          injectMigrationFailure: true,
        );
        await expectLater(
          failingVersionTwo.select(failingVersionTwo.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionTwo.close();

        final reopenedVersionOne = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 1,
        );
        final profiles = await reopenedVersionOne
            .select(reopenedVersionOne.localProfiles)
            .get();
        final userVersion = await reopenedVersionOne
            .customSelect('PRAGMA user_version')
            .getSingle();
        final privacyTable = await reopenedVersionOne
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type = 'table' AND name = 'privacy_preferences'",
            )
            .getSingle();

        expect(profiles, hasLength(1));
        expect(profiles.single.id, original.id);
        expect(userVersion.read<int>('user_version'), 1);
        expect(privacyTable.read<int>('count'), 0);
        await reopenedVersionOne.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-C-011,019 / Q2: v2 upgrades to schema v3 without profile loss',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();

      try {
        final versionTwo = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 2,
        );
        final original = await buildTestRepository(
          database: versionTwo,
        ).completeOnboarding();
        await versionTwo.close();

        final versionThree = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 3,
        );
        final profiles = await versionThree
            .select(versionThree.localProfiles)
            .get();
        final taskRows = await versionThree
            .select(versionThree.plannerTasks)
            .get();
        final userVersion = await versionThree
            .customSelect('PRAGMA user_version')
            .getSingle();

        expect(profiles.single.id, original.id);
        expect(taskRows, isEmpty);
        expect(userVersion.read<int>('user_version'), 3);
        await versionThree.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-C-019 / Q2: failed v3 migration preserves the valid v2 database',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();

      try {
        final versionTwo = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 2,
        );
        final original = await buildTestRepository(
          database: versionTwo,
        ).completeOnboarding();
        await versionTwo.close();

        final failingVersionThree = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 3,
          injectTaskMigrationFailure: true,
        );
        await expectLater(
          failingVersionThree.select(failingVersionThree.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionThree.close();

        final reopenedVersionTwo = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 2,
        );
        final profiles = await reopenedVersionTwo
            .select(reopenedVersionTwo.localProfiles)
            .get();
        final userVersion = await reopenedVersionTwo
            .customSelect('PRAGMA user_version')
            .getSingle();
        final taskTable = await reopenedVersionTwo
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type='table' AND name='planner_tasks'",
            )
            .getSingle();

        expect(profiles.single.id, original.id);
        expect(userVersion.read<int>('user_version'), 2);
        expect(taskTable.read<int>('count'), 0);
        await reopenedVersionTwo.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-E-019,024 / Q2: v3 upgrades to schema v4 without profile or Task loss',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();

      try {
        final versionThree = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 3,
        );
        final original = await buildTestRepository(
          database: versionThree,
        ).completeOnboarding();
        await versionThree.close();

        final versionFour = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 4,
        );
        final profiles = await versionFour
            .select(versionFour.localProfiles)
            .get();
        final eventRows = await versionFour
            .select(versionFour.calendarEvents)
            .get();
        final userVersion = await versionFour
            .customSelect('PRAGMA user_version')
            .getSingle();

        expect(profiles.single.id, original.id);
        expect(eventRows, isEmpty);
        expect(userVersion.read<int>('user_version'), 4);
        await versionFour.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-E-024 / Q2: failed v4 migration preserves the valid v3 database',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();

      try {
        final versionThree = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 3,
        );
        final original = await buildTestRepository(
          database: versionThree,
        ).completeOnboarding();
        await versionThree.close();

        final failingVersionFour = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 4,
          injectCalendarEventMigrationFailure: true,
        );
        await expectLater(
          failingVersionFour.select(failingVersionFour.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionFour.close();

        final reopenedVersionThree = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 3,
        );
        final profiles = await reopenedVersionThree
            .select(reopenedVersionThree.localProfiles)
            .get();
        final userVersion = await reopenedVersionThree
            .customSelect('PRAGMA user_version')
            .getSingle();
        final eventTable = await reopenedVersionThree
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type='table' AND name='calendar_events'",
            )
            .getSingle();

        expect(profiles.single.id, original.id);
        expect(userVersion.read<int>('user_version'), 3);
        expect(eventTable.read<int>('count'), 0);
        await reopenedVersionThree.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-F-018 / Q2: v4 upgrades to schema v5 without prior-data loss',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionFour = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 4,
        );
        final original = await buildTestRepository(
          database: versionFour,
        ).completeOnboarding();
        await versionFour.close();

        final versionFive = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 5,
        );
        expect(
          (await versionFive.select(versionFive.localProfiles).get()).single.id,
          original.id,
        );
        expect(
          await versionFive.select(versionFive.taskEventLinks).get(),
          isEmpty,
        );
        expect(
          (await versionFive.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          5,
        );
        await versionFive.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-F-018 / Q2: failed v5 migration preserves the valid v4 database',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionFour = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 4,
        );
        final original = await buildTestRepository(
          database: versionFour,
        ).completeOnboarding();
        await versionFour.close();

        final failingVersionFive = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 5,
          injectTaskEventLinkMigrationFailure: true,
        );
        await expectLater(
          failingVersionFive.select(failingVersionFive.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionFive.close();

        final reopenedVersionFour = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 4,
        );
        expect(
          (await reopenedVersionFour
                  .select(reopenedVersionFour.localProfiles)
                  .get())
              .single
              .id,
          original.id,
        );
        expect(
          (await reopenedVersionFour
                  .customSelect('PRAGMA user_version')
                  .getSingle())
              .read<int>('user_version'),
          4,
        );
        final linkTable = await reopenedVersionFour
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type='table' AND name='task_event_links'",
            )
            .getSingle();
        expect(linkTable.read<int>('count'), 0);
        await reopenedVersionFour.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test('AC-G-016 / AC-H-020 / Q2: v5 upgrades to schema v6 without prior-data '
      'loss', () async {
    final sqliteDatabase = sqlite3.openInMemory();
    try {
      final versionFive = AppDatabase.forTesting(
        NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        schemaVersionOverride: 5,
      );
      final original = await buildTestRepository(
        database: versionFive,
      ).completeOnboarding();
      await versionFive.close();

      final versionSix = AppDatabase.forTesting(
        NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        schemaVersionOverride: 6,
      );
      expect(
        (await versionSix.select(versionSix.localProfiles).get()).single.id,
        original.id,
      );
      expect(await versionSix.select(versionSix.outcomeReports).get(), isEmpty);
      expect(
        await versionSix.select(versionSix.activityLedgerEntries).get(),
        isEmpty,
      );
      expect(
        (await versionSix.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        6,
      );
      await versionSix.close();
    } finally {
      sqliteDatabase.close();
    }
  });

  test('AC-G-016 / AC-H-020 / Q2: failed v6 migration preserves the valid v5 '
      'database', () async {
    final sqliteDatabase = sqlite3.openInMemory();
    try {
      final versionFive = AppDatabase.forTesting(
        NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        schemaVersionOverride: 5,
      );
      final original = await buildTestRepository(
        database: versionFive,
      ).completeOnboarding();
      await versionFive.close();

      final failingVersionSix = AppDatabase.forTesting(
        NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        schemaVersionOverride: 6,
        injectOutcomeReportingMigrationFailure: true,
      );
      await expectLater(
        failingVersionSix.select(failingVersionSix.localProfiles).get(),
        throwsA(isA<StateError>()),
      );
      await failingVersionSix.close();

      final reopenedVersionFive = AppDatabase.forTesting(
        NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        schemaVersionOverride: 5,
      );
      expect(
        (await reopenedVersionFive
                .select(reopenedVersionFive.localProfiles)
                .get())
            .single
            .id,
        original.id,
      );
      expect(
        (await reopenedVersionFive
                .customSelect('PRAGMA user_version')
                .getSingle())
            .read<int>('user_version'),
        5,
      );
      final reportTable = await reopenedVersionFive
          .customSelect(
            "SELECT COUNT(*) AS count FROM sqlite_master "
            "WHERE type='table' AND name='outcome_reports'",
          )
          .getSingle();
      final ledgerTable = await reopenedVersionFive
          .customSelect(
            "SELECT COUNT(*) AS count FROM sqlite_master "
            "WHERE type='table' AND name='activity_ledger_entries'",
          )
          .getSingle();
      expect(reportTable.read<int>('count'), 0);
      expect(ledgerTable.read<int>('count'), 0);
      await reopenedVersionFive.close();
    } finally {
      sqliteDatabase.close();
    }
  });

  test(
    'AC-B-004 / Q2: v6 upgrades to schema v7 without prior-data loss',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionSix = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 6,
        );
        final original = await buildTestRepository(
          database: versionSix,
        ).completeOnboarding();
        await versionSix.close();

        final versionSeven = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 7,
        );
        expect(
          (await versionSeven.select(versionSeven.localProfiles).get())
              .single
              .id,
          original.id,
        );
        expect(
          await versionSeven
              .select(versionSeven.weeklyIndicatorTargetRevisions)
              .get(),
          isEmpty,
        );
        expect(
          (await versionSeven.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          7,
        );
        await versionSeven.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-B-004 / Q2: failed v7 migration preserves the valid v6 database',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionSix = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 6,
        );
        final original = await buildTestRepository(
          database: versionSix,
        ).completeOnboarding();
        await versionSix.close();

        final failingVersionSeven = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 7,
          injectIndicatorMigrationFailure: true,
        );
        await expectLater(
          failingVersionSeven.select(failingVersionSeven.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionSeven.close();

        final reopenedVersionSix = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 6,
        );
        expect(
          (await reopenedVersionSix
                  .select(reopenedVersionSix.localProfiles)
                  .get())
              .single
              .id,
          original.id,
        );
        expect(
          (await reopenedVersionSix
                  .customSelect('PRAGMA user_version')
                  .getSingle())
              .read<int>('user_version'),
          6,
        );
        final targetTable = await reopenedVersionSix
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type='table' AND "
              "name='weekly_indicator_target_revisions'",
            )
            .getSingle();
        expect(targetTable.read<int>('count'), 0);
        await reopenedVersionSix.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-I-001,019 / Q2: v7 upgrades to schema v8 without prior-data loss',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionSeven = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 7,
        );
        final original = await buildTestRepository(
          database: versionSeven,
        ).completeOnboarding();
        await versionSeven.close();

        final versionEight = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 8,
        );
        final profile =
            (await versionEight.select(versionEight.localProfiles).get())
                .single;
        expect(profile.id, original.id);
        expect(profile.timeZoneId, isNull);
        expect(
          await versionEight.select(versionEight.weeklyPlans).get(),
          isEmpty,
        );
        expect(
          (await versionEight.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          8,
        );
        await versionEight.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'AC-I-003,019 / Q2: failed v8 migration rolls back all planning tables',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionSeven = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 7,
        );
        final original = await buildTestRepository(
          database: versionSeven,
        ).completeOnboarding();
        await versionSeven.close();

        final failingVersionEight = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 8,
          injectWeeklyPlanningMigrationFailure: true,
        );
        await expectLater(
          failingVersionEight.select(failingVersionEight.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionEight.close();

        final reopenedVersionSeven = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 7,
        );
        expect(
          (await reopenedVersionSeven
                  .select(reopenedVersionSeven.localProfiles)
                  .get())
              .single
              .id,
          original.id,
        );
        expect(
          (await reopenedVersionSeven
                  .customSelect('PRAGMA user_version')
                  .getSingle())
              .read<int>('user_version'),
          7,
        );
        final planTable = await reopenedVersionSeven
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type='table' AND name='weekly_plans'",
            )
            .getSingle();
        expect(planTable.read<int>('count'), 0);
        await reopenedVersionSeven.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'VS08-CORRECTION / Q2: v8 upgrades to schema v9 without prior-data loss',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionEight = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 8,
        );
        final original = await buildTestRepository(
          database: versionEight,
        ).completeOnboarding();
        await versionEight.close();

        final versionNine = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 9,
        );
        expect(
          (await versionNine.select(versionNine.localProfiles).get()).single.id,
          original.id,
        );
        expect(
          await versionNine.select(versionNine.activityTypes).get(),
          isEmpty,
        );
        expect(
          await versionNine
              .select(versionNine.activityTypeIndicatorMappings)
              .get(),
          isEmpty,
        );
        expect(
          await versionNine.select(versionNine.plannerPreferences).get(),
          isEmpty,
        );
        expect(
          (await versionNine.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          9,
        );
        await versionNine.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'VS08-CORRECTION / Q2: failed v9 migration preserves valid v8 database',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionEight = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 8,
        );
        final original = await buildTestRepository(
          database: versionEight,
        ).completeOnboarding();
        await versionEight.close();

        final failingVersionNine = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 9,
          injectPlannerCorrectionMigrationFailure: true,
        );
        await expectLater(
          failingVersionNine.select(failingVersionNine.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionNine.close();

        final reopenedVersionEight = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 8,
        );
        expect(
          (await reopenedVersionEight
                  .select(reopenedVersionEight.localProfiles)
                  .get())
              .single
              .id,
          original.id,
        );
        expect(
          (await reopenedVersionEight
                  .customSelect('PRAGMA user_version')
                  .getSingle())
              .read<int>('user_version'),
          8,
        );
        final typeTable = await reopenedVersionEight
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type='table' AND name='activity_types'",
            )
            .getSingle();
        expect(typeTable.read<int>('count'), 0);
        await reopenedVersionEight.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'VS08-OWNER / Q2: v9 upgrades through schema v13 with safe Planner defaults',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionNine = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 9,
        );
        final original = await buildTestRepository(
          database: versionNine,
        ).completeOnboarding();
        await versionNine
            .into(versionNine.plannerPreferences)
            .insert(
              PlannerPreferencesCompanion.insert(
                profileId: original.id,
                updatedAtUtc: DateTime.utc(2026, 7, 29),
              ),
            );
        await _makeHistoricalV9Schema(versionNine);
        await versionNine.close();

        final versionTen = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        );
        final preference =
            (await versionTen.select(versionTen.plannerPreferences).get())
                .single;
        expect(preference.profileId, original.id);
        expect(preference.preferredPresentation, 'day');
        expect(preference.showEvents, isTrue);
        expect(preference.showBackupEvents, isTrue);
        expect(preference.showTasks, isTrue);
        expect(preference.showCompletedTasks, isFalse);
        expect(preference.timelineHourHeight, 60);
        expect(preference.eventColorPreferencesJson, isNull);
        expect(
          (await versionTen.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          // This legacy fixture must upgrade through M3's additive v34 Saved
          // Places schema, the v35 customization columns, M6.1's additive v36
          // boundary columns, M6.2's additive v37 Maps preferences table, and
          // M1's additive v38 notification-foundation tables and the v39
          // app-owned master field and v40 Snooze duration without losing
          // earlier owner data. VS16 M7 then advances to v47 by adding the five
          // typed Detailed-notification columns to the existing
          // notification_preferences row (additive, boolean-only), and the
          // owner-authorized v48 then adds the Detailed Content master as one
          // more additive boolean column on that same row.
          48,
        );
        final taskColumns = await versionTen
            .customSelect('PRAGMA table_info(planner_tasks)')
            .get();
        expect(
          taskColumns.map((row) => row.read<String>('name')),
          contains('people_json'),
        );
        await versionTen.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'VS08-OWNER / Q2: failed v10 migration preserves the valid v9 database',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final versionNine = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 9,
        );
        final original = await buildTestRepository(
          database: versionNine,
        ).completeOnboarding();
        await _makeHistoricalV9Schema(versionNine);
        await versionNine.close();

        final failingVersionTen = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          injectPlannerExperienceMigrationFailure: true,
        );
        await expectLater(
          failingVersionTen.select(failingVersionTen.localProfiles).get(),
          throwsA(isA<StateError>()),
        );
        await failingVersionTen.close();

        final reopenedVersionNine = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 9,
        );
        expect(
          (await reopenedVersionNine
                  .select(reopenedVersionNine.localProfiles)
                  .get())
              .single
              .id,
          original.id,
        );
        expect(
          (await reopenedVersionNine
                  .customSelect('PRAGMA user_version')
                  .getSingle())
              .read<int>('user_version'),
          9,
        );
        final columns = await reopenedVersionNine
            .customSelect('PRAGMA table_info(planner_preferences)')
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          isNot(contains('timeline_hour_height')),
        );
        await reopenedVersionNine.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'Prompt A: v15 to v16 removes Commitment metadata without deleting Events or Tasks',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final version15 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 15,
        );
        final profile = await buildTestRepository(
          database: version15,
        ).completeOnboarding();
        final createdAt = DateTime.utc(2026, 7, 27, 12);
        await version15
            .into(version15.plannerTasks)
            .insert(
              PlannerTasksCompanion.insert(
                id: 'prompt-a-task',
                profileId: profile.id,
                title: 'Preserve this task',
                dueDate: const drift.Value<String?>('2026-07-29'),
                createdAtUtc: createdAt,
                updatedAtUtc: createdAt,
              ),
            );
        await version15
            .into(version15.calendarEvents)
            .insert(
              CalendarEventsCompanion.insert(
                id: 'prompt-a-event',
                profileId: profile.id,
                title: 'Preserve this event',
                timing: 'allDay',
                startDate: '2026-07-29',
                createdAtUtc: createdAt,
                updatedAtUtc: createdAt,
              ),
            );
        for (final tableName in <String>[
          'indicator_commitment_links',
          'weekly_plan_commitments',
          'weekly_plan_review_indicator_snapshots',
          'weekly_plan_reviews',
          'weekly_plan_task_carryover_decisions',
        ]) {
          await version15.customStatement(
            'CREATE TABLE $tableName (id TEXT PRIMARY KEY)',
          );
        }
        await version15.close();

        final current = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        );
        expect(
          (await current.select(current.plannerTasks).get()).single.title,
          'Preserve this task',
        );
        expect(
          (await current.select(current.calendarEvents).get()).single.title,
          'Preserve this event',
        );
        for (final tableName in <String>[
          'indicator_commitment_links',
          'weekly_plan_commitments',
          'weekly_plan_review_indicator_snapshots',
          'weekly_plan_reviews',
          'weekly_plan_task_carryover_decisions',
        ]) {
          final table = await current
              .customSelect(
                "SELECT COUNT(*) AS count FROM sqlite_master "
                "WHERE type = 'table' AND name = '$tableName'",
              )
              .getSingle();
          expect(table.read<int>('count'), 0, reason: tableName);
        }
        final version = await current
            .customSelect('PRAGMA user_version')
            .getSingle();
        // The historical v15 database upgrades through every current additive
        // migration; v31 itself remains explicitly covered below.
        // VS-15 M6.2 advanced to v37; M1 then adds three empty foundation
        // tables at v38; v39 adds master state; v40 adds Snooze duration;
        // VS16 M7 advances to v47 with the five typed Detailed-notification
        // columns on the existing notification_preferences row, and the
        // owner-authorized v48 adds the Detailed Content master to that row.
        expect(version.read<int>('user_version'), 48);
        final taskColumns = await current
            .customSelect('PRAGMA table_info(planner_tasks)')
            .get();
        expect(
          taskColumns.map((row) => row.read<String>('name')),
          contains('is_backup'),
          reason: 'v30 must add planner_tasks.is_backup',
        );
        // VS-11C1B.3 §22: old Tasks migrate with is_backup = false (no
        // backfill; Backup is opt-in).
        final migratedTask = await current
            .customSelect(
              'SELECT is_backup FROM planner_tasks '
              'WHERE title = \'Preserve this task\'',
            )
            .getSingle();
        expect(migratedTask.read<int>('is_backup'), 0);
        await current.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'v30 through current (v37) adds Contact lifecycle fields without backfill',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final version30 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 30,
        );
        final profile = await buildTestRepository(
          database: version30,
        ).completeOnboarding();
        final createdAt = DateTime.utc(2026, 8, 3, 12);
        await version30
            .into(version30.contacts)
            .insert(
              ContactsCompanion.insert(
                id: 'legacy-contact',
                profileId: profile.id,
                displayName: 'Legacy Contact',
                createdAtUtc: createdAt,
                updatedAtUtc: createdAt,
              ),
            );
        await version30.customStatement(
          'ALTER TABLE contacts DROP COLUMN last_viewed_at_utc',
        );
        await version30.customStatement(
          'ALTER TABLE contacts DROP COLUMN deleted_at_utc',
        );
        await version30.customStatement(
          'ALTER TABLE contact_methods DROP COLUMN receives_texts',
        );
        await version30.customStatement(
          'ALTER TABLE contact_methods DROP COLUMN has_whats_app',
        );
        await version30.customStatement('PRAGMA user_version = 30');
        await version30.close();

        final version31 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 31,
        );
        final version31Columns = await version31
            .customSelect('PRAGMA table_info(contacts)')
            .get();
        expect(
          version31Columns.map((row) => row.read<String>('name')),
          contains('last_viewed_at_utc'),
        );
        expect(
          version31Columns.map((row) => row.read<String>('name')),
          isNot(contains('deleted_at_utc')),
        );
        final contact =
            (await version31.select(version31.contacts).get()).single;
        expect(contact.id, 'legacy-contact');
        expect(contact.lastViewedAtUtc, isNull);
        expect(
          (await version31.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          31,
        );
        await version31.close();

        final version33 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        );
        final currentColumns = await version33
            .customSelect('PRAGMA table_info(contacts)')
            .get();
        expect(
          currentColumns.map((row) => row.read<String>('name')),
          containsAll(<String>['last_viewed_at_utc', 'deleted_at_utc']),
        );
        final methodColumns = await version33
            .customSelect('PRAGMA table_info(contact_methods)')
            .get();
        expect(
          methodColumns.map((row) => row.read<String>('name')),
          containsAll(<String>['receives_texts', 'has_whats_app']),
        );
        final currentContact =
            (await version33.select(version33.contacts).get()).single;
        expect(currentContact.lastViewedAtUtc, isNull);
        expect(currentContact.deletedAtUtc, isNull);
        expect(
          (await version33.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          48,
        );
        await version33.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'v34 to v35 adds Saved Place customization columns with a deterministic default (reaching v37)',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final version34 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 34,
        );
        final profile = await buildTestRepository(
          database: version34,
        ).completeOnboarding();
        final createdAt = DateTime.utc(2026, 9, 2, 1);
        await version34
            .into(version34.savedPlaces)
            .insert(
              SavedPlacesCompanion.insert(
                id: 'place-legacy',
                profileId: profile.id,
                label: 'Legacy Place',
                latitude: 14.6,
                longitude: 121.0,
                createdAtUtc: createdAt,
                updatedAtUtc: createdAt,
              ),
            );
        // Simulate the true v34 shape (no customization columns).
        for (final column in <String>[
          'marker_mode',
          'standard_category',
          'custom_emoji',
          'marker_color',
        ]) {
          await version34.customStatement(
            'ALTER TABLE saved_places DROP COLUMN $column',
          );
        }
        await version34.customStatement('PRAGMA user_version = 34');
        await version34.close();

        final version35 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        );
        final place =
            (await version35.select(version35.savedPlaces).get()).single;
        expect(place.id, 'place-legacy');
        expect(place.label, 'Legacy Place');
        expect(place.markerMode, 'standard');
        expect(place.standardCategory, isNull);
        expect(place.customEmoji, isNull);
        expect(place.markerColor, '#175A8F');
        expect(
          (await version35.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          48,
        );
        final columns = await version35
            .customSelect('PRAGMA table_info(saved_places)')
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          containsAll(<String>[
            'marker_mode',
            'standard_category',
            'custom_emoji',
            'marker_color',
          ]),
        );
        await version35.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'failed v35 customization migration rolls back and preserves valid v34 data',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final version34 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 34,
        );
        final profile = await buildTestRepository(
          database: version34,
        ).completeOnboarding();
        final createdAt = DateTime.utc(2026, 9, 2, 1);
        await version34
            .into(version34.savedPlaces)
            .insert(
              SavedPlacesCompanion.insert(
                id: 'place-legacy',
                profileId: profile.id,
                label: 'Legacy Place',
                latitude: 14.6,
                longitude: 121.0,
                createdAtUtc: createdAt,
                updatedAtUtc: createdAt,
              ),
            );
        for (final column in <String>[
          'marker_mode',
          'standard_category',
          'custom_emoji',
          'marker_color',
        ]) {
          await version34.customStatement(
            'ALTER TABLE saved_places DROP COLUMN $column',
          );
        }
        await version34.customStatement('PRAGMA user_version = 34');
        await version34.close();

        final failing = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          injectSavedPlaceCustomizationMigrationFailure: true,
        );
        await expectLater(
          failing.select(failing.savedPlaces).get(),
          throwsA(isA<StateError>()),
        );
        await failing.close();

        final reopened = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 34,
        );
        // The v34 database predates the customization columns, so read the
        // preserved row through SQL (Drift's v35 table shape expects the new
        // columns, which are correctly absent on a clean v34 rollback).
        final preserved = await reopened
            .customSelect(
              "SELECT id, label FROM saved_places WHERE id = 'place-legacy'",
            )
            .getSingle();
        expect(preserved.read<String>('id'), 'place-legacy');
        expect(preserved.read<String>('label'), 'Legacy Place');
        final column = await reopened
            .customSelect('PRAGMA table_info(saved_places)')
            .get();
        expect(
          column.map((row) => row.read<String>('name')),
          isNot(contains('marker_mode')),
        );
        expect(
          (await reopened.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          34,
        );
        await reopened.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );

  test(
    'M6F v44 to current deduplicates memberships and enforces invariants',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final version44 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 44,
        );
        final profile = await buildTestRepository(
          database: version44,
        ).completeOnboarding();
        final createdAt = DateTime.utc(2026, 9, 8);
        await version44
            .into(version44.goals)
            .insert(
              GoalsCompanion.insert(
                id: 'm6f-migration-goal',
                profileId: profile.id,
                role: 'weekly',
                activeSlotIndex: const drift.Value<int?>(null),
                title: 'Migration Goal',
                status: 'active',
                createdAtUtc: createdAt,
                updatedAtUtc: createdAt,
              ),
            );
        await version44
            .into(version44.weeklyPlans)
            .insert(
              WeeklyPlansCompanion.insert(
                id: 'm6f-migration-plan',
                profileId: profile.id,
                periodStartDate: '2026-09-07',
                periodEndDate: '2026-09-13',
                timeZoneId: 'Asia/Manila',
                state: 'draft',
                createdAtUtc: createdAt,
                updatedAtUtc: createdAt,
              ),
            );
        for (final id in <String>[
          'm6f-membership-first',
          'm6f-membership-copy',
        ]) {
          await version44
              .into(version44.weeklyPlanGoalMemberships)
              .insert(
                WeeklyPlanGoalMembershipsCompanion.insert(
                  id: id,
                  profileId: profile.id,
                  weeklyPlanId: 'm6f-migration-plan',
                  goalId: 'm6f-migration-goal',
                  slotOrder: 2,
                  createdAtUtc: createdAt,
                ),
              );
        }
        await version44.close();

        final version45 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        );
        final rows = await version45
            .customSelect(
              "SELECT id FROM weekly_plan_goal_memberships "
              "WHERE weekly_plan_id = 'm6f-migration-plan' "
              "AND goal_id = 'm6f-migration-goal'",
            )
            .get();
        expect(rows, hasLength(1));
        expect(rows.single.read<String>('id'), 'm6f-membership-first');
        final index = await version45
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master "
              "WHERE type = 'index' "
              "AND name = 'weekly_plan_goal_membership_unique'",
            )
            .getSingle();
        expect(index.read<int>('count'), 1);
        expect(
          (await version45.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          48,
        );
        await version45.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );
}

Future<void> _makeHistoricalV9Schema(AppDatabase database) async {
  for (final statement in <String>[
    'ALTER TABLE calendar_events DROP COLUMN is_backup_appointment',
    'ALTER TABLE calendar_events DROP COLUMN backup_for_event_id',
    'ALTER TABLE calendar_events DROP COLUMN backup_relationship_provenance',
    'ALTER TABLE calendar_event_exceptions DROP COLUMN is_backup_appointment',
    'ALTER TABLE calendar_event_exceptions DROP COLUMN backup_for_event_id',
    'ALTER TABLE calendar_event_exceptions DROP COLUMN '
        'backup_relationship_provenance',
    'ALTER TABLE planner_preferences DROP COLUMN preferred_presentation',
    'ALTER TABLE planner_preferences DROP COLUMN show_events',
    'ALTER TABLE planner_preferences DROP COLUMN show_backup_events',
    'ALTER TABLE planner_preferences DROP COLUMN show_tasks',
    'ALTER TABLE planner_preferences DROP COLUMN show_completed_tasks',
    'ALTER TABLE planner_preferences DROP COLUMN timeline_hour_height',
  ]) {
    await database.customStatement(statement);
  }
}
