import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/startup/presentation/home_screen.dart';

import '../../../support/test_dependencies.dart';

void main() {
  test('Pack 1 month labels are render-time and locale-derived', () async {
    await initializeDateFormatting();
    expect(
      homeMonthGoalLabel(
        const PlannerDate(year: 2026, month: 8, day: 31),
        const Locale('en', 'US'),
      ),
      'August Goal',
    );
    expect(
      homeMonthGoalLabel(
        const PlannerDate(year: 2026, month: 9, day: 1),
        const Locale('en', 'US'),
      ),
      'September Goal',
    );
    expect(
      homeMonthGoalLabel(
        const PlannerDate(year: 2027, month: 1, day: 1),
        const Locale('fr', 'FR'),
      ),
      'janvier Goal',
    );
  });

  testWidgets(
    'VS-08 Home renders active canonical defaults and canonical planning entry',
    (tester) async {
      const monday = PlannerDate(year: 2026, month: 7, day: 27);
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

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Life Goals'), findsOneWidget);
      expect(find.text('Weekly Life Indicators'), findsNothing);
      expect(find.byKey(const Key('home-start-weekly-planning')), findsNothing);
      for (final key in <String>[
        'job_applications',
        'scripture_study',
        'exercise',
        'meaningful_connections',
        'budget_review',
        'temple_visit',
      ]) {
        expect(find.byKey(Key('home-indicator-$key')), findsOneWidget);
      }
      expect(find.text('Scheduled'), findsNothing);
      expect(find.textContaining('worthiness'), findsNothing);
      // R5 (owner 2026-08-16): the Active Pathways section is removed, so
      // the Goal Planning pill is the last element of the Home list; scroll
      // it into view (it may sit below the fold of the lazy list).
      await tester.scrollUntilVisible(
        find.byKey(const Key('weekly-targets-button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const Key('home-pathway-employment')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pumpAndSettle();
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(
        find.byKey(const Key('weekly-plan-indicator-job_applications')),
        findsOneWidget,
      );
      expect(find.text('Set Goal'), findsNWidgets(5));
      await tester.tap(
        find.byKey(const Key('weekly-plan-indicator-job_applications')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit Goal'), findsOneWidget);
      expect(find.text('Daily Progress Goal'), findsOneWidget);
      expect(find.byTooltip('Save'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('goal-period-daily')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      final dailyTargetPlus = find.descendant(
        of: find.byKey(const Key('goal-period-daily')),
        matching: find.byIcon(Icons.add_circle),
      );
      await tester.tap(dailyTargetPlus);
      await tester.pumpAndSettle();
      expect(find.text('1'), findsWidgets);

      await tester.scrollUntilVisible(
        find.byKey(const Key('goal-period-weekly')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      final weeklyTargetPlus = find.descendant(
        of: find.byKey(const Key('goal-period-weekly')),
        matching: find.byIcon(Icons.add_circle),
      );
      await tester.tap(weeklyTargetPlus);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goal-edit-save')));
      await tester.pumpAndSettle();
      expect(find.text('Goal Planning'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('Home remains usable at 200% text scale', (tester) async {
    const monday = PlannerDate(year: 2026, month: 7, day: 27);
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 2.5;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    final m6LegacySeedProfile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, m6LegacySeedProfile.id);
    final privacy = TestPrivacyDependencies(database: database);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerDateSource: const FixedPlannerDateSource(monday),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Life Goals'), findsOneWidget);
    // R5 (owner 2026-08-16): the Active Pathways section is removed; scroll
    // to the last Home element (Goal Planning pill) to prove the whole list
    // renders without exception at 200% scale.
    await tester.scrollUntilVisible(
      find.byKey(const Key('weekly-targets-button')),
      220,
      scrollable: find.descendant(
        of: find.byKey(const Key('home-indicator-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const Key('home-pathway-documents')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'Prompt A planned Home uses compact canonical WLI cards and Temple split',
    (tester) async {
      const monday = PlannerDate(year: 2026, month: 7, day: 27);
      tester.view.physicalSize = const Size(393, 874);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
      final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
      final reporting = DriftOutcomeReportingRepository(
        database: database,
        clock: clock,
      );
      final calendar = DriftCalendarEventRepository(
        database: database,
        clock: clock,
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
        reportSource: reporting,
      );
      final indicators = DriftIndicatorRepository(
        database: database,
        clock: clock,
        calendarEvents: calendar,
      );
      const indicatorKeys = <String>[
        'job_applications',
        'scripture_study',
        'exercise',
        'meaningful_connections',
        'budget_review',
        'temple_visit',
      ];
      for (var index = 0; index < indicatorKeys.length; index += 1) {
        await indicators.saveGoal(
          profileId: profile.id,
          draft: IndicatorGoalRevisionDraft(
            id: '82000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
            operationId:
                '83000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
            indicatorKey: indicatorKeys[index],
            period: IndicatorGoalPeriod.weekly(monday),
            value: IndicatorAmount(
              scaledValue: index + 2,
              scale: 0,
              unit: 'count',
            ),
          ),
        );
      }
      await indicators.saveGoal(
        profileId: profile.id,
        draft: const IndicatorGoalRevisionDraft(
          id: '84000000-0000-4000-8000-000000000001',
          operationId: '85000000-0000-4000-8000-000000000001',
          indicatorKey: 'job_applications',
          period: IndicatorGoalPeriod(
            type: IndicatorGoalPeriodType.daily,
            start: monday,
            end: monday,
          ),
          value: IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count'),
        ),
      );

      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Life Goals'), findsOneWidget);
      expect(find.byKey(const Key('home-start-weekly-planning')), findsNothing);
      for (final key in indicatorKeys) {
        expect(find.byKey(Key('home-indicator-$key')), findsOneWidget);
      }
      // HR-01: the approved compact Home restore — the daily Goal card is a
      // single 76 dp row ([icon] [title+ratio] [Today's Goal block] [+]);
      // compact cards are 76 dp horizontal icon+text pairs; the odd
      // full-width temple card is 76 dp too.
      expect(
        tester
            .getSize(find.byKey(const Key('home-indicator-job_applications')))
            .height,
        76,
      );
      expect(
        tester
            .getSize(find.byKey(const Key('home-indicator-job_applications')))
            .width,
        closeTo(357, 0.01),
      );
      expect(
        tester.getSize(find.byKey(const Key('home-indicator-exercise'))).height,
        76,
      );
      expect(
        tester.getSize(find.byKey(const Key('home-indicator-exercise'))).width,
        closeTo(173.5, 0.01),
      );
      expect(
        tester
            .getSize(find.byKey(const Key('home-indicator-temple_visit')))
            .height,
        76,
      );
      // HR-02 (approved mockup): Temple Visit + August Goal are ONE
      // full-width card — no two half-width bottom cards.  The August Goal
      // inset lives INSIDE the temple card at the right.
      expect(
        tester
            .getSize(find.byKey(const Key('home-indicator-temple_visit')))
            .width,
        closeTo(357, 0.01),
      );
      expect(find.byKey(const Key('home-month-goal-card')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('home-month-goal-card'))).width,
        lessThan(200),
      );
      expect(
        tester.getSize(find.byKey(const Key('home-month-goal-card'))).height,
        lessThanOrEqualTo(60),
      );
      expect(find.text('July Goal'), findsOneWidget);
      expect(find.text("Today's Goal"), findsOneWidget);
      expect(find.text('Job Applications'), findsOneWidget);
      expect(find.text('0/1'), findsOneWidget);
      // HR-02: the Today's Goal inset is a compact opaque-gray surface (label
      // + value + controls inside), never taller than the card's content band.
      expect(
        tester
            .getSize(find.byKey(const Key('home-daily-target-quick-control')))
            .width,
        lessThanOrEqualTo(170),
      );
      expect(
        tester
            .getSize(find.byKey(const Key('home-daily-target-quick-control')))
            .height,
        lessThanOrEqualTo(60),
      );
      for (final key in <String>[
        'home-daily-target-minus',
        'home-daily-target-plus',
      ]) {
        expect(tester.getSize(find.byKey(Key(key))), const Size(28, 24));
      }
      expect(find.text('Set Schedule'), findsOneWidget);
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // POLISH-02: the temple schedule affordance is the keyed TextButton
      // inside the monthly temple card, not the card center (which now
      // opens Goal Edit under the taller two-region card layout).
      await tester.tap(find.byKey(const Key('home-temple-schedule')));
      await tester.pumpAndSettle();
      expect(find.text('Select Event Type'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('Prompt A planned Home responsive width matrix', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const configurations = <({Size size, double textScale})>[
      (size: Size(360, 800), textScale: 1),
      (size: Size(393, 874), textScale: 1.15),
      (size: Size(411, 891), textScale: 1.3),
    ];
    for (final configuration in configurations) {
      tester.view.physicalSize = configuration.size;
      tester.platformDispatcher.textScaleFactorTestValue =
          configuration.textScale;
      final database = openMemoryDatabase();
      var databaseClosed = false;
      addTearDown(() async {
        if (!databaseClosed) {
          databaseClosed = true;
          await database.close();
        }
      });
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(database, profile.id);
      final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
      final reporting = DriftOutcomeReportingRepository(
        database: database,
        clock: clock,
      );
      final calendar = DriftCalendarEventRepository(
        database: database,
        clock: clock,
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
        reportSource: reporting,
      );
      final indicators = DriftIndicatorRepository(
        database: database,
        clock: clock,
        calendarEvents: calendar,
      );
      const monday = PlannerDate(year: 2026, month: 7, day: 27);
      await establishWeeklyPlan(
        database: database,
        profileId: profile.id,
        date: monday,
      );
      const indicatorKeys = <String>[
        'job_applications',
        'scripture_study',
        'exercise',
        'meaningful_connections',
        'budget_review',
        'temple_visit',
      ];
      for (var index = 0; index < indicatorKeys.length; index += 1) {
        await indicators.saveGoal(
          profileId: profile.id,
          draft: IndicatorGoalRevisionDraft(
            id: '86000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
            operationId:
                '87000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
            indicatorKey: indicatorKeys[index],
            period: IndicatorGoalPeriod.weekly(monday),
            value: const IndicatorAmount(
              scaledValue: 1,
              scale: 0,
              unit: 'count',
            ),
          ),
        );
      }
      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await tester.pumpAndSettle();

      for (final key in indicatorKeys) {
        expect(find.byKey(Key('home-indicator-$key')), findsOneWidget);
      }
      // HR-01: the approved compact Home restore keeps the daily Goal card at
      // the 76 dp row height (single horizontal row, no two-region column).
      expect(
        tester
            .getSize(find.byKey(const Key('home-indicator-job_applications')))
            .height,
        76,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await database.close();
      databaseClosed = true;
    }
  });

  testWidgets(
    'A3 / Pack 1: rapid Home daily target controls are immediate and target-only',
    (tester) async {
      const monday = PlannerDate(year: 2026, month: 7, day: 27);
      tester.view.physicalSize = const Size(393, 874);
      tester.view.devicePixelRatio = 1;
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
      final goalRepository = DriftGoalRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        identifiers: const UuidIdentifierSource(),
      );
      final defaults = await goalRepository.readActiveGoals(profile.id);
      for (var index = 0; index < defaults.length; index += 1) {
        await goalRepository.archiveGoal(
          profileId: profile.id,
          goalId: defaults[index].id,
          operationId: 'pack1-home-archive-default-$index',
        );
      }
      const target = IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count');
      final daily = await goalRepository.createGoal(
        profileId: profile.id,
        role: GoalRole.dailyWeekly,
        title: 'Replacement Daily',
        iconId: 'work_briefcase',
        targets: const GoalTargets(daily: target, weekly: target),
        operationId: 'pack1-home-create-daily',
      );
      final weekly = <Goal>[];
      for (var index = 1; index <= 4; index += 1) {
        weekly.add(
          await goalRepository.createGoal(
            profileId: profile.id,
            role: GoalRole.weekly,
            title: 'Replacement Weekly $index',
            iconId: index.isOdd ? 'learning_open_book' : 'social_two_people',
            targets: const GoalTargets(weekly: target),
            operationId: 'pack1-home-create-weekly-$index',
          ),
        );
      }
      final monthly = await goalRepository.createGoal(
        profileId: profile.id,
        role: GoalRole.weeklyMonthly,
        title: 'Replacement Monthly',
        iconId: 'spiritual_temple',
        targets: const GoalTargets(weekly: target, monthly: target),
        operationId: 'pack1-home-create-monthly',
      );

      final activityCountBefore = await (database.select(
        database.goalActivities,
      )..where((table) => table.profileId.equals(profile.id))).get();
      final ledgerCountBefore = await (database.select(
        database.activityLedgerEntries,
      )..where((table) => table.profileId.equals(profile.id))).get();
      final reportCountBefore = await (database.select(
        database.outcomeReports,
      )..where((table) => table.profileId.equals(profile.id))).get();
      final before = await goalRepository.readProgress(
        profileId: profile.id,
        goalId: daily.id,
        today: monday,
      );
      expect(before, isNot(isNull));

      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Life Goals'), findsOneWidget);
      expect(
        find.byKey(Key('home-indicator-goal-${daily.id}')),
        findsOneWidget,
      );
      for (final goal in weekly) {
        expect(
          find.byKey(Key('home-indicator-goal-${goal.id}')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(Key('home-indicator-goal-${monthly.id}')),
        findsOneWidget,
      );
      expect(find.text('New People'), findsNothing);
      expect(find.text('Ministering Visit'), findsNothing);
      // R5 (owner 2026-08-16): the Active Pathways Home section and its
      // major separator were removed, so no separator scroll is performed.
      // Return the Home list to the top so the daily quick controls are
      // fully hittable again (ensureVisible stops short of the app-bar
      // edge).
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, 800),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('home-daily-target-quick-control')),
        findsOneWidget,
      );
      Future<GoalProgress?> waitForDailyTarget(int expected) async {
        GoalProgress? latest;
        for (var attempt = 0; attempt < 40; attempt += 1) {
          await tester.pump(const Duration(milliseconds: 50));
          latest = await goalRepository.readProgress(
            profileId: profile.id,
            goalId: daily.id,
            today: monday,
          );
          if (latest?.dailyTarget.value?.scaledValue == expected) {
            return latest;
          }
        }
        return latest;
      }

      await tester.tap(find.byKey(const Key('home-daily-target-plus')));
      await tester.tap(find.byKey(const Key('home-daily-target-plus')));
      await tester.pump();
      final dailyTargetControl = find.byKey(
        const Key('home-daily-target-quick-control'),
      );
      expect(
        find.descendant(
          of: dailyTargetControl,
          matching: find.text(
            '${before!.dailyActual.display}/'
            '${before.dailyTarget.value!.scaledValue + 2}',
          ),
        ),
        findsOneWidget,
        reason: 'Both rapid taps must be visible in the next rendered frame.',
      );
      expect(
        find.byKey(const Key('home-canonical-plan-loading')),
        findsNothing,
        reason: 'A targeted counter update must not flash the Home loader.',
      );
      final afterIncrease = await waitForDailyTarget(
        before.dailyTarget.value!.scaledValue + 2,
      );
      expect(
        afterIncrease?.dailyTarget.value?.scaledValue,
        before.dailyTarget.value!.scaledValue + 2,
      );
      await tester.tap(find.byKey(const Key('home-daily-target-minus')));
      await tester.tap(find.byKey(const Key('home-daily-target-minus')));
      await tester.pump();
      expect(
        find.descendant(
          of: dailyTargetControl,
          matching: find.text(
            '${before.dailyActual.display}/'
            '${before.dailyTarget.value!.scaledValue}',
          ),
        ),
        findsOneWidget,
        reason: 'Both rapid decreases must be visible in the next frame.',
      );
      expect(
        find.byKey(const Key('home-canonical-plan-loading')),
        findsNothing,
      );
      final after = await waitForDailyTarget(
        before.dailyTarget.value!.scaledValue,
      );
      expect(
        after?.dailyTarget.value?.scaledValue,
        before.dailyTarget.value!.scaledValue,
      );
      expect(find.byKey(const Key('home-daily-target-dialog')), findsNothing);
      expect(after?.dailyActual.scaledValue, before.dailyActual.scaledValue);
      expect(after?.dailyActual.scale, before.dailyActual.scale);
      expect(after?.dailyActual.unit, before.dailyActual.unit);
      expect(after?.weeklyActual.scaledValue, before.weeklyActual.scaledValue);
      expect(after?.weeklyActual.scale, before.weeklyActual.scale);
      expect(after?.weeklyActual.unit, before.weeklyActual.unit);
      expect(
        after?.monthlyActual.scaledValue,
        before.monthlyActual.scaledValue,
      );
      expect(after?.monthlyActual.scale, before.monthlyActual.scale);
      expect(after?.monthlyActual.unit, before.monthlyActual.unit);
      final activityCountAfter = await (database.select(
        database.goalActivities,
      )..where((table) => table.profileId.equals(profile.id))).get();
      final ledgerCountAfter = await (database.select(
        database.activityLedgerEntries,
      )..where((table) => table.profileId.equals(profile.id))).get();
      final reportCountAfter = await (database.select(
        database.outcomeReports,
      )..where((table) => table.profileId.equals(profile.id))).get();
      expect(activityCountAfter, hasLength(activityCountBefore.length));
      expect(ledgerCountAfter, hasLength(ledgerCountBefore.length));
      expect(reportCountAfter, hasLength(reportCountBefore.length));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
