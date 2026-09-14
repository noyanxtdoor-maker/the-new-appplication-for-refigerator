import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/indicators/application/indicator_repository.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/domain/task_event_link.dart';
import 'package:uuid/uuid.dart';

final class DriftIndicatorRepository implements IndicatorRepository {
  const DriftIndicatorRepository({
    required this.database,
    required this.clock,
    required this.calendarEvents,
  });

  final AppDatabase database;
  final AppClock clock;
  final CalendarEventRepository calendarEvents;

  @override
  Stream<void> watchChanges(String profileId) {
    return database
        .tableUpdates(
          TableUpdateQuery.onAllTables(<ResultSetImplementation>[
            database.lifeIndicatorDefinitions,
            database.goals,
            database.goalActivities,
            database.goalOutboxOperations,
            database.weeklyIndicatorTargetRevisions,
            database.indicatorGoalRevisions,
            database.activityLedgerEntries,
            database.outcomeReports,
            database.plannerTasks,
            database.calendarEvents,
            database.calendarEventExceptions,
            database.taskEventLinks,
          ]),
        )
        .map((_) {});
  }

  @override
  Future<PlannerDate?> readNextTempleVisit({
    required String profileId,
    required PlannerDate today,
  }) {
    return _readNextTempleVisit(profileId: profileId, today: today);
  }

  @override
  Future<HomeIndicatorSnapshot> readHome({
    required String profileId,
    required IndicatorPeriod period,
    required PlannerDate today,
  }) async {
    if (database.schemaVersion >= 17) {
      await GoalBootstrap.ensure(database, profileId, nowUtc: clock.nowUtc());
    }
    final definitions =
        await (database.select(database.lifeIndicatorDefinitions)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(LifeIndicatorDefinitions)>[
                (table) => OrderingTerm.asc(table.position),
              ]))
            .get();
    final canonicalGoals = database.schemaVersion >= 17
        ? await (database.select(
            database.goals,
          )..where((table) => table.profileId.equals(profileId))).get()
        : const <GoalRow>[];
    final goalByIndicator = <String, GoalRow>{
      for (final goal in canonicalGoals)
        if (goal.status == GoalStatus.active.name && goal.indicatorKey != null)
          goal.indicatorKey!: goal,
    };
    // Definitions remain the durable WLI compatibility surface, but archived
    // canonical Goals must no longer render as Home Goal cards. The fallback
    // keeps pre-canonical databases readable while startup completes the
    // migration.
    final visibleDefinitions =
        database.schemaVersion >= 17 && canonicalGoals.isNotEmpty
        ? definitions
              .where(
                (definition) =>
                    goalByIndicator.containsKey(definition.indicatorKey),
              )
              .toList(growable: false)
        : definitions;
    final targets = await _latestTargets(profileId, period.start);
    final currentWeekPlanned =
        visibleDefinitions.isNotEmpty &&
        visibleDefinitions.every(
          (definition) => targets[definition.indicatorKey]?.state == 'explicit',
        );
    final scheduled = await _scheduledSources(
      profileId: profileId,
      period: period,
      today: today,
    );
    final staleKeys = await _staleIndicatorKeys(profileId);
    final nextTempleVisit = await _readNextTempleVisit(
      profileId: profileId,
      today: today,
    );
    IndicatorAmount? monthlyTempleActual;
    IndicatorTarget? monthlyTempleTarget;
    IndicatorGoalSnapshot? dailyJobApplications;
    final templeDefinition = visibleDefinitions
        .where((definition) => definition.indicatorKey == 'temple_visit')
        .firstOrNull;
    if (templeDefinition != null) {
      final monthly = await _readGoalSnapshot(
        profileId: profileId,
        indicatorKey: templeDefinition.indicatorKey,
        period: IndicatorGoalPeriod.monthly(today),
        today: today,
        definition: templeDefinition,
      );
      monthlyTempleActual = monthly.actual;
      monthlyTempleTarget = monthly.target;
    }
    final jobApplicationsDefinition = visibleDefinitions
        .where((definition) => definition.indicatorKey == 'job_applications')
        .firstOrNull;
    if (jobApplicationsDefinition != null) {
      dailyJobApplications = await _readGoalSnapshot(
        profileId: profileId,
        indicatorKey: jobApplicationsDefinition.indicatorKey,
        period: IndicatorGoalPeriod.daily(today),
        today: today,
        definition: jobApplicationsDefinition,
      );
    }
    final indicators = <LifeIndicatorSummary>[];
    for (final definition in visibleDefinitions) {
      try {
        final actual = await _readActual(
          profileId: profileId,
          definition: definition,
          period: period,
        );
        final sources =
            scheduled.sourcesByIndicator[definition.indicatorKey] ??
            const <ScheduledIndicatorSource>[];
        indicators.add(
          LifeIndicatorSummary(
            key: definition.indicatorKey,
            label:
                goalByIndicator[definition.indicatorKey]?.title ??
                definition.label,
            unit: definition.unit,
            position: definition.position,
            goalId: goalByIndicator[definition.indicatorKey]?.id,
            actual: actual,
            target: _mapTarget(targets[definition.indicatorKey]),
            scheduledPotential: _sumSources(sources, definition.unit),
            scheduledSources: sources,
            projectionState: staleKeys.contains(definition.indicatorKey)
                ? IndicatorProjectionState.stale
                : IndicatorProjectionState.current,
          ),
        );
      } on Object {
        indicators.add(
          LifeIndicatorSummary(
            key: definition.indicatorKey,
            label:
                goalByIndicator[definition.indicatorKey]?.title ??
                definition.label,
            unit: definition.unit,
            position: definition.position,
            goalId: goalByIndicator[definition.indicatorKey]?.id,
            actual: IndicatorAmount(
              scaledValue: 0,
              scale: IndicatorUnitPolicy.allowedScale(definition.unit),
              unit: definition.unit,
            ),
            target: _mapTarget(targets[definition.indicatorKey]),
            scheduledPotential: IndicatorAmount(
              scaledValue: 0,
              scale: IndicatorUnitPolicy.allowedScale(definition.unit),
              unit: definition.unit,
            ),
            scheduledSources: const <ScheduledIndicatorSource>[],
            projectionState: IndicatorProjectionState.failed,
            failureMessage: 'Projection unavailable. Other indicators remain.',
          ),
        );
      }
    }
    return HomeIndicatorSnapshot(
      period: period,
      indicators: indicators,
      overdueTaskCount: scheduled.overdueTaskCount,
      awaitingReportCount: scheduled.awaitingReportCount,
      nextTempleVisit: nextTempleVisit,
      currentWeekPlanned: currentWeekPlanned,
      monthlyTempleActual: monthlyTempleActual,
      monthlyTempleTarget: monthlyTempleTarget,
      dailyJobApplications: dailyJobApplications,
    );
  }

  @override
  Future<IndicatorDetail?> readDetail({
    required String profileId,
    required String indicatorKey,
    required IndicatorPeriod period,
    required PlannerDate today,
  }) async {
    final snapshot = await readHome(
      profileId: profileId,
      period: period,
      today: today,
    );
    final matches = snapshot.indicators.where(
      (indicator) => indicator.key == indicatorKey,
    );
    if (matches.isEmpty) {
      return null;
    }
    final rows =
        await (database.select(database.activityLedgerEntries)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.equals(indicatorKey) &
                    table.activityDate.isBiggerOrEqualValue(
                      period.start.iso8601,
                    ) &
                    table.activityDate.isSmallerOrEqualValue(
                      period.end.iso8601,
                    ),
              )
              ..orderBy(<OrderingTerm Function(ActivityLedgerEntries)>[
                (table) => OrderingTerm.desc(table.recordedAtUtc),
              ]))
            .get();
    final reportIds = rows.map((row) => row.sourceReportId).toSet();
    final reports = reportIds.isEmpty
        ? const <OutcomeReportRow>[]
        : await (database.select(
            database.outcomeReports,
          )..where((table) => table.id.isIn(reportIds))).get();
    final labels = <String, String>{
      for (final report in reports) report.id: report.sourceLabel,
    };
    return IndicatorDetail(
      summary: matches.single,
      period: period,
      contributionHistory: <IndicatorContributionHistoryItem>[
        for (final row in rows)
          IndicatorContributionHistoryItem(
            entryId: row.id,
            reportId: row.sourceReportId,
            sourceLabel: labels[row.sourceReportId] ?? 'Current Status',
            activityDate: PlannerDate.parse(row.activityDate),
            value: IndicatorAmount(
              scaledValue: row.valueScaled,
              scale: row.valueScale,
              unit: row.unit,
            ),
            isReversal: row.entryType == ActivityLedgerEntryType.reversal.name,
          ),
      ],
    );
  }

  @override
  Future<void> saveTarget({
    required String profileId,
    required IndicatorTargetRevisionDraft draft,
    int startDay = DateTime.monday,
  }) async {
    await saveGoal(
      profileId: profileId,
      startDay: startDay,
      draft: IndicatorGoalRevisionDraft(
        id: draft.id,
        operationId: draft.operationId,
        indicatorKey: draft.indicatorKey,
        period: IndicatorGoalPeriod.weekly(
          draft.period.start,
          startDay: startDay,
        ),
        value: draft.value,
      ),
    );
  }

  @override
  Future<void> saveGoal({
    required String profileId,
    required IndicatorGoalRevisionDraft draft,
    int startDay = DateTime.monday,
  }) async {
    if (!Uuid.isValidUUID(fromString: draft.id) ||
        !Uuid.isValidUUID(fromString: draft.operationId)) {
      throw StateError('Goal revisions require stable UUID identities');
    }
    await database.transaction(() async {
      final priorOperation =
          await (database.select(database.indicatorGoalRevisions)
                ..where((table) => table.operationId.equals(draft.operationId))
                ..limit(1))
              .getSingleOrNull();
      if (priorOperation != null) {
        return;
      }
      if (draft.period.type == IndicatorGoalPeriodType.weekly) {
        final plan =
            await (database.select(database.weeklyPlans)
                  ..where(
                    (table) =>
                        table.profileId.equals(profileId) &
                        table.periodStartDate.equals(
                          draft.period.start.iso8601,
                        ),
                  )
                  ..limit(1))
                .getSingleOrNull();
        if (plan != null &&
            (plan.state == 'reviewed' || plan.state == 'historical')) {
          throw StateError(
            'Reviewed and historical Weekly Plan targets are read-only',
          );
        }
      }
      final definition = await _definition(profileId, draft.indicatorKey);
      final canonicalGoal = database.schemaVersion >= 17
          ? await (database.select(database.goals)
                  ..where(
                    (table) =>
                        table.profileId.equals(profileId) &
                        table.indicatorKey.equals(draft.indicatorKey),
                  )
                  ..limit(1))
                .getSingleOrNull()
          : null;
      final value = draft.value;
      if (value != null &&
          (value.scaledValue < 0 ||
              value.unit != definition.unit ||
              value.scale !=
                  IndicatorUnitPolicy.allowedScale(definition.unit))) {
        throw StateError('Goal value does not match the indicator unit');
      }
      final prior = await _latestGoal(
        profileId: profileId,
        indicatorKey: draft.indicatorKey,
        period: draft.period,
      );
      await database
          .into(database.indicatorGoalRevisions)
          .insert(
            IndicatorGoalRevisionsCompanion.insert(
              id: draft.id,
              profileId: profileId,
              goalId: Value<String?>(canonicalGoal?.id),
              indicatorKey: draft.indicatorKey,
              periodType: draft.period.type.name,
              periodStartDate: draft.period.start.iso8601,
              periodEndDate: draft.period.end.iso8601,
              state: value == null ? 'notSet' : 'explicit',
              valueScaled: Value<int?>(value?.scaledValue),
              valueScale:
                  value?.scale ??
                  IndicatorUnitPolicy.allowedScale(definition.unit),
              unit: definition.unit,
              supersedesRevisionId: Value<String?>(prior?.id),
              operationId: draft.operationId,
              createdAtUtc: clock.nowUtc(),
            ),
          );
    });
  }

  @override
  Future<IndicatorGoalSnapshot> readGoal({
    required String profileId,
    required String indicatorKey,
    required IndicatorGoalPeriod period,
    required PlannerDate today,
  }) async {
    final definition = await _definition(profileId, indicatorKey);
    return _readGoalSnapshot(
      profileId: profileId,
      indicatorKey: indicatorKey,
      period: period,
      today: today,
      definition: definition,
    );
  }

  @override
  Future<List<IndicatorGoalSnapshot>> readGoalHistory({
    required String profileId,
    required String indicatorKey,
    required IndicatorGoalPeriodType periodType,
    required PlannerDate anchor,
    required PlannerDate today,
    int startDay = DateTime.monday,
  }) async {
    final periods = <IndicatorGoalPeriod>[];
    switch (periodType) {
      case IndicatorGoalPeriodType.daily:
        for (var offset = 4; offset >= 0; offset -= 1) {
          periods.add(IndicatorGoalPeriod.daily(anchor.addDays(-offset)));
        }
      case IndicatorGoalPeriodType.weekly:
        final current = IndicatorGoalPeriod.weekly(
          anchor,
          startDay: startDay,
        );
        for (var offset = 4; offset >= 0; offset -= 1) {
          periods.add(
            IndicatorGoalPeriod.weekly(
              current.start.addDays(-7 * offset),
              startDay: startDay,
            ),
          );
        }
      case IndicatorGoalPeriodType.monthly:
        final cursor = IndicatorGoalPeriod.monthly(anchor);
        for (var offset = 4; offset >= 0; offset -= 1) {
          final month = DateTime(
            cursor.start.year,
            cursor.start.month - offset,
            1,
          );
          periods.add(
            IndicatorGoalPeriod.monthly(PlannerDate.fromDateTime(month)),
          );
        }
    }
    final definition = await _definition(profileId, indicatorKey);
    return <IndicatorGoalSnapshot>[
      for (final period in periods)
        await _readGoalSnapshot(
          profileId: profileId,
          indicatorKey: indicatorKey,
          period: period,
          today: today,
          definition: definition,
        ),
    ];
  }

  @override
  Future<void> renameIndicator({
    required String profileId,
    required String indicatorKey,
    required String label,
  }) async {
    final normalizedLabel = label.trim();
    if (normalizedLabel.isEmpty) {
      throw ArgumentError.value(label, 'label', 'Label is required.');
    }
    await database.transaction(() async {
      final definitions = await (database.select(
        database.lifeIndicatorDefinitions,
      )..where((table) => table.profileId.equals(profileId))).get();
      final definition = definitions
          .where((row) => row.indicatorKey == indicatorKey)
          .firstOrNull;
      if (definition == null) {
        throw StateError('Life Goal not found.');
      }
      final duplicate = definitions.any(
        (row) =>
            row.indicatorKey != indicatorKey &&
            row.label.trim().toLowerCase() == normalizedLabel.toLowerCase(),
      );
      if (duplicate) {
        throw StateError('Life Goal names must be unique.');
      }
      await (database.update(database.lifeIndicatorDefinitions)..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.indicatorKey.equals(indicatorKey),
          ))
          .write(
            LifeIndicatorDefinitionsCompanion(
              label: Value<String>(normalizedLabel),
            ),
          );
    });
  }

  @override
  Future<List<IndicatorTargetRevision>> readTargetHistory({
    required String profileId,
    required String indicatorKey,
    required PlannerDate periodStart,
  }) async {
    final rows =
        await (database.select(database.indicatorGoalRevisions)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.indicatorKey.equals(indicatorKey) &
                  table.periodType.equals(IndicatorGoalPeriodType.weekly.name) &
                  table.periodStartDate.equals(periodStart.iso8601),
            ))
            .get();
    final byId = <String, IndicatorGoalRevisionRow>{
      for (final row in rows) row.id: row,
    };
    final superseded = rows
        .map((row) => row.supersedesRevisionId)
        .whereType<String>()
        .toSet();
    IndicatorGoalRevisionRow? current;
    for (final row in rows) {
      if (!superseded.contains(row.id)) {
        current = row;
        break;
      }
    }
    final ordered = <IndicatorGoalRevisionRow>[];
    while (current != null) {
      ordered.add(current);
      current = current.supersedesRevisionId == null
          ? null
          : byId[current.supersedesRevisionId];
    }
    return ordered
        .map(
          (row) => IndicatorTargetRevision(
            id: row.id,
            target: row.state == 'explicit'
                ? IndicatorTarget.explicit(
                    IndicatorAmount(
                      scaledValue: row.valueScaled!,
                      scale: row.valueScale,
                      unit: row.unit,
                    ),
                  )
                : const IndicatorTarget.notSet(),
            createdAtUtc: row.createdAtUtc.toUtc(),
          ),
        )
        .toList(growable: false);
  }

  Future<IndicatorAmount> _readActual({
    required String profileId,
    required LifeIndicatorDefinitionRow definition,
    required IndicatorPeriod period,
  }) async {
    final rows =
        await (database.select(database.activityLedgerEntries)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.indicatorKey.equals(definition.indicatorKey) &
                  table.activityDate.isBiggerOrEqualValue(
                    period.start.iso8601,
                  ) &
                  table.activityDate.isSmallerOrEqualValue(period.end.iso8601),
            ))
            .get();
    final scale = IndicatorUnitPolicy.allowedScale(definition.unit);
    var total = 0;
    for (final row in rows) {
      if (row.unit != definition.unit) {
        throw StateError('Ledger unit mismatch');
      }
      total += _rescale(row.valueScaled, row.valueScale, scale);
    }
    return IndicatorAmount(
      scaledValue: total,
      scale: scale,
      unit: definition.unit,
    );
  }

  Future<LifeIndicatorDefinitionRow> _definition(
    String profileId,
    String indicatorKey,
  ) async {
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
    return definition;
  }

  Future<IndicatorGoalSnapshot> _readGoalSnapshot({
    required String profileId,
    required String indicatorKey,
    required IndicatorGoalPeriod period,
    required PlannerDate today,
    required LifeIndicatorDefinitionRow definition,
  }) async {
    final actual = await _readActual(
      profileId: profileId,
      definition: definition,
      period: period.indicatorPeriod,
    );
    final target = _mapGoalTarget(
      await _latestGoal(
        profileId: profileId,
        indicatorKey: indicatorKey,
        period: period,
      ),
    );
    return IndicatorGoalSnapshot(
      indicatorKey: indicatorKey,
      period: period,
      actual: actual,
      target: target,
    );
  }

  Future<IndicatorGoalRevisionRow?> _latestGoal({
    required String profileId,
    required String indicatorKey,
    required IndicatorGoalPeriod period,
  }) async {
    final rows =
        await (database.select(database.indicatorGoalRevisions)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.indicatorKey.equals(indicatorKey) &
                    table.periodType.equals(period.type.name) &
                    table.periodStartDate.equals(period.start.iso8601),
              )
              ..orderBy(<OrderingTerm Function(IndicatorGoalRevisions)>[
                (table) => OrderingTerm.desc(table.createdAtUtc),
                (table) => OrderingTerm.desc(table.id),
              ]))
            .get();
    final supersededIds = rows
        .map((row) => row.supersedesRevisionId)
        .whereType<String>()
        .toSet();
    return rows.where((row) => !supersededIds.contains(row.id)).firstOrNull;
  }

  IndicatorTarget _mapGoalTarget(IndicatorGoalRevisionRow? row) {
    if (row == null || row.state == 'notSet' || row.valueScaled == null) {
      return const IndicatorTarget.notSet();
    }
    return IndicatorTarget.explicit(
      IndicatorAmount(
        scaledValue: row.valueScaled!,
        scale: row.valueScale,
        unit: row.unit,
      ),
    );
  }

  Future<Map<String, IndicatorGoalRevisionRow>> _latestTargets(
    String profileId,
    PlannerDate start,
  ) async {
    final rows =
        await (database.select(database.indicatorGoalRevisions)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.periodType.equals(
                      IndicatorGoalPeriodType.weekly.name,
                    ) &
                    table.periodStartDate.equals(start.iso8601),
              )
              ..orderBy(<OrderingTerm Function(IndicatorGoalRevisions)>[
                (table) => OrderingTerm.desc(table.createdAtUtc),
                (table) => OrderingTerm.desc(table.id),
              ]))
            .get();
    final supersededIds = rows
        .map((row) => row.supersedesRevisionId)
        .whereType<String>()
        .toSet();
    final latest = <String, IndicatorGoalRevisionRow>{};
    for (final row in rows) {
      if (!supersededIds.contains(row.id)) {
        latest.putIfAbsent(row.indicatorKey, () => row);
      }
    }
    return latest;
  }

  IndicatorTarget _mapTarget(IndicatorGoalRevisionRow? row) {
    if (row == null || row.state == 'notSet' || row.valueScaled == null) {
      return const IndicatorTarget.notSet();
    }
    return IndicatorTarget.explicit(
      IndicatorAmount(
        scaledValue: row.valueScaled!,
        scale: row.valueScale,
        unit: row.unit,
      ),
    );
  }

  Future<_ScheduledRead> _scheduledSources({
    required String profileId,
    required IndicatorPeriod period,
    required PlannerDate today,
  }) async {
    final result = <String, List<ScheduledIndicatorSource>>{};
    final links =
        await (database.select(database.taskEventLinks)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.status.equals(TaskEventLinkStatus.active.name),
            ))
            .get();
    final taskRows = await (database.select(
      database.plannerTasks,
    )..where((table) => table.profileId.equals(profileId))).get();
    var overdueTasks = 0;
    for (final row in taskRows) {
      final due = row.dueDate == null ? null : PlannerDate.parse(row.dueDate!);
      if (row.status == PlannerTaskStatus.incomplete.name &&
          due != null &&
          due.compareTo(today) < 0) {
        overdueTasks += 1;
      }
      final rule = ScheduledPotentialRule.tryParse(row.contributionRuleKey);
      if (row.status != PlannerTaskStatus.incomplete.name ||
          due == null ||
          due.compareTo(today) < 0 ||
          !period.contains(due) ||
          rule == null ||
          links.any(
            (link) =>
                link.taskId == row.id &&
                link.canonicalSource == TaskEventCanonicalSource.event.name,
          )) {
        continue;
      }
      result
          .putIfAbsent(rule.indicatorKey, () => [])
          .add(
            ScheduledIndicatorSource(
              sourceType: 'task',
              sourceId: row.id,
              label: row.title,
              date: due,
              value: rule.value,
              explanation: 'Explicit Task planning rule',
            ),
          );
    }

    var awaitingReports = 0;
    final eventRows = await (database.select(
      database.calendarEvents,
    )..where((table) => table.profileId.equals(profileId))).get();
    for (final row in eventRows) {
      final recurrence = calendarRecurrenceRuleFromStorage(
        frequencyName: row.recurrenceFrequency,
        endModeName: row.recurrenceEndMode,
        endDateIso: row.recurrenceEndDate,
        occurrenceCount: row.recurrenceCount,
        patternJson: row.recurrencePatternJson,
      );
      final start = PlannerDate.parse(row.startDate);
      for (
        var date = period.start;
        date.compareTo(period.end) <= 0;
        date = date.addDays(1)
      ) {
        if (recurrence.occurrenceIndexOn(startDate: start, targetDate: date) ==
            null) {
          continue;
        }
        final occurrence = await calendarEvents.readOccurrence(
          profileId: profileId,
          eventId: row.id,
          originalDate: date,
        );
        if (occurrence == null) {
          continue;
        }
        if (occurrence.isAwaitingReport(
          nowUtc: clock.nowUtc(),
          displayToday: today,
        )) {
          awaitingReports += 1;
        }
        final rule = ScheduledPotentialRule.tryParse(
          occurrence.contributionRuleKey,
        );
        final excludedByCanonicalTask = links.any(
          (link) =>
              link.eventId == row.id &&
              link.canonicalSource == TaskEventCanonicalSource.task.name &&
              (link.scope == TaskEventLinkScope.series.name ||
                  link.occurrenceId == occurrence.id),
        );
        if (occurrence.status != CalendarEventStatus.scheduled ||
            occurrence.displayDate.compareTo(today) < 0 ||
            !period.contains(occurrence.displayDate) ||
            (occurrence.isBackupAppointment &&
                occurrence.backupForEventId != null) ||
            occurrence.isAwaitingReport(
              nowUtc: clock.nowUtc(),
              displayToday: today,
            ) ||
            rule == null ||
            excludedByCanonicalTask) {
          continue;
        }
        result
            .putIfAbsent(rule.indicatorKey, () => [])
            .add(
              ScheduledIndicatorSource(
                sourceType: 'event',
                sourceId: occurrence.id,
                label: occurrence.title,
                date: occurrence.displayDate,
                value: rule.value,
                explanation: 'Explicit Calendar Event planning rule',
              ),
            );
      }
    }
    return _ScheduledRead(
      sourcesByIndicator: result,
      overdueTaskCount: overdueTasks,
      awaitingReportCount: awaitingReports,
    );
  }

  /// M3 P02 — the next applicable Temple visit, resolved through ONE scoped
  /// canonical range projection instead of a per-date/per-occurrence
  /// readOccurrence walk (M0 baseline: 2,203 SQL statements / ~311 ms for a
  /// single daily Temple series).
  ///
  /// Eligibility law is preserved EXACTLY from the previous path:
  /// - Temple source rows only (profile + SystemEventTypeIds.templeVisit);
  /// - occurrence must be `scheduled`;
  /// - occurrence must NOT be a replacement (`replacementEventId == null`);
  /// - visible displayDate inside today..today+366 inclusive;
  /// - the earliest such displayDate wins;
  /// - a source with no eligible occurrence contributes nothing.
  Future<PlannerDate?> _readNextTempleVisit({
    required String profileId,
    required PlannerDate today,
  }) async {
    if (calendarEvents is! CalendarEventScopedRangeSource) {
      return _readNextTempleVisitLegacy(profileId: profileId, today: today);
    }
    final horizon = today.addDays(366);
    final scoped = calendarEvents as CalendarEventScopedRangeSource;
    // Source-scoped range over the EXISTING today..today+366 window.  The
    // canonical projection resolves recurrence, moved exceptions, reports,
    // and timezone display dates once, in bounded batches.
    final items = await scoped.readRangeForEvents(
      profileId: profileId,
      startDate: today,
      endDate: horizon,
      eventIds: await templeSourceIds(profileId),
    );
    PlannerDate? earliest;
    for (final item in items) {
      if (item.activityTypeId != SystemEventTypeIds.templeVisit ||
          item.state != PlannerEventState.scheduled ||
          item.replacementId != null) {
        continue;
      }
      final displayDate = item.date;
      if (displayDate.compareTo(today) < 0 ||
          displayDate.compareTo(horizon) > 0) {
        continue;
      }
      final currentEarliest = earliest;
      if (currentEarliest == null ||
          displayDate.compareTo(currentEarliest) < 0) {
        earliest = displayDate;
      }
    }
    return earliest;
  }

  /// The Temple source IDs for one profile, from ONE bounded source query.
  /// Returns null only when the table read itself fails — never an empty
  /// substitute for unknown truth (an empty set is a valid "no Temple
  /// sources" answer and yields an empty scoped projection).
  Future<Set<String>?> templeSourceIds(String profileId) async {
    try {
      final rows =
          await (database.select(database.calendarEvents)..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.activityTypeId.equals(SystemEventTypeIds.templeVisit),
              ))
              .get();
      return <String>{for (final row in rows) row.id};
    } on Object {
      return null;
    }
  }

  /// The pre-M3 per-occurrence walk, retained ONLY for sources that cannot
  /// serve the scoped range.  Semantics are frozen exactly as shipped.
  Future<PlannerDate?> _readNextTempleVisitLegacy({
    required String profileId,
    required PlannerDate today,
  }) async {
    final rows =
        await (database.select(database.calendarEvents)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.activityTypeId.equals(SystemEventTypeIds.templeVisit),
            ))
            .get();
    final horizon = today.addDays(366);
    PlannerDate? earliest;
    for (final row in rows) {
      final start = PlannerDate.parse(row.startDate);
      final recurrence = calendarRecurrenceRuleFromStorage(
        frequencyName: row.recurrenceFrequency,
        endModeName: row.recurrenceEndMode,
        endDateIso: row.recurrenceEndDate,
        occurrenceCount: row.recurrenceCount,
        patternJson: row.recurrencePatternJson,
      );
      final firstDate = recurrence.isRecurring
          ? (start.compareTo(today) > 0 ? start : today)
          : start;
      if (firstDate.compareTo(today) < 0 || firstDate.compareTo(horizon) > 0) {
        continue;
      }
      if (recurrence.isRecurring) {
        for (
          var date = firstDate;
          date.compareTo(horizon) <= 0;
          date = date.addDays(1)
        ) {
          if (recurrence.occurrenceIndexOn(
                startDate: start,
                targetDate: date,
              ) ==
              null) {
            continue;
          }
          final occurrence = await calendarEvents.readOccurrence(
            profileId: profileId,
            eventId: row.id,
            originalDate: date,
          );
          if (occurrence == null ||
              occurrence.status != CalendarEventStatus.scheduled ||
              occurrence.replacementEventId != null ||
              occurrence.displayDate.compareTo(today) < 0 ||
              occurrence.displayDate.compareTo(horizon) > 0) {
            continue;
          }
          final currentEarliest = earliest;
          if (currentEarliest == null ||
              occurrence.displayDate.compareTo(currentEarliest) < 0) {
            earliest = occurrence.displayDate;
          }
        }
        continue;
      }
      final occurrence = await calendarEvents.readOccurrence(
        profileId: profileId,
        eventId: row.id,
        originalDate: firstDate,
      );
      final currentEarliest = earliest;
      if (occurrence != null &&
          occurrence.status == CalendarEventStatus.scheduled &&
          occurrence.replacementEventId == null &&
          occurrence.displayDate.compareTo(today) >= 0 &&
          occurrence.displayDate.compareTo(horizon) <= 0 &&
          (currentEarliest == null ||
              occurrence.displayDate.compareTo(currentEarliest) < 0)) {
        earliest = occurrence.displayDate;
      }
    }
    return earliest;
  }

  Future<Set<String>> _staleIndicatorKeys(String profileId) async {
    final rows = await (database.select(
      database.activityLedgerEntries,
    )..where((table) => table.profileId.equals(profileId))).get();
    final ids = rows.map((row) => row.id).toSet();
    return <String>{
      for (final row in rows)
        if ((row.entryType == ActivityLedgerEntryType.reversal.name &&
                (row.reversalOfEntryId == null ||
                    !ids.contains(row.reversalOfEntryId))) ||
            (row.entryType != ActivityLedgerEntryType.reversal.name &&
                row.valueScaled <= 0))
          row.indicatorKey,
    };
  }

  IndicatorAmount _sumSources(
    List<ScheduledIndicatorSource> sources,
    String unit,
  ) {
    final scale = IndicatorUnitPolicy.allowedScale(unit);
    var total = 0;
    for (final source in sources) {
      if (source.value.unit != unit) {
        throw StateError('Scheduled source unit mismatch');
      }
      total += _rescale(source.value.scaledValue, source.value.scale, scale);
    }
    return IndicatorAmount(scaledValue: total, scale: scale, unit: unit);
  }

  int _rescale(int value, int from, int to) {
    if (from == to) {
      return value;
    }
    if (from < to) {
      var multiplier = 1;
      for (var i = from; i < to; i += 1) {
        multiplier *= 10;
      }
      return value * multiplier;
    }
    var divisor = 1;
    for (var i = to; i < from; i += 1) {
      divisor *= 10;
    }
    if (value % divisor != 0) {
      throw StateError('Value precision is not compatible');
    }
    return value ~/ divisor;
  }
}

final class _ScheduledRead {
  const _ScheduledRead({
    required this.sourcesByIndicator,
    required this.overdueTaskCount,
    required this.awaitingReportCount,
  });

  final Map<String, List<ScheduledIndicatorSource>> sourcesByIndicator;
  final int overdueTaskCount;
  final int awaitingReportCount;
}
