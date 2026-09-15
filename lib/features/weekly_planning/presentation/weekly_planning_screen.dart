import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/app_route_observer.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/time/week_period.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';

final class WeeklyPlanningScreen extends ConsumerStatefulWidget {
  const WeeklyPlanningScreen({
    this.periodStart,
    this.initialManagementMode = false,
    super.key,
  });

  final PlannerDate? periodStart;
  final bool initialManagementMode;

  @override
  ConsumerState<WeeklyPlanningScreen> createState() =>
      _WeeklyPlanningScreenState();
}

final class _WeeklyPlanningScreenState
    extends ConsumerState<WeeklyPlanningScreen> {
  late bool _managementMode = widget.initialManagementMode;

  /// Pack 2 B5: the browsed week is local screen state only.  Week arrows
  /// never push or replace routes, so a single Back returns Home and no
  /// week-by-week history stack is ever created.  Null means "the route's
  /// periodStart (or the current week) has not been overridden yet".
  PlannerDate? _selectedWeek;
  String? _establishedSignalPeriod;

  void _setManagementMode(bool value) {
    if (mounted && _managementMode != value) {
      setState(() => _managementMode = value);
    }
  }

  void _selectWeek(PlannerDate start) {
    _setManagementMode(false);
    if (mounted) {
      setState(() => _selectedWeek = _weekStartOf(ref, start));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedWeek;
    final explicitPeriod = widget.periodStart;
    // A1: an explicit route period resolves the week directly.  The
    // today/time-zone Future is only started when no period is known yet.
    final needsToday = selected == null && explicitPeriod == null;
    final todayState = needsToday
        ? ref.watch(weeklyPlanningTodayProvider)
        : null;
    final today = todayState?.asData?.value;
    final resolvedStart = selected != null
        ? _weekStartOf(ref, selected)
        : explicitPeriod != null
        ? _weekStartOf(ref, explicitPeriod)
        : today == null
        ? null
        : _weekStartOf(ref, today);
    if (resolvedStart == null) {
      return Scaffold(
        appBar: _appBar(context),
        body: SafeArea(
          child: todayState!.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => _Failure(
              message: error.toString(),
              onRetry: () => ref.invalidate(weeklyPlanningTodayProvider),
            ),
            data: (_) => const Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }
    // Deliberate entry into the CURRENT period establishes it idempotently
    // through the lightweight ensure (row existence only; never the rich
    // projection).  Historical weeks are never created: the ensure is only
    // watched when the resolved period equals the current one.
    final plannerToday = ref.watch(plannerDateSourceProvider).today();
    final isCurrentPeriod = resolvedStart == _weekStartOf(ref, plannerToday);
    final currentEnsure = isCurrentPeriod
        ? ref.watch(weeklyPlanEnsureProvider(resolvedStart))
        : null;
    if (currentEnsure?.hasValue == true &&
        _establishedSignalPeriod != resolvedStart.iso8601) {
      _establishedSignalPeriod = resolvedStart.iso8601;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.invalidate(weeklyPlanEstablishedProvider(resolvedStart));
        }
      });
    }
    final plan = ref.watch(goalPlanningProvider(resolvedStart));
    final planBody = plan.when(
      // A1: returning from Edit Goal triggers a canonical reload; the last
      // confirmed Goal rows stay visible instead of a whole-body spinner.
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => _Failure(
        message: error.toString(),
        onRetry: () => ref.invalidate(goalPlanningProvider(resolvedStart)),
      ),
      data: (value) => _GoalPlanBody(
        plan: value,
        managementMode: _managementMode,
        onManagementModeChanged: _setManagementMode,
        onWeekSelected: _selectWeek,
      ),
    );
    return Scaffold(
      appBar: _appBar(context),
      body: SafeArea(
        child:
            currentEnsure?.when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => _Failure(
                message: error.toString(),
                onRetry: () =>
                    ref.invalidate(weeklyPlanEnsureProvider(resolvedStart)),
              ),
              data: (_) => planBody,
            ) ??
            planBody,
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      leading: IconButton(
        key: const Key('weekly-plan-back-home'),
        tooltip: 'Back to Home',
        // Pack 2 B6: toolbar Back agrees with Android Back.  When Planning
        // was pushed on Home, popping reveals Home; a direct entry with no
        // parent page falls back to the Home root instead of exiting.
        onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go(RoutePaths.home);
          }
        },
        icon: const Icon(Icons.arrow_back),
      ),
      title: const Text('Goal Planning'),
      actions: <Widget>[
        if (!_managementMode)
          IconButton(
            key: const Key('goal-archive-button'),
            tooltip: 'Goal Archive',
            onPressed: () => context.push(RoutePaths.goalArchive),
            icon: const Icon(Icons.archive_outlined),
          ),
        if (!_managementMode)
          // Pack 2 B5: Push keeps Planning beneath this page so Back returns
          // to Planning.  The history page pops itself with the chosen week,
          // which lands here as the push result so the week stays local state.
          IconButton(
            key: const Key('weekly-plan-history-button'),
            tooltip: 'Plan History',
            onPressed: () async {
              final selected = await context.push<PlannerDate>(
                RoutePaths.weeklyPlanningHistory,
              );
              if (selected != null && mounted) {
                _selectWeek(selected);
              }
            },
            icon: const Icon(Icons.history),
          ),
      ],
    );
  }
}

/// Starter Goals entry point on Goal Planning.
///
/// [prominent] is true ONLY while the user owns no active Goal — the zero-goal
/// empty state the owner locked.  In that state the optional catalog is offered
/// as a first-class action next to the existing Create Goal button; once any
/// Goal exists it collapses to a compact secondary action so the existing
/// Create Goal / Manage Goals hierarchy stays dominant.
///
/// A Starter Goal template is never an actual Goal: nothing is created until
/// the user selects templates, sets their targets and confirms in the catalog.
final class _StarterGoalsInvitation extends StatelessWidget {
  const _StarterGoalsInvitation({
    required this.prominent,
    required this.onUseStarterGoals,
  });

  final bool prominent;
  final VoidCallback onUseStarterGoals;

  @override
  Widget build(BuildContext context) {
    if (!prominent) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          key: const Key('weekly-plan-starter-goals-secondary'),
          onPressed: onUseStarterGoals,
          child: const Text('Use Starter Goals'),
        ),
      );
    }
    return Card(
      key: const Key('weekly-plan-starter-goals-invitation'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('No goals yet', style: AppTypography.cardTitle),
            const SizedBox(height: 4),
            const Text(
              'Create your own goal above, or choose optional Starter Goals '
              'and set your own target for each.',
              style: AppTypography.secondary,
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('weekly-plan-use-starter-goals'),
                onPressed: onUseStarterGoals,
                child: const Text('Use Starter Goals'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _GoalPlanBody extends ConsumerStatefulWidget {
  const _GoalPlanBody({
    required this.plan,
    required this.managementMode,
    required this.onManagementModeChanged,
    required this.onWeekSelected,
  });

  final GoalPlanningSnapshot plan;
  final bool managementMode;
  final ValueChanged<bool> onManagementModeChanged;
  final ValueChanged<PlannerDate> onWeekSelected;

  @override
  ConsumerState<_GoalPlanBody> createState() => _GoalPlanBodyState();
}

final class _GoalPlanBodyState extends ConsumerState<_GoalPlanBody>
    with RouteAware {
  ModalRoute<void>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _route)) {
      return;
    }
    if (_route != null) {
      shellRouteObserver.unsubscribe(this);
    }
    _route = route;
    shellRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    shellRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() {
    widget.onManagementModeChanged(false);
  }

  @override
  void didPop() {
    widget.onManagementModeChanged(false);
  }

  /// Opens the optional Starter Goals catalog.  The catalog itself writes
  /// nothing; only an explicit confirm there creates Goals.  The canonical
  /// providers are refreshed on return so a successful import is reflected
  /// here and on Home immediately.
  Future<void> _openStarterGoals() async {
    await context.push(RoutePaths.starterGoals);
    if (!mounted) {
      return;
    }
    ref.invalidate(activeGoalsProvider);
    ref.invalidate(goalCapacityProvider);
    ref.invalidate(goalPlanningProvider);
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final capacity = ref.watch(goalCapacityProvider).asData?.value;
    // The owner-locked zero-goal empty state: a user who owns no active Goal
    // sees the Starter Goals invitation; once any Goal exists the invitation
    // collapses to a compact secondary action.
    final hasAnyGoal =
        plan.daily != null || plan.weekly.isNotEmpty || plan.monthly != null;
    return Stack(
      children: <Widget>[
        ListView(
          key: const Key('weekly-plan-list'),
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          children: <Widget>[
            _WeekNavigation(
              start: plan.periodStart,
              end: plan.periodEnd,
              canGoForward:
                  plan.periodStart.compareTo(_weekStartOf(ref, _today(ref))) <
                  0,
              onPrevious: () =>
                  widget.onWeekSelected(plan.periodStart.addDays(-7)),
              onNext:
                  plan.periodStart.compareTo(_weekStartOf(ref, _today(ref))) < 0
                  ? () => widget.onWeekSelected(plan.periodStart.addDays(7))
                  : null,
            ),
            const SizedBox(height: 8),
            if (widget.managementMode)
              OutlinedButton.icon(
                key: const Key('weekly-plan-cancel-management'),
                onPressed: _exitManagementMode,
                icon: const Icon(Icons.close, size: 20),
                label: const Text('Cancel'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: AppTheme.onFillTextOf(context, 0.70),
                  side: BorderSide(color: AppTheme.outlineOf(context)),
                  textStyle: AppTypography.button,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              )
            else
              Row(
                children: <Widget>[
                  Expanded(
                    child: _ScaledGoalActionButton(
                      key: const Key('weekly-plan-create-goal'),
                      icon: Icons.add,
                      label: 'Create Goal',
                      onPressed: () =>
                          unawaited(_createGoal(context, capacity)),
                      foreground: Theme.of(context).colorScheme.primary,
                      border: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ScaledGoalActionButton(
                      key: const Key('weekly-plan-manage-goals'),
                      icon: Icons.tune_outlined,
                      label: 'Manage Goals',
                      onPressed: _enterManagementMode,
                    ),
                  ),
                ],
              ),
            if (!widget.managementMode) ...<Widget>[
              const SizedBox(height: 12),
              _StarterGoalsInvitation(
                prominent: !hasAnyGoal,
                onUseStarterGoals: () => unawaited(_openStarterGoals()),
              ),
            ],
            const SizedBox(height: 24),
            _GoalSection(
              title: 'Daily Progress Goal',
              description:
                  'A daily target that builds toward your weekly goal.',
              emptyText: 'No active Daily Progress Goal',
              goals: plan.daily == null
                  ? const <GoalProgress>[]
                  : <GoalProgress>[plan.daily!],
              managementMode: widget.managementMode,
            ),
            const SizedBox(height: 24),
            _GoalSection(
              title: 'Weekly Goals',
              description: 'Goals to complete during the current week.',
              emptyText: 'No active Weekly Goals',
              goals: plan.weekly,
              managementMode: widget.managementMode,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${4 - plan.weekly.length} of 4 Weekly Goal slots available',
                style: AppTypography.secondary,
              ),
            ),
            const SizedBox(height: 24),
            _GoalSection(
              title: 'Monthly Progress Goal',
              description:
                  'A weekly target that moves you toward your monthly goal.',
              emptyText: 'No active Monthly Progress Goal',
              goals: plan.monthly == null
                  ? const <GoalProgress>[]
                  : <GoalProgress>[plan.monthly!],
              managementMode: widget.managementMode,
            ),
          ],
        ),
        if (widget.managementMode)
          const IgnorePointer(
            child: SizedBox(
              key: Key('weekly-plan-management-mode'),
              width: 1,
              height: 1,
            ),
          ),
      ],
    );
  }

  Future<void> _createGoal(BuildContext context, GoalCapacity? capacity) async {
    final full =
        capacity != null &&
        capacity.usedDaily == 1 &&
        capacity.usedWeekly == 4 &&
        capacity.usedMonthly == 1;
    if (!full) {
      await context.push(RoutePaths.goalCreate);
      return;
    }
    final manage = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Goal limit reached'),
        content: const Text(
          'All 6 goal slots are currently in use. Archive at least one '
          'goal before creating another.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('weekly-plan-goal-limit-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('weekly-plan-goal-limit-manage'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Manage Goals'),
          ),
        ],
      ),
    );
    if (manage == true && mounted) {
      widget.onManagementModeChanged(true);
    }
  }

  void _enterManagementMode() {
    widget.onManagementModeChanged(true);
  }

  void _exitManagementMode() {
    widget.onManagementModeChanged(false);
  }

  PlannerDate _today(WidgetRef ref) {
    return ref.watch(weeklyPlanningTodayProvider).asData?.value ??
        PlannerDate.fromDateTime(DateTime.now());
  }
}

/// An OutlinedButton whose icon + label row is wrapped in a FittedBox so the
/// label can never overflow its half-width slot at large text scales.  The
/// 48 dp minimum height is preserved by the button style itself.
final class _ScaledGoalActionButton extends StatelessWidget {
  const _ScaledGoalActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.foreground,
    this.border,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? foreground;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    // Neutral (unspecified) actions resolve to the theme's secondary text and
    // outline so they stay readable on a light surface; accent callers pass
    // explicit colors (e.g. AppTheme.rose) unchanged.
    final resolvedForeground =
        foreground ?? AppTheme.onFillTextOf(context, 0.70);
    final resolvedBorder = border ?? AppTheme.outlineOf(context);
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        foregroundColor: resolvedForeground,
        side: BorderSide(color: resolvedBorder),
        textStyle: AppTypography.button,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      ),
    );
  }
}

final class _GoalSection extends StatelessWidget {
  const _GoalSection({
    required this.title,
    required this.description,
    required this.emptyText,
    required this.goals,
    required this.managementMode,
  });

  final String title;
  final String description;
  final String emptyText;
  final List<GoalProgress> goals;
  final bool managementMode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(title, style: AppTypography.sectionTitle),
        const SizedBox(height: 3),
        Text(description, style: AppTypography.secondary),
        const SizedBox(height: 8),
        const Divider(height: 1),
        if (goals.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(emptyText, style: AppTypography.secondary),
          )
        else
          for (final progress in goals)
            _GoalRow(progress: progress, managementMode: managementMode),
      ],
    );
  }
}

final class _GoalRow extends ConsumerWidget {
  const _GoalRow({required this.progress, required this.managementMode});

  final GoalProgress progress;
  final bool managementMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = progress.goal;
    final ratio = progress.primaryTarget.isSet
        ? '${progress.primaryActual.display}/${progress.primaryTarget.display}'
        : 'Set Goal';
    final secondary = switch (goal.role) {
      GoalRole.dailyWeekly =>
        'Today Goal: ${progress.dailyActual.display}/${progress.dailyTarget.value?.display ?? '0'}',
      GoalRole.weeklyMonthly =>
        'Month Goal: ${progress.monthlyActual.display}/${progress.monthlyTarget.value?.display ?? '0'}',
      GoalRole.weekly => null,
    };
    final row = InkWell(
      key: Key('weekly-plan-goal-${goal.id}'),
      onTap: () => context.push(RoutePaths.goalEdit(goal.id), extra: goal),
      child: Container(
        // GI-02: goal art doubles to 64dp; keep just enough height.
        constraints: const BoxConstraints(minHeight: 88),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: AppTheme.outlineOf(context)),
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: <Widget>[
            GoalIcon(
              iconId: goal.iconId,
              // GI-02: exactly 2x (32 -> 64).
              size: 64,
              semanticLabel: '${goal.title} goal icon',
              fallbackIcon: goalIconFallbackForRole(goal.role),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    goal.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.cardTitle,
                  ),
                  Text(ratio, style: AppTypography.metricCompact),
                  if (secondary != null)
                    Text(secondary, style: AppTypography.secondary),
                ],
              ),
            ),
            if (managementMode)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    key: Key('weekly-plan-goal-direct-archive-${goal.id}'),
                    tooltip: 'Archive goal',
                    onPressed: () {
                      unawaited(_confirmArchive(context, ref, goal));
                    },
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.archive_outlined, size: 24),
                  ),
                  IconButton(
                    key: Key('weekly-plan-goal-direct-delete-${goal.id}'),
                    tooltip: 'Delete goal permanently',
                    onPressed: () {
                      unawaited(_confirmDelete(context, ref, goal));
                    },
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 24,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              )
            else
              PopupMenuButton<String>(
                key: Key('weekly-plan-goal-menu-${goal.id}'),
                tooltip: 'Goal actions',
                onSelected: (value) {
                  if (value == 'edit') {
                    unawaited(
                      context.push(RoutePaths.goalEdit(goal.id), extra: goal),
                    );
                  } else if (value == 'delete') {
                    unawaited(_confirmDelete(context, ref, goal));
                  } else {
                    unawaited(_confirmArchive(context, ref, goal));
                  }
                },
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem(value: 'edit', child: Text('Edit Goal')),
                  const PopupMenuItem(
                    value: 'archive',
                    child: Text('Archive Goal'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Delete Goal',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                icon: const Icon(Icons.more_vert, size: 24),
              ),
          ],
        ),
      ),
    );
    final indicatorKey = goal.indicatorKey;
    return indicatorKey == null
        ? row
        : KeyedSubtree(
            key: Key('weekly-plan-indicator-$indicatorKey'),
            child: row,
          );
  }

  Future<bool> _confirmArchive(
    BuildContext context,
    WidgetRef ref,
    Goal goal,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Archive "${goal.title}"?'),
        content: const Text(
          'It will be removed from your active goals. Past targets, results, '
          'and history will be preserved.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('weekly-plan-archive-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return false;
    }
    await ref
        .read(goalRepositoryProvider)
        .archiveGoal(
          profileId: ref.read(goalProfileIdProvider),
          goalId: goal.id,
        );
    ref.invalidate(activeGoalsProvider);
    ref.invalidate(goalCapacityProvider);
    ref.invalidate(goalPlanningProvider);
    return true;
  }

  Future<bool> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Goal goal,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Goal permanently?'),
        content: Text(
          '“${goal.title}” will be removed and cannot be restored. '
          'Existing completed activity and history will remain in your '
          'records.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('weekly-plan-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('weekly-plan-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return false;
    }
    await ref
        .read(goalRepositoryProvider)
        .deleteGoal(
          profileId: ref.read(goalProfileIdProvider),
          goalId: goal.id,
        );
    ref.invalidate(activeGoalsProvider);
    ref.invalidate(goalCapacityProvider);
    ref.invalidate(goalPlanningProvider);
    return true;
  }
}

final class _WeekNavigation extends StatelessWidget {
  const _WeekNavigation({
    required this.start,
    required this.end,
    required this.canGoForward,
    required this.onPrevious,
    required this.onNext,
  });

  final PlannerDate start;
  final PlannerDate end;
  final bool canGoForward;
  final VoidCallback onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final startLabel = MaterialLocalizations.of(
      context,
    ).formatShortMonthDay(start.asLocalDate);
    final endLabel = MaterialLocalizations.of(
      context,
    ).formatShortMonthDay(end.asLocalDate);
    final label = start.year == end.year
        ? '$startLabel \u2013 $endLabel, ${end.year}'
        : '$startLabel, ${start.year} \u2013 $endLabel, ${end.year}';
    return SizedBox(
      height: 64,
      child: Row(
        children: <Widget>[
          // Pack 2 accent restraint: this is a decorative section marker, not
          // a selected state, primary action, category accent, or warning, so
          // it uses neutral secondary text instead of the highlight pink.
          Icon(
            Icons.calendar_month_outlined,
            color: AppTheme.onFillTextOf(context, 0.70),
            size: 28,
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: AppTypography.body)),
          IconButton(
            tooltip: 'Previous week',
            onPressed: onPrevious,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.chevron_left, size: 28),
          ),
          IconButton(
            tooltip: 'Next week',
            onPressed: canGoForward ? onNext : null,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.chevron_right,
              size: 28,
              color: onNext == null
                  ? AppTheme.onFillTextOf(context, 0.24)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

final class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Weekly Planning could not be opened.'),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

PlannerDate _weekStartOf(WidgetRef ref, PlannerDate date) {
  return resolveWeek(date: date, startDay: ref.read(startOfWeekProvider)).start;
}
