import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/presentation/planner_event_open.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_detail_primitives.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

/// The canonical UNREPORTED hub (owner law, 2026-09-19).
///
/// ONE unreported-Event backlog, classified into exactly one of three tabs by
/// canonical linkage — Life Goals, Events, Contacts.  Tasks are deliberately
/// absent: they have a single canonical home, the Tasks screen.
///
/// Every row opens the canonical Calendar Event detail/report flow, and an
/// attached Contact keeps its canonical Contact Profile hand-off.  The tab
/// rows, the hamburger red number and the summary notification all render the
/// SAME provider, so they can never disagree.
final class UnreportedScreen extends ConsumerWidget {
  const UnreportedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backlog = ref.watch(unreportedEntriesProvider);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: InternalAppBar(
          title: const Text('Unreported'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(key: Key('unreported-tab-life-goals'), text: 'Life Goals'),
              Tab(key: Key('unreported-tab-events'), text: 'Events'),
              Tab(key: Key('unreported-tab-contacts'), text: 'Contacts'),
            ],
          ),
        ),
        body: backlog.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object error, StackTrace stackTrace) =>
              const _UnreportedMessage(
                'Unreported items could not be loaded.',
              ),
          data: (List<UnreportedEntry> entries) => const TabBarView(
            children: <Widget>[
              _UnreportedTabList(
                tab: UnreportedTab.lifeGoals,
                emptyMessage: 'No Life Goal events are awaiting a report.',
              ),
              _UnreportedTabList(
                tab: UnreportedTab.events,
                emptyMessage: 'No Events are awaiting a report.',
              ),
              _UnreportedTabList(
                tab: UnreportedTab.contacts,
                emptyMessage: 'No Contact events are awaiting a report.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _UnreportedTabList extends ConsumerWidget {
  const _UnreportedTabList({required this.tab, required this.emptyMessage});

  final UnreportedTab tab;
  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(unreportedEntriesForTabProvider(tab));
    if (entries.isEmpty) {
      return _UnreportedMessage(
        emptyMessage,
        key: Key('unreported-empty-${tab.name}'),
      );
    }
    return ListView.builder(
      key: PageStorageKey<String>('unreported-list-${tab.name}'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      itemCount: entries.length,
      itemBuilder: (context, index) => _UnreportedRow(entry: entries[index]),
    );
  }
}

final class _UnreportedRow extends StatelessWidget {
  const _UnreportedRow({required this.entry});

  final UnreportedEntry entry;

  @override
  Widget build(BuildContext context) {
    final item = entry.event.item;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        key: Key('unreported-row-${item.id}'),
        leading: Icon(
          _tabIcon(entry.tab),
          color: entry.tab == UnreportedTab.events
              ? AppTheme.warning
              : Theme.of(context).colorScheme.primary,
        ),
        title: Row(
          children: <Widget>[
            Flexible(child: Text(item.displayTitle)),
            if (item.isRecurring) ...const <Widget>[
              SizedBox(width: 6),
              Icon(Icons.repeat, size: 16),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_detailLine(item)),
            if (entry.goalId != null)
              _UnreportedGoalLine(goalId: entry.goalId!),
            if (entry.contacts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final contact in entry.contacts)
                      PlannerPreviewContactLink(
                        key: Key('unreported-contact-${contact.contactId}'),
                        contactId: contact.contactId,
                        name: contact.displayName,
                        contact: contact.contact,
                      ),
                  ],
                ),
              ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPlannerCalendarEvent(context, item),
      ),
    );
  }

  static IconData _tabIcon(UnreportedTab tab) => switch (tab) {
    UnreportedTab.lifeGoals => Icons.flag_outlined,
    UnreportedTab.events => Icons.assignment_late_outlined,
    UnreportedTab.contacts => Icons.people_outline,
  };

  /// `2026-09-19 · 2:10 PM – 3:00 PM` (timed) or `2026-09-19 · All day`.
  static String _detailLine(PlannerCalendarItem item) {
    if (item.timing == PlannerEventTiming.allDay) {
      return '${item.date.iso8601} · All day';
    }
    return '${item.date.iso8601} · ${_time(item.startLocal)} – '
        '${_time(item.endLocal)}';
  }

  static String _time(DateTime? value) {
    if (value == null) {
      return 'Time not set';
    }
    final hour = value.hour == 0
        ? 12
        : value.hour > 12
        ? value.hour - 12
        : value.hour;
    return '$hour:${value.minute.toString().padLeft(2, '0')} '
        '${value.hour >= 12 ? 'PM' : 'AM'}';
  }
}

/// The Life Goal a row belongs to.  Resolved through the canonical goal read
/// (archived goals still resolve, so a historical link never renders blank),
/// and absent only while the goal lookup is still in flight.
final class _UnreportedGoalLine extends ConsumerWidget {
  const _UnreportedGoalLine({required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(goalByIdProvider(goalId)).value;
    if (goal == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.flag_outlined,
            size: 16,
            color: AppTheme.detailCaptionOf(context),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(goal.title)),
        ],
      ),
    );
  }
}

final class _UnreportedMessage extends StatelessWidget {
  const _UnreportedMessage(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: InternalScreen.label.copyWith(
            color: AppTheme.secondaryTextOf(context),
          ),
        ),
      ),
    );
  }
}
