import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart' as contacts;
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/domain/canonical_goal_slots.dart';
import 'package:rmplanner/features/goals/domain/goal_event_type_policy.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/domain/event_color_math.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/event_type_presentation.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_color_picker_components.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_layout_policy.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_color_preview.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_color_resolver.dart';
import 'package:rmplanner/features/settings/presentation/event_color_picker_dialog.dart';

const double _eventPreviewWidth = 183;
const double _eventRowHeight = 44;
const double _eventPreviewToControlsGap = 12;
const double _eventControlsWidth = 190;

final class PlannerEventColorsScreen extends ConsumerStatefulWidget {
  const PlannerEventColorsScreen({super.key});

  @override
  ConsumerState<PlannerEventColorsScreen> createState() =>
      _PlannerEventColorsScreenState();
}

final class _PlannerEventColorsScreenState
    extends ConsumerState<PlannerEventColorsScreen> {
  final Map<String, EventColorPreference> _liveEventColors =
      <String, EventColorPreference>{};

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(eventTypeControllerProvider);
    final controller = ref.read(eventTypeControllerProvider.notifier);
    final eventTypes = _orderedEventTypes(state.eventTypes);
    // Live presentation labels (display-only cache; saves re-validate).
    final profileId = ref.watch(goalProfileIdProvider);
    final bindings = ref
        .watch(liveGoalEventTypeBindingsProvider(profileId))
        .value;
    final overrides = ref
        .watch(goalEventTypeNameOverridesProvider(profileId))
        .value;
    String labelFor(EventType type) =>
        _displayLabelFor(type, bindings, overrides);
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Colors')),
      body: SafeArea(
        child: state.isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                key: const Key('planner-event-colors-list'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: <Widget>[
                  if (state.message != null) ...<Widget>[
                    MaterialBanner(
                      content: Text(state.message!),
                      actions: <Widget>[
                        TextButton(
                          onPressed: controller.clearMessage,
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  const _ColorsSectionHeader(
                    key: Key('planner-event-colors-events-section'),
                    label: 'Events',
                  ),
                  const SizedBox(height: 10),
                  for (final type in eventTypes) ...<Widget>[
                    _EventColorRow(
                      key: Key('event-color-row-${type.stableKey}'),
                      type: type,
                      displayLabel: labelFor(type),
                      preference:
                          _liveEventColors[type.stableKey] ??
                          _preferenceFor(state, type),
                      onAccent: () => _editEventColor(
                        context,
                        controller,
                        type,
                        EventColorRole.accent,
                        labelFor(type),
                      ),
                      onSurface: () => _editEventColor(
                        context,
                        controller,
                        type,
                        EventColorRole.surface,
                        labelFor(type),
                      ),
                      onRecommendedAccent: () => _editRecommendedAccent(
                        context,
                        controller,
                        type,
                        labelFor(type),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  _EventColorRow(
                    key: const Key('event-color-row-planner_task'),
                    type: _taskColorType,
                    displayLabel: _taskColorType.label,
                    preference:
                        _liveEventColors[PlannerEventColorResolver
                            .taskStableKey] ??
                        state.eventColors[PlannerEventColorResolver
                            .taskStableKey] ??
                        PlannerEventColorDefaults.task,
                    onAccent: () => _editEventColor(
                      context,
                      controller,
                      _taskColorType,
                      EventColorRole.accent,
                      _taskColorType.label,
                    ),
                    onSurface: () => _editEventColor(
                      context,
                      controller,
                      _taskColorType,
                      EventColorRole.surface,
                      _taskColorType.label,
                    ),
                    onRecommendedAccent: () => _editRecommendedAccent(
                      context,
                      controller,
                      _taskColorType,
                      _taskColorType.label,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      key: const Key('planner-event-colors-restore-defaults'),
                      onPressed: eventTypes.isEmpty
                          ? null
                          : () => _confirmRestoreEvents(context, controller),
                      child: const Text('Restore Event Defaults'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _ColorsSectionHeader(
                    key: Key('planner-event-colors-groups-section'),
                    label: 'Contact Group Colors',
                  ),
                  const SizedBox(height: 8),
                  const _ContactGroupColorsSection(),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      key: const Key('planner-group-colors-restore-defaults'),
                      onPressed: () => _confirmRestoreGroups(context),
                      child: const Text('Restore Group Defaults'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      key: const Key('planner-group-colors-manage'),
                      onPressed: () => context.push(RoutePaths.contactGroups),
                      child: const Text('Manage Groups'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  static List<EventType> _orderedEventTypes(List<EventType> types) {
    final order = <String, int>{
      for (
        var index = 0;
        index < SystemEventTypeKeys.approvedCreationOrder.length;
        index += 1
      )
        SystemEventTypeKeys.approvedCreationOrder[index]: index,
    };
    final result = types.where((type) => type.isCreationVisible).toList();
    result.sort((left, right) {
      final leftOrder = order[left.stableKey];
      final rightOrder = order[right.stableKey];
      if (leftOrder != null && rightOrder != null) {
        return leftOrder.compareTo(rightOrder);
      }
      if (leftOrder != null) {
        return -1;
      }
      if (rightOrder != null) {
        return 1;
      }
      final position = left.position.compareTo(right.position);
      return position == 0 ? left.label.compareTo(right.label) : position;
    });
    return result;
  }

  static EventColorPreference _preferenceFor(
    EventTypeState state,
    EventType type,
  ) {
    return PlannerEventColorResolver.preferenceForType(type, state.eventColors);
  }

  /// Settings display label for one row (closed-beta V2, owner decision
  /// AG-2, 2026-09-17):
  ///
  ///   manual stored name override
  ///     -> live current Goal title
  ///     -> `Life Goal <slotIndex>`
  ///
  /// A non-goal-linked row keeps the pure prospective alias law. A
  /// goal-linked row whose canonical slot has no real live Goal must NEVER
  /// display its seeded label, because those seeds are goal-shaped vocabulary
  /// ("Exercise", "Temple Visit", ...) and would masquerade as goals the user
  /// does not have. Starter Goal suggestions are not current Goals and are not
  /// consulted here.
  ///
  /// The placeholder is derived from the explicit canonical slot index — never
  /// from list position — so it stays stable across ordering changes.
  ///
  /// This law is deliberately scoped to this Colors surface; the general Event
  /// Types screen keeps its own accepted presentation.
  /// Display only — every save freshly re-validates.
  static String _displayLabelFor(
    EventType type,
    Map<int, LiveGoalEventTypeBinding>? bindings,
    Map<String, GoalEventTypeNameOverride>? overrides,
  ) {
    final slot = CanonicalGoalSlot.tryByEventTypeKey(type.stableKey);
    if (slot == null) {
      return EventTypePresentation.prospectiveLabel(type);
    }
    // A non-canonical Goal slot keeps the accepted prospective alias; every
    // canonical slot falls through to a truthful Goal-derived label.
    final binding = bindings?[slot.slotIndex];
    if (binding == null) {
      return 'Life Goal ${slot.slotIndex}';
    }
    final stored = overrides?[binding.goalId];
    if (stored != null && stored.eventTypeStableKey == type.stableKey) {
      return stored.name;
    }
    return binding.title.trim();
  }

  Future<void> _editEventColor(
    BuildContext context,
    EventTypeController controller,
    EventType type,
    EventColorRole role,
    String displayLabel,
  ) async {
    final state = ref.read(eventTypeControllerProvider);
    final current = _preferenceFor(state, type);
    final chosen = await showPlannerEventColorPicker(
      context: context,
      eventTypeLabel: displayLabel,
      role: role,
      initialColor: Color(
        role == EventColorRole.accent
            ? current.accentArgb
            : current.surfaceArgb,
      ),
      otherColor: Color(
        role == EventColorRole.accent
            ? current.surfaceArgb
            : current.accentArgb,
      ),
      onChanged: (color) {
        if (!mounted) {
          return;
        }
        setState(() {
          _liveEventColors[type.stableKey] = role == EventColorRole.accent
              ? EventColorPreference(
                  accentArgb: color.toARGB32(),
                  surfaceArgb: PlannerEventBlockColorPolicy.resolvedSurfaceArgb(
                    accentArgb: color.toARGB32(),
                    currentAccentArgb: current.accentArgb,
                    currentSurfaceArgb: current.surfaceArgb,
                  ),
                )
              : EventColorPreference(
                  accentArgb: current.accentArgb,
                  surfaceArgb: color.toARGB32(),
                );
        });
      },
    );
    if (!mounted) {
      return;
    }
    if (chosen == null) {
      setState(() {
        _liveEventColors.remove(type.stableKey);
      });
      return;
    }
    final updated = role == EventColorRole.accent
        ? EventColorPreference(
            accentArgb: chosen.toARGB32(),
            surfaceArgb: PlannerEventBlockColorPolicy.resolvedSurfaceArgb(
              accentArgb: chosen.toARGB32(),
              currentAccentArgb: current.accentArgb,
              currentSurfaceArgb: current.surfaceArgb,
            ),
          )
        : EventColorPreference(
            accentArgb: current.accentArgb,
            surfaceArgb: chosen.toARGB32(),
          );
    final saved = await controller.saveEventColor(type, updated);
    _reportSaveOutcome(saved);
    if (mounted) {
      setState(() {
        _liveEventColors.remove(type.stableKey);
      });
    }
  }

  /// Truthful failure surface (closed-beta V2, owner decision AG-1).
  ///
  /// The uniqueness guard legitimately refuses a deliberate duplicate accent.
  /// The banner above the list is easy to miss on a long, scrolled screen, so
  /// a refused save is announced where the user is actually looking. Nothing is
  /// persisted on failure, and the controller's own message is surfaced
  /// verbatim so the stated reason stays honest.
  void _reportSaveOutcome(bool saved) {
    if (saved || !mounted) {
      return;
    }
    final message = ref.read(eventTypeControllerProvider).message;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message ?? 'That color was not saved. You can safely retry.',
        ),
      ),
    );
  }

  Future<void> _editRecommendedAccent(
    BuildContext context,
    EventTypeController controller,
    EventType type,
    String displayLabel,
  ) async {
    final state = ref.read(eventTypeControllerProvider);
    final current = _preferenceFor(state, type);
    final chosen = await showRecommendedEventColorsDialog(
      context,
      title: displayLabel,
      initialColor: Color(current.accentArgb),
      peerAccentColors: <int>[
        for (final peer in state.eventTypes)
          if (peer.id != type.id) _preferenceFor(state, peer).accentArgb,
      ],
    );
    if (!mounted || chosen == null) {
      return;
    }
    final saved = await controller.saveEventColor(
      type,
      EventColorPreference(
        accentArgb: chosen.toARGB32(),
        // Recommended colors follow the same derivation as custom hex and
        // Edit Event Type so the surface can never stay stale.
        surfaceArgb: PlannerEventBlockColorPolicy.resolvedSurfaceArgb(
          accentArgb: chosen.toARGB32(),
          currentAccentArgb: current.accentArgb,
          currentSurfaceArgb: current.surfaceArgb,
        ),
      ),
    );
    _reportSaveOutcome(saved);
    if (mounted) {
      setState(() {
        _liveEventColors.remove(type.stableKey);
      });
    }
  }

  Future<void> _confirmRestoreGroups(BuildContext context) async {
    final restore = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('planner-group-colors-restore-dialog'),
        title: const Text('Restore Group color defaults?'),
        content: const Text(
          'The four built-in default group colors will be restored. '
          'Custom group colors and Event colors will not change.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('planner-group-colors-restore-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('planner-group-colors-restore-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (restore == true && context.mounted) {
      final profileId = ref.read(contactProfileIdProvider);
      await ref
          .read(contactRepositoryProvider)
          .restoreBuiltInGroupColorDefaults(profileId);
    }
  }

  Future<void> _confirmRestoreEvents(
    BuildContext context,
    EventTypeController controller,
  ) async {
    final colorScheme = Theme.of(context).colorScheme;
    final restore = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('planner-event-colors-restore-dialog'),
        title: Text(
          'Restore Event color defaults?',
          style: TextStyle(color: colorScheme.onSurface),
        ),
        content: Text(
          'Your custom Event colors will be replaced with the approved '
          'defaults. Group colors will not change.',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('planner-event-colors-restore-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(foregroundColor: colorScheme.primary),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('planner-event-colors-restore-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
            ),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (restore == true && context.mounted) {
      final restored = await controller.restoreEventColorDefaults();
      _reportSaveOutcome(restored);
      if (mounted) {
        setState(_liveEventColors.clear);
      }
    }
  }
}

final class _ColorsSectionHeader extends StatelessWidget {
  const _ColorsSectionHeader({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 16,
            height: 22 / 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        const Divider(height: 1),
      ],
    );
  }
}

final class _EventColorRow extends StatelessWidget {
  const _EventColorRow({
    required this.type,
    required this.displayLabel,
    required this.preference,
    required this.onAccent,
    required this.onSurface,
    required this.onRecommendedAccent,
    super.key,
  });

  final EventType type;

  /// Presentation-only label (live Goal alias / Study & Planning). The raw
  /// type keeps its identity: colors stay keyed by stable key.
  final String displayLabel;
  final EventColorPreference preference;
  final VoidCallback onAccent;
  final VoidCallback onSurface;
  final VoidCallback onRecommendedAccent;

  @override
  Widget build(BuildContext context) {
    final controls = _EventColorControls(
      type: type,
      displayLabel: displayLabel,
      preference: preference,
      onAccent: onAccent,
      onSurface: onSurface,
      onRecommendedAccent: onRecommendedAccent,
    );
    return Semantics(
      container: true,
      label: '$displayLabel Event colors',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final previewWidth =
              (constraints.maxWidth -
                      _eventControlsWidth -
                      _eventPreviewToControlsGap)
                  .clamp(0.0, _eventPreviewWidth)
                  .toDouble();
          return SizedBox(
            height: _eventRowHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: previewWidth,
                  height: 40,
                  child: PlannerEventColorPreview(
                    eventType: type,
                    displayLabel: displayLabel,
                    preference: preference,
                  ),
                ),
                const SizedBox(width: _eventPreviewToControlsGap),
                controls,
              ],
            ),
          );
        },
      ),
    );
  }
}

final class _EventColorControls extends StatelessWidget {
  const _EventColorControls({
    required this.type,
    required this.displayLabel,
    required this.preference,
    required this.onAccent,
    required this.onSurface,
    required this.onRecommendedAccent,
  });

  final EventType type;
  final String displayLabel;
  final EventColorPreference preference;
  final VoidCallback onAccent;
  final VoidCallback onSurface;
  final VoidCallback onRecommendedAccent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _eventControlsWidth,
      height: _eventRowHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _ColorControl(
            key: Key('event-color-accent-${type.stableKey}'),
            roleLabel: 'accent',
            typeLabel: displayLabel,
            color: Color(preference.accentArgb),
            onPressed: onAccent,
          ),
          _ColorControl(
            key: Key('event-color-surface-${type.stableKey}'),
            roleLabel: 'Event background',
            typeLabel: displayLabel,
            color: Color(preference.surfaceArgb),
            onPressed: onSurface,
          ),
          RecommendedEventColorsAction(
            key: Key('event-color-recommended-${type.stableKey}'),
            color: Theme.of(context).colorScheme.primary,
            onPressed: onRecommendedAccent,
          ),
        ],
      ),
    );
  }
}

/// The synthetic canonical Task identity used by this Colors surface ONLY.
///
/// `colorValue` deliberately reads [PlannerEventColorDefaults.task] instead of
/// repeating the literal: before this it duplicated the Task accent, so a
/// future Task default change could have left Settings and the Planner
/// rendering two different Task colours with nothing to catch it. Runtime
/// behaviour is unchanged — this resolves to the same value today.
final EventType _taskColorType = EventType(
  id: 'planner_task',
  stableKey: PlannerEventColorResolver.taskStableKey,
  label: 'Task',
  icon: EventTypeIcon.calendar,
  colorValue: PlannerEventColorDefaults.task.accentArgb,
  isSystem: true,
  isArchived: false,
  reportRequiredDefault: true,
  defaultDurationMinutes: 15,
  position: 999,
  mappingVersion: 1,
  indicatorKeys: <String>{},
);

final class _ColorControl extends StatelessWidget {
  const _ColorControl({
    required this.roleLabel,
    required this.typeLabel,
    required this.color,
    required this.onPressed,
    super.key,
  });

  final String roleLabel;
  final String typeLabel;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final value = colorHex(color);
    return SizedBox(
      width: 70,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            child: Semantics(
              button: true,
              label: '$typeLabel $roleLabel color, current value $value',
              onTap: onPressed,
              child: InkWell(
                key: Key('event-color-swatch-$typeLabel-$roleLabel'),
                onTap: onPressed,
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 30,
            top: 0,
            child: Semantics(
              button: true,
              label: 'Edit $typeLabel $roleLabel color',
              onTap: onPressed,
              child: Tooltip(
                message: 'Edit $typeLabel $roleLabel color',
                child: InkWell(
                  key: Key('event-color-pencil-$typeLabel-$roleLabel'),
                  onTap: onPressed,
                  borderRadius: BorderRadius.circular(20),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(child: Icon(Icons.edit_outlined, size: 20)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Contact Group Colors section backed by the canonical real ContactGroup
/// rows (C2). Default (built-in) groups render first in the approved order,
/// then custom groups. Editing writes the real row's colorValue; Restore
/// Group Defaults is handled by the parent via the repository.
final class _ContactGroupColorsSection extends ConsumerStatefulWidget {
  const _ContactGroupColorsSection();

  @override
  ConsumerState<_ContactGroupColorsSection> createState() =>
      _ContactGroupColorsSectionState();
}

final class _ContactGroupColorsSectionState
    extends ConsumerState<_ContactGroupColorsSection> {
  // Live preview colors during a picker drag; cleared once a save lands.
  final Map<String, int> _liveColors = <String, int>{};

  Future<void> _editGroupColor(
    BuildContext context,
    contacts.ContactGroup group,
    List<contacts.ContactGroup> groups,
  ) async {
    final chosen = await showModalBottomSheet<Color>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _GroupColorEditorSheet(
        groupName: group.name,
        initialColor: Color(_liveColors[group.id] ?? group.colorValue),
        peerColors: groups
            .where((peer) => peer.id != group.id && !peer.isArchived)
            .map((peer) => _liveColors[peer.id] ?? peer.colorValue)
            .toList(growable: false),
      ),
    );
    if (!mounted) {
      return;
    }
    if (chosen == null) {
      return;
    }
    final profileId = ref.read(contactProfileIdProvider);
    try {
      await ref
          .read(contactRepositoryProvider)
          .updateGroup(
            profileId: profileId,
            groupId: group.id,
            name: group.name,
            colorValue: chosen.toARGB32(),
          );
    } on contacts.ContactValidationException catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
    if (mounted) {
      setState(() {
        _liveColors.remove(group.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(contactGroupsProvider);
    final profileId = ref.read(contactProfileIdProvider);
    return groupsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'Contact groups could not be opened: $error',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      data: (groups) {
        final byId = <String, contacts.ContactGroup>{
          for (final group in groups) group.id: group,
        };
        // Built-ins keyed by their stable built-in key so tests and UI can
        // reference Family/Friends/Avoid/Other deterministically.
        final builtIns = <({String key, contacts.ContactGroup group})>[];
        for (final definition in contacts.ContactBuiltInGroupDefaults.ordered) {
          final row =
              byId[contacts.ContactBuiltInGroupIdentity.idForProfile(
                profileId,
                definition.key,
              )];
          if (row != null) {
            builtIns.add((key: definition.key, group: row));
          }
        }
        final custom = groups
            .where(
              (group) => !contacts.ContactBuiltInGroupIdentity.isBuiltInId(
                group.id,
                profileId,
              ),
            )
            .toList(growable: false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const _GroupSectionSubHeader('Default Groups'),
            for (final entry in builtIns)
              _GroupColorRow(
                rowKey: entry.key,
                name: entry.group.name,
                color: Color(
                  _liveColors[entry.group.id] ?? entry.group.colorValue,
                ),
                onPressed: () => _editGroupColor(context, entry.group, groups),
              ),
            if (custom.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              const _GroupSectionSubHeader('Custom Groups'),
              for (final group in custom)
                _GroupColorRow(
                  rowKey: group.id,
                  name: group.name,
                  color: Color(_liveColors[group.id] ?? group.colorValue),
                  onPressed: () => _editGroupColor(context, group, groups),
                ),
            ],
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'No groups yet. Create one from the Contacts menu.',
                  style: TextStyle(fontSize: 14),
                ),
              ),
          ],
        );
      },
    );
  }
}

final class _GroupColorEditorSheet extends StatefulWidget {
  const _GroupColorEditorSheet({
    required this.groupName,
    required this.initialColor,
    required this.peerColors,
  });

  final String groupName;
  final Color initialColor;
  final List<int> peerColors;

  @override
  State<_GroupColorEditorSheet> createState() => _GroupColorEditorSheetState();
}

final class _GroupColorEditorSheetState extends State<_GroupColorEditorSheet> {
  late Color _draft = widget.initialColor;

  bool _matchesOpaqueRgb(int left, int right) =>
      (left & 0x00FFFFFF) == (right & 0x00FFFFFF);

  Color _checkForeground(int swatchArgb) {
    const dark = 0xFF1A1C1F;
    const light = 0xFFFFFFFF;
    return Color(
      EventColorMath.contrastRatio(dark, swatchArgb) >=
              EventColorMath.contrastRatio(light, swatchArgb)
          ? dark
          : light,
    );
  }

  List<contacts.ContactGroupRecommendedColor> get _availableRecommendedColors =>
      contacts.ContactGroupColorPalette.recommended
          .where(
            (color) =>
                _matchesOpaqueRgb(color.argb, _draft.toARGB32()) ||
                !widget.peerColors.any(
                  (peer) => _matchesOpaqueRgb(peer, color.argb),
                ),
          )
          .toList(growable: false);

  Future<void> _openCustomColor() async {
    final chosen = await showPlannerEventColorPicker(
      context: context,
      eventTypeLabel: widget.groupName,
      role: EventColorRole.accent,
      initialColor: _draft,
      otherColor: Theme.of(context).scaffoldBackgroundColor,
      onChanged: (color) {
        if (mounted) {
          setState(() => _draft = color);
        }
      },
    );
    if (chosen != null && mounted) {
      setState(() => _draft = chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: SingleChildScrollView(
          key: const Key('group-color-editor-scroll'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.outlineOf(context),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Edit Group Color',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Container(
                    key: const Key('group-color-current-swatch'),
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _draft,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    widget.groupName,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Recommended Colors',
                key: Key('group-recommended-colors-title'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  for (final color in _availableRecommendedColors)
                    InkWell(
                      key: Key('group-recommended-color-${color.name}'),
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _draft = Color(color.argb)),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: Semantics(
                            label: color.name,
                            selected: _matchesOpaqueRgb(
                              _draft.toARGB32(),
                              color.argb,
                            ),
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Color(color.argb),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color:
                                      _matchesOpaqueRgb(
                                        _draft.toARGB32(),
                                        color.argb,
                                      )
                                      ? Theme.of(context).colorScheme.onSurface
                                      : Theme.of(context).colorScheme.outline,
                                  width:
                                      _matchesOpaqueRgb(
                                        _draft.toARGB32(),
                                        color.argb,
                                      )
                                      ? 3
                                      : 1,
                                ),
                              ),
                              child:
                                  _matchesOpaqueRgb(
                                    _draft.toARGB32(),
                                    color.argb,
                                  )
                                  ? Icon(
                                      Icons.check,
                                      size: 20,
                                      color: _checkForeground(color.argb),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('group-custom-color'),
                  onPressed: _openCustomColor,
                  icon: const Icon(Icons.palette_outlined, size: 20),
                  label: const Text('Custom Color'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    key: const Key('group-color-editor-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('group-color-editor-save'),
                    onPressed: () => Navigator.of(context).pop(_draft),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _GroupSectionSubHeader extends StatelessWidget {
  const _GroupSectionSubHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

final class _GroupColorRow extends StatelessWidget {
  const _GroupColorRow({
    required this.rowKey,
    required this.name,
    required this.color,
    required this.onPressed,
  });

  final String rowKey;
  final String name;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$name group color, current value ${colorHex(color)}',
      child: SizedBox(
        key: Key('planner-group-color-row-$rowKey'),
        height: 52,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                name,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontSize: 16),
              ),
            ),
            InkWell(
              key: Key('group-color-swatch-$rowKey'),
              onTap: onPressed,
              borderRadius: BorderRadius.circular(22),
              child: SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    child: const SizedBox(width: 28, height: 28),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 40,
              height: 40,
              child: IconButton(
                key: Key('group-color-edit-$rowKey'),
                tooltip: 'Edit $name group color',
                onPressed: onPressed,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 40,
                  height: 40,
                ),
                icon: const Icon(Icons.edit_outlined, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
