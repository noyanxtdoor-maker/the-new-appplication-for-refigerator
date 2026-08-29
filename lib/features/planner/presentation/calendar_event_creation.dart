import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_tap_marker_provider.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/event_type_picker_dialog.dart';
import 'package:rmplanner/features/planner/presentation/planner_editor_sheet_metrics.dart';
import 'package:rmplanner/features/planner/presentation/task_creation.dart';

final class CalendarEventCreationContext {
  const CalendarEventCreationContext({
    required this.source,
    required this.destinationPath,
    required this.date,
    this.startMinute,
    this.indicatorKey,
    this.recommendedEventTypeId,
    this.sourceTaskId,
  });

  final String source;
  final String destinationPath;
  final PlannerDate date;
  final int? startMinute;
  final String? indicatorKey;
  final String? recommendedEventTypeId;
  final String? sourceTaskId;
}

Future<T?> launchCalendarEventCreation<T>(
  BuildContext context,
  WidgetRef ref,
  CalendarEventCreationContext creationContext,
) async {
  final selected = await showEventTypePicker(
    context: context,
    ref: ref,
    recommendedEventTypeId: creationContext.recommendedEventTypeId,
    recommendedIndicatorKey: creationContext.indicatorKey,
  );
  if (selected == null || !context.mounted) {
    return null;
  }
  // The Planner's real Event-Type picker also exposes the Task entry.  That
  // choice must stay in the live Planner creation session; pushing the
  // general /tasks/new route here replaces the Planner and bypasses the one
  // provisional Task draft and its real draggable sheet.
  if (selected is EventTypePickerTask &&
      (creationContext.source == 'planner-fab' ||
           creationContext.source == 'planner-timeline')) {
    // A timeline tap temporarily paints a generic Event-selection marker while
    // the picker is open. Once Task is selected, its own canonical draft owns
    // the creation session, so the generic marker must not survive under the
    // Task sheet.
    ref.read(plannerTapMarkerProvider.notifier).clear();
    final now = DateTime.now();
    await launchTaskCreation(
      context,
      ref,
      TaskCreationContext(
        source: creationContext.source,
        date: creationContext.date,
        minute:
            creationContext.startMinute ?? (now.hour * 60 + now.minute),
      ),
    );
    return null;
  }
  if (selected case EventTypePickerEvent(:final eventType)
      when creationContext.source == 'planner-timeline' &&
          creationContext.startMinute != null) {
    // Delta 4.2R R8/R9: the configured Planner default duration drives the
    // timeline-creation path. The same value seeds the pre-type tap
    // placeholder (already the case), the provisional draft, AND the editor
    // sheet, so 1:00 PM + 30 min always yields 1:00-1:30 everywhere.
    final plannerDefaultDuration =
        ref.read(eventTypeControllerProvider).settings.defaultDurationMinutes;
    final draftId = ref.read(plannerIdentifierSourceProvider).nextUuid();
    ref
        .read(plannerEventCreationDraftProvider.notifier)
        .begin(
          id: draftId,
          date: creationContext.date,
          startMinute: creationContext.startMinute!,
          eventType: eventType,
          defaultDurationMinutes: plannerDefaultDuration,
        );
    try {
      showPlannerCalendarEventFormSheet(
        context: context,
        eventType: eventType,
        date: creationContext.date,
        startMinute: creationContext.startMinute!,
        indicatorKey: creationContext.indicatorKey,
        draftId: draftId,
        initialDurationMinutes: plannerDefaultDuration,
        onClosed: () =>
            ref.read(plannerEventCreationDraftProvider.notifier).clear(draftId),
      );
      return null;
    } on Object {
      ref.read(plannerEventCreationDraftProvider.notifier).clear(draftId);
      rethrow;
    }
  }
  return switch (selected) {
    EventTypePickerEvent(:final eventType) => showCalendarEventFormSheet<T>(
      context: context,
      eventType: eventType,
      date: creationContext.date,
      startMinute: creationContext.startMinute,
      indicatorKey: creationContext.indicatorKey,
      sourceTaskId: creationContext.sourceTaskId,
    ),
    EventTypePickerTask() => context.push<T>(
      _taskCreationPath(creationContext),
    ),
  };
}

/// Planner-only non-modal form surface. The uncovered timeline remains in
/// the gesture arena so the selected provisional block can be intentionally
/// resized while the form is open. Other creation entry points retain the
/// existing modal sheet behavior.
void showPlannerCalendarEventFormSheet({
  required BuildContext context,
  required EventType eventType,
  required PlannerDate date,
  required int startMinute,
  required String draftId,
  required VoidCallback onClosed,
  String? indicatorKey,
  int? initialDurationMinutes,
}) {
  final sheetController = DraggableScrollableController();
  // Delta 4.1 D4.1-04: the provisional editor is a real draggable bottom
  // sheet.  It opens LOW (resting-height contract): at rest the Planner
  // keeps most of the screen and only the sheet header (grab handle,
  // X / Cancel, Save), the Event Type field, and the Title field are
  // visible.  Notes, scheduling, Repeat, People, Life Goal, Report, Backup
  // and the rest of the form are revealed only when the user drags the
  // sheet upward.  The resting size is content-based — the header plus the
  // first two form fields — expressed as a fraction of the actual viewport,
  // so it stays responsive instead of being hardcoded to one device.  The
  // sheet expands to 90% when pulled upward and returns toward the initial
  // editing position when pulled downward; the floor only prevents a total
  // collapse and a normal downward drag never dismisses it.  `expand: false`
  // keeps the sheet sized to its current child size, so the uncovered
  // timeline above the sheet stays in the gesture arena (a full-height
  // expand:true shell would swallow every Planner tap).  The builder's
  // scroll controller is attached to the form ListView so content scrolling
  // and sheet dragging stay coordinated instead of fighting.
  const minChildSize = 0.2;
  const maxChildSize = kPlannerEditorSheetMaxChildSize;
  // Approximate resting content: sheet header (~72) + ListView top padding
  // (14) + Event Type field (54) + gap (22) + Title field (~58) with a small
  // bottom margin so the Title field (and its label) is fully visible at
  // rest and only Notes and the scheduling section stay below the fold.
  const restingContentHeight = 252.0;
  final initialChildSize =
      (restingContentHeight / MediaQuery.sizeOf(context).height)
          .clamp(minChildSize, maxChildSize)
          .toDouble();
  late final PersistentBottomSheetController persistentSheet;

  void finish(bool saved) {
    persistentSheet.close();
  }

  persistentSheet = showBottomSheet(
    context: context,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: AnimationStyle.noAnimation,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height),
    builder: (sheetContext) => DraggableScrollableSheet(
      key: const Key('calendar-event-provisional-draggable-sheet'),
      controller: sheetController,
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: maxChildSize,
      // `expand: false` keeps the sheet sized to its current child size, so
      // the uncovered timeline above the sheet stays in the gesture arena
      // (a full-height expand:true shell would swallow every Planner tap).
      expand: false,
      builder: (context, scrollController) => CalendarEventFormScreen.create(
        initialDate: date,
        initialEventType: eventType,
        initialStartMinute: startMinute,
        initialIndicatorKey: indicatorKey,
        initialEventTypeId: eventType.id,
        initialDraftId: draftId,
        initialDurationMinutes: initialDurationMinutes,
        onClose: finish,
        sheetPresentation: true,
        // The DraggableScrollableSheet builder controller is attached to the
        // form ListView so content scrolling and sheet dragging stay
        // coordinated (native sheet behavior): pulling the sheet upward
        // expands it and the header grab-handle drag drives [sheetController]
        // directly.  Scrolling the form expands the sheet only up to its max,
        // then the fields scroll.
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
      onClosed();
    }),
  );
}

String _taskCreationPath(CalendarEventCreationContext creationContext) {
  final query = <String, String>{'date': creationContext.date.iso8601};
  final encoded = Uri(queryParameters: query).query;
  return '${RoutePaths.taskCreate}${encoded.isEmpty ? '' : '?$encoded'}';
}

Future<T?> showCalendarEventFormSheet<T>({
  required BuildContext context,
  required EventType eventType,
  required PlannerDate date,
  int? startMinute,
  String? indicatorKey,
  String? sourceTaskId,
  List<String> initialContactIds = const <String>[],
}) {
  final sheetController = DraggableScrollableController();
  const minChildSize = 0.36;
  const maxChildSize = kPlannerEditorSheetMaxChildSize;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.38),
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 260),
      reverseDuration: Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ),
    builder: (sheetContext) {
      final sheet = DraggableScrollableSheet(
        key: const Key('calendar-event-draggable-sheet'),
        controller: sheetController,
        initialChildSize: 0.40,
        minChildSize: minChildSize,
        maxChildSize: maxChildSize,
        expand: false,
        builder: (context, scrollController) => sourceTaskId == null
            ? CalendarEventFormScreen.create(
                initialDate: date,
                initialEventType: eventType,
                initialStartMinute: startMinute,
                initialIndicatorKey: indicatorKey,
                initialEventTypeId: eventType.id,
                initialContactIds: initialContactIds,
                sheetPresentation: true,
                sheetScrollController: scrollController,
                sheetController: sheetController,
                sheetMinChildSize: minChildSize,
                sheetMaxChildSize: maxChildSize,
              )
            : CalendarEventFormScreen.createFromTask(
                sourceTaskId: sourceTaskId,
                initialDate: date,
                initialEventType: eventType,
                initialStartMinute: startMinute,
                initialIndicatorKey: indicatorKey,
                initialEventTypeId: eventType.id,
                sheetPresentation: true,
                sheetScrollController: scrollController,
                sheetController: sheetController,
                sheetMinChildSize: minChildSize,
                sheetMaxChildSize: maxChildSize,
              ),
      );
      final routeAnimation = ModalRoute.of(sheetContext)?.animation;
      if (routeAnimation == null) {
        return sheet;
      }
      return FadeTransition(
        key: const Key('calendar-event-form-entrance-fade'),
        opacity: CurvedAnimation(
          parent: routeAnimation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
        child: sheet,
      );
    },
  ).whenComplete(sheetController.dispose);
}
