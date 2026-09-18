import 'package:flutter/material.dart';

import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_report_status_icons.dart';

/// VS-11C1B.5: Shared presentation primitive for the compact Current Status
/// control row used by both Calendar Event and Task reporting UIs.
///
/// The current status label sits on the left and the direct-selection
/// controls sit on the right. Tapping a control only reports intent through
/// [onSelect]; nothing is persisted by this widget. The selected control uses
/// a filled treatment while the unselected ones use a neutral outline, so the
/// state never relies on color alone.
///
/// This widget is agnostic to the status model — adapters provide the
/// display label, selectable options, and selection callbacks.
class CurrentStatusControlRow<T> extends StatelessWidget {
  const CurrentStatusControlRow({
    required this.currentStatusLabel,
    required this.currentLabelColor,
    required this.options,
    required this.saving,
    required this.onSelect,
    this.controlKey = const Key('current-status-control'),
    this.currentStatusLabelKey = const Key('current-status-label'),
    this.optionKeyBuilder,
    super.key,
  });

  /// The human-readable label for the current status (e.g., "Unreported").
  final String currentStatusLabel;

  /// The color for the current status label text.
  final Color currentLabelColor;

  /// The list of selectable status options.
  final List<CurrentStatusOption<T>> options;

  /// Whether a save is in progress (disables taps).
  final bool saving;

  /// Called when a status option is selected. The adapter maps T to the
  /// appropriate backend call.
  final ValueChanged<T> onSelect;

  /// Stable semantic key for the row. Adapters use this only to preserve
  /// existing journey-test hooks while sharing the same presentation.
  final Key controlKey;

  /// Stable semantic key for the selected-status label.
  final Key currentStatusLabelKey;

  /// Optional adapter-specific keys for the selectable option wrappers.
  final Key Function(CurrentStatusOption<T> option)? optionKeyBuilder;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: controlKey,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Current Status',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AppTheme.detailCaptionOf(context),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                currentStatusLabel,
                key: currentStatusLabelKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: currentLabelColor,
                  fontSize: 17,
                  height: 20 / 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        for (final option in options) ...<Widget>[
          _CurrentStatusControlButton(
            key:
                optionKeyBuilder?.call(option) ??
                Key('current-status-option-${option.key}'),
            label: option.label,
            icon: option.icon,
            iconColor: option.iconColor,
            reportStatusKind: option.reportStatusKind,
            isContactEvent: option.isContactEvent,
            selected: option.selected,
            enabled: !saving,
            onTap: () => onSelect(option.value),
          ).withLegacyKeys(option.legacyKeys),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}

/// A single selectable status option for [CurrentStatusControlRow].
class CurrentStatusOption<T> {
  const CurrentStatusOption({
    required this.key,
    required this.value,
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.selected,
    this.reportStatusKind,
    this.isContactEvent = false,
    this.legacyKeys = const <Key>[],
  });

  /// Unique key for identification (e.g., 'completed', 'missed').
  final String key;

  /// The status value to pass to the adapter.
  final T value;

  /// The human-readable label for tooltip/semantics.
  final String label;

  /// The icon to display.
  final IconData icon;

  /// The color for the icon.
  final Color iconColor;

  /// Whether this option is currently selected.
  final bool selected;

  /// Optional canonical vector status kind. When present, the shared control
  /// renders the same CustomPaint icon used by Planner Event surfaces.
  final PlannerReportStatusKind? reportStatusKind;

  /// Whether the option belongs to a Contact Event label context.
  final bool isContactEvent;

  /// Compatibility finder hooks retained by older journey tests. These are
  /// presentation aliases only; they do not create a second control.
  final List<Key> legacyKeys;
}

/// Compact direct-selection control: 48 x 48 touch target with a ~21 dp icon.
/// Selected state communicated by fill (never color alone).
class _CurrentStatusControlButton extends StatelessWidget {
  const _CurrentStatusControlButton({
    required this.label,
    required this.icon,
    required this.iconColor,
    this.reportStatusKind,
    this.isContactEvent = false,
    required this.selected,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color iconColor;
  final PlannerReportStatusKind? reportStatusKind;
  final bool isContactEvent;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          key: Key('status-button-$label'),
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: reportStatusKind == null
                  ? Icon(
                      selected ? icon : _outlined(icon),
                      size: 21,
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    )
                  : PlannerReportStatusIcon(
                      kind: reportStatusKind!,
                      size: 21,
                      style: selected
                          ? PlannerReportStatusIconStyle.selected
                          : PlannerReportStatusIconStyle.unselected,
                      isContactEvent: isContactEvent,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget withLegacyKeys(List<Key> keys) {
    Widget child = this;
    for (final key in keys.reversed) {
      child = KeyedSubtree(key: key, child: child);
    }
    return child;
  }

  static IconData _outlined(IconData icon) {
    return switch (icon) {
      Icons.check_circle => Icons.check_circle_outline,
      Icons.remove_circle => Icons.remove_circle_outline,
      Icons.block => Icons.block_outlined,
      Icons.error => Icons.error_outline,
      _ => icon,
    };
  }
}
