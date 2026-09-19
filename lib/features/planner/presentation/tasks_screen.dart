import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/task_preview_sheet.dart';

/// The single canonical Tasks home (owner law, 2026-09-19).
///
/// Tasks no longer have a second list anywhere — not in the hamburger as a
/// category, and never inside Unreported.  Incomplete and Completed read the
/// same canonical Task universe: every persisted Task, with completion state
/// owned by the canonical outcome report that already writes
/// `PlannerTaskStatus`.  There is deliberately NO retention window; a
/// completed Task stays findable, so PMG's seven-day rule is not imported.
final class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskUniverseProvider);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: InternalAppBar(
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
              _TaskList(
                key: const Key('tasks-incomplete-list'),
                tasks: _incomplete(all),
                emptyMessage: 'No incomplete Tasks.',
              ),
              _TaskList(
                key: const Key('tasks-completed-list'),
                tasks: _completed(all),
                emptyMessage: 'No completed Tasks yet.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Incomplete first by due date (undated last), then by creation time and
  /// stable id so the order is deterministic.
  static List<PlannerTask> _incomplete(List<PlannerTask> all) {
    final tasks = all
        .where((task) => task.status == PlannerTaskStatus.incomplete)
        .toList(growable: false);
    tasks.sort((left, right) {
      final leftDue = left.dueDate;
      final rightDue = right.dueDate;
      if (leftDue != null && rightDue != null) {
        final byDue = leftDue.compareTo(rightDue);
        if (byDue != 0) return byDue;
      } else if (leftDue != null) {
        return -1;
      } else if (rightDue != null) {
        return 1;
      }
      final byCreated = left.createdAtUtc.compareTo(right.createdAtUtc);
      if (byCreated != 0) return byCreated;
      return left.id.compareTo(right.id);
    });
    return tasks;
  }

  /// Completed newest first: the completion write updates `updatedAtUtc`, so
  /// this is genuine completion recency, with due date then id as ties.
  static List<PlannerTask> _completed(List<PlannerTask> all) {
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
    return tasks;
  }
}

final class _TaskList extends ConsumerWidget {
  const _TaskList({required this.tasks, required this.emptyMessage, super.key});

  final List<PlannerTask> tasks;
  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tasks.isEmpty) {
      return _TasksMessage(emptyMessage);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      itemCount: tasks.length,
      itemBuilder: (context, index) => _TaskRow(task: tasks[index]),
    );
  }
}

final class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task});

  final PlannerTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        key: Key('tasks-row-${task.id}'),
        leading: Icon(
          Icons.task_alt_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(task.title),
        subtitle: Text(_subtitle(task)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          // The canonical Task Preview owns Current Status, completion and
          // editing, so the list re-reads canonical truth when it closes.
          await showTaskPreview<void>(context: context, taskId: task.id);
          ref.invalidate(taskUniverseProvider);
        },
      ),
    );
  }

  static String _subtitle(PlannerTask task) {
    final due = task.dueDate;
    if (due == null) {
      return 'No due date';
    }
    final minute = task.dueMinute;
    if (minute == null) {
      return 'Due ${due.iso8601}';
    }
    final hour = minute ~/ 60;
    final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final label =
        '$displayHour:${(minute % 60).toString().padLeft(2, '0')} '
        '${hour >= 12 ? 'PM' : 'AM'}';
    return 'Due ${due.iso8601} · $label';
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
