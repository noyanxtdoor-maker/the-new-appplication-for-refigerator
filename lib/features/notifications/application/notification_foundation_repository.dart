import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

abstract interface class NotificationFoundationRepository {
  Future<NotificationPreferences> readPreferences({required String profileId});

  Future<NotificationPreferences> savePreferences({
    required String profileId,
    required NotificationPreferences preferences,
  });

  Future<List<ReminderPolicy>> readPolicies({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
  });

  Future<ReminderPolicy> upsertPolicy(ReminderPolicy policy);

  Future<void> deletePolicy({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  });

  Future<BackgroundWorkRequest?> readWorkRequest(String stableKey);

  Future<BackgroundWorkRequest?> readWorkRequestByPlatformId(int platformId);

  /// Unbounded-in-time but profile/category scoped active-work listing used by
  /// terminal-source cleanup, reserved-ID repair and diagnostics.  Completed
  /// historical rows are excluded.
  Future<List<BackgroundWorkRequest>> readActiveReminderWork({
    required String profileId,
    ReminderSourceKind? sourceKind,
  });

  Future<List<BackgroundWorkRequest>> readReminderWork({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    String? sourceId,
  });

  Future<BackgroundWorkRequest> upsertWorkRequest(
    BackgroundWorkRequest request,
  );

  Future<void> recordAttempt({
    required String stableKey,
    required BackgroundWorkState nextState,
    String? failureCategory,
    DateTime? nextEligibleAtUtc,
  });

  /// Records a delivery claim (state=running, last attempt timestamp) WITHOUT
  /// incrementing the bounded attempt counter: the counter measures real
  /// retries (maximum five persisted attempts per revision), not claims.
  Future<void> recordClaim({required String stableKey});

  Future<void> recordSnooze({
    required String stableKey,
    required DateTime untilUtc,
  });

  Future<int> allocatePlatformNotificationId(String stableKey);

  Future<int> countPendingWork({required String profileId});

  /// M8 durable reminder-repair marker lifecycle.  [beginReminderRepair]
  /// returns true when this caller now owns a queued/retryScheduled episode.
  Future<bool> beginReminderRepair({required String profileId});

  Future<void> completeReminderRepair({required String profileId});
}
