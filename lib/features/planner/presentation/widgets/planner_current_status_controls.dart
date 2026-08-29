import 'package:flutter/material.dart';

import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_report_status_icons.dart';

/// A domain-neutral selectable status offered by [PlannerCurrentStatusControlRow].
///
/// Event and Task previews map their own canonical values to these visual
/// facts. This keeps the approved control implementation shared without
/// creating a second reporting store or allowing Event-only states for Tasks.
final class PlannerPreviewStatusOption {
  const PlannerPreviewStatusOption({
    required this.id,
    required this.label,
    required this.kind,
    this.enabled = true,
  });

  final String id;
  final String label;
  final PlannerReportStatusKind kind;
  final bool enabled;
}

/// The one production Current Status presentation for Planner previews.
final class PlannerCurrentStatusControlRow extends StatelessWidget {
  const PlannerCurrentStatusControlRow({
    required this.currentLabel,
    required this.currentKind,
    required this.selectedId,
    required this.options,
    required this.saving,
    required this.onSelect,
    required this.controlKey,
    required this.currentLabelKey,
    required this.optionKeyPrefix,
    super.key,
  });

  final String currentLabel;
  final PlannerReportStatusKind currentKind;
  final String selectedId;
  final List<PlannerPreviewStatusOption> options;
  final bool saving;
  final ValueChanged<String> onSelect;
  final Key controlKey;
  final Key currentLabelKey;
  final String optionKeyPrefix;

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
                currentLabel,
                key: currentLabelKey,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: PlannerEventReportStatus.labelColorFor(
                    context,
                    currentKind,
                  ),
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
          _PlannerPreviewStatusButton(
            key: Key('$optionKeyPrefix${option.id}'),
            option: option,
            selected: option.id == selectedId,
            enabled: !saving && option.enabled,
            onTap: () => onSelect(option.id),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }
}

final class _PlannerPreviewStatusButton extends StatelessWidget {
  const _PlannerPreviewStatusButton({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final PlannerPreviewStatusOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: option.label,
      child: Tooltip(
        message: option.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: PlannerReportStatusIcon(
                kind: option.kind,
                size: 21,
                semanticLabel: option.label,
                style: selected
                    ? PlannerReportStatusIconStyle.selected
                    : PlannerReportStatusIconStyle.unselected,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
