import 'package:rmplanner/features/planner/domain/planner_day.dart';

/// One canonically unresolved Calendar Event occurrence: the Event is still
/// `scheduled`, it requires a report, no report has been submitted, and its
/// occurrence window has elapsed.
///
/// This is the SAME truth the Planner's awaiting-reports presentation, the
/// `awaitingReport` reminder family and the Event reporting invariant already
/// use; it is deliberately a projection, not a second source of record.
///
/// The two classification keys are carried here because they are NOT part of
/// [PlannerCalendarItem]:
///
/// * [goalId] is the Event's manual Life Goal link (`calendar_events.goal_id`);
/// * [activityTypeStableKey] is the occurrence-effective Event Type key
///   (an occurrence exception may override the series snapshot).
///
/// Classification itself lives in the Unreported feature so the hub, the
/// hamburger indicator and the summary notification can never disagree.
final class AwaitingReportEvent {
  const AwaitingReportEvent({
    required this.item,
    required this.goalId,
    required this.activityTypeStableKey,
  });

  /// The canonical occurrence projection (identity, title, dates, timing,
  /// Event Type presentation) used to render and route the row.
  final PlannerCalendarItem item;

  /// The Event's manual Life Goal link, when any.
  final String? goalId;

  /// The occurrence-effective Event Type stable key, when any.
  final String? activityTypeStableKey;
}
