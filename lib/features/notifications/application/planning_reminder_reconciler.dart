import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';
import 'package:timezone/timezone.dart' as tz;

/// M5 consumes the existing durable notification/recovery boundary.  It owns
/// neither Weekly Plan nor Event truth; each pass re-reads both canonical
/// projections before scheduling, updating, or cancelling a planning job.
final class PlanningReminderReconciler {
  const PlanningReminderReconciler({
    required this.weeklyPlans,
    required this.events,
    required this.repository,
    required this.reminders,
    required this.permission,
    required this.privacy,
  });

  final WeeklyPlanningRepository weeklyPlans;
  final CalendarEventRepository events;
  final NotificationFoundationRepository repository;
  final ReminderReconciler reminders;
  final OperatingSystemPermissionState permission;
  final PrivacySettings privacy;

  Future<void> reconcile({required String profileId}) async {
    final preferences = await repository.readPreferences(profileId: profileId);
    final showDetails =
        resolveNotificationPreviewMode(
          settings: privacy,
          privacyProtectionRequired: privacy.lockEnabled,
        ) ==
        EffectiveNotificationPreviewMode.detailed;
    final zone = tz.getLocation(
      weeklyPlans is WeeklyPlanningProfileTimeZoneSource
          ? await (weeklyPlans as WeeklyPlanningProfileTimeZoneSource)
                .timeZoneForProfile(profileId)
          : tz.local.name,
    );
    await _reconcileWeekly(
      profileId: profileId,
      zone: zone,
      preferencesEnabled: preferences.weeklyReviewRemindersEnabled,
      systemEnabled: preferences.effectiveSystemEnabled(
        androidPermissionGranted:
            permission == OperatingSystemPermissionState.granted,
      ),
      showDetails: showDetails,
    );
    await _reconcileAwaitingReports(
      profileId: profileId,
      zone: zone,
      preferencesEnabled: preferences.awaitingReportRemindersEnabled,
      systemEnabled: preferences.effectiveSystemEnabled(
        androidPermissionGranted:
            permission == OperatingSystemPermissionState.granted,
      ),
      showDetails: showDetails,
    );
  }

  Future<void> _reconcileWeekly({
    required String profileId,
    required tz.Location zone,
    required bool preferencesEnabled,
    required bool systemEnabled,
    required bool showDetails,
  }) async {
    final expected = <String>{};
    for (final plan in await weeklyPlans.readHistory(profileId)) {
      // M8 planning fix: scheduling eligibility comes from known canonical
      // period timing while the plan is not reviewed/historical.  Delivery
      // attention (reviewDue) is a separate, later source check and must not
      // gate the future 09:00 target.
      final eligible =
          plan.reviewCompletedAtUtc == null &&
          plan.storedState != WeeklyPlanState.reviewed &&
          plan.storedState != WeeklyPlanState.historical;
      final scheduled = tz.TZDateTime(
        zone,
        plan.period.end.addDays(1).year,
        plan.period.end.addDays(1).month,
        plan.period.end.addDays(1).day,
        9,
      ).toUtc();
      await reminders.reconcile(
        sourceKind: ReminderSourceKind.weeklyReview,
        profileId: profileId,
        sourceId: plan.id,
        occurrenceId: plan.id,
        startsAtUtc: null,
        scheduledAtUtc: scheduled,
        globalOffsetMinutes: null,
        categoryEnabled: preferencesEnabled,
        systemEnabled: systemEnabled,
        sourceActive: eligible,
        sourceVersion: plan.updatedAtUtc.microsecondsSinceEpoch,
        genericTitle: '🔔 Next Transfer',
        genericBody: 'You have a new notification.',
        detailedTitle: '📋 Weekly review',
        detailedBody: 'Review your week and prepare for what comes next.',
        showDetails: showDetails,
        renderRevision: showDetails
            ? 'weekly_review_detailed'
            : 'weekly_review_generic',
      );
      final key = ReminderReconciler.planningStableKey(
        sourceKind: ReminderSourceKind.weeklyReview,
        profileId: profileId,
        occurrenceId: plan.id,
      );
      if (eligible && await _isActive(key)) expected.add(key);
    }
    await _cancelUnexpected(
      profileId: profileId,
      kind: ReminderSourceKind.weeklyReview,
      expected: expected,
    );
  }

  Future<void> _reconcileAwaitingReports({
    required String profileId,
    required tz.Location zone,
    required bool preferencesEnabled,
    required bool systemEnabled,
    required bool showDetails,
  }) async {
    if (events is! CalendarEventRangeSource) return;
    final now = reminders.clock.nowUtc();
    final today = PlannerDate.fromDateTime(tz.TZDateTime.from(now, zone));
    // M8 planning fix: previous-local-day occurrences keep the current
    // attention trigger, while future requiresReport Events may schedule their
    // known end+15m / next-day 09:00 target over the existing 42-day horizon.
    // No report/plan/outcome rows are ever created here.
    final items = await (events as CalendarEventRangeSource).readRange(
      profileId: profileId,
      startDate: today.addDays(-1),
      endDate: today.addDays(42),
    );
    final expected = <String>{};
    for (final item in items) {
      final eventId = item.eventId;
      final originalDate = item.originalDate;
      if (eventId == null || originalDate == null) continue;
      final occurrence = await events.readOccurrence(
        profileId: profileId,
        eventId: eventId,
        originalDate: originalDate,
      );
      if (occurrence == null) continue;
      // Scheduling eligibility is separate from current delivery attention:
      // any scheduled requiresReport Event without a submitted report can
      // hold a future target.  The repository folds a submitted report into a
      // terminal occurrence status, so `scheduled` already means unreported.
      final eligible =
          occurrence.status == CalendarEventStatus.scheduled &&
          occurrence.requiresReport;
      final scheduled = _reportTrigger(occurrence, zone);
      await reminders.reconcile(
        sourceKind: ReminderSourceKind.awaitingReport,
        profileId: profileId,
        sourceId: occurrence.eventId,
        occurrenceId: occurrence.id,
        startsAtUtc: null,
        scheduledAtUtc: scheduled,
        globalOffsetMinutes: null,
        categoryEnabled: preferencesEnabled,
        systemEnabled: systemEnabled,
        sourceActive: eligible,
        sourceVersion: occurrence.updatedAtUtc?.microsecondsSinceEpoch ?? 0,
        genericTitle: '🔔 Next Transfer',
        genericBody: 'You have a new notification.',
        detailedTitle: '📝 Report reminder',
        detailedBody: 'Complete the report for "${occurrence.displayTitle}".',
        showDetails: showDetails,
        renderRevision: showDetails
            ? 'awaiting_report_${occurrence.displayTitle.hashCode}_${occurrence.updatedAtUtc?.microsecondsSinceEpoch ?? 0}'
            : 'awaiting_report_generic',
      );
      final key = ReminderReconciler.planningStableKey(
        sourceKind: ReminderSourceKind.awaitingReport,
        profileId: profileId,
        occurrenceId: occurrence.id,
      );
      if (eligible && await _isActive(key)) expected.add(key);
    }
    await _cancelUnexpected(
      profileId: profileId,
      kind: ReminderSourceKind.awaitingReport,
      expected: expected,
    );
  }

  DateTime? _reportTrigger(
    CalendarEventOccurrence occurrence,
    tz.Location zone,
  ) {
    if (occurrence.timing == CalendarEventTiming.timed) {
      return occurrence.endUtc?.add(const Duration(minutes: 15));
    }
    final day = occurrence.displayDate.addDays(1);
    return tz.TZDateTime(zone, day.year, day.month, day.day, 9).toUtc();
  }

  Future<bool> _isActive(String key) async {
    final work = await repository.readWorkRequest(key);
    return work != null &&
        switch (work.state) {
          BackgroundWorkState.completed ||
          BackgroundWorkState.queued ||
          BackgroundWorkState.waitingForConstraints ||
          BackgroundWorkState.delayedBySystem ||
          BackgroundWorkState.retryScheduled ||
          BackgroundWorkState.scheduled => true,
          _ => false,
        };
  }

  Future<void> _cancelUnexpected({
    required String profileId,
    required ReminderSourceKind kind,
    required Set<String> expected,
  }) async {
    final now = reminders.clock.nowUtc();
    final work = await repository.readReminderWork(
      profileId: profileId,
      sourceKind: kind,
      windowStartUtc: DateTime.utc(2000),
      windowEndUtc: DateTime.utc(now.year + 2),
    );
    for (final item in work) {
      if (expected.contains(item.stableKey) || item.occurrenceId == null) {
        continue;
      }
      await reminders.cancel(
        sourceKind: kind,
        profileId: profileId,
        occurrenceId: item.occurrenceId!,
      );
    }
  }
}
