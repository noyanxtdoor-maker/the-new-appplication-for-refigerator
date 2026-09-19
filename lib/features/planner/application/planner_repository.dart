import 'package:rmplanner/features/notifications/domain/task_reminder_occurrence.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

abstract interface class PlannerCalendarSource {
  Future<List<PlannerCalendarItem>> readDay({
    required String profileId,
    required PlannerDate date,
  });
}

final class EmptyPlannerCalendarSource implements PlannerCalendarSource {
  const EmptyPlannerCalendarSource();

  @override
  Future<List<PlannerCalendarItem>> readDay({
    required String profileId,
    required PlannerDate date,
  }) async {
    return const <PlannerCalendarItem>[];
  }
}

abstract interface class PlannerTaskContextSource {
  Future<PlannerTaskContext> readContext(String taskId);
}

/// Optional batch capability for [PlannerTaskContextSource].
///
/// Production Drift sources implement this so a Planner day read can load the
/// Task context for every Task row in one/chunk set-based query instead of one
/// query per Task.  Callers must fall back to the single-Task
/// [PlannerTaskContextSource.readContext] contract when a source does not
/// implement this capability.
abstract interface class PlannerTaskContextBatchSource {
  /// Returns Task contexts keyed by Task ID for the given Task IDs.  A Task
  /// with no matching links has no map entry; callers treat a missing entry
  /// as an empty [PlannerTaskContext].
  Future<Map<String, PlannerTaskContext>> readContexts(
    Iterable<String> taskIds,
  );
}

final class EmptyPlannerTaskContextSource implements PlannerTaskContextSource {
  const EmptyPlannerTaskContextSource();

  @override
  Future<PlannerTaskContext> readContext(String taskId) async {
    return const PlannerTaskContext();
  }
}

/// Canonical bounded Task projection used by reminder reconciliation. Date-
/// only and non-incomplete Tasks are excluded by the production source.
abstract interface class PlannerTaskReminderSource {
  Future<List<PlannerTask>> readPendingReminderTasks({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  });
}

/// Optional bounded RECURRENCE-aware Task reminder projection
/// (contract section 37 TASK RECURRENCE FIX).
///
/// [PlannerTaskReminderSource] reads anchor due dates only, so a recurring Task
/// whose anchor fell outside the window is invisible to reminders even though
/// canonical truth projects it inside the window.  This port instead returns
/// `(task, projectedDate)` pairs derived from the canonical
/// `PlannerTask.projectsOn` projection, bounded by the caller's date range.
///
/// It deliberately does NOT mutate `dueDate`, duplicate Task source rows or add
/// per-occurrence persistence.  The anchor-only query remains available to
/// unrelated consumers.
abstract interface class PlannerTaskReminderOccurrenceSource {
  Future<List<TaskReminderOccurrence>> readTaskReminderOccurrences({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  });
}

abstract interface class PlannerBadgeTaskSource {
  Future<List<String>> readActionableBadgeTasks({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  });
}

/// Optional canonical capability for the dedicated Tasks screen.
///
/// Returns EVERY persisted Task for the profile — Incomplete, Completed and
/// historical alike — ordered by due date then creation time.  There is no
/// retention window: a completed Task stays findable, exactly like the
/// Planner day projection that produced it.  A source that does not
/// implement this capability has no universe.
abstract interface class PlannerTaskUniverseSource {
  Future<List<PlannerTask>> readTaskUniverse({required String profileId});
}

enum TaskHardDeleteOutcome { deleted, notFound, integrityFailure }

final class TaskHardDeleteIntegrityException implements Exception {
  const TaskHardDeleteIntegrityException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class TaskHistoricalEffectReader {
  Future<bool> hasReportOrLedgerEffect(String taskId);
}

final class NoTaskHistoricalEffects implements TaskHistoricalEffectReader {
  const NoTaskHistoricalEffects();

  @override
  Future<bool> hasReportOrLedgerEffect(String taskId) async => false;
}

abstract interface class PlannerRepository {
  Future<PlannerDay> readDay({
    required String profileId,
    required PlannerDate selectedDate,
    required PlannerDate today,
  });

  Future<PlannerTask?> readTask({
    required String profileId,
    required String taskId,
  });

  Future<PlannerTask> saveTask({
    required String profileId,
    required PlannerTaskDraft draft,
    bool confirmLinkedTypeTransfer = false,
  });

  Future<TaskStatusChangeOutcome> changeTaskStatus({
    required String profileId,
    required String taskId,
    required PlannerTaskStatus target,
    required String operationId,
    String? reason,
    bool confirmLinkedTypeTransfer = false,
  });

  /// Deletes only a Task and data proven to be owned by that Task.
  ///
  /// Test implementations retain a conservative default; the production Drift
  /// repository provides the profile-scoped transaction and integrity checks.
  Future<TaskHardDeleteOutcome> hardDeleteTask({
    required String profileId,
    required String taskId,
  }) async => TaskHardDeleteOutcome.notFound;
}
