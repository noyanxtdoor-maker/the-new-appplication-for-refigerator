import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/indicators/application/indicator_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';

abstract interface class WeeklyPlanningWriteGuard {
  Future<void> beforeCommit();
}

final class AllowWeeklyPlanningWrites implements WeeklyPlanningWriteGuard {
  const AllowWeeklyPlanningWrites();

  @override
  Future<void> beforeCommit() async {}
}

final class DriftWeeklyPlanningRepository
    implements
        WeeklyPlanningRepository,
        WeeklyPlanningProfileTimeZoneSource,
        WeeklyReviewCompletionSource {
  const DriftWeeklyPlanningRepository({
    required this.database,
    required this.clock,
    required this.identifiers,
    required this.timeZones,
    required this.indicators,
    this.writeGuard = const AllowWeeklyPlanningWrites(),
  });

  final AppDatabase database;
  final AppClock clock;
  final IdentifierSource identifiers;
  final IanaCalendarEventTimeZones timeZones;
  final IndicatorRepository indicators;
  final WeeklyPlanningWriteGuard writeGuard;

  @override
  Future<PlannerDate> todayForProfile(String profileId) async {
    final zone = await _profileTimeZone(profileId);
    return PlannerDate.fromDateTime(
      timeZones.utcToWall(value: clock.nowUtc(), timeZoneId: zone),
    );
  }

  @override
  Future<WeeklyPlan> openOrCreate({
    required String profileId,
    required PlannerDate date,
    int startDay = DateTime.monday,
  }) async {
    final zone = await _profileTimeZone(profileId);
    final period = WeeklyPeriod.containing(date, startDay: startDay);
    final existing = await _rowForPeriod(profileId, period.start);
    if (existing != null) {
      return _mapPlan(existing);
    }

    final now = clock.nowUtc();
    await database.transaction(() async {
      await database
          .into(database.weeklyPlans)
          .insert(
            WeeklyPlansCompanion.insert(
              id: identifiers.nextUuid(),
              profileId: profileId,
              periodStartDate: period.start.iso8601,
              periodEndDate: period.end.iso8601,
              timeZoneId: zone,
              state: WeeklyPlanState.draft.name,
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      await writeGuard.beforeCommit();
    });

    return _mapPlan((await _rowForPeriod(profileId, period.start))!);
  }

  @override
  Future<WeeklyPlan?> readPlanForPeriod({
    required String profileId,
    required PlannerDate periodStart,
  }) async {
    final row = await _rowForPeriod(profileId, periodStart);
    return row == null ? null : _mapPlan(row);
  }

  @override
  Future<bool> periodExists({
    required String profileId,
    required PlannerDate periodStart,
  }) async {
    final row = await _rowForPeriod(profileId, periodStart);
    return row != null;
  }

  @override
  Future<void> ensurePeriod({
    required String profileId,
    required PlannerDate periodStart,
    int startDay = DateTime.monday,
  }) async {
    // Lightweight establishment: identical canonical row semantics to
    // [openOrCreate] but without the rich projection (_mapPlan / readHome).
    final zone = await _profileTimeZone(profileId);
    final period = WeeklyPeriod.containing(periodStart, startDay: startDay);
    final now = clock.nowUtc();
    await database.transaction(() async {
      // The existence check lives INSIDE the transaction so concurrent
      // ensures serialize and coalesce onto one row (drift serializes
      // transactions per connection; the unique index is schema metadata).
      final existing = await _rowForPeriod(profileId, period.start);
      if (existing != null) {
        return;
      }
      await database
          .into(database.weeklyPlans)
          .insert(
            WeeklyPlansCompanion.insert(
              id: identifiers.nextUuid(),
              profileId: profileId,
              periodStartDate: period.start.iso8601,
              periodEndDate: period.end.iso8601,
              timeZoneId: zone,
              state: WeeklyPlanState.draft.name,
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      await writeGuard.beforeCommit();
    });
  }

  @override
  Future<WeeklyPlan?> readPlan({
    required String profileId,
    required String planId,
  }) async {
    final row = await _planRow(profileId, planId);
    return row == null ? null : _mapPlan(row);
  }

  @override
  Future<List<WeeklyPlan>> readHistory(String profileId) async {
    final rows =
        await (database.select(database.weeklyPlans)
              ..where((table) => table.profileId.equals(profileId))
              ..orderBy(<OrderingTerm Function(WeeklyPlans)>[
                (table) => OrderingTerm.desc(table.periodStartDate),
              ]))
            .get();
    final plans = <WeeklyPlan>[];
    for (final row in rows) {
      plans.add(await _mapPlan(row));
    }
    return plans;
  }

  @override
  Future<String> timeZoneForProfile(String profileId) =>
      _profileTimeZone(profileId);

  @override
  Future<WeeklyPlan> completeReview({
    required String profileId,
    required String planId,
  }) async {
    final existing = await _planRow(profileId, planId);
    if (existing == null) {
      throw const WeeklyPlanningValidationException('Weekly Plan not found.');
    }
    if (existing.state != WeeklyPlanState.reviewed.name &&
        existing.state != WeeklyPlanState.historical.name) {
      final now = clock.nowUtc();
      await database.transaction(() async {
        await (database.update(database.weeklyPlans)..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.id.equals(planId) &
                  table.state.isNotIn(<String>[
                    WeeklyPlanState.reviewed.name,
                    WeeklyPlanState.historical.name,
                  ]),
            ))
            .write(
              WeeklyPlansCompanion(
                state: Value<String>(WeeklyPlanState.reviewed.name),
                reviewCompletedAtUtc: Value<DateTime>(now),
                updatedAtUtc: Value<DateTime>(now),
              ),
            );
        // M8: reminder repair intent commits with the review completion.
        await ReminderRecoveryRequest.markDirty(
          database: database,
          profileId: profileId,
          nowUtc: now,
        );
        await writeGuard.beforeCommit();
      });
    }
    return _mapPlan((await _planRow(profileId, planId))!);
  }

  Future<String> _profileTimeZone(String profileId) async {
    final profile =
        await (database.select(database.localProfiles)
              ..where((table) => table.id.equals(profileId))
              ..limit(1))
            .getSingleOrNull();
    if (profile == null) {
      throw const WeeklyPlanningValidationException(
        'A Local Profile is required for Weekly Planning.',
      );
    }
    final stored = profile.timeZoneId;
    if (stored != null && timeZones.isValid(stored)) {
      return stored;
    }
    final resolved = timeZones.displayTimeZoneId;
    await (database.update(
      database.localProfiles,
    )..where((table) => table.id.equals(profileId))).write(
      LocalProfilesCompanion(
        timeZoneId: Value<String?>(resolved),
        updatedAtUtc: Value<DateTime>(clock.nowUtc()),
      ),
    );
    return resolved;
  }

  Future<WeeklyPlanRow?> _rowForPeriod(String profileId, PlannerDate start) {
    return (database.select(database.weeklyPlans)
          ..where(
            (table) =>
                table.profileId.equals(profileId) &
                table.periodStartDate.equals(start.iso8601),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<WeeklyPlanRow?> _planRow(String profileId, String planId) {
    return (database.select(database.weeklyPlans)
          ..where(
            (table) =>
                table.profileId.equals(profileId) & table.id.equals(planId),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  Future<WeeklyPlan> _mapPlan(WeeklyPlanRow row) async {
    final period = WeeklyPeriod(
      start: PlannerDate.parse(row.periodStartDate),
      end: PlannerDate.parse(row.periodEndDate),
    );
    final today = await todayForProfile(row.profileId);
    final snapshot = await indicators.readHome(
      profileId: row.profileId,
      period: period.indicatorPeriod,
      today: today,
    );
    final indicatorsForPlan = snapshot.indicators
        .map(
          (indicator) => WeeklyIndicatorReview(
            indicatorKey: indicator.key,
            label: indicator.label,
            actual: indicator.actual,
            target: indicator.target,
            scheduled: indicator.scheduledPotential,
          ),
        )
        .toList(growable: false);
    return WeeklyPlan(
      id: row.id,
      profileId: row.profileId,
      period: period,
      timeZoneId: row.timeZoneId,
      storedState: _stateFromName(row.state),
      indicators: indicatorsForPlan,
      createdAtUtc: row.createdAtUtc,
      updatedAtUtc: row.updatedAtUtc,
      reviewCompletedAtUtc: row.reviewCompletedAtUtc,
    );
  }

  // M6 forward-rollback (Phase A): the M6B weekly_plan_goal_memberships
  // first-materialization snapshot writer was removed. The v46 table remains
  // defined/dormant for owner-DB compatibility; no new membership rows are
  // written and weekly rendering is restored to the pre-M6 dynamic view.

  WeeklyPlanState _stateFromName(String value) {
    return WeeklyPlanState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => WeeklyPlanState.draft,
    );
  }
}
