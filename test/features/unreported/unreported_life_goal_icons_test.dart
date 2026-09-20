// Owner law (2026-09-20) — every Unreported → Life Goals row shows its OWN
// Life Goal's chosen icon.
//
// OWNER-REPORTED DEFECT: all Life Goals rows rendered the SAME generic Life
// Goal glyph.  The classifier puts an Event created under one of the six fixed
// Goal-linked Event Types into Life Goals, and such an Event carries NO manual
// `goalId` — yet its Event Type IS the canonical alias for a Goal slot, so the
// slot's live occupant is the linked Goal and its own icon must be drawn.
//
// The resolution is proven against the REAL canonical slot bindings read from a
// real database, so this cannot pass by agreeing with a hand-written stub.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/data/live_goal_event_type_bindings.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

import '../../support/test_dependencies.dart';

void main() {
  final slotA = CanonicalGoalSlot.bySlot(1);
  final slotB = CanonicalGoalSlot.bySlot(3);

  group('the canonical Life Goal resolution', () {
    late AppDatabase database;
    late String profileId;

    setUp(() async {
      database = openMemoryDatabase();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
    });

    tearDown(() async {
      await database.close();
    });

    Future<String> insertGoal({
      required CanonicalGoalSlot slot,
      required String iconId,
      required String title,
      String id = '',
    }) async {
      final goalId = id.isEmpty ? 'goal-${slot.slotIndex}' : id;
      await database
          .into(database.goals)
          .insert(
            GoalsCompanion.insert(
              id: goalId,
              profileId: profileId,
              role: slot.role.storageName,
              title: title,
              status: 'active',
              activeSlotIndex: Value<int?>(slot.slotIndex),
              indicatorKey: Value<String?>(slot.indicatorKey),
              assignedEventTypeStableKey: Value<String?>(
                slot.eventTypeStableKey,
              ),
              iconId: Value<String?>(iconId),
              createdAtUtc: DateTime.utc(2026, 9, 1, 9),
              updatedAtUtc: DateTime.utc(2026, 9, 1, 9),
              archivedAtUtc: const Value<DateTime?>(null),
            ),
          );
      return goalId;
    }

    Future<Map<int, String>> liveSlotOccupants() async {
      final bindings = await readLiveGoalEventTypeBindings(database, profileId);
      return <int, String>{
        for (final binding in bindings.values)
          binding.slotIndex: binding.goalId,
      };
    }

    test('GOAL-ICON-1/2/3: two Goal-linked Event Types resolve to their OWN '
        'Goals, which are different Goals with different icons', () async {
      final goalA = await insertGoal(
        slot: slotA,
        iconId: 'find_job',
        title: 'Goal A',
      );
      final goalB = await insertGoal(
        slot: slotB,
        iconId: 'work_briefcase',
        title: 'Goal B',
      );
      final occupants = await liveSlotOccupants();

      // GOAL-ICON-5: automatic linkage — the fixed Goal-linked Event Type IS
      // the Goal, even though the Event carries no manual link.
      final resolvedA = UnreportedClassification.linkedGoalIdFor(
        manualGoalId: null,
        activityTypeStableKey: slotA.eventTypeStableKey,
        goalIdBySlotIndex: occupants,
      );
      final resolvedB = UnreportedClassification.linkedGoalIdFor(
        manualGoalId: null,
        activityTypeStableKey: slotB.eventTypeStableKey,
        goalIdBySlotIndex: occupants,
      );
      expect(resolvedA, goalA);
      expect(resolvedB, goalB);
      expect(
        resolvedA,
        isNot(resolvedB),
        reason: 'two Goal-linked Event Types must not share one Goal.',
      );

      // The two Goals really do carry different chosen icons, so a row that
      // resolves to a different Goal necessarily draws a different icon.
      final icons = await (database.select(
        database.goals,
      )..where((table) => table.profileId.equals(profileId))).get();
      expect(icons.map((row) => row.iconId).toSet(), <String>{
        'find_job',
        'work_briefcase',
      });
    });

    test('GOAL-ICON-4: a manual Life Goal link wins outright', () async {
      final goalA = await insertGoal(
        slot: slotA,
        iconId: 'find_job',
        title: 'Goal A',
      );
      await insertGoal(slot: slotB, iconId: 'work_briefcase', title: 'Goal B');
      final occupants = await liveSlotOccupants();

      // A manual link to A on an Event whose type is B's slot still belongs
      // to A: the manual link is the stronger canonical statement.
      expect(
        UnreportedClassification.linkedGoalIdFor(
          manualGoalId: goalA,
          activityTypeStableKey: slotB.eventTypeStableKey,
          goalIdBySlotIndex: occupants,
        ),
        goalA,
      );
    });

    test('GOAL-ICON-7: an unresolvable Goal falls back and never borrows '
        'another Goal', () async {
      await insertGoal(slot: slotA, iconId: 'find_job', title: 'Goal A');
      final occupants = await liveSlotOccupants();

      // An empty slot: the Goal was archived, so nothing occupies it.
      expect(
        UnreportedClassification.linkedGoalIdFor(
          manualGoalId: null,
          activityTypeStableKey: slotB.eventTypeStableKey,
          goalIdBySlotIndex: occupants,
        ),
        isNull,
      );
      // A legacy per-Goal type key and an unknown key resolve to nothing.
      expect(
        UnreportedClassification.linkedGoalIdFor(
          manualGoalId: null,
          activityTypeStableKey: 'goal:legacy-goal',
          goalIdBySlotIndex: occupants,
        ),
        isNull,
      );
      expect(
        UnreportedClassification.linkedGoalIdFor(
          manualGoalId: null,
          activityTypeStableKey: null,
          goalIdBySlotIndex: occupants,
        ),
        isNull,
      );
    });

    test(
      'GOAL-ICON-6: the resolution follows a Goal icon change live',
      () async {
        final goalA = await insertGoal(
          slot: slotA,
          iconId: 'find_job',
          title: 'Goal A',
        );

        Future<String?> iconIdForGoalA() async {
          final row =
              await (database.select(database.goals)
                    ..where((table) => table.id.equals(goalA))
                    ..limit(1))
                  .getSingle();
          return row.iconId;
        }

        expect(await iconIdForGoalA(), 'find_job');
        // Re-iconing the Goal does not need a migration and is never copied: the
        // row keeps resolving the Goal and reads its CURRENT icon.
        await (database.update(
          database.goals,
        )..where((table) => table.id.equals(goalA))).write(
          const GoalsCompanion(iconId: Value<String?>('work_briefcase')),
        );
        expect(await iconIdForGoalA(), 'work_briefcase');
        expect(
          UnreportedClassification.linkedGoalIdFor(
            manualGoalId: null,
            activityTypeStableKey: slotA.eventTypeStableKey,
            goalIdBySlotIndex: await liveSlotOccupants(),
          ),
          goalA,
        );
      },
    );
  });

  // ---------------------------------------------------------------------
  // The rendered surface: two rows, two Goals, two DIFFERENT icons.
  // ---------------------------------------------------------------------
  testWidgets('GOAL-ICON-3: two Life Goals rows render two different icons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const goalA = 'goal-a';
    const goalB = 'goal-b';
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startup.completeOnboarding();

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        extraOverrides: <Override>[
          unreportedEntriesProvider.overrideWith(
            (ref) async => <UnreportedEntry>[
              _entry(
                id: 'occurrence-a',
                tab: UnreportedTab.lifeGoals,
                goalId: goalA,
              ),
              _entry(
                id: 'occurrence-b',
                tab: UnreportedTab.lifeGoals,
                goalId: goalB,
              ),
            ],
          ),
          goalByIdProvider.overrideWith(
            (ref, String id) async => switch (id) {
              goalA => _goal(goalA, 'Goal A', 'find_job'),
              goalB => _goal(goalB, 'Goal B', 'work_briefcase'),
              _ => null,
            },
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-unreported')));
    await tester.pumpAndSettle();

    final markerA = find.byKey(
      const Key('unreported-goal-marker-occurrence-a'),
    );
    final markerB = find.byKey(
      const Key('unreported-goal-marker-occurrence-b'),
    );
    expect(markerA, findsOneWidget);
    expect(markerB, findsOneWidget);

    final iconA = tester.widget<GoalIcon>(markerA).iconId;
    final iconB = tester.widget<GoalIcon>(markerB).iconId;
    expect(iconA, 'find_job');
    expect(iconB, 'work_briefcase');
    expect(
      iconA,
      isNot(iconB),
      reason: 'two Life Goals must not render the same generic icon.',
    );
    expect(tester.takeException(), isNull);
  });
}

UnreportedEntry _entry({
  required String id,
  required UnreportedTab tab,
  String? goalId,
}) {
  return UnreportedEntry(
    tab: tab,
    event: _awaiting(id),
    goalId: goalId,
    contacts: const <UnreportedContactRef>[],
  );
}

AwaitingReportEvent _awaiting(String id) {
  final endUtc = DateTime.utc(2026, 9, 19, 10);
  return AwaitingReportEvent(
    item: PlannerCalendarItem(
      id: id,
      eventId: 'event-$id',
      originalDate: PlannerDate.fromDateTime(endUtc),
      title: 'Unreported $id',
      date: PlannerDate.fromDateTime(endUtc),
      timing: PlannerEventTiming.timed,
      state: PlannerEventState.scheduled,
      requiresReport: true,
      hasOutcomeReport: false,
      startUtc: endUtc.subtract(const Duration(hours: 1)),
      endUtc: endUtc,
    ),
    goalId: null,
    activityTypeStableKey: null,
  );
}

Goal _goal(String id, String title, String iconId) {
  final created = DateTime.utc(2026, 9, 1, 9);
  return Goal(
    id: id,
    profileId: 'profile',
    role: GoalRole.dailyWeekly,
    activeSlotIndex: 1,
    assignedEventTypeStableKey: 'jobApplication',
    title: title,
    status: GoalStatus.active,
    iconId: iconId,
    indicatorKey: 'job_applications',
    createdAtUtc: created,
    updatedAtUtc: created,
    archivedAtUtc: null,
    deletedAtUtc: null,
  );
}
