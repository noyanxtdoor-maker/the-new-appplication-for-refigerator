import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

/// The concrete timed occurrence currently represented by the Event form.
/// New drafts have no identity and therefore exclude no persisted candidate.
final class EventScheduleConflictDraft {
  const EventScheduleConflictDraft({
    required this.startUtc,
    required this.endUtc,
    this.eventId,
    this.originalDate,
  });

  final DateTime startUtc;
  final DateTime endUtc;
  final String? eventId;
  final PlannerDate? originalDate;

  bool get hasValidInterval => endUtc.isAfter(startUtc);

  bool isSameOccurrence(PlannerCalendarItem candidate) {
    return eventId != null &&
        originalDate != null &&
        candidate.eventId == eventId &&
        candidate.originalDate == originalDate;
  }
}

bool isActionableEventConflictCandidate(PlannerCalendarItem candidate) {
  return candidate.eventId != null &&
      candidate.originalDate != null &&
      candidate.timing == PlannerEventTiming.timed &&
      candidate.state == PlannerEventState.scheduled &&
      !candidate.isBackupAppointment &&
      candidate.startUtc != null &&
      candidate.endUtc != null &&
      candidate.endUtc!.isAfter(candidate.startUtc!);
}

/// Strict half-open interval overlap. Adjacency at either boundary is safe.
bool eventScheduleIntervalsOverlap({
  required DateTime draftStartUtc,
  required DateTime draftEndUtc,
  required DateTime candidateStartUtc,
  required DateTime candidateEndUtc,
}) {
  return draftStartUtc.isBefore(candidateEndUtc) &&
      draftEndUtc.isAfter(candidateStartUtc);
}

/// Returns one informational warning state, deduplicated by canonical
/// occurrence identity and stopping at the first actionable overlap.
bool hasActionableEventScheduleConflict(
  EventScheduleConflictDraft? draft,
  Iterable<PlannerCalendarItem> candidates, {
  void Function()? onCandidateScanned,
}) {
  if (draft == null || !draft.hasValidInterval) {
    return false;
  }
  final seen = <String>{};
  for (final candidate in candidates) {
    if (!isActionableEventConflictCandidate(candidate) ||
        !seen.add(candidate.id) ||
        draft.isSameOccurrence(candidate)) {
      continue;
    }
    onCandidateScanned?.call();
    if (eventScheduleIntervalsOverlap(
      draftStartUtc: draft.startUtc,
      draftEndUtc: draft.endUtc,
      candidateStartUtc: candidate.startUtc!,
      candidateEndUtc: candidate.endUtc!,
    )) {
      return true;
    }
  }
  return false;
}
