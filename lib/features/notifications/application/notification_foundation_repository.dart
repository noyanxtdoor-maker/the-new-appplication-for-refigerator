import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// OWNER REVIEW #4 STRAIGHTFIX — the SEMANTIC notification-setup state.
///
/// Row existence alone is not a safe sentinel. The shared
/// `notification_preferences` row is also written by the Detailed content store
/// (which INSERTS it just to hold its five columns, leaving every delivery field
/// at its compiled default) and by a master toggle on a profile that never ran
/// first-run setup. "A row exists" can therefore mean "nothing about
/// notification DELIVERY was ever configured".
///
/// The classification is derived from the row's own delivery fields, so it needs
/// no new column, no sentinel table and no schema change (schema stays 47).
enum NotificationSetupState {
  /// Nothing about notification delivery has ever been configured: either no
  /// row exists, or the only thing ever written was Detailed content. This is
  /// the ONLY state in which the owner-approved new-user defaults may be
  /// seeded.
  neverConfigured,

  /// The Review #4 fingerprint: the master is on while EVERY delivery category,
  /// both defaults and Quiet Hours were all left at their untouched defaults, so
  /// the app can deliver nothing. It is deliberately NOT repaired automatically:
  /// "master on with every category turned off on purpose" is a configuration a
  /// real user could have chosen, and the durable record does not distinguish
  /// the two. It is classified and reported so a future owner-approved migration
  /// can target it precisely instead of guessing.
  partiallyInitialized,

  /// A meaningful delivery configuration exists and must never be overwritten by
  /// first-run seeding. This includes a restored profile: its own choices, and
  /// its deliberately unset default reminders, are the user's.
  configured,
}

abstract interface class NotificationFoundationRepository {
  Future<NotificationPreferences> readPreferences({required String profileId});

  /// Whether a `notification_preferences` row physically exists.
  ///
  /// This is a raw storage fact and NOT the first-run decision: the row can
  /// exist because only Detailed content was ever written, or because the master
  /// was switched on over delivery fields that were never initialized. Use
  /// [readSetupState] to decide whether first-run setup is still required.
  Future<bool> hasPreferences({required String profileId});

  /// The semantic first-run sentinel (OWNER REVIEW #4 STRAIGHTFIX).
  ///
  /// Decides whether this profile still needs the owner-approved new-user
  /// notification defaults. See [NotificationSetupState] for the exact law.
  /// Reading never creates or mutates a row.
  Future<NotificationSetupState> readSetupState({required String profileId});

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
