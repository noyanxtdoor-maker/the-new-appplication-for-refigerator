import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/task_event_link.dart';

abstract interface class CalendarEventReportSource {
  Future<List<CalendarEventReportSnapshot>> readSeriesReports(String eventId);
}

/// Optional batch capability for [CalendarEventReportSource].
///
/// Production Drift sources implement this so a Planner day read can fetch
/// outcome reports for every Calendar Event in a bounded number of set-based
/// queries instead of one query per Event.  Callers must fall back to the
/// single-event [CalendarEventReportSource.readSeriesReports] contract when a
/// source does not implement this capability.
abstract interface class CalendarEventReportBatchSource {
  /// Returns outcome report snapshots grouped by Event ID for the given
  /// Event IDs.  An Event with no matching reports has no map entry, and a
  /// map lookup for it must behave exactly like an empty list.
  Future<Map<String, List<CalendarEventReportSnapshot>>>
  readSeriesReportsForEvents(Iterable<String> eventIds);
}

final class EmptyCalendarEventReportSource
    implements CalendarEventReportSource {
  const EmptyCalendarEventReportSource();

  @override
  Future<List<CalendarEventReportSnapshot>> readSeriesReports(
    String eventId,
  ) async {
    return const <CalendarEventReportSnapshot>[];
  }
}

abstract interface class CalendarEventTaskContextSource {
  Future<List<String>> readLinkedTaskIds({
    required String eventId,
    required String occurrenceId,
  });
}

/// Optional batch capability for [CalendarEventTaskContextSource].
///
/// Production Drift sources implement this so a Planner day read can prefetch
/// the Task-Event link state for every Calendar Event in one/chunk set-based
/// query and resolve per-occurrence linked Task IDs in memory.
abstract interface class CalendarEventTaskContextBatchSource {
  Future<CalendarEventTaskContextSnapshot> readTaskContextSnapshot(
    Iterable<String> eventIds,
  );
}

/// Immutable application-layer snapshot of Task-Event link state for a set of
/// Calendar Events, prefetched by [CalendarEventTaskContextBatchSource].
///
/// It reproduces the frozen `readLinkedTaskIds` algorithm — start from active
/// series links, apply matching occurrence overrides (active adds, removed
/// removes), filter to Tasks that still exist, and sort ascending — without
/// issuing per-occurrence SQL.
final class CalendarEventTaskContextSnapshot {
  const CalendarEventTaskContextSnapshot({
    this.seriesByEvent = const <String, Set<String>>{},
    this.occurrenceByEvent =
        const <String, List<CalendarEventTaskContextOverride>>{},
    this.existingTaskIds = const <String>{},
  });

  /// Event ID -> Task IDs with an ACTIVE series-scoped link.
  final Map<String, Set<String>> seriesByEvent;

  /// Event ID -> occurrence-scoped overrides (active or removed).
  final Map<String, List<CalendarEventTaskContextOverride>> occurrenceByEvent;

  /// Task IDs that still exist and therefore pass the existence filter.
  final Set<String> existingTaskIds;

  bool get isEmpty => seriesByEvent.isEmpty && occurrenceByEvent.isEmpty;

  List<String> linkedTaskIds({
    required String eventId,
    required String occurrenceId,
  }) {
    final effective = <String>{...?seriesByEvent[eventId]};
    for (final override
        in occurrenceByEvent[eventId] ??
            const <CalendarEventTaskContextOverride>[]) {
      if (override.occurrenceId != occurrenceId) {
        continue;
      }
      if (override.status == TaskEventLinkStatus.active) {
        effective.add(override.taskId);
      } else {
        effective.remove(override.taskId);
      }
    }
    return effective.where(existingTaskIds.contains).toList()..sort();
  }
}

final class CalendarEventTaskContextOverride {
  const CalendarEventTaskContextOverride({
    required this.taskId,
    required this.occurrenceId,
    required this.status,
  });

  final String taskId;
  final String occurrenceId;
  final TaskEventLinkStatus status;
}

final class EmptyCalendarEventTaskContextSource
    implements CalendarEventTaskContextSource {
  const EmptyCalendarEventTaskContextSource();

  @override
  Future<List<String>> readLinkedTaskIds({
    required String eventId,
    required String occurrenceId,
  }) async {
    return const <String>[];
  }
}

abstract interface class CalendarEventLinkContextTransfer {
  Future<void> transferOnReschedule({
    required String profileId,
    required String sourceEventId,
    required String sourceOccurrenceId,
    required PlannerDate sourceOriginalDate,
    required CalendarEventEditScope scope,
    required String replacementEventId,
    required PlannerDate replacementOriginalDate,
    required String operationId,
  });
}

final class EmptyCalendarEventLinkContextTransfer
    implements CalendarEventLinkContextTransfer {
  const EmptyCalendarEventLinkContextTransfer();

  @override
  Future<void> transferOnReschedule({
    required String profileId,
    required String sourceEventId,
    required String sourceOccurrenceId,
    required PlannerDate sourceOriginalDate,
    required CalendarEventEditScope scope,
    required String replacementEventId,
    required PlannerDate replacementOriginalDate,
    required String operationId,
  }) async {}
}

/// Optional canonical capability for consumers that need exact occurrences
/// across a bounded civil-date window. Production Maps uses this instead of
/// repeatedly loading full Planner days (and unrelated Tasks).
abstract interface class CalendarEventRangeSource {
  Future<List<PlannerCalendarItem>> readRange({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  });
}

/// M3 P01 — optional SOURCE-SCOPED range capability.
///
/// Identical projection contract to [CalendarEventRangeSource.readRange]
/// (same `_buildOccurrence` recurrence/exception/timezone/report/Task
/// semantics, same 42-day inclusive window handled by the caller), except
/// the SQL source rows are constrained to the requested Event IDs FIRST so
/// batching and per-date expansion only ever process those sources.
///
/// Law:
/// - an EMPTY ID set returns an EMPTY projection (never a full read);
/// - a NULL id set means "no source constraint" and MUST behave exactly like
///   the unscoped readRange (used by global recovery);
/// - a result is still ordered and deduplicated exactly like readRange;
/// - the result of a SCOPED read is never the full badge/planner universe.
abstract interface class CalendarEventScopedRangeSource {
  Future<List<PlannerCalendarItem>> readRangeForEvents({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
    required Set<String>? eventIds,
  });
}

/// Optional canonical capability for the UNREPORTED backlog.
///
/// Returns every Event occurrence that is canonically awaiting a report:
/// the occurrence is still `scheduled`, it requires a report, no report has
/// been submitted for it, and its window has elapsed.  This is the same truth
/// the Planner's awaiting-reports presentation and the `awaitingReport`
/// reminder family already use, but WITHOUT their bounded day windows: the
/// owner law is that older unresolved occurrences remain findable, so the
/// production source expands each candidate from its own series start.
///
/// A source that does not implement this capability simply has no backlog —
/// callers must not substitute an "everything is unreported" fallback.
abstract interface class CalendarEventAwaitingReportSource {
  /// Oldest occurrence first; ties broken by the canonical day ordering.
  ///
  /// [today] anchors the all-day elapsed rule (`displayDate < today`);
  /// [nowUtc] anchors the timed rule (`endUtc < nowUtc`).  Both are passed in
  /// so the projection is deterministic under a test clock.
  Future<List<AwaitingReportEvent>> readAwaitingReportEvents({
    required String profileId,
    required PlannerDate today,
    required DateTime nowUtc,
  });
}

abstract interface class CalendarEventDuplicateContextTransfer {
  Future<void> copyPeopleOnDuplicate({
    required String profileId,
    required String sourceEventId,
    required String sourceOccurrenceId,
    required String duplicateEventId,
  });
}

final class EmptyCalendarEventDuplicateContextTransfer
    implements CalendarEventDuplicateContextTransfer {
  const EmptyCalendarEventDuplicateContextTransfer();

  @override
  Future<void> copyPeopleOnDuplicate({
    required String profileId,
    required String sourceEventId,
    required String sourceOccurrenceId,
    required String duplicateEventId,
  }) async {}
}

abstract interface class CalendarEventRepository
    implements PlannerCalendarSource {
  String get displayTimeZoneId;

  bool isValidTimeZone(String timeZoneId);

  Future<CalendarEventDraft?> readEventDraft({
    required String profileId,
    required String eventId,
  });

  Future<CalendarEventOccurrence?> readOccurrence({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
  });

  Future<CalendarEventDraft> saveEvent({
    required String profileId,
    required CalendarEventDraft draft,
  });

  Future<CalendarEventMutationOutcome> editEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft draft,
    required String operationId,
  });

  Future<CalendarEventMutationOutcome> cancelEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required String operationId,
  });

  Future<CalendarEventMutationOutcome> rescheduleEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft replacement,
    required String operationId,
  });

  Future<CalendarEventMutationOutcome> duplicateEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required String duplicateId,
    required String operationId,
  });
}

/// Optional production capability used by opaque notification tap routing.
abstract interface class CalendarEventOccurrenceIdLookup {
  Future<CalendarEventOccurrence?> readOccurrenceById({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  });
}
