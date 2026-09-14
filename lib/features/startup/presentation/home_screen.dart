import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/shell/global_drawer_controller.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/indicators/application/indicator_providers.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_creation.dart';
import 'package:rmplanner/features/planner/presentation/contextual_create_fab.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';

/// Returns the month-specific label shown beside the canonical monthly Goal.
///
/// The label is intentionally derived at render time. It is not a Goal title,
/// persisted field, activity entry, or outbox payload.
String homeMonthGoalLabel(PlannerDate today, Locale locale) {
  final month = DateFormat.LLLL(
    locale.toLanguageTag(),
  ).format(today.asLocalDate);
  return '$month Goal';
}

final class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

final class _HomeScreenState extends ConsumerState<HomeScreen> {
  // The Home quick control runs one coalescing persistence drain per canonical
  // Goal. Rapid taps update the shared desired target instead of opening
  // competing read-modify-write operations.
  final Map<String, Future<void>> _dailyTargetQueues = <String, Future<void>>{};

  // Optimistic Today's Goal target overlay. The visible target reacts in the
  // same frame as the tap while the canonical read-modify-write queue runs
  // behind it; entries are pruned once the repository value catches up.
  // Keys are the canonical Goal IDs (only the daily Goal uses the stepper).
  final Map<String, int> _optimisticDailyTargets = <String, int>{};

  /// Canonical daily target captured when the first pending tap landed.
  /// Re-seeded whenever the canonical value moves independently, so an
  /// external edit cannot make the optimistic value stale forever.
  final Map<String, int> _optimisticBases = <String, int>{};

  @override
  Widget build(BuildContext context) {
    final plannerToday = ref.watch(plannerDateSourceProvider).today();
    final startOfWeek = ref.watch(startOfWeekProvider);
    // A2: form period-family keys only after the initial persisted
    // start-of-week read is confirmed, so a provisional Monday-keyed family
    // never starts for a configured non-Monday week.
    final startOfWeekReady = ref.watch(
      startOfWeekInitialReadProvider,
    ).hasValue;
    final PlannerDate? periodStart = startOfWeekReady
        ? IndicatorPeriod.currentWeek(
            plannerToday,
            startDay: startOfWeek,
          ).start
        : null;
    final canonicalPlan = periodStart == null
        ? null
        : ref.watch(goalPlanningProvider(periodStart));
    // Plan-established signal: a WeeklyPlans row exists for the exact
    // resolved current period.  Read-only; never creates a row here.
    final established = periodStart == null
        ? null
        : ref.watch(weeklyPlanEstablishedProvider(periodStart)).value;
    _reconcileOptimisticTargets(canonicalPlan?.value);
    final planValue = canonicalPlan?.value;
    final optimisticDailyTarget = planValue?.daily == null
        ? null
        : _optimisticDailyTargets[planValue!.daily!.goal.id];
    // MP-18: tri-state (loading / confirmed date / confirmed true-null) so
    // the Temple card never renders "Set Schedule" while the schedule is
    // merely unresolved or refreshing.
    final nextTempleVisit = ref.watch(nextTempleVisitControllerProvider);
    return Scaffold(
      backgroundColor: AppTheme.surfaceOf(context),
      appBar: AppBar(
        key: const Key('home-app-bar'),
        backgroundColor: AppTheme.surfaceOf(context),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        toolbarHeight: 66,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: SizedBox(
            height: 1,
            child: ColoredBox(color: AppTheme.outlineOf(context)),
          ),
        ),
        title: const Text('Home', key: Key('home-title')),
        leading: Builder(
          builder: (innerContext) => IconButton(
            key: const Key('home-hamburger'),
            tooltip: 'Open global navigation',
            onPressed: () => GlobalDrawerScope.of(innerContext).open(),
            icon: const Icon(Icons.menu),
          ),
        ),
        actions: <Widget>[
          // Pack 3: the Home bell opens the canonical local Messages screen,
          // never Android notification permissions.
          IconButton(
            key: const Key('home-messages'),
            tooltip: 'Messages',
            onPressed: () => context.push(RoutePaths.messages),
            icon: const Icon(Icons.notifications_none_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: RefreshIndicator(
            onRefresh: () async {
              final start = periodStart;
              if (start != null) {
                ref.invalidate(goalPlanningProvider(start));
              }
              // MP-18: the controller retains the last confirmed value while
              // the refreshed read is in flight (no Set Schedule flash).
              await ref.read(
                nextTempleVisitControllerProvider.notifier,
              ).refresh();
            },
            child: ListView(
              key: const Key('home-indicator-list'),
              padding: EdgeInsets.fromLTRB(
                18,
                18,
                18,
                _homeBottomInset(context),
              ),
              children: <Widget>[
                _SectionHeader(
                  // Planner Polish Delta 2: the visible Home heading is
                  // "Life Goals".  Domain, provider, and database identifiers
                  // keep the canonical WLI naming.
                  title: 'Life Goals',
                  onViewAll: () {
                    final start = periodStart;
                    if (start != null) {
                      _openWeeklyPlanning(context, ref, start);
                    }
                  },
                  viewAllKey: const Key('home-wli-view-all'),
                ),
                const SizedBox(height: 6),
                _CanonicalHomePlan(
                  plan: canonicalPlan,
                  established: established,
                  monthGoalLabel: _monthGoalLabel(context, plannerToday),
                  optimisticDailyTarget: optimisticDailyTarget,
                  nextTempleVisit: nextTempleVisit,
                  onOpenWeeklyPlanning: () {
                    final start = periodStart;
                    if (start != null) {
                      _openWeeklyPlanning(context, ref, start);
                    }
                  },
                  onOpenGoal: (progress) =>
                      _openGoalById(context, progress.goal.id),
                  onOpenTempleSchedule: () =>
                      _openTempleSchedule(context, ref, plannerToday),
                  onAdjustDailyTarget: (progress, delta) {
                    final start = periodStart;
                    if (start == null) {
                      return;
                    }
                    _adjustDailyTarget(
                      ref,
                      progress,
                      delta: delta,
                      today: plannerToday,
                      periodStart: start,
                    );
                  },
                ),
                const SizedBox(height: 22),
                // R5 (owner 2026-08-16): Pathways is deferred; the Active
                // Pathways Home section (fabricated milestone content) is
                // hidden until a real Pathways foundation is authorized. The
                // domain/data/routes remain untouched.
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: ContextualCreateFab(
        destination: CreateActionDestination.home,
        onSelected: (action) => _handleCreate(context, ref, action),
      ),
    );
  }

  static double _homeBottomInset(BuildContext context) {
    final navigationHeight =
        NavigationBarTheme.of(context).height ?? kBottomNavigationBarHeight;
    const fabDiameter = 56.0;
    const fabBottomMargin = 16.0;
    const breathingRoom = 24.0;
    return math.max(
      breathingRoom,
      navigationHeight +
          MediaQuery.viewPaddingOf(context).bottom +
          fabDiameter +
          fabBottomMargin +
          breathingRoom,
    );
  }

  /// Opens the current-period Goal Planning flow immediately.  The destination
  /// owns idempotent plan establishment; Start Planning / View All / the Goal
  /// Planning button all converge here.  Historical weeks are never created.
  static void _openWeeklyPlanning(
    BuildContext context,
    WidgetRef ref,
    PlannerDate start,
  ) {
    unawaited(
      context.push(RoutePaths.weeklyPlanningFor(start)).then((_) {
        if (context.mounted) {
          ref.invalidate(weeklyPlanEstablishedProvider(start));
        }
      }),
    );
  }

  static void _openGoalById(BuildContext context, String goalId) {
    unawaited(context.push(RoutePaths.goalEdit(goalId)));
  }

  static String _monthGoalLabel(BuildContext context, PlannerDate today) {
    return homeMonthGoalLabel(today, Localizations.localeOf(context));
  }

  /// Drop optimistic entries whose canonical value has caught up. Called from
  /// [build] after watching the canonical plan; mutating the maps without
  /// [setState] is safe because the rendered value is identical either way.
  void _reconcileOptimisticTargets(GoalPlanningSnapshot? plan) {
    final daily = plan?.daily;
    if (daily == null) {
      return;
    }
    final goalId = daily.goal.id;
    final optimistic = _optimisticDailyTargets[goalId];
    if (optimistic == null) {
      return;
    }
    // The active drain owns the overlay until it has observed the last tap.
    // A canonical emission for an intermediate write must not discard a newer
    // desired value that is still waiting to be persisted.
    if (_dailyTargetQueues.containsKey(goalId)) {
      return;
    }
    final canonical = daily.dailyTarget.value?.scaledValue;
    final base = _optimisticBases[goalId];
    final canonicalCaughtUp = canonical != null && canonical == optimistic;
    final canonicalMovedElsewhere =
        canonical != null && base != null && canonical != base;
    if (canonicalCaughtUp || canonicalMovedElsewhere) {
      _optimisticDailyTargets.remove(goalId);
      _optimisticBases.remove(goalId);
    }
  }

  /// Immediate Today's Goal stepper.
  ///
  /// The visible target changes on the same frame as the tap (optimistic
  /// overlay) while the canonical read-modify-write queue persists safely
  /// behind it. Taps are serialized per Goal, never lost, and never turn
  /// into duplicate repository operations; the optimistic value is pruned
  /// once the repository value catches up, and a failed write rolls the
  /// display back to the canonical value.
  void _adjustDailyTarget(
    WidgetRef ref,
    GoalProgress progress, {
    required int delta,
    required PlannerDate today,
    required PlannerDate periodStart,
  }) {
    final goalId = progress.goal.id;
    final canonical = progress.dailyTarget.value?.scaledValue ?? 0;
    final storedBase = _optimisticBases[goalId];
    final displayed = _optimisticDailyTargets[goalId];
    // Re-seed the base whenever the canonical value moved independently of
    // our pending taps (an external edit or a restored plan).
    final base = storedBase != null && canonical == storedBase
        ? storedBase
        : canonical;
    final visibleTarget = displayed ?? base;
    final updated = math.max(0, visibleTarget + delta);
    if (updated == visibleTarget) {
      // Clamped at the zero minimum; nothing visible to change.
      return;
    }
    setState(() {
      _optimisticBases[goalId] = base;
      _optimisticDailyTargets[goalId] = updated;
    });

    if (_dailyTargetQueues.containsKey(goalId)) {
      return;
    }
    final next = _persistDailyTarget(
      ref,
      goalId: goalId,
      today: today,
    );
    final handled = next.catchError((Object error, StackTrace stackTrace) {
      debugPrint('[NextTransfer] home_daily_target_write_failed');
      // Honest rollback: the canonical store did not move, so drop the
      // optimistic overlay and reconcile from the repository.
      if (mounted) {
        setState(() {
          _optimisticDailyTargets.remove(goalId);
          _optimisticBases.remove(goalId);
        });
      }
      ref.invalidate(goalPlanningProvider(periodStart));
      ref.invalidate(activeGoalsProvider);
    });
    _dailyTargetQueues[goalId] = handled;
    unawaited(
      handled.then<void>((_) {
        if (identical(_dailyTargetQueues[goalId], handled)) {
          unawaited(_dailyTargetQueues.remove(goalId));
        }
      }),
    );
  }

  /// Persists the latest displayed target for one Goal. Rapid taps update the
  /// shared optimistic value, so a burst is coalesced into the fewest durable
  /// writes possible without dropping the final requested value.
  Future<void> _persistDailyTarget(
    WidgetRef ref, {
    required String goalId,
    required PlannerDate today,
  }) async {
    final repository = ref.read(goalRepositoryProvider);
    while (true) {
      final latest = await repository.readProgress(
        profileId: ref.read(goalProfileIdProvider),
        goalId: goalId,
        today: today,
        startDay: ref.read(startOfWeekProvider),
      );
      final desired = _optimisticDailyTargets[goalId];
      if (latest == null || desired == null) {
        return;
      }

      final existingDaily = latest.dailyTarget.value;
      final current = existingDaily?.scaledValue ?? 0;
      if (current == desired) {
        return;
      }
      final unit =
          existingDaily?.unit ?? latest.weeklyTarget.value?.unit ?? 'count';
      final scale =
          existingDaily?.scale ?? latest.weeklyTarget.value?.scale ?? 0;
      await repository.saveGoal(
        profileId: ref.read(goalProfileIdProvider),
        goalId: latest.goal.id,
        title: latest.goal.title,
        iconId: latest.goal.iconId,
        targets: GoalTargets(
          daily: IndicatorAmount(
            scaledValue: desired,
            scale: scale,
            unit: unit,
          ),
          weekly: latest.weeklyTarget.value,
          monthly: latest.monthlyTarget.value,
        ),
        today: today,
        startDay: ref.read(startOfWeekProvider),
      );
      if (_optimisticDailyTargets[goalId] == desired) {
        return;
      }
    }
  }

  static void _openTempleSchedule(
    BuildContext context,
    WidgetRef ref,
    PlannerDate date,
  ) {
    unawaited(
      launchCalendarEventCreation<void>(
        context,
        ref,
        CalendarEventCreationContext(
          source: 'home-temple-schedule',
          destinationPath: RoutePaths.calendarEventCreate,
          date: date,
          indicatorKey: 'temple_visit',
        ),
      ),
    );
  }

  void _handleCreate(
    BuildContext context,
    WidgetRef ref,
    ContextualCreateAction action,
  ) {
    final today = PlannerDate.fromDateTime(DateTime.now());
    switch (action) {
      case ContextualCreateAction.event:
        unawaited(
          launchCalendarEventCreation<void>(
            context,
            ref,
            CalendarEventCreationContext(
              source: 'home-fab',
              destinationPath: RoutePaths.calendarEventCreate,
              date: today,
            ),
          ),
        );
      case ContextualCreateAction.task:
        unawaited(
          context.push('${RoutePaths.taskCreate}?date=${today.iso8601}'),
        );
    }
  }
}

final class _CanonicalHomePlan extends StatelessWidget {
  const _CanonicalHomePlan({
    required this.plan,
    required this.established,
    required this.monthGoalLabel,
    required this.nextTempleVisit,
    required this.onOpenWeeklyPlanning,
    required this.onOpenGoal,
    required this.onOpenTempleSchedule,
    required this.onAdjustDailyTarget,
    this.optimisticDailyTarget,
  });

  /// Null while the start-of-week preference is still being confirmed, in
  /// which case no period family has been formed yet (A2).
  final AsyncValue<GoalPlanningSnapshot>? plan;

  /// True when a WeeklyPlans row exists for the exact resolved current period;
  /// null while the read-only existence check is still loading (so the Home
  /// never flashes Start Planning for an already-established period).
  final bool? established;
  final String monthGoalLabel;
  final NextTempleVisitState nextTempleVisit;
  final int? optimisticDailyTarget;
  final VoidCallback onOpenWeeklyPlanning;
  final ValueChanged<GoalProgress> onOpenGoal;
  final VoidCallback onOpenTempleSchedule;
  final void Function(GoalProgress progress, int delta) onAdjustDailyTarget;

  @override
  Widget build(BuildContext context) {
    final plan = this.plan;
    if (plan == null) {
      // A2: start-of-week readiness pending — honest section skeleton, no
      // fabricated names, actuals, targets, or established state.
      return const _LifeGoalsSkeleton();
    }
    return plan.when(
      skipLoadingOnReload: true,
      loading: () => const _LifeGoalsSkeleton(),
      error: (error, stackTrace) => const SizedBox(
        key: Key('home-canonical-plan-error'),
        height: 96,
        child: Center(child: Text('Life Goals unavailable.')),
      ),
      data: (value) {
        if (established == null) {
          return const _LifeGoalsSkeleton();
        }
        final hasActiveGoals =
            value.daily != null ||
            value.weekly.isNotEmpty ||
            value.monthly != null;
        // Unestablished period: hide the Life Goal card grid, keep the
        // section header + View All above, and show centered Start Planning.
        // Established-but-empty is treated the same defensive way.
        if (!established! || !hasActiveGoals) {
          return Align(
            alignment: Alignment.center,
            child: _StartPlanningButton(onPressed: onOpenWeeklyPlanning),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _CanonicalIndicatorGrid(
              plan: value,
              monthGoalLabel: monthGoalLabel,
              optimisticDailyTarget: optimisticDailyTarget,
              nextTempleVisit: nextTempleVisit,
              onOpenGoal: onOpenGoal,
              onOpenTempleSchedule: onOpenTempleSchedule,
              onAdjustDailyTarget: onAdjustDailyTarget,
            ),
            const SizedBox(height: 16),
            // The visible pill stays compact (118-134 x 34-38) while the outer
            // hit area keeps a minimum 48 dp touch target.
            SizedBox(
              key: const Key('weekly-targets-hit-area'),
              height: 48,
              child: Center(
                child: OutlinedButton(
                  key: const Key('weekly-targets-button'),
                  onPressed: onOpenWeeklyPlanning,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(126, 36),
                    fixedSize: const Size(126, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(
                      fontFamily: 'Roboto',
                      fontSize: 14,
                      height: 18 / 14,
                      fontWeight: FontWeight.w500,
                    ),
                    foregroundColor: AppTheme.onFillTextOf(context, 0.70),
                    side: BorderSide(color: AppTheme.outlineOf(context), width: 1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(19),
                    ),
                  ),
                  child: const Text('Goal Planning'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Honest first-load placeholder for the Life Goals section (A2): the same
/// card-grid geometry as the confirmed content but with NO fabricated Goal
/// names, actuals, targets, established state, or numbers.  Rendered while
/// the start-of-week preference is being confirmed or while the genuine
/// initial period family has no confirmed snapshot yet.
final class _LifeGoalsSkeleton extends StatelessWidget {
  const _LifeGoalsSkeleton();

  @override
  Widget build(BuildContext context) {
    final block = AppTheme.blockOf(context);
    // HR-02: the skeleton mirrors the approved special-row structure — a
    // full-width daily card with a right gray inset, two compact 2x2 rows,
    // then a full-width Temple/monthly card with a right gray inset.
    return Column(
      key: const Key('home-life-goals-skeleton'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _skeletonWideWithInset(block),
        const SizedBox(height: 6),
        _skeletonPair(block),
        const SizedBox(height: 6),
        _skeletonPair(block),
        const SizedBox(height: 6),
        _skeletonWideWithInset(block),
        const SizedBox(height: 16),
        Center(
          child: Container(
            width: 126,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: AppTheme.outlineOf(context)),
            ),
          ),
        ),
      ],
    );
  }

  static Widget _skeletonCard(Color block) {
    return Container(
      height: 76,
      decoration: BoxDecoration(
        color: block,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }

  static Widget _skeletonWideWithInset(Color block) {
    return Container(
      height: 76,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: block,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: block,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Right gray inset placeholder (Today's / August Goal inset).
          Container(
            width: 140,
            decoration: BoxDecoration(
              color: block,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _skeletonPair(Color block) {
    return SizedBox(
      height: 76,
      child: Row(
        children: <Widget>[
          Expanded(child: _skeletonCard(block)),
          const SizedBox(width: 10),
          Expanded(child: _skeletonCard(block)),
        ],
      ),
    );
  }
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.onViewAll,
    required this.viewAllKey,
  });

  final String title;
  final VoidCallback onViewAll;
  final Key viewAllKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: 30,
          child: Row(
            children: <Widget>[
              Expanded(child: Text(title, style: AppTypography.sectionTitle)),
              TextButton(
                key: viewAllKey,
                onPressed: onViewAll,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 30),
                  padding: EdgeInsets.zero,
                  textStyle: AppTypography.button,
                  foregroundColor: Theme.of(context).colorScheme.primary,
                ),
                child: const Text('View All'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        const Divider(height: 1),
      ],
    );
  }
}

final class _StartPlanningButton extends StatelessWidget {
  const _StartPlanningButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('home-start-weekly-planning'),
      height: 42,
      width: 160,
      child: Center(
        child: OutlinedButton(
          key: const Key('weekly-targets-button'),
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.onFillTextOf(context, 1.0),
            fixedSize: const Size(160, 40),
            side: BorderSide(color: AppTheme.outlineOf(context)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            textStyle: AppTypography.button,
          ),
          child: const Text('Start Planning'),
        ),
      ),
    );
  }
}

final class _CanonicalIndicatorGrid extends StatelessWidget {
  const _CanonicalIndicatorGrid({
    required this.plan,
    required this.monthGoalLabel,
    required this.nextTempleVisit,
    required this.onOpenGoal,
    required this.onOpenTempleSchedule,
    required this.onAdjustDailyTarget,
    this.optimisticDailyTarget,
  });

  final GoalPlanningSnapshot plan;
  final String monthGoalLabel;
  final NextTempleVisitState nextTempleVisit;
  final int? optimisticDailyTarget;
  final ValueChanged<GoalProgress> onOpenGoal;
  final VoidCallback onOpenTempleSchedule;
  final void Function(GoalProgress progress, int delta) onAdjustDailyTarget;

  // HR-01: the approved Home Life Goals layout is COMPACT HORIZONTAL cards
  // only — every row is a pair of half-width cards.  Row 1 is the daily Goal
  // card next to the compact Today's Goal card; the weekly grid is compact
  // icon+text pairs; the bottom row is the temple/monthly Goal card next to
  // the compact August Goal card.  Nothing stacks vertically and no card
  // grows tall, so Goal Planning and Active Pathways appear much earlier.
  static const double _cardHeight = 76;
  static const double _rowGap = 10;

  @override
  Widget build(BuildContext context) {
    final daily = plan.daily;
    final monthly = plan.monthly;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (daily != null) ...<Widget>[
          SizedBox(
            height: _cardHeight,
            child: _goalCard(
              context,
              daily,
              // HI-02 (painted-bounds audit): Home Life Goal icons are the
              // largest pair that preserves the 76dp card height (top/Temple
              // 64, middle 60) — the painted-art matrix proved a 20% visible
              // gain over HI-01 (see the HI-02+GP-01 forensic audit).
              iconSize: 64,
              // HR-02 (approved mockup): the daily Goal card is ONE full-width
              // white card — [icon] [title + ratio] [OPAQUE GRAY Today's Goal
              // inset] on a single horizontal row.  The inset holds the
              // Today's Goal label/value AND the +/- quick controls; nothing
              // floats loose on the white card.
              trailing: _buildTodayTrailing(context, daily),
            ),
          ),
          if (plan.weekly.isNotEmpty || monthly != null)
            const SizedBox(height: 6),
        ],
        for (var row = 0; row < plan.weekly.length; row += 2) ...<Widget>[
          SizedBox(
            height: _cardHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child:
                      _goalCard(context, plan.weekly[row], iconSize: 60),
                ),
                if (row + 1 < plan.weekly.length) ...<Widget>[
                  const SizedBox(width: _rowGap),
                  Expanded(
                    child: _goalCard(
                      context,
                      plan.weekly[row + 1],
                      iconSize: 60,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (row + 2 < plan.weekly.length || monthly != null)
            const SizedBox(height: 6),
        ],
        if (monthly != null) ...<Widget>[
          SizedBox(
            height: _cardHeight,
            // HR-02 (approved mockup): Temple Visit + August Goal are ONE
            // full-width white card — [larger Temple icon] [title + Next
            // Visit / Set Schedule] [OPAQUE GRAY August Goal inset].  No more
            // two half-width bottom cards.
            child: _goalCard(
              context,
              monthly,
              iconSize: 64,
              secondaryLabel:
                  monthly.goal.indicatorKey == 'temple_visit'
                  ? _templeSecondaryLabel(context, nextTempleVisit)
                  : null,
              onSecondaryTap:
                  monthly.goal.indicatorKey == 'temple_visit' &&
                      nextTempleVisit.isResolvedNull
                  ? onOpenTempleSchedule
                  : null,
              hideSecondaryLine:
                  monthly.goal.indicatorKey == 'temple_visit' &&
                      !nextTempleVisit.hasConfirmedValue &&
                      !nextTempleVisit.isResolvedNull,
              trailing: _AugustGoalInset(
                label: monthGoalLabel,
                value: _ratio(
                  monthly.monthlyActual,
                  monthly.monthlyTarget,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _goalCard(
    BuildContext context,
    GoalProgress progress, {
    double iconSize = 36,
    String? secondaryLabel,
    VoidCallback? onSecondaryTap,
    bool hideSecondaryLine = false,
    Widget? trailing,
  }) {
    return _IndicatorCard(
      indicator: _summaryFor(progress),
      goal: progress.goal,
      iconSize: iconSize,
      secondaryLabel: secondaryLabel,
      onSecondaryTap: onSecondaryTap,
      hideSecondaryLine: hideSecondaryLine,
      trailing: trailing,
      onTap: () => onOpenGoal(progress),
    );
  }

  /// MP-18 tri-state label for the Temple card secondary line:
  /// confirmed date -> Next Visit; confirmed true-null -> Set Schedule;
  /// unresolved/first-load -> null (neutral empty line, never Set Schedule).
  String? _templeSecondaryLabel(
    BuildContext context,
    NextTempleVisitState state,
  ) {
    final value = state.value;
    if (value != null) {
      return 'Next Visit: ${_formatNextVisit(context, value)}';
    }
    if (state.isResolvedNull) {
      return 'Set Schedule';
    }
    return null;
  }

  /// HR-02: the Today's Goal inset — one OPAQUE neutral-gray rounded surface
  /// at the right of the daily Goal card containing the label/value AND the
  /// +/- quick controls.  Nothing floats loose on the white outer card.
  Widget _buildTodayTrailing(BuildContext context, GoalProgress daily) {
    return _TodayGoalInset(
      value: _dailyAsideValue(daily, optimisticDailyTarget),
      dailyTargetIsZero: _dailyTargetIsZero(daily, optimisticDailyTarget),
      onMinus: () => onAdjustDailyTarget(daily, -1),
      onPlus: () => onAdjustDailyTarget(daily, 1),
    );
  }

  LifeIndicatorSummary _summaryFor(GoalProgress progress) {
    final target = progress.weeklyTarget;
    final unit = target.value?.unit ?? progress.weeklyActual.unit;
    return LifeIndicatorSummary(
      // The rendered Home identity belongs to the canonical Goal row, not
      // the legacy indicator definition.  This is what lets a replacement
      // Goal occupy the same role without inheriting the default Goal's
      // identity or a stale indicator snapshot.
      key: 'goal-${progress.goal.id}',
      label: progress.goal.title,
      unit: unit,
      position: progress.goal.activeSlotIndex ?? 0,
      goalId: progress.goal.id,
      actual: progress.weeklyActual,
      target: target,
      scheduledPotential: IndicatorAmount(
        scaledValue: 0,
        scale: progress.weeklyActual.scale,
        unit: unit,
      ),
      scheduledSources: const <ScheduledIndicatorSource>[],
      projectionState: IndicatorProjectionState.current,
    );
  }

  String _ratio(IndicatorAmount actual, IndicatorTarget target) {
    return '${actual.display}/${target.value?.display ?? '0'}';
  }

  /// Renders the Today's Goal ratio. When an optimistic target is pending it
  /// is formatted with the canonical target's scale/unit so the visible value
  /// changes on the same frame as the tap without fabricating progress.
  String _dailyAsideValue(GoalProgress progress, int? optimisticTarget) {
    final target = progress.dailyTarget.value;
    final targetDisplay = optimisticTarget == null
        ? target?.display ?? '0'
        : IndicatorAmount(
            scaledValue: optimisticTarget,
            scale: target?.scale ?? 0,
            unit: target?.unit ?? 'count',
          ).display;
    return '${progress.dailyActual.display}/$targetDisplay';
  }

  bool _dailyTargetIsZero(GoalProgress progress, int? optimisticTarget) {
    final value =
        optimisticTarget ?? progress.dailyTarget.value?.scaledValue ?? 0;
    return value == 0;
  }

  String _formatNextVisit(BuildContext context, PlannerDate date) {
    return MaterialLocalizations.of(
      context,
    ).formatShortMonthDay(date.asLocalDate);
  }
}

final class _IndicatorCard extends StatelessWidget {
  const _IndicatorCard({
    required this.indicator,
    required this.goal,
    required this.iconSize,
    required this.onTap,
    this.secondaryLabel,
    this.onSecondaryTap,
    this.hideSecondaryLine = false,
    this.trailing,
  });

  final LifeIndicatorSummary indicator;
  final Goal? goal;
  final double iconSize;
  final VoidCallback onTap;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryTap;

  /// MP-18: when true the card renders NO secondary line (used for the Temple
  /// card's unresolved/first-load state so it never flashes "Set Schedule"
  /// or the monthly ratio while the schedule is merely pending).
  final bool hideSecondaryLine;

  /// HR-01: optional right-side content rendered after the title/ratio column
  /// (the daily Goal card's compact Today's Goal block + quick controls).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      key: Key(
        'home-indicator-goal-${goal?.id ?? indicator.goalId ?? indicator.key}',
      ),
      margin: EdgeInsets.zero,
      // POLISH-01: Light Goal cards sit on the semantic near-white surface
      // (never the gray canvas slab); Dark keeps the accepted transparent
      // card behavior.
      color: Theme.of(context).brightness == Brightness.dark
          ? Colors.transparent
          : AppTheme.cardOf(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppTheme.cardBorderOf(context)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: _content(context),
          ),
        ),
      ),
    );

    // Keep the pre-Pack-1 selector as a render-box-sized compatibility alias
    // for existing tests and automation.  It is not used for data binding or
    // Goal lookup; the Card itself is always keyed by the Goal identity.
    final legacyIndicatorKey = goal?.indicatorKey;
    final keyedCard = legacyIndicatorKey == null
        ? card
        : SizedBox(key: Key('home-indicator-$legacyIndicatorKey'), child: card);
    // HR-01: the card fills its half-width grid cell; the outer row forces
    // the compact 76 dp height.
    return SizedBox(width: double.infinity, child: keyedCard);
  }

  /// HR-01 compact horizontal card: [icon] [title + value/date] on one row.
  Widget _content(BuildContext context) {
    final showScheduleButton =
        secondaryLabel == 'Set Schedule' && onSecondaryTap != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        // HR-01 Home-only icon proportions (compact 36 / wide-monthly 40);
        // all other GI-02 call sites keep their exact 2x sizes.
        _goalIcon(size: iconSize, context: context),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                indicator.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Roboto',
                  fontSize: 13,
                  height: 16 / 13,
                  fontWeight: FontWeight.w400,
                ),
              ),
              if (showScheduleButton)
                TextButton(
                  key: const Key('home-temple-schedule'),
                  onPressed: onSecondaryTap,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.centerLeft,
                    foregroundColor: Theme.of(context).colorScheme.primary,
                  ),
                  child: const Text(
                    'Set Schedule',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontFamily: 'Roboto',
                      fontSize: 13,
                      height: 16 / 13,
                    ),
                  ),
                )
              else if (hideSecondaryLine)
                const SizedBox.shrink()
              else
                Text(
                  secondaryLabel ??
                      _homeRatioText(indicator.actual, indicator.target),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: secondaryLabel == null
                      ? TextStyle(
                          fontFamily: 'Roboto',
                          fontSize: 21,
                          height: 23 / 21,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : const TextStyle(
                          fontFamily: 'Roboto',
                          fontSize: 11,
                          height: 14 / 11,
                          fontWeight: FontWeight.w400,
                        ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );
  }

  Widget _goalIcon({required double size, required BuildContext context}) {
    return GoalIcon(
      iconId: goal?.iconId,
      size: size,
      semanticLabel: '${indicator.label} goal icon',
      fallbackIcon: goalIconFallbackForRole(goal?.role),
      // R1 (2026-08-16): the null-iconId fallback uses the raw-art blue in
      // BOTH themes - never Theme.primary (Light navy vs Dark periwinkle
      // previously made the same icon render different colors per theme).
      color: AppTheme.goalIconFallbackBlue,
    );
  }
}

/// HR-02: the Today's Goal inset — one OPAQUE neutral-gray rounded surface
/// inside the daily Goal card.  It contains the label/value column AND the
/// +/- quick controls; there is no loose text and no floating + on the white
/// outer card.
final class _TodayGoalInset extends StatelessWidget {
  const _TodayGoalInset({
    required this.value,
    required this.dailyTargetIsZero,
    required this.onMinus,
    required this.onPlus,
  });

  final String value;
  final bool dailyTargetIsZero;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('home-daily-target-quick-control'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        // Semantic neutral gray surface role (Light: surfaceContainerHighest;
        // Dark: the same dark neutral block role).  Never a full-card slab.
        color: AppTheme.blockOf(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "Today's Goal",
                    maxLines: 1,
                    style: const TextStyle(
                      fontFamily: 'Roboto',
                      fontSize: 12,
                      height: 14 / 12,
                    ),
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 22,
                    height: 24 / 22,
                    fontWeight: FontWeight.w600,
                    // The Today / month progress value uses the neutral
                    // on-surface text family; only the quick controls carry
                    // the accent.
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _DailyTargetControls(
            onMinus: onMinus,
            onPlus: onPlus,
            minusEnabled: !dailyTargetIsZero,
          ),
        ],
      ),
    );
  }
}

/// HR-02: the August Goal inset — the OPAQUE neutral-gray rounded surface at
/// the right of the Temple/monthly full-width card ("August Goal" + ratio).
/// It is an inset inside the ONE outer card, never a separate half-width card.
final class _AugustGoalInset extends StatelessWidget {
  const _AugustGoalInset({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('home-month-goal-card'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.blockOf(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(
                fontFamily: 'Roboto',
                fontSize: 12,
                height: 14 / 12,
              ),
            ),
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 22,
              height: 24 / 22,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// POLISH-02: the distinct Today's Goal quick-control region (minus hidden
/// at zero behind a reserved non-interactive slot so the + never jumps).
final class _DailyTargetControls extends StatelessWidget {
  const _DailyTargetControls({
    required this.onMinus,
    required this.onPlus,
    required this.minusEnabled,
  });

  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final bool minusEnabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 68,
      height: 48,
      child: Row(
        children: <Widget>[
          if (minusEnabled)
            _DailyTargetButton(
              key: const Key('home-daily-target-minus'),
              tooltip: 'Decrease daily target',
              icon: Icons.remove,
              onPressed: onMinus,
            )
          else
            // Reserved invisible slot: same footprint as the minus button so
            // the plus keeps its exact position at zero.
            const ExcludeSemantics(child: SizedBox(width: 28)),
          const SizedBox(width: 4),
          _DailyTargetButton(
            key: const Key('home-daily-target-plus'),
            tooltip: 'Increase daily target',
            icon: Icons.add,
            onPressed: onPlus,
          ),
        ],
      ),
    );
  }
}

/// The Today's Goal minus/plus control.
///
/// The visible icon stays compact (22 dp) so the inset does not grow to the
/// size of its touch targets.  NOTE: Flutter hit-tests the layout footprint
/// (40 x 20 inside the locked 60 dp shared card), so a tap that lands just
/// outside the button falls through to the Goal card and opens Edit Goal.
/// A true 48 x 48 hit area cannot coexist with the approved two-line inset
/// inside the shared Goal 6 geometry; the owner approved the current
/// footprint in the Pack 1A physical acceptance.
final class _DailyTargetButton extends StatelessWidget {
  const _DailyTargetButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        // The enclosing Card wraps its content in a container semantics
        // boundary, so a non-boundary Semantics here would merge its label
        // into the card node and lose the per-button label (the card's own
        // label wins the merge).  Making the button its own boundary keeps
        // each quick control a distinct, announceable semantic target.
        container: true,
        button: true,
        label: tooltip,
        child: SizedBox(
          // A 28 dp layout footprint keeps the quick-control region compact
          // next to the 112 dp Today block.  The 40 x 40 OverflowBox only
          // enlarges the painted child; Flutter hit-tests the 28 x 24 layout
          // box, so the effective tap area is the button footprint itself.
          width: 28,
          height: 24,
          child: OverflowBox(
            alignment: Alignment.center,
            minWidth: 40,
            maxWidth: 40,
            minHeight: 40,
            maxHeight: 40,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onPressed,
                  child: Center(
                    child: Icon(
                      icon,
                      size: 22,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// R5 (owner 2026-08-16): Pathways is deferred. The previously hardcoded,
// non-authoritative "Active Pathways" Home card (Employment / N of M
// milestones / On Track) is no longer rendered. The class definitions were
// removed with the section; domain/data/routes are untouched.

/// Home-only compact ratio text: an unset target renders as 0 (0/0) exactly
/// like an explicit zero.  Domain semantics stay untouched — Goal Planning and
/// Edit screens keep distinguishing notSet/null from explicit 0.
String _homeRatioText(IndicatorAmount actual, IndicatorTarget target) {
  return '${actual.display}/${target.value?.display ?? '0'}';
}
