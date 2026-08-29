import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_task_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/planner_editor_sheet_metrics.dart';
import 'package:rmplanner/features/planner/presentation/task_form_screen.dart';

/// Frozen Planner anchor for a Task draft. The date/minute are captured when
/// creation starts and then owned jointly by the Task form and Day canvas.
final class TaskCreationContext {
  const TaskCreationContext({
    required this.source,
    required this.date,
    required this.minute,
    this.draftTitle = '',
    this.taskId,
    this.initialContactIds = const <String>[],
  });

  final String source;
  final PlannerDate date;
  final int minute;
  final String draftTitle;
  final String? taskId;
  final List<String> initialContactIds;
}

/// Opens a Planner-local Task editor and establishes one provisional Task
/// block before the form is presented. The editor is an in-route overlay, not
/// a modal barrier: the visible draft must remain reachable through the
/// canonical Planner drag path while its form is open. Closing without Save
/// clears only the draft; saving writes the canonical Task through
/// [TaskFormScreen].
Future<void> launchTaskCreation(
  BuildContext context,
  WidgetRef ref,
  TaskCreationContext creation,
) async {
  final container = ProviderScope.containerOf(context);
  final draftId = container.read(plannerIdentifierSourceProvider).nextUuid();
  container
      .read(plannerTaskCreationDraftProvider.notifier)
      .begin(
        id: draftId,
        date: creation.date,
        minute: creation.minute,
        title: creation.draftTitle,
        taskId: creation.taskId,
      );
  final closed = Completer<void>();
  final sheetController = DraggableScrollableController();
  // Keep the Task creation surface on the same persistent, draggable Planner
  // sheet path as Event creation.  Its resting content is deliberately low:
  // the Planner and its provisional Task remain in view until the owner
  // expands the form by its real sheet handle or content scroll.
  const minChildSize = 0.2;
  const maxChildSize = kPlannerEditorSheetMaxChildSize;
  const restingContentHeight = 252.0;
  final initialChildSize =
      (restingContentHeight / MediaQuery.sizeOf(context).height)
          .clamp(minChildSize, maxChildSize)
          .toDouble();
  late final PersistentBottomSheetController persistentSheet;
  var closing = false;

  void close() {
    if (closing) return;
    closing = true;
    persistentSheet.close();
  }

  persistentSheet = showBottomSheet(
    context: context,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: AnimationStyle.noAnimation,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height),
    builder: (sheetContext) => DraggableScrollableSheet(
      key: const Key('task-provisional-draggable-sheet'),
      controller: sheetController,
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: maxChildSize,
      expand: false,
      builder: (sheetContext, scrollController) => creation.taskId == null
          ? TaskFormScreen.create(
              // The live Planner block is provisional until the user
              // deliberately enables Due Date.  Do not seed a persisted due
              // value merely because the form was opened from the Day canvas.
              initialDueDate: null,
              initialDraftId: draftId,
              initialContactIds: creation.initialContactIds,
              sheetPresentation: true,
              onClose: (_) => close(),
              sheetScrollController: scrollController,
              sheetController: sheetController,
              sheetMinChildSize: minChildSize,
              sheetMaxChildSize: maxChildSize,
            )
          : TaskFormScreen.edit(
              taskId: creation.taskId!,
              initialDraftId: draftId,
              sheetPresentation: true,
              onClose: (_) => close(),
              sheetScrollController: scrollController,
              sheetController: sheetController,
              sheetMinChildSize: minChildSize,
              sheetMaxChildSize: maxChildSize,
            ),
    ),
  );
  unawaited(
    persistentSheet.closed.whenComplete(() {
      sheetController.dispose();
      container.read(plannerTaskCreationDraftProvider.notifier).clear(draftId);
      if (!closed.isCompleted) closed.complete();
    }),
  );
  await closed.future;
}
