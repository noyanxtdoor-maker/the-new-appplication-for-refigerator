import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final outcomeReportingRepositoryProvider = Provider<OutcomeReportingRepository>(
  (ref) {
    throw StateError(
      'OutcomeReportingRepository must be overridden at the app root',
    );
  },
);

final outcomeReportingControllerProvider =
    NotifierProvider<OutcomeReportingController, String?>(
      OutcomeReportingController.new,
    );

final class OutcomeReportingController extends Notifier<String?> {
  OutcomeReportingRepository get _repository =>
      ref.read(outcomeReportingRepositoryProvider);

  String get _profileId {
    final startup = ref.read(startupControllerProvider);
    if (startup is! StartupReady) {
      throw StateError('Outcome reporting requires a ready Local Profile');
    }
    return startup.profile.id;
  }

  @override
  String? build() => null;

  Future<OutcomeReportSource?> readTaskSource(String taskId) {
    return _repository.readTaskSource(profileId: _profileId, taskId: taskId);
  }

  Future<OutcomeReportSource?> readEventSource({
    required String eventId,
    required PlannerDate originalDate,
  }) {
    return _repository.readEventSource(
      profileId: _profileId,
      eventId: eventId,
      originalDate: originalDate,
    );
  }

  Future<List<IndicatorOption>> readIndicatorOptions() {
    return _repository.readIndicatorOptions(_profileId);
  }

  Future<OutcomeReport?> readDraft(String sourceSlotKey) {
    return _repository.readDraftForSlot(
      profileId: _profileId,
      sourceSlotKey: sourceSlotKey,
    );
  }

  Future<OutcomeReport?> readReport(String reportId) {
    return _repository.readReport(profileId: _profileId, reportId: reportId);
  }

  Future<List<OutcomeReport>> readHistory() {
    return _repository.readReportHistory(_profileId);
  }

  Future<List<ActivityLedgerEntry>> readLedgerHistory({
    bool effectiveOnly = true,
  }) {
    return _repository.readLedgerHistory(
      profileId: _profileId,
      effectiveOnly: effectiveOnly,
    );
  }

  Future<OutcomeReport?> saveDraft(OutcomeReportDraft draft) async {
    try {
      final saved = await _repository.saveDraft(
        profileId: _profileId,
        draft: draft,
      );
      state = 'Draft saved locally';
      return saved;
    } on OutcomeReportValidationException catch (error) {
      state = error.message;
      return null;
    } on Object {
      state = 'Draft could not be saved. Your input remains available.';
      return null;
    }
  }

  Future<ReportSubmissionResult?> submit({
    required OutcomeReportDraft draft,
    required String operationId,
  }) async {
    try {
      final result = await _repository.submit(
        profileId: _profileId,
        draft: draft,
        operationId: operationId,
      );
      final planner = ref.read(plannerControllerProvider.notifier);
      await planner.selectDate(
        ref.read(plannerControllerProvider).selectedDate,
      );
      state = result.unchanged
          ? 'This report was already submitted.'
          : 'Report submitted locally';
      return result;
    } on OutcomeReportValidationException catch (error) {
      state = error.message;
      return null;
    } on Object {
      state =
          'Report was not submitted. No partial completion or contribution '
          'was saved.';
      return null;
    }
  }

  /// Persists an Event's selected Current Status without opening a report
  /// form. The repository submission remains the single transactional write
  /// path, so history, ledger contributions, and planner refresh stay coupled
  /// and idempotent.
  Future<ReportSubmissionResult?> submitEventStatus({
    required String eventId,
    required PlannerDate originalDate,
    required OutcomeKind outcome,
    required String operationId,
    String? contributionRuleKey,
  }) async {
    try {
      final source = await readEventSource(
        eventId: eventId,
        originalDate: originalDate,
      );
      if (source == null) {
        state = 'This Calendar Event is no longer available.';
        return null;
      }

      final current = (await readHistory())
          .where(
            (report) =>
                report.status == OutcomeReportStatus.submitted &&
                report.source.slotKey == source.slotKey,
          )
          .firstOrNull;
      if (current?.outcome == outcome) {
        final entries = (await readLedgerHistory(effectiveOnly: false))
            .where((entry) => entry.sourceReportId == current!.id)
            .toList(growable: false);
        state = 'Status already saved locally.';
        return ReportSubmissionResult(
          report: current!,
          entries: entries,
          unchanged: true,
        );
      }

      final draft = await readDraft(source.slotKey);
      final rule = ScheduledPotentialRule.tryParse(contributionRuleKey);
      final contributions = outcome == OutcomeKind.didNotHappen || rule == null
          ? const <ContributionDraft>[]
          : <ContributionDraft>[
              ContributionDraft(
                ruleKey: rule.encode(),
                indicatorKey: rule.indicatorKey,
                value: IndicatorValue(
                  scaledValue: rule.value.scaledValue,
                  scale: rule.value.scale,
                  unit: rule.value.unit,
                ),
              ),
            ];
      final result = await submit(
        draft: OutcomeReportDraft(
          id: draft?.id ?? ref.read(plannerIdentifierSourceProvider).nextUuid(),
          source: source,
          activityDate: source.activityDate,
          outcome: outcome,
          correctsReportId: current?.id,
          correctionReason: current == null
              ? null
              : 'Current Status corrected directly.',
          contributions: contributions,
          allowUnstructuredPartial: true,
        ),
        operationId: operationId,
      );
      if (result != null) {
        state = result.unchanged
            ? 'Status already saved locally.'
            : 'Status saved locally.';
      }
      return result;
    } on OutcomeReportValidationException catch (error) {
      state = error.message;
      return null;
    } on Object {
      state =
          'Status was not saved. No partial completion or contribution '
          'was recorded.';
      return null;
    }
  }

  /// Commits a Task Current Status through the canonical outcome-report
  /// transaction that owns factual Activity History. It is deliberately a
  /// direct Task-preview action; Task Edit owns Task facts, not a duplicate
  /// reporting surface.
  Future<ReportSubmissionResult?> submitTaskStatus({
    required String taskId,
    required OutcomeKind outcome,
    required String operationId,
  }) async {
    try {
      final task = await ref
          .read(plannerControllerProvider.notifier)
          .readTask(taskId);
      if (task == null) {
        state = 'This Task is no longer available.';
        return null;
      }
      final source = await readTaskSource(taskId);
      if (source == null) {
        state = 'This Task is no longer available.';
        return null;
      }
      final current = (await readHistory())
          .where(
            (report) =>
                report.status == OutcomeReportStatus.submitted &&
                report.source.slotKey == source.slotKey,
          )
          .firstOrNull;
      if (current?.outcome == outcome) {
        final entries = (await readLedgerHistory(effectiveOnly: false))
            .where((entry) => entry.sourceReportId == current!.id)
            .toList(growable: false);
        state = 'Status already saved locally.';
        return ReportSubmissionResult(
          report: current!,
          entries: entries,
          unchanged: true,
        );
      }
      final draft = await readDraft(source.slotKey);
      final contributions = outcome == OutcomeKind.didNotHappen
          ? const <ContributionDraft>[]
          : await _taskReportContributions(task);
      final result = await submit(
        draft: OutcomeReportDraft(
          id: draft?.id ?? ref.read(plannerIdentifierSourceProvider).nextUuid(),
          source: source,
          activityDate: source.activityDate,
          outcome: outcome,
          correctsReportId: current?.id,
          correctionReason: current == null
              ? null
              : 'Task Current Status corrected directly.',
          contributions: contributions,
          // Current Status is a truthful categorical outcome; it does not
          // manufacture a numeric partial-completion value.
          allowUnstructuredPartial: true,
        ),
        operationId: operationId,
      );
      if (result != null) {
        state = result.unchanged
            ? 'Status already saved locally.'
            : 'Status saved locally.';
      }
      return result;
    } on OutcomeReportValidationException catch (error) {
      state = error.message;
      return null;
    } on Object {
      state =
          'Status was not saved. No partial completion or contribution '
          'was recorded.';
      return null;
    }
  }

  /// Returns a Task Current Status to factual Unreported through the same
  /// outcome repository. The former report remains superseded history and any
  /// effective contribution is reversed; no Task lifecycle state is changed.
  Future<bool> clearTaskStatus({
    required String taskId,
    required String operationId,
  }) async {
    try {
      final task = await ref
          .read(plannerControllerProvider.notifier)
          .readTask(taskId);
      if (task == null) {
        state = 'This Task is no longer available.';
        return false;
      }
      final source = await readTaskSource(taskId);
      if (source == null) {
        state = 'This Task is no longer available.';
        return false;
      }
      final cleared = await _repository.clearSubmittedStatus(
        profileId: _profileId,
        source: source,
        operationId: operationId,
        correctionReason: 'Task Current Status returned to Unreported.',
      );
      await ref
          .read(plannerControllerProvider.notifier)
          .selectDate(ref.read(plannerControllerProvider).selectedDate);
      state = cleared
          ? 'Status returned to Unreported.'
          : 'Already Unreported.';
      return true;
    } on OutcomeReportValidationException catch (error) {
      state = error.message;
      return false;
    } on Object {
      state = 'Status was not changed. No Task data was modified.';
      return false;
    }
  }

  Future<List<ContributionDraft>> _taskReportContributions(
    PlannerTask task,
  ) async {
    final rule = ScheduledPotentialRule.tryParse(task.contributionRuleKey);
    if (rule != null) {
      return <ContributionDraft>[
        ContributionDraft(
          ruleKey: rule.encode(),
          indicatorKey: rule.indicatorKey,
          value: IndicatorValue(
            scaledValue: rule.value.scaledValue,
            scale: rule.value.scale,
            unit: rule.value.unit,
          ),
        ),
      ];
    }
    final goalId = task.goalId;
    if (goalId == null) {
      return const <ContributionDraft>[];
    }
    final goal = await ref.read(goalByIdProvider(goalId).future);
    final indicatorKey = goal?.indicatorKey;
    if (indicatorKey == null || indicatorKey.isEmpty) {
      return const <ContributionDraft>[];
    }
    return <ContributionDraft>[
      ContributionDraft(
        ruleKey: 'task-goal:$goalId',
        indicatorKey: indicatorKey,
        value: const IndicatorValue(scaledValue: 1, scale: 0, unit: 'count'),
      ),
    ];
  }

  void clearMessage() {
    state = null;
  }
}
