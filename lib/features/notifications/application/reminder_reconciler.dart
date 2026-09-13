import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
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

/// Narrow port for scheduling canonical M7 worker delivery.
///
/// Injected by the composition layer so this application service never depends
/// on the WorkManager package, and so the worker input can be built by the one
/// component that owns the strict three-key contract (sections 6/14).
typedef ScheduleCanonicalReminderWork =
    Future<void> Function({
      required String stableKey,
      required DateTime scheduledAtUtc,
      required String sourceRevision,
      required int platformNotificationId,
    });

/// Narrow port for releasing an already-registered canonical M7 worker job.
///
/// Section 6 allows exactly one live delivery owner per logical reminder.  When
/// a key that already owns worker transport becomes ineligible, the durable row
/// is cancelled — but the queued WorkManager job would otherwise survive as a
/// second, orphaned owner.  The composition layer supplies the real cancel; the
/// application layer never depends on the WorkManager package.
typedef CancelCanonicalReminderWork = Future<void> Function(String uniqueName);

/// M7 transport markers persisted in the `sourceRevision` render suffix
/// (contract section 6).  No new column and no private-content flag is added.
///
/// * [_workerTransportPrefix] — this key is owned by the targeted worker.
/// * [_nativeTransportPrefix] — this key is owned by the ordinary native
///   alarm.  Section 6 requires the transport choice to be *persisted* so that
///   later comparisons know which transport owns the row; section 33 lists the
///   `m7w_`/`m7n_` marker among the technical revision tokens.  Both markers
///   therefore enter the render suffix.
///
/// Absent/legacy rows carry no marker and select their transport once from
/// current truth; a row already carrying `m7w_` keeps worker transport forever
/// for that key (section 6C stickiness).
const String _workerTransportPrefix = 'm7w_';
const String _nativeTransportPrefix = 'm7n_';

/// M2/M3's source-driven one-shot reminder boundary.  It owns neither Event
/// nor Task persistence: callers invoke it only after their canonical source
/// write has committed successfully.
final class ReminderReconciler {
  const ReminderReconciler({
    required this.repository,
    required this.gateway,
    required this.clock,
    this.deliveryKey,
    this.deliveryScheduledAtUtc,
    this.snoozeIntent,
    this.actionAtUtc,
    this.deviceLocation,
    this.scheduleWorker,
    this.cancelWorker,
  });

  final NotificationFoundationRepository repository;
  final NotificationGateway gateway;
  final AppClock clock;
  final String? deliveryKey;
  final DateTime? deliveryScheduledAtUtc;
  final NotificationResponseIntent? snoozeIntent;
  final DateTime? actionAtUtc;

  /// Canonical device zone for Quiet Hours arithmetic.  The device default
  /// local zone is only correct inside the main isolate binding; a headless
  /// WorkManager isolate may resolve a different zone, which silently moved
  /// delayed targets onto the wrong wall clock.
  final tz.Location? deviceLocation;

  /// Optional M7 worker-transport port.  When absent the reconciler stays on
  /// native ordinary transport, so a key is never marked `m7w_` without a real
  /// worker registration behind it (contract sections 6/18).
  final ScheduleCanonicalReminderWork? scheduleWorker;

  /// Optional M7 worker-transport release port.  Paired with [scheduleWorker] so
  /// a cancelled/obsolete worker row also releases its queued WorkManager job
  /// and never leaves two live delivery owners behind (contract section 6).
  final CancelCanonicalReminderWork? cancelWorker;

  /// The persisted transport marker for a durable revision, if any.
  static String? transportOf(String? sourceRevision) {
    if (sourceRevision == null) return null;
    if (sourceRevision.contains(_workerTransportPrefix)) {
      return _workerTransportPrefix;
    }
    if (sourceRevision.contains(_nativeTransportPrefix)) {
      return _nativeTransportPrefix;
    }
    return null;
  }

  /// True when the persisted revision says the targeted worker owns this key.
  static bool ownsWorkerTransport(String? sourceRevision) =>
      transportOf(sourceRevision) == _workerTransportPrefix;

  static bool _sameInstant(DateTime? a, DateTime? b) =>
      a == null ? b == null : b != null && a.isAtSameMomentAs(b);

  /// The stable-key family prefix for one source kind.
  ///
  /// F03 fix (contract section 34): `weeklyReview` and `awaitingReport` both
  /// persist `ownerKind = planning`, so a profile+category+ownerKind filter
  /// cannot tell the two planning families apart.  Cleanup for one family would
  /// retrieve the other family's rows and then rebuild a cancellation under the
  /// WRONG family key from a shared occurrence token.  Every durable-work query
  /// and every cancel therefore also matches this prefix, and a cancellation is
  /// issued against the retrieved row's ACTUAL key instead of a reconstructed
  /// one.  One derivation, used by both.
  static String familyPrefix(ReminderSourceKind sourceKind) =>
      sourceKind.stableKeyFamilyPrefix;

  /// True when [stableKey] belongs to [sourceKind]'s family.
  static bool belongsToFamily({
    required ReminderSourceKind sourceKind,
    required String stableKey,
  }) => sourceKind.ownsStableKey(stableKey);

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

  /// Persists a reminder policy row.
  ///
  /// F02 fix (contract section 9): a timing-only write MUST preserve the
  /// existing purpose/contactId.  Purpose only changes when the caller supplies
  /// an explicit [purpose]; an explicit [ReminderPurpose.standard] clears the
  /// Contact, and [clearPurpose] remains available for an explicit clear.
  Future<ReminderPolicy> savePolicy({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required ReminderPolicyMode mode,
    int? offsetMinutes,
    ReminderPurpose? purpose,
    Object? contactId = ReminderPolicy.unsetContactId,
    bool clearPurpose = false,
  }) async {
    final now = clock.nowUtc();
    final existing = (await repository.readPolicies(
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
    )).where((policy) => policy.occurrenceId == occurrenceId).firstOrNull;
    final base =
        existing ??
        ReminderPolicy(
          id: const Uuid().v4(),
          profileId: profileId,
          sourceKind: sourceKind,
          sourceId: sourceId,
          occurrenceId: occurrenceId,
          mode: mode,
          offsetMinutes: mode == ReminderPolicyMode.offset
              ? offsetMinutes
              : null,
          createdAtUtc: now,
          updatedAtUtc: now,
        );
    final resolvedPurpose = clearPurpose
        ? ReminderPurpose.standard
        : (purpose ?? base.purpose);
    final resolvedContactId = switch (resolvedPurpose) {
      ReminderPurpose.standard => null,
      ReminderPurpose.contactFollowUp =>
        identical(contactId, ReminderPolicy.unsetContactId)
            ? base.contactId
            : contactId as String?,
    };
    return repository.upsertPolicy(
      ReminderPolicy(
        id: base.id,
        profileId: profileId,
        sourceKind: sourceKind,
        sourceId: sourceId,
        occurrenceId: occurrenceId,
        purpose: resolvedPurpose,
        contactId: resolvedContactId,
        mode: mode,
        offsetMinutes: mode == ReminderPolicyMode.offset ? offsetMinutes : null,
        createdAtUtc: base.createdAtUtc,
        updatedAtUtc: now,
      ),
    );
  }

  /// Applies ONLY a purpose change to an existing policy row, preserving its
  /// timing mode and offset exactly (M7 sections 8/9).
  ///
  /// A follow-up is intent, not permission to invent or reset time: the series
  /// policy that already controls when the reminder fires must keep that timing.
  /// When no row exists yet, the caller's inherited/global timing governs and
  /// this seeds an `inherit` row so purpose has a durable home.
  Future<ReminderPolicy> updatePolicyPurpose({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required ReminderPurpose purpose,
    String? contactId,
    bool clearPurpose = false,
  }) async {
    final now = clock.nowUtc();
    final existing = (await repository.readPolicies(
      profileId: profileId,
      sourceKind: sourceKind,
      sourceId: sourceId,
    )).where((policy) => policy.occurrenceId == occurrenceId).firstOrNull;
    final resolvedPurpose = clearPurpose
        ? ReminderPurpose.standard
        : purpose;
    final resolvedContactId = resolvedPurpose == ReminderPurpose.standard
        ? null
        : contactId;
    final base =
        existing ??
        ReminderPolicy(
          id: const Uuid().v4(),
          profileId: profileId,
          sourceKind: sourceKind,
          sourceId: sourceId,
          occurrenceId: occurrenceId,
          // No timing has been chosen yet, so the existing inherited default
          // keeps governing when this reminder fires.
          mode: ReminderPolicyMode.inherit,
          createdAtUtc: now,
          updatedAtUtc: now,
        );
    return repository.upsertPolicy(
      ReminderPolicy(
        id: base.id,
        profileId: profileId,
        sourceKind: sourceKind,
        sourceId: sourceId,
        occurrenceId: occurrenceId,
        purpose: resolvedPurpose,
        contactId: resolvedContactId,
        // Timing is carried over verbatim — never reset by a purpose write.
        mode: base.mode,
        offsetMinutes: base.mode == ReminderPolicyMode.offset
            ? base.offsetMinutes
            : null,
        createdAtUtc: base.createdAtUtc,
        updatedAtUtc: now,
      ),
    );
  }

  /// Retires the durable row (and whichever transport owns it) for one
  /// occurrence.
  ///
  /// [exactStableKey] lets a caller that already holds the VALIDATED durable row
  /// cancel precisely that row.  Section 34 requires cancellation to use the
  /// retrieved row's real key rather than a key reconstructed from an
  /// occurrence token, which is ambiguous between the two planning families.
  Future<void> cancel({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required String occurrenceId,
    String? exactStableKey,
  }) async {
    final key =
        exactStableKey ??
        planningStableKey(
          sourceKind: sourceKind,
          profileId: profileId,
          occurrenceId: occurrenceId,
        );
    final existing = await repository.readWorkRequest(key);
    if (existing?.platformNotificationId case final platformId?) {
      await gateway.cancel(platformId);
    }
    // Section 6: one logical reminder has one live delivery owner.  A worker
    // row is only truly released when its queued WorkManager job is also
    // cancelled — otherwise the job survives and posts after the row is gone.
    if (existing != null) {
      await _releaseWorkerTransport(existing);
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

  /// Cancels the WorkManager job behind a durable worker row, if one exists.
  ///
  /// The unique name is derived from the SAME three values the worker was
  /// registered with, so the release always targets the exact queued job and
  /// never a sibling generation (section 65 dispatch identity).
  Future<void> _releaseWorkerTransport(BackgroundWorkRequest existing) async {
    final release = cancelWorker;
    final platformId = existing.platformNotificationId;
    final fireAt = existing.scheduledForUtc;
    final revision = existing.sourceRevision;
    if (release == null ||
        platformId == null ||
        fireAt == null ||
        revision == null) {
      return;
    }
    if (transportOf(revision) != _workerTransportPrefix) return;
    await release(
      CanonicalReminderWorkSpec.uniqueName(
        platformNotificationId: platformId,
        scheduledUtcMs: fireAt.millisecondsSinceEpoch,
        sourceRevision: revision,
      ),
    );
  }

  Future<void> reconcile({
    required ReminderSourceKind sourceKind,
    required String profileId,
    required String sourceId,
    required String occurrenceId,
    required DateTime? startsAtUtc,
    DateTime? endsAtUtc,
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
    bool requiresEnrichment = false,
    String? renderRevision,
    int? sourceVersion,
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
    // Only identity, source/policy timestamps and rendering mode enter this token.
    final identity = sourceVersion == null
        ? null
        : 'm4_${sourceVersion}_${startsAtUtc?.microsecondsSinceEpoch ?? 0}_${offset ?? -1}_${policy?.updatedAtUtc.microsecondsSinceEpoch ?? 0}';
    // Section 6 transport selection.  Worker transport is sticky per stable
    // work key once the durable revision already carries the m7w_ marker;
    // otherwise current enrichment truth selects it.  The marker lives in the
    // render suffix, so no new column or private-content flag is introduced.
    //
    // A key that has already been assigned worker transport keeps it across
    // purpose unlink, location removal and privacy changes (section 6C).  It is
    // never handed back to native, so an already-queued enriched job cannot be
    // lost; its posting simply falls back to normal current copy (section 18).
    //
    // An already-persisted NATIVE marker (m7n_) is NOT sticky: enrichment
    // appearing later legitimately promotes the key to worker transport, which
    // is the "Absent/legacy rows select once from current truth" upgrade path.
    final existingTransport = transportOf(existing?.sourceRevision);
    final stickyWorkerTransport = existingTransport == _workerTransportPrefix;
    final useWorkerTransport =
        scheduleWorker != null &&
        (stickyWorkerTransport || requiresEnrichment);
    // Section 6: the transport choice for this durable row is persisted in the
    // render suffix so later comparisons know which transport owns the key.
    // Both markers are written — the native marker is not merely informational,
    // it is the durable evidence that this key was deliberately left on the
    // ordinary alarm rather than the targeted worker (section 33 technical
    // revision tokens).
    final renderToken = useWorkerTransport
        ? '$_workerTransportPrefix${renderRevision ?? 'generic'}'
        : '$_nativeTransportPrefix${renderRevision ?? 'generic'}';
    final revision = identity == null ? renderToken : '$identity.$renderToken';
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
    // Section 64: when the current canonical Event bounds are known, relevance
    // runs to the Event end (E) instead of the obsolete start-time suppression.
    // Callers that cannot supply E keep the legacy decision, so no existing
    // path regresses while the caller wiring is completed.
    final hasEventWindow =
        sourceKind == ReminderSourceKind.calendarEvent &&
        startsAtUtc != null &&
        endsAtUtc != null &&
        endsAtUtc.isAfter(startsAtUtc);
    final eventRelevance = hasEventWindow
        ? ReminderDeliveryEligibility.classifyEvent(
            nowUtc: now,
            startsAtUtc: startsAtUtc,
            endsAtUtc: endsAtUtc,
            targetUtc: baseFireAt ?? fireAt ?? now,
            quietAdjustedUtc: fireAt ?? baseFireAt ?? now,
          )
        : null;
    final eventObsolete = hasEventWindow
        ? eventRelevance == ReminderEventRelevance.obsolete ||
              eventRelevance == ReminderEventRelevance.quietSuppressed
        : sourceKind == ReminderSourceKind.calendarEvent &&
              startsAtUtc != null &&
              ((delivery && !startsAtUtc.isAfter(now)) ||
                  (fireAt != null &&
                      fireAt != baseFireAt &&
                      !startsAtUtc.isAfter(fireAt)));
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
    final generation = acceptsSnooze
        ? existing.snoozeCount + 1
        : snoozedUntil != null
        ? existing!.snoozeCount
        : 0;
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
      attemptCount: existing?.attemptCount ?? 0,
      snoozeCount: generation,
      nextEligibleAtUtc: snoozedUntil,
      createdAtUtc: existing?.createdAtUtc ?? now,
      updatedAtUtc: now,
    );
    final platform = gateway;
    if (!delivery &&
        !acceptsSnooze &&
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
      // An OFF/category-disable write must retire whichever transport owns the
      // key.  Cancelling only the platform ID would leave a queued worker job
      // alive that later posts a reminder the user explicitly switched off.
      await gateway.cancel(platformId);
      if (useWorkerTransport) {
        // `durable` already carries this generation's revision and target, so
        // the derived unique name is exactly the job that was registered.
        await _releaseWorkerTransport(
          durable.copyWith(platformNotificationId: platformId),
        );
      }
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
    } else if (!deliverNow && useWorkerTransport) {
      // Section 6 exclusivity, both directions:
      //  * a key that was native (or legacy) has its old ordinary alarm
      //    cancelled before the worker takes ownership, so the notice cannot
      //    be posted twice;
      //  * a key that was ALREADY a worker row keeps its queued job, but a
      //    changed target/revision needs the previous generation released, or
      //    the superseded job would still fire as a second owner.
      if (!stickyWorkerTransport) {
        final existingPlatformId = existing?.platformNotificationId;
        if (existingPlatformId != null) {
          await gateway.cancel(existingPlatformId);
        }
      } else {
        await _releaseWorkerTransport(existing!);
      }
      await scheduleWorker!(
        stableKey: key,
        scheduledAtUtc: fireAt,
        // Worker transport always mints the m7w_ token, so it is non-null.
        sourceRevision: revision,
        platformNotificationId: platformId,
      );
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

/// How a current Event reminder target relates to its Event's relevance window.
enum ReminderEventRelevance {
  /// Before the (quiet-adjusted) target: register or rearm for it.
  schedule,

  /// Target reached, Event not yet ended: eligible for delivery or repair.
  due,

  /// Event end reached: obsolete, no new post.
  obsolete,

  /// Quiet Hours would delay delivery to/after the Event start: suppressed.
  quietSuppressed,
}

/// Shared, pure Event relevance law (contract section 64).
///
/// This replaces the obsolete "suppress Event workers at/after start" rule.
/// Let S = current canonical start, E = current canonical end (E > S),
/// L = effective non-negative offset, T = S - L.  The relevance window is
/// derived, not fixed: the reminder is deliverable while `T <= now < E`.
/// There is deliberately no arbitrary 3/5-minute minimum lead and no fixed
/// 15-minute expiry.
///
/// Shared by the reconciler, the targeted delivery service and horizon /
/// recovery so the arithmetic exists in exactly one place.
abstract final class ReminderDeliveryEligibility {
  /// T = S - L.  [offsetMinutes] must already be validated as non-negative.
  static DateTime eventTarget({
    required DateTime startsAtUtc,
    required int offsetMinutes,
  }) {
    if (offsetMinutes < 0) {
      throw ArgumentError.value(
        offsetMinutes,
        'offsetMinutes',
        'Event reminder offsets must be validated non-negative.',
      );
    }
    return startsAtUtc.subtract(Duration(minutes: offsetMinutes));
  }

  /// Classifies [targetUtc] against the current Event window.
  ///
  /// [quietAdjustedUtc] is the target after the existing Quiet Hours delay
  /// (equal to [targetUtc] when Quiet Hours do not move it).
  static ReminderEventRelevance classifyEvent({
    required DateTime nowUtc,
    required DateTime startsAtUtc,
    required DateTime endsAtUtc,
    required DateTime targetUtc,
    required DateTime quietAdjustedUtc,
  }) {
    if (!endsAtUtc.isAfter(startsAtUtc)) {
      throw ArgumentError('Event end must be after its start.');
    }
    // Quiet Hours that would delay delivery to/after the Event start suppress
    // the reminder.  Q == T is valid, so equality alone is never suppression.
    if (quietAdjustedUtc.isAfter(targetUtc) &&
        !quietAdjustedUtc.isBefore(startsAtUtc)) {
      return ReminderEventRelevance.quietSuppressed;
    }
    // Strict end boundary: after the Event ends the time-range copy is no
    // longer a current Event reminder.
    if (!nowUtc.isBefore(endsAtUtc)) {
      return ReminderEventRelevance.obsolete;
    }
    if (nowUtc.isBefore(quietAdjustedUtc)) {
      return ReminderEventRelevance.schedule;
    }
    return ReminderEventRelevance.due;
  }

  /// `T <= now < E` after the Quiet Hours adjustment.
  static bool isDeliverable({
    required DateTime nowUtc,
    required DateTime startsAtUtc,
    required DateTime endsAtUtc,
    required DateTime targetUtc,
    required DateTime quietAdjustedUtc,
  }) =>
      classifyEvent(
        nowUtc: nowUtc,
        startsAtUtc: startsAtUtc,
        endsAtUtc: endsAtUtc,
        targetUtc: targetUtc,
        quietAdjustedUtc: quietAdjustedUtc,
      ) ==
      ReminderEventRelevance.due;
}
