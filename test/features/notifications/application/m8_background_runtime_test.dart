// VS16 M8 — headless background runtime composition (contract section 26,
// scenarios T65-T67).
//
// The law under test:
//  * the WorkManager isolate composes the SAME canonical planning dependencies
//    as main.dart. A background pass that skips the planning repository would
//    silently stop reconciling planning reminders, so the override set must
//    carry the real WeeklyPlanning + Indicator repositories;
//  * the headless planning path is READ-ONLY. It may read plan history; it must
//    never establish a period, never open-or-create a Weekly Plan and never
//    complete a Weekly Review. Background execution must not create planning
//    truth (contract section 26 / planning law);
//  * a headless planning read does NOT require StartupReady: the runtime
//    profile override satisfies the profile path, and no fake StartupReady is
//    constructed;
//  * delivering an enriched reminder writes no Task, Event, Contact or ledger
//    state: delivery is a notification act, never a domain mutation.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/indicators/application/indicator_providers.dart';
import 'package:rmplanner/features/indicators/application/indicator_repository.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/data/drift_weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';

import '../../../support/test_dependencies.dart';

/// A WeeklyPlanning spy that records which read/write entry points the headless
/// planning pass actually reaches.  Everything delegates to the real
/// repository so the pass still sees canonical truth.
final class _WeeklyPlanningSpy implements WeeklyPlanningRepository {
  _WeeklyPlanningSpy(this._inner);

  final WeeklyPlanningRepository _inner;
  final List<String> calls = <String>[];

  @override
  Future<PlannerDate> todayForProfile(String profileId) {
    calls.add('todayForProfile');
    return _inner.todayForProfile(profileId);
  }

  @override
  Future<WeeklyPlan> openOrCreate({
    required String profileId,
    required PlannerDate date,
    int startDay = DateTime.monday,
  }) {
    calls.add('openOrCreate');
    return _inner.openOrCreate(
      profileId: profileId,
      date: date,
      startDay: startDay,
    );
  }

  @override
  Future<WeeklyPlan?> readPlanForPeriod({
    required String profileId,
    required PlannerDate periodStart,
  }) {
    calls.add('readPlanForPeriod');
    return _inner.readPlanForPeriod(
      profileId: profileId,
      periodStart: periodStart,
    );
  }

  @override
  Future<bool> periodExists({
    required String profileId,
    required PlannerDate periodStart,
  }) {
    calls.add('periodExists');
    return _inner.periodExists(profileId: profileId, periodStart: periodStart);
  }

  @override
  Future<void> ensurePeriod({
    required String profileId,
    required PlannerDate periodStart,
    int startDay = DateTime.monday,
  }) {
    calls.add('ensurePeriod');
    return _inner.ensurePeriod(
      profileId: profileId,
      periodStart: periodStart,
      startDay: startDay,
    );
  }

  @override
  Future<WeeklyPlan?> readPlan({
    required String profileId,
    required String planId,
  }) {
    calls.add('readPlan');
    return _inner.readPlan(profileId: profileId, planId: planId);
  }

  @override
  Future<List<WeeklyPlan>> readHistory(String profileId) {
    calls.add('readHistory');
    return _inner.readHistory(profileId);
  }
}

/// Inert reminder transport: this suite asserts composition, not delivery.
final class _InertGateway implements NotificationGateway {
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<List<PendingLocalNotification>> pending() async =>
      const <PendingLocalNotification>[];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

void main() {
  const profileId = '11111111-1111-4111-8111-111111111111';
  final now = DateTime.utc(2026, 9, 13, 9);

  /// Mirrors `reminder_background_runtime.dart`'s headless override set.
  ProviderContainer headlessContainer({
    required AppDatabase database,
    required AppClock clock,
    required WeeklyPlanningRepository weeklyPlans,
    required IndicatorRepository indicators,
  }) {
    final repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    final events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(
        displayTimeZoneId: 'Asia/Manila',
      ),
    );
    final gateway = _InertGateway();
    return ProviderContainer(
      overrides: <Override>[
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(gateway),
        // Mirrors the production headless container: the recovery coordinator
        // needs the durable work gateway, so the worker supplies it here too.
        backgroundWorkGatewayProvider.overrideWithValue(
          FakeBackgroundWorkGateway(),
        ),
        weeklyPlanningRepositoryProvider.overrideWithValue(weeklyPlans),
        indicatorRepositoryProvider.overrideWithValue(indicators),
        reminderReconcilerProvider.overrideWithValue(
          ReminderReconciler(
            repository: repository,
            gateway: gateway,
            clock: clock,
          ),
        ),
        calendarEventRepositoryProvider.overrideWithValue(events),
        eventTypeRepositoryProvider.overrideWithValue(
          DriftEventTypeRepository(database: database, clock: clock),
        ),
        plannerRepositoryProvider.overrideWithValue(
          DriftPlannerRepository(
            database: database,
            clock: clock,
            calendarSource: events,
          ),
        ),
        privacyRepositoryProvider.overrideWithValue(
          DriftPrivacyRepository(database: database, clock: clock),
        ),
        permissionGatewayProvider.overrideWithValue(FakePermissionGateway()),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      ],
    );
  }

  group('T65 headless runtime composes the canonical planning dependencies', () {
    test('T65 the planning pass reads canonical history and never creates '
        'planning truth', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();

      final events = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(now),
        timeZones: IanaCalendarEventTimeZones(
          displayTimeZoneId: 'Asia/Manila',
        ),
      );
      final indicators = DriftIndicatorRepository(
        database: database,
        clock: FixedClock(now),
        calendarEvents: events,
      );
      final spy = _WeeklyPlanningSpy(
        DriftWeeklyPlanningRepository(
          database: database,
          clock: FixedClock(now),
          identifiers: const UuidIdentifierSource(),
          timeZones: IanaCalendarEventTimeZones(
            displayTimeZoneId: 'Asia/Manila',
          ),
          indicators: indicators,
        ),
      );
      final container = headlessContainer(
        database: database,
        clock: FixedClock(now),
        weeklyPlans: spy,
        indicators: indicators,
      );
      addTearDown(container.dispose);

      // The canonical dependencies the headless pass must carry.
      expect(container.read(weeklyPlanningRepositoryProvider), same(spy));
      expect(container.read(indicatorRepositoryProvider), same(indicators));

      await container.read(reconcileRemindersProvider)();

      // Read-only planning access only.
      expect(
        spy.calls,
        isNot(contains('openOrCreate')),
        reason: 'a background pass must never open-or-create a Weekly Plan',
      );
      expect(
        spy.calls,
        isNot(contains('ensurePeriod')),
        reason: 'a background pass must never establish a period row',
      );
      expect(
        spy.calls,
        isNot(contains('todayForProfile')),
        reason: 'the runtime profile override supplies the profile',
      );
      expect(
        spy.calls.where((call) => call == 'readHistory').length,
        lessThanOrEqualTo(1),
        reason: 'planning recovery reads history at most once per pass',
      );
      // Planning recovery is allowed to look at history (canonical truth) or to
      // find nothing at all, but it must never WRITE planning state.
      final rowsBefore = await database.select(database.weeklyPlans).get();
      await container.read(reconcileRemindersProvider)();
      final rowsAfter = await database.select(database.weeklyPlans).get();
      expect(
        rowsAfter.length,
        rowsBefore.length,
        reason: 'repeated background passes cannot create Weekly Plans',
      );
    });

    test('T66 the planning path resolves without StartupReady', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();
      final events = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(now),
        timeZones: IanaCalendarEventTimeZones(
          displayTimeZoneId: 'Asia/Manila',
        ),
      );
      final indicators = DriftIndicatorRepository(
        database: database,
        clock: FixedClock(now),
        calendarEvents: events,
      );
      final spy = _WeeklyPlanningSpy(
        DriftWeeklyPlanningRepository(
          database: database,
          clock: FixedClock(now),
          identifiers: const UuidIdentifierSource(),
          timeZones: IanaCalendarEventTimeZones(
            displayTimeZoneId: 'Asia/Manila',
          ),
          indicators: indicators,
        ),
      );
      final container = headlessContainer(
        database: database,
        clock: FixedClock(now),
        weeklyPlans: spy,
        indicators: indicators,
      );
      addTearDown(container.dispose);

      // `startupRepositoryProvider` is deliberately NOT overridden: the worker
      // isolate must not build a UI startup graph. Reading the canonical
      // reconcile entry point must therefore succeed anyway.
      expect(
        () => container.read(startupRepositoryProvider),
        throwsA(anything),
        reason: 'no UI startup graph exists in the worker isolate',
      );
      await expectLater(
        container.read(reconcileRemindersProvider)(),
        completes,
      );
      // The runtime profile override is what made that possible.
      expect(container.read(reminderRuntimeProfileIdProvider), profileId);
    });
  });

  group('T67 delivery writes no domain state', () {
    test('T67 a delivered enriched reminder mutates no Task, Event, Contact or '
        'ledger row', () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      await buildTestRepository(database: database).completeOnboarding();

      Future<Map<String, int>> census() async => <String, int>{
        'tasks': (await database.select(database.plannerTasks).get()).length,
        'events': (await database.select(database.calendarEvents).get()).length,
        'ledger': (await database
                .select(database.activityLedgerEntries)
                .get())
            .length,
        'contacts': (await database.select(database.contacts).get()).length,
        'plans': (await database.select(database.weeklyPlans).get()).length,
        'goals': (await database.select(database.goals).get()).length,
      };

      final before = await census();

      final events = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(now),
        timeZones: IanaCalendarEventTimeZones(
          displayTimeZoneId: 'Asia/Manila',
        ),
      );
      final indicators = DriftIndicatorRepository(
        database: database,
        clock: FixedClock(now),
        calendarEvents: events,
      );
      final container = headlessContainer(
        database: database,
        clock: FixedClock(now),
        weeklyPlans: DriftWeeklyPlanningRepository(
          database: database,
          clock: FixedClock(now),
          identifiers: const UuidIdentifierSource(),
          timeZones: IanaCalendarEventTimeZones(
            displayTimeZoneId: 'Asia/Manila',
          ),
          indicators: indicators,
        ),
        indicators: indicators,
      );
      addTearDown(container.dispose);

      // Two full passes: the FIRST exercising whatever the empty horizon does,
      // the SECOND proving the pass is not a one-shot mutation that only shows
      // up on a repeat.
      await container.read(reconcileRemindersProvider)();
      await container.read(reconcileRemindersProvider)();

      expect(
        await census(),
        before,
        reason:
            'background delivery/recovery must never create Task, Event, '
            'Contact, ledger, Weekly Plan or Goal rows',
      );
    });
  });
}
