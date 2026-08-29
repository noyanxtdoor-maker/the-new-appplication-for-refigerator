import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/planner/presentation/task_preview_sheet.dart';

final class TaskDetailScreen extends ConsumerStatefulWidget {
  const TaskDetailScreen({required this.taskId, super.key});

  final String taskId;

  @override
  ConsumerState<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

final class _TaskDetailScreenState extends ConsumerState<TaskDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return TaskPreviewSheet(taskId: widget.taskId);
    /*
    return Scaffold(
      appBar: InternalAppBar(
        title: FutureBuilder<PlannerTask?>(
          future: _task,
          builder: (context, snapshot) => Text(snapshot.data?.title ?? 'Task'),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Edit Task',
            onPressed: _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<PlannerTask?>(
          future: _task,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final task = snapshot.data;
            if (task == null) {
              return const Center(child: Text('Task not found.'));
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                FutureBuilder<_TaskReportingSnapshot>(
                  future: _reporting,
                  builder: (context, reporting) {
                    final data = reporting.data ?? const _TaskReportingSnapshot.empty();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _TaskDetailSection(
                          title: 'Current Status',
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _statusButton(null, 'Unreported', data.currentOutcome),
                              _statusButton(OutcomeKind.didNotHappen, 'Did Not Attempt', data.currentOutcome),
                              _statusButton(OutcomeKind.partiallyCompleted, 'Missed', data.currentOutcome),
                              _statusButton(OutcomeKind.completedHappened, 'Completed', data.currentOutcome),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
                PlannerDetailField(
                  key: const Key('task-detail-title'),
                  icon: Icons.title_outlined,
                  label: 'Title',
                  value: task.title,
                ),
                PlannerDetailField(
                  icon: Icons.calendar_today_outlined,
                  label: 'Date',
                  value: task.dueDate?.iso8601 ?? 'No due date',
                ),
                if (task.dueMinute != null)
                  PlannerDetailField(
                    icon: Icons.schedule,
                    label: 'Time',
                    value: _time(task.dueMinute!),
                  ),
                PlannerDetailField(
                  icon: Icons.repeat,
                  label: 'Repeats',
                  value: _recurrenceLabel(task.recurrence),
                ),
                if (task.notes != null)
                  PlannerDetailRow(icon: Icons.notes, label: task.notes!),
                PlannerDetailField(
                  icon: Icons.people_outline,
                  label: 'Contacts',
                  value: task.people.isEmpty ? 'None' : task.people.join(', '),
                ),
                if (task.goalId != null)
                  const PlannerDetailField(
                    icon: Icons.flag_outlined,
                    label: 'Life Goal',
                    value: 'Linked for completion reporting',
                  ),
                if (task.pathwayContextLabels.isNotEmpty)
                  PlannerDetailRow(
                    icon: Icons.layers_outlined,
                    label: task.pathwayContextLabels.join(', '),
                  ),
                FutureBuilder<_TaskReportingSnapshot>(
                  future: _reporting,
                  builder: (context, reporting) {
                    final history =
                        reporting.data?.history ?? const <OutcomeReport>[];
                    if (history.isEmpty) return const SizedBox.shrink();
                    return _TaskDetailSection(
                      title: 'Activity History',
                      child: Column(
                        children: <Widget>[
                          for (final report in history)
                            _TaskScopedHistoryRow(report: report),
                        ],
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
    */
  }

}
