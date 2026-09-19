// Owner law (2026-09-20) — the Unreported timeline.
//
// Pins the PMG-inspired presentation the owner approved: the same flat
// date-grouped timeline as Tasks, and the record's CANONICAL marker for each
// tab — the Goal's own registered icon for Life Goals (never the stale
// Material flag), the app's real Report-Progress "Unreported" disc for Events,
// and the canonical People icon for Contacts — plus the single Events info
// line.  The accepted classification/count law is untouched.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_report_status_icons.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';
import 'package:rmplanner/features/unreported/presentation/unreported_screen.dart';

import '../../support/test_dependencies.dart';

void main() {
  group('occurrence date grouping', () {
    test('same occurrence date is ONE section', () {
      final groups = groupUnreportedEntries(<UnreportedEntry>[
        _entry(tab: UnreportedTab.events, id: 'a', day: 19),
        _entry(tab: UnreportedTab.events, id: 'b', day: 19),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.label, 'SEP 19, 2026');
      expect(groups.single.entries, hasLength(2));
    });

    test('different occurrence dates are ordered sections', () {
      final groups = groupUnreportedEntries(<UnreportedEntry>[
        _entry(tab: UnreportedTab.events, id: 'older', day: 18),
        _entry(tab: UnreportedTab.events, id: 'newer', day: 20),
      ]);
      expect(groups.map((group) => group.label).toList(), <String>[
        'SEP 18, 2026',
        'SEP 20, 2026',
      ]);
    });
  });

  group('Unreported timeline surface', () {
    Future<void> pumpHub(
      WidgetTester tester, {
      required List<UnreportedEntry> entries,
      List<Override> extraOverrides = const <Override>[],
    }) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startup = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      await startup.completeOnboarding();
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          extraOverrides: <Override>[
            unreportedEntriesProvider.overrideWith((ref) async => entries),
            ...extraOverrides,
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-unreported')));
      await tester.pumpAndSettle();
    }

    testWidgets('Life Goals uses the Goal canonical icon and no stale flag', (
      tester,
    ) async {
      const goalId = 'goal-1';
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          _entry(
            tab: UnreportedTab.lifeGoals,
            id: 'goal-occurrence',
            day: 19,
            goalId: goalId,
          ),
        ],
        extraOverrides: <Override>[
          goalByIdProvider.overrideWith(
            (ref, String id) async => id == goalId ? _goal(goalId) : null,
          ),
        ],
      );

      final marker = find.byKey(
        const Key('unreported-goal-marker-goal-occurrence'),
      );
      expect(marker, findsOneWidget);
      final icon = tester.widget<GoalIcon>(marker);
      expect(
        icon.iconId,
        'find_job',
        reason: 'the marker renders the Goal\'s OWN registered icon',
      );
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
      expect(find.byIcon(Icons.flag), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unresolvable Goal still never shows the stale flag', (
      tester,
    ) async {
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          _entry(tab: UnreportedTab.lifeGoals, id: 'goal-occurrence', day: 19),
        ],
      );
      expect(find.byType(GoalIcon), findsOneWidget);
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
      expect(find.byIcon(Icons.track_changes_outlined), findsOneWidget);
    });

    testWidgets('Events uses the real Report-Progress Unreported icon', (
      tester,
    ) async {
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          _entry(tab: UnreportedTab.events, id: 'plain-occurrence', day: 19),
        ],
      );
      await tester.tap(find.byKey(const Key('unreported-tab-events')));
      await tester.pumpAndSettle();

      final marker = find.byKey(
        const Key('unreported-event-marker-plain-occurrence'),
      );
      expect(marker, findsOneWidget);
      expect(
        tester.widget<PlannerReportStatusIcon>(marker).kind,
        PlannerReportStatusKind.unreported,
      );
      expect(find.byIcon(Icons.assignment_late_outlined), findsNothing);
    });

    testWidgets('Contacts keeps the canonical People icon', (tester) async {
      final contact = _contact('contact-1', 'Juan Dela Cruz');
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          UnreportedEntry(
            tab: UnreportedTab.contacts,
            event: _awaiting('contact-occurrence', 19),
            goalId: null,
            contacts: <UnreportedContactRef>[
              UnreportedContactRef(
                contactId: contact.id,
                displayName: contact.displayName,
                contact: ContactSummary(contact: contact),
              ),
            ],
          ),
        ],
      );
      await tester.tap(find.byKey(const Key('unreported-tab-contacts')));
      await tester.pumpAndSettle();

      // Scoped to the landmark itself: the shell's own Contacts destination
      // legitimately uses the same People icon.
      final marker = find.byKey(
        const Key('unreported-contact-marker-contact-occurrence'),
      );
      expect(marker, findsOneWidget);
      expect(tester.widget<Icon>(marker).icon, Icons.people_outline);
      // The accepted canonical Contact hand-off still renders.
      expect(
        find.byKey(const Key('unreported-contact-contact-1')),
        findsOneWidget,
      );
    });

    testWidgets('the Events info line is exact and appears on Events only', (
      tester,
    ) async {
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          _entry(tab: UnreportedTab.lifeGoals, id: 'goal-occurrence', day: 19),
          _entry(tab: UnreportedTab.events, id: 'plain-occurrence', day: 19),
        ],
      );

      // Life Goals (the initially selected tab) carries no info line.
      expect(
        find.byKey(const Key('unreported-events-info-line')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('unreported-tab-events')));
      await tester.pumpAndSettle();
      expect(
        find.text('Only events with Report Progress enabled are shown.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('unreported-tab-contacts')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('unreported-events-info-line')),
        findsNothing,
      );
    });

    testWidgets('the timeline is date-grouped, pinned and card-free', (
      tester,
    ) async {
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          _entry(tab: UnreportedTab.events, id: 'same-day-a', day: 19),
          _entry(tab: UnreportedTab.events, id: 'same-day-b', day: 19),
          _entry(tab: UnreportedTab.events, id: 'other-day', day: 18),
        ],
      );
      await tester.tap(find.byKey(const Key('unreported-tab-events')));
      await tester.pumpAndSettle();

      // Two distinct occurrence dates, one section each, oldest group first.
      expect(find.text('SEP 19, 2026'), findsOneWidget);
      expect(find.text('SEP 18, 2026'), findsOneWidget);
      final headers = tester
          .widgetList<SliverPersistentHeader>(
            find.byType(SliverPersistentHeader),
          )
          .toList();
      expect(headers, isNotEmpty);
      expect(headers.every((header) => header.pinned), isTrue);
      expect(
        find.descendant(
          of: find.byKey(const Key('unreported-list-events')),
          matching: find.byType(Card),
        ),
        findsNothing,
      );
    });

    testWidgets('a row still opens the canonical Calendar Event source', (
      tester,
    ) async {
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          _entry(tab: UnreportedTab.events, id: 'plain-occurrence', day: 19),
        ],
      );
      await tester.tap(find.byKey(const Key('unreported-tab-events')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('unreported-row-plain-occurrence')),
      );
      await tester.pumpAndSettle();

      // The canonical Calendar Event detail sheet opens over the hub, exactly
      // as it does from the Planner.
      expect(
        find.byKey(const Key('event-detail-sheet-close')),
        findsOneWidget,
        reason: 'a row still reaches the canonical Event detail/report flow',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the hub keeps its three tabs and never a Tasks tab', (
      tester,
    ) async {
      await pumpHub(tester, entries: <UnreportedEntry>[]);
      expect(find.byType(UnreportedScreen), findsOneWidget);
      expect(
        find.byKey(const Key('unreported-tab-life-goals')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('unreported-tab-events')), findsOneWidget);
      expect(find.byKey(const Key('unreported-tab-contacts')), findsOneWidget);
      expect(
        find.descendant(of: find.byType(TabBar), matching: find.byType(Tab)),
        findsNWidgets(3),
      );
      expect(find.byKey(const Key('unreported-back')), findsOneWidget);
    });
  });
}

UnreportedEntry _entry({
  required UnreportedTab tab,
  required String id,
  required int day,
  String? goalId,
}) {
  return UnreportedEntry(
    tab: tab,
    event: _awaiting(id, day),
    goalId: goalId,
    contacts: const <UnreportedContactRef>[],
  );
}

AwaitingReportEvent _awaiting(String id, int day) {
  final endUtc = DateTime.utc(2026, 9, day, 10);
  return AwaitingReportEvent(
    item: PlannerCalendarItem(
      id: id,
      eventId: 'event-$id',
      originalDate: PlannerDate(year: 2026, month: 9, day: day),
      title: 'Unreported $id',
      date: PlannerDate(year: 2026, month: 9, day: day),
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

Goal _goal(String id) {
  final created = DateTime.utc(2026, 9, 1, 9);
  return Goal(
    id: id,
    profileId: 'profile',
    indicatorKey: null,
    assignedEventTypeStableKey: null,
    role: GoalRole.weekly,
    activeSlotIndex: null,
    title: 'Find a job',
    iconId: 'find_job',
    status: GoalStatus.active,
    createdAtUtc: created,
    updatedAtUtc: created,
    archivedAtUtc: null,
    deletedAtUtc: null,
  );
}

Contact _contact(String id, String displayName) {
  final createdAt = DateTime.utc(2026, 9, 1, 9);
  return Contact(
    id: id,
    profileId: 'profile',
    firstName: displayName.split(' ').first,
    lastName: displayName.split(' ').last,
    displayName: displayName,
    preferredContactMethod: ContactPreferredMethod.message,
    isFavorite: false,
    lifecycleState: ContactLifecycleState.active,
    source: ContactSource.manual,
    createdAtUtc: createdAt,
    updatedAtUtc: createdAt,
  );
}
