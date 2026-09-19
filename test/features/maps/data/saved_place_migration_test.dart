import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../support/test_dependencies.dart';

void main() {
  test('v33 to current (v48) adds Saved Place customization + boundary '
      'columns without losing profile data', () async {
    final sqlite = sqlite3.openInMemory();
    try {
      final version33 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        schemaVersionOverride: 33,
      );
      final profile = await buildTestRepository(
        database: version33,
      ).completeOnboarding();
      await version33.close();

      final version35 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
      );
      expect(
        (await version35.select(version35.localProfiles).get()).single.id,
        profile.id,
      );
      expect(await version35.select(version35.savedPlaces).get(), isEmpty);
      expect(
        (await version35.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        // The current application schema is v48 (the owner-authorized Detailed
        // Content master). This path must preserve the Saved Place migration
        // contract through every later additive upgrade.
        48,
      );
      await version35.close();
    } finally {
      sqlite.close();
    }
  });

  test('failed v35 migration rolls back and preserves valid v33 data', () async {
    final sqlite = sqlite3.openInMemory();
    try {
      final version33 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        schemaVersionOverride: 33,
      );
      final profile = await buildTestRepository(
        database: version33,
      ).completeOnboarding();
      await version33.close();

      final failing = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        injectSavedPlaceMigrationFailure: true,
      );
      await expectLater(
        failing.customSelect('SELECT 1').get(),
        throwsA(isA<StateError>()),
      );
      await failing.close();

      final reopened = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        schemaVersionOverride: 33,
      );
      expect(
        (await reopened.select(reopened.localProfiles).get()).single.id,
        profile.id,
      );
      final table = await reopened
          .customSelect(
            "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = 'saved_places'",
          )
          .getSingle();
      expect(table.read<int>('count'), 0);
      await reopened.close();
    } finally {
      sqlite.close();
    }
  });
}
