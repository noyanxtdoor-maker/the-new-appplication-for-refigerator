import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/goals/data/live_goal_event_type_bindings.dart';
import 'package:rmplanner/features/goals/domain/assigned_event_type_draft.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal_event_type_policy.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/data/planner_presentation_document_store.dart';
import 'package:rmplanner/features/planner/domain/event_color_math.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';
import 'package:rmplanner/features/planner/domain/recommended_event_colors.dart';

/// Sanitized Education backfill failure (identity conflict or accent
/// collision). Carries no row data and is safe to surface; the surrounding
/// `_ensureSystemTypes` transaction rolls back so no partial seed lands and
/// no conflicting row is renamed, merged, deleted, or regenerated.
final class EducationBackfillException implements Exception {
  const EducationBackfillException(this.message);

  final String message;

  @override
  String toString() => 'EducationBackfillException: $message';
}

final class DriftEventTypeRepository implements EventTypeRepository {
  const DriftEventTypeRepository({
    required this.database,
    required this.clock,
    this.reminderRepair,
  });

  final AppDatabase database;
  final AppClock clock;

  /// M7 section 27 repair-intent port.  Used ONLY for a change to the
  /// profile's global reminder default, because that default governs the
  /// inherited timing of every reminder that has not overridden it.  Event
  /// Type / colour / name architecture is deliberately NOT touched here
  /// (contract section 53 P33).
  final ReminderRecoveryRequest? reminderRepair;

  @override
  Future<List<EventType>> readEventTypes({
    required String profileId,
    bool includeArchived = false,
  }) async {
    await _ensureSystemTypes(profileId);
    final rows =
        await (database.select(database.activityTypes)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    (includeArchived
                        ? const Constant(true)
                        : table.isArchived.equals(false)),
              )
              ..orderBy(<OrderingTerm Function(ActivityTypes)>[
                (table) => OrderingTerm.asc(table.position),
                (table) => OrderingTerm.asc(table.label),
              ]))
            .get();
    final mappings = await _readMappings(profileId);
    final mappedRows = rows
        .map(
          (row) => _map(
            row,
            mappings[_mappingRevisionKey(row.id, row.mappingVersion)] ??
                const <String>{},
          ),
        )
        .toList();
    final creationOrder = <String, int>{
      for (
        var index = 0;
        index < SystemEventTypeKeys.approvedCreationOrder.length;
        index += 1
      )
        SystemEventTypeKeys.approvedCreationOrder[index]: index,
    };
    mappedRows.sort((left, right) {
      final leftCreationOrder = creationOrder[left.stableKey];
      final rightCreationOrder = creationOrder[right.stableKey];
      if (leftCreationOrder != null || rightCreationOrder != null) {
        if (leftCreationOrder == null) return 1;
        if (rightCreationOrder == null) return -1;
        return leftCreationOrder.compareTo(rightCreationOrder);
      }
      final position = left.position.compareTo(right.position);
      return position == 0 ? left.label.compareTo(right.label) : position;
    });
    return List<EventType>.unmodifiable(mappedRows);
  }

  @override
  Future<EventType?> readEventType({
    required String profileId,
    required String eventTypeId,
  }) async {
    await _ensureSystemTypes(profileId);
    final row =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.equals(eventTypeId),
            ))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    final mappings = await _readMappings(profileId);
    return _map(
      row,
      mappings[_mappingRevisionKey(row.id, row.mappingVersion)] ??
          const <String>{},
    );
  }

  @override
  Future<EventType?> readExactTypeForIndicator({
    required String profileId,
    required String indicatorKey,
  }) async {
    final types = await readEventTypes(profileId: profileId);
    final matches = types
        .where(
          (type) =>
              type.isSystem &&
              type.indicatorKeys.length == 1 &&
              type.indicatorKeys.single == indicatorKey,
        )
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  @override
  Future<EventType> saveCustomType({
    required String profileId,
    required EventTypeDraft draft,
  }) async {
    final label = draft.label.trim();
    if (label.isEmpty) {
      throw ArgumentError.value(draft.label, 'label', 'Label is required.');
    }
    if (draft.defaultDurationMinutes < 15 ||
        draft.defaultDurationMinutes > 24 * 60) {
      throw ArgumentError.value(
        draft.defaultDurationMinutes,
        'defaultDurationMinutes',
      );
    }
    await _ensureSystemTypes(profileId);
    await _ensureUniqueActiveEventTypeAccent(
      profileId: profileId,
      eventTypeStableKey: 'custom:${draft.id}',
      proposedAccentArgb: draft.colorValue,
    );
    return database.transaction(() async {
      final existing =
          await (database.select(database.activityTypes)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(draft.id),
              ))
              .getSingleOrNull();
      if (existing?.isSystem ?? false) {
        throw StateError('System Event Type identity is protected.');
      }
      await _ensureUniqueActiveLabel(
        profileId: profileId,
        label: label,
        excludingEventTypeId: draft.id,
      );
      final now = clock.nowUtc();
      final nextPosition =
          existing?.position ??
          ((await (database.select(
                    database.activityTypes,
                  )..where((table) => table.profileId.equals(profileId))).get())
                  .map((row) => row.position)
                  .fold<int>(
                    -1,
                    (value, position) => position > value ? position : value,
                  ) +
              1);
      final mappingVersion = (existing?.mappingVersion ?? 0) + 1;
      await database
          .into(database.activityTypes)
          .insertOnConflictUpdate(
            ActivityTypesCompanion.insert(
              id: draft.id,
              profileId: profileId,
              stableKey: existing?.stableKey ?? 'custom:${draft.id}',
              label: label,
              iconKey: draft.icon.name,
              colorValue: draft.colorValue,
              isSystem: false,
              isArchived: const Value<bool>(false),
              reportRequiredDefault: Value<bool>(draft.reportRequiredDefault),
              defaultDurationMinutes: Value<int>(draft.defaultDurationMinutes),
              defaultReminderMinutes: Value<int?>(draft.defaultReminderMinutes),
              position: nextPosition,
              mappingVersion: Value<int>(mappingVersion),
              createdAtUtc: existing?.createdAtUtc ?? now,
              updatedAtUtc: now,
            ),
          );
      for (final indicatorKey in draft.indicatorKeys) {
        await database
            .into(database.activityTypeIndicatorMappings)
            .insert(
              ActivityTypeIndicatorMappingsCompanion.insert(
                id: '${draft.id}:$mappingVersion:$indicatorKey',
                profileId: profileId,
                activityTypeId: draft.id,
                indicatorKey: indicatorKey,
                mappingVersion: Value<int>(mappingVersion),
                createdAtUtc: now,
              ),
            );
      }
      return (await readEventType(
        profileId: profileId,
        eventTypeId: draft.id,
      ))!;
    });
  }

  @override
  Future<void> renameSystemType({
    required String profileId,
    required String eventTypeId,
    required String label,
  }) async {
    final normalizedLabel = label.trim();
    if (normalizedLabel.isEmpty) {
      throw ArgumentError.value(label, 'label', 'Label is required.');
    }
    await _ensureSystemTypes(profileId);
    final type = await readEventType(
      profileId: profileId,
      eventTypeId: eventTypeId,
    );
    if (type == null) {
      throw StateError('Event Type not found.');
    }
    if (!type.isLockedWliType) {
      throw StateError('Only locked WLI Event Types can be renamed here.');
    }
    await _ensureUniqueActiveLabel(
      profileId: profileId,
      label: normalizedLabel,
      excludingEventTypeId: eventTypeId,
    );
    await (database.update(database.activityTypes)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(eventTypeId),
        ))
        .write(
          ActivityTypesCompanion(
            label: Value<String>(normalizedLabel),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
  }

  @override
  Future<void> setCustomTypeArchived({
    required String profileId,
    required String eventTypeId,
    required bool archived,
  }) async {
    final type = await readEventType(
      profileId: profileId,
      eventTypeId: eventTypeId,
    );
    if (type == null) {
      throw StateError('Event Type not found.');
    }
    if (type.isSystem) {
      throw StateError('System Event Types cannot be archived.');
    }
    await (database.update(database.activityTypes)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(eventTypeId),
        ))
        .write(
          ActivityTypesCompanion(
            isArchived: Value<bool>(archived),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
  }

  @override
  Future<void> restoreSystemDefaults({required String profileId}) async {
    await database.transaction(() async {
      await (database.delete(database.activityTypeIndicatorMappings)..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.activityTypeId.isIn(
                  _systemSeeds.map((seed) => seed.id).toList(growable: false),
                ),
          ))
          .go();
      await (database.delete(database.activityTypes)..where(
            (table) =>
                table.profileId.equals(profileId) & table.isSystem.equals(true),
          ))
          .go();
      await _insertSystemTypes(profileId);
    });
  }

  @override
  Future<PlannerSettings> readPlannerSettings({
    required String profileId,
  }) async {
    await _ensureSystemTypes(profileId);
    final row = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    if (row == null) {
      return const PlannerSettings.defaults();
    }
    return PlannerSettings(
      defaultEventTypeId: row.defaultActivityTypeId,
      defaultDurationMinutes: row.defaultDurationMinutes,
      defaultReminderMinutes: row.defaultReminderMinutes,
      visibleStartHour: row.visibleStartHour,
      visibleEndHour: row.visibleEndHour,
      use24HourTime: row.use24HourTime,
      snapMinutes: row.snapMinutes,
      showCurrentTime: row.showCurrentTime,
      initialScrollBehavior: PlannerInitialScrollBehavior.values.byName(
        row.initialScrollBehavior,
      ),
      creationPresentation: EventCreationPresentation.values.byName(
        row.creationPresentation,
      ),
      quickEditEnabled: row.quickEditEnabled,
      showCompletedItems: row.showCompletedItems,
      showCancelledItems: row.showCancelledItems,
      weekStartDay: row.weekStartDay,
      preferredPresentation: PlannerPresentation.values.byName(
        row.preferredPresentation,
      ),
      contentFilters: PlannerContentFilters(
        events: row.showEvents,
        backupEvents: row.showBackupEvents,
        tasks: row.showTasks,
        completedTasks: row.showCompletedTasks,
      ),
      timelineHourHeight: row.timelineHourHeight.toDouble(),
    );
  }

  @override
  Future<PlannerSettings> savePlannerSettings({
    required String profileId,
    required PlannerSettings settings,
  }) async {
    settings.validate();
    final defaultTypeId = settings.defaultEventTypeId;
    // The persisted preferences row is read once for the whole save: the
    // default-type eligibility check below and the section 27 reminder-default
    // comparison both need the CURRENT stored truth.
    final stored = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    if (defaultTypeId != null) {
      final type = await readEventType(
        profileId: profileId,
        eventTypeId: defaultTypeId,
      );
      if (type == null || type.isArchived) {
        throw StateError('Default Event Type must be active.');
      }
      // Contract E: a NEW deliberate default that points at a canonical
      // slot type must have a live eligible Goal occupant. An ALREADY-STORED
      // default (unchanged from the persisted row) is retained even when its
      // slot has since become hidden — changing unrelated settings must not
      // fail. No Goal bootstrap, no passive preference mutation.
      final storedDefaultTypeId = stored?.defaultActivityTypeId;
      if (defaultTypeId != storedDefaultTypeId) {
        final bindings = await readLiveGoalEventTypeBindings(
          database,
          profileId,
        );
        final slot = CanonicalGoalSlot.tryByEventTypeKey(type.stableKey);
        final canonicalOk =
            slot == null ||
            (type.isSystem &&
                slot.eventTypeId == type.id &&
                bindings.containsKey(slot.slotIndex));
        if (!canonicalOk) {
          throw StateError(
            'That Event Type is not currently available as a default.',
          );
        }
      }
    }
    // Section 27: the global reminder default is INHERITED by every reminder
    // that has no explicit timing of its own, so only a REAL change to it
    // schedules a reconciliation.  The previous value is captured before
    // the write so an unrelated settings save stays a no-op.
    final previousReminderDefault = stored?.defaultReminderMinutes;
    // Read/merge/write inside ONE transaction: the full-document settings
    // write carries the CURRENT stored presentation JSON forward losslessly
    // (event colors, group colors, Goal name overrides, and any invalid raw
    // owner content) instead of a pre-transaction row snapshot that could
    // erase a concurrent color/name/group save.
    final encodedPresentation = await PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    ).encodedCurrentDocument(profileId);
    await database
        .into(database.plannerPreferences)
        .insertOnConflictUpdate(
          PlannerPreferencesCompanion.insert(
            profileId: profileId,
            defaultActivityTypeId: Value<String?>(defaultTypeId),
            defaultDurationMinutes: Value<int>(settings.defaultDurationMinutes),
            defaultReminderMinutes: Value<int?>(
              settings.defaultReminderMinutes,
            ),
            visibleStartHour: Value<int>(settings.visibleStartHour),
            visibleEndHour: Value<int>(settings.visibleEndHour),
            use24HourTime: Value<bool>(settings.use24HourTime),
            snapMinutes: Value<int>(settings.snapMinutes),
            showCurrentTime: Value<bool>(settings.showCurrentTime),
            initialScrollBehavior: Value<String>(
              settings.initialScrollBehavior.name,
            ),
            creationPresentation: Value<String>(
              settings.creationPresentation.name,
            ),
            quickEditEnabled: Value<bool>(settings.quickEditEnabled),
            showCompletedItems: Value<bool>(settings.showCompletedItems),
            showCancelledItems: Value<bool>(settings.showCancelledItems),
            weekStartDay: Value<int>(settings.weekStartDay),
            preferredPresentation: Value<String>(
              settings.preferredPresentation.name,
            ),
            showEvents: Value<bool>(settings.contentFilters.events),
            showBackupEvents: Value<bool>(settings.contentFilters.backupEvents),
            showTasks: Value<bool>(settings.contentFilters.tasks),
            showCompletedTasks: Value<bool>(
              settings.contentFilters.completedTasks,
            ),
            timelineHourHeight: Value<int>(settings.timelineHourHeight.round()),
            eventColorPreferencesJson: Value<String?>(encodedPresentation),
            updatedAtUtc: clock.nowUtc(),
          ),
        );
    if (previousReminderDefault != settings.defaultReminderMinutes) {
      await reminderRepair?.mark(database, profileId: profileId);
    }
    return settings;
  }

  @override
  Future<Map<String, EventColorPreference>> readEventColorPreferences({
    required String profileId,
  }) async {
    return (await _readColorDocument(profileId)).events;
  }

  @override
  Future<Map<String, int>> readContactGroupColors({
    required String profileId,
  }) async {
    return (await _readColorDocument(profileId)).groups;
  }

  @override
  Future<Map<String, int>> saveContactGroupColor({
    required String profileId,
    required String groupId,
    required int colorArgb,
  }) async {
    final normalizedId = groupId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(groupId, 'groupId', 'Group ID is required.');
    }
    if (colorArgb < 0 || colorArgb > 0xFFFFFFFF) {
      throw ArgumentError.value(colorArgb, 'colorArgb', 'Invalid ARGB color.');
    }
    final store = PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    );
    return store
        .update(profileId, (current) async {
          return PlannerColorPreferencesDocument(
            events: current.document.events,
            groups: <String, int>{
              ...current.document.groups,
              normalizedId: colorArgb,
            },
            goalEventTypeNames: current.document.goalEventTypeNames,
          );
        })
        .then((document) => document.groups);
  }

  @override
  Future<Map<String, int>> restoreContactGroupColorDefaults({
    required String profileId,
  }) async {
    final store = PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    );
    // Clears ONLY group colors. Event colors and Goal name overrides survive.
    await store.update(profileId, (current) async {
      return PlannerColorPreferencesDocument(
        events: current.document.events,
        groups: const <String, int>{},
        goalEventTypeNames: current.document.goalEventTypeNames,
      );
    });
    return const <String, int>{};
  }

  @override
  Future<Map<String, EventColorPreference>> saveEventColorPreference({
    required String profileId,
    required String eventTypeStableKey,
    required EventColorPreference preference,
  }) async {
    final stableKey = eventTypeStableKey.trim();
    if (stableKey.isEmpty) {
      throw ArgumentError.value(
        eventTypeStableKey,
        'eventTypeStableKey',
        'Event Type stable key is required.',
      );
    }
    await _ensureUniqueActiveEventTypeAccent(
      profileId: profileId,
      eventTypeStableKey: stableKey,
      proposedAccentArgb: preference.accentArgb,
    );
    final store = PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    );
    final updated = await store.update(profileId, (current) async {
      return PlannerColorPreferencesDocument(
        events: <String, EventColorPreference>{
          ...current.document.events,
          stableKey: preference,
        },
        groups: current.document.groups,
        goalEventTypeNames: current.document.goalEventTypeNames,
      );
    });
    return Map<String, EventColorPreference>.unmodifiable(updated.events);
  }

  /// Newly deliberate Event Type accent choices cannot duplicate an active
  /// peer after opaque-RGB normalization. Existing fallback/default/legacy
  /// duplicates remain readable and a type may retain its own current color.
  /// This rule is scoped to Event Types only; Groups use their own pool.
  ///
  /// Closed-beta V2 (owner decision AG-1, 2026-09-17): the synthetic Task
  /// identity is treated EXACTLY like a real Event Type. It owns no
  /// `activity_types` row, so a peer list built only from that table silently
  /// omitted it — which let a real Event Type claim the Task accent, and which
  /// made a Task save indistinguishable from a brand-new type. Both directions
  /// are now symmetric: the Task can always retain its own current accent, and
  /// no other identity (including the Task) may newly take the other's accent.
  Future<void> _ensureUniqueActiveEventTypeAccent({
    required String profileId,
    required String eventTypeStableKey,
    required int proposedAccentArgb,
  }) async {
    final activeTypes = await readEventTypes(profileId: profileId);
    final preferences = await _readColorDocument(profileId);

    /// The accent this identity currently resolves to, whether it is a real
    /// row or the synthetic Task identity that owns no `activity_types` row.
    int? effectiveAccentFor(String stableKey) {
      final stored = preferences.events[stableKey]?.accentArgb;
      if (stored != null) {
        return stored;
      }
      if (stableKey == PlannerEventColorDefaults.taskStableKey) {
        return PlannerEventColorDefaults.task.accentArgb;
      }
      final type = activeTypes
          .where((candidate) => candidate.stableKey == stableKey)
          .firstOrNull;
      return type == null
          ? null
          : PlannerEventColorDefaults.forEventType(type).accentArgb;
    }

    final isKnownIdentity =
        eventTypeStableKey == PlannerEventColorDefaults.taskStableKey ||
        activeTypes.any((type) => type.stableKey == eventTypeStableKey);
    final currentAccent = isKnownIdentity
        ? effectiveAccentFor(eventTypeStableKey)
        : null;
    // Retaining an existing duplicate/default is compatibility, not a new
    // deliberate duplicate assignment.
    if (currentAccent != null &&
        Vs11ColorSystem.sameOpaqueRgb(currentAccent, proposedAccentArgb)) {
      return;
    }
    final collision =
        <String>[
          for (final type in activeTypes) type.stableKey,
          PlannerEventColorDefaults.taskStableKey,
        ].any((stableKey) {
          if (stableKey == eventTypeStableKey) {
            return false;
          }
          final effectiveAccent = effectiveAccentFor(stableKey);
          return effectiveAccent != null &&
              Vs11ColorSystem.sameOpaqueRgb(
                effectiveAccent,
                proposedAccentArgb,
              );
        });
    if (collision) {
      throw StateError(
        'That color is already used by another active Event Type.',
      );
    }
  }

  @override
  Future<Map<String, EventColorPreference>> restoreEventColorDefaults({
    required String profileId,
  }) async {
    final store = PlannerPresentationDocumentStore(
      database: database,
      clock: clock,
    );
    // Clears ONLY event colors. Group colors and Goal name overrides are
    // presentation metadata that must survive a color restore.
    await store.update(profileId, (current) async {
      return PlannerColorPreferencesDocument(
        events: const <String, EventColorPreference>{},
        groups: current.document.groups,
        goalEventTypeNames: current.document.goalEventTypeNames,
      );
    });
    return const <String, EventColorPreference>{};
  }

  Future<void> _writeColorDocument({
    required String profileId,
    required Map<String, EventColorPreference> events,
    required Map<String, int> groups,
  }) async {
    final encoded = EventColorPreferenceCodec.encodeDocument(
      events: events,
      groups: groups,
    );
    await database.transaction(() async {
      final existing = await (database.select(
        database.plannerPreferences,
      )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
      if (existing == null) {
        await database
            .into(database.plannerPreferences)
            .insert(
              PlannerPreferencesCompanion.insert(
                profileId: profileId,
                eventColorPreferencesJson: Value<String?>(encoded),
                updatedAtUtc: clock.nowUtc(),
              ),
            );
        return;
      }
      await (database.update(
        database.plannerPreferences,
      )..where((table) => table.profileId.equals(profileId))).write(
        PlannerPreferencesCompanion(
          eventColorPreferencesJson: Value<String?>(encoded),
          updatedAtUtc: Value<DateTime>(clock.nowUtc()),
        ),
      );
    });
  }

  Future<PlannerColorPreferencesDocument> _readColorDocument(
    String profileId,
  ) async {
    final row = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    return EventColorPreferenceCodec.decodeDocument(
      row?.eventColorPreferencesJson,
    );
  }

  @override
  Stream<void> watchPresentationDocument(String profileId) {
    // Emits after every committed write to the Planner Preferences table;
    // the payload is ignored (the stream is a change signal only). Drift
    // suppresses consecutive no-op frames for equal update sets.
    return database.tableUpdates(
      TableUpdateQuery.onTable(database.plannerPreferences),
    );
  }

  @override
  Future<Map<String, GoalEventTypeNameOverride>> readGoalEventTypeNameOverrides(
    String profileId,
  ) async {
    return (await _readColorDocument(profileId)).goalEventTypeNames;
  }

  @override
  Future<LiveGoalPresentationResult> saveLiveGoalPresentation({
    required String profileId,
    required int expectedSlotIndex,
    required String expectedGoalId,
    required String expectedEventTypeId,
    required String expectedStableKey,
    required LiveGoalPresentationOriginals originalValues,
    required LiveGoalPresentationPatch patch,
  }) async {
    final canonicalSlot = CanonicalGoalSlot.bySlot(expectedSlotIndex);
    if (canonicalSlot.eventTypeStableKey != expectedStableKey ||
        canonicalSlot.eventTypeId != expectedEventTypeId) {
      throw StateError(
        'That Event Type is not currently available for editing.',
      );
    }

    await database.transaction(() async {
      // Live eligibility re-check at Save: exactly one raw-active occupant
      // of this slot with the exact expected identity. Archive/replacement
      // races are rejected before any write.
      final goalRows =
          await (database.select(database.goals)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.status.equals('active') &
                    table.activeSlotIndex.equals(expectedSlotIndex),
              ))
              .get();
      final binding = GoalEventTypePolicy.bindingsForCandidates(
        candidates: goalRows
            .map(
              (row) => LiveGoalCandidateRow(
                id: row.id,
                profileId: row.profileId,
                status: row.status,
                role: row.role,
                activeSlotIndex: row.activeSlotIndex,
                assignedEventTypeStableKey: row.assignedEventTypeStableKey,
                indicatorKey: row.indicatorKey,
                title: row.title,
              ),
            )
            .toList(growable: false),
        profileId: profileId,
      )[expectedSlotIndex];
      if (binding == null ||
          binding.goalId != expectedGoalId ||
          binding.title.trim().isEmpty) {
        throw StateError(
          'That Event Type is not currently available for editing.',
        );
      }

      // Exact canonical row validation (same law as the Goal save merge).
      final typeRows =
          await (database.select(database.activityTypes)..where(
                (table) =>
                    table.id.equals(expectedEventTypeId) &
                    table.profileId.equals(profileId),
              ))
              .get();
      if (typeRows.length != 1) {
        throw StateError(
          'That Event Type is not currently available for editing.',
        );
      }
      final typeRow = typeRows.single;
      if (typeRow.stableKey != expectedStableKey ||
          !typeRow.isSystem ||
          typeRow.isArchived) {
        throw StateError(
          'That Event Type is not currently available for editing.',
        );
      }
      final mappingRows =
          await (database.select(database.activityTypeIndicatorMappings)..where(
                (table) =>
                    table.activityTypeId.equals(expectedEventTypeId) &
                    table.profileId.equals(profileId),
              ))
              .get();
      if (mappingRows.length != 1 ||
          mappingRows.single.indicatorKey != canonicalSlot.indicatorKey) {
        throw StateError(
          'That Event Type is not currently available for editing.',
        );
      }

      final store = PlannerPresentationDocumentStore(
        database: database,
        clock: clock,
      );
      await store.update(profileId, (current) async {
        final stored = current.document;

        // Concurrency guards: caller-observed originals must still match,
        // or the change is rejected instead of overwriting.
        final storedEntry = stored.goalEventTypeNames[expectedGoalId];
        final observedEntry = originalValues.observedNameOverride;
        final nameMatches = observedEntry == null
            ? storedEntry == null
            : storedEntry != null &&
                  storedEntry.eventTypeStableKey ==
                      observedEntry.eventTypeStableKey &&
                  storedEntry.name == observedEntry.name;
        if (!nameMatches) {
          throw StateError(
            'That Event Type changed while you were editing. '
            'Review your changes and try again.',
          );
        }
        final changedColor = patch.colorPreference;
        if (changedColor != null) {
          final lockedDefault = PlannerEventColorDefaults
              .pmgStableKeyDefaults[canonicalSlot.eventTypeStableKey];
          final effectiveNow =
              stored.events[canonicalSlot.eventTypeStableKey] ??
              lockedDefault ??
              PlannerEventColorDefaults.other;
          final observedColor = originalValues.observedColor;
          if (observedColor != null && effectiveNow != observedColor) {
            throw StateError(
              'That Event Type changed while you were editing. '
              'Review your changes and try again.',
            );
          }
          await _ensureUniqueActiveEventTypeAccent(
            profileId: profileId,
            eventTypeStableKey: canonicalSlot.eventTypeStableKey,
            proposedAccentArgb: changedColor.accentArgb,
          );
        }

        var nextNames = stored.goalEventTypeNames;
        var nextEvents = stored.events;
        var mutated = false;
        if (patch.clearNameOverride) {
          if (nextNames.containsKey(expectedGoalId)) {
            nextNames = <String, GoalEventTypeNameOverride>{...nextNames}
              ..remove(expectedGoalId);
            mutated = true;
          }
        } else if (patch.nameOverride != null) {
          final trimmed = patch.nameOverride!.trim();
          if (trimmed.isEmpty) {
            throw StateError('Enter a name.');
          }
          final entry = GoalEventTypeNameOverride(
            eventTypeStableKey: canonicalSlot.eventTypeStableKey,
            name: trimmed,
          );
          if (nextNames[expectedGoalId] != entry) {
            nextNames = <String, GoalEventTypeNameOverride>{
              ...nextNames,
              expectedGoalId: entry,
            };
            mutated = true;
          }
        }
        if (changedColor != null) {
          if (nextEvents[canonicalSlot.eventTypeStableKey] != changedColor) {
            nextEvents = <String, EventColorPreference>{
              ...nextEvents,
              canonicalSlot.eventTypeStableKey: changedColor,
            };
            mutated = true;
          }
        }
        if (!mutated) {
          return null;
        }
        return PlannerColorPreferencesDocument(
          events: nextEvents,
          groups: stored.groups,
          goalEventTypeNames: nextNames,
        );
      });
    });

    final document = await _readColorDocument(profileId);
    final savedEntry = document.goalEventTypeNames[expectedGoalId];
    return LiveGoalPresentationResult(
      nameMode: savedEntry == null
          ? AssignedEventTypeNameMode.auto
          : AssignedEventTypeNameMode.manual,
      nameOverride: savedEntry?.name,
      colorPreference:
          document.events[canonicalSlot.eventTypeStableKey] ??
          PlannerEventColorDefaults.pmgStableKeyDefaults[canonicalSlot
              .eventTypeStableKey] ??
          PlannerEventColorDefaults.other,
    );
  }

  /// Self-healing repair for surfaces persisted before the light-muted
  /// palette pipeline (Part 14 lock) plus the targeted Recommended Color
  /// legacy repair (dark-surface correction).
  ///
  /// The Event block surface is always derived from the saved accent through
  /// the shared automatic derivation and is never independently
  /// user-editable, so any stored surface that does not equal that derivation
  /// is a stale legacy value from the old dark-blend pipeline. Recompute each
  /// surface from its saved accent and persist the repaired document. Accents
  /// and group colors are never touched, and the repair is idempotent (a
  /// repaired pair no longer differs from its derivation).
  ///
  /// For a Recommended Color accent the automatic derivation is its locked
  /// dark partner: a surface that equals the exact OLD generic light-muted
  /// derivation is upgraded to the dark partner (so current saved
  /// recommended auto-surfaces become dark), while an already-mapped-dark or
  /// explicit/manual/curated surface is preserved verbatim.
  ///
  /// The derivation clamps lightness to [0.30, 0.80], which for a dark custom
  /// accent yields the same lifted surface the picker persists today
  /// (mutedSurfaceFromAccent), so healing never invents a state the save
  /// pipeline would not produce.
  // Retained solely as historical migration documentation. The VS-11 exact
  // color-system lock removes this method from the read path: reading legacy
  // data must never rewrite an owner-selected/Event-history surface.
  // ignore: unused_element
  Future<PlannerColorPreferencesDocument> _reconcileLightMutedSurfaces(
    String profileId,
    PlannerColorPreferencesDocument document,
  ) async {
    var changed = false;
    final repaired = <String, EventColorPreference>{};
    for (final entry in document.events.entries) {
      // The exact PMG default surfaces are explicit and deliberate (they are
      // NOT derivation-consistent by design), so a surface that already
      // equals the locked default must never be re-derived on read.
      final lockedDefault =
          PlannerEventColorDefaults.pmgStableKeyDefaults[entry.key];
      if (lockedDefault != null &&
          entry.value.surfaceArgb == lockedDefault.surfaceArgb) {
        repaired[entry.key] = entry.value;
        continue;
      }
      // Dark-surface correction, targeted legacy repair: a Recommended Color
      // accent has two legitimate stored surfaces — the exact OLD generic
      // auto-derived light surface (upgraded to the mapped dark partner) and
      // every other value (mapped dark, manual, or curated — preserved).
      // The owner wants ALL currently saved recommended auto-surfaces to
      // appear dark, while arbitrary manual surfaces must never be
      // overwritten.  Non-recommended accents keep the generic repair below.
      final recommendedDarkSurfaceArgb = recommendedSurfaceArgbForAccent(
        entry.value.accentArgb,
      );
      if (recommendedDarkSurfaceArgb != null) {
        final oldLegacyAutoSurfaceArgb = EventColorMath.lightMutedSurfaceArgb(
          entry.value.accentArgb,
        );
        if (entry.value.surfaceArgb == oldLegacyAutoSurfaceArgb) {
          repaired[entry.key] = EventColorPreference(
            accentArgb: entry.value.accentArgb,
            surfaceArgb: recommendedDarkSurfaceArgb,
          );
          changed = true;
          continue;
        }
        // Already-mapped-dark or explicit/manual/curated surface: preserve.
        repaired[entry.key] = entry.value;
        continue;
      }
      final expectedSurfaceArgb = EventColorMath.lightMutedSurfaceArgb(
        entry.value.accentArgb,
      );
      if (entry.value.surfaceArgb == expectedSurfaceArgb) {
        repaired[entry.key] = entry.value;
        continue;
      }
      repaired[entry.key] = EventColorPreference(
        accentArgb: entry.value.accentArgb,
        surfaceArgb: expectedSurfaceArgb,
      );
      changed = true;
    }
    if (!changed) {
      return document;
    }
    // Best-effort persistence: the repaired in-memory document already serves
    // this read correctly even if the DB cannot be written right now (e.g.
    // read-only media during a restore); the next read retries the repair.
    try {
      await _writeColorDocument(
        profileId: profileId,
        events: repaired,
        groups: document.groups,
      );
    } on Object {
      // Persistence is opportunistic; healed values still reach the caller.
    }
    return PlannerColorPreferencesDocument(
      events: Map<String, EventColorPreference>.unmodifiable(repaired),
      groups: document.groups,
    );
  }

  /// Converge saved preferences whose ACCENT still carries a recognized
  /// legacy default toward the final PMG faded family (Parts 11-15 Final
  /// Planner correction).
  ///
  /// The presentation resolver prefers a saved preference over the new
  /// palette, so a stale legacy accent persisted by an older pipeline would
  /// otherwise keep the device showing pre-PMG colors after the migration.
  /// A preference is only rewritten when its accent EXACTLY matches the
  /// recognized legacy default for its stable key (i.e. it was never
  /// explicitly customized away from the seed); the new accent becomes the
  /// approved PMG value and its surface is re-derived through
  /// [EventColorMath.lightMutedSurfaceArgb]. Any other accent is a genuine
  /// user choice and is preserved, and the remap is idempotent.
  // Retained solely as historical migration documentation. The VS-11 exact
  // color-system lock removes this method from the read path: raw persisted
  // legacy accents remain evidence, never a migration input.
  // ignore: unused_element
  Future<PlannerColorPreferencesDocument> _reconcileLegacySavedAccents(
    String profileId,
    PlannerColorPreferencesDocument document,
  ) async {
    var changed = false;
    final remapped = <String, EventColorPreference>{};
    for (final entry in document.events.entries) {
      final hop = _legacySavedAccentMigrations[entry.key]
          ?.where((candidate) => candidate.legacyArgb == entry.value.accentArgb)
          .firstOrNull;
      if (hop == null) {
        remapped[entry.key] = entry.value;
        continue;
      }
      remapped[entry.key] = EventColorPreference(
        accentArgb: hop.nextArgb,
        // Locked PMG hops carry their explicit dark surface; every other hop
        // continues to derive through the light-muted pipeline.
        surfaceArgb:
            hop.nextSurfaceArgb ??
            EventColorMath.lightMutedSurfaceArgb(hop.nextArgb),
      );
      changed = true;
    }
    if (!changed) {
      return document;
    }
    try {
      await _writeColorDocument(
        profileId: profileId,
        events: remapped,
        groups: document.groups,
      );
    } on Object {
      // Persistence is opportunistic; the remapped values still reach the
      // caller and the next read retries the write.
    }
    return PlannerColorPreferencesDocument(
      events: Map<String, EventColorPreference>.unmodifiable(remapped),
      groups: document.groups,
    );
  }

  Future<void> _ensureSystemTypes(String profileId) async {
    await database.transaction(() async {
      await _ensureEducationType(profileId);
      await _insertSystemTypes(profileId);
      await _repairExactCrossedBudgetAndMinisteringLabels(profileId);
      await _migrateUntouchedMinisteringVisitLabel(profileId);
      await _migrateUntouchedWorkLabelToShopping(profileId);
    });
  }

  /// Repairs the exact two-row label crossover emitted by one legacy build.
  ///
  /// Both canonical system identities and both observed labels must match in
  /// the same transaction. A partial match is treated as an intentional rename
  /// and left untouched. Only the two labels and their update timestamps move;
  /// stable IDs, mappings, Event snapshots, colors, positions, and every other
  /// stored field remain unchanged.
  Future<void> _repairExactCrossedBudgetAndMinisteringLabels(
    String profileId,
  ) async {
    final rows =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.isIn(<String>[
                    SystemEventTypeIds.budgetReview,
                    SystemEventTypeIds.meaningfulConnection,
                  ]),
            ))
            .get();
    ActivityTypeRow? budget;
    ActivityTypeRow? ministering;
    for (final row in rows) {
      switch (row.id) {
        case SystemEventTypeIds.budgetReview:
          budget = row;
        case SystemEventTypeIds.meaningfulConnection:
          ministering = row;
      }
    }
    if (budget == null ||
        ministering == null ||
        !budget.isSystem ||
        !ministering.isSystem ||
        budget.stableKey != SystemEventTypeKeys.budgetReview ||
        ministering.stableKey != SystemEventTypeKeys.meaningfulConnection ||
        budget.label != 'Ministering' ||
        ministering.label != 'Budget Review') {
      return;
    }

    final now = clock.nowUtc();
    await (database.update(database.activityTypes)..where(
          (table) =>
              table.profileId.equals(profileId) &
              table.id.equals(SystemEventTypeIds.meaningfulConnection),
        ))
        .write(
          ActivityTypesCompanion(
            label: const Value<String>('Ministering Visit'),
            updatedAtUtc: Value<DateTime>(now),
          ),
        );
    await (database.update(database.activityTypes)..where(
          (table) =>
              table.profileId.equals(profileId) &
              table.id.equals(SystemEventTypeIds.budgetReview),
        ))
        .write(
          ActivityTypesCompanion(
            label: const Value<String>('Budget Review'),
            updatedAtUtc: Value<DateTime>(now),
          ),
        );
  }

  /// Deterministic one-time seed reconciliation for system Event Types.
  ///
  /// Fresh installs receive the current recommended colors from the seeds
  /// above. Existing installs keep their stored `color_value` untouched
  /// UNLESS it exactly matches a recognized legacy default seed for that
  /// stable Event Type (i.e. the user never customized it). Explicit user
  /// customizations stored in the color-preference document are never
  /// remapped; presentation-time defaults handle the non-customized path.
  /// The P-01D hop migrates untouched Work rows off the shared icy Service
  /// family onto the muted steel pair while Service stays unchanged.
  // Retained solely as historical migration documentation. System rows are
  // no longer recolored on read under the exact color-system preservation
  // law.
  // ignore: unused_element
  Future<void> _reconcileLockedWliSeedColors(String profileId) async {
    for (final entry in _lockedWliLegacySeedColors) {
      final row =
          await (database.select(database.activityTypes)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(entry.id),
              ))
              .getSingleOrNull();
      if (row == null || row.colorValue != entry.legacyArgb) {
        continue;
      }
      await (database.update(database.activityTypes)..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(entry.id),
          ))
          .write(
            ActivityTypesCompanion(
              colorValue: Value<int>(entry.nextArgb),
              updatedAtUtc: Value<DateTime>(clock.nowUtc()),
            ),
          );
    }
  }

  /// The fixed WLI slot formerly displayed as Contact/Meaningful Connections
  /// in older installs. Preserve an intentional user rename, but migrate the
  /// untouched legacy labels to the canonical title used by the Goal slot.
  Future<void> _migrateUntouchedMinisteringVisitLabel(String profileId) async {
    final row =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.equals(SystemEventTypeIds.meaningfulConnection),
            ))
            .getSingleOrNull();
    if (row == null ||
        (row.label != 'Contact' && row.label != 'Meaningful Connections')) {
      return;
    }
    await _ensureUniqueActiveLabel(
      profileId: profileId,
      label: 'Ministering Visit',
      excludingEventTypeId: row.id,
    );
    await (database.update(database.activityTypes)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(row.id),
        ))
        .write(
          ActivityTypesCompanion(
            label: const Value<String>('Ministering Visit'),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
  }

  /// Renames only the untouched built-in Work identity to its user-facing
  /// Shopping label. Custom labels and noncanonical rows are preserved.
  Future<void> _migrateUntouchedWorkLabelToShopping(String profileId) async {
    final row =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.equals(SystemEventTypeIds.work),
            ))
            .getSingleOrNull();
    if (row == null ||
        !row.isSystem ||
        row.stableKey != SystemEventTypeKeys.work ||
        row.label != 'Work') {
      return;
    }
    await (database.update(database.activityTypes)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(row.id),
        ))
        .write(
          ActivityTypesCompanion(
            label: const Value<String>('Shopping'),
            updatedAtUtc: Value<DateTime>(clock.nowUtc()),
          ),
        );
  }

  Future<void> _ensureUniqueActiveLabel({
    required String profileId,
    required String label,
    String? excludingEventTypeId,
  }) async {
    final normalized = label.trim().toLowerCase();
    final rows =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.isArchived.equals(false),
            ))
            .get();
    final duplicate = rows.any(
      (row) =>
          row.id != excludingEventTypeId &&
          row.label.trim().toLowerCase() == normalized,
    );
    if (duplicate) {
      throw StateError('Active Event Type names must be unique.');
    }
  }

  /// F. Education v46 backfill: the narrow additive identity preflight.
  ///
  /// Runs inside the `_ensureSystemTypes` transaction BEFORE generic seed
  /// insertion. Cases:
  /// - No Education identity row exists (neither the proposed global ID nor
  ///   the profile/'education' stable key): the P24 accent collision check
  ///   runs once before first insertion, then `_insertSystemTypes`
  ///   insertOrIgnore inserts exactly ONE Education row.
  /// - Exact system identity (same global ID AND profile/'education' key):
  ///   every stored field is preserved verbatim — explicit label, color,
  ///   archive state, and timestamps are never rewritten on later opens.
  /// - Any other identity collision (same key different ID, global ID owned
  ///   by another profile or key, non-system impostor, invalid icon key):
  ///   a sanitized error aborts the transaction.
  /// A custom row merely labeled "Education" is NOT the system row and is
  /// never merged; duplicate display labels are reported without guessing
  /// identity.
  Future<void> _ensureEducationType(String profileId) async {
    final byId = await (database.select(
      database.activityTypes,
    )..where((table) => table.id.equals(SystemEventTypeIds.education))).get();
    final byKey =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.stableKey.equals(SystemEventTypeKeys.education),
            ))
            .get();
    if (byId.isEmpty && byKey.isEmpty) {
      await _assertEducationAccentAvailable(profileId);
      return;
    }
    for (final row in byId) {
      if (row.profileId != profileId) {
        throw const EducationBackfillException(
          'Education Event Type ID belongs to another profile.',
        );
      }
      if (row.stableKey != SystemEventTypeKeys.education || !row.isSystem) {
        throw const EducationBackfillException(
          'Education Event Type ID identity mismatch.',
        );
      }
    }
    for (final row in byKey) {
      if (row.id != SystemEventTypeIds.education) {
        throw const EducationBackfillException(
          'education stable key belongs to another Event Type ID.',
        );
      }
      if (!row.isSystem) {
        throw const EducationBackfillException(
          'education stable key is owned by a non-system row.',
        );
      }
    }
    final exactRows = <ActivityTypeRow>{...byId, ...byKey};
    for (final row in exactRows) {
      try {
        EventTypeIcon.values.byName(row.iconKey);
      } on ArgumentError {
        throw const EducationBackfillException(
          'Education Event Type row has an unknown icon key.',
        );
      }
    }
  }

  /// Before FIRST Education insertion only: no active Event Type may already
  /// use the locked P24 accent. Accents are compared directly from rows, the
  /// saved preference document, and the pure default resolver — never by
  /// re-entering readEventTypes (which would recurse into seeding).
  Future<void> _assertEducationAccentAvailable(String profileId) async {
    final rows =
        await (database.select(database.activityTypes)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.isArchived.equals(false),
            ))
            .get();
    final preferenceRow = await (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();
    final preferences = EventColorPreferenceCodec.decodeDocument(
      preferenceRow?.eventColorPreferencesJson,
    ).events;
    final educationAccent = PlannerEventColorDefaults.education.accentArgb;
    for (final row in rows) {
      final effective =
          preferences[row.stableKey] ??
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
          );
      if (effective.accentArgb == educationAccent) {
        throw const EducationBackfillException(
          'An existing active Event Type already uses the Education accent.',
        );
      }
    }
  }

  Future<void> _insertSystemTypes(String profileId) async {
    final now = clock.nowUtc();
    for (final seed in _systemSeeds) {
      await database
          .into(database.activityTypes)
          .insert(
            ActivityTypesCompanion.insert(
              id: seed.id,
              profileId: profileId,
              stableKey: seed.key,
              label: seed.label,
              iconKey: seed.icon.name,
              colorValue: seed.colorValue,
              isSystem: true,
              reportRequiredDefault: Value<bool>(seed.reportRequired),
              defaultDurationMinutes: Value<int>(seed.durationMinutes),
              position: seed.position,
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      final indicatorKey = seed.indicatorKey;
      if (indicatorKey != null) {
        await database
            .into(database.activityTypeIndicatorMappings)
            .insert(
              ActivityTypeIndicatorMappingsCompanion.insert(
                id: '${seed.id}:1:$indicatorKey',
                profileId: profileId,
                activityTypeId: seed.id,
                indicatorKey: indicatorKey,
                createdAtUtc: now,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    }
  }

  Future<Map<String, Set<String>>> _readMappings(String profileId) async {
    final rows = await (database.select(
      database.activityTypeIndicatorMappings,
    )..where((table) => table.profileId.equals(profileId))).get();
    final result = <String, Set<String>>{};
    for (final row in rows) {
      result
          .putIfAbsent(
            _mappingRevisionKey(row.activityTypeId, row.mappingVersion),
            () => <String>{},
          )
          .add(row.indicatorKey);
    }
    return result;
  }

  static String _mappingRevisionKey(String eventTypeId, int mappingVersion) =>
      '$eventTypeId:$mappingVersion';

  EventType _map(ActivityTypeRow row, Set<String> indicatorKeys) {
    return EventType(
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
      indicatorKeys: Set<String>.unmodifiable(indicatorKeys),
    );
  }
}

final class _SystemEventTypeSeed {
  const _SystemEventTypeSeed({
    required this.id,
    required this.key,
    required this.label,
    required this.icon,
    required this.colorValue,
    required this.position,
    this.indicatorKey,
    this.reportRequired = false,
    this.durationMinutes = 60,
  });

  final String id;
  final String key;
  final String label;
  final EventTypeIcon icon;
  final int colorValue;
  final int position;
  final String? indicatorKey;
  final bool reportRequired;
  final int durationMinutes;
}

const _systemSeeds = <_SystemEventTypeSeed>[
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.general,
    key: SystemEventTypeKeys.general,
    label: 'General',
    icon: EventTypeIcon.calendar,
    colorValue: 0xFFE91E63,
    position: 0,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.other,
    key: SystemEventTypeKeys.other,
    label: 'Other',
    icon: EventTypeIcon.calendar,
    colorValue: 0xFF868A8D,
    position: 1,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.teaching,
    key: SystemEventTypeKeys.teaching,
    label: 'Teaching',
    icon: EventTypeIcon.exercise,
    colorValue: 0xFFF4D06F,
    position: 2,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.finding,
    key: SystemEventTypeKeys.finding,
    label: 'Finding',
    icon: EventTypeIcon.job,
    colorValue: 0xFFE594D1,
    position: 3,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.meeting,
    key: SystemEventTypeKeys.meeting,
    label: 'Meeting',
    icon: EventTypeIcon.appointment,
    colorValue: 0xFFE27386,
    position: 4,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.studyOrPlan,
    key: SystemEventTypeKeys.studyOrPlan,
    label: 'Study or Plan',
    icon: EventTypeIcon.scripture,
    colorValue: 0xFFA272C8,
    position: 5,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.service,
    key: SystemEventTypeKeys.service,
    label: 'Service',
    icon: EventTypeIcon.work,
    colorValue: 0xFFDEEDF2,
    position: 6,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.templeVisit,
    key: SystemEventTypeKeys.templeVisit,
    label: 'Temple Visit',
    icon: EventTypeIcon.temple,
    colorValue: 0xFF98CED8,
    position: 7,
    indicatorKey: 'temple_visit',
    reportRequired: true,
    durationMinutes: 120,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.scriptureStudy,
    key: SystemEventTypeKeys.scriptureStudy,
    label: 'Scripture Study',
    icon: EventTypeIcon.scripture,
    colorValue: 0xFFDE9EDA,
    position: 8,
    indicatorKey: 'scripture_study',
    reportRequired: true,
    durationMinutes: 30,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.exercise,
    key: SystemEventTypeKeys.exercise,
    label: 'Exercise',
    icon: EventTypeIcon.exercise,
    colorValue: 0xFFEAA15D,
    position: 9,
    indicatorKey: 'exercise',
    reportRequired: true,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.budgetReview,
    key: SystemEventTypeKeys.budgetReview,
    label: 'Budget Review',
    icon: EventTypeIcon.budget,
    colorValue: 0xFFBFA384,
    position: 10,
    indicatorKey: 'budget_review',
    reportRequired: true,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.jobApplication,
    key: SystemEventTypeKeys.jobApplication,
    label: 'Job Application',
    icon: EventTypeIcon.job,
    colorValue: 0xFFEBC766,
    position: 11,
    indicatorKey: 'job_applications',
    reportRequired: true,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.meaningfulConnection,
    key: SystemEventTypeKeys.meaningfulConnection,
    label: 'Ministering Visit',
    icon: EventTypeIcon.connection,
    colorValue: 0xFFB0A971,
    position: 12,
    indicatorKey: 'meaningful_connections',
    reportRequired: true,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.contact,
    key: SystemEventTypeKeys.contact,
    label: 'Contact',
    icon: EventTypeIcon.connection,
    colorValue: 0xFF76B181,
    position: 18,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.appointment,
    key: SystemEventTypeKeys.appointment,
    label: 'Appointment',
    icon: EventTypeIcon.appointment,
    colorValue: 0xFF26A69A,
    position: 13,
  ),
  // The stable Work identity is presented as Shopping and keeps the muted
  // steel/slate-blue pair, distinct from Service's approved icy family.
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.work,
    key: SystemEventTypeKeys.work,
    label: 'Shopping',
    icon: EventTypeIcon.work,
    colorValue: 0xFFA9BEC9,
    position: 14,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.travel,
    key: SystemEventTypeKeys.travel,
    label: 'Travel',
    icon: EventTypeIcon.personal,
    colorValue: 0xFFECC7D8,
    position: 15,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.meal,
    key: SystemEventTypeKeys.meal,
    label: 'Meal',
    icon: EventTypeIcon.budget,
    colorValue: 0xFFE1CFB9,
    position: 16,
  ),
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.personal,
    key: SystemEventTypeKeys.personal,
    label: 'Personal',
    icon: EventTypeIcon.personal,
    colorValue: 0xFFFFA726,
    position: 17,
  ),
  // F. Education: ordinary system seed, stored position 19 (existing
  // positions are NEVER renumbered). No indicator mapping, reportRequired
  // false, 60-minute default, no reminder. Approved creation order — not
  // this stored position — governs canonical picker order. The seed accent
  // follows the approved Education pair (P22 Gray Blue, Prompt-P46); the
  // raw color_value remains a legacy/factual fallback only.
  _SystemEventTypeSeed(
    id: SystemEventTypeIds.education,
    key: SystemEventTypeKeys.education,
    label: 'Education',
    icon: EventTypeIcon.scripture,
    colorValue: Vs11ColorSystem.p22SteelBlue,
    position: 19,
  ),
];

/// Legacy `color_value` seed for each locked WLI Event Type before the
/// VS-08 final-polish recolor, paired with its new recommended seed value.
/// Reconciliation only remaps a row whose stored value exactly matches the
/// legacy default for that stable identity — any other value is a user
/// customization and stays untouched.
final class _LockedWliColorMigration {
  const _LockedWliColorMigration({
    required this.id,
    required this.legacyArgb,
    required this.nextArgb,
  });

  final String id;
  final int legacyArgb;
  final int nextArgb;
}

/// Legacy saved-preference accent hops keyed by Event Type stable key.
///
/// The color-value reconciliation above rewrites `activity_types.color_value`
/// rows, but the presentation resolver prefers a SAVED preference over the
/// stored value.  An older pipeline that persisted the pre-PMG accent into
/// the preference document would keep the device rendering pre-PMG colors
/// forever; this table remaps exactly those recognized legacy accents (the
/// original bright seeds, the dark-muted Slate Blue family, the light-muted
/// recommended family, and the device-era Contact-through-Task values) to the
/// final PMG accents.  Any accent not listed is a genuine user customization
/// and is preserved.
final class _LegacySavedAccentMigration {
  const _LegacySavedAccentMigration({
    required this.legacyArgb,
    required this.nextArgb,
    this.nextSurfaceArgb,
  });

  final int legacyArgb;
  final int nextArgb;

  /// Optional explicit surface for hops that converge to a locked PMG pair.
  /// When null the surface is derived through the light-muted pipeline.
  final int? nextSurfaceArgb;
}

const _legacySavedAccentMigrations =
    <String, List<_LegacySavedAccentMigration>>{
      // The exact locked pairs carry their explicit dark surface so the
      // preference document converges to the PMG pair verbatim.
      SystemEventTypeKeys.jobApplication: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFAB47BC,
          nextArgb: 0xFFEBC766,
          nextSurfaceArgb: 0xFF4C4942,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF676DA2,
          nextArgb: 0xFFEBC766,
          nextSurfaceArgb: 0xFF4C4942,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFC98BA7,
          nextArgb: 0xFFEBC766,
          nextSurfaceArgb: 0xFF4C4942,
        ),
        // Device-era dusty mauve observed in the saved document on the Infinix.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFA15E79,
          nextArgb: 0xFFEBC766,
          nextSurfaceArgb: 0xFF4C4942,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFB98CA8,
          nextArgb: 0xFFEBC766,
          nextSurfaceArgb: 0xFF4C4942,
        ),
      ],
      SystemEventTypeKeys.scriptureStudy: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF7CB342,
          nextArgb: 0xFFDE9EDA,
          nextSurfaceArgb: 0xFF4C464A,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF5946B9,
          nextArgb: 0xFFDE9EDA,
          nextSurfaceArgb: 0xFF4C464A,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFD79A95,
          nextArgb: 0xFFDE9EDA,
          nextSurfaceArgb: 0xFF4C464A,
        ),
        // Device-era dusty rose observed in the saved document on the Infinix
        // (the same legacy tone the old pipeline also used for Ministering).
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFBB7772,
          nextArgb: 0xFFDE9EDA,
          nextSurfaceArgb: 0xFF4C464A,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFC27E6E,
          nextArgb: 0xFFDE9EDA,
          nextSurfaceArgb: 0xFF4C464A,
        ),
      ],
      SystemEventTypeKeys.exercise: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFFF7043,
          nextArgb: 0xFFEAA15D,
          nextSurfaceArgb: 0xFF474141,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF86CC7B,
          nextArgb: 0xFFEAA15D,
          nextSurfaceArgb: 0xFF474141,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF9CCB8F,
          nextArgb: 0xFFEAA15D,
          nextSurfaceArgb: 0xFF474141,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF90AE79,
          nextArgb: 0xFFEAA15D,
          nextSurfaceArgb: 0xFF474141,
        ),
      ],
      SystemEventTypeKeys.budgetReview: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF42A5F5,
          nextArgb: 0xFFBFA384,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFA5975F,
          nextArgb: 0xFFBFA384,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFD9A080,
          nextArgb: 0xFFBFA384,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFD28482,
          nextArgb: 0xFFBFA384,
        ),
      ],
      SystemEventTypeKeys.meaningfulConnection: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFEC407A,
          nextArgb: 0xFFB0A971,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFBB7772,
          nextArgb: 0xFFB0A971,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFCCB879,
          nextArgb: 0xFFB0A971,
        ),
      ],
      SystemEventTypeKeys.templeVisit: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFB39DDB,
          nextArgb: 0xFF98CED8,
          nextSurfaceArgb: 0xFF454B4B,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF66C7B3,
          nextArgb: 0xFF98CED8,
          nextSurfaceArgb: 0xFF454B4B,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF82C8BE,
          nextArgb: 0xFF98CED8,
          nextSurfaceArgb: 0xFF454B4B,
        ),
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF63C7B3,
          nextArgb: 0xFF98CED8,
          nextSurfaceArgb: 0xFF454B4B,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF77ADA9,
          nextArgb: 0xFF98CED8,
          nextSurfaceArgb: 0xFF454B4B,
        ),
      ],
      SystemEventTypeKeys.contact: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF7BB37D,
          nextArgb: 0xFF76B181,
          nextSurfaceArgb: 0xFF494E48,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF74C385,
          nextArgb: 0xFF76B181,
          nextSurfaceArgb: 0xFF494E48,
        ),
      ],
      SystemEventTypeKeys.meeting: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFE57A88,
          nextArgb: 0xFFE27386,
          nextSurfaceArgb: 0xFF463D40,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFF07175,
          nextArgb: 0xFFE27386,
          nextSurfaceArgb: 0xFF463D40,
        ),
      ],
      SystemEventTypeKeys.studyOrPlan: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF9E75CB,
          nextArgb: 0xFFA272C8,
          nextSurfaceArgb: 0xFF47444B,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFA474DC,
          nextArgb: 0xFFA272C8,
          nextSurfaceArgb: 0xFF47444B,
        ),
      ],
      SystemEventTypeKeys.service: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFD5E7EE,
          nextArgb: 0xFFDEEDF2,
          nextSurfaceArgb: 0xFF404447,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFD3EEF8,
          nextArgb: 0xFFDEEDF2,
          nextSurfaceArgb: 0xFF404447,
        ),
      ],
      SystemEventTypeKeys.work: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFD5E7EE,
          nextArgb: 0xFFDEEDF2,
          nextSurfaceArgb: 0xFF404447,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFCFE3EC,
          nextArgb: 0xFFDEEDF2,
          nextSurfaceArgb: 0xFF404447,
        ),
        // Post-VS-11 planner polish P-01D: a saved Work pair still on the
        // old icy default migrates to the muted steel/slate-blue pair.
        // Service keeps its approved icy family; a Work accent that was
        // explicitly customized to something else is untouched (no hop).
        // The document reconcile applies one hop per read, so a Work pair
        // persisted on an even older pre-delta accent (0xFFCFE3EC) reaches
        // the steel pair on the next read; both hops are idempotent.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFDEEDF2,
          nextArgb: 0xFFA9BEC9,
          nextSurfaceArgb: 0xFF43494D,
        ),
      ],
      SystemEventTypeKeys.travel: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFE5B2C5,
          nextArgb: 0xFFECC7D8,
          nextSurfaceArgb: 0xFF4F4D4E,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFECAEC6,
          nextArgb: 0xFFECC7D8,
          nextSurfaceArgb: 0xFF4F4D4E,
        ),
      ],
      SystemEventTypeKeys.meal: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFE5D1B8,
          nextArgb: 0xFFE1CFB9,
          nextSurfaceArgb: 0xFF4B4744,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFFEAD5B8,
          nextArgb: 0xFFE1CFB9,
          nextSurfaceArgb: 0xFF4B4744,
        ),
      ],
      SystemEventTypeKeys.other: <_LegacySavedAccentMigration>[
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF8C8C8C,
          nextArgb: 0xFF868A8D,
          nextSurfaceArgb: 0xFF494949,
        ),
        // The previous approved default (pre-delta) also converges.
        _LegacySavedAccentMigration(
          legacyArgb: 0xFF8E9599,
          nextArgb: 0xFF868A8D,
          nextSurfaceArgb: 0xFF494949,
        ),
      ],
    };

/// Old → new migration hops for Event Type stored `color_value` defaults.
///
/// Each hop rewrites a stored `color_value` ONLY when it still exactly
/// matches the hop's old value, so a user who customized a color keeps it and
/// the migration is idempotent (a migrated row no longer matches any hop).
/// The hops chain every older approved default — original bright seeds,
/// dark-muted Slate Blue, light-muted recommended, and the device-era
/// light-muted Contact-through-Task values — toward the final PMG faded
/// family (Parts 11-15 Final Planner correction), so installs on ANY older
/// default converge without ever touching explicit custom hex choices.
const _lockedWliLegacySeedColors = <_LockedWliColorMigration>[
  // Every hop now converges on the exact locked PMG accents. Budget Review
  // and Ministering Visit are NOT remapped and keep their prior values.
  // First hop: installs on the original bright legacy seeds.
  _LockedWliColorMigration(
    id: SystemEventTypeIds.jobApplication,
    legacyArgb: 0xFFAB47BC,
    nextArgb: 0xFFEBC766,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.scriptureStudy,
    legacyArgb: 0xFF7CB342,
    nextArgb: 0xFFDE9EDA,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.exercise,
    legacyArgb: 0xFFFF7043,
    nextArgb: 0xFFEAA15D,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.budgetReview,
    legacyArgb: 0xFF42A5F5,
    nextArgb: 0xFFBFA384,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.meaningfulConnection,
    legacyArgb: 0xFFEC407A,
    nextArgb: 0xFFB0A971,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.templeVisit,
    legacyArgb: 0xFFB39DDB,
    nextArgb: 0xFF98CED8,
  ),
  // Second hop: installs that already carry the previous approved default
  // (dark-muted Slate Blue family).
  _LockedWliColorMigration(
    id: SystemEventTypeIds.jobApplication,
    legacyArgb: 0xFF676DA2,
    nextArgb: 0xFFEBC766,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.scriptureStudy,
    legacyArgb: 0xFF5946B9,
    nextArgb: 0xFFDE9EDA,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.exercise,
    legacyArgb: 0xFF86CC7B,
    nextArgb: 0xFFEAA15D,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.budgetReview,
    legacyArgb: 0xFFA5975F,
    nextArgb: 0xFFBFA384,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.meaningfulConnection,
    legacyArgb: 0xFFBB7772,
    nextArgb: 0xFFB0A971,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.templeVisit,
    legacyArgb: 0xFF66C7B3,
    nextArgb: 0xFF98CED8,
  ),
  // Third hop: installs that already carry the previous light-muted
  // recommended mapping.
  _LockedWliColorMigration(
    id: SystemEventTypeIds.jobApplication,
    legacyArgb: 0xFFC98BA7,
    nextArgb: 0xFFEBC766,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.scriptureStudy,
    legacyArgb: 0xFFD79A95,
    nextArgb: 0xFFDE9EDA,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.exercise,
    legacyArgb: 0xFF9CCB8F,
    nextArgb: 0xFFEAA15D,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.budgetReview,
    legacyArgb: 0xFFD9A080,
    nextArgb: 0xFFBFA384,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.meaningfulConnection,
    legacyArgb: 0xFFCCB879,
    nextArgb: 0xFFB0A971,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.templeVisit,
    legacyArgb: 0xFF82C8BE,
    nextArgb: 0xFF98CED8,
  ),
  // Device-era light-muted values observed on the physical Infinix.
  _LockedWliColorMigration(
    id: SystemEventTypeIds.templeVisit,
    legacyArgb: 0xFF63C7B3,
    nextArgb: 0xFF98CED8,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.budgetReview,
    legacyArgb: 0xFFD28482,
    nextArgb: 0xFFBFA384,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.contact,
    legacyArgb: 0xFF7BB37D,
    nextArgb: 0xFF76B181,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.meeting,
    legacyArgb: 0xFFE57A88,
    nextArgb: 0xFFE27386,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.studyOrPlan,
    legacyArgb: 0xFF9E75CB,
    nextArgb: 0xFFA272C8,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.service,
    legacyArgb: 0xFFD5E7EE,
    nextArgb: 0xFFDEEDF2,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.work,
    legacyArgb: 0xFFD5E7EE,
    nextArgb: 0xFFDEEDF2,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.travel,
    legacyArgb: 0xFFE5B2C5,
    nextArgb: 0xFFECC7D8,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.meal,
    legacyArgb: 0xFFE5D1B8,
    nextArgb: 0xFFE1CFB9,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.other,
    legacyArgb: 0xFF8C8C8C,
    nextArgb: 0xFF868A8D,
  ),
  // Final hop: the previous approved defaults for the mapped Contact-
  // through-Task and fixed six types converge to the exact PMG accents.
  _LockedWliColorMigration(
    id: SystemEventTypeIds.jobApplication,
    legacyArgb: 0xFFB98CA8,
    nextArgb: 0xFFEBC766,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.scriptureStudy,
    legacyArgb: 0xFFC27E6E,
    nextArgb: 0xFFDE9EDA,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.exercise,
    legacyArgb: 0xFF90AE79,
    nextArgb: 0xFFEAA15D,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.templeVisit,
    legacyArgb: 0xFF77ADA9,
    nextArgb: 0xFF98CED8,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.contact,
    legacyArgb: 0xFF74C385,
    nextArgb: 0xFF76B181,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.meeting,
    legacyArgb: 0xFFF07175,
    nextArgb: 0xFFE27386,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.studyOrPlan,
    legacyArgb: 0xFFA474DC,
    nextArgb: 0xFFA272C8,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.service,
    legacyArgb: 0xFFD3EEF8,
    nextArgb: 0xFFDEEDF2,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.work,
    legacyArgb: 0xFFCFE3EC,
    nextArgb: 0xFFDEEDF2,
  ),
  // Post-VS-11 planner polish P-01D: the final Work hop leaves the shared
  // icy Service family for the muted steel/slate-blue pair. Only rows still
  // on the untouched legacy default converge; Service rows keep 0xFFDEEDF2.
  _LockedWliColorMigration(
    id: SystemEventTypeIds.work,
    legacyArgb: 0xFFDEEDF2,
    nextArgb: 0xFFA9BEC9,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.travel,
    legacyArgb: 0xFFECAEC6,
    nextArgb: 0xFFECC7D8,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.meal,
    legacyArgb: 0xFFEAD5B8,
    nextArgb: 0xFFE1CFB9,
  ),
  _LockedWliColorMigration(
    id: SystemEventTypeIds.other,
    legacyArgb: 0xFF8E9599,
    nextArgb: 0xFF868A8D,
  ),
];
