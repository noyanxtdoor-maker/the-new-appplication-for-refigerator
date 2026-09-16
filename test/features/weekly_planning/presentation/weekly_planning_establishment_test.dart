import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/application/goal_repository.dart';
import 'package:rmplanner/features/goals/domain/assigned_event_type_draft.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/domain/goal_event_type_policy.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/settings/application/start_of_week_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';
import 'package:rmplanner/features/weekly_planning/presentation/weekly_planning_screen.dart';

import '../../../support/test_dependencies.dart';

const _monday = PlannerDate(year: 2026, month: 7, day: 27);

/// Weekly Planning repository spy.
///
/// - [openOrCreate] (the rich projection entry) NEVER completes.  Any code
///   path that gates on it hangs forever, so a test that renders Goal rows
///   proves establishment did not touch the rich projection.
/// - [ensurePeriod] is immediate unless [gateEnsure] was called, and throws
///   when [failEnsure] is set, so durable-establishment and retry states can
///   be exercised deterministically.
final class _FakeWeeklyPlanningRepository implements WeeklyPlanningRepository {
  _FakeWeeklyPlanningRepository({this.today = _monday});

  PlannerDate today;
  bool established = true;
  int openOrCreateCalls = 0;
  int ensureCalls = 0;
  int todayForProfileCalls = 0;
  bool failEnsure = false;
  final Completer<void> _openOrCreateGate = Completer<void>();
  Completer<void>? _ensureGate;

  void gateEnsure() {
    _ensureGate = Completer<void>();
  }

  void releaseEnsure() {
    _ensureGate?.complete();
  }

  @override
  Future<PlannerDate> todayForProfile(String profileId) async {
    todayForProfileCalls += 1;
    return today;
  }

  @override
  Future<WeeklyPlan> openOrCreate({
    required String profileId,
    required PlannerDate date,
    int startDay = DateTime.monday,
  }) async {
    openOrCreateCalls += 1;
    await _openOrCreateGate.future; // Never released: rich projection hangs.
    throw StateError('openOrCreate must never gate establishment (A1).');
  }

  @override
  Future<bool> periodExists({
    required String profileId,
    required PlannerDate periodStart,
  }) async {
    return established;
  }

  @override
  Future<void> ensurePeriod({
    required String profileId,
    required PlannerDate periodStart,
    int startDay = DateTime.monday,
  }) async {
    ensureCalls += 1;
    if (failEnsure) {
      throw StateError('Injected ensure failure (A1).');
    }
    final gate = _ensureGate;
    if (gate != null) {
      // Keep the completer reachable while awaiting so [releaseEnsure] can
      // complete it.
      await gate.future;
      _ensureGate = null;
    }
    established = true;
  }

  @override
  Future<WeeklyPlan?> readPlanForPeriod({
    required String profileId,
    required PlannerDate periodStart,
  }) async => null;

  @override
  Future<WeeklyPlan?> readPlan({
    required String profileId,
    required String planId,
  }) async => null;

  @override
  Future<List<WeeklyPlan>> readHistory(String profileId) async =>
      const <WeeklyPlan>[];
}

/// Goal repository whose [readPlanning] can be held open after a change
/// emission, so the edit-return reload retention contract can be observed.
final class _ControlledGoalRepository implements GoalRepository {
  _ControlledGoalRepository(this.snapshot);

  GoalPlanningSnapshot snapshot;
  final StreamController<int> _changes = StreamController<int>.broadcast();
  Completer<void>? _holdPlanning;
  int readPlanningCalls = 0;

  void emitChange() {
    _changes.add(_changes.isClosed ? 0 : 1);
  }

  void holdNextPlanning() {
    _holdPlanning = Completer<void>();
  }

  void releasePlanning() {
    _holdPlanning?.complete();
  }

  @override
  Stream<int> watchChanges(String profileId) => _changes.stream;

  @override
  Future<GoalPlanningSnapshot> readPlanning({
    required String profileId,
    required PlannerDate periodStart,
    PlannerDate? today,
    int startDay = DateTime.monday,
  }) async {
    readPlanningCalls += 1;
    final hold = _holdPlanning;
    if (hold != null) {
      // Keep the completer reachable while awaiting so [releasePlanning]
      // can complete it.
      await hold.future;
      _holdPlanning = null;
    }
    return snapshot;
  }

  @override
  Future<GoalCapacity> readCapacity(String profileId) async =>
      const GoalCapacity(activeByRole: <GoalRole, int>{});

  @override
  Future<void> ensureCanonicalGoals(String profileId) async {}

  @override
  Future<List<Goal>> readActiveGoals(String profileId) async => const <Goal>[];

  @override
  Future<Goal?> readGoal({
    required String profileId,
    required String goalId,
  }) async => null;

  @override
  Future<int?> nextAvailableSlot({
    required String profileId,
    required GoalRole role,
  }) async => 0;

  @override
  Future<Goal> createGoal({
    required String profileId,
    required GoalRole role,
    required String title,
    required GoalTargets targets,
    String? indicatorKey,
    String? iconId,
    String? operationId,
    int? expectedSlotIndex,
    int startDay = DateTime.monday,
    AssignedEventTypeDraft? assignedEventTypeDraft,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Goal> saveGoal({
    required String profileId,
    required String goalId,
    required String title,
    required GoalTargets targets,
    String? iconId,
    String? operationId,
    PlannerDate? today,
    int startDay = DateTime.monday,
    AssignedEventTypeDraft? assignedEventTypeDraft,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> archiveGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) async {}

  @override
  Future<Goal> restoreGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) async {}

  @override
  Future<List<Goal>> readArchivedGoals({
    required String profileId,
    String? query,
  }) async => const <Goal>[];

  @override
  Future<List<GoalActivityHistoryItem>> readActivityHistory(
    String profileId, {
    String? goalId,
  }) async => const <GoalActivityHistoryItem>[];

  @override
  Future<Map<String, Object?>> exportGoalBackup(String profileId) async =>
      <String, Object?>{};

  @override
  Future<void> importGoalBackup({
    required String profileId,
    required Map<String, Object?> backup,
  }) async {}

  @override
  Future<Map<String, Object?>> exportBackup(String profileId) async =>
      <String, Object?>{};

  @override
  Future<void> importBackup({
    required String profileId,
    required Map<String, Object?> backup,
  }) async {}

  @override
  Future<GoalProgress?> readProgress({
    required String profileId,
    required String goalId,
    required PlannerDate today,
    int startDay = DateTime.monday,
  }) async => null;

  /// Additive fake implementation (contract P): derives raw candidates from
  /// the snapshot's canonical slots (daily.goal, each weekly.goal,
  /// monthly.goal — there is NO snapshot.goals) and applies the exact
  /// production domain validator. Model-only fake: raw completed-status
  /// behavior belongs to real DB fixture tests.
  @override
  Future<Map<int, LiveGoalEventTypeBinding>> readLiveEventTypeBindings(
    String profileId,
  ) {
    final candidates = <LiveGoalCandidateRow>[
      ...[
        ?snapshot.daily?.goal,
        ...snapshot.weekly.map((progress) => progress.goal),
        ?snapshot.monthly?.goal,
      ].map(
        (goal) => LiveGoalCandidateRow(
          id: goal.id,
          profileId: goal.profileId,
          status: goal.isActive ? 'active' : goal.status.name,
          role: goal.role.storageName,
          activeSlotIndex: goal.activeSlotIndex,
          assignedEventTypeStableKey: goal.assignedEventTypeStableKey,
          indicatorKey: goal.indicatorKey,
          title: goal.title,
        ),
      ),
    ];
    return Future<Map<int, LiveGoalEventTypeBinding>>.value(
      GoalEventTypePolicy.bindingsForCandidates(
        candidates: candidates,
        profileId: profileId,
      ),
    );
  }
}

final class _FixedStartOfWeekRepository implements StartOfWeekRepository {
  _FixedStartOfWeekRepository(this.value);

  int value;
  int readCalls = 0;

  @override
  Future<int> readStartOfWeek({required String profileId}) async {
    readCalls += 1;
    return value;
  }

  @override
  Future<void> saveStartOfWeek({
    required String profileId,
    required int startDay,
  }) async {
    value = startDay;
  }
}

Goal _goal(String id, String title) => Goal(
  id: id,
  profileId: 'profile',
  indicatorKey: 'job_applications',
  assignedEventTypeStableKey: null,
  role: GoalRole.weekly,
  activeSlotIndex: 0,
  title: title,
  iconId: 'work_briefcase',
  status: GoalStatus.active,
  createdAtUtc: DateTime.utc(2026, 7, 27),
  updatedAtUtc: DateTime.utc(2026, 7, 27),
  archivedAtUtc: null,
  deletedAtUtc: null,
);

GoalProgress _progress(String id, String title) => GoalProgress(
  goal: _goal(id, title),
  dailyActual: const IndicatorAmount(scaledValue: 0, scale: 0, unit: 'count'),
  dailyTarget: const IndicatorTarget.notSet(),
  weeklyActual: const IndicatorAmount(scaledValue: 0, scale: 0, unit: 'count'),
  weeklyTarget: const IndicatorTarget.notSet(),
  monthlyActual: const IndicatorAmount(scaledValue: 0, scale: 0, unit: 'count'),
  monthlyTarget: const IndicatorTarget.notSet(),
);

GoalPlanningSnapshot _snapshot({String title = 'Job Applications'}) =>
    GoalPlanningSnapshot(
      periodStart: _monday,
      periodEnd: _monday.addDays(6),
      daily: null,
      weekly: <GoalProgress>[_progress('goal-1', title)],
      monthly: null,
    );

void main() {
  late AppDatabase database;
  late _FakeWeeklyPlanningRepository weekly;

  setUp(() {
    database = openMemoryDatabase();
    addTearDown(database.close);
    weekly = _FakeWeeklyPlanningRepository();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    GoalRepository? goals,
    StartOfWeekRepository? startOfWeek,
    PlannerDate? periodStart,
    bool settle = true,
  }) async {
    final startup = buildTestRepository(database: database);
    await startup.completeOnboarding();
    final overrides = [
      startupRepositoryProvider.overrideWithValue(startup),
      diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      plannerDateSourceProvider.overrideWithValue(
        const FixedPlannerDateSource(_monday),
      ),
      weeklyPlanningRepositoryProvider.overrideWithValue(weekly),
      goalRepositoryProvider.overrideWithValue(
        goals ?? _ControlledGoalRepository(_snapshot()),
      ),
      startOfWeekRepositoryProvider.overrideWithValue(
        startOfWeek ?? _FixedStartOfWeekRepository(DateTime.monday),
      ),
    ];
    // Gate the screen on startup readiness inside the SAME scope: the
    // screen's providers use ref.read on the startup controller, so they
    // must never first-build while the async gate is still Opening (a cached
    // "not ready" error would persist forever).
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: Consumer(
          builder: (context, ref, child) {
            final state = ref.watch(startupControllerProvider);
            if (state is! StartupReady) {
              return const SizedBox();
            }
            return MaterialApp(
              theme: AppTheme.dark(),
              home: WeeklyPlanningScreen(periodStart: periodStart),
            );
          },
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // Honest scoped loading is an indeterminate animation; settle manually.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('A1.1: establishment never waits on the rich projection '
      '(openOrCreate hangs forever, rows still render)', (tester) async {
    await pumpScreen(tester, periodStart: _monday);

    // The rich projection was never even attempted for establishment.
    expect(weekly.openOrCreateCalls, 0);
    expect(weekly.ensureCalls, 1);
    expect(find.byKey(const Key('weekly-plan-list')), findsOneWidget);
    expect(find.text('Job Applications'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A1.2: durable establishment is honest (scoped loading, then rows; '
    'failure shows retry and no fake established state)',
    (tester) async {
      weekly.gateEnsure();
      await pumpScreen(tester, periodStart: _monday, settle: false);

      // Route chrome mounts immediately; no fake established rows yet.
      expect(find.byKey(const Key('weekly-plan-back-home')), findsOneWidget);
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason:
            'Before durable establishment an honest scoped loading state '
            'must be shown.',
      );
      expect(find.byKey(const Key('weekly-plan-list')), findsNothing);

      weekly.releaseEnsure();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('weekly-plan-list')), findsOneWidget);
      expect(find.text('Job Applications'), findsOneWidget);

      // Failure path: retry surfaces, no fake established rows.
      weekly.failEnsure = true;
      weekly.ensureCalls = 0;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await pumpScreen(tester, periodStart: _monday, settle: false);
      expect(find.textContaining('could not be opened'), findsOneWidget);
      expect(find.byKey(const Key('weekly-plan-list')), findsNothing);

      weekly.failEnsure = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('weekly-plan-list')), findsOneWidget);
      expect(weekly.ensureCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('A1.4: browsing a historical period never establishes a row', (
    tester,
  ) async {
    await pumpScreen(tester, periodStart: _monday);
    expect(weekly.ensureCalls, 1);
    expect(find.byKey(const Key('weekly-plan-list')), findsOneWidget);

    // Previous-week arrow browses the historical period.
    await tester.tap(find.byTooltip('Previous week'));
    await tester.pumpAndSettle();

    expect(weekly.ensureCalls, 1);
    expect(weekly.openOrCreateCalls, 0);
    expect(
      find.byKey(const Key('weekly-plan-list')),
      findsOneWidget,
      reason: 'Historical periods stay read-only and keep rendering.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A1.5: edit-return reload keeps the last confirmed Goal rows while the '
    'new read is held (no whole-body spinner)',
    (tester) async {
      final goals = _ControlledGoalRepository(_snapshot());
      await pumpScreen(tester, goals: goals, periodStart: _monday);
      expect(find.text('Job Applications'), findsOneWidget);

      // GI-02: weekly planning goal row art is exactly 2x (32 -> 64).
      expect(
        tester.widget<GoalIcon>(find.byType(GoalIcon).first).size,
        64,
        reason: 'GI-02 weekly planning goal row art must be 64dp (2x of 32)',
      );

      // A Goal change triggers a canonical reload; the new read is held.
      final readsBefore = goals.readPlanningCalls;
      goals.holdNextPlanning();
      goals.emitChange();
      await tester.pump();
      await tester.pump();

      expect(
        goals.readPlanningCalls,
        readsBefore + 1,
        reason: 'The goal change must re-read the canonical projection.',
      );
      expect(
        find.text('Job Applications'),
        findsOneWidget,
        reason: 'Confirmed rows must stay visible during a dependency reload.',
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason:
            'A dependency reload must not replace rows with a whole-body '
            'spinner.',
      );

      // The new canonical rows replace the old ones after success.
      goals.snapshot = _snapshot(title: 'Renamed Goal');
      goals.releasePlanning();
      await tester.pumpAndSettle();
      expect(find.text('Renamed Goal'), findsOneWidget);
      expect(find.text('Job Applications'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A1.6: an explicit route period never waits on the today/time-zone '
    'Future to resolve the week',
    (tester) async {
      // todayForProfile never completes (no TZ resolution available).
      final gatedToday = _GatedTodayRepository(today: _monday);
      weekly = gatedToday;

      await pumpScreen(tester, periodStart: _monday);

      expect(
        find.byKey(const Key('weekly-plan-list')),
        findsOneWidget,
        reason:
            'The explicit route period must resolve the week without the '
            'today/time-zone Future.',
      );
      // The route never blocks on the today Future.  At most the Goal Plan
      // body's own week-navigation check may consult it afterwards.
      expect(
        gatedToday.todayForProfileCalls,
        lessThanOrEqualTo(1),
        reason: 'Week resolution must not depend on the today/time-zone read.',
      );
      expect(weekly.ensureCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

/// Weekly repository whose [todayForProfile] hangs forever unless released.
final class _GatedTodayRepository extends _FakeWeeklyPlanningRepository {
  _GatedTodayRepository({super.today});

  final Completer<void> _todayGate = Completer<void>();

  @override
  Future<PlannerDate> todayForProfile(String profileId) async {
    todayForProfileCalls += 1;
    await _todayGate.future;
    return today;
  }
}
