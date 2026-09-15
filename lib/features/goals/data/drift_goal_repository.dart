import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/core/time/week_period.dart';
import 'package:rmplanner/features/goals/application/goal_repository.dart';
import 'package:rmplanner/features/goals/data/live_goal_event_type_bindings.dart';
import 'package:rmplanner/features/goals/domain/assigned_event_type_draft.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/domain/goal_event_type_policy.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/planner_presentation_document_store.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

/// Deterministic migration/bootstrap for the six approved WLI-backed Goals.
/// It is deliberately independent of display labels: slot and indicator key
/// are the identity used to recover from an interrupted first launch.
final class GoalBootstrap {
  const GoalBootstrap._();

  static String stableId(String profileId, int slotIndex) {
    return '$profileId:goal:$slotIndex';
  }

  static GoalRole roleForPosition(int position) => switch (position) {
    0 => GoalRole.dailyWeekly,
    5 => GoalRole.weeklyMonthly,
    _ => GoalRole.weekly,
  };

  static Future<void> ensure(
    AppDatabase database,
    String profileId, {
    DateTime? nowUtc,
  }) async {
    final definitions =
        await (database.select(database.lifeIndicatorDefinitions)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(LifeIndicatorDefinitions)>[
                (table) => OrderingTerm.asc(table.position),
              ]))
            .get();
    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    var existingGoals = await (database.select(
      database.goals,
    )..where((table) => table.profileId.equals(profileId))).get();
    final definitionsByIndicator = <String, LifeIndicatorDefinitionRow>{
      for (final definition in definitions) definition.indicatorKey: definition,
    };
    // MP-16: before the ordinary canonical-slot loop, repair the exact legacy
    // Budget/Ministering crossover if the immutable v17 creation evidence
    // proves the historical identity. The helper runs with the already loaded
    // rows so its steady-state cost is a single bounded evidence read (and
    // zero reads once the pair is repaired).
    final legacyPairReconciled = await _reconcileLegacyBudgetMinisteringCross(
      database,
      profileId,
      goals: existingGoals,
      nowUtc: now,
    );
    if (legacyPairReconciled) {
      // The rows changed underneath the preloaded list; reload so the ordinary
      // slot loop converges on the repaired pair instead of the stale one.
      existingGoals = await (database.select(
        database.goals,
      )..where((table) => table.profileId.equals(profileId))).get();
    }
    // Coalesce the per-slot activity/outbox existence checks into two reads
    // so the steady-state repair path is O(1) instead of O(slots) queries.
    final canonicalOperationIds = <String>{
      for (final slot in CanonicalGoalSlot.all)
        '${stableId(profileId, slot.slotIndex)}:created',
    };
    final existingActivityOperationIds = <String>{
      for (final row
          in await (database.select(database.goalActivities)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.operationId.isIn(canonicalOperationIds),
                ))
              .get())
        row.operationId,
    };
    final existingOutboxOperationIds = <String>{
      for (final row
          in await (database.select(database.goalOutboxOperations)
                ..where(
                  (table) => table.operationId.isIn(canonicalOperationIds),
                ))
              .get())
        row.operationId,
    };
    // M6 zero-goal law (owner-locked): the bootstrap is a REPAIRER of existing
    // Goal identity, never a CREATOR for a profile that was never seeded.
    //
    // The discriminator is the bootstrap's OWN canonical seed signature — the
    // stable Goal IDs it writes (`profileId:goal:slot`) and the canonical
    // creation activity/outbox operation IDs.  A profile that carries that
    // signature is a pre-M6 profile whose canonical six were seeded at
    // onboarding, so the loop below keeps converging a missing slot exactly as
    // before (and never rewrites, resurrects or removes a historical row).
    //
    // A profile with NO such signature has never been seeded — every Goal it
    // owns was created explicitly by the user (Create Goal / Starter Goal, whose
    // IDs are generated UUIDs).  For that profile the bootstrap creates
    // nothing, so a new user starts at ZERO Goals and STAYS at exactly the
    // goals they asked for; importing one starter goal can never cause the
    // other five to appear.
    final canonicalSeededGoalIds = <String>{
      for (final slot in CanonicalGoalSlot.all)
        stableId(profileId, slot.slotIndex),
    };
    final hasCanonicalSeedEvidence =
        existingGoals.any(
          (row) => canonicalSeededGoalIds.contains(row.id),
        ) ||
        existingActivityOperationIds.isNotEmpty ||
        existingOutboxOperationIds.isNotEmpty;
    // Nothing to repair for a profile the bootstrap never seeded.  The slot
    // loop below does more than insert missing slots: it also backfills the
    // slot's canonical `:created` activity/outbox evidence for ANY goal that
    // matches the slot.  Running it for a never-seeded profile would let a
    // single user-created Goal in a free canonical slot fabricate that
    // evidence, and the NEXT read would then seed the remaining five — exactly
    // the silent auto-population this law forbids.  Returning here also keeps
    // legacy title migration and definition-label repair where they belong:
    // on profiles that actually carry the pre-M6 seed.
    if (!hasCanonicalSeedEvidence) {
      return;
    }
    for (final slot in CanonicalGoalSlot.all) {
      final goalId = stableId(profileId, slot.slotIndex);
      final definition = definitionsByIndicator[slot.indicatorKey];
      GoalRow? goal;
      for (final row in existingGoals) {
        if (row.assignedEventTypeStableKey == slot.eventTypeStableKey) {
          goal = row;
          break;
        }
      }
      goal ??= existingGoals.where((row) => row.id == goalId).firstOrNull;
      goal ??= existingGoals
          .where((row) => row.indicatorKey == slot.indicatorKey)
          .firstOrNull;
      if (goal == null && definition != null && hasCanonicalSeedEvidence) {
        final title = definition.label == 'Meaningful Connections'
            ? slot.defaultTitle
            : definition.label;
        await database
            .into(database.goals)
            .insert(
              GoalsCompanion.insert(
                id: goalId,
                profileId: profileId,
                indicatorKey: Value<String?>(slot.indicatorKey),
                assignedEventTypeStableKey: Value<String?>(
                  slot.eventTypeStableKey,
                ),
                role: slot.role.storageName,
                activeSlotIndex: Value<int?>(slot.slotIndex),
                title: title,
                iconId: const Value<String?>(null),
                status: GoalStatus.active.name,
                createdAtUtc: now,
                updatedAtUtc: now,
                archivedAtUtc: const Value<DateTime?>(null),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        goal =
            await (database.select(database.goals)
                  ..where(
                    (table) =>
                        table.profileId.equals(profileId) &
                        table.id.equals(goalId),
                  )
                  ..limit(1))
                .getSingleOrNull();
      }
      if (goal == null) {
        continue;
      }
      final migratedTitle = goal.title == 'Meaningful Connections'
          ? slot.defaultTitle
          : goal.title;
      // A permanently deleted Goal must never be resurrected by the
      // bootstrap.  Its row stays untouched so historical records keep their
      // original identity and the slot stays free for a replacement.
      if (goal.status != GoalStatus.deleted.name &&
          (goal.assignedEventTypeStableKey != slot.eventTypeStableKey ||
              goal.indicatorKey != slot.indicatorKey ||
              goal.role != slot.role.storageName ||
              (goal.status == GoalStatus.active.name &&
                  goal.activeSlotIndex != slot.slotIndex) ||
              goal.title != migratedTitle)) {
        await (database.update(database.goals)..where(
              (table) =>
                  table.profileId.equals(profileId) & table.id.equals(goal!.id),
            ))
            .write(
              GoalsCompanion(
                indicatorKey: Value<String?>(slot.indicatorKey),
                assignedEventTypeStableKey: Value<String?>(
                  slot.eventTypeStableKey,
                ),
                role: Value<String>(slot.role.storageName),
                activeSlotIndex: goal.status == GoalStatus.active.name
                    ? Value<int?>(slot.slotIndex)
                    : const Value<int?>(null),
                title: Value<String>(migratedTitle),
                updatedAtUtc: Value<DateTime>(now),
              ),
            );
        goal =
            await (database.select(database.goals)
                  ..where(
                    (table) =>
                        table.profileId.equals(profileId) &
                        table.id.equals(goal!.id),
                  )
                  ..limit(1))
                .getSingleOrNull();
      }
      if (goal == null) continue;
      final title = goal.title;
      final operationId = '$goalId:created';
      if (!existingActivityOperationIds.contains(operationId)) {
        await database
            .into(database.goalActivities)
            .insert(
              GoalActivitiesCompanion.insert(
                id: operationId,
                profileId: profileId,
                goalId: goal.id,
                operationId: operationId,
                action: GoalActivityAction.created.name,
                previousValue: const Value<String?>(null),
                newValue: Value<String?>(title),
                occurredAtUtc: now,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
      if (!existingOutboxOperationIds.contains(operationId)) {
        await database
            .into(database.goalOutboxOperations)
            .insert(
              GoalOutboxOperationsCompanion.insert(
                operationId: operationId,
                profileId: profileId,
                entityType: 'goal',
                entityId: goal.id,
                action: GoalActivityAction.created.name,
                payloadJson: jsonEncode(<String, Object?>{
                  'goalId': goal.id,
                  'role': slot.role.storageName,
                  'slot': slot.slotIndex,
                  'title': title,
                  'iconId': goal.iconId,
                  'assignedEventTypeStableKey': slot.eventTypeStableKey,
                }),
                createdAtUtc: now,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
      if (definition != null &&
          definition.position == 3 &&
          definition.label != goal.title) {
        await (database.update(database.lifeIndicatorDefinitions)..where(
              (table) =>
                  table.id.equals(definition.id) &
                  table.label.equals(definition.label),
            ))
            .write(
              LifeIndicatorDefinitionsCompanion(
                label: Value<String>(goal.title),
              ),
            );
      }
    }
  }
}

/// MP-16: exact, history-keyed, transactional compatibility reconciliation
/// for the legacy fixed Goal <-> Event Type crossover.
///
/// Historical Goal identity is the durable Goal ID plus the immutable v17
/// created activity/outbox evidence, never the later corrupted slot. When the
/// exact crossed pair matches, G5 (Budget Review identity) is moved back to
/// Budget slot 4 and G4 (Ministering Visit identity) to slot 5, keeping the
/// current canonical slot order while restoring the historical semantics.
///
/// The predicate is deliberately narrow: any missing/one-sided/ambiguous
/// component returns false (zero writes) and the ordinary canonical slot loop
/// continues untouched. Event Types, mappings, Events, reports, ledger,
/// activities, outbox, targets, Planner, and unrelated rows are never written.
Future<bool> _reconcileLegacyBudgetMinisteringCross(
  AppDatabase database,
  String profileId, {
  required List<GoalRow> goals,
  required DateTime nowUtc,
}) async {
  final budgetSlot = CanonicalGoalSlot.bySlot(4);
  final ministeringSlot = CanonicalGoalSlot.bySlot(5);
  final budgetKey = budgetSlot.eventTypeStableKey;
  final budgetIndicator = budgetSlot.indicatorKey;
  final budgetEventTypeId = budgetSlot.eventTypeId;
  final ministeringKey = ministeringSlot.eventTypeStableKey;
  final ministeringIndicator = ministeringSlot.indicatorKey;
  final ministeringEventTypeId = ministeringSlot.eventTypeId;
  final g4Id = GoalBootstrap.stableId(profileId, 4);
  final g5Id = GoalBootstrap.stableId(profileId, 5);

  GoalRow? g4;
  GoalRow? g5;
  for (final row in goals) {
    if (row.id == g4Id) g4 = row;
    if (row.id == g5Id) g5 = row;
  }
  if (g4 == null || g5 == null) return false;
  if (g4.status != GoalStatus.active.name ||
      g5.status != GoalStatus.active.name) {
    return false;
  }
  if (g4.role != GoalRole.weekly.storageName ||
      g5.role != GoalRole.weekly.storageName) {
    return false;
  }
  // Exact current crossed post-bootstrap shape.
  if (g4.activeSlotIndex != 4 ||
      g4.indicatorKey != budgetIndicator ||
      g4.assignedEventTypeStableKey != budgetKey ||
      g5.activeSlotIndex != 5 ||
      g5.indicatorKey != ministeringIndicator ||
      g5.assignedEventTypeStableKey != ministeringKey) {
    return false;
  }

  // Immutable deterministic created activities prove the v17 identity. This
  // is the only evidence read on a fresh/canonical profile: its creation
  // titles differ (Budget Review for goal:4), so the check short-circuits
  // before any further read.
  final createdActivities = await (database.select(
    database.goalActivities,
  )..where(
    (table) =>
        table.profileId.equals(profileId) &
        table.operationId.isIn(<String>['$g4Id:created', '$g5Id:created']),
  )).get();
  String? createdValue(String goalId) {
    for (final row in createdActivities) {
      if (row.operationId == '$goalId:created' &&
          row.action == GoalActivityAction.created.name) {
        return row.newValue;
      }
    }
    return null;
  }

  if (createdValue(g4Id) != 'Ministering Visit') return false;
  if (createdValue(g5Id) != 'Budget Review') return false;

  // Matching deterministic v17 created-outbox identity (entity IDs, slots,
  // titles, and payload goalId).
  final createdOutbox = await (database.select(
    database.goalOutboxOperations,
  )..where(
    (table) =>
        table.operationId.isIn(<String>['$g4Id:created', '$g5Id:created']),
  )).get();
  bool outboxMatches(String goalId, int slot, String title) {
    for (final row in createdOutbox) {
      if (row.operationId != '$goalId:created' ||
          row.action != GoalActivityAction.created.name ||
          row.entityId != goalId) {
        continue;
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(row.payloadJson);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      if (decoded['goalId'] != goalId) continue;
      if (decoded['slot'] != slot) continue;
      if (decoded['title'] != title) continue;
      return true;
    }
    return false;
  }

  if (!outboxMatches(g4Id, 4, 'Ministering Visit')) return false;
  if (!outboxMatches(g5Id, 5, 'Budget Review')) return false;

  // Canonical Event Type identities must be exact and unmodified.
  final systemTypes = await (database.select(
    database.activityTypes,
  )..where(
    (table) => table.id.isIn(<String>[
      budgetEventTypeId,
      ministeringEventTypeId,
    ]),
  )).get();
  var budgetTypeExact = false;
  var ministeringTypeExact = false;
  for (final row in systemTypes) {
    if (row.id == budgetEventTypeId &&
        row.stableKey == budgetKey) {
      budgetTypeExact = true;
    } else if (row.id == ministeringEventTypeId &&
        row.stableKey == ministeringKey) {
      ministeringTypeExact = true;
    }
  }
  if (!budgetTypeExact || !ministeringTypeExact) return false;

  // Their version-1 indicator mapping rows must be exact.
  final systemMappings = await (database.select(
    database.activityTypeIndicatorMappings,
  )..where(
    (table) => table.activityTypeId.isIn(<String>[
      budgetEventTypeId,
      ministeringEventTypeId,
    ]),
  )).get();
  var budgetMappingExact = false;
  var ministeringMappingExact = false;
  for (final row in systemMappings) {
    if (row.activityTypeId == budgetEventTypeId &&
        row.indicatorKey == budgetIndicator &&
        row.mappingVersion == 1) {
      budgetMappingExact = true;
    } else if (row.activityTypeId == ministeringEventTypeId &&
        row.indicatorKey == ministeringIndicator &&
        row.mappingVersion == 1) {
      ministeringMappingExact = true;
    }
  }
  if (!budgetMappingExact || !ministeringMappingExact) return false;

  // One atomic repair. The predicate is re-checked inside the transaction;
  // both slots are cleared to NULL first so the unique
  // (profile_id, active_slot_index) index cannot collide during the swap.
  return database.transaction(() async {
    final current = await (database.select(
      database.goals,
    )..where(
      (table) =>
          table.profileId.equals(profileId) &
          (table.id.equals(g4Id) | table.id.equals(g5Id)),
    )).get();
    final currentG4 = current.where((row) => row.id == g4Id).firstOrNull;
    final currentG5 = current.where((row) => row.id == g5Id).firstOrNull;
    if (currentG4 == null || currentG5 == null) return false;
    if (currentG4.status != GoalStatus.active.name ||
        currentG5.status != GoalStatus.active.name) {
      return false;
    }
    if (currentG4.role != GoalRole.weekly.storageName ||
        currentG5.role != GoalRole.weekly.storageName) {
      return false;
    }
    if (currentG4.activeSlotIndex != 4 ||
        currentG4.indicatorKey != budgetIndicator ||
        currentG4.assignedEventTypeStableKey != budgetKey ||
        currentG5.activeSlotIndex != 5 ||
        currentG5.indicatorKey != ministeringIndicator ||
        currentG5.assignedEventTypeStableKey != ministeringKey) {
      return false;
    }

    await (database.update(database.goals)..where(
      (table) =>
          table.profileId.equals(profileId) &
          (table.id.equals(g4Id) | table.id.equals(g5Id)),
    )).write(
      const GoalsCompanion(activeSlotIndex: Value<int?>(null)),
    );
    // G5 (Budget Review identity) -> Budget slot 4.
    await (database.update(database.goals)..where(
      (table) => table.profileId.equals(profileId) & table.id.equals(g5Id),
    )).write(
      GoalsCompanion(
        activeSlotIndex: const Value<int?>(4),
        indicatorKey: Value<String?>(budgetIndicator),
        assignedEventTypeStableKey: Value<String?>(budgetKey),
        updatedAtUtc: Value<DateTime>(nowUtc),
      ),
    );
    // G4 (Ministering Visit identity) -> slot 5.
    await (database.update(database.goals)..where(
      (table) => table.profileId.equals(profileId) & table.id.equals(g4Id),
    )).write(
      GoalsCompanion(
        activeSlotIndex: const Value<int?>(5),
        indicatorKey: Value<String?>(ministeringIndicator),
        assignedEventTypeStableKey: Value<String?>(ministeringKey),
        updatedAtUtc: Value<DateTime>(nowUtc),
      ),
    );
    return true;
  });
}

final class DriftGoalRepository implements GoalRepository {
  const DriftGoalRepository({
    required this.database,
    required this.clock,
    required this.identifiers,
  });

  final AppDatabase database;
  final AppClock clock;
  final IdentifierSource identifiers;

  @override
  Stream<int> watchChanges(String profileId) {
    // Riverpod 3 suppresses consecutive equal AsyncData values. A void
    // change stream therefore refreshes dependants only once; use a distinct
    // generation for every committed Drift table update so Home projections
    // react to each Event lifecycle change, including deletion.
    var generation = 0;
    return database
        .tableUpdates(
          TableUpdateQuery.onAllTables(<ResultSetImplementation>[
            database.goals,
            database.goalActivities,
            database.goalOutboxOperations,
            database.indicatorGoalRevisions,
            database.weeklyIndicatorTargetRevisions,
            database.activityLedgerEntries,
            database.outcomeReports,
            database.calendarEvents,
            database.calendarEventExceptions,
            database.lifeIndicatorDefinitions,
            database.plannerTasks,
            database.taskStatusChanges,
            database.taskGoalContributions,
            database.activityTypes,
          ]),
        )
        .map((_) => ++generation);
  }

  @override
  Future<void> ensureCanonicalGoals(String profileId) async {
    await GoalBootstrap.ensure(database, profileId, nowUtc: clock.nowUtc());
    final mappings = await _goalMappings(profileId);
    final keys = mappings.keys.toList(growable: false);
    // Coalesce the per-Goal orphan-revision checks into two reads; only the
    // affected keys run the corrective UPDATE (steady state: none).
    final indicatorNullKeys = <String>{};
    final weeklyNullKeys = <String>{};
    if (keys.isNotEmpty) {
      indicatorNullKeys.addAll(
        (await (database.select(database.indicatorGoalRevisions)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.indicatorKey.isIn(keys) &
                  table.goalId.isNull(),
            ))
                .get())
            .map((row) => row.indicatorKey),
      );
      weeklyNullKeys.addAll(
        (await (database.select(database.weeklyIndicatorTargetRevisions)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.isIn(keys) &
                    table.goalId.isNull(),
              ))
              .get())
            .map((row) => row.indicatorKey),
      );
    }
    for (final goal in mappings.values) {
      if (indicatorNullKeys.contains(goal.indicatorKey)) {
        await database.customUpdate(
          'UPDATE indicator_goal_revisions SET goal_id = ? '
          'WHERE profile_id = ? AND indicator_key = ? AND goal_id IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(goal.id),
            Variable<String>(profileId),
            Variable<String>(goal.indicatorKey ?? ''),
          ],
          updates: <ResultSetImplementation>{database.indicatorGoalRevisions},
        );
      }
      if (weeklyNullKeys.contains(goal.indicatorKey)) {
        await database.customUpdate(
          'UPDATE weekly_indicator_target_revisions SET goal_id = ? '
          'WHERE profile_id = ? AND indicator_key = ? AND goal_id IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(goal.id),
            Variable<String>(profileId),
            Variable<String>(goal.indicatorKey ?? ''),
          ],
          updates: <ResultSetImplementation>{
            database.weeklyIndicatorTargetRevisions,
          },
        );
      }
    }
  }

  @override
  Future<List<Goal>> readActiveGoals(String profileId) async {
    await ensureCanonicalGoals(profileId);
    final rows =
        await (database.select(database.goals)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.status.equals(GoalStatus.active.name),
              )
              ..orderBy(<OrderingTerm Function(Goals)>[
                (table) => OrderingTerm.asc(table.activeSlotIndex),
              ]))
            .get();
    return rows.map(_mapGoal).toList(growable: false);
  }

  /// Additive read-only delegation (contract D.4): no GoalBootstrap.ensure,
  /// no readPlanning materialization, and no lifecycle writes of any kind.
  @override
  Future<Map<int, LiveGoalEventTypeBinding>> readLiveEventTypeBindings(
    String profileId,
  ) {
    return readLiveGoalEventTypeBindings(database, profileId);
  }

  @override
  Future<Goal?> readGoal({
    required String profileId,
    required String goalId,
  }) async {
    final row =
        await (database.select(database.goals)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) & table.id.equals(goalId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapGoal(row);
  }

  @override
  Future<int?> nextAvailableSlot({
    required String profileId,
    required GoalRole role,
  }) async {
    await ensureCanonicalGoals(profileId);
    return _freeSlotOrNull(profileId, role);
  }

  @override
  Future<GoalCapacity> readCapacity(String profileId) async {
    await ensureCanonicalGoals(profileId);
    final rows =
        await (database.select(database.goals)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.status.equals(GoalStatus.active.name),
            ))
            .get();
    final counts = <GoalRole, int>{for (final role in GoalRole.values) role: 0};
    for (final row in rows.where(_isCanonicalActiveRow)) {
      final role = _roleFromName(row.role);
      counts[role] = (counts[role] ?? 0) + 1;
    }
    return GoalCapacity(activeByRole: counts);
  }

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
  }) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw const GoalValidationException('Goal name is required.');
    }
    await ensureCanonicalGoals(profileId);
    final effectiveOperationId = operationId ?? identifiers.nextUuid();
    return database.transaction(() async {
      final prior = await _goalForOperation(profileId, effectiveOperationId);
      if (prior != null) {
        return prior;
      }
      final goalId = identifiers.nextUuid();
      final slot = await _freeSlot(profileId, role);
      if (expectedSlotIndex != null && slot != expectedSlotIndex) {
        throw const GoalValidationException(
          'The available Goal slot changed. Review the assigned Event Type '
          'and try again.',
        );
      }
      final canonicalSlot = CanonicalGoalSlot.bySlot(slot);
      final now = clock.nowUtc();
      final goal = Goal(
        id: goalId,
        profileId: profileId,
        indicatorKey: canonicalSlot.indicatorKey,
        assignedEventTypeStableKey: canonicalSlot.eventTypeStableKey,
        role: canonicalSlot.role,
        activeSlotIndex: slot,
        title: normalizedTitle,
        iconId: iconId,
        status: GoalStatus.active,
        createdAtUtc: now,
        updatedAtUtc: now,
        archivedAtUtc: null,
        deletedAtUtc: null,
      );
      await database.into(database.goals).insert(_goalCompanion(goal));
      await _writeTargets(
        goal: goal,
        targets: targets,
        operationId: effectiveOperationId,
        startDay: startDay,
      );
      await _writeActivity(
        goal: goal,
        action: GoalActivityAction.created,
        operationId: effectiveOperationId,
        newValue: normalizedTitle,
      );
      await _writeOutbox(
        profileId: profileId,
        goalId: goalId,
        operationId: effectiveOperationId,
        action: GoalActivityAction.created.name,
        payload: <String, Object?>{
          'goalId': goalId,
          'role': canonicalSlot.role.storageName,
          'slot': slot,
          'indicatorKey': canonicalSlot.indicatorKey,
          'assignedEventTypeStableKey': canonicalSlot.eventTypeStableKey,
          'title': normalizedTitle,
          'iconId': iconId,
          'targets': _targetsPayload(targets),
        },
      );
      if (assignedEventTypeDraft != null) {
        await _mergeAssignedEventTypePresentation(
          profileId: profileId,
          goalId: goalId,
          slotIndex: slot,
          draft: assignedEventTypeDraft,
        );
      }
      return goal;
    });
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
    AssignedEventTypeDraft? assignedEventTypeDraft,
    int startDay = DateTime.monday,
  }) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      throw const GoalValidationException('Goal name is required.');
    }
    await ensureCanonicalGoals(profileId);
    final effectiveOperationId = operationId ?? identifiers.nextUuid();
    return database.transaction(() async {
      final prior = await _goalForOperation(profileId, effectiveOperationId);
      if (prior != null) {
        return prior;
      }
      final row = await _goalRow(profileId, goalId);
      if (row == null || row.status != GoalStatus.active.name) {
        throw const GoalValidationException('Active Goal was not found.');
      }
      final before = _mapGoal(row);
      final now = clock.nowUtc();
      final titleChanged = before.title != normalizedTitle;
      // A missing icon argument means the caller is an older sync/client
      // path. Preserve the canonical value instead of clearing it.
      final effectiveIconId = iconId ?? before.iconId;
      await (database.update(database.goals)..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(goalId),
          ))
          .write(
            GoalsCompanion(
              title: Value<String>(normalizedTitle),
              iconId: Value<String?>(effectiveIconId),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
      if (titleChanged && before.indicatorKey != null) {
        await (database.update(database.lifeIndicatorDefinitions)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.indicatorKey.equals(before.indicatorKey!),
            ))
            .write(
              LifeIndicatorDefinitionsCompanion(label: Value(normalizedTitle)),
            );
      }
      await _writeTargets(
        goal: before,
        targets: targets,
        operationId: effectiveOperationId,
        today: today,
        startDay: startDay,
      );
      if (titleChanged) {
        await _writeActivity(
          goal: before,
          action: GoalActivityAction.renamed,
          operationId: effectiveOperationId,
          previousValue: before.title,
          newValue: normalizedTitle,
        );
      }
      await _writeOutbox(
        profileId: profileId,
        goalId: goalId,
        operationId: effectiveOperationId,
        action: titleChanged ? GoalActivityAction.renamed.name : 'updated',
        payload: <String, Object?>{
          'goalId': goalId,
          'title': normalizedTitle,
          'iconId': effectiveIconId,
          'targets': _targetsPayload(targets),
        },
      );
      if (assignedEventTypeDraft != null) {
        await _mergeAssignedEventTypePresentation(
          profileId: profileId,
          goalId: goalId,
          slotIndex: before.activeSlotIndex!,
          draft: assignedEventTypeDraft,
          goalUpdatedAtBeforeSave: before.updatedAtUtc,
        );
      }
      return _mapGoal((await _goalRow(profileId, goalId))!);
    });
  }

  /// Merges the Assigned Event Type presentation draft (explicit name
  /// override and/or explicitly changed slot color) into the profile's
  /// Planner Preferences document INSIDE the enclosing Goal save
  /// transaction, so Goal rows, targets, activity, outbox, and the
  /// presentation merge commit or roll back together.
  ///
  /// Validation (any failure throws and rolls back the whole save):
  /// - the draft's expected slot matches the Goal's actual canonical slot;
  /// - the exact canonical Event Type row exists for this profile with the
  ///   expected ID and stable key, is system, non-archived, and carries the
  ///   slot's exact one-indicator mapping;
  /// - the Goal is the raw-active occupant of that slot with the exact role;
  /// - Edit: the caller's observed [goalUpdatedAtBeforeSave] and the
  ///   original edited metadata/color still match current values, otherwise
  ///   the save is rejected instead of overwriting another editor's change;
  /// - a changed color applies the existing opaque-RGB accent-uniqueness law
  ///   against ALL active raw Event Types, including hidden canonical rows.
  ///
  /// A draft with no explicit change performs no write and no validation.
  /// An omitted patch never clears: unedited fields are preserved, including
  /// an override written concurrently while the form was open.
  Future<void> _mergeAssignedEventTypePresentation({
    required String profileId,
    required String goalId,
    required int slotIndex,
    required AssignedEventTypeDraft draft,
    DateTime? goalUpdatedAtBeforeSave,
  }) async {
    if (!draft.hasChanges) {
      return;
    }
    if (draft.expectedSlotIndex != slotIndex) {
      throw const GoalValidationException(
        'This Goal or Event Type changed. Review your changes and try again.',
      );
    }
    final canonicalSlot = CanonicalGoalSlot.bySlot(slotIndex);
    if (draft.expectedStableKey != canonicalSlot.eventTypeStableKey ||
        draft.expectedEventTypeId != canonicalSlot.eventTypeId) {
      throw const GoalValidationException(
        'This Goal or Event Type changed. Review your changes and try again.',
      );
    }

    // Exact canonical Event Type row validation: one row, exact ID, exact
    // profile, exact key, system, non-archived, exact one-indicator mapping.
    final typeRows =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.id.equals(draft.expectedEventTypeId) &
                  table.profileId.equals(profileId),
            ))
            .get();
    if (typeRows.length != 1) {
      throw const GoalValidationException(
        'This Goal or Event Type changed. Review your changes and try again.',
      );
    }
    final typeRow = typeRows.single;
    if (typeRow.stableKey != draft.expectedStableKey ||
        !typeRow.isSystem ||
        typeRow.isArchived) {
      throw const GoalValidationException(
        'This Goal or Event Type changed. Review your changes and try again.',
      );
    }
    final mappingRows =
        await (database.select(database.activityTypeIndicatorMappings)..where(
              (table) =>
                  table.activityTypeId.equals(draft.expectedEventTypeId) &
                  table.profileId.equals(profileId),
            ))
            .get();
    if (mappingRows.length != 1 ||
        mappingRows.single.indicatorKey != canonicalSlot.indicatorKey) {
      throw const GoalValidationException(
        'This Goal or Event Type changed. Review your changes and try again.',
      );
    }

    // Live occupancy: the Goal must be the raw-active occupant of this slot
    // with the exact role. Rejects archive/replacement races at Save.
    final goalRows =
        await (database.select(database.goals)..where(
              (table) =>
                  table.id.equals(goalId) &
                  table.profileId.equals(profileId),
            ))
            .get();
    if (goalRows.length != 1 ||
        goalRows.single.status != GoalStatus.active.name ||
        goalRows.single.activeSlotIndex != slotIndex ||
        goalRows.single.role != canonicalSlot.role.storageName) {
      throw const GoalValidationException(
        'This Goal or Event Type changed. Review your changes and try again.',
      );
    }

    // Edit concurrency guard: reject when the Goal row changed since the
    // draft was loaded.
    if (goalUpdatedAtBeforeSave != null &&
        draft.expectedGoalUpdatedAtUtc != null &&
        goalUpdatedAtBeforeSave != draft.expectedGoalUpdatedAtUtc) {
      throw const GoalValidationException(
        'This Goal or Event Type changed. Review your changes and try again.',
      );
    }

    const rejected = GoalValidationException(
      'This Goal or Event Type changed. Review your changes and try again.',
    );
    final store = PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    );
    await store.update(profileId, (current) async {
      final stored = current.document;

      // Metadata concurrency guard: when the user explicitly edited the
      // name, the stored entry must still equal the caller's observed
      // original. A concurrent override write is never silently overwritten.
      if (draft.nameDirty) {
        final storedEntry = stored.goalEventTypeNames[goalId];
        final matchesOriginal =
            draft.originalNameMode == AssignedEventTypeNameMode.auto
                ? storedEntry == null
                : storedEntry != null &&
                    storedEntry.name == draft.originalNameOverride &&
                    storedEntry.eventTypeStableKey ==
                        canonicalSlot.eventTypeStableKey;
        if (!matchesOriginal) {
          throw rejected;
        }
      }

      // Color concurrency guard and uniqueness law. Comparison uses the
      // EFFECTIVE pair (saved preference, else locked canonical default), so
      // an untouched default-color slot never fails against its own default.
      final lockedDefault =
          PlannerEventColorDefaults
              .pmgStableKeyDefaults[canonicalSlot.eventTypeStableKey];
      if (draft.colorDirty && draft.changedColor != null) {
        final storedColor = stored.events[canonicalSlot.eventTypeStableKey];
        final effectiveNow =
            storedColor ??
            lockedDefault ??
            PlannerEventColorDefaults.other;
        if (effectiveNow != draft.originalColor) {
          throw rejected;
        }
        await _assertChangedSlotColorAssignable(
          profileId: profileId,
          slotStableKey: canonicalSlot.eventTypeStableKey,
          proposed: draft.changedColor!,
        );
      }

      // Narrow mutation: only explicitly dirty fields change; everything
      // else (groups, other events, other goals' overrides, concurrent
      // entries for THIS goal when not name-dirty) is carried forward.
      var nextNames = stored.goalEventTypeNames;
      var nextEvents = stored.events;
      var mutated = false;
      if (draft.nameDirty) {
        final trimmedName = draft.currentNameOverride?.trim() ?? '';
        if (draft.currentNameMode == AssignedEventTypeNameMode.manual &&
            trimmedName.isNotEmpty) {
          final entry = GoalEventTypeNameOverride(
            eventTypeStableKey: canonicalSlot.eventTypeStableKey,
            name: trimmedName,
          );
          if (nextNames[goalId] != entry) {
            nextNames = <String, GoalEventTypeNameOverride>{
              ...nextNames,
              goalId: entry,
            };
            mutated = true;
          }
        } else if (nextNames.containsKey(goalId)) {
          nextNames = <String, GoalEventTypeNameOverride>{...nextNames}
            ..remove(goalId);
          mutated = true;
        }
      }
      if (draft.colorDirty && draft.changedColor != null) {
        if (nextEvents[canonicalSlot.eventTypeStableKey] !=
            draft.changedColor) {
          nextEvents = <String, EventColorPreference>{
            ...nextEvents,
            canonicalSlot.eventTypeStableKey: draft.changedColor!,
          };
          mutated = true;
        }
      }
      if (!mutated) {
        // Nothing effective changed: zero writes.
        return null;
      }
      return PlannerColorPreferencesDocument(
        events: nextEvents,
        groups: stored.groups,
        goalEventTypeNames: nextNames,
      );
    });
  }

  /// The existing opaque-RGB accent-uniqueness law applied to one explicit
  /// slot color change: no OTHER active raw Event Type may already use the
  /// proposed accent (hidden canonical rows included); retaining the slot's
  /// own current color remains legal. Peer accents compare from raw rows and
  /// the saved preference document — never by re-entering a repository read
  /// that could re-enter bootstrap.
  Future<void> _assertChangedSlotColorAssignable({
    required String profileId,
    required String slotStableKey,
    required EventColorPreference proposed,
  }) async {
    final peerRows =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.isArchived.equals(false),
            ))
            .get();
    final preferences = await PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    ).read(profileId);
    for (final row in peerRows) {
      if (row.stableKey == slotStableKey) {
        continue;
      }
      final effectiveAccent =
          preferences.events[row.stableKey]?.accentArgb ??
          PlannerEventColorDefaults.forEventType(
            EventType(
              id: row.id,
              stableKey: row.stableKey,
              label: row.label,
              icon: EventTypeIcon.values.byName(row.iconKey),
              colorValue: row.colorValue,
              isSystem: row.isSystem,
              isArchived: row.isArchived,
              reportRequiredDefault: row.reportRequiredDefault,
              defaultDurationMinutes: row.defaultDurationMinutes,
              defaultReminderMinutes: row.defaultReminderMinutes,
              position: row.position,
              mappingVersion: row.mappingVersion,
              indicatorKeys: const <String>{},
            ),
          ).accentArgb;
      if (Vs11ColorSystem.sameOpaqueRgb(effectiveAccent, proposed.accentArgb)) {
        throw const GoalValidationException(
          'That color is already used by another active Event Type.',
        );
      }
    }
  }

  @override
  Future<void> archiveGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) async {
    await ensureCanonicalGoals(profileId);
    // Archive keeps the stable ID, Event links, and the fixed Event Type
    // assignment (restoreGoal validates slot occupancy on the way back), so
    // archiving is the supported reassignment path for slot replacements.
    await _mutateLifecycle(
      profileId: profileId,
      goalId: goalId,
      action: GoalActivityAction.archived,
      operationId: operationId,
    );
  }

  @override
  Future<void> deleteGoal({
    required String profileId,
    required String goalId,
    String? operationId,
  }) async {
    await ensureCanonicalGoals(profileId);
    final effectiveOperationId = operationId ?? identifiers.nextUuid();
    await database.transaction(() async {
      final prior = await _goalForOperation(profileId, effectiveOperationId);
      if (prior != null) {
        return;
      }
      final row = await _goalRow(profileId, goalId);
      if (row == null ||
          row.status == GoalStatus.deleted.name ||
          (row.status != GoalStatus.active.name &&
              row.status != GoalStatus.archived.name)) {
        throw const GoalValidationException('Goal was not found.');
      }
      final goal = _mapGoal(row);
      final now = clock.nowUtc();
      await (database.update(database.goals)..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(goalId),
          ))
          .write(
            GoalsCompanion(
              status: Value<String>(GoalStatus.deleted.name),
              activeSlotIndex: const Value<int?>(null),
              archivedAtUtc: const Value<DateTime?>(null),
              deletedAtUtc: Value<DateTime?>(now),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
      final deleted = _mapGoal((await _goalRow(profileId, goalId))!);
      await _writeActivity(
        goal: deleted,
        action: GoalActivityAction.deleted,
        operationId: effectiveOperationId,
        newValue: deleted.title,
      );
      await _writeOutbox(
        profileId: profileId,
        goalId: goalId,
        operationId: effectiveOperationId,
        action: GoalActivityAction.deleted.name,
        payload: <String, Object?>{
          'goalId': goalId,
          'title': goal.title,
          'iconId': goal.iconId,
        },
      );
    });
  }

  @override
  Future<Goal> restoreGoal({
    required String profileId,
    required String goalId,
    String? operationId,
    int startDay = DateTime.monday,
  }) async {
    await ensureCanonicalGoals(profileId);
    final effectiveOperationId = operationId ?? identifiers.nextUuid();
    return database.transaction(() async {
      final prior = await _goalForOperation(profileId, effectiveOperationId);
      if (prior != null) {
        return prior;
      }
      final row = await _goalRow(profileId, goalId);
      if (row == null || row.status != GoalStatus.archived.name) {
        throw const GoalValidationException('Archived Goal was not found.');
      }
      final goal = _mapGoal(row);
      final canonicalSlot =
          CanonicalGoalSlot.tryByEventTypeKey(
            goal.assignedEventTypeStableKey,
          ) ??
          CanonicalGoalSlot.tryByIndicatorKey(goal.indicatorKey) ??
          (goal.activeSlotIndex == null
              ? null
              : CanonicalGoalSlot.tryByEventTypeKey(
                  CanonicalGoalSlot.bySlot(
                    goal.activeSlotIndex!,
                  ).eventTypeStableKey,
                ));
      if (canonicalSlot == null) {
        throw const GoalValidationException(
          'Archived Goal is missing its fixed Event Type assignment.',
        );
      }
      final occupant =
          await (database.select(database.goals)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.status.equals(GoalStatus.active.name) &
                    table.activeSlotIndex.equals(canonicalSlot.slotIndex) &
                    table.id.isNotIn(<String>[goalId]),
              ))
              .getSingleOrNull();
      if (occupant != null) {
        throw GoalCapacityException(canonicalSlot.role);
      }
      final slot = canonicalSlot.slotIndex;
      final now = clock.nowUtc();
      await (database.update(database.goals)..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(goalId),
          ))
          .write(
            GoalsCompanion(
              status: Value<String>(GoalStatus.active.name),
              activeSlotIndex: Value<int?>(slot),
              archivedAtUtc: const Value<DateTime?>(null),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
      final restored = _mapGoal((await _goalRow(profileId, goalId))!);
      await _ensureCurrentTargetsAfterRestore(
        goal: restored,
        operationId: effectiveOperationId,
        startDay: startDay,
      );
      await _writeActivity(
        goal: restored,
        action: GoalActivityAction.restored,
        operationId: effectiveOperationId,
        newValue: slot.toString(),
      );
      await _writeOutbox(
        profileId: profileId,
        goalId: goalId,
        operationId: effectiveOperationId,
        action: GoalActivityAction.restored.name,
        payload: <String, Object?>{
          'goalId': goalId,
          'slot': slot,
          'iconId': restored.iconId,
        },
      );
      return restored;
    });
  }

  @override
  Future<List<Goal>> readArchivedGoals({
    required String profileId,
    String? query,
  }) async {
    final rows =
        await (database.select(database.goals)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.status.equals(GoalStatus.archived.name),
              )
              ..orderBy(<OrderingTerm Function(Goals)>[
                (table) => OrderingTerm.desc(table.archivedAtUtc),
              ]))
            .get();
    final activities = await (database.select(
      database.goalActivities,
    )..where((table) => table.profileId.equals(profileId))).get();
    final aliases = <String, Set<String>>{};
    for (final activity in activities) {
      final values = aliases.putIfAbsent(activity.goalId, () => <String>{});
      for (final value in <String?>[
        activity.previousValue,
        activity.newValue,
      ]) {
        if (value != null && value.trim().isNotEmpty) {
          values.add(value.trim().toLowerCase());
        }
      }
    }
    final normalized = query?.trim().toLowerCase();
    return rows
        .where(
          (row) =>
              normalized == null ||
              normalized.isEmpty ||
              row.title.toLowerCase().contains(normalized) ||
              (aliases[row.id] ?? const <String>{}).any(
                (alias) => alias.contains(normalized),
              ),
        )
        .map(_mapGoal)
        .toList(growable: false);
  }

  @override
  Future<List<GoalActivityHistoryItem>> readActivityHistory(
    String profileId, {
    String? goalId,
  }) async {
    final rows =
        await (database.select(database.goalActivities)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(GoalActivities)>[
                (table) => OrderingTerm.desc(table.occurredAtUtc),
                (table) => OrderingTerm.desc(table.id),
              ]))
            .get();
    final goals = await (database.select(
      database.goals,
    )..where((table) => table.profileId.equals(profileId))).get();
    final byId = <String, Goal>{for (final row in goals) row.id: _mapGoal(row)};
    return rows
        .where((row) => goalId == null || row.goalId == goalId)
        .map(
          (row) => GoalActivityHistoryItem(
            activity: _mapActivity(row),
            goalTitle: byId[row.goalId]?.title ?? 'Archived Goal',
            role: byId[row.goalId]?.role ?? GoalRole.weekly,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<Map<String, Object?>> exportGoalBackup(String profileId) async {
    await ensureCanonicalGoals(profileId);
    final goals = await (database.select(
      database.goals,
    )..where((table) => table.profileId.equals(profileId))).get();
    final activities =
        await (database.select(database.goalActivities)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(GoalActivities)>[
                (table) => OrderingTerm.asc(table.occurredAtUtc),
              ]))
            .get();
    final outbox =
        await (database.select(database.goalOutboxOperations)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(GoalOutboxOperations)>[
                (table) => OrderingTerm.asc(table.createdAtUtc),
              ]))
            .get();
    final mappings = await _goalMappings(profileId);
    final targetRows = <String, Map<String, Object?>>{};
    final canonicalTargets = await (database.select(
      database.indicatorGoalRevisions,
    )..where((table) => table.profileId.equals(profileId))).get();
    for (final row in canonicalTargets) {
      final goalId = row.goalId ?? mappings[row.indicatorKey]?.id;
      if (goalId == null) {
        continue;
      }
      targetRows[row.id] = _exportGoalTarget(
        id: row.id,
        goalId: goalId,
        indicatorKey: row.indicatorKey,
        periodType: row.periodType,
        periodStartDate: row.periodStartDate,
        periodEndDate: row.periodEndDate,
        state: row.state,
        valueScaled: row.valueScaled,
        valueScale: row.valueScale,
        unit: row.unit,
        supersedesRevisionId: row.supersedesRevisionId,
        operationId: row.operationId,
        createdAtUtc: row.createdAtUtc,
      );
    }
    final legacyTargets = await (database.select(
      database.weeklyIndicatorTargetRevisions,
    )..where((table) => table.profileId.equals(profileId))).get();
    for (final row in legacyTargets) {
      final goalId = row.goalId ?? mappings[row.indicatorKey]?.id;
      if (goalId == null) {
        continue;
      }
      targetRows.putIfAbsent(
        row.id,
        () => _exportGoalTarget(
          id: row.id,
          goalId: goalId,
          indicatorKey: row.indicatorKey,
          periodType: IndicatorGoalPeriodType.weekly.name,
          periodStartDate: row.periodStartDate,
          periodEndDate: _periodEndDate(
            IndicatorGoalPeriodType.weekly,
            row.periodStartDate,
          ),
          state: row.state,
          valueScaled: row.valueScaled,
          valueScale: row.valueScale,
          unit: row.unit,
          supersedesRevisionId: row.supersedesRevisionId,
          operationId: row.operationId,
          createdAtUtc: row.createdAtUtc,
        ),
      );
    }
    return <String, Object?>{
      'format': 'rmplanner.goals.v1',
      'schemaVersion': 1,
      'profileId': profileId,
      'goals': <Map<String, Object?>>[
        for (final row in goals)
          <String, Object?>{
            'id': row.id,
            'indicatorKey': row.indicatorKey,
            'assignedEventTypeStableKey': row.assignedEventTypeStableKey,
            'role': row.role,
            'activeSlotIndex': row.activeSlotIndex,
            'title': row.title,
            'iconId': row.iconId,
            'status': row.status,
            'createdAtUtc': row.createdAtUtc.toUtc().toIso8601String(),
            'updatedAtUtc': row.updatedAtUtc.toUtc().toIso8601String(),
            'archivedAtUtc': row.archivedAtUtc?.toUtc().toIso8601String(),
            'deletedAtUtc': row.deletedAtUtc?.toUtc().toIso8601String(),
          },
      ],
      'goalActivities': <Map<String, Object?>>[
        for (final row in activities)
          <String, Object?>{
            'id': row.id,
            'goalId': row.goalId,
            'operationId': row.operationId,
            'action': row.action,
            'previousValue': row.previousValue,
            'newValue': row.newValue,
            'occurredAtUtc': row.occurredAtUtc.toUtc().toIso8601String(),
          },
      ],
      'goalTargets': targetRows.values.toList(growable: false),
      'goalOutboxOperations': <Map<String, Object?>>[
        for (final row in outbox)
          <String, Object?>{
            'operationId': row.operationId,
            'entityType': row.entityType,
            'entityId': row.entityId,
            'action': row.action,
            'payloadJson': row.payloadJson,
            'createdAtUtc': row.createdAtUtc.toUtc().toIso8601String(),
          },
      ],
    };
  }

  @override
  Future<void> importGoalBackup({
    required String profileId,
    required Map<String, Object?> backup,
  }) async {
    await ensureCanonicalGoals(profileId);
    await _importGoalBackupInternal(
      profileId: profileId,
      backup: backup,
      wrapInTransaction: true,
    );
  }

  Future<void> _importGoalBackupInternal({
    required String profileId,
    required Map<String, Object?> backup,
    required bool wrapInTransaction,
  }) async {
    final incomingGoals = _backupMaps(backup['goals']);
    final incomingActivities = _backupMaps(backup['goalActivities']);
    final incomingTargets = _backupMaps(
      backup['goalTargets'] ?? backup['targets'],
    );
    final incomingOutbox = _backupMaps(backup['goalOutboxOperations']);
    Future<void> operation() async {
      final currentRows = await (database.select(
        database.goals,
      )..where((table) => table.profileId.equals(profileId))).get();
      final merged = <String, _BackupGoalRecord>{
        for (final row in currentRows)
          row.id: _BackupGoalRecord.fromGoal(_mapGoal(row)),
      };
      final incoming = <String, _BackupGoalRecord>{};
      for (final map in incomingGoals) {
        final record = _BackupGoalRecord.fromMap(
          map,
          fallbackNowUtc: clock.nowUtc(),
        );
        incoming[record.id] = record;
        merged[record.id] = record;
      }
      _validateBackupOccupancy(merged.values);

      for (final record in incoming.values) {
        final existing = currentRows
            .where((row) => row.id == record.id)
            .firstOrNull;
        if (existing == null) {
          await database
              .into(database.goals)
              .insert(_goalCompanion(record.toGoal(profileId)));
        } else if (existing.status == GoalStatus.deleted.name &&
            record.status != GoalStatus.deleted) {
          // Deletion wins over an older backup: restoring an older snapshot
          // must never resurrect a Goal that was permanently deleted after
          // that snapshot was taken.
          continue;
        } else {
          await (database.update(database.goals)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(record.id),
              ))
              .write(
                GoalsCompanion(
                  indicatorKey: Value<String?>(record.indicatorKey),
                  assignedEventTypeStableKey: Value<String?>(
                    record.assignedEventTypeStableKey,
                  ),
                  role: Value<String>(record.role.storageName),
                  activeSlotIndex: Value<int?>(record.activeSlotIndex),
                  title: Value<String>(record.title),
                  iconId: Value<String?>(record.iconId),
                  status: Value<String>(record.status.name),
                  updatedAtUtc: Value<DateTime>(record.updatedAtUtc),
                  archivedAtUtc: Value<DateTime?>(record.archivedAtUtc),
                  deletedAtUtc: Value<DateTime?>(record.deletedAtUtc),
                ),
              );
        }
      }

      final validGoalIds = merged.keys.toSet();
      for (final map in incomingActivities) {
        final goalId = _requiredBackupString(map, 'goalId');
        if (!validGoalIds.contains(goalId)) {
          throw const GoalValidationException(
            'Goal backup activity references an unknown Goal.',
          );
        }
        final id = _requiredBackupString(map, 'id');
        final operationId = _backupString(map['operationId']) ?? id;
        await database
            .into(database.goalActivities)
            .insert(
              GoalActivitiesCompanion.insert(
                id: id,
                profileId: profileId,
                goalId: goalId,
                operationId: operationId,
                action:
                    _backupString(map['action']) ??
                    GoalActivityAction.created.name,
                previousValue: Value<String?>(
                  _backupString(map['previousValue']),
                ),
                newValue: Value<String?>(_backupString(map['newValue'])),
                occurredAtUtc: _backupDate(
                  map['occurredAtUtc'],
                  clock.nowUtc(),
                ),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }

      final targetIds = <String>{};
      for (final map in incomingTargets) {
        final id = _requiredBackupString(map, 'id');
        if (!targetIds.add(id)) {
          continue;
        }
        final goalId = _backupString(map['goalId']);
        final indicatorKey =
            _backupString(map['indicatorKey']) ??
            (goalId == null ? null : merged[goalId]?.indicatorKey);
        final resolvedGoalId =
            goalId ??
            (indicatorKey == null
                ? null
                : merged.values
                      .where((record) => record.indicatorKey == indicatorKey)
                      .firstOrNull
                      ?.id);
        if (resolvedGoalId == null || !validGoalIds.contains(resolvedGoalId)) {
          throw const GoalValidationException(
            'Goal backup target references an unknown Goal.',
          );
        }
        final periodType = _backupPeriodType(map['periodType']);
        final periodStart = _requiredBackupString(map, 'periodStartDate');
        final operationId = _backupString(map['operationId']) ?? id;
        await database
            .into(database.indicatorGoalRevisions)
            .insert(
              IndicatorGoalRevisionsCompanion.insert(
                id: id,
                profileId: profileId,
                goalId: Value<String?>(resolvedGoalId),
                indicatorKey: indicatorKey ?? 'goal:$resolvedGoalId',
                periodType: periodType.name,
                periodStartDate: periodStart,
                periodEndDate:
                    _backupString(map['periodEndDate']) ??
                    _periodEndDate(periodType, periodStart),
                state: _backupString(map['state']) ?? 'notSet',
                valueScaled: Value<int?>(_backupInt(map['valueScaled'])),
                valueScale: _backupInt(map['valueScale']) ?? 0,
                unit: _backupString(map['unit']) ?? 'count',
                supersedesRevisionId: Value<String?>(
                  _backupString(map['supersedesRevisionId']),
                ),
                operationId: operationId,
                createdAtUtc: _backupDate(map['createdAtUtc'], clock.nowUtc()),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }

      for (final map in incomingOutbox) {
        final operationId = _backupString(map['operationId']);
        final entityId = _backupString(map['entityId']);
        if (operationId == null ||
            entityId == null ||
            !validGoalIds.contains(entityId)) {
          continue;
        }
        await database
            .into(database.goalOutboxOperations)
            .insert(
              GoalOutboxOperationsCompanion.insert(
                operationId: operationId,
                profileId: profileId,
                entityType: _backupString(map['entityType']) ?? 'goal',
                entityId: entityId,
                action: _backupString(map['action']) ?? 'updated',
                payloadJson: _backupString(map['payloadJson']) ?? '{}',
                createdAtUtc: _backupDate(map['createdAtUtc'], clock.nowUtc()),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }

      // MP-16: an old crossed backup is internally consistent (its stored
      // keys match their current slots) so parser validation cannot detect
      // it. Run the exact history-keyed reconciliation after the immutable
      // creation evidence and targets are imported, before the import
      // transaction returns.
      final postImportGoals = await (database.select(
        database.goals,
      )..where((table) => table.profileId.equals(profileId))).get();
      await _reconcileLegacyBudgetMinisteringCross(
        database,
        profileId,
        goals: postImportGoals,
        nowUtc: clock.nowUtc(),
      );
    }

    if (wrapInTransaction) {
      await database.transaction(operation);
    } else {
      await operation();
    }
  }

  @override
  Future<Map<String, Object?>> exportBackup(String profileId) async {
    final goalBackup = await exportGoalBackup(profileId);
    final tasks =
        await (database.select(database.plannerTasks)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(PlannerTasks)>[
                (table) => OrderingTerm.asc(table.updatedAtUtc),
                (table) => OrderingTerm.asc(table.id),
              ]))
            .get();
    final statusChanges =
        await (database.select(database.taskStatusChanges)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(TaskStatusChanges)>[
                (table) => OrderingTerm.asc(table.changedAtUtc),
                (table) => OrderingTerm.asc(table.id),
              ]))
            .get();
    final contributions =
        await (database.select(database.taskGoalContributions)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(TaskGoalContributions)>[
                (table) => OrderingTerm.asc(table.updatedAtUtc),
                (table) => OrderingTerm.asc(table.id),
              ]))
            .get();
    return <String, Object?>{
      ...goalBackup,
      'format': 'rmplanner.backup.v2',
      'schemaVersion': 2,
      'plannerTasks': <Map<String, Object?>>[
        for (final row in tasks)
          <String, Object?>{
            'id': row.id,
            'title': row.title,
            'notes': row.notes,
            'dueDate': row.dueDate,
            'dueMinute': row.dueMinute,
            'recurrenceFrequency': row.recurrenceFrequency,
            'peopleJson': row.peopleJson,
            'status': row.status,
            'requiresReport': row.requiresReport,
            'contributionRuleKey': row.contributionRuleKey,
            'linkedActivityTypeId': row.linkedActivityTypeId,
            'linkedActivityTypeStableKey': row.linkedActivityTypeStableKey,
            'linkedActivityTypeLabelSnapshot':
                row.linkedActivityTypeLabelSnapshot,
            'goalId': row.goalId,
            'createdAtUtc': row.createdAtUtc.toUtc().toIso8601String(),
            'updatedAtUtc': row.updatedAtUtc.toUtc().toIso8601String(),
          },
      ],
      'taskStatusChanges': <Map<String, Object?>>[
        for (final row in statusChanges)
          <String, Object?>{
            'id': row.id,
            'taskId': row.taskId,
            'operationId': row.operationId,
            'fromStatus': row.fromStatus,
            'toStatus': row.toStatus,
            'reason': row.reason,
            'activityTypeId': row.activityTypeId,
            'activityTypeStableKeySnapshot': row.activityTypeStableKeySnapshot,
            'activityTypeLabelSnapshot': row.activityTypeLabelSnapshot,
            'changedAtUtc': row.changedAtUtc.toUtc().toIso8601String(),
          },
      ],
      'taskGoalContributions': <Map<String, Object?>>[
        for (final row in contributions)
          <String, Object?>{
            'id': row.id,
            'taskId': row.taskId,
            'activityTypeId': row.activityTypeId,
            'activityTypeStableKeySnapshot': row.activityTypeStableKeySnapshot,
            'activityTypeLabelSnapshot': row.activityTypeLabelSnapshot,
            'indicatorKey': row.indicatorKey,
            'valueScaled': row.valueScaled,
            'valueScale': row.valueScale,
            'unit': row.unit,
            'activityDate': row.activityDate,
            'state': row.state,
            'goalId': row.goalId,
            'createdAtUtc': row.createdAtUtc.toUtc().toIso8601String(),
            'updatedAtUtc': row.updatedAtUtc.toUtc().toIso8601String(),
          },
      ],
    };
  }

  @override
  Future<void> importBackup({
    required String profileId,
    required Map<String, Object?> backup,
  }) async {
    final incomingTasks = [
      for (final map in _strictBackupMaps(
        backup['plannerTasks'],
        key: 'plannerTasks',
      ))
        _PlannerTaskBackupRecord.fromMap(map),
    ];
    final incomingStatusChanges = [
      for (final map in _strictBackupMaps(
        backup['taskStatusChanges'],
        key: 'taskStatusChanges',
      ))
        _TaskStatusChangeBackupRecord.fromMap(map),
    ];
    final incomingContributions = [
      for (final map in _strictBackupMaps(
        backup['taskGoalContributions'],
        key: 'taskGoalContributions',
      ))
        _TaskGoalContributionBackupRecord.fromMap(map),
    ];
    _validateUniquePlannerBackupIds(
      incomingTasks: incomingTasks,
      incomingStatusChanges: incomingStatusChanges,
      incomingContributions: incomingContributions,
    );
    await database.transaction(() async {
      await ensureCanonicalGoals(profileId);
      await _importGoalBackupInternal(
        profileId: profileId,
        backup: backup,
        wrapInTransaction: false,
      );
      await _importPlannerBackup(
        profileId: profileId,
        tasks: incomingTasks,
        statusChanges: incomingStatusChanges,
        contributions: incomingContributions,
      );
    });
  }

  Future<void> _importPlannerBackup({
    required String profileId,
    required List<_PlannerTaskBackupRecord> tasks,
    required List<_TaskStatusChangeBackupRecord> statusChanges,
    required List<_TaskGoalContributionBackupRecord> contributions,
  }) async {
    final currentTaskRows = await database.select(database.plannerTasks).get();
    final tasksById = <String, PlannerTaskRow>{
      for (final row in currentTaskRows) row.id: row,
    };
    for (final task in tasks) {
      final existing = tasksById[task.id];
      if (existing != null && existing.profileId != profileId) {
        throw const GoalValidationException(
          'Planner backup references a Task owned by another profile.',
        );
      }
    }
    final validTaskIds = <String>{
      for (final row in currentTaskRows)
        if (row.profileId == profileId) row.id,
      ...tasks.map((task) => task.id),
    };
    final currentStatusRows = await database
        .select(database.taskStatusChanges)
        .get();
    final statusById = <String, TaskStatusChangeRow>{
      for (final row in currentStatusRows) row.id: row,
    };
    final statusByOperation = <String, TaskStatusChangeRow>{
      for (final row in currentStatusRows) row.operationId: row,
    };
    for (final change in statusChanges) {
      if (!validTaskIds.contains(change.taskId)) {
        throw const GoalValidationException(
          'Planner backup status history references an unknown Task.',
        );
      }
      final existingById = statusById[change.id];
      if (existingById != null && existingById.profileId != profileId) {
        throw const GoalValidationException(
          'Planner backup references status history owned by another profile.',
        );
      }
      final existingByOperation = statusByOperation[change.operationId];
      if (existingByOperation != null &&
          (existingByOperation.profileId != profileId ||
              existingByOperation.id != change.id)) {
        throw const GoalValidationException(
          'Planner backup contains a conflicting Task status operation.',
        );
      }
    }

    final currentContributionRows = await database
        .select(database.taskGoalContributions)
        .get();
    final contributionById = <String, TaskGoalContributionRow>{
      for (final row in currentContributionRows) row.id: row,
    };
    final contributionByTask = <String, TaskGoalContributionRow>{
      for (final row in currentContributionRows) row.taskId: row,
    };
    for (final contribution in contributions) {
      if (!validTaskIds.contains(contribution.taskId)) {
        throw const GoalValidationException(
          'Planner backup contribution references an unknown Task.',
        );
      }
      final existingById = contributionById[contribution.id];
      if (existingById != null && existingById.profileId != profileId) {
        throw const GoalValidationException(
          'Planner backup references a contribution owned by another profile.',
        );
      }
      final existingByTask = contributionByTask[contribution.taskId];
      if (existingByTask != null &&
          (existingByTask.profileId != profileId ||
              existingByTask.id != contribution.id)) {
        throw const GoalValidationException(
          'Planner backup contains conflicting contributions for a Task.',
        );
      }
    }

    for (final task in tasks) {
      final existing = tasksById[task.id];
      if (existing == null) {
        await database
            .into(database.plannerTasks)
            .insert(task.toCompanion(profileId));
      } else if (!task.updatedAtUtc.isBefore(existing.updatedAtUtc)) {
        await (database.update(database.plannerTasks)..where(
              (table) =>
                  table.id.equals(task.id) & table.profileId.equals(profileId),
            ))
            .write(task.toUpdateCompanion());
      }
    }

    for (final change in statusChanges) {
      final existingById = statusById[change.id];
      final existingByOperation = statusByOperation[change.operationId];
      if (existingById != null || existingByOperation != null) {
        continue;
      }
      await database
          .into(database.taskStatusChanges)
          .insert(change.toCompanion(profileId));
    }

    for (final contribution in contributions) {
      final existingById = contributionById[contribution.id];
      final existingByTask = contributionByTask[contribution.taskId];
      final existing = existingById ?? existingByTask;
      if (existing == null) {
        await database
            .into(database.taskGoalContributions)
            .insert(contribution.toCompanion(profileId));
      } else if (!contribution.updatedAtUtc.isBefore(existing.updatedAtUtc)) {
        await (database.update(database.taskGoalContributions)..where(
              (table) =>
                  table.id.equals(existing.id) &
                  table.profileId.equals(profileId),
            ))
            .write(contribution.toUpdateCompanion());
      }
    }
  }

  @override
  Future<GoalPlanningSnapshot> readPlanning({
    required String profileId,
    required PlannerDate periodStart,
    PlannerDate? today,
    int startDay = DateTime.monday,
  }) async {
    final goals =
        (await readActiveGoals(
            profileId,
          )).where(_isCanonicalPlanningGoal).toList(growable: true)
          ..sort(_compareCanonicalPlanningGoals);
    final resolvedToday = today ?? periodStart;
    final resolvedWeek = resolveWeek(date: periodStart, startDay: startDay);
    final progress = await _readProgressBatch(
      profileId: profileId,
      goals: goals,
      today: resolvedToday,
      weekStart: resolvedWeek.start,
      startDay: startDay,
    );
    return GoalPlanningSnapshot(
      periodStart: resolvedWeek.start,
      periodEnd: resolvedWeek.end,
      daily: progress
          .where((value) => value.goal.role == GoalRole.dailyWeekly)
          .firstOrNull,
      weekly: progress
          .where((value) => value.goal.role == GoalRole.weekly)
          .toList(growable: false),
      monthly: progress
          .where((value) => value.goal.role == GoalRole.weeklyMonthly)
          .firstOrNull,
    );
  }

  @override
  Future<GoalProgress?> readProgress({
    required String profileId,
    required String goalId,
    required PlannerDate today,
    int startDay = DateTime.monday,
  }) async {
    final goal = await readGoal(profileId: profileId, goalId: goalId);
    if (goal == null) {
      return null;
    }
    return _readProgress(
      goal: goal,
      today: today,
      periodStart: today,
      startDay: startDay,
    );
  }

  Future<GoalProgress> _readProgress({
    required Goal goal,
    required PlannerDate today,
    required PlannerDate periodStart,
    int startDay = DateTime.monday,
  }) async {
    final unit = await _unitForGoal(goal);
    final dailyPeriod = IndicatorGoalPeriod.daily(today);
    final weeklyPeriod = IndicatorGoalPeriod.weekly(
      periodStart,
      startDay: startDay,
    );
    final monthlyPeriod = IndicatorGoalPeriod.monthly(today);
    final daily = await _target(goal, dailyPeriod, unit);
    final weekly = await _target(goal, weeklyPeriod, unit);
    final monthly = await _target(goal, monthlyPeriod, unit);
    return GoalProgress(
      goal: goal,
      dailyActual: await _actual(goal, dailyPeriod.indicatorPeriod, unit),
      dailyTarget: _mapTarget(daily, unit),
      weeklyActual: await _actual(goal, weeklyPeriod.indicatorPeriod, unit),
      weeklyTarget: _mapTarget(weekly, unit),
      monthlyActual: await _actual(goal, monthlyPeriod.indicatorPeriod, unit),
      monthlyTarget: _mapTarget(monthly, unit),
    );
  }

  /// Bounded batch projection backing [readPlanning].  A fixed set of reads
  /// (goals, units, target revisions, ledger/task rows, and Event activity)
  /// replaces the previous per-Goal/per-field serial fan-out while preserving
  /// the exact canonical semantics: explicit vs unset targets, daily/weekly/
  /// monthly boundaries, latest-revision chains, archived/deleted exclusion,
  /// Event cancellation, recurrence occurrence exceptions, Task
  /// contributions, and the configured week start.
  Future<List<GoalProgress>> _readProgressBatch({
    required String profileId,
    required List<Goal> goals,
    required PlannerDate today,
    required PlannerDate weekStart,
    required int startDay,
  }) async {
    if (goals.isEmpty) {
      return const <GoalProgress>[];
    }
    final keys = goals
        .map((goal) => goal.indicatorKey)
        .whereType<String>()
        .toSet();
    final goalIds = goals.map((goal) => goal.id).toSet();
    final unitByKey = <String, String>{};
    if (keys.isNotEmpty) {
      final definitions =
          await (database.select(database.lifeIndicatorDefinitions)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.indicatorKey.isIn(keys),
                ))
              .get();
      unitByKey.addEntries(
        definitions.map((row) => MapEntry(row.indicatorKey, row.unit)),
      );
    }
    String unitFor(Goal goal) {
      final key = goal.indicatorKey;
      return key == null ? 'count' : (unitByKey[key] ?? 'count');
    }

    final dailyPeriod = IndicatorGoalPeriod.daily(today);
    final weeklyPeriod = IndicatorGoalPeriod.weekly(
      weekStart,
      startDay: startDay,
    );
    final monthlyPeriod = IndicatorGoalPeriod.monthly(today);

    // Latest-revision target lookup, batched across every Goal and period.
    // Each row is grouped twice: by Goal (the primary lookup) and by
    // indicator key (the legacy fallback), matching the canonical
    // goal-first, key-fallback resolution exactly.
    final periodStarts = <String>{
      dailyPeriod.start.iso8601,
      weeklyPeriod.start.iso8601,
      monthlyPeriod.start.iso8601,
    };
    final periodTypes = <String>{
      for (final type in IndicatorGoalPeriodType.values) type.name,
    };
    final revisionsByGoalAndPeriod =
        <String, Map<String, List<IndicatorGoalRevisionRow>>>{};
    final revisionsByKeyAndPeriod =
        <String, Map<String, List<IndicatorGoalRevisionRow>>>{};
    if (goalIds.isNotEmpty) {
      final targetRows =
          await (database.select(database.indicatorGoalRevisions)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      (table.goalId.isIn(goalIds) |
                          table.indicatorKey.isIn(keys)) &
                      table.periodType.isIn(periodTypes) &
                      table.periodStartDate.isIn(periodStarts),
                ))
              .get();
      for (final row in targetRows) {
        final periodKey = '${row.periodType}:${row.periodStartDate}';
        final goalId = row.goalId;
        if (goalId != null) {
          final byGoal = revisionsByGoalAndPeriod.putIfAbsent(
            goalId,
            () => <String, List<IndicatorGoalRevisionRow>>{},
          );
          byGoal
              .putIfAbsent(
                periodKey,
                () => <IndicatorGoalRevisionRow>[],
              )
              .add(row);
        }
        if (row.indicatorKey.isNotEmpty) {
          final byKey = revisionsByKeyAndPeriod.putIfAbsent(
            row.indicatorKey,
            () => <String, List<IndicatorGoalRevisionRow>>{},
          );
          byKey
              .putIfAbsent(
                periodKey,
                () => <IndicatorGoalRevisionRow>[],
              )
              .add(row);
        }
      }
    }

    IndicatorGoalRevisionRow? latestTarget({
      required Goal goal,
      required IndicatorGoalPeriod period,
    }) {
      final periodKey = '${period.type.name}:${period.start.iso8601}';
      final byGoal = revisionsByGoalAndPeriod[goal.id]?[periodKey];
      if (byGoal != null && byGoal.isNotEmpty) {
        return _latestTargetRevision(byGoal);
      }
      final key = goal.indicatorKey;
      if (key == null) {
        return null;
      }
      final byIndicator = revisionsByKeyAndPeriod[key]?[periodKey];
      return byIndicator == null || byIndicator.isEmpty
          ? null
          : _latestTargetRevision(byIndicator);
    }

    Future<Map<String, IndicatorAmount>> actualsFor(
      IndicatorGoalPeriod period,
    ) async {
      if (keys.isEmpty) {
        return const <String, IndicatorAmount>{};
      }
      final rows =
          await (database.select(database.activityLedgerEntries)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.isIn(keys) &
                    table.activityDate.isBiggerOrEqualValue(
                      period.start.iso8601,
                    ) &
                    table.activityDate.isSmallerOrEqualValue(
                      period.end.iso8601,
                    ),
              ))
              .get();
      final taskContributions =
          await (database.select(database.taskGoalContributions)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.isIn(keys) &
                    table.activityDate.isBiggerOrEqualValue(
                      period.start.iso8601,
                    ) &
                    table.activityDate.isSmallerOrEqualValue(
                      period.end.iso8601,
                    ) &
                    table.state.equals('active'),
              ))
              .get();
      final activeRows = await _filterActiveLedgerRows(profileId, rows);
      final rowsByKey = <String, List<ActivityLedgerEntryRow>>{};
      for (final row in activeRows) {
        rowsByKey
            .putIfAbsent(row.indicatorKey, () => <ActivityLedgerEntryRow>[])
            .add(row);
      }
      final tasksByKey = <String, List<TaskGoalContributionRow>>{};
      for (final row in taskContributions) {
        tasksByKey
            .putIfAbsent(row.indicatorKey, () => <TaskGoalContributionRow>[])
            .add(row);
      }
      final result = <String, IndicatorAmount>{};
      for (final key in keys) {
        final active = rowsByKey[key] ?? const <ActivityLedgerEntryRow>[];
        final tasks = tasksByKey[key] ?? const <TaskGoalContributionRow>[];
        final unit = unitByKey[key] ?? 'count';
        final scale =
            active.firstOrNull?.valueScale ??
            tasks.firstOrNull?.valueScale ??
            IndicatorUnitPolicy.allowedScale(unit);
        result[key] = IndicatorAmount(
          scaledValue:
              active.fold<int>(0, (sum, row) => sum + row.valueScaled) +
              tasks.fold<int>(0, (sum, row) => sum + row.valueScaled),
          scale: scale,
          unit: unit,
        );
      }
      return result;
    }

    final dailyActuals = await actualsFor(dailyPeriod);
    final weeklyActuals = await actualsFor(weeklyPeriod);
    final monthlyActuals = await actualsFor(monthlyPeriod);

    final progress = <GoalProgress>[];
    for (final goal in goals) {
      final unit = unitFor(goal);
      IndicatorAmount zero() => IndicatorAmount(
        scaledValue: 0,
        scale: IndicatorUnitPolicy.allowedScale(unit),
        unit: unit,
      );
      IndicatorAmount amountFor(
        Map<String, IndicatorAmount> actuals, {
        required String? key,
      }) {
        return key == null ? zero() : (actuals[key] ?? zero());
      }
      final key = goal.indicatorKey;
      progress.add(
        GoalProgress(
          goal: goal,
          dailyActual: amountFor(dailyActuals, key: key),
          dailyTarget: _mapTarget(
            latestTarget(goal: goal, period: dailyPeriod),
            unit,
          ),
          weeklyActual: amountFor(weeklyActuals, key: key),
          weeklyTarget: _mapTarget(
            latestTarget(goal: goal, period: weeklyPeriod),
            unit,
          ),
          monthlyActual: amountFor(monthlyActuals, key: key),
          monthlyTarget: _mapTarget(
            latestTarget(goal: goal, period: monthlyPeriod),
            unit,
          ),
        ),
      );
    }
    return progress;
  }

  /// Batched equivalent of [_eventContributionSourceIsActive].  Returns the
  /// ledger rows whose canonical Event source is still active: event-backed
  /// rows are excluded when their report's Event is cancelled or the specific
  /// recurring occurrence carries a cancelled exception.  Manual/task
  /// sources are intentionally unaffected.
  Future<List<ActivityLedgerEntryRow>> _filterActiveLedgerRows(
    String profileId,
    List<ActivityLedgerEntryRow> rows,
  ) async {
    if (rows.isEmpty) {
      return const <ActivityLedgerEntryRow>[];
    }
    final reportIds = rows.map((row) => row.sourceReportId).toSet();
    final reports =
        await (database.select(database.outcomeReports)
              ..where((table) => table.id.isIn(reportIds)))
            .get();
    final reportById = <String, OutcomeReportRow>{
      for (final report in reports) report.id: report,
    };
    final eventPairs = <(String, String)>[
      for (final report in reports)
        if (report.sourceType == OutcomeSourceType.event.name &&
            report.eventId != null &&
            report.occurrenceId != null)
          (report.eventId!, report.occurrenceId!),
    ];
    final eventIds = eventPairs.map((pair) => pair.$1).toSet();
    final eventsById = <String, CalendarEventRow>{};
    if (eventIds.isNotEmpty) {
      eventsById.addEntries(
        (await (database.select(database.calendarEvents)
              ..where(
                (table) =>
                    table.id.isIn(eventIds) &
                    table.profileId.equals(profileId),
              ))
            .get())
            .map((row) => MapEntry(row.id, row)),
      );
    }
    final exceptionsByPair = <String, CalendarEventExceptionRow>{};
    if (eventPairs.isNotEmpty) {
      final exceptionRows =
          await (database.select(database.calendarEventExceptions)
                ..where((table) {
                  Expression<bool> pairFilter = const Constant<bool>(false);
                  for (final pair in eventPairs) {
                    pairFilter =
                        pairFilter |
                        (table.eventId.equals(pair.$1) &
                            table.occurrenceId.equals(pair.$2));
                  }
                  return pairFilter;
                }))
              .get();
      for (final exception in exceptionRows) {
        final pairKey = '${exception.eventId}:${exception.occurrenceId}';
        final existing = exceptionsByPair[pairKey];
        if (existing == null ||
            exception.createdAtUtc.isAfter(existing.createdAtUtc)) {
          exceptionsByPair[pairKey] = exception;
        }
      }
    }
    final active = <ActivityLedgerEntryRow>[];
    for (final row in rows) {
      final report = reportById[row.sourceReportId];
      if (report == null ||
          report.sourceType != OutcomeSourceType.event.name) {
        active.add(row);
        continue;
      }
      final eventId = report.eventId;
      final occurrenceId = report.occurrenceId;
      if (eventId == null || occurrenceId == null) {
        continue;
      }
      final event = eventsById[eventId];
      if (event == null ||
          event.status == CalendarEventStatus.cancelled.name) {
        continue;
      }
      final exception = exceptionsByPair['$eventId:$occurrenceId'];
      if (exception?.status == CalendarEventStatus.cancelled.name) {
        continue;
      }
      active.add(row);
    }
    return active;
  }

  Future<IndicatorAmount> _actual(
    Goal goal,
    IndicatorPeriod period,
    String unit,
  ) async {
    final key = goal.indicatorKey;
    if (key == null) {
      return IndicatorAmount(
        scaledValue: 0,
        scale: IndicatorUnitPolicy.allowedScale(unit),
        unit: unit,
      );
    }
    final rows =
        await (database.select(database.activityLedgerEntries)..where(
              (table) =>
                  table.profileId.equals(goal.profileId) &
                  table.indicatorKey.equals(key) &
                  table.activityDate.isBiggerOrEqualValue(
                    period.start.iso8601,
                  ) &
                  table.activityDate.isSmallerOrEqualValue(period.end.iso8601),
            ))
            .get();
    final taskContributions =
        await (database.select(database.taskGoalContributions)..where(
              (table) =>
                  table.profileId.equals(goal.profileId) &
                  table.indicatorKey.equals(key) &
                  table.activityDate.isBiggerOrEqualValue(
                    period.start.iso8601,
                  ) &
                  table.activityDate.isSmallerOrEqualValue(period.end.iso8601) &
                  table.state.equals('active'),
            ))
            .get();
    final activeRows = <ActivityLedgerEntryRow>[];
    for (final row in rows) {
      if (await _eventContributionSourceIsActive(row)) {
        activeRows.add(row);
      }
    }
    final scale =
        activeRows.firstOrNull?.valueScale ??
        taskContributions.firstOrNull?.valueScale ??
        IndicatorUnitPolicy.allowedScale(unit);
    return IndicatorAmount(
      scaledValue:
          activeRows.fold<int>(0, (sum, row) => sum + row.valueScaled) +
          taskContributions.fold<int>(0, (sum, row) => sum + row.valueScaled),
      scale: scale,
      unit: unit,
    );
  }

  /// Event-backed ledger facts remain immutable history, but they stop
  /// contributing to current Goal projections when their canonical source
  /// Event (or only that recurring occurrence) is cancelled. Task and manual
  /// sources are intentionally unaffected.
  Future<bool> _eventContributionSourceIsActive(
    ActivityLedgerEntryRow ledger,
  ) async {
    final report =
        await (database.select(database.outcomeReports)
              ..where((table) => table.id.equals(ledger.sourceReportId))
              ..limit(1))
            .getSingleOrNull();
    if (report == null || report.sourceType != OutcomeSourceType.event.name) {
      return true;
    }
    final eventId = report.eventId;
    final occurrenceId = report.occurrenceId;
    if (eventId == null || occurrenceId == null) {
      return false;
    }
    final event =
        await (database.select(database.calendarEvents)
              ..where(
                (table) =>
                    table.id.equals(eventId) &
                    table.profileId.equals(ledger.profileId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (event == null || event.status == CalendarEventStatus.cancelled.name) {
      return false;
    }
    final exception =
        await (database.select(database.calendarEventExceptions)
              ..where(
                (table) =>
                    table.eventId.equals(eventId) &
                    table.occurrenceId.equals(occurrenceId),
              )
              ..orderBy(<OrderingTerm Function(CalendarEventExceptions)>[
                (table) => OrderingTerm.desc(table.createdAtUtc),
              ])
              ..limit(1))
            .getSingleOrNull();
    return exception?.status != CalendarEventStatus.cancelled.name;
  }

  Future<IndicatorGoalRevisionRow?> _target(
    Goal goal,
    IndicatorGoalPeriod period,
    String unit,
  ) async {
    final byGoal =
        await (database.select(database.indicatorGoalRevisions)..where(
              (table) =>
                  table.profileId.equals(goal.profileId) &
                  table.goalId.equals(goal.id) &
                  table.periodType.equals(period.type.name) &
                  table.periodStartDate.equals(period.start.iso8601),
            ))
            .get();
    final currentByGoal = _latestTargetRevision(byGoal);
    if (currentByGoal != null) {
      return currentByGoal;
    }
    final key = goal.indicatorKey;
    if (key == null) {
      return null;
    }
    final byIndicator =
        await (database.select(database.indicatorGoalRevisions)..where(
              (table) =>
                  table.profileId.equals(goal.profileId) &
                  table.indicatorKey.equals(key) &
                  table.periodType.equals(period.type.name) &
                  table.periodStartDate.equals(period.start.iso8601),
            ))
            .get();
    return _latestTargetRevision(byIndicator);
  }

  IndicatorGoalRevisionRow? _latestTargetRevision(
    List<IndicatorGoalRevisionRow> revisions,
  ) {
    if (revisions.isEmpty) {
      return null;
    }
    final supersededIds = revisions
        .map((revision) => revision.supersedesRevisionId)
        .whereType<String>()
        .toSet();
    final leaves = revisions
        .where((revision) => !supersededIds.contains(revision.id))
        .toList();
    final candidates = leaves.isEmpty ? revisions : leaves;
    candidates.sort((left, right) {
      final created = left.createdAtUtc.compareTo(right.createdAtUtc);
      return created != 0 ? created : left.id.compareTo(right.id);
    });
    return candidates.last;
  }

  IndicatorTarget _mapTarget(IndicatorGoalRevisionRow? row, String unit) {
    if (row == null || row.state != 'explicit' || row.valueScaled == null) {
      return const IndicatorTarget.notSet();
    }
    return IndicatorTarget.explicit(
      IndicatorAmount(
        scaledValue: row.valueScaled!,
        scale: row.valueScale,
        unit: row.unit.isEmpty ? unit : row.unit,
      ),
    );
  }

  Future<String> _unitForGoal(Goal goal) async {
    final key = goal.indicatorKey;
    if (key == null) {
      return 'count';
    }
    final row =
        await (database.select(database.lifeIndicatorDefinitions)
              ..where(
                (table) =>
                    table.profileId.equals(goal.profileId) &
                    table.indicatorKey.equals(key),
              )
              ..limit(1))
            .getSingleOrNull();
    return row?.unit ?? 'count';
  }

  Future<int> _freeSlot(String profileId, GoalRole role) async {
    final slot = await _freeSlotOrNull(profileId, role);
    if (slot == null) {
      throw GoalCapacityException(role);
    }
    return slot;
  }

  /// The single canonical slot-allocation function.  Create Goal preview,
  /// validation, and Save all resolve through this so a Goal is never created
  /// in a slot different from the one that was previewed.
  Future<int?> _freeSlotOrNull(String profileId, GoalRole role) async {
    final used =
        (await (database.select(database.goals)..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.status.equals(GoalStatus.active.name),
                ))
                .get())
            .where(_isCanonicalActiveRow)
            .toList(growable: false);
    final slots = switch (role) {
      GoalRole.dailyWeekly => <int>[1],
      GoalRole.weekly => <int>[2, 3, 4, 5],
      GoalRole.weeklyMonthly => <int>[6],
    };
    final available = slots.where(
      (slot) => used.every((row) => row.activeSlotIndex != slot),
    );
    return available.firstOrNull;
  }

  Future<void> _writeTargets({
    required Goal goal,
    required GoalTargets targets,
    required String operationId,
    PlannerDate? today,
    int startDay = DateTime.monday,
  }) async {
    final unit = await _unitForGoal(goal);
    final targetDate = today ?? _today();
    final values = <IndicatorGoalPeriod, IndicatorAmount?>{
      if (goal.role == GoalRole.dailyWeekly)
        IndicatorGoalPeriod.daily(targetDate): targets.daily,
      if (goal.role == GoalRole.dailyWeekly || goal.role == GoalRole.weekly)
        IndicatorGoalPeriod.weekly(
          targetDate,
          startDay: startDay,
        ): targets.weekly,
      if (goal.role ==
          GoalRole.weeklyMonthly) ...<IndicatorGoalPeriod, IndicatorAmount?>{
        IndicatorGoalPeriod.weekly(
          targetDate,
          startDay: startDay,
        ): targets.weekly,
        IndicatorGoalPeriod.monthly(targetDate): targets.monthly,
      },
    };
    for (final entry in values.entries) {
      final value = entry.value;
      if (value != null &&
          (value.scaledValue < 0 ||
              value.unit != unit ||
              value.scale != IndicatorUnitPolicy.allowedScale(unit))) {
        throw const GoalValidationException('Goal target is invalid.');
      }
      final prior = await _target(goal, entry.key, unit);
      final priorValue = prior?.state == 'explicit' ? prior?.valueScaled : null;
      final nextValue = value?.scaledValue;
      if (prior != null && priorValue == nextValue) {
        continue;
      }
      await database
          .into(database.indicatorGoalRevisions)
          .insert(
            IndicatorGoalRevisionsCompanion.insert(
              id: identifiers.nextUuid(),
              profileId: goal.profileId,
              goalId: Value<String?>(goal.id),
              indicatorKey: goal.indicatorKey ?? 'goal:${goal.id}',
              periodType: entry.key.type.name,
              periodStartDate: entry.key.start.iso8601,
              periodEndDate: entry.key.end.iso8601,
              state: value == null ? 'notSet' : 'explicit',
              valueScaled: Value<int?>(value?.scaledValue),
              valueScale:
                  value?.scale ?? IndicatorUnitPolicy.allowedScale(unit),
              unit: unit,
              supersedesRevisionId: Value<String?>(prior?.id),
              operationId:
                  '$operationId:target:${entry.key.type.name}:${entry.key.start.iso8601}',
              createdAtUtc: clock.nowUtc(),
            ),
          );
    }
  }

  Future<void> _ensureCurrentTargetsAfterRestore({
    required Goal goal,
    required String operationId,
    int startDay = DateTime.monday,
  }) async {
    final today = _today();
    final unit = await _unitForGoal(goal);
    final periods = <IndicatorGoalPeriod>[
      if (goal.role == GoalRole.dailyWeekly) IndicatorGoalPeriod.daily(today),
      if (goal.role == GoalRole.dailyWeekly || goal.role == GoalRole.weekly)
        IndicatorGoalPeriod.weekly(today, startDay: startDay),
      if (goal.role == GoalRole.weeklyMonthly) ...<IndicatorGoalPeriod>[
        IndicatorGoalPeriod.weekly(today, startDay: startDay),
        IndicatorGoalPeriod.monthly(today),
      ],
    ];
    for (final period in periods) {
      final current =
          await (database.select(database.indicatorGoalRevisions)
                ..where(
                  (table) =>
                      table.profileId.equals(goal.profileId) &
                      table.goalId.equals(goal.id) &
                      table.periodType.equals(period.type.name) &
                      table.periodStartDate.equals(period.start.iso8601),
                )
                ..orderBy(<OrderingTerm Function(IndicatorGoalRevisions)>[
                  (table) => OrderingTerm.desc(table.createdAtUtc),
                ])
                ..limit(1))
              .getSingleOrNull();
      if (current != null) {
        continue;
      }
      final historical =
          await (database.select(database.indicatorGoalRevisions)
                ..where(
                  (table) =>
                      table.profileId.equals(goal.profileId) &
                      table.goalId.equals(goal.id) &
                      table.periodType.equals(period.type.name) &
                      table.periodStartDate.isSmallerThanValue(
                        period.start.iso8601,
                      ) &
                      table.state.equals('explicit') &
                      table.valueScaled.isNotNull(),
                )
                ..orderBy(<OrderingTerm Function(IndicatorGoalRevisions)>[
                  (table) => OrderingTerm.desc(table.periodStartDate),
                  (table) => OrderingTerm.desc(table.createdAtUtc),
                ])
                ..limit(1))
              .getSingleOrNull();
      if (historical == null) {
        continue;
      }
      await database
          .into(database.indicatorGoalRevisions)
          .insert(
            IndicatorGoalRevisionsCompanion.insert(
              id: identifiers.nextUuid(),
              profileId: goal.profileId,
              goalId: Value<String?>(goal.id),
              indicatorKey: goal.indicatorKey ?? 'goal:${goal.id}',
              periodType: period.type.name,
              periodStartDate: period.start.iso8601,
              periodEndDate: period.end.iso8601,
              state: 'explicit',
              valueScaled: Value<int?>(historical.valueScaled),
              valueScale: historical.valueScale,
              unit: historical.unit.isEmpty ? unit : historical.unit,
              supersedesRevisionId: const Value<String?>(null),
              operationId:
                  '$operationId:restore-target:${period.type.name}:${period.start.iso8601}',
              createdAtUtc: clock.nowUtc(),
            ),
          );
    }
  }

  // Target writes use the repository clock, not wall-clock time from the
  // caller, so daily/monthly boundaries are stable under fake-clock tests.
  PlannerDate _today() => PlannerDate.fromDateTime(clock.nowUtc().toLocal());

  Future<void> _mutateLifecycle({
    required String profileId,
    required String goalId,
    required GoalActivityAction action,
    String? operationId,
  }) async {
    final effectiveOperationId = operationId ?? identifiers.nextUuid();
    await database.transaction(() async {
      final prior = await _goalForOperation(profileId, effectiveOperationId);
      if (prior != null) {
        return;
      }
      final row = await _goalRow(profileId, goalId);
      if (row == null || row.status != GoalStatus.active.name) {
        throw const GoalValidationException('Active Goal was not found.');
      }
      final goal = _mapGoal(row);
      final now = clock.nowUtc();
      await (database.update(database.goals)..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(goalId),
          ))
          .write(
            GoalsCompanion(
              status: Value<String>(GoalStatus.archived.name),
              activeSlotIndex: const Value<int?>(null),
              archivedAtUtc: Value<DateTime?>(now),
              updatedAtUtc: Value<DateTime>(now),
            ),
          );
      final archived = _mapGoal((await _goalRow(profileId, goalId))!);
      await _writeActivity(
        goal: archived,
        action: action,
        operationId: effectiveOperationId,
        newValue: archived.title,
      );
      await _writeOutbox(
        profileId: profileId,
        goalId: goalId,
        operationId: effectiveOperationId,
        action: action.name,
        payload: <String, Object?>{
          'goalId': goalId,
          'title': goal.title,
          'iconId': goal.iconId,
        },
      );
    });
  }

  Future<void> _writeActivity({
    required Goal goal,
    required GoalActivityAction action,
    required String operationId,
    String? previousValue,
    String? newValue,
  }) async {
    await database
        .into(database.goalActivities)
        .insert(
          GoalActivitiesCompanion.insert(
            id: identifiers.nextUuid(),
            profileId: goal.profileId,
            goalId: goal.id,
            operationId: operationId,
            action: action.name,
            previousValue: Value<String?>(previousValue),
            newValue: Value<String?>(newValue),
            occurredAtUtc: clock.nowUtc(),
          ),
        );
  }

  Future<void> _writeOutbox({
    required String profileId,
    required String goalId,
    required String operationId,
    required String action,
    required Map<String, Object?> payload,
  }) async {
    await database
        .into(database.goalOutboxOperations)
        .insert(
          GoalOutboxOperationsCompanion.insert(
            operationId: operationId,
            profileId: profileId,
            entityType: 'goal',
            entityId: goalId,
            action: action,
            payloadJson: jsonEncode(payload),
            createdAtUtc: clock.nowUtc(),
          ),
        );
  }

  Future<Goal?> _goalForOperation(String profileId, String operationId) async {
    final operation =
        await (database.select(database.goalOutboxOperations)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.operationId.equals(operationId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (operation == null) {
      return null;
    }
    final row = await _goalRow(profileId, operation.entityId);
    return row == null ? null : _mapGoal(row);
  }

  Future<GoalRow?> _goalRow(String profileId, String goalId) {
    return (database.select(database.goals)
          ..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(goalId),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<Map<String, GoalRow>> _goalMappings(String profileId) async {
    final rows = await (database.select(
      database.goals,
    )..where((table) => table.profileId.equals(profileId))).get();
    return <String, GoalRow>{
      for (final row in rows)
        if (row.indicatorKey != null) row.indicatorKey!: row,
    };
  }

  Goal _mapGoal(GoalRow row) {
    return Goal(
      id: row.id,
      profileId: row.profileId,
      indicatorKey: row.indicatorKey,
      assignedEventTypeStableKey: row.assignedEventTypeStableKey,
      role: _roleFromName(row.role),
      activeSlotIndex: row.activeSlotIndex,
      title: row.title,
      iconId: row.iconId,
      status: switch (row.status) {
        'archived' => GoalStatus.archived,
        'deleted' => GoalStatus.deleted,
        _ => GoalStatus.active,
      },
      createdAtUtc: row.createdAtUtc.toUtc(),
      updatedAtUtc: row.updatedAtUtc.toUtc(),
      archivedAtUtc: row.archivedAtUtc?.toUtc(),
      deletedAtUtc: row.deletedAtUtc?.toUtc(),
    );
  }

  GoalActivity _mapActivity(GoalActivityRow row) {
    return GoalActivity(
      id: row.id,
      profileId: row.profileId,
      goalId: row.goalId,
      operationId: row.operationId,
      action: GoalActivityAction.values.firstWhere(
        (value) => value.name == row.action,
        orElse: () => GoalActivityAction.created,
      ),
      previousValue: row.previousValue,
      newValue: row.newValue,
      occurredAtUtc: row.occurredAtUtc.toUtc(),
    );
  }

  GoalsCompanion _goalCompanion(Goal goal) {
    return GoalsCompanion.insert(
      id: goal.id,
      profileId: goal.profileId,
      indicatorKey: Value<String?>(goal.indicatorKey),
      assignedEventTypeStableKey: Value<String?>(
        goal.assignedEventTypeStableKey,
      ),
      role: goal.role.storageName,
      activeSlotIndex: Value<int?>(goal.activeSlotIndex),
      title: goal.title,
      iconId: Value<String?>(goal.iconId),
      status: goal.status.name,
      createdAtUtc: goal.createdAtUtc,
      updatedAtUtc: goal.updatedAtUtc,
      archivedAtUtc: Value<DateTime?>(goal.archivedAtUtc),
      deletedAtUtc: Value<DateTime?>(goal.deletedAtUtc),
    );
  }

  GoalRole _roleFromName(String value) {
    return GoalRole.values.firstWhere(
      (role) => role.storageName == value,
      orElse: () => GoalRole.weekly,
    );
  }

  bool _isCanonicalActiveRow(GoalRow row) {
    final slot = row.activeSlotIndex;
    return row.status == GoalStatus.active.name &&
        slot != null &&
        _slotSupportsRole(_roleFromName(row.role), slot);
  }

  Map<String, Object?> _targetsPayload(GoalTargets targets) {
    return <String, Object?>{
      'daily': targets.daily?.scaledValue,
      'weekly': targets.weekly?.scaledValue,
      'monthly': targets.monthly?.scaledValue,
    };
  }

}

bool _isCanonicalPlanningGoal(Goal goal) {
  final slot = goal.activeSlotIndex;
  return goal.isActive && slot != null && _slotSupportsRole(goal.role, slot);
}

int _compareCanonicalPlanningGoals(Goal left, Goal right) {
  final roleOrder = <GoalRole, int>{
    GoalRole.dailyWeekly: 0,
    GoalRole.weekly: 1,
    GoalRole.weeklyMonthly: 2,
  };
  final roleComparison = roleOrder[left.role]!.compareTo(
    roleOrder[right.role]!,
  );
  if (roleComparison != 0) {
    return roleComparison;
  }
  final slotComparison = left.activeSlotIndex!.compareTo(
    right.activeSlotIndex!,
  );
  return slotComparison != 0 ? slotComparison : left.id.compareTo(right.id);
}

Map<String, Object?> _exportGoalTarget({
  required String id,
  required String goalId,
  required String indicatorKey,
  required String periodType,
  required String periodStartDate,
  required String periodEndDate,
  required String state,
  required int? valueScaled,
  required int valueScale,
  required String unit,
  required String? supersedesRevisionId,
  required String operationId,
  required DateTime createdAtUtc,
}) {
  return <String, Object?>{
    'id': id,
    'goalId': goalId,
    'indicatorKey': indicatorKey,
    'periodType': periodType,
    'periodStartDate': periodStartDate,
    'periodEndDate': periodEndDate,
    'state': state,
    'valueScaled': valueScaled,
    'valueScale': valueScale,
    'unit': unit,
    'supersedesRevisionId': supersedesRevisionId,
    'operationId': operationId,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
  };
}

String _periodEndDate(IndicatorGoalPeriodType type, String startDate) {
  final start = PlannerDate.fromDateTime(DateTime.parse(startDate));
  return switch (type) {
    IndicatorGoalPeriodType.daily => start.iso8601,
    IndicatorGoalPeriodType.weekly => start.addDays(6).iso8601,
    IndicatorGoalPeriodType.monthly => IndicatorGoalPeriod.monthly(
      start,
    ).end.iso8601,
  };
}

List<Map<String, Object?>> _backupMaps(Object? value) {
  if (value is! List) {
    return const <Map<String, Object?>>[];
  }
  return value
      .whereType<Map>()
      .map(
        (row) => <String, Object?>{
          for (final entry in row.entries)
            if (entry.key is String) entry.key as String: entry.value,
        },
      )
      .toList(growable: false);
}

String? _backupString(Object? value) {
  if (value is String) {
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }
  return null;
}

String _requiredBackupString(Map<String, Object?> map, String key) {
  final value = _backupString(map[key]);
  if (value == null) {
    throw GoalValidationException('Goal backup is missing "$key".');
  }
  return value;
}

int? _backupInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return value is String ? int.tryParse(value) : null;
}

DateTime _backupDate(Object? value, DateTime fallback) {
  if (value is DateTime) {
    return value.toUtc();
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed.toUtc();
    }
  }
  return fallback.toUtc();
}

IndicatorGoalPeriodType _backupPeriodType(Object? value) {
  final name = _backupString(value);
  for (final periodType in IndicatorGoalPeriodType.values) {
    if (periodType.name == name) {
      return periodType;
    }
  }
  throw const GoalValidationException(
    'Goal backup has an invalid period type.',
  );
}

GoalRole _backupRole(Object? value) {
  final name = _backupString(value);
  for (final role in GoalRole.values) {
    if (role.storageName == name) {
      return role;
    }
  }
  throw const GoalValidationException('Goal backup has an invalid Goal role.');
}

GoalStatus _backupStatus(Map<String, Object?> map) {
  if (map['isArchived'] == true) {
    return GoalStatus.archived;
  }
  final value = _backupString(map['status']);
  if (value == GoalStatus.archived.name) {
    return GoalStatus.archived;
  }
  if (value == GoalStatus.deleted.name) {
    return GoalStatus.deleted;
  }
  return GoalStatus.active;
}

bool _slotSupportsRole(GoalRole role, int slot) {
  return switch (role) {
    GoalRole.dailyWeekly => slot == 1,
    GoalRole.weekly => slot >= 2 && slot <= 5,
    GoalRole.weeklyMonthly => slot == 6,
  };
}

void _validateBackupOccupancy(Iterable<_BackupGoalRecord> records) {
  final active = records.where((record) => record.status == GoalStatus.active);
  final owners = <int, String>{};
  final counts = <GoalRole, int>{for (final role in GoalRole.values) role: 0};
  for (final record in active) {
    final slot = record.activeSlotIndex;
    if (slot == null || !_slotSupportsRole(record.role, slot)) {
      throw GoalValidationException(
        'Goal "${record.title}" has an incompatible active slot.',
      );
    }
    final prior = owners[slot];
    if (prior != null && prior != record.id) {
      throw const GoalValidationException(
        'Goal backup contains a conflicting active slot.',
      );
    }
    owners[slot] = record.id;
    counts[record.role] = (counts[record.role] ?? 0) + 1;
  }
  for (final role in GoalRole.values) {
    if ((counts[role] ?? 0) > role.capacity) {
      throw GoalCapacityException(role);
    }
  }
}

final class _BackupGoalRecord {
  const _BackupGoalRecord({
    required this.id,
    required this.indicatorKey,
    required this.assignedEventTypeStableKey,
    required this.role,
    required this.activeSlotIndex,
    required this.title,
    required this.iconId,
    required this.status,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    required this.archivedAtUtc,
    required this.deletedAtUtc,
  });

  final String id;
  final String? indicatorKey;
  final String? assignedEventTypeStableKey;
  final GoalRole role;
  final int? activeSlotIndex;
  final String title;
  final String? iconId;
  final GoalStatus status;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? archivedAtUtc;
  final DateTime? deletedAtUtc;

  factory _BackupGoalRecord.fromGoal(Goal goal) {
    return _BackupGoalRecord(
      id: goal.id,
      indicatorKey: goal.indicatorKey,
      assignedEventTypeStableKey: goal.assignedEventTypeStableKey,
      role: goal.role,
      activeSlotIndex: goal.activeSlotIndex,
      title: goal.title,
      iconId: goal.iconId,
      status: goal.status,
      createdAtUtc: goal.createdAtUtc,
      updatedAtUtc: goal.updatedAtUtc,
      archivedAtUtc: goal.archivedAtUtc,
      deletedAtUtc: goal.deletedAtUtc,
    );
  }

  factory _BackupGoalRecord.fromMap(
    Map<String, Object?> map, {
    required DateTime fallbackNowUtc,
  }) {
    final id = _requiredBackupString(map, 'id');
    final role = _backupRole(map['role']);
    final status = _backupStatus(map);
    final title = _requiredBackupString(map, 'title');
    final requestedSlot = _backupInt(
      map['activeSlotIndex'] ?? map['activeSlot'] ?? map['slot'],
    );
    final slot = status == GoalStatus.active
        ? requestedSlot ?? (role == GoalRole.weekly ? null : role.slotIndex)
        : null;
    if (status == GoalStatus.active && slot == null) {
      throw GoalValidationException(
        'Active Weekly Goal "$title" is missing its slot.',
      );
    }
    if (slot != null && !_slotSupportsRole(role, slot)) {
      throw GoalValidationException(
        'Goal "$title" has an incompatible active slot.',
      );
    }
    final indicatorKey = _backupString(map['indicatorKey']);
    final requestedAssignment = _backupString(
      map['assignedEventTypeStableKey'],
    );
    final canonical =
        CanonicalGoalSlot.tryByEventTypeKey(requestedAssignment) ??
        CanonicalGoalSlot.tryByIndicatorKey(indicatorKey) ??
        (slot == null
            ? null
            : CanonicalGoalSlot.tryByEventTypeKey(
                CanonicalGoalSlot.bySlot(slot).eventTypeStableKey,
              ));
    if (canonical == null ||
        canonical.role != role ||
        (indicatorKey != null && indicatorKey != canonical.indicatorKey) ||
        (slot != null && slot != canonical.slotIndex)) {
      throw GoalValidationException(
        'Goal "$title" has an invalid fixed Event Type assignment.',
      );
    }
    final created = _backupDate(map['createdAtUtc'], fallbackNowUtc);
    return _BackupGoalRecord(
      id: id,
      indicatorKey: canonical.indicatorKey,
      assignedEventTypeStableKey: canonical.eventTypeStableKey,
      role: role,
      activeSlotIndex: slot,
      title: title,
      iconId: _backupString(map['iconId']),
      status: status,
      createdAtUtc: created,
      updatedAtUtc: _backupDate(map['updatedAtUtc'], created),
      archivedAtUtc: status == GoalStatus.archived
          ? _backupDateOrNull(map['archivedAtUtc']) ?? created
          : null,
      deletedAtUtc: status == GoalStatus.deleted
          ? _backupDateOrNull(map['deletedAtUtc']) ?? created
          : null,
    );
  }

  Goal toGoal(String profileId) {
    return Goal(
      id: id,
      profileId: profileId,
      indicatorKey: indicatorKey,
      assignedEventTypeStableKey: assignedEventTypeStableKey,
      role: role,
      activeSlotIndex: activeSlotIndex,
      title: title,
      iconId: iconId,
      status: status,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc,
      archivedAtUtc: archivedAtUtc,
      deletedAtUtc: deletedAtUtc,
    );
  }
}

DateTime? _backupDateOrNull(Object? value) {
  if (value is DateTime) {
    return value.toUtc();
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    return parsed?.toUtc();
  }
  return null;
}

List<Map<String, Object?>> _strictBackupMaps(
  Object? value, {
  required String key,
}) {
  if (value == null) {
    return const <Map<String, Object?>>[];
  }
  if (value is! List) {
    throw GoalValidationException('Planner backup field "$key" is invalid.');
  }
  final maps = <Map<String, Object?>>[];
  for (final row in value) {
    if (row is! Map) {
      throw GoalValidationException(
        'Planner backup field "$key" contains an invalid row.',
      );
    }
    maps.add(<String, Object?>{
      for (final entry in row.entries)
        if (entry.key is String) entry.key as String: entry.value,
    });
  }
  return maps;
}

void _validateUniquePlannerBackupIds({
  required List<_PlannerTaskBackupRecord> incomingTasks,
  required List<_TaskStatusChangeBackupRecord> incomingStatusChanges,
  required List<_TaskGoalContributionBackupRecord> incomingContributions,
}) {
  final taskIds = <String>{};
  for (final task in incomingTasks) {
    if (!taskIds.add(task.id)) {
      throw const GoalValidationException(
        'Planner backup contains duplicate Task IDs.',
      );
    }
  }
  final statusIds = <String>{};
  final statusOperations = <String>{};
  for (final change in incomingStatusChanges) {
    if (!statusIds.add(change.id) ||
        !statusOperations.add(change.operationId)) {
      throw const GoalValidationException(
        'Planner backup contains duplicate Task status operations.',
      );
    }
  }
  final contributionIds = <String>{};
  final contributionTasks = <String>{};
  for (final contribution in incomingContributions) {
    if (!contributionIds.add(contribution.id) ||
        !contributionTasks.add(contribution.taskId)) {
      throw const GoalValidationException(
        'Planner backup contains duplicate Task contributions.',
      );
    }
  }
}

final class _PlannerTaskBackupRecord {
  const _PlannerTaskBackupRecord({
    required this.id,
    required this.title,
    required this.notes,
    required this.dueDate,
    required this.dueMinute,
    required this.recurrenceFrequency,
    required this.peopleJson,
    required this.status,
    required this.requiresReport,
    required this.contributionRuleKey,
    required this.linkedActivityTypeId,
    required this.linkedActivityTypeStableKey,
    required this.linkedActivityTypeLabelSnapshot,
    required this.goalId,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String title;
  final String? notes;
  final String? dueDate;
  final int? dueMinute;
  final String recurrenceFrequency;
  final String peopleJson;
  final String status;
  final bool requiresReport;
  final String? contributionRuleKey;
  final String? linkedActivityTypeId;
  final String? linkedActivityTypeStableKey;
  final String? linkedActivityTypeLabelSnapshot;
  final String? goalId;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  factory _PlannerTaskBackupRecord.fromMap(Map<String, Object?> map) {
    final id = _requiredBackupString(map, 'id');
    final title = _requiredBackupString(map, 'title');
    final dueDate = _backupString(map['dueDate']);
    if (dueDate != null) {
      _validatePlannerDate(dueDate, field: 'dueDate');
    }
    final dueMinute = _backupInt(map['dueMinute']);
    if (dueMinute != null && (dueMinute < 0 || dueMinute > 1439)) {
      throw const GoalValidationException(
        'Planner backup contains an invalid Task due time.',
      );
    }
    final recurrenceFrequency = _backupEnumName(
      map['recurrenceFrequency'],
      field: 'recurrenceFrequency',
      allowed: PlannerTaskRecurrence.values.map((value) => value.name),
      fallback: PlannerTaskRecurrence.none.name,
    );
    final status = _backupEnumName(
      map['status'],
      field: 'status',
      allowed: PlannerTaskStatus.values.map((value) => value.name),
      fallback: PlannerTaskStatus.incomplete.name,
    );
    final stableKey = _backupString(map['linkedActivityTypeStableKey']);
    _validateCanonicalTaskType(stableKey);
    return _PlannerTaskBackupRecord(
      id: id,
      title: title,
      notes: _backupString(map['notes']),
      dueDate: dueDate,
      dueMinute: dueMinute,
      recurrenceFrequency: recurrenceFrequency,
      peopleJson: _backupPeopleJson(map['peopleJson'] ?? map['people']),
      status: status,
      requiresReport: _backupBool(
        map['requiresReport'],
        field: 'requiresReport',
        fallback: false,
      ),
      contributionRuleKey: _backupString(map['contributionRuleKey']),
      linkedActivityTypeId: _backupString(map['linkedActivityTypeId']),
      linkedActivityTypeStableKey: stableKey,
      linkedActivityTypeLabelSnapshot: _backupString(
        map['linkedActivityTypeLabelSnapshot'],
      ),
      goalId: _backupString(map['goalId']),
      createdAtUtc: _requiredBackupDate(map, 'createdAtUtc'),
      updatedAtUtc: _requiredBackupDate(map, 'updatedAtUtc'),
    );
  }

  PlannerTasksCompanion toCompanion(String profileId) {
    return PlannerTasksCompanion.insert(
      id: id,
      profileId: profileId,
      title: title,
      notes: Value<String?>(notes),
      dueDate: Value<String?>(dueDate),
      dueMinute: Value<int?>(dueMinute),
      recurrenceFrequency: Value<String>(recurrenceFrequency),
      peopleJson: Value<String>(peopleJson),
      status: Value<String>(status),
      requiresReport: Value<bool>(requiresReport),
      contributionRuleKey: Value<String?>(contributionRuleKey),
      linkedActivityTypeId: Value<String?>(linkedActivityTypeId),
      linkedActivityTypeStableKey: Value<String?>(linkedActivityTypeStableKey),
      linkedActivityTypeLabelSnapshot: Value<String?>(
        linkedActivityTypeLabelSnapshot,
      ),
      goalId: Value<String?>(goalId),
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc,
    );
  }

  PlannerTasksCompanion toUpdateCompanion() {
    return PlannerTasksCompanion(
      title: Value<String>(title),
      notes: Value<String?>(notes),
      dueDate: Value<String?>(dueDate),
      dueMinute: Value<int?>(dueMinute),
      recurrenceFrequency: Value<String>(recurrenceFrequency),
      peopleJson: Value<String>(peopleJson),
      status: Value<String>(status),
      requiresReport: Value<bool>(requiresReport),
      contributionRuleKey: Value<String?>(contributionRuleKey),
      linkedActivityTypeId: Value<String?>(linkedActivityTypeId),
      linkedActivityTypeStableKey: Value<String?>(linkedActivityTypeStableKey),
      linkedActivityTypeLabelSnapshot: Value<String?>(
        linkedActivityTypeLabelSnapshot,
      ),
      goalId: Value<String?>(goalId),
      updatedAtUtc: Value<DateTime>(updatedAtUtc),
    );
  }
}

final class _TaskStatusChangeBackupRecord {
  const _TaskStatusChangeBackupRecord({
    required this.id,
    required this.taskId,
    required this.operationId,
    required this.fromStatus,
    required this.toStatus,
    required this.reason,
    required this.activityTypeId,
    required this.activityTypeStableKeySnapshot,
    required this.activityTypeLabelSnapshot,
    required this.changedAtUtc,
  });

  final String id;
  final String taskId;
  final String operationId;
  final String fromStatus;
  final String toStatus;
  final String? reason;
  final String? activityTypeId;
  final String? activityTypeStableKeySnapshot;
  final String? activityTypeLabelSnapshot;
  final DateTime changedAtUtc;

  factory _TaskStatusChangeBackupRecord.fromMap(Map<String, Object?> map) {
    final stableKey = _backupString(map['activityTypeStableKeySnapshot']);
    _validateCanonicalTaskType(stableKey);
    return _TaskStatusChangeBackupRecord(
      id: _requiredBackupString(map, 'id'),
      taskId: _requiredBackupString(map, 'taskId'),
      operationId:
          _backupString(map['operationId']) ?? _requiredBackupString(map, 'id'),
      fromStatus: _backupEnumName(
        map['fromStatus'],
        field: 'fromStatus',
        allowed: PlannerTaskStatus.values.map((value) => value.name),
        fallback: PlannerTaskStatus.incomplete.name,
      ),
      toStatus: _backupEnumName(
        map['toStatus'],
        field: 'toStatus',
        allowed: PlannerTaskStatus.values.map((value) => value.name),
        fallback: PlannerTaskStatus.incomplete.name,
      ),
      reason: _backupString(map['reason']),
      activityTypeId: _backupString(map['activityTypeId']),
      activityTypeStableKeySnapshot: stableKey,
      activityTypeLabelSnapshot: _backupString(
        map['activityTypeLabelSnapshot'],
      ),
      changedAtUtc: _requiredBackupDate(map, 'changedAtUtc'),
    );
  }

  TaskStatusChangesCompanion toCompanion(String profileId) {
    return TaskStatusChangesCompanion.insert(
      id: id,
      profileId: profileId,
      taskId: taskId,
      operationId: operationId,
      fromStatus: fromStatus,
      toStatus: toStatus,
      reason: Value<String?>(reason),
      activityTypeId: Value<String?>(activityTypeId),
      activityTypeStableKeySnapshot: Value<String?>(
        activityTypeStableKeySnapshot,
      ),
      activityTypeLabelSnapshot: Value<String?>(activityTypeLabelSnapshot),
      changedAtUtc: changedAtUtc,
    );
  }
}

final class _TaskGoalContributionBackupRecord {
  const _TaskGoalContributionBackupRecord({
    required this.id,
    required this.taskId,
    required this.activityTypeId,
    required this.activityTypeStableKeySnapshot,
    required this.activityTypeLabelSnapshot,
    required this.indicatorKey,
    required this.valueScaled,
    required this.valueScale,
    required this.unit,
    required this.activityDate,
    required this.state,
    required this.goalId,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String taskId;
  final String? activityTypeId;
  final String? activityTypeStableKeySnapshot;
  final String? activityTypeLabelSnapshot;
  final String indicatorKey;
  final int valueScaled;
  final int valueScale;
  final String unit;
  final String activityDate;
  final String state;
  final String? goalId;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;

  factory _TaskGoalContributionBackupRecord.fromMap(Map<String, Object?> map) {
    final stableKey = _backupString(map['activityTypeStableKeySnapshot']);
    _validateCanonicalTaskType(stableKey);
    final indicatorKey = _requiredBackupString(map, 'indicatorKey');
    if (CanonicalGoalSlot.tryByIndicatorKey(indicatorKey) == null) {
      throw const GoalValidationException(
        'Planner backup contains a non-canonical Task contribution.',
      );
    }
    final activityDate = _requiredBackupString(map, 'activityDate');
    _validatePlannerDate(activityDate, field: 'activityDate');
    final state = _backupEnumName(
      map['state'],
      field: 'state',
      allowed: const <String>['active', 'reversed'],
      fallback: 'active',
    );
    final valueScaled = _backupInt(map['valueScaled']) ?? 1;
    final valueScale = _backupInt(map['valueScale']) ?? 0;
    if (valueScaled < 0 || valueScale < 0) {
      throw const GoalValidationException(
        'Planner backup contains an invalid Task contribution amount.',
      );
    }
    return _TaskGoalContributionBackupRecord(
      id: _requiredBackupString(map, 'id'),
      taskId: _requiredBackupString(map, 'taskId'),
      activityTypeId: _backupString(map['activityTypeId']),
      activityTypeStableKeySnapshot: stableKey,
      activityTypeLabelSnapshot: _backupString(
        map['activityTypeLabelSnapshot'],
      ),
      indicatorKey: indicatorKey,
      valueScaled: valueScaled,
      valueScale: valueScale,
      unit: _backupString(map['unit']) ?? 'count',
      activityDate: activityDate,
      state: state,
      goalId: _backupString(map['goalId']),
      createdAtUtc: _requiredBackupDate(map, 'createdAtUtc'),
      updatedAtUtc: _requiredBackupDate(map, 'updatedAtUtc'),
    );
  }

  TaskGoalContributionsCompanion toCompanion(String profileId) {
    return TaskGoalContributionsCompanion.insert(
      id: id,
      profileId: profileId,
      taskId: taskId,
      activityTypeId: Value<String?>(activityTypeId),
      activityTypeStableKeySnapshot: Value<String?>(
        activityTypeStableKeySnapshot,
      ),
      activityTypeLabelSnapshot: Value<String?>(activityTypeLabelSnapshot),
      indicatorKey: indicatorKey,
      valueScaled: Value<int>(valueScaled),
      valueScale: Value<int>(valueScale),
      unit: Value<String>(unit),
      activityDate: activityDate,
      state: Value<String>(state),
      goalId: Value<String?>(goalId),
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc,
    );
  }

  TaskGoalContributionsCompanion toUpdateCompanion() {
    return TaskGoalContributionsCompanion(
      taskId: Value<String>(taskId),
      activityTypeId: Value<String?>(activityTypeId),
      activityTypeStableKeySnapshot: Value<String?>(
        activityTypeStableKeySnapshot,
      ),
      activityTypeLabelSnapshot: Value<String?>(activityTypeLabelSnapshot),
      indicatorKey: Value<String>(indicatorKey),
      valueScaled: Value<int>(valueScaled),
      valueScale: Value<int>(valueScale),
      unit: Value<String>(unit),
      activityDate: Value<String>(activityDate),
      state: Value<String>(state),
      goalId: Value<String?>(goalId),
      updatedAtUtc: Value<DateTime>(updatedAtUtc),
    );
  }
}

String _backupEnumName(
  Object? value, {
  required String field,
  required Iterable<String> allowed,
  required String fallback,
}) {
  final name = _backupString(value) ?? fallback;
  if (!allowed.contains(name)) {
    throw GoalValidationException('Planner backup has an invalid "$field".');
  }
  return name;
}

bool _backupBool(
  Object? value, {
  required String field,
  required bool fallback,
}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  throw GoalValidationException('Planner backup has an invalid "$field".');
}

DateTime _requiredBackupDate(Map<String, Object?> map, String field) {
  final value = _backupDateOrNull(map[field]);
  if (value == null) {
    throw GoalValidationException('Planner backup is missing "$field".');
  }
  return value;
}

String _backupPeopleJson(Object? value) {
  if (value == null) return '[]';
  Object? decoded = value;
  if (value is String) {
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      throw const GoalValidationException(
        'Planner backup contains invalid Task people data.',
      );
    }
  }
  if (decoded is! List || decoded.any((person) => person is! String)) {
    throw const GoalValidationException(
      'Planner backup contains invalid Task people data.',
    );
  }
  return jsonEncode(decoded);
}

void _validateCanonicalTaskType(String? stableKey) {
  if (stableKey != null &&
      CanonicalGoalSlot.tryByEventTypeKey(stableKey) == null) {
    throw const GoalValidationException(
      'Planner backup contains a non-canonical linked Event Type.',
    );
  }
}

void _validatePlannerDate(String value, {required String field}) {
  try {
    PlannerDate.parse(value);
  } on Object {
    throw GoalValidationException(
      'Planner backup contains an invalid "$field".',
    );
  }
}
