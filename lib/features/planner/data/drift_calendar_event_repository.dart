import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/goals/data/live_goal_event_type_bindings.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal_event_type_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/planner_presentation_document_store.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/event_type_presentation.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:uuid/uuid.dart';

abstract interface class CalendarEventWriteGuard {
  Future<void> beforeCommit();
}

/// Contract E explicit write context (private seam). New-selection writes
/// (new Event, duplicate, deliberate type change) validate eligibility and
/// capture the live Goal-title alias; preservation writes (same-type edits,
/// reschedule, cancel, report preservation) never gate and never re-alias.
enum _CalendarEventSelectionContext { newSelection, preservation }

final class AllowCalendarEventWrites implements CalendarEventWriteGuard {
  const AllowCalendarEventWrites();

  @override
  Future<void> beforeCommit() async {}
}

final class _ActivityTypeSnapshot {
  const _ActivityTypeSnapshot({this.stableKey, this.label, this.colorValue});

  final String? stableKey;
  final String? label;
  final int? colorValue;
}

final class DriftCalendarEventRepository
    implements
        CalendarEventRepository,
        CalendarEventRangeSource,
        CalendarEventScopedRangeSource,
        CalendarEventAwaitingReportSource,
        CalendarEventOccurrenceIdLookup {
  const DriftCalendarEventRepository({
    required this.database,
    required this.clock,
    required this.timeZones,
    this.reportSource = const EmptyCalendarEventReportSource(),
    this.taskContextSource = const EmptyCalendarEventTaskContextSource(),
    this.linkContextTransfer = const EmptyCalendarEventLinkContextTransfer(),
    this.duplicateContextTransfer =
        const EmptyCalendarEventDuplicateContextTransfer(),
    this.writeGuard = const AllowCalendarEventWrites(),
    this.reminderRepair,
  });

  final AppDatabase database;
  final AppClock clock;
  final IanaCalendarEventTimeZones timeZones;
  final CalendarEventReportSource reportSource;
  final CalendarEventTaskContextSource taskContextSource;
  final CalendarEventLinkContextTransfer linkContextTransfer;
  final CalendarEventDuplicateContextTransfer duplicateContextTransfer;
  final CalendarEventWriteGuard writeGuard;

  /// M7 section 27 repair-intent port.  Every Event mutation below can change a
  /// reminder's timing, eligibility or live link, so the intent to reconcile
  /// commits INSIDE the mutation's own transaction.  Absent in read-only and
  /// test compositions.
  final ReminderRecoveryRequest? reminderRepair;

  /// Safety bound for the UNREPORTED backlog expansion, NOT a product
  /// retention window: an occurrence whose series start is older than this is
  /// only ever reached when the stored start date itself is corrupt or absurd
  /// (a real beta backlog never approaches five years).
  static const int awaitingReportBacklogMaxDays = 1830;

  @override
  String get displayTimeZoneId => timeZones.displayTimeZoneId;

  @override
  bool isValidTimeZone(String timeZoneId) => timeZones.isValid(timeZoneId);

  @override
  Future<List<PlannerCalendarItem>> readDay({
    required String profileId,
    required PlannerDate date,
  }) => readRange(profileId: profileId, startDate: date, endDate: date);

  @override
  Future<List<PlannerCalendarItem>> readRange({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) => _readRangeInternal(
    profileId: profileId,
    startDate: startDate,
    endDate: endDate,
    eventIds: null,
  );

  /// M3 P01 — source-scoped canonical projection.  The SQL source rows are
  /// constrained by profile + requested Event IDs BEFORE batching and
  /// per-date expansion; everything downstream (reports, exceptions, Task
  /// context, `_buildOccurrence`, ordering, dedup) is byte-for-byte the
  /// shared unscoped path.  A null ID set behaves exactly like [readRange];
  /// an EMPTY ID set returns an empty projection without touching the
  /// Events table.
  @override
  Future<List<PlannerCalendarItem>> readRangeForEvents({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
    required Set<String>? eventIds,
  }) {
    if (eventIds != null && eventIds.isEmpty) {
      return Future.value(const <PlannerCalendarItem>[]);
    }
    return _readRangeInternal(
      profileId: profileId,
      startDate: startDate,
      endDate: endDate,
      eventIds: eventIds,
    );
  }

  /// Owner law (2026-09-19): the UNREPORTED backlog is the canonical set of
  /// unresolved report-required occurrences with NO recent-only window, so an
  /// older unresolved occurrence remains findable.  Candidate rows are
  /// pre-filtered by `requires_report` (row OR any occurrence exception), so
  /// expansion cost stays proportional to the Events that can actually be
  /// unreported rather than to the whole Event universe.
  ///
  /// The projection is byte-for-byte the shared occurrence path
  /// ([_buildOccurrence] + [_toPlannerItem]); only the window and the elapsed
  /// filter are decided here, and the filter is exactly the canonical
  /// awaiting-report rule (scheduled + requires report + elapsed, where a
  /// submitted report already overlays the occurrence status).
  @override
  Future<List<AwaitingReportEvent>> readAwaitingReportEvents({
    required String profileId,
    required PlannerDate today,
    required DateTime nowUtc,
  }) async {
    final rows =
        await (database.select(database.calendarEvents)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(CalendarEvents)>[
                (table) => OrderingTerm.asc(table.createdAtUtc),
              ]))
            .get();
    if (rows.isEmpty) {
      return const <AwaitingReportEvent>[];
    }
    final reportBatchSource = reportSource is CalendarEventReportBatchSource
        ? reportSource as CalendarEventReportBatchSource
        : null;
    final reportsByEvent = reportBatchSource == null
        ? null
        : await reportBatchSource.readSeriesReportsForEvents(
            rows.map((row) => row.id),
          );
    final exceptionsByEvent = await _latestExceptionsForEvents(
      rows.map((row) => row.id),
    );
    final entries = <AwaitingReportEvent>[];
    for (final row in rows) {
      final exceptions =
          exceptionsByEvent[row.id] ??
          const <String, CalendarEventExceptionRow>{};
      final rowRequiresReport =
          row.requiresReport ||
          exceptions.values.any((exception) => exception.requiresReport);
      if (!rowRequiresReport) {
        continue;
      }
      final reports = reportsByEvent == null
          ? await reportSource.readSeriesReports(row.id)
          : reportsByEvent[row.id] ?? const <CalendarEventReportSnapshot>[];
      final reportById = <String, CalendarEventReportSnapshot>{
        for (final report in reports) report.occurrenceId: report,
      };
      final rule = _ruleFromRow(row);
      final start = PlannerDate.parse(row.startDate);
      final floor = today.addDays(-awaitingReportBacklogMaxDays);
      final first = start.compareTo(floor) < 0 ? floor : start;
      // A timed occurrence's END can land on the day after its original date
      // in another display time zone, so the expansion reaches one day past
      // today; the elapsed filter still decides membership.
      final last = today.addDays(1);
      for (
        var originalDate = first;
        originalDate.compareTo(last) <= 0;
        originalDate = originalDate.addDays(1)
      ) {
        final exception =
            exceptions[CalendarEventOccurrenceIdentity.forDate(
              eventId: row.id,
              originalDate: originalDate,
            )];
        if (rule.occurrenceIndexOn(
                  startDate: start,
                  targetDate: originalDate,
                ) ==
                null &&
            exception == null) {
          continue;
        }
        final occurrence = await _buildOccurrence(
          row: row,
          originalDate: originalDate,
          exception: exception,
          reportById: reportById,
        );
        if (occurrence == null ||
            occurrence.status != CalendarEventStatus.scheduled ||
            !occurrence.requiresReport) {
          continue;
        }
        final elapsed = occurrence.timing == CalendarEventTiming.allDay
            ? occurrence.displayDate.compareTo(today) < 0
            : occurrence.endUtc != null && occurrence.endUtc!.isBefore(nowUtc);
        if (!elapsed) {
          continue;
        }
        entries.add(
          AwaitingReportEvent(
            item: _toPlannerItem(occurrence),
            goalId: row.goalId,
            activityTypeStableKey: occurrence.activityTypeStableKey,
            // The occurrence-effective Contact Type, so the Unreported >
            // Contacts marker can draw the Event's own contact visual. A legacy
            // NULL stays null here and presents as In Person; nothing writes.
            contactChannel: occurrence.contactChannel,
          ),
        );
      }
    }
    entries.sort((left, right) {
      final byDate = left.item.date.compareTo(right.item.date);
      if (byDate != 0) return byDate;
      final leftStart = left.item.startLocal;
      final rightStart = right.item.startLocal;
      if (leftStart != null && rightStart != null) {
        final byStart = leftStart.compareTo(rightStart);
        if (byStart != 0) return byStart;
      } else if (leftStart != null) {
        return -1;
      } else if (rightStart != null) {
        return 1;
      }
      return left.item.id.compareTo(right.item.id);
    });
    return List<AwaitingReportEvent>.unmodifiable(entries);
  }

  Future<List<PlannerCalendarItem>> _readRangeInternal({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
    required Set<String>? eventIds,
  }) async {
    if (endDate.compareTo(startDate) < 0) {
      throw ArgumentError.value(
        endDate,
        'endDate',
        'must not precede startDate',
      );
    }
    final rows =
        await (database.select(database.calendarEvents)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    (eventIds == null
                        ? const Constant<bool>(true)
                        : table.id.isIn(eventIds)),
              )
              ..orderBy(<OrderingTerm Function(CalendarEvents)>[
                (table) => OrderingTerm.asc(table.createdAtUtc),
              ]))
            .get();
    // S1A: the per-row reads below (reports, exceptions, Task links) are
    // hoisted into bounded set-based batches for production Drift sources.
    // Each per-Event lookup then becomes a map access with identical
    // semantics; non-batch-capable test doubles keep the legacy per-Event
    // read path untouched.
    final reportBatchSource = reportSource is CalendarEventReportBatchSource
        ? reportSource as CalendarEventReportBatchSource
        : null;
    final reportsByEvent = reportBatchSource == null
        ? null
        : await reportBatchSource.readSeriesReportsForEvents(
            rows.map((row) => row.id),
          );
    final exceptionsByEvent = await _latestExceptionsForEvents(
      rows.map((row) => row.id),
    );
    final taskContextBatchSource =
        taskContextSource is CalendarEventTaskContextBatchSource
        ? taskContextSource as CalendarEventTaskContextBatchSource
        : null;
    final taskContextSnapshot = taskContextBatchSource == null
        ? null
        : await taskContextBatchSource.readTaskContextSnapshot(
            rows.map((row) => row.id),
          );
    final itemsById = <String, PlannerCalendarItem>{};
    for (final row in rows) {
      final reports = reportsByEvent == null
          ? await reportSource.readSeriesReports(row.id)
          : reportsByEvent[row.id] ?? const <CalendarEventReportSnapshot>[];
      final reportById = <String, CalendarEventReportSnapshot>{
        for (final report in reports) report.occurrenceId: report,
      };
      final exceptions =
          exceptionsByEvent[row.id] ??
          const <String, CalendarEventExceptionRow>{};
      final candidateStart = row.timing == CalendarEventTiming.allDay.name
          ? startDate
          : startDate.addDays(-1);
      final candidateEnd = row.timing == CalendarEventTiming.allDay.name
          ? endDate
          : endDate.addDays(1);
      final included = <String>{};
      for (
        var originalDate = candidateStart;
        originalDate.compareTo(candidateEnd) <= 0;
        originalDate = originalDate.addDays(1)
      ) {
        final occurrence = await _buildOccurrence(
          row: row,
          originalDate: originalDate,
          exception:
              exceptions[CalendarEventOccurrenceIdentity.forDate(
                eventId: row.id,
                originalDate: originalDate,
              )],
          reportById: reportById,
          taskContextSnapshot: taskContextSnapshot,
        );
        if (occurrence == null ||
            (!_insideRange(occurrence.displayDate, startDate, endDate) &&
                !(occurrence.isChange &&
                    _insideRange(
                      occurrence.originalDate,
                      startDate,
                      endDate,
                    )))) {
          continue;
        }
        included.add(occurrence.id);
        itemsById[occurrence.id] = _toPlannerItem(occurrence);
      }
      for (final exception in exceptions.values) {
        if (included.contains(exception.occurrenceId)) {
          continue;
        }
        final originalDate = PlannerDate.parse(exception.originalDate);
        final effectiveDate = PlannerDate.parse(exception.effectiveDate);
        if (!_insideRange(originalDate, startDate, endDate) &&
            !_insideRange(effectiveDate, startDate, endDate)) {
          continue;
        }
        final occurrence = await _buildOccurrence(
          row: row,
          originalDate: originalDate,
          exception: exception,
          reportById: reportById,
          taskContextSnapshot: taskContextSnapshot,
        );
        // Planner Polish Delta 2: an occurrence-scoped MOVE writes an
        // exception whose effective date differs from its original date.
        // Such an occurrence belongs only on its effective (new) day, so it
        // must never leak onto the original date's collection.
        if (occurrence != null &&
            _insideRange(occurrence.displayDate, startDate, endDate)) {
          itemsById[occurrence.id] = _toPlannerItem(occurrence);
        }
      }
    }
    final items = itemsById.values.toList(growable: false);
    items.sort((left, right) {
      final byDate = left.date.compareTo(right.date);
      if (byDate != 0) return byDate;
      final leftTime = left.startLocal;
      final rightTime = right.startLocal;
      if (leftTime == null && rightTime != null) {
        return -1;
      }
      if (leftTime != null && rightTime == null) {
        return 1;
      }
      return (leftTime?.compareTo(rightTime!) ?? 0);
    });
    return items;
  }

  static bool _insideRange(
    PlannerDate value,
    PlannerDate startDate,
    PlannerDate endDate,
  ) => value.compareTo(startDate) >= 0 && value.compareTo(endDate) <= 0;

  @override
  Future<CalendarEventDraft?> readEventDraft({
    required String profileId,
    required String eventId,
  }) async {
    final row = await _readRow(profileId: profileId, eventId: eventId);
    return row == null ? null : _draftFromRow(row);
  }

  @override
  Future<CalendarEventOccurrence?> readOccurrence({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
  }) async {
    final row = await _readRow(profileId: profileId, eventId: eventId);
    if (row == null) {
      return null;
    }
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: originalDate,
    );
    final reports = await reportSource.readSeriesReports(eventId);
    return _buildOccurrence(
      row: row,
      originalDate: originalDate,
      exception: (await _latestExceptions(eventId))[occurrenceId],
      reportById: <String, CalendarEventReportSnapshot>{
        for (final report in reports) report.occurrenceId: report,
      },
    );
  }

  @override
  Future<CalendarEventOccurrence?> readOccurrenceById({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async {
    final row = await _readRow(profileId: profileId, eventId: eventId);
    if (row == null) return null;
    final reports = await reportSource.readSeriesReports(eventId);
    final reportById = <String, CalendarEventReportSnapshot>{
      for (final report in reports) report.occurrenceId: report,
    };
    final exceptions = await _latestExceptions(eventId);
    final exception = exceptions[occurrenceId];
    if (exception != null) {
      return _buildOccurrence(
        row: row,
        originalDate: PlannerDate.parse(exception.originalDate),
        exception: exception,
        reportById: reportById,
      );
    }
    final start = PlannerDate.parse(row.startDate);
    // M2's scheduled occurrence horizon is 90 days; routing resolves the
    // same bounded canonical projection rather than reversing UUIDv5 IDs.
    //
    // Section 64: an Event reminder's target is T = start - offset, which can
    // fall on the PREVIOUS local day (an early-morning Event with a long lead).
    // Starting the scan at today would make that occurrence unresolvable for
    // report-reminder routes, so the window opens one day earlier.  The upper
    // bound is unchanged; only the lower bound widens.
    final today = PlannerDate.fromDateTime(clock.nowUtc().toLocal());
    final scanFloor = today.addDays(-1);
    final first = start.compareTo(scanFloor) < 0 ? scanFloor : start;
    final rule = _ruleFromRow(row);
    for (var offset = 0; offset <= 91; offset++) {
      final date = first.addDays(offset);
      if (rule.occurrenceIndexOn(startDate: start, targetDate: date) == null) {
        continue;
      }
      if (CalendarEventOccurrenceIdentity.forDate(
            eventId: eventId,
            originalDate: date,
          ) !=
          occurrenceId) {
        continue;
      }
      return _buildOccurrence(
        row: row,
        originalDate: date,
        exception: null,
        reportById: reportById,
      );
    }
    return null;
  }

  @override
  Future<CalendarEventDraft> saveEvent({
    required String profileId,
    required CalendarEventDraft draft,
  }) async {
    final normalized = _validateDraft(draft);
    await database.transaction(() async {
      final existing = await _readRow(
        profileId: profileId,
        eventId: normalized.id,
      );
      // Contract E/F: a NEW Event may not select a canonical slot Event
      // Type whose slot has no live Goal occupant. The eligibility read and
      // the alias snapshot are captured once, atomically, inside the same
      // transaction that writes the row.
      final bindings = await readLiveGoalEventTypeBindings(database, profileId);
      await _validateSelectionEligibility(
        profileId: profileId,
        bindings: bindings,
        draft: normalized,
        originalTypeId: existing?.activityTypeId,
      );
      await _writeEvent(
        profileId: profileId,
        eventId: normalized.id,
        draft: normalized,
        existing: existing,
        selectionContext: _CalendarEventSelectionContext.newSelection,
        liveBindings: bindings,
      );
      // Section 27: a new/edited Event changes reminder eligibility and timing,
      // so the repair intent commits with the source write.
      await reminderRepair?.mark(database, profileId: profileId);
      await writeGuard.beforeCommit();
    });
    return normalized;
  }

  @override
  Future<CalendarEventMutationOutcome> editEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft draft,
    required String operationId,
  }) async {
    _validateOperationId(operationId);
    final normalized = _validateDraft(draft);
    final reports = await reportSource.readSeriesReports(eventId);
    // Intentionally do NOT call `_ensureOccurrenceIsEditable`
    // here: a resize gesture changes only `endMinute` and the
    // resulting occurrence exception stores status =
    // `scheduled`. `_buildOccurrence` re-applies the existing
    // report's status on top of a scheduled exception, so the
    // report remains semantically intact and the resize
    // coexists with the report row. The immutability check is
    // still enforced for the structural cancellation and
    // reschedule flows that follow below.
    return database.transaction(() async {
      if (await _operationExists(operationId)) {
        return CalendarEventMutationOutcome.unchanged;
      }
      final row = await _requireRow(profileId: profileId, eventId: eventId);
      final current = await _requireOccurrence(
        row: row,
        originalDate: originalDate,
        reports: reports,
      );
      // Contract E/F: explicit current-occurrence-vs-draft type resolution
      // at the editEvent boundary. The occurrence's stored type (exception
      // snapshot -> master snapshot -> raw master row, exactly the read
      // chain) is the reference; a differing draft type is a deliberate
      // change and must point at a live-occupied canonical slot. Same-type
      // writes are preservations and never gate, including a recurring
      // occurrence override carrying the same canonical type as its master.
      final typeChanged = normalized.activityTypeId != current.activityTypeId;
      final bindings = typeChanged
          ? await readLiveGoalEventTypeBindings(database, profileId)
          : null;
      if (typeChanged && bindings != null) {
        await _validateSelectionEligibility(
          profileId: profileId,
          bindings: bindings,
          draft: normalized,
          originalTypeId: current.activityTypeId,
        );
      }
      final selectionContext = typeChanged
          ? _CalendarEventSelectionContext.newSelection
          : _CalendarEventSelectionContext.preservation;
      final sourceRule = _ruleFromRow(row);
      // Clearing Repeat is always a series-level mutation, even if the edit
      // flow was entered through "This event only". An exception row has no
      // recurrence columns and therefore cannot truthfully stop a series.
      final resolvedScope =
          sourceRule.isRecurring && !normalized.recurrence.isRecurring
          ? CalendarEventEditScope.series
          : scope;
      if (resolvedScope != CalendarEventEditScope.occurrence) {
        await _preserveReports(
          profileId: profileId,
          row: row,
          reports: reports,
          operationId: operationId,
        );
      }
      switch (resolvedScope) {
        case CalendarEventEditScope.occurrence:
          if (!_ruleFromRow(row).isRecurring) {
            // Owner fix: editing a NON-recurring Event (the detail Edit
            // screen and the timeline move/resize gestures all use
            // occurrence scope for it) must write the master row, not an
            // exception.  The exception table has no recurrence columns, so
            // an edit that turns the Event into a repeating Event could
            // never persist, and a Backup state set through edit landed only
            // on the exception while the master stayed normal — a later
            // move/resize drafts from the master row and silently reverted
            // it.  A non-recurring Event has exactly one occurrence, so
            // occurrence scope and series scope address the same record;
            // the master row is the canonical owner of its date, schedule,
            // recurrence, and Backup identity. This also lets an atomic
            // cross-date timeline move retain the Event's stable identity.
            await _writeEvent(
              profileId: profileId,
              eventId: eventId,
              draft: normalized.copyWith(id: eventId),
              existing: row,
              selectionContext: selectionContext,
              liveBindings: bindings,
            );
            // A scheduled field-override exception written by an earlier
            // build no longer represents user intent now that the master row
            // carries the full edited state, and it would otherwise keep
            // masking the fresh master values.  Only scheduled
            // (field-override) exceptions are removed; cancelled/rescheduled
            // lifecycle rows stay untouched.
            await _clearFieldOverrideExceptions(
              eventId: eventId,
              occurrenceId: current.id,
            );
          } else {
            await _insertException(
              profileId: profileId,
              eventId: eventId,
              originalDate: originalDate,
              occurrenceId: current.id,
              draft: normalized.copyWith(
                id: eventId,
                startDate: originalDate,
                recurrence: const CalendarRecurrenceRule(),
              ),
              status: current.status,
              operationId: operationId,
              selectionContext: selectionContext,
              liveBindings: bindings,
            );
          }
        case CalendarEventEditScope.thisAndFuture:
          if (originalDate == PlannerDate.parse(row.startDate)) {
            await _writeEvent(
              profileId: profileId,
              eventId: eventId,
              draft: normalized.copyWith(id: eventId),
              existing: row,
              selectionContext: selectionContext,
              liveBindings: bindings,
            );
          } else {
            if (normalized.id == eventId) {
              throw const CalendarEventValidationException(
                'This-and-future edits require a new stable series identity.',
              );
            }
            await _truncateBefore(row, originalDate);
            await _writeEvent(
              profileId: profileId,
              eventId: normalized.id,
              draft: _draftForSplit(
                source: row,
                targetDate: originalDate,
                replacement: normalized,
              ),
              parentEventId: eventId,
              selectionContext: selectionContext,
              liveBindings: bindings,
            );
          }
        case CalendarEventEditScope.series:
          await _writeEvent(
            profileId: profileId,
            eventId: eventId,
            draft: normalized.copyWith(id: eventId),
            existing: row,
            selectionContext: selectionContext,
            liveBindings: bindings,
          );
          if (sourceRule.isRecurring && !normalized.recurrence.isRecurring) {
            await _removeUnreportedExceptions(
              eventId: eventId,
              reports: reports,
            );
          } else if (sourceRule.isRecurring &&
              row.startMinute != null &&
              normalized.startMinute != null) {
            // Delta 4.1 recurrence rebase: an "All events" move is a pure
            // translation of the whole series.  The master row above already
            // moved by the movement delta; every surviving time-based
            // occurrence override belonging to this series must move by the
            // SAME delta so each exception keeps its relative offset instead
            // of being left behind at its old absolute override time.  Only
            // scheduled (field-override) timed exceptions carrying persisted
            // times are rebased — cancelled/rescheduled lifecycle rows
            // (excluded or detached occurrences) and overrides with no time
            // component are never shifted.
            final deltaMinutes = normalized.startMinute! - row.startMinute!;
            if (deltaMinutes != 0) {
              await _rebaseSeriesTimeOverrides(
                eventId: eventId,
                deltaMinutes: deltaMinutes,
              );
            }
          }
      }
      await _insertOperation(
        operationId: operationId,
        profileId: profileId,
        eventId: eventId,
        occurrenceId: current.id,
        command: 'edit:${resolvedScope.name}',
      );
      // Section 27: this mutation can change a reminder's timing, eligibility
      // or live link, so the repair intent commits with the source write.
      await reminderRepair?.mark(database, profileId: profileId);
      await writeGuard.beforeCommit();
      return CalendarEventMutationOutcome.changed;
    });
  }

  @override
  Future<CalendarEventMutationOutcome> cancelEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required String operationId,
  }) async {
    _validateOperationId(operationId);
    final reports = await reportSource.readSeriesReports(eventId);
    return database.transaction(() async {
      if (await _operationExists(operationId)) {
        return CalendarEventMutationOutcome.unchanged;
      }
      final row = await _requireRow(profileId: profileId, eventId: eventId);
      final current = await _requireOccurrence(
        row: row,
        originalDate: originalDate,
        reports: reports,
      );
      if (scope != CalendarEventEditScope.occurrence) {
        await _preserveReports(
          profileId: profileId,
          row: row,
          reports: reports,
          operationId: operationId,
        );
      }
      switch (scope) {
        case CalendarEventEditScope.occurrence:
          await _insertExceptionFromOccurrence(
            profileId: profileId,
            occurrence: current,
            status: CalendarEventStatus.cancelled,
            operationId: operationId,
          );
        case CalendarEventEditScope.thisAndFuture:
          if (originalDate == PlannerDate.parse(row.startDate)) {
            await _setSeriesStatus(
              row: row,
              status: CalendarEventStatus.cancelled,
            );
          } else {
            await _truncateBefore(row, originalDate);
            await _insertExceptionFromOccurrence(
              profileId: profileId,
              occurrence: current,
              status: CalendarEventStatus.cancelled,
              operationId: operationId,
            );
          }
        case CalendarEventEditScope.series:
          await _setSeriesStatus(
            row: row,
            status: CalendarEventStatus.cancelled,
          );
      }
      await _insertOperation(
        operationId: operationId,
        profileId: profileId,
        eventId: eventId,
        occurrenceId: current.id,
        command: 'cancel:${scope.name}',
      );
      // Section 27: this mutation can change a reminder's timing, eligibility
      // or live link, so the repair intent commits with the source write.
      await reminderRepair?.mark(database, profileId: profileId);
      await writeGuard.beforeCommit();
      return CalendarEventMutationOutcome.changed;
    });
  }

  @override
  Future<CalendarEventMutationOutcome> rescheduleEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft replacement,
    required String operationId,
  }) async {
    _validateOperationId(operationId);
    final normalized = _validateDraft(replacement);
    if (normalized.id == eventId) {
      throw const CalendarEventValidationException(
        'Rescheduling requires a new stable replacement identity.',
      );
    }
    final reports = await reportSource.readSeriesReports(eventId);
    _ensureOccurrenceIsEditable(
      eventId: eventId,
      originalDate: originalDate,
      reports: reports,
    );
    return database.transaction(() async {
      if (await _operationExists(operationId)) {
        return CalendarEventMutationOutcome.unchanged;
      }
      final row = await _requireRow(profileId: profileId, eventId: eventId);
      final current = await _requireOccurrence(
        row: row,
        originalDate: originalDate,
        reports: reports,
      );
      // Planner Polish Delta 2: moving a repeating occurrence with "This
      // event only" must keep it attached to the original series as an
      // occurrence override — never as an unrelated standalone Event.  When
      // the source series is recurring, an occurrence-scoped reschedule
      // writes an exception row under the SAME series event id carrying the
      // new effective date and times, so the occurrence keeps its series
      // lineage, its deterministic occurrence id, and its repeat icon;
      // future and past occurrences are untouched and no replacement Event
      // row is created.  Non-recurring Events keep the replacement contract
      // (there is no series identity to preserve for a single Event).
      final sourceRule = _ruleFromRow(row);
      if (scope == CalendarEventEditScope.occurrence &&
          sourceRule.isRecurring) {
        await _insertException(
          profileId: profileId,
          eventId: eventId,
          originalDate: originalDate,
          occurrenceId: current.id,
          draft: normalized.copyWith(
            id: eventId,
            startDate: normalized.startDate,
            recurrence: const CalendarRecurrenceRule(),
          ),
          status: current.status,
          operationId: operationId,
        );
        await _insertOperation(
          operationId: operationId,
          profileId: profileId,
          eventId: eventId,
          occurrenceId: current.id,
          command: 'reschedule:occurrence',
        );
        // Section 27: same repair intent as the series reschedule.
        await reminderRepair?.mark(database, profileId: profileId);
        await writeGuard.beforeCommit();
        return CalendarEventMutationOutcome.changed;
      }
      if (scope != CalendarEventEditScope.occurrence) {
        await _preserveReports(
          profileId: profileId,
          row: row,
          reports: reports,
          operationId: operationId,
        );
      }
      final replacementDraft = scope == CalendarEventEditScope.occurrence
          ? normalized.copyWith(recurrence: const CalendarRecurrenceRule())
          : normalized;
      await _writeEvent(
        profileId: profileId,
        eventId: replacementDraft.id,
        draft: replacementDraft,
        parentEventId: eventId,
      );
      switch (scope) {
        case CalendarEventEditScope.occurrence:
          await _insertExceptionFromOccurrence(
            profileId: profileId,
            occurrence: current,
            status: CalendarEventStatus.rescheduled,
            operationId: operationId,
            replacementEventId: replacementDraft.id,
          );
        case CalendarEventEditScope.thisAndFuture:
          if (originalDate == PlannerDate.parse(row.startDate)) {
            await _setSeriesStatus(
              row: row,
              status: CalendarEventStatus.rescheduled,
              replacementEventId: replacementDraft.id,
            );
          } else {
            await _truncateBefore(row, originalDate);
            await _insertExceptionFromOccurrence(
              profileId: profileId,
              occurrence: current,
              status: CalendarEventStatus.rescheduled,
              operationId: operationId,
              replacementEventId: replacementDraft.id,
            );
          }
        case CalendarEventEditScope.series:
          await _setSeriesStatus(
            row: row,
            status: CalendarEventStatus.rescheduled,
            replacementEventId: replacementDraft.id,
          );
      }
      await linkContextTransfer.transferOnReschedule(
        profileId: profileId,
        sourceEventId: eventId,
        sourceOccurrenceId: current.id,
        sourceOriginalDate: originalDate,
        scope: scope,
        replacementEventId: replacementDraft.id,
        replacementOriginalDate: replacementDraft.startDate,
        operationId: operationId,
      );
      await _insertOperation(
        operationId: operationId,
        profileId: profileId,
        eventId: eventId,
        occurrenceId: current.id,
        command: 'reschedule:${scope.name}',
      );
      // Section 27: this mutation can change a reminder's timing, eligibility
      // or live link, so the repair intent commits with the source write.
      await reminderRepair?.mark(database, profileId: profileId);
      await writeGuard.beforeCommit();
      return CalendarEventMutationOutcome.changed;
    });
  }

  @override
  Future<CalendarEventMutationOutcome> duplicateEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required String duplicateId,
    required String operationId,
  }) async {
    _validateOperationId(operationId);
    if (!Uuid.isValidUUID(fromString: duplicateId) || duplicateId == eventId) {
      throw const CalendarEventValidationException(
        'Duplicate Calendar Events require a new stable UUID identifier.',
      );
    }
    final reports = await reportSource.readSeriesReports(eventId);
    return database.transaction(() async {
      if (await _operationExists(operationId)) {
        return CalendarEventMutationOutcome.unchanged;
      }
      final row = await _requireRow(profileId: profileId, eventId: eventId);
      final current = await _requireOccurrence(
        row: row,
        originalDate: originalDate,
        reports: reports,
      );
      final timed = current.timing == CalendarEventTiming.timed;
      // Contract E/F: a duplicate is a NEW selection. Its type must pass
      // the same live-occupancy gate as any new Event, and its snapshot is
      // freshly captured (current live alias), never inherited stale.
      final bindings = await readLiveGoalEventTypeBindings(database, profileId);
      await _validateSelectionEligibility(
        profileId: profileId,
        bindings: bindings,
        draft: CalendarEventDraft(
          id: duplicateId,
          title: '',
          timing: current.timing,
          startDate: current.displayDate,
          activityTypeId: current.activityTypeId,
          recurrence: const CalendarRecurrenceRule(),
          requiresReport: current.requiresReport,
          isBackupAppointment: current.isBackupAppointment,
        ),
        originalTypeId: null,
      );
      final draft = _validateDraft(
        CalendarEventDraft(
          id: duplicateId,
          title: '${current.displayTitle} (Copy)',
          notes: current.notes,
          timing: current.timing,
          startDate: current.displayDate,
          startMinute: timed && current.startUtc != null
              ? _originMinute(current.startUtc!, current.timeZoneId!)
              : null,
          endMinute: timed && current.startUtc != null && current.endUtc != null
              ? _originEndMinute(
                  current.startUtc!,
                  current.endUtc!,
                  current.timeZoneId!,
                )
              : null,
          timeZoneId: current.timeZoneId,
          locationText: current.locationText,
          requiresReport: current.requiresReport,
          activityTypeId: current.activityTypeId,
          activityTypeMappingVersion: current.activityTypeMappingVersion,
          activityTypeStableKeySnapshot: current.activityTypeStableKey,
          activityTypeLabelSnapshot: current.activityTypeLabel,
          activityTypeColorValueSnapshot: current.activityTypeColorValue,
          // P2-A: duplicating a Contact Event keeps its Contact Type. The
          // channel is a descriptive fact of the Event, not an outcome or a
          // scheduled contribution rule, so it is preserved exactly like the
          // Event Type, notes and location are.
          contactChannel: current.contactChannel,
          // A duplicate is a new scheduled record. It must not inherit a
          // scheduled indicator contribution rule or any factual outcome.
          contributionRuleKey: null,
          isBackupAppointment: current.isBackupAppointment,
          backupForEventId: current.backupForEventId,
          backupRelationshipProvenance: current.backupRelationshipProvenance,
        ),
      );
      await _writeEvent(
        profileId: profileId,
        eventId: duplicateId,
        draft: draft,
        existing: null,
        parentEventId: eventId,
        selectionContext: _CalendarEventSelectionContext.newSelection,
        liveBindings: bindings,
      );
      await (database.update(
        database.calendarEvents,
      )..where((table) => table.id.equals(duplicateId))).write(
        CalendarEventsCompanion(
          latitude: Value<double?>(row.latitude),
          longitude: Value<double?>(row.longitude),
          coordinateSource: Value<String?>(row.coordinateSource),
        ),
      );
      await duplicateContextTransfer.copyPeopleOnDuplicate(
        profileId: profileId,
        sourceEventId: eventId,
        sourceOccurrenceId: current.id,
        duplicateEventId: duplicateId,
      );
      await _insertOperation(
        operationId: operationId,
        profileId: profileId,
        eventId: eventId,
        occurrenceId: current.id,
        command: 'duplicate',
      );
      // Section 27: this mutation can change a reminder's timing, eligibility
      // or live link, so the repair intent commits with the source write.
      await reminderRepair?.mark(database, profileId: profileId);
      await writeGuard.beforeCommit();
      return CalendarEventMutationOutcome.changed;
    });
  }

  CalendarEventDraft _validateDraft(CalendarEventDraft draft) {
    final normalized = draft.normalized();
    final zone = normalized.timeZoneId;
    if (zone != null && !timeZones.isValid(zone)) {
      throw CalendarEventValidationException('Unknown IANA time zone: $zone');
    }
    return normalized;
  }

  void _validateOperationId(String operationId) {
    if (!Uuid.isValidUUID(fromString: operationId)) {
      throw const CalendarEventValidationException(
        'Calendar Event operations require stable UUID identifiers.',
      );
    }
  }

  Future<CalendarEventRow?> _readRow({
    required String profileId,
    required String eventId,
  }) {
    return (database.select(database.calendarEvents)
          ..where(
            (table) =>
                table.id.equals(eventId) & table.profileId.equals(profileId),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<CalendarEventRow> _requireRow({
    required String profileId,
    required String eventId,
  }) async {
    final row = await _readRow(profileId: profileId, eventId: eventId);
    if (row == null) {
      throw StateError('Calendar Event not found');
    }
    return row;
  }

  Future<void> _writeEvent({
    required String profileId,
    required String eventId,
    required CalendarEventDraft draft,
    CalendarEventRow? existing,
    String? parentEventId,
    _CalendarEventSelectionContext selectionContext =
        _CalendarEventSelectionContext.preservation,
    Map<int, LiveGoalEventTypeBinding>? liveBindings,
  }) async {
    final activityTypeSnapshot = await _resolveActivityTypeSnapshot(
      profileId: profileId,
      draft: draft,
      existing: existing,
      selectionContext: selectionContext,
      liveBindings: liveBindings,
    );
    // Life Goal invariant (domain rule): a linked Event is always Report
    // Required.  Normalize here so direct repository callers can never
    // persist goalId != null with requiresReport == false.  Planner Polish
    // Delta 2 adds the Contact Event rule: the Contact Event Type always
    // requires a report, independent of Life Goal linkage.  The resolved
    // activity-type snapshot is the canonical stable-key source (a draft may
    // carry only an activityTypeId).
    final effectiveRequiresReport =
        draft.goalId != null ||
            activityTypeSnapshot?.stableKey == SystemEventTypeKeys.contact
        ? true
        : draft.requiresReport;
    final now = clock.nowUtc();
    final values = CalendarEventsCompanion(
      title: Value<String>(draft.title),
      notes: Value<String?>(draft.notes),
      timing: Value<String>(draft.timing.name),
      startDate: Value<String>(draft.startDate.iso8601),
      startMinute: Value<int?>(draft.startMinute),
      endMinute: Value<int?>(draft.endMinute),
      timeZoneId: Value<String?>(draft.timeZoneId),
      locationText: Value<String?>(draft.locationText),
      requiresReport: Value<bool>(effectiveRequiresReport),
      activityTypeId: Value<String?>(draft.activityTypeId),
      activityTypeMappingVersion: Value<int?>(draft.activityTypeMappingVersion),
      activityTypeStableKeySnapshot: Value<String?>(
        activityTypeSnapshot?.stableKey,
      ),
      activityTypeLabelSnapshot: Value<String?>(activityTypeSnapshot?.label),
      activityTypeColorValueSnapshot: Value<int?>(
        activityTypeSnapshot?.colorValue,
      ),
      // P2-A: the draft's explicit channel wins. A draft that carries NO
      // channel (a partial or non-form write) preserves whatever the row
      // already holds instead of erasing it, which is what keeps an unrelated
      // Event edit from silently dropping a Contact Type — and it also keeps
      // an unrecognised stored key byte-for-byte rather than destroying it.
      contactChannel: Value<String?>(
        draft.contactChannel?.stableKey ?? existing?.contactChannel,
      ),
      contributionRuleKey: Value<String?>(draft.contributionRuleKey),
      goalId: Value<String?>(draft.goalId),
      isBackupAppointment: Value<bool>(draft.isBackupAppointment),
      backupForEventId: Value<String?>(draft.backupForEventId),
      backupRelationshipProvenance: Value<String?>(
        draft.backupRelationshipProvenance,
      ),
      recurrenceFrequency: Value<String>(draft.recurrence.frequency.name),
      recurrenceEndMode: Value<String>(draft.recurrence.endMode.name),
      recurrenceEndDate: Value<String?>(draft.recurrence.endDate?.iso8601),
      recurrenceCount: Value<int?>(draft.recurrence.occurrenceCount),
      recurrencePatternJson: Value<String?>(
        calendarRecurrencePatternToJson(draft.recurrence.pattern),
      ),
      status: Value<String>(draft.status.name),
      parentEventId: Value<String?>(parentEventId ?? existing?.parentEventId),
      replacementEventId: const Value<String?>(null),
      updatedAtUtc: Value<DateTime>(now),
    );
    if (existing == null) {
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: eventId,
              profileId: profileId,
              title: draft.title,
              notes: Value<String?>(draft.notes),
              timing: draft.timing.name,
              startDate: draft.startDate.iso8601,
              startMinute: Value<int?>(draft.startMinute),
              endMinute: Value<int?>(draft.endMinute),
              timeZoneId: Value<String?>(draft.timeZoneId),
              locationText: Value<String?>(draft.locationText),
              requiresReport: Value<bool>(effectiveRequiresReport),
              activityTypeId: Value<String?>(draft.activityTypeId),
              activityTypeMappingVersion: Value<int?>(
                draft.activityTypeMappingVersion,
              ),
              activityTypeStableKeySnapshot: Value<String?>(
                activityTypeSnapshot?.stableKey,
              ),
              activityTypeLabelSnapshot: Value<String?>(
                activityTypeSnapshot?.label,
              ),
              activityTypeColorValueSnapshot: Value<int?>(
                activityTypeSnapshot?.colorValue,
              ),
              // P2-A: a brand-new Event simply stores the chosen channel (or
              // NULL when the user did not set one). Nothing is invented.
              contactChannel: Value<String?>(draft.contactChannel?.stableKey),
              contributionRuleKey: Value<String?>(draft.contributionRuleKey),
              goalId: Value<String?>(draft.goalId),
              isBackupAppointment: Value<bool>(draft.isBackupAppointment),
              backupForEventId: Value<String?>(draft.backupForEventId),
              backupRelationshipProvenance: Value<String?>(
                draft.backupRelationshipProvenance,
              ),
              recurrenceFrequency: Value<String>(
                draft.recurrence.frequency.name,
              ),
              recurrenceEndMode: Value<String>(draft.recurrence.endMode.name),
              recurrenceEndDate: Value<String?>(
                draft.recurrence.endDate?.iso8601,
              ),
              recurrenceCount: Value<int?>(draft.recurrence.occurrenceCount),
              recurrencePatternJson: Value<String?>(
                calendarRecurrencePatternToJson(draft.recurrence.pattern),
              ),
              status: Value<String>(draft.status.name),
              parentEventId: Value<String?>(parentEventId),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
    } else {
      await (database.update(
        database.calendarEvents,
      )..where((table) => table.id.equals(eventId))).write(values);
    }
  }

  CalendarEventDraft _draftFromRow(CalendarEventRow row) {
    return CalendarEventDraft(
      id: row.id,
      title: row.title,
      notes: row.notes,
      timing: CalendarEventTiming.values.byName(row.timing),
      startDate: PlannerDate.parse(row.startDate),
      status: CalendarEventStatus.values.byName(row.status),
      startMinute: row.startMinute,
      endMinute: row.endMinute,
      timeZoneId: row.timeZoneId,
      locationText: row.locationText,
      requiresReport: row.requiresReport,
      activityTypeId: row.activityTypeId,
      activityTypeMappingVersion: row.activityTypeMappingVersion,
      activityTypeStableKeySnapshot: row.activityTypeStableKeySnapshot,
      activityTypeLabelSnapshot: row.activityTypeLabelSnapshot,
      activityTypeColorValueSnapshot: row.activityTypeColorValueSnapshot,
      // P2-A: null for legacy rows and for any stored value that is not one of
      // the eight canonical keys, so the UI shows an honest unset state.
      contactChannel: EventContactChannel.fromStableKey(row.contactChannel),
      contributionRuleKey: row.contributionRuleKey,
      goalId: row.goalId,
      isBackupAppointment: row.isBackupAppointment,
      backupForEventId: row.backupForEventId,
      backupRelationshipProvenance: row.backupRelationshipProvenance,
      recurrence: _ruleFromRow(row),
    );
  }

  CalendarRecurrenceRule _ruleFromRow(CalendarEventRow row) {
    return calendarRecurrenceRuleFromStorage(
      frequencyName: row.recurrenceFrequency,
      endModeName: row.recurrenceEndMode,
      endDateIso: row.recurrenceEndDate,
      occurrenceCount: row.recurrenceCount,
      patternJson: row.recurrencePatternJson,
    );
  }

  Future<Map<String, CalendarEventExceptionRow>> _latestExceptions(
    String eventId,
  ) async {
    final rows =
        await (database.select(database.calendarEventExceptions)
              ..where((table) => table.eventId.equals(eventId))
              ..orderBy(<OrderingTerm Function(CalendarEventExceptions)>[
                (table) => OrderingTerm.asc(table.createdAtUtc),
              ]))
            .get();
    return <String, CalendarEventExceptionRow>{
      for (final row in rows) row.occurrenceId: row,
    };
  }

  /// Batch equivalent of [_latestExceptions] for a set of Event IDs.
  ///
  /// Fetches the exact same exception population the per-Event method would
  /// fetch (no date filtering — that is a later, recurrence-safe phase) and
  /// reproduces the same latest-wins rule: rows ordered by createdAtUtc
  /// ascending, with the last row per occurrenceId winning.  Returns
  /// Event ID -> (occurrenceId -> latest exception row).
  Future<Map<String, Map<String, CalendarEventExceptionRow>>>
  _latestExceptionsForEvents(Iterable<String> eventIds) async {
    final ids = eventIds.toSet().toList();
    if (ids.isEmpty) {
      return const <String, Map<String, CalendarEventExceptionRow>>{};
    }
    final grouped = <String, Map<String, CalendarEventExceptionRow>>{};
    for (final chunk in _chunks(ids, _batchChunkSize)) {
      final rows =
          await (database.select(database.calendarEventExceptions)
                ..where((table) => table.eventId.isIn(chunk))
                ..orderBy(<OrderingTerm Function(CalendarEventExceptions)>[
                  (table) => OrderingTerm.asc(table.eventId),
                  (table) => OrderingTerm.asc(table.createdAtUtc),
                ]))
              .get();
      for (final row in rows) {
        final byOccurrence = grouped.putIfAbsent(
          row.eventId,
          () => <String, CalendarEventExceptionRow>{},
        );
        byOccurrence[row.occurrenceId] = row;
      }
    }
    return grouped;
  }

  static const int _batchChunkSize = 500;

  static Iterable<List<String>> _chunks(List<String> values, int size) sync* {
    for (var start = 0; start < values.length; start += size) {
      final end = start + size < values.length ? start + size : values.length;
      yield values.sublist(start, end);
    }
  }

  Future<ActivityTypeRow?> _readActivityType(
    String profileId,
    String activityTypeId,
  ) {
    return (database.select(database.activityTypes)
          ..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.id.equals(activityTypeId),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<CalendarEventOccurrence?> _buildOccurrence({
    required CalendarEventRow row,
    required PlannerDate originalDate,
    required CalendarEventExceptionRow? exception,
    required Map<String, CalendarEventReportSnapshot> reportById,
    CalendarEventTaskContextSnapshot? taskContextSnapshot,
  }) async {
    final rule = _ruleFromRow(row);
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: row.id,
      originalDate: originalDate,
    );
    if (rule.occurrenceIndexOn(
              startDate: PlannerDate.parse(row.startDate),
              targetDate: originalDate,
            ) ==
            null &&
        exception == null) {
      return null;
    }
    final effectiveDate = exception == null
        ? originalDate
        : PlannerDate.parse(exception.effectiveDate);
    final timing = CalendarEventTiming.values.byName(
      exception?.timing ?? row.timing,
    );
    final zoneId = exception?.timeZoneId ?? row.timeZoneId;
    final startMinute = exception?.startMinute ?? row.startMinute;
    final endMinute = exception?.endMinute ?? row.endMinute;
    DateTime? startUtc;
    DateTime? endUtc;
    DateTime? startDisplay;
    DateTime? endDisplay;
    PlannerDate displayDate = effectiveDate;
    if (timing == CalendarEventTiming.timed) {
      startUtc = timeZones.wallTimeToUtc(
        date: effectiveDate,
        minuteOfDay: startMinute!,
        timeZoneId: zoneId!,
      );
      endUtc = timeZones.wallTimeToUtc(
        date: effectiveDate,
        minuteOfDay: endMinute!,
        timeZoneId: zoneId,
      );
      startDisplay = timeZones.utcToDisplayWall(startUtc);
      endDisplay = timeZones.utcToDisplayWall(endUtc);
      displayDate = PlannerDate.fromDateTime(startDisplay);
    }
    final masterStatus = CalendarEventStatus.values.byName(row.status);
    final occurrenceStoredStatus = CalendarEventStatus.values.byName(
      exception?.status ?? row.status,
    );
    final isStructurallyCancelled =
        masterStatus == CalendarEventStatus.cancelled ||
        occurrenceStoredStatus == CalendarEventStatus.cancelled;
    var status = occurrenceStoredStatus;
    final report = reportById[occurrenceId];
    if (!isStructurallyCancelled &&
        status == CalendarEventStatus.scheduled &&
        report != null) {
      status = report.status;
    }
    final activityTypeId = exception?.activityTypeId ?? row.activityTypeId;
    final activityTypeStableKeySnapshot =
        exception?.activityTypeStableKeySnapshot ??
        row.activityTypeStableKeySnapshot;
    final activityTypeLabelSnapshot =
        exception?.activityTypeLabelSnapshot ?? row.activityTypeLabelSnapshot;
    final activityTypeColorValueSnapshot =
        exception?.activityTypeColorValueSnapshot ??
        row.activityTypeColorValueSnapshot;
    final activityType =
        activityTypeId == null ||
            (activityTypeStableKeySnapshot != null &&
                activityTypeLabelSnapshot != null &&
                activityTypeColorValueSnapshot != null)
        ? null
        : await _readActivityType(row.profileId, activityTypeId);
    final activityTypeStableKey =
        activityTypeStableKeySnapshot ?? activityType?.stableKey;
    final activityTypeLabel = activityTypeLabelSnapshot ?? activityType?.label;
    final activityTypeColorValue =
        activityTypeColorValueSnapshot ?? activityType?.colorValue;
    return CalendarEventOccurrence(
      id: occurrenceId,
      eventId: row.id,
      profileId: row.profileId,
      title: exception?.title ?? row.title,
      notes: exception == null ? row.notes : exception.notes,
      timing: timing,
      originalDate: originalDate,
      displayDate: displayDate,
      startUtc: startUtc,
      endUtc: endUtc,
      startDisplay: startDisplay,
      endDisplay: endDisplay,
      timeZoneId: zoneId,
      displayTimeZoneId: timing == CalendarEventTiming.timed
          ? timeZones.displayTimeZoneId
          : null,
      locationText: exception == null
          ? row.locationText
          : exception.locationText,
      status: status,
      requiresReport: exception?.requiresReport ?? row.requiresReport,
      activityTypeId: activityTypeId,
      activityTypeMappingVersion:
          exception?.activityTypeMappingVersion ??
          row.activityTypeMappingVersion,
      activityTypeStableKey: activityTypeStableKey,
      activityTypeLabel: activityTypeLabel,
      activityTypeColorValue: activityTypeColorValue,
      // P2-A: the channel is a series-level Event fact (design D1); occurrence
      // exceptions carry no channel column of their own, so it always comes
      // from the Event row.
      contactChannel: EventContactChannel.fromStableKey(row.contactChannel),
      contributionRuleKey: exception == null
          ? row.contributionRuleKey
          : exception.contributionRuleKey,
      isBackupAppointment:
          exception?.isBackupAppointment ?? row.isBackupAppointment,
      backupForEventId: exception == null
          ? row.backupForEventId
          : exception.backupForEventId,
      backupRelationshipProvenance: exception == null
          ? row.backupRelationshipProvenance
          : exception.backupRelationshipProvenance,
      recurrence: rule,
      replacementEventId:
          exception?.replacementEventId ?? row.replacementEventId,
      linkedTaskIds: taskContextSnapshot == null
          ? await taskContextSource.readLinkedTaskIds(
              eventId: row.id,
              occurrenceId: occurrenceId,
            )
          : taskContextSnapshot.linkedTaskIds(
              eventId: row.id,
              occurrenceId: occurrenceId,
            ),
      isStructurallyCancelled: isStructurallyCancelled,
      reportedStatus: report?.status,
      createdAtUtc: exception?.createdAtUtc ?? row.createdAtUtc,
      updatedAtUtc: exception?.createdAtUtc ?? row.updatedAtUtc,
    );
  }

  PlannerCalendarItem _toPlannerItem(CalendarEventOccurrence occurrence) {
    return PlannerCalendarItem(
      id: occurrence.id,
      eventId: occurrence.eventId,
      title: occurrence.title,
      date: occurrence.displayDate,
      originalDate: occurrence.originalDate,
      timing: occurrence.timing == CalendarEventTiming.allDay
          ? PlannerEventTiming.allDay
          : PlannerEventTiming.timed,
      state: switch (occurrence.status) {
        CalendarEventStatus.scheduled => PlannerEventState.scheduled,
        CalendarEventStatus.completedHappened =>
          PlannerEventState.completedHappened,
        CalendarEventStatus.partiallyCompleted =>
          PlannerEventState.partiallyCompleted,
        CalendarEventStatus.didNotHappen => PlannerEventState.didNotHappen,
        CalendarEventStatus.cancelled => PlannerEventState.cancelled,
        CalendarEventStatus.rescheduled => PlannerEventState.rescheduled,
      },
      requiresReport: occurrence.requiresReport,
      hasOutcomeReport:
          occurrence.status == CalendarEventStatus.completedHappened ||
          occurrence.status == CalendarEventStatus.partiallyCompleted ||
          occurrence.status == CalendarEventStatus.didNotHappen,
      startLocal: occurrence.startDisplay,
      endLocal: occurrence.endDisplay,
      startUtc: occurrence.startUtc,
      endUtc: occurrence.endUtc,
      locationText: occurrence.locationText,
      isRecurring: occurrence.isRecurring,
      replacementId: occurrence.replacementEventId,
      linkedTaskIds: occurrence.linkedTaskIds,
      timeZoneId: occurrence.timeZoneId,
      displayTimeZoneId: occurrence.displayTimeZoneId,
      activityTypeId: occurrence.activityTypeId,
      activityTypeStableKey: occurrence.activityTypeStableKey,
      activityTypeLabel: occurrence.activityTypeLabel,
      activityTypeColorValue: occurrence.activityTypeColorValue,
      contactChannel: occurrence.contactChannel,
      isBackupAppointment: occurrence.isBackupAppointment,
      backupForEventId: occurrence.backupForEventId,
    );
  }

  Future<CalendarEventOccurrence> _requireOccurrence({
    required CalendarEventRow row,
    required PlannerDate originalDate,
    required List<CalendarEventReportSnapshot> reports,
  }) async {
    final id = CalendarEventOccurrenceIdentity.forDate(
      eventId: row.id,
      originalDate: originalDate,
    );
    final occurrence = await _buildOccurrence(
      row: row,
      originalDate: originalDate,
      exception: (await _latestExceptions(row.id))[id],
      reportById: <String, CalendarEventReportSnapshot>{
        for (final report in reports) report.occurrenceId: report,
      },
    );
    if (occurrence == null) {
      throw StateError('Calendar Event occurrence not found');
    }
    return occurrence;
  }

  void _ensureOccurrenceIsEditable({
    required String eventId,
    required PlannerDate originalDate,
    required List<CalendarEventReportSnapshot> reports,
  }) {
    final id = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: originalDate,
    );
    if (reports.any((report) => report.occurrenceId == id)) {
      throw const CalendarEventValidationException(
        'Reported historical occurrences are immutable.',
      );
    }
  }

  Future<void> _preserveReports({
    required String profileId,
    required CalendarEventRow row,
    required List<CalendarEventReportSnapshot> reports,
    required String operationId,
  }) async {
    final existing = await _latestExceptions(row.id);
    for (final report in reports) {
      if (existing.containsKey(report.occurrenceId)) {
        continue;
      }
      final occurrence = await _buildOccurrence(
        row: row,
        originalDate: report.originalDate,
        exception: null,
        reportById: <String, CalendarEventReportSnapshot>{
          report.occurrenceId: report,
        },
      );
      if (occurrence == null) {
        continue;
      }
      await _insertExceptionFromOccurrence(
        profileId: profileId,
        occurrence: occurrence,
        status: report.status,
        operationId: '$operationId:${report.occurrenceId}',
      );
    }
  }

  Future<void> _insertExceptionFromOccurrence({
    required String profileId,
    required CalendarEventOccurrence occurrence,
    required CalendarEventStatus status,
    required String operationId,
    String? replacementEventId,
  }) {
    return _insertException(
      profileId: profileId,
      eventId: occurrence.eventId,
      originalDate: occurrence.originalDate,
      occurrenceId: occurrence.id,
      draft: CalendarEventDraft(
        id: occurrence.eventId,
        title: occurrence.title,
        notes: occurrence.notes,
        timing: occurrence.timing,
        startDate: occurrence.originalDate,
        startMinute: occurrence.startUtc == null
            ? null
            : _originMinute(occurrence.startUtc!, occurrence.timeZoneId!),
        endMinute: occurrence.startUtc == null || occurrence.endUtc == null
            ? null
            : _originEndMinute(
                occurrence.startUtc!,
                occurrence.endUtc!,
                occurrence.timeZoneId!,
              ),
        timeZoneId: occurrence.timeZoneId,
        locationText: occurrence.locationText,
        requiresReport: occurrence.requiresReport,
        activityTypeId: occurrence.activityTypeId,
        activityTypeMappingVersion: occurrence.activityTypeMappingVersion,
        activityTypeStableKeySnapshot: occurrence.activityTypeStableKey,
        activityTypeLabelSnapshot: occurrence.activityTypeLabel,
        activityTypeColorValueSnapshot: occurrence.activityTypeColorValue,
        contactChannel: occurrence.contactChannel,
        contributionRuleKey: occurrence.contributionRuleKey,
        isBackupAppointment: occurrence.isBackupAppointment,
        backupForEventId: occurrence.backupForEventId,
        backupRelationshipProvenance: occurrence.backupRelationshipProvenance,
      ),
      status: status,
      operationId: operationId,
      replacementEventId: replacementEventId,
    );
  }

  Future<void> _insertException({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required String occurrenceId,
    required CalendarEventDraft draft,
    required CalendarEventStatus status,
    required String operationId,
    String? replacementEventId,
    _CalendarEventSelectionContext selectionContext =
        _CalendarEventSelectionContext.preservation,
    Map<int, LiveGoalEventTypeBinding>? liveBindings,
  }) async {
    final existing = await _readRow(profileId: profileId, eventId: eventId);
    final activityTypeSnapshot = await _resolveActivityTypeSnapshot(
      profileId: profileId,
      draft: draft,
      existing: existing,
      selectionContext: selectionContext,
      liveBindings: liveBindings,
    );
    // Life Goal invariant (domain rule): a linked Event is always Report
    // Required.  Normalize here so occurrence persistence can never write
    // goalId != null with requiresReport == false.  Planner Polish Delta 2:
    // the Contact Event Type always requires a report even without a Goal.
    final effectiveRequiresReport =
        draft.goalId != null ||
            activityTypeSnapshot?.stableKey == SystemEventTypeKeys.contact
        ? true
        : draft.requiresReport;
    await database
        .into(database.calendarEventExceptions)
        .insert(
          CalendarEventExceptionsCompanion.insert(
            id: CalendarEventExceptionIdentity.forOperation(
              operationId: operationId,
              occurrenceId: occurrenceId,
            ),
            profileId: profileId,
            eventId: eventId,
            occurrenceId: occurrenceId,
            originalDate: originalDate.iso8601,
            effectiveDate: draft.startDate.iso8601,
            title: draft.title,
            notes: Value<String?>(draft.notes),
            timing: draft.timing.name,
            startMinute: Value<int?>(draft.startMinute),
            endMinute: Value<int?>(draft.endMinute),
            timeZoneId: Value<String?>(draft.timeZoneId),
            locationText: Value<String?>(draft.locationText),
            requiresReport: Value<bool>(effectiveRequiresReport),
            activityTypeId: Value<String?>(draft.activityTypeId),
            activityTypeMappingVersion: Value<int?>(
              draft.activityTypeMappingVersion,
            ),
            activityTypeStableKeySnapshot: Value<String?>(
              activityTypeSnapshot?.stableKey,
            ),
            activityTypeLabelSnapshot: Value<String?>(
              activityTypeSnapshot?.label,
            ),
            activityTypeColorValueSnapshot: Value<int?>(
              activityTypeSnapshot?.colorValue,
            ),
            contributionRuleKey: Value<String?>(draft.contributionRuleKey),
            goalId: Value<String?>(draft.goalId),
            isBackupAppointment: Value<bool>(draft.isBackupAppointment),
            backupForEventId: Value<String?>(draft.backupForEventId),
            backupRelationshipProvenance: Value<String?>(
              draft.backupRelationshipProvenance,
            ),
            status: status.name,
            replacementEventId: Value<String?>(replacementEventId),
            createdAtUtc: clock.nowUtc(),
          ),
        );
  }

  /// Contract E/F: new-selection eligibility guard. Enforced ONLY when the
  /// write would make the Event carry a canonical slot Event Type that its
  /// reference row does not already carry (new Event, duplicate, or a
  /// deliberate type change resolved at the editEvent boundary). Every such
  /// selection requires the slot to have exactly one live raw-active Goal
  /// occupant with exact canonical identity (system ID AND stable key AND
  /// mapping); hidden slot types fail closed. Corrupt bindings fail closed
  /// through the same map (occupant duplicates simply produce no binding).
  Future<void> _validateSelectionEligibility({
    required String profileId,
    required Map<int, LiveGoalEventTypeBinding> bindings,
    required CalendarEventDraft draft,
    required String? originalTypeId,
  }) async {
    final activityTypeId = draft.activityTypeId;
    if (activityTypeId == null || activityTypeId == originalTypeId) {
      return;
    }
    final typeRow = await _readActivityType(profileId, activityTypeId);
    if (typeRow == null) {
      return;
    }
    final slot = CanonicalGoalSlot.tryByEventTypeKey(typeRow.stableKey);
    if (slot == null || slot.eventTypeId != activityTypeId) {
      return;
    }
    if (!bindings.containsKey(slot.slotIndex)) {
      throw const CalendarEventValidationException(
        'That Event Type is not currently available for new Events.',
      );
    }
  }

  Future<_ActivityTypeSnapshot?> _resolveActivityTypeSnapshot({
    required String profileId,
    required CalendarEventDraft draft,
    required CalendarEventRow? existing,
    required _CalendarEventSelectionContext selectionContext,
    Map<int, LiveGoalEventTypeBinding>? liveBindings,
  }) async {
    final activityTypeId = draft.activityTypeId;
    if (activityTypeId == null) {
      return null;
    }
    final sameType =
        existing != null && existing.activityTypeId == activityTypeId;
    final canUseDraftSnapshot = existing == null || sameType;
    final stableKey = canUseDraftSnapshot
        ? draft.activityTypeStableKeySnapshot ??
              (sameType ? existing.activityTypeStableKeySnapshot : null)
        : null;
    final label = canUseDraftSnapshot
        ? draft.activityTypeLabelSnapshot ??
              (sameType ? existing.activityTypeLabelSnapshot : null)
        : null;
    final colorValue = canUseDraftSnapshot
        ? draft.activityTypeColorValueSnapshot ??
              (sameType ? existing.activityTypeColorValueSnapshot : null)
        : null;
    final current = stableKey == null || label == null || colorValue == null
        ? await _readActivityType(profileId, activityTypeId)
        : null;
    final resolvedStableKey = stableKey ?? current?.stableKey;
    var resolvedColor = colorValue ?? current?.colorValue;
    var resolvedLabel = label ?? current?.label;
    // Contract E alias capture + Prompt-P46 presentation overrides: ONLY a
    // new-selection write (new Event, duplicate, deliberate type change) may
    // persist a live presentation alias for a canonical slot type. The live
    // binding's effective display name (valid MANUAL override for the bound
    // Goal, otherwise the current Goal title) ALWAYS wins over any
    // caller-supplied or stale label; overrides come from the same raw
    // document helper inside this transaction — never from UI provider
    // aliases. Preservation writes (same-type edits, reschedule, cancel,
    // report preservation) keep every stored snapshot EXACTLY as-is — a Goal
    // rename never rewrites historical snapshots, and the raw label fallback
    // stays untouched. The raw label in activity_types is never modified.
    if (selectionContext == _CalendarEventSelectionContext.newSelection) {
      final slot = CanonicalGoalSlot.tryByEventTypeKey(resolvedStableKey);
      if (slot != null && slot.eventTypeId == activityTypeId) {
        final binding = liveBindings?[slot.slotIndex];
        // Read the current presentation document ONCE, inside this
        // transaction, for both the live name override and the Education
        // color rule below.
        final stored = await PlannerPresentationDocumentStore(
          database: database,
          clock: clock,
        ).read(profileId);
        if (binding != null) {
          // Live canonical type: valid manual override wins, else Goal title.
          final override = stored.goalEventTypeNames[binding.goalId];
          final validOverride =
              override != null &&
                  override.eventTypeStableKey == slot.eventTypeStableKey
              ? override
              : null;
          resolvedLabel = validOverride?.name ?? binding.title;
        } else {
          // Non-Goal prospective surface: the exact untouched Study row
          // presents as Study & Planning in new-selection snapshots.
          final currentLabel = resolvedLabel ?? current?.label;
          if (currentLabel != null) {
            resolvedLabel = EventTypePresentation.prospectiveLabel(
              EventType(
                id: activityTypeId,
                stableKey: resolvedStableKey!,
                label: currentLabel,
                icon: EventTypeIcon.calendar,
                colorValue: resolvedColor ?? 0,
                isSystem: true,
                isArchived: false,
                reportRequiredDefault: false,
                defaultDurationMinutes: 60,
                position: 0,
                mappingVersion: 1,
                indicatorKeys: const <String>{},
              ),
            );
          }
        }
        // Prompt-P46 Education: a new-selection snapshot for the exact
        // canonical Education type resolves the accent from the explicit
        // saved education preference, or the NEW P22 default — never from
        // the legacy raw seed still stored in activity_types for an
        // existing install. The saved/custom user entry is preserved
        // verbatim; nothing is written back to preferences here.
        if (slot.eventTypeStableKey == SystemEventTypeKeys.education) {
          final saved = stored.events[SystemEventTypeKeys.education];
          resolvedColor =
              saved?.accentArgb ??
              PlannerEventColorDefaults.education.accentArgb;
        }
      } else if (resolvedStableKey == SystemEventTypeKeys.studyOrPlan) {
        // Study snapshot capture for a non-canonical-ID row can only be a
        // data corruption; keep the raw label (no alias) — identity is the
        // exact canonical pair.
      }
    }
    return _ActivityTypeSnapshot(
      stableKey: resolvedStableKey,
      label: resolvedLabel,
      colorValue: resolvedColor,
    );
  }

  Future<bool> _operationExists(String operationId) async {
    return (await (database.select(database.calendarEventOperations)
              ..where((table) => table.operationId.equals(operationId))
              ..limit(1))
            .getSingleOrNull()) !=
        null;
  }

  Future<void> _insertOperation({
    required String operationId,
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required String command,
  }) async {
    await database
        .into(database.calendarEventOperations)
        .insert(
          CalendarEventOperationsCompanion.insert(
            operationId: operationId,
            profileId: profileId,
            eventId: eventId,
            occurrenceId: Value<String?>(occurrenceId),
            command: command,
            createdAtUtc: clock.nowUtc(),
          ),
        );
  }

  /// Removes scheduled (field-override) exceptions for one occurrence.  Used
  /// when a NON-recurring Event edit rewrites the master row: the master now
  /// owns the full edited state, so a stale override (for example old times
  /// from a pre-fix build) must not keep masking the master values.  Lifecycle
  /// exceptions (cancelled / rescheduled) are intentionally preserved.
  Future<void> _clearFieldOverrideExceptions({
    required String eventId,
    required String occurrenceId,
  }) async {
    await (database.delete(database.calendarEventExceptions)..where(
          (table) =>
              table.eventId.equals(eventId) &
              table.occurrenceId.equals(occurrenceId) &
              table.status.equals(CalendarEventStatus.scheduled.name),
        ))
        .go();
  }

  /// Once a series becomes a single non-repeating Event, only exceptions
  /// that preserve submitted historical occurrence truth may remain. Future
  /// or otherwise unreported overrides would continue to project phantom
  /// occurrences because exception identity intentionally bypasses rule
  /// expansion.
  Future<void> _removeUnreportedExceptions({
    required String eventId,
    required List<CalendarEventReportSnapshot> reports,
  }) async {
    final reportedOccurrenceIds = reports
        .map((report) => report.occurrenceId)
        .toSet();
    final deletion = database.delete(database.calendarEventExceptions)
      ..where((table) {
        final eventMatches = table.eventId.equals(eventId);
        if (reportedOccurrenceIds.isEmpty) {
          return eventMatches;
        }
        return eventMatches & table.occurrenceId.isNotIn(reportedOccurrenceIds);
      });
    await deletion.go();
  }

  /// Delta 4.1 recurrence rebase: translates every surviving time-based
  /// occurrence override of a series by [deltaMinutes] while preserving each
  /// override's duration and its relative offset from the series baseline.
  ///
  /// Only `scheduled` (field-override) exceptions with `timed` timing and
  /// persisted start/end minutes are rebased.  Lifecycle rows (cancelled
  /// exclusions, rescheduled/detached occurrences) stay untouched, and
  /// overrides belonging to other series are never selected (the query is
  /// scoped by this series' event id).  The new start is clamped inside the
  /// civil day with the full duration preserved, so an extreme delta cannot
  /// produce an invalid end-before-start or an over-24h span.
  Future<void> _rebaseSeriesTimeOverrides({
    required String eventId,
    required int deltaMinutes,
  }) async {
    final exceptions = await (database.select(
      database.calendarEventExceptions,
    )..where((table) => table.eventId.equals(eventId))).get();
    for (final exception in exceptions) {
      if (exception.timing != CalendarEventTiming.timed.name ||
          exception.status != CalendarEventStatus.scheduled.name) {
        continue;
      }
      final start = exception.startMinute;
      final end = exception.endMinute;
      if (start == null || end == null) {
        continue;
      }
      final duration = end - start;
      final nextStart = (start + deltaMinutes).clamp(0, 1440 - duration);
      final nextEnd = nextStart + duration;
      await (database.update(
        database.calendarEventExceptions,
      )..where((table) => table.id.equals(exception.id))).write(
        CalendarEventExceptionsCompanion(
          startMinute: Value<int>(nextStart),
          endMinute: Value<int>(nextEnd),
        ),
      );
    }
  }

  Future<void> _truncateBefore(
    CalendarEventRow row,
    PlannerDate originalDate,
  ) async {
    await (database.update(
      database.calendarEvents,
    )..where((table) => table.id.equals(row.id))).write(
      CalendarEventsCompanion(
        recurrenceEndMode: const Value<String>('onDate'),
        recurrenceEndDate: Value<String>(originalDate.addDays(-1).iso8601),
        recurrenceCount: const Value<int?>(null),
        updatedAtUtc: Value<DateTime>(clock.nowUtc()),
      ),
    );
  }

  Future<void> _setSeriesStatus({
    required CalendarEventRow row,
    required CalendarEventStatus status,
    String? replacementEventId,
  }) async {
    await (database.update(
      database.calendarEvents,
    )..where((table) => table.id.equals(row.id))).write(
      CalendarEventsCompanion(
        status: Value<String>(status.name),
        replacementEventId: Value<String?>(replacementEventId),
        updatedAtUtc: Value<DateTime>(clock.nowUtc()),
      ),
    );
  }

  CalendarEventDraft _draftForSplit({
    required CalendarEventRow source,
    required PlannerDate targetDate,
    required CalendarEventDraft replacement,
  }) {
    var rule = replacement.recurrence;
    final sourceRule = _ruleFromRow(source);
    if (_sameRule(rule, sourceRule) &&
        sourceRule.endMode == CalendarRecurrenceEndMode.afterCount) {
      final index = sourceRule.occurrenceIndexOn(
        startDate: PlannerDate.parse(source.startDate),
        targetDate: targetDate,
      )!;
      rule = CalendarRecurrenceRule(
        frequency: rule.frequency,
        endMode: CalendarRecurrenceEndMode.afterCount,
        occurrenceCount: sourceRule.occurrenceCount! - index,
        pattern: rule.pattern,
      );
    }
    return replacement.copyWith(startDate: targetDate, recurrence: rule);
  }

  bool _sameRule(CalendarRecurrenceRule left, CalendarRecurrenceRule right) {
    return left.frequency == right.frequency &&
        left.endMode == right.endMode &&
        left.endDate == right.endDate &&
        left.occurrenceCount == right.occurrenceCount &&
        left.pattern == right.pattern;
  }

  int _originMinute(DateTime instant, String timeZoneId) {
    final wall = timeZones.utcToWall(value: instant, timeZoneId: timeZoneId);
    return wall.hour * 60 + wall.minute;
  }

  /// Normalized origin-zone END minute (1..1440) for a timed Event.
  ///
  /// A 24:00 local end normalizes to 00:00 of the next civil day; without
  /// the normalization the snapshot/duplicate path would persist `endMinute
  /// == 0`, which is before any start and would be rejected by validation —
  /// the final-hour 11 PM-12 AM edit/move failure.  A valid timed Event
  /// always ends after it starts, so an end wall-clock of exactly 00:00 with
  /// positive duration can only be the final 24:00 boundary (including a
  /// full-day Event from 00:00 to 24:00); a zero-duration end at 00:00 is
  /// invalid and stays minute 0.
  int _originEndMinute(
    DateTime startInstant,
    DateTime endInstant,
    String timeZoneId,
  ) {
    final endWall = timeZones.utcToWall(
      value: endInstant,
      timeZoneId: timeZoneId,
    );
    final endMinute = endWall.hour * 60 + endWall.minute;
    if (endMinute == 0 && endInstant.isAfter(startInstant)) {
      return 1440;
    }
    return endMinute;
  }
}
