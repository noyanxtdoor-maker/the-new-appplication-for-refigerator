import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/domain/goal_icon_registry.dart';
import 'package:rmplanner/features/goals/domain/starter_goals.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';

/// Optional **Starter Goals**.
///
/// The screen is ADD-ONLY and read-only until the user confirms:
/// - opening it writes NOTHING (it only reads the active Goals and capacity);
/// - selecting a template writes NOTHING;
/// - only the final confirm creates Goals, one canonical `createGoal`
///   transaction per selected template.
///
/// Templates whose canonical identity is already owned by an active Goal are
/// shown as unavailable — nothing is ever overwritten, replaced or deleted,
/// and display names are never matched.
final class StarterGoalsScreen extends ConsumerStatefulWidget {
  const StarterGoalsScreen({super.key});

  @override
  ConsumerState<StarterGoalsScreen> createState() => _StarterGoalsScreenState();
}

final class _StarterGoalsScreenState extends ConsumerState<StarterGoalsScreen> {
  final Set<String> _selected = <String>{};
  final Map<String, int> _daily = <String, int>{};
  final Map<String, int> _weekly = <String, int>{};
  final Map<String, int> _monthly = <String, int>{};
  bool _creating = false;
  String? _error;

  /// The canonical Create Goal default for a new target is 1; the user always
  /// sees and can change the value before anything is created.
  static const int _defaultTarget = 1;

  int _targetFor(Map<String, int> map, StarterGoalTemplate template) =>
      map[template.id] ?? _defaultTarget;

  void _setTarget(
    Map<String, int> map,
    StarterGoalTemplate template,
    int value,
  ) {
    setState(() => map[template.id] = value < 1 ? 1 : value);
  }

  IndicatorAmount? _amount(int? value) {
    if (value == null) {
      return null;
    }
    return IndicatorAmount(scaledValue: value, scale: 0, unit: 'count');
  }

  bool get _canConfirm => !_creating && _selected.isNotEmpty;

  /// Creates ONLY the selected, currently-available templates, in canonical
  /// slot order.  Each Goal is an independent canonical transaction, so a
  /// process death mid-import leaves a truthful partial import and re-entry
  /// simply offers whatever is still missing.
  Future<void> _confirm(List<StarterGoalTemplate> selectedTemplates) async {
    if (!_canConfirm) {
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    final repository = ref.read(goalRepositoryProvider);
    final profileId = ref.read(goalProfileIdProvider);
    final startDay = ref.read(startOfWeekProvider);
    var created = 0;
    try {
      for (final template in selectedTemplates) {
        // Exactly the Create Goal path: resolve the canonical slot the
        // allocator will occupy (and guard against a race that moved it), so
        // every imported Goal inherits the canonical slot identity law rather
        // than a template-private one.
        final slot = await repository.nextAvailableSlot(
          profileId: profileId,
          role: template.role,
        );
        await repository.createGoal(
          profileId: profileId,
          role: template.role,
          title: template.title,
          targets: GoalTargets(
            daily: template.needsDailyTarget
                ? _amount(_targetFor(_daily, template))
                : null,
            weekly: template.needsWeeklyTarget
                ? _amount(_targetFor(_weekly, template))
                : null,
            monthly: template.needsMonthlyTarget
                ? _amount(_targetFor(_monthly, template))
                : null,
          ),
          iconId: GoalIconRegistry.instance
              .suggestForGoalTitle(template.title)
              ?.iconId,
          expectedSlotIndex: slot,
          startDay: startDay,
        );
        created += 1;
      }
    } on GoalCapacityException {
      setState(() => _error = 'That Goal type is full. Archive one first.');
    } on GoalValidationException catch (error) {
      setState(() => _error = error.message);
    } on Object {
      setState(() => _error = 'Some starter goals could not be added.');
    } finally {
      ref.invalidate(activeGoalsProvider);
      ref.invalidate(goalCapacityProvider);
      ref.invalidate(goalPlanningProvider);
      if (mounted) {
        setState(() => _creating = false);
      }
    }
    if (created > 0 && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final goals = ref.watch(activeGoalsProvider);
    return Scaffold(
      appBar: InternalAppBar(
        leading: IconButton(
          key: const Key('starter-goals-back'),
          tooltip: 'Back',
          onPressed: _creating ? null : () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Starter Goals'),
      ),
      body: SafeArea(
        child: goals.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Padding(
              padding: InternalScreen.pagePadding,
              child: Text(
                'Starter goals are unavailable right now.',
                style: AppTypography.secondary,
                textAlign: TextAlign.center,
              ),
            ),
          ),
          data: (activeGoals) {
            final templates = starterGoalTemplates;
            final availableByTemplate = <String, bool>{
              for (final template in templates)
                template.id: starterTemplateIsAvailable(template, activeGoals),
            };
            final selectedTemplates = <StarterGoalTemplate>[
              for (final template in templates)
                if (_selected.contains(template.id) &&
                    availableByTemplate[template.id] == true)
                  template,
            ];
            return ListView(
              padding: InternalScreen.pagePadding,
              children: <Widget>[
                Text('Add goals you can shape', style: InternalScreen.sectionHeading),
                const SizedBox(height: 3),
                const Text(
                  'These are optional ideas. Choose any you want, set a target '
                  'for each, and add them. Nothing is added until you confirm, '
                  'and your existing goals are never changed.',
                  style: AppTypography.secondary,
                ),
                const SizedBox(height: 18),
                for (final template in templates) ...<Widget>[
                  _StarterGoalCard(
                    template: template,
                    available: availableByTemplate[template.id] ?? false,
                    selected: _selected.contains(template.id),
                    dailyTarget: _targetFor(_daily, template),
                    weeklyTarget: _targetFor(_weekly, template),
                    monthlyTarget: _targetFor(_monthly, template),
                    enabled: !_creating,
                    onToggle: () => setState(() {
                      if (!_selected.remove(template.id)) {
                        _selected.add(template.id);
                      }
                    }),
                    onDailyChanged: (value) =>
                        _setTarget(_daily, template, value),
                    onWeeklyChanged: (value) =>
                        _setTarget(_weekly, template, value),
                    onMonthlyChanged: (value) =>
                        _setTarget(_monthly, template, value),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    _error!,
                    key: const Key('starter-goals-error'),
                    style: AppTypography.secondary,
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('starter-goals-confirm'),
                  onPressed: _canConfirm
                      ? () => _confirm(selectedTemplates)
                      : null,
                  child: _creating
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          selectedTemplates.length == 1
                              ? 'Add 1 starter goal'
                              : 'Add ${selectedTemplates.length} starter goals',
                        ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Added goals appear in Goal Planning and on Home. You can '
                  'rename, re-target, archive or delete them later from Manage '
                  'Goals.',
                  style: AppTypography.secondary,
                  textAlign: TextAlign.center,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _StarterGoalCard extends StatelessWidget {
  const _StarterGoalCard({
    required this.template,
    required this.available,
    required this.selected,
    required this.dailyTarget,
    required this.weeklyTarget,
    required this.monthlyTarget,
    required this.enabled,
    required this.onToggle,
    required this.onDailyChanged,
    required this.onWeeklyChanged,
    required this.onMonthlyChanged,
  });

  final StarterGoalTemplate template;
  final bool available;
  final bool selected;
  final int dailyTarget;
  final int weeklyTarget;
  final int monthlyTarget;
  final bool enabled;
  final VoidCallback onToggle;
  final ValueChanged<int> onDailyChanged;
  final ValueChanged<int> onWeeklyChanged;
  final ValueChanged<int> onMonthlyChanged;

  @override
  Widget build(BuildContext context) {
    final canSelect = available && enabled;
    return Card(
      key: Key('starter-goal-${template.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(template.title, style: AppTypography.cardTitle),
                      const SizedBox(height: 3),
                      Text(
                        template.description,
                        style: AppTypography.secondary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!available)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Already active',
                      key: Key('starter-goal-${template.id}-unavailable'),
                      style: AppTypography.secondary,
                    ),
                  )
                else
                  Checkbox(
                    key: Key('starter-goal-${template.id}-select'),
                    value: selected,
                    onChanged: canSelect ? (_) => onToggle() : null,
                  ),
              ],
            ),
            if (selected && available) ...<Widget>[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Text(template.role.title, style: AppTypography.secondary),
              const SizedBox(height: 8),
              if (template.needsDailyTarget)
                _StarterTargetStepper(
                  templateId: template.id,
                  field: 'daily',
                  label: 'Daily target',
                  value: dailyTarget,
                  enabled: enabled,
                  onChanged: onDailyChanged,
                ),
              if (template.needsWeeklyTarget)
                _StarterTargetStepper(
                  templateId: template.id,
                  field: 'weekly',
                  label: 'Weekly target',
                  value: weeklyTarget,
                  enabled: enabled,
                  onChanged: onWeeklyChanged,
                ),
              if (template.needsMonthlyTarget)
                _StarterTargetStepper(
                  templateId: template.id,
                  field: 'monthly',
                  label: 'Monthly target',
                  value: monthlyTarget,
                  enabled: enabled,
                  onChanged: onMonthlyChanged,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact target stepper.  The value is always visible and always editable
/// before confirming, so no silent target value is ever applied.
final class _StarterTargetStepper extends StatelessWidget {
  const _StarterTargetStepper({
    required this.templateId,
    required this.field,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String templateId;
  final String field;
  final String label;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  Key get _valueKey => Key('starter-goal-$templateId-$field');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: AppTypography.secondary)),
          IconButton(
            key: Key('starter-goal-$templateId-$field-decrement'),
            tooltip: 'Decrease $label',
            onPressed: enabled && value > 1 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            key: _valueKey,
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: AppTypography.cardTitle,
            ),
          ),
          IconButton(
            key: Key('starter-goal-$templateId-$field-increment'),
            tooltip: 'Increase $label',
            onPressed: enabled ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
