import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/notifications/application/planning_reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';
import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

import '../../support/test_dependencies.dart';

final class _FixedClock implements AppClock {
  const _FixedClock(this.value);

  final DateTime value;

  @override
  DateTime nowUtc() => value;
}

void main() {
  setUpAll(data.initializeTimeZones);

  group('VS16 M8 section 37 planning fixes (T49-T52)', () {
    const profileId = '11111111-1111-4111-8111-111111111111';
    final now = DateTime.utc(2026, 9, 12, 9);
    final zones = IanaCalendarEventTimeZones(
      displayTimeZoneId: 'Asia/Manila',
    );

    Future<
      ({
        DriftNotificationFoundationRepository notifications,
        DriftCalendarEventRepository events,
        DriftWeeklyPlanningRepository plans,
        PlanningReminderReconciler reconciler,
      })
    >
    harness(dynamic database, {String? profile}) async {
      final id = profile ?? profileId;
      final clock = _FixedClock(now);
      final notifications = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      final events = DriftCalendarEventRepository(
        database: database,
        clock: clock,
        timeZones: zones,
      );
      final plans = DriftWeeklyPlanningRepository(
        database: database,
        clock: clock,
        identifiers: const UuidIdentifierSource(),
        timeZones: zones,
        indicators: DriftIndicatorRepository(
          database: database,
          clock: clock,
          calendarEvents: events,
        ),
      );
      await notifications.savePreferences(
        profileId: id,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
          weeklyReviewRemindersEnabled: true,
          awaitingReportRemindersEnabled: true,
        ),
      );
      return (
        notifications: notifications,
        events: events,
        plans: plans,
        reconciler: PlanningReminderReconciler(
          weeklyPlans: plans,
          events: events,
          repository: notifications,
          reminders: ReminderReconciler(
            repository: notifications,
            gateway: FakeNotificationGateway(),
            clock: clock,
            deviceLocation: tz.getLocation('Asia/Manila'),
          ),
          permission: OperatingSystemPermissionState.granted,
          privacy: const PrivacySettings.defaults(),
        ),
      );
    }

    test('T49 a weekly future target is scheduled from the known period end '
        'WITHOUT the plan being due for review', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final h = await harness(database, profile: profile.id);
      final plan = await h.plans.openOrCreate(
        profileId: profile.id,
        date: const PlannerDate(year: 2026, month: 9, day: 12),
      );

      // The plan is NOT due for review yet: its period has not ended.  A
      // SCHEDULING decision must therefore not require reviewDue — only
      // CURRENT-ATTENTION does.
      expect(plan.reviewCompletedAtUtc, isNull);
      expect(
        plan.effectiveState(const PlannerDate(year: 2026, month: 9, day: 12)),
        isNot(WeeklyPlanState.reviewDue),
        reason: 'the period is still running at the moment of scheduling',
      );

      await h.reconciler.reconcile(profileId: profile.id);

      final key = ReminderReconciler.planningStableKey(
        sourceKind: ReminderSourceKind.weeklyReview,
        profileId: profile.id,
        occurrenceId: plan.id,
      );
      final row = await h.notifications.readWorkRequest(key);
      expect(
        row,
        isNotNull,
        reason: 'FAIL pre-fix: scheduling was gated on reviewDue',
      );
      expect(row!.state, BackgroundWorkState.scheduled);
      final expectedTarget = tz.TZDateTime(
        tz.getLocation('Asia/Manila'),
        plan.period.end.addDays(1).year,
        plan.period.end.addDays(1).month,
        plan.period.end.addDays(1).day,
        9,
      ).toUtc();
      expect(
        row.scheduledForUtc!.toUtc().millisecondsSinceEpoch,
        expectedTarget.millisecondsSinceEpoch,
        reason: 'the target is the canonical period end + 1 at 09:00 local',
      );
    });

    test('T50 an Awaiting-Report future target is scheduled from the known '
        'Event end', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final h = await harness(database, profile: profile.id);
      await h.events.saveEvent(
        profileId: profile.id,
        draft: const CalendarEventDraft(
          id: '7d2b4c19-6a3f-4e58-b0d1-8c5f2e9a3b71',
          title: 'Future event owing a report',
          timing: CalendarEventTiming.timed,
          startDate: PlannerDate(year: 2026, month: 9, day: 14),
          startMinute: 600,
          endMinute: 660,
          timeZoneId: 'Asia/Manila',
          requiresReport: true,
        ),
      );
      final occurrence = await h.events.readOccurrence(
        profileId: profile.id,
        eventId: '7d2b4c19-6a3f-4e58-b0d1-8c5f2e9a3b71',
        originalDate: const PlannerDate(year: 2026, month: 9, day: 14),
      );
      expect(occurrence, isNotNull);
      expect(
        occurrence!.endUtc!.isAfter(now),
        isTrue,
        reason: 'the Event has not happened yet at scheduling time',
      );

      await h.reconciler.reconcile(profileId: profile.id);

      final key = ReminderReconciler.planningStableKey(
        sourceKind: ReminderSourceKind.awaitingReport,
        profileId: profile.id,
        occurrenceId: occurrence.id,
      );
      final row = await h.notifications.readWorkRequest(key);
      expect(
        row,
        isNotNull,
        reason: 'FAIL pre-fix: the previous-day window was too narrow',
      );
      expect(row!.state, BackgroundWorkState.scheduled);
      expect(
        row.scheduledForUtc!.toUtc().millisecondsSinceEpoch,
        occurrence.endUtc!
            .add(const Duration(minutes: 15))
            .millisecondsSinceEpoch,
        reason: 'the target is derived from the known canonical Event end',
      );
    });

    test('T51 source ineligibility cancels an already-scheduled future target',
        () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final h = await harness(database, profile: profile.id);
      final plan = await h.plans.openOrCreate(
        profileId: profile.id,
        date: const PlannerDate(year: 2026, month: 9, day: 12),
      );
      await h.reconciler.reconcile(profileId: profile.id);
      final key = ReminderReconciler.planningStableKey(
        sourceKind: ReminderSourceKind.weeklyReview,
        profileId: profile.id,
        occurrenceId: plan.id,
      );
      expect(
        (await h.notifications.readWorkRequest(key))!.state,
        BackgroundWorkState.scheduled,
      );

      // The owner completes the review: the plan is now retired at source.
      await h.plans.completeReview(profileId: profile.id, planId: plan.id);
      await h.reconciler.reconcile(profileId: profile.id);

      expect(
        (await h.notifications.readWorkRequest(key))!.state,
        BackgroundWorkState.cancelledObsolete,
        reason: 'a retired review must retire its projected target',
      );
    });

    test('T52 the scheduling path creates no plan, report, outcome or ledger '
        'row', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final h = await harness(database, profile: profile.id);
      await h.plans.openOrCreate(
        profileId: profile.id,
        date: const PlannerDate(year: 2026, month: 9, day: 12),
      );
      await h.events.saveEvent(
        profileId: profile.id,
        draft: const CalendarEventDraft(
          id: 'b4e8a1d3-2c7f-4a96-8e50-1d9b6f3c0a24',
          title: 'Event that owes a report',
          timing: CalendarEventTiming.timed,
          startDate: PlannerDate(year: 2026, month: 9, day: 14),
          startMinute: 600,
          endMinute: 660,
          timeZoneId: 'Asia/Manila',
          requiresReport: true,
        ),
      );

      final plansBefore = await database.select(database.weeklyPlans).get();
      final reportsBefore = await database.select(database.outcomeReports).get();
      final ledgerBefore = await database
          .select(database.activityLedgerEntries)
          .get();
      final tasksBefore = await database.select(database.plannerTasks).get();
      final eventsBefore = await database.select(database.calendarEvents).get();

      await h.reconciler.reconcile(profileId: profile.id);

      expect(
        await database.select(database.weeklyPlans).get(),
        hasLength(plansBefore.length),
        reason: 'background work must never create a Weekly Plan',
      );
      expect(
        await database.select(database.outcomeReports).get(),
        hasLength(reportsBefore.length),
        reason: 'background work must never create a report or outcome',
      );
      expect(
        await database.select(database.activityLedgerEntries).get(),
        hasLength(ledgerBefore.length),
        reason: 'background work must never write the Activity Ledger',
      );
      expect(
        await database.select(database.plannerTasks).get(),
        hasLength(tasksBefore.length),
      );
      expect(
        await database.select(database.calendarEvents).get(),
        hasLength(eventsBefore.length),
      );
      expect(
        reportsBefore,
        isEmpty,
        reason: 'a notification pass is not an outcome-reporting event',
      );
    });
  });

  test('planning categories default off and remain gated by system truth', () {
    const defaults = NotificationPreferences.defaults();
    expect(defaults.weeklyReviewRemindersEnabled, isFalse);
    expect(defaults.awaitingReportRemindersEnabled, isFalse);
    expect(
      defaults.effectiveWeeklyReviewEnabled(androidPermissionGranted: true),
      isFalse,
    );
    expect(
      defaults
          .copyWith(
            systemNotificationsEnabled: true,
            weeklyReviewRemindersEnabled: true,
            awaitingReportRemindersEnabled: true,
          )
          .effectiveAwaitingReportEnabled(androidPermissionGranted: false),
      isFalse,
    );
  });

  test('planning stable keys are family-specific and ID-only', () {
    expect(
      ReminderReconciler.planningStableKey(
        sourceKind: ReminderSourceKind.weeklyReview,
        profileId: 'profile-1',
        occurrenceId: 'weekly-plan-1',
      ),
      'planning:weekly-review:profile-1:weekly-plan-1',
    );
    expect(
      ReminderReconciler.planningStableKey(
        sourceKind: ReminderSourceKind.awaitingReport,
        profileId: 'profile-1',
        occurrenceId: 'occurrence-1',
      ),
      'planning:awaiting-report:profile-1:occurrence-1',
    );
  });

  test(
    'weekly review due state remains distinct from canonical completion',
    () {
      final period = WeeklyPeriod(
        start: const PlannerDate(year: 2026, month: 9, day: 1),
        end: const PlannerDate(year: 2026, month: 9, day: 7),
      );
      final due = WeeklyPlan(
        id: 'weekly-plan-1',
        profileId: 'profile-1',
        period: period,
        timeZoneId: 'Etc/UTC',
        storedState: WeeklyPlanState.active,
        indicators: const <WeeklyIndicatorReview>[],
        createdAtUtc: DateTime.utc(2026, 9, 1),
        updatedAtUtc: DateTime.utc(2026, 9, 1),
      );
      expect(
        due.effectiveState(const PlannerDate(year: 2026, month: 9, day: 8)),
        WeeklyPlanState.reviewDue,
      );
      final reviewed = WeeklyPlan(
        id: due.id,
        profileId: due.profileId,
        period: due.period,
        timeZoneId: due.timeZoneId,
        storedState: WeeklyPlanState.reviewed,
        indicators: due.indicators,
        createdAtUtc: due.createdAtUtc,
        updatedAtUtc: DateTime.utc(2026, 9, 8),
        reviewCompletedAtUtc: DateTime.utc(2026, 9, 8),
      );
      expect(
        reviewed.effectiveState(
          const PlannerDate(year: 2026, month: 9, day: 9),
        ),
        WeeklyPlanState.reviewed,
      );
      expect(reviewed.reviewCompletedAtUtc, isNotNull);
    },
  );

  test('awaiting report remains canonical occurrence eligibility', () {
    final occurrence = CalendarEventOccurrence(
      id: 'occurrence-1',
      eventId: 'event-1',
      profileId: 'profile-1',
      title: 'Sensitive title is never part of the key',
      timing: CalendarEventTiming.timed,
      originalDate: const PlannerDate(year: 2026, month: 9, day: 8),
      displayDate: const PlannerDate(year: 2026, month: 9, day: 8),
      status: CalendarEventStatus.scheduled,
      requiresReport: true,
      recurrence: const CalendarRecurrenceRule(),
      endUtc: DateTime.utc(2026, 9, 8, 10),
    );
    expect(
      occurrence.isAwaitingReport(
        nowUtc: DateTime.utc(2026, 9, 8, 10, 1),
        displayToday: const PlannerDate(year: 2026, month: 9, day: 8),
      ),
      isTrue,
    );
  });

  test('planning tap payload remains a body-open ID-only intent', () {
    const intent = NotificationResponseIntent(
      profileId: 'profile-1',
      sourceKind: NotificationSourceKind.weeklyReview,
      sourceId: 'weekly-plan-1',
      action: NotificationResponseAction.open,
    );
    expect(
      NotificationPayloadCodec.tryDecode(
        NotificationPayloadCodec.encode(intent),
      ),
      intent,
    );
  });
}
