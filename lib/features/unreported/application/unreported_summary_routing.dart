import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

/// P4 (2026-09-22) — SMART UNREPORTED SUMMARY ROUTING (pure law).
///
/// When the user taps the generic/unreported SUMMARY notification, Next
/// Transfer opens the Unreported hub on the tab that currently owns the most
/// actionable occurrences.
///
/// The count is taken from the EXISTING canonical classification result
/// ([UnreportedEntry.tab]), never from raw CalendarEvents, People links, Goal
/// links, notification payload counts or Tasks.  Classification precedence
/// (Life Goals -> Contacts -> Events) is frozen and untouched here; this file
/// only decides which tab to OPEN, which has its own tie priority:
///
/// 1. Life Goals
/// 2. Events
/// 3. Contacts
///
/// So the winner starts as Life Goals and is replaced only by a STRICTLY
/// larger count, in that order.  A zero backlog therefore still opens Life
/// Goals and shows its honest empty state.

/// How long a summary tap waits for one fresh canonical projection before it
/// falls back to the canonical hub's first tab.
///
/// The fallback never fabricates a zero count: the hub keeps its own honest
/// loading/error state, and a late completion cannot hijack navigation because
/// the request generation has already moved on.
const Duration unreportedSummaryRoutingTimeout = Duration(seconds: 5);

/// The canonical tab order of the Unreported hub, and therefore the routing
/// tie priority.  Kept as an explicit list rather than derived from
/// [UnreportedTab.values] so a future enum addition cannot silently change
/// routing priority.
const List<UnreportedTab> unreportedSummaryTabPriority = <UnreportedTab>[
  UnreportedTab.lifeGoals,
  UnreportedTab.events,
  UnreportedTab.contacts,
];

/// The per-tab occurrence counts of one canonical backlog projection.
final class UnreportedTabCounts {
  const UnreportedTabCounts({
    required this.lifeGoals,
    required this.events,
    required this.contacts,
  });

  final int lifeGoals;
  final int events;
  final int contacts;

  /// Every classified occurrence, counted exactly once.
  int get total => lifeGoals + events + contacts;

  int operator [](UnreportedTab tab) => switch (tab) {
    UnreportedTab.lifeGoals => lifeGoals,
    UnreportedTab.events => events,
    UnreportedTab.contacts => contacts,
  };

  @override
  String toString() =>
      'UnreportedTabCounts(LG=$lifeGoals, E=$events, C=$contacts)';
}

/// Counts CURRENT canonical [entries] by their existing tab ownership.
///
/// Each entry is one actionable occurrence and is counted once, so the counts
/// sum to `entries.length` and can never double-count.
UnreportedTabCounts countUnreportedEntriesByTab(
  Iterable<UnreportedEntry> entries,
) {
  var lifeGoals = 0;
  var events = 0;
  var contacts = 0;
  for (final entry in entries) {
    switch (entry.tab) {
      case UnreportedTab.lifeGoals:
        lifeGoals += 1;
      case UnreportedTab.events:
        events += 1;
      case UnreportedTab.contacts:
        contacts += 1;
    }
  }
  return UnreportedTabCounts(
    lifeGoals: lifeGoals,
    events: events,
    contacts: contacts,
  );
}

/// The tab a summary tap must open for this canonical backlog projection.
UnreportedTab unreportedSummaryTabFor(Iterable<UnreportedEntry> entries) {
  final counts = countUnreportedEntriesByTab(entries);
  var best = UnreportedTab.lifeGoals;
  var bestCount = counts.lifeGoals;
  for (final tab in unreportedSummaryTabPriority) {
    if (tab == UnreportedTab.lifeGoals) continue;
    final count = counts[tab];
    if (count > bestCount) {
      best = tab;
      bestCount = count;
    }
  }
  return best;
}

/// The 0-based page index of [tab] in the hub's canonical tab order.
int unreportedTabIndex(UnreportedTab tab) =>
    unreportedSummaryTabPriority.indexOf(tab);
