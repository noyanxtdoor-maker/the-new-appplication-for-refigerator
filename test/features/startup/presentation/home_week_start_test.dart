import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/settings/application/start_of_week_repository.dart';
import 'package:rmplanner/features/settings/data/drift_start_of_week_repository.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';

import '../../../support/test_dependencies.dart';

final class _DelayedWeeklyPlanningRepository
    implements WeeklyPlanningRepository {
  _DelayedWeeklyPlanningRepository({
    required this.today,
    required this.established,
  });

  final PlannerDate today;
  bool established;
  final Completer<void> _release = Completer<void>();
  int openOrCreateCalls = 0;
  int ensureCalls = 0;
  final List<String> periodExistsStarts = <String>[];
  final Set<String> establishedPeriods = <String>{};

  void release() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<WeeklyPlan> openOrCreate({
    required String profileId,
    required PlannerDate date,
    int startDay = DateTime.monday,
  }) async {
    openOrCreateCalls += 1;
    // The rich projection never completes: any establishment path that
    // depends on it hangs forever and fails the A1 isolation assertions.
    await _release.future;
    final period = WeeklyPeriod.containing(date, startDay: startDay);
    return WeeklyPlan(
      id: 'delayed-plan',
      profileId: profileId,
      period: period,
      timeZoneId: 'Asia/Manila',
      storedState: WeeklyPlanState.draft,
      indicators: const <WeeklyIndicatorReview>[],
      createdAtUtc: DateTime.utc(2026, 8, 13),
      updatedAtUtc: DateTime.utc(2026, 8, 13),
    );
  }

  @override
  Future<bool> periodExists({
    required String profileId,
    required PlannerDate periodStart,
  }) async {
    periodExistsStarts.add(periodStart.iso8601);
    return established || establishedPeriods.contains(periodStart.iso8601);
  }

  @override
  Future<void> ensurePeriod({
    required String profileId,
    required PlannerDate periodStart,
    int startDay = DateTime.monday,
  }) async {
    ensureCalls += 1;
    established = true;
  }

  @override
  Future<WeeklyPlan?> readPlanForPeriod({
    required String profileId,
    required PlannerDate periodStart,
  }) async {
    if (!established) {
      return null;
    }
    return WeeklyPlan(
      id: 'existing-plan',
      profileId: profileId,
      period: WeeklyPeriod.containing(periodStart),
      timeZoneId: 'Asia/Manila',
      storedState: WeeklyPlanState.draft,
      indicators: const <WeeklyIndicatorReview>[],
      createdAtUtc: DateTime.utc(2026, 8, 13),
      updatedAtUtc: DateTime.utc(2026, 8, 13),
    );
  }

  @override
  Future<PlannerDate> todayForProfile(String profileId) async => today;

  @override
  Future<WeeklyPlan?> readPlan({
    required String profileId,
    required String planId,
  }) async => null;

  @override
  Future<List<WeeklyPlan>> readHistory(String profileId) async =>
      const <WeeklyPlan>[];
}

final class _MutablePlannerDateSource implements PlannerDateSource {
  _MutablePlannerDateSource(this.value);

  PlannerDate value;

  @override
  PlannerDate today() => value;
}

final class _ControlledStartOfWeekRepository
    implements StartOfWeekRepository {
  _ControlledStartOfWeekRepository(this.value);

  int value;
  int readCalls = 0;
  bool _holdNextRead = false;
  Completer<int>? _pendingRead;

  void holdNextRead() {
    _holdNextRead = true;
    _pendingRead = Completer<int>();
  }

  void releasePendingRead() {
    final pending = _pendingRead;
    if (pending != null && !pending.isCompleted) {
      pending.complete(value);
    }
  }

  @override
  Future<int> readStartOfWeek({required String profileId}) {
    readCalls += 1;
    if (_holdNextRead) {
      _holdNextRead = false;
      return _pendingRead!.future;
    }
    return Future<int>.value(value);
  }

  @override
  Future<void> saveStartOfWeek({
    required String profileId,
    required int startDay,
  }) async {
    value = startDay;
  }
}

void main() {
  // 2026-08-13 is a Thursday.  Monday week = Aug 10-16; Sunday week = Aug 9-15.
  const thursday = PlannerDate(year: 2026, month: 8, day: 13);

  Future<void> pumpHome(
    WidgetTester tester,
    AppDatabase database, {
    PlannerDate today = thursday,
    PlannerDateSource? plannerDateSource,
    WeeklyPlanningRepository? weeklyPlanningRepository,
    StartOfWeekRepository? startOfWeekRepository,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    final m6LegacySeedProfile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, m6LegacySeedProfile.id);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerDateSource:
            plannerDateSource ?? FixedPlannerDateSource(today),
        weeklyPlanningRepository: weeklyPlanningRepository,
        startOfWeekRepository: startOfWeekRepository,
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // Pre-readiness Home may hold an honest skeleton; settle manually to
      // avoid a pumpAndSettle timeout from any provisional loading state.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('unestablished current period hides cards and shows Start Planning',
      (tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpHome(tester, database);

    // Header + View All remain.
    expect(find.text('Life Goals'), findsOneWidget);
    expect(find.byKey(const Key('home-wli-view-all')), findsOneWidget);
    // Life Goal cards are hidden.
    final goalCards = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('home-indicator-goal-');
    });
    expect(goalCards, findsNothing);
    expect(find.byKey(const Key('home-daily-target-quick-control')), findsNothing);
    // Centered Start Planning is visible.
    expect(find.byKey(const Key('home-start-weekly-planning')), findsOneWidget);
    expect(find.text('Start Planning'), findsOneWidget);
    // The established pill is NOT shown.
    expect(find.text('Goal Planning'), findsNothing);
    // R5 (owner 2026-08-16): Pathways is deferred; the fabricated Active
    // Pathways card must not render on Home at all.
    expect(find.byKey(const Key('home-pathway-employment')), findsNothing);
    expect(find.text('Active Pathways'), findsNothing);
  });

  testWidgets(
      'deliberate entry establishes the period; Home then shows cards and '
      'Goal Planning', (tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    await pumpHome(tester, database);

    expect(find.byKey(const Key('home-start-weekly-planning')), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-start-weekly-planning')));
    await tester.pumpAndSettle();
    // The Goal Planning screen opens with the new title.
    expect(find.text('Goal Planning'), findsWidgets);

    // Return Home: now established.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Goal Planning'), findsOneWidget);
    expect(find.byKey(const Key('home-start-weekly-planning')), findsNothing);
    // Cards are visible again (the six canonical Goals were bootstrapped).
    final goalCards = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('home-indicator-goal-');
    });
    expect(goalCards, findsWidgets);

    // HI-02: Home Life Goal card art uses the audited largest pair at 76dp
    // (60 dp compact / 64 dp top+Temple) — the GI-02 2x Home sizes were
    // superseded by the owner-approved compact restore + icon visibility pass.
    final homeIcons = find.byType(GoalIcon);
    expect(homeIcons, findsWidgets);
    for (final element in homeIcons.evaluate()) {
      final size = (element.widget as GoalIcon).size;
      expect(
        size == 60 || size == 64,
        isTrue,
        reason: 'HI-02 Home card art must be 60dp (compact) or 64dp '
            '(top/Temple); found $size',
      );
    }
  });

  testWidgets('established Home shows the Goal Planning pill and 0/0 for unset',
      (tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    await seedLegacyCanonicalGoals(database, profile.id);
    await establishWeeklyPlan(
      database: database,
      profileId: profile.id,
      date: thursday,
    );
    await pumpHome(tester, database);

    expect(find.byKey(const Key('home-start-weekly-planning')), findsNothing);
    expect(find.text('Goal Planning'), findsOneWidget);
    // Home-only unset target renders 0/0 (never 0/Not set).
    expect(find.textContaining('Not set'), findsNothing);
    expect(find.text('0/0'), findsWidgets);
  });

  for (final entry in <({bool established, String button})>[
    (established: false, button: 'Start Planning'),
    (established: true, button: 'Goal Planning'),
  ]) {
    testWidgets(
      'A1: ${entry.button} opens Goal Planning via the lightweight ensure '
      'without the rich projection',
      (tester) async {
        final database = openMemoryDatabase();
        addTearDown(database.close);
        final delayed = _DelayedWeeklyPlanningRepository(
          today: thursday,
          established: entry.established,
        );
        addTearDown(delayed.release);
        await pumpHome(
          tester,
          database,
          weeklyPlanningRepository: delayed,
        );

        expect(find.text(entry.button), findsOneWidget);
        await tester.tap(find.byKey(const Key('weekly-targets-button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('weekly-plan-back-home')),
          findsOneWidget,
          reason:
              '${entry.button} must transfer control to the destination.',
        );
        expect(
          delayed.openOrCreateCalls,
          0,
          reason: 'Establishment must not call the rich projection (A1).',
        );
        expect(
          delayed.ensureCalls,
          1,
          reason: 'Establishment must use the lightweight idempotent ensure '
              '(A1).',
        );
        expect(
          find.byKey(const Key('weekly-plan-list')),
          findsOneWidget,
          reason: 'Goal rows must render without the rich projection.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'A2: same-day resume keeps confirmed Home without provider reload churn',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
      await seedLegacyCanonicalGoals(database, profile.id);
      await establishWeeklyPlan(
        database: database,
        profileId: profile.id,
        date: thursday,
        startDay: DateTime.sunday,
      );
      final dates = _MutablePlannerDateSource(thursday);
      final startOfWeek = _ControlledStartOfWeekRepository(DateTime.sunday);
      addTearDown(startOfWeek.releasePendingRead);
      await pumpHome(
        tester,
        database,
        plannerDateSource: dates,
        startOfWeekRepository: startOfWeek,
      );
      final initialReads = startOfWeek.readCalls;
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(
        find.byKey(const Key('home-canonical-plan-loading')),
        findsNothing,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(
        startOfWeek.readCalls,
        initialReads,
        reason: 'Same-day resume must not re-read an unchanged preference.',
      );
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(
        find.byKey(const Key('home-canonical-plan-loading')),
        findsNothing,
      );

      // The accepted resume path queues reminder reconciliation behind a
      // yield (a zero-duration timer). The same-day assertions above are
      // already captured; drain the queued work so no timer outlives the
      // disposed tree.
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A2: date-boundary resume retains confirmed Home while preference reloads',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
      await seedLegacyCanonicalGoals(database, profile.id);
      await establishWeeklyPlan(
        database: database,
        profileId: profile.id,
        date: thursday,
        startDay: DateTime.sunday,
      );
      final dates = _MutablePlannerDateSource(thursday);
      final startOfWeek = _ControlledStartOfWeekRepository(DateTime.sunday);
      addTearDown(startOfWeek.releasePendingRead);
      await pumpHome(
        tester,
        database,
        plannerDateSource: dates,
        startOfWeekRepository: startOfWeek,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('home-app-bar'))),
      );
      final initialReads = startOfWeek.readCalls;
      expect(container.read(startOfWeekProvider), DateTime.sunday);
      expect(find.text('Goal Planning'), findsOneWidget);

      startOfWeek.holdNextRead();
      dates.value = thursday.addDays(1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(startOfWeek.readCalls, initialReads + 1);
      expect(
        container.read(startOfWeekProvider),
        DateTime.sunday,
        reason:
            'A pending refresh must preserve the last confirmed preference.',
      );
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(
        find.byKey(const Key('home-canonical-plan-loading')),
        findsNothing,
      );

      startOfWeek.releasePendingRead();
      await tester.pumpAndSettle();
      expect(container.read(startOfWeekProvider), DateTime.sunday);
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A2.1: a non-Monday profile never starts a Monday period family before '
    'the initial preference read is confirmed',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
      await seedLegacyCanonicalGoals(database, profile.id);
      // The stored preference is Sunday and the Sunday week is established.
      await establishWeeklyPlan(
        database: database,
        profileId: profile.id,
        date: thursday,
        startDay: DateTime.sunday,
      );
      final startOfWeek = _ControlledStartOfWeekRepository(DateTime.sunday);
      addTearDown(startOfWeek.releasePendingRead);
      final weekly = _DelayedWeeklyPlanningRepository(
        today: thursday,
        established: true,
      );
      addTearDown(weekly.release);
      // Gate the initial persisted read so the provisional default (Monday)
      // is the only value Home could form families with.
      startOfWeek.holdNextRead();
      await pumpHome(
        tester,
        database,
        weeklyPlanningRepository: weekly,
        startOfWeekRepository: startOfWeek,
        settle: false,
      );

      expect(
        weekly.periodExistsStarts,
        isEmpty,
        reason:
            'Before the initial preference read is confirmed, no period '
            'family (not even the Monday default) may be started.',
      );
      expect(find.text('Start Planning'), findsNothing);
      expect(find.text('Goal Planning'), findsNothing);
      expect(
        find.byKey(const Key('home-canonical-plan-loading')),
        findsNothing,
        reason: 'Pre-readiness Home must not show a central spinner.',
      );

      startOfWeek.releasePendingRead();
      await tester.pumpAndSettle();

      // Exactly ONE family begins, keyed by the CONFIGURED Sunday week
      // (2026-08-09), never the Monday week (2026-08-10).
      expect(
        weekly.periodExistsStarts,
        <String>['2026-08-09'],
        reason:
            'Exactly one configured-period family must begin; the Monday '
            'family must never start.',
      );
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A2.3: a genuine new period starts an honest new family; the old family '
    'value is never reused',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
      await seedLegacyCanonicalGoals(database, profile.id);
      // Sunday preference; Thursday 2026-08-13 -> Sunday week Aug 9-15.
      final startOfWeek = _ControlledStartOfWeekRepository(DateTime.sunday);
      addTearDown(startOfWeek.releasePendingRead);
      await establishWeeklyPlan(
        database: database,
        profileId: profile.id,
        date: thursday,
        startDay: DateTime.sunday,
      );
      final dates = _MutablePlannerDateSource(thursday);
      final weekly = _DelayedWeeklyPlanningRepository(
        today: thursday,
        established: false,
      )..establishedPeriods.add('2026-08-09');
      addTearDown(weekly.release);
      await pumpHome(
        tester,
        database,
        plannerDateSource: dates,
        weeklyPlanningRepository: weekly,
        startOfWeekRepository: startOfWeek,
      );
      expect(find.text('Goal Planning'), findsOneWidget);

      // Cross the Sunday boundary into a genuinely NEW period (Aug 16-22)
      // through the app's date-change path.
      dates.value = thursday.addDays(4); // Sunday 2026-08-17.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        weekly.periodExistsStarts,
        contains('2026-08-16'),
        reason: 'The genuinely new period must begin its own family.',
      );
      expect(
        find.text('Goal Planning'),
        findsNothing,
        reason: 'The old period established value must not be reused for the '
            'new family.',
      );
      expect(
        find.text('Start Planning'),
        findsOneWidget,
        reason: 'The new period is honestly unestablished.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a non-Monday configured start is used for the current period',
      (tester) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    await seedLegacyCanonicalGoals(database, profile.id);
    final startOfWeek = DriftStartOfWeekRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 8, 13, 12)),
    );
    await startOfWeek.saveStartOfWeek(
      profileId: profile.id,
      startDay: DateTime.sunday,
    );
    // Establish the SUNDAY week (Aug 9-15), not the Monday week (Aug 10-16).
    await establishWeeklyPlan(
      database: database,
      profileId: profile.id,
      date: thursday,
      startDay: DateTime.sunday,
    );
    await pumpHome(tester, database);

    expect(find.text('Goal Planning'), findsOneWidget);
    expect(find.byKey(const Key('home-start-weekly-planning')), findsNothing);
    // With only the Sunday week established, opening planning must land on
    // the Sunday-resolved period (Aug 9-15).
    await tester.tap(find.byKey(const Key('weekly-targets-button')));
    await tester.pumpAndSettle();
    expect(find.text('Goal Planning'), findsWidgets);
    expect(find.text('Aug 9 – Aug 15, 2026'), findsOneWidget);
  });
}
