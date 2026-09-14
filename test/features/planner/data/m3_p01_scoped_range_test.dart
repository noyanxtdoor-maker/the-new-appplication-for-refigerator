import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/counting_query_executor.dart';
import '../../../support/test_dependencies.dart';

/// M3 P01 — Event-ID-scoped canonical range projection.
///
/// Ticket evidence law: targeted Event among 600 unrelated events must touch
/// TARGETED SOURCE ROWS ONLY (bounded statement count, no 601-row scan), and
/// the filtered output must be IDENTICAL to filtering the canonical
/// unscoped range.
void main() {
  late AppDatabase database;
  late CountingQueryExecutor executor;
  late String profileId;
  late DriftCalendarEventRepository calendar;

  const today = PlannerDate(year: 2026, month: 9, day: 14);
  final clock = DateTime.utc(2026, 9, 14, 12);
  final horizon = today.addDays(42);

  setUp(() async {
    executor = CountingQueryExecutor(NativeDatabase.memory());
    database = AppDatabase.forTesting(executor);
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    calendar = DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(clock),
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    );
  });

  tearDown(() => database.close());

  Future<void> seedEvent(
    String eventId, {
    String? startDate,
    String? activityTypeId,
  }) {
    return database.into(database.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: eventId,
            profileId: profileId,
            title: 'Event $eventId',
            timing: CalendarEventTiming.allDay.name,
            startDate: startDate ?? today.iso8601,
            activityTypeId: Value<String?>(activityTypeId),
            createdAtUtc: clock,
            updatedAtUtc: clock,
          ),
        );
  }

  test('empty ID set returns empty projection WITHOUT reading events', () async {
    await seedEvent('evt-target');
    executor.clear();
    final items = await calendar.readRangeForEvents(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
      eventIds: const <String>{},
    );
    expect(items, isEmpty);
    expect(
      executor.statements.any((statement) => statement.contains('calendar')),
      isFalse,
      reason: 'empty scope must short-circuit before any Event query',
    );
  });

  test('targeted Event among 600 unrelated: scoped source rows only', () async {
    await seedEvent('evt-target');
    for (var index = 0; index < 600; index += 1) {
      await seedEvent('evt-noise-$index');
    }

    // The unscoped canonical path is the current-law baseline: 601 source
    // rows go through batching and per-date expansion.
    executor.clear();
    final unscoped = await calendar.readRange(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
    );
    final unscopedCount = executor.statementCount;
    expect(unscopedCount, lessThan(30),
        reason: 'S1A batching keeps even the global read bounded');
    expect(unscoped, hasLength(601));

    // The scoped path must NOT re-read 601 source rows: the events SELECT
    // carries the source-ID constraint, so the executor sees an IN clause.
    executor.clear();
    final scoped = await calendar.readRangeForEvents(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
      eventIds: <String>{'evt-target'},
    );
    final eventsReads = executor.statements
        .where((statement) => statement.contains('"calendar_events"'))
        .toList();
    expect(eventsReads, isNotEmpty);
    expect(
      eventsReads.any((statement) => statement.contains('IN (?')),
      isTrue,
      reason: 'scoped read must constrain source rows by Event ID',
    );
    expect(scoped, hasLength(1));
    expect(scoped.single.eventId, 'evt-target');
  });

  test('scoped output equals unscoped output filtered to the same IDs',
      () async {
    await seedEvent('evt-a', startDate: today.iso8601);
    await seedEvent('evt-b', startDate: today.addDays(3).iso8601);
    for (var index = 0; index < 20; index += 1) {
      await seedEvent('evt-noise-$index');
    }

    final unscoped = await calendar.readRange(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
    );
    final expected = unscoped
        .where((item) => const {'evt-a', 'evt-b'}.contains(item.eventId))
        .map((item) => (item.id, item.eventId, item.date))
        .toList();

    final scoped = await calendar.readRangeForEvents(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
      eventIds: const <String>{'evt-a', 'evt-b'},
    );
    final actual = scoped
        .map((item) => (item.id, item.eventId, item.date))
        .toList();

    expect(actual, expected);
  });

  test('null ID set behaves exactly like the unscoped range', () async {
    await seedEvent('evt-a');
    await seedEvent('evt-b');

    final unscoped = await calendar.readRange(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
    );
    final unscopedScoped = await calendar.readRangeForEvents(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
      eventIds: null,
    );
    expect(
      unscopedScoped.map((item) => item.id),
      unscoped.map((item) => item.id),
    );
  });

  test('events outside the window still obey the range law when scoped',
      () async {
    await seedEvent('evt-in-horizon');
    await seedEvent('evt-out', startDate: today.addDays(100).iso8601);

    final scoped = await calendar.readRangeForEvents(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
      eventIds: <String>{'evt-in-horizon', 'evt-out'},
    );
    expect(scoped, hasLength(1));
    expect(scoped.single.eventId, 'evt-in-horizon');
  });

  test('scoped read is profile-isolated', () async {
    await seedEvent('evt-mine');
    // A distinct profile row (completeOnboarding is idempotent per DB, so
    // the second profile is inserted directly).
    const other = 'other-profile-id';
    await database.into(database.localProfiles).insert(
          LocalProfilesCompanion.insert(
            id: other,
            slot: const Value('other-profile-slot'),
            localName: 'Other Profile',
            createdAtUtc: clock,
            updatedAtUtc: clock,
          ),
        );
    await database.into(database.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: 'evt-other-profile',
            profileId: other,
            title: 'Other',
            timing: CalendarEventTiming.allDay.name,
            startDate: today.iso8601,
            createdAtUtc: clock,
            updatedAtUtc: clock,
          ),
        );

    final scoped = await calendar.readRangeForEvents(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
      eventIds: <String>{'evt-mine', 'evt-other-profile'},
    );
    expect(scoped.map((item) => item.eventId), <String>['evt-mine']);
  });
}
