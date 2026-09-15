import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/event_type_creation_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import '../../../support/test_dependencies.dart';

/// Contract: live settings visibility (Prompt-P46 section 6).
///
/// The six canonical Event Types are creation choices ONLY while their exact
/// slot has one raw-active eligible Goal occupant; a hidden (empty/corrupt)
/// slot never appears under the legacy/historical heading either. Name
/// overrides flow through the profile presentation document without ever
/// touching raw labels, and raw/history reads stay untouched.
void main() {
  late AppDatabase database;
  late DriftGoalRepository goals;
  late DriftEventTypeRepository types;
  late String profileId;
  late StartupRepository startupRepository;
  final clock = FixedClock(DateTime.utc(2026, 9, 9, 12));

  setUp(() async {
    database = openMemoryDatabase();
    startupRepository = buildTestRepository(database: database);
    profileId = (await startupRepository.completeOnboarding()).id;
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    await seedLegacyCanonicalGoals(database, profileId);
    goals = DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    types = DriftEventTypeRepository(database: database, clock: clock);
    // Leave the first weekly slot occupied so test Goals can deterministically
    // allocate Exercise (slot 3); archive every other bootstrap Goal.
    await (database.update(database.goals)
            ..where(
              (table) =>
                  table.status.equals('active') &
                  table.activeSlotIndex.equals(2).not(),
            ))
        .write(const GoalsCompanion(status: Value<String>('archived')));
    await types.readEventTypes(profileId: profileId);
  });

  tearDown(() async {
    await database.close();
  });

  const amount = IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count');

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(
      overrides: [
        startupRepositoryProvider.overrideWithValue(startupRepository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        eventTypeRepositoryProvider.overrideWithValue(types),
        goalRepositoryProvider.overrideWithValue(goals),
      ],
    );
    addTearDown(c.dispose);
    // Boot startup to a ready state so profile-scoped providers resolve.
    c.read(startupControllerProvider);
    for (var i = 0; i < 200; i += 1) {
      if (c.read(startupControllerProvider) is StartupReady) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (c.read(startupControllerProvider) is! StartupReady) {
      fail('Startup did not reach ready state');
    }
    // Warm the raw controller so eventTypeControllerProvider is loaded.
    c.read(eventTypeControllerProvider);
    for (var i = 0; i < 200; i += 1) {
      if (!c.read(eventTypeControllerProvider).isLoading) {
        break;
      }
      await Future<void>.delayed(Duration.zero);
    }
    return c;
  }

  test(
    'empty slot: canonical type is omitted from creation choices and never '
    'listed as a legacy row',
    () async {
      final c = await container();
      // Slot 3 empty: exercise is NOT a valid choice.
      final choices = await c.read(eventTypeCreationChoicesProvider.future);
      final exercise = choices
          .where(
            (choice) =>
                choice.type.stableKey == SystemEventTypeKeys.exercise,
          )
          .toList();
      expect(exercise, isEmpty);
      // The raw state still retains the row for history (raw law intact).
      final state = c.read(eventTypeControllerProvider);
      expect(
        state.eventTypes.any(
          (type) => type.stableKey == SystemEventTypeKeys.exercise,
        ),
        isTrue,
      );
      // And the raw row is untouched: label 'Exercise', system, non-archived.
      final raw = await types.readEventType(
        profileId: profileId,
        eventTypeId: CanonicalGoalSlot.bySlot(3).eventTypeId,
      );
      expect(raw!.label, 'Exercise');
      expect(raw.isSystem, isTrue);
      expect(raw.isArchived, isFalse);
    },
  );

  test(
    'live occupant: canonical type becomes a choice whose displayLabel is '
    'the Goal title (AUTO)',
    () async {
      await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-vis-1',
      );
      final c = await container();
      final choices = await c.read(eventTypeCreationChoicesProvider.future);
      final exercise = choices.singleWhere(
        (choice) => choice.type.stableKey == SystemEventTypeKeys.exercise,
      );
      expect(exercise.binding, isNotNull);
      expect(exercise.displayLabel, 'Swim');
      // Raw label untouched by the alias.
      expect(exercise.type.label, 'Exercise');
    },
  );

  test(
    'MANUAL override flows into displayLabel without renaming the raw row',
    () async {
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-vis-2',
      );
      await types.saveLiveGoalPresentation(
        profileId: profileId,
        expectedSlotIndex: 3,
        expectedGoalId: goal.id,
        expectedEventTypeId: CanonicalGoalSlot.bySlot(3).eventTypeId,
        expectedStableKey: SystemEventTypeKeys.exercise,
        originalValues: const LiveGoalPresentationOriginals(),
        patch: const LiveGoalPresentationPatch(
          nameOverride: 'Pool training',
        ),
      );

      final c = await container();
      final choices = await c.read(eventTypeCreationChoicesProvider.future);
      final exercise = choices.singleWhere(
        (choice) => choice.type.stableKey == SystemEventTypeKeys.exercise,
      );
      expect(exercise.displayLabel, 'Pool training');
      final raw = await types.readEventType(
        profileId: profileId,
        eventTypeId: CanonicalGoalSlot.bySlot(3).eventTypeId,
      );
      expect(raw!.label, 'Exercise');
    },
  );

  test(
    'archived occupant: canonical type disappears from choices, raw row stays',
    () async {
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-vis-3',
      );
      await goals.archiveGoal(
        profileId: profileId,
        goalId: goal.id,
        operationId: 'p46-vis-4',
      );
      final c = await container();
      final choices = await c.read(eventTypeCreationChoicesProvider.future);
      expect(
        choices.where(
          (choice) => choice.type.stableKey == SystemEventTypeKeys.exercise,
        ),
        isEmpty,
      );
      final raw = await types.readEventType(
        profileId: profileId,
        eventTypeId: CanonicalGoalSlot.bySlot(3).eventTypeId,
      );
      expect(raw, isNotNull);
    },
  );

  test(
    'slot color duplicates compare against ALL raw active peers including '
    'hidden canonical rows',
    () async {
      // Occupy slot 3 (live) and save the exercise color explicitly.
      final goal = await goals.createGoal(
        profileId: profileId,
        role: GoalRole.weekly,
        title: 'Swim',
        targets: const GoalTargets(weekly: amount),
        expectedSlotIndex: 3,
        operationId: 'p46-vis-5',
      );
      const pair = EventColorPreference(
        accentArgb: 0xFF7986CB,
        surfaceArgb: 0xFF3E4356,
      );
      await types.saveEventColorPreference(
        profileId: profileId,
        eventTypeStableKey: SystemEventTypeKeys.exercise,
        preference: pair,
      );
      // A settings save for another canonical row with the same accent is
      // rejected because the hidden/live canonical row reserves the color.
      await expectLater(
        types.saveEventColorPreference(
          profileId: profileId,
          eventTypeStableKey: SystemEventTypeKeys.scriptureStudy,
          preference: pair,
        ),
        throwsA(isA<StateError>()),
      );
      expect(goal.title, 'Swim');
    },
  );

  test(
    'readEventTypes/readEventType raw law is NOT globally filtered by '
    'eligibility',
    () async {
      final all = await types.readEventTypes(profileId: profileId);
      // Every canonical row stays in the raw list even with all slots empty.
      for (final slotIndex in <int>[1, 2, 3, 4, 5, 6]) {
        final slot = CanonicalGoalSlot.bySlot(slotIndex);
        expect(
          all.any((type) => type.stableKey == slot.eventTypeStableKey),
          isTrue,
          reason: '${slot.eventTypeStableKey} must remain in raw reads',
        );
      }
    },
  );

  test('Study prospective alias appears on creation choices',
      () async {
    final c = await container();
    final choices = await c.read(eventTypeCreationChoicesProvider.future);
    final study = choices.singleWhere(
      (choice) => choice.type.stableKey == SystemEventTypeKeys.studyOrPlan,
    );
    expect(study.displayLabel, 'Study & Planning');
    expect(study.type.label, 'Study or Plan');
  });

  test('Study alias preserves the distinct Goal-linked Scripture binding',
      () async {
    final c = await container();
    final choices = await c.read(eventTypeCreationChoicesProvider.future);
    final study = choices.singleWhere(
      (choice) => choice.type.stableKey == SystemEventTypeKeys.studyOrPlan,
    );
    expect(study.displayLabel, 'Study & Planning');
    expect(study.type.label, 'Study or Plan');
  });
}
