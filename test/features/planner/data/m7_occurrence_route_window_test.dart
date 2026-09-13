import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// M7 section 64 / 53 P29 — occurrence routing must not lose the PREVIOUS
/// local day.
///
/// An Event reminder's target is `T = start - offset`, so an early-morning
/// Event with a long lead has a target that falls on the prior calendar day.
/// Report-reminder routes resolve the occurrence by scanning a bounded window
/// from "today" forward; when that window opened AT today, yesterday's
/// occurrence became unresolvable and the reminder could never be delivered.
///
/// These tests pin the widened lower bound and, just as importantly, that the
/// upper bound did not grow: the window is still bounded.
void main() {
  late AppDatabase database;
  late DriftCalendarEventRepository events;
  late String profileId;

  final clock = FixedClock(DateTime.utc(2026, 9, 11, 10));

  setUp(() async {
    database = openMemoryDatabase();
    events = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Etc/UTC'),
    );
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
  });

  tearDown(() => database.close());

  Future<String> seedEvent(
    PlannerDate start, {
    CalendarRecurrenceRule recurrence = const CalendarRecurrenceRule(),
  }) async {
    final id = const UuidIdentifierSource().nextUuid();
    await events.saveEvent(
      profileId: profileId,
      draft: CalendarEventDraft(
        id: id,
        title: 'Early flight',
        timing: CalendarEventTiming.timed,
        startDate: start,
        startMinute: 5 * 60,
        endMinute: 6 * 60,
        timeZoneId: 'Etc/UTC',
        requiresReport: false,
        recurrence: recurrence,
      ),
    );
    return id;
  }

  test('P29 an occurrence one day before today still resolves', () async {
    final yesterday = PlannerDate.fromDateTime(
      clock.nowUtc().toLocal(),
    ).addDays(-1);
    final eventId = await seedEvent(yesterday);

    final resolved = await events.readOccurrenceById(
      profileId: profileId,
      eventId: eventId,
      occurrenceId: CalendarEventOccurrenceIdentity.forDate(
        eventId: eventId,
        originalDate: yesterday,
      ),
    );

    expect(
      resolved,
      isNotNull,
      reason:
          'an early-morning Event whose reminder target lands on yesterday '
          'must stay routable (section 64)',
    );
    expect(resolved!.originalDate, yesterday);
  });

  test('P29 today still resolves and the window stays bounded', () async {
    final today = PlannerDate.fromDateTime(clock.nowUtc().toLocal());
    final eventId = await seedEvent(today);
    final identity = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: today,
    );

    expect(
      await events.readOccurrenceById(
        profileId: profileId,
        eventId: eventId,
        occurrenceId: identity,
      ),
      isNotNull,
    );

    // Two days back is OUTSIDE the bounded window: widening the floor by one
    // day must not turn the scan into an unbounded walk.
    final wayBack = today.addDays(-2);
    expect(
      await events.readOccurrenceById(
        profileId: profileId,
        eventId: eventId,
        occurrenceId: CalendarEventOccurrenceIdentity.forDate(
          eventId: eventId,
          originalDate: wayBack,
        ),
      ),
      isNull,
      reason: 'the horizon remains bounded, only its lower edge moved',
    );
  });

  test('P29 a recurring series anchored well before today still resolves its newest occurrence', () async {
    // A long-running DAILY series that began a week ago: the projection still
    // has to find the current-period occurrence rather than give up at the
    // origin.  (A non-recurring Event has exactly ONE occurrence — its start
    // date — so this case only exists for a recurring source.)
    final today = PlannerDate.fromDateTime(clock.nowUtc().toLocal());
    final eventId = await seedEvent(
      today.addDays(-7),
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );

    final resolved = await events.readOccurrenceById(
      profileId: profileId,
      eventId: eventId,
      occurrenceId: CalendarEventOccurrenceIdentity.forDate(
        eventId: eventId,
        originalDate: today,
      ),
    );

    expect(resolved, isNotNull);
    expect(resolved!.originalDate, today);
  });
}
