import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/data/task_goal_contribution_engine.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

abstract interface class TaskWriteGuard {
  Future<void> beforeCommit();
}

final class AllowTaskWrites implements TaskWriteGuard {
  const AllowTaskWrites();

  @override
  Future<void> beforeCommit() async {}
}

final class DriftPlannerRepository implements PlannerRepository {
  const DriftPlannerRepository({
    required this.database,
    required this.clock,
    this.calendarSource = const EmptyPlannerCalendarSource(),
    this.taskContextSource = const EmptyPlannerTaskContextSource(),
    this.historicalEffectReader = const NoTaskHistoricalEffects(),
    this.writeGuard = const AllowTaskWrites(),
  });

  final AppDatabase database;
  final AppClock clock;
  final PlannerCalendarSource calendarSource;
  final PlannerTaskContextSource taskContextSource;
  final TaskHistoricalEffectReader historicalEffectReader;
  final TaskWriteGuard writeGuard;

  @override
  Future<TaskStatusChangeOutcome> changeTaskStatus({
    required String profileId,
    required String taskId,
    required PlannerTaskStatus target,
    required String operationId,
    String? reason,
    bool confirmLinkedTypeTransfer = false,
  }) async {
    // Status changes never silently move a completed Task's contribution to a
    // different Event Type.  The explicit transfer flag is accepted here for
    // repository symmetry with saveTask; relinking is performed by saveTask
    // so a status transition remains a single, idempotent operation.
    // The flag is intentionally unused here; relinking is handled by the
    // atomic saveTask path, while status changes only change completion state.
    final hasEffects = await historicalEffectReader.hasReportOrLedgerEffect(
      taskId,
    );

    return database.transaction(() async {
      final existingOperation =
          await (database.select(database.taskStatusChanges)
                ..where((table) => table.operationId.equals(operationId))
                ..limit(1))
              .getSingleOrNull();
      if (existingOperation != null) {
        return TaskStatusChangeOutcome.unchanged;
      }

      final current = await readTask(profileId: profileId, taskId: taskId);
      if (current == null) {
        throw StateError('Task not found');
      }
      final activeContribution = await _readActiveContribution(taskId);
      final outcome = TaskStatusPolicy.evaluate(
        task: current,
        target: target,
        hasReportOrLedgerEffect: hasEffects,
        hasReversibleGoalContribution: activeContribution != null,
      );
      if (outcome != TaskStatusChangeOutcome.changed) {
        return outcome;
      }

      final changedAt = clock.nowUtc();
      final linkedType = await _resolveStoredTaskLink(
        profileId: profileId,
        task: current,
      );
      await database
          .into(database.taskStatusChanges)
          .insert(
            TaskStatusChangesCompanion.insert(
              id: operationId,
              profileId: profileId,
              taskId: taskId,
              operationId: operationId,
              fromStatus: current.status.name,
              toStatus: target.name,
              reason: Value<String?>(_normalizeOptional(reason)),
              // B3.2 (D2): the direct Goal link is not an Event Type, so a
              // status-change record carries no Event-Type snapshot for
              // Goal-linked contributions.  Goal identity lives in goal_id.
              activityTypeId: const Value<String?>(null),
              activityTypeStableKeySnapshot: const Value<String?>(null),
              activityTypeLabelSnapshot: const Value<String?>(null),
              changedAtUtc: changedAt,
            ),
          );
      await (database.update(database.plannerTasks)..where(
            (table) =>
                table.id.equals(taskId) & table.profileId.equals(profileId),
          ))
          .write(
            PlannerTasksCompanion(
              status: Value<String>(target.name),
              updatedAtUtc: Value<DateTime>(changedAt),
            ),
          );
      switch (target) {
        case PlannerTaskStatus.completed:
          await _reconcileContribution(
            profileId: profileId,
            task: current,
            linkedType: linkedType,
            changedAt: changedAt,
          );
        case PlannerTaskStatus.incomplete:
          await _reverseContribution(activeContribution, changedAt);
        case PlannerTaskStatus.skipped:
        case PlannerTaskStatus.cancelled:
          // These states do not create or remove a Goal contribution.  A
          // completed -> cancelled correction is rejected by policy unless a
          // caller first returns the task to incomplete.
          break;
      }
      await writeGuard.beforeCommit();
      return TaskStatusChangeOutcome.changed;
    });
  }

  @override
  Future<TaskHardDeleteOutcome> hardDeleteTask({
    required String profileId,
    required String taskId,
  }) async {
    return database.transaction(() async {
      final task =
          await (database.select(database.plannerTasks)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.id.equals(taskId),
                )
                ..limit(1))
              .getSingleOrNull();
      if (task == null) return TaskHardDeleteOutcome.notFound;

      final taskLinks =
          await (database.select(database.taskEventLinks)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.taskId.equals(taskId),
              ))
              .get();
      final taskLinkIds = taskLinks.map((row) => row.id).toSet();

      // Task-source rows are the sole ownership root. Corrections form a
      // closure so a historical descendant is removed only when it explicitly
      // corrects a proven Task-owned report.
      final allProfileReports = await (database.select(
        database.outcomeReports,
      )..where((table) => table.profileId.equals(profileId))).get();
      final ownedReportIds = allProfileReports
          .where(
            (row) =>
                row.sourceType == OutcomeSourceType.task.name &&
                row.sourceId == taskId,
          )
          .map((row) => row.id)
          .toSet();
      var expanded = true;
      while (expanded) {
        expanded = false;
        for (final row in allProfileReports) {
          final corrects = row.correctsReportId;
          if (corrects != null &&
              ownedReportIds.contains(corrects) &&
              ownedReportIds.add(row.id)) {
            expanded = true;
          }
        }
      }

      final allProfileLedgerRows = await (database.select(
        database.activityLedgerEntries,
      )..where((table) => table.profileId.equals(profileId))).get();
      final ownedLedgerRows = allProfileLedgerRows
          .where((row) => ownedReportIds.contains(row.sourceReportId))
          .toList(growable: false);
      final ownedLedgerIds = ownedLedgerRows.map((row) => row.id).toSet();
      for (final row in ownedLedgerRows) {
        final referencedIds = <String>{
          if (row.reversalOfEntryId != null) row.reversalOfEntryId!,
          if (row.replacesEntryId != null) row.replacesEntryId!,
        };
        if (referencedIds.any((id) => !ownedLedgerIds.contains(id))) {
          throw TaskHardDeleteIntegrityException(
            'Task $taskId has a ledger reference outside its proven report closure.',
          );
        }
      }

      if (ownedLedgerIds.isNotEmpty) {
        await (database.delete(database.activityLedgerEntries)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.isIn(ownedLedgerIds),
            ))
            .go();
      }
      if (ownedReportIds.isNotEmpty) {
        await (database.delete(
          database.outcomeReportContributionDrafts,
        )..where((table) => table.reportId.isIn(ownedReportIds))).go();
        await (database.delete(database.outcomeReports)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.isIn(ownedReportIds),
            ))
            .go();
      }
      if (taskLinkIds.isNotEmpty) {
        await (database.delete(database.taskEventLinkHistory)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  (table.linkId.isIn(taskLinkIds) |
                      table.relatedLinkId.isIn(taskLinkIds)),
            ))
            .go();
      }
      await (database.delete(database.taskEventLinks)..where(
            (table) =>
                table.profileId.equals(profileId) & table.taskId.equals(taskId),
          ))
          .go();
      await (database.delete(database.taskContactLinks)..where(
            (table) =>
                table.profileId.equals(profileId) & table.taskId.equals(taskId),
          ))
          .go();
      await (database.delete(database.taskGoalContributions)..where(
            (table) =>
                table.profileId.equals(profileId) & table.taskId.equals(taskId),
          ))
          .go();
      await (database.delete(database.taskStatusChanges)..where(
            (table) =>
                table.profileId.equals(profileId) & table.taskId.equals(taskId),
          ))
          .go();
      final deleted =
          await (database.delete(database.plannerTasks)..where(
                (table) =>
                    table.profileId.equals(profileId) & table.id.equals(taskId),
              ))
              .go();
      if (deleted != 1) {
        throw TaskHardDeleteIntegrityException(
          'Task $taskId disappeared before hard delete completed.',
        );
      }
      await writeGuard.beforeCommit();
      return TaskHardDeleteOutcome.deleted;
    });
  }

  @override
  Future<PlannerDay> readDay({
    required String profileId,
    required PlannerDate selectedDate,
    required PlannerDate today,
  }) async {
    final taskRows =
        await (database.select(database.plannerTasks)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(PlannerTasks)>[
                (table) => OrderingTerm.asc(table.dueDate),
                (table) => OrderingTerm.asc(table.createdAtUtc),
              ]))
            .get();
    // S1A: when the Task context source supports it, load every Task's
    // context in one/chunk set-based query instead of one query per Task.
    // A missing map entry (a Task with no links) becomes an empty context so
    // no per-Task fallback query is issued for the batched path.
    final taskContextBatchSource =
        taskContextSource is PlannerTaskContextBatchSource
        ? taskContextSource as PlannerTaskContextBatchSource
        : null;
    final batchContexts = taskContextBatchSource == null
        ? null
        : await taskContextBatchSource.readContexts(
            taskRows.map((row) => row.id),
          );
    final contextsByTask = batchContexts == null
        ? null
        : <String, PlannerTaskContext>{
            for (final row in taskRows)
              row.id: batchContexts[row.id] ?? const PlannerTaskContext(),
          };
    final outcomesByTask = await _readEffectiveTaskOutcomes(
      profileId: profileId,
      taskIds: taskRows.map((row) => row.id),
    );
    final allTasks = await Future.wait(
      taskRows.map(
        (row) => _mapTask(
          row,
          preloadedContext: contextsByTask?[row.id],
          reportedOutcome: outcomesByTask[row.id],
        ),
      ),
    );
    final calendarItems = await calendarSource.readDay(
      profileId: profileId,
      date: selectedDate,
    );
    final nowLocal = clock.nowUtc().toLocal();
    final awaiting = calendarItems
        .where((item) => item.isAwaitingReport(nowLocal))
        .toList(growable: false);

    final tasks = allTasks
        .where(
          (task) =>
              task.projectsOn(selectedDate) ||
              (task.status == PlannerTaskStatus.incomplete &&
                  task.dueDate == null &&
                  selectedDate == today),
        )
        .toList(growable: false);
    final overdueTasks = allTasks
        .where(
          (task) =>
              task.isOverdueOn(selectedDate) && !task.projectsOn(selectedDate),
        )
        .toList(growable: false);
    final completedTasks = allTasks
        .where(
          (task) =>
              task.status == PlannerTaskStatus.completed &&
              (task.dueDate == selectedDate ||
                  (task.dueDate == null && selectedDate == today)),
        )
        .toList(growable: false);

    final changes = <PlannerChangeItem>[
      for (final task in allTasks)
        if (task.isHistorical &&
            (task.dueDate == selectedDate ||
                (task.dueDate == null && selectedDate == today)))
          PlannerChangeItem(
            id: task.id,
            title: task.title,
            label: _taskStatusLabel(task.status),
            isTask: true,
          ),
      for (final event in calendarItems)
        if (event.isChange)
          PlannerChangeItem(
            id: event.id,
            title: event.title,
            label: event.state == PlannerEventState.cancelled
                ? 'Cancelled event'
                : 'Rescheduled event',
            isTask: false,
            eventId: event.eventId,
            originalDate: event.originalDate,
          ),
    ];

    return PlannerDay(
      selectedDate: selectedDate,
      allDayEvents: calendarItems
          .where(_isVisibleTimelineState)
          .where((item) => item.timing == PlannerEventTiming.allDay)
          .toList(growable: false),
      timedEvents: calendarItems
          .where(_isVisibleTimelineState)
          .where((item) => item.timing == PlannerEventTiming.timed)
          .toList(growable: false),
      tasks: tasks,
      overdueTasks: overdueTasks,
      completedTasks: completedTasks,
      awaitingReportEvents: awaiting,
      changes: changes,
    );
  }

  @override
  Future<PlannerTask?> readTask({
    required String profileId,
    required String taskId,
  }) async {
    final row =
        await (database.select(database.plannerTasks)
              ..where(
                (table) =>
                    table.id.equals(taskId) & table.profileId.equals(profileId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : await _mapTask(row);
  }

  @override
  Future<PlannerTask> saveTask({
    required String profileId,
    required PlannerTaskDraft draft,
    bool confirmLinkedTypeTransfer = false,
  }) async {
    final normalized = draft.normalized();
    await database.transaction(() async {
      final existing =
          await (database.select(database.plannerTasks)
                ..where(
                  (table) =>
                      table.id.equals(normalized.id) &
                      table.profileId.equals(profileId),
                )
                ..limit(1))
              .getSingleOrNull();
      final now = clock.nowUtc();
      final linkedType = await _resolveTaskLink(
        profileId: profileId,
        draft: normalized,
      );
      // B3.2 (D2): the Goal link is the ONLY contribution mover.  Event-Type
      // edits are independent metadata and never trigger the transfer guard.
      final oldGoalId = _normalizeOptional(existing?.goalId);
      final newGoalId = linkedType?.id;
      final linkChanged = oldGoalId != newGoalId;
      if (existing != null &&
          existing.status == PlannerTaskStatus.completed.name &&
          linkChanged &&
          !confirmLinkedTypeTransfer) {
        throw const PlannerTaskValidationException(
          'This completed Task already contributed progress. Confirm the Goal change to move that contribution.',
        );
      }
      final oldContribution = existing == null
          ? null
          : await _readActiveContribution(existing.id);
      if (existing != null &&
          existing.status == PlannerTaskStatus.completed.name &&
          linkChanged) {
        await _reverseContribution(oldContribution, now);
      }
      if (existing == null) {
        await database
            .into(database.plannerTasks)
            .insert(
              PlannerTasksCompanion.insert(
                id: normalized.id,
                profileId: profileId,
                title: normalized.title,
                notes: Value<String?>(normalized.notes),
                dueDate: Value<String?>(normalized.dueDate?.iso8601),
                dueMinute: Value<int?>(normalized.dueMinute),
                recurrenceFrequency: Value<String>(normalized.recurrence.name),
                peopleJson: Value<String>(jsonEncode(normalized.people)),
                requiresReport: Value<bool>(normalized.requiresReport),
                contributionRuleKey: Value<String?>(
                  normalized.contributionRuleKey,
                ),
                // B3.2 (D2): the Goal link is NOT an Event Type.  The
                // linkedActivityType* columns carry the Task's independent
                // Event-Type metadata from the draft; the direct Goal lives in
                // goalId only.
                linkedActivityTypeId: Value<String?>(
                  normalized.linkedActivityTypeId,
                ),
                linkedActivityTypeStableKey: Value<String?>(
                  normalized.linkedActivityTypeStableKey,
                ),
                linkedActivityTypeLabelSnapshot: Value<String?>(
                  normalized.linkedActivityTypeLabelSnapshot,
                ),
                goalId: Value<String?>(normalized.goalId),
                createdAtUtc: now,
                updatedAtUtc: now,
              ),
            );
      } else {
        await (database.update(database.plannerTasks)..where(
              (table) =>
                  table.id.equals(normalized.id) &
                  table.profileId.equals(profileId),
            ))
            .write(
              PlannerTasksCompanion(
                title: Value<String>(normalized.title),
                notes: Value<String?>(normalized.notes),
                dueDate: Value<String?>(normalized.dueDate?.iso8601),
                dueMinute: Value<int?>(normalized.dueMinute),
                recurrenceFrequency: Value<String>(normalized.recurrence.name),
                peopleJson: Value<String>(jsonEncode(normalized.people)),
                requiresReport: Value<bool>(normalized.requiresReport),
                contributionRuleKey: Value<String?>(
                  normalized.contributionRuleKey,
                ),
                // B3.2 (D2): the Goal link is NOT an Event Type.  The
                // linkedActivityType* columns carry the Task's independent
                // Event-Type metadata from the draft; the direct Goal lives in
                // goalId only.
                linkedActivityTypeId: Value<String?>(
                  normalized.linkedActivityTypeId,
                ),
                linkedActivityTypeStableKey: Value<String?>(
                  normalized.linkedActivityTypeStableKey,
                ),
                linkedActivityTypeLabelSnapshot: Value<String?>(
                  normalized.linkedActivityTypeLabelSnapshot,
                ),
                goalId: Value<String?>(normalized.goalId),
                updatedAtUtc: Value<DateTime>(now),
              ),
            );
      }
      if (existing != null &&
          existing.status == PlannerTaskStatus.completed.name) {
        final savedTask = PlannerTask(
          id: normalized.id,
          profileId: profileId,
          title: normalized.title,
          notes: normalized.notes,
          dueDate: normalized.dueDate,
          dueMinute: normalized.dueMinute,
          recurrence: normalized.recurrence,
          people: normalized.people,
          status: PlannerTaskStatus.completed,
          requiresReport: normalized.requiresReport,
          contributionRuleKey: normalized.contributionRuleKey,
          createdAtUtc: existing.createdAtUtc,
          updatedAtUtc: now,
          linkedActivityTypeId: normalized.linkedActivityTypeId,
          linkedActivityTypeStableKey: normalized.linkedActivityTypeStableKey,
          linkedActivityTypeLabelSnapshot: normalized.linkedActivityTypeLabelSnapshot,
          goalId: normalized.goalId,
        );
        await _reconcileContribution(
          profileId: profileId,
          task: savedTask,
          linkedType: linkedType,
          changedAt: now,
        );
      }
      await writeGuard.beforeCommit();
    });

    final saved = await readTask(profileId: profileId, taskId: normalized.id);
    if (saved == null) {
      throw StateError('Task save did not produce a readable record');
    }
    return saved;
  }

  Future<PlannerTask> _mapTask(
    PlannerTaskRow row, {
    PlannerTaskContext? preloadedContext,
    OutcomeKind? reportedOutcome,
  }) async {
    final context =
        preloadedContext ?? await taskContextSource.readContext(row.id);
    return PlannerTask(
      id: row.id,
      profileId: row.profileId,
      title: row.title,
      notes: row.notes,
      dueDate: row.dueDate == null ? null : PlannerDate.parse(row.dueDate!),
      dueMinute: row.dueMinute,
      recurrence: PlannerTaskRecurrence.values.byName(row.recurrenceFrequency),
      people: _decodePeople(row.peopleJson),
      status: PlannerTaskStatus.values.byName(row.status),
      requiresReport: row.requiresReport,
      contributionRuleKey: row.contributionRuleKey,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      linkedEventIds: context.linkedEventIds,
      pathwayContextLabels: context.pathwayContextLabels,
      linkedActivityTypeId: row.linkedActivityTypeId,
      linkedActivityTypeStableKey: row.linkedActivityTypeStableKey,
      linkedActivityTypeLabelSnapshot: row.linkedActivityTypeLabelSnapshot,
      goalId: row.goalId,
      reportedOutcome: reportedOutcome,
    );
  }

  /// Reads the one effective canonical outcome per Task slot in one bounded
  /// query. Historical/superseded reports intentionally do not affect the
  /// Day block's factual status symbol.
  Future<Map<String, OutcomeKind>> _readEffectiveTaskOutcomes({
    required String profileId,
    required Iterable<String> taskIds,
  }) async {
    final ids = taskIds.toList(growable: false);
    if (ids.isEmpty) {
      return const <String, OutcomeKind>{};
    }
    final rows = await (database.select(database.outcomeReports)
          ..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.sourceType.equals(OutcomeSourceType.task.name) &
                table.sourceId.isIn(ids) &
                table.status.equals(OutcomeReportStatus.submitted.name) &
                table.effectiveSlotKey.isNotNull() &
                table.outcome.isNotNull(),
          ))
        .get();
    return <String, OutcomeKind>{
      for (final row in rows) row.sourceId: OutcomeKind.values.byName(row.outcome!),
    };
  }

  Future<TaskGoalContributionLink?> _resolveTaskLink({
    required String profileId,
    required PlannerTaskDraft draft,
  }) {
    // B3.2 (D2): explicit direct Goal is the ONLY resolver.  Event-Type
    // fields are independent metadata and are deliberately not consulted.
    return _contributionEngine.resolve(
      profileId: profileId,
      goalId: draft.goalId,
    );
  }

  Future<TaskGoalContributionLink?> _resolveStoredTaskLink({
    required String profileId,
    required PlannerTask task,
  }) {
    return _contributionEngine.resolve(
      profileId: profileId,
      goalId: task.goalId,
      allowArchived: true,
    );
  }

  Future<TaskGoalContributionRow?> _readActiveContribution(String taskId) {
    return _contributionEngine.readActive(taskId);
  }

  Future<void> _reverseContribution(
    TaskGoalContributionRow? contribution,
    DateTime changedAt,
  ) async {
    await _contributionEngine.reverse(contribution, changedAt);
  }

  Future<void> _reconcileContribution({
    required String profileId,
    required PlannerTask task,
    required TaskGoalContributionLink? linkedType,
    required DateTime changedAt,
  }) async {
    await _contributionEngine.reconcile(
      profileId: profileId,
      taskId: task.id,
      dueDate: task.dueDate,
      linkedType: linkedType,
      changedAt: changedAt,
    );
  }

  TaskGoalContributionEngine get _contributionEngine =>
      TaskGoalContributionEngine(database: database);

  static String? _normalizeOptional(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static List<String> _decodePeople(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List<Object?>) {
        return List<String>.unmodifiable(
          decoded
              .whereType<String>()
              .map((person) => person.trim())
              .where((person) => person.isNotEmpty),
        );
      }
    } on FormatException {
      // Older or manually edited local rows remain readable without people.
    }
    return const <String>[];
  }

  static String _taskStatusLabel(PlannerTaskStatus status) {
    return switch (status) {
      PlannerTaskStatus.incomplete => 'Incomplete',
      PlannerTaskStatus.completed => 'Completed',
      PlannerTaskStatus.skipped => 'Skipped',
      PlannerTaskStatus.cancelled => 'Cancelled',
    };
  }

  /// Normal Planner Day timeline keeps every valid occurrence on the day
  /// regardless of its report outcome. A report outcome (completed,
  /// partially-completed, or did-not-attempt) is a status on the
  /// occurrence, never an existence gate (Post-VS-11 planner polish
  /// P-01A): reporting "Did Not Attempt" must never hide, delete, or
  /// reschedule a valid Event. Only explicit lifecycle actions (cancelled,
  /// rescheduled) remove a row from the timeline, and those surface through
  /// the changes list and awaiting-report surfaces.
  static bool _isVisibleTimelineState(PlannerCalendarItem item) {
    return switch (item.state) {
      PlannerEventState.scheduled ||
      PlannerEventState.completedHappened ||
      PlannerEventState.partiallyCompleted ||
      PlannerEventState.didNotHappen => true,
      PlannerEventState.cancelled || PlannerEventState.rescheduled => false,
    };
  }
}
