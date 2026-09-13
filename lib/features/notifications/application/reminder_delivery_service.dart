import 'package:rmplanner/core/background/background_retry_policy.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// Result of one targeted worker delivery attempt (contract section 32).
///
/// Every value except [retryable] is terminal for the OS: the dispatcher must
/// return true so WorkManager stops retrying.  [uncertain] is a truthful
/// non-delivery outcome, never a fabricated success.
enum ReminderDeliveryOutcome {
  /// A current notification was actually shown.
  posted,

  /// The current generation was already displayed; recorded without re-showing.
  alreadyDisplayed,

  /// The source/permission/quiet-hours state suppressed this reminder.
  suppressed,

  /// This invocation belongs to a superseded dispatch generation.
  superseded,

  /// Malformed, legacy, terminal or unknown work: handled no-op.
  handledObsolete,

  /// A known pre-post transient failure; the caller may retry within budget.
  retryable,

  /// The post outcome cannot be proven: delivery_uncertain, no blind replay.
  uncertain,
}

/// Immutable current-source truth read immediately before posting.
final class ReminderDeliverySnapshot {
  const ReminderDeliverySnapshot({
    required this.sourceKind,
    required this.sourceId,
    required this.occurrenceId,
    required this.sourceActive,
    required this.categoryEnabled,
    required this.showDetails,
    this.sourceTitle,
    this.detailOptions = ReminderDetailOptions.all,
    this.startUtc,
    this.endUtc,
    this.notes,
    this.followUpName,
    this.locationText,
  });

  final ReminderSourceKind sourceKind;
  final String sourceId;
  final String occurrenceId;
  final bool sourceActive;
  final bool categoryEnabled;

  /// Resolved preview mode: true means Detailed is permitted right now.
  final bool showDetails;

  /// VS16 M7 corrective (Astra section 13 owner amendment): the ACTUAL resolved
  /// source title read live from canonical state — the Planner-visible Event
  /// title (stored title, falling back to the Event Type label) or the Task
  /// title.  User emoji is preserved verbatim.  The renderer substitutes its
  /// constant fallback only when this is null or blank.
  final String? sourceTitle;

  /// VS16 M7 corrective: the profile's saved per-field Detailed content
  /// options.  Defaults to all-TRUE so a snapshot constructed without them
  /// keeps the richest Detailed behaviour.
  final ReminderDetailOptions detailOptions;

  final DateTime? startUtc;
  final DateTime? endUtc;
  final String? notes;

  /// Already sanitized by the enrichment resolver; null omits the line.
  final String? followUpName;

  /// Already sanitized by the enrichment resolver; Event sources only.
  final String? locationText;
}

/// Narrow, read-only port that returns the CURRENT canonical source truth.
///
/// Implementations must reread the canonical repositories; they must not replay
/// a scheduled snapshot and must not write anything.
abstract interface class ReminderDeliverySourceReader {
  Future<ReminderDeliverySnapshot?> read({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  });
}

/// VS16-M7 P16 — targeted worker delivery for the current Event/Task occurrence.
///
/// Implements the section 32 spine: strict three-field validation, exact durable
/// dispatch comparison, terminal/superseded no-ops, current source reread,
/// section 64 relevance, render, show and a generation-conditional receipt.
///
/// It never scans the whole horizon, never writes domain state (Event, Task,
/// Contact, Goal, report or ledger) and never fabricates a completion.
final class ReminderDeliveryService {
  const ReminderDeliveryService({
    required this.repository,
    required this.gateway,
    required this.source,
    required this.clock,
  });

  final NotificationFoundationRepository repository;
  final CanonicalReminderDeliveryGateway gateway;
  final ReminderDeliverySourceReader source;
  final AppClock clock;

  static final RegExp _keyPattern = RegExp(r'^reminder:[A-Za-z0-9_.:-]{1,240}$');
  static final RegExp _revisionPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,256}$');

  /// Maximum delivery attempts for ONE dispatch identity (contract section 31).
  ///
  /// The budget is scoped to `(stableKey, target, sourceRevision)` rather than to
  /// the durable row, because a content-only revision refresh starts a NEW
  /// generation and must get its own budget.  A row that already exhausted this
  /// generation's budget is retired instead of being retried forever.
  static const int maxAttemptsPerGeneration =
      BackgroundRetryPolicy.maxAttemptsPerRevision;

  /// Exponential retry backoff: 30 / 60 / 120 / 240 seconds (section 31).
  static Duration backoffFor(int attempt) =>
      BackgroundRetryPolicy.minimumBackoffFor(attempt);

  /// States that mean the reminder episode is already finished.  These are
  /// never replayed, even though WorkManager may still hand us the callback.
  static bool _isTerminal(BackgroundWorkState state) => switch (state) {
    BackgroundWorkState.completed ||
    BackgroundWorkState.cancelledObsolete ||
    BackgroundWorkState.failedActionRequired => true,
    _ => false,
  };

  Future<ReminderDeliveryOutcome> deliver({
    required String stableKey,
    required int scheduledUtcMs,
    required String sourceRevision,
  }) async {
    // 1. Exactly three technical fields, validated types and shapes.
    if (scheduledUtcMs < 0 ||
        !_keyPattern.hasMatch(stableKey) ||
        !_revisionPattern.hasMatch(sourceRevision)) {
      return ReminderDeliveryOutcome.handledObsolete;
    }
    final target = DateTime.fromMillisecondsSinceEpoch(
      scheduledUtcMs,
      isUtc: true,
    );
    final now = clock.nowUtc();

    // 3. The durable row must be THIS dispatch, worker-owned and unfinished.
    final durable = await repository.readWorkRequest(stableKey);
    if (durable == null) return ReminderDeliveryOutcome.handledObsolete;
    if (durable.sourceRevision != sourceRevision ||
        durable.scheduledForUtc == null ||
        !durable.scheduledForUtc!.isAtSameMomentAs(target)) {
      // A superseded invocation must not touch the newer generation.
      return ReminderDeliveryOutcome.superseded;
    }
    if (!(durable.sourceRevision?.contains('m7w_') ?? false)) {
      return ReminderDeliveryOutcome.handledObsolete;
    }
    if (_isTerminal(durable.state)) {
      return ReminderDeliveryOutcome.handledObsolete;
    }

    // Process-death law (contract section 36).  Platform posting and the SQLite
    // commit are NOT one atomic transaction, so a row left `running` means a
    // previous invocation claimed the post but never recorded an outcome.  A
    // blind re-post could duplicate a user-visible alert, which section 36
    // explicitly prefers to avoid.  Inspect the ACTUAL active platform state
    // instead of guessing, and never fabricate a receipt.
    if (durable.state == BackgroundWorkState.running) {
      final interruptedPlatformId = durable.platformNotificationId;
      if (interruptedPlatformId != null &&
          await gateway.hasDisplayedReminder(interruptedPlatformId)) {
        await _completeWithoutAttempt(durable);
        return ReminderDeliveryOutcome.alreadyDisplayed;
      }
      // The outcome cannot be proven.  Report it truthfully; do not re-alert.
      await _record(durable, BackgroundWorkState.failedActionRequired);
      return ReminderDeliveryOutcome.uncertain;
    }

    final profileId = durable.profileId;
    final sourceId = durable.ownerId;
    final occurrenceId = durable.occurrenceId;
    if (profileId == null || sourceId == null || occurrenceId == null) {
      return ReminderDeliveryOutcome.handledObsolete;
    }
    final sourceKind = switch (durable.ownerKind) {
      BackgroundWorkOwnerKind.occurrence => ReminderSourceKind.calendarEvent,
      BackgroundWorkOwnerKind.task => ReminderSourceKind.task,
      _ => null,
    };
    if (sourceKind == null) return ReminderDeliveryOutcome.handledObsolete;

    // 4/5/6. Reread current truth.  A read failure is a bounded retry, never a
    // stale post and never a fabricated completion.
    final ReminderDeliverySnapshot? snapshot;
    try {
      snapshot = await source.read(
        profileId: profileId,
        sourceKind: sourceKind,
        sourceId: sourceId,
        occurrenceId: occurrenceId,
      );
    } on Object {
      // A read failure is retryable only while this generation still has budget.
      // Once exhausted the episode is retired truthfully — never left scheduled
      // forever, and never turned into a fabricated success.
      await _recordRetryable(durable);
      return ReminderDeliveryOutcome.retryable;
    }
    if (snapshot == null ||
        !snapshot.sourceActive ||
        !snapshot.categoryEnabled) {
      await _suppress(durable, 'stale_source');
      return ReminderDeliveryOutcome.suppressed;
    }

    // Section 64: an Event is only relevant until its current canonical end.
    if (sourceKind == ReminderSourceKind.calendarEvent) {
      final start = snapshot.startUtc;
      final end = snapshot.endUtc;
      if (start != null && end != null && end.isAfter(start)) {
        final relevance = ReminderDeliveryEligibility.classifyEvent(
          nowUtc: now,
          startsAtUtc: start,
          endsAtUtc: end,
          targetUtc: target,
          quietAdjustedUtc: target,
        );
        if (relevance == ReminderEventRelevance.obsolete ||
            relevance == ReminderEventRelevance.quietSuppressed) {
          await _suppress(durable, 'stale_source');
          return ReminderDeliveryOutcome.suppressed;
        }
      }
    }

    // 7. Claim under the existing SQLite serialization with an expected-state
    // compare.  A newer generation wins; this invocation then no-ops.
    final claimed = await _claim(durable);
    if (!claimed) return ReminderDeliveryOutcome.superseded;

    final rendered = _render(snapshot, sourceKind);
    final platformId = durable.platformNotificationId;
    if (platformId == null) {
      await _record(durable, BackgroundWorkState.failedActionRequired);
      return ReminderDeliveryOutcome.handledObsolete;
    }

    // 8. Show with the SAME platform id, body-open ID-only payload and no
    // actions.  A prior-generation active id is not a current receipt.
    try {
      await gateway.showCanonicalReminder(
        LocalNotificationRequest(
          platformId: platformId,
          stableKey: stableKey,
          channel: NotificationChannelKind.reminders,
          scheduledAtUtc: target,
          title: rendered.title,
          body: rendered.body,
          responseIntent: NotificationResponseIntent(
            profileId: profileId,
            sourceKind: sourceKind == ReminderSourceKind.calendarEvent
                ? NotificationSourceKind.calendarEvent
                : NotificationSourceKind.task,
            sourceId: sourceId,
            occurrenceId: occurrenceId,
            action: NotificationResponseAction.open,
          ),
        ),
      );
    } on Object {
      // Ambiguous post: do not replay, do not claim success.
      await _record(durable, BackgroundWorkState.failedActionRequired);
      return ReminderDeliveryOutcome.uncertain;
    }

    // 9. Conditional completed receipt.  Only if the generation is still ours.
    final confirmed = await _completeIfCurrent(durable);
    return confirmed
        ? ReminderDeliveryOutcome.posted
        : ReminderDeliveryOutcome.alreadyDisplayed;
  }

  RenderedReminder _render(
    ReminderDeliverySnapshot snapshot,
    ReminderSourceKind sourceKind,
  ) {
    if (!snapshot.showDetails) return ReminderNotificationRenderer.generic;
    return switch (sourceKind) {
      ReminderSourceKind.calendarEvent =>
        ReminderNotificationRenderer.eventDetailed(
          eventTitle: snapshot.sourceTitle,
          startDisplay: snapshot.startUtc,
          endDisplay: snapshot.endUtc,
          notes: snapshot.notes,
          followUpName: snapshot.followUpName,
          locationText: snapshot.locationText,
          options: snapshot.detailOptions,
        ),
      ReminderSourceKind.task => ReminderNotificationRenderer.taskDetailed(
        taskTitle: snapshot.sourceTitle,
        dueMinute: snapshot.startUtc == null
            ? null
            : snapshot.startUtc!.hour * 60 + snapshot.startUtc!.minute,
        notes: snapshot.notes,
        followUpName: snapshot.followUpName,
        options: snapshot.detailOptions,
      ),
      // Planning families never carry M7 enrichment.
      ReminderSourceKind.weeklyReview ||
      ReminderSourceKind.awaitingReport => ReminderNotificationRenderer.generic,
    };
  }

  /// Expected-state claim: only a still-current nonterminal row moves to
  /// running.  Re-reads first so a newer generation always wins.
  Future<bool> _claim(BackgroundWorkRequest durable) async {
    final latest = await repository.readWorkRequest(durable.stableKey);
    if (latest == null ||
        latest.sourceRevision != durable.sourceRevision ||
        _isTerminal(latest.state)) {
      return false;
    }
    await repository.upsertWorkRequest(
      latest.copyWith(
        state: BackgroundWorkState.running,
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    return true;
  }

  /// Completes only when the row is still this exact generation.
  Future<bool> _completeIfCurrent(BackgroundWorkRequest durable) async {
    final latest = await repository.readWorkRequest(durable.stableKey);
    if (latest == null || latest.sourceRevision != durable.sourceRevision) {
      return false;
    }
    await repository.upsertWorkRequest(
      latest.copyWith(
        state: BackgroundWorkState.completed,
        completedAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    return true;
  }

  /// Completes a row that a previous invocation already posted, WITHOUT
  /// charging another delivery attempt.  Used only when an active platform
  /// notification proves the earlier post actually happened.
  Future<void> _completeWithoutAttempt(BackgroundWorkRequest durable) async {
    final latest = await repository.readWorkRequest(durable.stableKey);
    if (latest == null || latest.sourceRevision != durable.sourceRevision) {
      return;
    }
    final now = clock.nowUtc();
    await repository.upsertWorkRequest(
      latest.copyWith(
        state: BackgroundWorkState.completed,
        completedAtUtc: now,
        updatedAtUtc: now,
      ),
    );
  }

  Future<void> _suppress(BackgroundWorkRequest durable, String category) async {
    final latest = await repository.readWorkRequest(durable.stableKey);
    if (latest == null || latest.sourceRevision != durable.sourceRevision) {
      return;
    }
    await repository.upsertWorkRequest(
      latest.copyWith(
        state: BackgroundWorkState.cancelledObsolete,
        lastFailureCategory: category,
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  Future<void> _record(
    BackgroundWorkRequest durable,
    BackgroundWorkState next,
  ) async {
    final latest = await repository.readWorkRequest(durable.stableKey);
    if (latest == null || latest.sourceRevision != durable.sourceRevision) {
      return;
    }
    await repository.upsertWorkRequest(
      latest.copyWith(
        state: next,
        attemptCount: latest.attemptCount + 1,
        lastAttemptAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  /// Records one bounded, still-retryable attempt for THIS generation.
  ///
  /// The budget is per dispatch identity, so the increment is only applied while
  /// the row still belongs to the same generation.  On exhaustion the row is
  /// retired with `retry_exhausted` and the caller's `retryable` outcome lets
  /// the OS stop — the delivery is never silently downgraded to success.
  Future<void> _recordRetryable(BackgroundWorkRequest durable) async {
    final latest = await repository.readWorkRequest(durable.stableKey);
    if (latest == null || latest.sourceRevision != durable.sourceRevision) {
      return;
    }
    final attempt = latest.attemptCount + 1;
    final exhausted = BackgroundRetryPolicy.isTerminalAttempt(attempt);
    final now = clock.nowUtc();
    await repository.upsertWorkRequest(
      latest.copyWith(
        state: exhausted
            ? BackgroundWorkState.failedActionRequired
            : BackgroundWorkState.retryScheduled,
        attemptCount: attempt,
        lastAttemptAtUtc: now,
        // Earliest retry eligibility, NOT a promise of OS execution.
        nextEligibleAtUtc: exhausted
            ? null
            : now.add(BackgroundRetryPolicy.minimumBackoffFor(attempt)),
        lastFailureCategory: exhausted ? 'retry_exhausted' : null,
        updatedAtUtc: now,
      ),
    );
  }
}
