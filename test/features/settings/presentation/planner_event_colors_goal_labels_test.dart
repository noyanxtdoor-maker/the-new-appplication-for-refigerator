import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// Closed-beta V2 (owner decision AG-2, 2026-09-17) — Settings > Colors
/// goal-linked row labels must represent REALITY.
///
/// Canonical goal-linked rows stay visible even when no Life Goal exists, but
/// the label law is now:
///
///   manual stored name override
///     -> live current Goal title
///     -> `Life Goal <slotIndex>`
///
/// The six slot identities are the existing canonical slot indices, resolved
/// through the explicit canonical slot <-> Event Type mapping rather than by
/// list position. Starter Goal suggestions are NOT current Goals and must
/// never leak into the label. Color ownership never moves: a saved color stays
/// keyed to the same canonical Event Type stable key. This law is scoped to
/// the Colors screen; the general Event Types screen is unchanged.
void main() {
  const seededGoalVocabulary = <String>[
    'Job Application',
    'Scripture Study',
    'Exercise',
    'Budget Review',
    'Ministering Visit',
    'Temple Visit',
  ];
  const today = PlannerDate(year: 2026, month: 9, day: 17);
  const weeklyTarget = IndicatorAmount(scaledValue: 7, scale: 0, unit: 'count');
  const exerciseSlot = 3;

  late AppDatabase database;

  setUp(() {
    database = openMemoryDatabase();
  });

  tearDown(() => database.close());

  DriftGoalRepository goalsFor(AppDatabase db) => DriftGoalRepository(
    database: db,
    clock: FixedClock(DateTime.utc(2026, 9, 17, 12)),
    identifiers: const UuidIdentifierSource(),
  );

  DriftEventTypeRepository typesFor(AppDatabase db) => DriftEventTypeRepository(
    database: db,
    clock: FixedClock(DateTime.utc(2026, 9, 17, 12)),
  );

  /// Onboards a zero-Goal profile (the M6 zero-goal law): every canonical
  /// slot is empty, which is the owner's "Home shows no actual Life Goals"
  /// state.
  Future<String> onboardEmptyProfile() async {
    final profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    await typesFor(database).readEventTypes(profileId: profileId);
    return profileId;
  }

  /// Onboards and gives all six canonical slots a real active Goal.
  Future<String> onboardWithAllSlotsOccupied() async {
    final profileId = await onboardEmptyProfile();
    await seedLegacyCanonicalGoals(database, profileId);
    await typesFor(database).readEventTypes(profileId: profileId);
    return profileId;
  }

  /// Leaves exactly [slotIndex] occupied so the owner's mixed case — one real
  /// Goal plus five empty slots — is reproduced.
  Future<void> keepOnlySlot(String profileId, int slotIndex) async {
    await (database.update(database.goals)..where(
          (table) =>
              table.profileId.equals(profileId) &
              table.status.equals('active') &
              table.activeSlotIndex.equals(slotIndex).not(),
        ))
        .write(const GoalsCompanion(status: Value<String>('archived')));
  }

  Future<Goal> goalInSlot(String profileId, int slotIndex) async {
    return (await goalsFor(database).readActiveGoals(
      profileId,
    )).singleWhere((goal) => goal.activeSlotIndex == slotIndex);
  }

  Future<void> renameSlot(String profileId, int slotIndex, String title) async {
    final goal = await goalInSlot(profileId, slotIndex);
    await goalsFor(database).saveGoal(
      profileId: profileId,
      goalId: goal.id,
      title: title,
      targets: const GoalTargets(weekly: weeklyTarget),
      today: today,
      operationId: 'v2-goal-label-rename-$slotIndex',
    );
  }

  Future<void> openColors(WidgetTester tester) async {
    await tester.pumpWidget(
      TestPrivacyDependencies(database: database).buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: buildTestRepository(database: database),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-account-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-colors')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-colors')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('planner-event-colors-list')), findsOneWidget);
  }

  Finder rowFor(int slotIndex) => find.byKey(
    Key(
      'event-color-row-${CanonicalGoalSlot.bySlot(slotIndex).eventTypeStableKey}',
    ),
  );

  Finder labelIn(int slotIndex, String label) =>
      find.descendant(of: rowFor(slotIndex), matching: find.text(label));

  Finder colorsScrollable() => find.descendant(
    of: find.byKey(const Key('planner-event-colors-list')),
    matching: find.byType(Scrollable),
  );

  /// Brings a row into the lazy ListView's viewport. Only downward scrolling
  /// is attempted (the list's own visual order), so callers must reveal rows
  /// top-to-bottom; a target that is already mounted is left alone.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        120,
        scrollable: colorsScrollable(),
      );
    }
    await tester.pumpAndSettle();
  }

  void usePhonePortrait(WidgetTester tester) {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'with zero live Goals every canonical row shows its neutral placeholder',
    (tester) async {
      usePhonePortrait(tester);
      await onboardEmptyProfile();
      await openColors(tester);

      for (var slotIndex = 1; slotIndex <= 6; slotIndex += 1) {
        final expected = 'Life Goal $slotIndex';
        await reveal(tester, labelIn(slotIndex, expected));
        expect(
          labelIn(slotIndex, expected),
          findsOneWidget,
          reason:
              'slot $slotIndex must present the neutral "$expected" placeholder '
              'when no real Goal occupies it.',
        );
      }
      for (final label in seededGoalVocabulary) {
        expect(
          find.text(label),
          findsNothing,
          reason:
              'seeded goal vocabulary "$label" must never masquerade as a '
              'current Life Goal.',
        );
      }
      // Non-canonical rows keep their accepted presentation, in list order.
      for (final label in <String>['Study & Planning', 'Meal', 'Task']) {
        await reveal(tester, find.text(label));
        expect(
          find.text(label),
          findsOneWidget,
          reason: '"$label" must keep its accepted Colors-row presentation.',
        );
      }
    },
  );

  testWidgets(
    'one real Goal lends its title while the empty slots stay neutral',
    (tester) async {
      usePhonePortrait(tester);
      final profileId = await onboardWithAllSlotsOccupied();
      await keepOnlySlot(profileId, exerciseSlot);
      await renameSlot(profileId, exerciseSlot, 'Learn Cebuano');
      await openColors(tester);

      // Revealed in the list's own visual order: the occupied slot 3 shows the
      // real Goal title, and every empty slot shows its neutral placeholder.
      const expected = <int, String>{
        1: 'Life Goal 1',
        2: 'Life Goal 2',
        3: 'Learn Cebuano',
        4: 'Life Goal 4',
        5: 'Life Goal 5',
        6: 'Life Goal 6',
      };
      for (final entry in expected.entries) {
        await reveal(tester, labelIn(entry.key, entry.value));
        expect(
          labelIn(entry.key, entry.value),
          findsOneWidget,
          reason: 'slot ${entry.key} must show "${entry.value}".',
        );
      }
    },
  );

  testWidgets('a Goal rename updates the row without moving its color', (
    tester,
  ) async {
    usePhonePortrait(tester);
    final profileId = await onboardWithAllSlotsOccupied();
    await keepOnlySlot(profileId, exerciseSlot);
    // Give the row a distinctive saved color the rename must not disturb.
    const custom = EventColorPreference(
      accentArgb: 0xFF6E8FA3,
      surfaceArgb: 0xFF2F3E46,
    );
    await typesFor(database).saveEventColorPreference(
      profileId: profileId,
      eventTypeStableKey: SystemEventTypeKeys.exercise,
      preference: custom,
    );
    await renameSlot(profileId, exerciseSlot, 'Learn Cebuano');
    await openColors(tester);

    await reveal(tester, labelIn(exerciseSlot, 'Learn Cebuano'));
    expect(labelIn(exerciseSlot, 'Learn Cebuano'), findsOneWidget);
    expect(labelIn(exerciseSlot, 'Exercise'), findsNothing);
    // Color ownership is unchanged: the same canonical stable key still owns
    // the saved pair, so a label change never moves a customization.
    final stored = await typesFor(
      database,
    ).readEventColorPreferences(profileId: profileId);
    expect(stored[SystemEventTypeKeys.exercise], custom);
  });

  testWidgets('archiving a Goal returns its row to the neutral placeholder', (
    tester,
  ) async {
    usePhonePortrait(tester);
    final profileId = await onboardWithAllSlotsOccupied();
    await keepOnlySlot(profileId, exerciseSlot);
    final goal = await goalInSlot(profileId, exerciseSlot);
    await goalsFor(database).archiveGoal(profileId: profileId, goalId: goal.id);
    await openColors(tester);

    await reveal(tester, labelIn(exerciseSlot, 'Life Goal $exerciseSlot'));
    expect(
      labelIn(exerciseSlot, 'Life Goal $exerciseSlot'),
      findsOneWidget,
      reason:
          'an archived Goal no longer occupies the slot, so the row must fall '
          'back to the neutral placeholder.',
    );
    expect(labelIn(exerciseSlot, 'Exercise'), findsNothing);
  });

  testWidgets('a manual stored name override wins over the Goal title', (
    tester,
  ) async {
    usePhonePortrait(tester);
    final profileId = await onboardWithAllSlotsOccupied();
    await keepOnlySlot(profileId, exerciseSlot);
    final goal = await goalInSlot(profileId, exerciseSlot);
    final types = typesFor(database);
    await types.saveLiveGoalPresentation(
      profileId: profileId,
      expectedSlotIndex: exerciseSlot,
      expectedGoalId: goal.id,
      expectedEventTypeId: CanonicalGoalSlot.bySlot(exerciseSlot).eventTypeId,
      expectedStableKey: SystemEventTypeKeys.exercise,
      originalValues: const LiveGoalPresentationOriginals(),
      patch: const LiveGoalPresentationPatch(nameOverride: 'Pool training'),
    );
    await openColors(tester);

    await reveal(tester, labelIn(exerciseSlot, 'Pool training'));
    expect(labelIn(exerciseSlot, 'Pool training'), findsOneWidget);
    expect(labelIn(exerciseSlot, 'Exercise'), findsNothing);
    // The raw type is never renamed.
    final raw = await types.readEventType(
      profileId: profileId,
      eventTypeId: CanonicalGoalSlot.bySlot(exerciseSlot).eventTypeId,
    );
    expect(raw!.label, 'Exercise');
  });

  testWidgets('a very long Goal title stays bounded at text scale 1.3', (
    tester,
  ) async {
    usePhonePortrait(tester);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;

    final profileId = await onboardWithAllSlotsOccupied();
    await keepOnlySlot(profileId, exerciseSlot);
    await renameSlot(
      profileId,
      exerciseSlot,
      'Learn Cebuano well enough to hold a long Sunday dinner '
      'conversation with the whole extended family',
    );
    await openColors(tester);
    await reveal(tester, rowFor(exerciseSlot));

    // The canonical row keeps its accepted geometry: the preview label is a
    // single ellipsized line, so a long title never wraps or overflows.
    expect(rowFor(exerciseSlot), findsOneWidget);
    expect(
      tester.getSize(rowFor(exerciseSlot)).height,
      44,
      reason: 'the goal-linked row must keep its 44 dp identity geometry.',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'text scale 1.3 must not overflow the Event identity preview.',
    );
  });

  // DOCUMENTED OUT-OF-SCOPE FINDING (closed-beta V2, 2026-09-17).
  //
  // No widget test asserts the Colors surface at text scale 1.5, because it
  // measures a REAL pre-existing defect that this ticket may not fix:
  // `PlannerEventColorPreview` lays out two fixed-size text lines inside its
  // own hard-coded 40 dp box (34 dp of content height after 3 dp padding), so
  // at 1.5 the block wants 37.5 dp and Flutter reports
  //
  //   RenderFlex overflowed by 4.0 pixels on the bottom
  //   planner_event_color_preview.dart:61 (Column)
  //   constraints: BoxConstraints(w=122.0, h=34.0)
  //
  // The overflow is title-length independent: it is pure two-line geometry.
  // The widget is on this ticket's NO-TOUCH list, and the parent cannot fix it
  // because the 40 dp height is hard-coded inside the preview itself, so the
  // finding is reported for an explicit owner decision instead. A test that
  // drained the overflow would hide any future, genuine layout regression, so
  // 1.3 is asserted in full and 1.5 is documented here.
}
