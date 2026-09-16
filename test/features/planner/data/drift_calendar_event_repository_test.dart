import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:uuid/uuid.dart';

import '../../../support/test_dependencies.dart';

const _eventId = '11111111-1111-4111-8111-111111111111';
const _replacementId = '33333333-3333-4333-8333-333333333333';
const _operationId = '22222222-2222-4222-8222-222222222222';
const _secondOperationId = '44444444-4444-4444-8444-444444444444';
const _duplicateId = '55555555-5555-4555-8555-555555555555';
const _duplicateOperationId = '66666666-6666-4666-8666-666666666666';
const _snapshotEditOperationId = '77777777-7777-4777-8777-777777777777';
const _snapshotTypeChangeOperationId = '88888888-8888-4888-8888-888888888888';
const _start = PlannerDate(year: 2026, month: 1, day: 31);

void main() {
  late AppDatabase database;
  late String profileId;
  late IanaCalendarEventTimeZones timeZones;

  setUp(() async {
    database = openMemoryDatabase();
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    timeZones = IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila');
  });

  tearDown(() => database.close());

  DriftCalendarEventRepository buildRepository({
    CalendarEventReportSource reportSource =
        const EmptyCalendarEventReportSource(),
    CalendarEventTaskContextSource taskSource =
        const EmptyCalendarEventTaskContextSource(),
    CalendarEventWriteGuard writeGuard = const AllowCalendarEventWrites(),
  }) {
    return DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 2, 2, 12)),
      timeZones: timeZones,
      reportSource: reportSource,
      taskContextSource: taskSource,
      writeGuard: writeGuard,
    );
  }

  test(
    'AC-E-001..010,014,020: offline all-day recurrence stays date-only',
    () async {
      final repository = buildRepository();
      final saved = await repository.saveEvent(
        profileId: profileId,
        draft: _allDayDraft(),
      );

      final february = await repository.readDay(
        profileId: profileId,
        date: const PlannerDate(year: 2026, month: 2, day: 28),
      );

      expect(saved.title, 'Month-end visit');
      expect(february, hasLength(1));
      expect(february.single.timing, PlannerEventTiming.allDay);
      expect(february.single.date.iso8601, '2026-02-28');
      expect(february.single.startUtc, isNull);
      expect(february.single.timeZoneId, isNull);
      expect(february.single.locationText, 'Typed local location');
    },
  );

  test(
    'final-hour 11 PM-12 AM event saves and stays visible on its day',
    () async {
      final repository = buildRepository();
      await repository.saveEvent(
        profileId: profileId,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Final-hour review',
          timing: CalendarEventTiming.timed,
          startDate: PlannerDate(year: 2026, month: 7, day: 28),
          startMinute: 23 * 60, // 11:00 PM
          endMinute: 24 * 60, // 12:00 AM next day (final-hour boundary 1440)
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
        ),
      );

      final occurrence = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: const PlannerDate(year: 2026, month: 7, day: 28),
      );
      expect(occurrence, isNotNull, reason: 'occurrence must exist');
      expect(occurrence!.startDisplay, DateTime(2026, 7, 28, 23));
      expect(occurrence.endDisplay, DateTime(2026, 7, 29, 0));
      expect(occurrence.displayDate.iso8601, '2026-07-28');

      // The day read surfaces the Event on July 28 (its start day) with the
      // exact final-hour slice, and does not leak it onto July 29.
      final july28 = await repository.readDay(
        profileId: profileId,
        date: const PlannerDate(year: 2026, month: 7, day: 28),
      );
      expect(
        july28.singleWhere((item) => item.id == occurrence.id).startLocal,
        DateTime(2026, 7, 28, 23),
      );
      final july29 = await repository.readDay(
        profileId: profileId,
        date: const PlannerDate(year: 2026, month: 7, day: 29),
      );
      expect(
        july29.any((item) => item.id == occurrence.id),
        isFalse,
        reason: 'a final-hour Event belongs to its start day only',
      );
    },
  );

  test(
    'AC-E-011,012,020: timed event retains origin IANA zone and converts',
    () async {
      final repository = buildRepository();
      await repository.saveEvent(
        profileId: profileId,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Origin-zone meeting',
          timing: CalendarEventTiming.timed,
          startDate: PlannerDate(year: 2026, month: 7, day: 28),
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'America/New_York',
          requiresReport: false,
        ),
      );

      final occurrence = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: const PlannerDate(year: 2026, month: 7, day: 28),
      );

      expect(occurrence!.timeZoneId, 'America/New_York');
      expect(occurrence.displayTimeZoneId, 'Asia/Manila');
      expect(occurrence.startUtc, DateTime.utc(2026, 7, 28, 13));
      expect(occurrence.startDisplay, DateTime(2026, 7, 28, 21));
    },
  );

  test(
    'AC-E-013,015,016,019,024: cancellation is scoped and retry-idempotent',
    () async {
      final repository = buildRepository();
      await repository.saveEvent(profileId: profileId, draft: _allDayDraft());

      final first = await repository.cancelEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: const PlannerDate(year: 2026, month: 2, day: 28),
        scope: CalendarEventEditScope.occurrence,
        operationId: _operationId,
      );
      final retry = await repository.cancelEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: const PlannerDate(year: 2026, month: 2, day: 28),
        scope: CalendarEventEditScope.occurrence,
        operationId: _operationId,
      );
      final occurrence = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: const PlannerDate(year: 2026, month: 2, day: 28),
      );
      final exceptions = await database
          .select(database.calendarEventExceptions)
          .get();

      expect(first, CalendarEventMutationOutcome.changed);
      expect(retry, CalendarEventMutationOutcome.unchanged);
      expect(occurrence!.status, CalendarEventStatus.cancelled);
      expect(exceptions, hasLength(1));
      expect(Uuid.isValidUUID(fromString: exceptions.single.id), isTrue);
    },
  );

  test('AC-E-015,016,022 + D2: occurrence-scoped reschedule of a repeating '
      'Event keeps the occurrence attached to the original series as an '
      'override — no standalone replacement Event', () async {
    final repository = buildRepository();
    await repository.saveEvent(profileId: profileId, draft: _allDayDraft());

    await repository.rescheduleEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
      scope: CalendarEventEditScope.occurrence,
      replacement: const CalendarEventDraft(
        id: _replacementId,
        title: 'Replacement',
        timing: CalendarEventTiming.allDay,
        startDate: PlannerDate(year: 2026, month: 2, day: 1),
        requiresReport: false,
      ),
      operationId: _operationId,
    );

    // Series lineage preserved: the moved occurrence still reads from the
    // ORIGINAL event row under its deterministic occurrence identity.
    final movedId = CalendarEventOccurrenceIdentity.forDate(
      eventId: _eventId,
      originalDate: _start,
    );
    final moved = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
    );
    expect(moved, isNotNull);
    expect(moved!.id, movedId);
    expect(moved.eventId, _eventId);
    expect(moved.originalDate, _start);
    expect(moved.displayDate, const PlannerDate(year: 2026, month: 2, day: 1));
    expect(moved.status, CalendarEventStatus.scheduled);
    expect(moved.isRecurring, isTrue);

    // No standalone replacement Event row was created.
    final replacement = await repository.readOccurrence(
      profileId: profileId,
      eventId: _replacementId,
      originalDate: const PlannerDate(year: 2026, month: 2, day: 1),
    );
    expect(replacement, isNull);

    // The moved occurrence renders on its new date exactly once and never
    // leaks onto the original date.
    final februaryFirst = await repository.readDay(
      profileId: profileId,
      date: const PlannerDate(year: 2026, month: 2, day: 1),
    );
    expect(februaryFirst.where((item) => item.id == movedId), hasLength(1));
    final januaryThirtyFirst = await repository.readDay(
      profileId: profileId,
      date: _start,
    );
    expect(
      januaryThirtyFirst.any((item) => item.id == movedId),
      isFalse,
      reason: 'a moved occurrence must never leak onto its original date',
    );

    // The next series occurrence (Feb 28) remains scheduled normally.
    final next = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: const PlannerDate(year: 2026, month: 2, day: 28),
    );
    expect(next!.status, CalendarEventStatus.scheduled);
  });

  test('D2: moving one weekly occurrence to a new time keeps series lineage, '
      'the repeat identity, and the untouched future occurrence', () async {
    final repository = buildRepository();
    const first = PlannerDate(year: 2026, month: 8, day: 7); // Friday
    const movedDate = PlannerDate(year: 2026, month: 8, day: 14);
    const futureDate = PlannerDate(year: 2026, month: 8, day: 21);
    await repository.saveEvent(
      profileId: profileId,
      draft: const CalendarEventDraft(
        id: _eventId,
        title: 'Weekly Meeting',
        timing: CalendarEventTiming.timed,
        startDate: first,
        startMinute: 19 * 60,
        endMinute: 20 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: false,
        recurrence: CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.weekly,
        ),
      ),
    );

    // Move Aug 14 only to 8:30-9:30 PM with "This event only" scope.
    await repository.rescheduleEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: movedDate,
      scope: CalendarEventEditScope.occurrence,
      replacement: const CalendarEventDraft(
        id: _replacementId,
        title: 'Weekly Meeting',
        timing: CalendarEventTiming.timed,
        startDate: movedDate,
        startMinute: 20 * 60 + 30,
        endMinute: 21 * 60 + 30,
        timeZoneId: 'Asia/Manila',
        requiresReport: false,
      ),
      operationId: _operationId,
    );

    // Exactly ONE Event row remains — the moved occurrence never becomes
    // an unrelated standalone Event and no second recurrence chain exists.
    final rows = await database.select(database.calendarEvents).get();
    expect(rows, hasLength(1));
    expect(rows.single.id, _eventId);

    // The moved occurrence keeps its series identity, occurrence identity,
    // and repeat lineage, and now carries the overridden 8:30-9:30 window.
    final movedId = CalendarEventOccurrenceIdentity.forDate(
      eventId: _eventId,
      originalDate: movedDate,
    );
    final moved = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: movedDate,
    );
    expect(moved, isNotNull);
    expect(moved!.id, movedId);
    expect(moved.isRecurring, isTrue);
    expect(moved.startDisplay, DateTime(2026, 8, 14, 20, 30));
    expect(moved.endDisplay, DateTime(2026, 8, 14, 21, 30));

    // The first occurrence is untouched and the future occurrence stays at
    // the original 7:00-8:00 PM window.
    final firstOccurrence = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: first,
    );
    expect(firstOccurrence!.startDisplay, DateTime(2026, 8, 7, 19));
    final futureOccurrence = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: futureDate,
    );
    expect(futureOccurrence!.startDisplay, DateTime(2026, 8, 21, 19));

    // The moved day renders exactly one occurrence (no duplicate).
    final movedDay = await repository.readDay(
      profileId: profileId,
      date: movedDate,
    );
    expect(movedDay.where((item) => item.id == movedId), hasLength(1));
  });

  test(
    'VS08-PB: reportable occurrence cancellation preserves external history',
    () async {
      final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: _eventId,
        originalDate: _start,
      );
      final reportSource = _MemoryReportSource(<CalendarEventReportSnapshot>[
        CalendarEventReportSnapshot(
          occurrenceId: occurrenceId,
          originalDate: _start,
          status: CalendarEventStatus.completedHappened,
        ),
      ]);
      final repository = buildRepository(reportSource: reportSource);
      await repository.saveEvent(profileId: profileId, draft: _allDayDraft());

      final result = await repository.cancelEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        scope: CalendarEventEditScope.occurrence,
        operationId: _secondOperationId,
      );
      final cancelled = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );

      expect(result, CalendarEventMutationOutcome.changed);
      expect(cancelled!.status, CalendarEventStatus.cancelled);
      expect(reportSource.reports, hasLength(1));
      expect(
        reportSource.reports.single.status,
        CalendarEventStatus.completedHappened,
      );
    },
  );

  test(
    'AC-E-017,018,021,023: reports are factual and reported history is immutable',
    () async {
      final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: _eventId,
        originalDate: _start,
      );
      final reports = _MemoryReportSource(<CalendarEventReportSnapshot>[
        CalendarEventReportSnapshot(
          occurrenceId: occurrenceId,
          originalDate: _start,
          status: CalendarEventStatus.partiallyCompleted,
        ),
      ]);
      final repository = buildRepository(
        reportSource: reports,
        taskSource: const _TaskLinks(<String>['task-one']),
      );
      await repository.saveEvent(profileId: profileId, draft: _allDayDraft());

      final occurrence = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      expect(occurrence!.status, CalendarEventStatus.partiallyCompleted);
      expect(occurrence.linkedTaskIds, <String>['task-one']);

      // Approved resize-era behavior: an in-place edit (the same path
      // resize uses) on a series that already has a report preserves
      // the report snapshot and writes the new draft. The
      // immutability throw is reserved for structural cancellation
      // and reschedule flows.
      final outcome = await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        scope: CalendarEventEditScope.series,
        draft: _allDayDraft(title: 'Edited in place, history preserved'),
        operationId: _secondOperationId,
      );
      expect(outcome, CalendarEventMutationOutcome.changed);

      final preserved = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      expect(preserved!.status, CalendarEventStatus.partiallyCompleted);
      expect(preserved.linkedTaskIds, <String>['task-one']);

      final edited = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      expect(edited!.title, 'Edited in place, history preserved');
    },
  );

  test(
    'AC-E-015,023: series cancellation preserves an earlier report snapshot',
    () async {
      final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: _eventId,
        originalDate: _start,
      );
      final repository = buildRepository(
        reportSource: _MemoryReportSource(<CalendarEventReportSnapshot>[
          CalendarEventReportSnapshot(
            occurrenceId: occurrenceId,
            originalDate: _start,
            status: CalendarEventStatus.completedHappened,
          ),
        ]),
      );
      await repository.saveEvent(profileId: profileId, draft: _allDayDraft());

      await repository.cancelEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: const PlannerDate(year: 2026, month: 2, day: 28),
        scope: CalendarEventEditScope.series,
        operationId: _secondOperationId,
      );

      final reported = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      final cancelled = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: const PlannerDate(year: 2026, month: 2, day: 28),
      );

      expect(reported!.status, CalendarEventStatus.completedHappened);
      expect(cancelled!.status, CalendarEventStatus.cancelled);
    },
  );

  test(
    'AC-E-024 / BR-E-010: injected failure rolls back the full mutation',
    () async {
      final repository = buildRepository(
        writeGuard: const _FailingWriteGuard(),
      );

      await expectLater(
        repository.saveEvent(profileId: profileId, draft: _allDayDraft()),
        throwsA(isA<StateError>()),
      );

      expect(await database.select(database.calendarEvents).get(), isEmpty);
    },
  );

  test(
    'VS08-OWNER: backup identity and provenance survive an ordinary edit',
    () async {
      final repository = buildRepository();
      await repository.saveEvent(
        profileId: profileId,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Backup visit',
          timing: CalendarEventTiming.allDay,
          startDate: _start,
          requiresReport: false,
          isBackupAppointment: true,
          backupForEventId: _replacementId,
          backupRelationshipProvenance: 'user-classified',
        ),
      );
      final existing = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        scope: CalendarEventEditScope.series,
        draft: existing!.copyWith(title: 'Edited backup visit'),
        operationId: _operationId,
      );

      final row = (await database.select(database.calendarEvents).get()).single;
      expect(row.isBackupAppointment, isTrue);
      expect(row.backupForEventId, _replacementId);
      expect(row.backupRelationshipProvenance, 'user-classified');

      final normalized = existing
          .copyWith(isBackupAppointment: false)
          .normalized();
      expect(normalized.backupForEventId, isNull);
      expect(normalized.backupRelationshipProvenance, isNull);
    },
  );

  test(
    'VS08-OWNER: duplicate creates a new scheduled event without outcome state',
    () async {
      final repository = buildRepository();
      await repository.saveEvent(
        profileId: profileId,
        draft: _allDayDraft().copyWith(
          contributionRuleKey: 'weekly-life-indicator-rule',
          status: CalendarEventStatus.completedHappened,
        ),
      );

      final first = await repository.duplicateEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        duplicateId: _duplicateId,
        operationId: _duplicateOperationId,
      );
      final retry = await repository.duplicateEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        duplicateId: _duplicateId,
        operationId: _duplicateOperationId,
      );

      final duplicate = await repository.readEventDraft(
        profileId: profileId,
        eventId: _duplicateId,
      );
      final rows = await database.select(database.calendarEvents).get();

      expect(first, CalendarEventMutationOutcome.changed);
      expect(retry, CalendarEventMutationOutcome.unchanged);
      expect(rows, hasLength(2));
      expect(duplicate!.title, 'Month-end visit (Copy)');
      expect(duplicate.status, CalendarEventStatus.scheduled);
      expect(duplicate.contributionRuleKey, isNull);
      expect(duplicate.recurrence.isRecurring, isFalse);
      final duplicateRow = rows.singleWhere((row) => row.id == _duplicateId);
      final sourceRow = rows.singleWhere((row) => row.id == _eventId);
      expect(duplicateRow.parentEventId, _eventId);
      expect(sourceRow.parentEventId, isNull);
    },
  );

  test(
    'Pack 1A: Event Type snapshots preserve history across rename, color, and type changes',
    () async {
      final eventTypes = DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 2, 2, 12)),
      );
      final seededTypes = await eventTypes.readEventTypes(profileId: profileId);
      final scriptureStudy = seededTypes.singleWhere(
        (type) => type.stableKey == SystemEventTypeKeys.scriptureStudy,
      );
      final exercise = seededTypes.singleWhere(
        (type) => type.stableKey == SystemEventTypeKeys.exercise,
      );
      final repository = buildRepository();

      // Accepted Contract E/F law: a NEW or type-changed Event may select a
      // canonical slot Event Type only while that slot has exactly one live
      // raw-active Goal occupant. M6's zero-goal law means a fresh profile
      // carries no Goals, so seed the two slot occupants this scenario uses
      // before exercising history preservation.
      Future<void> seedSlotOccupant(int slotIndex) async {
        final slot = CanonicalGoalSlot.bySlot(slotIndex);
        await database
            .into(database.goals)
            .insert(
              GoalsCompanion.insert(
                id: 'snapshot-goal-$slotIndex',
                profileId: profileId,
                role: slot.role.storageName,
                title: slot.defaultTitle,
                status: 'active',
                activeSlotIndex: Value<int?>(slot.slotIndex),
                indicatorKey: Value<String?>(slot.indicatorKey),
                assignedEventTypeStableKey: Value<String?>(
                  slot.eventTypeStableKey,
                ),
                iconId: const Value<String?>(null),
                createdAtUtc: DateTime.utc(2026, 2, 2, 12),
                updatedAtUtc: DateTime.utc(2026, 2, 2, 12),
                archivedAtUtc: const Value<DateTime?>(null),
              ),
            );
      }

      await seedSlotOccupant(2); // Scripture Study: the Event's first type.
      await seedSlotOccupant(3); // Exercise: the deliberate type change.

      await repository.saveEvent(
        profileId: profileId,
        draft: _allDayDraft().copyWith(
          title: 'Study history',
          activityTypeId: scriptureStudy.id,
          activityTypeMappingVersion: scriptureStudy.mappingVersion,
        ),
      );

      final original = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      expect(original!.activityTypeStableKey, scriptureStudy.stableKey);
      expect(original.activityTypeLabel, scriptureStudy.label);
      expect(original.activityTypeColorValue, scriptureStudy.colorValue);

      await eventTypes.renameSystemType(
        profileId: profileId,
        eventTypeId: scriptureStudy.id,
        label: 'Renamed Scripture Type',
      );
      await (database.update(
        database.activityTypes,
      )..where((table) => table.id.equals(scriptureStudy.id))).write(
        ActivityTypesCompanion(
          colorValue: const Value<int>(0xFF123456),
          updatedAtUtc: Value<DateTime>(DateTime.utc(2026, 2, 2, 12, 1)),
        ),
      );

      final afterTypeMetadataChange = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      expect(
        afterTypeMetadataChange!.activityTypeStableKey,
        scriptureStudy.stableKey,
      );
      expect(afterTypeMetadataChange.activityTypeLabel, scriptureStudy.label);
      expect(
        afterTypeMetadataChange.activityTypeColorValue,
        scriptureStudy.colorValue,
      );

      final draft = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        scope: CalendarEventEditScope.series,
        draft: draft!.copyWith(title: 'Edited study history'),
        operationId: _snapshotEditOperationId,
      );
      final afterSameTypeEdit = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      expect(afterSameTypeEdit!.activityTypeLabel, scriptureStudy.label);
      expect(
        afterSameTypeEdit.activityTypeColorValue,
        scriptureStudy.colorValue,
      );

      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        scope: CalendarEventEditScope.series,
        draft: draft.copyWith(
          title: 'Exercise history',
          activityTypeId: exercise.id,
          activityTypeMappingVersion: exercise.mappingVersion,
        ),
        operationId: _snapshotTypeChangeOperationId,
      );
      final afterTypeChange = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      expect(afterTypeChange!.activityTypeStableKey, exercise.stableKey);
      expect(afterTypeChange.activityTypeLabel, exercise.label);
      expect(afterTypeChange.activityTypeColorValue, exercise.colorValue);
    },
  );

  test('Owner fix: editing a non-recurring Event into a repeating Event '
      'persists the recurrence on the master row (no exception, next day '
      'generated)', () async {
    final repository = buildRepository();
    await repository.saveEvent(
      profileId: profileId,
      draft: const CalendarEventDraft(
        id: _eventId,
        title: 'Standalone meeting',
        timing: CalendarEventTiming.timed,
        startDate: _start,
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: false,
      ),
    );
    final existing = await repository.readEventDraft(
      profileId: profileId,
      eventId: _eventId,
    );
    expect(existing!.recurrence.isRecurring, isFalse);

    // The detail screen edits a non-recurring Event with occurrence scope.
    final outcome = await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
      scope: CalendarEventEditScope.occurrence,
      draft: existing.copyWith(
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: _operationId,
    );
    expect(outcome, CalendarEventMutationOutcome.changed);

    final master = await repository.readEventDraft(
      profileId: profileId,
      eventId: _eventId,
    );
    expect(master!.recurrence.frequency, CalendarRecurrenceFrequency.daily);
    expect(master.recurrence.isRecurring, isTrue);

    // The edited occurrence keeps its identity and the daily rule now
    // generates the next day's occurrence.
    final occurrence = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
    );
    expect(occurrence!.isRecurring, isTrue);
    final nextDay = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start.addDays(1),
    );
    expect(nextDay, isNotNull, reason: 'daily recurrence generates Feb 1');
    expect(nextDay!.startDisplay, DateTime(2026, 2, 1, 9));

    // The master row is the single owner — no exception row was written.
    final exceptions = await database
        .select(database.calendarEventExceptions)
        .get();
    expect(exceptions, isEmpty);
  });

  test('Owner fix: a Backup state set by editing a normal Event lives on the '
      'master row and survives a subsequent move/resize edit', () async {
    final repository = buildRepository();
    await repository.saveEvent(
      profileId: profileId,
      draft: const CalendarEventDraft(
        id: _eventId,
        title: 'Normal visit',
        timing: CalendarEventTiming.timed,
        startDate: _start,
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: false,
      ),
    );
    final existing = await repository.readEventDraft(
      profileId: profileId,
      eventId: _eventId,
    );

    // Step 1 — the edit form flips Backup ON (occurrence scope is what the
    // detail screen uses for a non-recurring Event).
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
      scope: CalendarEventEditScope.occurrence,
      draft: existing!.copyWith(isBackupAppointment: true),
      operationId: _operationId,
    );
    var master = await repository.readEventDraft(
      profileId: profileId,
      eventId: _eventId,
    );
    expect(
      master!.isBackupAppointment,
      isTrue,
      reason: 'Backup must persist on the master row',
    );

    // Step 2 — the timeline move/resize drafts from the master row and
    // writes occurrence scope again; Backup must survive the move.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
      scope: CalendarEventEditScope.occurrence,
      draft: master.copyWith(
        startMinute: 11 * 60,
        endMinute: 12 * 60,
        isBackupAppointment: true,
        backupForEventId: master.backupForEventId,
      ),
      operationId: _secondOperationId,
    );
    final occurrence = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
    );
    expect(
      occurrence!.isBackupAppointment,
      isTrue,
      reason: 'a moved Backup Event must stay Backup',
    );
    expect(occurrence.startDisplay, DateTime(2026, 1, 31, 11));

    master = await repository.readEventDraft(
      profileId: profileId,
      eventId: _eventId,
    );
    expect(master!.isBackupAppointment, isTrue);
    expect(master.startMinute, 11 * 60);
  });

  test(
    'Owner fix: editing a non-recurring Event removes a stale scheduled '
    'override exception so the fresh master state is authoritative',
    () async {
      final repository = buildRepository();
      await repository.saveEvent(
        profileId: profileId,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Legacy event',
          timing: CalendarEventTiming.timed,
          startDate: _start,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
        ),
      );
      // Seed the pre-fix state: an old scheduled field-override exception
      // (e.g. a time change written by the previous build).
      final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: _eventId,
        originalDate: _start,
      );
      await database
          .into(database.calendarEventExceptions)
          .insert(
            CalendarEventExceptionsCompanion.insert(
              id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              profileId: profileId,
              eventId: _eventId,
              occurrenceId: occurrenceId,
              originalDate: _start.iso8601,
              effectiveDate: _start.iso8601,
              title: 'Legacy event',
              timing: CalendarEventTiming.timed.name,
              startMinute: const Value<int?>(7 * 60),
              endMinute: const Value<int?>(8 * 60),
              requiresReport: const Value<bool>(false),
              isBackupAppointment: const Value<bool>(false),
              status: CalendarEventStatus.scheduled.name,
              createdAtUtc: DateTime.utc(2026, 2, 1),
            ),
          );

      final existing = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
        scope: CalendarEventEditScope.occurrence,
        draft: existing!.copyWith(startMinute: 14 * 60, endMinute: 15 * 60),
        operationId: _operationId,
      );

      final occurrence = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      expect(
        occurrence!.startDisplay,
        DateTime(2026, 1, 31, 14),
        reason: 'the master edit must win over the stale override',
      );
      final exceptions = await database
          .select(database.calendarEventExceptions)
          .get();
      expect(exceptions, isEmpty);
    },
  );

  test('Delta 4 A2: a moved non-recurring Event reloads from its new canonical '
      'time and cannot snap back after repository reconstruction', () async {
    final repository = buildRepository();
    await repository.saveEvent(
      profileId: profileId,
      draft: const CalendarEventDraft(
        id: _eventId,
        title: 'Persistent move',
        timing: CalendarEventTiming.timed,
        startDate: _start,
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: false,
      ),
    );
    final original = await repository.readEventDraft(
      profileId: profileId,
      eventId: _eventId,
    );
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
      scope: CalendarEventEditScope.occurrence,
      draft: original!.copyWith(
        startMinute: 13 * 60 + 15,
        endMinute: 14 * 60 + 15,
      ),
      operationId: _operationId,
    );

    final reconstructedRepository = buildRepository();
    final reloaded = await reconstructedRepository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _start,
    );
    final master = await reconstructedRepository.readEventDraft(
      profileId: profileId,
      eventId: _eventId,
    );
    expect(reloaded!.startDisplay, DateTime(2026, 1, 31, 13, 15));
    expect(reloaded.endDisplay, DateTime(2026, 1, 31, 14, 15));
    expect(master!.startMinute, 13 * 60 + 15);
    expect(master.endMinute, 14 * 60 + 15);
    expect(
      await database.select(database.calendarEventExceptions).get(),
      isEmpty,
      reason: 'a single Event has one canonical schedule owner',
    );
  });

  test(
    'Delta 4 A4: Daily to Does not repeat clears canonical recurrence, '
    'removes unreported future overrides, and retains reported history',
    () async {
      final historicalOccurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: _eventId,
        originalDate: _start,
      );
      final reports = _MemoryReportSource(<CalendarEventReportSnapshot>[
        CalendarEventReportSnapshot(
          occurrenceId: historicalOccurrenceId,
          originalDate: _start,
          status: CalendarEventStatus.completedHappened,
        ),
      ]);
      final repository = buildRepository(reportSource: reports);
      await repository.saveEvent(
        profileId: profileId,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Daily series',
          timing: CalendarEventTiming.timed,
          startDate: _start,
          startMinute: 8 * 60,
          endMinute: 9 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: true,
          recurrence: CalendarRecurrenceRule(
            frequency: CalendarRecurrenceFrequency.daily,
          ),
        ),
      );
      const future = PlannerDate(year: 2026, month: 2, day: 2);
      final recurringDraft = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: future,
        scope: CalendarEventEditScope.occurrence,
        draft: recurringDraft!.copyWith(
          startDate: future,
          startMinute: 12 * 60,
          endMinute: 13 * 60,
          recurrence: const CalendarRecurrenceRule(
            frequency: CalendarRecurrenceFrequency.daily,
          ),
        ),
        operationId: _operationId,
      );
      expect(
        await database.select(database.calendarEventExceptions).get(),
        isNotEmpty,
        reason: 'the fixture must contain an unreported future override',
      );
      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: future,
        scope: CalendarEventEditScope.occurrence,
        draft: recurringDraft.copyWith(
          recurrence: const CalendarRecurrenceRule(),
        ),
        operationId: _secondOperationId,
      );

      final master = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      final reconstructedRepository = buildRepository(reportSource: reports);
      final afterRestart = await reconstructedRepository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      final nextDay = await reconstructedRepository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: future.addDays(1),
      );
      final historical = await reconstructedRepository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _start,
      );
      final exceptions = await database
          .select(database.calendarEventExceptions)
          .get();
      final rows = await database.select(database.calendarEvents).get();

      expect(master!.recurrence.isRecurring, isFalse);
      expect(afterRestart!.recurrence.isRecurring, isFalse);
      expect(nextDay, isNull);
      expect(historical!.status, CalendarEventStatus.completedHappened);
      expect(rows, hasLength(1));
      expect(rows.single.id, _eventId);
      expect(
        exceptions.map((exception) => exception.occurrenceId),
        everyElement(historicalOccurrenceId),
        reason: 'only an exception tied to retained report history may remain',
      );
      expect(
        exceptions.any(
          (exception) =>
              exception.originalDate == future.iso8601 ||
              exception.effectiveDate == future.iso8601,
        ),
        isFalse,
      );
    },
  );

  test('Delta 4.1 D4.1-01 CASE A: an All events move translates a previously '
      'overridden occurrence by the same delta, preserving its offset and '
      'identity across restart', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    const aug10 = PlannerDate(year: 2026, month: 8, day: 10);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Daily 3 PM series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 15 * 60,
      endMinute: 16 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);

    // Step 1: move Aug 9 "This event only" from 3 PM to 4 PM.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.occurrence,
      draft: masterDraft.copyWith(
        startDate: aug9,
        startMinute: 16 * 60,
        endMinute: 17 * 60,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: Uuid().v4(),
    );
    final beforeMove = await repository.readDay(
      profileId: profileId,
      date: aug9,
    );
    expect(beforeMove.single.startLocal, DateTime(2026, 8, 9, 16));

    // Step 2: move the whole series "All events" +30 minutes.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 15 * 60 + 30,
        endMinute: 16 * 60 + 30,
      ),
      operationId: Uuid().v4(),
    );

    final aug8Day = await repository.readDay(profileId: profileId, date: aug8);
    final aug9Day = await repository.readDay(profileId: profileId, date: aug9);
    final aug10Day = await repository.readDay(
      profileId: profileId,
      date: aug10,
    );
    expect(aug8Day.single.startLocal, DateTime(2026, 8, 8, 15, 30));
    expect(aug10Day.single.startLocal, DateTime(2026, 8, 10, 15, 30));
    expect(
      aug9Day.single.startLocal,
      DateTime(2026, 8, 9, 16, 30),
      reason: 'the override must shift with the series, keeping +60 min',
    );

    // The exception survives as an override: same series, same occurrence
    // identity, same original date, no duplicate Event rows.
    final exceptions = await database
        .select(database.calendarEventExceptions)
        .get();
    expect(exceptions, hasLength(1));
    expect(exceptions.single.status, CalendarEventStatus.scheduled.name);
    expect(exceptions.single.eventId, _eventId);
    expect(exceptions.single.originalDate, aug9.iso8601);
    expect(
      exceptions.single.occurrenceId,
      CalendarEventOccurrenceIdentity.forDate(
        eventId: _eventId,
        originalDate: aug9,
      ),
    );
    expect(exceptions.single.startMinute, 16 * 60 + 30);
    expect(exceptions.single.endMinute, 17 * 60 + 30);
    expect(await database.select(database.calendarEvents).get(), hasLength(1));

    // Restart: a fresh repository over the same database still sees it.
    final restarted = buildRepository();
    final afterRestart = await restarted.readDay(
      profileId: profileId,
      date: aug9,
    );
    expect(afterRestart.single.startLocal, DateTime(2026, 8, 9, 16, 30));
  });

  test('Delta 4.1 D4.1-01 CASE B: a negative-offset earlier override also '
      'rebases correctly', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Daily 3 PM series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 15 * 60,
      endMinute: 16 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);

    // Override Aug 9 earlier: 3 PM -> 2 PM (-60 minutes).
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.occurrence,
      draft: masterDraft.copyWith(
        startDate: aug9,
        startMinute: 14 * 60,
        endMinute: 15 * 60,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: Uuid().v4(),
    );
    // Series move +30 minutes.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 15 * 60 + 30,
        endMinute: 16 * 60 + 30,
      ),
      operationId: Uuid().v4(),
    );
    final aug9Day = await repository.readDay(profileId: profileId, date: aug9);
    expect(aug9Day.single.startLocal, DateTime(2026, 8, 9, 14, 30));
    final exceptions = await database
        .select(database.calendarEventExceptions)
        .get();
    expect(exceptions.single.startMinute, 14 * 60 + 30);
  });

  test('Delta 4.1 D4.1-01 CASE C: a custom-duration override translates both '
      'endpoints by the same delta and keeps its duration', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Daily 3 PM series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 15 * 60,
      endMinute: 16 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    // Override Aug 9 to a 90-minute span (3 PM -> 4:30 PM).
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.occurrence,
      draft: masterDraft.copyWith(
        startDate: aug9,
        startMinute: 15 * 60,
        endMinute: 16 * 60 + 30,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: Uuid().v4(),
    );
    // Series move +15 minutes.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 15 * 60 + 15,
        endMinute: 16 * 60 + 15,
      ),
      operationId: Uuid().v4(),
    );
    final aug9Day = await repository.readDay(profileId: profileId, date: aug9);
    expect(aug9Day.single.startLocal, DateTime(2026, 8, 9, 15, 15));
    expect(aug9Day.single.endLocal, DateTime(2026, 8, 9, 16, 45));
    expect(
      aug9Day.single.endLocal!.difference(aug9Day.single.startLocal!).inMinutes,
      90,
      reason: 'custom override duration must survive the series rebase',
    );
  });

  test('Delta 4.1 D4.1-01 CASES D+E: multiple overrides shift and an excluded '
      'occurrence stays excluded', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    const aug10 = PlannerDate(year: 2026, month: 8, day: 10);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Daily 3 PM series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 15 * 60,
      endMinute: 16 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    // Two time overrides: Aug 9 -> 4 PM, Aug 10 -> 5 PM.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.occurrence,
      draft: masterDraft.copyWith(
        startDate: aug9,
        startMinute: 16 * 60,
        endMinute: 17 * 60,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: Uuid().v4(),
    );
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug10,
      scope: CalendarEventEditScope.occurrence,
      draft: masterDraft.copyWith(
        startDate: aug10,
        startMinute: 17 * 60,
        endMinute: 18 * 60,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: Uuid().v4(),
    );
    // Exclude Aug 8 entirely (cancelled lifecycle row).
    await repository.cancelEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug8,
      scope: CalendarEventEditScope.occurrence,
      operationId: Uuid().v4(),
    );
    // Series move +30 minutes.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 15 * 60 + 30,
        endMinute: 16 * 60 + 30,
      ),
      operationId: Uuid().v4(),
    );

    final aug9Day = await repository.readDay(profileId: profileId, date: aug9);
    final aug10Day = await repository.readDay(
      profileId: profileId,
      date: aug10,
    );
    expect(aug9Day.single.startLocal, DateTime(2026, 8, 9, 16, 30));
    expect(aug10Day.single.startLocal, DateTime(2026, 8, 10, 17, 30));
    final excluded = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug8,
    );
    expect(
      excluded!.status,
      CalendarEventStatus.cancelled,
      reason: 'the excluded occurrence must remain excluded after the move',
    );
    final exceptions = await database
        .select(database.calendarEventExceptions)
        .get();
    expect(exceptions, hasLength(3));
    final scheduled =
        exceptions
            .where((exception) => exception.status == 'scheduled')
            .toList()
          ..sort(
            (left, right) => left.originalDate.compareTo(right.originalDate),
          );
    expect(scheduled, hasLength(2));
    expect(scheduled[0].startMinute, 16 * 60 + 30);
    expect(scheduled[1].startMinute, 17 * 60 + 30);
    final cancelled = exceptions.singleWhere(
      (exception) => exception.status == 'cancelled',
    );
    expect(cancelled.originalDate, aug8.iso8601);
  });

  // ---------------------------------------------------------------------
  // Delta 4.2R3 R3-07: recurring resize "All events" must keep the resized
  // range on the series master (owner-confirmed FAIL: after choosing All
  // events the series reverted to its original duration/position).
  // ---------------------------------------------------------------------

  test('Delta 4.2R3 R3-07-01: recurring END shrink + All events keeps the '
      'resized series range across restart', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    const aug10 = PlannerDate(year: 2026, month: 8, day: 10);
    // Owner scenario: master 12:00 AM-5:30 AM daily series.
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Owner series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 0,
      endMinute: 5 * 60 + 30,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);

    // Resize the END handle from 5:30 AM down to 2:00 AM, then choose
    // "All events" (series scope). The series draft carries the new range.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 0,
        endMinute: 2 * 60,
      ),
      operationId: Uuid().v4(),
    );

    for (final date in <PlannerDate>[aug8, aug9, aug10]) {
      final day = await repository.readDay(profileId: profileId, date: date);
      expect(day, hasLength(1), reason: 'no duplicates on $date');
      expect(day.single.startLocal, DateTime(date.year, date.month, date.day));
      expect(
        day.single.endLocal,
        DateTime(date.year, date.month, date.day, 2),
        reason: 'All events shrink must persist on $date',
      );
    }
    final rows = await database.select(database.calendarEvents).get();
    expect(rows, hasLength(1));
    expect(rows.single.startMinute, 0);
    expect(rows.single.endMinute, 2 * 60);

    // Restart: a fresh repository over the same database still sees the
    // resized range (owner checklist item 9).
    final restarted = buildRepository();
    final afterRestart = await restarted.readDay(
      profileId: profileId,
      date: aug10,
    );
    expect(afterRestart.single.startLocal, DateTime(2026, 8, 10));
    expect(afterRestart.single.endLocal, DateTime(2026, 8, 10, 2));
  });

  test('Delta 4.2R3 R3-07-02: recurring END expand + All events keeps the '
      'resized series range', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Expand series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 9 * 60,
      endMinute: 10 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 9 * 60,
        endMinute: 12 * 60,
      ),
      operationId: Uuid().v4(),
    );
    final day = await repository.readDay(profileId: profileId, date: aug9);
    expect(day.single.startLocal, DateTime(2026, 8, 9, 9));
    expect(day.single.endLocal, DateTime(2026, 8, 9, 12));
  });

  test('Delta 4.2R3 R3-07-03: recurring START move + All events keeps the '
      'resized series range', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Start move series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 9 * 60,
      endMinute: 10 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    // START resize 9 AM -> 8 AM (same duration kept).
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 8 * 60,
        endMinute: 9 * 60,
      ),
      operationId: Uuid().v4(),
    );
    final day = await repository.readDay(profileId: profileId, date: aug9);
    expect(day.single.startLocal, DateTime(2026, 8, 9, 8));
    expect(day.single.endLocal, DateTime(2026, 8, 9, 9));
  });

  test('Delta 4.2R3 R3-07-04: recurring START+END range change + All events '
      'keeps the resized series range', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Range change series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 9 * 60,
      endMinute: 11 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    // START 9->10 AM and END 11 AM->2 PM (new range 10 AM-2 PM).
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 10 * 60,
        endMinute: 14 * 60,
      ),
      operationId: Uuid().v4(),
    );
    final day = await repository.readDay(profileId: profileId, date: aug9);
    expect(day.single.startLocal, DateTime(2026, 8, 9, 10));
    expect(day.single.endLocal, DateTime(2026, 8, 9, 14));
  });

  test('Delta 4.2R3 R3-07-05: This event only resize stays an attached '
      'occurrence exception with no duplicate series', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Occurrence resize series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 9 * 60,
      endMinute: 10 * 60,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.occurrence,
      draft: masterDraft.copyWith(
        startDate: aug9,
        startMinute: 9 * 60,
        endMinute: 12 * 60,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: Uuid().v4(),
    );
    final aug9Day = await repository.readDay(profileId: profileId, date: aug9);
    expect(aug9Day.single.startLocal, DateTime(2026, 8, 9, 9));
    expect(aug9Day.single.endLocal, DateTime(2026, 8, 9, 12));
    // Other dates keep the master range.
    final aug10Day = await repository.readDay(
      profileId: profileId,
      date: const PlannerDate(year: 2026, month: 8, day: 10),
    );
    expect(aug10Day.single.endLocal, DateTime(2026, 8, 10, 10));
    final exceptions = await database
        .select(database.calendarEventExceptions)
        .get();
    expect(exceptions, hasLength(1));
    expect(exceptions.single.eventId, _eventId);
    expect(exceptions.single.originalDate, aug9.iso8601);
    expect(exceptions.single.status, CalendarEventStatus.scheduled.name);
    final rows = await database.select(database.calendarEvents).get();
    expect(rows, hasLength(1), reason: 'no duplicate series/occurrences');
  });

  test('Delta 4.2R3 R3-07-06: positive-time occurrence override survives a '
      'series range resize', () async {
    final repository = buildRepository();
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Override series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 0,
      endMinute: 5 * 60 + 30,
      timeZoneId: 'Asia/Manila',
      requiresReport: false,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    // Override Aug 9 to +60 minutes (1 AM-6:30 AM).
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.occurrence,
      draft: masterDraft.copyWith(
        startDate: aug9,
        startMinute: 60,
        endMinute: 6 * 60 + 30,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      ),
      operationId: Uuid().v4(),
    );
    // Series END shrink to 2 AM (master 12 AM-2 AM), same START.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug8,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 0,
        endMinute: 2 * 60,
      ),
      operationId: Uuid().v4(),
    );
    final aug8Day = await repository.readDay(profileId: profileId, date: aug8);
    expect(aug8Day.single.startLocal, DateTime(2026, 8, 8));
    expect(aug8Day.single.endLocal, DateTime(2026, 8, 8, 2));
    // A series resize with an unchanged START (delta = 0) is not a
    // translation, so the existing locked rebase rule (shift scheduled
    // time overrides by the SAME delta) leaves the override's absolute
    // times untouched. The override keeps its identity, status and
    // absolute range; its relative offset survives.
    final aug9Day = await repository.readDay(profileId: profileId, date: aug9);
    expect(aug9Day.single.startLocal, DateTime(2026, 8, 9, 1));
    expect(
      aug9Day.single.endLocal,
      DateTime(2026, 8, 9, 6, 30),
      reason: 'delta=0 series resize leaves the scheduled override absolute '
          'times intact per the locked translation-only rebase rule',
    );
  });

  test('Delta 4.2R3 R3-07-07: reported historical occurrence stays preserved '
      'after an All events resize', () async {
    const aug8 = PlannerDate(year: 2026, month: 8, day: 8);
    const aug9 = PlannerDate(year: 2026, month: 8, day: 9);
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: _eventId,
      originalDate: aug8,
    );
    final reportSource = _MemoryReportSource(<CalendarEventReportSnapshot>[
      CalendarEventReportSnapshot(
        occurrenceId: occurrenceId,
        originalDate: aug8,
        status: CalendarEventStatus.completedHappened,
      ),
    ]);
    final repository = buildRepository(reportSource: reportSource);
    final masterDraft = CalendarEventDraft(
      id: _eventId,
      title: 'Reported series',
      timing: CalendarEventTiming.timed,
      startDate: aug8,
      startMinute: 0,
      endMinute: 5 * 60 + 30,
      timeZoneId: 'Asia/Manila',
      requiresReport: true,
      recurrence: const CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.daily,
      ),
    );
    await repository.saveEvent(profileId: profileId, draft: masterDraft);
    final before = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug8,
    );
    expect(before!.status, CalendarEventStatus.completedHappened);
    // Series END shrink to 2 AM.
    await repository.editEvent(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug9,
      scope: CalendarEventEditScope.series,
      draft: masterDraft.copyWith(
        startMinute: 0,
        endMinute: 2 * 60,
      ),
      operationId: Uuid().v4(),
    );
    final reportedAgain = await repository.readOccurrence(
      profileId: profileId,
      eventId: _eventId,
      originalDate: aug8,
    );
    expect(
      reportedAgain!.status,
      CalendarEventStatus.completedHappened,
      reason: 'historical report must survive the series resize',
    );
  });

  test(
    'Delta 4.2F: custom repeat persists additively and legacy repeat stays null',
    () async {
      final repository = buildRepository();
      const start = PlannerDate(year: 2026, month: 8, day: 9);
      const rule = CalendarRecurrenceRule(
        frequency: CalendarRecurrenceFrequency.weekly,
        endMode: CalendarRecurrenceEndMode.onDate,
        endDate: PlannerDate(year: 2026, month: 11, day: 9),
        pattern: CalendarRecurrencePattern(
          weeklyWeekdays: <int>{DateTime.sunday, DateTime.tuesday},
        ),
      );
      await repository.saveEvent(
        profileId: profileId,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Sunday and Tuesday visit',
          timing: CalendarEventTiming.timed,
          startDate: start,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          recurrence: rule,
        ),
      );

      final row = await database.select(database.calendarEvents).getSingle();
      expect(row.recurrenceFrequency, CalendarRecurrenceFrequency.weekly.name);
      expect(row.recurrenceEndMode, CalendarRecurrenceEndMode.onDate.name);
      expect(row.recurrenceEndDate, '2026-11-09');
      expect(row.recurrencePatternJson, isNotNull);
      expect(
        calendarRecurrencePatternFromJson(row.recurrencePatternJson),
        rule.pattern,
      );

      final reloaded = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      expect(reloaded!.recurrence.pattern, rule.pattern);
      expect(
        await repository.readDay(
          profileId: profileId,
          date: const PlannerDate(year: 2026, month: 8, day: 10),
        ),
        isEmpty,
      );
      expect(
        await repository.readDay(
          profileId: profileId,
          date: const PlannerDate(year: 2026, month: 8, day: 11),
        ),
        hasLength(1),
      );

      await repository.saveEvent(
        profileId: profileId,
        draft: _allDayDraft().copyWith(id: _replacementId),
      );
      final legacyRow = await (database.select(
        database.calendarEvents,
      )..where((table) => table.id.equals(_replacementId))).getSingle();
      expect(legacyRow.recurrenceFrequency, 'monthly');
      expect(legacyRow.recurrencePatternJson, isNull);
    },
  );

  test(
    'Delta 4.2E: a non-recurring cross-date edit and inverse edit retain '
    'one stable Event row and restore the original occurrence identity',
    () async {
      final repository = buildRepository();
      const source = PlannerDate(year: 2026, month: 7, day: 27);
      const target = PlannerDate(year: 2026, month: 7, day: 28);
      const sourceDraft = CalendarEventDraft(
        id: _eventId,
        title: 'Stable cross-date Event',
        timing: CalendarEventTiming.timed,
        startDate: source,
        startMinute: 9 * 60,
        endMinute: 11 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: false,
      );
      await repository.saveEvent(profileId: profileId, draft: sourceDraft);

      final moved = await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: source,
        scope: CalendarEventEditScope.occurrence,
        draft: sourceDraft.copyWith(
          startDate: target,
          startMinute: 9 * 60 + 30,
          endMinute: 11 * 60 + 30,
        ),
        operationId: _operationId,
      );
      expect(moved, CalendarEventMutationOutcome.changed);
      var rows = await database.select(database.calendarEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, _eventId);
      expect(rows.single.startDate, target.iso8601);
      expect(
        await repository.readDay(profileId: profileId, date: source),
        isEmpty,
      );
      final targetDay = await repository.readDay(
        profileId: profileId,
        date: target,
      );
      expect(targetDay, hasLength(1));
      expect(targetDay.single.eventId, _eventId);

      final undone = await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: target,
        scope: CalendarEventEditScope.occurrence,
        draft: sourceDraft,
        operationId: _secondOperationId,
      );
      expect(undone, CalendarEventMutationOutcome.changed);
      rows = await database.select(database.calendarEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, _eventId);
      expect(rows.single.startDate, source.iso8601);
      final restoredDay = await repository.readDay(
        profileId: profileId,
        date: source,
      );
      expect(restoredDay, hasLength(1));
      expect(
        restoredDay.single.id,
        CalendarEventOccurrenceIdentity.forDate(
          eventId: _eventId,
          originalDate: source,
        ),
      );
      expect(
        await repository.readDay(profileId: profileId, date: target),
        isEmpty,
      );
      expect(
        await database.select(database.calendarEventOperations).get(),
        hasLength(2),
      );
    },
  );
}

CalendarEventDraft _allDayDraft({String title = 'Month-end visit'}) {
  return CalendarEventDraft(
    id: _eventId,
    title: title,
    timing: CalendarEventTiming.allDay,
    startDate: _start,
    locationText: 'Typed local location',
    requiresReport: true,
    recurrence: const CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.monthly,
    ),
  );
}

final class _MemoryReportSource implements CalendarEventReportSource {
  const _MemoryReportSource(this.reports);

  final List<CalendarEventReportSnapshot> reports;

  @override
  Future<List<CalendarEventReportSnapshot>> readSeriesReports(
    String eventId,
  ) async {
    return eventId == _eventId
        ? reports
        : const <CalendarEventReportSnapshot>[];
  }
}

final class _TaskLinks implements CalendarEventTaskContextSource {
  const _TaskLinks(this.ids);

  final List<String> ids;

  @override
  Future<List<String>> readLinkedTaskIds({
    required String eventId,
    required String occurrenceId,
  }) async => ids;
}

final class _FailingWriteGuard implements CalendarEventWriteGuard {
  const _FailingWriteGuard();

  @override
  Future<void> beforeCommit() async {
    throw StateError('Injected Calendar Event write failure');
  }
}
