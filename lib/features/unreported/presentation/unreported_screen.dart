import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/app/shell/planning_navigation.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/presentation/planner_event_open.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_contact_channel_visuals.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_detail_primitives.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_report_status_icons.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planning_timeline.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/application/unreported_summary_routing.dart';
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
///
/// Presentation (owner law, 2026-09-20): the same flat date-grouped timeline as
/// Tasks — pinned date headers, a rail, and the record's CANONICAL marker:
/// the Goal's own icon for Life Goals, the app's real Report-Progress
/// "Unreported" disc for Events, and the canonical People icon for Contacts.
/// The stale Material flag is gone.
///
/// P4 (2026-09-22): the hub also consumes the ONE typed one-shot tab request
/// the summary-notification route leaves behind, so a summary tap opens the tab
/// that then owned the backlog.  It is consumed exactly once — afterwards the
/// user's own tab selection is authoritative and later backlog changes never
/// seize the current tab.
final class UnreportedScreen extends ConsumerStatefulWidget {
  const UnreportedScreen({super.key});

  /// The owner's exact single-line explanation for the Events tab.
  static const String eventsInfoLine =
      'Only events with Report Progress enabled are shown.';

  @override
  ConsumerState<UnreportedScreen> createState() => _UnreportedScreenState();
}

final class _UnreportedScreenState extends ConsumerState<UnreportedScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: unreportedSummaryTabPriority.length,
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    // The request can already be pending before the hub is first built (cold
    // start, or the hub was not mounted yet), so consume it once here as well
    // as listening for one that arrives while the hub is already mounted.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyPendingTabRequest(),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Applies AND consumes the pending request, exactly once.
  void _applyPendingTabRequest() {
    if (!mounted) return;
    final request = ref.read(unreportedSummaryTabRequestProvider);
    if (request == null) return;
    ref.read(unreportedSummaryTabRequestProvider.notifier).consume();
    final index = unreportedTabIndex(request.tab);
    if (_tabs.index == index) return;
    _tabs.animateTo(index);
  }

  @override
  Widget build(BuildContext context) {
    // A request that arrives while the hub is already mounted (warm app, or a
    // second summary tap from another tab) takes the same one-shot path.
    ref.listen<UnreportedSummaryTabRequest?>(
      unreportedSummaryTabRequestProvider,
      (
        UnreportedSummaryTabRequest? previous,
        UnreportedSummaryTabRequest? next,
      ) {
        if (next == null) return;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _applyPendingTabRequest(),
        );
      },
    );
    final backlog = ref.watch(unreportedEntriesProvider);
    final origin = planningRouteOriginOf(context);
    return Scaffold(
      appBar: InternalAppBar(
        automaticallyImplyLeading: false,
        leading: PlanningBackButton(
          key: const Key('unreported-back'),
          origin: origin,
        ),
        title: const Text('Unreported'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const <Widget>[
            Tab(key: Key('unreported-tab-life-goals'), text: 'Life Goals'),
            Tab(key: Key('unreported-tab-events'), text: 'Events'),
            Tab(key: Key('unreported-tab-contacts'), text: 'Contacts'),
          ],
        ),
      ),
      body: backlog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stackTrace) =>
            const _UnreportedMessage('Unreported items could not be loaded.'),
        data: (List<UnreportedEntry> entries) => TabBarView(
          controller: _tabs,
          children: const <Widget>[
            _UnreportedTimeline(
              tab: UnreportedTab.lifeGoals,
              emptyMessage: 'No Life Goal events are awaiting a report.',
            ),
            _UnreportedTimeline(
              tab: UnreportedTab.events,
              emptyMessage: 'No Events are awaiting a report.',
            ),
            _UnreportedTimeline(
              tab: UnreportedTab.contacts,
              emptyMessage: 'No Contact events are awaiting a report.',
            ),
          ],
        ),
      ),
    );
  }
}

/// One date group of the Unreported timeline.
final class UnreportedDateGroup {
  const UnreportedDateGroup({
    required this.label,
    required this.keyPrefix,
    required this.entries,
  });

  final String label;
  final String keyPrefix;
  final List<UnreportedEntry> entries;
}

/// Groups entries by the OCCURRENCE's canonical local date, preserving the
/// accepted backlog order (oldest occurrence first).  Never the creation
/// timestamp and never the report timestamp, and there is no age expiration.
List<UnreportedDateGroup> groupUnreportedEntries(
  List<UnreportedEntry> entries,
) {
  final byDate = <String, List<UnreportedEntry>>{};
  final labels = <String, String>{};
  final orderedKeys = <String>[];
  for (final entry in entries) {
    final date = entry.event.item.date;
    final key = date.iso8601;
    final bucket = byDate.putIfAbsent(key, () {
      labels[key] = planningDateSectionLabel(date);
      orderedKeys.add(key);
      return <UnreportedEntry>[];
    });
    bucket.add(entry);
  }
  return <UnreportedDateGroup>[
    for (final key in orderedKeys)
      UnreportedDateGroup(
        label: labels[key]!,
        keyPrefix: 'occurrence-$key',
        entries: List<UnreportedEntry>.unmodifiable(byDate[key]!),
      ),
  ];
}

final class _UnreportedTimeline extends ConsumerWidget {
  const _UnreportedTimeline({required this.tab, required this.emptyMessage});

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
    final groups = groupUnreportedEntries(entries);
    return CustomScrollView(
      key: PageStorageKey<String>('unreported-list-${tab.name}'),
      slivers: <Widget>[
        // The Events tab explains its own filter in ONE muted line; the other
        // two tabs carry no such note.
        if (tab == UnreportedTab.events)
          const SliverToBoxAdapter(
            child: PlanningTimelineInfoLine(
              key: Key('unreported-events-info-line'),
              text: UnreportedScreen.eventsInfoLine,
            ),
          ),
        for (final group in groups)
          PlanningTimelineSection(
            label: group.label,
            keyPrefix: group.keyPrefix,
            children: <Widget>[
              for (var index = 0; index < group.entries.length; index++)
                _UnreportedTimelineRow(
                  entry: group.entries[index],
                  isFirst: index == 0,
                  isLast: index == group.entries.length - 1,
                ),
            ],
          ).buildSliver(context),
        planningTimelineTail,
      ],
    );
  }
}

final class _UnreportedTimelineRow extends StatelessWidget {
  const _UnreportedTimelineRow({
    required this.entry,
    required this.isFirst,
    required this.isLast,
  });

  final UnreportedEntry entry;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final item = entry.event.item;
    return PlanningTimelineRow(
      rowKey: Key('unreported-row-${item.id}'),
      isFirst: isFirst,
      isLast: isLast,
      marker: _UnreportedCategoryMarker(
        tab: entry.tab,
        // The EFFECTIVE Life Goal, not just the manual link: an Event created
        // under one of the six fixed Goal-linked Event Types is canonically
        // bound to the Goal that occupies that slot, so it must render THAT
        // Goal's own icon rather than a generic one shared by every row.
        goalId: entry.linkedGoalId,
        // The occurrence-effective Contact Type, so a Contact row draws its own
        // channel visual instead of one generic Contact glyph for every row.
        contactChannel: entry.event.contactChannel,
        item: item,
      ),
      timeLine: _timeLine(item),
      title: item.displayTitle,
      trailing: item.isRecurring
          ? Icon(
              Icons.repeat,
              key: Key('unreported-recurring-${item.id}'),
              size: 16,
              color: AppTheme.secondaryTextOf(context),
            )
          : null,
      secondary: _secondary(context),
      onTap: () => openPlannerCalendarEvent(context, item),
    );
  }

  Widget? _secondary(BuildContext context) {
    final goalId = entry.linkedGoalId;
    if (goalId == null && entry.contacts.isEmpty) {
      return null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (goalId != null)
          _UnreportedGoalLine(
            key: Key('unreported-goal-$goalId'),
            goalId: goalId,
          ),
        if (entry.contacts.isNotEmpty)
          for (final contact in entry.contacts)
            PlannerPreviewContactLink(
              key: Key('unreported-contact-${contact.contactId}'),
              contactId: contact.contactId,
              name: contact.displayName,
              contact: contact.contact,
            ),
      ],
    );
  }

  /// `10:30 AM – 11:00 AM`, `All day`, or no time line at all — a record never
  /// gains a fabricated time.
  static String? _timeLine(PlannerCalendarItem item) {
    if (item.timing == PlannerEventTiming.allDay) {
      return 'All day';
    }
    final start = item.startLocal;
    final end = item.endLocal;
    if (start == null) {
      return null;
    }
    if (end == null) {
      return planningClockLabel(start);
    }
    return '${planningClockLabel(start)} – ${planningClockLabel(end)}';
  }
}

/// The record's CANONICAL marker for its tab.
///
/// Life Goals → the Goal's own registered icon (`GoalIcon`), the same renderer
/// every other Goal surface uses; an unresolvable Goal falls back to the app's
/// canonical Life-Goal-link glyph, never a stale flag.
/// Events → the real Report-Progress "Unreported" disc the Planner already
/// paints for an Event awaiting its report.
/// Contacts → the canonical People icon, unchanged.
final class _UnreportedCategoryMarker extends ConsumerWidget {
  const _UnreportedCategoryMarker({
    required this.tab,
    required this.goalId,
    required this.contactChannel,
    required this.item,
  });

  final UnreportedTab tab;
  final String? goalId;

  /// The Event's effective Contact Type for the Contacts tab. `null` means
  /// "never stored", which presents as In Person — never as "Not set".
  final EventContactChannel? contactChannel;

  final PlannerCalendarItem item;

  static const double size = 22;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (tab) {
      case UnreportedTab.lifeGoals:
        final goal = goalId == null
            ? null
            : ref.watch(goalByIdProvider(goalId!)).value;
        return GoalIcon(
          key: Key('unreported-goal-marker-${item.id}'),
          iconId: goal?.iconId,
          size: size,
          fallbackIcon: Icons.track_changes_outlined,
          semanticLabel: goal?.title ?? 'Life Goal event',
        );
      case UnreportedTab.events:
        return PlannerReportStatusIcon(
          key: Key('unreported-event-marker-${item.id}'),
          kind: PlannerReportStatusKind.unreported,
          size: size,
        );
      case UnreportedTab.contacts:
        // Owner revision (2026-09-22): the marker follows the Event's effective
        // Contact Type rather than drawing one generic glyph for every Contact
        // Event. In Person — and a legacy NULL, which IS In Person — keeps the
        // generic Contacts/People glyph this surface has always drawn, because
        // the visual is the same one the Contacts surfaces use. The key stays on
        // whichever widget is built, so the landmark is unchanged.
        return eventContactChannelVisual(
          key: Key('unreported-contact-marker-${item.id}'),
          channel: contactChannel,
          color: Theme.of(context).colorScheme.primary,
          size: size,
        );
    }
  }
}

/// The Life Goal a row belongs to.  Resolved through the canonical goal read
/// (archived goals still resolve, so a historical link never renders blank),
/// and absent only while the goal lookup is still in flight.
final class _UnreportedGoalLine extends ConsumerWidget {
  const _UnreportedGoalLine({required this.goalId, super.key});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(goalByIdProvider(goalId)).value;
    if (goal == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        goal.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: 13,
          height: 18 / 13,
          color: AppTheme.secondaryTextOf(context),
        ),
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
