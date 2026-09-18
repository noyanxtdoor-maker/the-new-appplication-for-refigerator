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

  /// Astra §32 step 7 / §65 G4: expected-generation conditional claim.
  /// Atomically (under SQLite writer serialization) verifies the durable row
  /// still carries [expectedRevision], [expectedScheduledForUtc] and one of
  /// the claimable states, then records the delivery attempt (state running,
  /// attemptCount+1, lastAttemptAtUtc) WITHOUT resetting the budget (G2:
  /// same-generation repair preserves attempts).  Returns the claimed row,
  /// or null when a newer generation/terminal state won the race.
  Future<BackgroundWorkRequest?> claimForDelivery({
    required String stableKey,
    required String expectedRevision,
    required DateTime expectedScheduledForUtc,
    required DateTime nowUtc,
  });

  /// §32 step 9 / §65 G4: conditional completion receipt — committed only
  /// when the row still matches the claimed generation.
  Future<bool> completeDelivery({
    required String stableKey,
    required String expectedRevision,
    required DateTime expectedScheduledForUtc,
    required DateTime nowUtc,
  });

  /// §31: durably record a retry/terminal outcome with sanitized category.
  /// Returns false when a newer generation superseded the expected one.
  Future<bool> recordDeliveryFailure({
    required String stableKey,
    required String expectedRevision,
    required DateTime expectedScheduledForUtc,
    required BackgroundWorkState nextState,
    required String failureCategory,
    DateTime? nextEligibleAtUtc,
    required DateTime nowUtc,
  });

  Future<void> recordAttempt({
    required String stableKey,
    required BackgroundWorkState nextState,
    String? failureCategory,
    DateTime? nextEligibleAtUtc,
  });

  Future<void> recordSnooze({
    required String stableKey,
    required DateTime untilUtc,
  });

  Future<int> allocatePlatformNotificationId(String stableKey);

  Future<int> countPendingWork({required String profileId});
}
