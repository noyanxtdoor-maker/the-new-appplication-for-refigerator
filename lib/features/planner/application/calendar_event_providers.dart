import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/event_reminder_horizon_reconciler.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final calendarEventRepositoryProvider = Provider<CalendarEventRepository>((
  ref,
) {
  throw StateError(
    'CalendarEventRepository must be overridden at the app root',
  );
});

final calendarEventControllerProvider =
    NotifierProvider<CalendarEventController, String?>(
      CalendarEventController.new,
    );

typedef EventReminderHorizonOverride =
    Future<void> Function(String? eventId, bool refreshContent);

/// Test seam for observing mutation-boundary scopes. Production leaves this
/// null and uses [EventReminderHorizonReconciler].
final eventReminderHorizonOverrideProvider =
    Provider<EventReminderHorizonOverride?>((ref) => null);

/// Distinguishes a durable Event cancellation from the separate Planner
/// refresh confirmation.  A committed cancellation is never retried merely
/// because the visible Planner projection is temporarily stale.
enum CalendarEventCancellationResult {
  deleted,
  deletedAwaitingPlannerRefresh,
  deletionStateUncertain,
  notDeleted;

  bool get closesDetail => this != notDeleted;
}

final class CalendarEventController extends Notifier<String?> {
  CalendarEventRepository get _repository =>
      ref.read(calendarEventRepositoryProvider);

  String get displayTimeZoneId => _repository.displayTimeZoneId;

  String get _profileId {
    final runtimeProfile = ref.read(reminderRuntimeProfileIdProvider);
    if (runtimeProfile != null) return runtimeProfile;
    final startup = ref.read(startupControllerProvider);
    if (startup is! StartupReady) {
      throw StateError('Calendar Events require a ready Local Profile');
    }
    return startup.profile.id;
  }

  @override
  String? build() => null;

  bool isValidTimeZone(String value) => _repository.isValidTimeZone(value);

  Future<CalendarEventDraft?> readEventDraft(String eventId) {
    return _repository.readEventDraft(profileId: _profileId, eventId: eventId);
  }

  Future<CalendarEventOccurrence?> readOccurrence({
    required String eventId,
    required PlannerDate originalDate,
  }) {
    return _repository.readOccurrence(
      profileId: _profileId,
      eventId: eventId,
      originalDate: originalDate,
    );
  }

  Future<bool> saveEvent(
    CalendarEventDraft draft, {
    bool awaitPlannerRefresh = true,
    ReminderPolicyMode? reminderMode,
    int? reminderOffsetMinutes,
    String reminderOccurrenceId = ReminderPolicy.seriesOccurrenceId,
    bool deferReminderReconciliation = false,
  }) async {
    try {
      final saved = await _repository.saveEvent(
        profileId: _profileId,
        draft: draft,
      );
      // Persist the requested policy after the Event itself commits but before
      // scheduling.  This makes Custom/Off take effect on the save that chose
      // it, without ever creating policy for an Event whose save failed.
      if (reminderMode != null) {
        await _saveReminderPolicy(
          sourceId: saved.id,
          occurrenceId: reminderOccurrenceId,
          mode: reminderMode,
          offsetMinutes: reminderOffsetMinutes,
        );
      }
      // M7 section 8: an explicit Contact follow-up save withholds this early
      // scheduling until the caller has committed People and applied the
      // source-level purpose.  Every other save keeps the existing immediate
      // reconciliation (default false); this is a narrow, opt-in deferral.
      if (!deferReminderReconciliation) {
        await reconcileEventHorizon(eventId: saved.id);
      }
      await _refreshLauncherBadge();
      if (awaitPlannerRefresh) {
        await _refreshPlanner();
      } else {
        _refreshPlannerInBackground();
      }
      state = null;
      return true;
    } on CalendarEventValidationException catch (error) {
      state = error.message;
      return false;
    } on Object {
      state =
          'Calendar Event could not be saved. Your input remains available '
          'to retry.';
      return false;
    }
  }

  /// VS16 M7 corrective — renderer convergence.
  ///
  /// The native ordinary transport no longer owns reminder copy.  It delegates
  /// to the single canonical [ReminderNotificationRenderer] so the native path
  /// and the worker/enriched path can never drift apart.  The Detailed options
  /// are left at their all-TRUE default here: this call site only resolves
  /// transport-independent copy for the SCHEDULED notification, and the
  /// user's per-field preferences are applied by the reconciler when the
  /// notification is actually presented.
  ///
  /// [CalendarEventOccurrence.displayTitle] already carries the Planner-visible
  /// title (stored title, falling back to the Event Type label), so the
  /// amendment's "actual resolved source title" rule is satisfied by passing it
  /// straight through.  User emoji is preserved; only the renderer's blank
  /// fallback applies.
  static RenderedReminder _eventReminderPresentation(
    CalendarEventOccurrence? occurrence, {
    String? notes,
  }) {
    return ReminderNotificationRenderer.eventDetailed(
      eventTitle: occurrence?.displayTitle,
      startDisplay: occurrence?.startDisplay,
      endDisplay: occurrence?.endDisplay,
      notes: notes,
    );
  }

  /// Reconcile a committed occurrence after a policy-only mutation. Event
  /// forms save the Event first; this makes that saved policy effective on the
  /// same edit/reschedule rather than waiting for a later unrelated write.
  /// Whether the effective policy for this occurrence (exact occurrence row,
  /// else the series row) carries an explicit Contact follow-up purpose.
  ///
  /// Section 6A: purpose is an ENRICHMENT request, not a separate scheduler —
  /// it only selects which transport owns the reminder.
  Future<bool> _hasFollowUpPurpose({
    required String sourceId,
    required String occurrenceId,
  }) async {
    final policies = await ref
        .read(notificationFoundationRepositoryProvider)
        .readPolicies(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: sourceId,
        );
    final effective =
        policies.where((p) => p.occurrenceId == occurrenceId).firstOrNull ??
        policies
            .where(
              (p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId,
            )
            .firstOrNull;
    return effective?.purpose == ReminderPurpose.contactFollowUp;
  }

  Future<void> reconcileOccurrence({
    required String eventId,
    required PlannerDate originalDate,
    bool refreshContent = false,
  }) async {
    final occurrence = await _repository.readOccurrence(
      profileId: _profileId,
      eventId: eventId,
      originalDate: originalDate,
    );
    if (occurrence == null) return;
    final preferences = await ref
        .read(notificationFoundationRepositoryProvider)
        .readPreferences(profileId: _profileId);
    final permission = await ref
        .read(permissionGatewayProvider)
        .status(OptionalPermission.notifications);
    final plannerSettings = await ref
        .read(eventTypeRepositoryProvider)
        .readPlannerSettings(profileId: _profileId);
    final privacy = await ref.read(privacyRepositoryProvider).readSettings();
    // M2 OWNER CORRECTION (Issue 1): notification content follows ONLY the
    // saved preview preference.  Privacy Lock is no longer an input.
    final showDetails =
        resolveNotificationPreviewMode(settings: privacy) ==
        EffectiveNotificationPreviewMode.detailed;
    // Section 6A transport selection: this occurrence needs the targeted worker
    // when its EFFECTIVE policy carries a Contact follow-up purpose or its
    // current canonical occurrence has eligible human location text.  The
    // choice is independent of preview mode — a Generic/Locked enriched source
    // still uses the same live-read transport, so a privacy toggle never churns
    // the transport that already owns the key.
    final requiresEnrichment = occurrence.locationText?.trim().isNotEmpty ==
            true ||
        await _hasFollowUpPurpose(
          sourceId: occurrence.eventId,
          occurrenceId: occurrence.id,
        );
    await ref
        .read(reminderReconcilerProvider)
        .reconcile(
          sourceKind: ReminderSourceKind.calendarEvent,
          profileId: _profileId,
          sourceId: occurrence.eventId,
          occurrenceId: occurrence.id,
          startsAtUtc: occurrence.startUtc,
          // Section 64: relevance runs to the current canonical Event end, not
          // to the obsolete start-time suppression.
          endsAtUtc: occurrence.endUtc,
          sourceVersion: occurrence.updatedAtUtc?.microsecondsSinceEpoch ?? 0,
          globalOffsetMinutes: plannerSettings.defaultReminderMinutes,
          categoryEnabled: preferences.eventRemindersEnabled,
          systemEnabled: preferences.effectiveSystemEnabled(
            androidPermissionGranted:
                permission == OperatingSystemPermissionState.granted,
          ),
          sourceActive: occurrence.status == CalendarEventStatus.scheduled,
          genericTitle: ReminderNotificationRenderer.genericTitle,
          genericBody: ReminderNotificationRenderer.genericBody,
          // VS16 M7 corrective (Astra section 13 owner amendment): Detailed
          // uses the ACTUAL resolved source title — [displayTitle], which is
          // the Planner-visible title the owner sees today (stored title,
          // falling back to the Event Type label e.g. "Study or Plan").  User
          // emoji is preserved verbatim.  The constant `📅 Event reminder` is
          // now only the blank-title fallback, applied inside the renderer.
          //
          // Both fields come from the single canonical renderer so the native
          // ordinary transport and the worker/enriched transport can never
          // drift apart.
          detailedTitle: _eventReminderPresentation(occurrence).title,
          detailedBody: _eventReminderPresentation(
            occurrence,
            notes: occurrence.notes,
          ).body,
          showDetails: showDetails,
          refreshContent: refreshContent,
          requiresEnrichment: requiresEnrichment,
          // Correction: include the resolved title in the render revision so
          // a title-display fix (or Event Type label change) refreshes the
          // SAME notification identity in place instead of leaving a blank
          // title on an already-scheduled reminder.
          renderRevision: showDetails
              ? 'event_detailed_${occurrence.displayTitle.hashCode}_${occurrence.updatedAtUtc?.microsecondsSinceEpoch ?? 0}'
              : 'event_generic',
        );
  }

  Future<bool> editEvent({
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft draft,
    required String operationId,
    bool refreshPlanner = true,
    bool awaitPlannerRefresh = true,
    ReminderPolicyMode? reminderMode,
    int? reminderOffsetMinutes,
  }) async {
    final sourceBefore = await _repository.readEventDraft(
      profileId: _profileId,
      eventId: eventId,
    );
    final changed = await _runMutation(
      () => _repository.editEvent(
        profileId: _profileId,
        eventId: eventId,
        originalDate: originalDate,
        scope: scope,
        draft: draft,
        operationId: operationId,
      ),
      refreshPlanner: refreshPlanner,
      awaitPlannerRefresh: awaitPlannerRefresh,
    );
    if (changed) {
      final resolvedScope =
          sourceBefore?.recurrence.isRecurring == true &&
              !draft.recurrence.isRecurring
          ? CalendarEventEditScope.series
          : scope;
      final splitSource =
          resolvedScope == CalendarEventEditScope.thisAndFuture &&
          sourceBefore != null &&
          originalDate != sourceBefore.startDate;
      final policySourceId = splitSource ? draft.id : eventId;
      final policyOccurrenceId =
          resolvedScope == CalendarEventEditScope.occurrence
          ? CalendarEventOccurrenceIdentity.forDate(
              eventId: eventId,
              originalDate: originalDate,
            )
          : ReminderPolicy.seriesOccurrenceId;
      if (reminderMode != null) {
        await _saveReminderPolicy(
          sourceId: policySourceId,
          occurrenceId: policyOccurrenceId,
          mode: reminderMode,
          offsetMinutes: reminderOffsetMinutes,
        );
      }
      await reconcileEventHorizon(eventId: eventId);
      if (splitSource) {
        await reconcileEventHorizon(eventId: draft.id);
      }
      await _refreshLauncherBadge();
    }
    return changed;
  }

  /// Reconciles the canonical occurrence projection for a conservative six
  /// week window. The repository remains the sole recurrence/exception
  /// engine; notifications only consume its bounded results.
  Future<void> reconcileEventHorizon({
    String? eventId,
    bool refreshContent = false,
  }) async {
    final override = ref.read(eventReminderHorizonOverrideProvider);
    if (override != null) {
      await override(eventId, refreshContent);
      return;
    }
    if (_repository is! CalendarEventRangeSource) return;
    final reconciler = ref.read(reminderReconcilerProvider);
    await EventReminderHorizonReconciler(
      rangeSource: _repository as CalendarEventRangeSource,
      repository: ref.read(notificationFoundationRepositoryProvider),
      reminderReconciler: reconciler,
      clock: reconciler.clock,
      reconcileOccurrence: ({required eventId, required originalDate}) =>
          reconcileOccurrence(
            eventId: eventId,
            originalDate: originalDate,
            refreshContent: refreshContent,
          ),
    ).reconcile(
      profileId: _profileId,
      today: PlannerDate.fromDateTime(DateTime.now()),
      eventId: eventId,
    );
  }

  /// Applies an explicit source-level purpose after the canonical Event and its
  /// People links have committed, then reconciles the affected source.
  ///
  /// M7 section 8: purpose is written into the SERIES policy while its timing
  /// is preserved, so a follow-up never silently disables or retimes the
  /// reminder that was already configured for the source.
  Future<void> saveReminderPolicyAndReconcile({
    required String sourceId,
    required String occurrenceId,
    required ReminderPolicyMode mode,
    int? offsetMinutes,
    ReminderPurpose? purpose,
    String? contactId,
  }) async {
    await _saveReminderPolicy(
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      mode: mode,
      offsetMinutes: offsetMinutes,
      purpose: purpose,
      contactId: contactId,
    );
    await reconcileEventHorizon(eventId: sourceId);
  }

  /// Applies ONLY a source-level purpose change, preserving the existing timing
  /// mode/offset of that policy row (M7 sections 8/9).
  Future<void> applySeriesReminderPurpose({
    required String sourceId,
    required ReminderPurpose purpose,
    String? contactId,
  }) async {
    await ref
        .read(reminderReconcilerProvider)
        .updatePolicyPurpose(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: sourceId,
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          purpose: purpose,
          contactId: contactId,
        );
  }

  Future<void> _saveReminderPolicy({
    required String sourceId,
    required String occurrenceId,
    required ReminderPolicyMode mode,
    int? offsetMinutes,
    ReminderPurpose? purpose,
    String? contactId,
  }) async {
    await ref
        .read(reminderReconcilerProvider)
        .savePolicy(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: sourceId,
          occurrenceId: occurrenceId,
          mode: mode,
          offsetMinutes: offsetMinutes,
          purpose: purpose,
          contactId: contactId,
        );
  }

  Future<CalendarEventCancellationResult> cancelEvent({
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required String operationId,
    bool refreshPlanner = true,
    bool managePendingDeletion = true,
  }) async {
    final targets = switch (scope) {
      CalendarEventEditScope.series => PlannerEventDeletionTargetSet.series(
        eventId,
      ),
      CalendarEventEditScope.occurrence =>
        PlannerEventDeletionTargetSet.occurrence(
          eventId: eventId,
          originalDate: originalDate,
        ),
      // ThisAndFuture hides the clicked occurrence (same transient identity
      // as an occurrence delete) but its durable mutation affects future
      // dates too, so its confirmation must stay BROAD.
      CalendarEventEditScope.thisAndFuture =>
        PlannerEventDeletionTargetSet.thisAndFuture(
          eventId: eventId,
          originalDate: originalDate,
        ),
    };
    final planner = ref.read(plannerControllerProvider.notifier);
    if (managePendingDeletion) {
      planner.beginPendingEventDeletion(targets);
    }
    try {
      await _repository.cancelEvent(
        profileId: _profileId,
        eventId: eventId,
        originalDate: originalDate,
        scope: scope,
        operationId: operationId,
      );
      await reconcileEventHorizon(eventId: eventId);
      await _refreshLauncherBadge();
    } on CalendarEventValidationException catch (error) {
      if (managePendingDeletion) {
        planner.rollbackPendingEventDeletion(targets);
      }
      state = error.message;
      return CalendarEventCancellationResult.notDeleted;
    } on Object {
      if (managePendingDeletion) {
        planner.rollbackPendingEventDeletion(targets);
      }
      state = 'Event was not deleted. Try again.';
      return CalendarEventCancellationResult.notDeleted;
    }

    if (managePendingDeletion) {
      final confirmed = await planner.confirmPendingEventDeletion(targets);
      if (!confirmed) {
        final canonical = await _readCancellationState(
          eventId: eventId,
          originalDate: originalDate,
        );
        if (canonical == CalendarEventStatus.cancelled) {
          _refreshPlannerInBackground();
          state = null;
          return CalendarEventCancellationResult.deletedAwaitingPlannerRefresh;
        }
        _refreshPlannerInBackground();
        state = null;
        return CalendarEventCancellationResult.deletionStateUncertain;
      }
    } else if (refreshPlanner) {
      try {
        await _refreshPlanner();
      } on Object {
        // The durable repository cancellation is already complete.  The
        // caller receives a committed result and Planner keeps refreshing.
        _refreshPlannerInBackground();
        state = null;
        return CalendarEventCancellationResult.deletedAwaitingPlannerRefresh;
      }
    }
    state = null;
    return CalendarEventCancellationResult.deleted;
  }

  Future<CalendarEventStatus?> _readCancellationState({
    required String eventId,
    required PlannerDate originalDate,
  }) async {
    try {
      return (await _repository.readOccurrence(
        profileId: _profileId,
        eventId: eventId,
        originalDate: originalDate,
      ))?.status;
    } on Object {
      return null;
    }
  }

  void _refreshPlannerInBackground() {
    unawaited(_refreshPlanner().catchError((Object _) {}));
  }

  Future<bool> rescheduleEvent({
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft replacement,
    required String operationId,
    bool refreshPlanner = true,
    ReminderPolicyMode? reminderMode,
    int? reminderOffsetMinutes,
  }) async {
    final sourceBefore = await _repository.readEventDraft(
      profileId: _profileId,
      eventId: eventId,
    );
    final changed = await _runMutation(
      () => _repository.rescheduleEvent(
        profileId: _profileId,
        eventId: eventId,
        originalDate: originalDate,
        scope: scope,
        replacement: replacement,
        operationId: operationId,
      ),
      refreshPlanner: refreshPlanner,
    );
    if (changed) {
      final occurrenceStaysInSource =
          scope == CalendarEventEditScope.occurrence &&
          sourceBefore?.recurrence.isRecurring == true;
      final policySourceId = occurrenceStaysInSource ? eventId : replacement.id;
      final policyOccurrenceId = occurrenceStaysInSource
          ? CalendarEventOccurrenceIdentity.forDate(
              eventId: eventId,
              originalDate: originalDate,
            )
          : ReminderPolicy.seriesOccurrenceId;
      if (reminderMode != null) {
        await _saveReminderPolicy(
          sourceId: policySourceId,
          occurrenceId: policyOccurrenceId,
          mode: reminderMode,
          offsetMinutes: reminderOffsetMinutes,
        );
      }
      await reconcileEventHorizon(eventId: eventId);
      if (!occurrenceStaysInSource) {
        await reconcileEventHorizon(eventId: replacement.id);
      }
      await _refreshLauncherBadge();
    }
    return changed;
  }

  Future<bool> duplicateEvent({
    required String eventId,
    required PlannerDate originalDate,
    required String duplicateId,
    required String operationId,
  }) async {
    final changed = await _runMutation(
      () => _repository.duplicateEvent(
        profileId: _profileId,
        eventId: eventId,
        originalDate: originalDate,
        duplicateId: duplicateId,
        operationId: operationId,
      ),
    );
    if (changed) await reconcileEventHorizon(eventId: duplicateId);
    if (changed) await _refreshLauncherBadge();
    return changed;
  }

  void clearMessage() {
    state = null;
  }

  Future<void> _refreshLauncherBadge() async {
    try {
      await ref.read(launcherBadgeRefreshProvider)();
    } on Object {
      // Canonical Event persistence must not depend on OEM badge support.
    }
  }

  Future<bool> _runMutation(
    Future<CalendarEventMutationOutcome> Function() command, {
    bool refreshPlanner = true,
    bool awaitPlannerRefresh = true,
  }) async {
    try {
      await command();
      if (refreshPlanner) {
        if (awaitPlannerRefresh) {
          await _refreshPlanner();
        } else {
          // Background refresh for the normal Edit form: the durable Event
          // write is the truth gate, so dismissal must not wait on the
          // selected-day reload. Failures are surfaced through PlannerState;
          // an unexpected error must never escape as an unhandled async
          // error, hence the explicit swallow on the unawaited future.
          unawaited(_refreshPlanner().catchError((Object _) {}));
        }
      }
      state = null;
      return true;
    } on CalendarEventValidationException catch (error) {
      state = error.message;
      return false;
    } on Object {
      state = 'Calendar Event was not changed. You can safely retry.';
      return false;
    }
  }

  Future<void> _refreshPlanner() {
    final planner = ref.read(plannerControllerProvider.notifier);
    return planner.selectDate(ref.read(plannerControllerProvider).selectedDate);
  }
}
