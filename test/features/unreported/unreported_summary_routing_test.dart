// P4 (2026-09-22) — SMART UNREPORTED SUMMARY ROUTING, pure law.
//
// The summary notification opens the Unreported hub on the tab that then owned
// the most actionable occurrences.  The exception is zero backlog: the owner
// asked for Life Goals and its honest empty state.
//
// Routing tie priority (Life Goals -> Events -> Contacts) is a DIFFERENT
// concept from the frozen classification precedence (Life Goals -> Contacts ->
// Events); this file pins that difference down so a future edit cannot quietly
// merge the two.

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/unreported/application/unreported_summary_routing.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

void main() {
  group('P4 owner cases', () {
    test('LG 1 / E 4 / C 2 -> Events', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 1, events: 4, contacts: 2)),
        UnreportedTab.events,
      );
    });

    test('LG 0 / E 0 / C 1 -> Contacts', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 0, events: 0, contacts: 1)),
        UnreportedTab.contacts,
      );
    });

    test('LG 2 / E 2 / C 2 -> Life Goals (a tie is never stolen)', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 2, events: 2, contacts: 2)),
        UnreportedTab.lifeGoals,
      );
    });

    test('LG 2 / E 2 / C 1 -> Life Goals', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 2, events: 2, contacts: 1)),
        UnreportedTab.lifeGoals,
      );
    });

    test('LG 1 / E 3 / C 3 -> Events (Events outranks Contacts on a tie)', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 1, events: 3, contacts: 3)),
        UnreportedTab.events,
      );
    });

    test('LG 0 / E 0 / C 0 -> Life Goals (the honest empty state)', () {
      expect(
        unreportedSummaryTabFor(const <UnreportedEntry>[]),
        UnreportedTab.lifeGoals,
      );
      expect(countUnreportedEntriesByTab(const <UnreportedEntry>[]).total, 0);
    });
  });

  group('single-tab backlogs open their own tab', () {
    test('Life Goals only', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 3)),
        UnreportedTab.lifeGoals,
      );
    });

    test('Events only', () {
      expect(unreportedSummaryTabFor(_mix(events: 1)), UnreportedTab.events);
    });

    test('Contacts only, even when Contacts dominate Life Goals', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 2, contacts: 9)),
        UnreportedTab.contacts,
      );
    });

    test('Contacts win when they strictly dominate both other tabs', () {
      expect(
        unreportedSummaryTabFor(_mix(lifeGoals: 5, events: 5, contacts: 6)),
        UnreportedTab.contacts,
      );
    });
  });

  group('counting law', () {
    test('every classified occurrence is counted exactly once', () {
      final entries = _mix(lifeGoals: 2, events: 3, contacts: 1);
      final counts = countUnreportedEntriesByTab(entries);
      expect(counts.lifeGoals, 2);
      expect(counts.events, 3);
      expect(counts.contacts, 1);
      expect(
        counts.total,
        entries.length,
        reason: 'the tab counts must never double-count an occurrence',
      );
    });

    test('counting sums to the canonical list length for uneven backlogs', () {
      final entries = _mix(lifeGoals: 7, events: 1, contacts: 4);
      expect(countUnreportedEntriesByTab(entries).total, 12);
      expect(countsFor(entries)[UnreportedTab.contacts], 4);
    });

    test('a shuffled order gives the same tab and the same counts', () {
      final ordered = _mix(lifeGoals: 1, events: 4, contacts: 2);
      // The same occurrences in a different order.
      final shuffled = <UnreportedEntry>[
        ...ordered.where((entry) => entry.tab == UnreportedTab.contacts),
        ...ordered.where((entry) => entry.tab == UnreportedTab.events),
        ...ordered.where((entry) => entry.tab == UnreportedTab.lifeGoals),
      ];
      expect(shuffled.length, ordered.length);
      expect(
        unreportedSummaryTabFor(shuffled),
        unreportedSummaryTabFor(ordered),
      );
      expect(
        countsFor(shuffled)[UnreportedTab.events],
        countsFor(ordered)[UnreportedTab.events],
      );
    });

    test('the routing count source is the tab ownership, not a title', () {
      // An occurrence whose TITLE reads like another tab belongs to the tab its
      // canonical classification assigned; routing must follow the tab.
      final entries = <UnreportedEntry>[
        _entry(UnreportedTab.contacts, 'title suggests a Goal'),
        _entry(UnreportedTab.contacts, 'title suggests an Event'),
      ];
      expect(unreportedSummaryTabFor(entries), UnreportedTab.contacts);
    });
  });

  group('the routing surface can never select Tasks', () {
    test('the hub has exactly the three canonical tabs', () {
      expect(UnreportedTab.values, <UnreportedTab>[
        UnreportedTab.lifeGoals,
        UnreportedTab.events,
        UnreportedTab.contacts,
      ]);
      for (final tab in UnreportedTab.values) {
        expect(tab.name.toLowerCase(), isNot(contains('task')));
      }
    });

    test(
      'the routing priority covers exactly the canonical tabs, in order',
      () {
        expect(unreportedSummaryTabPriority, <UnreportedTab>[
          UnreportedTab.lifeGoals,
          UnreportedTab.events,
          UnreportedTab.contacts,
        ]);
        expect(
          unreportedSummaryTabPriority.toSet(),
          UnreportedTab.values.toSet(),
        );
      },
    );

    test('the page index matches the hub tab order', () {
      expect(unreportedTabIndex(UnreportedTab.lifeGoals), 0);
      expect(unreportedTabIndex(UnreportedTab.events), 1);
      expect(unreportedTabIndex(UnreportedTab.contacts), 2);
    });
  });

  group('routing timeout law', () {
    test('a fresh read gets five seconds before the honest fallback', () {
      expect(unreportedSummaryRoutingTimeout, const Duration(seconds: 5));
    });
  });
}

Map<UnreportedTab, int> countsFor(List<UnreportedEntry> entries) {
  final counts = countUnreportedEntriesByTab(entries);
  return <UnreportedTab, int>{
    for (final tab in UnreportedTab.values) tab: counts[tab],
  };
}

/// The canonical classification already assigned each occurrence a tab, so a
/// mixed backlog is built by simply listing occurrences under their tab.
List<UnreportedEntry> _mix({
  int lifeGoals = 0,
  int events = 0,
  int contacts = 0,
}) {
  var id = 0;
  return <UnreportedEntry>[
    for (var index = 0; index < lifeGoals; index++)
      _entry(UnreportedTab.lifeGoals, 'lg-${id++}'),
    for (var index = 0; index < events; index++)
      _entry(UnreportedTab.events, 'ev-${id++}'),
    for (var index = 0; index < contacts; index++)
      _entry(UnreportedTab.contacts, 'co-${id++}'),
  ];
}

UnreportedEntry _entry(UnreportedTab tab, String id) {
  return UnreportedEntry(
    tab: tab,
    event: _awaiting(id),
    goalId: null,
    contacts: const <UnreportedContactRef>[],
  );
}

AwaitingReportEvent _awaiting(String id) {
  final endUtc = DateTime.utc(2026, 9, 6, 10);
  return AwaitingReportEvent(
    item: PlannerCalendarItem(
      id: id,
      eventId: 'event-$id',
      originalDate: PlannerDate.fromDateTime(endUtc),
      title: 'Unreported $id',
      date: PlannerDate.fromDateTime(endUtc),
      timing: PlannerEventTiming.timed,
      state: PlannerEventState.scheduled,
      requiresReport: true,
      hasOutcomeReport: false,
      startUtc: endUtc.subtract(const Duration(hours: 1)),
      endUtc: endUtc,
    ),
    goalId: null,
    activityTypeStableKey: null,
  );
}
