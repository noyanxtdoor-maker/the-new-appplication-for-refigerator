// M1 (T4 / S02) — Home daily-target failure must never emit raw error text.
//
// The failure handler used to interpolate the caught object into `debugPrint`,
// which stringifies repository/plugin exceptions that can carry durable values.
// The correction replaces ONLY the log line with one fixed technical code; the
// optimistic overlay, the honest rollback, the provider invalidations and the
// per-Goal write queue must all behave exactly as before.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/application/goal_repository.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/assigned_event_type_draft.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/domain/goal_event_type_policy.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';

import '../../../support/test_dependencies.dart';

const PlannerDate _monday = PlannerDate(year: 2026, month: 7, day: 27);
const String _sentinel = 'M1_SECRET_EXCEPTION';
const String _privateTitle = 'M1_PRIVATE_GOAL_TITLE_9f3c';
const String _privateNotes = 'M1_PRIVATE_NOTE_71ab';
const String _staticCode = '[NextTransfer] home_daily_target_write_failed';

/// Forwarding [GoalRepository] that fails exactly one armed write/read and
/// forwards every other call to the real Drift repository, so rollback reloads
/// keep observing canonical truth.
final class _FaultGoalRepository implements GoalRepository {
  _FaultGoalRepository(this._inner);

  final GoalRepository _inner;

  bool armed = false;
  bool failSave = false;
  int progressFailures = 0;
  Completer<void>? saveGate;
  Completer<void>? progressGate;

  Object _fault() =>
      StateError('$_sentinel title=$_privateTitle notes=$_privateNotes');

  void arm({bool save = false, int progressReads = 0}) {
    armed = true;
    failSave = save;
    progressFailures = progressReads;
  }

  void disarm() {
    armed = false;
  }

  Completer<void> gateSave() {
    final completer = Completer<void>();
    saveGate = completer;
    return completer;
  }

  Completer<void> gateProgress() {
    final completer = Completer<void>();
    progressGate = completer;
    return completer;
  }

  @override
  Stream<int> watchChanges(String profileId) => _inner.watchChanges(profileId);

  @override
  Future<void> ensureCanonicalGoals(String profileId) =>
      _inner.ensureCanonicalGoals(profileId);

  @override
  Future<List<Goal>> readActiveGoals(String profileId) =>
      _inner.readActiveGoals(profileId);

  @override
  Future<Goal?> readGoal({
    required String profileId,
    required String goalId,
  }) => _inner.readGoal(profileId: profileId, goalId: goalId);

  @override
  Future<GoalCapacity> readCapacity(String profileId) =>
      _inner.readCapacity(profileId);

  @override
  Future<int?> nextAvailableSlot({
    required String profileId,
    required GoalRole role,
  }) => _inner.nextAvailableSlot(profileId: profileId, role: role);

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
    AssignedEventTypeDraft? assignedEventTypeDraft,
    int startDay = DateTime.monday,
  }) => _inner.createGoal(
    profileId: profileId,
    role: role,
    title: title,
    targets: targets,
    indicatorKey: indicatorKey,
    iconId: iconId,
    operationId: operationId,
    expectedSlotIndex: expectedSlotIndex,
    assignedEventTypeDraft: assignedEventTypeDraft,
    startDay: startDay,
  );

  @override
  Future<Goal> saveGoal({
    required String profileId,
    required String goalId,
    required String title,
    required GoalTargets targets,
    String? iconId,
    String? operationId,
    PlannerDate? today,
    AssignedEventTypeDraft? assignedEventTypeDraft,
    int startDay = DateTime.monday,
  }) async {
    if (armed && failSave) {
      final gate = saveGate;
      if (gate != null) {
        await gate.future;
      }
      throw _fault();
    }
    return _inner.saveGoal(
      profileId: profileId,
      goalId: goalId,
      title: title,
      targets: targets,
      iconId: iconId,
      operationId: operationId,
      today: today,
      assignedEventTypeDraft: assignedEventTypeDraft,
      startDay: startDay,
    );
  }

  @override
  Future<void> archiveGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) => _inner.archiveGoal(
    profileId: profileId,
    goalId: goalId,
    operationId: operationId,
  );

  @override
  Future<Goal> restoreGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) => _inner.restoreGoal(
    profileId: profileId,
    goalId: goalId,
    operationId: operationId,
  );

  @override
  Future<void> deleteGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) => _inner.deleteGoal(
    profileId: profileId,
    goalId: goalId,
    operationId: operationId,
  );

  @override
  Future<List<Goal>> readArchivedGoals({
    required String profileId,
    String? query,
  }) => _inner.readArchivedGoals(profileId: profileId, query: query);

  @override
  Future<List<GoalActivityHistoryItem>> readActivityHistory(
    String profileId, {
    String? goalId,
  }) => _inner.readActivityHistory(profileId, goalId: goalId);

  @override
  Future<Map<String, Object?>> exportGoalBackup(String profileId) =>
      _inner.exportGoalBackup(profileId);

  @override
  Future<void> importGoalBackup({
    required String profileId,
    required Map<String, Object?> backup,
  }) => _inner.importGoalBackup(profileId: profileId, backup: backup);

  @override
  Future<Map<String, Object?>> exportBackup(String profileId) =>
      _inner.exportBackup(profileId);

  @override
  Future<void> importBackup({
    required String profileId,
    required Map<String, Object?> backup,
  }) => _inner.importBackup(profileId: profileId, backup: backup);

  @override
  Future<Map<int, LiveGoalEventTypeBinding>> readLiveEventTypeBindings(
    String profileId,
  ) => _inner.readLiveEventTypeBindings(profileId);

  @override
  Future<GoalPlanningSnapshot> readPlanning({
    required String profileId,
    required PlannerDate periodStart,
    PlannerDate? today,
    int startDay = DateTime.monday,
  }) => _inner.readPlanning(
    profileId: profileId,
    periodStart: periodStart,
    today: today,
    startDay: startDay,
  );

  @override
  Future<GoalProgress?> readProgress({
    required String profileId,
    required String goalId,
    required PlannerDate today,
    int startDay = DateTime.monday,
  }) async {
    if (armed && progressFailures > 0) {
      progressFailures -= 1;
      final gate = progressGate;
      if (gate != null) {
        await gate.future;
      }
      throw _fault();
    }
    return _inner.readProgress(
      profileId: profileId,
      goalId: goalId,
      today: today,
      startDay: startDay,
    );
  }
}

/// One daily Goal (target 2) plus four weekly Goals on an established plan.
Future<({DriftGoalRepository canonical, Goal daily, String profileId})>
_prepare(AppDatabase database) async {
  final startup = buildTestRepository(database: database);
  final profile = await startup.completeOnboarding();
  // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
  // seeded explicitly instead of being created implicitly at onboarding.
  await seedLegacyCanonicalGoals(database, profile.id);
  await establishWeeklyPlan(
    database: database,
    profileId: profile.id,
    date: _monday,
  );
  final canonical = DriftGoalRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    identifiers: const UuidIdentifierSource(),
  );
  final defaults = await canonical.readActiveGoals(profile.id);
  for (var index = 0; index < defaults.length; index += 1) {
    await canonical.archiveGoal(
      profileId: profile.id,
      goalId: defaults[index].id,
      operationId: 'm1-redaction-archive-$index',
    );
  }
  const target = IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count');
  final daily = await canonical.createGoal(
    profileId: profile.id,
    role: GoalRole.dailyWeekly,
    title: 'M1 Daily',
    iconId: 'work_briefcase',
    targets: const GoalTargets(daily: target, weekly: target),
    operationId: 'm1-redaction-create-daily',
  );
  for (var index = 1; index <= 4; index += 1) {
    await canonical.createGoal(
      profileId: profile.id,
      role: GoalRole.weekly,
      title: 'M1 Weekly $index',
      iconId: index.isOdd ? 'learning_open_book' : 'social_two_people',
      targets: const GoalTargets(weekly: target),
      operationId: 'm1-redaction-create-weekly-$index',
    );
  }
  await canonical.createGoal(
    profileId: profile.id,
    role: GoalRole.weeklyMonthly,
    title: 'M1 Monthly',
    iconId: 'spiritual_temple',
    targets: const GoalTargets(weekly: target, monthly: target),
    operationId: 'm1-redaction-create-monthly',
  );
  return (canonical: canonical, daily: daily, profileId: profile.id);
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required AppDatabase database,
  required StartupRepository startup,
  required _FaultGoalRepository faults,
}) async {
  tester.view.physicalSize = const Size(393, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final privacy = TestPrivacyDependencies(database: database);
  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: startup,
      plannerDateSource: const FixedPlannerDateSource(_monday),
      extraOverrides: [goalRepositoryProvider.overrideWithValue(faults)],
    ),
  );
  await tester.pumpAndSettle();
  // Return the Home list to the top so the quick controls are hittable.
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 800));
  await tester.pumpAndSettle();
  // Dispose the mounted app BEFORE the database teardown: a FAILED widget test
  // does not tear the tree down, and closing the database while the app still
  // holds an open stream wedges the next test in the same file.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

void main() {
  testWidgets(
    'T4/S02 a failed daily-target write logs one fixed code and still rolls '
    'back',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final fixture = await _prepare(database);
      final baseline = (await fixture.canonical.readProgress(
        profileId: fixture.profileId,
        goalId: fixture.daily.id,
        today: _monday,
      ))!;
      expect(baseline.dailyTarget.value?.scaledValue, 2);
      final activityBefore = await database
          .select(database.goalActivities)
          .get();
      final ledgerBefore = await database
          .select(database.activityLedgerEntries)
          .get();
      final reportsBefore = await database
          .select(database.outcomeReports)
          .get();

      final faults = _FaultGoalRepository(fixture.canonical);
      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) {
          logs.add(message);
        }
      };
      addTearDown(() {
        debugPrint = originalDebugPrint;
      });

      await _pumpHome(
        tester,
        database: database,
        startup: buildTestRepository(database: database),
        faults: faults,
      );
      expect(
        find.byKey(const Key('home-daily-target-quick-control')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('home-canonical-plan-loading')), findsNothing);

      // Arm the failure only AFTER real Home rendered, then hold the write open
      // so the optimistic overlay is observable in its own frame.
      faults.arm(save: true);
      final gate = faults.gateSave();
      logs.clear();
      await tester.tap(find.byKey(const Key('home-daily-target-plus')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('home-daily-target-quick-control')),
          matching: find.text('${baseline.dailyActual.display}/3'),
        ),
        findsOneWidget,
        reason: 'the optimistic overlay is unchanged by this correction',
      );

      gate.complete();
      await tester.pumpAndSettle();

      final persisted = await fixture.canonical.readProgress(
        profileId: fixture.profileId,
        goalId: fixture.daily.id,
        today: _monday,
      );
      expect(
        persisted?.dailyTarget.value?.scaledValue,
        2,
        reason: 'the canonical store never moved',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('home-daily-target-quick-control')),
          matching: find.text('${baseline.dailyActual.display}/2'),
        ),
        findsOneWidget,
        reason: 'the display rolls back to canonical truth',
      );
      expect(
        await database.select(database.goalActivities).get(),
        hasLength(activityBefore.length),
      );
      expect(
        await database.select(database.activityLedgerEntries).get(),
        hasLength(ledgerBefore.length),
      );
      expect(
        await database.select(database.outcomeReports).get(),
        hasLength(reportsBefore.length),
      );

      // The security assertions: the raw sink must carry nothing private.
      expect(
        logs.where((line) => line.contains(_sentinel)),
        isEmpty,
        reason: 'the raw exception must never reach the debug sink',
      );
      expect(logs.where((line) => line.contains(_privateTitle)), isEmpty);
      expect(logs.where((line) => line.contains(_privateNotes)), isEmpty);
      expect(
        logs.where((line) => line == _staticCode),
        hasLength(1),
        reason: 'exactly one fixed technical code is emitted',
      );

      // The per-Goal queue must have been released for the next write.
      faults.disarm();
      await tester.tap(find.byKey(const Key('home-daily-target-plus')));
      GoalProgress? latest;
      for (var attempt = 0; attempt < 40; attempt += 1) {
        await tester.pump(const Duration(milliseconds: 50));
        latest = await fixture.canonical.readProgress(
          profileId: fixture.profileId,
          goalId: fixture.daily.id,
          today: _monday,
        );
        if (latest?.dailyTarget.value?.scaledValue == 3) {
          break;
        }
      }
      expect(
        latest?.dailyTarget.value?.scaledValue,
        3,
        reason: 'a subsequent successful tap still persists',
      );
      expect(find.byKey(const Key('home-daily-target-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
      // Restore INSIDE the body: the binding's foundation-debug-variable
      // invariant is verified before `addTearDown` callbacks run, so a
      // teardown-only restore would leave this test reporting a harness error.
      debugPrint = originalDebugPrint;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'T4/S02b a failed mutation READ is redacted and rolls back the same way',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final fixture = await _prepare(database);
      final baseline = (await fixture.canonical.readProgress(
        profileId: fixture.profileId,
        goalId: fixture.daily.id,
        today: _monday,
      ))!;

      final faults = _FaultGoalRepository(fixture.canonical);
      final logs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) {
          logs.add(message);
        }
      };
      addTearDown(() {
        debugPrint = originalDebugPrint;
      });

      await _pumpHome(
        tester,
        database: database,
        startup: buildTestRepository(database: database),
        faults: faults,
      );
      expect(
        find.byKey(const Key('home-daily-target-quick-control')),
        findsOneWidget,
      );

      faults.arm(progressReads: 1);
      final gate = faults.gateProgress();
      logs.clear();
      await tester.tap(find.byKey(const Key('home-daily-target-plus')));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('home-daily-target-quick-control')),
          matching: find.text('${baseline.dailyActual.display}/3'),
        ),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();

      final persisted = await fixture.canonical.readProgress(
        profileId: fixture.profileId,
        goalId: fixture.daily.id,
        today: _monday,
      );
      expect(persisted?.dailyTarget.value?.scaledValue, 2);
      expect(logs.where((line) => line.contains(_sentinel)), isEmpty);
      expect(logs.where((line) => line.contains(_privateTitle)), isEmpty);
      expect(logs.where((line) => line.contains(_privateNotes)), isEmpty);
      expect(
        logs.where((line) => line == _staticCode),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      // Restore INSIDE the body: the binding's foundation-debug-variable
      // invariant is verified before `addTearDown` callbacks run, so a
      // teardown-only restore would leave this test reporting a harness error.
      debugPrint = originalDebugPrint;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
