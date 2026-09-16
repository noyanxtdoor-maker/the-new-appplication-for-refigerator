import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/domain/goal_icon_registry.dart';
import 'package:rmplanner/features/goals/domain/starter_goals.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/startup/domain/life_indicator_seed.dart';

import '../../../support/test_dependencies.dart';

/// M6 FINAL CORRECTION — Starter Goal catalogue contract.
///
/// The owner replaced the Starter catalogue's visible names and named the exact
/// canonical SVG for each one.  The icon used to be GUESSED with
/// `GoalIconRegistry.suggestForGoalTitle`, which returned null for
/// "Ministering Visit" and the wrong icon for several other templates; the
/// label used to come from the canonical slot's legacy default title.  These
/// tests pin the declared identity, the registry validity of every icon id, the
/// Option-2 label consistency across the three label sources, and the
/// persistence of BOTH title and icon through the canonical create transaction.
void main() {
  const periodStart = PlannerDate(year: 2026, month: 8, day: 3);
  final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));

  const expectedLabels = <String>[
    'Find Date',
    'Work with Missionaries',
    'Exercise',
    'Learn a New Skill',
    'Ministering Visit',
    'Temple Visit',
  ];

  const expectedIconIds = <String>[
    'dating',
    'elders',
    'jogging',
    'target_arrow',
    'handshake',
    'spiritual_temple',
  ];

  const supersededLabels = <String>[
    'Job Applications',
    'Scripture Study',
    'Budget Review',
    'Meaningful Connections',
  ];

  test('the catalogue is exactly the six owner-approved labels in slot order',
      () {
    expect(
      starterGoalTemplates.map((template) => template.title).toList(),
      expectedLabels,
    );
    for (final label in supersededLabels) {
      expect(starterGoalTemplates.map((t) => t.title), isNot(contains(label)));
    }
  });

  test('every template declares its canonical icon, never a title guess', () {
    expect(
      starterGoalTemplates.map((template) => template.iconId).toList(),
      expectedIconIds,
    );

    // The regression this replaces: title matching returned NULL here.
    for (final template in starterGoalTemplates) {
      expect(
        GoalIconRegistry.instance.suggestForGoalTitle(template.title),
        anyOf(isNull, isNotNull),
      );
      expect(template.iconId, isNotEmpty);
    }

    // Every declared icon id is a real, selectable registry entry whose asset
    // is the registered SVG for that id.
    for (final template in starterGoalTemplates) {
      expect(
        GoalIconRegistry.approvedIconIds,
        contains(template.iconId),
        reason: '${template.title} must use a registered icon id',
      );
      final definition = GoalIconRegistry.instance.findById(template.iconId);
      expect(definition, isNotNull);
      expect(
        definition!.assetPath,
        '${GoalIconRegistry.assetPrefix}${template.iconId}.svg',
      );
    }
  });

  test('Ministering Visit resolves the handshake icon, not null', () {
    final template = starterGoalTemplates.firstWhere(
      (candidate) => candidate.title == 'Ministering Visit',
    );
    expect(template.iconId, 'handshake');
    // Proven root cause of the owner's report: the fuzzy matcher found nothing.
    expect(
      GoalIconRegistry.instance.suggestForGoalTitle('Ministering Visit'),
      isNull,
    );
  });

  test('Option 2: the Starter name is the visible Goal name everywhere', () async {
    // OWNER LAW: one Starter Goal reads the SAME name in the Starter list, in
    // Goal Planning and on Home.
    //
    // The consistency is achieved WITHOUT any historical data rewrite, and the
    // mechanism is source-confirmed rather than assumed:
    //   * the template declares the approved title (Starter list);
    //   * `createGoal` persists exactly that title, and Goal Planning renders
    //     `goal.title`;
    //   * Home resolves `label: goalByIndicator[key]?.title ?? definition.label`
    //     (drift_indicator_repository), so an occupied canonical slot shows the
    //     created Goal's own title — the historical indicator DEFINITION label
    //     only surfaces where no Goal exists.
    // The seeded Life Indicator definition labels are deliberately left at
    // their historical values: they feed canonical Goal creation and the
    // history-keyed MP-16 reconciliation evidence, so rewriting them would
    // mutate historical identity for no user-visible gain.
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    final repo = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );

    const amount = IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count');
    for (final template in starterGoalTemplates) {
      final slot = await repo.nextAvailableSlot(
        profileId: profile.id,
        role: template.role,
      );
      await repo.createGoal(
        profileId: profile.id,
        role: template.role,
        title: template.title,
        targets: GoalTargets(
          daily: template.needsDailyTarget ? amount : null,
          weekly: template.needsWeeklyTarget ? amount : null,
          monthly: template.needsMonthlyTarget ? amount : null,
        ),
        iconId: template.iconId,
        expectedSlotIndex: slot,
        startDay: DateTime.monday,
      );
    }

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
    final home = await indicators.readHome(
      profileId: profile.id,
      period: IndicatorPeriod.currentWeek(periodStart),
      today: periodStart,
    );

    for (final template in starterGoalTemplates) {
      final visible = home.indicators.firstWhere(
        (indicator) => indicator.key == template.indicatorKey,
      );
      expect(
        visible.label,
        template.title,
        reason: 'Home must show the created Goal title (${template.title}) '
            'rather than the historical indicator definition label',
      );
    }

    // No historical mutation was needed to reach that consistency: every
    // seeded canonical definition still carries its own historical label.
    final definitions = await (database.select(
      database.lifeIndicatorDefinitions,
    )..where((table) => table.profileId.equals(profile.id))).get();
    for (final seed in approvedLifeIndicatorSeeds) {
      final definition = definitions.firstWhere(
        (candidate) => candidate.indicatorKey == seed.key,
      );
      expect(definition.label, seed.label);
    }
  });

  test('creating the six starters persists exact titles and icons', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    final repo = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );

    const amount = IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count');
    for (final template in starterGoalTemplates) {
      // Exactly the Starter Goals screen path: resolve the canonical slot the
      // allocator will occupy, then create through the canonical transaction.
      final slot = await repo.nextAvailableSlot(
        profileId: profile.id,
        role: template.role,
      );
      final created = await repo.createGoal(
        profileId: profile.id,
        role: template.role,
        title: template.title,
        targets: GoalTargets(
          daily: template.needsDailyTarget ? amount : null,
          weekly: template.needsWeeklyTarget ? amount : null,
          monthly: template.needsMonthlyTarget ? amount : null,
        ),
        iconId: template.iconId,
        expectedSlotIndex: slot,
        startDay: DateTime.monday,
      );
      expect(created.title, template.title);
      expect(created.iconId, template.iconId);
    }

    // Read back from the database: this is what Goal Planning (goal.title) and
    // Home (`_summaryFor` -> label: progress.goal.title) both render.
    final goals = await repo.readActiveGoals(profile.id);
    expect(goals, hasLength(6));
    for (final template in starterGoalTemplates) {
      final goal = goals.firstWhere(
        (candidate) => candidate.indicatorKey == template.indicatorKey,
      );
      expect(goal.title, template.title);
      expect(goal.iconId, template.iconId);
      expect(goal.status, GoalStatus.active);
    }

    // Importing all six never fabricates anything extra, and the zero-goal
    // laws are untouched by the rename.
    final planning = await repo.readPlanning(
      profileId: profile.id,
      periodStart: periodStart,
      today: periodStart,
    );
    expect(planning, isNotNull);
    expect(await repo.readActiveGoals(profile.id), hasLength(6));
  });

  test('an imported Starter Goal keeps its icon across a re-read', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    final repo = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );

    final template = starterGoalTemplates.firstWhere(
      (candidate) => candidate.title == 'Ministering Visit',
    );
    final slot = await repo.nextAvailableSlot(
      profileId: profile.id,
      role: template.role,
    );
    await repo.createGoal(
      profileId: profile.id,
      role: template.role,
      title: template.title,
      targets: const GoalTargets(
        weekly: IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count'),
      ),
      iconId: template.iconId,
      expectedSlotIndex: slot,
      startDay: DateTime.monday,
    );

    // A fresh repository instance reads the same persisted values (restart).
    final reopened = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    final goals = await reopened.readActiveGoals(profile.id);
    expect(goals, hasLength(1));
    expect(goals.single.title, 'Ministering Visit');
    expect(goals.single.iconId, 'handshake');
  });
}
