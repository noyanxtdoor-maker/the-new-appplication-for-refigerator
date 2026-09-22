import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

/// P3 (2026-09-22) — the Event form's temporary scheduling session.
///
/// The form remains the owner of the draft.  Tapping `Schedule from Planner`
/// (a new Event) or `Reschedule from Planner` (an existing timed Event) opens
/// the ordinary Planner timeline in a session that carries ONLY this schedule;
/// dragging or resizing the provisional block writes here, and `Confirm`
/// returns a [PlannerScheduleResult] to the still-open form.
///
/// Nothing in this file persists anything.  The session holds no repository,
/// no controller and no `CalendarEventDraft`: it is the draft-only adapter the
/// ticket requires, so a session can never save an Event, submit a report,
/// move a recurrence, or write a row.
final class PlannerScheduleSession {
  const PlannerScheduleSession({
    required this.id,
    required this.date,
    required this.startMinute,
    required this.endMinute,
    required this.title,
    this.eventTypeId,
    this.eventTypeLabel,
    this.eventTypeColorValue,
    this.suppressedEventId,
    this.suppressedOriginalDate,
  });

  /// Identity of the provisional block's presentation item.  It deliberately
  /// does NOT reuse the creation draft's `provisional:` prefix: the two are
  /// different sessions and a mixed-up id would let one route the other's drag.
  static const String itemPrefix = 'schedule-session:';

  final String id;
  final PlannerDate date;

  /// Start as a minute of [date]'s day (0..1439).
  final int startMinute;

  /// End as an ABSOLUTE minute that may exceed 1440 — a session dragged to an
  /// end past midnight keeps the overnight duration the form then displays as a
  /// next-day end.  The Planner's own single-day canvas clamps what a drag can
  /// produce; the form's `Set Time to Now` is what reaches beyond midnight.
  final int endMinute;

  final String title;
  final String? eventTypeId;
  final String? eventTypeLabel;
  final int? eventTypeColorValue;

  /// Set only when an EXISTING saved occurrence is being rescheduled.  The
  /// occurrence is then hidden from the timeline while the provisional block
  /// stands in for it, so the same Event is never painted twice.
  final String? suppressedEventId;
  final PlannerDate? suppressedOriginalDate;

  String get itemId => '$itemPrefix$id';

  int get durationMinutes => endMinute - startMinute;

  bool sameOccurrenceAs(PlannerCalendarItem item) {
    final targetId = suppressedEventId;
    if (targetId == null) {
      return false;
    }
    if (item.eventId != targetId) {
      return false;
    }
    final targetDate = suppressedOriginalDate;
    if (targetDate == null) {
      return true;
    }
    return item.originalDate == targetDate || item.date == targetDate;
  }

  PlannerScheduleSession copyWith({
    PlannerDate? date,
    int? startMinute,
    int? endMinute,
  }) {
    return PlannerScheduleSession(
      id: id,
      date: date ?? this.date,
      startMinute: startMinute ?? this.startMinute,
      endMinute: endMinute ?? this.endMinute,
      title: title,
      eventTypeId: eventTypeId,
      eventTypeLabel: eventTypeLabel,
      eventTypeColorValue: eventTypeColorValue,
      suppressedEventId: suppressedEventId,
      suppressedOriginalDate: suppressedOriginalDate,
    );
  }
}

/// What `Confirm` hands back to the form.  A pure value: the form assigns it
/// to its own draft, and the ordinary form Save remains the only writer.
final class PlannerScheduleResult {
  const PlannerScheduleResult({
    required this.date,
    required this.startMinute,
    required this.endMinute,
  });

  final PlannerDate date;
  final int startMinute;
  final int endMinute;

  int get durationMinutes => endMinute - startMinute;
}

/// The provisional block the session paints.
PlannerCalendarItem plannerScheduleSessionItem(PlannerScheduleSession session) {
  final midnight = DateTime(
    session.date.year,
    session.date.month,
    session.date.day,
  );
  return PlannerCalendarItem(
    id: session.itemId,
    title: session.title,
    date: session.date,
    timing: PlannerEventTiming.timed,
    state: PlannerEventState.scheduled,
    requiresReport: false,
    hasOutcomeReport: false,
    startLocal: midnight.add(Duration(minutes: session.startMinute)),
    endLocal: midnight.add(Duration(minutes: session.endMinute)),
    originalDate: session.date,
    activityTypeId: session.eventTypeId,
    activityTypeLabel: session.eventTypeLabel,
    activityTypeColorValue: session.eventTypeColorValue,
  );
}

/// Presentation-only projection applied to a day's timed Events.
///
/// It (a) removes the occurrence a reschedule session stands in for, so the
/// Event is not painted twice, and (b) appends the provisional block when the
/// session's own date is the day being rendered.  No stored value, identity or
/// DateTime is rewritten — the input list is returned untouched when no session
/// is active.
List<PlannerCalendarItem> applyPlannerScheduleSessionProjection(
  List<PlannerCalendarItem> events,
  PlannerScheduleSession? session,
  PlannerDate selectedDate,
) {
  if (session == null) {
    return events;
  }
  final suppressedEventId = session.suppressedEventId;
  final kept = suppressedEventId == null
      ? events
      : <PlannerCalendarItem>[
          for (final event in events)
            if (!session.sameOccurrenceAs(event)) event,
        ];
  if (session.date != selectedDate) {
    return kept;
  }
  return <PlannerCalendarItem>[...kept, plannerScheduleSessionItem(session)];
}
