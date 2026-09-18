import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_quiet_hours.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

/// Astra §64 FINAL AT EVENT TIME / LATE DELIVERY LAW — the one shared Event
/// relevance computation used by the reconciler, the targeted delivery
/// service and horizon/recovery (no duplicate time arithmetic).
///
/// S = canonical startUtc, E = canonical endUtc (E > S), L = effective
/// nonnegative offset, T = S - L.  The relevance window is [T, E): a reminder
/// is deliverable from its target until the Event ends — zero offset (At
/// Event Time) is a VALID reminder, and there is no arbitrary 15-minute or
/// 3/5-minute expiry.  Quiet Hours may only delay the target before S.
enum ReminderDeliveryEligibilityOutcome {
  beforeWindow,
  due,
  expired,
}

final class ReminderDeliveryEligibility {
  const ReminderDeliveryEligibility({
    required this.targetUtc,
    required this.quietAdjustedUtc,
    required this.relevanceEndUtc,
    required this.outcome,
  });

  final DateTime targetUtc;

  /// Quiet-Hours-adjusted effective registration/delivery time Q.
  final DateTime quietAdjustedUtc;

  /// E — the Event end.  Delivery is obsolete at or after this instant.
  final DateTime relevanceEndUtc;

  final ReminderDeliveryEligibilityOutcome outcome;

  /// Event-only law.  Task relevance stays "current incomplete timed
  /// occurrence" and MUST NOT apply E (§64 transport scope).
  static ReminderDeliveryEligibility compute({
    required DateTime nowUtc,
    required DateTime startUtc,
    required DateTime endUtc,
    required int offsetMinutes,
    required QuietHoursSettings quietHours,
    tz.Location? deviceLocation,
  }) {
    if (!endUtc.isAfter(startUtc)) {
      throw ArgumentError('Event relevance requires endUtc after startUtc.');
    }
    final target = startUtc.subtract(Duration(minutes: offsetMinutes));
    final quietAdjusted = ReminderQuietHours.delayUntilEnd(
      targetUtc: target,
      settings: quietHours,
      location: deviceLocation,
    );
    final outcome = nowUtc.isBefore(target)
        ? ReminderDeliveryEligibilityOutcome.beforeWindow
        : nowUtc.isBefore(endUtc)
        ? ReminderDeliveryEligibilityOutcome.due
        : ReminderDeliveryEligibilityOutcome.expired;
    return ReminderDeliveryEligibility(
      targetUtc: target,
      quietAdjustedUtc: quietAdjusted,
      relevanceEndUtc: endUtc,
      outcome: outcome,
    );
  }
}

/// M2/M3's source-driven one-shot reminder boundary.  It owns neither Event
/// nor Task persistence: callers invoke it only after their canonical source
/// write has committed successfully.
///
/// Astra §6 transport ownership: each durable Event/Task occurrence key has
/// exactly ONE live delivery owner — native inexact alarm (m7n_) or targeted
/// WorkManager enrichment worker (m7w_).  Selection is A) worker when the
/// current source requests enrichment, B) native otherwise, C) sticky m7w_
/// once assigned.  The choice is persisted in the sourceRevision render
/// suffix; no new column and no private-content flag.
final class ReminderReconciler {
  const ReminderReconciler({
    required this.repository,
    required this.gateway,
    required this.clock,
    this.backgroundWork,
    this.deliveryKey,
    this.deliveryScheduledAtUtc,
    this.deliverySourceRevision,
    this.snoozeIntent,
    this.actionAtUtc,
    this.deviceLocation,
  });

  final NotificationFoundationRepository repository;
  final NotificationGateway gateway;
  final AppClock clock;

  /// Available only when the platform background adapter initialized; null
  /// means worker transport cannot be used and enriched rows stay native
  /// (truthful absence, never a fabricated worker registration).
  final BackgroundWorkGateway? backgroundWork;
  final String? deliveryKey;
  final DateTime? deliveryScheduledAtUtc;
  final String? deliverySourceRevision;
  final NotificationResponseIntent? snoozeIntent;
  final DateTime? actionAtUtc;

  /// Canonical device zone for Quiet Hours arithmetic.  The device default
  /// local zone is only correct inside the main isolate binding; a headless
  /// WorkManager isolate may resolve a different zone, which silently moved
  /// delayed targets onto the wrong wall clock.
  final tz.Location? deviceLocation;

  static bool _sameInstant(DateTime? a, DateTime? b) =>
      a == null ? b == null : b != null && a.isAtSameMomentAs(b);

  static String stableKey({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required String occurrenceId,
  }) => switch (sourceKind) {
    ReminderSourceKind.weeklyReview =>
      'planning:weekly-review:$profileId:$occurrenceId',
    ReminderSourceKind.awaitingReport =>
      'planning:awaiting-report:$profileId:$occurrenceId',
    _ => 'reminder:${sourceKind.name}:$profileId:$occurrenceId:base',
  };

  static String planningStableKey({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required String occurrenceId,
  }) => stableKey(
    sourceKind: sourceKind,
    profileId: profileId,
    occurrenceId: occurrenceId,
  );

  /// Astra §6: transport markers persisted in the sourceRevision suffix.
  static const String workerTransportMarker = 'm7w_';
  static const String nativeTransportMarker = 'm7n_';

  /// The timing-generation token is the identity before the first render
  /// suffix dot (§33/§65 G1).  Null when the revision has no dot-separated
  /// timing identity (legacy planning preview rows).
  static String? transportGenerationPrefix(String? revision) {
    if (revision == null) return null;
    final dot = revision.indexOf('.');
    return dot < 0 ? null : revision.substring(0, dot);
  }

  static bool hasWorkerTransport(String? revision) =>
      revision != null && revision.contains('.$workerTransportMarker');

  /// §65 G1: worker unique name embeds the platform ID, target ms and the
  /// SHA-256 technical digest (first 16 hex chars) of the full revision.
  static String workerUniqueName({
    required int platformId,
    required DateTime scheduledForUtc,
    required String sourceRevision,
  }) =>
      'nt.reminder.$platformId.'
      '${scheduledForUtc.millisecondsSinceEpoch}.'
      '${sha256.convert(utf8.encode(sourceRevision)).toString().substring(0, 16)}';

  /// Astra §9: timing-only writes MUST preserve existing purpose/contactId
  /// (F02).  Purpose changes are explicit: [purpose] omitted means preserve;
  /// [ReminderPurpose.standard] explicitly clears the stored Contact;
  /// [ReminderPurpose.contactFollowUp] sets/keeps [purposeContactId].
  Future<ReminderPolicy> savePolicy({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required ReminderPolicyMode mode,
    int? offsetMinutes,
    ReminderPurpose? purpose,
    String? purposeContactId,
  }) async {
    final now = clock.nowUtc();
    final policies = await repository.readPolicies(
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
    );
    final existing = policies
        .where((policy) => policy.occurrenceId == occurrenceId)
        .firstOrNull;
    final seriesPolicy = policies
        .where((policy) => policy.occurrenceId == ReminderPolicy.seriesOccurrenceId)
        .firstOrNull;
    // §9: a NEW occurrence timing override copies the effective source-level
    // purpose/contactId (the explicit intent belongs to the source, not one
    // date); an EXISTING occurrence override keeps its own purpose unless the
    // caller explicitly changes it.  A series row itself never inherits from
    // anything else.
    final purposeFallback = occurrenceId == ReminderPolicy.seriesOccurrenceId
        ? null
        : seriesPolicy?.purpose;
    final contactFallback = purposeFallback == null
        ? null
        : seriesPolicy?.contactId;
    final effectivePurpose =
        purpose ??
        existing?.purpose ??
        purposeFallback ??
        ReminderPurpose.standard;
    final effectiveContactId = switch (effectivePurpose) {
      ReminderPurpose.contactFollowUp =>
        purposeContactId ??
            existing?.contactId ??
            (purpose == null ? contactFallback : null),
      ReminderPurpose.standard => null,
    };
    return repository.upsertPolicy(
      ReminderPolicy(
        id: existing?.id ?? const Uuid().v4(),
        profileId: profileId,
        sourceKind: sourceKind,
        sourceId: sourceId,
        occurrenceId: occurrenceId,
        purpose: effectivePurpose,
        contactId: effectiveContactId,
        mode: mode,
        offsetMinutes: mode == ReminderPolicyMode.offset ? offsetMinutes : null,
        createdAtUtc: existing?.createdAtUtc ?? now,
        updatedAtUtc: now,
      ),
    );
  }

  Future<void> cancel({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required String occurrenceId,
  }) async {
    final key = planningStableKey(
      sourceKind: sourceKind,
      profileId: profileId,
      occurrenceId: occurrenceId,
    );
    final existing = await repository.readWorkRequest(key);
    if (existing?.platformNotificationId case final platformId?) {
      await gateway.cancel(platformId);
    }
    // §18/§65 G5: cancel the exact old worker unique name — never a tag-wide
    // sweep that could kill a replacement installed by a newer generation.
    if (existing != null && hasWorkerTransport(existing.sourceRevision)) {
      final background = backgroundWork;
      final platformId = existing.platformNotificationId;
      final scheduledAt = existing.scheduledForUtc;
      if (background != null && platformId != null && scheduledAt != null) {
        await background.cancelUnique(
          workerUniqueName(
            platformId: platformId,
            scheduledForUtc: scheduledAt,
            sourceRevision: existing.sourceRevision!,
          ),
        );
      }
    }
    if (existing != null) {
      await repository.upsertWorkRequest(
        existing.copyWith(
          state: BackgroundWorkState.cancelledObsolete,
          updatedAtUtc: clock.nowUtc(),
        ),
      );
    }
  }

  Future<void> reconcile({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required String sourceId,
    required String occurrenceId,
    required DateTime? startsAtUtc,
    DateTime? scheduledAtUtc,
    required int? globalOffsetMinutes,
    required bool categoryEnabled,
    required bool systemEnabled,
    required bool sourceActive,
    required String genericTitle,
    required String genericBody,
    String? detailedTitle,
    String? detailedBody,
    bool showDetails = false,
    bool refreshContent = false,
    String? renderRevision,
    int? sourceVersion,
    DateTime? contactUpdatedAtUtc,
    bool enrichmentRequested = false,
  }) async {
    final key = planningStableKey(
      sourceKind: sourceKind,
      profileId: profileId,
      occurrenceId: occurrenceId,
    );
    final existing = await repository.readWorkRequest(key);
    final policies = await repository.readPolicies(
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
    );
    final policy =
        policies.where((p) => p.occurrenceId == occurrenceId).firstOrNull ??
        policies
            .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
            .firstOrNull;
    final offset = switch (policy?.mode) {
      ReminderPolicyMode.offset => policy!.offsetMinutes,
      ReminderPolicyMode.off => null,
      _ => globalOffsetMinutes,
    };
    final baseFireAt =
        scheduledAtUtc ??
        (startsAtUtc == null || offset == null
            ? null
            : startsAtUtc.subtract(Duration(minutes: offset)));
    // Astra §33 technical revision law: identity carries source version,
    // timing, policy timestamp, resolved Contact timestamp (when available)
    // and effective offset — technical IDs/timestamps only, never names or
    // note hashes.  A content-only change (Contact rename) advances the
    // fingerprint without minting a new timing generation (§65 G3).
    final identity = sourceVersion == null
        ? null
        : 'm4_${sourceVersion}_${startsAtUtc?.microsecondsSinceEpoch ?? 0}_${offset ?? -1}_${policy?.updatedAtUtc.microsecondsSinceEpoch ?? 0}'
          '${contactUpdatedAtUtc == null ? '' : '_${contactUpdatedAtUtc.microsecondsSinceEpoch}'}';
    // §6 transport selection: sticky worker evidence first, then current
    // truth.  Planning rows never select worker transport.
    final stickyWorker = hasWorkerTransport(existing?.sourceRevision);
    final wantsWorker =
        sourceKind == ReminderSourceKind.calendarEvent ||
            sourceKind == ReminderSourceKind.task
        ? (stickyWorker || enrichmentRequested) && backgroundWork != null
        : false;
    final transportMarker = wantsWorker
        ? workerTransportMarker
        : identity == null
        ? ''
        : nativeTransportMarker;
    final revision = identity == null
        ? renderRevision
        : '$identity.$transportMarker${renderRevision ?? 'generic'}';
    final sameSource = identity == null
        ? existing?.sourceRevision == revision
        : existing?.sourceRevision?.split('.').first == identity;
    final now = clock.nowUtc();
    final action = snoozeIntent;
    final requestedSnooze =
        action != null &&
        action.action == NotificationResponseAction.snooze &&
        action.profileId == profileId &&
        action.sourceId == sourceId &&
        action.occurrenceId == occurrenceId &&
        action.sourceKind.name == sourceKind.name;
    final acceptsSnooze =
        requestedSnooze &&
        existing != null &&
        sameSource &&
        existing.snoozeCount == action.generation &&
        (existing.state == BackgroundWorkState.completed ||
            (existing.state == BackgroundWorkState.scheduled &&
                existing.scheduledForUtc != null &&
                !existing.scheduledForUtc!.isAfter(now)));
    final priorSnooze =
        sameSource &&
            existing != null &&
            existing.snoozeCount > 0 &&
            (existing.state == BackgroundWorkState.scheduled ||
                existing.state == BackgroundWorkState.queued)
        ? existing.nextEligibleAtUtc
        : null;
    final preferences = await repository.readPreferences(profileId: profileId);
    final snoozedUntil = acceptsSnooze
        ? DateTime.fromMillisecondsSinceEpoch(
            (actionAtUtc ?? now).millisecondsSinceEpoch ~/ 1000 * 1000,
            isUtc: true,
          ).add(Duration(minutes: preferences.snoozeDurationMinutes))
        : priorSnooze;
    final proposed = snoozedUntil ?? baseFireAt;
    var fireAt = proposed == null
        ? null
        : ReminderQuietHours.delayUntilEnd(
            targetUtc: proposed,
            settings: preferences.quietHours,
            location: deviceLocation,
          );
    final delivery =
        deliveryKey == key &&
        existing != null &&
        sameSource &&
        existing.state == BackgroundWorkState.scheduled &&
        _sameInstant(existing.scheduledForUtc, deliveryScheduledAtUtc) &&
        _sameInstant(fireAt, existing.scheduledForUtc) &&
        fireAt != null &&
        !fireAt.isAfter(now);
    if (delivery) {
      // Inexact execution can reach a different quiet interval from its target.
      final allowed = ReminderQuietHours.delayUntilEnd(
        targetUtc: now,
        settings: preferences.quietHours,
        location: deviceLocation,
      );
      if (allowed.isAfter(now)) fireAt = allowed;
    }
    // Astra §64 replaces the original start-expiry law.  For WORKER rows the
    // relevance window is [T, E): a due delivery inside the window is valid,
    // including zero-offset At-Event-Time rows that always fire at/after S.
    // For NATIVE rows the inexact alarm keeps its pending/active evidence
    // window below; a past-target native row with neither is obsolete truth,
    // never an undocumented immediate alarm.
    final workerOwned = wantsWorker;
    final workerRevision = workerOwned ? revision : null;
    final eventObsolete =
        sourceKind == ReminderSourceKind.calendarEvent &&
        startsAtUtc != null &&
        fireAt != null &&
        (workerOwned
            ? (delivery &&
                (startsAtUtc.isAtSameMomentAs(fireAt) ||
                    fireAt.isAfter(startsAtUtc)) &&
                (scheduledAtUtc ?? startsAtUtc).isBefore(fireAt))
            : ((delivery && !startsAtUtc.isAfter(now)) ||
                (fireAt != baseFireAt && !startsAtUtc.isAfter(fireAt))));
    final eligible =
        preferences.systemNotificationsEnabled &&
        _categoryEnabled(preferences, sourceKind) &&
        systemEnabled &&
        categoryEnabled &&
        sourceActive &&
        baseFireAt != null &&
        fireAt != null &&
        !eventObsolete;
    if (!eligible || (!fireAt.isAfter(now) && !delivery)) {
      // Keep an already displayed valid reminder actionable; a source/preference
      // change still cancels it. Recovery never turns an expired target into now.
      if (eligible &&
          sameSource &&
          existing?.state == BackgroundWorkState.completed) {
        return;
      }
      // Astra §64: a due WORKER row inside the relevance window is repairable,
      // not obsolete — fall through to (re)registration below instead of
      // cancelling, unless the window itself has closed.
      final workerDueRepair =
          workerOwned &&
          eligible &&
          sameSource &&
          !fireAt.isAfter(now) &&
          (sourceKind != ReminderSourceKind.calendarEvent ||
              (startsAtUtc != null &&
                  (startsAtUtc.isAfter(fireAt) ||
                      startsAtUtc.isAtSameMomentAs(fireAt))));
      if (workerDueRepair) {
        // Guard against replaying a row the worker already completed for this
        // same generation; only absent/unfinished registrations re-enqueue.
        if (existing?.state == BackgroundWorkState.completed) return;
        if (existing?.state == BackgroundWorkState.cancelledObsolete) return;
      } else {
        // Native inexact alarms do not call the Dart delivery worker. A past
        // target can therefore still be pending or already visible while its
        // durable state remains scheduled. Recovery (including another reminder's
        // Snooze pass) must not cancel that valid notification before its action.
        final platform = gateway;
        if (eligible &&
            sameSource &&
            existing?.state == BackgroundWorkState.scheduled &&
            existing?.platformNotificationId != null &&
            _sameInstant(existing?.scheduledForUtc, fireAt) &&
            (sourceKind != ReminderSourceKind.calendarEvent ||
                startsAtUtc!.isAfter(now)) &&
            platform is CanonicalReminderDeliveryGateway) {
          final native = platform as CanonicalReminderDeliveryGateway;
          final platformId = existing!.platformNotificationId!;
          if (await native.hasPendingReminder(platformId, fireAt)) return;
          if (await native.hasDisplayedReminder(platformId)) {
            await repository.upsertWorkRequest(
              existing.copyWith(
                state: BackgroundWorkState.completed,
                completedAtUtc: now,
                updatedAtUtc: now,
              ),
            );
            return;
          }
        }
        await cancel(
          sourceKind: sourceKind,
          profileId: profileId,
          occurrenceId: occurrenceId,
        );
        return;
      }
    }
    final generation = acceptsSnooze
        ? existing.snoozeCount + 1
        : snoozedUntil != null
        ? existing!.snoozeCount
        : 0;
    // Astra §65 G2: a NEW dispatch generation (changed target or technical
    // revision for an undelivered eligible reminder) resets the attempt
    // budget and clears stale failure evidence.  Same-generation repair
    // preserves attempts/backoff.
    final generationChanged =
        existing == null ||
        !_sameInstant(existing.scheduledForUtc, fireAt) ||
        existing.sourceRevision != revision;
    var durable = BackgroundWorkRequest(
      stableKey: key,
      profileId: profileId,
      category: BackgroundWorkCategory.reminderRecovery,
      ownerKind: switch (sourceKind) {
        ReminderSourceKind.calendarEvent => BackgroundWorkOwnerKind.occurrence,
        ReminderSourceKind.task => BackgroundWorkOwnerKind.task,
        ReminderSourceKind.weeklyReview ||
        ReminderSourceKind.awaitingReport => BackgroundWorkOwnerKind.planning,
      },
      ownerId: sourceId,
      occurrenceId: occurrenceId,
      sourceRevision: revision,
      scheduledForUtc: fireAt,
      state: BackgroundWorkState.queued,
      platformNotificationId: existing?.platformNotificationId,
      attemptCount: generationChanged ? 0 : existing.attemptCount,
      snoozeCount: generation,
      nextEligibleAtUtc: snoozedUntil,
      completedAtUtc: generationChanged ? null : existing.completedAtUtc,
      lastFailureCategory: generationChanged ? null : existing.lastFailureCategory,
      createdAtUtc: existing?.createdAtUtc ?? now,
      updatedAtUtc: now,
    );
    final platform = gateway;
    if (!delivery &&
        !acceptsSnooze &&
        !workerOwned &&
        existing?.state == BackgroundWorkState.scheduled &&
        _sameInstant(existing?.scheduledForUtc, fireAt) &&
        existing?.sourceRevision == revision &&
        (platform is! CanonicalReminderDeliveryGateway ||
            await (platform as CanonicalReminderDeliveryGateway)
                .hasPendingReminder(
                  existing!.platformNotificationId!,
                  fireAt,
                ))) {
      return;
    }
    if (workerRevision != null) {
      await _reconcileWorkerTransport(
        sourceKind: sourceKind,
        profileId: profileId,
        sourceId: sourceId,
        occurrenceId: occurrenceId,
        key: key,
        existing: existing,
        durable: durable,
        revision: workerRevision,
        fireAt: fireAt,
        now: now,
        showDetails: showDetails,
        detailedTitle: detailedTitle,
        genericTitle: genericTitle,
        genericBody: genericBody,
        generation: generation,
        delivery: delivery,
      );
      return;
    }
    if (existing?.platformNotificationId != null &&
        !_sameInstant(existing?.scheduledForUtc, fireAt)) {
      await gateway.cancel(existing!.platformNotificationId!);
    }
    durable = await repository.upsertWorkRequest(durable);
    final platformId =
        durable.platformNotificationId ??
        await repository.allocatePlatformNotificationId(key);
    final intent = NotificationResponseIntent(
      profileId: profileId,
      sourceKind: switch (sourceKind) {
        ReminderSourceKind.calendarEvent =>
          NotificationSourceKind.calendarEvent,
        ReminderSourceKind.task => NotificationSourceKind.task,
        ReminderSourceKind.weeklyReview => NotificationSourceKind.weeklyReview,
        ReminderSourceKind.awaitingReport =>
          NotificationSourceKind.awaitingReport,
      },
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      action: NotificationResponseAction.open,
      generation: generation,
    );
    final request = LocalNotificationRequest(
      platformId: platformId,
      stableKey: key,
      channel: switch (sourceKind) {
        ReminderSourceKind.weeklyReview ||
        ReminderSourceKind.awaitingReport => NotificationChannelKind.planning,
        _ => NotificationChannelKind.reminders,
      },
      scheduledAtUtc: fireAt,
      title: showDetails && detailedTitle != null
          ? detailedTitle
          : genericTitle,
      body: showDetails && detailedBody != null ? detailedBody : genericBody,
      responseIntent: intent,
    );
    Future<bool> stillEnabled() async {
      final latest = await repository.readPreferences(profileId: profileId);
      return latest.systemNotificationsEnabled &&
          _categoryEnabled(latest, sourceKind);
    }

    Future<void> cancelDisabled() async {
      await gateway.cancel(platformId);
      await repository.upsertWorkRequest(
        durable.copyWith(
          state: BackgroundWorkState.cancelledObsolete,
          platformNotificationId: platformId,
          updatedAtUtc: clock.nowUtc(),
        ),
      );
    }

    // An OFF write can overtake an already-running horizon or platform call.
    if (!await stillEnabled()) {
      await cancelDisabled();
      return;
    }
    final deliverNow = delivery && !fireAt.isAfter(now);
    if (deliverNow && platform is CanonicalReminderDeliveryGateway) {
      await (platform as CanonicalReminderDeliveryGateway)
          .showCanonicalReminder(request);
    } else {
      await gateway.schedule(request);
    }
    if (!await stillEnabled()) {
      await cancelDisabled();
      return;
    }
    await repository.upsertWorkRequest(
      durable.copyWith(
        state: deliverNow
            ? BackgroundWorkState.completed
            : BackgroundWorkState.scheduled,
        platformNotificationId: platformId,
        updatedAtUtc: clock.nowUtc(),
        completedAtUtc: deliverNow ? clock.nowUtc() : null,
      ),
    );
  }

  /// Astra §6C/§12/§65: worker-transport registration.  One stable key, one
  /// platform ID, one live owner.  The exact previous generation's worker
  /// unique name is cancelled before installing the new owner (never a
  /// tag-wide cancel, never after the new enqueue — G5).
  Future<void> _reconcileWorkerTransport({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required String sourceId,
    required String occurrenceId,
    required String key,
    required BackgroundWorkRequest? existing,
    required BackgroundWorkRequest durable,
    required String revision,
    required DateTime fireAt,
    required DateTime now,
    required bool showDetails,
    required String? detailedTitle,
    required String genericTitle,
    required String genericBody,
    required int generation,
    required bool delivery,
  }) async {
    final background = backgroundWork!;
    // Sticky/same-generation idempotence: identical generation already
    // durably scheduled or completed needs no re-enqueue.
    final unchanged =
        existing != null &&
        existing.sourceRevision == revision &&
        _sameInstant(existing.scheduledForUtc, fireAt) &&
        (existing.state == BackgroundWorkState.scheduled ||
            existing.state == BackgroundWorkState.queued ||
            existing.state == BackgroundWorkState.completed ||
            existing.state == BackgroundWorkState.running);
    final platformId =
        durable.platformNotificationId ??
        await repository.allocatePlatformNotificationId(key);
    final newUniqueName = workerUniqueName(
      platformId: platformId,
      scheduledForUtc: fireAt,
      sourceRevision: revision,
    );
    if (unchanged) {
      // §65 matrix ABSENT repair: a queued/scheduled row whose platform job
      // vanished (crash gap) is repaired with KEEP, preserving the budget.
      final state = await background.inspect(newUniqueName);
      if (state == BackgroundGatewayWorkState.absent) {
        if (existing.state == BackgroundWorkState.completed) return;
        await background.enqueueUnique(
          BackgroundWorkSpec(
            uniqueName: newUniqueName,
            taskName: 'nt.reminder.delivery',
            inputData: <String, Object>{
              'stable_key': key,
              'scheduled_utc_ms': fireAt.millisecondsSinceEpoch,
              'source_revision': revision,
            },
            initialDelay: fireAt.isAfter(now)
                ? fireAt.difference(now)
                : Duration.zero,
            tag: 'nt.reminder.$platformId',
            existingPolicy: BackgroundExistingWorkPolicy.keep,
            backoffPolicy: BackgroundBackoffPolicy.exponential,
            backoffPolicyDelay: const Duration(seconds: 30),
          ),
        );
      }
      return;
    }
    // G5: cancel the exact old worker name (old generation) before enqueue.
    if (existing != null &&
        hasWorkerTransport(existing.sourceRevision) &&
        existing.platformNotificationId != null &&
        existing.scheduledForUtc != null &&
        existing.sourceRevision != revision) {
      final oldName = workerUniqueName(
        platformId: existing.platformNotificationId!,
        scheduledForUtc: existing.scheduledForUtc!,
        sourceRevision: existing.sourceRevision!,
      );
      if (oldName != newUniqueName) {
        await background.cancelUnique(oldName);
      }
    }
    // Transport switch native -> worker (§18): the old native alarm must go
    // before the worker owner is installed.
    if (existing != null &&
        !hasWorkerTransport(existing.sourceRevision) &&
        existing.platformNotificationId != null) {
      await gateway.cancel(existing.platformNotificationId!);
    }
    durable = await repository.upsertWorkRequest(
      durable.copyWith(platformNotificationId: platformId),
    );
    await background.enqueueUnique(
      BackgroundWorkSpec(
        uniqueName: newUniqueName,
        taskName: 'nt.reminder.delivery',
        inputData: <String, Object>{
          'stable_key': key,
          'scheduled_utc_ms': fireAt.millisecondsSinceEpoch,
          'source_revision': revision,
        },
        initialDelay: fireAt.isAfter(now) ? fireAt.difference(now) : Duration.zero,
        tag: 'nt.reminder.$platformId',
        existingPolicy: BackgroundExistingWorkPolicy.keep,
        backoffPolicy: BackgroundBackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(seconds: 30),
      ),
    );
    // §65 G4: mark scheduled only if the generation is still current.
    final latest = await repository.readWorkRequest(key);
    if (latest == null ||
        latest.sourceRevision != revision ||
        (latest.scheduledForUtc != null &&
            !latest.scheduledForUtc!.isAtSameMomentAs(fireAt))) {
      return;
    }
    await repository.upsertWorkRequest(
      durable.copyWith(
        state: BackgroundWorkState.scheduled,
        platformNotificationId: platformId,
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  static bool _categoryEnabled(
    NotificationPreferences preferences,
    ReminderSourceKind sourceKind,
  ) => switch (sourceKind) {
    ReminderSourceKind.calendarEvent => preferences.eventRemindersEnabled,
    ReminderSourceKind.task => preferences.taskRemindersEnabled,
    ReminderSourceKind.weeklyReview => preferences.weeklyReviewRemindersEnabled,
    ReminderSourceKind.awaitingReport =>
      preferences.awaitingReportRemindersEnabled,
  };
}
