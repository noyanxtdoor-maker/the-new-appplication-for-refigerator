import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';

import '../../../support/test_dependencies.dart';

/// VS16 M7 corrective persistence repair — TYPED storage.
///
/// These five options were briefly stored as a namespaced key
/// (`notificationDetailedContent`) inside the SHARED planner presentation JSON
/// document. That design was reproduced as an actual data-loss defect: the
/// planner document writers rebuild that JSON from only the keys they
/// understand, so an ordinary Event Color save silently dropped the key and the
/// switches reverted to all-TRUE.
///
/// The options now live in TYPED columns on the existing
/// `notification_preferences` row (schema v47). These tests prove:
///   * schema v47 is the live version and carries exactly five new columns,
///   * a round trip returns exactly what was written,
///   * a read never writes and a read of a missing row still yields all-TRUE,
///   * writing the options leaves the shared planner JSON document completely
///     untouched (the structural cross-feature isolation this repair buys),
///   * writing the options leaves every OTHER notification preference intact,
///   * a profile with no row is created on first write, exactly once.
void main() {
  final clock = FixedClock(DateTime.utc(2026, 9, 12, 12));

  Future<AppDatabase> open() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    return database;
  }

  DetailedContentPreferencesStore storeFor(AppDatabase database) =>
      DetailedContentPreferencesStore(database: database, clock: clock);

  /// Creates the primary profile row the store keys against.
  Future<String> seedProfile(AppDatabase database) async {
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    return profile.id;
  }

  /// The raw shared planner presentation document, which the notification
  /// store must never touch.
  Future<String?> plannerJson(AppDatabase database, String profileId) async {
    final row = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    return row?.eventColorPreferencesJson;
  }

  Future<NotificationPreferenceRow?> notificationRow(
    AppDatabase database,
    String profileId,
  ) async {
    return (database.select(
      database.notificationPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
  }

  group('D25 — schema v47 (v48 after the Detailed Content master)', () {
    test('the live schema version is 48', () async {
      final database = await open();
      final row = await database
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(row.read<int>('user_version'), 49);
    });

    test('the five detailed columns exist exactly once', () async {
      final database = await open();
      final rows = await database
          .customSelect('PRAGMA table_info(notification_preferences)')
          .get();
      final names = rows.map((row) => row.read<String>('name')).toList();

      for (final column in <String>[
        'detailed_show_title',
        'detailed_show_description',
        'detailed_show_time',
        'detailed_show_contacts',
        'detailed_show_location',
      ]) {
        expect(
          names.where((name) => name == column),
          hasLength(1),
          reason: '$column must exist exactly once',
        );
      }
    });

    test('reading a fresh profile writes nothing', () async {
      final database = await open();
      final profileId = await seedProfile(database);
      expect(await notificationRow(database, profileId), isNull);

      final read = await storeFor(database).read(profileId);

      expect(read, DetailedContentPreferences.defaults);
      expect(read.showTitle, isTrue);
      expect(read.showDescription, isTrue);
      expect(read.showTime, isTrue);
      expect(read.showContacts, isTrue);
      expect(read.showLocation, isTrue);
      // A read is never a write: no notification row is created.
      expect(await notificationRow(database, profileId), isNull);
    });
  });

  group('D26 — round trip', () {
    test('every field survives a write/read cycle', () async {
      final database = await open();
      final profileId = await seedProfile(database);
      final subject = storeFor(database);

      const written = DetailedContentPreferences(
        showTitle: false,
        showDescription: true,
        showTime: false,
        showContacts: false,
        showLocation: true,
      );
      await subject.write(profileId, written);

      expect(await subject.read(profileId), written);
    });

    test(
      'the all-off combination round trips as an explicit empty state',
      () async {
        final database = await open();
        final profileId = await seedProfile(database);
        final subject = storeFor(database);

        const written = DetailedContentPreferences(
          showTitle: false,
          showDescription: false,
          showTime: false,
          showContacts: false,
          showLocation: false,
        );
        await subject.write(profileId, written);

        final read = await subject.read(profileId);
        expect(read, written);
        expect(read.isEmpty, isTrue);
      },
    );

    test(
      'the value is stored in the typed column, not in the planner JSON',
      () async {
        final database = await open();
        final profileId = await seedProfile(database);
        await storeFor(database).write(
          profileId,
          const DetailedContentPreferences(showLocation: false),
        );

        final row = await notificationRow(database, profileId);
        expect(row, isNotNull);
        expect(row!.detailedShowTitle, isTrue);
        expect(row.detailedShowLocation, isFalse);
        // The structural proof: nothing was written to the shared JSON document.
        expect(await plannerJson(database, profileId), isNull);
      },
    );
  });

  group('D27 — cross-feature isolation', () {
    test(
      'a write leaves the shared planner JSON byte-for-byte untouched',
      () async {
        final database = await open();
        final profileId = await seedProfile(database);

        // A document owned entirely by the planner feature, including an unknown
        // forward-compatibility key and a legacy namespaced key from the
        // disqualified design. Neither may be rewritten by a notification save.
        const existing =
            '{"events":{"default":3},"someFutureOwnerKey":[1,"two",true],'
            '"notificationDetailedContent":{"showTitle":false}}';
        await database
            .into(database.plannerPreferences)
            .insertOnConflictUpdate(
              PlannerPreferencesCompanion.insert(
                profileId: profileId,
                eventColorPreferencesJson: const Value<String?>(existing),
                updatedAtUtc: clock.nowUtc(),
              ),
            );

        await storeFor(database).write(
          profileId,
          const DetailedContentPreferences(showContacts: false),
        );

        // The obsolete namespaced key is deliberately NOT cleaned up: rewriting
        // planner data to tidy an unused key would risk real planner content.
        expect(await plannerJson(database, profileId), existing);
      },
    );

    test('a write leaves every other notification preference intact', () async {
      final database = await open();
      final profileId = await seedProfile(database);

      await database
          .into(database.notificationPreferences)
          .insertOnConflictUpdate(
            NotificationPreferencesCompanion.insert(
              profileId: profileId,
              systemNotificationsEnabled: const Value(true),
              eventRemindersEnabled: const Value(true),
              taskRemindersEnabled: const Value(false),
              weeklyReviewRemindersEnabled: const Value(true),
              defaultTaskReminderMinutes: const Value(25),
              snoozeDurationMinutes: const Value(15),
              quietHoursEnabled: const Value(true),
              quietStartMinute: const Value(1320),
              quietEndMinute: const Value(420),
              updatedAtUtc: DateTime.utc(2026, 9, 10, 8),
            ),
          );

      await storeFor(
        database,
      ).write(profileId, const DetailedContentPreferences(showTime: false));

      final row = await notificationRow(database, profileId);
      expect(row!.systemNotificationsEnabled, isTrue);
      expect(row.eventRemindersEnabled, isTrue);
      expect(row.taskRemindersEnabled, isFalse);
      expect(row.weeklyReviewRemindersEnabled, isTrue);
      expect(row.defaultTaskReminderMinutes, 25);
      expect(row.snoozeDurationMinutes, 15);
      expect(row.quietHoursEnabled, isTrue);
      expect(row.quietStartMinute, 1320);
      expect(row.quietEndMinute, 420);
      // And the field that WAS written changed.
      expect(row.detailedShowTime, isFalse);
      expect(row.detailedShowTitle, isTrue);
    });
  });

  group('D28 — fail-closed reads', () {
    test('a profile with no notification row reads as all-TRUE', () async {
      final database = await open();
      final profileId = await seedProfile(database);
      expect(await notificationRow(database, profileId), isNull);

      expect(
        await storeFor(database).read(profileId),
        DetailedContentPreferences.defaults,
      );
    });

    test('an unknown profile reads as all-TRUE', () async {
      final database = await open();
      expect(
        await storeFor(database).read('no-such-profile'),
        DetailedContentPreferences.defaults,
      );
    });
  });

  group('D29 — write discipline', () {
    test('the first write creates exactly one row', () async {
      final database = await open();
      final profileId = await seedProfile(database);
      final subject = storeFor(database);

      await subject.write(profileId, const DetailedContentPreferences());
      await subject.write(
        profileId,
        const DetailedContentPreferences(showTitle: false),
      );

      final rows = await (database.select(
        database.notificationPreferences,
      )..where((table) => table.profileId.equals(profileId))).get();
      expect(rows, hasLength(1));
      expect(rows.single.detailedShowTitle, isFalse);
    });

    test('a write does not touch the shared planner JSON document', () async {
      final database = await open();
      final profileId = await seedProfile(database);
      final before = await plannerJson(database, profileId);

      await storeFor(database).write(
        profileId,
        const DetailedContentPreferences(showDescription: false),
      );

      expect(await plannerJson(database, profileId), before);
    });
  });
}
