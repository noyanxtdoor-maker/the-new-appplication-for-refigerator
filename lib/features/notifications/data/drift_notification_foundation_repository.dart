import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

typedef PlatformNotificationIdSeed = int Function(String stableKey);

final class DriftNotificationFoundationRepository
    implements NotificationFoundationRepository {
  const DriftNotificationFoundationRepository({
    required this.database,
    required this.clock,
    this.platformIdSeed = _defaultPlatformIdSeed,
  });

  static const int _maximumPlatformId = 0x7fffffff;

  /// VS16 M8: the launcher badge allocates this ID outside the work table.
  /// The reminder allocator must never hand it out, and a legitimate reminder
  /// row that somehow occupies it is relocated transactionally.
  static const int reservedPlatformNotificationId = 0x7ffffffe;

  final AppDatabase database;
  final AppClock clock;
  final PlatformNotificationIdSeed platformIdSeed;

  @override
  Future<NotificationPreferences> readPreferences({
    required String profileId,
  }) async {
    final row =
        await (database.select(database.notificationPreferences)
              ..where((table) => table.profileId.equals(profileId))
              ..limit(1))
            .getSingleOrNull();
    if (row == null) return const NotificationPreferences.defaults();
    final preferences = NotificationPreferences(
      systemNotificationsEnabled: row.systemNotificationsEnabled,
      eventRemindersEnabled: row.eventRemindersEnabled,
      taskRemindersEnabled: row.taskRemindersEnabled,
      weeklyReviewRemindersEnabled: row.weeklyReviewRemindersEnabled,
      awaitingReportRemindersEnabled: row.awaitingReportRemindersEnabled,
      goalCompletionNotificationsEnabled:
          row.goalCompletionNotificationsEnabled,
      inAppGoalCelebrationsEnabled: row.inAppGoalCelebrationsEnabled,
      defaultTaskReminderMinutes: row.defaultTaskReminderMinutes,
      snoozeDurationMinutes: row.snoozeDurationMinutes,
      quietHours: QuietHoursSettings(
        enabled: row.quietHoursEnabled,
        startMinute: row.quietStartMinute,
        endMinute: row.quietEndMinute,
      ),
    );
    preferences.validate();
    return preferences;
  }

  @override
  Future<NotificationPreferences> savePreferences({
    required String profileId,
    required NotificationPreferences preferences,
  }) async {
    if (profileId.trim().isEmpty) {
      throw ArgumentError.value(profileId, 'profileId');
    }
    preferences.validate();
    await database
        .into(database.notificationPreferences)
        .insertOnConflictUpdate(
          NotificationPreferencesCompanion.insert(
            profileId: profileId,
            systemNotificationsEnabled: Value(
              preferences.systemNotificationsEnabled,
            ),
            eventRemindersEnabled: Value(preferences.eventRemindersEnabled),
            taskRemindersEnabled: Value(preferences.taskRemindersEnabled),
            weeklyReviewRemindersEnabled: Value(
              preferences.weeklyReviewRemindersEnabled,
            ),
            awaitingReportRemindersEnabled: Value(
              preferences.awaitingReportRemindersEnabled,
            ),
            goalCompletionNotificationsEnabled: Value(
              preferences.goalCompletionNotificationsEnabled,
            ),
            inAppGoalCelebrationsEnabled: Value(
              preferences.inAppGoalCelebrationsEnabled,
            ),
            defaultTaskReminderMinutes: Value(
              preferences.defaultTaskReminderMinutes,
            ),
            snoozeDurationMinutes: Value(preferences.snoozeDurationMinutes),
            quietHoursEnabled: Value(preferences.quietHours.enabled),
            quietStartMinute: Value(preferences.quietHours.startMinute),
            quietEndMinute: Value(preferences.quietHours.endMinute),
            updatedAtUtc: clock.nowUtc(),
          ),
        );
    return readPreferences(profileId: profileId);
  }

  @override
  Future<List<ReminderPolicy>> readPolicies({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
  }) async {
    final rows =
        await (database.select(database.reminderPolicies)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.sourceKind.equals(sourceKind.name) &
                    table.sourceId.equals(sourceId),
              )
              ..orderBy(<OrderingTerm Function(ReminderPolicies)>[
                (table) => OrderingTerm.asc(table.occurrenceId),
              ]))
            .get();
    return rows.map(_mapReminderPolicy).toList(growable: false);
  }

  @override
  Future<ReminderPolicy> upsertPolicy(ReminderPolicy policy) async {
    policy.validate();
    await database.transaction(() async {
      final existing =
          await (database.select(database.reminderPolicies)
                ..where(
                  (table) =>
                      table.profileId.equals(policy.profileId) &
                      table.sourceKind.equals(policy.sourceKind.name) &
                      table.sourceId.equals(policy.sourceId) &
                      table.occurrenceId.equals(policy.occurrenceId),
                )
                ..limit(1))
              .getSingleOrNull();
      if (existing == null) {
        await database
            .into(database.reminderPolicies)
            .insert(
              ReminderPoliciesCompanion.insert(
                id: policy.id,
                profileId: policy.profileId,
                sourceKind: policy.sourceKind.name,
                sourceId: policy.sourceId,
                occurrenceId: policy.occurrenceId,
                purpose: Value(policy.purpose.name),
                contactId: Value(policy.contactId),
                mode: policy.mode.name,
                offsetMinutes: Value(policy.offsetMinutes),
                createdAtUtc: policy.createdAtUtc,
                updatedAtUtc: policy.updatedAtUtc,
              ),
            );
      } else {
        await (database.update(
          database.reminderPolicies,
        )..where((table) => table.id.equals(existing.id))).write(
          ReminderPoliciesCompanion(
            purpose: Value(policy.purpose.name),
            contactId: Value(policy.contactId),
            mode: Value(policy.mode.name),
            offsetMinutes: Value(policy.offsetMinutes),
            updatedAtUtc: Value(policy.updatedAtUtc),
          ),
        );
      }
    });
    return (await readPolicies(
      profileId: policy.profileId,
      sourceKind: policy.sourceKind,
      sourceId: policy.sourceId,
    )).singleWhere((item) => item.occurrenceId == policy.occurrenceId);
  }

  @override
  Future<void> deletePolicy({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  }) async {
    await (database.delete(database.reminderPolicies)..where(
          (table) =>
              table.profileId.equals(profileId) &
              table.sourceKind.equals(sourceKind.name) &
              table.sourceId.equals(sourceId) &
              table.occurrenceId.equals(occurrenceId),
        ))
        .go();
  }

  ReminderPolicy _mapReminderPolicy(ReminderPolicyRow row) => ReminderPolicy(
    id: row.id,
    profileId: row.profileId,
    sourceKind: ReminderSourceKind.values.byName(row.sourceKind),
    sourceId: row.sourceId,
    occurrenceId: row.occurrenceId,
    purpose: ReminderPurpose.values.byName(row.purpose),
    contactId: row.contactId,
    mode: ReminderPolicyMode.values.byName(row.mode),
    offsetMinutes: row.offsetMinutes,
    createdAtUtc: row.createdAtUtc,
    updatedAtUtc: row.updatedAtUtc,
  );

  @override
  Future<BackgroundWorkRequest?> readWorkRequest(String stableKey) async {
    final row =
        await (database.select(database.backgroundWorkRequests)
              ..where((table) => table.stableKey.equals(stableKey))
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapWorkRequest(row);
  }

  @override
  Future<BackgroundWorkRequest?> readWorkRequestByPlatformId(
    int platformId,
  ) async {
    final row =
        await (database.select(database.backgroundWorkRequests)
              ..where(
                (table) => table.platformNotificationId.equals(platformId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapWorkRequest(row);
  }

  @override
  Future<List<BackgroundWorkRequest>> readActiveReminderWork({
    required String profileId,
    ReminderSourceKind? sourceKind,
  }) async {
    if (profileId.trim().isEmpty) {
      throw ArgumentError.value(profileId, 'profileId');
    }
    final prefix = switch (sourceKind) {
      ReminderSourceKind.calendarEvent => 'reminder:calendarEvent:',
      ReminderSourceKind.task => 'reminder:task:',
      ReminderSourceKind.weeklyReview => 'planning:weekly-review:',
      ReminderSourceKind.awaitingReport => 'planning:awaiting-report:',
      null => null,
    };
    final query = database.select(database.backgroundWorkRequests)
      ..where(
        (table) =>
            table.profileId.equals(profileId) &
            table.category.equals(
              BackgroundWorkCategory.reminderRecovery.name,
            ) &
            table.state.isIn(<String>[
              BackgroundWorkState.queued.name,
              BackgroundWorkState.waitingForConstraints.name,
              BackgroundWorkState.running.name,
              BackgroundWorkState.delayedBySystem.name,
              BackgroundWorkState.retryScheduled.name,
              BackgroundWorkState.scheduled.name,
            ]) &
            (prefix == null
                ? const Constant<bool>(true)
                : table.stableKey.like('$prefix%')),
      )
      ..orderBy(<OrderingTerm Function(BackgroundWorkRequests)>[
        (table) => OrderingTerm.asc(table.stableKey),
      ]);
    final rows = await query.get();
    return rows.map(_mapWorkRequest).toList(growable: false);
  }

  @override
  Future<List<BackgroundWorkRequest>> readReminderWork({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    String? sourceId,
  }) async {
    if (profileId.trim().isEmpty) {
      throw ArgumentError.value(profileId, 'profileId');
    }
    if (!windowStartUtc.isUtc || !windowEndUtc.isUtc) {
      throw ArgumentError('Reminder work bounds must be UTC.');
    }
    if (!windowStartUtc.isBefore(windowEndUtc)) {
      throw ArgumentError('Reminder work bounds must form a non-empty range.');
    }
    final ownerKind = switch (sourceKind) {
      ReminderSourceKind.calendarEvent =>
        BackgroundWorkOwnerKind.occurrence.name,
      ReminderSourceKind.task => BackgroundWorkOwnerKind.task.name,
      ReminderSourceKind.weeklyReview || ReminderSourceKind.awaitingReport =>
        BackgroundWorkOwnerKind.planning.name,
    };
    // F03: both planning kinds map to ownerKind=planning, so family identity
    // must be enforced by the stableKey prefix.  Otherwise a weekly cleanup
    // can retrieve (and cancel under the wrong identity) awaiting-report rows
    // with the same occurrence token.
    final familyPrefix = switch (sourceKind) {
      ReminderSourceKind.calendarEvent => 'reminder:calendarEvent:',
      ReminderSourceKind.task => 'reminder:task:',
      ReminderSourceKind.weeklyReview => 'planning:weekly-review:',
      ReminderSourceKind.awaitingReport => 'planning:awaiting-report:',
    };
    final activeStates = <String>[
      BackgroundWorkState.completed.name,
      BackgroundWorkState.queued.name,
      BackgroundWorkState.waitingForConstraints.name,
      BackgroundWorkState.delayedBySystem.name,
      BackgroundWorkState.retryScheduled.name,
      BackgroundWorkState.scheduled.name,
    ];
    final query = database.select(database.backgroundWorkRequests)
      ..where(
        (table) =>
            table.profileId.equals(profileId) &
            table.category.equals(
              BackgroundWorkCategory.reminderRecovery.name,
            ) &
            table.ownerKind.equals(ownerKind) &
            table.stableKey.like('$familyPrefix%') &
            table.state.isIn(activeStates) &
            table.scheduledForUtc.isBiggerOrEqualValue(windowStartUtc) &
            table.scheduledForUtc.isSmallerThanValue(windowEndUtc) &
            (sourceId == null
                ? const Constant<bool>(true)
                : table.ownerId.equals(sourceId)),
      )
      ..orderBy(<OrderingTerm Function(BackgroundWorkRequests)>[
        (table) => OrderingTerm.asc(table.scheduledForUtc),
        (table) => OrderingTerm.asc(table.stableKey),
      ]);
    final rows = await query.get();
    return rows.map(_mapWorkRequest).toList(growable: false);
  }

  @override
  Future<BackgroundWorkRequest> upsertWorkRequest(
    BackgroundWorkRequest request,
  ) async {
    request.validate();
    await database
        .into(database.backgroundWorkRequests)
        .insertOnConflictUpdate(
          BackgroundWorkRequestsCompanion.insert(
            stableKey: request.stableKey,
            profileId: Value(request.profileId),
            category: request.category.name,
            ownerKind: request.ownerKind.name,
            ownerId: Value(request.ownerId),
            occurrenceId: Value(request.occurrenceId),
            sourceRevision: Value(request.sourceRevision),
            scheduledForUtc: Value(request.scheduledForUtc),
            state: request.state.name,
            platformNotificationId: Value(request.platformNotificationId),
            attemptCount: Value(request.attemptCount),
            snoozeCount: Value(request.snoozeCount),
            lastAttemptAtUtc: Value(request.lastAttemptAtUtc),
            nextEligibleAtUtc: Value(request.nextEligibleAtUtc),
            completedAtUtc: Value(request.completedAtUtc),
            lastFailureCategory: Value(request.lastFailureCategory),
            createdAtUtc: request.createdAtUtc,
            updatedAtUtc: request.updatedAtUtc,
          ),
        );
    return (await readWorkRequest(request.stableKey))!;
  }

  @override
  Future<void> recordAttempt({
    required String stableKey,
    required BackgroundWorkState nextState,
    String? failureCategory,
    DateTime? nextEligibleAtUtc,
  }) async {
    final current = await readWorkRequest(stableKey);
    if (current == null) throw StateError('Background work request not found.');
    final now = clock.nowUtc();
    await upsertWorkRequest(
      current.copyWith(
        state: nextState,
        attemptCount: current.attemptCount + 1,
        lastAttemptAtUtc: now,
        clearNextEligibleAtUtc: nextEligibleAtUtc == null,
        nextEligibleAtUtc: nextEligibleAtUtc,
        clearLastFailureCategory: failureCategory == null,
        lastFailureCategory: failureCategory,
        updatedAtUtc: now,
      ),
    );
  }

  @override
  Future<void> recordClaim({required String stableKey}) async {
    final current = await readWorkRequest(stableKey);
    if (current == null) throw StateError('Background work request not found.');
    final now = clock.nowUtc();
    await upsertWorkRequest(
      current.copyWith(
        state: BackgroundWorkState.running,
        lastAttemptAtUtc: now,
        clearNextEligibleAtUtc: true,
        clearLastFailureCategory: true,
        updatedAtUtc: now,
      ),
    );
  }

  @override
  Future<void> recordSnooze({
    required String stableKey,
    required DateTime untilUtc,
  }) async {
    final current = await readWorkRequest(stableKey);
    if (current == null) throw StateError('Background work request not found.');
    await upsertWorkRequest(
      current.copyWith(
        state: BackgroundWorkState.scheduled,
        snoozeCount: current.snoozeCount + 1,
        scheduledForUtc: untilUtc,
        nextEligibleAtUtc: untilUtc,
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  @override
  Future<int> allocatePlatformNotificationId(String stableKey) {
    return database.transaction(() async {
      final row =
          await (database.select(database.backgroundWorkRequests)
                ..where((table) => table.stableKey.equals(stableKey))
                ..limit(1))
              .getSingleOrNull();
      if (row == null) {
        throw StateError('Allocate IDs only for durable work requests.');
      }
      if (row.platformNotificationId != null &&
          row.platformNotificationId != reservedPlatformNotificationId) {
        return row.platformNotificationId!;
      }
      if (row.platformNotificationId == reservedPlatformNotificationId) {
        // VS16 M8: a legitimate reminder row must never keep the launcher
        // badge slot.  Free it transactionally, then allocate a normal ID.
        await (database.update(
          database.backgroundWorkRequests,
        )..where((table) => table.stableKey.equals(stableKey))).write(
          BackgroundWorkRequestsCompanion(
            platformNotificationId: const Value<int?>(null),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
      }
      var candidate = platformIdSeed(stableKey) & _maximumPlatformId;
      if (candidate == 0 || candidate == reservedPlatformNotificationId) {
        candidate = 1;
      }
      for (var probes = 0; probes < _maximumPlatformId; probes++) {
        if (candidate != reservedPlatformNotificationId) {
          final collision =
              await (database.select(database.backgroundWorkRequests)
                    ..where(
                      (table) => table.platformNotificationId.equals(candidate),
                    )
                    ..limit(1))
                  .getSingleOrNull();
          if (collision == null) {
            await (database.update(
              database.backgroundWorkRequests,
            )..where((table) => table.stableKey.equals(stableKey))).write(
              BackgroundWorkRequestsCompanion(
                platformNotificationId: Value(candidate),
                updatedAtUtc: Value(clock.nowUtc()),
              ),
            );
            return candidate;
          }
        }
        candidate = candidate == _maximumPlatformId ? 1 : candidate + 1;
      }
      throw StateError('No platform notification ID is available.');
    });
  }

  @override
  Future<int> countPendingWork({required String profileId}) async {
    final count = database.backgroundWorkRequests.stableKey.count();
    final query = database.selectOnly(database.backgroundWorkRequests)
      ..addColumns(<Expression<Object>>[count])
      ..where(
        database.backgroundWorkRequests.profileId.equals(profileId) &
            database.backgroundWorkRequests.state.isIn(<String>[
              BackgroundWorkState.queued.name,
              BackgroundWorkState.scheduled.name,
              BackgroundWorkState.retryScheduled.name,
            ]),
      );
    return (await query.getSingle()).read(count) ?? 0;
  }

  @override
  Future<bool> beginReminderRepair({required String profileId}) =>
      ReminderRecoveryRequest.markRunning(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );

  @override
  Future<void> completeReminderRepair({required String profileId}) =>
      ReminderRecoveryRequest.markCompleted(
        database: database,
        profileId: profileId,
        nowUtc: clock.nowUtc(),
      );

  BackgroundWorkRequest _mapWorkRequest(BackgroundWorkRequestRow row) =>
      BackgroundWorkRequest(
        stableKey: row.stableKey,
        profileId: row.profileId,
        category: BackgroundWorkCategory.values.byName(row.category),
        ownerKind: BackgroundWorkOwnerKind.values.byName(row.ownerKind),
        ownerId: row.ownerId,
        occurrenceId: row.occurrenceId,
        sourceRevision: row.sourceRevision,
        scheduledForUtc: row.scheduledForUtc,
        state: BackgroundWorkState.values.byName(row.state),
        platformNotificationId: row.platformNotificationId,
        attemptCount: row.attemptCount,
        snoozeCount: row.snoozeCount,
        lastAttemptAtUtc: row.lastAttemptAtUtc,
        nextEligibleAtUtc: row.nextEligibleAtUtc,
        completedAtUtc: row.completedAtUtc,
        lastFailureCategory: row.lastFailureCategory,
        createdAtUtc: row.createdAtUtc,
        updatedAtUtc: row.updatedAtUtc,
      );

  static int _defaultPlatformIdSeed(String stableKey) {
    var hash = 0x811c9dc5;
    for (final unit in stableKey.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & _maximumPlatformId;
  }
}
