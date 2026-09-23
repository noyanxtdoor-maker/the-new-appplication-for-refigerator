import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_schedule_conflict.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

void main() {
  const day = PlannerDate(year: 2026, month: 9, day: 22);

  PlannerCalendarItem candidate({
    String id = 'candidate',
    String eventId = 'event-b',
    PlannerDate originalDate = day,
    DateTime? start,
    DateTime? end,
    PlannerEventState state = PlannerEventState.scheduled,
    PlannerEventTiming timing = PlannerEventTiming.timed,
    bool backup = false,
  }) {
    return PlannerCalendarItem(
      id: id,
      eventId: eventId,
      originalDate: originalDate,
      title: 'Candidate',
      date: day,
      timing: timing,
      state: state,
      requiresReport: false,
      hasOutcomeReport: false,
      startUtc: start ?? DateTime.utc(2026, 9, 22, 10),
      endUtc: end ?? DateTime.utc(2026, 9, 22, 11),
      isBackupAppointment: backup,
    );
  }

  EventScheduleConflictDraft draft({
    DateTime? start,
    DateTime? end,
    String? eventId,
    PlannerDate? originalDate,
  }) {
    return EventScheduleConflictDraft(
      startUtc: start ?? DateTime.utc(2026, 9, 22, 10, 30),
      endUtc: end ?? DateTime.utc(2026, 9, 22, 11, 30),
      eventId: eventId,
      originalDate: originalDate,
    );
  }

  group('strict actionable conflict law', () {
    test('overlap, containment and equal start conflict', () {
      expect(
        hasActionableEventScheduleConflict(draft(), [candidate()]),
        isTrue,
      );
      expect(
        hasActionableEventScheduleConflict(
          draft(
            start: DateTime.utc(2026, 9, 22, 9),
            end: DateTime.utc(2026, 9, 22, 12),
          ),
          [candidate()],
        ),
        isTrue,
      );
      expect(
        hasActionableEventScheduleConflict(
          draft(
            start: DateTime.utc(2026, 9, 22, 10),
            end: DateTime.utc(2026, 9, 22, 10, 15),
          ),
          [candidate()],
        ),
        isTrue,
      );
    });

    test('both adjacency boundaries are not conflicts', () {
      expect(
        hasActionableEventScheduleConflict(
          draft(
            start: DateTime.utc(2026, 9, 22, 11),
            end: DateTime.utc(2026, 9, 22, 12),
          ),
          [candidate()],
        ),
        isFalse,
      );
      expect(
        hasActionableEventScheduleConflict(
          draft(
            start: DateTime.utc(2026, 9, 22, 9),
            end: DateTime.utc(2026, 9, 22, 10),
          ),
          [candidate()],
        ),
        isFalse,
      );
    });

    test(
      'exact occurrence self-excludes but another series occurrence remains',
      () {
        final original = const PlannerDate(year: 2026, month: 9, day: 21);
        final self = candidate(
          id: CalendarEventOccurrenceIdentity.forDate(
            eventId: 'series',
            originalDate: original,
          ),
          eventId: 'series',
          originalDate: original,
        );
        expect(
          hasActionableEventScheduleConflict(
            draft(eventId: 'series', originalDate: original),
            [self],
          ),
          isFalse,
        );
        expect(
          hasActionableEventScheduleConflict(
            draft(eventId: 'series', originalDate: original),
            [candidate(eventId: 'series', originalDate: day)],
          ),
          isTrue,
        );
      },
    );

    test('terminal, backup and date-only candidates are excluded', () {
      for (final state in <PlannerEventState>[
        PlannerEventState.cancelled,
        PlannerEventState.rescheduled,
        PlannerEventState.completedHappened,
        PlannerEventState.partiallyCompleted,
        PlannerEventState.didNotHappen,
      ]) {
        expect(
          hasActionableEventScheduleConflict(draft(), [
            candidate(state: state),
          ]),
          isFalse,
        );
      }
      expect(
        hasActionableEventScheduleConflict(draft(), [candidate(backup: true)]),
        isFalse,
      );
      expect(
        hasActionableEventScheduleConflict(draft(), [
          candidate(timing: PlannerEventTiming.allDay),
        ]),
        isFalse,
      );
    });

    test('invalid/date-only draft and synthetic rows do not conflict', () {
      expect(hasActionableEventScheduleConflict(null, [candidate()]), isFalse);
      expect(
        hasActionableEventScheduleConflict(draft(), [
          PlannerCalendarItem(
            id: 'synthetic',
            title: 'Draft',
            date: day,
            timing: PlannerEventTiming.timed,
            state: PlannerEventState.scheduled,
            requiresReport: false,
            hasOutcomeReport: false,
            startUtc: DateTime.utc(2026, 9, 22, 10),
            endUtc: DateTime.utc(2026, 9, 22, 11),
          ),
        ]),
        isFalse,
      );
    });

    test('deduplicates occurrences and stops after one warning', () {
      var scans = 0;
      expect(
        hasActionableEventScheduleConflict(draft(), [
          candidate(),
          candidate(),
          candidate(id: 'later'),
        ], onCandidateScanned: () => scans++),
        isTrue,
      );
      expect(scans, 1);
    });

    test('scan count is linear for 0, 10, 100 and 1000 candidates', () {
      for (final count in <int>[0, 10, 100, 1000]) {
        var scans = 0;
        final candidates = List<PlannerCalendarItem>.generate(
          count,
          (index) => candidate(
            id: 'candidate-$index',
            eventId: 'event-$index',
            start: DateTime.utc(2026, 9, 23, 10),
            end: DateTime.utc(2026, 9, 23, 11),
          ),
        );
        expect(
          hasActionableEventScheduleConflict(
            draft(),
            candidates,
            onCandidateScanned: () => scans++,
          ),
          isFalse,
        );
        expect(scans, count);
      }
    });
  });
}
