import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

final class IndicatorOption {
  const IndicatorOption({
    required this.key,
    required this.label,
    required this.unit,
    required this.position,
  });

  final String key;
  final String label;
  final String unit;
  final int position;
}

abstract interface class OutcomeReportingRepository {
  Future<OutcomeReportSource?> readTaskSource({
    required String profileId,
    required String taskId,
  });

  Future<OutcomeReportSource?> readEventSource({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
  });

  Future<List<IndicatorOption>> readIndicatorOptions(String profileId);

  Future<OutcomeReport?> readDraftForSlot({
    required String profileId,
    required String sourceSlotKey,
  });

  Future<OutcomeReport?> readReport({
    required String profileId,
    required String reportId,
  });

  Future<List<OutcomeReport>> readReportHistory(String profileId);

  Future<List<ActivityLedgerEntry>> readLedgerHistory({
    required String profileId,
    String? indicatorKey,
    PlannerDate? startDate,
    PlannerDate? endDate,
    bool effectiveOnly = true,
  });

  Future<OutcomeReport> saveDraft({
    required String profileId,
    required OutcomeReportDraft draft,
  });

  Future<ReportSubmissionResult> submit({
    required String profileId,
    required OutcomeReportDraft draft,
    required String operationId,
  });

  /// Removes the current effective status while preserving the submitted
  /// report as superseded factual history and reversing only its effective
  /// ledger entries.  The source remains the canonical owner of the slot.
  Future<bool> clearSubmittedStatus({
    required String profileId,
    required OutcomeReportSource source,
    required String operationId,
    required String correctionReason,
  });

  Future<IndicatorActual> readActual({
    required String profileId,
    required String indicatorKey,
    required PlannerDate startDate,
    required PlannerDate endDate,
  });

  Future<List<IndicatorActual>> rebuildActuals({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  });

  Future<LedgerProjectionAudit> auditProjection(String profileId);
}
