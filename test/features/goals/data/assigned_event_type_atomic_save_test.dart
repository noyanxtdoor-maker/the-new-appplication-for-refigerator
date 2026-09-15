import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/assigned_event_type_draft.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/planner_presentation_document_store.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';

import '../../../support/test_dependencies.dart';

/// Contract: Assigned Event Type draft Save atomicity (Prompt-P46).
///
/// The parent Goal Save commits the Goal row/targets/activity/outbox AND the
/// presentation merge (explicit name override + changed slot color) in ONE
/// AppDatabase transaction: any injected failure rolls the whole save back,
/// and a parent Cancel writes nothing at all.
void main() {
  const amount = IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count');
  late AppDatabase database;
  late DriftGoalRepository goals;
  late DriftEventTypeRepository types;
  late String profileId;
  final clock = FixedClock(DateTime.utc(2026, 9, 9, 12));

  setUp(() async {
    database = openMemoryDatabase();
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    await seedLegacyCanonicalGoals(database, profileId);
    goals = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    types = DriftEventTypeRepository(database: database, clock: clock);
    // Bootstrap occupies every slot. The allocator hands out the FIRST free
    // weekly slot (2..5), so archiving the slot-3 (Exercise) bootstrap Goal
    // and filling slot 2 makes every test below deterministically allocate
    // slot 3. Rows are marked archived, never deleted — raw history keeps
    // them exactly like production archives.
    await (database.update(database.goals)
            ..where(
              (table) =>
                  table.status.equals('active') &
                  table.activeSlotIndex.equals(3),
            ))
        .write(const GoalsCompanion(status: Value<String>('archived')));
    await types.readEventTypes(profileId: profileId);
  });

  tearDown(() => database.close());

  AssignedEventTypeDraft draft({
    int slotIndex = 3,
    AssignedEventTypeNameMode currentNameMode = AssignedEventTypeNameMode.auto,
    String? currentNameOverride,
    bool nameDirty = false,
    EventColorPreference? changedColor,
    bool colorDirty = false,
    String? originalNameOverride,
  }) {
    final slot = CanonicalGoalSlot.bySlot(slotIndex);
    return AssignedEventTypeDraft(
      expectedSlotIndex: slot.slotIndex,
      expectedEventTypeId: slot.eventTypeId,
      expectedStableKey: slot.eventTypeStableKey,
      originalNameMode: AssignedEventTypeNameMode.auto,
      originalNameOverride: originalNameOverride,
      currentNameMode: currentNameMode,
      currentNameOverride: currentNameOverride,
      nameDirty: nameDirty,
      originalColor: PlannerEventColorDefaults.exercise,
      changedColor: changedColor,
      colorDirty: colorDirty,
    );
  }

  Future<Map<String, GoalEventTypeNameOverride>> storedOverrides() async {
    final row = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    return EventColorPreferenceCodec.decodeDocument(
      row?.eventColorPreferencesJson,
    ).goalEventTypeNames;
  }

  Future<PlannerColorPreferencesDocument> storedDocument() async {
    final row = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    return EventColorPreferenceCodec.decodeDocument(
      row?.eventColorPreferencesJson,
    );
  }

  test(
    'Create commits Goal + MANUAL override + slot color in one transaction',
    () async {
      const pair = EventColorPreference(
        accentArgb: 0xFF7986CB,
        surfaceArgb: 0xFF3E4356,
      );
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-create-atomic-1',
        assignedEventTypeDraft: draft(
          currentNameMode: AssignedEventTypeNameMode.manual,
          currentNameOverride: 'Pool training',
          nameDirty: true,
          changedColor: pair,
          colorDirty: true,
        ),
      );

      expect(goal.title, 'Swim');
      expect(goal.activeSlotIndex, 3);
      final document = await storedDocument();
      expect(document.goalEventTypeNames[goal.id]?.name, 'Pool training');
      expect(document.goalEventTypeNames[goal.id]?.eventTypeStableKey,
          'exercise');
      expect(document.events['exercise'], pair);
    },
  );

  test('parent Cancel writes nothing: no Goal, no override, no color',
      () async {
    // Cancel is modeled by NOT calling save with the draft — verify a draft
    // with no changes (what Cancel leaves behind) triggers zero writes even
    // when a save DOES happen for an unrelated Goal.
    final goal = await goals.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Unchanged Draft',
      targets: const GoalTargets(weekly: amount),
      expectedSlotIndex: 3,
      operationId: 'p46-create-cancel-1',
      assignedEventTypeDraft: draft(),
    );
    expect(goal.title, 'Unchanged Draft');
    final document = await storedDocument();
    expect(document.goalEventTypeNames, isEmpty);
    expect(document.events, isEmpty);
    expect((await storedOverrides()), isEmpty);
  });

  test(
    'a draft with no explicit change writes nothing but still creates the Goal',
    () async {
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'No Draft Changes',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-create-noop-1',
        assignedEventTypeDraft: draft(),
      );
      expect(goal.title, 'No Draft Changes');
      final document = await storedDocument();
      expect(document.goalEventTypeNames, isEmpty);
      expect(document.events, isEmpty);
    },
  );

  test('injected merge failure rolls back the whole Goal save', () async {
    // Inject a failure INSIDE the presentation merge (after the Goal row,
    // targets, activity, and outbox writes) by making the profile row's
    // preferences JSON unparseable: the store fails closed, the transaction
    // throws, and every Goal write must roll back.
    final existingPreference = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    if (existingPreference == null) {
      await database.into(database.plannerPreferences).insert(
            PlannerPreferencesCompanion.insert(
              profileId: profileId,
              eventColorPreferencesJson: const Value<String?>('{not json'),
              updatedAtUtc: clock.nowUtc(),
            ),
          );
    } else {
      await (database.update(database.plannerPreferences)
              ..where((table) => table.profileId.equals(profileId)))
          .write(const PlannerPreferencesCompanion(
        eventColorPreferencesJson: Value<String?>('{not json'),
      ));
    }

    await expectLater(
      goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Doomed',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-create-atomic-2',
        assignedEventTypeDraft: draft(
          currentNameMode: AssignedEventTypeNameMode.manual,
          currentNameOverride: 'Pool training',
          nameDirty: true,
        ),
      ),
      throwsA(isA<PresentationMutationRejectedException>()),
    );

    // The Goal row itself must NOT exist.
    final rows = await (database.select(database.goals)..where(
          (table) =>
              table.profileId.equals(profileId) &
              table.title.equals('Doomed'),
        )).get();
    expect(rows, isEmpty);
    // The malformed owner content is untouched.
    final preferenceRow = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingle();
    expect(preferenceRow.eventColorPreferencesJson, '{not json');
  });

  test('injected color failure rolls back the whole Goal save', () async {
    // Pre-store a saved color for another active type that collides with the
    // proposed slot color: the opaque-RGB uniqueness law throws inside the
    // merge, after the Goal row was written.
    const colliding = EventColorPreference(
      accentArgb: 0xFF7986CB,
      surfaceArgb: 0xFF3E4356,
    );
    final store = PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    );
    await store.update(profileId, (current) async {
      return PlannerColorPreferencesDocument(
        events: <String, EventColorPreference>{'budget_review': colliding},
        groups: current.document.groups,
      );
    });

    await expectLater(
      goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Collides',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-create-atomic-3',
        assignedEventTypeDraft: draft(
          changedColor: colliding,
          colorDirty: true,
        ),
      ),
      throwsA(isA<GoalValidationException>()),
    );

    final rows = await (database.select(database.goals)..where(
          (table) =>
              table.profileId.equals(profileId) &
              table.title.equals('Collides'),
        )).get();
    expect(rows, isEmpty);
  });

  test('Edit updates override and slot color and persists across a re-read',
      () async {
    const pair = EventColorPreference(
      accentArgb: 0xFF7986CB,
      surfaceArgb: 0xFF3E4356,
    );
    final goal = await goals.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Swim',
      targets: const GoalTargets(weekly: amount),
      expectedSlotIndex: 3,
      operationId: 'p46-edit-base-1',
    );

    final updated = await goals.saveGoal(
      profileId: profileId,
      goalId: goal.id,
      title: 'Swim',
      targets: const GoalTargets(weekly: amount),
      operationId: 'p46-edit-1',
      assignedEventTypeDraft: draft(
        currentNameMode: AssignedEventTypeNameMode.manual,
        currentNameOverride: 'Pool training',
        nameDirty: true,
        changedColor: pair,
        colorDirty: true,
      ),
    );
    expect(updated.title, 'Swim');

    final document = await storedDocument();
    expect(document.goalEventTypeNames[goal.id]?.name, 'Pool training');
    expect(document.events['exercise'], pair);

    // Re-read: a later rename of the Goal title does NOT change the manual
    // presentation name (manual survives restart/title changes).
    final renamed = await goals.saveGoal(
      profileId: profileId,
      goalId: goal.id,
      title: 'Completely Different',
      targets: const GoalTargets(weekly: amount),
      operationId: 'p46-edit-2',
    );
    expect(renamed.title, 'Completely Different');
    final afterRename = await storedDocument();
    expect(afterRename.goalEventTypeNames[goal.id]?.name, 'Pool training');
  });

  test('Edit dirty guard: stale expectedGoalUpdatedAtUtc rejects the merge',
      () async {
    final goal = await goals.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Swim',
      targets: const GoalTargets(weekly: amount),
      expectedSlotIndex: 3,
      operationId: 'p46-edit-base-2',
    );

    // Emulate another editor saving the Goal between draft load and save:
    // the draft's expectedGoalUpdatedAtUtc goes stale.
    final staleDraft = AssignedEventTypeDraft(
      expectedSlotIndex: 3,
      expectedEventTypeId: CanonicalGoalSlot.bySlot(3).eventTypeId,
      expectedStableKey: CanonicalGoalSlot.bySlot(3).eventTypeStableKey,
      originalNameMode: AssignedEventTypeNameMode.auto,
      originalNameOverride: null,
      currentNameMode: AssignedEventTypeNameMode.manual,
      currentNameOverride: 'Pool training',
      nameDirty: true,
      originalColor: PlannerEventColorDefaults.exercise,
      changedColor: null,
      colorDirty: false,
      expectedGoalUpdatedAtUtc:
          goal.updatedAtUtc.subtract(const Duration(minutes: 1)),
    );

    await expectLater(
      goals.saveGoal(
        profileId: profileId,
        goalId: goal.id,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        operationId: 'p46-edit-stale-1',
        assignedEventTypeDraft: staleDraft,
      ),
      throwsA(isA<GoalValidationException>()),
    );
    final document = await storedDocument();
    expect(document.goalEventTypeNames, isEmpty);
  });

  test(
    'Edit concurrency: a concurrently written override is never overwritten',
    () async {
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-edit-base-3',
      );

      // Concurrent writer: another path stores an override for this Goal.
      final store = PlannerPresentationDocumentStore(
        database: database,
        clock: clock,
      );
      await store.update(profileId, (current) async {
        return PlannerColorPreferencesDocument(
          events: current.document.events,
          groups: current.document.groups,
          goalEventTypeNames: <String, GoalEventTypeNameOverride>{
            goal.id: const GoalEventTypeNameOverride(
              eventTypeStableKey: 'exercise',
              name: 'Concurrent writer',
            ),
          },
        );
      });

      // Our editor observed AUTO and now saves a manual name: rejected,
      // because the stored metadata no longer matches the observed original.
      await expectLater(
        goals.saveGoal(
          profileId: profileId,
          goalId: goal.id,
          title: 'Swim',
          targets: const GoalTargets(weekly: amount),
          operationId: 'p46-edit-concurrent-1',
          assignedEventTypeDraft: AssignedEventTypeDraft(
            expectedSlotIndex: 3,
            expectedEventTypeId: CanonicalGoalSlot.bySlot(3).eventTypeId,
            expectedStableKey: CanonicalGoalSlot.bySlot(3).eventTypeStableKey,
            originalNameMode: AssignedEventTypeNameMode.auto,
            currentNameMode: AssignedEventTypeNameMode.manual,
            currentNameOverride: 'Pool training',
            nameDirty: true,
            originalColor: PlannerEventColorDefaults.exercise,
            changedColor: null,
            colorDirty: false,
          ),
        ),
        throwsA(isA<GoalValidationException>()),
      );
      final document = await storedDocument();
      expect(document.goalEventTypeNames[goal.id]?.name, 'Concurrent writer');
    },
  );

  test(
    'archive/replacement race: archived occupant rejects the presentation merge',
    () async {
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-edit-base-4',
      );
      // Archive between draft and save.
      await goals.archiveGoal(
        profileId: profileId,
        goalId: goal.id,
        operationId: 'p46-archive-1',
      );
      await expectLater(
        goals.saveGoal(
          profileId: profileId,
          goalId: goal.id,
          title: 'Swim',
          targets: const GoalTargets(weekly: amount),
          operationId: 'p46-edit-archived-1',
          assignedEventTypeDraft: draft(
            currentNameMode: AssignedEventTypeNameMode.manual,
            currentNameOverride: 'Pool training',
            nameDirty: true,
          ),
        ),
        throwsA(isA<GoalValidationException>()),
      );
      final document = await storedDocument();
      expect(document.goalEventTypeNames[goal.id], isNull);
    },
  );

  test('slot color carryover: new Goal in the same slot keeps slot color',
      () async {
    const slotPair = EventColorPreference(
      accentArgb: 0xFF7986CB,
      surfaceArgb: 0xFF3E4356,
    );
    final first = await goals.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Swim',
      targets: const GoalTargets(weekly: amount),
      expectedSlotIndex: 3,
      operationId: 'p46-slot-carry-1',
      assignedEventTypeDraft: draft(
        changedColor: slotPair,
        colorDirty: true,
      ),
    );
    await goals.archiveGoal(
      profileId: profileId,
      goalId: first.id,
      operationId: 'p46-slot-carry-2',
    );

    // Reoccupation by a NEW Goal: AUTO name (never copies the old override),
    // and the slot's saved color survives (no draft change = preserve).
    final second = await goals.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Different Goal',
      targets: const GoalTargets(weekly: amount),
      expectedSlotIndex: 3,
      operationId: 'p46-slot-carry-3',
    );
    final document = await storedDocument();
    expect(document.goalEventTypeNames[first.id], isNull);
    expect(document.goalEventTypeNames[second.id], isNull);
    expect(document.events['exercise'], slotPair);
  });

  test(
    'expectedSlotIndex mismatch at Save (allocator race) rejects the merge',
    () async {
      // Draft resolved against slot 3. Free one later weekly slot as well, then
      // occupy slot 3 first so the racer receives slot 4 and hits the expected
      // slot mismatch rather than the unrelated capacity guard.
      await (database.update(database.goals)
              ..where(
                (table) =>
                    table.status.equals('active') &
                    table.activeSlotIndex.equals(4),
              ))
          .write(const GoalsCompanion(status: Value<String>('archived')));
      await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Occupier',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-race-occupy-1',
      );
      await expectLater(
        goals.createGoal(
          profileId: profileId,
          role: GoalRole.weekly,
          title: 'Racer',
          targets: const GoalTargets(weekly: amount),
          expectedSlotIndex: 3,
          operationId: 'p46-race-1',
          assignedEventTypeDraft: draft(
            currentNameMode: AssignedEventTypeNameMode.manual,
            currentNameOverride: 'Pool training',
            nameDirty: true,
          ),
        ),
        throwsA(isA<GoalValidationException>()),
      );
    },
  );

  test(
    'retaining the slot current color stays legal under the uniqueness law',
    () async {
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-retain-1',
      );
      // Re-save the SAME pair explicitly: legal (retaining current color).
      await goals.saveGoal(
        profileId: profileId,
        goalId: goal.id,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        operationId: 'p46-retain-2',
        assignedEventTypeDraft: draft(
          changedColor: PlannerEventColorDefaults.exercise,
          colorDirty: true,
        ),
      );
      final document = await storedDocument();
      expect(document.events['exercise'], PlannerEventColorDefaults.exercise);
    },
  );
}
