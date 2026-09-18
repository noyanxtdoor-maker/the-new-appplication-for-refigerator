import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/goals/domain/goal_event_type_policy.dart';
import 'package:rmplanner/features/planner/application/event_type_creation_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/event_type_creation_choice.dart';
import 'package:rmplanner/features/planner/presentation/widgets/anchored_top_bar_popup.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_color_resolver.dart';

sealed class EventTypePickerSelection {
  const EventTypePickerSelection();
}

final class EventTypePickerEvent extends EventTypePickerSelection {
  const EventTypePickerEvent(this.eventType, {this.binding});

  final EventType eventType;

  /// Live Goal alias at selection time, when the chosen canonical type had
  /// an eligible occupant. Additive: existing constructions without this
  /// argument are unchanged and [eventType] stays the raw type.
  final LiveGoalEventTypeBinding? binding;
}

final class EventTypePickerTask extends EventTypePickerSelection {
  const EventTypePickerTask();
}

Future<EventTypePickerSelection?> showEventTypePicker({
  required BuildContext context,
  required WidgetRef ref,
  String? recommendedEventTypeId,
  String? recommendedIndicatorKey,
  Set<String>? allowedStableKeys,
  bool includeTask = true,
}) async {
  final controller = ref.read(eventTypeControllerProvider.notifier);
  // O1/O10: reuse a warm same-profile successful load; cold/foreign states
  // still wait here.  The eligibility consumers below stay fail-closed on
  // their own AsyncValue, so readiness is never inferred from this await.
  await controller.ensureLoaded();
  if (!context.mounted) {
    return null;
  }

  var recommendedId = recommendedEventTypeId;
  if (recommendedId == null && recommendedIndicatorKey != null) {
    recommendedId = (await controller.exactTypeForIndicator(
      recommendedIndicatorKey,
    ))?.id;
  }
  if (!context.mounted) {
    return null;
  }

  final state = ref.read(eventTypeControllerProvider);
  if (state.message != null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(state.message!)));
    return null;
  }
  return showDialog<EventTypePickerSelection>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    useSafeArea: false,
    builder: (dialogContext) {
      // Consumer inside the dialog: the open sheet rebuilds when the raw
      // controller or the live bindings change (archive/reoccupation while
      // open), per contract C/E.
      return Consumer(
        builder: (context, ref, _) {
          final choicesAsync = ref.watch(eventTypeCreationChoicesProvider);
          return LayoutBuilder(
            builder: (context, constraints) {
              final media = MediaQuery.of(context);
              final topOffset = media.padding.top + kToolbarHeight + 13;
              // Delta 4.2D restores the last known-good Next Transfer selector
              // width. Filtering and selection semantics remain unchanged.
              final cardWidth = math.min(347.0, constraints.maxWidth - 32);
              final cardHeight = math.max(
                1.0,
                math.min(672.0, constraints.maxHeight - topOffset - 16),
              );
              // The projection is a FutureProvider, so EVERY re-resolution
              // (raw controller change, Goal change stream emission,
              // presentation-document write) publishes AsyncLoading while
              // Riverpod keeps the previous list in `value`. Resolving through
              // `maybeWhen(orElse:)` discarded that retained list, so an open
              // selector collapsed to `choices.isEmpty` and rendered
              // 'No active Event Types are available.' for one to five frames
              // per refresh — a false statement about the profile's data.
              // Render the retained list instead; `choicesReady` below keeps
              // those rows non-actionable until the fresh projection lands, so
              // the archive/reoccupation tap guard is preserved (and made
              // strictly tighter, since it now also covers a failed
              // projection carrying a stale value).
              final retainedChoices = choicesAsync.value;
              final ordered = retainedChoices == null
                  ? const <EventTypeCreationChoice>[]
                  : EventTypeCreationChoice.orderedForPicker(
                      retainedChoices,
                      recommendedEventTypeId: recommendedId,
                      allowedStableKeys: allowedStableKeys,
                    );
              return Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: topOffset),
                  child: SizedBox(
                    width: cardWidth,
                    height: cardHeight,
                    child: _EventTypePickerSheet(
                      choices: ordered,
                      choicesReady:
                          choicesAsync.hasValue &&
                          !choicesAsync.isLoading &&
                          !choicesAsync.hasError,
                      recommendedEventTypeId: recommendedId,
                      eventColorsByTypeId: ref
                          .read(eventTypeControllerProvider)
                          .resolvedEventColorsByTypeId,
                      taskAccentColor: Color(
                        ref
                                .read(eventTypeControllerProvider)
                                .eventColors[PlannerEventColorResolver
                                    .taskStableKey]
                                ?.accentArgb ??
                            PlannerEventColorDefaults.task.accentArgb,
                      ),
                      includeTask: includeTask,
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    },
  );
}

/// Opens the compact, text-only Event Type menu used by the shared form.
/// The large selector remains the entry flow's source picker; this anchored
/// menu is deliberately a separate presentation so changing a type in an
/// existing form does not replace the form with another card hierarchy.
Future<EventType?> showEventTypeDropdown({
  required BuildContext context,
  required WidgetRef ref,
  required GlobalKey anchorKey,
  String? selectedEventTypeId,
  String? recommendedIndicatorKey,
}) async {
  final fieldContext = anchorKey.currentContext;
  final fieldBox = fieldContext?.findRenderObject() as RenderBox?;
  if (fieldBox == null || !fieldBox.hasSize) {
    return null;
  }
  final controller = ref.read(eventTypeControllerProvider.notifier);
  // O1/O10: opening the type dropdown on an already-warm same profile must not
  // force a redundant reload before the options can render.
  await controller.ensureLoaded();
  if (!context.mounted) {
    return null;
  }

  var recommendedId = selectedEventTypeId;
  if (recommendedId == null && recommendedIndicatorKey != null) {
    recommendedId = (await controller.exactTypeForIndicator(
      recommendedIndicatorKey,
    ))?.id;
  }
  if (!context.mounted) {
    return null;
  }

  final state = ref.read(eventTypeControllerProvider);
  if (state.message != null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(state.message!)));
    return null;
  }
  if (!context.mounted) {
    return null;
  }
  EventType? selected;
  await showAnchoredTopBarPopup(
    context: context,
    triggerKey: anchorKey,
    width: fieldBox.size.width,
    maxHeight: 336,
    topGap: 5,
    borderRadius: 5,
    builder: (popupContext) => Consumer(
      builder: (context, ref, _) {
        final current = ref.watch(eventTypeCreationChoicesProvider);
        final choices = current.maybeWhen(
          data: (value) => EventTypeCreationChoice.orderedForDropdown(value),
          // Never keep the previous eligible list active while a fresh
          // profile/Goal binding projection is loading or has failed. This
          // closes the archive/reoccupation tap race; the popup stays open
          // and repopulates only after current eligibility resolves.
          orElse: () => const <EventTypeCreationChoice>[],
        );
        final ready = current.hasValue;
        return SingleChildScrollView(
          key: const Key('event-type-dropdown-scroll'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final choice in choices)
                SizedBox(
                  height: 48,
                  child: InkWell(
                    key: Key(
                      'event-type-dropdown-option-${choice.type.stableKey}',
                    ),
                    onTap: ready
                        ? () {
                            selected = choice.type;
                            anchoredTopBarPopupController.dismiss();
                          }
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              choice.displayLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight:
                                    choice.type.id == selectedEventTypeId
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (choice.type.id == selectedEventTypeId)
                            const Icon(Icons.check, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
  return selected;
}

final class _EventTypePickerSheet extends StatelessWidget {
  const _EventTypePickerSheet({
    required this.choices,
    required this.choicesReady,
    required this.recommendedEventTypeId,
    required this.eventColorsByTypeId,
    required this.taskAccentColor,
    required this.includeTask,
  });

  final List<EventTypeCreationChoice> choices;
  final bool choicesReady;
  final String? recommendedEventTypeId;
  final Map<String, EventColorPreference> eventColorsByTypeId;

  /// The LIVE configured accent of the canonical Task identity. The Task row
  /// is not an `activity_types` row, so it is never present in
  /// [eventColorsByTypeId]; it must not fall back to a hard-coded literal or
  /// the selector would disagree with Settings > Colors after a customization.
  final Color taskAccentColor;
  final bool includeTask;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final onSurface = AppTheme.onFillTextOf(context, 1.0);
    return Material(
      key: const Key('event-type-picker'),
      color: AppTheme.surfaceOf(context),
      elevation: 0,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
            child: SizedBox(
              height: 28,
              child: Text(
                'Select Event Type',
                style: TextStyle(
                  color: onSurface,
                  fontSize: 20,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              key: const Key('event-type-picker-scroll'),
              child: choices.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Text(
                        'No active Event Types are available.',
                        style: TextStyle(color: onSurface),
                      ),
                    )
                  : Column(
                      key: const Key('event-type-picker-list'),
                      children: <Widget>[
                        for (final choice in choices)
                          _buildEventTypeRow(context, choice),
                        if (includeTask) _buildTaskRow(context),
                      ],
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 40, bottom: 46),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('event-type-picker-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: EdgeInsets.zero,
                  foregroundColor: colorScheme.primary,
                ),
                child: Text(
                  'Cancel',
                  style: TextStyle(
                    color: colorScheme.primary,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventTypeRow(
    BuildContext context,
    EventTypeCreationChoice choice,
  ) {
    final type = choice.type;
    final recommended = type.id == recommendedEventTypeId;
    return Semantics(
      button: true,
      label:
          '${choice.displayLabel} Event Type${recommended ? ', Recommended' : ''}',
      child: InkWell(
        key: Key('event-type-option-${type.stableKey}'),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        // Current eligibility tap guard (contract C): rows only exist for
        // eligible types, and a tap is rejected when inputs are not ready.
        onTap: choicesReady
            ? () => Navigator.of(
                context,
              ).pop(EventTypePickerEvent(type, binding: choice.binding))
            : null,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Row(
              children: <Widget>[
                Container(
                  key: Key('event-type-icon-${type.stableKey}'),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: PlannerEventColorResolver.accentColorForType(
                      type,
                      eventColorsByTypeId,
                    ),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // Goal-title alias for live slots; raw label otherwise.
                    // Long aliases wrap to one line with ellipsis inside the
                    // existing 44dp row; full text stays in Semantics above.
                    choice.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.onFillTextOf(context, 1.0),
                      fontSize: 17,
                      height: 24 / 17,
                      fontWeight: recommended
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (recommended)
                  SizedBox(
                    key: Key('event-type-recommended-${type.stableKey}'),
                    width: 0,
                    height: 0,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTaskRow(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Task entry',
      child: InkWell(
        key: const Key('event-type-option-task'),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        onTap: choicesReady
            ? () => Navigator.of(context).pop(const EventTypePickerTask())
            : null,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Row(
              children: <Widget>[
                DecoratedBox(
                  key: const Key('event-type-icon-planner_task'),
                  decoration: BoxDecoration(
                    color: taskAccentColor,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox(width: 22, height: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Task',
                    style: TextStyle(
                      color: AppTheme.onFillTextOf(context, 1.0),
                      fontSize: 17,
                      height: 24 / 17,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
