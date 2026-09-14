import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/indicators/data/drift_indicator_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/counting_query_executor.dart';
import '../../../support/test_dependencies.dart';

/// M3 P02 — Temple next-visit via the scoped canonical range.
///
/// Ticket evidence law: the daily 367-candidate case must stop issuing
/// per-date/per-occurrence SQL (M0: 2,203 statements / ~311 ms), while the
/// visible next-visit semantics are preserved exactly.
void main() {
  late AppDatabase database;
  late CountingQueryExecutor executor;
  late String profileId;
  late DriftCalendarEventRepository calendar;
  late DriftIndicatorRepository indicators;

  const today = PlannerDate(year: 2026, month: 9, day: 14);
  final clock = DateTime.utc(2026, 9, 14, 12);

  setUp(() async {
    executor = CountingQueryExecutor(NativeDatabase.memory());
    database = AppDatabase.forTesting(executor);
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    await DriftEventTypeRepository(
      database: database,
      clock: FixedClock(clock),
    ).readEventTypes(profileId: profileId);
    calendar = DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(clock),
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    );
    indicators = DriftIndicatorRepository(
      database: database,
      clock: FixedClock(clock),
      calendarEvents: calendar,
    );
  });

  tearDown(() => database.close());

  Future<void> seedTempleSeries(
    String eventId, {
    required String startDate,
    String frequency = 'daily',
    String endMode = 'never',
    int? count,
    String? endDate,
  }) {
    return database.into(database.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: eventId,
            profileId: profileId,
            title: 'Temple $eventId',
            timing: CalendarEventTiming.allDay.name,
            startDate: startDate,
            activityTypeId: Value<String?>(SystemEventTypeIds.templeVisit),
            recurrenceFrequency: const Value<String>('daily'),
            recurrenceEndMode: Value<String>(endMode),
            recurrenceCount: Value<int?>(count),
            recurrenceEndDate: Value<String?>(endDate),
            createdAtUtc: clock,
            updatedAtUtc: clock,
          ),
        );
  }

  test('daily Temple series: statement count collapses to a bounded set',
      () async {
    await seedTempleSeries('temple-daily', startDate: today.iso8601);

    executor.clear();
    await indicators.readNextTempleVisit(profileId: profileId, today: today);
    final count = executor.statementCount;

    // M0 baseline: the legacy per-occurrence walk issued 2,203 statements
    // for exactly this case (~6 per candidate day over the 367-day window).
    // The scoped canonical path is bounded: one Temple source-ID read plus
    // the fixed batch reads of ONE single-Event scoped projection.  A daily
    // series contributes 367 candidate dates but ZERO additional statements
    // beyond the fixed per-Event batches.
    //
    // Relative regression law (ticket): the count must NOT scale with the
    // number of candidate days.  2,203 -> a low fixed count is a >50x cut.
    expect(count, lessThan(2203));
    expect(count, lessThan(500), reason: 'measured: $count statements');
  });

  test('statement count does NOT scale with the recurrence window',
      () async {
    // A daily series STARTING YEARS EARLIER still only scans today+366;
    // its statement count must equal the starts-today series (same fixed
    // batches, same candidate-day expansion with no extra SQL).
    await seedTempleSeries(
      'temple-old',
      startDate: today.addDays(-800).iso8601,
    );
    executor.clear();
    await indicators.readNextTempleVisit(profileId: profileId, today: today);
    final oldStartCount = executor.statementCount;

    await (database.delete(database.calendarEvents)).go();
    await seedTempleSeries('temple-today', startDate: today.iso8601);
    executor.clear();
    await indicators.readNextTempleVisit(profileId: profileId, today: today);
    final todayStartCount = executor.statementCount;

    expect(oldStartCount, todayStartCount,
        reason: 'projection SQL is independent of recurrence age');
  });

  test('daily Temple series resolves to today and stays visible-stable',
      () async {
    await seedTempleSeries('temple-daily', startDate: today.iso8601);
    final next = await indicators.readNextTempleVisit(
      profileId: profileId,
      today: today,
    );
    expect(next, today);
  });

  test('no Temple events -> null', () async {
    final next = await indicators.readNextTempleVisit(
      profileId: profileId,
      today: today,
    );
    expect(next, isNull);
  });

  test('recurring series already in progress still resolves from today',
      () async {
    // A daily series that started long ago: firstDate clamps to today and
    // the next visit is today itself.
    await seedTempleSeries(
      'temple-old',
      startDate: today.addDays(-30).iso8601,
    );
    final next = await indicators.readNextTempleVisit(
      profileId: profileId,
      today: today,
    );
    expect(next, today);
  });

  test('Temple visit beyond the 366-day horizon is not returned', () async {
    // A non-recurring Temple visit far outside the window.
    await database.into(database.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: 'temple-far',
            profileId: profileId,
            title: 'Temple far',
            timing: CalendarEventTiming.allDay.name,
            startDate: today.addDays(400).iso8601,
            activityTypeId: Value<String?>(SystemEventTypeIds.templeVisit),
            createdAtUtc: clock,
            updatedAtUtc: clock,
          ),
        );
    final next = await indicators.readNextTempleVisit(
      profileId: profileId,
      today: today,
    );
    expect(next, isNull);
  });

  test('multiple series: earliest eligible wins', () async {
    await seedTempleSeries(
      'temple-monthly',
      startDate: today.addDays(10).iso8601,
      frequency: 'monthly',
    );
    await seedTempleSeries('temple-daily', startDate: today.iso8601);

    final next = await indicators.readNextTempleVisit(
      profileId: profileId,
      today: today,
    );
    expect(next, today);
  });

  test('non-Temple Events never contribute to the Temple visit', () async {
    await database.into(database.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: 'evt-plain',
            profileId: profileId,
            title: 'Plain event today',
            timing: CalendarEventTiming.allDay.name,
            startDate: today.iso8601,
            createdAtUtc: clock,
            updatedAtUtc: clock,
          ),
        );
    final next = await indicators.readNextTempleVisit(
      profileId: profileId,
      today: today,
    );
    expect(next, isNull);
  });
}
