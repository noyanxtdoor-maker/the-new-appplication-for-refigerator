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
      // M7 explicit follow-up finalization withholds the early reconcile until
      // the live Contact link and purpose are committed (form step 4).
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

  static String _eventReminderBody(
    CalendarEventOccurrence? occurrence,
    String? notes,
  ) => ReminderNotificationCopy.eventDetailedBody(
    start: occurrence?.startDisplay,
    end: occurrence?.endDisplay,
    notes: notes,
  );

  /// M7 explicit follow-up finalization: apply the source-level purpose only
  /// after the canonical Event save and the scoped People commit succeeded,
  /// then reconcile that source.
  Future<void> finalizeContactFollowUp({
    required String sourceId,
    required String contactId,
    String occurrenceId = ReminderPolicy.seriesOccurrenceId,
  }) async {
    await ref
        .read(reminderReconcilerProvider)
        .applySourcePurpose(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: sourceId,
          purpose: ReminderPurpose.contactFollowUp,
          contactId: contactId,
          occurrenceId: occurrenceId,
        );
    await reconcileEventHorizon(eventId: sourceId);
    await _refreshLauncherBadge();
  }

  /// Clears follow-up provenance for Contacts removed by an ordinary People
  /// commit and re-reconciles only when something actually changed.
  Future<void> clearUnlinkedFollowUp({
    required String sourceId,
    required Set<String> currentContactIds,
  }) async {
    try {
      final cleared = await ref
          .read(reminderReconcilerProvider)
          .clearUnlinkedPurpose(
            profileId: _profileId,
            sourceKind: ReminderSourceKind.calendarEvent,
            sourceId: sourceId,
            currentContactIds: currentContactIds,
          );
      if (cleared) {
        await reconcileEventHorizon(eventId: sourceId);
        await _refreshLauncherBadge();
      }
    } on Object {
      // The canonical Event/People save already committed; a retry reconciles.
    }
  }

  /// Unlink/lifecycle clearing for an explicitly chosen follow-up Contact.
  Future<void> clearContactFollowUpPurpose({
    required String sourceId,
    required String contactId,
    String? occurrenceId,
  }) async {
    await ref
        .read(reminderReconcilerProvider)
        .clearContactPurpose(
          profileId: _profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: sourceId,
          contactId: contactId,
          occurrenceId: occurrenceId,
        );
    await reconcileEventHorizon(eventId: sourceId);
  }

  /// Reconcile a committed occurrence after a policy-only mutation. Event
  /// forms save the Event first; this makes that saved policy effective on the
  /// same edit/reschedule rather than waiting for a later unrelated write.
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
    final showDetails =
        resolveNotificationPreviewMode(
          settings: privacy,
          privacyProtectionRequired: privacy.lockEnabled,
        ) ==
        EffectiveNotificationPreviewMode.detailed;
    await ref
        .read(reminderReconcilerProvider)
        .reconcile(
          sourceKind: ReminderSourceKind.calendarEvent,
          profileId: _profileId,
          sourceId: occurrence.eventId,
          occurrenceId: occurrence.id,
          startsAtUtc: occurrence.startUtc,
          sourceVersion: occurrence.updatedAtUtc?.microsecondsSinceEpoch ?? 0,
          globalOffsetMinutes: plannerSettings.defaultReminderMinutes,
          categoryEnabled: preferences.eventRemindersEnabled,
          systemEnabled: preferences.effectiveSystemEnabled(
            androidPermissionGranted:
                permission == OperatingSystemPermissionState.granted,
          ),
          sourceActive: occurrence.status == CalendarEventStatus.scheduled,
          genericTitle: '🔔 Next Transfer',
          genericBody: 'You have a new notification.',
          // Owner-review correction: the notification title must equal the
          // title the Planner UI shows — the stored title, falling back to
          // the Event Type label (e.g. "Study or Plan") when the stored
          // title is blank. Using the raw stored title left blank titles on
          // Events created with only an Event Type.
          detailedTitle: ReminderNotificationCopy.eventDetailedTitle,
          detailedBody: _eventReminderBody(occurrence, occurrence.notes),
          showDetails: showDetails,
          refreshContent: refreshContent,
          sourceHasLocationEnrichment:
              occurrence.locationText?.trim().isNotEmpty == true,
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

  Future<void> saveReminderPolicyAndReconcile({
    required String sourceId,
    required String occurrenceId,
    required ReminderPolicyMode mode,
    int? offsetMinutes,
  }) async {
    await _saveReminderPolicy(
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      mode: mode,
      offsetMinutes: offsetMinutes,
    );
    await reconcileEventHorizon(eventId: sourceId);
  }

  Future<void> _saveReminderPolicy({
    required String sourceId,
    required String occurrenceId,
    required ReminderPolicyMode mode,
    int? offsetMinutes,
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
