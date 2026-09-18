import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const profileId = '11111111-1111-4111-8111-111111111111';
  final now = DateTime.utc(2026, 9, 5, 5);

  test(
    'missing row resolves locked defaults; preferences persist locally',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      expect(
        await repository.readPreferences(profileId: profileId),
        const NotificationPreferences.defaults(),
      );
      expect(
        await database.select(database.notificationPreferences).get(),
        isEmpty,
      );

      const saved = NotificationPreferences(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        taskRemindersEnabled: true,
        defaultTaskReminderMinutes: 30,
        quietHours: QuietHoursSettings(
          enabled: true,
          startMinute: 1320,
          endMinute: 420,
        ),
      );
      await repository.savePreferences(
        profileId: profileId,
        preferences: saved,
      );
      expect(await repository.readPreferences(profileId: profileId), saved);

      final columns = await database
          .customSelect("PRAGMA table_info('notification_preferences')")
          .get();
      final names = columns.map((row) => row.read<String>('name'));
      expect(names, isNot(contains('default_event_reminder_minutes')));
      expect(names, isNot(contains('notification_preview_mode')));
    },
  );

  test(
    'ReminderPolicy validates non-null series identity and unique upsert',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      expect(ReminderPolicy.seriesOccurrenceId, 'series');
      final policy = ReminderPolicy(
        id: 'policy-1',
        profileId: profileId,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 15,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
      await repository.upsertPolicy(policy);
      await repository.upsertPolicy(policy.copyWith(offsetMinutes: 30));
      final policies = await repository.readPolicies(
        profileId: profileId,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
      );
      expect(policies, hasLength(1));
      expect(policies.single.occurrenceId, 'series');
      expect(policies.single.offsetMinutes, 30);
      expect(
        ReminderPolicy(
          id: 'bad',
          profileId: profileId,
          sourceKind: ReminderSourceKind.task,
          sourceId: 'task-1',
          occurrenceId: '',
          mode: ReminderPolicyMode.inherit,
          createdAtUtc: now,
          updatedAtUtc: now,
        ).validate,
        throwsArgumentError,
      );
    },
  );

  test(
    'durable platform IDs probe collisions and survive recreation',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
        platformIdSeed: (_) => 41,
      );
      for (final key in <String>['foundation:first', 'foundation:second']) {
        await repository.upsertWorkRequest(
          BackgroundWorkRequest(
            stableKey: key,
            profileId: profileId,
            category: BackgroundWorkCategory.notificationFoundation,
            ownerKind: BackgroundWorkOwnerKind.profile,
            ownerId: profileId,
            state: BackgroundWorkState.queued,
            attemptCount: 0,
            snoozeCount: 0,
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
      }
      expect(
        await repository.allocatePlatformNotificationId('foundation:first'),
        41,
      );
      expect(
        await repository.allocatePlatformNotificationId('foundation:second'),
        42,
      );
      final recreated = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
        platformIdSeed: (_) => 999,
      );
      expect(
        await recreated.allocatePlatformNotificationId('foundation:first'),
        41,
      );
    },
  );

  test(
    'background work persists sanitized state, attempts, and snoozes',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final request = BackgroundWorkRequest(
        stableKey: 'foundation:profile-1',
        profileId: profileId,
        category: BackgroundWorkCategory.notificationFoundation,
        ownerKind: BackgroundWorkOwnerKind.profile,
        ownerId: profileId,
        state: BackgroundWorkState.queued,
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
      await repository.upsertWorkRequest(request);
      await repository.recordAttempt(
        stableKey: request.stableKey,
        nextState: BackgroundWorkState.retryScheduled,
        failureCategory: 'platform_unavailable',
        nextEligibleAtUtc: now.add(const Duration(minutes: 5)),
      );
      await repository.recordSnooze(
        stableKey: request.stableKey,
        untilUtc: now.add(const Duration(minutes: 10)),
      );
      final stored = await repository.readWorkRequest(request.stableKey);
      expect(stored?.attemptCount, 1);
      expect(stored?.snoozeCount, 1);
      expect(stored?.lastFailureCategory, 'platform_unavailable');
      final columns = await database
          .customSelect("PRAGMA table_info('background_work_requests')")
          .get();
      final names = columns.map((row) => row.read<String>('name')).toSet();
      for (final privateName in <String>{
        'title',
        'body',
        'notes',
        'reflection',
        'latitude',
        'longitude',
        'payload',
      }) {
        expect(names, isNot(contains(privateName)));
      }
    },
  );

  test(
    'bounded reminder-work query returns only active Event work in scope',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(now),
      );
      final windowStart = DateTime.utc(2026, 9, 6);
      final windowEnd = DateTime.utc(2026, 10, 19);

      Future<void> insert({
        required String key,
        required String ownerId,
        required BackgroundWorkCategory category,
        required BackgroundWorkOwnerKind ownerKind,
        required BackgroundWorkState state,
        DateTime? scheduledForUtc,
      }) {
        // M8: family identity is carried by the canonical stableKey prefix.
        final familyPrefix = ownerKind == BackgroundWorkOwnerKind.task
            ? 'reminder:task:'
            : 'reminder:calendarEvent:';
        return repository
            .upsertWorkRequest(
              BackgroundWorkRequest(
                stableKey: '$familyPrefix$profileId:$key:base',
                profileId: profileId,
                category: category,
                ownerKind: ownerKind,
                ownerId: ownerId,
                occurrenceId: 'occurrence-$key',
                scheduledForUtc: scheduledForUtc,
                state: state,
                attemptCount: 0,
                snoozeCount: 0,
                createdAtUtc: now,
                updatedAtUtc: now,
              ),
            )
            .then((_) {});
      }

      await insert(
        key: 'event-a-start',
        ownerId: 'event-a',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.scheduled,
        scheduledForUtc: windowStart,
      );
      await insert(
        key: 'event-a-later',
        ownerId: 'event-a',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.retryScheduled,
        scheduledForUtc: windowStart.add(const Duration(days: 2)),
      );
      await insert(
        key: 'event-b',
        ownerId: 'event-b',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.queued,
        scheduledForUtc: windowStart.add(const Duration(days: 1)),
      );
      await insert(
        key: 'task-a',
        ownerId: 'task-a',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.task,
        state: BackgroundWorkState.scheduled,
        scheduledForUtc: windowStart.add(const Duration(hours: 1)),
      );
      await insert(
        key: 'event-a-cancelled',
        ownerId: 'event-a',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.cancelledObsolete,
        scheduledForUtc: windowStart.add(const Duration(hours: 2)),
      );
      await insert(
        key: 'event-a-foundation',
        ownerId: 'event-a',
        category: BackgroundWorkCategory.notificationFoundation,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.scheduled,
        scheduledForUtc: windowStart.add(const Duration(hours: 3)),
      );
      await insert(
        key: 'event-a-before',
        ownerId: 'event-a',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.scheduled,
        scheduledForUtc: windowStart.subtract(const Duration(microseconds: 1)),
      );
      await insert(
        key: 'event-a-end',
        ownerId: 'event-a',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.scheduled,
        scheduledForUtc: windowEnd,
      );
      await insert(
        key: 'event-a-unscheduled',
        ownerId: 'event-a',
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        state: BackgroundWorkState.queued,
      );

      final scoped = await repository.readReminderWork(
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-a',
        windowStartUtc: windowStart,
        windowEndUtc: windowEnd,
      );
      expect(scoped.map((work) => work.stableKey), <String>[
        'reminder:calendarEvent:$profileId:event-a-start:base',
        'reminder:calendarEvent:$profileId:event-a-later:base',
      ]);

      final allEvents = await repository.readReminderWork(
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        windowStartUtc: windowStart,
        windowEndUtc: windowEnd,
      );
      expect(allEvents.map((work) => work.stableKey), <String>[
        'reminder:calendarEvent:$profileId:event-a-start:base',
        'reminder:calendarEvent:$profileId:event-b:base',
        'reminder:calendarEvent:$profileId:event-a-later:base',
      ]);
      expect(
        () => repository.readReminderWork(
          profileId: profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          windowStartUtc: windowEnd,
          windowEndUtc: windowStart,
        ),
        throwsArgumentError,
      );
    },
  );
}
