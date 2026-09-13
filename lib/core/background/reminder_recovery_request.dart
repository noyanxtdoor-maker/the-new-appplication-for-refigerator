import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/background_retry_policy.dart';
import 'package:rmplanner/core/background/background_work_request.dart';

import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/time/app_clock.dart';

/// Transaction-local reminder reconciliation marker (contract sections 27/30).
///
/// A canonical mutation that can change an Event/Task reminder's timing,
/// eligibility, live link or privacy permission persists this marker INSIDE ITS
/// OWN TRANSACTION.  Doing so means a later platform/plugin failure cannot erase
/// the committed intent to reconcile: the marker survives, and background
/// recovery consumes and clears it.
///
/// The marker uses the EXISTING `background_work_requests` table — it is a new
/// logical row, not a schema change.  It is explicitly NOT a notification and
/// NOT owner-domain truth: it carries no platform ID, no target instant and no
/// attempt budget of its own beyond the bounded repair law.
///
/// Writers pass their OWN transaction-bound [AppDatabase] (obtained from
/// `database.transaction(...)` or the default accessor) so the marker commits
/// atomically with the mutation it accompanies.
final class ReminderRecoveryRequest {
  const ReminderRecoveryRequest({
    required this.database,
    required this.clock,
    required this.identifiers,
  });

  final AppDatabase database;
  final AppClock clock;
  final IdentifierSource identifiers;

  /// The one device/global marker key per profile.
  static String stableKeyFor(String profileId) =>
      'reconcile:reminders:$profileId';

  /// States in which a repair episode is still live.
  ///
  /// A live episode keeps its attempt budget and its original creation instant:
  /// a burst of mutations must never restart a repair, and must never discard
  /// bounded retry progress.  A terminal episode is finished, so the next real
  /// mutation opens a NEW episode with a fresh budget.
  static bool isLiveEpisode(BackgroundWorkState state) => switch (state) {
    BackgroundWorkState.queued ||
    BackgroundWorkState.running ||
    BackgroundWorkState.retryScheduled ||
    BackgroundWorkState.waitingForConstraints ||
    BackgroundWorkState.delayedBySystem => true,
    BackgroundWorkState.scheduled ||
    BackgroundWorkState.completed ||
    BackgroundWorkState.cancelledObsolete ||
    BackgroundWorkState.failedActionRequired => false,
  };

  /// Records pending reconciliation for [profileId] on [executor].
  ///
  /// The write is idempotent in the only sense that matters: an existing live
  /// episode keeps its STATE and its bounded attempt budget, so a burst of
  /// mutations collapses into ONE pending repair that cannot be restarted or
  /// have its retry progress discarded.
  ///
  /// Every mark mints a NEW technical revision, and the revision IS the dirty
  /// generation.  That is deliberate:
  ///  * a mutation that lands while a pass is running must be detectable, and
  ///    the only durable field a writer can change without touching the attempt
  ///    budget is the revision;
  ///  * a bookkeeping timestamp cannot serve as the token, because the pass's
  ///    own attempt writes also advance it — which would invalidate the token
  ///    the pass captured and silently stop the bounded retry at attempt 1.
  ///
  /// The revision is a technical UUID.  It never carries private content, and
  /// it is never derived from Event/Task/Contact/Goal text.
  Future<void> mark(
    DatabaseConnectionUser executor, {
    required String profileId,
  }) async {
    final key = stableKeyFor(profileId);
    final now = clock.nowUtc();
    final existing = await read(executor, profileId: profileId);
    // A live episode keeps its state and budget; a terminal one is finished, so
    // the next real mutation opens a NEW episode with a fresh budget.
    final live = existing != null && isLiveEpisode(existing.state)
        ? existing
        : null;

    await executor
        .into(database.backgroundWorkRequests)
        .insertOnConflictUpdate(
          BackgroundWorkRequestsCompanion.insert(
            stableKey: key,
            profileId: Value(profileId),
            category: BackgroundWorkCategory.reminderRecovery.name,
            ownerKind: BackgroundWorkOwnerKind.profile.name,
            ownerId: Value(profileId),
            occurrenceId: const Value(null),
            // Each mark is a new dirty generation, so an in-flight pass always
            // notices that canonical truth changed underneath it.
            sourceRevision: Value(identifiers.nextUuid()),
            scheduledForUtc: const Value(null),
            state: live?.state.name ?? BackgroundWorkState.queued.name,
            platformNotificationId: const Value(null),
            attemptCount: Value(live?.attemptCount ?? 0),
            snoozeCount: Value(live?.snoozeCount ?? 0),
            lastAttemptAtUtc: Value(live?.lastAttemptAtUtc),
            nextEligibleAtUtc: Value(live?.nextEligibleAtUtc),
            completedAtUtc: const Value(null),
            lastFailureCategory: Value(live?.lastFailureCategory),
            createdAtUtc: live?.createdAtUtc ?? now,
            updatedAtUtc: now,
          ),
        );
  }

  /// Reads the current marker, or null when no repair is pending.
  Future<BackgroundWorkRequest?> read(
    DatabaseConnectionUser executor, {
    required String profileId,
  }) async {
    final row =
        await (executor.select(database.backgroundWorkRequests)
              ..where(
                (table) => table.stableKey.equals(stableKeyFor(profileId)),
              )
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// The dirty-generation token: the marker's technical revision.
  ///
  /// Null means "no pending repair".  It is a UUID minted by the marking
  /// mutation and is never persisted as content.
  ///
  /// It is deliberately NOT the bookkeeping timestamp: a pass's own attempt
  /// writes advance `updatedAtUtc`, so a timestamp token would be invalidated by
  /// the very attempt it is supposed to authorise, and the bounded retry would
  /// silently stop after attempt 1.
  static String? generationToken(BackgroundWorkRequest? row) =>
      row?.sourceRevision;

  /// `queued`/`retryScheduled` -> `running` for one captured generation.
  ///
  /// Returns the captured generation token, or null when there is nothing to
  /// repair.  A terminal marker is never resurrected.
  Future<String?> claimRunning(
    DatabaseConnectionUser executor, {
    required String profileId,
  }) async {
    final existing = await read(executor, profileId: profileId);
    if (existing == null || !isLiveEpisode(existing.state)) return null;
    final now = clock.nowUtc();
    await _write(
      executor,
      existing.stableKey,
      BackgroundWorkRequestsCompanion(
        state: Value(BackgroundWorkState.running.name),
        lastAttemptAtUtc: Value(now),
        updatedAtUtc: Value(now),
      ),
    );
    return generationToken(existing);
  }

  /// Marks the captured generation `completed` — but ONLY if it is still the
  /// generation the pass actually reconciled.
  ///
  /// Returns true when the marker was consumed.  False means a newer mutation
  /// arrived while the pass was running, so the caller must run exactly one
  /// trailing pass rather than stamping newer truth with an older result.
  Future<bool> completeIfUnchanged(
    DatabaseConnectionUser executor, {
    required String profileId,
    required String capturedToken,
  }) async {
    final existing = await read(executor, profileId: profileId);
    if (existing == null) return true;
    if (generationToken(existing) != capturedToken) return false;
    final now = clock.nowUtc();
    await _write(
      executor,
      existing.stableKey,
      BackgroundWorkRequestsCompanion(
        state: Value(BackgroundWorkState.completed.name),
        completedAtUtc: Value(now),
        nextEligibleAtUtc: const Value(null),
        lastFailureCategory: const Value(null),
        updatedAtUtc: Value(now),
      ),
    );
    return true;
  }

  /// Records one failed repair attempt for the captured generation under the
  /// bounded retry law (section 31).
  ///
  /// A superseded generation is left alone: a newer dirty mark owns the repair
  /// now.  The attempt count is committed OUTSIDE any transaction that is going
  /// to roll back, so an exception inside the pass cannot lose it.
  Future<void> recordRepairFailure(
    DatabaseConnectionUser executor, {
    required String profileId,
    required String capturedToken,
    required String failureCategory,
  }) async {
    final existing = await read(executor, profileId: profileId);
    if (existing == null) return;
    if (generationToken(existing) != capturedToken) return;
    final now = clock.nowUtc();
    final attempt = existing.attemptCount + 1;
    final exhausted = BackgroundRetryPolicy.isTerminalAttempt(attempt);
    await _write(
      executor,
      existing.stableKey,
      BackgroundWorkRequestsCompanion(
        state: Value(
          (exhausted
                  ? BackgroundWorkState.failedActionRequired
                  : BackgroundWorkState.retryScheduled)
              .name,
        ),
        attemptCount: Value(attempt),
        lastAttemptAtUtc: Value(now),
        nextEligibleAtUtc: Value(
          exhausted
              ? null
              : now.add(BackgroundRetryPolicy.minimumBackoffFor(attempt)),
        ),
        lastFailureCategory: Value(
          exhausted ? 'retry_exhausted' : failureCategory,
        ),
        updatedAtUtc: Value(now),
      ),
    );
  }

  Future<void> _write(
    DatabaseConnectionUser executor,
    String stableKey,
    BackgroundWorkRequestsCompanion companion,
  ) async {
    await (executor.update(database.backgroundWorkRequests)
          ..where((table) => table.stableKey.equals(stableKey)))
        .write(companion);
  }

  static BackgroundWorkRequest _map(BackgroundWorkRequestRow row) =>
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
}
