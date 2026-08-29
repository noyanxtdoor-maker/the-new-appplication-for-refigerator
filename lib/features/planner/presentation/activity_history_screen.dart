import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';

final class ActivityHistoryScreen extends ConsumerStatefulWidget {
  const ActivityHistoryScreen({this.sourceSlotKey, super.key});

  /// When supplied by a Preview, the same History presentation is restricted
  /// to that canonical source slot. The global route leaves it null.
  final String? sourceSlotKey;

  @override
  ConsumerState<ActivityHistoryScreen> createState() =>
      _ActivityHistoryScreenState();
}

final class _ActivityHistoryScreenState
    extends ConsumerState<ActivityHistoryScreen> {
  late Future<_ActivityHistoryData> _load;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final controller = ref.read(outcomeReportingControllerProvider.notifier);
    _load =
        Future.wait<Object>(<Future<Object>>[
          controller.readHistory(),
          controller.readLedgerHistory(effectiveOnly: false),
        ]).then(
          (values) => _ActivityHistoryData(
            reports: (values[0] as List<OutcomeReport>)
                .where(
                  (report) =>
                      widget.sourceSlotKey == null ||
                      report.source.slotKey == widget.sourceSlotKey,
                )
                .toList(growable: false),
            entries: values[1] as List<ActivityLedgerEntry>,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Activity History')),
      body: SafeArea(
        child: FutureBuilder<_ActivityHistoryData>(
          future: _load,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text(
                        'Activity history could not be opened. No local data '
                        'was changed.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      FilledButton(
                        onPressed: () => setState(_reload),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final data = snapshot.data!;
            if (data.reports.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No status activity recorded yet.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                setState(_reload);
                await _load;
              },
              child: ListView(
                key: const Key('activity-history-list'),
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                children: <Widget>[
                  const _HistoryNotice(),
                  const SizedBox(height: 12),
                  for (final report in data.reports)
                    _ReportHistoryCard(
                      report: report,
                      entries: data.entries
                          .where((entry) => entry.sourceReportId == report.id)
                          .toList(growable: false),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _ActivityHistoryData {
  const _ActivityHistoryData({required this.reports, required this.entries});

  final List<OutcomeReport> reports;
  final List<ActivityLedgerEntry> entries;
}

final class _HistoryNotice extends StatelessWidget {
  const _HistoryNotice();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.verified_outlined),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Effective status changes appear first. Corrections never '
                'overwrite history: reversals and replacements remain auditable, while '
                'Actual is derived only from effective ledger entries.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ReportHistoryCard extends StatelessWidget {
  const _ReportHistoryCard({required this.report, required this.entries});

  final OutcomeReport report;
  final List<ActivityLedgerEntry> entries;

  @override
  Widget build(BuildContext context) {
    final effective = report.status == OutcomeReportStatus.submitted;
    return Card(
      key: Key('activity-history-entry-${report.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: Icon(
          _historyIcon(report),
          color: _historyColor(context, report),
        ),
        title: Text(report.source.label),
        subtitle: Text(
          '${report.activityDate.iso8601} · '
          '${_outcomeLabel(report.outcome, report.source.isContactEvent)} · '
          '${effective ? 'Effective' : 'Superseded'}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: <Widget>[
          if (report.correctsReportId != null)
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.edit_note_outlined),
              title: Text('Corrected status'),
              subtitle: Text(
                'The original status remains preserved in this history.',
              ),
            ),
          if (report.correctionReason != null)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.subject),
              title: const Text('Correction note'),
              subtitle: Text(report.correctionReason!),
            ),
          if (entries.isEmpty)
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('No contribution was recorded.'),
            )
          else
            for (final entry in entries)
              ListTile(
                key: Key('ledger-entry-${entry.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  entry.type == ActivityLedgerEntryType.reversal
                      ? Icons.undo
                      : Icons.add_chart,
                ),
                title: Text(
                  '${entry.value.displayValue} ${entry.value.unit} · '
                  '${entry.indicatorKey}',
                ),
                subtitle: Text(
                  entry.type == ActivityLedgerEntryType.reversal
                      ? 'Reversal preserved for audit'
                      : entry.isEffective
                      ? 'Effective contribution'
                      : 'Reversed contribution',
                ),
              ),
        ],
      ),
    );
  }

  static String _outcomeLabel(OutcomeKind? outcome, bool isContactEvent) {
    return switch (outcome) {
      // Planner Polish Delta 2 final matrix: the success outcome reads
      // 'Completed' for BOTH Contact and generic Events.
      OutcomeKind.completedHappened => 'Completed',
      // NX-03: the user-facing partial outcome is 'Missed' for Contact and
      // generic Events alike; the stored MISSED_ATTEMPTED value is internal.
      OutcomeKind.partiallyCompleted => 'Missed',
      OutcomeKind.didNotHappen => 'Did Not Attempt',
      null => 'Draft',
    };
  }

  static IconData _historyIcon(OutcomeReport report) {
    if (report.outcome == OutcomeKind.partiallyCompleted) {
      return Icons.sync_disabled;
    }
    return report.status == OutcomeReportStatus.submitted
        ? Icons.check_circle_outline
        : Icons.history;
  }

  static Color _historyColor(BuildContext context, OutcomeReport report) {
    if (report.outcome == OutcomeKind.partiallyCompleted) {
      return const Color(0xFFE27386);
    }
    return report.status == OutcomeReportStatus.submitted
        ? Theme.of(context).colorScheme.primary
        : Colors.white54;
  }
}
