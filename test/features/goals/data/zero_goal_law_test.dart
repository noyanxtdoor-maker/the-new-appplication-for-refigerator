import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// M6 zero-goal law (owner-locked).
///
/// A TRUE NEW USER completes onboarding with ZERO real Goals.  The canonical
/// bootstrap is a REPAIRER of an already-seeded profile's Goal identity, never
/// a CREATOR for a profile that carries no canonical seed signature.  These
/// tests pin that law at the repository boundary so a partial fix (removing
/// only the onboarding call) cannot silently regress.
void main() {
  const periodStart = PlannerDate(year: 2026, month: 8, day: 3);
  final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));

  DriftGoalRepository repository(AppDatabase database) => DriftGoalRepository(
    database: database,
    clock: clock,
    identifiers: const UuidIdentifierSource(),
  );

  Future<(AppDatabase, DriftGoalRepository, String)> freshProfile() async {
    final database = openMemoryDatabase();
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return (database, repository(database), profile.id);
  }

  Future<int> goalRowCount(AppDatabase database, String profileId) async {
    final rows = await (database.select(
      database.goals,
    )..where((table) => table.profileId.equals(profileId))).get();
    return rows.length;
  }

  Future<int> goalActivityCount(AppDatabase database, String profileId) async {
    final rows = await (database.select(
      database.goalActivities,
    )..where((table) => table.profileId.equals(profileId))).get();
    return rows.length;
  }

  test('a freshly completed onboarding owns ZERO goals and no goal history',
      () async {
    final (database, repo, profileId) = await freshProfile();
    addTearDown(database.close);

    expect(await repo.readActiveGoals(profileId), isEmpty);
    expect(await goalRowCount(database, profileId), 0);
    expect(await goalActivityCount(database, profileId), 0);
    expect(
      await database.select(database.goalOutboxOperations).get(),
      isEmpty,
    );
  });

  test('every goal read path stays empty for a zero-goal profile', () async {
    final (database, repo, profileId) = await freshProfile();
    addTearDown(database.close);

    // The bootstrap's own convergence, the read paths, the Home indicator
    // read's delegate and the live-binding reader are all invoked here.  None
    // may create a Goal for a profile with no canonical seed signature.
    await repo.ensureCanonicalGoals(profileId);
    await GoalBootstrap.ensure(database, profileId, nowUtc: clock.nowUtc());
    await repo.readActiveGoals(profileId);
    await repo.readCapacity(profileId);
    await repo.readLiveEventTypeBindings(profileId);
    await repo.readPlanning(
      profileId: profileId,
      periodStart: periodStart,
      today: periodStart,
    );

    expect(await repo.readActiveGoals(profileId), isEmpty);
    expect(await goalRowCount(database, profileId), 0);
    expect(await goalActivityCount(database, profileId), 0);
    expect(await repo.readArchivedGoals(profileId: profileId), isEmpty);
  });

  test('a partially seeded legacy profile converges the missing slots',
      () async {
    final (database, repo, profileId) = await freshProfile();
    addTearDown(database.close);
    // A pre-M6 interrupted install that only wrote the slot-1 identity after
    // the seed signature: the repair path must restore ONLY the missing
    // identities and never duplicate or rewrite the existing one.
    await seedLegacyCanonicalGoals(
      database,
      profileId,
      clock: clock,
      convergeRemainingSlots: false,
    );
    // Read the raw rows: readActiveGoals itself converges, which is the very
    // repair path under test.
    expect(await goalRowCount(database, profileId), 1);

    await repo.ensureCanonicalGoals(profileId);

    final repaired = await repo.readActiveGoals(profileId);
    expect(repaired, hasLength(6));
    expect(
      repaired.map((goal) => goal.activeSlotIndex).toList()..sort(),
      <int?>[1, 2, 3, 4, 5, 6],
    );
  });

  test('reading an existing user never fabricates extra goals', () async {
    final (database, repo, profileId) = await freshProfile();
    addTearDown(database.close);
    await seedLegacyCanonicalGoals(database, profileId, clock: clock);

    for (var i = 0; i < 3; i += 1) {
      await repo.ensureCanonicalGoals(profileId);
      await GoalBootstrap.ensure(database, profileId, nowUtc: clock.nowUtc());
      await repo.readActiveGoals(profileId);
      await repo.readCapacity(profileId);
    }

    expect(await repo.readActiveGoals(profileId), hasLength(6));
    expect(await goalRowCount(database, profileId), 6);
    expect(await goalActivityCount(database, profileId), 6);
  });

  test('importing one starter goal never fabricates the other five', () async {
    final (database, repo, profileId) = await freshProfile();
    addTearDown(database.close);

    // Exactly how the Starter Goals screen imports: resolve the canonical slot
    // the allocator will occupy, then create through the canonical transaction.
    final slot = await repo.nextAvailableSlot(
      profileId: profileId,
      role: GoalRole.weekly,
    );
    await repo.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Exercise',
      targets: const GoalTargets(
        weekly: IndicatorAmount(scaledValue: 3, scale: 0, unit: 'count'),
      ),
      expectedSlotIndex: slot,
    );

    expect(await repo.readActiveGoals(profileId), hasLength(1));

    // The bootstrap and every read path must now leave the profile at exactly
    // the ONE goal the user asked for.
    await repo.ensureCanonicalGoals(profileId);
    await GoalBootstrap.ensure(database, profileId, nowUtc: clock.nowUtc());
    await repo.readActiveGoals(profileId);
    await repo.readPlanning(
      profileId: profileId,
      periodStart: periodStart,
      today: periodStart,
    );

    final goals = await repo.readActiveGoals(profileId);
    expect(goals, hasLength(1));
    expect(goals.single.title, 'Exercise');
    expect(await goalRowCount(database, profileId), 1);
  });

  test('creating a custom goal keeps the profile at exactly its own goals',
      () async {
    final (database, repo, profileId) = await freshProfile();
    addTearDown(database.close);

    await repo.createGoal(
      profileId: profileId,
      role: GoalRole.weekly,
      title: 'Read a book',
      targets: const GoalTargets(
        weekly: IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count'),
      ),
    );
    await repo.ensureCanonicalGoals(profileId);

    final goals = await repo.readActiveGoals(profileId);
    expect(goals, hasLength(1));
    expect(goals.single.title, 'Read a book');
    // The canonical transaction assigns the slot's canonical identity — exactly
    // the Create Goal law.  What matters for the zero-goal law is that the
    // profile stays at the ONE goal the user asked for.
    expect(goals.single.activeSlotIndex, 2);
    expect(goals.single.indicatorKey, 'scripture_study');
  });
}
