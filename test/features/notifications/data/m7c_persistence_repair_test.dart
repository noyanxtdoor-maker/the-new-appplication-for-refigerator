// VS16 M7 CORRECTIVE PERSISTENCE REPAIR — FAIL-FIRST COVERAGE.
//
// This file encodes the OWNER'S TARGET CONTRACT (schema v47: the five Detailed
// notification content preferences live in TYPED columns on the existing
// `notification_preferences` table). It is written BEFORE the production fix
// on purpose: against the current v46 JSON-piggyback implementation these
// tests MUST FAIL, and the failure is the evidence that the current
// persistence architecture is wrong.
//
// Everything asserted here is behaviour, never implementation shape: after the
// repair the store may reach the typed columns however it likes, as long as
// these guarantees hold.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/planner_presentation_document_store.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../support/test_dependencies.dart';

void main() {
  final clock = FixedClock(DateTime.utc(2026, 9, 12, 12));

  Future<AppDatabase> open() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    return database;
  }

  DetailedContentPreferencesStore storeFor(AppDatabase database) =>
      DetailedContentPreferencesStore(database: database, clock: clock);

  Future<String> seedProfile(AppDatabase database) async {
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    return profile.id;
  }

  /// A deliberately un-defaulted set: proves each field is stored
  /// independently and that `true` is not merely a fallback.
  const mixed = DetailedContentPreferences(
    showTitle: false,
    showDescription: false,
    showTime: true,
    showContacts: false,
    showLocation: true,
  );

  // ---------------------------------------------------------------------------
  // PERSIST-6 — fresh v47 profile defaults all five TRUE
  // ---------------------------------------------------------------------------
  test('PERSIST-6 fresh profile defaults all five Detailed fields TRUE', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final read = await storeFor(database).read(profileId);

    expect(read.showTitle, isTrue);
    expect(read.showDescription, isTrue);
    expect(read.showTime, isTrue);
    expect(read.showContacts, isTrue);
    expect(read.showLocation, isTrue);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-7 — save each combination and read back exact values
  // ---------------------------------------------------------------------------
  test('PERSIST-7 every combination round-trips exactly', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);

    // Every one of the 32 combinations, including all-off and all-on.
    for (var mask = 0; mask < 32; mask++) {
      final next = DetailedContentPreferences(
        showTitle: mask & 1 != 0,
        showDescription: mask & 2 != 0,
        showTime: mask & 4 != 0,
        showContacts: mask & 8 != 0,
        showLocation: mask & 16 != 0,
      );
      await store.write(profileId, next);
      expect(
        await store.read(profileId),
        next,
        reason: 'combination mask=$mask must round-trip exactly',
      );
    }
  });

  // ---------------------------------------------------------------------------
  // PERSIST-8 — close/reopen the database, values identical
  // ---------------------------------------------------------------------------
  test('PERSIST-8 mixed values survive a real close/reopen', () async {
    final sqlite = sqlite3.openInMemory();
    try {
      final first = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
      );
      final profileId = await seedProfile(first);
      await storeFor(first).write(profileId, mixed);
      await first.close();

      final second = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
      );
      expect(await storeFor(second).read(profileId), mixed);
      await second.close();
    } finally {
      sqlite.close();
    }
  });

  // ---------------------------------------------------------------------------
  // PERSIST-9 — Event Color write must not disturb the five values
  // ---------------------------------------------------------------------------
  test('PERSIST-9 Event Color write leaves the five values untouched', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);
    await store.write(profileId, mixed);

    await PlannerPresentationDocumentStore(database: database, clock: clock)
        .update(profileId, (current) async {
          final events = Map<String, EventColorPreference>.from(
            current.document.events,
          );
          events['someEventTypeId'] = const EventColorPreference(
            accentArgb: 0xFF112233,
            surfaceArgb: 0xFF445566,
          );
          return PlannerColorPreferencesDocument(
            events: events,
            groups: current.document.groups,
            goalEventTypeNames: current.document.goalEventTypeNames,
          );
        });

    expect(
      await store.read(profileId),
      mixed,
      reason: 'an Event Color save must never change notification settings',
    );
  });

  // ---------------------------------------------------------------------------
  // PERSIST-10 — Contact Group colour save must not disturb them
  // ---------------------------------------------------------------------------
  test('PERSIST-10 Contact Group colour save leaves them untouched', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);
    await store.write(profileId, mixed);

    final repo = DriftEventTypeRepository(database: database, clock: clock);
    await repo.saveContactGroupColor(
      profileId: profileId,
      groupId: 'some-group',
      colorArgb: 0xFF00FF00,
    );
    expect(await store.read(profileId), mixed);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-11 — Restore Event Color defaults must not disturb them
  // ---------------------------------------------------------------------------
  test('PERSIST-11 restore Event Color defaults leaves them untouched', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);
    await store.write(profileId, mixed);

    final repo = DriftEventTypeRepository(database: database, clock: clock);
    await repo.saveEventColorPreference(
      profileId: profileId,
      eventTypeStableKey: 'some-event-type',
      preference: const EventColorPreference(
        accentArgb: 0xFF123456,
        surfaceArgb: 0xFF123457,
      ),
    );
    await repo.restoreEventColorDefaults(profileId: profileId);

    expect(await store.read(profileId), mixed);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-12 — savePlannerSettings must not disturb them
  // ---------------------------------------------------------------------------
  test('PERSIST-12 savePlannerSettings leaves them untouched', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);
    await store.write(profileId, mixed);

    final repo = DriftEventTypeRepository(database: database, clock: clock);
    final before = await repo.readPlannerSettings(profileId: profileId);
    await repo.savePlannerSettings(
      profileId: profileId,
      settings: before.copyWith(defaultDurationMinutes: 45),
    );

    expect(await store.read(profileId), mixed);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-13 — Notification-detail save must not alter Event Color JSON
  // ---------------------------------------------------------------------------
  test('PERSIST-13 notification save does not alter Event Color data', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);
    final presentation = PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    );

    await presentation.update(profileId, (current) async {
      final events = Map<String, EventColorPreference>.from(
        current.document.events,
      );
      events['keep-me'] = const EventColorPreference(
        accentArgb: 0xFFAABBCC,
        surfaceArgb: 0xFFDDEEFF,
      );
      return PlannerColorPreferencesDocument(
        events: events,
        groups: const <String, int>{'g1': 0xFF010203},
        goalEventTypeNames: current.document.goalEventTypeNames,
      );
    });

    final colorsBefore = await presentation.read(profileId);

    await store.write(profileId, mixed);

    final colorsAfter = await presentation.read(profileId);
    expect(colorsAfter.events, colorsBefore.events);
    expect(colorsAfter.groups, colorsBefore.groups);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-14 — Notification-detail save must not alter unrelated
  //              PlannerPreferences values
  // ---------------------------------------------------------------------------
  test('PERSIST-14 notification save leaves unrelated planner columns alone',
      () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);

    final planner = DriftEventTypeRepository(database: database, clock: clock);
    final settings = await planner.readPlannerSettings(profileId: profileId);
    await planner.savePlannerSettings(
      profileId: profileId,
      settings: settings.copyWith(defaultDurationMinutes: 30),
    );

    final rowBefore =
        await (database.select(database.plannerPreferences)
              ..where((t) => t.profileId.equals(profileId)))
            .getSingle();
    final eventColorBefore = rowBefore.eventColorPreferencesJson;

    await store.write(profileId, mixed);

    final rowAfter =
        await (database.select(database.plannerPreferences)
              ..where((t) => t.profileId.equals(profileId)))
            .getSingle();
    expect(rowAfter.eventColorPreferencesJson, eventColorBefore);
    final plannerAfter = await planner.readPlannerSettings(profileId: profileId);
    expect(plannerAfter, isA<PlannerSettings>());
    expect(plannerAfter.defaultDurationMinutes, 30);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-15 — Privacy Lock forces Generic WITHOUT rewriting the five values
  // ---------------------------------------------------------------------------
  test('PERSIST-15 privacy lock forces Generic but keeps saved choices',
      () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);
    await store.write(profileId, mixed);

    // The renderer's lock is authoritative: whatever the saved options say,
    // the produced copy is the exact Generic pair.
    final locked = ReminderNotificationRenderer.eventDetailed(
      eventTitle: 'Private dental appointment',
      startDisplay: DateTime.utc(2026, 9, 12, 9),
      options: mixed.toOptions(),
      privacyLockForcesGeneric: true,
    );
    expect(locked.title, ReminderNotificationRenderer.genericTitle);
    expect(locked.body, ReminderNotificationRenderer.genericBody);
    expect(locked.body, 'You have a new notification.');
    expect(locked.body, isNot(contains('dental')));

    // The lock must NOT have cleared the owner's saved Detailed choices.
    expect(await store.read(profileId), mixed);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-16 — all five OFF yields the exact Generic fallback
  // ---------------------------------------------------------------------------
  test('PERSIST-16 all five OFF yields exact Generic copy', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    final store = storeFor(database);

    const allOff = DetailedContentPreferences(
      showTitle: false,
      showDescription: false,
      showTime: false,
      showContacts: false,
      showLocation: false,
    );
    await store.write(profileId, allOff);
    final read = await store.read(profileId);

    expect(read, allOff);
    expect(read.isEmpty, isTrue);

    // Persisted all-off must render as the exact Generic pair.
    final rendered = ReminderNotificationRenderer.eventDetailed(
      eventTitle: 'Should never surface',
      startDisplay: DateTime.utc(2026, 9, 12, 9),
      options: read.toOptions(),
      privacyLockForcesGeneric: false,
    );
    expect(rendered.title, ReminderNotificationRenderer.genericTitle);
    expect(rendered.body, ReminderNotificationRenderer.genericBody);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-17 — worker and UI read the same persisted typed values
  // ---------------------------------------------------------------------------
  test('PERSIST-17 worker and UI see identical persisted values', () async {
    final database = await open();
    final profileId = await seedProfile(database);
    await storeFor(database).write(profileId, mixed);

    // UI path: through the foundation repository port.
    final uiRepo = _repo(database);
    final ui = await uiRepo.readDetailedContent(profileId: profileId);

    // Worker path: a SECOND repository instance over the same database, which
    // is what the headless isolate does.
    final workerRepo = _repo(database);
    final worker = await workerRepo.readDetailedContent(profileId: profileId);

    expect(ui, worker);
    expect(worker, mixed);
  });

  // ---------------------------------------------------------------------------
  // PERSIST-18 — no private content enters durable worker input
  // ---------------------------------------------------------------------------
  test('PERSIST-18 durable worker input carries no private display strings',
      () async {
    final database = await open();
    final profileId = await seedProfile(database);
    await storeFor(database).write(profileId, mixed);

    // Nothing about the Detailed options may appear in the durable work
    // projection: only a boolean policy, never a title/notes/contact/location.
    final rows = await database.select(database.backgroundWorkRequests).get();
    final serialized = rows.map((row) => row.toString()).join('\n');
    expect(serialized, isNot(contains('showDescription')));
    expect(serialized, isNot(contains('showLocation')));
  });

  // ---------------------------------------------------------------------------
  // FORENSIC REGRESSION — the exact previously-reproduced unsafe sequence
  // ---------------------------------------------------------------------------
  test(
    'FORENSIC REGRESSION: save details -> save Event Color -> reopen details',
    () async {
      final sqlite = sqlite3.openInMemory();
      try {
        final database = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        );
        final profileId = await seedProfile(database);
        final store = storeFor(database);

        // 1. save notification Detailed options
        await store.write(profileId, mixed);

        // 2. save Event Color preference
        await PlannerPresentationDocumentStore(
          database: database,
          clock: clock,
        ).update(profileId, (current) async {
          final events = Map<String, EventColorPreference>.from(
            current.document.events,
          );
          events['regression-event-type'] = const EventColorPreference(
            accentArgb: 0xFF010101,
            surfaceArgb: 0xFF020202,
          );
          return PlannerColorPreferencesDocument(
            events: events,
            groups: current.document.groups,
            goalEventTypeNames: current.document.goalEventTypeNames,
          );
        });

        // 3. reload notification Detailed options — through a FRESH database
        //    handle, so this reads durable state rather than any cache.
        await database.close();
        final reopened = AppDatabase.forTesting(
          NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        );
        final after = await storeFor(reopened).read(profileId);
        await reopened.close();

        expect(
          after,
          mixed,
          reason:
              'REQUIRED: notification options unchanged exactly. Returning '
              'all-TRUE here is the exact regression this repair exists to '
              'eliminate.',
        );
      } finally {
        sqlite.close();
      }
    },
  );

  // ---------------------------------------------------------------------------
  // MIGRATION — v46 -> v47
  // ---------------------------------------------------------------------------
  test('PERSIST-1 v46 notification_preferences row migrates to v47', () async {
    final sqlite = sqlite3.openInMemory();
    try {
      final v46 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        schemaVersionOverride: 46,
      );
      final profileId = await seedProfile(v46);
      // Give the row non-default values so the migration cannot be confused
      // with a fresh insert.
      await v46
          .into(v46.notificationPreferences)
          .insertOnConflictUpdate(
            NotificationPreferencesCompanion.insert(
              profileId: profileId,
              systemNotificationsEnabled: const Value(true),
              eventRemindersEnabled: const Value(true),
              taskRemindersEnabled: const Value(false),
              weeklyReviewRemindersEnabled: const Value(true),
              awaitingReportRemindersEnabled: const Value(false),
              goalCompletionNotificationsEnabled: const Value(true),
              inAppGoalCelebrationsEnabled: const Value(false),
              defaultTaskReminderMinutes: const Value(25),
              snoozeDurationMinutes: const Value(15),
              quietHoursEnabled: const Value(true),
              quietStartMinute: const Value(1320),
              quietEndMinute: const Value(420),
              updatedAtUtc: DateTime.utc(2026, 9, 10, 8),
            ),
          );
      await v46.close();

      final v47 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
      );
      expect(
        (await v47.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        47,
        reason: 'the repaired schema must report v47',
      );

      final row =
          await (v47.select(v47.notificationPreferences)
                ..where((t) => t.profileId.equals(profileId)))
              .getSingle();

      // PERSIST-2 — all five new values TRUE
      expect(row.detailedShowTitle, isTrue);
      expect(row.detailedShowDescription, isTrue);
      expect(row.detailedShowTime, isTrue);
      expect(row.detailedShowContacts, isTrue);
      expect(row.detailedShowLocation, isTrue);

      // PERSIST-3 — pre-existing values survive exactly
      expect(row.systemNotificationsEnabled, isTrue);
      expect(row.eventRemindersEnabled, isTrue);
      expect(row.taskRemindersEnabled, isFalse);
      expect(row.weeklyReviewRemindersEnabled, isTrue);
      expect(row.awaitingReportRemindersEnabled, isFalse);
      expect(row.goalCompletionNotificationsEnabled, isTrue);
      expect(row.inAppGoalCelebrationsEnabled, isFalse);
      expect(row.defaultTaskReminderMinutes, 25);
      expect(row.snoozeDurationMinutes, 15);
      expect(row.quietHoursEnabled, isTrue);
      expect(row.quietStartMinute, 1320);
      expect(row.quietEndMinute, 420);

      // PERSIST-5 — no duplicate row
      expect(await v47.select(v47.notificationPreferences).get(), hasLength(1));
      await v47.close();
    } finally {
      sqlite.close();
    }
  });

  test('PERSIST-4 privacy settings survive the migration', () async {
    final sqlite = sqlite3.openInMemory();
    try {
      final v46 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        schemaVersionOverride: 46,
      );
      await seedProfile(v46);
      // Privacy state is keyed by a single 'primary' row. Seed a NON-default
      // value so the migration cannot be confused with a fresh default row.
      await v46
          .into(v46.privacyPreferences)
          .insertOnConflictUpdate(
            PrivacyPreferencesCompanion.insert(
              lockEnabled: const Value(true),
              notificationPreviewMode: const Value('hidden'),
              updatedAtUtc: DateTime.utc(2026, 9, 10, 8),
            ),
          );
      final privacyBefore = await v46.select(v46.privacyPreferences).get();
      expect(privacyBefore, isNotEmpty);
      expect(privacyBefore.single.lockEnabled, isTrue);
      await v46.close();

      final v47 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
      );
      final privacyAfter = await v47.select(v47.privacyPreferences).get();
      expect(privacyAfter.length, privacyBefore.length);
      expect(privacyAfter.single.lockEnabled, isTrue);
      expect(privacyAfter.single.notificationPreviewMode, 'hidden');
      expect(privacyAfter.single.key, privacyBefore.single.key);
      await v47.close();
    } finally {
      sqlite.close();
    }
  });

  test('MIGRATION-SAFETY representative tables lose zero rows', () async {
    final sqlite = sqlite3.openInMemory();
    try {
      final v46 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
        schemaVersionOverride: 46,
      );
      final profileId = await seedProfile(v46);
      await v46
          .into(v46.notificationPreferences)
          .insertOnConflictUpdate(
            NotificationPreferencesCompanion.insert(
              profileId: profileId,
              updatedAtUtc: DateTime.utc(2026, 9, 10),
            ),
          );

      Future<int> count(AppDatabase db, String table) async =>
          (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
              .read<int>('c');

      const tables = <String>[
        'contacts',
        'calendar_events',
        'calendar_event_exceptions',
        'planner_tasks',
        'goals',
        'reminder_policies',
        'notification_preferences',
        'privacy_preferences',
        'saved_places',
      ];
      final before = <String, int>{
        for (final t in tables) t: await count(v46, t),
      };
      await v46.close();

      final v47 = AppDatabase.forTesting(
        NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
      );
      for (final t in tables) {
        expect(
          await count(v47, t),
          before[t],
          reason: '$t must not lose rows across v46 -> v47',
        );
      }
      await v47.close();
    } finally {
      sqlite.close();
    }
  });
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

NotificationFoundationRepository _repo(AppDatabase database) =>
    DriftNotificationFoundationRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 12, 12)),
    );
