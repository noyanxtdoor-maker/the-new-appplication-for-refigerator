import 'package:flutter/material.dart';

import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/presentation/widgets/current_status_control_row.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';

/// VS-11C1B.5: Task-specific adapter for the shared [CurrentStatusControlRow]
/// presentation primitive.
///
/// Maps Task report statuses to the shared visual presentation:
///   - Unreported: no report yet (display state)
///   - Did Not Attempt: didNotHappen outcome
///   - Completed: completedHappened outcome
///
/// The adapter uses the same visual language as Event Current Status
/// but routes through the Task reporting backend. Historical Missed remains a
/// read-only effective value; it is deliberately not included in this
/// selectable list.
class TaskCurrentStatusControlRow extends StatelessWidget {
  const TaskCurrentStatusControlRow({
    required this.currentStatus,
    required this.isReportEligible,
    required this.saving,
    required this.onSelect,
    this.controlKey = const Key('current-status-control'),
    this.currentStatusLabelKey = const Key('current-status-label'),
    super.key,
  });

  /// The current report status (null = Unreported).
  final OutcomeKind? currentStatus;

  /// Whether the Task is eligible for reporting (time has passed).
  final bool isReportEligible;

  /// Whether a save is in progress.
  final bool saving;

  /// Called when a status is selected. The adapter maps [OutcomeKind] to
  /// the appropriate Task backend call.
  final ValueChanged<OutcomeKind?> onSelect;

  /// Adapter-specific semantic keys used by the Task preview without
  /// changing the shared form presentation.
  final Key controlKey;
  final Key currentStatusLabelKey;

  @override
  Widget build(BuildContext context) {
    if (!isReportEligible) {
      return const SizedBox.shrink();
    }

    final effective = currentStatus;
    final currentKind = _kindForOutcome(effective);

    return CurrentStatusControlRow<OutcomeKind?>(
      currentStatusLabel: _labelForOutcome(effective),
      currentLabelColor: PlannerEventReportStatus.labelColorFor(
        context,
        currentKind,
      ),
      options: _buildOptions(effective),
      saving: saving,
      onSelect: onSelect,
      controlKey: controlKey,
      currentStatusLabelKey: currentStatusLabelKey,
    );
  }

  List<CurrentStatusOption<OutcomeKind?>> _buildOptions(
    OutcomeKind? effective,
  ) {
    return [
      CurrentStatusOption<OutcomeKind?>(
        key: 'unreported',
        value: null,
        label: 'Unreported',
        icon: Icons.error_outline,
        iconColor: PlannerEventReportStatus.unreportedColor,
        selected: effective == null,
        reportStatusKind: PlannerReportStatusKind.unreported,
      ),
      CurrentStatusOption<OutcomeKind?>(
        key: 'did_not_attempt',
        value: OutcomeKind.didNotHappen,
        label: 'Did Not Attempt',
        icon: Icons.remove_circle_outline,
        iconColor: PlannerEventReportStatus.didNotAttemptColor,
        selected: effective == OutcomeKind.didNotHappen,
        reportStatusKind: PlannerReportStatusKind.didNotAttempt,
      ),
      CurrentStatusOption<OutcomeKind?>(
        key: 'completed',
        value: OutcomeKind.completedHappened,
        label: 'Completed',
        icon: Icons.check_circle_outline,
        iconColor: PlannerEventReportStatus.completedColor,
        selected: effective == OutcomeKind.completedHappened,
        reportStatusKind: PlannerReportStatusKind.completed,
        legacyKeys: const <Key>[Key('task-stage-status-completed')],
      ),
    ];
  }

  static String _labelForOutcome(OutcomeKind? outcome) {
    return switch (outcome) {
      null => 'Unreported',
      OutcomeKind.partiallyCompleted => 'Missed (legacy)',
      OutcomeKind.didNotHappen => 'Did Not Attempt',
      OutcomeKind.completedHappened => 'Completed',
    };
  }

  static PlannerReportStatusKind _kindForOutcome(OutcomeKind? outcome) {
    return switch (outcome) {
      null => PlannerReportStatusKind.unreported,
      OutcomeKind.partiallyCompleted => PlannerReportStatusKind.missedAttempted,
      OutcomeKind.didNotHappen => PlannerReportStatusKind.didNotAttempt,
      OutcomeKind.completedHappened => PlannerReportStatusKind.completed,
    };
  }
}
