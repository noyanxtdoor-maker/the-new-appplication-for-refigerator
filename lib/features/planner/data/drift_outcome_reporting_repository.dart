import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/data/task_goal_contribution_engine.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:uuid/uuid.dart';

abstract interface class OutcomeReportingWriteGuard {
  Future<void> beforeCommit();
}

final class AllowOutcomeReportingWrites implements OutcomeReportingWriteGuard {
  const AllowOutcomeReportingWrites();

  @override
  Future<void> beforeCommit() async {}
}

final class DriftOutcomeReportingRepository
    implements
        OutcomeReportingRepository,
        CalendarEventReportSource,
        CalendarEventReportBatchSource,
        TaskHistoricalEffectReader {
  const DriftOutcomeReportingRepository({
    required this.database,
    required this.clock,
    this.writeGuard = const AllowOutcomeReportingWrites(),
  });

  final AppDatabase database;
  final AppClock clock;
  final OutcomeReportingWriteGuard writeGuard;

  @override
  Future<bool> hasReportOrLedgerEffect(String taskId) async {
    final report =
        await (database.select(database.outcomeReports)
              ..where(
                (table) =>
                    table.sourceType.equals(OutcomeSourceType.task.name) &
                    table.sourceId.equals(taskId) &
                    table.status.isNotValue(OutcomeReportStatus.draft.name),
              )
              ..limit(1))
            .getSingleOrNull();
    return report != null;
  }

  @override
  Future<List<CalendarEventReportSnapshot>> readSeriesReports(
    String eventId,
  ) async {
    final rows =
        await (database.select(database.outcomeReports)
              ..where(
                (table) =>
                    table.eventId.equals(eventId) &
                    table.status.equals(OutcomeReportStatus.submitted.name) &
                    table.effectiveSlotKey.isNotNull(),
              )
              ..orderBy(<OrderingTerm Function(OutcomeReports)>[
                (table) => OrderingTerm.asc(table.activityDate),
              ]))
            .get();
    return rows
        .map(_reportSnapshotFromRow)
        .whereType<CalendarEventReportSnapshot>()
        .toList(growable: false);
  }

  @override
  Future<Map<String, List<CalendarEventReportSnapshot>>>
  readSeriesReportsForEvents(Iterable<String> eventIds) async {
    final ids = eventIds.toSet().toList();
    if (ids.isEmpty) {
      return const <String, List<CalendarEventReportSnapshot>>{};
    }
    final grouped = <String, List<CalendarEventReportSnapshot>>{};
    for (final chunk in _chunks(ids, _reportBatchChunkSize)) {
      final rows =
          await (database.select(database.outcomeReports)
                ..where(
                  (table) =>
                      table.eventId.isIn(chunk) &
                      table.status.equals(OutcomeReportStatus.submitted.name) &
                      table.effectiveSlotKey.isNotNull(),
                )
                ..orderBy(<OrderingTerm Function(OutcomeReports)>[
                  (table) => OrderingTerm.asc(table.eventId),
                  (table) => OrderingTerm.asc(table.activityDate),
                ]))
              .get();
      for (final row in rows) {
        final eventId = row.eventId;
        final snapshot = eventId == null ? null : _reportSnapshotFromRow(row);
        if (eventId == null || snapshot == null) {
          continue;
        }
        (grouped[eventId] ??= <CalendarEventReportSnapshot>[]).add(snapshot);
      }
    }
    return grouped;
  }

  /// Maps one [OutcomeReportRow] to a [CalendarEventReportSnapshot], or
  /// returns null for rows that the legacy read path excluded (missing
  /// occurrence identity or outcome).  Shared by the single-Event and batch
  /// read paths so their filters and mapping stay identical.
  static CalendarEventReportSnapshot? _reportSnapshotFromRow(
    OutcomeReportRow row,
  ) {
    final occurrenceId = row.occurrenceId;
    final originalDate = row.originalDate;
    final outcome = row.outcome;
    if (occurrenceId == null || originalDate == null || outcome == null) {
      return null;
    }
    return CalendarEventReportSnapshot(
      occurrenceId: occurrenceId,
      originalDate: PlannerDate.parse(originalDate),
      status: CalendarEventStatus.values.byName(outcome),
    );
  }

  static const int _reportBatchChunkSize = 500;

  static Iterable<List<String>> _chunks(List<String> values, int size) sync* {
    for (var start = 0; start < values.length; start += size) {
      final end = start + size < values.length ? start + size : values.length;
      yield values.sublist(start, end);
    }
  }

  @override
  Future<OutcomeReportSource?> readTaskSource({
    required String profileId,
    required String taskId,
  }) async {
    final row =
        await (database.select(database.plannerTasks)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) & table.id.equals(taskId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return OutcomeReportSource(
      type: OutcomeSourceType.task,
      sourceId: row.id,
      label: row.title,
      activityDate: row.dueDate == null
          ? PlannerDate.fromDateTime(clock.nowUtc().toLocal())
          : PlannerDate.parse(row.dueDate!),
    );
  }

  @override
  Future<OutcomeReportSource?> readEventSource({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
  }) async {
    final row =
        await (database.select(database.calendarEvents)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(eventId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (row == null ||
        _recurrenceFromRow(row).occurrenceIndexOn(
              startDate: PlannerDate.parse(row.startDate),
              targetDate: originalDate,
            ) ==
            null) {
      return null;
    }
    final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: originalDate,
    );
    final exception = await _latestException(eventId, occurrenceId);
    final status = exception?.status ?? row.status;
    if (status == CalendarEventStatus.cancelled.name ||
        status == CalendarEventStatus.rescheduled.name) {
      return null;
    }
    final activityTypeId = exception?.activityTypeId ?? row.activityTypeId;
    final activityTypeStableKeySnapshot =
        exception?.activityTypeStableKeySnapshot ??
        row.activityTypeStableKeySnapshot;
    final activityTypeLabelSnapshot =
        exception?.activityTypeLabelSnapshot ?? row.activityTypeLabelSnapshot;
    final needsActivityTypeFallback =
        activityTypeStableKeySnapshot == null ||
        activityTypeLabelSnapshot == null;
    final activityType = activityTypeId == null || !needsActivityTypeFallback
        ? null
        : await (database.select(database.activityTypes)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.id.equals(activityTypeId),
                )
                ..limit(1))
              .getSingleOrNull();
    final activityTypeStableKey =
        activityTypeStableKeySnapshot ?? activityType?.stableKey;
    final activityTypeLabel = activityTypeLabelSnapshot ?? activityType?.label;
    final isContactEvent =
        _isContactEvent(activityTypeStableKey) ||
        _isContactEvent(activityTypeLabel);
    // The report source label must mirror the canonical display title:
    // Quick-Created Events (six-icon pilot) store an empty title and surface
    // the Event Type label instead.  Using the raw stored title here would
    // produce an empty factual label and the canonical engine would reject
    // the report ("A report requires a stable source and factual label.").
    final sourceLabel = calendarEventDisplayTitle(
      storedTitle: exception?.title ?? row.title,
      eventTypeLabel: activityTypeLabel,
    );
    return OutcomeReportSource(
      type: OutcomeSourceType.event,
      sourceId: occurrenceId,
      label: sourceLabel,
      activityDate: exception == null
          ? originalDate
          : PlannerDate.parse(exception.effectiveDate),
      eventId: eventId,
      occurrenceId: occurrenceId,
      originalDate: originalDate,
      eventTypeLabel: activityTypeLabel,
      isContactEvent: isContactEvent,
    );
  }

  @override
  Future<List<IndicatorOption>> readIndicatorOptions(String profileId) async {
    final rows =
        await (database.select(database.lifeIndicatorDefinitions)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(LifeIndicatorDefinitions)>[
                (table) => OrderingTerm.asc(table.position),
              ]))
            .get();
    return rows
        .map(
          (row) => IndicatorOption(
            key: row.indicatorKey,
            label: row.label,
            unit: row.unit,
            position: row.position,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<OutcomeReport?> readDraftForSlot({
    required String profileId,
    required String sourceSlotKey,
  }) async {
    final row =
        await (database.select(database.outcomeReports)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.sourceSlotKey.equals(sourceSlotKey) &
                    table.status.equals(OutcomeReportStatus.draft.name),
              )
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapReport(row);
  }

  @override
  Future<OutcomeReport?> readReport({
    required String profileId,
    required String reportId,
  }) async {
    final row =
        await (database.select(database.outcomeReports)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(reportId),
              )
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapReport(row);
  }

  @override
  Future<List<OutcomeReport>> readReportHistory(String profileId) async {
    final rows =
        await (database.select(database.outcomeReports)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.status.isNotValue(OutcomeReportStatus.draft.name),
              )
              ..orderBy(<OrderingTerm Function(OutcomeReports)>[
                (table) => OrderingTerm.desc(table.effectiveSlotKey),
                (table) => OrderingTerm.desc(table.updatedAtUtc),
              ]))
            .get();
    return Future.wait(rows.map(_mapReport));
  }

  @override
  Future<List<ActivityLedgerEntry>> readLedgerHistory({
    required String profileId,
    String? indicatorKey,
    PlannerDate? startDate,
    PlannerDate? endDate,
    bool effectiveOnly = true,
  }) async {
    final rows =
        await (database.select(database.activityLedgerEntries)
              ..where((table) {
                Expression<bool> predicate = table.profileId.equals(profileId);
                if (indicatorKey != null) {
                  predicate =
                      predicate & table.indicatorKey.equals(indicatorKey);
                }
                if (startDate != null) {
                  predicate =
                      predicate &
                      table.activityDate.isBiggerOrEqualValue(
                        startDate.iso8601,
                      );
                }
                if (endDate != null) {
                  predicate =
                      predicate &
                      table.activityDate.isSmallerOrEqualValue(endDate.iso8601);
                }
                return predicate;
              })
              ..orderBy(<OrderingTerm Function(ActivityLedgerEntries)>[
                (table) => OrderingTerm.desc(table.activityDate),
                (table) => OrderingTerm.desc(table.recordedAtUtc),
              ]))
            .get();
    final reversedIds = rows
        .where(
          (row) =>
              row.entryType == ActivityLedgerEntryType.reversal.name &&
              row.reversalOfEntryId != null,
        )
        .map((row) => row.reversalOfEntryId!)
        .toSet();
    return rows
        .where(
          (row) =>
              !effectiveOnly ||
              (row.entryType == ActivityLedgerEntryType.contribution.name &&
                  !reversedIds.contains(row.id)),
        )
        .map(
          (row) => _mapLedgerEntry(
            row,
            isEffective:
                row.entryType == ActivityLedgerEntryType.contribution.name &&
                !reversedIds.contains(row.id),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<OutcomeReport> saveDraft({
    required String profileId,
    required OutcomeReportDraft draft,
  }) async {
    final normalized = draft.normalized(forSubmission: false);
    final source = await _validateAndCanonicalizeSource(
      profileId,
      normalized.source,
    );
    return database.transaction(() async {
      final existing =
          await (database.select(database.outcomeReports)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.draftSlotKey.equals(source.slotKey),
                )
                ..limit(1))
              .getSingleOrNull();
      final now = clock.nowUtc();
      if (existing == null) {
        await database
            .into(database.outcomeReports)
            .insert(
              _reportInsert(
                profileId: profileId,
                draft: normalized,
                source: source,
                status: OutcomeReportStatus.draft,
                createdAtUtc: now,
                updatedAtUtc: now,
                draftSlotKey: source.slotKey,
              ),
            );
      } else {
        await (database.update(database.outcomeReports)..where(
              (table) =>
                  table.id.equals(existing.id) &
                  table.profileId.equals(profileId),
            ))
            .write(
              _reportUpdate(
                draft: normalized,
                source: source,
                status: OutcomeReportStatus.draft,
                updatedAtUtc: now,
                draftSlotKey: source.slotKey,
              ),
            );
      }
      final savedId = existing?.id ?? normalized.id;
      await (database.delete(
        database.outcomeReportContributionDrafts,
      )..where((table) => table.reportId.equals(savedId))).go();
      for (final contribution in normalized.contributions) {
        await database
            .into(database.outcomeReportContributionDrafts)
            .insert(
              OutcomeReportContributionDraftsCompanion.insert(
                reportId: savedId,
                ruleKey: contribution.ruleKey,
                indicatorKey: contribution.indicatorKey,
                valueScaled: contribution.value.scaledValue,
                valueScale: contribution.value.scale,
                unit: contribution.value.unit,
              ),
            );
      }
      await writeGuard.beforeCommit();
      final row = await _requireReportRow(profileId, savedId);
      return _mapReport(row);
    });
  }

  @override
  Future<ReportSubmissionResult> submit({
    required String profileId,
    required OutcomeReportDraft draft,
    required String operationId,
  }) async {
    _validateUuid(operationId, 'submission operation');
    final normalized = draft.normalized(forSubmission: true);
    final source = await _validateAndCanonicalizeSource(
      profileId,
      normalized.source,
    );

    return database.transaction(() async {
      final priorOperation =
          await (database.select(database.outcomeReports)
                ..where((table) => table.operationId.equals(operationId))
                ..limit(1))
              .getSingleOrNull();
      if (priorOperation != null) {
        return ReportSubmissionResult(
          report: await _mapReport(priorOperation),
          entries: await _entriesForReport(priorOperation.id),
          unchanged: true,
        );
      }

      final existingEffective =
          await (database.select(database.outcomeReports)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.effectiveSlotKey.equals(source.slotKey),
                )
                ..limit(1))
              .getSingleOrNull();
      final correctedId = normalized.correctsReportId;
      OutcomeReportRow? corrected;
      List<ActivityLedgerEntryRow> correctedEntries =
          const <ActivityLedgerEntryRow>[];
      if (correctedId == null) {
        if (existingEffective != null) {
          throw const OutcomeReportValidationException(
            'This source already has an effective report. Use correction.',
          );
        }
      } else {
        corrected = await _requireReportRow(profileId, correctedId);
        if (corrected.effectiveSlotKey != source.slotKey ||
            corrected.status != OutcomeReportStatus.submitted.name) {
          throw const OutcomeReportValidationException(
            'Only the current effective report can be corrected.',
          );
        }
        correctedEntries = await _effectiveContributionRows(corrected.id);
        if ((correctedEntries.isNotEmpty ||
                normalized.contributions.isNotEmpty) &&
            normalized.correctionReason == null) {
          throw const OutcomeReportValidationException(
            'Explain why this correction changes Actual.',
          );
        }
      }

      await _validateContributions(
        profileId: profileId,
        outcome: normalized.outcome!,
        contributions: normalized.contributions,
      );
      final now = clock.nowUtc();
      if (corrected != null) {
        await (database.update(
          database.outcomeReports,
        )..where((table) => table.id.equals(corrected!.id))).write(
          OutcomeReportsCompanion(
            status: Value<String>(OutcomeReportStatus.superseded.name),
            effectiveSlotKey: const Value<String?>(null),
            updatedAtUtc: Value<DateTime>(now),
          ),
        );
      }

      final existingDraft =
          await (database.select(database.outcomeReports)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.draftSlotKey.equals(source.slotKey),
                )
                ..limit(1))
              .getSingleOrNull();
      final submittedId = existingDraft?.id ?? normalized.id;
      if (existingDraft != null && existingDraft.id != normalized.id) {
        throw const OutcomeReportValidationException(
          'Resume the existing local Draft before submitting.',
        );
      }
      if (existingDraft == null) {
        await database
            .into(database.outcomeReports)
            .insert(
              _reportInsert(
                profileId: profileId,
                draft: normalized,
                source: source,
                status: OutcomeReportStatus.submitted,
                createdAtUtc: now,
                updatedAtUtc: now,
                effectiveSlotKey: source.slotKey,
                operationId: operationId,
                submittedAtUtc: now,
              ),
            );
      } else {
        await (database.update(
          database.outcomeReports,
        )..where((table) => table.id.equals(existingDraft.id))).write(
          _reportUpdate(
            draft: normalized,
            source: source,
            status: OutcomeReportStatus.submitted,
            updatedAtUtc: now,
            effectiveSlotKey: source.slotKey,
            operationId: operationId,
            submittedAtUtc: now,
          ),
        );
      }

      for (final oldEntry in correctedEntries) {
        final reversalId = OutcomeReportIdentity.reversalEntry(
          reportId: submittedId,
          originalEntryId: oldEntry.id,
        );
        await database
            .into(database.activityLedgerEntries)
            .insert(
              ActivityLedgerEntriesCompanion.insert(
                id: reversalId,
                profileId: profileId,
                sourceReportId: submittedId,
                entryType: ActivityLedgerEntryType.reversal.name,
                indicatorKey: oldEntry.indicatorKey,
                valueScaled: -oldEntry.valueScaled,
                valueScale: oldEntry.valueScale,
                unit: oldEntry.unit,
                activityDate: oldEntry.activityDate,
                ruleKey: oldEntry.ruleKey,
                idempotencyKey: reversalId,
                reversalOfEntryId: Value<String>(oldEntry.id),
                recordedAtUtc: now,
              ),
            );
      }
      await (database.delete(
        database.outcomeReportContributionDrafts,
      )..where((table) => table.reportId.equals(submittedId))).go();

      for (final contribution in normalized.contributions) {
        final entryId = OutcomeReportIdentity.ledgerEntry(
          reportId: submittedId,
          ruleKey: contribution.ruleKey,
          type: ActivityLedgerEntryType.contribution,
        );
        final replaced = correctedEntries
            .where(
              (row) =>
                  row.ruleKey == contribution.ruleKey ||
                  row.indicatorKey == contribution.indicatorKey,
            )
            .firstOrNull;
        await database
            .into(database.activityLedgerEntries)
            .insert(
              ActivityLedgerEntriesCompanion.insert(
                id: entryId,
                profileId: profileId,
                sourceReportId: submittedId,
                entryType: ActivityLedgerEntryType.contribution.name,
                indicatorKey: contribution.indicatorKey,
                valueScaled: contribution.value.scaledValue,
                valueScale: contribution.value.scale,
                unit: contribution.value.unit,
                activityDate: normalized.activityDate.iso8601,
                ruleKey: contribution.ruleKey,
                idempotencyKey: entryId,
                replacesEntryId: Value<String?>(replaced?.id),
                recordedAtUtc: now,
              ),
            );
      }

      await _applyRequiredTaskStatus(
        profileId: profileId,
        source: source,
        outcome: normalized.outcome!,
        operationId: operationId,
        now: now,
      );
      await writeGuard.beforeCommit();

      final reportRow = await _requireReportRow(profileId, submittedId);
      return ReportSubmissionResult(
        report: await _mapReport(reportRow),
        entries: await _entriesForReport(submittedId),
        unchanged: false,
      );
    });
  }

  @override
  Future<bool> clearSubmittedStatus({
    required String profileId,
    required OutcomeReportSource source,
    required String operationId,
    required String correctionReason,
  }) async {
    _validateUuid(operationId, 'status-clear operation');
    final canonicalSource = await _validateAndCanonicalizeSource(
      profileId,
      source,
    );
    return database.transaction(() async {
      final current =
          await (database.select(database.outcomeReports)
                ..where(
                  (table) =>
                      table.profileId.equals(profileId) &
                      table.effectiveSlotKey.equals(canonicalSource.slotKey),
                )
                ..limit(1))
              .getSingleOrNull();
      if (current == null) return false;

      final currentEntries = await _effectiveContributionRows(current.id);
      await writeGuard.beforeCommit();
      final now = clock.nowUtc();
      await (database.update(
        database.outcomeReports,
      )..where((table) => table.id.equals(current.id))).write(
        OutcomeReportsCompanion(
          status: Value<String>(OutcomeReportStatus.superseded.name),
          effectiveSlotKey: const Value<String?>(null),
          correctionReason: Value<String>(correctionReason),
          operationId: Value<String>(operationId),
          updatedAtUtc: Value<DateTime>(now),
        ),
      );
      for (final entry in currentEntries) {
        final reversalId = OutcomeReportIdentity.reversalEntry(
          reportId: current.id,
          originalEntryId: entry.id,
        );
        await database
            .into(database.activityLedgerEntries)
            .insert(
              ActivityLedgerEntriesCompanion.insert(
                id: reversalId,
                profileId: profileId,
                sourceReportId: current.id,
                entryType: ActivityLedgerEntryType.reversal.name,
                indicatorKey: entry.indicatorKey,
                valueScaled: -entry.valueScaled,
                valueScale: entry.valueScale,
                unit: entry.unit,
                activityDate: entry.activityDate,
                ruleKey: entry.ruleKey,
                idempotencyKey: reversalId,
                reversalOfEntryId: Value<String>(entry.id),
                recordedAtUtc: now,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
      return true;
    });
  }

  @override
  Future<IndicatorActual> readActual({
    required String profileId,
    required String indicatorKey,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) async {
    final definition =
        await (database.select(database.lifeIndicatorDefinitions)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.equals(indicatorKey),
              )
              ..limit(1))
            .getSingleOrNull();
    if (definition == null) {
      throw StateError('Life Goal not found');
    }
    final rows = await readLedgerHistory(
      profileId: profileId,
      indicatorKey: indicatorKey,
      startDate: startDate,
      endDate: endDate,
      effectiveOnly: false,
    );
    final scale = IndicatorUnitPolicy.allowedScale(definition.unit);
    var total = 0;
    for (final entry in rows) {
      if (entry.value.unit != definition.unit) {
        throw StateError('Ledger unit does not match its Life Goal');
      }
      total += _rescale(
        entry.value.scaledValue,
        fromScale: entry.value.scale,
        toScale: scale,
      );
    }
    return IndicatorActual(
      indicatorKey: indicatorKey,
      value: IndicatorValue(
        scaledValue: total,
        scale: scale,
        unit: definition.unit,
      ),
    );
  }

  @override
  Future<List<IndicatorActual>> rebuildActuals({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) async {
    final definitions = await readIndicatorOptions(profileId);
    return Future.wait(
      definitions.map(
        (definition) => readActual(
          profileId: profileId,
          indicatorKey: definition.key,
          startDate: startDate,
          endDate: endDate,
        ),
      ),
    );
  }

  @override
  Future<LedgerProjectionAudit> auditProjection(String profileId) async {
    final rows = await (database.select(
      database.activityLedgerEntries,
    )..where((table) => table.profileId.equals(profileId))).get();
    final ids = rows.map((row) => row.id).toSet();
    final sourceRules = <String>{};
    var issues = 0;
    for (final row in rows) {
      final key = '${row.sourceReportId}:${row.ruleKey}:${row.entryType}';
      if (!sourceRules.add(key)) {
        issues += 1;
      }
      if (row.entryType == ActivityLedgerEntryType.reversal.name) {
        final reversed = row.reversalOfEntryId;
        if (row.valueScaled >= 0 ||
            reversed == null ||
            !ids.contains(reversed)) {
          issues += 1;
        }
      } else if (row.valueScaled <= 0 || row.reversalOfEntryId != null) {
        issues += 1;
      }
    }
    return LedgerProjectionAudit(isConsistent: issues == 0, issueCount: issues);
  }

  Future<OutcomeReportSource> _validateAndCanonicalizeSource(
    String profileId,
    OutcomeReportSource source,
  ) async {
    final normalized = source.normalized();
    switch (normalized.type) {
      case OutcomeSourceType.task:
        final canonical = await readTaskSource(
          profileId: profileId,
          taskId: normalized.sourceId,
        );
        if (canonical == null) {
          throw StateError('Task source not found');
        }
        return canonical;
      case OutcomeSourceType.event:
        final originalDate = normalized.originalDate;
        final eventId = normalized.eventId;
        if (originalDate == null || eventId == null) {
          throw const OutcomeReportValidationException(
            'Event occurrence identity is incomplete.',
          );
        }
        final canonical = await readEventSource(
          profileId: profileId,
          eventId: eventId,
          originalDate: originalDate,
        );
        if (canonical == null ||
            canonical.occurrenceId != normalized.occurrenceId) {
          throw StateError('Event occurrence source not found');
        }
        return canonical;
      case OutcomeSourceType.manual:
        return normalized;
    }
  }

  Future<void> _validateContributions({
    required String profileId,
    required OutcomeKind outcome,
    required List<ContributionDraft> contributions,
  }) async {
    if (outcome == OutcomeKind.didNotHappen && contributions.isNotEmpty) {
      throw const OutcomeReportValidationException(
        'Did Not Attempt cannot create contributions.',
      );
    }
    final definitions = <String, LifeIndicatorDefinitionRow>{
      for (final row in await (database.select(
        database.lifeIndicatorDefinitions,
      )..where((table) => table.profileId.equals(profileId))).get())
        row.indicatorKey: row,
    };
    for (final contribution in contributions) {
      final definition = definitions[contribution.indicatorKey];
      if (definition == null) {
        throw const OutcomeReportValidationException(
          'Contribution indicator is not approved for this Local Profile.',
        );
      }
      if (definition.unit != contribution.value.unit) {
        throw const OutcomeReportValidationException(
          'Contribution unit does not match its Life Goal.',
        );
      }
      IndicatorUnitPolicy.validate(contribution.value);
    }
  }

  static bool _isContactEvent(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == SystemEventTypeKeys.meaningfulConnection ||
        (normalized != null && normalized.contains('contact'));
  }

  Future<void> _applyRequiredTaskStatus({
    required String profileId,
    required OutcomeReportSource source,
    required OutcomeKind outcome,
    required String operationId,
    required DateTime now,
  }) async {
    if (source.type != OutcomeSourceType.task) {
      return;
    }
    final task =
        await (database.select(database.plannerTasks)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(source.sourceId),
              )
              ..limit(1))
            .getSingleOrNull();
    // Every Task is intrinsically reportable. The persisted legacy flag stays
    // schema-compatible but cannot suppress the canonical Task report/status
    // lifecycle for older owner data.
    if (task == null) {
      return;
    }
    final target = outcome == OutcomeKind.completedHappened
        ? PlannerTaskStatus.completed.name
        : PlannerTaskStatus.incomplete.name;
    if (task.status == target) {
      return;
    }
    final contributionEngine = TaskGoalContributionEngine(database: database);
    final linkedType = await contributionEngine.resolve(
      profileId: profileId,
      goalId: task.goalId,
      allowArchived: true,
    );
    final changeId = const Uuid().v5(
      Namespace.url.value,
      'com.nexttransfer.rmplanner:report-task-status:'
      '$operationId:${task.id}:$target',
    );
    await database
        .into(database.taskStatusChanges)
        .insert(
          TaskStatusChangesCompanion.insert(
            id: changeId,
            profileId: profileId,
            taskId: task.id,
            operationId: operationId,
            fromStatus: task.status,
            toStatus: target,
            reason: const Value<String>('Structured outcome report'),
            // B3.2 (D2): the direct Goal link is not an Event Type, so this
            // status-change record carries no Event-Type snapshot for
            // Goal-linked contributions.  Goal identity lives in goal_id.
            activityTypeId: const Value<String?>(null),
            activityTypeStableKeySnapshot: const Value<String?>(null),
            activityTypeLabelSnapshot: const Value<String?>(null),
            changedAtUtc: now,
          ),
        );
    await (database.update(database.plannerTasks)..where(
          (table) =>
              table.profileId.equals(profileId) & table.id.equals(task.id),
        ))
        .write(
          PlannerTasksCompanion(
            status: Value<String>(target),
            updatedAtUtc: Value<DateTime>(now),
          ),
        );
    if (target == PlannerTaskStatus.completed.name) {
      await contributionEngine.reconcile(
        profileId: profileId,
        taskId: task.id,
        dueDate: task.dueDate == null ? null : PlannerDate.parse(task.dueDate!),
        linkedType: linkedType,
        changedAt: now,
      );
    } else {
      await contributionEngine.reverse(
        await contributionEngine.readActive(task.id),
        now,
      );
    }
  }

  OutcomeReportsCompanion _reportInsert({
    required String profileId,
    required OutcomeReportDraft draft,
    required OutcomeReportSource source,
    required OutcomeReportStatus status,
    required DateTime createdAtUtc,
    required DateTime updatedAtUtc,
    String? draftSlotKey,
    String? effectiveSlotKey,
    String? operationId,
    DateTime? submittedAtUtc,
  }) {
    return OutcomeReportsCompanion.insert(
      id: draft.id,
      profileId: profileId,
      sourceType: source.type.name,
      sourceId: source.sourceId,
      sourceLabel: source.label,
      sourceSlotKey: source.slotKey,
      eventId: Value<String?>(source.eventId),
      occurrenceId: Value<String?>(source.occurrenceId),
      originalDate: Value<String?>(source.originalDate?.iso8601),
      draftSlotKey: Value<String?>(draftSlotKey),
      effectiveSlotKey: Value<String?>(effectiveSlotKey),
      status: status.name,
      outcome: Value<String?>(draft.outcome?.name),
      activityDate: draft.activityDate.iso8601,
      factualValueScaled: Value<int?>(draft.factualValue?.scaledValue),
      factualValueScale: Value<int>(draft.factualValue?.scale ?? 0),
      factualValueUnit: Value<String?>(draft.factualValue?.unit),
      privateNotes: Value<String?>(draft.privateNotes),
      correctsReportId: Value<String?>(draft.correctsReportId),
      correctionReason: Value<String?>(draft.correctionReason),
      operationId: Value<String?>(operationId),
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc,
      submittedAtUtc: Value<DateTime?>(submittedAtUtc),
    );
  }

  OutcomeReportsCompanion _reportUpdate({
    required OutcomeReportDraft draft,
    required OutcomeReportSource source,
    required OutcomeReportStatus status,
    required DateTime updatedAtUtc,
    String? draftSlotKey,
    String? effectiveSlotKey,
    String? operationId,
    DateTime? submittedAtUtc,
  }) {
    return OutcomeReportsCompanion(
      sourceType: Value<String>(source.type.name),
      sourceId: Value<String>(source.sourceId),
      sourceLabel: Value<String>(source.label),
      sourceSlotKey: Value<String>(source.slotKey),
      eventId: Value<String?>(source.eventId),
      occurrenceId: Value<String?>(source.occurrenceId),
      originalDate: Value<String?>(source.originalDate?.iso8601),
      draftSlotKey: Value<String?>(draftSlotKey),
      effectiveSlotKey: Value<String?>(effectiveSlotKey),
      status: Value<String>(status.name),
      outcome: Value<String?>(draft.outcome?.name),
      activityDate: Value<String>(draft.activityDate.iso8601),
      factualValueScaled: Value<int?>(draft.factualValue?.scaledValue),
      factualValueScale: Value<int>(draft.factualValue?.scale ?? 0),
      factualValueUnit: Value<String?>(draft.factualValue?.unit),
      privateNotes: Value<String?>(draft.privateNotes),
      correctsReportId: Value<String?>(draft.correctsReportId),
      correctionReason: Value<String?>(draft.correctionReason),
      operationId: Value<String?>(operationId),
      updatedAtUtc: Value<DateTime>(updatedAtUtc),
      submittedAtUtc: Value<DateTime?>(submittedAtUtc),
    );
  }

  Future<OutcomeReportRow> _requireReportRow(
    String profileId,
    String reportId,
  ) async {
    final row =
        await (database.select(database.outcomeReports)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.id.equals(reportId),
              )
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      throw StateError('Outcome Report not found');
    }
    return row;
  }

  Future<OutcomeReport> _mapReport(OutcomeReportRow row) async {
    final contributions =
        await (database.select(database.activityLedgerEntries)..where(
              (table) =>
                  table.sourceReportId.equals(row.id) &
                  table.entryType.equals(
                    ActivityLedgerEntryType.contribution.name,
                  ),
            ))
            .get();
    final draftRows = await (database.select(
      database.outcomeReportContributionDrafts,
    )..where((table) => table.reportId.equals(row.id))).get();
    final persistedSource = OutcomeReportSource(
      type: OutcomeSourceType.values.byName(row.sourceType),
      sourceId: row.sourceId,
      label: row.sourceLabel,
      activityDate: PlannerDate.parse(row.activityDate),
      eventId: row.eventId,
      occurrenceId: row.occurrenceId,
      originalDate: row.originalDate == null
          ? null
          : PlannerDate.parse(row.originalDate!),
    );
    var source = persistedSource;
    if (persistedSource.type == OutcomeSourceType.event &&
        persistedSource.eventId != null &&
        persistedSource.originalDate != null) {
      final canonical = await readEventSource(
        profileId: row.profileId,
        eventId: persistedSource.eventId!,
        originalDate: persistedSource.originalDate!,
      );
      if (canonical != null) {
        source = OutcomeReportSource(
          type: persistedSource.type,
          sourceId: persistedSource.sourceId,
          label: persistedSource.label,
          activityDate: persistedSource.activityDate,
          eventId: persistedSource.eventId,
          occurrenceId: persistedSource.occurrenceId,
          originalDate: persistedSource.originalDate,
          eventTypeLabel: canonical.eventTypeLabel,
          isContactEvent: canonical.isContactEvent,
        );
      }
    }
    return OutcomeReport(
      id: row.id,
      profileId: row.profileId,
      source: source,
      status: OutcomeReportStatus.values.byName(row.status),
      outcome: row.outcome == null
          ? null
          : OutcomeKind.values.byName(row.outcome!),
      activityDate: PlannerDate.parse(row.activityDate),
      factualValue: row.factualValueScaled == null
          ? null
          : IndicatorValue(
              scaledValue: row.factualValueScaled!,
              scale: row.factualValueScale,
              unit: row.factualValueUnit!,
            ),
      privateNotes: row.privateNotes,
      correctsReportId: row.correctsReportId,
      correctionReason: row.correctionReason,
      createdAtUtc: row.createdAtUtc.toUtc(),
      updatedAtUtc: row.updatedAtUtc.toUtc(),
      submittedAtUtc: row.submittedAtUtc?.toUtc(),
      contributionCount: contributions.length,
      draftContributions: draftRows
          .map(
            (item) => ContributionDraft(
              ruleKey: item.ruleKey,
              indicatorKey: item.indicatorKey,
              value: IndicatorValue(
                scaledValue: item.valueScaled,
                scale: item.valueScale,
                unit: item.unit,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Future<List<ActivityLedgerEntry>> _entriesForReport(String reportId) async {
    final rows = await (database.select(
      database.activityLedgerEntries,
    )..where((table) => table.sourceReportId.equals(reportId))).get();
    final allRows = await database.select(database.activityLedgerEntries).get();
    final reversedIds = allRows
        .where((row) => row.reversalOfEntryId != null)
        .map((row) => row.reversalOfEntryId!)
        .toSet();
    return rows
        .map(
          (row) =>
              _mapLedgerEntry(row, isEffective: !reversedIds.contains(row.id)),
        )
        .toList(growable: false);
  }

  ActivityLedgerEntry _mapLedgerEntry(
    ActivityLedgerEntryRow row, {
    required bool isEffective,
  }) {
    return ActivityLedgerEntry(
      id: row.id,
      profileId: row.profileId,
      sourceReportId: row.sourceReportId,
      type: ActivityLedgerEntryType.values.byName(row.entryType),
      indicatorKey: row.indicatorKey,
      value: IndicatorValue(
        scaledValue: row.valueScaled,
        scale: row.valueScale,
        unit: row.unit,
      ),
      activityDate: PlannerDate.parse(row.activityDate),
      ruleKey: row.ruleKey,
      recordedAtUtc: row.recordedAtUtc.toUtc(),
      reversalOfEntryId: row.reversalOfEntryId,
      replacesEntryId: row.replacesEntryId,
      isEffective: isEffective,
    );
  }

  Future<List<ActivityLedgerEntryRow>> _effectiveContributionRows(
    String reportId,
  ) async {
    final rows =
        await (database.select(database.activityLedgerEntries)..where(
              (table) =>
                  table.sourceReportId.equals(reportId) &
                  table.entryType.equals(
                    ActivityLedgerEntryType.contribution.name,
                  ),
            ))
            .get();
    if (rows.isEmpty) {
      return const <ActivityLedgerEntryRow>[];
    }
    final reversals =
        await (database.select(database.activityLedgerEntries)..where(
              (table) =>
                  table.entryType.equals(
                    ActivityLedgerEntryType.reversal.name,
                  ) &
                  table.reversalOfEntryId.isIn(rows.map((row) => row.id)),
            ))
            .get();
    final reversedIds = reversals
        .map((row) => row.reversalOfEntryId)
        .nonNulls
        .toSet();
    return rows
        .where((row) => !reversedIds.contains(row.id))
        .toList(growable: false);
  }

  Future<CalendarEventExceptionRow?> _latestException(
    String eventId,
    String occurrenceId,
  ) {
    return (database.select(database.calendarEventExceptions)
          ..where(
            (table) =>
                table.eventId.equals(eventId) &
                table.occurrenceId.equals(occurrenceId),
          )
          ..orderBy(<OrderingTerm Function(CalendarEventExceptions)>[
            (table) => OrderingTerm.desc(table.createdAtUtc),
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  CalendarRecurrenceRule _recurrenceFromRow(CalendarEventRow row) {
    return calendarRecurrenceRuleFromStorage(
      frequencyName: row.recurrenceFrequency,
      endModeName: row.recurrenceEndMode,
      endDateIso: row.recurrenceEndDate,
      occurrenceCount: row.recurrenceCount,
      patternJson: row.recurrencePatternJson,
    );
  }

  static int _rescale(
    int value, {
    required int fromScale,
    required int toScale,
  }) {
    if (fromScale == toScale) {
      return value;
    }
    if (fromScale > toScale) {
      final divisor = _pow10(fromScale - toScale);
      if (value % divisor != 0) {
        throw StateError('Ledger precision exceeds the indicator precision');
      }
      return value ~/ divisor;
    }
    return value * _pow10(toScale - fromScale);
  }

  static int _pow10(int exponent) {
    var result = 1;
    for (var index = 0; index < exponent; index += 1) {
      result *= 10;
    }
    return result;
  }

  static void _validateUuid(String value, String label) {
    if (!Uuid.isValidUUID(fromString: value)) {
      throw OutcomeReportValidationException(
        'A $label requires a stable UUID.',
      );
    }
  }
}
