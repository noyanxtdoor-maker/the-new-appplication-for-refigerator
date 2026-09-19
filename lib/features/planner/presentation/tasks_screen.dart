import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/planning_navigation.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/task_preview_sheet.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planning_timeline.dart';

/// The single canonical Tasks home (owner law, 2026-09-19).
///
/// Tasks no longer have a second list anywhere — not in the hamburger as a
/// category, never inside Unreported, and (owner decision, 2026-09-20) not as
/// an in-Planner presentation either: the Planner's overflow `Tasks` row opens
/// THIS screen.  Incomplete and Completed read the same canonical Task
/// universe: every persisted Task, with completion state owned by the
/// canonical outcome report that already writes `PlannerTaskStatus`.  There is
/// deliberately NO retention window; a completed Task stays findable, so PMG's
/// seven-day rule is not imported.
///
/// Presentation (owner law, 2026-09-20): the flat, date-grouped timeline with
/// pinned date headers and a rail, NOT one large rounded card per Task.
final class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskUniverseProvider);
    final origin = planningRouteOriginOf(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: InternalAppBar(
          automaticallyImplyLeading: false,
          leading: PlanningBackButton(
            key: const Key('tasks-back'),
            origin: origin,
          ),
          title: const Text('Tasks'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(key: Key('tasks-tab-incomplete'), text: 'Incomplete'),
              Tab(key: Key('tasks-tab-completed'), text: 'Completed'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          key: const Key('tasks-create-fab'),
          heroTag: 'tasks-fab',
          tooltip: 'New Task',
          onPressed: () => unawaited(context.push(RoutePaths.taskCreate)),
          child: const Icon(Icons.add),
        ),
        body: tasks.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, StackTrace stackTrace) =>
              const _TasksMessage('Tasks could not be loaded.'),
          data: (List<PlannerTask> all) => TabBarView(
            children: <Widget>[
              _TaskTimeline(
                key: const Key('tasks-incomplete-list'),
                groups: groupIncompleteTasks(all),
                emptyMessage: 'No incomplete Tasks.',
                tab: _TaskTimelineTab.incomplete,
              ),
              _TaskTimeline(
                key: const Key('tasks-completed-list'),
                groups: groupCompletedTasks(all),
                emptyMessage: 'No completed Tasks yet.',
                tab: _TaskTimelineTab.completed,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _TaskTimelineTab { incomplete, completed }

/// One rendered date group: its label, its stable key prefix and its Tasks.
final class TaskDateGroup {
  const TaskDateGroup({
    required this.label,
    required this.keyPrefix,
    required this.tasks,
  });

  final String label;
  final String keyPrefix;
  final List<PlannerTask> tasks;
}

/// The canonical "no due date" group label.  An undated Task is never dropped
/// and never given a fabricated date — it lands here.
const String taskNoDueDateGroupLabel = 'NO DUE DATE';

/// Incomplete Tasks grouped by their canonical due date, ascending, with the
/// undated group LAST.  Order inside a group is the accepted deterministic
/// order: due time, then creation time, then id.
List<TaskDateGroup> groupIncompleteTasks(List<PlannerTask> all) {
  final tasks = all
      .where((task) => task.status == PlannerTaskStatus.incomplete)
      .toList(growable: false);
  tasks.sort((left, right) {
    final leftDue = left.dueDate;
    final rightDue = right.dueDate;
    if (leftDue != null && rightDue != null) {
      final byDue = leftDue.compareTo(rightDue);
      if (byDue != 0) return byDue;
      final byMinute = (left.dueMinute ?? 24 * 60).compareTo(
        right.dueMinute ?? 24 * 60,
      );
      if (byMinute != 0) return byMinute;
    } else if (leftDue != null) {
      return -1;
    } else if (rightDue != null) {
      return 1;
    }
    final byCreated = left.createdAtUtc.compareTo(right.createdAtUtc);
    if (byCreated != 0) return byCreated;
    return left.id.compareTo(right.id);
  });

  final byDate = <String, List<PlannerTask>>{};
  final labels = <String, String>{};
  final orderedKeys = <String>[];
  final undated = <PlannerTask>[];
  for (final task in tasks) {
    final due = task.dueDate;
    if (due == null) {
      undated.add(task);
      continue;
    }
    final key = due.iso8601;
    final bucket = byDate.putIfAbsent(key, () {
      labels[key] = planningDateSectionLabel(due);
      orderedKeys.add(key);
      return <PlannerTask>[];
    });
    bucket.add(task);
  }
  final groups = <TaskDateGroup>[
    for (final key in orderedKeys)
      TaskDateGroup(
        label: labels[key]!,
        keyPrefix: 'due-$key',
        tasks: List<PlannerTask>.unmodifiable(byDate[key]!),
      ),
  ];
  if (undated.isNotEmpty) {
    groups.add(
      TaskDateGroup(
        label: taskNoDueDateGroupLabel,
        keyPrefix: 'due-none',
        tasks: List<PlannerTask>.unmodifiable(undated),
      ),
    );
  }
  return groups;
}

/// Completed Tasks grouped by the canonical completion date, newest first.
///
/// AUDITED (Astra, 2026-09-20): `PlannerTasks` has NO `completedAtUtc` column,
/// so there is no dedicated completion timestamp to read.  The completion write
/// updates `updatedAtUtc` — already the accepted completion-recency source on
/// this screen — so the local date of `updatedAtUtc` is the documented
/// canonical grouping signal.  No schema change (schema stays 48) and no
/// invented date.
List<TaskDateGroup> groupCompletedTasks(List<PlannerTask> all) {
  final tasks = all
      .where((task) => task.status == PlannerTaskStatus.completed)
      .toList(growable: false);
  tasks.sort((left, right) {
    final byUpdated = right.updatedAtUtc.compareTo(left.updatedAtUtc);
    if (byUpdated != 0) return byUpdated;
    final leftDue = left.dueDate;
    final rightDue = right.dueDate;
    if (leftDue != null && rightDue != null) {
      final byDue = rightDue.compareTo(leftDue);
      if (byDue != 0) return byDue;
    }
    return left.id.compareTo(right.id);
  });

  final byDate = <String, List<PlannerTask>>{};
  final labels = <String, String>{};
  final orderedKeys = <String>[];
  for (final task in tasks) {
    final local = task.updatedAtUtc.toLocal();
    final date = PlannerDate(
      year: local.year,
      month: local.month,
      day: local.day,
    );
    final key = date.iso8601;
    final bucket = byDate.putIfAbsent(key, () {
      labels[key] = planningDateSectionLabel(date);
      orderedKeys.add(key);
      return <PlannerTask>[];
    });
    bucket.add(task);
  }
  return <TaskDateGroup>[
    for (final key in orderedKeys)
      TaskDateGroup(
        label: labels[key]!,
        keyPrefix: 'completed-$key',
        tasks: List<PlannerTask>.unmodifiable(byDate[key]!),
      ),
  ];
}

final class _TaskTimeline extends ConsumerWidget {
  const _TaskTimeline({
    required this.groups,
    required this.emptyMessage,
    required this.tab,
    super.key,
  });

  final List<TaskDateGroup> groups;
  final String emptyMessage;
  final _TaskTimelineTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (groups.isEmpty) {
      return _TasksMessage(emptyMessage);
    }
    return CustomScrollView(
      key: PageStorageKey<String>('tasks-timeline-${tab.name}'),
      slivers: <Widget>[
        for (final group in groups)
          PlanningTimelineSection(
            label: group.label,
            keyPrefix: group.keyPrefix,
            children: <Widget>[
              for (var index = 0; index < group.tasks.length; index++)
                _TaskTimelineRow(
                  task: group.tasks[index],
                  tab: tab,
                  isFirst: index == 0,
                  isLast: index == group.tasks.length - 1,
                ),
            ],
          ).buildSliver(context),
        planningTimelineTail,
      ],
    );
  }
}

final class _TaskTimelineRow extends StatelessWidget {
  const _TaskTimelineRow({
    required this.task,
    required this.tab,
    required this.isFirst,
    required this.isLast,
  });

  final PlannerTask task;
  final _TaskTimelineTab tab;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final completed = tab == _TaskTimelineTab.completed;
    final localUpdated = task.updatedAtUtc.toLocal();
    final due = task.dueDate;
    return PlanningTimelineRow(
      rowKey: Key('tasks-row-${task.id}'),
      isFirst: isFirst,
      isLast: isLast,
      marker: Icon(
        completed ? Icons.check_circle_outline : Icons.task_alt_outlined,
        size: 22,
        color: completed
            ? PlannerEventReportStatus.completedColor
            : Theme.of(context).colorScheme.primary,
      ),
      timeLine: completed
          ? planningClockLabel(localUpdated)
          : planningMinuteLabel(task.dueMinute),
      title: task.title,
      secondary: completed && due != null
          ? Text(
              'Due ${planningDateSectionLabel(due)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Roboto',
                fontSize: 13,
                height: 18 / 13,
                color: AppTheme.secondaryTextOf(context),
              ),
            )
          : null,
      // The canonical Task Preview owns Current Status, completion and
      // editing, and every mutation it performs publishes through the
      // controller's canonical change seam, which re-reads this timeline.  The
      // row therefore never invalidates anything itself: doing so after the
      // preview closed could touch a provider element this row no longer owns
      // once it has been unmounted.
      onTap: () => showTaskPreview<void>(context: context, taskId: task.id),
    );
  }
}

final class _TasksMessage extends StatelessWidget {
  const _TasksMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: InternalScreen.label.copyWith(
            color: AppTheme.secondaryTextOf(context),
          ),
        ),
      ),
    );
  }
}
