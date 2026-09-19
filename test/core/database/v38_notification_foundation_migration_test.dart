import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/test_dependencies.dart';

void main() {
  test(
    'v37 to v39 adds the master default safely and preserves profile + Maps data',
    () async {
      final sqlite = sqlite3.openInMemory();
      try {
        final v37 = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
          schemaVersionOverride: 37,
        );
        final profile = await buildTestRepository(
          database: v37,
        ).completeOnboarding();
        await v37
            .into(v37.mapsPreferences)
            .insert(
              MapsPreferencesCompanion.insert(
                mapType: const drift.Value<String>('terrain'),
                showBoundaries: const drift.Value<bool>(false),
                updatedAtUtc: DateTime.utc(2026, 9, 5),
              ),
            );
        await v37.close();

        final v39 = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        );
        expect(
          (await v39.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          // M7 reconciliation (2026-09-16): the LIVE frozen schema law was 47
          // (M3 projection, M4 contacts/maps, M6 starter-goal closure); the
          // owner-authorized Detailed Content master moved it to 48. The
          // assertion is "the migration lands on the CURRENT schema", so the
          // historical literal 41 is superseded.
          48,
        );
        final names =
            (await v39
                    .customSelect(
                      "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN "
                      "('notification_preferences','reminder_policies','background_work_requests') "
                      'ORDER BY name',
                    )
                    .get())
                .map((row) => row.read<String>('name'))
                .toList();
        expect(names, <String>[
          'background_work_requests',
          'notification_preferences',
          'reminder_policies',
        ]);
        expect(await v39.select(v39.notificationPreferences).get(), isEmpty);
        expect(await v39.select(v39.reminderPolicies).get(), isEmpty);
        expect(await v39.select(v39.backgroundWorkRequests).get(), isEmpty);
        expect(
          (await v39.select(v39.localProfiles).get()).single.id,
          profile.id,
        );
        final maps = (await v39.select(v39.mapsPreferences).get()).single;
        expect(maps.mapType, 'terrain');
        expect(maps.showBoundaries, isFalse);
        await v39.close();
      } finally {
        sqlite.close();
      }
    },
  );

  test(
    'injected v38 failure rolls back all three tables and user_version',
    () async {
      final sqlite = sqlite3.openInMemory();
      try {
        final v37 = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
          schemaVersionOverride: 37,
        );
        final profile = await buildTestRepository(
          database: v37,
        ).completeOnboarding();
        await v37.close();
        final failing = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
          injectNotificationFoundationMigrationFailure: true,
        );
        await expectLater(
          failing.customSelect('SELECT 1').get(),
          throwsA(isA<StateError>()),
        );
        await failing.close();
        final reopened = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
          schemaVersionOverride: 37,
        );
        expect(
          (await reopened.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          37,
        );
        expect(
          (await reopened.select(reopened.localProfiles).get()).single.id,
          profile.id,
        );
        final count = await reopened
            .customSelect(
              "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' "
              "AND name IN ('notification_preferences','reminder_policies','background_work_requests')",
            )
            .getSingle();
        expect(count.read<int>('count'), 0);
        await reopened.close();
      } finally {
        sqlite.close();
      }
    },
  );

  test(
    'fresh v39 database creates exactly three unseeded foundation tables',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      // M7 reconciliation (2026-09-16): frozen schema law was 47, not 41;
      // the owner-authorized Detailed Content master made it 48.
      expect(database.schemaVersion, 48);
      expect(
        await database.select(database.notificationPreferences).get(),
        isEmpty,
      );
      expect(await database.select(database.reminderPolicies).get(), isEmpty);
      expect(
        await database.select(database.backgroundWorkRequests).get(),
        isEmpty,
      );
    },
  );

  test(
    'v41 resumes a partial planning-preferences migration without startup failure',
    () async {
      final sqlite = sqlite3.openInMemory();
      try {
        final v40 = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
          schemaVersionOverride: 40,
        );
        await v40.customSelect('SELECT 1').get();
        final columns = await v40
            .customSelect('PRAGMA table_info(notification_preferences)')
            .get();
        if (!columns.any(
          (row) =>
              row.read<String>('name') == 'weekly_review_reminders_enabled',
        )) {
          await v40.customStatement(
            'ALTER TABLE notification_preferences ADD COLUMN '
            'weekly_review_reminders_enabled INTEGER NOT NULL DEFAULT 0',
          );
        }
        await v40.close();

        final v41 = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        );
        final migrated = await v41
            .customSelect('PRAGMA table_info(notification_preferences)')
            .get();
        expect(
          migrated.map((row) => row.read<String>('name')),
          containsAll(<String>[
            'weekly_review_reminders_enabled',
            'awaiting_report_reminders_enabled',
          ]),
        );
        expect(
          (await v41.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          // M7 reconciliation (2026-09-16): frozen schema law was 47, not
          // 41; the owner-authorized Detailed Content master made it 48.
          48,
        );
        await v41.close();
      } finally {
        sqlite.close();
      }
    },
  );
}
