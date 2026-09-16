import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/domain/assigned_event_type_draft.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/assigned_event_type_draft_screen.dart';
import 'package:rmplanner/features/goals/presentation/goal_archive_screen.dart';
import 'package:rmplanner/features/goals/presentation/goal_icon_picker_screen.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon_choice_row.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';

final class GoalEditScreen extends ConsumerStatefulWidget {
  const GoalEditScreen({required this.goalId, this.initialGoal, super.key});

  final String goalId;
  final Goal? initialGoal;

  @override
  ConsumerState<GoalEditScreen> createState() => _GoalEditScreenState();
}

final class _GoalEditScreenState extends ConsumerState<GoalEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  Goal? _goal;
  GoalProgress? _progress;
  List<GoalActivityHistoryItem> _history = const <GoalActivityHistoryItem>[];
  int? _daily;
  int? _weekly;
  int? _monthly;
  String? _iconId;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _showIconPicker = false;

  /// Parent-owned Assigned Event Type draft. Built once the initial Goal
  /// load completes (override metadata + effective color); user edits mark
  /// it dirty; Save commits it atomically with the Goal row.
  AssignedEventTypeDraft? _assignedDraft;
  // True once the build path has re-requested the one-shot assigned-Event-Type
  // resolve because the Event Type catalog arrived after that resolve ran.
  bool _assignedDraftLoadRequested = false;

  /// Guards late initial loads from overwriting user edits: the stored
  /// override/original color are only bound while the user has not touched
  /// the draft.
  bool _assignedDraftTouched = false;

  @override
  void initState() {
    super.initState();
    final initialGoal = widget.initialGoal;
    if (initialGoal != null) {
      _goal = initialGoal;
      _iconId = initialGoal.iconId;
      _titleController.text = initialGoal.title;
      _loading = false;
    }
    _titleController.addListener(_draftChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _titleController.removeListener(_draftChanged);
    _titleController.dispose();
    super.dispose();
  }

  void _draftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _load() async {
    try {
      final profileId = ref.read(goalProfileIdProvider);
      final repository = ref.read(goalRepositoryProvider);
      final goal = await repository.readGoal(
        profileId: profileId,
        goalId: widget.goalId,
      );
      if (!mounted) {
        return;
      }
      if (goal == null || !goal.isActive) {
        if (_goal == null) {
          setState(() {
            _loading = false;
            _error = 'This Goal is no longer active.';
          });
        }
        return;
      }
      _titleController.text = goal.title;
      setState(() {
        _goal = goal;
        _iconId = goal.iconId;
        _loading = false;
      });
      unawaited(_loadAssignedDraft(goal));

      // The Goal identity and manually selected icon are the first-order edit
      // surface. Render them as soon as the Goal row is available instead of
      // making the user wait for the progress/history queries to finish.
      // This also prevents a slow local database read from presenting an
      // apparently empty Edit Goal screen after navigation.
      try {
        final today = ref.read(plannerDateSourceProvider).today();
        final progress = await repository.readProgress(
          profileId: profileId,
          goalId: widget.goalId,
          today: today,
          startDay: ref.read(startOfWeekProvider),
        );
        final history = await repository.readActivityHistory(
          profileId,
          goalId: widget.goalId,
        );
        if (mounted) {
          setState(() {
            _progress = progress;
            _history = history;
            _daily = progress?.dailyTarget.value?.scaledValue;
            _weekly = progress?.weeklyTarget.value?.scaledValue;
            _monthly = progress?.monthlyTarget.value?.scaledValue;
          });
        }
      } on Object catch (error) {
        if (mounted) {
          setState(() => _error = error.toString());
        }
      }
    } on Object catch (error) {
      if (mounted && _goal == null) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  /// Loads the stored override metadata and effective slot color for the
  /// Goal's canonical slot, then binds the initial draft. A late load NEVER
  /// overwrites user edits (dirty guard): if the user already edited the
  /// draft, only the expectedGoalUpdatedAtUtc identity is refreshed.
  Future<void> _loadAssignedDraft(Goal goal) async {
    try {
      final profileId = ref.read(goalProfileIdProvider);
      final stableKey =
          goal.assignedEventTypeStableKey ??
          CanonicalGoalSlot.tryByIndicatorKey(
            goal.indicatorKey,
          )?.eventTypeStableKey;
      if (stableKey == null) {
        return;
      }
      final overrides = await ref.read(
        goalEventTypeNameOverridesProvider(profileId).future,
      );
      final eventTypeState = ref.read(eventTypeControllerProvider);
      EventType? type;
      for (final candidate in eventTypeState.eventTypes) {
        if (candidate.stableKey == stableKey) {
          type = candidate;
          break;
        }
      }
      final slotIndex = goal.activeSlotIndex;
      if (!mounted || type == null || slotIndex == null) {
        return;
      }
      final stored = overrides[goal.id];
      final storedMatchesKey =
          stored != null && stored.eventTypeStableKey == stableKey;
      final originalColor =
          eventTypeState.eventColors[stableKey] ??
          PlannerEventColorDefaults.forEventType(type);
      final resolvedType = type;
      setState(() {
        final existing = _assignedDraft;
        if (existing == null || !_assignedDraftTouched) {
          _assignedDraft = AssignedEventTypeDraft(
            expectedSlotIndex: slotIndex,
            expectedEventTypeId: resolvedType.id,
            expectedStableKey: stableKey,
            originalNameMode: storedMatchesKey
                ? AssignedEventTypeNameMode.manual
                : AssignedEventTypeNameMode.auto,
            originalNameOverride: storedMatchesKey ? stored.name : null,
            currentNameMode: storedMatchesKey
                ? AssignedEventTypeNameMode.manual
                : AssignedEventTypeNameMode.auto,
            currentNameOverride: storedMatchesKey ? stored.name : null,
            nameDirty: false,
            originalColor: originalColor,
            changedColor: null,
            colorDirty: false,
            expectedGoalUpdatedAtUtc: goal.updatedAtUtc,
          );
        } else if (existing.expectedGoalUpdatedAtUtc == null) {
          _assignedDraft = existing.copyWith(
            expectedGoalUpdatedAtUtc: goal.updatedAtUtc,
          );
        }
      });
    } on Object {
      // Draft stays unresolved: the section shows the unavailable state and
      // Save keeps working without a presentation merge (a plain Goal edit
      // is never blocked on a metadata read failure).
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        appBar: _GoalEditAppBar(),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_goal == null) {
      return Scaffold(
        appBar: _GoalEditAppBar(),
        body: Center(child: Text(_error ?? 'Goal unavailable.')),
      );
    }
    final goal = _goal!;
    if (_showIconPicker) {
      return GoalIconPickerScreen(
        args: GoalIconPickerArgs(
          goalTitle: _titleController.text.trim(),
          currentIconId: _iconId,
        ),
        onSelected: (iconId) {
          setState(() {
            _iconId = iconId;
            _showIconPicker = false;
          });
        },
        onCancel: () => setState(() => _showIconPicker = false),
      );
    }
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_saving) {
          unawaited(_handleBackAndPop());
        }
      },
      child: Scaffold(
        appBar: InternalAppBar(
          leading: IconButton(
            key: const Key('goal-edit-back'),
            tooltip: 'Back',
            onPressed: _saving ? null : () => unawaited(_handleBackAndPop()),
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('Edit Goal'),
          actions: <Widget>[
            TextButton(
              key: const Key('goal-edit-save'),
              onPressed: _saving || !_draftIsValid ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: InternalScreen.pagePadding,
              children: <Widget>[
                Text(
                  goal.title,
                  style: AppTypography.pageTitle.copyWith(
                    fontSize: 24,
                    height: 30 / 24,
                  ),
                ),
                const SizedBox(height: 2),
                Text(goal.role.title, style: AppTypography.secondary),
                const SizedBox(height: 16),
                _buildAssignedEventTypeSection(goal),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('goal-title'),
                  controller: _titleController,
                  decoration: const InputDecoration(labelText: 'Goal Name'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a Goal name.'
                      : null,
                ),
                const SizedBox(height: 16),
                Text('Icon', style: AppTypography.cardTitle),
                const SizedBox(height: 3),
                const Text(
                  'Choose an icon that represents your goal.',
                  style: AppTypography.secondary,
                ),
                const SizedBox(height: 8),
                GoalIconChoiceRow(
                  goalTitle: _titleController.text.trim(),
                  iconId: _iconId,
                  fallbackIcon: goalIconFallbackForRole(goal.role),
                  onTap: _openIconPicker,
                ),
                const SizedBox(height: 16),
                if (goal.role == GoalRole.dailyWeekly) ...<Widget>[
                  _EditTarget(
                    key: const Key('goal-period-daily'),
                    label: 'Daily Target',
                    value: _daily,
                    onChanged: (value) => setState(() => _daily = value),
                  ),
                  const SizedBox(height: 12),
                ],
                _EditTarget(
                  key: const Key('goal-period-weekly'),
                  label: 'Weekly Target',
                  value: _weekly,
                  onChanged: (value) => setState(() => _weekly = value),
                ),
                if (goal.role == GoalRole.weeklyMonthly) ...<Widget>[
                  const SizedBox(height: 12),
                  _EditTarget(
                    key: const Key('goal-period-monthly'),
                    label: 'Monthly Target',
                    value: _monthly,
                    onChanged: (value) => setState(() => _monthly = value),
                  ),
                ],
                const SizedBox(height: 18),
                _ProgressSummary(progress: _progress),
                const SizedBox(height: 18),
                _GoalHistoryPreview(
                  items: _history,
                  onViewAll: () => _openGoalHistory(goal.id),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Changes are saved only when you tap Save.',
                  style: AppTypography.secondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAssignedEventTypeSection(Goal goal) {
    final stableKey =
        goal.assignedEventTypeStableKey ??
        CanonicalGoalSlot.tryByIndicatorKey(
          goal.indicatorKey,
        )?.eventTypeStableKey;
    final eventTypeState = ref.watch(eventTypeControllerProvider);
    final draft = _assignedDraft;
    EventType? assignedType;
    for (final candidate in eventTypeState.eventTypes) {
      if (candidate.stableKey == stableKey) {
        assignedType = candidate;
        break;
      }
    }
    final type = assignedType;
    if (draft == null &&
        stableKey != null &&
        type != null &&
        !type.isArchived &&
        !_assignedDraftLoadRequested) {
      // [_loadAssignedDraft] is a one-shot resolve driven by the Goal read, and
      // it reads the Event Type catalog with `ref.read` even though that catalog
      // is loaded asynchronously by its own provider. On any open that beats the
      // catalog (cold start, or a direct push such as a Home deep-link) the
      // one-shot observed an empty catalog, returned early and nothing ever
      // retried — so the section showed "Event Type unavailable" FOREVER even
      // though the catalog arrived a frame later, and Save then silently skipped
      // the presentation merge. This build path already watches the catalog, so
      // re-request the resolve exactly once here, the moment the catalog can
      // actually satisfy it. The dirty guard inside [_loadAssignedDraft] keeps a
      // late resolve from overwriting user edits.
      _assignedDraftLoadRequested = true;
      unawaited(_loadAssignedDraft(goal));
    }
    if (stableKey == null || type == null || type.isArchived || draft == null) {
      return const Card(
        key: Key('goal-assigned-event-type'),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('Event Type unavailable', style: AppTypography.secondary),
        ),
      );
    }
    final colorPair = draft.changedColor ?? draft.originalColor;
    return Card(
      key: const Key('goal-assigned-event-type'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Assigned Event Type',
              style: InternalScreen.sectionHeading,
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 12,
                  backgroundColor: Color(colorPair.accentArgb),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    draft.effectiveName(goalTitle: _titleController.text),
                    style: AppTypography.cardTitle,
                  ),
                ),
                TextButton(
                  key: const Key('goal-edit-event-type'),
                  onPressed: _saving
                      ? null
                      : () => unawaited(_openDraftEditor(draft)),
                  child: const Text('Edit Event Type'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Events of this type contribute toward this Goal. '
              'The assignment is fixed.',
              style: AppTypography.secondary,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDraftEditor(AssignedEventTypeDraft draft) async {
    final result = await Navigator.of(context)
        .push<AssignedEventTypeDraftResult>(
          MaterialPageRoute<AssignedEventTypeDraftResult>(
            builder: (_) => AssignedEventTypeDraftScreen(
              initialDraft: draft,
              goalTitle: _titleController.text.trim(),
            ),
          ),
        );
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      _assignedDraft = result.applyTo(_assignedDraft!);
      _assignedDraftTouched = true;
    });
  }

  Future<void> _openGoalHistory(String goalId) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GoalArchiveScreen(initialTab: 1, historyGoalId: goalId),
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    if (!_formKey.currentState!.validate() || _goal == null) {
      return;
    }
    if ([
      _daily,
      _weekly,
      _monthly,
    ].any((value) => value != null && value < 0)) {
      _showError('Targets must be zero or greater.');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(goalRepositoryProvider)
          .saveGoal(
            profileId: ref.read(goalProfileIdProvider),
            goalId: _goal!.id,
            title: _titleController.text.trim(),
            targets: GoalTargets(
              daily: _amount(_daily),
              weekly: _amount(_weekly),
              monthly: _amount(_monthly),
            ),
            iconId: _iconId,
            startDay: ref.read(startOfWeekProvider),
            assignedEventTypeDraft: _assignedDraftTouched
                ? _assignedDraft
                : null,
          );
      ref.invalidate(activeGoalsProvider);
      ref.invalidate(goalCapacityProvider);
      ref.invalidate(goalPlanningProvider);
      if (mounted) {
        setState(() {
          _goal = saved;
          _saving = false;
        });
        Navigator.of(context).pop(true);
      }
    } on GoalValidationException catch (error) {
      _showError(error.message);
      if (mounted) {
        setState(() => _saving = false);
      }
    } on Object {
      _showError('The Goal could not be saved.');
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<bool> _handleBack() async {
    if (!_hasChanges()) {
      return true;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved Changes'),
        content: const Text('Your changes have not been saved.'),
        actions: <Widget>[
          TextButton(
            key: const Key('goal-discard-changes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard Changes'),
          ),
          FilledButton(
            key: const Key('goal-continue-editing'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Continue Editing'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _handleBackAndPop() async {
    if (await _handleBack() && mounted) {
      Navigator.of(context).pop();
    }
  }

  bool _hasChanges() {
    final goal = _goal;
    if (goal == null) {
      return false;
    }
    final draft = _assignedDraft;
    final draftChanged =
        _assignedDraftTouched &&
        draft != null &&
        (draft.nameDirty || draft.colorDirty);
    return goal.title != _titleController.text.trim() ||
        _daily != _progress?.dailyTarget.value?.scaledValue ||
        _weekly != _progress?.weeklyTarget.value?.scaledValue ||
        _monthly != _progress?.monthlyTarget.value?.scaledValue ||
        _iconId != goal.iconId ||
        draftChanged;
  }

  bool get _draftIsValid =>
      _titleController.text.trim().isNotEmpty &&
      <int?>[
        _daily,
        _weekly,
        _monthly,
      ].every((value) => value == null || value >= 0);

  IndicatorAmount? _amount(int? value) {
    if (value == null) {
      return null;
    }
    return IndicatorAmount(scaledValue: value, scale: 0, unit: 'count');
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openIconPicker() {
    if (mounted) {
      setState(() => _showIconPicker = true);
    }
  }
}

final class _GoalHistoryPreview extends StatelessWidget {
  const _GoalHistoryPreview({required this.items, required this.onViewAll});

  final List<GoalActivityHistoryItem> items;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final visible = items.take(4).toList(growable: false);
    return Card(
      key: const Key('goal-activity-history-preview'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Activity History',
                    style: InternalScreen.sectionHeading,
                  ),
                ),
                TextButton(
                  key: const Key('goal-view-all-history'),
                  onPressed: onViewAll,
                  child: const Text('View All'),
                ),
              ],
            ),
            const Divider(),
            if (visible.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No Goal activity yet.',
                  style: AppTypography.secondary,
                ),
              )
            else
              for (final item in visible) _GoalHistoryRow(item: item),
          ],
        ),
      ),
    );
  }
}

final class _GoalHistoryRow extends StatelessWidget {
  const _GoalHistoryRow({required this.item});

  final GoalActivityHistoryItem item;

  @override
  Widget build(BuildContext context) {
    final activity = item.activity;
    final title = switch (activity.action) {
      GoalActivityAction.created =>
        'Created “${activity.newValue ?? item.goalTitle}”',
      GoalActivityAction.renamed =>
        'Renamed “${activity.previousValue ?? ''}” to '
            '“${activity.newValue ?? item.goalTitle}”',
      GoalActivityAction.archived =>
        'Archived “${activity.newValue ?? item.goalTitle}”',
      GoalActivityAction.restored => 'Restored “${item.goalTitle}”',
      GoalActivityAction.deleted =>
        'Deleted “${activity.newValue ?? item.goalTitle}”',
    };
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(activity.occurredAtUtc.toLocal());
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(activity.occurredAtUtc.toLocal()));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      // B3.1: theme-owned generic action icon — resolves through the active
      // Theme Color semantic primary (Blue in Blue mode, canonical Rose in
      // Rose Dark).  Goal Icon artwork is NOT affected (separate renderer).
      leading: Icon(
        _goalActivityIcon(activity.action),
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(title, style: AppTypography.secondary),
      subtitle: Text('$date · $time'),
    );
  }
}

IconData _goalActivityIcon(GoalActivityAction action) => switch (action) {
  GoalActivityAction.created => Icons.add_circle_outline,
  GoalActivityAction.renamed => Icons.edit_outlined,
  GoalActivityAction.archived => Icons.archive_outlined,
  GoalActivityAction.restored => Icons.restore,
  GoalActivityAction.deleted => Icons.delete_outline,
};

final class _GoalEditAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const _GoalEditAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(InternalScreen.appBarHeight);

  @override
  Widget build(BuildContext context) {
    return const InternalAppBar(title: Text('Edit Goal'));
  }
}

final class _EditTarget extends StatelessWidget {
  const _EditTarget({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: InputDecorator(
            decoration: InputDecoration(labelText: label),
            child: Text(value?.toString() ?? '-', style: AppTypography.body),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: Key('${key}_minus'),
          tooltip: 'Decrease $label',
          onPressed: value != null && value! > 0
              ? () => onChanged(value! - 1)
              : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        IconButton(
          key: Key('${key}_plus'),
          tooltip: 'Increase $label',
          onPressed: () => onChanged((value ?? 0) + 1),
          icon: const Icon(Icons.add_circle),
          color: Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }
}

final class _ProgressSummary extends StatelessWidget {
  const _ProgressSummary({required this.progress});

  final GoalProgress? progress;

  @override
  Widget build(BuildContext context) {
    if (progress == null) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Current Progress',
              style: InternalScreen.sectionHeading,
            ),
            const SizedBox(height: 6),
            Text(
              'Daily: ${progress!.dailyActual.display}   '
              'Weekly: ${progress!.weeklyActual.display}   '
              'Monthly: ${progress!.monthlyActual.display}',
              style: AppTypography.secondary,
            ),
          ],
        ),
      ),
    );
  }
}
