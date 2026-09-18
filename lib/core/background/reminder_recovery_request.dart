import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/database/app_database.dart';

/// VS16 M8 durable reminder-repair intent.
///
/// Uses the existing `BackgroundWorkRequests` representation with the
/// contract-defined logical row `reconcile:reminders:<profileId>`.  Canonical
/// mutations write this marker inside their OWN transaction so a later plugin
/// failure can never erase committed repair intent.  Reads and diagnostics
/// never create it; background work only consumes/clears it.
abstract final class ReminderRecoveryRequest {
  static const String keyPrefix = 'reconcile:reminders:';
  static const int maximumAttempts = 5;

  static String stableKeyFor(String profileId) => '$keyPrefix$profileId';

  /// The durable representation exists from the v38 notification foundation
  /// schema onward.  Legacy schema-override databases (migration tests) must
  /// never see a marker write, and no marker may break a legacy save path.
  static bool _supported(AppDatabase database) => database.schemaVersion >= 38;

  static Future<void> markDirty({
    required AppDatabase database,
    required String profileId,
    required DateTime nowUtc,
  }) async {
    if (!_supported(database) || profileId.trim().isEmpty) return;
    await database
        .into(database.backgroundWorkRequests)
        .insertOnConflictUpdate(
          BackgroundWorkRequestsCompanion.insert(
            stableKey: stableKeyFor(profileId),
            profileId: Value<String>(profileId),
            category: BackgroundWorkCategory.reminderRecovery.name,
            ownerKind: BackgroundWorkOwnerKind.profile.name,
            ownerId: Value<String>(profileId),
            occurrenceId: const Value<String?>(null),
            sourceRevision: Value<String>(
              'reconcile_${nowUtc.microsecondsSinceEpoch}',
            ),
            scheduledForUtc: const Value<DateTime?>(null),
            state: BackgroundWorkState.queued.name,
            platformNotificationId: const Value<int?>(null),
            attemptCount: const Value<int>(0),
            snoozeCount: const Value<int>(0),
            lastAttemptAtUtc: const Value<DateTime?>(null),
            nextEligibleAtUtc: const Value<DateTime?>(null),
            completedAtUtc: const Value<DateTime?>(null),
            lastFailureCategory: const Value<String?>(null),
            createdAtUtc: nowUtc,
            updatedAtUtc: nowUtc,
          ),
        );
  }

  /// Marks a queued/retryScheduled marker running.  Returns true when this
  /// invocation now owns a repair episode (queued or retryScheduled).
  static Future<bool> markRunning({
    required AppDatabase database,
    required String profileId,
    required DateTime nowUtc,
  }) async {
    if (!_supported(database)) return false;
    final row = await _read(database, profileId);
    if (row == null) return false;
    if (row.state != BackgroundWorkState.queued.name &&
        row.state != BackgroundWorkState.retryScheduled.name) {
      return false;
    }
    await (database.update(
      database.backgroundWorkRequests,
    )..where((table) => table.stableKey.equals(stableKeyFor(profileId)))).write(
      BackgroundWorkRequestsCompanion(
        state: Value<String>(BackgroundWorkState.running.name),
        lastAttemptAtUtc: Value<DateTime?>(nowUtc),
        attemptCount: Value<int>(row.attemptCount + 1),
        updatedAtUtc: Value<DateTime>(nowUtc),
      ),
    );
    return true;
  }

  /// Completes the captured episode.  A newer mutation during the pass will
  /// have already re-queued the marker (insertOnConflictUpdate resets queued),
  /// so this only completes a row still observed running.
  static Future<void> markCompleted({
    required AppDatabase database,
    required String profileId,
    required DateTime nowUtc,
  }) async {
    final row = await _read(database, profileId);
    if (row == null || row.state != BackgroundWorkState.running.name) return;
    await (database.update(
      database.backgroundWorkRequests,
    )..where((table) => table.stableKey.equals(stableKeyFor(profileId)))).write(
      BackgroundWorkRequestsCompanion(
        state: Value<String>(BackgroundWorkState.completed.name),
        completedAtUtc: Value<DateTime?>(nowUtc),
        lastFailureCategory: const Value<String?>(null),
        updatedAtUtc: Value<DateTime>(nowUtc),
      ),
    );
  }

  static Future<void> markFailed({
    required AppDatabase database,
    required String profileId,
    required DateTime nowUtc,
    required String failureCategory,
  }) async {
    final row = await _read(database, profileId);
    if (row == null || row.state != BackgroundWorkState.running.name) return;
    final exhausted = row.attemptCount >= maximumAttempts;
    await (database.update(
      database.backgroundWorkRequests,
    )..where((table) => table.stableKey.equals(stableKeyFor(profileId)))).write(
      BackgroundWorkRequestsCompanion(
        state: Value<String>(
          (exhausted
                  ? BackgroundWorkState.failedActionRequired
                  : BackgroundWorkState.retryScheduled)
              .name,
        ),
        lastFailureCategory: Value<String?>(
          exhausted ? 'retry_exhausted' : failureCategory,
        ),
        updatedAtUtc: Value<DateTime>(nowUtc),
      ),
    );
  }

  static Future<BackgroundWorkRequestRow?> _read(
    AppDatabase database,
    String profileId,
  ) {
    if (!_supported(database) || profileId.trim().isEmpty) {
      return Future<BackgroundWorkRequestRow?>.value();
    }
    return (database.select(database.backgroundWorkRequests)
          ..where((table) => table.stableKey.equals(stableKeyFor(profileId)))
          ..limit(1))
        .getSingleOrNull();
  }
}
