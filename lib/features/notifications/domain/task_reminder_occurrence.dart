import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

/// A bounded reminder projection for one Task on one projected date.
///
/// Recurrence arithmetic stays in [PlannerTask.projectsOn]; this value type
/// never mutates `task.dueDate` and never creates per-occurrence Task rows or
/// per-occurrence completion semantics.
final class TaskReminderOccurrence {
  const TaskReminderOccurrence({
    required this.task,
    required this.projectedDate,
  });

  final PlannerTask task;
  final PlannerDate projectedDate;

  String get occurrenceId => 'task:${task.id}:${projectedDate.iso8601}';
}
