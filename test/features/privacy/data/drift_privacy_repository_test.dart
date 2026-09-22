import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../support/test_dependencies.dart';

void main() {
  test(
    'AC-W-003..005: lock configuration persists without biometric data',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final repository = DriftPrivacyRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27)),
      );

      expect((await repository.readSettings()).lockEnabled, isFalse);
      await repository.setLockEnabled(true);
      await repository.setNotificationPreviewMode(
        NotificationPreviewMode.showContent,
      );

      final restored = await repository.readSettings();
      expect(restored.lockEnabled, isTrue);
      expect(
        restored.notificationPreviewMode,
        NotificationPreviewMode.showContent,
      );

      final columns = await database
          .customSelect('PRAGMA table_info(privacy_preferences)')
          .get();
      final names = columns.map((row) => row.read<String>('name')).toList();
      expect(names, isNot(contains('biometric_data')));
      expect(names, isNot(contains('pin')));
      expect(names, isNot(contains('token')));
    },
  );

  test('AC-W-018,019: permission audit preserves internal records', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repository = DriftPrivacyRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27)),
    );

    expect(
      (await repository.readPermissionAudit(
        OptionalPermission.contacts,
      )).requestedByApp,
      isFalse,
    );
    await repository.recordPermissionRequested(OptionalPermission.contacts);
    await repository.recordPermissionGranted(OptionalPermission.contacts);

    final audit = await repository.readPermissionAudit(
      OptionalPermission.contacts,
    );
    expect(audit.requestedByApp, isTrue);
    expect(audit.everGranted, isTrue);
    expect(await database.select(database.localProfiles).get(), isEmpty);
  });

  test('Q2: version-1 data upgrades to current schema without loss', () async {
    final sqliteDatabase = sqlite3.openInMemory();
    try {
      final versionOne = AppDatabase.forTesting(
        NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
        schemaVersionOverride: 1,
      );
      final original = await buildTestRepository(
        database: versionOne,
      ).completeOnboarding();
      await versionOne.close();

      final currentVersion = AppDatabase.forTesting(
        NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
      );
      final repository = DriftPrivacyRepository(
        database: currentVersion,
        clock: FixedClock(DateTime.utc(2026, 7, 27)),
      );

      expect(
        (await currentVersion.select(currentVersion.localProfiles).get())
            .single
            .id,
        original.id,
      );
      expect((await repository.readSettings()).lockEnabled, isFalse);
      expect(
        await currentVersion.select(currentVersion.plannerTasks).get(),
        isEmpty,
      );
      final version = await currentVersion
          .customSelect('PRAGMA user_version')
          .getSingle();
      // Delta 4.2R R8: current schema is 24 (30-minute default migration);
      // Pack B1: current schema is 25 (AppearancePreferences table);
      // B3.2: current schema is 27 (direct Task Goal + contact-link columns);
      // MAPS V1: 28 (coordinate columns); VS-11B1: 29 (ledger contact_id);
      // VS-11C1B.3: 30 (additive planner_tasks.is_backup); Maps M1-M2: 34;
      // VS-15 M3 promoted customization: 35; VS16-M1 adds empty notification
      // foundation tables at 38 and the app-owned master at 39.
      // M7 reconciliation (2026-09-16): the frozen product law is now schema
      // 47 (M3 projection, M4 contacts/maps, M6 starter-goal closure). The
      // assertion is the LIVE version, not a historical literal.
      expect(version.read<int>('user_version'), 49);
      await currentVersion.close();
    } finally {
      sqliteDatabase.close();
    }
  });
}
