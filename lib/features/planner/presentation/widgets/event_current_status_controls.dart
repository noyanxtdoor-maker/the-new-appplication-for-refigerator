import 'package:flutter/material.dart';

import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_report_status_icons.dart';

/// Form-only, staged Event outcome selector. This widget has no persistence
/// dependency: the enclosing Event editor owns Save and Cancel boundaries.
final class EventCurrentStatusControlRow extends StatelessWidget {
  const EventCurrentStatusControlRow({
    required this.currentStatus,
    required this.isContactEvent,
    required this.saving,
    required this.onSelect,
    super.key,
  });

  final CalendarEventStatus currentStatus;
  final bool isContactEvent;
  final bool saving;
  final ValueChanged<CalendarEventStatus> onSelect;

  @override
  Widget build(BuildContext context) {
    final kind = PlannerEventReportStatus.kindForStatus(
      currentStatus,
      isContactEvent: isContactEvent,
    );
    return Row(
      key: const Key('event-status-control'),
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
                calendarEventOutcomeLabel(
                  status: currentStatus,
                  isContactEvent: isContactEvent,
                ),
                key: const Key('event-status-current-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: PlannerEventReportStatus.labelColorFor(context, kind),
                  fontSize: 17,
                  height: 20 / 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        for (final status in _statuses(isContactEvent)) ...<Widget>[
          _StatusButton(
            key: Key('event-status-option-${status.name}'),
            status: status,
            isContactEvent: isContactEvent,
            selected: status == currentStatus,
            enabled: !saving &&
                (status != CalendarEventStatus.scheduled ||
                    currentStatus == CalendarEventStatus.scheduled),
            onTap: () => onSelect(status),
          ),
          const SizedBox(width: 6),
        ],
      ],
    );
  }

  static List<CalendarEventStatus> _statuses(bool isContactEvent) =>
      const <CalendarEventStatus>[
        CalendarEventStatus.scheduled,
        CalendarEventStatus.didNotHappen,
        CalendarEventStatus.partiallyCompleted,
        CalendarEventStatus.completedHappened,
      ];
}

final class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.status,
    required this.isContactEvent,
    required this.selected,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final CalendarEventStatus status;
  final bool isContactEvent;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kind = PlannerEventReportStatus.kindForStatus(
      status,
      isContactEvent: isContactEvent,
    );
    final label = PlannerEventReportStatus.labelFor(
      kind,
      isContactEvent: isContactEvent,
    );
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: PlannerReportStatusIcon(
                kind: kind,
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
}
