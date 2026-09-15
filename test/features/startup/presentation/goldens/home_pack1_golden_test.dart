import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../../support/test_dependencies.dart';

const _monday = PlannerDate(year: 2026, month: 8, day: 3);
const _target = IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count');

typedef _ArrangeGolden =
    Future<void> Function(DriftGoalRepository repository, String profileId);

void main() {
  _registerHomeGolden(name: '01_default_canonical_home');
  _registerHomeGolden(
    name: '02_six_replacement_goals',
    arrange: _replaceAllGoals,
  );
  _registerHomeGolden(
    name: '03_mixed_default_and_replacement_goals',
    arrange: _mixedGoals,
  );
  _registerHomeGolden(
    name: '04_all_empty_start_planning',
    arrange: (repository, profileId) => _archiveWhere(
      repository,
      profileId,
      (_) => true,
      operationPrefix: 'golden-empty',
    ),
  );
  _registerHomeGolden(
    name: '05_daily_only',
    arrange: (repository, profileId) => _archiveWhere(
      repository,
      profileId,
      (goal) => goal.role != GoalRole.dailyWeekly,
      operationPrefix: 'golden-daily-only',
    ),
  );
  _registerHomeGolden(
    name: '06_weekly_only',
    arrange: (repository, profileId) => _archiveWhere(
      repository,
      profileId,
      (goal) => goal.role != GoalRole.weekly,
      operationPrefix: 'golden-weekly-only',
    ),
  );
  _registerHomeGolden(
    name: '07_monthly_only',
    arrange: (repository, profileId) => _archiveWhere(
      repository,
      profileId,
      (goal) => goal.role != GoalRole.weeklyMonthly,
      operationPrefix: 'golden-monthly-only',
    ),
  );
  _registerHomeGolden(
    name: '08_august_render_time_month_label',
    today: const PlannerDate(year: 2026, month: 8, day: 31),
  );
  _registerHomeGolden(
    name: '09_september_render_time_month_label',
    today: const PlannerDate(year: 2026, month: 9, day: 1),
  );
  _registerHomeGolden(
    name: '10_long_titles_360_scale_1_30',
    viewport: const Size(360, 800),
    textScale: 1.3,
    arrange: _replaceAllLongGoals,
  );
  _registerHomeGolden(
    name: '11_responsive_411',
    viewport: const Size(411, 891),
  );
  _registerHomeGolden(name: '12_responsive_393_scale_1_15', textScale: 1.15);
  _registerHomeGolden(
    name: '13_daily_target_dialog',
    captureKey: const Key('home-daily-target-quick-control'),
  );
  _registerHomeGolden(
    name: '14_goal_limit_dialog',
    beforeCapture: (tester) async {
      await tester.ensureVisible(
        find.byKey(const Key('weekly-targets-button')),
      );
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-plan-create-goal')));
      await tester.pumpAndSettle();
    },
    captureType: AlertDialog,
  );
  _registerHomeGolden(
    name: '15_management_mode',
    beforeCapture: (tester) async {
      await tester.ensureVisible(
        find.byKey(const Key('weekly-targets-button')),
      );
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-plan-create-goal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-plan-goal-limit-manage')));
      await tester.pumpAndSettle();
    },
    captureKey: const Key('weekly-plan-list'),
  );
  _registerHomeGolden(
    name: '16_direct_archive_confirmation',
    beforeCapture: (tester) async {
      await tester.ensureVisible(
        find.byKey(const Key('weekly-targets-button')),
      );
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-plan-create-goal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('weekly-plan-goal-limit-manage')));
      await tester.pumpAndSettle();
      final archive = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return widget is IconButton &&
            key is ValueKey &&
            key.value.toString().startsWith('weekly-plan-goal-direct-archive-');
      });
      await tester.tap(archive.first);
      await tester.pumpAndSettle();
    },
    captureType: AlertDialog,
  );
  _registerHomeGolden(
    name: '17_weekly_planning_neutral_secondary_surface',
    beforeCapture: (tester) async {
      await tester.ensureVisible(
        find.byKey(const Key('weekly-targets-button')),
      );
      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await tester.pumpAndSettle();
    },
    captureKey: const Key('weekly-plan-list'),
  );
  // R5 (owner 2026-08-16): the Active Pathways Home section is removed, so
  // the Life Goals -> Pathways major separator no longer exists; golden 18
  // was retired with it.
  _registerHomeGolden(
    name: '19_daily_target_maximum',
    arrange: _setDailyTargetMaximum,
    captureKey: const Key('home-daily-target-quick-control'),
  );
  _registerHomeGolden(
    name: '20_home_custom_long_titles_411',
    viewport: const Size(411, 891),
    arrange: _replaceAllLongGoals,
  );
}

void _registerHomeGolden({
  required String name,
  Size viewport = const Size(393, 874),
  double textScale = 1,
  PlannerDate today = _monday,
  _ArrangeGolden? arrange,
  Future<void> Function(WidgetTester tester)? beforeCapture,
  Key? captureKey,
  Type? captureType,
}) {
  testWidgets('Pack 1 golden: $name', (tester) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    // M6 zero-goal law: these goldens describe an EXISTING (pre-M6) user; the
    // per-scenario `arrange` callback then adjusts goals from that baseline.
    await seedLegacyCanonicalGoals(database, profile.id);
    // Establish the current period so the golden captures the established
    // Home (cards + Goal Planning pill), matching the pre-pack Home layout.
    await establishWeeklyPlan(
      database: database,
      profileId: profile.id,
      date: today,
    );
    final repository = DriftGoalRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 8, 4, 12)),
      identifiers: const UuidIdentifierSource(),
    );
    if (arrange != null) {
      await arrange(repository, profile.id);
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
        plannerDateSource: FixedPlannerDateSource(today),
      ),
    );
    await tester.pumpAndSettle();
    if (beforeCapture != null) {
      await beforeCapture(tester);
    }
    expect(tester.takeException(), isNull);
    final capture = captureKey == null
        ? captureType == null
              ? find.byKey(const Key('home-indicator-list'))
              : find.byType(captureType)
        : find.byKey(captureKey);
    expect(capture, findsOneWidget);
    await expectLater(
      capture,
      matchesGoldenFile('goldens/home_pack1/$name.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

Future<void> _archiveWhere(
  DriftGoalRepository repository,
  String profileId,
  bool Function(Goal goal) predicate, {
  required String operationPrefix,
}) async {
  final goals = await repository.readActiveGoals(profileId);
  for (var index = 0; index < goals.length; index += 1) {
    final goal = goals[index];
    if (predicate(goal)) {
      await repository.archiveGoal(
        profileId: profileId,
        goalId: goal.id,
        operationId: '$operationPrefix-$index',
      );
    }
  }
}

Future<void> _replaceAllGoals(
  DriftGoalRepository repository,
  String profileId,
) async {
  await _archiveWhere(
    repository,
    profileId,
    (_) => true,
    operationPrefix: 'golden-replace-archive',
  );
  await repository.createGoal(
    profileId: profileId,
    role: GoalRole.dailyWeekly,
    title: 'Daily Applications',
    iconId: 'work_briefcase',
    targets: const GoalTargets(daily: _target, weekly: _target),
    operationId: 'golden-replace-daily',
  );
  for (var index = 1; index <= 4; index += 1) {
    await repository.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Weekly Replacement $index',
      iconId: index.isOdd ? 'learning_open_book' : 'social_two_people',
      targets: const GoalTargets(weekly: _target),
      operationId: 'golden-replace-weekly-$index',
    );
  }
  await repository.createGoal(
    profileId: profileId,
    role: GoalRole.weeklyMonthly,
    title: 'Monthly Temple Visit',
    iconId: 'spiritual_temple',
    targets: const GoalTargets(weekly: _target, monthly: _target),
    operationId: 'golden-replace-monthly',
  );
}

Future<void> _mixedGoals(
  DriftGoalRepository repository,
  String profileId,
) async {
  final goals = await repository.readActiveGoals(profileId);
  final archived = goals
      .where(
        (goal) => goal.title == 'Scripture Study' || goal.title == 'Exercise',
      )
      .toList(growable: false);
  for (var index = 0; index < archived.length; index += 1) {
    await repository.archiveGoal(
      profileId: profileId,
      goalId: archived[index].id,
      operationId: 'golden-mixed-archive-$index',
    );
  }
  await repository.createGoal(
    profileId: profileId,
    role: GoalRole.weekly,
    title: 'Replacement Study',
    iconId: 'learning_open_book',
    targets: const GoalTargets(weekly: _target),
    operationId: 'golden-mixed-study',
  );
  await repository.createGoal(
    profileId: profileId,
    role: GoalRole.weekly,
    title: 'Replacement Exercise',
    iconId: 'health_dumbbell',
    targets: const GoalTargets(weekly: _target),
    operationId: 'golden-mixed-exercise',
  );
}

Future<void> _replaceAllLongGoals(
  DriftGoalRepository repository,
  String profileId,
) async {
  await _archiveWhere(
    repository,
    profileId,
    (_) => true,
    operationPrefix: 'golden-long-archive',
  );
  await repository.createGoal(
    profileId: profileId,
    role: GoalRole.dailyWeekly,
    title: 'A very long daily replacement goal title',
    iconId: 'work_briefcase',
    targets: const GoalTargets(daily: _target, weekly: _target),
    operationId: 'golden-long-daily',
  );
  for (var index = 1; index <= 4; index += 1) {
    await repository.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'A very long weekly replacement goal title $index',
      iconId: 'learning_open_book',
      targets: const GoalTargets(weekly: _target),
      operationId: 'golden-long-weekly-$index',
    );
  }
  await repository.createGoal(
    profileId: profileId,
    role: GoalRole.weeklyMonthly,
    title: 'A very long monthly replacement goal title',
    iconId: 'spiritual_temple',
    targets: const GoalTargets(weekly: _target, monthly: _target),
    operationId: 'golden-long-monthly',
  );
}

Future<void> _setDailyTargetMaximum(
  DriftGoalRepository repository,
  String profileId,
) async {
  final daily = (await repository.readActiveGoals(
    profileId,
  )).firstWhere((goal) => goal.role == GoalRole.dailyWeekly);
  const maximum = IndicatorAmount(scaledValue: 999, scale: 0, unit: 'count');
  await repository.saveGoal(
    profileId: profileId,
    goalId: daily.id,
    title: daily.title,
    iconId: daily.iconId,
    targets: const GoalTargets(daily: maximum, weekly: maximum),
    operationId: 'golden-daily-maximum',
  );
}
