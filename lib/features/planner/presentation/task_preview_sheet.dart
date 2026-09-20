import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/activity_history_screen.dart';
import 'package:rmplanner/features/planner/presentation/task_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/anchored_top_bar_popup.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_current_status_controls.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_detail_primitives.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_top_bar_icons.dart';

enum _TaskPreviewAction { addToPlanner, duplicate, delete }

/// Canonical Task-contact projection for the Preview. It deliberately reads
/// only task_contact_links through [taskContactsProvider]; Task display text
/// is never used as a substitute for a relationship.
final class _TaskPreviewContactsSection extends ConsumerWidget {
  const _TaskPreviewContactsSection({required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(taskContactsProvider(taskId));
    final values = contacts.asData?.value;
    if (values == null || values.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Contacts',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          for (final ContactSummary contact in values)
            PlannerPreviewContactLink(
              key: Key('task-preview-contact-${contact.contact.id}'),
              contactId: contact.contact.id,
              name: contact.contact.displayName,
              contact: contact,
            ),
        ],
      ),
    );
  }
}

/// Task facts and Task-owned actions rendered in the Event Preview production
/// shell. This owns no parallel reporting or history data; it delegates each
/// mutation to the canonical Task/reporting paths.
final class TaskPreviewSheet extends ConsumerStatefulWidget {
  const TaskPreviewSheet({required this.taskId, super.key});

  final String taskId;

  @override
  ConsumerState<TaskPreviewSheet> createState() => _TaskPreviewSheetState();
}

final class _TaskPreviewSheetState extends ConsumerState<TaskPreviewSheet> {
  late Future<PlannerTask?> _task;
  late Future<_TaskReportingSnapshot> _reporting;
  final GlobalKey _overflowAnchorKey = GlobalKey();
  String _heading = 'Task';
  bool _updatingStatus = false;
  PlannerTask? _taskSnapshot;
  _TaskReportingSnapshot _reportingSnapshot =
      const _TaskReportingSnapshot.empty();
  bool _hasReportingSnapshot = false;
  OutcomeKind? _optimisticOutcome;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload({bool reloadTask = true}) {
    if (reloadTask) {
      final task = ref
          .read(plannerControllerProvider.notifier)
          .readTask(widget.taskId);
      _task = task;
      unawaited(
        task.then((value) {
          if (mounted && value != null) {
            setState(() {
              _taskSnapshot = value;
              if (value.title != _heading) _heading = value.title;
            });
          }
        }),
      );
    }
    final reporting = _readTaskReporting(widget.taskId);
    _reporting = reporting;
    unawaited(
      reporting.then((value) {
        if (mounted) {
          setState(() {
            _reportingSnapshot = value;
            _hasReportingSnapshot = true;
          });
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SharedPlannerPreviewSheet(
      key: const Key('task-preview-sheet'),
      title: _heading,
      closeKey: const Key('task-preview-sheet-close'),
      closeTooltip: 'Close Task details',
      onClose: () => Navigator.of(context).pop(),
      actions: <Widget>[
        PlannerTopBarIconButton(
          key: const Key('task-detail-sheet-edit-icon'),
          tooltip: 'Edit Task',
          onPressed: _edit,
          icon: const Icon(Icons.edit_outlined),
        ),
        KeyedSubtree(
          key: _overflowAnchorKey,
          child: PlannerTopBarIconButton(
            key: const Key('task-detail-sheet-overflow-icon'),
            tooltip: 'Task actions',
            onPressed: _openOverflow,
            icon: const Icon(Icons.more_vert),
          ),
        ),
      ],
      child: FutureBuilder<PlannerTask?>(
        future: _task,
        builder: (context, snapshot) {
          final task = snapshot.data ?? _taskSnapshot;
          if (task == null &&
              snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (task == null) return const Center(child: Text('Task not found.'));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: <Widget>[
              FutureBuilder<_TaskReportingSnapshot>(
                future: _reporting,
                builder: (context, reporting) {
                  // A FutureBuilder retains the previous future's data while
                  // swapping futures. Once a canonical snapshot has arrived,
                  // it is the sole display owner; otherwise that retained
                  // data can briefly repaint the prior Task status after an
                  // optimistic direct mutation has already settled.
                  final data = _hasReportingSnapshot
                      ? _reportingSnapshot
                      : reporting.data ?? _reportingSnapshot;
                  final effectiveOutcome =
                      _optimisticOutcome ?? data.currentOutcome;
                  final reportingStarted =
                      effectiveOutcome != null || data.hasReportedHistory;
                  return Column(
                    children: <Widget>[
                      PlannerCurrentStatusControlRow(
                        currentLabel: _outcomeLabel(effectiveOutcome),
                        currentKind: _kindFor(effectiveOutcome),
                        selectedId: effectiveOutcome?.name ?? 'unreported',
                        options: <PlannerPreviewStatusOption>[
                          PlannerPreviewStatusOption(
                            id: 'unreported',
                            label: 'Unreported',
                            kind: PlannerReportStatusKind.unreported,
                            enabled: !reportingStarted,
                          ),
                          PlannerPreviewStatusOption(
                            id: 'didNotHappen',
                            label: 'Did Not Attempt',
                            kind: PlannerReportStatusKind.didNotAttempt,
                          ),
                          PlannerPreviewStatusOption(
                            id: 'partiallyCompleted',
                            label: 'Missed',
                            kind: PlannerReportStatusKind.missedAttempted,
                          ),
                          PlannerPreviewStatusOption(
                            id: 'completedHappened',
                            label: 'Completed',
                            kind: PlannerReportStatusKind.completed,
                          ),
                        ],
                        saving: _updatingStatus,
                        onSelect: _submitStatus,
                        controlKey: const Key('task-status-control'),
                        currentLabelKey: const Key('task-status-current-label'),
                        optionKeyPrefix: 'task-status-option-',
                      ),
                      const SizedBox(height: 12),
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
              _TaskPreviewContactsSection(taskId: task.id),
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
              if (task.notes case final notes? when notes.trim().isNotEmpty)
                PlannerDetailField(
                  icon: Icons.notes_outlined,
                  label: 'Notes',
                  value: notes,
                ),
              const Divider(height: 28),
              ListTile(
                key: const Key('task-activity-history-button'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history_outlined),
                title: const Text('Activity History'),
                subtitle: const Text('Read-only status and activity records'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openActivityHistory,
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openOverflow() async {
    final task = await _task;
    if (!mounted || task == null) return;
    _TaskPreviewAction? action;
    await showAnchoredTopBarPopup(
      context: context,
      triggerKey: _overflowAnchorKey,
      width: 228,
      maxHeight: 220,
      builder: (popupContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (task.dueDate == null || task.dueMinute == null)
            PlannerPreviewOverflowItem(
              key: const Key('task-overflow-add-to-planner'),
              icon: Icons.add_to_queue_outlined,
              label: 'Add to Planner',
              onTap: () {
                action = _TaskPreviewAction.addToPlanner;
                anchoredTopBarPopupController.dismiss();
              },
            ),
          PlannerPreviewOverflowItem(
            key: const Key('task-overflow-duplicate'),
            icon: Icons.copy_outlined,
            label: 'Duplicate',
            onTap: () {
              action = _TaskPreviewAction.duplicate;
              anchoredTopBarPopupController.dismiss();
            },
          ),
          PlannerPreviewOverflowItem(
            key: const Key('task-overflow-delete'),
            icon: Icons.delete_outline,
            label: 'Delete',
            destructive: true,
            onTap: () {
              action = _TaskPreviewAction.delete;
              anchoredTopBarPopupController.dismiss();
            },
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action!) {
      case _TaskPreviewAction.addToPlanner:
        await _addToPlanner();
      case _TaskPreviewAction.duplicate:
        await _duplicate(task);
      case _TaskPreviewAction.delete:
        await _delete(task);
    }
  }

  Future<void> _edit() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => TaskFormScreen.edit(taskId: widget.taskId),
      ),
    );
    if (changed == true && mounted) setState(_reload);
  }

  Future<void> _addToPlanner() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => TaskFormScreen.addToPlanner(taskId: widget.taskId),
      ),
    );
    if (changed == true && mounted) setState(_reload);
  }

  Future<void> _duplicate(PlannerTask task) async {
    final contacts = await ref.read(taskContactsProvider(task.id).future);
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => TaskFormScreen.create(
          initialDueDate: task.dueDate,
          initialDueMinute: task.dueMinute,
          initialContactIds: contacts
              .map((contact) => contact.contact.id)
              .toList(),
          initialTitle: task.title,
          initialDescription: task.notes,
          initialPeople: task.people,
          initialRecurrence: task.recurrence,
          initialGoalId: task.goalId,
        ),
      ),
    );
    if (changed == true && mounted) setState(_reload);
  }

  Future<void> _delete(PlannerTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Task?'),
        content: const Text(
          'This permanently deletes this Task and only data proven to be '
          'Task-owned. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep Task'),
          ),
          FilledButton(
            key: const Key('task-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete Task'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await ref
        .read(plannerControllerProvider.notifier)
        .hardDeleteTask(task.id);
    if (!mounted) return;
    if (result == TaskHardDeleteOutcome.deleted) {
      Navigator.of(context).pop(true);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == TaskHardDeleteOutcome.notFound
              ? 'This Task is no longer available.'
              : 'Task deletion was rolled back because its ownership could not be proven.',
        ),
      ),
    );
  }

  Future<void> _openActivityHistory() async {
    final snapshot = await _readTaskReporting(widget.taskId);
    if (!mounted || snapshot.source == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ActivityHistoryScreen(sourceSlotKey: snapshot.source!.slotKey),
      ),
    );
  }

  Future<_TaskReportingSnapshot> _readTaskReporting(String taskId) async {
    final controller = ref.read(outcomeReportingControllerProvider.notifier);
    final source = await controller.readTaskSource(taskId);
    if (source == null) return const _TaskReportingSnapshot.empty();
    final history =
        (await controller.readHistory())
            .where((report) => report.source.slotKey == source.slotKey)
            .toList(growable: false)
          ..sort((left, right) {
            final timestampOrder = right.updatedAtUtc.compareTo(
              left.updatedAtUtc,
            );
            return timestampOrder != 0
                ? timestampOrder
                : right.id.compareTo(left.id);
          });
    return _TaskReportingSnapshot(source: source, history: history);
  }

  Future<void> _submitStatus(String id) async {
    if (_updatingStatus || id == 'unreported') return;
    final selected = OutcomeKind.values.byName(id);
    if (selected == _optimisticOutcome ||
        selected == _reportingSnapshot.currentOutcome) {
      return;
    }
    // Task reporting is intentionally direct in the Preview.  The tiny
    // optimistic status update keeps the settled sheet stable while the
    // canonical Task-owned reporting transaction commits; it never opens the
    // Event editor or reloads unrelated Preview rows.
    setState(() {
      _optimisticOutcome = selected;
      _updatingStatus = true;
    });
    final controller = ref.read(outcomeReportingControllerProvider.notifier);
    final operationId = ref.read(plannerIdentifierSourceProvider).nextUuid();
    final succeeded =
        await controller.submitTaskStatus(
          taskId: widget.taskId,
          outcome: selected,
          operationId: operationId,
        ) !=
        null;
    if (!mounted) return;
    if (!succeeded) {
      setState(() {
        _updatingStatus = false;
        _optimisticOutcome = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ref.read(outcomeReportingControllerProvider) ??
                'Task status could not be saved.',
          ),
        ),
      );
      return;
    }

    // The canonical write has completed. Do not make a later reporting reread
    // hold the control disabled: a correction is another Task-owned write,
    // and the optimistic outcome remains authoritative until its matching
    // canonical snapshot arrives. This prevents both the old-status flash and
    // a stale reread from blocking the next valid correction.
    setState(() => _updatingStatus = false);
    final refreshed = await _readTaskReporting(widget.taskId);
    if (!mounted) return;
    setState(() {
      _reportingSnapshot = refreshed;
      _hasReportingSnapshot = true;
      _reporting = Future<_TaskReportingSnapshot>.value(refreshed);
      if (refreshed.currentOutcome == selected &&
          _optimisticOutcome == selected) {
        _optimisticOutcome = null;
      }
    });
  }

  static PlannerReportStatusKind _kindFor(OutcomeKind? outcome) =>
      switch (outcome) {
        OutcomeKind.didNotHappen => PlannerReportStatusKind.didNotAttempt,
        OutcomeKind.completedHappened => PlannerReportStatusKind.completed,
        OutcomeKind.partiallyCompleted =>
          PlannerReportStatusKind.missedAttempted,
        null => PlannerReportStatusKind.unreported,
      };

  static String _outcomeLabel(OutcomeKind? outcome) => switch (outcome) {
    OutcomeKind.didNotHappen => 'Did Not Attempt',
    OutcomeKind.completedHappened => 'Completed',
    OutcomeKind.partiallyCompleted => 'Missed',
    null => 'Unreported',
  };

  static String _recurrenceLabel(PlannerTaskRecurrence recurrence) =>
      switch (recurrence) {
        PlannerTaskRecurrence.none => 'Does not repeat',
        PlannerTaskRecurrence.daily => 'Daily',
        PlannerTaskRecurrence.weekly => 'Weekly',
        PlannerTaskRecurrence.monthly => 'Monthly',
        PlannerTaskRecurrence.yearly => 'Yearly',
      };

  static String _time(int minute) {
    final hour24 = minute ~/ 60;
    final hour = hour24 == 0
        ? 12
        : hour24 > 12
        ? hour24 - 12
        : hour24;
    return '$hour:${(minute % 60).toString().padLeft(2, '0')} '
        '${hour24 >= 12 ? 'PM' : 'AM'}';
  }
}

final class _TaskReportingSnapshot {
  const _TaskReportingSnapshot({required this.source, required this.history});

  const _TaskReportingSnapshot.empty()
    : source = null,
      history = const <OutcomeReport>[];

  final OutcomeReportSource? source;
  final List<OutcomeReport> history;

  bool get hasReportedHistory =>
      history.any((report) => report.outcome != null);

  OutcomeKind? get currentOutcome => history
      .where((report) => report.status == OutcomeReportStatus.submitted)
      .firstOrNull
      ?.outcome;
}

Future<T?> showTaskPreview<T>({
  required BuildContext context,
  required String taskId,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: kPlannerPreviewSheetMaxWidth),
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.92,
      child: TaskPreviewSheet(taskId: taskId),
    ),
  );
}
