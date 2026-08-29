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
