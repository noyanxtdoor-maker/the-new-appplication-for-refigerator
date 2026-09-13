import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

/// One PROJECTED Task reminder occurrence (contract section 37).
///
/// A Task keeps its whole-source lifecycle: recurrence is a projection over
/// dates, never a second persisted occurrence record and never a rewritten
/// `dueDate`.  This value type pairs the canonical Task with the single date the
/// reminder is projected for, so reminder code can key, schedule and cancel per
/// date without inventing per-occurrence Task persistence or per-occurrence
/// completion semantics.
///
/// Only INCOMPLETE and TIMED Tasks produce occurrences.  A date-only Task has no
/// truthful reminder time and therefore never appears here.
final class TaskReminderOccurrence {
  const TaskReminderOccurrence({
    required this.task,
    required this.projectedDate,
  });

  final PlannerTask task;
  final PlannerDate projectedDate;

  /// The one occurrence identity derivation for Task reminders.
  ///
  /// Section 12 key shape:
  /// `reminder:task:<profileId>:task:<taskId>:<projectedDate>:base`.
  String get occurrenceId => 'task:${task.id}:${projectedDate.iso8601}';

  @override
  bool operator ==(Object other) =>
      other is TaskReminderOccurrence &&
      task.id == other.task.id &&
      projectedDate == other.projectedDate;

  @override
  int get hashCode => Object.hash(task.id, projectedDate);

  @override
  String toString() =>
      'TaskReminderOccurrence(${task.id}, ${projectedDate.iso8601})';
}
