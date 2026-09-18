import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

abstract interface class NotificationFoundationRepository {
  Future<NotificationPreferences> readPreferences({required String profileId});

  /// Whether this profile has EVER had notification preferences written.
  ///
  /// OWNER REVIEW #4 — the first-ever-setup sentinel.
  ///
  /// [readPreferences] is documented never to create a row and to answer with
  /// [NotificationPreferences.defaults] when none exists, so "the row is
  /// absent" is a durable, already-existing record that nothing has ever been
  /// configured on this profile. That is the only state in which the app may
  /// seed the owner-approved new-user defaults. A returning user who revoked
  /// and re-granted the Android permission keeps their deliberate choices,
  /// because their row exists. No new column, no sentinel table and no schema
  /// change are needed.
  Future<bool> hasPreferences({required String profileId});

  /// VS16 M7 corrective persistence repair — the five per-field Detailed
  /// notification content options.
  ///
  /// These are TYPED boolean columns on the existing `notification_preferences`
  /// row (schema v47). They were briefly stored as a namespaced key inside the
  /// shared planner presentation JSON document; that design was reproduced as
  /// an actual data-loss defect, because the planner document writers rebuild
  /// that JSON from only the keys they understand and therefore dropped the
  /// notification key on an ordinary Event Color save.
  ///
  /// A missing row or missing value reads as the all-TRUE default, and reading
  /// never creates a row.
  Future<DetailedContentPreferences> readDetailedContent({
    required String profileId,
  });

  /// Persists ONLY the five dedicated columns (plus `updatedAtUtc`). No other
  /// notification preference and no planner/colour content can be affected.
  Future<DetailedContentPreferences> saveDetailedContent({
    required String profileId,
    required DetailedContentPreferences preferences,
  });

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

  /// Active (non-terminal) durable REMINDER rows for one profile, ordered by
  /// `stableKey` and paginated in batches (contract section 34).
  ///
  /// This is the unbounded-in-time, profile/category-scoped listing used for
  /// terminal-source cancellation and orphan cleanup OUTSIDE the narrow
  /// horizon.  It deliberately excludes the profile-scoped reconciliation
  /// marker (`ownerKind = profile`), which is not a notification, and it never
  /// deletes: completed historical rows are preserved and platform IDs are not
  /// reused in this milestone.
  Future<List<BackgroundWorkRequest>> readActiveReminderWork({
    required String profileId,
    int limit = 200,
    String? afterStableKey,
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
