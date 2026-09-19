import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_detail_screen.dart';

/// Opens the canonical Calendar Event detail sheet for one Planner item.
///
/// Shared by the Planner presentations and the Unreported hub so a row in
/// either surface reaches the SAME detail/report flow, with the same truthful
/// first-frame heading.  An external item without a local record keeps its
/// existing non-destructive feedback instead of pushing a broken route.
void openPlannerCalendarEvent(BuildContext context, PlannerCalendarItem event) {
  final eventId = event.eventId;
  final originalDate = event.originalDate;
  if (eventId == null || originalDate == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This external calendar item has no editable local record.',
        ),
      ),
    );
    return;
  }
  unawaited(
    showCalendarEventDetailSheet<void>(
      context: context,
      eventId: eventId,
      originalDate: originalDate,
      // NX-05: the tapped planner item already knows the activity identity, so
      // the sheet title is truthful from the first rendered frame (no generic
      // 'Calendar Event' -> activity-label morph while the record loads).
      initialHeading: event.activityTypeLabel?.trim().isNotEmpty == true
          ? event.activityTypeLabel
          : event.displayTitle,
    ),
  );
}
