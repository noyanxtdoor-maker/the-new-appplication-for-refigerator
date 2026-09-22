import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:uuid/uuid.dart';

void main() {
  const januaryMonthEnd = PlannerDate(year: 2025, month: 1, day: 31);

  test(
    'AC-E-007,008 / OPD-1-016: monthly recurrence clamps each month end',
    () {
      const rule = CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.monthly,
      );

      expect(
        rule.occurrenceAt(startDate: januaryMonthEnd, index: 1),
        const PlannerDate(year: 2025, month: 2, day: 28),
      );
      expect(
        rule.occurrenceAt(startDate: januaryMonthEnd, index: 2),
        const PlannerDate(year: 2025, month: 3, day: 31),
      );
      expect(
        rule.occurrenceIndexOn(
          startDate: januaryMonthEnd,
          targetDate: const PlannerDate(year: 2025, month: 2, day: 27),
        ),
        isNull,
      );
    },
  );

  test(
    'AC-E-007,008 / OPD-1-017: Feb 29 recurs on Feb 28 in non-leap years',
    () {
      const rule = CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.yearly,
      );
      const leapDay = PlannerDate(year: 2024, month: 2, day: 29);

      expect(
        rule.occurrenceAt(startDate: leapDay, index: 1),
        const PlannerDate(year: 2025, month: 2, day: 28),
      );
      expect(
        rule.occurrenceAt(startDate: leapDay, index: 4),
        const PlannerDate(year: 2028, month: 2, day: 29),
      );
    },
  );

  test('AC-E-009,010: date and count end rules are deterministic', () {
    const byDate = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.daily,
      endMode: CalendarRecurrenceEndMode.onDate,
      endDate: PlannerDate(year: 2025, month: 2, day: 2),
    );
    const byCount = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.weekly,
      endMode: CalendarRecurrenceEndMode.afterCount,
      occurrenceCount: 2,
    );

    expect(
      byDate.occurrenceIndexOn(
        startDate: januaryMonthEnd,
        targetDate: const PlannerDate(year: 2025, month: 2, day: 2),
      ),
      2,
    );
    expect(
      byDate.occurrenceIndexOn(
        startDate: januaryMonthEnd,
        targetDate: const PlannerDate(year: 2025, month: 2, day: 3),
      ),
      isNull,
    );
    expect(
      byCount.occurrenceIndexOn(
        startDate: januaryMonthEnd,
        targetDate: const PlannerDate(year: 2025, month: 2, day: 14),
      ),
      isNull,
    );
  });

  test('Delta 4.2F: new repeat choices receive their locked concrete ends', () {
    const start = PlannerDate(year: 2026, month: 8, day: 9);

    expect(
      calendarDefaultRecurrenceEndDate(
        start,
        CalendarRecurrenceFrequency.daily,
      ),
      const PlannerDate(year: 2026, month: 10, day: 9),
    );
    expect(
      calendarDefaultRecurrenceEndDate(
        start,
        CalendarRecurrenceFrequency.weekly,
      ),
      const PlannerDate(year: 2026, month: 11, day: 9),
    );
    expect(
      calendarDefaultRecurrenceEndDate(
        start,
        CalendarRecurrenceFrequency.monthly,
      ),
      const PlannerDate(year: 2027, month: 2, day: 9),
    );
    expect(
      calendarDefaultRecurrenceEndDate(
        start,
        CalendarRecurrenceFrequency.yearly,
      ),
      const PlannerDate(year: 2028, month: 8, day: 9),
    );
  });

  test('Delta 4.2F: custom pattern JSON is versioned and fail-safe', () {
    const pattern = CalendarRecurrencePattern(
      interval: 2,
      weeklyWeekdays: <int>{DateTime.tuesday, DateTime.sunday},
      monthlyMode: CalendarRecurrenceMonthlyMode.nthWeekday,
    );

    final encoded = calendarRecurrencePatternToJson(pattern);

    expect(encoded, contains('"version":1'));
    expect(calendarRecurrencePatternFromJson(encoded), pattern);
    expect(calendarRecurrencePatternFromJson('{not-json'), isNull);
    expect(
      calendarRecurrencePatternFromJson(
        '{"version":2,"interval":2,"weekdays":[],"monthlyMode":"dayOfMonth"}',
      ),
      isNull,
    );
  });

  test('Delta 4.2F: custom daily interval preserves deterministic indexes', () {
    const start = PlannerDate(year: 2026, month: 8, day: 9);
    const rule = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.daily,
      pattern: CalendarRecurrencePattern(interval: 3),
    );

    expect(
      rule.occurrenceAt(startDate: start, index: 2),
      const PlannerDate(year: 2026, month: 8, day: 15),
    );
    expect(
      rule.occurrenceIndexOn(
        startDate: start,
        targetDate: const PlannerDate(year: 2026, month: 8, day: 12),
      ),
      1,
    );
    expect(
      rule.occurrenceIndexOn(
        startDate: start,
        targetDate: const PlannerDate(year: 2026, month: 8, day: 13),
      ),
      isNull,
    );
  });

  test('Delta 4.2F: custom week supports Sunday plus Tuesday', () {
    const start = PlannerDate(year: 2026, month: 8, day: 9);
    const rule = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.weekly,
      pattern: CalendarRecurrencePattern(
        weeklyWeekdays: <int>{DateTime.sunday, DateTime.tuesday},
      ),
    );

    expect(start.weekday, DateTime.sunday);
    expect(
      rule.occurrenceAt(startDate: start, index: 1),
      const PlannerDate(year: 2026, month: 8, day: 11),
    );
    expect(
      rule.occurrenceAt(startDate: start, index: 2),
      const PlannerDate(year: 2026, month: 8, day: 16),
    );
    expect(
      rule.occurrenceIndexOn(
        startDate: start,
        targetDate: const PlannerDate(year: 2026, month: 8, day: 18),
      ),
      3,
    );
    expect(
      rule.occurrenceIndexOn(
        startDate: start,
        targetDate: const PlannerDate(year: 2026, month: 8, day: 17),
      ),
      isNull,
    );
  });

  test('Delta 4.2F: selecting all weekdays repeats on every next day', () {
    const start = PlannerDate(year: 2026, month: 8, day: 9);
    const rule = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.weekly,
      pattern: CalendarRecurrencePattern(
        weeklyWeekdays: <int>{
          DateTime.monday,
          DateTime.tuesday,
          DateTime.wednesday,
          DateTime.thursday,
          DateTime.friday,
          DateTime.saturday,
          DateTime.sunday,
        },
      ),
    );

    for (var index = 1; index <= 9; index++) {
      expect(
        rule.occurrenceAt(startDate: start, index: index),
        start.addDays(index),
      );
      expect(
        rule.occurrenceIndexOn(
          startDate: start,
          targetDate: start.addDays(index),
        ),
        index,
      );
    }
  });

  test('Delta 4.2F: custom month supports day and nth-weekday modes', () {
    const start = PlannerDate(year: 2026, month: 8, day: 9);
    const byDay = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.monthly,
      pattern: CalendarRecurrencePattern(interval: 2),
    );
    const byNthWeekday = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.monthly,
      pattern: CalendarRecurrencePattern(
        monthlyMode: CalendarRecurrenceMonthlyMode.nthWeekday,
      ),
    );

    expect(
      byDay.occurrenceAt(startDate: start, index: 1),
      const PlannerDate(year: 2026, month: 10, day: 9),
    );
    expect(
      byDay.occurrenceIndexOn(
        startDate: start,
        targetDate: const PlannerDate(year: 2026, month: 9, day: 9),
      ),
      isNull,
    );
    expect(
      byNthWeekday.occurrenceAt(startDate: start, index: 1),
      const PlannerDate(year: 2026, month: 9, day: 13),
    );
    expect(
      byNthWeekday.occurrenceIndexOn(
        startDate: start,
        targetDate: const PlannerDate(year: 2026, month: 10, day: 11),
      ),
      2,
    );
  });

  test('Delta 4.2F: a missing fifth weekday month is skipped', () {
    const start = PlannerDate(year: 2026, month: 3, day: 30);
    const rule = CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.monthly,
      pattern: CalendarRecurrencePattern(
        monthlyMode: CalendarRecurrenceMonthlyMode.nthWeekday,
      ),
    );

    expect(start.weekday, DateTime.monday);
    expect(
      rule.occurrenceAt(startDate: start, index: 1),
      const PlannerDate(year: 2026, month: 6, day: 29),
    );
    expect(
      rule.occurrenceIndexOn(
        startDate: start,
        targetDate: const PlannerDate(year: 2026, month: 6, day: 29),
      ),
      1,
    );
  });

  test(
    'AC-E-014,019,024: occurrence and exception identities are stable UUIDs',
    () {
      const eventId = '11111111-1111-4111-8111-111111111111';
      const operationId = '22222222-2222-4222-8222-222222222222';
      final first = CalendarEventOccurrenceIdentity.forDate(
        eventId: eventId,
        originalDate: januaryMonthEnd,
      );
      final retry = CalendarEventOccurrenceIdentity.forDate(
        eventId: eventId,
        originalDate: januaryMonthEnd,
      );
      final exception = CalendarEventExceptionIdentity.forOperation(
        operationId: operationId,
        occurrenceId: first,
      );

      expect(first, retry);
      expect(Uuid.isValidUUID(fromString: first), isTrue);
      expect(Uuid.isValidUUID(fromString: exception), isTrue);
    },
  );

  test('AC-E-005,006,021: elapsed time does not infer a factual outcome', () {
    const occurrence = CalendarEventOccurrence(
      id: 'occurrence',
      eventId: 'event',
      profileId: 'profile',
      title: 'Report-required event',
      timing: CalendarEventTiming.timed,
      originalDate: januaryMonthEnd,
      displayDate: januaryMonthEnd,
      status: CalendarEventStatus.scheduled,
      requiresReport: true,
      recurrence: CalendarRecurrenceRule(),
      endUtc: null,
    );

    expect(occurrence.status, CalendarEventStatus.scheduled);
    expect(
      occurrence.isAwaitingReport(
        nowUtc: DateTime.utc(2030),
        displayToday: const PlannerDate(year: 2030, month: 1, day: 1),
      ),
      isFalse,
    );
  });

  test('VS08-OWNER: report labels use the canonical status vocabulary', () {
    expect(
      calendarEventOutcomeLabel(
        status: CalendarEventStatus.scheduled,
        isContactEvent: true,
      ),
      'Unreported',
    );
    // OWNER LAW (2026-09-22), superseding the Delta 2 matrix: the success
    // state reads 'Contacted' for a CONTACT Event and 'Completed' for an
    // ordinary Event. This is PRESENTATION ONLY — the canonical stored status
    // is still `completedHappened`.
    expect(
      calendarEventOutcomeLabel(
        status: CalendarEventStatus.completedHappened,
        isContactEvent: true,
      ),
      'Contacted',
    );
    expect(
      calendarEventOutcomeLabel(
        status: CalendarEventStatus.completedHappened,
        isContactEvent: false,
      ),
      'Completed',
    );
    expect(
      calendarEventOutcomeLabel(
        status: CalendarEventStatus.partiallyCompleted,
        isContactEvent: true,
      ),
      // NX-03: the user-facing partial outcome is 'Missed' for Contact and
      // generic Events alike (the stored MISSED_ATTEMPTED value is internal).
      'Missed',
    );
    expect(
      calendarEventOutcomeLabel(
        status: CalendarEventStatus.partiallyCompleted,
        isContactEvent: false,
      ),
      'Missed',
    );
    // NX-03: the status helper reads 'Missed' for the partial outcome in
    // every context (Contact and generic); legacy Did Not Attempt stays
    // historically readable for non-Contact records.
    expect(
      calendarEventStatusLabel(CalendarEventStatus.partiallyCompleted),
      'Missed',
    );
    expect(
      calendarEventStatusLabel(
        CalendarEventStatus.partiallyCompleted,
        isContactEvent: true,
      ),
      'Missed',
    );
    expect(
      calendarEventStatusLabel(CalendarEventStatus.didNotHappen),
      'Did Not Attempt',
    );
    expect(
      calendarEventOutcomeLabel(
        status: CalendarEventStatus.didNotHappen,
        isContactEvent: false,
      ),
      'Did Not Attempt',
    );
  });
}
