import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/indicators/application/indicator_repository.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// MP-18 — Temple Visit Home card secondary-line stability.
///
/// Historical defect (B1 owner recording, 8.5-8.6s / 10.9-11.0s): the
/// secondary line briefly flipped from `Next Visit: Aug 16` to `Set Schedule`
/// and back.  Root cause: Home collapsed "unresolved/loading" and "resolved
/// true-null" into one null state, and the refresh path explicitly invalidated
/// the provider, so every reload re-created the flash window.
///
/// Contract (tri-state):
/// - resolved date            -> `Next Visit: <date>`
/// - resolved true-null       -> "Set Schedule" (keyed affordance)
/// - unresolved / first load  -> NEUTRAL: never "Set Schedule" while pending
/// - refresh with previous    -> previous confirmed line stays visible until
///                               the newer result resolves
///
/// These tests are written against the Home UI surface (not the provider API)
/// so they capture the defect through the real render path on both the old and
/// the fixed implementation.
/// A real DriftIndicatorRepository whose `readNextTempleVisit` is staged:
/// each call returns a pending future the test completes explicitly, so the
/// loading window is deterministic.  All other IndicatorRepository methods
/// delegate to the real repository.
final class StagedTempleRepository implements IndicatorRepository {
  StagedTempleRepository(this._inner);

  final DriftIndicatorRepository _inner;
  final List<Completer<PlannerDate?>> _pending = <Completer<PlannerDate?>>[];
  int nextCalls = 0;

  int get pendingCount => _pending.length;

  Completer<PlannerDate?> pending(int index) => _pending[index];

  @override
  Future<PlannerDate?> readNextTempleVisit({
    required String profileId,
    required PlannerDate today,
  }) {
    nextCalls++;
    final completer = Completer<PlannerDate?>();
    _pending.add(completer);
    return completer.future;
  }

  @override
  Stream<void> watchChanges(String profileId) => _inner.watchChanges(profileId);

  @override
  Future<HomeIndicatorSnapshot> readHome({
    required String profileId,
    required IndicatorPeriod period,
    required PlannerDate today,
  }) =>
      _inner.readHome(profileId: profileId, period: period, today: today);

  @override
  Future<IndicatorDetail?> readDetail({
    required String profileId,
    required String indicatorKey,
    required IndicatorPeriod period,
    required PlannerDate today,
  }) =>
      _inner.readDetail(
        profileId: profileId,
        indicatorKey: indicatorKey,
        period: period,
        today: today,
      );

  @override
  Future<void> saveTarget({
    required String profileId,
    required IndicatorTargetRevisionDraft draft,
    int startDay = DateTime.monday,
  }) =>
      _inner.saveTarget(profileId: profileId, draft: draft, startDay: startDay);

  @override
  Future<void> saveGoal({
    required String profileId,
    required IndicatorGoalRevisionDraft draft,
    int startDay = DateTime.monday,
  }) =>
      _inner.saveGoal(profileId: profileId, draft: draft, startDay: startDay);

  @override
  Future<IndicatorGoalSnapshot> readGoal({
    required String profileId,
    required String indicatorKey,
    required IndicatorGoalPeriod period,
    required PlannerDate today,
  }) =>
      _inner.readGoal(
        profileId: profileId,
        indicatorKey: indicatorKey,
        period: period,
        today: today,
      );

  @override
  Future<List<IndicatorGoalSnapshot>> readGoalHistory({
    required String profileId,
    required String indicatorKey,
    required IndicatorGoalPeriodType periodType,
    required PlannerDate anchor,
    required PlannerDate today,
    int startDay = DateTime.monday,
  }) =>
      _inner.readGoalHistory(
        profileId: profileId,
        indicatorKey: indicatorKey,
        periodType: periodType,
        anchor: anchor,
        today: today,
        startDay: startDay,
      );

  @override
  Future<void> renameIndicator({
    required String profileId,
    required String indicatorKey,
    required String label,
  }) =>
      _inner.renameIndicator(
        profileId: profileId,
        indicatorKey: indicatorKey,
        label: label,
      );

  @override
  Future<List<IndicatorTargetRevision>> readTargetHistory({
    required String profileId,
    required String indicatorKey,
    required PlannerDate periodStart,
  }) =>
      _inner.readTargetHistory(
        profileId: profileId,
        indicatorKey: indicatorKey,
        periodStart: periodStart,
      );
}

void main() {
  const monday = PlannerDate(year: 2026, month: 7, day: 27);
  const aug16 = PlannerDate(year: 2026, month: 8, day: 16);
  const aug18 = PlannerDate(year: 2026, month: 8, day: 18);

  Future<StagedTempleRepository> pumpHomeWithStagedTemple(
    WidgetTester tester, {
    bool awaitSettle = true,
  }) async {
    tester.view.physicalSize = const Size(941, 1672);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
    // seeded explicitly instead of being created implicitly at onboarding.
    await seedLegacyCanonicalGoals(database, profile.id);
    await establishWeeklyPlan(
      database: database,
      profileId: profile.id,
      date: monday,
    );
    final privacy = TestPrivacyDependencies(database: database);
    final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
    final linkRepository = DriftTaskEventLinkRepository(
      database: database,
      clock: clock,
    );
    final outcomeReportingRepository = DriftOutcomeReportingRepository(
      database: database,
      clock: clock,
    );
    final calendarEvents = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(
        displayTimeZoneId: 'Asia/Manila',
      ),
      taskContextSource: linkRepository,
      linkContextTransfer: linkRepository,
      reportSource: outcomeReportingRepository,
    );
    final staged = StagedTempleRepository(
      DriftIndicatorRepository(
        database: database,
        clock: clock,
        calendarEvents: calendarEvents,
      ),
    );
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerDateSource: const FixedPlannerDateSource(monday),
        indicatorRepository: staged,
      ),
    );
    if (awaitSettle) {
      await tester.pumpAndSettle();
    }
    return staged;
  }

  Finder templeCard() => find.byKey(const Key('home-indicator-temple_visit'));
  Finder setSchedule() => find.text('Set Schedule');
  Finder nextVisit(String text) => find.text(text);
  Finder scheduleButton() => find.byKey(const Key('home-temple-schedule'));

  testWidgets(
    'A/D: first-ever unresolved load is NEUTRAL, then resolved date shows '
    'Next Visit',
    (tester) async {
      final staged = await pumpHomeWithStagedTemple(tester);

      // First-ever load is pending: the card exists and the line must NOT
      // claim there is no schedule.
      expect(templeCard(), findsOneWidget);
      expect(
        setSchedule(),
        findsNothing,
        reason: 'MP-18: loading must never render Set Schedule merely '
            'because the value is unresolved',
      );
      expect(find.textContaining('Next Visit'), findsNothing);

      // Resolve to a date -> Next Visit renders.
      staged.pending(0).complete(aug16);
      await tester.pumpAndSettle();
      expect(nextVisit('Next Visit: Aug 16'), findsOneWidget);
      expect(setSchedule(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'D2: first-ever unresolved load is NEUTRAL, then resolved true-null '
    'shows Set Schedule',
    (tester) async {
      final staged = await pumpHomeWithStagedTemple(tester);

      expect(
        setSchedule(),
        findsNothing,
        reason: 'MP-18: pending first load must stay neutral',
      );
      expect(find.textContaining('Next Visit'), findsNothing);

      staged.pending(0).complete(null);
      await tester.pumpAndSettle();
      expect(setSchedule(), findsOneWidget);
      expect(scheduleButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'B/E: pull-to-refresh with a previous confirmed date retains Next Visit '
    'through the pending reload, then updates to the new date',
    (tester) async {
      final staged = await pumpHomeWithStagedTemple(tester);
      staged.pending(0).complete(aug16);
      await tester.pumpAndSettle();
      expect(nextVisit('Next Visit: Aug 16'), findsOneWidget);

      // Home pull-to-refresh path (RefreshIndicator -> same reload Home uses).
      await tester.drag(
        find.byKey(const Key('home-indicator-list')),
        const Offset(0, 400),
      );
      // Let the indicator settle into the refresh mode (onRefresh fires after
      // the drag-settle animation).  The refreshed read is then held pending.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // The refreshed read is now pending; the previous confirmed line must
      // stay visible and Set Schedule must NOT flash.
      expect(
        staged.nextCalls,
        greaterThanOrEqualTo(2),
        reason: 'the refresh must have started a second read',
      );
      expect(nextVisit('Next Visit: Aug 16'), findsOneWidget);
      expect(
        setSchedule(),
        findsNothing,
        reason: 'MP-18: a refresh with a previous confirmed date must not '
            'flash Set Schedule while the newer read is pending',
      );

      // Newer result arrives -> newer truth replaces the retained line.
      staged.pending(1).complete(aug18);
      await tester.pumpAndSettle();
      expect(nextVisit('Next Visit: Aug 18'), findsOneWidget);
      expect(nextVisit('Next Visit: Aug 16'), findsNothing);
      expect(setSchedule(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'C: refresh resolving to true null keeps the prior date while pending, '
    'then switches to Set Schedule only after null is confirmed',
    (tester) async {
      final staged = await pumpHomeWithStagedTemple(tester);
      staged.pending(0).complete(aug16);
      await tester.pumpAndSettle();
      expect(nextVisit('Next Visit: Aug 16'), findsOneWidget);

      await tester.drag(
        find.byKey(const Key('home-indicator-list')),
        const Offset(0, 400),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(nextVisit('Next Visit: Aug 16'), findsOneWidget);
      expect(
        setSchedule(),
        findsNothing,
        reason: 'MP-18: Set Schedule must wait for the confirmed null result',
      );

      staged.pending(1).complete(null);
      await tester.pumpAndSettle();
      expect(setSchedule(), findsOneWidget);
      expect(scheduleButton(), findsOneWidget);
      expect(nextVisit('Next Visit: Aug 16'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'F: DF-04 keyed schedule affordance still opens the create gate on a '
    'resolved true-null',
    (tester) async {
      final staged = await pumpHomeWithStagedTemple(tester);
      staged.pending(0).complete(null);
      await tester.pumpAndSettle();

      expect(scheduleButton(), findsOneWidget);
      await tester.tap(scheduleButton());
      await tester.pumpAndSettle();
      // The keyed affordance leads to the temple-visit create-gate flow
      // (same destination assertion the Home journey test uses).
      expect(find.text('Select Event Type'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
